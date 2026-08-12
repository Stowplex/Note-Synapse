import 'package:file_picker/file_picker.dart';
import '../services/attachment_preprocessor.dart';
import '../providers/app_provider.dart';
import 'models/ai_model.dart';
import 'models/gemini_model.dart';
import 'models/openai_model.dart';
import 'models/local_mnn_model.dart';
import 'model_storage_service.dart';
import '../utils/token_estimator.dart';
import 'logger_service.dart';
import 'prompts/prompt_models.dart';
import '../models/mcp_endpoint.dart';
import '../models/model_type.dart';
import '../models/model_config.dart';
import '../models/generation_context.dart';
import 'model_preference_service.dart';

typedef AIModelFactory = AIModel Function(ModelType modelType);

/// Service for selecting and managing AI models
class ModelSelector {
  final ModelStorageService _modelStorage;
  final ModelPreferenceService _modelPreference;
  final AIModelFactory? _modelFactory;

  ModelSelector(
    this._modelStorage,
    this._modelPreference, {
    AIModelFactory? modelFactory,
  }) : _modelFactory = modelFactory;

  AIModel? _currentModel;
  ModelConfig? _currentModelConfig;

  /// Cache for models by their unique config ID
  final Map<String, AIModel> _modelCache = {};

  /// Get the current model
  AIModel? get currentModel => _currentModel;

  /// Get the current model config
  ModelConfig? get currentModelConfig => _currentModelConfig;

  /// Ensures a model is selected and initialized
  Future<AIModel> _ensureModelAvailable() async {
    if (_currentModel != null) {
      final isReady = await _currentModel!.isReady();
      if (isReady) return _currentModel!;
    }

    // Try to recover from config
    if (_currentModelConfig != null) {
      await switchToModel(_currentModelConfig!);
      if (_currentModel != null) return _currentModel!;
    }

    // Try to load from storage
    final config = await _modelStorage.getActiveModel();
    if (config != null) {
      await switchToModel(config);
      if (_currentModel != null) return _currentModel!;
    }

    throw Exception(
      'No model is currently selected. Please select a model first in settings.',
    );
  }

  /// Dispose of all cached models
  Future<void> dispose() async {
    for (final model in _modelCache.values) {
      await model.dispose();
    }
    // We do NOT clear _modelCache or _currentModel pointers here.
    // The models themselves (e.g. LocalMnnModel) will handle re-initialization
    // of their internal runtimes on the next generation call if needed.
  }

  /// Initialize with the selected model
  Future<void> initialize(AppProvider appProvider) async {
    try {
      // Try to get from provider first, then storage
      final selectedConfig =
          appProvider.modelConfig ?? await _modelStorage.getActiveModel();

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

      // Get or create model instance from cache
      var model = _modelCache[config.id];
      if (model == null) {
        model = _createModel(config.type);
        LoggerService.debug(
          'ModelSelector: Created new model instance: ${model.runtimeType}',
        );
        _modelCache[config.id] = model;
      } else {
        LoggerService.debug(
          'ModelSelector: Using cached model instance: ${model.runtimeType}',
        );
      }

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
      await _modelStorage.activateModel(config.id);

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

    AIModel? modelToUse;

    // If override is provided, get or create from cache
    if (modelOverride != null) {
      LoggerService.debug(
        'ModelSelector: Using model override: ${modelOverride.displayName} (${modelOverride.id})',
      );
      try {
        var tempModel = _modelCache[modelOverride.id];
        if (tempModel == null) {
          tempModel = _createModel(modelOverride.type);
          _modelCache[modelOverride.id] = tempModel;
        }
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

    // Fallback to default model if no override or override not ready
    modelToUse ??= await _ensureModelAvailable();

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

    AIModel? modelToUse;

    if (modelOverride != null) {
      try {
        var tempModel = _modelCache[modelOverride.id];
        if (tempModel == null) {
          tempModel = _createModel(modelOverride.type);
          _modelCache[modelOverride.id] = tempModel;
        }
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

    modelToUse ??= await _ensureModelAvailable();

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

    // Auto-select model based on capabilities if no override is set
    if (context.modelOverride == null) {
      final allMessages = [
        request.systemMessage,
        ...request.contextMessages,
        ...request.conversationMessages,
      ];
      await _autoSelectModelForCapabilities(allMessages, context);
    }

    final modelOverride = context.modelOverride;

    AIModel? modelToUse;

    if (modelOverride != null) {
      try {
        var tempModel = _modelCache[modelOverride.id];
        if (tempModel == null) {
          tempModel = _createModel(modelOverride.type);
          _modelCache[modelOverride.id] = tempModel;
        }
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

    modelToUse ??= await _ensureModelAvailable();

    return await modelToUse.generateFromPrompt(
      request,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

  /// Generates with exactly [config], failing closed if that model cannot be
  /// initialized. Unlike [generateFromPrompt], this method never auto-selects
  /// or falls back to the active model.
  ///
  /// Protocol Study uses this after showing the user the exact local/remote
  /// destination and outbound field preview. Falling back after that approval
  /// would send the payload somewhere the user did not approve.
  Future<String> generateFromPromptExact(
    PromptRequest request, {
    required ModelConfig config,
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    context.modelOverride = config;
    var model = _modelCache[config.id];
    model ??= _createModel(config.type);
    _modelCache[config.id] = model;
    await model.initialize(config: config);
    if (!await model.isReady()) {
      throw StateError(
        'Approved model ${config.displayName ?? config.id} is not ready.',
      );
    }
    return model.generateFromPrompt(
      request,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

  /// Generate a multi-part response from a prompt request.
  ///
  /// Returns a list of parts where each part is a map with 'type' ('text' or 'image')
  /// and 'content' (text string or base64 data URL for images).
  Future<List<Map<String, dynamic>>> generateFromPromptMultiPart(
    PromptRequest request, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();

    // Auto-select model based on capabilities if no override is set
    if (context.modelOverride == null) {
      final allMessages = [
        request.systemMessage,
        ...request.contextMessages,
        ...request.conversationMessages,
      ];
      await _autoSelectModelForCapabilities(allMessages, context);
    }

    final modelOverride = context.modelOverride;

    AIModel? modelToUse;

    if (modelOverride != null) {
      try {
        var tempModel = _modelCache[modelOverride.id];
        if (tempModel == null) {
          tempModel = _createModel(modelOverride.type);
          _modelCache[modelOverride.id] = tempModel;
        }
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

    modelToUse ??= await _ensureModelAvailable();

    // Check if the model supports multi-part response
    if (modelToUse is GeminiModel) {
      return await modelToUse.generateFromPromptMultiPart(
        request,
        temperature: temperature,
        topK: topK,
        topP: topP,
        maxOutputTokens: maxOutputTokens,
        generationContext: context,
      );
    }

    // For models that don't support multi-part, fall back to text-only response
    final textResponse = await modelToUse.generateFromPrompt(
      request,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );

    return [
      {'type': 'text', 'content': textResponse},
    ];
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

    // Auto-select model based on capabilities
    if (context.modelOverride == null) {
      // Create a temporary message to check capabilities for this prompt + attachments
      final tempMsg = PromptMessage(
        role: PromptRole.user,
        content: prompt,
        attachments: attachedFiles,
      );
      await _autoSelectModelForCapabilities([tempMsg], context);
    }

    final modelOverride = context.modelOverride;

    AIModel? modelToUse;

    if (modelOverride != null) {
      try {
        var tempModel = _modelCache[modelOverride.id];
        if (tempModel == null) {
          tempModel = _createModel(modelOverride.type);
          _modelCache[modelOverride.id] = tempModel;
        }
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

    modelToUse ??= await _ensureModelAvailable();

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

  List<Map<String, dynamic>> buildToolDeclarations(
    Map<String, List<McpTool>> toolsByEndpoint, {
    GenerationContext? generationContext,
  }) {
    final modelOverride = generationContext?.modelOverride;
    AIModel? model;
    if (modelOverride != null) {
      model = _modelCache[modelOverride.id];
      if (model == null) {
        model = _createModel(modelOverride.type);
        _modelCache[modelOverride.id] = model;
      }
    }

    // Fallback to current model if no override or instance not in cache
    model ??= _currentModel;

    return model?.buildToolDeclarations(toolsByEndpoint) ?? [];
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

    // Auto-select model based on capabilities if no override is set
    if (context.modelOverride == null) {
      await _autoSelectModelForCapabilities(messages, context);
    }

    final modelOverride = context.modelOverride;

    AIModel? modelToUse;

    if (modelOverride != null) {
      try {
        var tempModel = _modelCache[modelOverride.id];
        if (tempModel == null) {
          tempModel = _createModel(modelOverride.type);
          _modelCache[modelOverride.id] = tempModel;
        }
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

    modelToUse ??= await _ensureModelAvailable();

    final response = await modelToUse.generateWithToolsAndMessages(
      messages,
      tools,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );

    // Inject the actual model ID used into the response metadata
    // This ensures we track overrides correctly
    final mutableResponse = Map<String, dynamic>.from(response);
    mutableResponse['modelUsed'] = modelToUse.id;
    return mutableResponse;
  }

  /// Helper to auto-select a model based on capabilities found in messages
  Future<void> _autoSelectModelForCapabilities(
    List<PromptMessage> messages,
    GenerationContext context,
  ) async {
    final allAttachments = <PlatformFile>[];
    final allContent = StringBuffer();

    // Collect attachments and content from messages
    for (final msg in messages) {
      allAttachments.addAll(msg.attachments);
      allContent.write(msg.content);
    }

    // Start with explicitly provided hints from context
    final Set<String> caps = {};
    if (context.getValue<List<String>>('modelHints') != null) {
      caps.addAll(context.getValue<List<String>>('modelHints')!);
    }

    final detectedCaps =
        await AttachmentPreprocessor.detectRequiredCapabilities(allAttachments);
    caps.addAll(detectedCaps);

    if (caps.isNotEmpty) {
      final preferredModel = await selectModelByPreference(caps);
      if (preferredModel != null) {
        LoggerService.debug(
          'ModelSelector: Auto-selected model ${preferredModel.displayName} based on capabilities: $caps',
        );
        context.modelOverride = preferredModel;
      }
    }
  }

  /// Create a model instance for the given model type
  AIModel _createModel(ModelType modelType) {
    final factory = _modelFactory;
    if (factory != null) return factory(modelType);
    switch (modelType) {
      case ModelType.gemini:
        return GeminiModel();
      case ModelType.openaiCompatible:
        return OpenAIModel();
      case ModelType.localMnn:
        return LocalMnnModel();
    }
  }

  /// Estimates total tokens for a request and checks against local model's token window.
  /// Returns null if within limits, or a warning message if over.
  String? checkLocalModelConstraints(
    List<PromptMessage> messages,
    ModelConfig config,
  ) {
    if (config.type != ModelType.localMnn) return null;
    final tokenWindow = config.tokenWindow ?? 16384;

    int estimatedTokens = 0;
    for (final msg in messages) {
      estimatedTokens += TokenEstimator.estimateTokens(msg.content);
    }

    if (estimatedTokens > tokenWindow) {
      return 'Estimated input (~${(estimatedTokens / 1024).toStringAsFixed(1)}K tokens) '
          'exceeds local model token window (${(tokenWindow / 1024).toStringAsFixed(0)}K).';
    }
    return null;
  }

  /// Find a model with specified capability hints.
  ///
  /// Priority:
  /// 1. First checks the current model (or overridden model) - if it matches, returns null
  ///    (caller should use the current model as-is, no override needed)
  /// 2. If current model doesn't match, searches configured models for a match
  ///
  /// Supported hints:
  /// - 'image_gen': Model supports image generation
  /// - 'tts': Model supports speech (audio) generation
  /// - 'audio': Model supports audio processing
  /// - 'video': Model supports video processing
  /// - 'documents': Model supports document understanding
  /// - 'images': Model supports image input
  ///
  /// Returns null if current model matches (no override needed) or no model found.
  /// Returns a ModelConfig if an alternative model with the capability was found.
  Future<ModelConfig?> getModelByHint(
    List<String> hints, {
    ModelConfig? currentOverride,
  }) async {
    if (hints.isEmpty) return null;

    // First, check the current model or override
    final currentConfig = currentOverride ?? _currentModelConfig;
    if (currentConfig != null && _modelMatchesHints(currentConfig, hints)) {
      LoggerService.debug(
        'ModelSelector: Current model ${currentConfig.displayName} matches hints $hints, no override needed',
      );
      return null; // Current model is fine, no need to override
    }

    // Current model doesn't match, search for an alternative
    final models = await _modelStorage.getConfiguredModels();
    for (final model in models) {
      if (_modelMatchesHints(model, hints)) {
        LoggerService.debug(
          'ModelSelector: Found alternative model matching hints $hints: ${model.displayName}',
        );
        return model;
      }
    }
    LoggerService.debug('ModelSelector: No model found matching hints $hints');
    return null;
  }

  bool _modelMatchesHints(ModelConfig model, List<String> hints) {
    if (hints.isEmpty) return true;

    final caps = model.customCapabilitiesObject;
    if (caps == null) return false;

    for (final hint in hints) {
      switch (hint) {
        case 'images':
          if (!caps.supportsImages) return false;
          break;
        case 'video':
          if (!caps.supportsVideo) return false;
          break;
        case 'audio':
          if (!caps.supportsAudio) return false;
          break;
        case 'documents':
          if (!caps.supportsDocuments) return false;
          break;
        case 'image_gen':
          if (!caps.supportsImageGeneration) return false;
          break;
        case 'tts':
          if (!caps.supportsSpeechGeneration) return false;
          break;
        case 'generateCode':
          if (!caps.supportsCodeGeneration) return false;
          break;
        // Ignore unknown hints
      }
    }
    return true;
  }

  /// Select model based on preference list and required capabilities.
  /// Candidates = [Active Model] + [Preference List]
  /// Priority:
  /// 1. Perfect Match (supports ALL required caps)
  /// 2. Media Capabilities (Video, Image, Audio, Documents) - Strongest priority
  /// 3. Image Generation - Medium priority
  /// 4. Code Generation - Lower priority
  ///
  /// If no perfect match:
  /// - If media required: Find model supporting media (ignoring other missing caps if needed, but primarily focusing on media support).
  /// - If image_gen required: Find model supporting image_gen.
  /// - If generateCode required: Find model supporting generateCode.
  /// - Fallback: Active/Default model.
  Future<ModelConfig?> selectModelByPreference(Set<String> requiredCaps) async {
    // 1. Prepare candidates: Active Model + Preference List
    final activeModel = await _modelStorage.getActiveModel();
    if (activeModel == null) {
      return null; // Should not happen if app initialized
    }

    final preferenceListIds = await _modelPreference.getPreferenceList();
    final allModels = await _modelStorage.getConfiguredModels();

    final candidates = <ModelConfig>[
      activeModel,
      ...preferenceListIds
          .map(
            (id) => allModels.firstWhere(
              (m) => m.id == id,
              orElse: () =>
                  activeModel, // Fallback to active to avoid null, filtered out later if needed or assumes distinct IDs usually
            ),
          )
          .where(
            (m) => m.id != activeModel.id,
          ), // Avoid duplicates if active is in preference list
    ];

    // 2. Find perfect match in candidates
    for (final model in candidates) {
      if (_modelMatchesHints(model, requiredCaps.toList())) {
        // Interesting log check: Is this the active model?
        if (model.id != activeModel.id) {
          _logSelection(model, 'perfect_match', requiredCaps);
        }
        return model;
      }
    }

    // 3. No perfect match - fallback by priority

    // Priority A: Media Capabilities (Video, Image, Audio, Documents)
    // These are critical for understanding input. If missing, the model fails to process request.
    final mediaCaps = requiredCaps.intersection({
      'video',
      'images',
      'audio',
      'documents',
    });
    if (mediaCaps.isNotEmpty) {
      for (final model in candidates) {
        // Check if model supports ALL required media types
        bool supportsMedia = true;
        for (final cap in mediaCaps) {
          if (!_modelMatchesHints(model, [cap])) {
            supportsMedia = false;
            break;
          }
        }

        if (supportsMedia) {
          _logSelection(model, 'media_caps_priority', requiredCaps);
          return model;
        }
      }
      // If no candidate supports all media, we might want to fall through or return null?
      // For now, fall through to other checks or default.
    }

    // Priority B: Image Generation
    if (requiredCaps.contains('image_gen')) {
      // Try to find image gen support in candidates first
      for (final model in candidates) {
        if (model.customCapabilitiesObject?.supportsImageGeneration == true) {
          _logSelection(model, 'image_gen_priority_candidate', requiredCaps);
          return model;
        }
      }

      // Then try any configured model (global search)
      for (final model in allModels) {
        if (candidates.any((c) => c.id == model.id)) continue;

        if (model.customCapabilitiesObject?.supportsImageGeneration == true) {
          _logSelection(model, 'image_gen_priority_global', requiredCaps);
          return model;
        }
      }
    }

    // Priority B2: Speech Generation (TTS)
    if (requiredCaps.contains('tts')) {
      // Try to find speech gen support in candidates first
      for (final model in candidates) {
        if (model.customCapabilitiesObject?.supportsSpeechGeneration == true) {
          _logSelection(model, 'tts_priority_candidate', requiredCaps);
          return model;
        }
      }

      // Then try any configured model (global search)
      for (final model in allModels) {
        if (candidates.any((c) => c.id == model.id)) continue;

        if (model.customCapabilitiesObject?.supportsSpeechGeneration == true) {
          _logSelection(model, 'tts_priority_global', requiredCaps);
          return model;
        }
      }
    }

    // Priority C: Code Generation
    // Only checked if media/image_gen didn't force a decision (or weren't required).
    // Or if they were required but no model found, we still check this?
    // Logic: If I need [Image, Code], and I found no [Image, Code] perfect match.
    // I checked [Image] capability above. If I found an Image model, I returned it.
    // So here I only reach if:
    // 1. No media caps required.
    // OR
    // 2. Media caps required but found NO model supporting them (unlikely, but possible).

    if (requiredCaps.contains('generateCode')) {
      for (final model in candidates) {
        if (model.customCapabilitiesObject?.supportsCodeGeneration == true) {
          _logSelection(model, 'code_gen_priority', requiredCaps);
          return model;
        }
      }
    }

    // 4. Fallback to active model (default)
    return activeModel;
  }

  void _logSelection(
    ModelConfig model,
    String reason,
    Set<String> requiredCaps,
  ) {
    LoggerService.logAiRequest(
      endpoint: 'model_preference_selection',
      headers: {},
      requestBody: {
        'action': 'model_selected',
        'selectedModel': model.displayName,
        'reason': reason,
        'requiredCaps': requiredCaps.toList(),
      },
      // Generate a temporary ID if not in a request context yet, or pass from caller
    );
  }
}
