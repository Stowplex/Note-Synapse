import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import '../../models/model_provider.dart';
import '../../models/model_capabilities.dart';
import '../../models/model_type.dart' as AppModelType;
import '../model_storage_service.dart';
import '../logger_service.dart';

/// Gemma 3n model provider using flutter_gemma package
class GemmaProvider extends ModelProvider {
  String? _apiKey;
  bool _isDownloaded = false;
  InferenceModel? _inferenceModel;

  GemmaProvider() : super(
    id: AppModelType.ModelType.gemma3n.id,
    name: AppModelType.ModelType.gemma3n.displayName,
    description: 'Google\'s Gemma 3n model with multimodal capabilities (except document understanding)',
    capabilities: const ModelCapabilities(
      maxInputTokens: 1000000,
      maxOutputTokens: 60000,
      supportsImages: true,
      supportsDocuments: false, // Gemma 3n doesn't support document understanding
      supportsAudio: true,
      supportsVideo: true,
      supportedImageFormats: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
      supportedAudioFormats: ['mp3', 'wav', 'aac', 'm4a', 'ogg'],
    ),
    requiresApiKey: true,
    requiresDownload: true,
  );

  @override
  Future<void> initialize() async {
    LoggerService.debug('GemmaProvider: Reading API key from storage...');
    _apiKey = await ModelStorageService.getModelApiKey(AppModelType.ModelType.gemma3n);
    LoggerService.debug('GemmaProvider: Retrieved API key, length: ${_apiKey?.length ?? 0}');
    
    if (_apiKey == null || _apiKey!.isEmpty) {
      LoggerService.error('GemmaProvider: API key is null or empty');
      throw Exception('Gemma API key not configured');
    }
    
    LoggerService.debug('GemmaProvider: API key validation passed, length: ${_apiKey!.length}');

    // Initialize Flutter Gemma first
    try {
      FlutterGemma.initialize(
        huggingFaceToken: _apiKey,
        maxDownloadRetries: 10,
      );
    } catch (e) {
      LoggerService.warning('FlutterGemma already initialized or error: $e');
    }
    
    // Now check if model is downloaded (after FlutterGemma is initialized)
    _isDownloaded = await _checkModelDownloaded();
    if (!_isDownloaded) {
      throw Exception('Gemma model not downloaded. Please download the model first.');
    }

    // Get the active model
    try {
      _inferenceModel = await FlutterGemmaPlugin.instance.createModel(
  modelType: ModelType.gemmaIt, // Required, model type to create
  preferredBackend: PreferredBackend.gpu, // Optional, backend type, default is PreferredBackend.gpu
  maxTokens: 1024, // Optional, default is 1024
);
      
      // Update the downloaded status based on successful initialization
      _isDownloaded = true;
      
      LoggerService.debug('GemmaProvider: Model initialized successfully');
    } catch (e) {
      LoggerService.error('GemmaProvider: Error initializing model: $e');
      throw Exception('Failed to initialize Gemma model: $e');
    }
  }

  @override
  Future<bool> isReady() async {
    try {
      LoggerService.debug('GemmaProvider: Checking readiness...');
      final apiKey = await ModelStorageService.getModelApiKey(AppModelType.ModelType.gemma3n);
      LoggerService.debug('GemmaProvider: isReady - API key length: ${apiKey?.length ?? 0}');
      final isDownloaded = await _checkModelDownloaded();
      LoggerService.debug('GemmaProvider: isReady - isDownloaded: $isDownloaded, inferenceModel: ${_inferenceModel != null}');
      
      final isReady = apiKey != null && 
                     apiKey.isNotEmpty && 
                     isDownloaded && 
                     _inferenceModel != null;
      
      LoggerService.debug('GemmaProvider: isReady result: $isReady');
      return isReady;
    } catch (e) {
      LoggerService.error('GemmaProvider: Error checking readiness: $e');
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
      await _ensureInitialized();
      
      if (_inferenceModel == null) {
        throw Exception('Inference model not initialized. Please initialize the model first.');
      }

      // Create a new session for this interaction
      final session = await _inferenceModel!.createSession(
        enableVisionModality: false, // Text-only session
      );
      
      try {
        LoggerService.debug('GemmaProvider: Created text-only session');
        
        // Add user message to session
        await session.addQueryChunk(Message(text: prompt, isUser: true));
        
        LoggerService.debug('GemmaProvider: About to get response from session');
        
        // Generate response
        final response = await session.getResponse();
        
        LoggerService.debug('GemmaProvider: Generated response length: ${response.length}');
        
        return response;
      } finally {
        // Always close the session
        await session.close();
        LoggerService.debug('GemmaProvider: Session closed');
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
    return await _withErrorHandling('generation with attachments', () async {
      await _ensureInitialized();
      
      if (_inferenceModel == null) {
        throw Exception('Inference model not initialized. Please initialize the model first.');
      }

      LoggerService.debug('GemmaProvider: generateWithAttachments called with ${attachedFiles.length} attachments');
      
      // Check if we have any image files
      final imageFiles = attachedFiles.where((file) {
        final extension = file.name.split('.').last.toLowerCase();
        return ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(extension);
      }).toList();
      
      // Determine if we need multimodal support
      final needsVision = imageFiles.isNotEmpty;
      
      // Create a new session for this interaction
      final session = await _inferenceModel!.createSession(
        enableVisionModality: true, // Enable vision if images are present
      );
      
      try {
        LoggerService.debug('GemmaProvider: Created session with vision: $needsVision');
        
        if (needsVision && imageFiles.isNotEmpty) {
          // Process the first image (Gemma 3n typically handles one image at a time)
          final imageFile = imageFiles.first;
          LoggerService.debug('GemmaProvider: Processing image: ${imageFile.name}');
          
          try {
            // Read image bytes
            Uint8List imageBytes;
            if (imageFile.bytes != null) {
              imageBytes = imageFile.bytes!;
            } else {
              // Fallback to reading from path if bytes not available
              final file = File(imageFile.path!);
              imageBytes = await file.readAsBytes();
            }
            
            // Create multimodal prompt with image context
            String imagePrompt = prompt;
            if (attachedFiles.length > 1) {
              imagePrompt += '\n\nNote: I can see ${attachedFiles.length} attached files, but I\'ll focus on analyzing the image: ${imageFile.name}. The other files are:';
              for (final file in attachedFiles.where((f) => f != imageFile)) {
                imagePrompt += '\n- ${file.name} (${file.extension}) - ${file.size} bytes';
              }
            }
            
            // Add multimodal message with image
            await session.addQueryChunk(Message.withImage(
              text: imagePrompt,
              imageBytes: imageBytes,
              isUser: true,
            ));
            
            LoggerService.debug('GemmaProvider: Added multimodal message with image : ${imageBytes.length} bytes');
          } catch (e) {
            LoggerService.error('GemmaProvider: Error processing image: $e');
            // Fallback to text-only message
            String fallbackPrompt = prompt;
            fallbackPrompt += '\n\nNote: I tried to process an image (${imageFile.name}) but encountered an error. Please describe the image content in text if you need analysis.';
            await session.addQueryChunk(Message(text: fallbackPrompt, isUser: true));
          }
        } else {
          // No images, create text-only message with file information
          String textPrompt = prompt;
          if (attachedFiles.isNotEmpty) {
            textPrompt += '\n\nAttached files:';
            for (int i = 0; i < attachedFiles.length; i++) {
              final file = attachedFiles[i];
              textPrompt += '\n${i + 1}. ${file.name} (${file.extension}) - ${file.size} bytes';
            }
            textPrompt += '\n\nPlease analyze the attached files and respond to the original prompt accordingly.';
          }
          
          await session.addQueryChunk(Message(text: textPrompt, isUser: true));
        }
        
        // Generate response
        final response = await session.getResponse();
        
        LoggerService.debug('GemmaProvider: Generated response with attachments, length: ${response.length}');
        
        return response;
      } finally {
        // Always close the session
        await session.close();
        LoggerService.debug('GemmaProvider: Session closed');
      }
    });
  }

  @override
  Future<String> transcribeAudio(String audioFilePath, {String? requestId}) async {
    return await _withErrorHandling('audio transcription', () async {
      await _ensureInitialized();
      
      if (_inferenceModel == null) {
        throw Exception('Inference model not initialized. Please initialize the model first.');
      }

      LoggerService.debug('GemmaProvider: transcribeAudio called for: $audioFilePath');
      
      // Create a new session for this interaction
      final session = await _inferenceModel!.createSession(
        enableVisionModality: false, // Audio transcription doesn't need vision
      );
      
      try {
        // Create transcription prompt
        final transcriptionPrompt = '''
Please transcribe the audio file located at: $audioFilePath

Provide a detailed transcription that includes:
1. All spoken words and phrases
2. Any background sounds or music (if relevant)
3. Speaker changes (if multiple speakers)
4. Any unclear or inaudible sections marked as [unclear]
5. Timestamps if possible

Please be as accurate as possible and maintain the original meaning and context.
''';

        // Add user message to session
        await session.addQueryChunk(Message(text: transcriptionPrompt, isUser: true));
        
        // Generate response
        final response = await session.getResponse();
        
        LoggerService.debug('GemmaProvider: Generated audio transcription, length: ${response.length}');
        
        return response;
      } finally {
        // Always close the session
        await session.close();
        LoggerService.debug('GemmaProvider: Session closed');
      }
    });
  }

  @override
  Future<String> summarizeAudio(String audioFilePath, {String? context, String? requestId}) async {
    return await _withErrorHandling('audio summarization', () async {
      await _ensureInitialized();
      
      if (_inferenceModel == null) {
        throw Exception('Inference model not initialized. Please initialize the model first.');
      }

      LoggerService.debug('GemmaProvider: summarizeAudio called for: $audioFilePath');
      
      // Create a new session for this interaction
      final session = await _inferenceModel!.createSession(
        enableVisionModality: false, // Audio summarization doesn't need vision
      );
      
      try {
        // Create summarization prompt
        String summarizationPrompt = '''
Please analyze and summarize the audio file located at: $audioFilePath
''';

        if (context != null && context.isNotEmpty) {
          summarizationPrompt += '\n\nContext: $context';
        }

        summarizationPrompt += '''

Please provide a comprehensive summary that includes:
1. Main topics and themes discussed
2. Key points and important information
3. Any decisions or conclusions reached
4. Important quotes or statements
5. Overall tone and mood
6. Any action items or next steps mentioned

Format the summary in a clear, organized manner that would be useful for reference and follow-up.
''';

        // Add user message to session
        await session.addQueryChunk(Message(text: summarizationPrompt, isUser: true));
        
        // Generate response
        final response = await session.getResponse();
        
        LoggerService.debug('GemmaProvider: Generated audio summary, length: ${response.length}');
        
        return response;
      } finally {
        // Always close the session
        await session.close();
        LoggerService.debug('GemmaProvider: Session closed');
      }
    });
  }

  @override
  Future<Map<String, dynamic>> extractContentFromImage(String imagePath, {String? requestId}) async {
    try {
      await _ensureInitialized();
      
      if (_inferenceModel == null) {
        return {
          'success': false,
          'error': 'Inference model not initialized. Please initialize the model first.',
        };
      }

      LoggerService.debug('GemmaProvider: extractContentFromImage called for: $imagePath');
      
      // Read image bytes
      final file = File(imagePath);
      if (!await file.exists()) {
        return {
          'success': false,
          'error': 'Image file does not exist: $imagePath',
        };
      }
      
      final imageBytes = await file.readAsBytes();
      LoggerService.debug('GemmaProvider: Read image bytes: ${imageBytes.length} bytes');
      
      // Create a new session for this interaction with vision enabled
      final session = await _inferenceModel!.createSession(
        enableVisionModality: true, // Enable vision for image analysis
      );
      
      try {
        // Create image analysis prompt
        final imageAnalysisPrompt = '''
Please analyze this image and provide a detailed analysis that includes:
1. Visual description of what you see
2. Text content (if any) - transcribe all visible text
3. Objects, people, or items in the image
4. Colors, composition, and visual elements
5. Context or setting information
6. Any charts, graphs, or data visualizations
7. Overall mood or atmosphere
8. Any important details or insights

Be thorough and descriptive, as this analysis will be used for note-taking and reference purposes.
''';

        // Add multimodal message with image
        await session.addQueryChunk(Message.withImage(
          text: imageAnalysisPrompt,
          imageBytes: imageBytes,
          isUser: true,
        ));
        
        // Generate response
        final response = await session.getResponse();
        
        LoggerService.debug('GemmaProvider: Generated image analysis, length: ${response.length}');
        
        return {
          'success': true,
          'content': response,
          'imagePath': imagePath,
        };
      } finally {
        // Always close the session
        await session.close();
        LoggerService.debug('GemmaProvider: Session closed');
      }
    } catch (e) {
      LoggerService.error('GemmaProvider: Error extracting content from image: $e');
      return <String, dynamic>{
        'success': false,
        'error': e.toString(),
      };
    }
  }

  @override
  Future<Map<String, dynamic>> extractContentFromPdf(String pdfPath, {String? requestId}) async {
    return {
      'success': false,
      'error': 'Gemma 3n does not support document understanding',
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
      
      if (_inferenceModel == null) {
        return {
          'success': false,
          'error': 'Inference model not initialized. Please initialize the model first.',
        };
      }

      // Create a new session for this interaction
      final session = await _inferenceModel!.createSession(
        enableVisionModality: false, // Text extraction doesn't need vision
      );
      
      try {
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

        // Add user message to session
        await session.addQueryChunk(Message(text: extractionPrompt, isUser: true));
        
        // Generate response
        final response = await session.getResponse();
        
        LoggerService.debug('GemmaProvider: Generated text extraction, length: ${response.length}');

        return {
          'success': true,
          'content': response,
          'title': title,
          'contentType': contentType,
        };
      } finally {
        // Always close the session
        await session.close();
        LoggerService.debug('GemmaProvider: Session closed');
      }
    } catch (e) {
      LoggerService.error('GemmaProvider: Error extracting content from text: $e');
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
    // If there are attachments, use the multimodal function
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

  /// Download the Gemma model using flutter_gemma
  Future<void> downloadModel({Function(double)? onProgress}) async {
    await _withErrorHandling('model download', () async {
      LoggerService.debug('GemmaProvider: Starting model download...');
      
      try {
        // Download Gemma 3 Nano 2B model (multimodal support)
        await FlutterGemma.installModel(
          modelType: ModelType.gemmaIt,

        )
        .fromNetwork(
          'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task',
          token: _apiKey,
        )
        .withProgress((progress) {
          LoggerService.debug('GemmaProvider: Download progress: $progress%');
          // Call the progress callback if provided
          if (onProgress != null) {
            onProgress(progress / 100.0); // Convert to 0.0-1.0 range
          }
        })
        .install();
        
        // Mark as downloaded - this will be true whether it was downloaded or already installed
        _isDownloaded = true;
        
        LoggerService.debug('GemmaProvider: Model download completed (or was already installed)');
      } catch (e) {
        LoggerService.error('GemmaProvider: Error downloading model: $e');
        rethrow;
      }
    });
  }

  /// Check if the model is downloaded
  Future<bool> _checkModelDownloaded() async {
    try {
      // Try to get the active model to see if it's available
      // This will fail if the model is not installed
      // Use device cache size limit to avoid crashes
      await FlutterGemma.getActiveModel(
        maxTokens: 1280, // Set to device cache size limit
        preferredBackend: PreferredBackend.gpu,
      );
      
      // If we can get the model, it means it's installed
      return true;
    } catch (e) {
      LoggerService.debug('GemmaProvider: Model not available, checking cached value: $e');
      
      // Check if it's a token limit error
      if (e.toString().contains('Max number of tokens is larger than the maximum cache size')) {
        LoggerService.warning('GemmaProvider: Device cache size limitation detected. Model may need lower token limit.');
      }
      
      // If we can't get the model, fall back to cached value
      return _isDownloaded;
    }
  }

  // Helper methods
  Future<void> _ensureInitialized() async {
    if (_apiKey == null) {
      await initialize();
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
