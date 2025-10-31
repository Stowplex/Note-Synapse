import 'dart:convert';
import 'dart:typed_data';
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
      
      // Build message content with attachments and limitation note
      // Note: todayContext should be in system message, not here
      final messageContent = _buildMessageContentWithFiles(prompt, attachedFiles);

      final requestBody = <String, dynamic>{
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
  Future<String> generateWithMessages(
    List<Map<String, dynamic>> messages,
    List<PlatformFile> attachedFiles, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    return await _withErrorHandling('generation with messages', () async {
      await initialize(config: _config);

      // Convert messages array to OpenAI format
      final openaiMessages = await _convertMessagesToOpenAIFormat(messages, attachedFiles);

      final requestBody = <String, dynamic>{
        'model': _config!.modelName!,
        'messages': openaiMessages,
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
      
      // Build message content with attachments and limitation note
      // Note: todayContext should be in system message, not here
      final messageContent = _buildMessageContent(prompt, attachedFiles);

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

  @override
  Future<Map<String, dynamic>> generateWithToolsAndMessages(
    List<Map<String, dynamic>> messages,
    List<PlatformFile> attachedFiles,
    List<Map<String, dynamic>> tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    return await _withErrorHandling('generation with tools and messages', () async {
      await initialize(config: _config);

      // Convert messages array to OpenAI format
      final openaiMessages = await _convertMessagesToOpenAIFormat(messages, attachedFiles);

      final requestBody = <String, dynamic>{
        'model': _config!.modelName!,
        'messages': openaiMessages,
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

  /// Convert messages array to OpenAI format
  /// Handles system, user, and assistant roles
  /// Attachments are added to the first user message (documents should only be attached once)
  /// Today's context is added to the last user message (like Gemini)
  Future<List<Map<String, dynamic>>> _convertMessagesToOpenAIFormat(
    List<Map<String, dynamic>> messages,
    List<PlatformFile> attachedFiles,
  ) async {
    final openaiMessages = <Map<String, dynamic>>[];
    final todayContext = AIModel.getTodayContext();
    bool filesAttached = false;
    
    // Find the index of the last user message first
    int lastUserMessageIndex = -1;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        lastUserMessageIndex = i;
        break;
      }
    }
    
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final role = msg['role'] as String;
      final content = msg['content'] as String;
      
      // Determine if this is the first user message (where we attach files)
      final isFirstUserMessage = role == 'user' && !filesAttached;
      // Determine if this is the last user message (where we add todayContext)
      final isLastUserMessage = role == 'user' && i == lastUserMessageIndex;
      
      if (role == 'system') {
        // System messages are supported by OpenAI
        openaiMessages.add({
          'role': 'system',
          'content': content,
        });
      } else if (role == 'user') {
        // Add attachments to the first user message only (documents should only appear once)
        if (isFirstUserMessage && attachedFiles.isNotEmpty) {
          final messageContent = _buildMessageContentWithFiles(
            content + (isLastUserMessage ? todayContext : ''), 
            attachedFiles
          );
          openaiMessages.add({
            'role': 'user',
            'content': messageContent,
          });
          filesAttached = true; // Mark that files have been attached
        } else {
          openaiMessages.add({
            'role': 'user',
            'content': content + (isLastUserMessage ? todayContext : ''),
          });
        }
      } else if (role == 'assistant') {
        // Assistant messages are supported by OpenAI
        // Check if this assistant message has tool calls with results (for ID mapping)
        final toolCallsWithResults = msg['tool_calls_with_results'] as List?;
        if (toolCallsWithResults != null && toolCallsWithResults.isNotEmpty) {
          // Use the stored tool call IDs from the conversation
          openaiMessages.add({
            'role': 'assistant',
            'content': content,
            'tool_calls': toolCallsWithResults.map((tcwr) {
              final fc = tcwr['function_call'] as Map<String, dynamic>;
              return {
                'id': tcwr['id'] as String,
                'type': 'function',
                'function': {
                  'name': fc['name'] as String,
                  'arguments': jsonEncode(fc['args'] ?? {}),
                }
              };
            }).toList(),
          });
        } else {
          // Regular assistant message
          openaiMessages.add({
            'role': 'assistant',
            'content': content,
          });
        }
      } else if (role == 'tool') {
        // Tool role is for function call results in OpenAI
        // Must include tool_call_id to match the assistant's tool_call
        final toolCallId = msg['tool_call_id'] as String?;
        if (toolCallId != null) {
          openaiMessages.add({
            'role': 'tool',
            'tool_call_id': toolCallId,
            'content': content,
          });
        } else {
          // Fallback if tool_call_id is missing
          LoggerService.warning('Tool message missing tool_call_id, skipping');
        }
      }
    }
    
    return openaiMessages;
  }


  // Private helper methods


  /// Build message content with attachments in OpenAI format
  /// Returns content (string or array of content parts)
  dynamic _buildMessageContentWithFiles(String prompt, List<PlatformFile> attachedFiles) {
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
        // OpenAI supports document understanding via file_input parameter
        isSupported = true;
        attachmentType = 'document';
      } else if (category == 'video' && capabilities.supportsVideo) {
        // OpenAI doesn't support video in the same way as images yet
        isSupported = false;
      }
      
      if (isSupported && file.bytes != null) {
        supportedFiles.add(fileName);
        
        // Attach file in OpenAI format
        if (attachmentType == 'image') {
          final base64Data = base64Encode(file.bytes!);
          // Use content-based detection if extension is missing, otherwise trust extension
          final mimeType = FileTypeUtils.getMimeTypeForBytes(
            Uint8List.fromList(file.bytes!),
            extension: extension.isEmpty ? null : extension,
          );
          
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
        } else if (attachmentType == 'document') {
          // OpenAI document format - goes in content array with type "file"
          final base64Data = base64Encode(file.bytes!);
          final mimeType = FileTypeUtils.getMimeTypeForBytes(
            Uint8List.fromList(file.bytes!),
            extension: extension.isEmpty ? null : extension,
          );
          
          // Format as data URI: data:mime/type;base64,{base64data}
          final fileDataUri = 'data:$mimeType;base64,$base64Data';
          
          contentParts.add({
            'type': 'file',
            'file': {
              'filename': fileName,
              'file_data': fileDataUri,
            }
          });
          
          LoggerService.debug('Document attached', error: {
            'fileName': fileName,
            'mimeType': mimeType,
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

    // Build final content
    dynamic finalContent;
    if (contentParts.isEmpty) {
      finalContent = prompt + limitationNote;
    } else {
      finalContent = [
        {'type': 'text', 'text': prompt + limitationNote},
        ...contentParts,
      ];
    }

    return finalContent;
  }

  /// Build message content with attachments in OpenAI format (alias for backward compatibility)
  dynamic _buildMessageContent(String prompt, List<PlatformFile> attachedFiles) {
    return _buildMessageContentWithFiles(prompt, attachedFiles);
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

