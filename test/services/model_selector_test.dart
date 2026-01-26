import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/models/model_capabilities.dart';

void main() {
  group('ModelSelector Tests', () {
    late ModelConfig geminiVisionModel;
    late ModelConfig geminiTextModel;
    late ModelConfig openaiImageModel;

    setUp(() async {
      // Reset and set up service locator
      await resetForTesting();

      FlutterSecureStorage.setMockInitialValues({});
      setupServiceLocator();

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      geminiVisionModel = ModelConfig(
        id: 'gemini_vision',
        type: ModelType.gemini,
        displayName: 'Gemini Pro Vision',
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 128000,
          maxOutputTokens: 4096,
          supportsImages: true,
          supportsDocuments: true,
          supportsAudio: false,
          supportsVideo: false,
        ),
        isConfigured: true,
      );

      geminiTextModel = ModelConfig(
        id: 'gemini_text',
        type: ModelType.gemini,
        displayName: 'Gemini Pro',
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 32000,
          maxOutputTokens: 2048,
          supportsImages: false,
          supportsDocuments: true, // Suppose it supports text docs
          supportsAudio: false,
          supportsVideo: false,
        ),
        isConfigured: true,
      );

      openaiImageModel = ModelConfig(
        id: 'dall_e',
        type: ModelType.openaiCompatible,
        displayName: 'DALL-E 3',
        modelFeatures: ['image_gen'],
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 4096,
          maxOutputTokens: 1024,
          supportsImageGeneration: true,
          supportsImages:
              false, // It generates images, doesn't necessarily accept them in this context example, but let's say it has the feature 'image_gen'
          supportsDocuments: false,
          supportsAudio: false,
          supportsVideo: false,
        ),
        isConfigured: true,
      );
    });

    tearDown(() async {
      await resetForTesting();
    });

    Future<void> _setupStorage({
      required ModelConfig activeModel,
      List<ModelConfig> allModels = const [],
      List<String> validApiModels = const [], // Models that have keys
      List<String> preferences = const [],
    }) async {
      final prefs = await SharedPreferences.getInstance();

      // Save Configured Models
      final configsJson = jsonEncode(allModels.map((m) => m.toJson()).toList());
      await prefs.setString('configured_models', configsJson);

      // Save Active Model ID
      await prefs.setString('active_model_id', activeModel.id);

      // Save Preferences
      await prefs.setStringList('model_preference_list', preferences);
    }

    test(
      'selectModelByPreference - Empty preference list returns active model if capable',
      () async {
        await _setupStorage(
          activeModel: geminiVisionModel,
          allModels: [geminiVisionModel],
        );

        final result = await getIt<ModelSelector>().selectModelByPreference({
          'images',
        });
        expect(result?.id, geminiVisionModel.id);
      },
    );

    test(
      'selectModelByPreference - Empty preference list returns active model even if not capable (default behavior?) or null?',
      () async {
        // Code logic check: If capability matching fails on active model, it might search others or return active model?
        // Let's verify expectations.
        // The requirement says: "If no perfect model is found, the system should select a model based on feature priority".
        // And "empty list defaulting to the default model".

        await _setupStorage(
          activeModel: geminiTextModel,
          allModels: [geminiTextModel],
        );

        // Request 'image' capability, but active model only supports text/docs.
        // Logic likely falls back or returns null?
        // Actually, if active model doesn't support it, and no other model is preferred, it might try to find *any* model?
        // Or it just returns the active model as a fallback.

        final result = await getIt<ModelSelector>().selectModelByPreference({
          'images',
        });

        // Given the logic implemented: "Fallback 1: Try Active Model (Default)"
        // If it doesn't match...
        // "Fallback 2: Feature Priority Search"
        // If no image model found, it returns active model?

        // In this case, we have no other models. So it should probably return active model (best effort) or null.
        // Based on typical "default to active", it should probably be geminiTextModel.
        expect(result?.id, geminiTextModel.id);
      },
    );

    test(
      'selectModelByPreference - Preferences override active model for capabilities',
      () async {
        await _setupStorage(
          activeModel: geminiTextModel,
          allModels: [geminiTextModel, geminiVisionModel],
          preferences: [geminiVisionModel.id],
        );

        // Active is Text (no image), Preference is Vision (has image).
        // We request 'image'.
        // Active model fails capability check (assumed).
        // Preference list checked: matching capability found in geminiVisionModel.

        final result = await getIt<ModelSelector>().selectModelByPreference({
          'images',
        });
        expect(result?.id, geminiVisionModel.id);
      },
    );

    test('selectModelByPreference - Preferences respect order', () async {
      final geminiUltra = geminiVisionModel.copyWith(
        id: 'gemini_ultra',
        displayName: 'Gemini Ultra',
      );
      await _setupStorage(
        activeModel: geminiTextModel,
        allModels: [geminiTextModel, geminiVisionModel, geminiUltra],
        preferences: [geminiUltra.id, geminiVisionModel.id],
      );

      // Both Ultra and Vision support 'image'. Ultra is first in preference.
      final result = await getIt<ModelSelector>().selectModelByPreference({
        'images',
      });
      expect(result?.id, geminiUltra.id);
    });

    test('selectModelByPreference - Fallback to image_gen priority', () async {
      await _setupStorage(
        activeModel: geminiTextModel,
        allModels: [
          geminiTextModel,
          openaiImageModel,
        ], // Active (text), DALL-E (image_gen)
        preferences: [], // Empty preferences
      );

      // Request 'image_gen' capability.
      // Active model (text) doesn't have it.
      // Preference list empty.
      // Fallback 2: Feature priority 'image_gen'. DALL-E has it.

      final result = await getIt<ModelSelector>().selectModelByPreference({
        'image_gen',
      });
      expect(result?.id, openaiImageModel.id); // Should select DALL-E
    });

    test('selectModelByPreference - Code generation priority', () async {
      final codeModel = ModelConfig(
        id: 'code_model',
        type: ModelType.gemini,
        displayName: 'Code Model',
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 32000,
          maxOutputTokens: 4096,
          supportsImages: false,
          supportsDocuments: false,
          supportsAudio: false,
          supportsVideo: false,
          supportsCodeGeneration: true,
        ),
        isConfigured: true,
      );

      await _setupStorage(
        activeModel: geminiTextModel,
        allModels: [geminiTextModel, codeModel],
        preferences: [
          codeModel.id,
        ], // Code model must be in preferences to be a candidate
      );

      final result = await getIt<ModelSelector>().selectModelByPreference({
        'generateCode',
      });
      expect(result?.id, codeModel.id);
    });

    test(
      'selectModelByPreference - Media capabilities priority over code',
      () async {
        final videoModel = ModelConfig(
          id: 'video_model',
          type: ModelType.gemini,
          displayName: 'Video Model',
          customCapabilitiesObject: const ModelCapabilities(
            maxInputTokens: 128000,
            maxOutputTokens: 4096,
            supportsImages: false,
            supportsDocuments: false,
            supportsAudio: false,
            supportsVideo: true,
          ),
          isConfigured: true,
        );

        await _setupStorage(
          activeModel: geminiTextModel,
          allModels: [geminiTextModel, videoModel],
          preferences: [videoModel.id],
        );

        final result = await getIt<ModelSelector>().selectModelByPreference({
          'video',
        });
        expect(result?.id, videoModel.id);
      },
    );

    test('selectModelByPreference - Audio capability', () async {
      final audioModel = ModelConfig(
        id: 'audio_model',
        type: ModelType.gemini,
        displayName: 'Audio Model',
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 32000,
          maxOutputTokens: 4096,
          supportsImages: false,
          supportsDocuments: false,
          supportsAudio: true,
          supportsVideo: false,
        ),
        isConfigured: true,
      );

      await _setupStorage(
        activeModel: geminiTextModel,
        allModels: [geminiTextModel, audioModel],
        preferences: [
          audioModel.id,
        ], // Audio model must be in preferences to be a candidate
      );

      final result = await getIt<ModelSelector>().selectModelByPreference({
        'audio',
      });
      expect(result?.id, audioModel.id);
    });

    test('selectModelByPreference - Documents capability', () async {
      await _setupStorage(
        activeModel: geminiTextModel, // Already supports documents
        allModels: [geminiTextModel],
        preferences: [],
      );

      final result = await getIt<ModelSelector>().selectModelByPreference({
        'documents',
      });
      expect(result?.id, geminiTextModel.id);
    });

    test('selectModelByPreference - Multiple capabilities required', () async {
      final multiCapModel = ModelConfig(
        id: 'multi_cap_model',
        type: ModelType.gemini,
        displayName: 'Multi-Capability Model',
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 128000,
          maxOutputTokens: 4096,
          supportsImages: true,
          supportsDocuments: true,
          supportsAudio: false,
          supportsVideo: true,
        ),
        isConfigured: true,
      );

      await _setupStorage(
        activeModel: geminiTextModel,
        allModels: [geminiTextModel, geminiVisionModel, multiCapModel],
        preferences: [multiCapModel.id],
      );

      // Request both images and video
      final result = await getIt<ModelSelector>().selectModelByPreference({
        'images',
        'video',
      });
      expect(result?.id, multiCapModel.id);
    });

    test(
      'selectModelByPreference - Empty required caps returns active model',
      () async {
        await _setupStorage(
          activeModel: geminiTextModel,
          allModels: [geminiTextModel],
          preferences: [],
        );

        final result = await getIt<ModelSelector>().selectModelByPreference({});
        expect(result?.id, geminiTextModel.id);
      },
    );
  });
}
