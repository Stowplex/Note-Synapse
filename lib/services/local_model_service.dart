import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/services/models/local_model_presets.dart';

class LocalModelDownloadProgress {
  final int progressPercent;

  const LocalModelDownloadProgress({required this.progressPercent});
}

class LocalModelStatus {
  final LocalModelPreset preset;
  final bool isDownloaded;
  final String? modelPath;

  const LocalModelStatus({
    required this.preset,
    required this.isDownloaded,
    this.modelPath,
  });
}

class LocalModelService {
  static const _keyPrefix = 'local_model_source_';

  Future<bool> isModelDownloaded(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    final preset = LocalModelPresets.findById(modelId);
    if (preset != null) {
      try {
        final installed = await FlutterGemma.isModelInstalled(preset.filename);
        if (installed) {
          await prefs.setString('$_keyPrefix$modelId', preset.downloadUrl);
          return true;
        }
      } catch (_) {
        // FlutterGemma is not initialized in some unit tests.
      }
    }
    return prefs.containsKey('$_keyPrefix$modelId');
  }

  Future<String?> getModelPath(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_keyPrefix$modelId');
  }

  Future<void> markModelDownloaded(String modelId, String source) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_keyPrefix$modelId', source);
  }

  Future<void> removeModel(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    final preset = LocalModelPresets.findById(modelId);
    if (preset != null) {
      try {
        final installed = await FlutterGemma.isModelInstalled(preset.filename);
        if (installed) {
          await FlutterGemma.uninstallModel(preset.filename);
        }
      } catch (_) {
        // Ignore plugin initialization failures in tests.
      }
    }
    await prefs.remove('$_keyPrefix$modelId');
  }

  Future<List<String>> getDownloadedModels() async {
    final downloaded = <String>[];
    for (final preset in LocalModelPresets.available) {
      if (await isModelDownloaded(preset.id)) {
        downloaded.add(preset.id);
      }
    }
    return downloaded;
  }

  Future<List<LocalModelStatus>> getAvailableModels() async {
    final statuses = <LocalModelStatus>[];
    for (final preset in LocalModelPresets.available) {
      final source = await getModelPath(preset.id);
      final isDownloaded = await isModelDownloaded(preset.id);
      statuses.add(
        LocalModelStatus(
          preset: preset,
          isDownloaded: isDownloaded,
          modelPath: source,
        ),
      );
    }
    return statuses;
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
      await FlutterGemma.installModel(
        modelType: preset.modelType,
        fileType: preset.fileType,
      ).fromNetwork(
        preset.downloadUrl,
        foreground: preset.foregroundDownload,
      ).withProgress((progress) {
        if (!controller.isClosed) {
          controller.add(
            LocalModelDownloadProgress(progressPercent: progress),
          );
        }
      }).install();
      await markModelDownloaded(preset.id, preset.downloadUrl);
      onComplete(preset.downloadUrl);
    } catch (e) {
      onError(e.toString());
    } finally {
      await controller.close();
    }
  }
}
