import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/models/generation_context.dart';
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
import 'agent_service_test.mocks.dart';
import '../utils/test_prompt_template_setup.dart';

class MockScreenScope {
  bool isDisposed = false;
  final Set<String> enabledTools;

  MockScreenScope({this.enabledTools = const {}});

  Future<String> executeTool(
    String serviceName,
    String toolName,
    Map<String, dynamic> params,
    GenerationContext ctx,
  ) async {
    if (isDisposed) {
      throw 'HeadlessInAppWebView is not running (Scope disposed)';
    }
    if (!enabledTools.contains(toolName)) {
      throw 'Tool $toolName is not enabled in this scope';
    }
    return 'Tool executed successfully';
  }

  void dispose() {
    isDisposed = true;
  }
}

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
    when(mockDatabaseService.getNotesByTag(any)).thenAnswer((_) async => []);
    await registerTestPromptTemplateService();

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );

    // Mocks
    when(mockModelSelector.currentModelConfig).thenReturn(null);

    // Explicit mocks for ContextManager
    when(mockContextManager.rootContext).thenReturn(null);

    when(
      mockContextManager.createRootContext(
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
      ),
    ).thenAnswer((_) async => ContextNode(id: 'root', objective: 'root'));

    when(
      mockContextManager.createChildContext(
        parent: anyNamed('parent'),
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
      ),
    ).thenAnswer((_) => ContextNode(id: 'child', objective: 'sub'));

    when(mockContextManager.checkAndCompact(any)).thenAnswer((_) async => null);
    when(mockContextManager.setActiveContext(any)).thenReturn(null);
    when(mockContextManager.getContext(any)).thenReturn(null);
    when(mockContextManager.markContextFailed(any, any)).thenReturn(null);
    when(mockContextManager.buildContextForNode(any)).thenReturn('context');
    when(
      mockContextManager.buildContextForResearchTask(
        any,
        dependencyResults: anyNamed('dependencyResults'),
        structuredDependencies: anyNamed('structuredDependencies'),
      ),
    ).thenReturn('context');
    when(mockContextManager.buildContextForSubtask(any)).thenReturn('context');
    when(
      mockContextManager.buildSynthesisContext(
        any,
        structuredDependencies: anyNamed('structuredDependencies'),
      ),
    ).thenReturn('context');

    // AI Service Mock
    // Setup Plan
    when(
      mockAIService.generateWithAttachments(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      ),
    ).thenAnswer(
      (_) async => '''
[
  {
    "name": "task_1",
    "description": "Use a tool",
    "tools": ["test_tool"],
    "isFinalDeliverable": false,
    "extractFindings": false
  }
]
''',
    );
  });

  tearDown(() async {
    await resetForTesting();
  });

  test(
    'Verification: Agent resumes successfully when executor is updated',
    () async {
      final screen1 = MockScreenScope(enabledTools: {'test_tool'});

      await agentService.generatePlan(
        'Test Objective',
        activeTools: {
          'default': [
            McpTool(name: 'test_tool', description: 'test', inputSchema: {}),
          ],
        },
        executeTool: screen1.executeTool,
      );

      // Setup Execution Response with Counter
      int callCount = 0;
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        callCount++;
        if (callCount == 1) {
          return '''
<MyThought>Calling tool now.</MyThought>
<Action type="tool">
<ToolName>test_tool</ToolName>
<Content>{}</Content>
</Action>
''';
        }
        return '<Action type="answer"><Content>Finished</Content></Action>';
      });

      // START TEST

      // 1. Simulate Screen 1 disposal (e.g. navigation)
      screen1.dispose();

      // 2. Simulate new Screen attachment (Fix)
      final screen2 = MockScreenScope(enabledTools: {'test_tool'});
      agentService.updateToolExecutor(screen2.executeTool);

      // 3. Run Agent
      print('Starting execution...');
      await agentService.executePlan();
      print('Execution finished.');

      final task = agentService.tasks.first;
      print('Task Status: ${task.status}');
      print('History: ${task.executionHistory}');
      print('Result: ${task.result}');

      // Check if result indicates success (no error about headless webview)
      final hasError =
          (task.result?.contains('HeadlessInAppWebView is not running') ??
              false) ||
          task.executionHistory.any(
            (s) => s.contains('HeadlessInAppWebView is not running'),
          );

      expect(
        hasError,
        isFalse,
        reason: 'Should NOT fail with stale executor error after update.',
      );
      expect(task.status, AgentTaskStatus.completed);
      expect(
        task.executionHistory.any(
          (s) => s.contains('Tool executed successfully'),
        ),
        isTrue,
      );
    },
  );
}
