import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/protocol_exchange.dart';
import 'package:note_synapse/models/protocol_study.dart';
import 'package:note_synapse/services/protocol_study/protocol_capture_controller.dart';
import 'package:note_synapse/services/protocol_study/protocol_capture_user_script.dart';
import 'package:note_synapse/services/protocol_study/protocol_sensitivity_classifier.dart';

void main() {
  final now = DateTime.parse('2026-08-02T12:00:00Z');

  Map<String, dynamic> event(
    String type, {
    int sequence = 1,
    String pageInstanceId = 'page-1',
    String? exchangeId,
    Map<String, dynamic> extra = const {},
  }) => {
    'schemaVersion': 1,
    'type': type,
    'pageInstanceId': pageInstanceId,
    'sequence': sequence,
    'timestampMs': now.millisecondsSinceEpoch,
    'documentUrl': 'https://app.example.com/page',
    if (exchangeId != null) 'exchangeId': exchangeId,
    ...extra,
  };

  group('ProtocolCaptureUserScript', () {
    test('is bounded, non-keylogging, and uses the asynchronous bridge', () {
      const limits = ProtocolCaptureLimits(
        maxRequestBodyBytes: 1234,
        maxResponseBodyBytes: 5678,
        maxEvents: 99,
      );
      final script = ProtocolCaptureUserScript.build(
        handlerName: 'protocolBridge_abcd1234',
        limits: limits,
      );

      expect(script, contains('const MAX_REQUEST = 1234'));
      expect(script, contains('const MAX_RESPONSE = 5678'));
      expect(script, contains('const MAX_EVENTS = 99'));
      expect(script, contains('originalFetch.apply(this, arguments)'));
      expect(
        script.indexOf('originalFetch.apply(this, arguments)'),
        lessThan(script.indexOf('new Request(resource, init)')),
        reason:
            'The browser must accept the original request before capture cloning.',
      );
      expect(script, contains('Promise.resolve(result).then((response) => {'));
      final responseObserver = script.indexOf(
        'Promise.resolve(result).then((response) => {',
      );
      expect(
        responseObserver,
        lessThan(script.indexOf('return result;', responseObserver)),
        reason: 'Deep capture must clone before page callbacks consume it.',
      );
      expect(script, contains('response.clone()'));
      expect(script, contains('response_not_cloneable_before_page_callback'));
      expect(
        script,
        isNot(contains('response_not_cloneable_after_page_callback')),
      );
      expect(script, contains('queueMicrotask(flush)'));
      expect(script, isNot(contains('await bridge.callHandler')));
      expect(script, contains('stream.getReader()'));
      expect(script, contains("reader.cancel('protocol capture body limit')"));
      expect(
        script,
        isNot(contains("await reader.cancel('protocol capture body limit')")),
      );
      expect(script, isNot(contains('response.text()')));
      expect(script, isNot(contains('keydown')));
      expect(script, isNot(contains("addEventListener('input'")));
      expect(script, isNot(contains('shouldInterceptFetchRequest')));
      expect(script, isNot(contains('shouldInterceptAjaxRequest')));
      expect(script, contains("code: 'wrapper_replaced'"));
      expect(script, contains('same_origin_frame_late_injection'));
      expect(script, contains('child.location.origin !== location.origin'));
    });

    test('rejects an unsafe bridge handler name', () {
      expect(
        () => ProtocolCaptureUserScript.build(
          handlerName: "x'); stealCookies();//",
          limits: const ProtocolCaptureLimits(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('ProtocolCaptureController', () {
    test('assembles request, chunked bodies, response, and completion', () {
      final controller = ProtocolCaptureController(now: () => now);
      const id = 'page-1:fetch:1';

      expect(
        controller.acceptEvent(
          event(
            'request',
            exchangeId: id,
            extra: {
              'source': 'fetch',
              'method': 'POST',
              'url': '/api/search?q=birds&q=recent',
              'headers': [
                ['content-type', 'application/json'],
                ['authorization', 'Bearer local-secret'],
              ],
            },
          ),
        ),
        true,
      );
      controller.acceptEvent(
        event(
          'requestBodyStart',
          sequence: 2,
          exchangeId: id,
          extra: {
            'body': {
              'mimeType': 'application/json',
              'byteLength': 27,
              'truncated': false,
            },
          },
        ),
      );
      controller.acceptEvent(
        event(
          'requestBodyChunk',
          sequence: 3,
          exchangeId: id,
          extra: {'index': 0, 'text': '{"query":"nest'},
        ),
      );
      controller.acceptEvent(
        event(
          'requestBodyChunk',
          sequence: 4,
          exchangeId: id,
          extra: {'index': 1, 'text': 'ing","page":2}'},
        ),
      );
      controller.acceptEvent(
        event('requestBodyEnd', sequence: 5, exchangeId: id),
      );
      controller.acceptEvent(
        event(
          'response',
          sequence: 6,
          exchangeId: id,
          extra: {
            'status': 200,
            'url': '/api/final',
            'redirected': true,
            'headers': [
              ['content-type', 'application/json'],
            ],
          },
        ),
      );
      controller.acceptEvent(
        event(
          'responseBody',
          sequence: 7,
          exchangeId: id,
          extra: {
            'body': {
              'text': '{"ok":true}',
              'mimeType': 'application/json',
              'byteLength': 11,
            },
          },
        ),
      );
      controller.acceptEvent(event('complete', sequence: 8, exchangeId: id));

      final exchange = controller.exchanges.single;
      expect(exchange.method, 'POST');
      expect(
        exchange.url,
        'https://app.example.com/api/search?q=birds&q=recent',
      );
      expect(exchange.queryFields.map((field) => field.value), [
        'birds',
        'recent',
      ]);
      expect(exchange.requestBody!.text, '{"query":"nesting","page":2}');
      expect(exchange.requestBody!.fields.map((field) => field.name), [
        'query',
        'page',
      ]);
      expect(exchange.responseBody!.fields.single.name, 'ok');
      expect(exchange.status, 200);
      expect(exchange.responseUrl, 'https://app.example.com/api/final');
      expect(exchange.redirected, true);
      expect(exchange.completedAt, now);
      expect(exchange.mutatesState, true);
    });

    test('keeps bounded transport metadata and per-exchange limitations', () {
      final controller = ProtocolCaptureController(now: () => now);
      const id = 'page-1:fetch:1';
      controller.acceptEvent(
        event(
          'request',
          exchangeId: id,
          extra: {
            'source': 'fetch',
            'method': 'POST',
            'url': '/stream',
            'headers': const [],
            'metadata': {
              'credentials': 'include',
              'mode': 'cors',
              'redirect': 'manual',
              'notAllowed': 'ignored',
            },
          },
        ),
      );
      controller.acceptEvent(
        event(
          'complete',
          sequence: 2,
          exchangeId: id,
          extra: {
            'omittedReason': 'response_not_cloneable_after_page_callback',
          },
        ),
      );

      final exchange = controller.exchanges.single;
      expect(exchange.requestMetadata, {
        'credentials': 'include',
        'mode': 'cors',
        'redirect': 'manual',
      });
      expect(exchange.captureIssues, [
        'response_not_cloneable_after_page_callback',
      ]);
    });

    test('surfaces page replacement of the capture wrappers', () {
      final controller = ProtocolCaptureController(now: () => now);
      controller.acceptEvent(
        event(
          'hello',
          extra: {
            'capabilities': {'fetch': true, 'wrapperIntegrity': true},
          },
        ),
      );
      controller.acceptEvent(
        event('diagnostic', sequence: 2, extra: {'code': 'wrapper_replaced'}),
      );

      expect(controller.capabilities['wrapperIntegrity'], false);
      expect(controller.issues.single, contains('wrapper_replaced'));
    });

    test('merges frame capabilities conservatively', () {
      final controller = ProtocolCaptureController(now: () => now);
      controller.acceptEvent(
        event(
          'hello',
          extra: {
            'capabilities': {'fetch': true, 'wrapperIntegrity': false},
          },
        ),
      );
      controller.acceptEvent(
        event(
          'hello',
          pageInstanceId: 'page-2',
          sequence: 2,
          extra: {
            'capabilities': {'fetch': true, 'wrapperIntegrity': true},
          },
        ),
      );

      expect(controller.capabilities['fetch'], true);
      expect(controller.capabilities['wrapperIntegrity'], false);
    });

    test('separates example runs and preserves user-marked parameters', () {
      final controller = ProtocolCaptureController(now: () => now);
      controller.acceptEvent(
        event(
          'request',
          exchangeId: 'page-1:fetch:1',
          extra: {
            'source': 'fetch',
            'method': 'GET',
            'url': '/search?q=first',
            'headers': const [],
          },
        ),
      );
      final firstField = controller.exchanges.single.queryFields.single;
      controller.setParameter(firstField.id, true);
      controller.startNewExample();
      controller.acceptEvent(
        event(
          'request',
          sequence: 2,
          exchangeId: 'page-1:fetch:2',
          extra: {
            'source': 'fetch',
            'method': 'GET',
            'url': '/search?q=second',
            'headers': const [],
          },
        ),
      );

      expect(controller.exchanges.first.exampleIndex, 1);
      expect(controller.exchanges.last.exampleIndex, 2);
      expect(controller.exchanges.first.queryFields.single.isParameter, true);
      expect(controller.interactions.single.kind, 'example_marker');
    });

    test('persists user marks for URL-derived parameter fields', () {
      final controller = ProtocolCaptureController(now: () => now);
      controller.acceptEvent(
        event(
          'request',
          exchangeId: 'page-1:fetch:1',
          extra: {
            'source': 'fetch',
            'method': 'GET',
            'url': 'https://example.test/items/42?q=term',
            'headers': const [],
          },
        ),
      );
      const pathFieldId = 'page-1:fetch:1:requestPath:1';
      controller.setParameter(pathFieldId, true);

      final exchange = controller.exchanges.single;
      expect(exchange.parameterFieldIds, contains(pathFieldId));
      final roundTrip = ProtocolExchange.fromJson(exchange.toJson());
      expect(roundTrip.parameterFieldIds, contains(pathFieldId));
      final derived = const ProtocolSensitivityClassifier()
          .fieldsFor(roundTrip)
          .singleWhere((field) => field.id == pathFieldId);
      expect(derived.isParameter, true);

      controller.setParameter(pathFieldId, false);
      expect(controller.exchanges.single.parameterFieldIds, isEmpty);
    });

    test('keeps submitted payment and password fields in the local record', () {
      final controller = ProtocolCaptureController(now: () => now);
      controller.acceptEvent(
        event(
          'form',
          extra: {
            'action': '/checkout',
            'method': 'POST',
            'fields': [
              ['card_number', '4111111111111111'],
              ['password', 'locally-visible'],
            ],
          },
        ),
      );

      final fields = controller.exchanges.single.requestBody!.fields;
      expect(fields.map((field) => field.name), ['card_number', 'password']);
      expect(fields.last.value, 'locally-visible');
      expect(controller.interactions.single.kind, 'form_submit');
    });

    test('accepts trusted cookie observations outside the page bridge', () {
      final controller = ProtocolCaptureController(now: () => now);
      const id = 'page-1:fetch:1';
      controller.acceptEvent(
        event(
          'request',
          exchangeId: id,
          extra: {
            'source': 'fetch',
            'method': 'GET',
            'url': '/api',
            'headers': const [],
          },
        ),
      );
      controller.addTrustedHeader(
        id,
        request: true,
        name: 'Cookie',
        value: 'sid=http-only-local-value',
      );

      final cookie = controller.exchanges.single.requestHeaders.single;
      expect(cookie.name, 'Cookie');
      expect(cookie.value, 'sid=http-only-local-value');
    });

    test(
      'enforces per-body UTF-8 limits while preserving original byte count',
      () {
        final controller = ProtocolCaptureController(
          limits: const ProtocolCaptureLimits(maxRequestBodyBytes: 5),
          now: () => now,
        );
        const id = 'page-1:xhr:1';
        controller.acceptEvent(
          event(
            'request',
            exchangeId: id,
            extra: {
              'source': 'xhr',
              'method': 'POST',
              'url': '/api',
              'headers': const [],
            },
          ),
        );
        controller.acceptEvent(
          event(
            'requestBody',
            sequence: 2,
            exchangeId: id,
            extra: {
              'body': {'text': 'abcdefghij'},
            },
          ),
        );

        final body = controller.exchanges.single.requestBody!;
        expect(utf8.encode(body.text!).length, lessThanOrEqualTo(5));
        expect(body.byteLength, 10);
        expect(body.truncated, true);
      },
    );

    test('rejects oversized and malformed page messages', () {
      final controller = ProtocolCaptureController(
        limits: const ProtocolCaptureLimits(maxEventBytes: 300),
        now: () => now,
      );
      expect(
        controller.acceptEvent(
          event('interaction', extra: {'label': 'x' * 1000}),
        ),
        false,
      );
      expect(controller.acceptEvent({'type': 'request'}), false);
      expect(controller.exchanges, isEmpty);
      expect(controller.issues, isNotEmpty);
    });

    test('stops accepting events after the configured count', () {
      final controller = ProtocolCaptureController(
        limits: const ProtocolCaptureLimits(
          maxEvents: 1,
          maxEventsPerSecond: 10,
        ),
        now: () => now,
      );
      expect(controller.acceptEvent(event('hello')), true);
      expect(controller.acceptEvent(event('hello', sequence: 2)), false);
      expect(controller.stoppedByLimit, true);
    });

    test('stores rendered page snapshots as bounded supplemental evidence', () {
      final controller = ProtocolCaptureController(
        limits: const ProtocolCaptureLimits(
          maxResponseBodyBytes: 100,
          maxSessionBytes: 200,
        ),
        now: () => now,
      );

      final id = controller.addPageSnapshot(
        url: 'https://app.example.com/results?q=private',
        title: 'Results',
        html: '<html><body>${'🙂' * 100}</body></html>',
        visibleText: 'visible ' * 100,
        trigger: 'loadStop',
      );

      expect(id, isNotNull);
      final snapshot = controller.exchanges.single;
      expect(snapshot.source, ProtocolRequestSource.navigation);
      expect(snapshot.selected, false);
      expect(snapshot.requestMetadata['evidenceKind'], 'renderedPageSnapshot');
      expect(snapshot.requestMetadata['snapshotTrigger'], 'loadStop');
      expect(snapshot.responseBody!.mimeType, 'text/html');
      expect(
        utf8.encode(snapshot.responseBody!.text!).length,
        lessThanOrEqualTo(60),
      );
      expect(snapshot.responseBody!.truncated, true);
      expect(
        snapshot.captureIssues,
        contains('rendered_page_snapshot_not_http_response'),
      );
      expect(
        snapshot.responseBody!.fields.map((field) => field.name),
        containsAll([r'$renderedHtml', r'$visibleText']),
      );
    });

    test('attaches replay without replacing passive response or cookies', () {
      final original = ProtocolExchange(
        id: 'exchange-1',
        pageInstanceId: 'page-1',
        sequence: 1,
        source: ProtocolRequestSource.fetch,
        method: 'GET',
        url: 'https://app.example.com/api',
        startedAt: now,
        requestHeaders: const [],
        queryFields: const [],
        responseHeaders: const [],
        responseBody: const ProtocolBody(
          text: '{"passive":true}',
          mimeType: 'application/json',
        ),
      );
      final controller = ProtocolCaptureController.fromExchanges(
        exchanges: [original],
      );

      controller.attachReplay(
        exchangeId: original.id,
        replayedAt: now,
        statusCode: 201,
        finalUrl: 'https://app.example.com/api?version=2',
        headers: const {
          'content-type': 'application/json',
          'set-cookie': 'sid=must-not-be-stored',
        },
        bodyText: '{"replayed":true}',
        mimeType: 'application/json',
        byteLength: 17,
        truncated: false,
        omittedReason: null,
        redirectChain: const ['https://app.example.com/api?version=2'],
        usedSessionCookies: true,
        fidelityIssues: const ['server_state_may_have_changed'],
      );

      final exchange = controller.exchanges.single;
      expect(exchange.responseBody!.text, '{"passive":true}');
      expect(
        exchange.replayObservation!.responseBody.text,
        '{"replayed":true}',
      );
      expect(exchange.replayObservation!.statusCode, 201);
      expect(exchange.replayObservation!.usedSessionCookies, true);
      expect(
        exchange.replayObservation!.responseHeaders.map((field) => field.name),
        isNot(contains('set-cookie')),
      );

      final restored = ProtocolExchange.fromJson(
        jsonDecode(jsonEncode(exchange.toJson())) as Map<String, dynamic>,
      );
      expect(
        restored.replayObservation!.responseBody.text,
        '{"replayed":true}',
      );
      expect(restored.responseBody!.text, '{"passive":true}');
    });

    test('protocol study records round-trip through JSON', () {
      final controller = ProtocolCaptureController(now: () => now);
      controller.acceptEvent(
        event(
          'request',
          exchangeId: 'page-1:fetch:1',
          extra: {
            'source': 'fetch',
            'method': 'GET',
            'url': '/api',
            'headers': const [],
          },
        ),
      );
      final study = ProtocolStudy(
        id: 'study-1',
        title: 'Example',
        startUrl: 'https://app.example.com',
        createdAt: now,
        updatedAt: now,
        sessionProvenance: ProtocolSessionProvenance.unknownSharedState,
        limits: controller.limits,
        exchanges: controller.exchanges,
      );

      final restored = ProtocolStudy.fromJson(
        jsonDecode(jsonEncode(study.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, 'study-1');
      expect(restored.exchanges.single.url, 'https://app.example.com/api');
    });
  });
}
