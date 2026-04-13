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
    test('supportsToolOrchestration defaults to false', () {
      expect(LocalModelPresets.gemma4E2b.supportsToolOrchestration, isFalse);
    });
  });
}
