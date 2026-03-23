import 'dart:async';
import 'dart:io';
import 'package:edge_gen/edge_gen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

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
  static const _keyPrefix = 'local_model_path_';

  Future<bool> isModelDownloaded(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_keyPrefix$modelId');
  }

  Future<String?> getModelPath(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_keyPrefix$modelId');
  }

  Future<void> markModelDownloaded(String modelId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_keyPrefix$modelId', path);
  }

  Future<void> removeModel(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('$_keyPrefix$modelId');
    if (path != null) {
      final dir = Directory(path).parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    await prefs.remove('$_keyPrefix$modelId');
  }

  Future<List<String>> getDownloadedModels() async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded = <String>[];
    for (final preset in LocalModelPresets.available) {
      if (prefs.containsKey('$_keyPrefix${preset.id}')) {
        downloaded.add(preset.id);
      }
    }
    return downloaded;
  }

  Future<List<LocalModelStatus>> getAvailableModels() async {
    final statuses = <LocalModelStatus>[];
    for (final preset in LocalModelPresets.available) {
      final path = await getModelPath(preset.id);
      statuses.add(
        LocalModelStatus(
          preset: preset,
          isDownloaded: path != null,
          modelPath: path,
        ),
      );
    }
    return statuses;
  }

  /// Downloads [preset] and emits raw download progress updates.
  ///
  /// [onComplete] is called with the config path when the download finishes.
  /// [onError] is called with an error message if the download fails.
  Stream<DownloadProgress> downloadModel(
    LocalModelPreset preset, {
    required void Function(String configPath) onComplete,
    required void Function(String error) onError,
  }) {
    final controller = StreamController<DownloadProgress>();
    _doDownload(preset, controller, onComplete, onError);
    return controller.stream;
  }

  Future<void> _doDownload(
    LocalModelPreset preset,
    StreamController<DownloadProgress> controller,
    void Function(String configPath) onComplete,
    void Function(String error) onError,
  ) async {
    try {
      final downloaded = await QwenModelDownloader().ensureDownloaded(
        preset.spec,
        onProgress: (DownloadProgress progress) {
          if (!controller.isClosed) {
            controller.add(progress);
          }
        },
      );
      await markModelDownloaded(preset.id, downloaded.configPath);
      onComplete(downloaded.configPath);
    } catch (e) {
      onError(e.toString());
    } finally {
      await controller.close();
    }
  }
}
