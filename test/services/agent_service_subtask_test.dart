import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

@GenerateMocks([
  ContextManagerService,
  ModelSelector,
  AIService,
  DatabaseService,
])
import 'agent_service_subtask_test.mocks.dart';
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
    when(mockDatabaseService.getNotesByTag(any)).thenAnswer((_) async => []);
    await registerTestPromptTemplateService();

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );

    // Default mock behaviors
    when(
      mockContextManager.rootContext,
    ).thenReturn(ContextNode(id: 'root', objective: 'obj'));
    when(mockModelSelector.currentModelConfig).thenReturn(null);
    when(mockContextManager.getContext(any)).thenReturn(null);
    when(
      mockContextManager.createChildContext(
        parent: anyNamed('parent'),
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
      ),
    ).thenAnswer(
      (invocation) => ContextNode(
        id: 'child_ctx',
        objective: invocation.namedArguments[#objective],
      ),
    );

    // Mock buildContextForSubtask
    when(
      mockContextManager.buildContextForSubtask(any),
    ).thenReturn('Subtask Context');
  });

  tearDown(() async {
    await resetForTesting();
  });

  test(
    'Spawned subtask should inherit allowedTools from parent, not limit to hinted tools',
    () async {
      // 1. Setup parent task with access to toolA and toolB
      final parentTask = AgentTask(
        id: 'parent_1',
        description: 'Parent Task',
        allowedTools: ['toolA', 'toolB'], // The parent has access to these
        status: AgentTaskStatus.inProgress,
      );

      // 2. Mock LLM response to spawn a subtask that "hints" only toolA
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => '''
<MyThought>I need to spawn a subtask.</MyThought>
<Action type="spawn_subtasks">
<Content>[{"description": "Subtask 1", "tools": ["toolA"]}]</Content>
</Action>
''',
      );

      // Add parent task to service
      // We need to inject it into the _tasks list.
      // Since _tasks is private, we can use startObjective to populate it, or rely on performTaskForTest which operates on the task passed to it?
      // performTaskForTest executes the task provided. However, _handleSpawnSubtasks accesses _tasks to insert the new subtask.
      // So we need _tasks to contain parentTask.
      // We can't easily modify _tasks directly as it is private and no setter.

      // Workaround: Use startObjective to initialize a task list, then replace/manipulate it?
      // Or just use performTaskForTest on a task that IS in the list.
      // We can use generatePlan to populate _tasks.

      // Let's use startObjective with a mock plan generation that returns our parent task.
      // But startObjective clears tasks.

      // Alternative: We can use reflection or just modify AgentService to be more testable, but let's try to use public API.
      // generatePlan populates _tasks.

      // Let's call generatePlan with a single task.
      // We need to mock generateWithAttachments to return the plan first.

      when(
        mockAIService.generateWithAttachments(
          argThat(
            contains('You are an intelligent agent that plans'),
          ), // Prompt for plan
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => '''
[
  {
    "name": "parent_task",
    "description": "Parent Task",
    "tools": ["toolA", "toolB"]
  }
]
''',
      );

      // Also mock createRootContext
      when(
        mockContextManager.createRootContext(
          objective: anyNamed('objective'),
          allowedTools: anyNamed('allowedTools'),
        ),
      ).thenAnswer((_) async => ContextNode(id: 'root', objective: 'obj'));

      // Initialize with generatePlan (called via startObjective is easier but runs execution loop)
      // We want to control execution. So just call generatePlan.
      await agentService.generatePlan("Objective", activeTools: {});

      // Now _tasks should contain the parent task.
      final tasks = agentService.tasks;
      expect(tasks.length, 1);
      final storedParentTask = tasks.first;
      expect(storedParentTask.description, "Parent Task");

      // Initialize allowedTools of parent task to be everything (since we passed empty activeTools, it defaults to all or empty depending on logic)
      // In generatePlan: if activeTools is empty, _enabledNativeToolNames = null (all enabled).
      // And _parseTasksFromJson sets allowedTools to valid tools.
      // Let's ensure parentTask.allowedTools is correct.
      // Wait, _parseTasksFromJson uses activeTools argument.
      // In generatePlan: getAllToolNames() is passed.

      // Let's just manually update the task in the service if possible? No.
      // We'll trust generatePlan to set it up.

      // Now mock the execution of this task
      when(
        mockAIService.generateWithAttachments(
          argThat(
            contains('Task Description: "Parent Task"'),
          ), // Execution prompt
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer(
        (_) async => '''
<MyThought>Spawning subtask</MyThought>
<Action type="spawn_subtasks">
<Content>[{"description": "Subtask 1", "tools": ["toolA"]}]</Content>
</Action>
''',
      );

      // Perform the task
      await agentService.performTaskForTest(storedParentTask, "Context");

      // Now check if subtask was spawned
      final updatedTasks = agentService.tasks;
      expect(updatedTasks.length, 2); // Parent + Subtask

      final subtask = updatedTasks[1]; // Subtask is inserted after parent
      expect(subtask.description, "Subtask 1");
      expect(subtask.isSpawnedDynamically, isTrue);

      // Verify that subtask inherits allowedTools from parent (all available tools)
      // instead of being restricted to only the tools hinted in the spawn request.
      expect(subtask.allowedTools, equals(storedParentTask.allowedTools));
      expect(subtask.allowedTools, isNot(equals(['toolA'])));
    },
  );
}
