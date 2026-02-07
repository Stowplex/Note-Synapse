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

  group('ConversationAiEngine tool iteration', () {
    test('executes tool when call_tool function received', () async {
      // First response: function_call with call_tool
      // Second response: text only (final)
      var callCount = 0;
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return {
            'text': null,
            'function_calls': [
              {
                'name': 'call_tool',
                'args': {
                  'service_name': 'test-service',
                  'tool_name': 'test-tool',
                  'params': {'key': 'value'},
                },
              }
            ],
            'parts_history': [],
          };
        }
        return {'text': 'Done!', 'function_calls': null, 'parts_history': []};
      });

      var toolExecuted = false;
      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: {
          'test-service': [
            McpTool(
              name: 'test-tool',
              description: 'Test',
              inputSchema: const {},
            ),
          ],
        },
        enableTools: true,
        executeTool: (service, tool, params, ctx) async {
          toolExecuted = true;
          expect(service, equals('test-service'));
          expect(tool, equals('test-tool'));
          return 'Tool result';
        },
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      expect(toolExecuted, isTrue);
      expect(result.content, contains('Done!'));
    });

    test('handles unknown function calls gracefully', () async {
      // Model calls unknown function directly instead of call_tool
      var callCount = 0;
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return {
            'text': null,
            'function_calls': [
              {'name': 'unknown_function', 'args': {}},
            ],
            'parts_history': [],
          };
        }
        return {
          'text': 'Understood, I will use call_tool',
          'function_calls': null,
          'parts_history': [],
        };
      });

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: <String, List<McpTool>>{},
        enableTools: true,
        executeTool: (_, __, ___, ____) async => '',
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // Should complete without crashing
      expect(result.content, isNotEmpty);
    });

    test('respects max iterations limit', () async {
      // Always return function_calls to trigger limit
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
                  'service_name': 's',
                  'tool_name': 't',
                  'params': <String, dynamic>{},
                },
              }
            ],
            'parts_history': [],
          });

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: {
          's': [
            McpTool(name: 't', description: '', inputSchema: const {}),
          ],
        },
        enableTools: true,
        executeTool: (_, __, ___, ____) async => 'result',
        isCancelled: () => false,
        generationContext: GenerationContext(),
        maxToolIterations: 2,
      );

      // Should return error message after hitting limit
      expect(result.content, contains('unable to complete'));
    });

    test('calls onIterationsExhausted when limit reached', () async {
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
                  'service_name': 's',
                  'tool_name': 't',
                  'params': <String, dynamic>{},
                },
              }
            ],
            'parts_history': [],
          });

      var exhaustedCalled = false;
      // When onIterationsExhausted returns null, it throws ConversationCancelledException
      try {
        await engine.generate(
          request: createTestRequest(),
          activeTools: {
            's': [
              McpTool(name: 't', description: '', inputSchema: const {}),
            ],
          },
          enableTools: true,
          executeTool: (_, __, ___, ____) async => 'result',
          isCancelled: () => false,
          generationContext: GenerationContext(),
          maxToolIterations: 1,
          onIterationsExhausted: (limit) async {
            exhaustedCalled = true;
            return null; // Cancel - this throws ConversationCancelledException
          },
        );
      } on ConversationCancelledException {
        // Expected when returning null from onIterationsExhausted
      }

      expect(exhaustedCalled, isTrue);
    });

    test('continues when onIterationsExhausted returns higher limit', () async {
      var modelCallCount = 0;
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async {
        modelCallCount++;
        if (modelCallCount <= 3) {
          return {
            'text': null,
            'function_calls': [
              {
                'name': 'call_tool',
                'args': {
                  'service_name': 's',
                  'tool_name': 't',
                  'params': <String, dynamic>{},
                },
              }
            ],
            'parts_history': [],
          };
        }
        return {
          'text': 'Finally done!',
          'function_calls': null,
          'parts_history': [],
        };
      });

      var exhaustedCallCount = 0;
      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: {
          's': [
            McpTool(name: 't', description: '', inputSchema: const {}),
          ],
        },
        enableTools: true,
        executeTool: (_, __, ___, ____) async => 'result',
        isCancelled: () => false,
        generationContext: GenerationContext(),
        maxToolIterations: 2,
        onIterationsExhausted: (limit) async {
          exhaustedCallCount++;
          return limit + 2; // Allow more iterations
        },
      );

      expect(exhaustedCallCount, greaterThan(0));
      expect(result.content, contains('Finally done!'));
    });
  });

  group('ConversationAiEngine error handling', () {
    test('handles model error gracefully', () async {
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenThrow(Exception('Model API error'));

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: {},
        enableTools: false,
        executeTool: (_, __, ___, ____) async => '',
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // Should return synthetic error message, not throw
      expect(result.content, contains('error'));
      expect(result.metadata?['is_client_synthetic'], isTrue);
    });

    test('handles tool execution error gracefully', () async {
      var callCount = 0;
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return {
            'text': null,
            'function_calls': [
              {
                'name': 'call_tool',
                'args': {
                  'service_name': 's',
                  'tool_name': 't',
                  'params': {},
                },
              }
            ],
            'parts_history': [],
          };
        }
        return {
          'text': 'Completed despite error',
          'function_calls': null,
          'parts_history': [],
        };
      });

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: {
          's': [McpTool(name: 't', description: '', inputSchema: const {})],
        },
        enableTools: true,
        executeTool: (_, __, ___, ____) async {
          throw Exception('Tool execution failed');
        },
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // Should complete without throwing - tool errors are logged, not fatal
      expect(result.content, contains('Completed'));
    });

    test('rethrows ConversationCancelledException', () async {
      when(mockModelSelector.generateWithToolsAndMessages(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenThrow(const ConversationCancelledException('Test cancellation'));

      expect(
        () => engine.generate(
          request: createTestRequest(),
          activeTools: {},
          enableTools: false,
          executeTool: (_, __, ___, ____) async => '',
          isCancelled: () => false,
          generationContext: GenerationContext(),
        ),
        throwsA(isA<ConversationCancelledException>()),
      );
    });
  });
}
