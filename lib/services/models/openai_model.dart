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
      
      // Build message content with attachments and limitation note
      final messageContent = _buildMessageContent(prompt + todayContext, attachedFiles);

      final requestBody = {
        'model': _config!.modelName!,
        'messages': [
          {'role': 'user', 'content': messageContent}
        ],
        'temperature': 1.0, // temperature is not supported by OpenAI, except 1.0
        'max_completion_tokens': maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
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
      
      // Build message content with attachments and limitation note
      final messageContent = _buildMessageContent(prompt + todayContext, attachedFiles);

      final requestBody = {
        'model': _config!.modelName!,
        'messages': [
          {'role': 'user', 'content': messageContent}
        ],
        'temperature': 1.0, // temperature is not supported by OpenAI, only 1.0 is used.
        'max_completion_tokens': maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
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


  /// Build message content with attachments in OpenAI format
  dynamic _buildMessageContent(String prompt, List<PlatformFile> attachedFiles) {
    if (attachedFiles.isEmpty) {
      return prompt;
    }

    final capabilities = _config?.customCapabilitiesObject;
    if (capabilities == null) {
      LoggerService.debug('OpenAI model: No capabilities configured, sending text only');
      return prompt;
    }

    final contentParts = <Map<String, dynamic>>[];
    final unsupportedFiles = <String>[];
    final supportedFiles = <String>[];
    final unsupportedByType = <String, List<String>>{};

    // Process each file
    for (final file in attachedFiles) {
      final fileName = file.name;
      final extension = FileTypeUtils.getFileExtension(fileName);
      final category = FileTypeUtils.getFileCategory(extension);
      
      LoggerService.debug('Processing file for attachment', error: {
        'fileName': fileName,
        'extension': extension,
        'category': category,
      });
      
      // Check if the model supports this type of content AND the specific file format
      bool isSupported = false;
      String? attachmentType;
      
      if (category == 'image' && capabilities.supportsImages && 
          capabilities.supportedImageFormats.contains(extension)) {
        isSupported = true;
        attachmentType = 'image';
      } else if (category == 'audio' && capabilities.supportsAudio && 
                 capabilities.supportedAudioFormats.contains(extension)) {
        isSupported = true;
        attachmentType = 'audio';
      } else if (category == 'document' && capabilities.supportsDocuments && 
                 capabilities.supportedDocumentFormats.contains(extension)) {
        // OpenAI doesn't support document attachments in the same way as images
        // Documents need to be extracted/processed separately
        isSupported = false;
      } else if (category == 'video' && capabilities.supportsVideo) {
        // OpenAI doesn't support video in the same way as images yet
        isSupported = false;
      }
      
      if (isSupported && file.bytes != null) {
        supportedFiles.add(fileName);
        
        // Attach file in OpenAI format
        if (attachmentType == 'image') {
          final base64Data = base64Encode(file.bytes!);
          final mimeType = FileTypeUtils.getMimeType(extension);
          
          contentParts.add({
            'type': 'image_url',
            'image_url': {
              'url': 'data:$mimeType;base64,$base64Data',
            }
          });
          
          LoggerService.debug('Image attached', error: {
            'fileName': fileName,
            'mimeType': mimeType,
            'sizeBytes': file.bytes!.length,
          });
        } else if (attachmentType == 'audio') {
          // OpenAI audio format (for models that support it)
          final base64Data = base64Encode(file.bytes!);
          final audioFormat = extension.replaceAll('.', '');
          
          contentParts.add({
            'type': 'input_audio',
            'input_audio': {
              'data': base64Data,
              'format': audioFormat,
            }
          });
          
          LoggerService.debug('Audio attached', error: {
            'fileName': fileName,
            'format': audioFormat,
            'sizeBytes': file.bytes!.length,
          });
        }
      } else {
        unsupportedFiles.add(fileName);
        unsupportedByType.putIfAbsent(category, () => []).add(fileName);
        LoggerService.debug('File unsupported', error: {
          'fileName': fileName,
          'category': category,
          'reason': file.bytes == null ? 'no bytes' : 'unsupported type',
        });
      }
    }

    // Build limitation note if there are unsupported files
    String limitationNote = '';
    if (unsupportedFiles.isNotEmpty) {
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
      
      limitationNote = buffer.toString();
    }

    // If no files were actually attached, return text only
    if (contentParts.isEmpty) {
      return prompt + limitationNote;
    }

    // Return array format with text and attachments
    return [
      {'type': 'text', 'text': prompt + limitationNote},
      ...contentParts,
    ];
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

