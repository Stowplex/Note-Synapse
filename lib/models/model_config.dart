import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'model_type.dart';
import 'model_capabilities.dart';

/// Configuration for a specific model
class ModelConfig {
  final String id;
  final ModelType type;
  final String? apiKey;
  final String? endpoint;
  final String? modelName;
  final String? displayName;
  final int? maxInputTokens;
  final int? maxOutputTokens;
  final ModelCapabilities? customCapabilitiesObject;
  final List<String>? supportedAttachmentMimeTypes;
  final List<String>? modelFeatures;
  final bool isConfigured;
  final int? tokenWindow;
  final bool? enableThinking;

  /// Enabled local-inference backends, in no particular order (e.g.
  /// `['npu', 'gpu', 'cpu']`). The effective backend handed to the engine is
  /// the highest-priority enabled one — see [backendPriority] and
  /// [effectiveBackendType].
  final List<String>? backendTypes;

  /// Backend selection priority, highest first. The underlying engine falls
  /// back along this same chain when a backend is unavailable.
  static const List<String> backendPriority = ['npu', 'gpu', 'cpu'];

  ModelConfig({
    String? id,
    required this.type,
    this.apiKey,
    this.endpoint,
    this.modelName,
    this.displayName,
    this.maxInputTokens,
    this.maxOutputTokens,
    ModelCapabilities? customCapabilitiesObject,
    List<String>? supportedAttachmentMimeTypes,
    List<String>? modelFeatures,
    this.isConfigured = false,
    this.tokenWindow,
    this.enableThinking,
    this.backendTypes,
  }) : id = id ?? const Uuid().v4(),
       customCapabilitiesObject =
           customCapabilitiesObject ??
           const ModelCapabilities(
             maxInputTokens: 100000,
             maxOutputTokens: 4000,
             supportsImages: false,
             supportsDocuments: false,
             supportsAudio: false,
             supportsVideo: false,
           ),
       supportedAttachmentMimeTypes = supportedAttachmentMimeTypes == null
           ? null
           : List.unmodifiable(
               supportedAttachmentMimeTypes.map((m) => m.trim()).toList(),
             ),
       modelFeatures = modelFeatures == null
           ? null
           : List.unmodifiable(modelFeatures.map((f) => f.trim()).toList());

  /// The single backend handed to the inference engine: the highest-priority
  /// enabled backend per [backendPriority]. Returns null when no backends are
  /// configured (engine picks its own default).
  String? get effectiveBackendType {
    final types = backendTypes;
    if (types == null || types.isEmpty) return null;
    for (final backend in backendPriority) {
      if (types.contains(backend)) return backend;
    }
    return types.first;
  }

  /// Create a copy with updated values
  ModelConfig copyWith({
    String? id,
    ModelType? type,
    String? apiKey,
    String? endpoint,
    String? modelName,
    String? displayName,
    int? maxInputTokens,
    int? maxOutputTokens,
    ModelCapabilities? customCapabilitiesObject,
    List<String>? supportedAttachmentMimeTypes,
    List<String>? modelFeatures,
    bool? isConfigured,
    int? tokenWindow,
    bool? enableThinking,
    List<String>? backendTypes,
  }) {
    return ModelConfig(
      id: id ?? this.id,
      type: type ?? this.type,
      apiKey: apiKey ?? this.apiKey,
      endpoint: endpoint ?? this.endpoint,
      modelName: modelName ?? this.modelName,
      displayName: displayName ?? this.displayName,
      maxInputTokens: maxInputTokens ?? this.maxInputTokens,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      customCapabilitiesObject:
          customCapabilitiesObject ?? this.customCapabilitiesObject,
      supportedAttachmentMimeTypes:
          supportedAttachmentMimeTypes ?? this.supportedAttachmentMimeTypes,
      modelFeatures: modelFeatures ?? this.modelFeatures,
      isConfigured: isConfigured ?? this.isConfigured,
      tokenWindow: tokenWindow ?? this.tokenWindow,
      enableThinking: enableThinking ?? this.enableThinking,
      backendTypes: backendTypes ?? this.backendTypes,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.id,
      'apiKey': apiKey,
      'endpoint': endpoint,
      'modelName': modelName,
      'displayName': displayName,
      'maxInputTokens': maxInputTokens,
      'maxOutputTokens': maxOutputTokens,
      'customCapabilitiesObject': customCapabilitiesObject?.toJson(),
      'supportedAttachmentMimeTypes': supportedAttachmentMimeTypes,
      'modelFeatures': modelFeatures,
      'isConfigured': isConfigured,
      if (tokenWindow != null) 'token_window': tokenWindow,
      if (enableThinking != null) 'enable_thinking': enableThinking,
      if (backendTypes != null) 'backend_types': backendTypes,
    };
  }

  /// Create from JSON
  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    final type = ModelType.fromId(json['type'] as String) ?? ModelType.gemini;
    final capJson =
        json['customCapabilitiesObject'] as Map<String, dynamic>?;
    return ModelConfig(
      id: json['id'] as String?,
      type: type,
      apiKey: json['apiKey'] as String?,
      endpoint: json['endpoint'] as String?,
      modelName: json['modelName'] as String?,
      displayName: json['displayName'] as String?,
      maxInputTokens: json['maxInputTokens'] as int?,
      maxOutputTokens: json['maxOutputTokens'] as int?,
      customCapabilitiesObject: capJson != null
          ? ModelCapabilities.fromJson(
              capJson,
              defaultSupportsOrchestration: type != ModelType.localMnn,
            )
          : null,
      supportedAttachmentMimeTypes:
          (json['supportedAttachmentMimeTypes'] as List?)
              ?.whereType<String>()
              .toList(),
      modelFeatures: (json['modelFeatures'] as List?)
          ?.whereType<String>()
          .toList(),
      isConfigured: json['isConfigured'] as bool? ?? false,
      tokenWindow: json['token_window'] as int?,
      enableThinking: json['enable_thinking'] as bool?,
      backendTypes: _backendTypesFromJson(json),
    );
  }

  /// Reads the enabled backends, migrating the legacy single `backend_type`
  /// string into a one-element list when the new `backend_types` is absent.
  static List<String>? _backendTypesFromJson(Map<String, dynamic> json) {
    final list = (json['backend_types'] as List?)
        ?.whereType<String>()
        .toList();
    if (list != null) return list;
    final legacy = json['backend_type'] as String?;
    return legacy == null ? null : [legacy];
  }

  @override
  String toString() {
    return 'ModelConfig(id: $id, type: ${type.displayName}, configured: $isConfigured)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is ModelConfig &&
        other.id == id &&
        other.type == type &&
        other.apiKey == apiKey &&
        other.endpoint == endpoint &&
        other.modelName == modelName &&
        other.displayName == displayName &&
        other.maxInputTokens == maxInputTokens &&
        other.maxOutputTokens == maxOutputTokens &&
        other.customCapabilitiesObject == customCapabilitiesObject &&
        listEquals(
          other.supportedAttachmentMimeTypes,
          supportedAttachmentMimeTypes,
        ) &&
        listEquals(other.modelFeatures, modelFeatures) &&
        other.isConfigured == isConfigured;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        type.hashCode ^
        apiKey.hashCode ^
        endpoint.hashCode ^
        modelName.hashCode ^
        displayName.hashCode ^
        maxInputTokens.hashCode ^
        maxOutputTokens.hashCode ^
        customCapabilitiesObject.hashCode ^
        Object.hashAll(supportedAttachmentMimeTypes ?? const []) ^
        Object.hashAll(modelFeatures ?? const []) ^
        isConfigured.hashCode;
  }
}
