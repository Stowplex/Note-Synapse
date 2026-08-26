import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:path/path.dart' as path;

import '../../logger_service.dart';
import 'embedding_provider.dart';

/// Checks whether the on-device model + tokenizer files for [config] are
/// installed.
///
/// Defaults to [gemma.FlutterGemma.isModelInstalled] checks on both files;
/// tests inject a fake because flutter_gemma's platform channel is not
/// available there (mirrors the [EmbeddingHttpPost] seam of the HTTP
/// providers).
typedef LocalEmbedderInstalledCheck =
    Future<bool> Function(EmbeddingProviderConfig config);

/// Embeds [texts] on device, applying [taskType]'s retrieval prefix.
///
/// Defaults to the lazily initialized flutter_gemma [gemma.EmbeddingModel];
/// tests inject a fake to capture task-type routing and return canned
/// vectors.
typedef LocalEmbedFn =
    Future<List<List<double>>> Function(
      List<String> texts,
      gemma.TaskType taskType,
    );

/// (Re)activates the installed files as flutter_gemma's active embedding
/// spec and returns the live [gemma.EmbeddingModel].
///
/// Defaults to the FlutterGemma installEmbedder/getActiveEmbedder chain;
/// tests inject a fake model because the plugin's platform channel is not
/// available there.
typedef LocalEmbedderActivateFn =
    Future<gemma.EmbeddingModel> Function(EmbeddingProviderConfig config);

/// On-device embedding provider backed by flutter_gemma's LiteRT embedder
/// (EmbeddingGemma — model + tokenizer files, see plan §2.1).
///
/// - Text-only: image inputs throw a permanent [EmbeddingProviderException].
/// - Documents are embedded with [gemma.TaskType.retrievalDocument], queries
///   with [gemma.TaskType.retrievalQuery] (EmbeddingGemma is prefix-trained).
/// - Outputs are ALWAYS L2-normalized. flutter_gemma does not document its
///   raw LiteRT outputs as unit vectors, and normalization is a cheap
///   idempotent guard either way (same policy as the HTTP providers).
/// - The model is initialized lazily on first embed and NEVER downloaded
///   here: installs are strictly opt-in via LocalEmbeddingModelManager. When
///   the files are missing, calls fail with `isNotInstalled: true`.
/// - [dispose] closes the native model; the registry calls it when the
///   active provider changes.
class LocalEmbeddingProvider implements EmbeddingProvider {
  /// Modest cap for on-device work: batches run sequentially on the
  /// CPU/GPU delegate (~300 ms/document), so large batches only delay
  /// progress reporting and cancellation without adding throughput.
  static const int _maxBatchSize = 8;

  final EmbeddingProviderConfig config;
  final LocalEmbedderInstalledCheck? _installedCheck;
  final LocalEmbedFn? _embedFn;
  final LocalEmbedderActivateFn? _activateModel;

  /// Lazily created on first embed (default path only); closed by [dispose].
  Future<gemma.EmbeddingModel>? _modelFuture;

  LocalEmbeddingProvider(
    this.config, {
    LocalEmbedderInstalledCheck? installedCheck,
    LocalEmbedFn? embedFn,
    LocalEmbedderActivateFn? activateModel,
  }) : _installedCheck = installedCheck,
       _embedFn = embedFn,
       _activateModel = activateModel;

  /// Filename flutter_gemma stores the model file under: the URL path
  /// basename — the same derivation EmbeddingInstallationBuilder uses, so
  /// installed-checks and uninstalls address the exact files it wrote.
  static String? modelFilenameFor(EmbeddingProviderConfig config) =>
      _urlBasename(config.modelUrl);

  /// Filename flutter_gemma stores the tokenizer file under.
  static String? tokenizerFilenameFor(EmbeddingProviderConfig config) =>
      _urlBasename(config.tokenizerUrl);

  static String? _urlBasename(String? url) {
    if (url == null || url.isEmpty) return null;
    // EmbeddingInstallationBuilder._extractFilename derives the stored
    // filename as `path.basename(Uri.parse(url).path)`. Uri.path keeps
    // percent-ENCODING (unlike Uri.pathSegments, which decodes), so a URL
    // containing "%20" is stored under a name with the literal "%20" — this
    // derivation must match byte-for-byte or installed-checks and uninstalls
    // would address a file the installer never wrote.
    final basename = path.basename(Uri.parse(url).path);
    return basename.isEmpty || basename == '.' || basename == '/'
        ? null
        : basename;
  }

  @override
  String get providerKey => 'local:${config.modelName}:${config.dimensions}';

  @override
  String get displayName => config.displayName;

  @override
  int get dimensions => config.dimensions;

  @override
  bool get supportsImages => false;

  @override
  int get maxBatchSize => _maxBatchSize;

  @override
  Future<bool> isReady() => _isInstalled();

  Future<bool> _isInstalled() async {
    final check = _installedCheck;
    if (check != null) return check(config);

    final modelFilename = modelFilenameFor(config);
    final tokenizerFilename = tokenizerFilenameFor(config);
    if (modelFilename == null || tokenizerFilename == null) return false;
    try {
      return await gemma.FlutterGemma.isModelInstalled(modelFilename) &&
          await gemma.FlutterGemma.isModelInstalled(tokenizerFilename);
    } catch (_) {
      // FlutterGemma is not initialized in some unit tests (mirrors
      // LocalModelService.isModelDownloaded's guard).
      return false;
    }
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
    final texts = inputs
        .map((input) {
          if (input.isImage) {
            throw EmbeddingProviderException(
              '${config.modelName} is a text-only on-device embedder and does '
              'not support image inputs',
            );
          }
          return input.text ?? '';
        })
        .toList(growable: false);

    final vectors = await _embed(texts, gemma.TaskType.retrievalDocument);
    if (vectors.length != texts.length) {
      throw EmbeddingProviderException(
        'On-device embedder returned ${vectors.length} vectors for '
        '${texts.length} inputs',
      );
    }
    return vectors.map(l2Normalize).toList(growable: false);
  }

  @override
  Future<Float32List> embedQuery(String query) async {
    final vectors = await _embed([query], gemma.TaskType.retrievalQuery);
    if (vectors.isEmpty) {
      throw const EmbeddingProviderException(
        'On-device embedder returned no vector for the query',
      );
    }
    return l2Normalize(vectors.first);
  }

  Future<List<List<double>>> _embed(
    List<String> texts,
    gemma.TaskType taskType,
  ) async {
    final vectors = await _embedRaw(texts, taskType);
    // Runtime dims guard: a wrong dims value that skipped testConnection
    // must fail loudly here, not silently index off-size vectors under a
    // providerKey whose dims component lies.
    if (vectors.isNotEmpty && vectors.first.length != config.dimensions) {
      throw EmbeddingProviderException.dimensionMismatch(
        modelName: config.modelName,
        expected: config.dimensions,
        actual: vectors.first.length,
      );
    }
    return vectors;
  }

  Future<List<List<double>>> _embedRaw(
    List<String> texts,
    gemma.TaskType taskType,
  ) async {
    final embedFn = _embedFn;
    if (embedFn != null) return embedFn(texts, taskType);

    if (!await _isInstalled()) {
      throw EmbeddingProviderException(
        '${config.displayName} is not installed on this device — download '
        'it from search settings first',
        isNotInstalled: true,
      );
    }
    final modelFuture = _ensureModel();
    final model = await modelFuture;
    try {
      return await model.generateEmbeddings(texts, taskType: taskType);
    } catch (e) {
      // Self-heal: flutter_gemma's embedding model is a PLUGIN-LEVEL
      // singleton, so an external close (a probe provider's dispose, an
      // uninstall, another provider taking over the spec) invalidates our
      // cached instance and every call on it throws StateError. Drop the
      // cache so the NEXT embed re-initializes cleanly (the plugin's
      // onClose reset makes re-init safe) instead of failing until app
      // restart. Identity-guarded so a concurrent re-init's fresher future
      // is never clobbered.
      if (identical(_modelFuture, modelFuture)) {
        _modelFuture = null;
      }
      LoggerService.error('LocalEmbeddingProvider: embedding failed: $e');
      throw EmbeddingProviderException('On-device embedding failed: $e');
    }
  }

  Future<gemma.EmbeddingModel> _ensureModel() {
    final existing = _modelFuture;
    if (existing != null) return existing;
    late final Future<gemma.EmbeddingModel> future;
    future = _createModel().then<gemma.EmbeddingModel>(
      (model) => model,
      onError: (Object e, StackTrace st) {
        // Initialization failed: clear the cache so the next embed retries.
        // Identity-guarded — dispose() or a newer init may have already
        // replaced the cached future, and nulling unconditionally here
        // (this callback runs asynchronously) could clobber that newer
        // future and leak its model.
        if (identical(_modelFuture, future)) {
          _modelFuture = null;
        }
        Error.throwWithStackTrace(e, st);
      },
    );
    _modelFuture = future;
    return future;
  }

  Future<gemma.EmbeddingModel> _createModel() async {
    final modelUrl = config.modelUrl;
    final tokenizerUrl = config.tokenizerUrl;
    if (modelUrl == null || tokenizerUrl == null) {
      throw EmbeddingProviderException(
        'Local embedding config "${config.modelName}" is missing its '
        'model/tokenizer download URLs',
        isNotInstalled: true,
      );
    }
    // TOCTOU guard: the caller checked _isInstalled() before _ensureModel(),
    // but an uninstall can land in between — re-check immediately before
    // (re)installing so a vanished file surfaces as isNotInstalled instead
    // of triggering an unwanted download. A residual race remains between
    // this check and the plugin's own file access; it only narrows the
    // window, it cannot eliminate it.
    if (!await _isInstalled()) {
      throw EmbeddingProviderException(
        '${config.displayName} is not installed on this device — download '
        'it from search settings first',
        isNotInstalled: true,
      );
    }
    final activate = _activateModel;
    try {
      if (activate != null) return await activate(config);
      // Re-run the installer builder to (re)activate the installed files as
      // the active embedding spec. install() is idempotent: both files were
      // just verified installed, so NO download happens here — this only
      // registers the spec (needed after an app restart, or when another
      // embedding model was previously active).
      await gemma.FlutterGemma.installEmbedder()
          .modelFromNetwork(modelUrl)
          .tokenizerFromNetwork(tokenizerUrl)
          .install();
      return await gemma.FlutterGemma.getActiveEmbedder();
    } catch (e) {
      LoggerService.error('LocalEmbeddingProvider: init failed: $e');
      throw EmbeddingProviderException(
        'On-device embedder failed to initialize: $e',
      );
    }
  }

  /// Close the on-device model and release native resources. Called by the
  /// registry when the active provider changes; safe to call repeatedly
  /// (the next embed lazily re-initializes).
  Future<void> dispose() async {
    final pending = _modelFuture;
    _modelFuture = null;
    if (pending == null) return;
    try {
      final model = await pending;
      await model.close();
    } catch (_) {
      // Initialization failed (already surfaced to the embed caller) —
      // nothing to close.
    }
  }
}
