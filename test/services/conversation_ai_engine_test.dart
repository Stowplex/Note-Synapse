import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/conversation_ai_engine.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

@GenerateMocks([ModelSelector])
import 'conversation_ai_engine_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockModelSelector mockModelSelector;
  late ConversationAiEngine engine;

  /// Helper to create a minimal PromptRequest for testing
  PromptRequest createTestRequest({String userMessage = 'Hello'}) {
    return PromptRequest(
      systemMessage: const PromptMessage(
        role: PromptRole.system,
        content: 'You are helpful',
      ),
      contextMessages: [],
      conversationMessages: [
        PromptMessage(role: PromptRole.user, content: userMessage),
      ],
    );
  }

  setUp(() async {
    await resetForTesting();
    mockModelSelector = MockModelSelector();
    getIt.registerSingleton<ModelSelector>(mockModelSelector);
    engine = const ConversationAiEngine();

    // Default: return null for currentModelConfig (Gemini path)
    when(mockModelSelector.currentModelConfig).thenReturn(null);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('ConversationAiEngine basic generation', () {
    test('returns text response when no tools needed', () async {
      // Arrange: Mock ModelSelector to return text response with no function_calls
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => {
            'text': 'Hello! How can I help you?',
            'function_calls': null,
            'parts_history': [],
          });

      // Act
      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: <String, List<McpTool>>{},
        enableTools: false,
        executeTool: (_, __, ___, ____) async => '',
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // Assert
      expect(result.content, equals('Hello! How can I help you?'));
      verify(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).called(1);
    });

    test('handles empty response', () async {
      // Arrange: Mock ModelSelector to return null/empty response
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => {
            'text': null,
            'function_calls': null,
            'parts_history': null,
          });

      // Act
      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: <String, List<McpTool>>{},
        enableTools: false,
        executeTool: (_, __, ___, ____) async => '',
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // Assert: Should return a fallback message when response is empty
      expect(
        result.content,
        equals('I was unable to generate a response. Please try again.'),
      );
    });

    test('throws immediately if cancelled at start', () async {
      // Arrange: Set isCancelled to return true immediately
      // No mock setup needed for generateWithToolsAndMessages since it
      // should throw before reaching that point

      // Act & Assert
      expect(
        () => engine.generate(
          request: createTestRequest(),
          activeTools: <String, List<McpTool>>{},
          enableTools: false,
          executeTool: (_, __, ___, ____) async => '',
          isCancelled: () => true, // Cancelled from the start
          generationContext: GenerationContext(),
        ),
        throwsA(isA<ConversationCancelledException>()),
      );

      // Verify that generateWithToolsAndMessages was never called
      verifyNever(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      ));
    });

    test('throws when cancelled during iteration', () async {
      // Arrange: Return a function_call first, then check cancelled
      var callCount = 0;

      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => {
            'text': null,
            'function_calls': [
              {
                'name': 'call_tool',
                'args': {
                  'service_name': 'test_service',
                  'tool_name': 'test_tool',
                  'params': <String, dynamic>{},
                },
              }
            ],
            'parts_history': [],
          });

      // Set isCancelled to return true after the first model response
      bool isCancelled() {
        callCount++;
        // First check (before loop) = false
        // Second check (inside _generateWithTools before loop) = false
        // Third check (after model response) = true
        return callCount > 2;
      }

      // Act & Assert
      expect(
        () => engine.generate(
          request: createTestRequest(),
          activeTools: <String, List<McpTool>>{
            'test_service': [
              McpTool(
                name: 'test_tool',
                description: 'A test tool',
                inputSchema: const {},
              ),
            ],
          },
          enableTools: true,
          executeTool: (_, __, ___, ____) async => 'tool result',
          isCancelled: isCancelled,
          generationContext: GenerationContext(),
        ),
        throwsA(isA<ConversationCancelledException>()),
      );
    });
  });
}
