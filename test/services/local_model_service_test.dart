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
      final result = await service.isModelDownloaded('gemma4_e2b');
      expect(result, false);
    });

    test('getDownloadedModels returns empty list initially', () async {
      final result = await service.getDownloadedModels();
      expect(result, isEmpty);
    });

    test('markModelDownloaded persists model path', () async {
      await service.markModelDownloaded(
        'gemma4_e2b',
        'https://example.com/gemma-4-E2B-it.litertlm',
      );
      final result = await service.isModelDownloaded('gemma4_e2b');
      expect(result, true);
    });

    test('getModelPath returns stored path', () async {
      await service.markModelDownloaded(
        'gemma4_e2b',
        'https://example.com/gemma-4-E2B-it.litertlm',
      );
      final path = await service.getModelPath('gemma4_e2b');
      expect(path, 'https://example.com/gemma-4-E2B-it.litertlm');
    });

    test('removeModel clears stored path', () async {
      await service.markModelDownloaded(
        'gemma4_e2b',
        'https://example.com/gemma-4-E2B-it.litertlm',
      );
      await service.removeModel('gemma4_e2b');
      final result = await service.isModelDownloaded('gemma4_e2b');
      expect(result, false);
    });

    test('getAvailableModels returns all presets with download status',
        () async {
      await service.markModelDownloaded(
        'gemma4_e2b',
        'https://example.com/gemma-4-E2B-it.litertlm',
      );
      final models = await service.getAvailableModels();
      expect(models.length, LocalModelPresets.all.length);
      expect(
        models.firstWhere((m) => m.preset.id == 'gemma4_e2b').isDownloaded,
        true,
      );
    });
  });
}
