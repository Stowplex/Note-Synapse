import 'package:file_picker/file_picker.dart';
import '../models/model_provider.dart';
import '../models/model_type.dart';
import '../models/model_config.dart';
import 'model_storage_service.dart';
import 'secure_storage_service.dart';
import 'providers/gemini_provider.dart';
import 'providers/openai_provider.dart';
import 'providers/gemma_provider.dart';
import 'providers/qwen_provider.dart';
import 'logger_service.dart';

/// Service for managing AI model providers
class ModelService {
  static ModelService? _instance;
  static ModelService get instance => _instance ??= ModelService._();
  
  ModelService._();

  ModelProvider? _currentProvider;
  ModelType? _currentModelType;

  /// Get the current model provider
  ModelProvider? get currentProvider => _currentProvider;

  /// Get the current model type
  ModelType? get currentModelType => _currentModelType;

  /// Initialize the model service with the selected model
  Future<void> initialize() async {
    try {
      // Migrate old Gemini API key to new system if needed
      await _migrateOldGeminiApiKey();
      
      final selectedModel = await ModelStorageService.getSelectedModel();
      LoggerService.debug('ModelService: Selected model from storage: ${selectedModel.displayName}');
      
      await switchToModel(selectedModel);
      LoggerService.debug('ModelService: Successfully initialized with ${selectedModel.displayName}');
    } catch (e) {
      LoggerService.error('ModelService: Error during initialization with selected model: $e');
      LoggerService.warning('ModelService: Falling back to Gemini 2.5 Flash');
      
      // Fallback to Gemini if available
      try {
        await switchToModel(ModelType.gemini25Flash);
        LoggerService.warning('ModelService: Successfully fell back to Gemini 2.5 Flash');
      } catch (fallbackError) {
        LoggerService.error('ModelService: Fallback to Gemini also failed: $fallbackError');
      }
    }
  }

  /// Switch to a different model
  Future<void> switchToModel(ModelType modelType) async {
    try {
      LoggerService.debug('ModelService: Switching to ${modelType.displayName}');
      LoggerService.debug('ModelService: Previous model was: ${_currentModelType?.displayName ?? "None"}');
      LoggerService.debug('ModelService: Previous provider was: ${_currentProvider.runtimeType}');
      
      // Create provider instance
      final provider = _createProvider(modelType);
      LoggerService.debug('ModelService: Created provider: ${provider.runtimeType}');
      
      // Initialize the provider
      LoggerService.debug('ModelService: About to initialize provider...');
      await provider.initialize();
      LoggerService.debug('ModelService: Provider initialized successfully');
      
      // Check if provider is ready
      LoggerService.debug('ModelService: Checking if provider is ready...');
      final isReady = await provider.isReady();
      LoggerService.debug('ModelService: Provider ready status: $isReady');
      if (!isReady) {
        throw Exception('${modelType.displayName} is not ready. Please configure it first.');
      }
      
      // Update current provider
      LoggerService.debug('ModelService: Updating current provider and model type...');
      _currentProvider = provider;
      _currentModelType = modelType;
      
      // Save selection
      LoggerService.debug('ModelService: Saving model selection...');
      await ModelStorageService.setSelectedModel(modelType);
      
      LoggerService.debug('ModelService: Successfully switched to ${modelType.displayName}');
      LoggerService.debug('ModelService: Current provider is now: ${_currentProvider.runtimeType}');
      LoggerService.debug('ModelService: Current model type is now: ${_currentModelType?.displayName}');
    } catch (e) {
      LoggerService.error('ModelService: Error switching to ${modelType.displayName}: $e');
      LoggerService.error('ModelService: Current provider remains: ${_currentProvider.runtimeType}');
      LoggerService.error('ModelService: Current model type remains: ${_currentModelType?.displayName}');
      rethrow;
    }
  }

  /// Get all available model types
  List<ModelType> getAvailableModels() {
    return ModelType.all;
  }

  /// Get configured models
  Future<List<ModelType>> getConfiguredModels() async {
    return await ModelStorageService.getConfiguredModels();
  }

  /// Check if a model is configured
  Future<bool> isModelConfigured(ModelType modelType) async {
    return await ModelStorageService.isModelConfigured(modelType);
  }

  /// Reset model configuration (useful when download fails)
  Future<void> resetModelConfiguration(ModelType modelType) async {
    try {
      LoggerService.debug('ModelService: Resetting configuration for ${modelType.displayName}');
      await ModelStorageService.resetModelConfiguration(modelType);
      LoggerService.debug('ModelService: Successfully reset configuration for ${modelType.displayName}');
    } catch (e) {
      LoggerService.error('ModelService: Error resetting configuration for ${modelType.displayName}: $e');
      rethrow;
    }
  }

  /// Configure a model
  Future<void> configureModel(ModelType modelType, {
    String? apiKey,
    String? endpoint,
    String? modelName,
    Map<String, dynamic>? customCapabilities,
  }) async {
    try {
      LoggerService.debug('ModelService: Configuring ${modelType.displayName}');
      
      // Save API key if provided
      if (apiKey != null && apiKey.isNotEmpty) {
        await ModelStorageService.saveModelApiKey(modelType, apiKey);
      }
      
      // Create and save configuration
      final config = ModelConfig(
        type: modelType,
        apiKey: apiKey,
        endpoint: endpoint,
        modelName: modelName,
        customCapabilities: customCapabilities ?? {},
        isConfigured: true,
      );
      
      await ModelStorageService.saveModelConfig(config);
      
      LoggerService.debug('ModelService: Successfully configured ${modelType.displayName}');
    } catch (e) {
      LoggerService.error('ModelService: Error configuring ${modelType.displayName}: $e');
      rethrow;
    }
  }

  /// Download a model (for models that require download)
  Future<void> downloadModel(ModelType modelType, {Function(double)? onProgress}) async {
    try {
      LoggerService.debug('ModelService: Downloading ${modelType.displayName}');
      
      final provider = _createProvider(modelType);
      
      if (provider is GemmaProvider) {
        await provider.downloadModel(onProgress: onProgress);
      } else if (provider is QwenProvider) {
        await provider.downloadModel(onProgress: onProgress);
      } else {
        throw Exception('${modelType.displayName} does not require download');
      }
      
      LoggerService.debug('ModelService: Successfully downloaded ${modelType.displayName}');
    } catch (e) {
      LoggerService.error('ModelService: Error downloading ${modelType.displayName}: $e');
      rethrow;
    }
  }

  /// Generate text using the current model
  Future<String> generateText(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    _ensureProviderReady();
    return await _currentProvider!.generateText(
      prompt,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      requestId: requestId,
    );
  }

  /// Generate text with attachments using the current model
  Future<String> generateWithAttachments(
    String prompt,
    List<PlatformFile> attachedFiles, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    _ensureProviderReady();
    
    LoggerService.debug('ModelService: generateWithAttachments called with current model: ${_currentModelType?.displayName ?? "Unknown"}');
    LoggerService.debug('ModelService: Current provider type: ${_currentProvider.runtimeType}');
    
    // Check capabilities
    if (!_currentProvider!.canHandleRequest(attachedFiles: attachedFiles)) {
      throw Exception(_currentProvider!.getCapabilityErrorMessage(attachedFiles: attachedFiles));
    }
    
    return await _currentProvider!.generateWithAttachments(
      prompt,
      attachedFiles,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      requestId: requestId,
    );
  }

  /// Transcribe audio using the current model
  Future<String> transcribeAudio(String audioFilePath, {String? requestId}) async {
    _ensureProviderReady();
    
    if (!_currentProvider!.capabilities.supportsAudioInput) {
      throw Exception(_currentProvider!.getCapabilityErrorMessage(requiresAudioSupport: true));
    }
    
    return await _currentProvider!.transcribeAudio(audioFilePath, requestId: requestId);
  }

  /// Summarize audio using the current model
  Future<String> summarizeAudio(String audioFilePath, {String? context, String? requestId}) async {
    _ensureProviderReady();
    
    if (!_currentProvider!.capabilities.supportsAudioInput) {
      throw Exception(_currentProvider!.getCapabilityErrorMessage(requiresAudioSupport: true));
    }
    
    return await _currentProvider!.summarizeAudio(audioFilePath, context: context, requestId: requestId);
  }

  /// Extract content from image using the current model
  Future<Map<String, dynamic>> extractContentFromImage(String imagePath, {String? requestId}) async {
    _ensureProviderReady();
    
    if (!_currentProvider!.capabilities.supportsImageInput) {
      return {
        'success': false,
        'error': _currentProvider!.getCapabilityErrorMessage(requiresImageSupport: true),
      };
    }
    
    return await _currentProvider!.extractContentFromImage(imagePath, requestId: requestId);
  }

  /// Extract content from PDF using the current model
  Future<Map<String, dynamic>> extractContentFromPdf(String pdfPath, {String? requestId}) async {
    _ensureProviderReady();
    
    if (!_currentProvider!.capabilities.supportsDocumentInput) {
      return {
        'success': false,
        'error': _currentProvider!.getCapabilityErrorMessage(requiresDocumentSupport: true),
      };
    }
    
    return await _currentProvider!.extractContentFromPdf(pdfPath, requestId: requestId);
  }

  /// Extract content from text using the current model
  Future<Map<String, dynamic>> extractContentFromText(
    String text,
    String contentType,
    String title, {
    String? requestId,
  }) async {
    _ensureProviderReady();
    return await _currentProvider!.extractContentFromText(
      text,
      contentType,
      title,
      requestId: requestId,
    );
  }

  /// Generate user app HTML using the current model
  Future<String> generateApp(String prompt, {String? requestId}) async {
    _ensureProviderReady();
    return await _currentProvider!.generateApp(prompt, requestId: requestId);
  }

  /// Generate user app HTML with attachments using the current model
  Future<String> generateAppWithAttachments(
    String prompt,
    List<PlatformFile>? attachedFiles, {
    String? requestId,
  }) async {
    _ensureProviderReady();
    return await _currentProvider!.generateAppWithAttachments(
      prompt,
      attachedFiles,
      requestId: requestId,
    );
  }

  /// Chat AI using the current model
  Future<String> chatAI(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    List<PlatformFile>? attachedFiles,
    String? requestId,
  }) async {
    _ensureProviderReady();
    return await _currentProvider!.chatAI(
      prompt,
      temperature: temperature,
      topK: topK,
      topP: topP,
      attachedFiles: attachedFiles,
      requestId: requestId,
    );
  }

  /// Check if the current model can handle a request
  bool canHandleRequest({
    List<PlatformFile>? attachedFiles,
    bool requiresImageSupport = false,
    bool requiresDocumentSupport = false,
    bool requiresAudioSupport = false,
    bool requiresVideoSupport = false,
  }) {
    if (_currentProvider == null) return false;
    
    return _currentProvider!.canHandleRequest(
      attachedFiles: attachedFiles,
      requiresImageSupport: requiresImageSupport,
      requiresDocumentSupport: requiresDocumentSupport,
      requiresAudioSupport: requiresAudioSupport,
      requiresVideoSupport: requiresVideoSupport,
    );
  }

  /// Get error message for unsupported capabilities
  String getCapabilityErrorMessage({
    List<PlatformFile>? attachedFiles,
    bool requiresImageSupport = false,
    bool requiresDocumentSupport = false,
    bool requiresAudioSupport = false,
    bool requiresVideoSupport = false,
  }) {
    if (_currentProvider == null) {
      return 'No model provider is currently selected';
    }
    
    return _currentProvider!.getCapabilityErrorMessage(
      attachedFiles: attachedFiles,
      requiresImageSupport: requiresImageSupport,
      requiresDocumentSupport: requiresDocumentSupport,
      requiresAudioSupport: requiresAudioSupport,
      requiresVideoSupport: requiresVideoSupport,
    );
  }

  /// Create a provider instance for the given model type
  ModelProvider _createProvider(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini25Flash:
        return GeminiProvider();
      case ModelType.openaiCompatible:
        return OpenAiProvider();
      case ModelType.gemma3n:
        return GemmaProvider();
      case ModelType.qwen25:
        return QwenProvider();
    }
  }

  /// Ensure that a provider is ready
  void _ensureProviderReady() {
    if (_currentProvider == null) {
      throw Exception('No model provider is currently selected. Please select a model first.');
    }
  }

  /// Migrate old Gemini API key from SecureStorageService to ModelStorageService
  Future<void> _migrateOldGeminiApiKey() async {
    try {
      // Check if Gemini is already configured in the new system
      final isConfigured = await ModelStorageService.isModelConfigured(ModelType.gemini25Flash);
      if (isConfigured) {
        LoggerService.debug('ModelService: Gemini already configured in new system, skipping migration');
        return;
      }

      // Check if old API key exists
      final oldApiKey = await SecureStorageService.getApiKey();
      if (oldApiKey == null || oldApiKey.isEmpty) {
        LoggerService.debug('ModelService: No old Gemini API key found, skipping migration');
        return;
      }

      LoggerService.debug('ModelService: Migrating old Gemini API key to new system');
      
      // Save API key to new system
      await ModelStorageService.saveModelApiKey(ModelType.gemini25Flash, oldApiKey);
      
      // Create and save model configuration
      final config = ModelConfig(
        type: ModelType.gemini25Flash,
        apiKey: oldApiKey,
        isConfigured: true,
      );
      await ModelStorageService.saveModelConfig(config);
      
      LoggerService.debug('ModelService: Successfully migrated Gemini API key to new system');
    } catch (e) {
      LoggerService.error('ModelService: Error migrating old Gemini API key: $e');
      // Don't throw - migration failure shouldn't break initialization
    }
  }
}
