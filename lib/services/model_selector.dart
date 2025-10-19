import 'package:file_picker/file_picker.dart';
import '../providers/app_provider.dart';
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
  Future<void> initialize(AppProvider appProvider) async {
    try {
      final selectedModel = appProvider.modelConfig?.type ?? await ModelStorageService.getSelectedModel();
      if (selectedModel != null) {
        LoggerService.debug('ModelSelector: Selected model from storage: ${selectedModel.displayName}');

        await switchToModel(selectedModel, config: appProvider.modelConfig);
        LoggerService.debug('ModelSelector: Successfully initialized with ${selectedModel.displayName}');
      } else {
        LoggerService.debug('ModelSelector: No model selected.');
      }
    } catch (e) {
      LoggerService.error('ModelSelector: Error during initialization with selected model: $e');
    }
  }

  /// Switch to a different model
  Future<void> switchToModel(ModelType modelType, {ModelConfig? config}) async {
    try {
      LoggerService.debug('ModelSelector: Switching to ${modelType.displayName}');
      LoggerService.debug('ModelSelector: Previous model was: ${_currentModelType?.displayName ?? "None"}');

      // Create model instance
      final model = _createModel(modelType);
      LoggerService.debug('ModelSelector: Created model: ${model.runtimeType}');

      // Initialize the model
      LoggerService.debug('ModelSelector: About to initialize model...');
      await model.initialize(config: config);
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

    // Model will handle capability limitations gracefully through limitation notes
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


  /// Create a model instance for the given model type
  AIModel _createModel(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini:
        return GeminiModel();
      case ModelType.openaiCompatible:
        return OpenAIModel();
    }
  }
}
