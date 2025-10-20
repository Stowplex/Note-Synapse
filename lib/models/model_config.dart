import 'package:flutter/foundation.dart';
import 'model_type.dart';
import 'model_capabilities.dart';

/// Configuration for a specific model
class ModelConfig {
  final ModelType type;
  final String? apiKey;
  final String? endpoint;
  final String? modelName;
  final String? displayName;
  final int? maxInputTokens;
  final int? maxOutputTokens;
  final ModelCapabilities? customCapabilitiesObject;
  final bool isConfigured;

  const ModelConfig({
    required this.type,
    this.apiKey,
    this.endpoint,
    this.modelName,
    this.displayName,
    this.maxInputTokens,
    this.maxOutputTokens,
    ModelCapabilities? customCapabilitiesObject,
    this.isConfigured = false,
  }) : this.customCapabilitiesObject = customCapabilitiesObject ??
      const ModelCapabilities(
        maxInputTokens: 100000,
        maxOutputTokens: 4000,
        supportsImages: false,
        supportsDocuments: false,
        supportsAudio: false,
        supportsVideo: false,
      );

  /// Create a copy with updated values
  ModelConfig copyWith({
    ModelType? type,
    String? apiKey,
    String? endpoint,
    String? modelName,
    String? displayName,
    int? maxInputTokens,
    int? maxOutputTokens,
    ModelCapabilities? customCapabilitiesObject,
    bool? isConfigured,
  }) {
    return ModelConfig(
      type: type ?? this.type,
      apiKey: apiKey ?? this.apiKey,
      endpoint: endpoint ?? this.endpoint,
      modelName: modelName ?? this.modelName,
      displayName: displayName ?? this.displayName,
      maxInputTokens: maxInputTokens ?? this.maxInputTokens,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      customCapabilitiesObject:
          customCapabilitiesObject ?? this.customCapabilitiesObject,
      isConfigured: isConfigured ?? this.isConfigured,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'type': type.id,
      'apiKey': apiKey,
      'endpoint': endpoint,
      'modelName': modelName,
      'displayName': displayName,
      'maxInputTokens': maxInputTokens,
      'maxOutputTokens': maxOutputTokens,
      'customCapabilitiesObject': customCapabilitiesObject?.toJson(),
      'isConfigured': isConfigured,
    };
  }

  /// Create from JSON
  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    return ModelConfig(
      type: ModelType.fromId(json['type'] as String) ?? ModelType.gemini,
      apiKey: json['apiKey'] as String?,
      endpoint: json['endpoint'] as String?,
      modelName: json['modelName'] as String?,
      displayName: json['displayName'] as String?,
      maxInputTokens: json['maxInputTokens'] as int?,
      maxOutputTokens: json['maxOutputTokens'] as int?,
      customCapabilitiesObject: json['customCapabilitiesObject'] != null
          ? ModelCapabilities.fromJson(json['customCapabilitiesObject'])
          : null,
      isConfigured: json['isConfigured'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'ModelConfig(type: ${type.displayName}, configured: $isConfigured)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
  
    return other is ModelConfig &&
      other.type == type &&
      other.apiKey == apiKey &&
      other.endpoint == endpoint &&
      other.modelName == modelName &&
      other.displayName == displayName &&
      other.maxInputTokens == maxInputTokens &&
      other.maxOutputTokens == maxOutputTokens &&
      other.customCapabilitiesObject == customCapabilitiesObject &&
      other.isConfigured == isConfigured;
  }

  @override
  int get hashCode {
    return type.hashCode ^
      apiKey.hashCode ^
      endpoint.hashCode ^
      modelName.hashCode ^
      displayName.hashCode ^
      maxInputTokens.hashCode ^
      maxOutputTokens.hashCode ^
      customCapabilitiesObject.hashCode ^
      isConfigured.hashCode;
  }
}
