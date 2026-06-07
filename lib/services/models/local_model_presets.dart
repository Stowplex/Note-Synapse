import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;

class LocalModelPreset {
  final String id;
  final String displayName;
  final String downloadUrl;
  final String filename;
  final gemma.ModelType modelType;
  final gemma.ModelFileType fileType;

  /// Backends offered per platform, e.g. `{'android': ['npu', 'gpu', 'cpu']}`.
  /// The settings screen renders one checkbox per entry and defaults them all
  /// to enabled.
  final Map<String, List<String>> supportedBackends;
  final bool supportsVision;
  final bool supportsThinking;
  final bool supportsToolCalls;
  final bool supportsToolOrchestration;
  final bool experimental;
  final bool foregroundDownload;
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
    required this.downloadUrl,
    required this.filename,
    required this.modelType,
    required this.fileType,
    required this.supportedBackends,
    required this.supportsVision,
    required this.supportsThinking,
    required this.supportsToolCalls,
    required this.defaultTokenWindow,
    required this.minTokenWindow,
    required this.maxTokenWindow,
    this.experimental = false,
    this.foregroundDownload = false,
    this.supportsToolOrchestration = false,
    this.maxNumImages,
    this.temperature = 1.0,
    this.topK = 64,
    this.topP = 0.95,
  });
}

class LocalModelPresets {
  LocalModelPresets._();

  static const gemma4E2b = LocalModelPreset(
    id: 'gemma4_e2b',
    displayName: 'Gemma 4 E2B',
    downloadUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    filename: 'gemma-4-E2B-it.litertlm',
    modelType: gemma.ModelType.gemma4,
    fileType: gemma.ModelFileType.litertlm,
    supportedBackends: {
      // NPU is only honored on Android with .litertlm models; iOS has no NPU
      // path in flutter_gemma, so it isn't offered there.
      'android': ['npu', 'gpu', 'cpu'],
      'ios': ['gpu', 'cpu'],
    },
    supportsVision: true,
    supportsThinking: false,
    supportsToolCalls: true,
    defaultTokenWindow: 16384,
    minTokenWindow: 2048,
    maxTokenWindow: 32768,
    foregroundDownload: true,
    maxNumImages: 8,
  );

  static final List<LocalModelPreset> all = [gemma4E2b];

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
