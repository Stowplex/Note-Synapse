import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/conversation_ai_engine.dart';
import 'package:note_synapse/services/mcp_tool_integration_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

@GenerateMocks([ModelSelector])
import 'conversation_ai_engine_test.mocks.dart';
import '../utils/test_prompt_template_setup.dart';

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
    await registerTestPromptTemplateService();
    engine = const ConversationAiEngine();

    // Default: return null for currentModelConfig (Gemini path)
    when(mockModelSelector.currentModelConfig).thenReturn(null);
    when(mockModelSelector.currentModel).thenReturn(null);
    when(
      mockModelSelector.buildToolDeclarations(
        any,
        generationContext: anyNamed('generationContext'),
      ),
    ).thenAnswer((invocation) {
      final tools = invocation.positionalArguments[0]
          as Map<String, List<McpTool>>;
      if (tools.isEmpty) return <Map<String, dynamic>>[];
      return [
        McpToolIntegrationService.getCallToolFunctionForGemini(tools),
      ];
    });
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('ConversationAiEngine basic generation', () {
    test('returns text response when no tools needed', () async {
      // Arrange: Mock ModelSelector to return text response with no function_calls
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => {
          'text': 'Hello! How can I help you?',
          'function_calls': null,
          'parts_history': [],
        },
      );

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
      verify(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).called(1);
    });

    test('handles empty response', () async {
      // Arrange: Mock ModelSelector to return null/empty response
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => {
          'text': null,
          'function_calls': null,
          'parts_history': null,
        },
      );

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
      verifyNever(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      );
    });

    test('throws when cancelled during iteration', () async {
      // Arrange: Return a function_call first, then check cancelled
      var callCount = 0;

      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => {
          'text': null,
          'function_calls': [
            {
              'name': 'call_tool',
              'args': {
                'service_name': 'test_service',
                'tool_name': 'test_tool',
                'params': <String, dynamic>{},
              },
            },
          ],
          'parts_history': [],
        },
      );

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
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async {
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
              },
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

    test('normalizes direct tool calls with wrapper-shaped args', () async {
      var callCount = 0;
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return {
            'text': null,
            'function_calls': [
              {
                'name': 'load_skill',
                'args': {
                  'service_name': 'SkillTools',
                  'tool_name': 'load_skill',
                  'params': {'noteId': 'skill-1'},
                },
              },
            ],
            'parts_history': [],
          };
        }
        return {'text': 'Done!', 'function_calls': null, 'parts_history': []};
      });

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: {
          'SkillTools': [
            McpTool(
              name: 'load_skill',
              description: 'Load a skill',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'noteId': {'type': 'string'},
                },
                'required': ['noteId'],
              },
            ),
          ],
        },
        enableTools: true,
        executeTool: (service, tool, params, ctx) async {
          expect(service, equals('SkillTools'));
          expect(tool, equals('load_skill'));
          expect(params, equals({'noteId': 'skill-1'}));
          return 'Loaded skill';
        },
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      expect(result.content, contains('Done!'));
    });

    test(
      'refreshes active tools after load_skill and injects discovery prompt',
      () async {
        var callCount = 0;
        final modelCalls = <List<dynamic>>[];
        final currentTools = <String, List<McpTool>>{
          'SkillTools': [
            McpTool(
              name: 'load_skill',
              description: 'Load a skill',
              inputSchema: const {},
            ),
          ],
        };

        when(
          mockModelSelector.generateWithToolsAndMessages(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((invocation) async {
          modelCalls.add([
            invocation.positionalArguments[0],
            invocation.positionalArguments[1],
          ]);
          callCount++;
          if (callCount == 1) {
            return {
              'text': null,
              'function_calls': [
                {
                  'name': 'call_tool',
                  'args': {
                    'service_name': 'SkillTools',
                    'tool_name': 'load_skill',
                    'params': {'noteId': 'skill-1'},
                  },
                },
              ],
              'parts_history': [],
            };
          }
          return {
            'text': 'Discovered tool used.',
            'function_calls': null,
            'parts_history': [],
          };
        });

        await engine.generate(
          request: createTestRequest(),
          activeTools: currentTools,
          activeToolsProvider: () => currentTools,
          enableTools: true,
          executeTool: (service, tool, params, ctx) async {
            currentTools['SkillTools'] = [
              ...currentTools['SkillTools']!,
              McpTool(
                name: 'search_notes',
                description: 'Search notes',
                inputSchema: const {
                  'type': 'object',
                  'properties': {
                    'query': {'type': 'string'},
                  },
                },
              ),
            ];
            return 'Loaded skill';
          },
          isCancelled: () => false,
          generationContext: GenerationContext(),
        );

        expect(modelCalls, hasLength(2));

        final secondMessages = (modelCalls[1][0] as List)
            .cast<PromptMessage>()
            .toList();
        expect(
          secondMessages.any(
            (message) =>
                message.role == PromptRole.system &&
                message.content.contains('EXECUTE') &&
                message.content.contains('search_notes'),
          ),
          isTrue,
        );

        final secondFunctions = (modelCalls[1][1] as List)
            .cast<Map<String, dynamic>>();
        expect(secondFunctions, isNotEmpty);
        final description = secondFunctions.first['description'] as String;
        expect(
          description,
          contains('call_tool with {service_name, tool_name, params}'),
        );
        expect(description, contains('- search_notes: Search notes'));
      },
    );

    test('handles unknown function calls gracefully', () async {
      // Model calls unknown function directly instead of call_tool
      var callCount = 0;
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async {
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
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => {
          'text': null,
          'function_calls': [
            {
              'name': 'call_tool',
              'args': {
                'service_name': 's',
                'tool_name': 't',
                'params': <String, dynamic>{},
              },
            },
          ],
          'parts_history': [],
        },
      );

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: {
          's': [McpTool(name: 't', description: '', inputSchema: const {})],
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
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => {
          'text': null,
          'function_calls': [
            {
              'name': 'call_tool',
              'args': {
                'service_name': 's',
                'tool_name': 't',
                'params': <String, dynamic>{},
              },
            },
          ],
          'parts_history': [],
        },
      );

      var exhaustedCalled = false;
      // When onIterationsExhausted returns null, it throws ConversationCancelledException
      try {
        await engine.generate(
          request: createTestRequest(),
          activeTools: {
            's': [McpTool(name: 't', description: '', inputSchema: const {})],
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
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async {
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
              },
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
          's': [McpTool(name: 't', description: '', inputSchema: const {})],
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
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenThrow(Exception('Model API error'));

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
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return {
            'text': null,
            'function_calls': [
              {
                'name': 'call_tool',
                'args': {'service_name': 's', 'tool_name': 't', 'params': {}},
              },
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
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenThrow(const ConversationCancelledException('Test cancellation'));

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

  group('ConversationAiEngine history integrity', () {
    Map<String, dynamic> callToolFn(String tool, [Map<String, dynamic>? p]) {
      return {
        'name': 'call_tool',
        'args': {
          'service_name': 'System',
          'tool_name': tool,
          'params': p ?? <String, dynamic>{},
        },
      };
    }

    Map<String, List<McpTool>> systemTools() => {
      'System': [
        McpTool(name: 'tool_a', description: 'A', inputSchema: const {}),
        McpTool(name: 'tool_b', description: 'B', inputSchema: const {}),
      ],
    };

    test(
      'in-flight assistant messages carry only their own iteration parts '
      '(no cumulative aliasing)',
      () async {
        var callCount = 0;
        final modelCalls = <List<PromptMessage>>[];

        when(
          mockModelSelector.generateWithToolsAndMessages(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((invocation) async {
          modelCalls.add(
            (invocation.positionalArguments[0] as List)
                .cast<PromptMessage>()
                .toList(),
          );
          callCount++;
          if (callCount <= 3) {
            return {
              'text': null,
              'function_calls': [callToolFn('tool_a')],
              'parts_history': [
                {
                  'type': 'tool_call',
                  'function_call': {
                    'name': 'call_tool',
                    'args': {
                      'service_name': 'System',
                      'tool_name': 'tool_a',
                      'params': {'iteration': callCount},
                    },
                  },
                  'is_included': true,
                },
              ],
            };
          }
          return {
            'text': 'Done!',
            'function_calls': null,
            'parts_history': [
              {'type': 'text', 'text': 'Done!', 'is_included': true},
            ],
          };
        });

        final result = await engine.generate(
          request: createTestRequest(),
          activeTools: systemTools(),
          enableTools: true,
          executeTool: (_, __, ___, ____) async => 'ok',
          isCancelled: () => false,
          generationContext: GenerationContext(),
        );

        expect(modelCalls, hasLength(4));

        // The final request contains 3 assistant messages, each holding
        // exactly its own iteration's single tool_call part — never the
        // accumulated set.
        final assistants = modelCalls[3]
            .where((m) => m.role == PromptRole.assistant)
            .toList();
        expect(assistants, hasLength(3));
        for (var i = 0; i < assistants.length; i++) {
          final parts = assistants[i].metadata?['parts_history'] as List;
          expect(
            parts,
            hasLength(1),
            reason: 'assistant $i must hold only its own iteration parts',
          );
          final call = (parts.single as Map)['function_call'] as Map;
          expect(
            (call['args'] as Map)['params'],
            {'iteration': i + 1},
            reason: 'assistant $i must hold iteration ${i + 1}\'s call',
          );
        }

        // Distinct list instances — mutating one must not affect another.
        final lists = assistants
            .map((m) => m.metadata?['parts_history'] as List)
            .toList();
        expect(identical(lists[0], lists[1]), isFalse);
        expect(identical(lists[1], lists[2]), isFalse);

        // Request size grows linearly: every iteration adds exactly one
        // assistant + one tool message.
        for (var i = 1; i < modelCalls.length; i++) {
          expect(modelCalls[i].length - modelCalls[i - 1].length, 2);
        }

        // Final persisted metadata still carries the full union:
        // 3 tool_call parts + 3 tool_result parts + 1 final text part.
        final persisted = result.metadata?['parts_history'] as List;
        expect(persisted, hasLength(7));
        expect(
          persisted.where((p) => (p as Map)['type'] == 'tool_call').length,
          3,
        );
        expect(
          persisted.where((p) => (p as Map)['type'] == 'tool_result').length,
          3,
        );
        expect(
          persisted.where((p) => (p as Map)['type'] == 'text').length,
          1,
        );
        // And the persisted list is not aliased to any in-flight message.
        for (final list in lists) {
          expect(identical(persisted, list), isFalse);
        }
      },
    );

    test(
      'every function call gets exactly one paired tool response, including '
      'unparseable and unknown calls',
      () async {
        var callCount = 0;
        final modelCalls = <List<PromptMessage>>[];

        when(
          mockModelSelector.generateWithToolsAndMessages(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((invocation) async {
          modelCalls.add(
            (invocation.positionalArguments[0] as List)
                .cast<PromptMessage>()
                .toList(),
          );
          callCount++;
          if (callCount == 1) {
            return {
              'text': null,
              'function_calls': [
                callToolFn('tool_a'),
                // Unparseable: no service/tool names anywhere.
                {'name': 'call_tool', 'args': 42},
                // Unknown function called directly by name.
                {
                  'name': 'not_a_tool',
                  'args': {'x': 1},
                },
              ],
              'parts_history': [],
            };
          }
          return {'text': 'Done!', 'function_calls': null, 'parts_history': []};
        });

        final executed = <String>[];
        await engine.generate(
          request: createTestRequest(),
          activeTools: systemTools(),
          enableTools: true,
          executeTool: (service, tool, params, ctx) async {
            executed.add('$service.$tool');
            return 'ok';
          },
          isCancelled: () => false,
          generationContext: GenerationContext(),
        );

        expect(executed, ['System.tool_a']);
        expect(modelCalls, hasLength(2));

        // Second request: 3 function calls → exactly 3 tool messages,
        // in call order, each with function metadata.
        final toolMessages = modelCalls[1]
            .where((m) => m.role == PromptRole.tool)
            .toList();
        expect(toolMessages, hasLength(3));
        expect(
          toolMessages.map((m) => m.metadata?['function_name']).toList(),
          ['call_tool', 'call_tool', 'not_a_tool'],
        );
        expect(toolMessages[0].content, contains('Result: ok'));
        expect(
          toolMessages[1].content,
          contains('Could not parse call_tool arguments'),
        );
        expect(toolMessages[2].content, contains('Error'));
      },
    );
  });

  group('ConversationAiEngine retry discipline and disclosure', () {
    const invalidArgEnvelope =
        '{"synapse_tool_outcome": 1, "error": {"code": "invalid_argument", '
        '"message": '
        '"modifications[0].modification: expected object, got int (4)", '
        '"retryable": false}}';
    const transportEnvelope =
        '{"synapse_tool_outcome": 1, "error": {"code": "transport_error", '
        '"message": "Connection refused", "retryable": true}}';

    Map<String, dynamic> callToolFn(Map<String, dynamic> params) {
      return {
        'name': 'call_tool',
        'args': {
          'service_name': 'System',
          'tool_name': 'modify_notes',
          'params': params,
        },
      };
    }

    Map<String, List<McpTool>> systemTools() => {
      'System': [
        McpTool(name: 'modify_notes', description: 'M', inputSchema: const {}),
      ],
    };

    test(
      'second byte-equivalent deterministic failure is not executed again, '
      'even with reordered keys',
      () async {
        var callCount = 0;
        when(
          mockModelSelector.generateWithToolsAndMessages(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((invocation) async {
          callCount++;
          if (callCount == 1) {
            return {
              'text': null,
              'function_calls': [
                callToolFn({'note_id': 'n1', 'modification': 4}),
              ],
              'parts_history': [],
            };
          }
          if (callCount == 2) {
            // Identical call, different key order.
            return {
              'text': null,
              'function_calls': [
                callToolFn({'modification': 4, 'note_id': 'n1'}),
              ],
              'parts_history': [],
            };
          }
          return {'text': 'Done', 'function_calls': null, 'parts_history': []};
        });

        var executions = 0;
        final result = await engine.generate(
          request: createTestRequest(),
          activeTools: systemTools(),
          enableTools: true,
          executeTool: (_, __, ___, ____) async {
            executions++;
            return invalidArgEnvelope;
          },
          isCancelled: () => false,
          generationContext: GenerationContext(),
        );

        // Executed once; the identical retry was answered without execution.
        expect(executions, 1);
        // Unresolved failure is disclosed deterministically.
        expect(result.content, contains('Tool execution report'));
        expect(result.content, contains('System.modify_notes'));
        final failed = result.metadata?['failed_tool_calls'] as List;
        expect(failed, hasLength(1));
        expect((failed.single as Map)['code'], 'invalid_argument');
      },
    );

    test('retryable transport failures are executed again', () async {
      var callCount = 0;
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        callCount++;
        if (callCount <= 2) {
          return {
            'text': null,
            'function_calls': [
              callToolFn({'note_id': 'n1'}),
            ],
            'parts_history': [],
          };
        }
        return {'text': 'Done', 'function_calls': null, 'parts_history': []};
      });

      var executions = 0;
      await engine.generate(
        request: createTestRequest(),
        activeTools: systemTools(),
        enableTools: true,
        executeTool: (_, __, ___, ____) async {
          executions++;
          return transportEnvelope;
        },
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      expect(executions, 2);
    });

    test('a later success of the same tool clears the disclosure', () async {
      var callCount = 0;
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        callCount++;
        if (callCount == 1) {
          return {
            'text': null,
            'function_calls': [
              callToolFn({'note_id': 'n1', 'modification': 4}),
            ],
            'parts_history': [],
          };
        }
        if (callCount == 2) {
          // Corrected arguments.
          return {
            'text': null,
            'function_calls': [
              callToolFn({
                'note_id': 'n1',
                'modification': {
                  'content': {'action': 'append', 'text': 'x'},
                },
              }),
            ],
            'parts_history': [],
          };
        }
        return {
          'text': 'All done',
          'function_calls': null,
          'parts_history': [],
        };
      });

      var executions = 0;
      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: systemTools(),
        enableTools: true,
        executeTool: (_, __, params, ___) async {
          executions++;
          return params['modification'] is Map
              ? '{"status": "success"}'
              : invalidArgEnvelope;
        },
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      expect(executions, 2);
      expect(result.content, isNot(contains('Tool execution report')));
      expect(result.metadata?.containsKey('failed_tool_calls'), isFalse);
    });

    test('circuit breaker: variant invalid calls stop executing after 3 '
        'failures and terminate the turn on a further attempt', () async {
      var callCount = 0;
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        callCount++;
        // A different invalid payload every iteration — byte-identity
        // dedupe can never fire.
        return {
          'text': null,
          'function_calls': [
            callToolFn({'note_id': 'n1', 'modification': callCount}),
          ],
          'parts_history': [],
        };
      });

      var executions = 0;
      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: systemTools(),
        enableTools: true,
        executeTool: (_, __, ___, ____) async {
          executions++;
          return invalidArgEnvelope;
        },
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // 3 executed failures, then a blocked directive, then termination —
      // far below the 10-iteration cap.
      expect(executions, 3);
      expect(callCount, 5);
      expect(result.content, contains('invalid arguments'));
      expect(result.content, contains('Tool execution report'));
      expect(result.metadata?['isSynthesized'], isTrue);
      expect(result.metadata?['failed_tool_calls'], isNotEmpty);
    });

    test('a success against a different target does not erase a distinct '
        'failed call\'s disclosure', () async {
      var callCount = 0;
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        callCount++;
        if (callCount == 1) {
          // Two calls in one turn: note1 fails, note2 succeeds.
          return {
            'text': null,
            'function_calls': [
              callToolFn({'note_id': 'note-1'}),
              callToolFn({'note_id': 'note-2'}),
            ],
            'parts_history': [],
          };
        }
        return {
          'text': 'Both notes updated!',
          'function_calls': null,
          'parts_history': [],
        };
      });

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: systemTools(),
        enableTools: true,
        executeTool: (_, __, params, ___) async =>
            params['note_id'] == 'note-1'
            ? '{"synapse_tool_outcome": 1, "error": {"code": "tool_error", '
                  '"message": "Section not found", "retryable": false}}'
            : '{"status": "success"}',
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // note-2's success must NOT clear note-1's tool_error disclosure.
      expect(result.content, contains('Tool execution report'));
      expect(result.content, contains('Section not found'));
      final failed = result.metadata?['failed_tool_calls'] as List;
      expect(failed, hasLength(1));
    });

    test('disclosure overrides a hallucinated success claim (two distinct '
        'failed calls, then a false success)', () async {
      var callCount = 0;
      when(
        mockModelSelector.generateWithToolsAndMessages(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        callCount++;
        if (callCount == 1) {
          return {
            'text': null,
            'function_calls': [
              callToolFn({'note_id': 'n1', 'modification': 4}),
            ],
            'parts_history': [],
          };
        }
        if (callCount == 2) {
          // A DIFFERENT malformed call — identical-call dedupe alone would
          // never catch this sequence.
          return {
            'text': null,
            'function_calls': [
              callToolFn({'note_id': 'n1', 'modification': 'Infinity'}),
            ],
            'parts_history': [],
          };
        }
        return {
          'text': 'I have successfully updated your Reading Record!',
          'function_calls': null,
          'parts_history': [],
        };
      });

      final result = await engine.generate(
        request: createTestRequest(),
        activeTools: systemTools(),
        enableTools: true,
        executeTool: (_, __, ___, ____) async => invalidArgEnvelope,
        isCancelled: () => false,
        generationContext: GenerationContext(),
      );

      // The model's claim stays, but the harness disclosure follows it.
      expect(result.content, contains('successfully updated'));
      expect(result.content, contains('Tool execution report'));
      expect(result.content, contains('did NOT complete'));
      expect(result.metadata?['failed_tool_calls'], isNotEmpty);
    });
  });
}
