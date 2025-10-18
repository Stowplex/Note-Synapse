import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../../models/model_provider.dart';
import '../../models/model_capabilities.dart';
import '../../models/model_type.dart';
import '../model_storage_service.dart';
import '../logger_service.dart';

/// OpenAI compatible model provider that supports multiple configurable models
class OpenAiProvider extends ModelProvider {
  String? _endpoint;
  String? _apiKey;
  String? _modelName;
  ModelCapabilities? _customCapabilities;

  OpenAiProvider() : super(
    id: ModelType.openaiCompatible.id,
    name: ModelType.openaiCompatible.displayName,
    description: 'OpenAI compatible API endpoint with configurable capabilities',
    capabilities: const ModelCapabilities(
      maxInputTokens: 100000, // Default, can be overridden
      maxOutputTokens: 4000,  // Default, can be overridden
      supportsImages: false,  // Can be enabled via configuration
      supportsDocuments: false, // Can be enabled via configuration
      supportsAudio: false,   // Can be enabled via configuration
      supportsVideo: false,   // Can be enabled via configuration
    ),
    requiresApiKey: true,
  );

  @override
  Future<void> initialize() async {
    final config = await ModelStorageService.getModelConfig(ModelType.openaiCompatible);
    _endpoint = config.endpoint;
    _apiKey = await ModelStorageService.getModelApiKey(ModelType.openaiCompatible);
    _modelName = config.modelName;
    
    // Load custom capabilities if configured
    _customCapabilities = config.customCapabilitiesObject;
    
    if (_endpoint == null || _endpoint!.isEmpty) {
      throw Exception('OpenAI endpoint not configured');
    }
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('OpenAI API key not configured');
    }
    if (_modelName == null || _modelName!.isEmpty) {
      throw Exception('OpenAI model name not configured');
    }
  }

  @override
  Future<bool> isReady() async {
    try {
      final config = await ModelStorageService.getModelConfig(ModelType.openaiCompatible);
      final apiKey = await ModelStorageService.getModelApiKey(ModelType.openaiCompatible);
      return config.isConfigured && 
             config.endpoint != null && 
             config.endpoint!.isNotEmpty &&
             config.modelName != null &&
             config.modelName!.isNotEmpty &&
             apiKey != null && 
             apiKey.isNotEmpty;
    } catch (e) {
      LoggerService.error('OpenAiProvider: Error checking readiness: $e');
      return false;
    }
  }

  /// Get the effective capabilities (custom or default)
  ModelCapabilities get effectiveCapabilities {
    return _customCapabilities ?? capabilities;
  }

  /// Get the configured model name
  String get modelName => _modelName ?? 'unknown';

  @override
  Future<String> generateText(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    return await _withErrorHandling('text generation', () async {
      await _ensureInitialized();
      
      // Check if the request exceeds token limits
      final effectiveCapabilities = this.effectiveCapabilities;
      if (maxOutputTokens != null && maxOutputTokens > effectiveCapabilities.maxOutputTokens) {
        throw Exception('Requested output tokens ($maxOutputTokens) exceeds model limit (${effectiveCapabilities.maxOutputTokens})');
      }
      
      final requestBody = {
        'model': modelName,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
        'temperature': temperature ?? 0.7,
        'max_tokens': maxOutputTokens ?? effectiveCapabilities.maxOutputTokens,
      };

      return await _makeOpenAiRequest(requestBody, requestId ?? DateTime.now().millisecondsSinceEpoch.toString());
    });
  }

  @override
  Future<String> generateWithAttachments(
    String prompt,
    List<PlatformFile> attachedFiles, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    // Check if this model supports attachments
    final effectiveCapabilities = this.effectiveCapabilities;
    if (!effectiveCapabilities.supportsImages && !effectiveCapabilities.supportsDocuments) {
      throw Exception('This OpenAI model does not support file attachments');
    }
    
    return await generateText(
      prompt,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      requestId: requestId,
    );
  }

  @override
  Future<String> transcribeAudio(String audioFilePath, {String? requestId}) async {
    final effectiveCapabilities = this.effectiveCapabilities;
    if (!effectiveCapabilities.supportsAudio) {
      throw Exception('This OpenAI model does not support audio transcription');
    }
    
    return await _withErrorHandling('audio transcription', () async {
      await _ensureInitialized();
      
      // For now, return a message indicating this feature is not available
      // In a real implementation, this would use OpenAI's Whisper API or similar
      return 'Audio transcription is not yet implemented for this OpenAI model. Please use a different model or transcribe the audio manually.';
    });
  }

  @override
  Future<String> summarizeAudio(String audioFilePath, {String? context, String? requestId}) async {
    final effectiveCapabilities = this.effectiveCapabilities;
    if (!effectiveCapabilities.supportsAudio) {
      throw Exception('This OpenAI model does not support audio processing');
    }
    
    return await _withErrorHandling('audio summarization', () async {
      await _ensureInitialized();
      
      // For now, return a message indicating this feature is not available
      // In a real implementation, this would use OpenAI's Whisper API or similar
      return 'Audio summarization is not yet implemented for this OpenAI model. Please use a different model or process the audio manually.';
    });
  }

  @override
  Future<Map<String, dynamic>> extractContentFromImage(String imagePath, {String? requestId}) async {
    final effectiveCapabilities = this.effectiveCapabilities;
    if (!effectiveCapabilities.supportsImages) {
      throw Exception('This OpenAI model does not support image processing');
    }
    
    try {
      await _ensureInitialized();
      
      // For now, return a message indicating this feature is not available
      // In a real implementation, this would use OpenAI's vision models
      return {
        'success': false,
        'error': 'Image content extraction is not yet implemented for this OpenAI model. Please use a different model or process the image manually.',
      };
    } catch (e) {
      return <String, dynamic>{
        'success': false,
        'error': e.toString(),
      };
    }
  }

  @override
  Future<Map<String, dynamic>> extractContentFromPdf(String pdfPath, {String? requestId}) async {
    final effectiveCapabilities = this.effectiveCapabilities;
    if (!effectiveCapabilities.supportsDocuments) {
      throw Exception('This OpenAI model does not support document processing');
    }
    
    try {
      await _ensureInitialized();
      
      // For now, return a message indicating this feature is not available
      // In a real implementation, this would use OpenAI's document processing capabilities
      return {
        'success': false,
        'error': 'PDF content extraction is not yet implemented for this OpenAI model. Please use a different model or process the document manually.',
      };
    } catch (e) {
      return <String, dynamic>{
        'success': false,
        'error': e.toString(),
      };
    }
  }

  @override
  Future<Map<String, dynamic>> extractContentFromText(
    String text,
    String contentType,
    String title, {
    String? requestId,
  }) async {
    try {
      await _ensureInitialized();
      
      final prompt = _buildContentExtractionPrompt(text, contentType, title);
      final response = await generateText(prompt, requestId: requestId);

      return {
        'success': true,
        'content': response,
      };
    } catch (e) {
      return <String, dynamic>{
        'success': false,
        'error': e.toString(),
      };
    }
  }

  @override
  Future<String> generateApp(String prompt, {String? requestId}) async {
    return await generateText(prompt, requestId: requestId);
  }

  @override
  Future<String> generateAppWithAttachments(
    String prompt,
    List<PlatformFile>? attachedFiles, {
    String? requestId,
  }) async {
    return await generateWithAttachments(prompt, attachedFiles ?? [], requestId: requestId);
  }

  @override
  Future<String> chatAI(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  }) async {
    return await generateText(
      prompt,
      temperature: temperature,
      topK: topK,
      topP: topP,
      requestId: requestId,
    );
  }

  // Helper methods
  Future<void> _ensureInitialized() async {
    if (_endpoint == null || _apiKey == null) {
      await initialize();
    }
  }

  Future<T> _withErrorHandling<T>(
    String operation,
    Future<T> Function() operationFunction, {
    String? requestId,
  }) async {
    final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    try {
      return await operationFunction();
    } catch (e) {
      LoggerService.error('Error in $operation', error: {
        'error': e.toString(),
        'requestId': actualRequestId,
      });
      rethrow;
    }
  }

  Future<String> _makeOpenAiRequest(Map<String, dynamic> requestBody, String requestId) async {
    final startTime = DateTime.now();

    LoggerService.logAiRequest(
      endpoint: _endpoint!,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      requestBody: requestBody,
      requestId: requestId,
    );

    final response = await http.post(
      Uri.parse(_endpoint!),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode(requestBody),
    );
    
    final duration = DateTime.now().difference(startTime);

    LoggerService.logAiResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      responseBody: response.body,
      requestId: requestId,
      duration: duration,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['choices'] != null && data['choices'].isNotEmpty) {
        final choice = data['choices'][0];
        final content = choice['message']['content'];
        
        if (content != null) {
          LoggerService.debug('OpenAI API request completed successfully', error: {
            'responseLength': content.length,
            'requestId': requestId,
            'duration': '${duration.inMilliseconds}ms',
          });
          return content;
        }
      }
      LoggerService.error('No content in OpenAI API response', error: {
        'responseData': data,
        'requestId': requestId,
      });
      throw Exception('No content in OpenAI API response');
    } else {
      LoggerService.logAiError(
        error: 'Failed to process request: ${response.statusCode} - ${response.body}',
        endpoint: _endpoint!,
        requestId: requestId,
        duration: duration,
      );
      throw Exception('Failed to process request: ${response.statusCode} - ${response.body}');
    }
  }

  String _buildContentExtractionPrompt(String text, String contentType, String title) {
    return '''
Please analyze and extract the key content from this $contentType. 

Title: $title

Content:
$text

Please provide a well-structured summary that includes:
1. Main topics and themes
2. Key points and important information
3. Any actionable items or insights
4. Relevant context or background information

Format the response in a clear, organized manner that would be useful for note-taking and future reference.
''';
  }
}
