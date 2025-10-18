import 'package:file_picker/file_picker.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import '../../models/model_provider.dart';
import '../../models/model_capabilities.dart';
import '../../models/model_type.dart' as LocalModelType;
import '../logger_service.dart';

/// Qwen 2.5 model provider using flutter_gemma package
class QwenProvider extends ModelProvider {
  bool _isDownloaded = false;
  InferenceModel? _inferenceModel;
  InferenceChat? _chat;

  QwenProvider() : super(
    id: LocalModelType.ModelType.qwen25.id,
    name: LocalModelType.ModelType.qwen25.displayName,
    description: 'Qwen 2.5 model with text-only capabilities',
    capabilities: const ModelCapabilities(
      maxInputTokens: 1000000,
      maxOutputTokens: 60000,
      supportsImages: false, // Text-only model
      supportsDocuments: false, // Text-only model
      supportsAudio: false, // Text-only model
      supportsVideo: false, // Text-only model
    ),
    requiresApiKey: false,
    requiresDownload: true,
  );

  @override
  Future<void> initialize() async {
    LoggerService.debug('QwenProvider: Starting initialization...');
    
    // Initialize Flutter Gemma first
    try {
      LoggerService.debug('QwenProvider: Initializing FlutterGemma...');
      FlutterGemma.initialize(
        maxDownloadRetries: 10,
      );
      LoggerService.debug('QwenProvider: FlutterGemma initialized successfully');
    } catch (e) {
      LoggerService.warning('FlutterGemma already initialized or error: $e');
    }

    // Now check if model is downloaded (after FlutterGemma is initialized)
    LoggerService.debug('QwenProvider: Checking if model is downloaded...');
    _isDownloaded = await _checkModelDownloaded();
    LoggerService.debug('QwenProvider: Model downloaded status: $_isDownloaded');
    
    if (!_isDownloaded) {
      throw Exception('Qwen model not downloaded. Please download the model first.');
    }

    // Get the active model
    try {
      _inferenceModel = await FlutterGemma.getActiveModel(
        maxTokens: 1280, // Set to device cache size limit
        preferredBackend: PreferredBackend.gpu,
      );
      
      // Create chat instance
      _chat = await _inferenceModel!.createChat();
      
      // Update the downloaded status based on successful initialization
      _isDownloaded = true;
      
      LoggerService.debug('QwenProvider: Model initialized successfully');
    } catch (e) {
      LoggerService.error('QwenProvider: Error initializing model: $e');
      throw Exception('Failed to initialize Qwen model: $e');
    }
  }

  @override
  Future<bool> isReady() async {
    try {
      final isDownloaded = await _checkModelDownloaded();
      return isDownloaded && _inferenceModel != null && _chat != null;
    } catch (e) {
      LoggerService.error('QwenProvider: Error checking readiness: $e');
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
      LoggerService.debug('QwenProvider: generateText called with prompt length: ${prompt.length}');
      LoggerService.debug('QwenProvider: Current model downloaded status: $_isDownloaded');
      
      await _ensureInitialized();
      
      if (_chat == null) {
        throw Exception('Chat not initialized. Please initialize the model first.');
      }

      LoggerService.debug('QwenProvider: About to add query chunk to chat');
      
      // Add user message to chat
      await _chat!.addQueryChunk(Message(text: prompt, isUser: true));
      
      LoggerService.debug('QwenProvider: About to generate chat response');
      
      // Generate response
      final response = await _chat!.generateChatResponse();
      
      LoggerService.debug('QwenProvider: Generated response type: ${response.runtimeType}');
      
      // Extract text from response
      if (response is TextResponse) {
        LoggerService.debug('QwenProvider: Returning text response: ${response.token}');
        return response.token;
      } else if (response is FunctionCallResponse) {
        // Handle function calls if needed
        LoggerService.debug('QwenProvider: Function call detected: ${response.name}');
        return 'Function call detected: ${response.name}';
      } else {
        LoggerService.debug('QwenProvider: Returning string response: ${response.toString()}');
        return response.toString();
      }
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
    LoggerService.debug('QwenProvider: generateWithAttachments called with ${attachedFiles.length} attachments');
    
    // Qwen is text-only, so we inform the user and process the text prompt
    String enhancedPrompt = prompt;
    
    if (attachedFiles.isNotEmpty) {
      enhancedPrompt += '\n\nNote: Qwen 2.5 is a text-only model and cannot process the ${attachedFiles.length} attached file(s). Please describe the content of the files in text format if you need analysis of their contents.';
      
      // Add basic file information to help the user
      enhancedPrompt += '\n\nAttached files:';
      for (int i = 0; i < attachedFiles.length; i++) {
        final file = attachedFiles[i];
        enhancedPrompt += '\n${i + 1}. ${file.name} (${file.extension}) - ${file.size} bytes';
      }
    }
    
    return await generateText(
      enhancedPrompt,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      requestId: requestId,
    );
  }

  @override
  Future<String> transcribeAudio(String audioFilePath, {String? requestId}) async {
    throw Exception('Qwen 2.5 is a text-only model and does not support audio transcription');
  }

  @override
  Future<String> summarizeAudio(String audioFilePath, {String? context, String? requestId}) async {
    throw Exception('Qwen 2.5 is a text-only model and does not support audio processing');
  }

  @override
  Future<Map<String, dynamic>> extractContentFromImage(String imagePath, {String? requestId}) async {
    return {
      'success': false,
      'error': 'Qwen 2.5 is a text-only model and does not support image processing',
    };
  }

  @override
  Future<Map<String, dynamic>> extractContentFromPdf(String pdfPath, {String? requestId}) async {
    return {
      'success': false,
      'error': 'Qwen 2.5 is a text-only model and does not support document processing',
    };
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
      
      if (_chat == null) {
        return {
          'success': false,
          'error': 'Chat not initialized. Please initialize the model first.',
        };
      }

      // Create extraction prompt
      final extractionPrompt = '''
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

      // Add user message to chat
      await _chat!.addQueryChunk(Message(text: extractionPrompt, isUser: true));
      
      // Generate response
      final response = await _chat!.generateChatResponse();
      
      // Extract content from response
      String content;
      if (response is TextResponse) {
        content = response.token;
      } else if (response is FunctionCallResponse) {
        content = 'Function call detected: ${response.name}';
      } else {
        content = response.toString();
      }

      return {
        'success': true,
        'content': content,
        'title': title,
        'contentType': contentType,
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
    // If there are attachments, use the multimodal function (which handles text-only limitation)
    if (attachedFiles != null && attachedFiles.isNotEmpty) {
      return await generateWithAttachments(
        prompt,
        attachedFiles,
        temperature: temperature,
        topK: topK,
        topP: topP,
        requestId: requestId,
      );
    }
    
    // Otherwise, use regular text generation
    return await generateText(
      prompt,
      temperature: temperature,
      topK: topK,
      topP: topP,
      requestId: requestId,
    );
  }

  /// Download the Qwen model using flutter_gemma
  Future<void> downloadModel({Function(double)? onProgress}) async {
    await _withErrorHandling('model download', () async {
      LoggerService.debug('QwenProvider: Starting model download...');
      
      try {
        // Download Qwen 2.5 1.5B model
        await FlutterGemma.installModel(
          modelType: ModelType.qwen,
        )
        .fromNetwork('https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_seq128_q8_ekv1280.task')
        .withProgress((progress) {
          LoggerService.debug('QwenProvider: Download progress: $progress%');
          // Call the progress callback if provided
          if (onProgress != null) {
            onProgress(progress / 100.0); // Convert to 0.0-1.0 range
          }
        })
        .install();
        
        // Mark as downloaded - this will be true whether it was downloaded or already installed
        _isDownloaded = true;
        
        LoggerService.debug('QwenProvider: Model download completed (or was already installed)');
      } catch (e) {
        LoggerService.error('QwenProvider: Error downloading model: $e');
        rethrow;
      }
    });
  }

  /// Check if the model is downloaded
  Future<bool> _checkModelDownloaded() async {
    try {
      LoggerService.debug('QwenProvider: Checking if model is downloaded...');
      
      // Try to get the active model to see if it's available
      // This will fail if the model is not installed
      // Use device cache size limit to avoid crashes
      await FlutterGemma.getActiveModel(
        maxTokens: 1280, // Set to device cache size limit
        preferredBackend: PreferredBackend.gpu,
      );
      
      LoggerService.debug('QwenProvider: Model is available in flutter_gemma cache');
      // If we can get the model, it means it's installed
      return true;
    } catch (e) {
      LoggerService.debug('QwenProvider: Model not available in flutter_gemma cache: $e');
      
      // Check if it's a token limit error
      if (e.toString().contains('Max number of tokens is larger than the maximum cache size')) {
        LoggerService.warning('QwenProvider: Device cache size limitation detected. Model may need lower token limit.');
      }
      
      LoggerService.debug('QwenProvider: Falling back to cached value: $_isDownloaded');
      // If we can't get the model, fall back to cached value
      return _isDownloaded;
    }
  }

  // Helper methods
  Future<void> _ensureInitialized() async {
    LoggerService.debug('QwenProvider: _ensureInitialized called, _isDownloaded: $_isDownloaded');
    if (!_isDownloaded) {
      LoggerService.debug('QwenProvider: Model not downloaded, calling initialize()');
      await initialize();
    } else {
      LoggerService.debug('QwenProvider: Model already downloaded, skipping initialize()');
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
}
