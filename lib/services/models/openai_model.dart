import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'ai_model.dart';
import '../attachment_preprocessor.dart';
import '../mcp_tool_integration_service.dart';
import '../model_storage_service.dart';
import '../service_locator.dart';
import '../logger_service.dart';
import '../prompts/prompt_models.dart';
import '../network_provider.dart';
import '../../models/mcp_endpoint.dart';
import '../../models/model_type.dart';
import '../../models/model_config.dart';
import '../../utils/file_type_utils.dart';
import '../../models/generation_context.dart';

/// OpenAI compatible model implementation
class OpenAIModel implements AIModel {
  ModelConfig? _config;

  @override
  String get id => _config?.type.id ?? ModelType.openaiCompatible.id;

  @override
  String get name =>
      _config?.displayName ?? ModelType.openaiCompatible.displayName;

  @override
  String get description =>
      'OpenAI compatible API endpoint with configurable capabilities';

  @override
  bool get usesNativeToolDeclarations => false;

  @override
  bool get supportsStreaming => false;

  @override
  Future<bool> isReady() async {
    try {
      if (_config == null) return false;
      final apiKey =
          _config?.apiKey ??
          await getIt<ModelStorageService>().getModelApiKey(_config!.id);
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
      LoggerService.debug(
        'OpenAI model initialized with provided config',
        error: {
          'modelName': config.modelName,
          'displayName': config.displayName,
          'supportsImages': config.customCapabilitiesObject?.supportsImages,
          'supportsDocuments':
              config.customCapabilitiesObject?.supportsDocuments,
          'supportsAudio': config.customCapabilitiesObject?.supportsAudio,
          'supportsVideo': config.customCapabilitiesObject?.supportsVideo,
        },
      );
    } else {
      // If no config provided, try to get the active model if it matches this type
      final activeModel = await getIt<ModelStorageService>().getActiveModel();
      if (activeModel?.type == ModelType.openaiCompatible) {
        _config = activeModel;
        LoggerService.debug(
          'OpenAI model initialized with active config',
          error: {
            'modelName': _config?.modelName,
            'displayName': _config?.displayName,
          },
        );
      }
    }

    if (_config == null) {
      throw Exception(
        'OpenAIModel: Configuration not provided and no active OpenAI model found',
      );
    }

    if (_config?.apiKey == null || _config!.apiKey!.isEmpty) {
      // Try to fetch from storage using ID
      final storedKey = await getIt<ModelStorageService>().getModelApiKey(_config!.id);
      if (storedKey != null && storedKey.isNotEmpty) {
        _config = _config!.copyWith(apiKey: storedKey);
      } else {
        throw Exception('OpenAI API key not configured');
      }
    }

    if (_config?.endpoint == null || _config!.endpoint!.isEmpty) {
      throw Exception('OpenAI endpoint not configured');
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
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final actualRequestId = context.ensureRequestId();
    return await _withErrorHandling('generation with attachments', () async {
      await initialize(config: _config);
      final sanitizedAttachments = await _sanitizeAttachments(
        attachedFiles,
        actualRequestId,
      );

      final messageContent = _buildMessageContentWithFiles(
        prompt,
        sanitizedAttachments,
      );

      final requestBody = <String, dynamic>{
        'model': _config!.modelName!,
        'messages': [
          {'role': 'user', 'content': messageContent},
        ],
        'temperature': 1.0,
        'max_completion_tokens':
            maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
      };

      return await _makeOpenAiRequest(requestBody, actualRequestId);
    }, requestId: actualRequestId);
  }

  @override
  Future<String> generateFromPrompt(
    PromptRequest request, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) {
    return generateWithMessages(
      request.buildFullMessageList(),
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: generationContext,
    );
  }

  @override
  Future<String> generateWithMessages(
    List<PromptMessage> messages, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final actualRequestId = context.ensureRequestId();
    return await _withErrorHandling('generation with messages', () async {
      await initialize(config: _config);
      final sanitizedMessages = await _sanitizeMessages(
        messages,
        actualRequestId,
      );

      final openaiMessages = await _convertMessagesToOpenAIFormat(
        sanitizedMessages,
      );

      final requestBody = <String, dynamic>{
        'model': _config!.modelName!,
        'messages': openaiMessages,
        'temperature': 1.0,
        'max_completion_tokens':
            maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
      };

      // Add model features if present
      final modelFeatures =
          context.getValue<List<String>>('modelFeatures') ?? [];
      if (modelFeatures.isNotEmpty) {
        for (final feature in modelFeatures) {
          if (feature == 'web_search') {
            requestBody['web_search_options'] = {};
          }
        }
      }

      return await _makeOpenAiRequest(requestBody, actualRequestId);
    }, requestId: actualRequestId);
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
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final actualRequestId = context.ensureRequestId();
    return await _withErrorHandling('generation with tools', () async {
      await initialize(config: _config);
      final sanitizedAttachments = await _sanitizeAttachments(
        attachedFiles,
        actualRequestId,
      );

      final messageContent = _buildMessageContent(prompt, sanitizedAttachments);

      final requestBody = {
        'model': _config!.modelName!,
        'messages': [
          {'role': 'user', 'content': messageContent},
        ],
        'temperature': 1.0,
        'max_completion_tokens':
            maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
      };

      if (tools.isNotEmpty) {
        requestBody['tools'] = tools
            .map((tool) => {'type': 'function', 'function': tool})
            .toList();
        requestBody['tool_choice'] = 'auto';
      }

      // Add model features if present
      final modelFeatures =
          context.getValue<List<String>>('modelFeatures') ?? [];
      if (modelFeatures.isNotEmpty) {
        for (final feature in modelFeatures) {
          if (feature == 'web_search') {
            requestBody['web_search_options'] = {};
          }
        }
      }

      return await _makeOpenAiRequestWithTools(requestBody, actualRequestId);
    }, requestId: actualRequestId);
  }

  @override
  List<Map<String, dynamic>> buildToolDeclarations(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    if (toolsByEndpoint.isEmpty) return [];
    return [
      McpToolIntegrationService.getCallToolFunctionForOpenAI(toolsByEndpoint),
    ];
  }

  @override
  Future<Map<String, dynamic>> generateWithToolsAndMessages(
    List<PromptMessage> messages,
    List<Map<String, dynamic>> tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final actualRequestId = context.ensureRequestId();
    return await _withErrorHandling(
      'generation with tools and messages',
      () async {
        await initialize(config: _config);
        final sanitizedMessages = await _sanitizeMessages(
          messages,
          actualRequestId,
        );

        final openaiMessages = await _convertMessagesToOpenAIFormat(
          sanitizedMessages,
        );

        final requestBody = <String, dynamic>{
          'model': _config!.modelName!,
          'messages': openaiMessages,
          'temperature': 1.0,
          'max_completion_tokens':
              maxOutputTokens ?? _config!.maxOutputTokens ?? 8192,
        };

        if (tools.isNotEmpty) {
          requestBody['tools'] = tools
              .map((tool) => {'type': 'function', 'function': tool})
              .toList();
          requestBody['tool_choice'] = 'auto';
        }

        // Add model features if present
        final modelFeatures =
            context.getValue<List<String>>('modelFeatures') ?? [];
        if (modelFeatures.isNotEmpty) {
          final toolsList = requestBody['tools'] as List<dynamic>? ?? [];
          for (final feature in modelFeatures) {
            if (feature == 'web_search') {
              toolsList.add({'type': 'web_search'});
            }
          }
          if (toolsList.isNotEmpty) {
            requestBody['tools'] = toolsList;
            // If we only have web_search, we might not need tool_choice auto, but it doesn't hurt
          }
        }

        return await _makeOpenAiRequestWithTools(requestBody, actualRequestId);
      },
      requestId: actualRequestId,
    );
  }

  /// Convert messages array to OpenAI format
  /// Handles system, user, and assistant roles
  /// Attachments are added to the first user message (documents should only be attached once)
  /// Today's context is added to the last user message (like Gemini)
  Future<List<Map<String, dynamic>>> _convertMessagesToOpenAIFormat(
    List<PromptMessage> messages,
  ) async {
    final openaiMessages = <Map<String, dynamic>>[];

    for (final message in messages) {
      switch (message.role) {
        case PromptRole.system:
          openaiMessages.add({'role': 'system', 'content': message.content});
          break;
        case PromptRole.user:
          final content = message.attachments.isEmpty
              ? message.content
              : _buildMessageContentWithFiles(
                  message.content,
                  message.attachments,
                );

          openaiMessages.add({'role': 'user', 'content': content});
          break;
        case PromptRole.assistant:
          final entry = <String, dynamic>{
            'role': 'assistant',
            'content': message.content,
          };

          final toolCallsWithResults =
              message.metadata?['tool_calls_with_results'] as List?;
          if (toolCallsWithResults != null && toolCallsWithResults.isNotEmpty) {
            entry['tool_calls'] = toolCallsWithResults.map((tcwr) {
              final fc = tcwr['function_call'] as Map<String, dynamic>;
              return {
                'id': tcwr['id'] as String,
                'type': 'function',
                'function': {
                  'name': fc['name'] as String,
                  'arguments': jsonEncode(fc['args'] ?? {}),
                },
              };
            }).toList();
          }

          openaiMessages.add(entry);
          break;
        case PromptRole.tool:
          final toolCallId =
              message.metadata?['tool_call_id'] as String? ??
              message.metadata?['id'] as String?;
          if (toolCallId != null) {
            openaiMessages.add({
              'role': 'tool',
              'tool_call_id': toolCallId,
              'content': message.content,
            });
          } else {
            LoggerService.warning(
              'Tool message missing tool_call_id, skipping',
            );
          }
          break;
      }
    }

    return openaiMessages;
  }

  // Private helper methods

  /// Build message content with attachments in OpenAI format
  /// Returns content (string or array of content parts)
  dynamic _buildMessageContentWithFiles(
    String prompt,
    List<PlatformFile> attachedFiles,
  ) {
    if (attachedFiles.isEmpty) {
      return prompt;
    }

    final capabilities = _config?.customCapabilitiesObject;
    if (capabilities == null) {
      LoggerService.debug(
        'OpenAI model: No capabilities configured, sending text only',
      );
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

      LoggerService.debug(
        'Processing file for attachment',
        error: {
          'fileName': fileName,
          'extension': extension,
          'category': category,
        },
      );

      // Check if the model supports this type of content AND the specific file format
      bool isSupported = false;
      String? attachmentType;

      if (category == 'image' &&
          capabilities.supportsImages &&
          capabilities.supportedImageFormats.contains(extension)) {
        isSupported = true;
        attachmentType = 'image';
      } else if (category == 'audio' &&
          capabilities.supportsAudio &&
          capabilities.supportedAudioFormats.contains(extension)) {
        isSupported = true;
        attachmentType = 'audio';
      } else if (category == 'document' &&
          capabilities.supportsDocuments &&
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
            'image_url': {'url': 'data:$mimeType;base64,$base64Data'},
          });

          LoggerService.debug(
            'Image attached',
            error: {
              'fileName': fileName,
              'mimeType': mimeType,
              'sizeBytes': file.bytes!.length,
            },
          );
        } else if (attachmentType == 'audio') {
          // OpenAI audio format (for models that support it)
          final base64Data = base64Encode(file.bytes!);
          final audioFormat = extension.replaceAll('.', '');

          contentParts.add({
            'type': 'input_audio',
            'input_audio': {'data': base64Data, 'format': audioFormat},
          });

          LoggerService.debug(
            'Audio attached',
            error: {
              'fileName': fileName,
              'format': audioFormat,
              'sizeBytes': file.bytes!.length,
            },
          );
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
            'file': {'filename': fileName, 'file_data': fileDataUri},
          });

          LoggerService.debug(
            'Document attached',
            error: {
              'fileName': fileName,
              'mimeType': mimeType,
              'sizeBytes': file.bytes!.length,
            },
          );
        }
      } else if (file.path != null &&
          (file.path!.startsWith('http') || file.path!.startsWith('gs://'))) {
        // Handle URI attachments
        final extension = FileTypeUtils.getFileExtension(file.name);
        final category = FileTypeUtils.getFileCategory(extension);

        supportedFiles.add(fileName);

        if (category == 'image') {
          contentParts.add({
            'type': 'image_url',
            'image_url': {'url': file.path},
          });
        } else {
          // For non-image files, use input_file with file_url
          contentParts.add({'type': 'input_file', 'file_url': file.path});
        }

        LoggerService.debug(
          'URI attachment added',
          error: {'fileName': fileName, 'category': category, 'uri': file.path},
        );
      } else {
        unsupportedFiles.add(fileName);
        unsupportedByType.putIfAbsent(category, () => []).add(fileName);
        LoggerService.debug(
          'File unsupported',
          error: {
            'fileName': fileName,
            'category': category,
            'reason': file.bytes == null ? 'no bytes' : 'unsupported type',
          },
        );
      }
    }

    // Build limitation note if there are unsupported files
    String limitationNote = '';
    if (unsupportedFiles.isNotEmpty) {
      final buffer = StringBuffer();
      buffer.writeln('\n\n--- MODEL LIMITATION NOTICE ---');
      buffer.writeln(
        'Note: This model has limited file processing capabilities.',
      );

      // List unsupported files by category
      unsupportedByType.forEach((category, files) {
        buffer.writeln(
          'The following $category files cannot be processed with respect to model limitation: ${files.join(', ')}',
        );
      });

      if (supportedFiles.isNotEmpty) {
        buffer.writeln(
          'The following files are available for processing: ${supportedFiles.join(', ')}',
        );
      }

      buffer.writeln(
        'Please provide your response based on the available information.',
      );
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
  dynamic _buildMessageContent(
    String prompt,
    List<PlatformFile> attachedFiles,
  ) {
    return _buildMessageContentWithFiles(prompt, attachedFiles);
  }

  Future<List<PlatformFile>> _sanitizeAttachments(
    List<PlatformFile> attachments,
    String requestId,
  ) async {
    if (attachments.isEmpty) {
      return attachments;
    }

    final outcome = await AttachmentPreprocessor.sanitizeAttachments(
      attachments,
      config: _config,
    );

    AttachmentPreprocessor.logIgnoredAttachments(
      outcome.ignored,
      endpoint: '${name} attachment_filter',
      requestId: requestId,
    );

    return outcome.attachments;
  }

  Future<List<PromptMessage>> _sanitizeMessages(
    List<PromptMessage> messages,
    String requestId,
  ) async {
    if (messages.isEmpty) {
      return messages;
    }

    final outcome = await AttachmentPreprocessor.sanitizeMessages(
      messages,
      config: _config,
    );

    AttachmentPreprocessor.logIgnoredAttachments(
      outcome.ignored,
      endpoint: '${name} attachment_filter',
      requestId: requestId,
    );

    return outcome.messages;
  }

  Future<T> _withErrorHandling<T>(
    String operation,
    Future<T> Function() operationFunction, {
    String? requestId,
  }) async {
    final actualRequestId =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();

    try {
      return await operationFunction();
    } catch (e) {
      LoggerService.error(
        'Error in $operation',
        error: {'error': e.toString(), 'requestId': actualRequestId},
      );
      rethrow;
    }
  }

  Future<String> _makeOpenAiRequest(
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

    final response = await NetworkProvider.post(
      Uri.parse(_config!.endpoint!),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_config!.apiKey}',
      },
      body: jsonEncode(requestBody),
    );

    final duration = DateTime.now().difference(startTime);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      LoggerService.logAiResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        responseBody: data,
        requestId: requestId,
        duration: duration,
      );
      if (data['choices'] != null && data['choices'].isNotEmpty) {
        final choice = data['choices'][0];
        final rawContent = choice['message']['content'];
        final textContent = _extractTextContent(rawContent);

        if (textContent != null && textContent.isNotEmpty) {
          LoggerService.debug(
            'OpenAI API request completed successfully',
            error: {
              'responseLength': textContent.length,
              'requestId': requestId,
              'duration': '${duration.inMilliseconds}ms',
            },
          );
          return textContent;
        }
      }
      LoggerService.error(
        'No content in OpenAI API response',
        error: {'responseData': data, 'requestId': requestId},
      );
      throw Exception('No content in OpenAI API response');
    } else {
      LoggerService.logAiResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        responseBody: response.body,
        requestId: requestId,
        duration: duration,
      );
      LoggerService.logAiError(
        error:
            'Failed to process request: ${response.statusCode} - ${response.body}',
        endpoint: _config!.endpoint!,
        requestId: requestId,
        duration: duration,
      );
      throw Exception(
        'Failed to process request: ${response.statusCode} - ${response.body}',
      );
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

    final response = await NetworkProvider.post(
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

        // Check for tool/function call (new OpenAI API)
        final toolCalls = message['tool_calls'] as List?;
        final functionCall = message['function_call'];
        final rawContent = message['content'];
        String? textContent = _extractTextContent(rawContent);

        if (toolCalls != null && toolCalls.isNotEmpty) {
          LoggerService.debug(
            'OpenAI API request completed with tool calls',
            error: {
              'toolCalls': toolCalls
                  .map((tc) => tc['function']?['name'])
                  .toList(),
              'requestId': requestId,
              'duration': '${duration.inMilliseconds}ms',
            },
          );

          final parsedCalls = toolCalls.map((tc) {
            final fn = tc['function'] as Map<String, dynamic>? ?? const {};
            final argsText = fn['arguments'] as String? ?? '{}';
            Map<String, dynamic> parsedArgs;
            try {
              parsedArgs = jsonDecode(argsText) as Map<String, dynamic>;
            } catch (_) {
              parsedArgs = {};
            }
            return {
              'name': fn['name'],
              'args': parsedArgs,
              'id':
                  tc['id'], // Preserve tool call ID for proper message threading
            };
          }).toList();

          return {
            'text': textContent,
            'function_calls': parsedCalls,
            'raw_data': data,
          };
        }

        if (functionCall != null) {
          // Legacy function_call fallback
          LoggerService.debug(
            'OpenAI API request completed with legacy function call',
            error: {
              'functionName': functionCall['name'],
              'requestId': requestId,
              'duration': '${duration.inMilliseconds}ms',
            },
          );

          Map<String, dynamic> parsedArgs;
          try {
            parsedArgs =
                jsonDecode(functionCall['arguments']) as Map<String, dynamic>;
          } catch (_) {
            parsedArgs = {};
          }

          return {
            'text': textContent,
            'function_calls': [
              {'name': functionCall['name'], 'args': parsedArgs},
            ],
            'raw_data': data,
          };
        }

        if (textContent != null && textContent.isNotEmpty) {
          LoggerService.debug(
            'OpenAI API request completed with text response',
            error: {
              'responseLength': textContent.length,
              'requestId': requestId,
              'duration': '${duration.inMilliseconds}ms',
            },
          );

          return {
            'text': textContent,
            'function_calls': null,
            'raw_data': data,
          };
        }
      }

      LoggerService.error(
        'No content in OpenAI API response',
        error: {'responseData': data, 'requestId': requestId},
      );
      throw Exception('No content in OpenAI API response');
    } else {
      LoggerService.logAiError(
        error:
            'Failed to process request: ${response.statusCode} - ${response.body}',
        endpoint: _config!.endpoint!,
        requestId: requestId,
        duration: duration,
      );
      throw Exception(
        'Failed to process request: ${response.statusCode} - ${response.body}',
      );
    }
  }
}

String? _extractTextContent(dynamic content) {
  if (content == null) {
    return null;
  }

  if (content is String) {
    return content;
  }

  if (content is List) {
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is Map<String, dynamic>) {
        final type = part['type']?.toString();
        if (type == null) {
          final text = part['text']?.toString();
          if (text != null) {
            buffer.write(text);
          }
          continue;
        }

        if (type == 'text' || type == 'output_text') {
          final text = part['text']?.toString();
          if (text != null) {
            buffer.write(text);
          }
        } else if (type == 'message' && part['content'] != null) {
          final nested = _extractTextContent(part['content']);
          if (nested != null) {
            buffer.write(nested);
          }
        }
      } else if (part is String) {
        buffer.write(part);
      }
    }

    final result = buffer.toString();
    return result.isEmpty ? null : result;
  }

  return content.toString();
}
