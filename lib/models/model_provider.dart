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

  /// Chat AI with configurable parameters
  Future<String> chatAI(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  });

}
