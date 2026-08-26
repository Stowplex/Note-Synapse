import 'dart:async';

// DownloadException/DownloadError are not re-exported by
// package:flutter_gemma/flutter_gemma.dart; the deep imports are the only
// way to keep the TYPED variants (gated-HF 401 vs transient network) instead
// of collapsing every failure to an opaque string.
import 'package:flutter_gemma/core/domain/download_error.dart';
import 'package:flutter_gemma/core/domain/download_exception.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;

import 'embedding_provider.dart';
import 'local_embedding_provider.dart';

/// Progress of a two-file (model + tokenizer) embedding model download.
///
/// Extends LocalModelService's single-percent [LocalModelDownloadProgress]
/// shape to two files: per-file percents for detailed UI, plus a combined
/// percent for a single progress bar.
class LocalEmbeddingDownloadProgress {
  final int modelProgressPercent;
  final int tokenizerProgressPercent;

  const LocalEmbeddingDownloadProgress({
    required this.modelProgressPercent,
    required this.tokenizerProgressPercent,
  });

  /// Combined 0–100, weighted heavily toward the model file (~180 MB for
  /// EmbeddingGemma vs a ~4 MB sentencepiece tokenizer).
  int get progressPercent =>
      (modelProgressPercent * 97 + tokenizerProgressPercent * 3) ~/ 100;
}

/// Structured install failure surfaced by [LocalEmbeddingModelManager
/// .install] — manager-local on purpose (downloads are not embed calls, so
/// this deliberately does NOT reuse [EmbeddingProviderException]).
///
/// [isAuthError]: gated HuggingFace repo rejected the request (401/403) —
/// retrying is pointless until the user supplies/fixes a token and accepts
/// the model license. [isTransient]: network/5xx/429 — a retry may succeed.
/// Unknown failures carry neither flag.
class LocalEmbeddingInstallError {
  final String message;
  final bool isAuthError;
  final bool isTransient;

  const LocalEmbeddingInstallError(
    this.message, {
    this.isAuthError = false,
    this.isTransient = false,
  });

  @override
  String toString() =>
      'LocalEmbeddingInstallError($message, isAuthError: $isAuthError, '
      'isTransient: $isTransient)';
}

/// Runs the two-file download/activation for [config], reporting per-file
/// percents. Defaults to flutter_gemma's EmbeddingInstallationBuilder; tests
/// inject a fake (the plugin's platform channel is unavailable there).
typedef LocalEmbedderInstallOp =
    Future<void> Function(
      EmbeddingProviderConfig config,
      String? authToken,
      void Function(int percent) onModelProgress,
      void Function(int percent) onTokenizerProgress,
    );

/// Whether flutter_gemma has [filename] installed. Seam for tests.
typedef LocalModelFileInstalledCheck = Future<bool> Function(String filename);

/// Delete flutter_gemma's installed [filename]. Seam for tests.
typedef LocalModelFileUninstallOp = Future<void> Function(String filename);

/// Close the plugin's LIVE embedding model when it belongs to [config].
/// Seam for tests; defaults to FlutterGemmaPlugin introspection.
typedef LocalActiveEmbedderCloseOp =
    Future<void> Function(EmbeddingProviderConfig config);

/// Manages STRICTLY OPT-IN download/removal of on-device embedding models.
///
/// This extends the existing local-model download UX (LocalModelService's
/// StreamController-progress + onComplete/onError callback pattern) rather
/// than reusing it as-is: flutter_gemma's embedder install is two-file
/// (EmbeddingInstallationBuilder requires BOTH a model and a tokenizer
/// source), so the single `downloadUrl`/`withProgress` flow doesn't fit.
/// Nothing here runs automatically — [install] is only reached from an
/// explicit user action in search settings, and LocalEmbeddingProvider
/// itself never downloads.
class LocalEmbeddingModelManager {
  final LocalEmbedderInstallOp? _installOp;
  final LocalModelFileInstalledCheck? _fileInstalledCheck;
  final LocalModelFileUninstallOp? _fileUninstallOp;
  final LocalActiveEmbedderCloseOp? _closeActiveEmbedderOp;

  /// One in-flight install per config identity ([EmbeddingProviderConfig
  /// .storageId]): a second concurrent [install] joins the first download
  /// instead of racing it (two builder chains over the same files would
  /// double-download and interleave progress).
  final Map<String, _InFlightInstall> _inFlight = {};

  LocalEmbeddingModelManager({
    LocalEmbedderInstallOp? installOp,
    LocalModelFileInstalledCheck? fileInstalledCheck,
    LocalModelFileUninstallOp? fileUninstallOp,
    LocalActiveEmbedderCloseOp? closeActiveEmbedderOp,
  }) : _installOp = installOp,
       _fileInstalledCheck = fileInstalledCheck,
       _fileUninstallOp = fileUninstallOp,
       _closeActiveEmbedderOp = closeActiveEmbedderOp;

  /// Whether both files (model + tokenizer) for [config] are installed.
  Future<bool> isInstalled(EmbeddingProviderConfig config) async {
    final modelFilename = LocalEmbeddingProvider.modelFilenameFor(config);
    final tokenizerFilename = LocalEmbeddingProvider.tokenizerFilenameFor(
      config,
    );
    if (modelFilename == null || tokenizerFilename == null) return false;
    return await _isFileInstalled(modelFilename) &&
        await _isFileInstalled(tokenizerFilename);
  }

  /// Download and install the model + tokenizer for [config], reporting
  /// per-file progress. Mirrors LocalModelService.downloadModel's signature
  /// (progress stream + onComplete/onError callbacks; the stream closes
  /// after either callback fires).
  ///
  /// [authToken]: HuggingFace access token. The official EmbeddingGemma
  /// LiteRT repo (litert-community/embeddinggemma-300m) is GATED — downloads
  /// fail with 401 unless the user has accepted the license and supplies a
  /// token. The settings UI stores it under the config's secure-storage slot
  /// (`config.storageId`, same mechanism as cloud API keys) and passes it
  /// here.
  ///
  /// install() is idempotent: already-installed files are not re-downloaded
  /// (their share of the combined progress is credited immediately so the
  /// bar doesn't idle near 0%/sit at 97%). A call for a config whose install
  /// is ALREADY running joins the in-flight download: it observes the same
  /// progress and terminal callback rather than starting a duplicate.
  Stream<LocalEmbeddingDownloadProgress> install(
    EmbeddingProviderConfig config, {
    String? authToken,
    required void Function() onComplete,
    required void Function(LocalEmbeddingInstallError error) onError,
  }) {
    final existing = _inFlight[config.storageId];
    if (existing != null) {
      return _attach(existing, onComplete, onError);
    }
    final flight = _InFlightInstall();
    _inFlight[config.storageId] = flight;
    final stream = _attach(flight, onComplete, onError);
    unawaited(_doInstall(config, authToken, flight));
    return stream;
  }

  /// Subscribe one caller to [flight]: mirror its progress into a fresh
  /// stream and fire this caller's terminal callback when it settles.
  Stream<LocalEmbeddingDownloadProgress> _attach(
    _InFlightInstall flight,
    void Function() onComplete,
    void Function(LocalEmbeddingInstallError error) onError,
  ) {
    final out = StreamController<LocalEmbeddingDownloadProgress>();
    final subscription = flight.progress.stream.listen(out.add);
    flight.done.future.then((failure) async {
      await subscription.cancel();
      if (failure == null) {
        onComplete();
      } else {
        onError(failure);
      }
      await out.close();
    });
    return out.stream;
  }

  Future<void> _doInstall(
    EmbeddingProviderConfig config,
    String? authToken,
    _InFlightInstall flight,
  ) async {
    var modelPercent = 0;
    var tokenizerPercent = 0;
    void emit() {
      if (!flight.progress.isClosed) {
        flight.progress.add(
          LocalEmbeddingDownloadProgress(
            modelProgressPercent: modelPercent,
            tokenizerProgressPercent: tokenizerPercent,
          ),
        );
      }
    }

    LocalEmbeddingInstallError? failure;
    try {
      final modelUrl = config.modelUrl;
      final tokenizerUrl = config.tokenizerUrl;
      if (modelUrl == null || tokenizerUrl == null) {
        throw ArgumentError(
          'Local embedding config "${config.modelName}" has no '
          'model/tokenizer download URLs',
        );
      }
      // Pre-credit files that are already installed: the builder skips their
      // download WITHOUT emitting progress for them, so without this the
      // combined bar would sit at 3% (model present) or cap at 97%
      // (tokenizer present) while everything is actually on track.
      final modelFilename = LocalEmbeddingProvider.modelFilenameFor(config);
      final tokenizerFilename = LocalEmbeddingProvider.tokenizerFilenameFor(
        config,
      );
      if (modelFilename != null && await _isFileInstalled(modelFilename)) {
        modelPercent = 100;
      }
      if (tokenizerFilename != null &&
          await _isFileInstalled(tokenizerFilename)) {
        tokenizerPercent = 100;
      }
      if (modelPercent > 0 || tokenizerPercent > 0) emit();

      final installOp = _installOp ?? _defaultInstallOp;
      await installOp(
        config,
        authToken,
        (percent) {
          modelPercent = percent;
          emit();
        },
        (percent) {
          tokenizerPercent = percent;
          emit();
        },
      );
    } catch (e) {
      failure = _mapInstallError(e);
    } finally {
      _inFlight.remove(config.storageId);
      await flight.progress.close();
      flight.done.complete(failure);
    }
  }

  static Future<void> _defaultInstallOp(
    EmbeddingProviderConfig config,
    String? authToken,
    void Function(int percent) onModelProgress,
    void Function(int percent) onTokenizerProgress,
  ) async {
    await gemma.FlutterGemma.installEmbedder()
        .modelFromNetwork(config.modelUrl!, token: authToken)
        .tokenizerFromNetwork(config.tokenizerUrl!, token: authToken)
        .withModelProgress(onModelProgress)
        .withTokenizerProgress(onTokenizerProgress)
        .install();
  }

  /// Map flutter_gemma's typed [DownloadException] variants onto the
  /// structured result the settings UI needs ("get/fix your HF token" vs
  /// "retry"). Non-DownloadException failures keep their message with
  /// neither flag set.
  static LocalEmbeddingInstallError _mapInstallError(Object e) {
    if (e is DownloadException) {
      final error = e.error;
      return LocalEmbeddingInstallError(
        error.toUserMessage(),
        // Gated-repo rejections: 401 (no/expired token) and 403 (token
        // lacks access / license not accepted).
        isAuthError: error is UnauthorizedError || error is ForbiddenError,
        // Matches DownloadError.isRetryable.
        isTransient:
            error is NetworkError ||
            error is ServerError ||
            error is RateLimitedError,
      );
    }
    return LocalEmbeddingInstallError(e.toString());
  }

  /// Remove both installed files for [config] (frees ~180 MB for
  /// EmbeddingGemma). Stored vectors in `chunk_embeddings` are unaffected —
  /// providerKey-based GC is the indexer's job.
  ///
  /// When [config] is the plugin's ACTIVE embedding spec, the live native
  /// model is closed FIRST: deleting the files under an open embedder would
  /// leak the native instance (and its ~hundreds of MB of weights) until app
  /// restart. A LocalEmbeddingProvider currently serving this config
  /// self-heals: its per-call installed re-check makes the next embed fail
  /// with `isNotInstalled: true`, and its embed-failure cache clearing drops
  /// the closed model so nothing stays wedged.
  Future<void> uninstall(EmbeddingProviderConfig config) async {
    final closeOp = _closeActiveEmbedderOp ?? _defaultCloseActiveEmbedder;
    await closeOp(config);

    final filenames = [
      LocalEmbeddingProvider.modelFilenameFor(config),
      LocalEmbeddingProvider.tokenizerFilenameFor(config),
    ];
    for (final filename in filenames) {
      if (filename == null) continue;
      try {
        if (await _isFileInstalled(filename)) {
          final uninstallOp = _fileUninstallOp;
          if (uninstallOp != null) {
            await uninstallOp(filename);
          } else {
            await gemma.FlutterGemma.uninstallModel(filename);
          }
        }
      } catch (_) {
        // Ignore plugin initialization failures in tests (mirrors
        // LocalModelService.removeModel's guard).
      }
    }
  }

  static Future<void> _defaultCloseActiveEmbedder(
    EmbeddingProviderConfig config,
  ) async {
    try {
      final plugin = gemma.FlutterGemmaPlugin.instance;
      final live = plugin.initializedEmbeddingModel;
      if (live == null) return;
      final activeSpec = plugin.modelManager.activeEmbeddingModel;
      final modelFilename = LocalEmbeddingProvider.modelFilenameFor(config);
      if (activeSpec == null || modelFilename == null) return;
      // The spec name is the model filename with its extension(s) stripped
      // (FileNameUtils.getBaseName in EmbeddingInstallationBuilder).
      final matches =
          modelFilename == activeSpec.name ||
          modelFilename.startsWith('${activeSpec.name}.');
      if (matches) {
        await live.close();
      }
    } catch (_) {
      // Plugin not initialized (unit tests) — nothing live to close.
    }
  }

  Future<bool> _isFileInstalled(String filename) async {
    final check = _fileInstalledCheck;
    if (check != null) return check(filename);
    try {
      return await gemma.FlutterGemma.isModelInstalled(filename);
    } catch (_) {
      // FlutterGemma is not initialized in some unit tests (mirrors
      // LocalModelService.isModelDownloaded's guard).
      return false;
    }
  }
}

/// Shared state of one running install: a broadcast progress feed plus a
/// terminal outcome (null = success) every attached caller awaits.
class _InFlightInstall {
  final StreamController<LocalEmbeddingDownloadProgress> progress =
      StreamController<LocalEmbeddingDownloadProgress>.broadcast();
  final Completer<LocalEmbeddingInstallError?> done =
      Completer<LocalEmbeddingInstallError?>();
}
