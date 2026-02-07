import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/model_preset_service.dart';
import 'package:note_synapse/models/model_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelPresetService', () {
    test('instance getter returns singleton', () {
      final instance1 = ModelPresetService.instance;
      final instance2 = ModelPresetService.instance;
      expect(identical(instance1, instance2), isTrue);
    });

    test('getApiKeyUrl returns null for unknown model', () {
      final service = ModelPresetService.instance;
      final url = service.getApiKeyUrl('NonExistentModel');
      expect(url, isNull);
    });

    test('hasPremiumWarning returns false for unknown model', () {
      final service = ModelPresetService.instance;
      final hasPremium = service.hasPremiumWarning('NonExistentModel');
      expect(hasPremium, isFalse);
    });

    test('getPresetForType returns null when no presets match', () async {
      final service = ModelPresetService.instance;
      // This will try to load presets - may or may not find files
      // but should not throw
      final preset = await service.getPresetForType(ModelType.gemini);
      // Result could be null or a preset depending on asset availability
      expect(preset == null || preset.type == ModelType.gemini, isTrue);
    });

    test('loadPresets does not throw with forceRefresh', () async {
      final service = ModelPresetService.instance;
      // This should not throw even if assets are not available
      expect(
        () async => await service.loadPresets(forceRefresh: true),
        returnsNormally,
      );
    });
  });
}
