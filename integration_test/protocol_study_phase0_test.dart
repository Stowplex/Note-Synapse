import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:note_synapse/models/protocol_exchange.dart';
import 'package:note_synapse/models/protocol_study.dart';
import 'package:note_synapse/services/protocol_study/protocol_capture_controller.dart';
import 'package:note_synapse/services/protocol_study/protocol_capture_user_script.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('document-start probe captures the bounded mobile fixture', (
    tester,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    final fixture = await _startFixtureServer();
    final cookieManager = CookieManager.instance();
    await cookieManager.deleteAllCookies();
    final capture = ProtocolCaptureController(
      limits: const ProtocolCaptureLimits(
        maxRequestBodyBytes: 8 * 1024,
        maxResponseBodyBytes: 16 * 1024,
        maxEvents: 600,
        maxEventsPerSecond: 300,
      ),
    );
    final webViewReady = Completer<InAppWebViewController>();
    final responseTrace = Completer<List<dynamic>>();
    addTearDown(() async {
      capture.dispose();
      await cookieManager.deleteAllCookies();
      await fixture.close();
    });
    final url = fixture.url('/');
    await tester.pumpWidget(
      MaterialApp(
        home: _CaptureHarness(
          url: url,
          capture: capture,
          onWebViewCreated: webViewReady.complete,
          onResponseTrace: (trace) {
            if (!responseTrace.isCompleted) responseTrace.complete(trace);
          },
        ),
      ),
    );

    final webView = await webViewReady.future.timeout(
      const Duration(seconds: 10),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      final paths = capture.exchanges
          .where((item) => item.completedAt != null)
          .map((item) => Uri.parse(item.url).path)
          .toSet();
      final concurrent = capture.exchanges
          .where((item) => Uri.parse(item.url).path == '/concurrent')
          .length;
      if (paths.containsAll({
            '/fetch',
            '/request-object',
            '/xhr',
            '/binary',
            '/redirect',
            '/large',
            '/auth',
            '/xhr-arraybuffer',
          }) &&
          concurrent >= 5 &&
          capture.capabilities['wrapperIntegrity'] == false) {
        break;
      }
    }

    final sources = capture.exchanges.map((item) => item.source).toSet();
    expect(sources, contains(ProtocolRequestSource.fetch));
    expect(sources, contains(ProtocolRequestSource.xhr));
    expect(sources, contains(ProtocolRequestSource.form));
    expect(
      capture.exchanges.any(
        (item) => item.requestBody?.text?.contains('inline-fetch') == true,
      ),
      true,
      reason: 'The inline head script must run after document-start injection.',
    );
    expect(
      capture.exchanges.any(
        (item) => item.responseBody?.text?.contains('fetch-ok') == true,
      ),
      true,
    );
    expect(
      capture.exchanges.any(
        (item) => item.responseBody?.omittedReason == 'binary_disabled',
      ),
      true,
    );
    expect(
      capture.exchanges.any(
        (item) =>
            item.redirected &&
            item.responseUrl?.endsWith('/redirect-target') == true,
      ),
      true,
    );
    final requestObject = capture.exchanges.singleWhere(
      (item) => Uri.parse(item.url).path == '/request-object',
    );
    expect(requestObject.method, 'POST');
    expect(requestObject.requestMetadata['credentials'], 'include');
    expect(requestObject.requestMetadata['cache'], 'no-store');
    expect(requestObject.requestMetadata['redirect'], 'follow');
    expect(
      fixture.requests.any(
        (item) =>
            item.path == '/request-object' &&
            item.body == 'request-object-body' &&
            item.headers.value('x-probe-option') == 'preserved',
      ),
      true,
      reason: 'Request object method, headers, and body must reach the server.',
    );
    final concurrent = capture.exchanges
        .where((item) => Uri.parse(item.url).path == '/concurrent')
        .toList();
    expect(
      concurrent.length,
      greaterThanOrEqualTo(5),
      reason:
          'server concurrent requests: '
          '${fixture.requests.where((item) => item.path == '/concurrent').length}; '
          'captured paths: ${capture.exchanges.map((item) => Uri.parse(item.url).path).toList()}',
    );
    expect(concurrent.map((item) => item.id).toSet().length, concurrent.length);
    expect(
      concurrent.map((item) => item.pageInstanceId).toSet().length,
      greaterThanOrEqualTo(2),
      reason:
          'The all-frame document-start script must identify iframe traffic.',
    );
    final large = capture.exchanges.singleWhere(
      (item) => Uri.parse(item.url).path == '/large',
    );
    expect(large.responseBody?.truncated, true);
    expect(
      utf8.encode(large.responseBody?.text ?? '').length,
      lessThanOrEqualTo(capture.limits.maxResponseBodyBytes),
    );
    expect(
      large.completedAt,
      isNotNull,
      reason: 'Clone cancellation must not hang.',
    );
    final binaryXhr = capture.exchanges.singleWhere(
      (item) => Uri.parse(item.url).path == '/xhr-arraybuffer',
    );
    expect(binaryXhr.responseBody?.omittedReason, 'binary_disabled');
    expect(capture.capabilities['serviceWorkers'], false);
    expect(capture.capabilities['webSockets'], false);
    expect(capture.capabilities['wrapperIntegrity'], false);
    expect(capture.issues, contains(contains('wrapper_replaced')));
    final trace = await responseTrace.future.timeout(
      const Duration(seconds: 5),
    );
    expect(trace, contains('page-then-before-capture'));
    final phaseJson = await webView.evaluateJavascript(
      source: 'JSON.stringify(window.__phase0)',
    );
    final phase = jsonDecode(phaseJson as String) as Map<String, dynamic>;
    expect(phase['requestPromisePreserved'], true);
    expect(phase['requestObjectResult'], 'request-object-ok');
    expect(phase['aborted'], 'AbortError');
    expect(phase['xhrText'], 'xhr-ok');
    expect(phase['syncXhr'], anyOf('sync-xhr-ok', startsWith('unsupported:')));
    expect(
      fixture.requests
          .firstWhere((item) => item.path == '/auth')
          .headers
          .value(HttpHeaders.cookieHeader),
      contains('sid=initial'),
      reason: 'The controlled server proves the HttpOnly cookie was sent.',
    );
    final auth = capture.exchanges.singleWhere(
      (item) => Uri.parse(item.url).path == '/auth',
    );
    expect(
      auth.requestHeaders.any(
        (field) => field.name == 'Cookie-Jar-Observed-Near-Request',
      ),
      true,
    );
    expect(capture.stoppedByLimit, false);
  });
}

class _CaptureHarness extends StatelessWidget {
  const _CaptureHarness({
    required this.url,
    required this.capture,
    required this.onWebViewCreated,
    required this.onResponseTrace,
  });

  final String url;
  final ProtocolCaptureController capture;
  final ValueChanged<InAppWebViewController> onWebViewCreated;
  final ValueChanged<List<dynamic>> onResponseTrace;

  @override
  Widget build(BuildContext context) {
    const handler = 'protocolPhase0Bridge';
    return Scaffold(
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          allowFileAccess: false,
          allowContentAccess: false,
          allowFileAccessFromFileURLs: false,
          allowUniversalAccessFromFileURLs: false,
          useShouldInterceptFetchRequest: false,
          useShouldInterceptAjaxRequest: false,
          useShouldInterceptRequest: false,
        ),
        initialUserScripts: UnmodifiableListView([
          UserScript(
            source: ProtocolCaptureUserScript.build(
              handlerName: handler,
              limits: capture.limits,
            ),
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            forMainFrameOnly: false,
            contentWorld: ContentWorld.PAGE,
          ),
        ]),
        onWebViewCreated: (controller) {
          onWebViewCreated(controller);
          controller.addJavaScriptHandler(
            handlerName: handler,
            callback: (arguments) {
              if (arguments.length == 1) {
                final raw = arguments.first;
                final accepted = capture.acceptEvent(raw);
                if (accepted && raw is Map) {
                  final id = raw['exchangeId'];
                  final type = raw['type'];
                  if (id is String &&
                      (type == 'request' || type == 'response')) {
                    unawaited(
                      _observeCookies(capture, id, request: type == 'request'),
                    );
                  }
                  if (type == 'response' &&
                      raw['url']?.toString().contains('/callback-order') ==
                          true) {
                    unawaited(
                      controller
                          .evaluateJavascript(
                            source: 'window.__phase0.trace.slice()',
                          )
                          .then(
                            (value) => onResponseTrace(
                              List<dynamic>.from(value as List),
                            ),
                          ),
                    );
                  }
                }
              }
              return null;
            },
          );
        },
      ),
    );
  }
}

Future<void> _observeCookies(
  ProtocolCaptureController capture,
  String exchangeId, {
  required bool request,
}) async {
  final exchange = capture.exchanges
      .where((item) => item.id == exchangeId)
      .firstOrNull;
  if (exchange == null) return;
  final cookies = await CookieManager.instance().getCookies(
    url: WebUri(exchange.url),
  );
  final value = cookies
      .where((cookie) => cookie.value?.isNotEmpty == true)
      .map((cookie) => '${cookie.name}=${cookie.value}')
      .join('; ');
  if (value.isEmpty) return;
  capture.addTrustedHeader(
    exchangeId,
    request: request,
    name: request
        ? 'Cookie-Jar-Observed-Near-Request'
        : 'Cookie-Jar-Observed-After-Response',
    value: value,
  );
}

class _FixtureRequest {
  const _FixtureRequest({
    required this.path,
    required this.headers,
    required this.body,
  });

  final String path;
  final HttpHeaders headers;
  final String body;
}

class _Fixture {
  const _Fixture(this.main, this.crossOrigin, this.requests);

  final HttpServer main;
  final HttpServer crossOrigin;
  final List<_FixtureRequest> requests;

  String url(String path) => 'http://${main.address.host}:${main.port}$path';

  Future<void> close() async {
    await main.close(force: true);
    await crossOrigin.close(force: true);
  }
}

Future<_Fixture> _startFixtureServer() async {
  final requests = <_FixtureRequest>[];
  final crossOrigin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    crossOrigin.forEach((request) async {
      request.response.headers.contentType = ContentType.text;
      if (request.uri.path == '/cors') {
        request.response.headers.set('access-control-allow-origin', '*');
      }
      request.response.write('cross-origin-ok');
      await request.response.close();
    }),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add(
        _FixtureRequest(
          path: request.uri.path,
          headers: request.headers,
          body: body,
        ),
      );
      final response = request.response;
      switch (request.uri.path) {
        case '/':
          response.headers.add(
            HttpHeaders.setCookieHeader,
            'sid=initial; HttpOnly; Path=/; SameSite=Lax',
          );
          response.headers.contentType = ContentType.html;
          final html =
              r'''<!doctype html><html><head>
<script>
window.__phase0 = {trace: []};
fetch('/fetch', {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({kind:'inline-fetch'})});
const callbackPromise = fetch('/callback-order');
callbackPromise.then(() => window.__phase0.trace.push('page-then-before-capture'));
const request = new Request('/request-object', {
  method: 'POST', body: 'request-object-body', credentials: 'include',
  cache: 'no-store', redirect: 'follow', referrer: location.href,
  headers: {'x-probe-option': 'preserved', 'content-type': 'text/plain'}
});
const returned = fetch(request);
window.__phase0.requestPromisePreserved = returned instanceof Promise;
returned.then(response => response.text()).then(text => window.__phase0.requestObjectResult = text);
const abortController = new AbortController();
fetch('/slow', {signal: abortController.signal}).catch(error => window.__phase0.aborted = error.name);
abortController.abort();
for (let index = 0; index < 3; index += 1) fetch('/concurrent?main=' + index);
const xhr = new XMLHttpRequest();
xhr.open('POST', '/xhr');
xhr.setRequestHeader('content-type', 'application/x-www-form-urlencoded');
xhr.addEventListener('load', () => window.__phase0.xhrText = JSON.parse(xhr.responseText).result);
xhr.send('kind=inline-xhr');
const binaryXhr = new XMLHttpRequest();
binaryXhr.open('GET', '/xhr-arraybuffer');
binaryXhr.responseType = 'arraybuffer';
binaryXhr.send();
const blobXhr = new XMLHttpRequest();
blobXhr.open('GET', '/xhr-blob');
blobXhr.responseType = 'blob';
blobXhr.send();
fetch('/binary');
fetch('/redirect');
fetch('/large');
fetch('/auth');
fetch('http://127.0.0.1:__CROSS_PORT__/cors', {mode: 'cors'});
fetch('http://127.0.0.1:__CROSS_PORT__/opaque', {mode: 'no-cors'});
setTimeout(() => {
  try {
    const sync = new XMLHttpRequest();
    sync.open('GET', '/xhr-sync', false);
    sync.send();
    window.__phase0.syncXhr = sync.responseText;
  } catch (error) {
    window.__phase0.syncXhr = 'unsupported:' + error.name;
  }
}, 0);
setTimeout(() => { window.fetch = window.fetch.bind(window); }, 200);
</script></head><body>
<iframe src="/frame"></iframe>
<form id="fixture" action="/form" method="post"><input name="payment_field" value="visible-locally"></form>
<script>
const form = document.getElementById('fixture');
form.addEventListener('submit', event => event.preventDefault());
form.requestSubmit();
</script></body></html>'''
                  .replaceAll('__CROSS_PORT__', '${crossOrigin.port}');
          response.write(html);
        case '/frame':
          response.headers.contentType = ContentType.html;
          response.write('''<!doctype html><script>
setTimeout(() => {
  fetch('/concurrent?frame=1');
  fetch('/concurrent?frame=2');
}, 100);
</script>''');
        case '/fetch':
          response.headers.contentType = ContentType.json;
          response.write('{"result":"fetch-ok"}');
        case '/callback-order':
          response.headers.contentType = ContentType.text;
          response.write('callback-ok');
        case '/request-object':
          response.headers.contentType = ContentType.text;
          response.write('request-object-ok');
        case '/slow':
          await Future<void>.delayed(const Duration(seconds: 2));
          response.headers.contentType = ContentType.text;
          response.write('too-late');
        case '/concurrent':
          response.headers.contentType = ContentType.text;
          response.write('same-request-ok');
        case '/xhr':
          response.headers.contentType = ContentType.json;
          response.write('{"result":"xhr-ok"}');
        case '/binary':
          response.headers.contentType = ContentType.binary;
          response.add(List<int>.generate(1024, (index) => index % 256));
        case '/xhr-arraybuffer':
        case '/xhr-blob':
          response.headers.contentType = ContentType.binary;
          response.add(List<int>.generate(2048, (index) => index % 256));
        case '/xhr-sync':
          response.headers.contentType = ContentType.text;
          response.write('sync-xhr-ok');
        case '/large':
          response.headers.contentType = ContentType.text;
          response.add(utf8.encode('large-response-' * 4096));
        case '/auth':
          response.headers.add(
            HttpHeaders.setCookieHeader,
            'sid=rotated; HttpOnly; Path=/; SameSite=Lax',
          );
          response.headers.contentType = ContentType.json;
          response.write('{"authenticated":true}');
        case '/redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '/redirect-target');
        case '/redirect-target':
          response.headers.contentType = ContentType.json;
          response.write('{"result":"redirect-ok"}');
        case '/form':
          response.headers.contentType = ContentType.json;
          response.write('{"result":"form-ok"}');
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    }),
  );
  return _Fixture(server, crossOrigin, requests);
}
