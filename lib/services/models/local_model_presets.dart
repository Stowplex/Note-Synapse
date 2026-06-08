import 'package:edge_gen/edge_gen.dart';
import 'package:flutter/foundation.dart';

import 'local_model_tool_templates/local_model_type.dart';

/// A selectable on-device model, backed by the MNN runtime via edge_gen.
///
/// [mnnSpec] describes where to download the model and which files it needs;
/// [family] selects the tool-call parser. Backend strings are edge_gen-native
/// (`cpu`, `opencl` on Android, `metal` on iOS).
class LocalModelPreset {
  final String id;
  final String displayName;
  final QwenModelSpec mnnSpec;
  final LocalModelFamily family;
  final Map<String, String> defaultBackend;
  final Map<String, List<String>> supportedBackends;
  final bool supportsVision;
  final bool supportsAudio;
  final bool supportsThinking;
  final bool supportsToolCalls;
  final bool supportsToolOrchestration;
  final bool experimental;
  final int defaultTokenWindow;
  final int minTokenWindow;
  final int maxTokenWindow;
  final int? maxNumImages;
  final double temperature;
  final int topK;
  final double topP;

  const LocalModelPreset({
    required this.id,
    required this.displayName,
    required this.mnnSpec,
    required this.family,
    required this.defaultBackend,
    required this.supportedBackends,
    required this.supportsVision,
    required this.supportsThinking,
    required this.supportsToolCalls,
    required this.defaultTokenWindow,
    required this.minTokenWindow,
    required this.maxTokenWindow,
    this.supportsAudio = false,
    this.experimental = false,
    this.supportsToolOrchestration = false,
    this.maxNumImages,
    this.temperature = 1.0,
    this.topK = 64,
    this.topP = 0.95,
  });
}

class LocalModelPresets {
  LocalModelPresets._();

  // Android GPU backend is OpenCL; iOS GPU backend is Metal. CPU is always
  // available as a fallback.
  static const Map<String, String> _gpuDefaultBackend = {
    'android': 'opencl',
    'ios': 'metal',
  };
  static const Map<String, List<String>> _gpuOrCpuBackends = {
    'android': ['opencl', 'cpu'],
    'ios': ['metal', 'cpu'],
  };

  static const gemma4E2b = LocalModelPreset(
    id: 'gemma4_e2b',
    displayName: 'Gemma 4 E2B',
    mnnSpec: QwenModelSpec.gemma4E2bMnn,
    family: LocalModelFamily.gemma,
    defaultBackend: _gpuDefaultBackend,
    supportedBackends: _gpuOrCpuBackends,
    supportsVision: true,
    supportsAudio: true,
    supportsThinking: false,
    supportsToolCalls: true,
    defaultTokenWindow: 8192,
    minTokenWindow: 2048,
    maxTokenWindow: 32768,
    maxNumImages: 8,
  );

  static const qwen35_08b = LocalModelPreset(
    id: 'qwen35_08b',
    displayName: 'Qwen3.5 0.8B',
    mnnSpec: QwenModelSpec.qwen35_08bMnn,
    family: LocalModelFamily.qwen,
    defaultBackend: _gpuDefaultBackend,
    supportedBackends: _gpuOrCpuBackends,
    supportsVision: true,
    supportsThinking: true,
    supportsToolCalls: true,
    defaultTokenWindow: 8192,
    minTokenWindow: 2048,
    maxTokenWindow: 32768,
    maxNumImages: 4,
    temperature: 0.7,
    topK: 20,
    topP: 0.8,
  );

  static const qwen35_2b = LocalModelPreset(
    id: 'qwen35_2b',
    displayName: 'Qwen3.5 2B',
    mnnSpec: QwenModelSpec.qwen35_2bMnn,
    family: LocalModelFamily.qwen,
    defaultBackend: _gpuDefaultBackend,
    supportedBackends: _gpuOrCpuBackends,
    supportsVision: true,
    supportsThinking: true,
    supportsToolCalls: true,
    defaultTokenWindow: 8192,
    minTokenWindow: 2048,
    maxTokenWindow: 32768,
    maxNumImages: 4,
    temperature: 0.7,
    topK: 20,
    topP: 0.8,
  );

  static const qwen35_4b = LocalModelPreset(
    id: 'qwen35_4b',
    displayName: 'Qwen3.5 4B',
    mnnSpec: QwenModelSpec.qwen35_4bMnn,
    family: LocalModelFamily.qwen,
    defaultBackend: _gpuDefaultBackend,
    supportedBackends: _gpuOrCpuBackends,
    supportsVision: true,
    supportsThinking: true,
    supportsToolCalls: true,
    defaultTokenWindow: 8192,
    minTokenWindow: 2048,
    maxTokenWindow: 32768,
    maxNumImages: 4,
    temperature: 0.7,
    topK: 20,
    topP: 0.8,
  );

  static final List<LocalModelPreset> all = [
    gemma4E2b,
    qwen35_08b,
    qwen35_2b,
    qwen35_4b,
  ];

  static List<LocalModelPreset> get available {
    if (kDebugMode) {
      return all;
    }
    return all.where((preset) => !preset.experimental).toList(growable: false);
  }

  static LocalModelPreset? findById(String id) {
    try {
      return all.firstWhere((preset) => preset.id == id);
    } catch (_) {
      return null;
    }
  }
}
