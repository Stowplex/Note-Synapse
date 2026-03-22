import 'package:edge_gen/edge_gen.dart';

class LocalModelPreset {
  final String id;
  final String displayName;
  final QwenModelSpec spec;
  final Map<String, String> defaultBackend;
  final bool supportsVision;
  final bool supportsThinking;
  final int defaultTokenWindow;

  const LocalModelPreset({
    required this.id,
    required this.displayName,
    required this.spec,
    required this.defaultBackend,
    required this.supportsVision,
    required this.supportsThinking,
    required this.defaultTokenWindow,
  });
}

class LocalModelPresets {
  LocalModelPresets._();

  // CPU-only: OpenCL produces garbled output for this model's attention layers.
  static final qwen35_08b = LocalModelPreset(
    id: 'qwen35_08b',
    displayName: 'Qwen 3.5 0.8B',
    spec: QwenModelSpec.qwen35_08bMnn,
    defaultBackend: {'android': 'cpu', 'ios': 'cpu'},
    supportsVision: true,
    supportsThinking: true,
    defaultTokenWindow: 16384,
  );

  static final qwen3Vl2b = LocalModelPreset(
    id: 'qwen3_vl_2b',
    displayName: 'Qwen3 VL 2B',
    spec: QwenModelSpec.qwen3Vl2bInstructMnn,
    defaultBackend: {'android': 'cpu', 'ios': 'metal'},
    supportsVision: true,
    supportsThinking: true,
    defaultTokenWindow: 16384,
  );

  static final List<LocalModelPreset> all = [qwen35_08b, qwen3Vl2b];

  static LocalModelPreset? findById(String id) {
    try {
      return all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}
