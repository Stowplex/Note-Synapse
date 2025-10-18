import 'package:file_picker/file_picker.dart';
import 'model_capabilities.dart';

/// Base class for all model providers
abstract class ModelProvider {
  final String id;
  final String name;
  final String description;
  final ModelCapabilities capabilities;
  final bool requiresApiKey;
  final bool requiresDownload;
  final bool isConfigured;

  const ModelProvider({
    required this.id,
    required this.name,
    required this.description,
    required this.capabilities,
    this.requiresApiKey = false,
    this.requiresDownload = false,
    this.isConfigured = false,
  });

  /// Initialize the provider (e.g., download model, validate API key)
  Future<void> initialize();

  /// Check if the provider is ready to use
  Future<bool> isReady();

  /// Make a text-only request
  Future<String> generateText(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  });

  /// Make a request with file attachments
  Future<String> generateWithAttachments(
    String prompt,
    List<PlatformFile> attachedFiles, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  });

  /// Transcribe audio
  Future<String> transcribeAudio(String audioFilePath, {String? requestId});

  /// Summarize audio
  Future<String> summarizeAudio(String audioFilePath, {String? context, String? requestId});

  /// Extract content from image
  Future<Map<String, dynamic>> extractContentFromImage(String imagePath, {String? requestId});

  /// Extract content from PDF
  Future<Map<String, dynamic>> extractContentFromPdf(String pdfPath, {String? requestId});

  /// Extract content from text
  Future<Map<String, dynamic>> extractContentFromText(
    String text,
    String contentType,
    String title, {
    String? requestId,
  });

  /// Generate user app HTML
  Future<String> generateApp(String prompt, {String? requestId});

  /// Generate user app HTML with attachments
  Future<String> generateAppWithAttachments(
    String prompt,
    List<PlatformFile>? attachedFiles, {
    String? requestId,
  });

  /// Chat AI with configurable parameters
  Future<String> chatAI(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  });

  /// Validate that the model can handle the request based on capabilities
  bool canHandleRequest({
    List<PlatformFile>? attachedFiles,
    bool requiresImageSupport = false,
    bool requiresDocumentSupport = false,
    bool requiresAudioSupport = false,
    bool requiresVideoSupport = false,
  }) {
    if (requiresImageSupport && !capabilities.supportsImageInput) return false;
    if (requiresDocumentSupport && !capabilities.supportsDocumentInput) return false;
    if (requiresAudioSupport && !capabilities.supportsAudioInput) return false;
    if (requiresVideoSupport && !capabilities.supportsVideoInput) return false;

    if (attachedFiles != null && attachedFiles.isNotEmpty) {
      for (final file in attachedFiles) {
        final extension = file.name.split('.').last.toLowerCase();
        if (!capabilities.supportsFileType(extension)) return false;
      }
    }

    return true;
  }

  /// Get error message for unsupported capabilities
  String getCapabilityErrorMessage({
    List<PlatformFile>? attachedFiles,
    bool requiresImageSupport = false,
    bool requiresDocumentSupport = false,
    bool requiresAudioSupport = false,
    bool requiresVideoSupport = false,
  }) {
    final unsupported = <String>[];

    if (requiresImageSupport && !capabilities.supportsImageInput) {
      unsupported.add('image processing');
    }
    if (requiresDocumentSupport && !capabilities.supportsDocumentInput) {
      unsupported.add('document understanding');
    }
    if (requiresAudioSupport && !capabilities.supportsAudioInput) {
      unsupported.add('audio processing');
    }
    if (requiresVideoSupport && !capabilities.supportsVideoInput) {
      unsupported.add('video processing');
    }

    if (attachedFiles != null && attachedFiles.isNotEmpty) {
      final unsupportedFiles = <String>[];
      for (final file in attachedFiles) {
        final extension = file.name.split('.').last.toLowerCase();
        if (!capabilities.supportsFileType(extension)) {
          unsupportedFiles.add(extension);
        }
      }
      if (unsupportedFiles.isNotEmpty) {
        unsupported.add('file types: ${unsupportedFiles.join(', ')}');
      }
    }

    if (unsupported.isEmpty) return '';

    return 'This model ($name) does not support: ${unsupported.join(', ')}. '
           'Please switch to a different model or remove unsupported content.';
  }
}
