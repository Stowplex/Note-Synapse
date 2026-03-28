import 'package:flutter/foundation.dart';
import 'package:edge_gen/edge_gen.dart';

class LocalModelPreset {
  final String id;
  final String displayName;
  final QwenModelSpec spec;
  final Map<String, String> defaultBackend;
  final Map<String, List<String>> supportedBackends;
  final bool supportsVision;
  final bool supportsThinking;
  final bool experimental;
  final int defaultTokenWindow;

  const LocalModelPreset({
    required this.id,
    required this.displayName,
    required this.spec,
    required this.defaultBackend,
    required this.supportedBackends,
    required this.supportsVision,
    required this.supportsThinking,
    this.experimental = false,
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
    supportedBackends: {
      'android': ['cpu'],
      'ios': ['cpu'],
    },
    supportsVision: true,
    supportsThinking: true,
    defaultTokenWindow: 16384,
  );

  static final qwen3Vl2b = LocalModelPreset(
    id: 'qwen3_vl_2b',
    displayName: 'Qwen3 VL 2B',
    spec: QwenModelSpec.qwen3Vl2bInstructMnn,
    defaultBackend: {'android': 'cpu', 'ios': 'cpu'},
    supportedBackends: {
      'android': ['cpu'],
      'ios': ['cpu'],
    },
    supportsVision: true,
    supportsThinking: true,
    experimental: true,
    defaultTokenWindow: 16384,
  );

  static final List<LocalModelPreset> all = [qwen35_08b, qwen3Vl2b];

  static List<LocalModelPreset> get available {
    if (kDebugMode) {
      return all;
    }
    return all.where((preset) => !preset.experimental).toList(growable: false);
  }

  static LocalModelPreset? findById(String id) {
    try {
      return all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}
