import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/protocol_exchange.dart';
import '../web_session_service.dart';

class ProtocolRecipeResult {
  const ProtocolRecipeResult({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.mimeType,
    required this.byteLength,
    required this.truncated,
    required this.finalUrl,
    required this.redirectChain,
    required this.usedSessionCookies,
    required this.fidelityIssues,
    this.omittedReason,
  });

  final int statusCode;

  /// Response headers safe to persist as replay evidence. `Set-Cookie` is
  /// deliberately excluded; the parsed cookie is applied directly to the
  /// WebView jar instead.
  final Map<String, String> headers;
  final String? body;
  final String? mimeType;
  final int byteLength;
  final bool truncated;
  final String? omittedReason;
  final String finalUrl;
  final List<String> redirectChain;
  final bool usedSessionCookies;
  final List<String> fidelityIssues;
}

class ProtocolRecipeStepResult {
  const ProtocolRecipeStepResult({
    required this.exchange,
    required this.result,
  });

  final ProtocolExchange exchange;
  final ProtocolRecipeResult result;
}

/// An internal HTTP request shape exposed for deterministic replay tests.
class ProtocolReplayTransportRequest {
  const ProtocolReplayTransportRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.bodyBytes,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> bodyBytes;
}

/// A single response hop. Cookie values live only in this transient object.
class ProtocolReplayTransportResponse {
  const ProtocolReplayTransportResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.byteLength,
    required this.truncated,
    this.cookies = const [],
  });

  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> bodyBytes;
  final int byteLength;
  final bool truncated;
  final List<WebSessionCookie> cookies;
}

abstract class ProtocolReplayTransport {
  Future<ProtocolReplayTransportResponse> send(
    ProtocolReplayTransportRequest request, {
    required int maxResponseBytes,
  });

  void close();
}

/// Executes a selected exchange as a local minimal repro. Live WebView cookies
/// are attached immediately before every HTTP hop and are never represented in
/// generated code, AI prompts, logs, or the returned result.
class ProtocolRecipeRunner {
  ProtocolRecipeRunner({
    required WebSessionService webSessions,
    http.Client? client,
    ProtocolReplayTransport? transport,
  }) : assert(client == null || transport == null),
       _webSessions = webSessions,
       _transport =
           transport ??
           (client == null
               ? _IoProtocolReplayTransport()
               : _PackageHttpReplayTransport(client));

  final WebSessionService _webSessions;
  final ProtocolReplayTransport _transport;

  /// Replays the selected recorded requests in their original observation
  /// order. This is deliberately called a minimal repro: captured values are
  /// reused where possible, but browser-only service-worker/cache behavior and
  /// response-derived token extraction are not invented.
  Future<List<ProtocolRecipeStepResult>> runWorkflow(
    Iterable<ProtocolExchange> exchanges, {
    bool useSavedLogin = false,
    bool? useSessionCookies,
    int maxResponseBytesPerStep = 1024 * 1024,
  }) async {
    final ordered = exchanges.toList(growable: false)
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    final results = <ProtocolRecipeStepResult>[];
    for (final exchange in ordered) {
      results.add(
        ProtocolRecipeStepResult(
          exchange: exchange,
          result: await run(
            exchange,
            useSavedLogin: useSavedLogin,
            useSessionCookies: useSessionCookies,
            maxResponseBytes: maxResponseBytesPerStep,
          ),
        ),
      );
    }
    return List.unmodifiable(results);
  }

  Future<ProtocolRecipeResult> run(
    ProtocolExchange exchange, {
    bool useSavedLogin = false,
    bool? useSessionCookies,
    int maxResponseBytes = 1024 * 1024,
  }) async {
    if (maxResponseBytes < 0) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        'Must not be negative.',
      );
    }
    var uri = Uri.parse(exchange.url);
    if (!_isHttp(uri)) {
      throw ArgumentError('Only HTTP(S) recipes can run.');
    }

    var method = exchange.method.toUpperCase();
    var bodyBytes = _requestBodyBytes(exchange);
    final fidelityIssues = <String>{};
    if (exchange.requestHeaders.any(
      (field) => field.name.toLowerCase() == 'accept-encoding',
    )) {
      fidelityIssues.add('accept_encoding_managed_by_replay_client');
    }
    if (exchange.source == ProtocolRequestSource.form) {
      final reconstructed = _reconstructForm(exchange, method, uri);
      uri = reconstructed.url;
      bodyBytes = reconstructed.bodyBytes;
      fidelityIssues.add('form_reconstructed_not_byte_exact');
    }
    var headers = _requestHeaders(exchange);
    if (exchange.source == ProtocolRequestSource.form &&
        method != 'GET' &&
        method != 'HEAD') {
      headers.putIfAbsent(
        'Content-Type',
        () => 'application/x-www-form-urlencoded; charset=utf-8',
      );
    }

    const maximumRedirects = 10;
    final redirectChain = <String>[];
    var usedSessionCookies = false;
    ProtocolReplayTransportResponse? response;

    for (var hop = 0; hop <= maximumRedirects; hop++) {
      final hopHeaders = Map<String, String>.from(headers);
      if (useSessionCookies ?? useSavedLogin) {
        final cookieHeader = await _webSessions.liveCookieHeaderFor(
          uri.toString(),
        );
        if (cookieHeader.isNotEmpty) {
          hopHeaders['Cookie'] = cookieHeader;
          usedSessionCookies = true;
        }
      }

      response = await _transport.send(
        ProtocolReplayTransportRequest(
          method: method,
          url: uri,
          headers: Map.unmodifiable(hopHeaders),
          bodyBytes: List.unmodifiable(bodyBytes),
        ),
        maxResponseBytes: maxResponseBytes,
      );
      await _webSessions.applyLiveResponseCookies(
        uri.toString(),
        response.cookies,
      );

      final location = _firstHeader(response.headers, 'location');
      if (!_isRedirect(response.statusCode) || location == null) {
        break;
      }
      if (hop == maximumRedirects) {
        throw StateError('Replay exceeded $maximumRedirects redirects.');
      }
      final next = uri.resolve(location);
      if (!_isHttp(next)) {
        throw StateError('Replay redirect left HTTP(S).');
      }
      redirectChain.add(next.toString());

      if (!_sameOrigin(uri, next)) {
        headers = Map<String, String>.from(headers)
          ..removeWhere(
            (name, _) => const {
              'authorization',
              'proxy-authorization',
            }.contains(name.toLowerCase()),
          );
        fidelityIssues.add('cross_origin_authorization_removed');
      }
      if (_redirectChangesToGet(response.statusCode, method)) {
        method = 'GET';
        bodyBytes = const [];
        headers = Map<String, String>.from(headers)
          ..removeWhere(
            (name, _) => const {
              'content-type',
              'content-encoding',
              'content-language',
            }.contains(name.toLowerCase()),
          );
      }
      uri = next;
    }

    final completed = response!;
    final contentType = _firstHeader(completed.headers, 'content-type');
    final mimeType = _mimeType(contentType);
    final isText = _isTextualResponse(mimeType, completed.bodyBytes);
    String? body;
    String? omittedReason;
    if (isText) {
      final decoded = _decodeText(completed.bodyBytes, contentType);
      body = decoded.text;
      if (decoded.fidelityIssue != null) {
        fidelityIssues.add(decoded.fidelityIssue!);
      }
    } else {
      omittedReason = 'binary_response_not_stored';
    }

    return ProtocolRecipeResult(
      statusCode: completed.statusCode,
      headers: Map.unmodifiable(_safeResponseHeaders(completed.headers)),
      body: body,
      mimeType: mimeType,
      byteLength: completed.byteLength,
      truncated: completed.truncated,
      omittedReason: omittedReason,
      finalUrl: uri.toString(),
      redirectChain: List.unmodifiable(redirectChain),
      usedSessionCookies: usedSessionCookies,
      fidelityIssues: List.unmodifiable(fidelityIssues),
    );
  }

  void close() => _transport.close();

  static bool _isHttp(Uri uri) =>
      const {'http', 'https'}.contains(uri.scheme.toLowerCase()) &&
      uri.host.isNotEmpty;

  static bool _isRedirect(int status) =>
      const {301, 302, 303, 307, 308}.contains(status);

  static bool _redirectChangesToGet(int status, String method) =>
      (status == 303 && method.toUpperCase() != 'HEAD') ||
      ((status == 301 || status == 302) && method.toUpperCase() == 'POST');

  static bool _sameOrigin(Uri first, Uri second) =>
      first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      first.port == second.port;

  static Map<String, String> _requestHeaders(ProtocolExchange exchange) {
    final headers = <String, String>{};
    for (final field in exchange.requestHeaders) {
      final name = field.name.trim();
      if (name.isEmpty ||
          const {
            'cookie',
            'host',
            'content-length',
            'connection',
            'transfer-encoding',
            'accept-encoding',
            'proxy-authorization',
            'proxy-connection',
            'te',
            'trailer',
            'upgrade',
          }.contains(name.toLowerCase())) {
        continue;
      }
      headers[name] = field.value;
    }
    return headers;
  }

  static List<int> _requestBodyBytes(ProtocolExchange exchange) {
    final body = exchange.requestBody;
    if (body == null) return const [];
    final text = body.text;
    if (text != null) return utf8.encode(text);
    if ((body.byteLength ?? 0) > 0) {
      throw StateError(
        'The captured request had a non-text body that cannot be replayed exactly.',
      );
    }
    return const [];
  }

  static ({Uri url, List<int> bodyBytes}) _reconstructForm(
    ProtocolExchange exchange,
    String method,
    Uri url,
  ) {
    if (exchange.captureIssues.contains(
      'form_contains_file_body_not_replayable',
    )) {
      throw StateError('A captured form containing files cannot be replayed.');
    }
    final raw = exchange.requestBody?.text;
    if (raw == null) {
      throw StateError('The captured form fields are unavailable.');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Captured form fields are malformed.');
    }
    final pairs = <MapEntry<String, String>>[];
    for (final item in decoded) {
      if (item is! List ||
          item.length != 2 ||
          item[0] is! String ||
          item[1] is! String) {
        throw const FormatException(
          'Captured form contains a file or unsupported field.',
        );
      }
      pairs.add(MapEntry(item[0] as String, item[1] as String));
    }
    final encoded = pairs
        .map(
          (pair) =>
              '${Uri.encodeQueryComponent(pair.key).replaceAll('%20', '+')}='
              '${Uri.encodeQueryComponent(pair.value).replaceAll('%20', '+')}',
        )
        .join('&');
    if (method == 'GET' || method == 'HEAD') {
      if (encoded.isEmpty) return (url: url, bodyBytes: const []);
      final existing = url.hasQuery ? '${url.query}&' : '';
      return (
        url: url.replace(query: '$existing$encoded'),
        bodyBytes: const [],
      );
    }
    return (url: url, bodyBytes: utf8.encode(encoded));
  }

  static String? _firstHeader(
    Map<String, List<String>> headers,
    String target,
  ) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target && entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  static Map<String, String> _safeResponseHeaders(
    Map<String, List<String>> headers,
  ) {
    final safe = <String, String>{};
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (name == 'set-cookie' || name == 'cookie') continue;
      safe[entry.key] = entry.value.join(', ');
    }
    return safe;
  }

  static String? _mimeType(String? contentType) {
    if (contentType == null || contentType.trim().isEmpty) return null;
    return contentType.split(';').first.trim().toLowerCase();
  }

  static bool _isTextualResponse(String? mimeType, List<int> bytes) {
    if (mimeType == null) return _looksLikeUtf8Text(bytes);
    return mimeType.startsWith('text/') ||
        mimeType.contains('json') ||
        mimeType.contains('xml') ||
        mimeType.contains('javascript') ||
        mimeType.contains('graphql') ||
        mimeType == 'application/x-www-form-urlencoded' ||
        mimeType == 'image/svg+xml';
  }

  static bool _looksLikeUtf8Text(List<int> bytes) {
    if (bytes.isEmpty) return true;
    if (bytes.contains(0)) return false;
    try {
      final decoded = utf8.decode(bytes);
      final nonText = decoded.runes.where(
        (rune) => rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d,
      );
      return nonText.length * 20 <= decoded.runes.length;
    } on FormatException {
      return false;
    }
  }

  static ({String text, String? fidelityIssue}) _decodeText(
    List<int> bytes,
    String? contentType,
  ) {
    final charset = RegExp(
      r'charset\s*=\s*["\x27]?([^;"\x27\s]+)',
      caseSensitive: false,
    ).firstMatch(contentType ?? '')?.group(1)?.toLowerCase();
    if (charset == 'iso-8859-1' ||
        charset == 'latin1' ||
        charset == 'latin-1') {
      return (text: latin1.decode(bytes), fidelityIssue: null);
    }
    if (charset == null ||
        charset == 'utf-8' ||
        charset == 'utf8' ||
        charset == 'us-ascii') {
      return (
        text: utf8.decode(bytes, allowMalformed: true),
        fidelityIssue: null,
      );
    }
    return (
      text: utf8.decode(bytes, allowMalformed: true),
      fidelityIssue: 'unsupported_response_charset_decoded_as_utf8',
    );
  }
}

class _IoProtocolReplayTransport implements ProtocolReplayTransport {
  _IoProtocolReplayTransport() : _client = HttpClient()..autoUncompress = true;

  final HttpClient _client;

  @override
  Future<ProtocolReplayTransportResponse> send(
    ProtocolReplayTransportRequest replayRequest, {
    required int maxResponseBytes,
  }) async {
    final request = await _client.openUrl(
      replayRequest.method,
      replayRequest.url,
    );
    request.followRedirects = false;
    for (final entry in replayRequest.headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (replayRequest.bodyBytes.isNotEmpty) {
      request.add(replayRequest.bodyBytes);
    }
    final response = await request.close();
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      headers[name] = List.unmodifiable(values);
    });
    final bounded = await _readBounded(response, maxResponseBytes);
    var cookies = const <WebSessionCookie>[];
    try {
      cookies = response.cookies.map(_webSessionCookie).toList(growable: false);
    } on Object {
      // Ignore malformed Set-Cookie syntax without retaining the raw value.
    }
    return ProtocolReplayTransportResponse(
      statusCode: response.statusCode,
      headers: Map.unmodifiable(headers),
      bodyBytes: bounded.bytes,
      byteLength: response.contentLength >= 0
          ? response.contentLength
          : bounded.observedBytes,
      truncated: bounded.truncated,
      cookies: cookies,
    );
  }

  @override
  void close() => _client.close(force: true);
}

class _PackageHttpReplayTransport implements ProtocolReplayTransport {
  _PackageHttpReplayTransport(this._client);

  final http.Client _client;

  @override
  Future<ProtocolReplayTransportResponse> send(
    ProtocolReplayTransportRequest replayRequest, {
    required int maxResponseBytes,
  }) async {
    final request = http.Request(replayRequest.method, replayRequest.url)
      ..followRedirects = false
      ..headers.addAll(replayRequest.headers)
      ..bodyBytes = replayRequest.bodyBytes;
    final response = await _client.send(request);
    final bounded = await _readBounded(response.stream, maxResponseBytes);
    final headers = response.headersSplitValues;
    final cookies = <WebSessionCookie>[];
    for (final value in headers['set-cookie'] ?? const <String>[]) {
      try {
        cookies.add(_webSessionCookie(Cookie.fromSetCookieValue(value)));
      } on Object {
        // A malformed cookie must not prevent the user from examining the
        // response. Its raw value is never retained.
      }
    }
    return ProtocolReplayTransportResponse(
      statusCode: response.statusCode,
      headers: Map.unmodifiable(headers),
      bodyBytes: bounded.bytes,
      byteLength: response.contentLength ?? bounded.observedBytes,
      truncated: bounded.truncated,
      cookies: List.unmodifiable(cookies),
    );
  }

  @override
  void close() => _client.close();
}

Future<({List<int> bytes, int observedBytes, bool truncated})> _readBounded(
  Stream<List<int>> stream,
  int maximum,
) async {
  final bytes = <int>[];
  var observed = 0;
  var truncated = false;
  await for (final chunk in stream) {
    observed += chunk.length;
    final remaining = maximum - bytes.length;
    if (remaining > 0) {
      bytes.addAll(chunk.take(remaining));
    }
    if (chunk.length > remaining) {
      truncated = true;
      break;
    }
  }
  return (
    bytes: List<int>.unmodifiable(bytes),
    observedBytes: observed,
    truncated: truncated,
  );
}

WebSessionCookie _webSessionCookie(Cookie cookie) => WebSessionCookie(
  name: cookie.name,
  value: cookie.value,
  domain: cookie.domain,
  path: cookie.path,
  expiresDate:
      cookie.expires?.millisecondsSinceEpoch ??
      (cookie.maxAge == null
          ? null
          : DateTime.now()
                .add(Duration(seconds: cookie.maxAge!))
                .millisecondsSinceEpoch),
  isSecure: cookie.secure,
  isHttpOnly: cookie.httpOnly,
  sameSite: cookie.sameSite?.name,
);
