import 'package:file_picker/file_picker.dart';
import '../providers/app_provider.dart';
import 'models/ai_model.dart';
import 'models/gemini_model.dart';
import 'models/openai_model.dart';
import 'model_storage_service.dart';
import 'logger_service.dart';
import 'prompts/prompt_models.dart';
import '../models/model_type.dart';
import '../models/model_config.dart';
import '../models/generation_context.dart';

/// Service for selecting and managing AI models
class ModelSelector {
  static ModelSelector? _instance;
  static ModelSelector get instance => _instance ??= ModelSelector._();

  ModelSelector._();

  AIModel? _currentModel;
  ModelConfig? _currentModelConfig;

  /// Get the current model
  AIModel? get currentModel => _currentModel;

  /// Get the current model config
  ModelConfig? get currentModelConfig => _currentModelConfig;

  /// Initialize with the selected model
  Future<void> initialize(AppProvider appProvider) async {
    try {
      // Try to get from provider first, then storage
      final selectedConfig =
          appProvider.modelConfig ?? await ModelStorageService.getActiveModel();

      if (selectedConfig != null) {
        LoggerService.debug(
          'ModelSelector: Selected model from storage: ${selectedConfig.displayName} (${selectedConfig.id})',
        );

        await switchToModel(selectedConfig);
        LoggerService.debug(
          'ModelSelector: Successfully initialized with ${selectedConfig.displayName}',
        );
      } else {
        LoggerService.debug('ModelSelector: No model selected.');
      }
    } catch (e) {
      LoggerService.error(
        'ModelSelector: Error during initialization with selected model: $e',
      );
    }
  }

  /// Switch to a different model
  Future<void> switchToModel(ModelConfig config) async {
    try {
      LoggerService.debug(
        'ModelSelector: Switching to ${config.displayName} (${config.id})',
      );
      LoggerService.debug(
        'ModelSelector: Previous model was: ${_currentModelConfig?.displayName ?? "None"}',
      );

      // Create model instance
      final model = _createModel(config.type);
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
        throw Exception(
          '${config.displayName} is not ready. Please configure it first.',
        );
      }

      // Update current model
      LoggerService.debug('ModelSelector: Updating current model...');
      _currentModel = model;
      _currentModelConfig = config;

      // Save selection
      LoggerService.debug('ModelSelector: Saving model selection...');
      await ModelStorageService.activateModel(config.id);

      LoggerService.debug(
        'ModelSelector: Successfully switched to ${config.displayName}',
      );
    } catch (e) {
      LoggerService.error(
        'ModelSelector: Error switching to ${config.displayName}: $e',
      );
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
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final modelOverride = context.modelOverride;

    AIModel? modelToUse = _currentModel;

    // If override is provided, create a temporary model instance
    if (modelOverride != null) {
      LoggerService.debug(
        'ModelSelector: Using model override: ${modelOverride.displayName} (${modelOverride.id})',
      );
      try {
        final tempModel = _createModel(modelOverride.type);
        await tempModel.initialize(config: modelOverride);
        if (await tempModel.isReady()) {
          modelToUse = tempModel;
        } else {
          LoggerService.warning(
            'ModelSelector: Override model ${modelOverride.displayName} is not ready. Falling back to current model.',
          );
        }
      } catch (e) {
        LoggerService.error(
          'ModelSelector: Failed to initialize override model: $e. Falling back to current model.',
        );
      }
    }

    if (modelToUse == null) {
      throw Exception(
        'No model is currently selected. Please select a model first.',
      );
    }

    // Model will handle capability limitations gracefully through limitation notes
    return await modelToUse.generateWithAttachments(
      prompt,
      attachedFiles,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

  /// Generate text using messages array (for conversations)
  Future<String> generateWithMessages(
    List<PromptMessage> messages, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final modelOverride = context.modelOverride;

    AIModel? modelToUse = _currentModel;

    if (modelOverride != null) {
      try {
        final tempModel = _createModel(modelOverride.type);
        await tempModel.initialize(config: modelOverride);
        if (await tempModel.isReady()) {
          modelToUse = tempModel;
        }
      } catch (e) {
        LoggerService.error(
          'ModelSelector: Failed to initialize override model: $e',
        );
      }
    }

    if (modelToUse == null) {
      throw Exception(
        'No model is currently selected. Please select a model first.',
      );
    }

    return await modelToUse.generateWithMessages(
      messages,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

  Future<String> generateFromPrompt(
    PromptRequest request, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final modelOverride = context.modelOverride;

    AIModel? modelToUse = _currentModel;

    if (modelOverride != null) {
      try {
        final tempModel = _createModel(modelOverride.type);
        await tempModel.initialize(config: modelOverride);
        if (await tempModel.isReady()) {
          modelToUse = tempModel;
        }
      } catch (e) {
        LoggerService.error(
          'ModelSelector: Failed to initialize override model: $e',
        );
      }
    }

    if (modelToUse == null) {
      throw Exception(
        'No model is currently selected. Please select a model first.',
      );
    }

    return await modelToUse.generateFromPrompt(
      request,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

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
    final modelOverride = context.modelOverride;

    AIModel? modelToUse = _currentModel;

    if (modelOverride != null) {
      try {
        final tempModel = _createModel(modelOverride.type);
        await tempModel.initialize(config: modelOverride);
        if (await tempModel.isReady()) {
          modelToUse = tempModel;
        }
      } catch (e) {
        LoggerService.error(
          'ModelSelector: Failed to initialize override model: $e',
        );
      }
    }

    if (modelToUse == null) {
      throw Exception(
        'No model is currently selected. Please select a model first.',
      );
    }

    return await modelToUse.generateWithTools(
      prompt,
      attachedFiles,
      tools,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

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
    final modelOverride = context.modelOverride;

    AIModel? modelToUse = _currentModel;

    if (modelOverride != null) {
      try {
        final tempModel = _createModel(modelOverride.type);
        await tempModel.initialize(config: modelOverride);
        if (await tempModel.isReady()) {
          modelToUse = tempModel;
        }
      } catch (e) {
        LoggerService.error(
          'ModelSelector: Failed to initialize override model: $e',
        );
      }
    }

    if (modelToUse == null) {
      throw Exception(
        'No model is currently selected. Please select a model first.',
      );
    }

    return await modelToUse.generateWithToolsAndMessages(
      messages,
      tools,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
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
