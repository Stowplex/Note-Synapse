/// Model capabilities define what features a model supports
class ModelCapabilities {
  final int maxInputTokens;
  final int maxOutputTokens;
  final bool supportsImages;
  final bool supportsDocuments;
  final bool supportsAudio;
  final bool supportsVideo;
  final bool supportsImageGeneration;
  final bool supportsCodeGeneration;
  final bool supportsToolOrchestration;
  final List<String> supportedImageFormats;
  final List<String> supportedDocumentFormats;
  final List<String> supportedAudioFormats;

  const ModelCapabilities({
    required this.maxInputTokens,
    required this.maxOutputTokens,
    required this.supportsImages,
    required this.supportsDocuments,
    required this.supportsAudio,
    required this.supportsVideo,
    this.supportsImageGeneration = false,
    this.supportsCodeGeneration = false,
    this.supportsToolOrchestration = true,
    this.supportedImageFormats = const ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    this.supportedDocumentFormats = const ['pdf', 'txt', 'doc', 'docx'],
    this.supportedAudioFormats = const ['mp3', 'wav', 'aac', 'm4a', 'ogg'],
  });

  /// Check if the model supports a specific file type
  bool supportsFileType(String extension) {
    final ext = extension.toLowerCase();
    return supportedImageFormats.contains(ext) ||
        supportedDocumentFormats.contains(ext) ||
        supportedAudioFormats.contains(ext);
  }

  /// Check if the model supports images
  bool get supportsImageInput => supportsImages;

  /// Check if the model supports document understanding
  bool get supportsDocumentInput => supportsDocuments;

  /// Check if the model supports audio processing
  bool get supportsAudioInput => supportsAudio;

  /// Check if the model supports video processing
  bool get supportsVideoInput => supportsVideo;

  /// Get a human-readable description of capabilities
  String get description {
    final capabilities = <String>[];

    capabilities.add('Max input: ${_formatTokens(maxInputTokens)}');
    capabilities.add('Max output: ${_formatTokens(maxOutputTokens)}');

    if (supportsImages) capabilities.add('Images');
    if (supportsDocuments) capabilities.add('Documents');
    if (supportsAudio) capabilities.add('Audio');
    if (supportsVideo) capabilities.add('Video');
    if (supportsImageGeneration) capabilities.add('Image Generation');
    if (supportsCodeGeneration) capabilities.add('Code Generation');
    if (supportsToolOrchestration) capabilities.add('Tool Orchestration');

    return capabilities.join(', ');
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(1)}M';
    } else if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}K';
    } else {
      return tokens.toString();
    }
  }

  @override
  String toString() => description;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelCapabilities &&
          runtimeType == other.runtimeType &&
          maxInputTokens == other.maxInputTokens &&
          maxOutputTokens == other.maxOutputTokens &&
          supportsImages == other.supportsImages &&
          supportsDocuments == other.supportsDocuments &&
          supportsAudio == other.supportsAudio &&
          supportsVideo == other.supportsVideo &&
          supportsImageGeneration == other.supportsImageGeneration &&
          supportsCodeGeneration == other.supportsCodeGeneration &&
          supportsToolOrchestration == other.supportsToolOrchestration;

  @override
  int get hashCode =>
      maxInputTokens.hashCode ^
      maxOutputTokens.hashCode ^
      supportsImages.hashCode ^
      supportsDocuments.hashCode ^
      supportsAudio.hashCode ^
      supportsVideo.hashCode ^
      supportsImageGeneration.hashCode ^
      supportsCodeGeneration.hashCode ^
      supportsToolOrchestration.hashCode;

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'maxInputTokens': maxInputTokens,
      'maxOutputTokens': maxOutputTokens,
      'supportsImages': supportsImages,
      'supportsDocuments': supportsDocuments,
      'supportsAudio': supportsAudio,
      'supportsVideo': supportsVideo,
      'supportsImageGeneration': supportsImageGeneration,
      'supportsCodeGeneration': supportsCodeGeneration,
      'supportsToolOrchestration': supportsToolOrchestration,
      'supportedImageFormats': supportedImageFormats,
      'supportedDocumentFormats': supportedDocumentFormats,
      'supportedAudioFormats': supportedAudioFormats,
    };
  }

  /// Create from JSON.
  ///
  /// [defaultSupportsOrchestration] controls the fallback when the
  /// `supportsToolOrchestration` key is absent (pre-existing saves).
  /// Pass `false` for local models so old configs default to unsupported.
  factory ModelCapabilities.fromJson(
    Map<String, dynamic> json, {
    bool defaultSupportsOrchestration = true,
  }) {
    return ModelCapabilities(
      maxInputTokens: json['maxInputTokens'] as int? ?? 100000,
      maxOutputTokens: json['maxOutputTokens'] as int? ?? 4000,
      supportsImages: json['supportsImages'] as bool? ?? false,
      supportsDocuments: json['supportsDocuments'] as bool? ?? false,
      supportsAudio: json['supportsAudio'] as bool? ?? false,
      supportsVideo: json['supportsVideo'] as bool? ?? false,
      supportsImageGeneration:
          json['supportsImageGeneration'] as bool? ?? false,
      supportsCodeGeneration: json['supportsCodeGeneration'] as bool? ?? false,
      supportsToolOrchestration:
          json['supportsToolOrchestration'] as bool? ??
          defaultSupportsOrchestration,
      supportedImageFormats: List<String>.from(
        json['supportedImageFormats'] ?? ['jpg', 'jpeg', 'png', 'gif', 'webp'],
      ),
      supportedDocumentFormats: List<String>.from(
        json['supportedDocumentFormats'] ?? ['pdf', 'txt', 'doc', 'docx'],
      ),
      supportedAudioFormats: List<String>.from(
        json['supportedAudioFormats'] ?? ['mp3', 'wav', 'aac', 'm4a', 'ogg'],
      ),
    );
  }
}
