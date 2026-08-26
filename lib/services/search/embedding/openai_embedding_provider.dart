import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../logger_service.dart';
import '../../network_provider.dart';
import 'embedding_provider.dart';

/// OpenAI-compatible embedding provider: `POST {endpoint}/v1/embeddings`.
///
/// The endpoint is a free-form base URL — presets (OpenAI, DeepSeek, …) are
/// prefills only, and self-hosted servers (Ollama, vLLM, TEI, LiteLLM) are
/// first-class: the API key is OPTIONAL, and when absent no Authorization
/// header is sent. Text only ([supportsImages] is always false).
class OpenAIEmbeddingProvider implements EmbeddingProvider {
  static const int _maxBatchSize = 100;

  final EmbeddingProviderConfig config;
  final EmbeddingHttpPost _post;

  OpenAIEmbeddingProvider(this.config, {EmbeddingHttpPost? httpPost})
    : _post = httpPost ?? _networkProviderPost;

  static Future<http.Response> _networkProviderPost(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return NetworkProvider.post(url, headers: headers, body: body);
  }

  @override
  String get providerKey => 'openai:${config.modelName}:${config.dimensions}';

  @override
  String get displayName => config.displayName;

  @override
  int get dimensions => config.dimensions;

  @override
  bool get supportsImages => false;

  @override
  int get maxBatchSize => _maxBatchSize;

  @override
  Future<bool> isReady() async {
    // Keyless self-hosted endpoints are valid: only the endpoint is required.
    final endpoint = config.endpoint;
    return endpoint != null && endpoint.isNotEmpty;
  }

  /// Resolve the embeddings URL from the free-form base endpoint. Users may
  /// paste a bare host ("https://api.openai.com"), a versioned base
  /// ("http://localhost:11434/v1"), or the full route — accept all three.
  Uri buildRequestUri() {
    final raw = (config.endpoint ?? '').trim();
    if (raw.isEmpty) {
      throw const EmbeddingProviderException(
        'OpenAI-compatible embedding endpoint not configured',
      );
    }
    // Strip ALL trailing slashes ("https://host//" happens with pasted
    // URLs) so route suffix checks and appends see a clean base.
    var base = raw;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/embeddings')) {
      return Uri.parse(base);
    }
    if (base.endsWith('/v1')) {
      return Uri.parse('$base/embeddings');
    }
    return Uri.parse('$base/v1/embeddings');
  }

  @override
  Future<List<Float32List>> embedDocuments(List<EmbeddingInput> inputs) async {
    if (inputs.isEmpty) return [];
    if (inputs.length > maxBatchSize) {
      throw ArgumentError.value(
        inputs.length,
        'inputs',
        'exceeds maxBatchSize ($maxBatchSize); callers must chunk batches',
      );
    }
    final texts = inputs.map((input) {
      if (input.isImage) {
        throw EmbeddingProviderException(
          '${config.modelName} does not support image inputs',
        );
      }
      return input.text ?? '';
    }).toList();
    return _embed(texts);
  }

  @override
  Future<Float32List> embedQuery(String query) async {
    final vectors = await _embed([query]);
    return vectors.first;
  }

  Future<List<Float32List>> _embed(List<String> inputs) async {
    final requestBody = <String, dynamic>{
      'model': config.modelName,
      'input': inputs,
    };
    // Matryoshka truncation parameter. Opt-in (sendDimensions): the official
    // OpenAI API supports it, but many self-hosted OpenAI-compatible servers
    // reject the parameter outright.
    if (config.sendDimensions && config.dimensions > 0) {
      requestBody['dimensions'] = config.dimensions;
    }

    final headers = <String, String>{'Content-Type': 'application/json'};
    final apiKey = config.apiKey;
    if (apiKey != null && apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }

    http.Response response;
    try {
      response = await _post(
        buildRequestUri(),
        headers: headers,
        body: jsonEncode(requestBody),
      );
    } on EmbeddingProviderException {
      rethrow;
    } catch (e) {
      LoggerService.error('OpenAIEmbeddingProvider: network error: $e');
      throw EmbeddingProviderException.network(e);
    }

    if (response.statusCode != 200) {
      LoggerService.error(
        'OpenAIEmbeddingProvider: request failed '
        '(${response.statusCode}) for ${config.modelName}',
      );
      throw EmbeddingProviderException.fromHttpStatus(
        response.statusCode,
        response.body,
      );
    }

    final decoded = jsonDecode(response.body);
    final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
    if (data is! List || data.length != inputs.length) {
      throw EmbeddingProviderException(
        'OpenAI embeddings response returned '
        '${data is List ? data.length : 'no'} vectors for '
        '${inputs.length} inputs',
      );
    }

    // Order by `index` — the API documents data order as matching input
    // order, but index is authoritative when the server provides it.
    // Sort ONLY when every entry carries a valid, distinct, in-range index:
    // some OpenAI-compatible servers omit `index`, and treating missing as
    // 0 through an unstable sort can permute >32 embeddings, silently
    // attaching vectors to the wrong texts. Missing indexes → preserve
    // server order (documented to match input order); duplicate or
    // out-of-range indexes → permanent error rather than corrupt vectors.
    final entries = List<Map<String, dynamic>>.from(data);
    final indexes = entries.map((e) => e['index'] as num?).toList();
    if (indexes.every((i) => i != null)) {
      final seen = <int>{};
      for (final index in indexes) {
        final i = index!.toInt();
        if (index != i || i < 0 || i >= entries.length || !seen.add(i)) {
          throw EmbeddingProviderException(
            'OpenAI embeddings response has invalid index values '
            '(duplicate or out of range): $indexes',
          );
        }
      }
      entries.sort((a, b) => (a['index'] as num).compareTo(b['index'] as num));
    }

    final vectors = entries.map((entry) {
      final values = entry['embedding'];
      if (values is! List || values.isEmpty) {
        throw const EmbeddingProviderException(
          'OpenAI embeddings response missing embedding values',
        );
      }
      final doubles = values
          .map((v) => (v as num).toDouble())
          .toList(growable: false);
      // ALWAYS L2-normalize before storing/returning.
      return l2Normalize(doubles);
    }).toList();

    // Runtime dims guard: a wrong dims value that skipped testConnection
    // (e.g. sendDimensions off against a server with a different native
    // size) must fail loudly instead of silently indexing off-size vectors
    // under a providerKey whose dims component lies.
    if (vectors.isNotEmpty && vectors.first.length != config.dimensions) {
      throw EmbeddingProviderException.dimensionMismatch(
        modelName: config.modelName,
        expected: config.dimensions,
        actual: vectors.first.length,
      );
    }
    return vectors;
  }
}
