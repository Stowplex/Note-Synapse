import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/models/protocol_exchange.dart';
import 'package:note_synapse/models/protocol_study.dart';
import 'package:note_synapse/services/protocol_study/protocol_ai_projection.dart';
import 'package:note_synapse/services/protocol_study/protocol_sensitivity_classifier.dart';
import 'package:note_synapse/services/protocol_study/protocol_study_workspace.dart';

void main() {
  ProtocolExchange exchange({bool selected = true}) => ProtocolExchange(
    id: 'exchange-1',
    pageInstanceId: 'page-1',
    sequence: 1,
    source: ProtocolRequestSource.fetch,
    method: 'POST',
    url: 'https://api.example.com/search?q=private-search',
    startedAt: DateTime.parse('2026-08-02T12:00:00Z'),
    requestHeaders: const [
      ProtocolField(
        id: 'authorization-field',
        location: ProtocolFieldLocation.requestHeader,
        name: 'Authorization',
        value: 'Bearer do-not-send',
      ),
    ],
    queryFields: const [
      ProtocolField(
        id: 'query-field',
        location: ProtocolFieldLocation.query,
        name: 'q',
        value: 'private-search',
      ),
    ],
    requestBody: const ProtocolBody(
      text: '{"card_number":"4111111111111111","page":2}',
      mimeType: 'application/json',
      fields: [
        ProtocolField(
          id: 'card-field',
          location: ProtocolFieldLocation.requestBody,
          name: 'card_number',
          value: '4111111111111111',
        ),
        ProtocolField(
          id: 'page-field',
          location: ProtocolFieldLocation.requestBody,
          name: 'page',
          value: '2',
        ),
      ],
    ),
    responseHeaders: const [],
    mutatesState: true,
    selected: selected,
  );

  group('Protocol sensitivity and disclosure', () {
    test('destination resolves the exact endpoint the approved model uses', () {
      final gemini = ProtocolAIDestination.forModel(
        ModelConfig(
          id: 'gemini-model',
          type: ModelType.gemini,
          endpoint: 'https://gemini.example/v1beta',
          modelName: 'gemini-test',
        ),
      );
      final compatible = ProtocolAIDestination.forModel(
        ModelConfig(
          id: 'openai-model',
          type: ModelType.openaiCompatible,
          endpoint: 'https://openai.example/v1/chat/completions',
          modelName: 'test-model',
        ),
      );

      expect(
        gemini.endpoint,
        'https://gemini.example/v1beta/models/gemini-test:generateContent',
      );
      expect(compatible.endpoint, 'https://openai.example/v1/chat/completions');
    });

    test('labels authentication and payment fields conservatively', () {
      const classifier = ProtocolSensitivityClassifier();
      final fields = classifier.fieldsFor(exchange());
      expect(
        fields
            .firstWhere((field) => field.id == 'authorization-field')
            .sensitivity,
        ProtocolSensitivity.authentication,
      );
      expect(
        fields.firstWhere((field) => field.id == 'card-field').sensitivity,
        ProtocolSensitivity.payment,
      );
    });

    test('remote preview includes only individually disclosed values', () {
      const destination = ProtocolAIDestination(
        modelId: 'remote-model',
        displayName: 'Remote model',
        endpoint: 'https://ai.example.com/v1',
        isLocal: false,
      );
      final disclosure = ProtocolDisclosureSession(
        destination,
        nonce: 'study-session-1',
      )..setDisclosed('query-field', true);
      final preview = const ProtocolAIProjectionBuilder().build(
        exchanges: [exchange()],
        disclosure: disclosure,
      );

      expect(preview.formattedPayload, contains('private-search'));
      expect(preview.formattedPayload, isNot(contains('do-not-send')));
      expect(preview.formattedPayload, isNot(contains('4111111111111111')));
      expect(preview.disclosedFields.map((field) => field.id), ['query-field']);
      expect(preview.redactedFieldCount, 4);
      expect(
        () => const ProtocolOutboundVerifier().verify(
          preview: preview,
          disclosure: disclosure,
          sourceExchanges: [exchange()],
        ),
        returnsNormally,
      );
    });

    test('local model projection can see every captured field', () {
      const destination = ProtocolAIDestination(
        modelId: 'local-model',
        displayName: 'On-device model',
        endpoint: 'on-device',
        isLocal: true,
      );
      final disclosure = ProtocolDisclosureSession(destination);
      final preview = const ProtocolAIProjectionBuilder().build(
        exchanges: [exchange()],
        disclosure: disclosure,
      );
      expect(preview.formattedPayload, contains('do-not-send'));
      expect(preview.formattedPayload, contains('4111111111111111'));
      expect(preview.redactedFieldCount, 0);
    });

    test('local model can omit irrelevant fields from its input', () {
      const destination = ProtocolAIDestination(
        modelId: 'local-model',
        displayName: 'On-device model',
        endpoint: 'on-device',
        isLocal: true,
      );
      final disclosure = ProtocolDisclosureSession(destination)
        ..setIncluded('authorization-field', false);
      final preview = const ProtocolAIProjectionBuilder().build(
        exchanges: [exchange()],
        disclosure: disclosure,
      );

      expect(preview.formattedPayload, isNot(contains('do-not-send')));
      expect(preview.formattedPayload, isNot(contains('authorization-field')));
      expect(preview.excludedFieldCount, 1);
    });

    test('disclosing one copy permits the same sensitive scalar', () {
      const destination = ProtocolAIDestination(
        modelId: 'remote-model',
        displayName: 'Remote model',
        endpoint: 'https://ai.example.com/v1',
        isLocal: false,
      );
      final source = exchange().copyWith(
        requestHeaders: const [
          ProtocolField(
            id: 'authorization-field',
            location: ProtocolFieldLocation.requestHeader,
            name: 'Authorization',
            value: 'Bearer do-not-send',
          ),
          ProtocolField(
            id: 'duplicate-sensitive-field',
            location: ProtocolFieldLocation.requestHeader,
            name: 'X-Session-Mirror',
            value: 'Bearer do-not-send',
          ),
        ],
      );
      final disclosure = ProtocolDisclosureSession(destination)
        ..setDisclosed('authorization-field', true);
      final preview = const ProtocolAIProjectionBuilder().build(
        exchanges: [source],
        disclosure: disclosure,
      );

      expect(
        () => const ProtocolOutboundVerifier().verify(
          preview: preview,
          disclosure: disclosure,
          sourceExchanges: [source],
        ),
        returnsNormally,
      );
      expect(preview.formattedPayload, contains('Bearer do-not-send'));
      expect(
        (preview.payload['exchanges'] as List)
            .cast<Map>()
            .single['requestFields'],
        contains(containsPair('id', 'duplicate-sensitive-field')),
      );
    });

    test(
      'remote model can omit a field instead of sending redacted metadata',
      () {
        const destination = ProtocolAIDestination(
          modelId: 'remote-model',
          displayName: 'Remote model',
          endpoint: 'https://ai.example.com/v1',
          isLocal: false,
        );
        final disclosure = ProtocolDisclosureSession(destination)
          ..setIncluded('card-field', false);
        final preview = const ProtocolAIProjectionBuilder().build(
          exchanges: [exchange()],
          disclosure: disclosure,
        );

        expect(preview.formattedPayload, isNot(contains('card-field')));
        expect(preview.excludedFieldCount, 1);
        expect(
          () => const ProtocolOutboundVerifier().verify(
            preview: preview,
            disclosure: disclosure,
            sourceExchanges: [exchange()],
          ),
          returnsNormally,
        );
      },
    );

    test('remote verifier still rejects an actually leaked field value', () {
      const destination = ProtocolAIDestination(
        modelId: 'remote-model',
        displayName: 'Remote model',
        endpoint: 'https://ai.example.com/v1',
        isLocal: false,
      );
      final disclosure = ProtocolDisclosureSession(destination);
      final preview = const ProtocolAIProjectionBuilder().build(
        exchanges: [exchange()],
        disclosure: disclosure,
      );
      final projectedExchange =
          (preview.payload['exchanges'] as List).single as Map<String, dynamic>;
      final authorization = (projectedExchange['requestFields'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((field) => field['id'] == 'authorization-field');
      authorization['value'] = 'Bearer do-not-send';

      expect(
        () => const ProtocolOutboundVerifier().verify(
          preview: preview,
          disclosure: disclosure,
          sourceExchanges: [exchange()],
        ),
        throwsStateError,
      );
    });

    test('approval is bound to an exact destination and session nonce', () {
      const destination = ProtocolAIDestination(
        modelId: 'model-a',
        displayName: 'A',
        endpoint: 'https://a.example',
        isLocal: false,
      );
      final disclosure = ProtocolDisclosureSession(destination, nonce: 'n1');
      final preview = const ProtocolAIProjectionBuilder().build(
        exchanges: [exchange()],
        disclosure: disclosure,
      );
      final other = ProtocolDisclosureSession(
        const ProtocolAIDestination(
          modelId: 'model-a',
          displayName: 'A',
          endpoint: 'https://other.example',
          isLocal: false,
        ),
        nonce: 'n1',
      );
      expect(
        () => const ProtocolOutboundVerifier().verify(
          preview: preview,
          disclosure: other,
          sourceExchanges: [exchange()],
        ),
        throwsStateError,
      );
    });
  });

  group('ProtocolStudyWorkspace', () {
    late Directory temporary;
    late ProtocolStudyWorkspace workspace;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('protocol-study-test-');
      workspace = ProtocolStudyWorkspace(rootProvider: () async => temporary);
    });

    tearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    test(
      'saves raw studies outside the notes database and loads them',
      () async {
        final timestamp = DateTime.parse('2026-08-02T12:00:00Z');
        final study = ProtocolStudy(
          id: 'study_1',
          title: 'Checkout',
          startUrl: 'https://example.com',
          createdAt: timestamp,
          updatedAt: timestamp,
          sessionProvenance: ProtocolSessionProvenance.noSavedLogin,
          limits: const ProtocolCaptureLimits(),
          exchanges: [exchange()],
        );

        await workspace.save(study);
        expect((await workspace.listStudies()).single.title, 'Checkout');
        expect(
          (await workspace.load('study_1'))!.exchanges.single.id,
          'exchange-1',
        );
        expect(File('${temporary.path}/study_1/study.json').existsSync(), true);
      },
    );

    test('rejects path traversal IDs', () async {
      expect(() => workspace.load('../notes.db'), throwsArgumentError);
    });

    test(
      'recovers an interrupted atomic save from the private backup',
      () async {
        final timestamp = DateTime.parse('2026-08-02T12:00:00Z');
        final study = ProtocolStudy(
          id: 'recoverable',
          title: 'Recover me',
          startUrl: 'https://example.com',
          createdAt: timestamp,
          updatedAt: timestamp,
          sessionProvenance: ProtocolSessionProvenance.noSavedLogin,
          limits: const ProtocolCaptureLimits(),
          exchanges: [exchange()],
        );
        await workspace.save(study);
        final directory = Directory('${temporary.path}/recoverable');
        await File(
          '${directory.path}/study.json',
        ).rename('${directory.path}/study.json.bak');

        final recovered = await workspace.load('recoverable');

        expect(recovered?.title, 'Recover me');
        expect(File('${directory.path}/study.json').existsSync(), true);
      },
    );

    test('ignores malformed private workspace records', () async {
      final directory = Directory('${temporary.path}/broken');
      await directory.create(recursive: true);
      await File('${directory.path}/study.json').writeAsString('{not json');

      expect(await workspace.load('broken'), isNull);
      expect(await workspace.listStudies(), isEmpty);
    });
  });
}
