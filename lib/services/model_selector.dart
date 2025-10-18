import 'package:file_picker/file_picker.dart';
import 'models/ai_model.dart';
import 'models/gemini_model.dart';
import 'models/openai_model.dart';
import 'model_storage_service.dart';
import 'logger_service.dart';
import '../models/model_type.dart';
import '../models/model_config.dart';

/// Service for selecting and managing AI models
class ModelSelector {
  static ModelSelector? _instance;
  static ModelSelector get instance => _instance ??= ModelSelector._();
  
  ModelSelector._();

  AIModel? _currentModel;
  ModelType? _currentModelType;

  /// Get the current model
  AIModel? get currentModel => _currentModel;

  /// Get the current model type
  ModelType? get currentModelType => _currentModelType;

  /// Initialize with the selected model
  Future<void> initialize() async {
    try {
      final selectedModel = await ModelStorageService.getSelectedModel();
      LoggerService.debug('ModelSelector: Selected model from storage: ${selectedModel.displayName}');
      
      await switchToModel(selectedModel);
      LoggerService.debug('ModelSelector: Successfully initialized with ${selectedModel.displayName}');
    } catch (e) {
      LoggerService.error('ModelSelector: Error during initialization with selected model: $e');
      LoggerService.warning('ModelSelector: Falling back to Gemini 2.5 Flash');
      
      // Fallback to Gemini if available
      try {
        await switchToModel(ModelType.gemini25Flash);
        LoggerService.warning('ModelSelector: Successfully fell back to Gemini 2.5 Flash');
      } catch (fallbackError) {
        LoggerService.error('ModelSelector: Fallback to Gemini also failed: $fallbackError');
      }
    }
  }

  /// Switch to a different model
  Future<void> switchToModel(ModelType modelType) async {
    try {
      LoggerService.debug('ModelSelector: Switching to ${modelType.displayName}');
      LoggerService.debug('ModelSelector: Previous model was: ${_currentModelType?.displayName ?? "None"}');
      
      // Create model instance
      final model = _createModel(modelType);
      LoggerService.debug('ModelSelector: Created model: ${model.runtimeType}');
      
      // Initialize the model
      LoggerService.debug('ModelSelector: About to initialize model...');
      await model.initialize();
      LoggerService.debug('ModelSelector: Model initialized successfully');
      
      // Check if model is ready
      LoggerService.debug('ModelSelector: Checking if model is ready...');
      final isReady = await model.isReady();
      LoggerService.debug('ModelSelector: Model ready status: $isReady');
      if (!isReady) {
        throw Exception('${modelType.displayName} is not ready. Please configure it first.');
      }
      
      // Update current model
      LoggerService.debug('ModelSelector: Updating current model...');
      _currentModel = model;
      _currentModelType = modelType;
      
      // Save selection
      LoggerService.debug('ModelSelector: Saving model selection...');
      await ModelStorageService.setSelectedModel(modelType);
      
      LoggerService.debug('ModelSelector: Successfully switched to ${modelType.displayName}');
      LoggerService.debug('ModelSelector: Current model type is now: ${_currentModelType?.displayName}');
    } catch (e) {
      LoggerService.error('ModelSelector: Error switching to ${modelType.displayName}: $e');
      LoggerService.error('ModelSelector: Current model type remains: ${_currentModelType?.displayName}');
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

  /// Configure a model
  Future<void> configureModel(ModelType modelType, {
    String? apiKey,
    String? endpoint,
    String? modelName,
    Map<String, dynamic>? customCapabilities,
  }) async {
    try {
      LoggerService.debug('ModelSelector: Configuring ${modelType.displayName}');
      
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
      
      LoggerService.debug('ModelSelector: Successfully configured ${modelType.displayName}');
    } catch (e) {
      LoggerService.error('ModelSelector: Error configuring ${modelType.displayName}: $e');
      rethrow;
    }
  }

  /// Generate text using the current model
  Future<String> generateWithAttachments(
    String prompt,
    List<PlatformFile> attachedFiles, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    if (_currentModel == null) {
      throw Exception('No model is currently selected. Please select a model first.');
    }

    // Check if model can handle the request
    if (!_currentModel!.canHandleRequest(attachedFiles: attachedFiles)) {
      throw Exception(_currentModel!.getCapabilityErrorMessage(attachedFiles: attachedFiles));
    }

    return await _currentModel!.generateWithAttachments(
      prompt,
      attachedFiles,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
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
    if (_currentModel == null) return false;
    
    return _currentModel!.canHandleRequest(
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
    if (_currentModel == null) {
      return 'No model is currently selected';
    }
    
    return _currentModel!.getCapabilityErrorMessage(
      attachedFiles: attachedFiles,
      requiresImageSupport: requiresImageSupport,
      requiresDocumentSupport: requiresDocumentSupport,
      requiresAudioSupport: requiresAudioSupport,
      requiresVideoSupport: requiresVideoSupport,
    );
  }

  /// Create a model instance for the given model type
  AIModel _createModel(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini25Flash:
        return GeminiModel();
      case ModelType.openaiCompatible:
        return OpenAIModel();
    }
  }
}
