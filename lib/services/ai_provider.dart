import 'package:file_picker/file_picker.dart';
import 'package:ai_clients/ai_clients.dart';
import '../models/note.dart';
import '../models/dedup_rule.dart';
import 'openai_compatible_provider.dart';

/// Abstract interface for AI providers using OpenAI-compatible APIs
abstract class AIProvider {
  /// Initialize the provider with configuration
  Future<void> initialize(AIProviderConfig config);
  
  /// Check if the provider is properly initialized
  bool get isInitialized;
  
  /// Get the AI client instance
  AiClient get client;
  
  /// Generate text completion with optional file attachments
  Future<String> generateText({
    required String prompt,
    List<PlatformFile>? attachedFiles,
    double? temperature,
    int? topK,
    double? topP,
    int? maxTokens,
    String? requestId,
  });
  
  /// Generate text completion with image
  Future<String> generateTextWithImage({
    required String prompt,
    required String base64Image,
    required String mimeType,
    double? temperature,
    int? topK,
    double? topP,
    int? maxTokens,
    String? requestId,
  });
  
  /// Answer questions based on note context
  Future<String> answerNoteQuestion({
    required String question,
    required List<Note> contextNotes,
    List<PlatformFile>? attachedFiles,
    bool useOwnKnowledge = false,
    String? requestId,
  });
  
  /// Transform a note based on a prompt
  Future<String> transformNote({
    required Note note,
    required String transformationPrompt,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  });
  
  /// Create new notes based on a prompt and context
  Future<List<Note>> createNewNotes({
    required String prompt,
    required List<Note> contextNotes,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  });
  
  /// Transcribe audio file
  Future<String> transcribeAudio({
    required String audioFilePath,
    String? requestId,
  });
  
  /// Summarize audio file
  Future<String> summarizeAudio({
    required String audioFilePath,
    String? context,
    String? requestId,
  });
  
  /// Extract content from text
  Future<Map<String, dynamic>> extractContentFromText({
    required String text,
    required String contentType,
    required String title,
    String? requestId,
  });
  
  /// Extract content from image
  Future<Map<String, dynamic>> extractContentFromImage({
    required String imagePath,
    String? requestId,
  });
  
  /// Extract content from PDF
  Future<Map<String, dynamic>> extractContentFromPdf({
    required String pdfPath,
    String? requestId,
  });
  
  /// Suggest deduplication rules for tags
  Future<List<DedupRule>> suggestDedupRules({
    required List<String> tagNames,
    String? requestId,
  });
  
  /// Generate user app HTML with attachments
  Future<String> generateAppWithAttachments({
    required String prompt,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  });
  
  /// Generate user app HTML
  Future<String> generateApp({
    required String prompt,
    String? requestId,
  });
  
  /// Chat AI with configurable parameters
  Future<String> chatAI({
    required String prompt,
    double? temperature,
    int? topK,
    double? topP,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  });
}

/// Configuration for AI providers using OpenAI-compatible APIs
class AIProviderConfig {
  final String apiKey;
  final String baseUrl;
  final String model;
  final Map<String, dynamic>? defaultGenerationConfig;
  final Map<String, dynamic>? creativeGenerationConfig;
  final Duration? timeout;
  final Map<String, String>? customHeaders;

  const AIProviderConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.defaultGenerationConfig,
    this.creativeGenerationConfig,
    this.timeout,
    this.customHeaders,
  });

  /// Create Gemini configuration using OpenAI-compatible endpoint
  factory AIProviderConfig.gemini({
    required String apiKey,
    String model = 'gemini-2.5-flash',
    Map<String, dynamic>? defaultGenerationConfig,
    Map<String, dynamic>? creativeGenerationConfig,
    Duration? timeout,
    Map<String, String>? customHeaders,
  }) {
    return AIProviderConfig(
      apiKey: apiKey,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      model: model,
      defaultGenerationConfig: defaultGenerationConfig,
      creativeGenerationConfig: creativeGenerationConfig,
      timeout: timeout,
      customHeaders: customHeaders,
    );
  }

  /// Create OpenAI configuration
  factory AIProviderConfig.openai({
    required String apiKey,
    String model = 'gpt-4o',
    String baseUrl = 'https://api.openai.com/v1',
    Map<String, dynamic>? defaultGenerationConfig,
    Map<String, dynamic>? creativeGenerationConfig,
    Duration? timeout,
    Map<String, String>? customHeaders,
  }) {
    return AIProviderConfig(
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      defaultGenerationConfig: defaultGenerationConfig,
      creativeGenerationConfig: creativeGenerationConfig,
      timeout: timeout,
      customHeaders: customHeaders,
    );
  }

  /// Create custom OpenAI-compatible configuration (e.g., for DeepSeek, Anthropic, etc.)
  factory AIProviderConfig.custom({
    required String apiKey,
    required String baseUrl,
    required String model,
    Map<String, dynamic>? defaultGenerationConfig,
    Map<String, dynamic>? creativeGenerationConfig,
    Duration? timeout,
    Map<String, String>? customHeaders,
  }) {
    return AIProviderConfig(
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      defaultGenerationConfig: defaultGenerationConfig,
      creativeGenerationConfig: creativeGenerationConfig,
      timeout: timeout,
      customHeaders: customHeaders,
    );
  }
}

/// Factory for creating AI providers
class AIProviderFactory {
  static AIProvider createProvider(AIProviderConfig config) {
    // All providers now use the same OpenAI-compatible implementation
    return OpenAICompatibleProvider(config);
  }
}

/// Supported AI provider types
enum AIProviderType {
  gemini,
  openai,
  custom,
}

