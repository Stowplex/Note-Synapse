import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

void main() {
  group('LocalModelPreset', () {
    test('qwen35_08b preset has correct properties', () {
      final preset = LocalModelPresets.qwen35_08b;
      expect(preset.id, 'qwen35_08b');
      expect(preset.displayName, 'Qwen 3.5 0.8B');
      expect(preset.supportsVision, true);
      expect(preset.supportsThinking, true);
      expect(preset.defaultTokenWindow, 16384);
      expect(preset.defaultBackend['android'], 'cpu');
      expect(preset.defaultBackend['ios'], 'cpu');
    });

    test('qwen35_2b preset has correct properties', () {
      final preset = LocalModelPresets.qwen35_2b;
      expect(preset.id, 'qwen35_2b');
      expect(preset.displayName, 'Qwen 3.5 2B');
      expect(preset.supportsVision, true);
      expect(preset.supportsThinking, true);
      expect(preset.defaultTokenWindow, 16384);
      expect(preset.defaultBackend['android'], 'cpu');
      expect(preset.defaultBackend['ios'], 'cpu');
    });

    test('qwen3_vl_2b preset has correct properties', () {
      final preset = LocalModelPresets.qwen3Vl2b;
      expect(preset.id, 'qwen3_vl_2b');
      expect(preset.displayName, 'Qwen3 VL 2B');
      expect(preset.supportsVision, true);
      expect(preset.supportsThinking, true);
      expect(preset.defaultTokenWindow, 16384);
      expect(preset.defaultBackend['android'], 'cpu');
      expect(preset.defaultBackend['ios'], 'cpu');
    });

    test('all presets returns three models', () {
      expect(LocalModelPresets.all.length, 3);
    });

    test('findById returns correct preset', () {
      expect(LocalModelPresets.findById('qwen35_08b')?.id, 'qwen35_08b');
      expect(LocalModelPresets.findById('qwen35_2b')?.id, 'qwen35_2b');
      expect(LocalModelPresets.findById('nonexistent'), null);
    });
  });
}
