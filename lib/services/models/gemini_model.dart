import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'ai_model.dart';
import '../attachment_preprocessor.dart';
import '../model_storage_service.dart';
import '../logger_service.dart';
import '../prompts/prompt_models.dart';
import '../../models/model_type.dart';
import '../../models/model_config.dart';
import '../../utils/file_type_utils.dart';
import '../../models/generation_context.dart';

/// Gemini model implementation
class GeminiModel implements AIModel {
  ModelConfig? _config;

  @override
  String get id => _config?.type.id ?? ModelType.gemini.id;

  @override
  String get name => _config?.displayName ?? ModelType.gemini.displayName;

  @override
  String get description =>
      'Google\'s Gemini model with full multimodal capabilities';

  @override
  Future<bool> isReady() async {
    try {
      final apiKey = _config?.apiKey ?? await ModelStorageService.getModelApiKey(ModelType.gemini);
      return apiKey != null && apiKey.isNotEmpty;
    } catch (e) {
      LoggerService.error('GeminiModel: Error checking readiness: $e');
      return false;
    }
  }

  @override
  Future<void> initialize({ModelConfig? config}) async {
    if (config != null) {
      _config = config;
    } else {
      _config = await ModelStorageService.getModelConfig(ModelType.gemini);
    }

    if (_config?.apiKey == null || _config!.apiKey!.isEmpty) {
      throw Exception('Gemini API key not configured');
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
    return await _withErrorHandling(
      'generation with attachments',
      () async {
        final apiKey = await _validateApiKey(requestId: actualRequestId);

        final generationConfig = {
          'temperature': 1.0, // Gemini 3 recommends temperature to be at 1.0
          'topK': topK ?? 32,
          'topP': topP ?? 1,
          'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
        };

        final sanitizedAttachments = await _sanitizeAttachments(
          attachedFiles,
          actualRequestId,
        );

        return await _makeGeminiRequest(
          apiKey,
          prompt,
          attachedFiles: sanitizedAttachments,
          generationConfig: generationConfig,
          requestId: actualRequestId,
        );
      },
      requestId: actualRequestId,
    );
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
    return await _withErrorHandling(
      'generation with messages',
      () async {
        final apiKey = await _validateApiKey(requestId: actualRequestId);

        final generationConfig = {
          'temperature': 1.0, // temperature ?? 0.1,
          'topK': topK ?? 32,
          'topP': topP ?? 1,
          'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
        };

        final sanitizedMessages = await _sanitizeMessages(
          messages,
          actualRequestId,
        );

        // Convert messages array to Gemini format
        final requestBody = _buildRequestBodyFromMessages(
          sanitizedMessages,
          generationConfig: generationConfig,
        );

        return await _makeRequest(
          apiKey,
          requestBody,
          requestId: actualRequestId,
        );
      },
      requestId: actualRequestId,
    );
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
    return await _withErrorHandling(
      'generation with tools',
      () async {
        final apiKey = await _validateApiKey(requestId: actualRequestId);

        final generationConfig = {
          'temperature': 1.0, // temperature ?? 0.1, Tools must be at temperature 1.0 or it may fail.
          'topK': topK ?? 32,
          'topP': topP ?? 1,
          'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
        };

        final sanitizedAttachments = await _sanitizeAttachments(
          attachedFiles,
          actualRequestId,
        );

        return await _makeGeminiRequestWithTools(
          apiKey,
          prompt,
          tools,
          attachedFiles: sanitizedAttachments,
          generationConfig: generationConfig,
          requestId: actualRequestId,
        );
      },
      requestId: actualRequestId,
    );
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
        final apiKey = await _validateApiKey(requestId: actualRequestId);

        final generationConfig = {
          'temperature': 1.0, // tools require temperature at 1.0
          'topK': topK ?? 32,
          'topP': topP ?? 1,
          'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
        };

        final sanitizedMessages = await _sanitizeMessages(
          messages,
          actualRequestId,
        );

        // Convert messages array to Gemini format
        final requestBody = _buildRequestBodyFromMessages(
          sanitizedMessages,
          generationConfig: generationConfig,
        );

        // Add tools to request body
        if (tools.isNotEmpty) {
          requestBody['tools'] = [
            {'function_declarations': tools}
          ];
        }

        // Make request and get raw response
        return await _makeRequestWithRawResponse(
          apiKey,
          requestBody,
          requestId: actualRequestId,
        );
      },
      requestId: actualRequestId,
    );
  }

  /// Build request body from prompt messages.
  Map<String, dynamic> _buildRequestBodyFromMessages(
    List<PromptMessage> messages, {
    Map<String, dynamic>? generationConfig,
  }) {
    final contents = <Map<String, dynamic>>[];
    final systemMessages = <String>[];

    for (final message in messages) {
      switch (message.role) {
        case PromptRole.system:
          if (message.content.trim().isNotEmpty) {
            systemMessages.add(message.content.trim());
          }
          break;
        case PromptRole.user:
          // Check if this is a function response (tool result)
          if (message.metadata != null && message.metadata!['function_name'] != null) {
            final functionName = message.metadata!['function_name'] as String;
            
            // Parse the tool result content to extract the actual result
            // Format: "Tool: service.tool\nResult: actual_result" or "Tool: service.tool\nError: error_msg"
            final content = message.content;
            final resultMatch = RegExp(r'Result:\s*(.+)', dotAll: true).firstMatch(content);
            final errorMatch = RegExp(r'Error:\s*(.+)', dotAll: true).firstMatch(content);
            
            final responseData = <String, dynamic>{};
            if (resultMatch != null) {
              responseData['result'] = resultMatch.group(1)?.trim() ?? '';
            } else if (errorMatch != null) {
              responseData['error'] = errorMatch.group(1)?.trim() ?? '';
            } else {
              responseData['result'] = content;
            }
            
            final functionResponse = <String, dynamic>{
              'name': functionName,
              'response': responseData,
            };

            contents.add({
              'role': 'user',
              'parts': [
                {
                  'functionResponse': functionResponse,
                }
              ],
            });
          } else {
            // Regular user message with optional attachments
            final parts = <Map<String, dynamic>>[
              {'text': message.content},
            ];

            if (message.attachments.isNotEmpty) {
              for (final file in message.attachments) {
                final bytes = _readPlatformFileBytes(file);
                if (bytes == null) continue;

                final extension = FileTypeUtils.getFileExtension(file.name);
                final mimeType = FileTypeUtils.getMimeTypeForBytes(
                  bytes,
                  extension: extension.isEmpty ? null : extension,
                );

                parts.add({
                  'inline_data': {
                    'mime_type': mimeType,
                    'data': base64Encode(bytes),
                  }
                });
              }
            }

            contents.add({
              'role': 'user',
              'parts': parts,
            });
          }
          break;
        case PromptRole.assistant:
          final parts = <Map<String, dynamic>>[];
          
          // Add text content if present
          if (message.content.trim().isNotEmpty) {
            parts.add({'text': message.content});
          }
          
          // Add function calls if present in metadata
          if (message.metadata != null && message.metadata!['function_calls'] != null) {
            final functionCalls = message.metadata!['function_calls'] as List;
            for (final functionCall in functionCalls) {
              if (functionCall is Map<String, dynamic>) {
                final callData = Map<String, dynamic>.from(functionCall);
                final thoughtSignature =
                    callData.remove('thoughtSignature') ?? callData.remove('thought_signature');
                final part = <String, dynamic>{'functionCall': callData};
                if (thoughtSignature != null) {
                  part['thoughtSignature'] = thoughtSignature;
                }
                parts.add(part);
              } else {
                parts.add({'functionCall': functionCall});
              }
            }
          }
          
          contents.add({
            'role': 'model',
            'parts': parts,
          });
          break;
        case PromptRole.tool:
          // For Gemini, tool results should use functionResponse format
          // Check if we have function metadata to construct proper response
          if (message.metadata != null && message.metadata!['function_name'] != null) {
            final functionName = message.metadata!['function_name'] as String;
            
            // Parse the tool result content to extract the actual result
            // Format: "Tool: service.tool\nResult: actual_result" or "Tool: service.tool\nError: error_msg"
            final content = message.content;
            final resultMatch = RegExp(r'Result:\s*(.+)', dotAll: true).firstMatch(content);
            final errorMatch = RegExp(r'Error:\s*(.+)', dotAll: true).firstMatch(content);
            
            final responseData = <String, dynamic>{};
            if (resultMatch != null) {
              responseData['result'] = resultMatch.group(1)?.trim() ?? '';
            } else if (errorMatch != null) {
              responseData['error'] = errorMatch.group(1)?.trim() ?? '';
            } else {
              responseData['result'] = content;
            }
            
            contents.add({
              'role': 'user',
              'parts': [
                {
                  'functionResponse': {
                    'name': functionName,
                    'response': responseData,
                  }
                }
              ],
            });
          } else {
            // Fallback to text format if no metadata
            contents.add({
              'role': 'user',
              'parts': [
                {
                  'text': 'Tool result:\n${message.content}',
                }
              ],
            });
          }
          break;
      }
    }

    final requestBody = <String, dynamic>{
      'contents': contents,
      'generationConfig': generationConfig ??
          {
            'temperature': 1.0, // 0.1,
            'topK': 32,
            'topP': 1,
            'maxOutputTokens': _config?.maxOutputTokens ?? 65536,
          },
    };

    if (systemMessages.isNotEmpty) {
      requestBody['systemInstruction'] = {
        'parts': [
          {'text': systemMessages.join('\n\n')},
        ],
      };
    }

    return requestBody;
  }

  Uint8List? _readPlatformFileBytes(PlatformFile file) {
    if (file.bytes != null) {
      return Uint8List.fromList(file.bytes!);
    }

    if (file.path != null) {
      try {
        final bytes = File(file.path!).readAsBytesSync();
        return Uint8List.fromList(bytes);
      } catch (e) {
        LoggerService.warning('GeminiModel: failed to read attachment ${file.path}: $e');
      }
    }

    return null;
  }


  // Private helper methods


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
      LoggerService.error('Error in $operation', error: {
        'error': e.toString(),
        'requestId': actualRequestId,
      });
      rethrow;
    }
  }

  Future<String> _validateApiKey({String? requestId}) async {
    final apiKey = _config?.apiKey;
    if (apiKey == null) {
      LoggerService.error('API key not found', error: {'requestId': requestId});
      throw Exception('API key not found');
    }
    return apiKey;
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

  Map<String, dynamic> _buildRequestBody(
    String prompt,
    List<PlatformFile> attachedFiles, {
    Map<String, dynamic>? generationConfig,
    List<Map<String, String>>? safetySettings,
  }) {
    final parts = <Map<String, dynamic>>[{'text': prompt}];

    // Add file attachments if any
    if (attachedFiles.isNotEmpty) {
      for (final file in attachedFiles) {
        if (file.bytes != null) {
          final base64Data = base64Encode(file.bytes!);
          final extension = FileTypeUtils.getFileExtension(file.name);
          // Always use content-based detection (more reliable than extension)
          // Content detection will validate extension if provided
          final mimeType = FileTypeUtils.getMimeTypeForBytes(
            Uint8List.fromList(file.bytes!),
            extension: extension.isEmpty ? null : extension,
          );

          parts.add({
            'inline_data': {
              'mime_type': mimeType,
              'data': base64Data,
            }
          });
        }
      }
    }

    final requestBody = {
      'contents': [
        {'parts': parts}
      ],
      'generationConfig': generationConfig ??
          {
            'temperature': 1.0, // 0.1,
            'topK': 32,
            'topP': 1,
            'maxOutputTokens': _config?.maxOutputTokens ?? 65536,
          },
    };

    if (safetySettings != null) {
      requestBody['safetySettings'] = safetySettings;
    }

    return requestBody;
  }

  Future<String> _makeRequest(
    String apiKey,
    Map<String, dynamic> requestBody, {
    String? requestId,
  }) async {
    final actualRequestId =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();

    final endpoint = _config?.endpoint ?? 'https://generativelanguage.googleapis.com/v1beta';
    final modelName = _config?.modelName ?? 'gemini-2.5-flash';

    LoggerService.logAiRequest(
      endpoint: '$endpoint/models/$modelName:generateContent',
      headers: {'Content-Type': 'application/json'},
      requestBody: requestBody,
      requestId: actualRequestId,
    );

    final response = await http.post(
      Uri.parse('$endpoint/models/$modelName:generateContent?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requestBody),
    );

    final duration = DateTime.now().difference(startTime);

    LoggerService.logAiResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      responseBody: response.body,
      requestId: actualRequestId,
      duration: duration,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['candidates'] != null && data['candidates'].isNotEmpty) {
        final candidate = data['candidates'][0];
        final content = candidate['content'];

        if (content is Map<String, dynamic>) {
          final parts = content['parts'];
          if (parts is List && parts.isNotEmpty) {
            final buffer = StringBuffer();

            for (final part in parts) {
              if (part is Map<String, dynamic>) {
                final text = part['text'];
                if (text is String && text.isNotEmpty) {
                  buffer.write(text);
                }
              } else if (part is String && part.isNotEmpty) {
                buffer.write(part);
              }
            }

            final responseText = buffer.toString();
            if (responseText.isNotEmpty) {
              LoggerService.debug('Gemini API request completed successfully', error: {
                'responseLength': responseText.length,
                'requestId': actualRequestId,
                'duration': '${duration.inMilliseconds}ms',
              });
              return responseText;
            }
          }
        }
      }
      LoggerService.error('No content in Gemini API response', error: {
        'responseData': data,
        'requestId': actualRequestId,
      });
      throw Exception('No content in Gemini API response');
    } else {
      LoggerService.logAiError(
        error:
            'Failed to process request: ${response.statusCode} - ${response.body}',
        endpoint: '$endpoint/models/$modelName:generateContent',
        requestId: actualRequestId,
        duration: duration,
      );
      throw Exception(
          'Failed to process request: ${response.statusCode} - ${response.body}');
    }
  }

  Future<String> _makeGeminiRequest(
    String apiKey,
    String prompt, {
    List<PlatformFile> attachedFiles = const [],
    Map<String, dynamic>? generationConfig,
    List<Map<String, String>>? safetySettings,
    String? requestId,
  }) async {
    final requestBody = _buildRequestBody(
      prompt,
      attachedFiles,
      generationConfig: generationConfig,
      safetySettings: safetySettings,
    );

    return await _makeRequest(apiKey, requestBody, requestId: requestId);
  }

  Future<Map<String, dynamic>> _makeGeminiRequestWithTools(
    String apiKey,
    String prompt,
    List<Map<String, dynamic>> tools, {
    List<PlatformFile> attachedFiles = const [],
    Map<String, dynamic>? generationConfig,
    String? requestId,
  }) async {
    final actualRequestId =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    final requestBody = _buildRequestBody(
      prompt,
      attachedFiles,
      generationConfig: generationConfig,
    );

    // Add tools to request body
    if (tools.isNotEmpty) {
      requestBody['tools'] = [
        {'function_declarations': tools}
      ];
    }

    // Make request and get raw response
    return await _makeRequestWithRawResponse(
      apiKey,
      requestBody,
      requestId: actualRequestId,
    );
  }

  Future<Map<String, dynamic>> _makeRequestWithRawResponse(
    String apiKey,
    Map<String, dynamic> requestBody, {
    String? requestId,
  }) async {
    final actualRequestId =
        requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();

    final endpoint = _config?.endpoint ?? 'https://generativelanguage.googleapis.com/v1beta';
    final modelName = _config?.modelName ?? 'gemini-2.5-flash';

    LoggerService.logAiRequest(
      endpoint: '$endpoint/models/$modelName:generateContent',
      headers: {'Content-Type': 'application/json'},
      requestBody: requestBody,
      requestId: actualRequestId,
    );

    final response = await http.post(
      Uri.parse('$endpoint/models/$modelName:generateContent?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requestBody),
    );

    final duration = DateTime.now().difference(startTime);

    LoggerService.logAiResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      responseBody: response.body,
      requestId: actualRequestId,
      duration: duration,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['candidates'] != null && data['candidates'].isNotEmpty) {
        final candidate = data['candidates'][0];
        final content = candidate['content'];

        if (content is Map<String, dynamic>) {
          final parts = content['parts'];
          if (parts is List && parts.isNotEmpty) {
            final functionCalls = <Map<String, dynamic>>[];
            final textBuffer = StringBuffer();

          for (final part in parts) {
                if (part is Map<String, dynamic>) {
                  if (part.containsKey('functionCall')) {
                    final fnCallRaw = part['functionCall'];
                    if (fnCallRaw is Map<String, dynamic>) {
                      final fnCall = Map<String, dynamic>.from(fnCallRaw);
                      final thoughtSignature =
                          part['thoughtSignature'] ?? part['thought_signature'];
                      if (thoughtSignature != null) {
                        fnCall['thoughtSignature'] = thoughtSignature;
                      }
                      functionCalls.add(fnCall);
                    }
                    continue;
                  }

                final text = part['text'];
                if (text is String && text.isNotEmpty) {
                  textBuffer.write(text);
                }
              } else if (part is String && part.isNotEmpty) {
                textBuffer.write(part);
              }
            }

            final textResponse = textBuffer.toString();

            LoggerService.debug('Gemini API request completed', error: {
              'hasFunctionCalls': functionCalls.isNotEmpty,
              'hasText': textResponse.isNotEmpty,
              'requestId': actualRequestId,
              'duration': '${duration.inMilliseconds}ms',
            });

            return {
              'text': textResponse.isEmpty ? null : textResponse,
              'function_calls': functionCalls.isEmpty ? null : functionCalls,
              'raw_data': data,
            };
          }
        }
      }
      LoggerService.error('No content in Gemini API response', error: {
        'responseData': data,
        'requestId': actualRequestId,
      });
      throw Exception('No content in Gemini API response');
    } else {
      final endpoint = _config?.endpoint ?? 'https://generativelanguage.googleapis.com/v1beta';
      final modelName = _config?.modelName ?? 'gemini-2.5-flash';
      
      LoggerService.logAiError(
        error: 'Gemini API request failed with status ${response.statusCode}: ${response.body}',
        endpoint: '$endpoint/models/$modelName:generateContent',
        requestId: actualRequestId,
      );
      throw Exception('Gemini API request failed with status ${response.statusCode}: ${response.body}');
    }
  }

}
