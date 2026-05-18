import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/services/models/gemini_model.dart';
import 'package:note_synapse/services/models/openai_model.dart';

void main() {
  group('AIModel id contract', () {
    test('GeminiModel reports the concrete configured model id', () async {
      final model = GeminiModel();
      final config = ModelConfig(
        id: 'gemini-3-1-flash-lite-config',
        type: ModelType.gemini,
        apiKey: 'test-key',
        modelName: 'gemini-3.1-flash-lite-preview',
        displayName: 'Gemini 3.1 Flash Lite',
      );

      await model.initialize(config: config);

      expect(model.id, 'gemini-3-1-flash-lite-config');
    });

    test('OpenAIModel reports the concrete configured model id', () async {
      final model = OpenAIModel();
      final config = ModelConfig(
        id: 'openai-gpt-5-2-config',
        type: ModelType.openaiCompatible,
        apiKey: 'test-key',
        endpoint: 'https://api.example.test/v1',
        modelName: 'gpt-5.2',
        displayName: 'GPT-5.2',
      );

      await model.initialize(config: config);

      expect(model.id, 'openai-gpt-5-2-config');
    });
  });
}
