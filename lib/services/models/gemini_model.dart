import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'ai_model.dart';
import '../model_storage_service.dart';
import '../logger_service.dart';
import '../../models/model_type.dart';

/// Gemini 2.5 Flash model implementation
class GeminiModel implements AIModel {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';
  static const String _model = 'gemini-2.5-flash';

  // Common configuration constants
  static const Map<String, dynamic> _defaultGenerationConfig = {
    'temperature': 0.1,
    'topK': 32,
    'topP': 1,
    'maxOutputTokens': 60000,
  };


  @override
  String get id => ModelType.gemini25Flash.id;

  @override
  String get name => ModelType.gemini25Flash.displayName;

  @override
  String get description => 'Google\'s Gemini 2.5 Flash model with full multimodal capabilities';

  @override
  Future<bool> isReady() async {
    try {
      final apiKey = await ModelStorageService.getModelApiKey(ModelType.gemini25Flash);
      return apiKey != null && apiKey.isNotEmpty;
    } catch (e) {
      LoggerService.error('GeminiModel: Error checking readiness: $e');
      return false;
    }
  }

  @override
  Future<void> initialize() async {
    // Check if API key is available
    final apiKey = await ModelStorageService.getModelApiKey(ModelType.gemini25Flash);
    if (apiKey == null || apiKey.isEmpty) {
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
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      
      final generationConfig = {
        'temperature': temperature ?? 0.1,
        'topK': topK ?? 32,
        'topP': topP ?? 1,
        'maxOutputTokens': maxOutputTokens ?? 60000,
      };

      return await _makeGeminiRequest(apiKey, prompt, attachedFiles: attachedFiles, generationConfig: generationConfig, requestId: actualRequestId);
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
    // Gemini supports all these capabilities
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
    return 'This request is not supported by the current model configuration';
  }

  // Private helper methods

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

  Future<String> _validateApiKey({String? requestId}) async {
    final apiKey = await ModelStorageService.getModelApiKey(ModelType.gemini25Flash);
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
          final extension = file.name.split('.').last;
          final mimeType = _getMimeType(extension);
          
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
      'contents': [{'parts': parts}],
      'generationConfig': generationConfig ?? _defaultGenerationConfig,
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
    final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();

    LoggerService.logAiRequest(
      endpoint: '$_baseUrl/models/$_model:generateContent',
      headers: {'Content-Type': 'application/json'},
      requestBody: requestBody,
      requestId: actualRequestId,
    );

    final response = await http.post(
      Uri.parse('$_baseUrl/models/$_model:generateContent?key=$apiKey'),
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
        error: 'Failed to process request: ${response.statusCode} - ${response.body}',
        endpoint: '$_baseUrl/models/$_model:generateContent',
        requestId: actualRequestId,
        duration: duration,
      );
      throw Exception('Failed to process request: ${response.statusCode} - ${response.body}');
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


  String _getMimeType(String? extension) {
    if (extension == null) return 'application/octet-stream';
    
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'mp4':
        return 'video/mp4';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      default:
        return 'application/octet-stream';
    }
  }
}
