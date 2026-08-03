import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/protocol_exchange.dart';
import '../web_session_service.dart';

class ProtocolRecipeResult {
  const ProtocolRecipeResult({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.truncated,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
  final bool truncated;
}

class ProtocolRecipeStepResult {
  const ProtocolRecipeStepResult({
    required this.exchange,
    required this.result,
  });

  final ProtocolExchange exchange;
  final ProtocolRecipeResult result;
}

/// Executes a selected exchange as a local minimal repro. Saved-login cookies
/// are attached immediately before the HTTP call and are never represented in
/// generated code, AI prompts, or the returned result.
class ProtocolRecipeRunner {
  ProtocolRecipeRunner({
    required WebSessionService webSessions,
    http.Client? client,
  }) : _webSessions = webSessions,
       _client = client ?? http.Client();

  final WebSessionService _webSessions;
  final http.Client _client;

  /// Replays the selected recorded requests in their original observation
  /// order. This is deliberately called a minimal repro: captured values are
  /// reused exactly, but browser-only service-worker/cache behavior and
  /// response-derived token extraction are not invented.
  Future<List<ProtocolRecipeStepResult>> runWorkflow(
    Iterable<ProtocolExchange> exchanges, {
    bool useSavedLogin = false,
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
    int maxResponseBytes = 1024 * 1024,
  }) async {
    final uri = Uri.parse(exchange.url);
    if (!const {'http', 'https'}.contains(uri.scheme)) {
      throw ArgumentError('Only HTTP(S) recipes can run.');
    }
    final request = http.Request(exchange.method, uri);
    for (final field in exchange.requestHeaders) {
      final name = field.name.toLowerCase();
      if (const {
        'cookie',
        'host',
        'content-length',
        'connection',
      }.contains(name)) {
        continue;
      }
      request.headers[field.name] = field.value;
    }
    if (useSavedLogin) {
      final cookie = await _webSessions.cookieHeaderFor(exchange.url);
      if (cookie.isNotEmpty) request.headers['Cookie'] = cookie;
    }
    if (exchange.requestBody?.text case final body?) {
      request.bodyBytes = utf8.encode(body);
    }
    final streamed = await _client.send(request);
    final bytes = <int>[];
    var truncated = false;
    await for (final chunk in streamed.stream) {
      final remaining = maxResponseBytes - bytes.length;
      if (remaining <= 0) {
        truncated = true;
        continue;
      }
      if (chunk.length > remaining) {
        bytes.addAll(chunk.take(remaining));
        truncated = true;
      } else {
        bytes.addAll(chunk);
      }
    }
    return ProtocolRecipeResult(
      statusCode: streamed.statusCode,
      headers: Map.unmodifiable(streamed.headers),
      body: utf8.decode(bytes, allowMalformed: true),
      truncated: truncated,
    );
  }

  void close() => _client.close();
}
