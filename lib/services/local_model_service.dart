import 'dart:async';

import 'package:edge_gen/edge_gen.dart';

import 'package:note_synapse/services/models/local_model_presets.dart';

class LocalModelDownloadProgress {
  final int progressPercent;

  const LocalModelDownloadProgress({required this.progressPercent});
}

class LocalModelStatus {
  final LocalModelPreset preset;
  final bool isDownloaded;

  /// Path to the model's `config.json` when downloaded; null otherwise.
  final String? modelPath;

  const LocalModelStatus({
    required this.preset,
    required this.isDownloaded,
    this.modelPath,
  });
}

/// Download / status / deletion for on-device models, backed by the MNN model
/// downloader in edge_gen. The source of truth is the files on disk — there is
/// no separate bookkeeping to drift out of sync.
class LocalModelService {
  LocalModelService({QwenModelDownloader? downloader})
    : _downloader = downloader ?? QwenModelDownloader();

  final QwenModelDownloader _downloader;

  Future<bool> isModelDownloaded(String modelId) async {
    final preset = LocalModelPresets.findById(modelId);
    if (preset == null) return false;
    return _downloader.isDownloaded(preset.mnnSpec);
  }

  /// Path to the downloaded model's `config.json`, or null if not downloaded.
  Future<String?> getModelPath(String modelId) async {
    final preset = LocalModelPresets.findById(modelId);
    if (preset == null) return null;
    if (!await _downloader.isDownloaded(preset.mnnSpec)) return null;
    return _downloader.resolveConfigPath(preset.mnnSpec);
  }

  Future<List<String>> getDownloadedModels() async {
    final downloaded = <String>[];
    for (final preset in LocalModelPresets.available) {
      if (await _downloader.isDownloaded(preset.mnnSpec)) {
        downloaded.add(preset.id);
      }
    }
    return downloaded;
  }

  Future<List<LocalModelStatus>> getAvailableModels() async {
    final statuses = <LocalModelStatus>[];
    for (final preset in LocalModelPresets.available) {
      final isDownloaded = await _downloader.isDownloaded(preset.mnnSpec);
      statuses.add(
        LocalModelStatus(
          preset: preset,
          isDownloaded: isDownloaded,
          modelPath: isDownloaded
              ? await _downloader.resolveConfigPath(preset.mnnSpec)
              : null,
        ),
      );
    }
    return statuses;
  }

  /// Delete a downloaded model's files to reclaim disk space. No-op if the
  /// model id is unknown or nothing is on disk.
  Future<void> removeModel(String modelId) async {
    final preset = LocalModelPresets.findById(modelId);
    if (preset == null) return;
    await _downloader.deleteDownloadedModel(preset.mnnSpec);
  }

  Stream<LocalModelDownloadProgress> downloadModel(
    LocalModelPreset preset, {
    required void Function(String configPath) onComplete,
    required void Function(String error) onError,
  }) {
    final controller = StreamController<LocalModelDownloadProgress>();
    _doDownload(preset, controller, onComplete, onError);
    return controller.stream;
  }

  Future<void> _doDownload(
    LocalModelPreset preset,
    StreamController<LocalModelDownloadProgress> controller,
    void Function(String configPath) onComplete,
    void Function(String error) onError,
  ) async {
    try {
      final model = await _downloader.ensureDownloaded(
        preset.mnnSpec,
        onProgress: (progress) {
          if (!controller.isClosed) {
            controller.add(
              LocalModelDownloadProgress(
                progressPercent: (progress.fraction * 100).round().clamp(0, 100),
              ),
            );
          }
        },
      );
      onComplete(model.configPath);
    } catch (e) {
      onError(e.toString());
    } finally {
      await controller.close();
    }
  }
}
