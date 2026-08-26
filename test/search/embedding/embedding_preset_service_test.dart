import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/search/embedding/embedding_preset_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EmbeddingPresetService', () {
    test('instance getter returns singleton', () {
      expect(
        identical(
          EmbeddingPresetService.instance,
          EmbeddingPresetService.instance,
        ),
        isTrue,
      );
    });

    test('loads the bundled presets with expected fields', () async {
      final presets = await EmbeddingPresetService.instance.loadPresets(
        forceRefresh: true,
      );

      expect(presets.length, greaterThanOrEqualTo(4));

      final gemini001 = presets.firstWhere(
        (p) => p.modelName == 'gemini-embedding-001',
      );
      expect(gemini001.type, 'gemini');
      expect(
        gemini001.endpoint,
        'https://generativelanguage.googleapis.com/v1beta',
      );
      expect(gemini001.dimensions, 768);
      expect(gemini001.supportsImages, isFalse);
      expect(gemini001.supportsBatch, isTrue);
      expect(gemini001.apiKeyUrl, 'https://aistudio.google.com/app/apikey');
      expect(gemini001.providerKey, 'gemini:gemini-embedding-001:768');

      final gemini2 = presets.firstWhere(
        (p) => p.modelName == 'gemini-embedding-2',
      );
      expect(gemini2.supportsImages, isTrue);
      expect(gemini2.supportsBatch, isFalse);

      final openai = presets.firstWhere(
        (p) => p.modelName == 'text-embedding-3-small',
      );
      expect(openai.type, 'openai');
      expect(openai.endpoint, 'https://api.openai.com');
      expect(openai.dimensions, 1536);
      expect(openai.supportsImages, isFalse);
      expect(openai.sendDimensions, isTrue);

      final local = presets.firstWhere(
        (p) => p.modelName == 'embeddinggemma-300m',
      );
      expect(local.type, 'local');
      expect(local.dimensions, 768);
      expect(local.supportsImages, isFalse);
      expect(
        local.modelUrl,
        'https://huggingface.co/litert-community/embeddinggemma-300m/'
        'resolve/main/embeddinggemma-300M_seq512_mixed-precision.tflite',
      );
      expect(
        local.tokenizerUrl,
        'https://huggingface.co/litert-community/embeddinggemma-300m/'
        'resolve/main/sentencepiece.model',
      );
      expect(local.apiKeyUrl, 'https://huggingface.co/settings/tokens');
      expect(local.providerKey, 'local:embeddinggemma-300m:768');
    });

    test('getPreset finds by type + model name', () async {
      final preset = await EmbeddingPresetService.instance.getPreset(
        'openai',
        'text-embedding-3-small',
      );
      expect(preset, isNotNull);
      expect(preset!.displayName, 'OpenAI Text Embedding 3 Small');

      final missing = await EmbeddingPresetService.instance.getPreset(
        'gemini',
        'nope',
      );
      expect(missing, isNull);
    });

    test('local preset lacking model_url/tokenizer_url is skipped '
        '(it could never install)', () async {
      final fixtures = <String, String>{
        'assets/embedding_presets/local_no_model_url.yaml': '''
model_type: local
model_name: broken-no-model-url
model_display_name: Broken (no model_url)
dimensions: 768
tokenizer_url: https://example.com/tokenizer.model
''',
        'assets/embedding_presets/local_no_tokenizer_url.yaml': '''
model_type: local
model_name: broken-no-tokenizer-url
model_display_name: Broken (no tokenizer_url)
dimensions: 768
model_url: https://example.com/model.tflite
''',
        'assets/embedding_presets/local_valid.yaml': '''
model_type: local
model_name: valid-local
model_display_name: Valid Local
dimensions: 768
model_url: https://example.com/model.tflite
tokenizer_url: https://example.com/tokenizer.model
''',
      };
      final service = EmbeddingPresetService.forTesting(
        listAssets: () async => fixtures.keys.toList(),
        loadAsset: (key) async => fixtures[key]!,
      );

      final presets = await service.loadPresets(forceRefresh: true);

      // Only the preset with BOTH download URLs survives.
      expect(presets, hasLength(1));
      expect(presets.single.modelName, 'valid-local');
      expect(presets.single.modelUrl, 'https://example.com/model.tflite');
      expect(
        presets.single.tokenizerUrl,
        'https://example.com/tokenizer.model',
      );
    });
  });
}
