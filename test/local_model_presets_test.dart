import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

void main() {
  group('LocalModelPresets.gemma4E2b', () {
    test('supportsToolOrchestration is false', () {
      expect(LocalModelPresets.gemma4E2b.supportsToolOrchestration, isFalse);
    });

    test('supportsToolCalls remains true', () {
      expect(LocalModelPresets.gemma4E2b.supportsToolCalls, isTrue);
    });
  });

  group('LocalModelPreset default', () {
    test('supportsToolOrchestration defaults to false when not specified', () {
      const preset = LocalModelPreset(
        id: 'test',
        displayName: 'Test',
        downloadUrl: '',
        filename: '',
        modelType: gemma.ModelType.gemmaIt,
        fileType: gemma.ModelFileType.litertlm,
        defaultBackend: {},
        supportedBackends: {},
        supportsVision: false,
        supportsThinking: false,
        supportsToolCalls: false,
        defaultTokenWindow: 8192,
        minTokenWindow: 2048,
        maxTokenWindow: 16384,
      );
      expect(preset.supportsToolOrchestration, isFalse);
    });
  });
}
