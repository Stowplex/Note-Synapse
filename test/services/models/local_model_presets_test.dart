import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

void main() {
  group('LocalModelPreset', () {
    test('gemma4_e2b preset has correct properties', () {
      final preset = LocalModelPresets.gemma4E2b;

      expect(preset.id, 'gemma4_e2b');
      expect(preset.displayName, 'Gemma 4 E2B');
      expect(
        preset.downloadUrl,
        contains('gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm'),
      );
      expect(preset.filename, 'gemma-4-E2B-it.litertlm');
      expect(preset.modelType, gemma.ModelType.gemmaIt);
      expect(preset.fileType, gemma.ModelFileType.litertlm);
      expect(preset.supportsVision, isTrue);
      expect(preset.supportsThinking, isFalse);
      expect(preset.supportsToolCalls, isTrue);
      expect(preset.defaultTokenWindow, 16384);
      expect(preset.minTokenWindow, 2048);
      expect(preset.maxTokenWindow, 32768);
      expect(preset.defaultBackend['android'], 'gpu');
      expect(preset.defaultBackend['ios'], 'gpu');
    });

    test('all presets returns the Gemma preset', () {
      expect(LocalModelPresets.all, hasLength(1));
      expect(LocalModelPresets.all.single.id, 'gemma4_e2b');
    });

    test('findById returns correct preset', () {
      expect(LocalModelPresets.findById('gemma4_e2b')?.id, 'gemma4_e2b');
      expect(LocalModelPresets.findById('nonexistent'), isNull);
    });
  });
}
