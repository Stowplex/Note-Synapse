import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// HTTP POST function signature used by embedding providers.
///
/// Defaults to [NetworkProvider.post] in production; tests inject a fake to
/// capture request shapes and return canned responses (the repo's existing
/// model classes call the static NetworkProvider directly, which is not
/// fakeable — providers here take this seam instead).
typedef EmbeddingHttpPost =
    Future<http.Response> Function(
      Uri url, {
      Map<String, String>? headers,
      Object? body,
    });

/// A single input to embed: either text, or raw bytes (e.g. an image) with a
/// MIME type, for providers that support image inputs.
class EmbeddingInput {
  final String? text;
  final Uint8List? bytes;
  final String? mimeType;

  const EmbeddingInput.text(String this.text) : bytes = null, mimeType = null;

  const EmbeddingInput.image(Uint8List this.bytes, String this.mimeType)
    : text = null;

  bool get isImage => bytes != null;
}

/// Typed exception for embedding provider failures.
///
/// [isAuthError] (401/403): callers must halt backfill immediately — retrying
/// only burns quota and hides the misconfiguration from the user.
/// [isTransient] (429/5xx/timeouts/network): callers may back off and retry.
/// [isNotInstalled] (local providers): the on-device model files are missing —
/// permanent until the user downloads them; the settings UI surfaces this
/// distinctly from auth/transient failures ("Download" vs "Fix key"/"Retry").
class EmbeddingProviderException implements Exception {
  final String message;
  final int? statusCode;
  final bool isAuthError;
  final bool isTransient;
  final bool isNotInstalled;

  /// Set by [EmbeddingProviderException.dimensionMismatch]: the vector length
  /// the provider actually produced when it differs from the configured
  /// dimensions. Permanent for indexing paths (retrying cannot change the
  /// model's output size), but [EmbeddingProviderRegistry.testConnection]
  /// maps it back into a successful probe with a corrected config.
  final int? detectedDimensions;

  const EmbeddingProviderException(
    this.message, {
    this.statusCode,
    this.isAuthError = false,
    this.isTransient = false,
    this.isNotInstalled = false,
    this.detectedDimensions,
  });

  /// The provider produced [actual]-dimensional vectors while the config
  /// promises [expected]. Guards every embed path (not just testConnection,
  /// which can be skipped): silently returning off-size vectors would store
  /// rows under a providerKey whose dims component lies, corrupting the
  /// vector index.
  factory EmbeddingProviderException.dimensionMismatch({
    required String modelName,
    required int expected,
    required int actual,
  }) {
    return EmbeddingProviderException(
      '$modelName returned $actual-dimensional vectors but the configuration '
      'expects $expected dimensions — correct the configured dimensions '
      '(re-run the connection test) before indexing',
      detectedDimensions: actual,
    );
  }

  /// Map an HTTP status code to the right error category.
  factory EmbeddingProviderException.fromHttpStatus(
    int statusCode,
    String body,
  ) {
    final isAuth = statusCode == 401 || statusCode == 403;
    final isTransient =
        statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500;
    return EmbeddingProviderException(
      'Embedding request failed: $statusCode - $body',
      statusCode: statusCode,
      isAuthError: isAuth,
      isTransient: isTransient,
    );
  }

  /// Wrap a network-level failure (socket/timeout/client exception).
  factory EmbeddingProviderException.network(Object error) {
    return EmbeddingProviderException(
      'Embedding network error: $error',
      isTransient: true,
    );
  }

  @override
  String toString() =>
      'EmbeddingProviderException($message, statusCode: $statusCode, '
      'isAuthError: $isAuthError, isTransient: $isTransient, '
      'isNotInstalled: $isNotInstalled)';
}

/// L2-normalize a raw embedding vector into a [Float32List].
///
/// All vectors stored in `chunk_embeddings` and all query vectors MUST be
/// unit-length so cosine similarity reduces to a dot product. This is cheap
/// and idempotent, so providers call it unconditionally — including for
/// models documented as returning pre-normalized outputs (guard against
/// Matryoshka truncation, float re-serialization drift, or doc drift).
Float32List l2Normalize(List<double> values) {
  final result = Float32List(values.length);
  double sumSquares = 0;
  for (final v in values) {
    sumSquares += v * v;
  }
  if (sumSquares == 0) {
    return result; // Zero vector stays zero — nothing meaningful to scale.
  }
  final norm = math.sqrt(sumSquares);
  for (var i = 0; i < values.length; i++) {
    result[i] = values[i] / norm;
  }
  return result;
}

/// Configuration for an embedding provider instance.
///
/// Mirrors [ModelConfig]'s split persistence: the config itself is stored as
/// JSON in SharedPreferences, while the API key lives in secure storage and
/// is injected at build time (never serialized by [toJson]).
class EmbeddingProviderConfig {
  /// Provider type: 'gemini' | 'openai' | 'local'.
  final String type;

  /// Base URL. For gemini this is the API base (…/v1beta); for openai it is a
  /// free-form user-editable base URL (self-hosted servers are valid).
  /// Unused by local configs (their download URLs live in [modelUrl] and
  /// [tokenizerUrl]).
  final String? endpoint;

  final String modelName;
  final String displayName;

  /// Target vector dimensionality. Verified/auto-detected by
  /// [EmbeddingProviderRegistry.testConnection].
  final int dimensions;

  final bool supportsImages;

  /// Gemini only: whether `:batchEmbedContents` is supported. When false the
  /// provider falls back to per-item `:embedContent` calls.
  final bool supportsBatch;

  /// OpenAI only: whether to include the `dimensions` request parameter
  /// (Matryoshka truncation). Off by default — many OpenAI-compatible
  /// self-hosted servers reject unknown/unsupported parameters.
  final bool sendDimensions;

  /// Local only: download URL for the on-device model file (.tflite).
  /// flutter_gemma's two-file embedder install needs BOTH this and
  /// [tokenizerUrl] (EmbeddingInstallationBuilder).
  final String? modelUrl;

  /// Local only: download URL for the on-device tokenizer file
  /// (sentencepiece .model).
  final String? tokenizerUrl;

  /// Where the user can obtain an API key (preset metadata, UI-only). For
  /// gated local model downloads (HuggingFace) this points at the token page.
  final String? apiKeyUrl;

  /// True for a user-entered OpenAI-compatible config not backed by a preset.
  final bool isCustom;

  /// Runtime-resolved API key. Optional: keyless self-hosted OpenAI-compatible
  /// endpoints are valid. Never persisted via [toJson].
  final String? apiKey;

  const EmbeddingProviderConfig({
    required this.type,
    this.endpoint,
    required this.modelName,
    required this.displayName,
    required this.dimensions,
    this.supportsImages = false,
    this.supportsBatch = true,
    this.sendDimensions = false,
    this.modelUrl,
    this.tokenizerUrl,
    this.apiKeyUrl,
    this.isCustom = false,
    this.apiKey,
  });

  /// Row-level invalidation key: "{type}:{model}:{dims}".
  String get providerKey => '$type:$modelName:$dimensions';

  /// Stable identity used as the secure-storage API-key handle
  /// (mirrors ModelStorageService's `'${modelId}_api_key'` convention).
  ///
  /// For OpenAI-compatible configs the ENDPOINT is part of the identity:
  /// the endpoint is free-form, so "model X at host A" and "model X at
  /// host B" are different credentials — without the endpoint component
  /// they would share one secure-storage slot, silently sending host A's
  /// Bearer key to host B (a key leak) and letting B's key overwrite A's.
  /// The endpoint is folded in as a short sha256 digest of its normalized
  /// form so the key stays a compact, storage-safe token.
  ///
  /// Gemini configs keep the endpoint-less id: their endpoint is fixed by
  /// the preset (one Google host), so including it would only churn the
  /// stored-key handle without adding identity. This asymmetry is
  /// deliberate and documented here.
  ///
  /// No migration shim is needed for the id-scheme change: this feature is
  /// on an unreleased branch, so no user has keys stored under the old ids.
  String get storageId {
    if (type == 'openai') {
      return 'embedding_${type}_${modelName}_$_endpointDigest';
    }
    return 'embedding_${type}_$modelName';
  }

  /// First 12 hex chars of sha256 over the normalized endpoint (trimmed,
  /// trailing slashes stripped, lowercased — so cosmetic variants of the
  /// same base URL map to one identity).
  String get _endpointDigest {
    var normalized = (endpoint ?? '').trim().toLowerCase();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 12);
  }

  EmbeddingProviderConfig copyWith({
    String? type,
    String? endpoint,
    String? modelName,
    String? displayName,
    int? dimensions,
    bool? supportsImages,
    bool? supportsBatch,
    bool? sendDimensions,
    String? modelUrl,
    String? tokenizerUrl,
    String? apiKeyUrl,
    bool? isCustom,
    String? apiKey,
  }) {
    return EmbeddingProviderConfig(
      type: type ?? this.type,
      endpoint: endpoint ?? this.endpoint,
      modelName: modelName ?? this.modelName,
      displayName: displayName ?? this.displayName,
      dimensions: dimensions ?? this.dimensions,
      supportsImages: supportsImages ?? this.supportsImages,
      supportsBatch: supportsBatch ?? this.supportsBatch,
      sendDimensions: sendDimensions ?? this.sendDimensions,
      modelUrl: modelUrl ?? this.modelUrl,
      tokenizerUrl: tokenizerUrl ?? this.tokenizerUrl,
      apiKeyUrl: apiKeyUrl ?? this.apiKeyUrl,
      isCustom: isCustom ?? this.isCustom,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  /// Serializes everything EXCEPT the API key (secure storage owns it).
  Map<String, dynamic> toJson() => {
    'type': type,
    'endpoint': endpoint,
    'modelName': modelName,
    'displayName': displayName,
    'dimensions': dimensions,
    'supportsImages': supportsImages,
    'supportsBatch': supportsBatch,
    'sendDimensions': sendDimensions,
    'modelUrl': modelUrl,
    'tokenizerUrl': tokenizerUrl,
    'apiKeyUrl': apiKeyUrl,
    'isCustom': isCustom,
  };

  factory EmbeddingProviderConfig.fromJson(Map<String, dynamic> json) {
    return EmbeddingProviderConfig(
      type: json['type'] as String,
      endpoint: json['endpoint'] as String?,
      modelName: json['modelName'] as String,
      displayName:
          json['displayName'] as String? ?? json['modelName'] as String,
      dimensions: json['dimensions'] as int? ?? 768,
      supportsImages: json['supportsImages'] as bool? ?? false,
      supportsBatch: json['supportsBatch'] as bool? ?? true,
      sendDimensions: json['sendDimensions'] as bool? ?? false,
      modelUrl: json['modelUrl'] as String?,
      tokenizerUrl: json['tokenizerUrl'] as String?,
      apiKeyUrl: json['apiKeyUrl'] as String?,
      isCustom: json['isCustom'] as bool? ?? false,
    );
  }
}

/// Base interface for embedding providers, mirroring the [AIModel] pattern
/// (Gemini / OpenAI-compatible / local, YAML presets — see plan §2.1).
abstract class EmbeddingProvider {
  /// "{type}:{model}:{dims}" — row-level invalidation key for stored vectors.
  String get providerKey;

  String get displayName;

  /// Vector dimensionality this provider produces (default corpus target 768).
  int get dimensions;

  bool get supportsImages;

  /// Maximum number of inputs per [embedDocuments] call.
  int get maxBatchSize;

  Future<bool> isReady();

  /// Embed a batch of document inputs (text and/or bytes+mime).
  /// Returned vectors are ALWAYS L2-normalized.
  Future<List<Float32List>> embedDocuments(List<EmbeddingInput> inputs);

  /// Embed a search query. Returned vector is ALWAYS L2-normalized.
  Future<Float32List> embedQuery(String query);
}
