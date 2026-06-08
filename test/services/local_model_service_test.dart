import 'package:edge_gen/edge_gen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

/// In-memory stand-in for the MNN downloader so the service can be tested
/// without the filesystem / platform channels. Tracks "downloaded" specs by
/// their directory name.
class _FakeDownloader extends QwenModelDownloader {
  final Set<String> downloaded = <String>{};

  @override
  Future<bool> isDownloaded(QwenModelSpec spec) async =>
      downloaded.contains(spec.directoryName);

  @override
  Future<void> deleteDownloadedModel(QwenModelSpec spec) async {
    downloaded.remove(spec.directoryName);
  }

  @override
  Future<String> resolveConfigPath(QwenModelSpec spec) async =>
      '/fake/${spec.directoryName}/config.json';
}

void main() {
  group('LocalModelService', () {
    late _FakeDownloader downloader;
    late LocalModelService service;

    setUp(() {
      downloader = _FakeDownloader();
      service = LocalModelService(downloader: downloader);
    });

    String dirFor(String id) =>
        LocalModelPresets.findById(id)!.mnnSpec.directoryName;

    test('isModelDownloaded returns false when no model downloaded', () async {
      expect(await service.isModelDownloaded('gemma4_e2b'), false);
    });

    test('getDownloadedModels returns empty list initially', () async {
      expect(await service.getDownloadedModels(), isEmpty);
    });

    test('reflects downloaded state and config path', () async {
      downloader.downloaded.add(dirFor('gemma4_e2b'));

      expect(await service.isModelDownloaded('gemma4_e2b'), true);
      expect(await service.getModelPath('gemma4_e2b'), contains('config.json'));
      expect(await service.getDownloadedModels(), contains('gemma4_e2b'));
    });

    test('getModelPath is null when not downloaded', () async {
      expect(await service.getModelPath('gemma4_e2b'), isNull);
    });

    test('removeModel deletes the downloaded model', () async {
      downloader.downloaded.add(dirFor('gemma4_e2b'));
      await service.removeModel('gemma4_e2b');
      expect(await service.isModelDownloaded('gemma4_e2b'), false);
    });

    test('getAvailableModels returns all presets with download status',
        () async {
      downloader.downloaded.add(dirFor('gemma4_e2b'));
      final models = await service.getAvailableModels();
      expect(models.length, LocalModelPresets.available.length);
      final gemma = models.firstWhere((m) => m.preset.id == 'gemma4_e2b');
      expect(gemma.isDownloaded, true);
      expect(gemma.modelPath, contains('config.json'));
    });
  });
}
