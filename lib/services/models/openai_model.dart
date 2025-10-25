import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'ai_model.dart';
import '../model_storage_service.dart';
import '../logger_service.dart';
import '../../models/model_type.dart';
import '../../models/model_config.dart';
import '../../utils/file_type_utils.dart';

/// OpenAI compatible model implementation
class OpenAIModel implements AIModel {
  ModelConfig? _config;

  @override
  String get id => _config?.type.id ?? ModelType.openaiCompatible.id;

  @override
  String get name => _config?.displayName ?? ModelType.openaiCompatible.displayName;

  @override
  String get description => 'OpenAI compatible API endpoint with configurable capabilities';

  @override
  Future<bool> isReady() async {
    try {
      final apiKey = _config?.apiKey ?? await ModelStorageService.getModelApiKey(ModelType.openaiCompatible);
      return apiKey != null && apiKey.isNotEmpty;
    } catch (e) {
      LoggerService.error('OpenAIModel: Error checking readiness: $e');
      return false;
    }
  }

  @override
  Future<void> initialize({ModelConfig? config}) async {
    if (config != null) {
      _config = config;
      LoggerService.debug('OpenAI model initialized with provided config', error: {
        'modelName': config.modelName,
        'displayName': config.displayName,
        'supportsImages': config.customCapabilitiesObject?.supportsImages,
        'supportsDocuments': config.customCapabilitiesObject?.supportsDocuments,
        'supportsAudio': config.customCapabilitiesObject?.supportsAudio,
        'supportsVideo': config.customCapabilitiesObject?.supportsVideo,
      });
    } else {
      _config = await ModelStorageService.getModelConfig(ModelType.openaiCompatible);
      LoggerService.debug('OpenAI model initialized with stored config', error: {
        'modelName': _config?.modelName,
        'displayName': _config?.displayName,
        'supportsImages': _config?.customCapabilitiesObject?.supportsImages,
        'supportsDocuments': _config?.customCapabilitiesObject?.supportsDocuments,
        'supportsAudio': _config?.customCapabilitiesObject?.supportsAudio,
        'supportsVideo': _config?.customCapabilitiesObject?.supportsVideo,
      });
    }

    if (_config?.endpoint == null || _config!.endpoint!.isEmpty) {
      throw Exception('OpenAI endpoint not configured');
    }
    if (_config?.apiKey == null || _config!.apiKey!.isEmpty) {
      throw Exception('OpenAI API key not configured');
    }
    if (_config?.modelName == null || _config!.modelName!.isEmpty) {
      throw Exception('OpenAI model name not configured');
    }
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
      await initialize(config: _config);

      // Add date context like Gemini model
      final todayContext = AIModel.getTodayContext();
      
      // Build limitation note for unsupported files
      final limitationNote = _buildLimitationNote(attachedFiles);
      final enhancedPrompt = prompt + todayContext + limitationNote;

      final requestBody = {
        'model': _config!.modelName!,
        'messages': [
          {'role': 'user', 'content': enhancedPrompt}
        ],
        'temperature': temperature ?? 0.7,
        'max_tokens': maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
      };

      return await _makeOpenAiRequest(requestBody, requestId ?? DateTime.now().millisecondsSinceEpoch.toString());
    });
  }

  @override
  Future<Map<String, dynamic>> generateWithTools(
    String prompt,
    List<PlatformFile> attachedFiles,
    List<Map<String, dynamic>> tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    return await _withErrorHandling('generation with tools', () async {
      await initialize(config: _config);

      // Add date context
      final todayContext = AIModel.getTodayContext();
      final limitationNote = _buildLimitationNote(attachedFiles);
      final enhancedPrompt = prompt + todayContext + limitationNote;

      final requestBody = {
        'model': _config!.modelName!,
        'messages': [
          {'role': 'user', 'content': enhancedPrompt}
        ],
        'temperature': temperature ?? 0.7,
        'max_tokens': maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
      };

      // Add tools/functions to request body
      if (tools.isNotEmpty) {
        requestBody['functions'] = tools;
        requestBody['function_call'] = 'auto';
      }

      return await _makeOpenAiRequestWithTools(
        requestBody,
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString(),
      );
    });
  }


  // Private helper methods


  /// Build a limitation note to inform the AI about unsupported features
  String _buildLimitationNote(List<PlatformFile> attachedFiles) {
    if (attachedFiles.isEmpty) {
      return '';
    }

    final capabilities = _config?.customCapabilitiesObject;
    if (capabilities == null) {
      LoggerService.debug('OpenAI model: No capabilities configured');
      return '';
    }

    LoggerService.debug('OpenAI model capabilities', error: {
      'supportsImages': capabilities.supportsImages,
      'supportsDocuments': capabilities.supportsDocuments,
      'supportsAudio': capabilities.supportsAudio,
      'supportsVideo': capabilities.supportsVideo,
      'supportedImageFormats': capabilities.supportedImageFormats,
      'supportedDocumentFormats': capabilities.supportedDocumentFormats,
      'supportedAudioFormats': capabilities.supportedAudioFormats,
      'modelName': _config?.modelName,
      'displayName': _config?.displayName,
    });

    final unsupportedFiles = <String>[];
    final supportedFiles = <String>[];
    final unsupportedByType = <String, List<String>>{};

    for (final file in attachedFiles) {
      final fileName = file.name;
      final extension = FileTypeUtils.getFileExtension(fileName);
      final category = FileTypeUtils.getFileCategory(extension);
      
      LoggerService.debug('Processing file', error: {
        'fileName': fileName,
        'extension': extension,
        'category': category,
      });
      
      // Check if the model supports this type of content AND the specific file format
      bool isSupported = false;
      if (category == 'image' && capabilities.supportsImages && capabilities.supportedImageFormats.contains(extension)) {
        isSupported = true;
      } else if (category == 'document' && capabilities.supportsDocuments && capabilities.supportedDocumentFormats.contains(extension)) {
        isSupported = true;
      } else if (category == 'audio' && capabilities.supportsAudio && capabilities.supportedAudioFormats.contains(extension)) {
        isSupported = true;
      } else if (category == 'video' && capabilities.supportsVideo) {
        isSupported = true;
      }
      
      if (isSupported) {
        supportedFiles.add(fileName);
        LoggerService.debug('File supported', error: {'fileName': fileName});
      } else {
        unsupportedFiles.add(fileName);
        unsupportedByType.putIfAbsent(category, () => []).add(fileName);
        LoggerService.debug('File unsupported', error: {'fileName': fileName, 'category': category});
      }
    }

    // Only add limitation notice if there are unsupported files
    if (unsupportedFiles.isEmpty) {
      LoggerService.debug('No unsupported files, no limitation notice needed');
      return '';
    }

    final buffer = StringBuffer();
    buffer.writeln('\n\n--- MODEL LIMITATION NOTICE ---');
    buffer.writeln('Note: This model has limited file processing capabilities.');

    // List unsupported files by category
    unsupportedByType.forEach((category, files) {
      buffer.writeln('The following $category files cannot be processed with respect to model limitation: ${files.join(', ')}');
    });

    if (supportedFiles.isNotEmpty) {
      buffer.writeln('The following files are available for processing: ${supportedFiles.join(', ')}');
    }

    buffer.writeln('Please provide your response based on the available information.');
    buffer.writeln('--- END NOTICE ---');

    return buffer.toString();
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
      endpoint: _config!.endpoint!,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_config!.apiKey}',
      },
      requestBody: requestBody,
      requestId: requestId,
    );

    final response = await http.post(
      Uri.parse(_config!.endpoint!),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_config!.apiKey}',
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
        endpoint: _config!.endpoint!,
        requestId: requestId,
        duration: duration,
      );
      throw Exception('Failed to process request: ${response.statusCode} - ${response.body}');
    }
  }

  Future<Map<String, dynamic>> _makeOpenAiRequestWithTools(
    Map<String, dynamic> requestBody,
    String requestId,
  ) async {
    final startTime = DateTime.now();

    LoggerService.logAiRequest(
      endpoint: _config!.endpoint!,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_config!.apiKey}',
      },
      requestBody: requestBody,
      requestId: requestId,
    );

    final response = await http.post(
      Uri.parse(_config!.endpoint!),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_config!.apiKey}',
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
        final message = choice['message'];

        // Check for function call
        final functionCall = message['function_call'];
        String? textContent = message['content'];

        if (functionCall != null) {
          // OpenAI returns function call in a different format than Gemini
          LoggerService.debug('OpenAI API request completed with function call', error: {
            'functionName': functionCall['name'],
            'requestId': requestId,
            'duration': '${duration.inMilliseconds}ms',
          });

          return {
            'text': textContent,
            'function_calls': [
              {
                'name': functionCall['name'],
                'args': jsonDecode(functionCall['arguments']),
              }
            ],
            'raw_data': data,
          };
        }

        // No function call, just text response
        if (textContent != null) {
          LoggerService.debug('OpenAI API request completed successfully', error: {
            'responseLength': textContent.length,
            'requestId': requestId,
            'duration': '${duration.inMilliseconds}ms',
          });

          return {
            'text': textContent,
            'function_calls': null,
            'raw_data': data,
          };
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
        endpoint: _config!.endpoint!,
        requestId: requestId,
        duration: duration,
      );
      throw Exception('Failed to process request: ${response.statusCode} - ${response.body}');
    }
  }
}
