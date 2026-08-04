import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

@GenerateMocks([
  ContextManagerService,
  ModelSelector,
  AIService,
  DatabaseService,
])
import 'agent_service_execution_loop_test.mocks.dart';
import '../utils/test_prompt_template_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockContextManagerService mockContextManager;
  late MockModelSelector mockModelSelector;
  late MockAIService mockAIService;
  late MockDatabaseService mockDatabaseService;
  late AgentService agentService;

  setUp(() async {
    await resetForTesting();
    mockContextManager = MockContextManagerService();
    mockModelSelector = MockModelSelector();
    mockAIService = MockAIService();
    mockDatabaseService = MockDatabaseService();

    getIt.registerLazySingleton<ContextManagerService>(
      () => mockContextManager,
    );
    getIt.registerLazySingleton<ModelSelector>(() => mockModelSelector);
    getIt.registerLazySingleton<AIService>(() => mockAIService);
    getIt.registerLazySingleton<DatabaseService>(() => mockDatabaseService);
    getIt.registerLazySingleton<SkillService>(
      () => SkillService(mockDatabaseService),
    );
    await registerTestPromptTemplateService();
    when(
      mockDatabaseService.searchNotesFTS(any, tags: anyNamed('tags')),
    ).thenAnswer((_) async => []);
    when(mockDatabaseService.getNotesByTag(any))
        .thenAnswer((_) async => []);
    when(mockContextManager.rootContext).thenReturn(null);
    when(mockModelSelector.currentModelConfig).thenReturn(null);

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );
  });

  group('AgentService - Execution Loop (_performTask)', () {
    test('Handles "answer" action completing task', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      final contextNode = ContextNode(id: 'node1', objective: 'desc');

      when(mockContextManager.getContext(any)).thenReturn(contextNode);
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async =>
            '<Action type="answer"><Content>Detailed Result</Content></Action>',
      );

      await agentService.performTaskForTest(task, 'global context');

      expect(task.status, equals(AgentTaskStatus.completed));
      expect(task.result, equals('Detailed Result'));
      verify(mockContextManager.getContext(any)).called(greaterThan(0));
    });

    test('Handles "tool" action and executes tool', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      final contextNode = ContextNode(id: 'node1', objective: 'desc');

      when(mockContextManager.getContext(any)).thenReturn(contextNode);

      // Sequence: 1. Tool Call -> 2. Answer
      var callCount = 0;
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return '<Action type="tool"><ToolName>mock_tool</ToolName><Content>{"arg":"value"}</Content></Action>';
        }
        return '<Action type="answer"><Content>Final Answer</Content></Action>';
      });

      // Mock tool executor
      bool toolCalled = false;
      agentService.toolExecutor = (service, tool, params, ctx) async {
        toolCalled = true;
        expect(service, equals('mock_service'));
        expect(tool, equals('mock_tool'));
        expect(params['arg'], equals('value'));
        return 'Tool Result';
      };

      // Mock external tools discovery to include mock_tool
      agentService.externalToolsForTest = {
        'mock_service': [McpTool(name: 'mock_tool', description: 'mock')],
      };

      await agentService.performTaskForTest(task, 'global context');
      await agentService.performTaskForTest(task, 'global context');

      expect(toolCalled, isTrue);
      // Verify history contains tool call execution. Production format is
      // 'Action: Call <service>.<tool>'.
      expect(
        task.executionHistory.any(
          (l) => l.contains('Action: Call mock_service.mock_tool'),
        ),
        isTrue,
      );
      // Verify history contains observation
      expect(
        task.executionHistory.any(
          (l) => l.contains('Observation: Tool Result'),
        ),
        isTrue,
      );
      expect(task.result, equals('Final Answer'));
    });

    test('Handles malformed response with retry/error', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      final contextNode = ContextNode(id: 'node1', objective: 'desc');
      when(mockContextManager.getContext(any)).thenReturn(contextNode);

      // Return malformed XML
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => '<Action type="tool">Missing Content</Action>');

      await agentService.performTaskForTest(task, 'ctx');

      // Should log error to executionHistory and context
      expect(
        task.executionHistory.join(),
        contains('Observation:'),
      ); // Error log
      expect(task.status, isNot(equals(AgentTaskStatus.completed)));
    });

    test('Rejects multiple action elements in a single turn', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      when(
        mockContextManager.getContext(any),
      ).thenReturn(ContextNode(id: 'n', objective: 'o'));

      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => '''
<Action type="tool">
  <ToolName>mock_tool</ToolName>
  <Content>{"arg":"value"}</Content>
</Action>
<Action type="tool">
  <ToolName>mock_tool</ToolName>
  <Content>{"arg":"value-2"}</Content>
</Action>
''',
      );

      var toolCalled = false;
      agentService.toolExecutor = (_, __, ___, ____) async {
        toolCalled = true;
        return 'Tool Result';
      };
      agentService.externalToolsForTest = {
        'mock_service': [McpTool(name: 'mock_tool', description: 'mock')],
      };

      await agentService.performTaskForTest(task, 'ctx');

      expect(toolCalled, isFalse);
      expect(
        task.executionHistory.any(
          (line) => line.contains('Exactly one action is allowed per turn'),
        ),
        isTrue,
      );
      expect(task.status, isNot(AgentTaskStatus.completed));
    });

    test(
      'Blocks wiki-ingest completion claims without observed writes',
      () async {
        final task = AgentTask(
          id: 't1',
          name: 'task 1',
          description: 'desc',
          allowedTools: [],
          isFinalDeliverable: true,
          validationProfile: AgentTaskValidationProfile.wikiIngest,
        );
        when(
          mockContextManager.getContext(any),
        ).thenReturn(ContextNode(id: 'n', objective: 'o'));

        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer(
          (_) async =>
              '<Action type="answer"><Content>Completed ingest. Created two entity notes and updated the index.</Content></Action>',
        );

        await agentService.performTaskForTest(task, 'ctx');

        expect(task.status, isNot(AgentTaskStatus.completed));
        expect(
          task.executionHistory.any(
            (line) => line.contains('Cannot report wiki ingest completion yet'),
          ),
          isTrue,
        );
      },
    );

    test(
      'Allows wiki-ingest completion after create and modify observations',
      () async {
        final task = AgentTask(
          id: 't1',
          name: 'task 1',
          description: 'desc',
          allowedTools: [],
          isFinalDeliverable: true,
          validationProfile: AgentTaskValidationProfile.wikiIngest,
          toolExecutionRecords: const [
            AgentToolExecutionRecord(
              toolName: 'create_notes',
              args: {},
              result: 'Created notes',
              succeeded: true,
            ),
            AgentToolExecutionRecord(
              toolName: 'modify_notes',
              args: {},
              result: 'Modified notes',
              succeeded: true,
            ),
          ],
        );
        when(
          mockContextManager.getContext(any),
        ).thenReturn(ContextNode(id: 'n', objective: 'o'));

        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer(
          (_) async =>
              '<Action type="answer"><Content>Completed ingest. Created two entity notes and updated the index.</Content></Action>',
        );

        await agentService.performTaskForTest(task, 'ctx');

        expect(task.status, AgentTaskStatus.completed);
        expect(task.result, contains('Completed ingest.'));
      },
    );

    test('Handles "think" action', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      when(
        mockContextManager.getContext(any),
      ).thenReturn(ContextNode(id: 'n', objective: 'o'));

      // Sequence: Think -> Answer
      final responses = [
        '<Action type="think"><Content>Thinking...</Content></Action>',
        '<Action type="answer"><Content>Done</Content></Action>',
      ];
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => responses.removeAt(0));

      await agentService.performTaskForTest(task, 'ctx'); // Process think
      await agentService.performTaskForTest(task, 'ctx'); // Process answer

      expect(
        task.executionHistory.any((l) => l.contains('Thinking...')),
        isTrue,
      );
      expect(task.result, equals('Done'));
    });

    test('Skips a byte-equivalent repeat of a failed tool call', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      when(
        mockContextManager.getContext(any),
      ).thenReturn(ContextNode(id: 'n', objective: 'o'));

      // Same failing call twice (second with reordered keys), then answer.
      final responses = [
        '<Action type="tool"><ToolName>mock_tool</ToolName>'
            '<Content>{"a":1,"b":2}</Content></Action>',
        '<Action type="tool"><ToolName>mock_tool</ToolName>'
            '<Content>{"b":2,"a":1}</Content></Action>',
        '<Action type="answer"><Content>Done</Content></Action>',
      ];
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => responses.removeAt(0));

      var executions = 0;
      agentService.toolExecutor = (service, tool, params, ctx) async {
        executions++;
        throw Exception('deterministic failure');
      };
      agentService.externalToolsForTest = {
        'mock_service': [McpTool(name: 'mock_tool', description: 'mock')],
      };

      await agentService.performTaskForTest(task, 'ctx');
      await agentService.performTaskForTest(task, 'ctx');
      await agentService.performTaskForTest(task, 'ctx');

      expect(executions, 1, reason: 'identical retry must not execute');
      expect(
        task.executionHistory.any(
          (l) => l.contains('was NOT executed again'),
        ),
        isTrue,
      );
    });

    test('Circuit breaker: variant failing calls are skipped after 3 '
        'deterministic failures', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      when(
        mockContextManager.getContext(any),
      ).thenReturn(ContextNode(id: 'n', objective: 'o'));

      // Four different payloads — identity dedupe never fires.
      final responses = [
        for (var i = 1; i <= 4; i++)
          '<Action type="tool"><ToolName>mock_tool</ToolName>'
              '<Content>{"attempt":$i}</Content></Action>',
        '<Action type="answer"><Content>Done</Content></Action>',
      ];
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => responses.removeAt(0));

      var executions = 0;
      agentService.toolExecutor = (service, tool, params, ctx) async {
        executions++;
        throw Exception('deterministic failure ${params['attempt']}');
      };
      agentService.externalToolsForTest = {
        'mock_service': [McpTool(name: 'mock_tool', description: 'mock')],
      };

      for (var i = 0; i < 5; i++) {
        await agentService.performTaskForTest(task, 'ctx');
      }

      expect(executions, 3, reason: '4th variant must be skipped');
      expect(
        task.executionHistory.any(
          (l) => l.contains('was NOT executed again'),
        ),
        isTrue,
      );
    });

    test('Structured {"error": ...} tool results are recorded as failures',
        () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      when(
        mockContextManager.getContext(any),
      ).thenReturn(ContextNode(id: 'n', objective: 'o'));

      final responses = [
        '<Action type="tool"><ToolName>mock_tool</ToolName>'
            '<Content>{"x":1}</Content></Action>',
        '<Action type="answer"><Content>Done</Content></Action>',
      ];
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => responses.removeAt(0));

      agentService.toolExecutor = (service, tool, params, ctx) async =>
          '{"synapse_tool_outcome": 1, "error": {"code": "invalid_argument", '
          '"message": "bad args", "retryable": false}}';
      agentService.externalToolsForTest = {
        'mock_service': [McpTool(name: 'mock_tool', description: 'mock')],
      };

      await agentService.performTaskForTest(task, 'ctx');
      await agentService.performTaskForTest(task, 'ctx');

      expect(task.toolExecutionRecords, hasLength(1));
      expect(task.toolExecutionRecords.single.succeeded, isFalse);
    });

    test('Answer gets deterministic disclosure when all modify attempts '
        'failed', () async {
      final task = AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'desc',
        allowedTools: [],
      );
      when(
        mockContextManager.getContext(any),
      ).thenReturn(ContextNode(id: 'n', objective: 'o'));

      final responses = [
        '<Action type="tool"><ToolName>modify_notes</ToolName>'
            '<Content>{"modifications":[{"note_id":"n1","modification":4}]}'
            '</Content></Action>',
        '<Action type="answer"><Content>I updated your notes successfully!'
            '</Content></Action>',
      ];
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => responses.removeAt(0));

      agentService.toolExecutor = (service, tool, params, ctx) async =>
          throw Exception('type cast failure');
      agentService.externalToolsForTest = {
        'mock_service': [McpTool(name: 'modify_notes', description: 'mock')],
      };

      await agentService.performTaskForTest(task, 'ctx');
      await agentService.performTaskForTest(task, 'ctx');

      expect(task.status, AgentTaskStatus.completed);
      expect(task.result, contains('I updated your notes successfully!'));
      expect(task.result, contains('Tool execution report'));
      expect(task.result, contains('NOT applied'));
    });
  });
}
