import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../../models/model_provider.dart';
import '../../models/model_capabilities.dart';
import '../../models/model_type.dart';
import '../model_storage_service.dart';
import '../logger_service.dart';

/// Gemini 2.5 Flash model provider
class GeminiProvider extends ModelProvider {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';
  static const String _model = 'gemini-2.5-flash';

  // Common configuration constants
  static const Map<String, dynamic> _defaultGenerationConfig = {
    'temperature': 0.1,
    'topK': 32,
    'topP': 1,
    'maxOutputTokens': 60000,
  };

  static const Map<String, dynamic> _creativeGenerationConfig = {
    'temperature': 0.7,
    'topK': 40,
    'topP': 0.95,
    'maxOutputTokens': 60000,
  };

  GeminiProvider() : super(
    id: ModelType.gemini25Flash.id,
    name: ModelType.gemini25Flash.displayName,
    description: 'Google\'s Gemini 2.5 Flash model with full multimodal capabilities',
    capabilities: const ModelCapabilities(
      maxInputTokens: 1000000,
      maxOutputTokens: 60000,
      supportsImages: true,
      supportsDocuments: true,
      supportsAudio: true,
      supportsVideo: true,
      supportedImageFormats: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'],
      supportedDocumentFormats: ['pdf', 'txt', 'doc', 'docx'],
      supportedAudioFormats: ['mp3', 'wav', 'aac', 'm4a', 'ogg', 'flac', 'wma'],
    ),
    requiresApiKey: true,
  );

  @override
  Future<void> initialize() async {
    // Check if API key is available
    final apiKey = await ModelStorageService.getModelApiKey(ModelType.gemini25Flash);
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('Gemini API key not configured');
    }
  }

  @override
  Future<bool> isReady() async {
    try {
      final apiKey = await ModelStorageService.getModelApiKey(ModelType.gemini25Flash);
      return apiKey != null && apiKey.isNotEmpty;
    } catch (e) {
      LoggerService.error('GeminiProvider: Error checking readiness: $e');
      return false;
    }
  }

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
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      
      final generationConfig = {
        'temperature': temperature ?? 0.1,
        'topK': topK ?? 32,
        'topP': topP ?? 1,
        'maxOutputTokens': maxOutputTokens ?? 60000,
      };

      return await _makeGeminiRequest(apiKey, prompt, generationConfig: generationConfig, requestId: actualRequestId);
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
  Future<String> transcribeAudio(String audioFilePath, {String? requestId}) async {
    return await _withErrorHandling('audio transcription', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      final audioData = await _processAudioFile(audioFilePath, actualRequestId);
      
      final prompt = "Please transcribe the following audio file. Provide only the transcribed text without any additional commentary or formatting.";
      final requestBody = _buildAudioRequestBody(prompt, audioData['base64Data'], audioData['mimeType']);
      
      return await _makeRequest(apiKey, requestBody, requestId: actualRequestId);
    });
  }

  @override
  Future<String> summarizeAudio(String audioFilePath, {String? context, String? requestId}) async {
    return await _withErrorHandling('audio summarization', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      final audioData = await _processAudioFile(audioFilePath, actualRequestId);
      
      final contextText = context != null ? "\n\nContext: $context" : "";
      final prompt = "Please listen to the following audio file and provide a concise summary of its main points and key information.$contextText";
      
      final requestBody = _buildAudioRequestBody(prompt, audioData['base64Data'], audioData['mimeType'], temperature: 0.3);
      
      return await _makeRequest(apiKey, requestBody, requestId: actualRequestId);
    });
  }

  @override
  Future<Map<String, dynamic>> extractContentFromImage(String imagePath, {String? requestId}) async {
    return await _withErrorHandling('image content extraction', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      final file = File(imagePath);
      
      if (!await file.exists()) {
        throw Exception('Image file not found');
      }

      final bytes = await file.readAsBytes();
      final base64Image = base64Encode(bytes);
      final mimeType = _getImageMimeType(imagePath);

      final prompt = 'Extract and summarize the content from this image. Provide a detailed description of what you see, including any text, objects, people, or important visual elements.';

      final response = await _makeGeminiRequestWithImage(prompt, base64Image, mimeType, apiKey, requestId: actualRequestId);

      return {
        'success': true,
        'content': response,
      };
    }).catchError((e) => {
      'success': false,
      'error': e.toString(),
    });
  }

  @override
  Future<Map<String, dynamic>> extractContentFromPdf(String pdfPath, {String? requestId}) async {
    return await _withErrorHandling('PDF content extraction', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      final file = File(pdfPath);
      
      if (!await file.exists()) {
        throw Exception('PDF file not found');
      }

      final bytes = await file.readAsBytes();
      final base64Pdf = base64Encode(bytes);

      final prompt = 'Extract and summarize the content from this PDF document. Provide a detailed summary of the main topics, key points, and important information contained in the document.';

      final response = await _makeGeminiRequestWithImage(prompt, base64Pdf, 'application/pdf', apiKey, requestId: actualRequestId);

      return {
        'success': true,
        'content': response,
      };
    }).catchError((e) => {
      'success': false,
      'error': e.toString(),
    });
  }

  @override
  Future<Map<String, dynamic>> extractContentFromText(
    String text,
    String contentType,
    String title, {
    String? requestId,
  }) async {
    return await _withErrorHandling('text content extraction', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      final prompt = _buildContentExtractionPrompt(text, contentType, title);
      final response = await _makeGeminiRequest(apiKey, prompt, requestId: actualRequestId);

      return {
        'success': true,
        'content': response,
      };
    }).catchError((e) => {
      'success': false,
      'error': e.toString(),
    });
  }

  @override
  Future<String> generateApp(String prompt, {String? requestId}) async {
    return await _withErrorHandling('app generation', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      return await _makeGeminiRequest(apiKey, prompt, generationConfig: _creativeGenerationConfig, requestId: actualRequestId);
    });
  }

  @override
  Future<String> generateAppWithAttachments(
    String prompt,
    List<PlatformFile>? attachedFiles, {
    String? requestId,
  }) async {
    return await _withErrorHandling('app generation with attachments', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      return await _makeGeminiRequest(apiKey, prompt, attachedFiles: attachedFiles, generationConfig: _creativeGenerationConfig, requestId: actualRequestId);
    });
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
    return await _withErrorHandling('chat AI', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final apiKey = await _validateApiKey(requestId: actualRequestId);
      final generationConfig = {
        'temperature': temperature ?? 0.7,
        'topK': topK ?? 40,
        'topP': topP ?? 0.95,
        'maxOutputTokens': 60000,
      };

      return await _makeGeminiRequest(apiKey, prompt, attachedFiles: attachedFiles, generationConfig: generationConfig, requestId: actualRequestId);
    });
  }

  // Helper methods (copied from original GeminiApiService)
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
    List<PlatformFile>? attachedFiles, {
    Map<String, dynamic>? generationConfig,
    List<Map<String, String>>? safetySettings,
  }) {
    final today = DateTime.now();
    final todayContext = '\n\nToday\'s date: ${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')} (${_getDayOfWeek(today)})';
    final enhancedPrompt = prompt + todayContext;

    final parts = <Map<String, dynamic>>[{'text': enhancedPrompt}];

    // Add file attachments if any
    if (attachedFiles != null && attachedFiles.isNotEmpty) {
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
    List<PlatformFile>? attachedFiles,
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

  Future<String> _makeGeminiRequestWithImage(
    String prompt,
    String base64Image,
    String mimeType,
    String apiKey, {
    String? requestId,
  }) async {
    final url = '$_baseUrl/models/$_model:generateContent?key=$apiKey';
    
    final requestBody = {
      'contents': [
        {
          'parts': [
            {
              'text': prompt,
            },
            {
              'inline_data': {
                'mime_type': mimeType,
                'data': base64Image,
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.7,
        'topK': 40,
        'topP': 0.95,
        'maxOutputTokens': 60000,
      },
    };

    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      final responseData = jsonDecode(response.body);
      return responseData['candidates'][0]['content']['parts'][0]['text'];
    } else {
      throw Exception('API request failed: ${response.statusCode} - ${response.body}');
    }
  }

  Future<Map<String, dynamic>> _processAudioFile(String audioFilePath, String requestId) async {
    final file = File(audioFilePath);
    if (!await file.exists()) {
      LoggerService.error('Audio file not found', error: {
        'audioFilePath': audioFilePath,
        'requestId': requestId,
      });
      throw Exception('Audio file not found');
    }

    final bytes = await file.readAsBytes();
    final base64Data = base64Encode(bytes);
    final fileName = audioFilePath.split('/').last;
    final extension = fileName.split('.').last.toLowerCase();
    final mimeType = _getAudioMimeType(extension);

    LoggerService.debug('Audio file processed', error: {
      'fileName': fileName,
      'fileSize': bytes.length,
      'mimeType': mimeType,
      'requestId': requestId,
    });

    return {
      'base64Data': base64Data,
      'mimeType': mimeType,
    };
  }

  Map<String, dynamic> _buildAudioRequestBody(
    String prompt,
    String base64Data,
    String mimeType, {
    double? temperature,
  }) {
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      {
        'inline_data': {
          'mime_type': mimeType,
          'data': base64Data,
        }
      }
    ];

    return {
      'contents': [{'parts': parts}],
      'generationConfig': {
        'temperature': temperature ?? 0.1,
        'topK': 32,
        'topP': 1,
        'maxOutputTokens': 60000,
      }
    };
  }

  String _getDayOfWeek(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
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

  String _getAudioMimeType(String extension) {
    switch (extension.toLowerCase()) {
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      case 'm4a':
        return 'audio/mp4';
      case 'ogg':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      case 'wma':
        return 'audio/x-ms-wma';
      default:
        return 'audio/mpeg';
    }
  }

  String _getImageMimeType(String imagePath) {
    final extension = imagePath.toLowerCase().split('.').last;
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
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

IMPORTANT - Math Formula Guidelines:
- When encountering mathematical formulas, equations, or expressions, represent them using LaTeX format
- Use the format: \\( formula \\) for inline math (without leading and ending \$ symbols)
- Use the format: \\[ formula \\] for display math (without leading and ending \$ symbols)
- Examples:
  - Inline: \\( E = mc^2 \\) or \\( \\frac{a}{b} \\)
  - Display: \\[ \\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi} \\]
- Preserve all mathematical notation, symbols, and formatting accurately
- If you encounter complex equations, break them down into logical components

Format the response in a clear, organized manner that would be useful for note-taking and future reference.
''';
  }
}
