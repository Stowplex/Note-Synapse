import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/logger_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/models/model_capabilities.dart';
import 'package:note_synapse/providers/app_provider.dart';

// Mock AppProvider since initialization requires it
class MockAppProvider extends Mock implements AppProvider {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ModelConfig geminiTextModel;
  late ModelConfig geminiVisionModel;
  late ModelConfig geminiAudioModel;

  setUp(() async {
    // 1. Setup temporary directory for file I/O
    tempDir = await Directory.systemTemp.createTemp('ai_service_test');

    // 2. Clear logs
    LoggerService.clearAiLogBucket();

    // 3. Clear SharedPreferences
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    // 4. Define Models
    geminiTextModel = ModelConfig(
      id: 'gemini_text',
      type: ModelType.gemini,
      modelName: 'gemini-pro',
      displayName: 'Gemini Pro',
      isConfigured: true,
      customCapabilitiesObject: const ModelCapabilities(
        maxInputTokens: 4096,
        maxOutputTokens: 1024,
        supportsImages: false,
        supportsAudio: false,
        supportsVideo: false,
        supportsDocuments: false,
      ),
    );

    geminiVisionModel = ModelConfig(
      id: 'gemini_vision',
      type: ModelType.gemini,
      modelName: 'gemini-pro-vision',
      displayName: 'Gemini Vision',
      isConfigured: true,
      customCapabilitiesObject: const ModelCapabilities(
        maxInputTokens: 4096,
        maxOutputTokens: 1024,
        supportsImages: true,
        supportsAudio: false,
        supportsVideo: false,
        supportsDocuments: false,
      ),
    );

    geminiAudioModel = ModelConfig(
      id: 'gemini_audio',
      type: ModelType.gemini,
      modelName: 'gemini-audio-model',
      displayName: 'Gemini Audio',
      isConfigured: true,
      customCapabilitiesObject: const ModelCapabilities(
        maxInputTokens: 4096,
        maxOutputTokens: 1024,
        supportsImages: false,
        supportsAudio: true,
        supportsVideo: false,
        supportsDocuments: false,
      ),
    );

    // 5. Save models to storage (via SharedPreferences)
    // Active model is Text Only
    await ModelStorageService.addModel(geminiTextModel);
    await ModelStorageService.activateModel(geminiTextModel.id);

    // Save capability models
    await ModelStorageService.addModel(geminiVisionModel);
    await ModelStorageService.addModel(geminiAudioModel);

    // 6. Set Preferences: Prefer Audio and Vision models
    await prefs.setStringList('model_preference_list', [
      geminiVisionModel.id,
      geminiAudioModel.id,
    ]);

    // 7. Initialize AIService
    // Note: ModelSelector singleton persists, so re-init updates it.
    await AIService.initialize(MockAppProvider());

    // Wait slightly for async init if any
    await Future.delayed(Duration(milliseconds: 50));
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('AIService Wiring Tests', () {
    test('extractContentFromImage triggers preference selection', () async {
      // Create a dummy image file
      final imageFile = File('${tempDir.path}/test_image.jpg');
      await imageFile.writeAsBytes([1, 2, 3]); // Dummy bytes

      try {
        await AIService.extractContentFromImage(imageFile.path);
      } catch (e) {
        // Expected to fail at network step, but we check logs
      }

      // Verify that selection logic ran and picked Vision model
      final logs = LoggerService.aiLogBucket;
      final selectionLog = logs.firstWhere(
        (l) => l.endpoint == 'model_preference_selection',
        orElse: () => throw Exception('Selection log not found'),
      );

      final data = selectionLog.data['body'] as Map<String, dynamic>;
      expect(data['action'], 'model_selected');
      expect(data['selectedModel'], 'Gemini Vision');
      expect(data['requiredCaps'], contains('images'));
    });

    test('transcribeAudio triggers preference selection', () async {
      // Create a dummy audio file
      final audioFile = File('${tempDir.path}/test_audio.mp3');
      await audioFile.writeAsBytes([1, 2, 3]);

      try {
        await AIService.transcribeAudio(audioFile.path);
      } catch (e) {
        // Network will fail
      }

      final logs = LoggerService.aiLogBucket;
      final selectionLog = logs.firstWhere(
        (l) => l.endpoint == 'model_preference_selection',
        orElse: () => throw Exception('Selection log not found'),
      );

      final data = selectionLog.data['body'] as Map<String, dynamic>;
      expect(data['action'], 'model_selected');
      expect(data['selectedModel'], 'Gemini Audio');
      expect(data['requiredCaps'], contains('audio'));
    });
  });
}
