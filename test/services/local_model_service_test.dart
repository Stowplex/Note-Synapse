import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

void main() {
  group('LocalModelService', () {
    late LocalModelService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = LocalModelService();
    });

    test('isModelDownloaded returns false when no model downloaded', () async {
      final result = await service.isModelDownloaded('qwen35_08b');
      expect(result, false);
    });

    test('getDownloadedModels returns empty list initially', () async {
      final result = await service.getDownloadedModels();
      expect(result, isEmpty);
    });

    test('markModelDownloaded persists model path', () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      final result = await service.isModelDownloaded('qwen35_08b');
      expect(result, true);
    });

    test('getModelPath returns stored path', () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      final path = await service.getModelPath('qwen35_08b');
      expect(path, '/path/to/model');
    });

    test('removeModel clears stored path', () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      await service.removeModel('qwen35_08b');
      final result = await service.isModelDownloaded('qwen35_08b');
      expect(result, false);
    });

    test('getAvailableModels returns all presets with download status',
        () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      final models = await service.getAvailableModels();
      expect(models.length, LocalModelPresets.all.length);
      expect(
          models.firstWhere((m) => m.preset.id == 'qwen35_08b').isDownloaded,
          true);
      expect(
          models.firstWhere((m) => m.preset.id == 'qwen3_vl_2b').isDownloaded,
          false);
    });
  });
}
