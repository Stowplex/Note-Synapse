import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/models/protocol_exchange.dart';
import 'package:note_synapse/services/model_preference_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/models/ai_model.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';
import 'package:note_synapse/services/protocol_study/protocol_ai_projection.dart';
import 'package:note_synapse/services/protocol_study/protocol_analysis_service.dart';
import 'package:note_synapse/utils/token_estimator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PairModel extends AIModel {
  _PairModel({Iterable<String> responses = const []})
    : _responses = Queue.of(responses);

  final List<List<PromptMessage>> calls = [];
  final Queue<String> _responses;

  @override
  String get id => 'local-pair-model';

  @override
  String get name => 'Local pair model';

  @override
  String get description => 'test';

  @override
  Future<void> initialize({ModelConfig? config}) async {}

  @override
  Future<bool> isReady() async => true;

  @override
  Future<String> generateWithMessages(
    List<PromptMessage> messages, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    calls.add(List.of(messages));
    if (_responses.isNotEmpty) return _responses.removeFirst();
    final user = messages.last.content;
    final id = RegExp(r'"exchangeId":"([^"]+)"').firstMatch(user)!.group(1)!;
    return jsonEncode({
      'title': 'Local workflow',
      'summary': 'Analyzed $id.',
      'parameters': const [],
      'steps': [
        {
          'exchangeId': id,
          'method': 'GET',
          'urlTemplate': 'https://example.test/$id',
          'purpose': 'Handle $id',
          'mutatesState': false,
        },
      ],
      'caveats': const [],
      'confidence': 0.8,
    });
  }

  @override
  Future<void> dispose() async {}
}

String _knowledgeResponse(String id) => jsonEncode({
  'title': 'Local workflow',
  'summary': 'Analyzed $id.',
  'parameters': const [],
  'steps': [
    {
      'exchangeId': id,
      'method': 'GET',
      'urlTemplate': 'https://example.test/$id',
      'purpose': 'Handle $id',
      'mutatesState': false,
    },
  ],
  'caveats': const [],
  'confidence': 0.8,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProtocolExchange exchange(String id, String path) => ProtocolExchange(
    id: id,
    pageInstanceId: 'page-1',
    sequence: id == 'exchange-1' ? 1 : 2,
    source: ProtocolRequestSource.fetch,
    method: 'GET',
    url: 'https://example.test/$path',
    startedAt: DateTime.parse('2026-08-02T12:00:00Z'),
    requestHeaders: const [],
    queryFields: const [],
    responseHeaders: const [],
    responseBody: ProtocolBody(
      text: List.filled(12000, id).join('-'),
      mimeType: 'text/plain',
    ),
    selected: true,
  );

  test(
    'local analysis sends one bounded request-response pair per call',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fake = _PairModel();
      final selector = ModelSelector(
        ModelStorageService(),
        ModelPreferenceService(),
        modelFactory: (_) => fake,
      );
      final model = ModelConfig(
        id: 'local-model',
        type: ModelType.localMnn,
        displayName: 'Local model',
        maxInputTokens: 1200,
        maxOutputTokens: 512,
      );
      final source = [
        exchange('exchange-1', 'first').copyWith(
          replayObservation: ProtocolReplayObservation(
            replayedAt: DateTime.parse('2026-08-02T13:00:00Z'),
            statusCode: 200,
            finalUrl: 'https://example.test/first?cursor=replayed',
            responseHeaders: const [],
            responseBody: ProtocolBody(
              text: List.filled(12000, 'replay').join('-'),
              mimeType: 'text/plain',
            ),
          ),
        ),
        exchange('exchange-2', 'second'),
      ];
      final disclosure = ProtocolDisclosureSession(
        ProtocolAIDestination.forModel(model),
        nonce: 'local-analysis',
      );
      final preview = const ProtocolAIProjectionBuilder().build(
        exchanges: source,
        disclosure: disclosure,
      );
      final progress = <(int, int)>[];

      final knowledge = await ProtocolAnalysisService(selector).analyze(
        model: model,
        preview: preview,
        disclosure: disclosure,
        sourceExchanges: source,
        onProgress: (current, total) => progress.add((current, total)),
      );

      expect(fake.calls, hasLength(2));
      expect(progress, [(1, 2), (2, 2)]);
      expect(fake.calls[0].last.content, contains('exchange-1'));
      expect(fake.calls[0].last.content, isNot(contains('exchange-2')));
      expect(fake.calls[1].last.content, contains('exchange-2'));
      expect(fake.calls[1].last.content, isNot(contains('exchange-1')));
      for (final call in fake.calls) {
        expect(
          TokenEstimator.estimateTokens(
            call.map((item) => item.content).join(),
          ),
          lessThan(model.maxInputTokens!),
        );
      }
      expect(knowledge.steps.map((step) => step.exchangeId), [
        'exchange-1',
        'exchange-2',
      ]);
      expect(knowledge.caveats.single, contains('separately'));
    },
  );

  test('accepts JSON fenced inside surrounding model commentary', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _PairModel(
      responses: [
        'Here is the result:\n```JSON\n${_knowledgeResponse('exchange-1')}\n```\nDone.',
      ],
    );
    final selector = ModelSelector(
      ModelStorageService(),
      ModelPreferenceService(),
      modelFactory: (_) => fake,
    );
    final model = ModelConfig(
      id: 'local-model',
      type: ModelType.localMnn,
      displayName: 'Local model',
      maxInputTokens: 16000,
      maxOutputTokens: 512,
    );
    final source = [exchange('exchange-1', 'first')];
    final disclosure = ProtocolDisclosureSession(
      ProtocolAIDestination.forModel(model),
      nonce: 'fenced-json',
    );
    final preview = const ProtocolAIProjectionBuilder().build(
      exchanges: source,
      disclosure: disclosure,
    );

    final knowledge = await ProtocolAnalysisService(selector).analyze(
      model: model,
      preview: preview,
      disclosure: disclosure,
      sourceExchanges: source,
    );

    expect(fake.calls, hasLength(1));
    expect(knowledge.steps.single.exchangeId, 'exchange-1');
  });

  test('asks the local model to repair malformed fenced JSON', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _PairModel(
      responses: [
        '```json\n{"title":"Broken","summary":"parameters":[}\n```',
        '```json\n${_knowledgeResponse('exchange-1')}\n```',
      ],
    );
    final selector = ModelSelector(
      ModelStorageService(),
      ModelPreferenceService(),
      modelFactory: (_) => fake,
    );
    final model = ModelConfig(
      id: 'local-model',
      type: ModelType.localMnn,
      displayName: 'Local model',
      maxInputTokens: 16000,
      maxOutputTokens: 512,
    );
    final source = [exchange('exchange-1', 'first')];
    final disclosure = ProtocolDisclosureSession(
      ProtocolAIDestination.forModel(model),
      nonce: 'repair-json',
    );
    final preview = const ProtocolAIProjectionBuilder().build(
      exchanges: source,
      disclosure: disclosure,
    );

    final knowledge = await ProtocolAnalysisService(selector).analyze(
      model: model,
      preview: preview,
      disclosure: disclosure,
      sourceExchanges: source,
    );

    expect(fake.calls, hasLength(2));
    expect(fake.calls[1].first.content, contains('Repair malformed'));
    expect(fake.calls[1].last.content, contains('exchange-1'));
    expect(
      fake.calls[1].last.content,
      isNot(contains('exchange-1-exchange-1-exchange-1')),
    );
    expect(knowledge.steps.single.exchangeId, 'exchange-1');
  });

  test('reports malformed local JSON after bounded repair attempts', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _PairModel(
      responses: List.filled(3, '```json\n{"title":\n```'),
    );
    final selector = ModelSelector(
      ModelStorageService(),
      ModelPreferenceService(),
      modelFactory: (_) => fake,
    );
    final model = ModelConfig(
      id: 'local-model',
      type: ModelType.localMnn,
      displayName: 'Local model',
      maxInputTokens: 16000,
      maxOutputTokens: 512,
    );
    final source = [exchange('exchange-1', 'first')];
    final disclosure = ProtocolDisclosureSession(
      ProtocolAIDestination.forModel(model),
      nonce: 'failed-repair-json',
    );
    final preview = const ProtocolAIProjectionBuilder().build(
      exchanges: source,
      disclosure: disclosure,
    );

    await expectLater(
      ProtocolAnalysisService(selector).analyze(
        model: model,
        preview: preview,
        disclosure: disclosure,
        sourceExchanges: source,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('after 3 attempts'),
        ),
      ),
    );
    expect(fake.calls, hasLength(3));
  });
}
