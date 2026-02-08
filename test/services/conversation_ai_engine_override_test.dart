import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/services/conversation_ai_engine.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:get_it/get_it.dart';

// Mock ModelSelector
class MockModelSelector extends Mock implements ModelSelector {
  @override
  ModelConfig? get currentModelConfig =>
      super.noSuchMethod(
            Invocation.getter(#currentModelConfig),
            returnValue: null,
          )
          as ModelConfig?;

  @override
  Future<Map<String, dynamic>> generateWithToolsAndMessages(
    List<PromptMessage>? messages,
    List<Map<String, dynamic>>? tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) =>
      super.noSuchMethod(
            Invocation.method(
              #generateWithToolsAndMessages,
              [messages, tools],
              {
                #temperature: temperature,
                #topK: topK,
                #topP: topP,
                #maxOutputTokens: maxOutputTokens,
                #generationContext: generationContext,
              },
            ),
            returnValue: Future.value(<String, dynamic>{}),
          )
          as Future<Map<String, dynamic>>;
}

@GenerateMocks([ModelSelector])
void main() {
  final getIt = GetIt.instance;
  late MockModelSelector mockModelSelector;
  late ConversationAiEngine engine;

  setUp(() {
    getIt.reset();
    mockModelSelector = MockModelSelector();
    getIt.registerSingleton<ModelSelector>(mockModelSelector);
    engine = const ConversationAiEngine();
  });

  tearDown(() {
    getIt.reset();
  });

  test(
    'ConversationAiEngine should use overridden model ID in metadata',
    () async {
      // 1. Setup Global Model A
      final globalConfig = ModelConfig(
        id: 'model-a-global',
        type: ModelType.gemini,
        displayName: 'Model A',
      );
      when(mockModelSelector.currentModelConfig).thenReturn(globalConfig);

      // 2. Setup Override Model B
      final overrideConfig = ModelConfig(
        id: 'model-b-override',
        type: ModelType.gemini,
        displayName: 'Model B',
      );
      final context = GenerationContext();
      context.modelOverride = overrideConfig;

      // 3. Mock Generation Response
      // The generator returns content, but (currently) ModelSelector does NOT inject the ID.
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any as List<PromptMessage>?,
          any as List<Map<String, dynamic>>?,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => {
          'text': 'Response from Model B',
          'modelUsed': 'model-b-override',
        },
      );

      // 4. Call Engine
      final response = await engine.generate(
        request: PromptRequest(
          systemMessage: PromptMessage(role: PromptRole.system, content: 'sys'),
          conversationMessages: [],
          contextMessages: [],
        ),
        activeTools: {},
        enableTools: false,
        executeTool: (_, __, ___, ____) async => 'done',
        isCancelled: () => false,
        generationContext: context,
      );

      // 5. Assert
      // EXPECTATION: Metadata should reflect the OVERRIDE model ID (Model B)
      // CURRENT BUG: It uses global model ID (Model A)
      expect(response.metadata?['modelUsed'], equals('model-b-override'));
    },
  );
}
