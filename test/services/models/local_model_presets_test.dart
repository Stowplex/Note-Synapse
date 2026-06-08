import 'package:edge_gen/edge_gen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/services/models/local_model_tool_templates/local_model_type.dart';

void main() {
  group('LocalModelPreset', () {
    test('gemma4_e2b preset has correct properties', () {
      final preset = LocalModelPresets.gemma4E2b;

      expect(preset.id, 'gemma4_e2b');
      expect(preset.displayName, 'Gemma 4 E2B');
      expect(preset.mnnSpec, QwenModelSpec.gemma4E2bMnn);
      expect(preset.mnnSpec.repoId, 'taobao-mnn/gemma-4-E2B-it-MNN');
      expect(preset.family, LocalModelFamily.gemma);
      expect(preset.supportsVision, isTrue);
      expect(preset.supportsAudio, isTrue);
      expect(preset.supportsThinking, isFalse);
      expect(preset.supportsToolCalls, isTrue);
      expect(preset.supportsToolOrchestration, isFalse);
      expect(preset.minTokenWindow, 2048);
      expect(preset.maxTokenWindow, 32768);
      // Android GPU backend is OpenCL; iOS is Metal.
      expect(preset.defaultBackend['android'], 'opencl');
      expect(preset.defaultBackend['ios'], 'metal');
      expect(preset.supportedBackends['android'], contains('cpu'));
    });

    test('qwen presets use the qwen tool-call family', () {
      for (final preset in [
        LocalModelPresets.qwen35_08b,
        LocalModelPresets.qwen35_2b,
        LocalModelPresets.qwen35_4b,
      ]) {
        expect(preset.family, LocalModelFamily.qwen);
        expect(preset.supportsToolCalls, isTrue);
      }
    });

    test('all presets are the Gemma + Qwen MNN catalog', () {
      final ids = LocalModelPresets.all.map((p) => p.id).toList();
      expect(ids, ['gemma4_e2b', 'qwen35_08b', 'qwen35_2b', 'qwen35_4b']);
    });

    test('findById returns correct preset', () {
      expect(LocalModelPresets.findById('gemma4_e2b')?.id, 'gemma4_e2b');
      expect(LocalModelPresets.findById('qwen35_4b')?.id, 'qwen35_4b');
      expect(LocalModelPresets.findById('nonexistent'), isNull);
    });
  });
}
