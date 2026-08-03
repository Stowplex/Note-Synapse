import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:note_synapse/models/protocol_exchange.dart';
import 'package:note_synapse/models/protocol_knowledge.dart';
import 'package:note_synapse/models/protocol_study.dart';
import 'package:note_synapse/services/protocol_study/protocol_analysis_service.dart';
import 'package:note_synapse/services/protocol_study/protocol_recipe_runner.dart';
import 'package:note_synapse/services/protocol_study/protocol_report_renderer.dart';
import 'package:note_synapse/services/web_session_service.dart';

class _FakeWebSessions extends WebSessionService {
  @override
  Future<String> cookieHeaderFor(String url) async => 'sid=cookie-secret';
}

void main() {
  final timestamp = DateTime.parse('2026-08-02T12:00:00Z');
  final exchange = ProtocolExchange(
    id: 'evidence-1',
    pageInstanceId: 'page-1',
    sequence: 1,
    source: ProtocolRequestSource.fetch,
    method: 'POST',
    url: 'https://api.example.com/search?q=private-search',
    startedAt: timestamp,
    requestHeaders: const [
      ProtocolField(
        id: 'auth',
        location: ProtocolFieldLocation.requestHeader,
        name: 'Authorization',
        value: 'Bearer raw-local-token',
      ),
      ProtocolField(
        id: 'content-type',
        location: ProtocolFieldLocation.requestHeader,
        name: 'Content-Type',
        value: 'application/json',
      ),
    ],
    queryFields: const [
      ProtocolField(
        id: 'query',
        location: ProtocolFieldLocation.query,
        name: 'q',
        value: 'private-search',
      ),
    ],
    requestBody: const ProtocolBody(
      text: '{"query":"private-search"}',
      mimeType: 'application/json',
      fields: [
        ProtocolField(
          id: 'body-query',
          location: ProtocolFieldLocation.requestBody,
          name: 'query',
          value: 'private-search',
        ),
      ],
    ),
    responseHeaders: const [],
    mutatesState: true,
    selected: true,
  );

  test('minimal repro attaches saved cookies only at execution time', () async {
    final client = MockClient((request) async {
      expect(request.headers['Cookie'], 'sid=cookie-secret');
      expect(request.headers['Authorization'], 'Bearer raw-local-token');
      expect(request.body, '{"query":"private-search"}');
      return http.Response('abcdefghij', 200, headers: {'x-result': 'ok'});
    });
    final runner = ProtocolRecipeRunner(
      webSessions: _FakeWebSessions(),
      client: client,
    );

    final result = await runner.run(
      exchange,
      useSavedLogin: true,
      maxResponseBytes: 5,
    );

    expect(result.statusCode, 200);
    expect(result.body, 'abcde');
    expect(result.truncated, true);
    expect(result.body, isNot(contains('cookie-secret')));
    runner.close();
  });

  test('workflow repro preserves the recorded request order', () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      seen.add(request.url.path);
      return http.Response('ok', 200);
    });
    final runner = ProtocolRecipeRunner(
      webSessions: _FakeWebSessions(),
      client: client,
    );
    final later = ProtocolExchange.fromJson({
      ...exchange.toJson(),
      'id': 'later',
      'sequence': 20,
      'url': 'https://api.example.com/later',
    });
    final earlier = ProtocolExchange.fromJson({
      ...exchange.toJson(),
      'id': 'earlier',
      'sequence': 10,
      'url': 'https://api.example.com/earlier',
    });

    final results = await runner.runWorkflow([later, earlier]);

    expect(seen, ['/earlier', '/later']);
    expect(results.map((step) => step.exchange.id), ['earlier', 'later']);
    runner.close();
  });

  test('sanitized note view cannot import captured values from model fields', () {
    final study = ProtocolStudy(
      id: 'study-1',
      title: 'Study',
      startUrl: 'https://api.example.com',
      createdAt: timestamp,
      updatedAt: timestamp,
      sessionProvenance: ProtocolSessionProvenance.savedLoginRestored,
      savedLoginDomain: 'example.com',
      limits: const ProtocolCaptureLimits(),
      exchanges: [exchange],
    );
    const knowledge = ProtocolKnowledge(
      title: 'Search private-search <script>',
      summary:
          'Use Bearer raw-local-token for private-search. ![beacon](https://attacker.example)',
      parameters: [
        ProtocolParameterKnowledge(
          name: 'query',
          location: 'query',
          description: 'Captured value was private-search',
          required: true,
        ),
      ],
      steps: [
        ProtocolStepKnowledge(
          exchangeId: 'evidence-1',
          method: 'POST',
          urlTemplate: 'https://api.example.com/search?q=private-search',
          purpose: 'Search private-search',
          mutatesState: true,
        ),
      ],
      caveats: [
        'Do not expose raw-local-token, cmF3LWxvY2FsLXRva2Vu, or 7261772d6c6f63616c2d746f6b656e',
      ],
      confidence: 0.8,
    );

    final view = ProtocolExportView.build(study: study, knowledge: knowledge);
    expect(view.markdown, isNot(contains('private-search')));
    expect(view.markdown, isNot(contains('raw-local-token')));
    expect(view.markdown, isNot(contains('cmF3LWxvY2FsLXRva2Vu')));
    expect(view.markdown, isNot(contains('7261772d6c6f63616c2d746f6b656e')));
    expect(view.markdown, contains('api.example.com/search'));
    expect(view.markdown, contains('Cookie values are not included'));
    expect(view.markdown, contains('mutates state'));
    expect(view.markdown, isNot(contains('<script>')));
    expect(view.markdown, isNot(contains('![')));
    expect(view.markdown, contains('&lt;script&gt;'));
  });

  test('knowledge validation rejects evidence the user did not select', () {
    const knowledge = ProtocolKnowledge(
      title: 'Workflow',
      summary: '',
      parameters: [],
      steps: [
        ProtocolStepKnowledge(
          exchangeId: 'invented',
          method: 'GET',
          urlTemplate: 'https://example.com/api',
          purpose: '',
          mutatesState: false,
        ),
      ],
      caveats: [],
      confidence: 0.5,
    );
    expect(
      () => ProtocolKnowledgeValidator.validate(
        knowledge,
        selectedExchangeIds: {'evidence-1'},
      ),
      throwsFormatException,
    );
  });
}
