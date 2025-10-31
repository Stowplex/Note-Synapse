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
    String? requestId,
  }) async {
    return await _withErrorHandling('generation with attachments', () async {
      final actualRequestId =
          requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);

      final generationConfig = {
        'temperature': temperature ?? 0.1,
        'topK': topK ?? 32,
        'topP': topP ?? 1,
        'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
      };

      return await _makeGeminiRequest(apiKey, prompt,
          attachedFiles: attachedFiles,
          generationConfig: generationConfig,
          requestId: actualRequestId);
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
      final actualRequestId =
          requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);

      final generationConfig = {
        'temperature': temperature ?? 0.1,
        'topK': topK ?? 32,
        'topP': topP ?? 1,
        'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
      };

      // Convert messages array to Gemini format
      final requestBody = _buildRequestBodyFromMessages(
        messages,
        attachedFiles,
        generationConfig: generationConfig,
      );

      return await _makeRequest(apiKey, requestBody, requestId: actualRequestId);
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
      final actualRequestId =
          requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);

      final generationConfig = {
        'temperature': temperature ?? 0.1,
        'topK': topK ?? 32,
        'topP': topP ?? 1,
        'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
      };

      return await _makeGeminiRequestWithTools(
        apiKey,
        prompt,
        tools,
        attachedFiles: attachedFiles,
        generationConfig: generationConfig,
        requestId: actualRequestId,
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
      final actualRequestId =
          requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);

      final generationConfig = {
        'temperature': temperature ?? 0.1,
        'topK': topK ?? 32,
        'topP': topP ?? 1,
        'maxOutputTokens': maxOutputTokens ?? _config?.maxOutputTokens ?? 65536,
      };

      // Convert messages array to Gemini format
      final requestBody = _buildRequestBodyFromMessages(
        messages,
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
    });
  }

  /// Build request body from messages array
  /// Gemini uses a different format: contents array where each content has parts
  /// System messages are passed in a separate systemInstruction field
  /// Gemini expects alternating user and model messages
  Map<String, dynamic> _buildRequestBodyFromMessages(
    List<Map<String, dynamic>> messages,
    List<PlatformFile> attachedFiles, {
    Map<String, dynamic>? generationConfig,
  }) {
    final todayContext = AIModel.getTodayContext();
    final contents = <Map<String, dynamic>>[];
    String? systemInstruction;
    
    // Extract system messages and combine them for systemInstruction
    final systemMessages = <String>[];
    final conversationMessages = <Map<String, dynamic>>[];
    
    for (final msg in messages) {
      final role = msg['role'] as String;
      final content = msg['content'] as String;
      
      if (role == 'system') {
        systemMessages.add(content);
      } else {
        conversationMessages.add(msg);
      }
    }
    
    if (systemMessages.isNotEmpty) {
      systemInstruction = systemMessages.join('\n\n');
    }
    
    // Find the index of the last user message first
    int lastUserMessageIndex = -1;
    for (int i = conversationMessages.length - 1; i >= 0; i--) {
      if (conversationMessages[i]['role'] == 'user') {
        lastUserMessageIndex = i;
        break;
      }
    }
    
    // Convert messages to Gemini format
    // Gemini expects alternating user and model (assistant) messages
    for (int i = 0; i < conversationMessages.length; i++) {
      final msg = conversationMessages[i];
      final role = msg['role'] as String;
      final content = msg['content'] as String;
      
      if (role == 'assistant') {
        // Add assistant response as model's turn
        contents.add({
          'role': 'model',
          'parts': [{'text': content}]
        });
      } else if (role == 'user') {
        // Determine if this is the last user message (where we attach files and add todayContext)
        final isLastUserMessage = i == lastUserMessageIndex;
        
        // Build parts for this user message
        final parts = <Map<String, dynamic>>[];
        
        // Add today's context to last user message only
        String messageText = content;
        if (isLastUserMessage) {
          messageText = messageText + todayContext;
        }
        
        parts.add({'text': messageText});
        
        // Add file attachments to the last user message
        if (isLastUserMessage && attachedFiles.isNotEmpty) {
          for (final file in attachedFiles) {
            if (file.bytes != null) {
              final base64Data = base64Encode(file.bytes!);
              final extension = FileTypeUtils.getFileExtension(file.name);
              final mimeType = FileTypeUtils.getMimeTypeForBytes(
                file.bytes!,
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
        
        contents.add({
          'role': 'user',
          'parts': parts
        });
      }
    }
    
    final requestBody = <String, dynamic>{
      'contents': contents,
      'generationConfig': generationConfig ??
          {
            'temperature': 0.1,
            'topK': 32,
            'topP': 1,
            'maxOutputTokens': _config?.maxOutputTokens ?? 65536,
          },
    };
    
    // Add systemInstruction if we have system messages
    if (systemInstruction != null && systemInstruction.isNotEmpty) {
      requestBody['systemInstruction'] = {
        'parts': [{'text': systemInstruction}]
      };
    }
    
    return requestBody;
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

  Map<String, dynamic> _buildRequestBody(
    String prompt,
    List<PlatformFile> attachedFiles, {
    Map<String, dynamic>? generationConfig,
    List<Map<String, String>>? safetySettings,
  }) {
    final todayContext = AIModel.getTodayContext();
    final enhancedPrompt = prompt + todayContext;

    final parts = <Map<String, dynamic>>[{'text': enhancedPrompt}];

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
            'temperature': 0.1,
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

        if (content != null &&
            content['parts'] != null &&
            content['parts'].isNotEmpty) {
          final responseText = content['parts'][0]['text'];
          LoggerService.debug('Gemini API request completed successfully', error: {
            'responseLength': responseText.length,
            'requestId': actualRequestId,
            'duration': '${duration.inMilliseconds}ms',
          });
          return responseText;
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

        if (content != null && content['parts'] != null && content['parts'].isNotEmpty) {
          final parts = content['parts'] as List;
          
          // Check for function calls
          final functionCalls = <Map<String, dynamic>>[];
          String? textResponse;

          for (final part in parts) {
            if (part.containsKey('functionCall')) {
              functionCalls.add(part['functionCall'] as Map<String, dynamic>);
            } else if (part.containsKey('text')) {
              textResponse = part['text'];
            }
          }

          LoggerService.debug('Gemini API request completed', error: {
            'hasFunctionCalls': functionCalls.isNotEmpty,
            'hasText': textResponse != null,
            'requestId': actualRequestId,
            'duration': '${duration.inMilliseconds}ms',
          });

          return {
            'text': textResponse,
            'function_calls': functionCalls.isEmpty ? null : functionCalls,
            'raw_data': data,
          };
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
