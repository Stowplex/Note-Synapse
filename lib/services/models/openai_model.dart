import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'ai_model.dart';
import '../model_storage_service.dart';
import '../logger_service.dart';
import '../../models/model_type.dart';
import '../../models/model_capabilities.dart';

/// OpenAI compatible model implementation
class OpenAIModel implements AIModel {
  String? _endpoint;
  String? _apiKey;
  String? _modelName;
  ModelCapabilities? _capabilities;

  @override
  String get id => ModelType.openaiCompatible.id;

  @override
  String get name => ModelType.openaiCompatible.displayName;

  @override
  String get description => 'OpenAI compatible API endpoint with configurable capabilities';

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
      LoggerService.error('OpenAIModel: Error checking readiness: $e');
      return false;
    }
  }

  @override
  Future<void> initialize() async {
    await _loadConfiguration();
  }

  /// Load configuration from storage
  Future<void> _loadConfiguration() async {
    final config = await ModelStorageService.getModelConfig(ModelType.openaiCompatible);
    _endpoint = config.endpoint;
    _apiKey = await ModelStorageService.getModelApiKey(ModelType.openaiCompatible);
    _modelName = config.modelName;
    
    // Load capabilities from config
    _capabilities = config.customCapabilitiesObject ?? _getDefaultCapabilities();
    
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

  /// Get default capabilities for OpenAI models
  ModelCapabilities _getDefaultCapabilities() {
    return const ModelCapabilities(
      maxInputTokens: 100000,
      maxOutputTokens: 4000,
      supportsImages: false,
      supportsDocuments: false,
      supportsAudio: false,
      supportsVideo: false,
      supportedImageFormats: [],
      supportedDocumentFormats: [],
      supportedAudioFormats: [],
    );
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
    return await _withErrorHandling('generation with attachments', () async {
      await _ensureInitialized();
      
      // Check if we can handle the request
      if (!canHandleRequest(attachedFiles: attachedFiles)) {
        final errorMessage = getCapabilityErrorMessage(attachedFiles: attachedFiles);
        LoggerService.warning('OpenAI model: $errorMessage');
        
        // Gracefully fail by informing the AI about the limitation
        final limitationNote = _buildLimitationNote(attachedFiles);
        final enhancedPrompt = prompt + limitationNote;
        
        final requestBody = {
          'model': _modelName!,
          'messages': [
            {'role': 'user', 'content': enhancedPrompt}
          ],
          'temperature': temperature ?? 0.7,
          'max_tokens': maxOutputTokens ?? 8192,
        };

        return await _makeOpenAiRequest(requestBody, requestId ?? DateTime.now().millisecondsSinceEpoch.toString());
      }
      
      // Add date context like Gemini model
      final todayContext = AIModel.getTodayContext();
      final enhancedPrompt = prompt + todayContext;
      
      final requestBody = {
        'model': _modelName!,
        'messages': [
          {'role': 'user', 'content': enhancedPrompt}
        ],
        'temperature': temperature ?? 0.7,
        'max_tokens': maxOutputTokens ?? 8192,
      };

      return await _makeOpenAiRequest(requestBody, requestId ?? DateTime.now().millisecondsSinceEpoch.toString());
    });
  }

  @override
  bool canHandleRequest({
    List<PlatformFile>? attachedFiles,
    bool requiresImageSupport = false,
    bool requiresDocumentSupport = false,
    bool requiresAudioSupport = false,
    bool requiresVideoSupport = false,
  }) {
    // Ensure capabilities are loaded
    if (_capabilities == null) {
      return false;
    }

    // Check file attachments
    if (attachedFiles != null && attachedFiles.isNotEmpty) {
      for (final file in attachedFiles) {
        final extension = file.name.split('.').last.toLowerCase();
        if (!_capabilities!.supportsFileType(extension)) {
          return false;
        }
      }
    }

    // Check specific capability requirements
    if (requiresImageSupport && !_capabilities!.supportsImages) {
      return false;
    }
    if (requiresDocumentSupport && !_capabilities!.supportsDocuments) {
      return false;
    }
    if (requiresAudioSupport && !_capabilities!.supportsAudio) {
      return false;
    }
    if (requiresVideoSupport && !_capabilities!.supportsVideo) {
      return false;
    }

    return true;
  }

  @override
  String getCapabilityErrorMessage({
    List<PlatformFile>? attachedFiles,
    bool requiresImageSupport = false,
    bool requiresDocumentSupport = false,
    bool requiresAudioSupport = false,
    bool requiresVideoSupport = false,
  }) {
    if (_capabilities == null) {
      return 'Model capabilities not loaded. Please check your configuration.';
    }

    final modelName = _modelName ?? 'this OpenAI model';
    final unsupportedFeatures = <String>[];
    final unsupportedFiles = <String>[];

    // Check file attachments
    if (attachedFiles != null && attachedFiles.isNotEmpty) {
      for (final file in attachedFiles) {
        final extension = file.name.split('.').last.toLowerCase();
        if (!_capabilities!.supportsFileType(extension)) {
          unsupportedFiles.add('.$extension');
        }
      }
    }

    // Check specific capability requirements
    if (requiresImageSupport && !_capabilities!.supportsImages) {
      unsupportedFeatures.add('image processing');
    }
    if (requiresDocumentSupport && !_capabilities!.supportsDocuments) {
      unsupportedFeatures.add('document processing');
    }
    if (requiresAudioSupport && !_capabilities!.supportsAudio) {
      unsupportedFeatures.add('audio processing');
    }
    if (requiresVideoSupport && !_capabilities!.supportsVideo) {
      unsupportedFeatures.add('video processing');
    }

    // Build error message
    final errorParts = <String>[];
    
    if (unsupportedFiles.isNotEmpty) {
      errorParts.add('${modelName} does not support file types: ${unsupportedFiles.join(', ')}');
    }
    
    if (unsupportedFeatures.isNotEmpty) {
      errorParts.add('${modelName} does not support ${unsupportedFeatures.join(', ')}');
    }

    if (errorParts.isEmpty) {
      return 'Unknown capability error';
    }

    return errorParts.join('. ') + '. Please configure a different model or update the model capabilities.';
  }

  // Private helper methods

  /// Build a limitation note to inform the AI about unsupported features
  String _buildLimitationNote(List<PlatformFile> attachedFiles) {
    if (attachedFiles.isEmpty) {
      return '';
    }

    final unsupportedFiles = <String>[];
    final supportedFiles = <String>[];

    for (final file in attachedFiles) {
      final extension = file.name.split('.').last.toLowerCase();
      if (_capabilities?.supportsFileType(extension) == true) {
        supportedFiles.add(file.name);
      } else {
        unsupportedFiles.add(file.name);
      }
    }

    final buffer = StringBuffer();
    buffer.writeln('\n\n--- MODEL LIMITATION NOTICE ---');
    buffer.writeln('Note: This model has limited file processing capabilities.');
    
    if (unsupportedFiles.isNotEmpty) {
      buffer.writeln('The following files cannot be processed: ${unsupportedFiles.join(', ')}');
      buffer.writeln('Please work with the text content only and mention that these files were not accessible.');
    }
    
    if (supportedFiles.isNotEmpty) {
      buffer.writeln('The following files are available for processing: ${supportedFiles.join(', ')}');
    }
    
    buffer.writeln('Please provide your response based on the available information.');
    buffer.writeln('--- END NOTICE ---');
    
    return buffer.toString();
  }

  Future<void> _ensureInitialized() async {
    // Always reload configuration to get latest settings
    await _loadConfiguration();
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

}
