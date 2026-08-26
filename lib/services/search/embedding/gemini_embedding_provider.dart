import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../logger_service.dart';
import '../../network_provider.dart';
import 'embedding_provider.dart';

/// Gemini embedding provider (REST, HTTP layer patterned on gemini_model.dart:
/// same v1beta base URL and `x-goog-api-key` header).
///
/// - gemini-embedding-001 (text): `task_type` RETRIEVAL_DOCUMENT for
///   documents, RETRIEVAL_QUERY for queries; `outputDimensionality` when the
///   configured dims differ from the native 3072; outputs must be
///   RE-NORMALIZED after Matryoshka truncation.
/// - Multimodal models (config supportsImages, e.g. gemini-embedding-2):
///   image inputs go as `inline_data` parts; outputs are documented as
///   pre-normalized, but we still normalize (cheap idempotent guard).
/// - Batch endpoint `:batchEmbedContents` is used when the config says it is
///   supported; otherwise falls back to per-item `:embedContent`.
class GeminiEmbeddingProvider implements EmbeddingProvider {
  static const String defaultEndpoint =
      'https://generativelanguage.googleapis.com/v1beta';

  /// Native output dimensionality of the gemini-embedding family; requesting
  /// this value needs no `outputDimensionality` parameter.
  static const int nativeDimensions = 3072;

  /// Documented request cap for batchEmbedContents.
  static const int _maxBatchSize = 100;

  final EmbeddingProviderConfig config;
  final EmbeddingHttpPost _post;

  GeminiEmbeddingProvider(this.config, {EmbeddingHttpPost? httpPost})
    : _post = httpPost ?? _networkProviderPost;

  static Future<http.Response> _networkProviderPost(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return NetworkProvider.post(url, headers: headers, body: body);
  }

  @override
  String get providerKey => 'gemini:${config.modelName}:${config.dimensions}';

  @override
  String get displayName => config.displayName;

  @override
  int get dimensions => config.dimensions;

  @override
  bool get supportsImages => config.supportsImages;

  @override
  int get maxBatchSize => config.supportsBatch ? _maxBatchSize : 1;

  /// Configured API base with trailing slashes stripped, so the
  /// `'$_endpoint/models/…'` interpolations never produce '//' in the path.
  String get _endpoint {
    var base = (config.endpoint ?? defaultEndpoint).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base.isEmpty ? defaultEndpoint : base;
  }

  @override
  Future<bool> isReady() async {
    final key = config.apiKey;
    return key != null && key.isNotEmpty;
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
    if (config.supportsBatch) {
      return _batchEmbed(inputs, taskType: 'RETRIEVAL_DOCUMENT');
    }
    // Config flags batch as unsupported (e.g. preview multimodal models):
    // fall back to per-item :embedContent calls.
    final results = <Float32List>[];
    for (final input in inputs) {
      results.add(await _embedSingle(input, taskType: 'RETRIEVAL_DOCUMENT'));
    }
    return results;
  }

  @override
  Future<Float32List> embedQuery(String query) {
    return _embedSingle(
      EmbeddingInput.text(query),
      taskType: 'RETRIEVAL_QUERY',
    );
  }

  Future<List<Float32List>> _batchEmbed(
    List<EmbeddingInput> inputs, {
    required String taskType,
  }) async {
    final requests = inputs
        .map(
          (input) => _buildEmbedContentRequest(
            input,
            taskType: taskType,
            includeModel: true,
          ),
        )
        .toList();

    final data = await _postJson(
      Uri.parse('$_endpoint/models/${config.modelName}:batchEmbedContents'),
      {'requests': requests},
    );

    final embeddings = data['embeddings'];
    if (embeddings is! List || embeddings.length != inputs.length) {
      throw EmbeddingProviderException(
        'Gemini batchEmbedContents returned ${embeddings is List ? embeddings.length : 'no'} '
        'embeddings for ${inputs.length} inputs',
      );
    }
    return embeddings.map((e) => _parseValues(e?['values'])).toList();
  }

  Future<Float32List> _embedSingle(
    EmbeddingInput input, {
    required String taskType,
  }) async {
    final data = await _postJson(
      Uri.parse('$_endpoint/models/${config.modelName}:embedContent'),
      _buildEmbedContentRequest(input, taskType: taskType),
    );
    return _parseValues(data['embedding']?['values']);
  }

  /// Builds an EmbedContentRequest. [includeModel] is required inside
  /// batchEmbedContents request entries.
  Map<String, dynamic> _buildEmbedContentRequest(
    EmbeddingInput input, {
    required String taskType,
    bool includeModel = false,
  }) {
    final request = <String, dynamic>{
      'content': {
        'parts': [_buildPart(input)],
      },
    };
    if (includeModel) {
      request['model'] = 'models/${config.modelName}';
    }
    // taskType applies to text inputs; multimodal image requests omit it
    // (the multimodal models embed all modalities into one vector space
    // without retrieval task hints for images).
    if (!input.isImage) {
      request['taskType'] = taskType;
    }
    if (config.dimensions != nativeDimensions) {
      request['outputDimensionality'] = config.dimensions;
    }
    return request;
  }

  Map<String, dynamic> _buildPart(EmbeddingInput input) {
    if (input.isImage) {
      if (!config.supportsImages) {
        throw EmbeddingProviderException(
          '${config.modelName} does not support image inputs',
        );
      }
      final mimeType = input.mimeType;
      if (mimeType == null || mimeType.isEmpty) {
        throw const EmbeddingProviderException(
          'Image embedding input requires a MIME type',
        );
      }
      // Mirrors gemini_model.dart's inline_data attachment part shape.
      return {
        'inline_data': {
          'mime_type': mimeType,
          'data': base64Encode(input.bytes!),
        },
      };
    }
    return {'text': input.text ?? ''};
  }

  Future<Map<String, dynamic>> _postJson(
    Uri url,
    Map<String, dynamic> requestBody,
  ) async {
    final apiKey = config.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      throw const EmbeddingProviderException(
        'Gemini embedding API key not configured',
        isAuthError: true,
      );
    }

    http.Response response;
    try {
      response = await _post(
        url,
        headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
        body: jsonEncode(requestBody),
      );
    } on EmbeddingProviderException {
      rethrow;
    } catch (e) {
      LoggerService.error('GeminiEmbeddingProvider: network error: $e');
      throw EmbeddingProviderException.network(e);
    }

    if (response.statusCode != 200) {
      LoggerService.error(
        'GeminiEmbeddingProvider: request failed '
        '(${response.statusCode}) for ${config.modelName}',
      );
      throw EmbeddingProviderException.fromHttpStatus(
        response.statusCode,
        response.body,
      );
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw const EmbeddingProviderException(
        'Gemini embedding response was not a JSON object',
      );
    }
    return data;
  }

  Float32List _parseValues(dynamic values) {
    if (values is! List || values.isEmpty) {
      throw const EmbeddingProviderException(
        'Gemini embedding response missing vector values',
      );
    }
    final doubles = values
        .map((v) => (v as num).toDouble())
        .toList(growable: false);
    // Runtime dims guard: a wrong dims value that skipped testConnection
    // (e.g. a dims equal to nativeDimensions typo suppressing the
    // outputDimensionality parameter) must fail loudly instead of silently
    // indexing off-size vectors under a lying providerKey.
    if (doubles.length != config.dimensions) {
      throw EmbeddingProviderException.dimensionMismatch(
        modelName: config.modelName,
        expected: config.dimensions,
        actual: doubles.length,
      );
    }
    // ALWAYS re-normalize: mandatory after Matryoshka truncation for
    // gemini-embedding-001; an idempotent no-op guard for models that
    // already return unit vectors.
    return l2Normalize(doubles);
  }
}
