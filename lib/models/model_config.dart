import 'model_type.dart';
import 'model_capabilities.dart';

/// Configuration for a specific model
class ModelConfig {
  final ModelType type;
  final String? apiKey;
  final String? endpoint;
  final String? modelName;
  final Map<String, dynamic> customCapabilities;
  final ModelCapabilities? customCapabilitiesObject;
  final bool isConfigured;

  const ModelConfig({
    required this.type,
    this.apiKey,
    this.endpoint,
    this.modelName,
    this.customCapabilities = const {},
    this.customCapabilitiesObject,
    this.isConfigured = false,
  });

  /// Create a copy with updated values
  ModelConfig copyWith({
    ModelType? type,
    String? apiKey,
    String? endpoint,
    String? modelName,
    Map<String, dynamic>? customCapabilities,
    ModelCapabilities? customCapabilitiesObject,
    bool? isConfigured,
  }) {
    return ModelConfig(
      type: type ?? this.type,
      apiKey: apiKey ?? this.apiKey,
      endpoint: endpoint ?? this.endpoint,
      modelName: modelName ?? this.modelName,
      customCapabilities: customCapabilities ?? this.customCapabilities,
      customCapabilitiesObject: customCapabilitiesObject ?? this.customCapabilitiesObject,
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
      'customCapabilities': customCapabilities,
      'customCapabilitiesObject': customCapabilitiesObject?.toJson(),
      'isConfigured': isConfigured,
    };
  }

  /// Create from JSON
  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    return ModelConfig(
      type: ModelType.fromId(json['type'] as String) ?? ModelType.gemini25Flash,
      apiKey: json['apiKey'] as String?,
      endpoint: json['endpoint'] as String?,
      modelName: json['modelName'] as String?,
      customCapabilities: Map<String, dynamic>.from(json['customCapabilities'] ?? {}),
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelConfig &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          apiKey == other.apiKey &&
          endpoint == other.endpoint &&
          isConfigured == other.isConfigured;

  @override
  int get hashCode =>
      type.hashCode ^
      apiKey.hashCode ^
      endpoint.hashCode ^
      isConfigured.hashCode;
}
