import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/services/built_in_tools_service.dart';

@GenerateMocks([
  ContextManagerService,
  ModelSelector,
  AIService,
  DatabaseService,
  BuiltInToolsService,
])
import 'agent_service_task_control_test.mocks.dart';
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
    when(mockContextManager.rootContext).thenReturn(null);
    when(mockContextManager.clear()).thenReturn(null);
    when(mockModelSelector.currentModelConfig).thenReturn(null);
    when(
      mockContextManager.createRootContext(
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
        maxTokens: anyNamed('maxTokens'),
      ),
    ).thenAnswer(
      (invocation) async => ContextNode(
        id: 'root',
        objective: invocation.namedArguments[#objective],
      ),
    );

    // Allow getContext to return null for any ID (prevent MissingStubError)
    when(mockContextManager.getContext(any)).thenReturn(null);

    // Stub for buildContextForResearchTask
    when(
      mockContextManager.buildContextForResearchTask(
        any,
        structuredDependencies: anyNamed('structuredDependencies'),
      ),
    ).thenReturn('Mock Context');
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('AgentService - cancel', () {
    test('cancel sets isRunning to false', () {
      agentService.cancel();
      expect(agentService.isRunning, isFalse);
    });

    test('cancel sets currentThought to cancelled message', () {
      agentService.cancel();
      expect(agentService.currentThought, equals('Cancelled by user.'));
    });
  });

  group('AgentService - Model Override', () {
    test('modelOverride is null initially', () {
      expect(agentService.modelOverride, isNull);
    });

    test('modelOverride can be set and retrieved', () {
      // We'll test the setter behavior without an actual ModelConfig
      // The property should notify listeners
      var notified = false;
      agentService.addListener(() => notified = true);
      agentService.modelOverride = null; // Already null, but triggers setter
      expect(notified, isTrue);
    });
  });

  group('AgentService - Enabled Native Tools', () {
    test('enabledNativeTools returns all tools when no filter set', () {
      final tools = agentService.enabledNativeTools;
      expect(tools, isNotEmpty);
    });
  });

  group('AgentService - Context Manager Access', () {
    test('contextManager getter returns injected context manager', () {
      expect(agentService.contextManager, equals(mockContextManager));
    });
  });

  group('AgentService - performTaskForTest', () {
    test('performTaskForTest is accessible for testing', () async {
      final task = AgentTask(
        id: 'test-task-1',
        description: 'Test task',
        status: AgentTaskStatus.pending,
      );

      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => '<answer>Done</answer>');

      // This should not throw - it exposes _performTask for testing
      // We don't verify the full behavior here, just that it's callable
      expect(
        () => agentService.performTaskForTest(task, 'test context'),
        returnsNormally,
      );
    });
  });

  group('AgentService - ChangeNotifier', () {
    test('notifies listeners when clearState is called', () {
      var notified = false;
      when(mockContextManager.clear()).thenReturn(null);

      agentService.addListener(() => notified = true);
      agentService.clearState();
      expect(notified, isTrue);
    });

    test('notifies listeners when addGlobalContextNote is called', () {
      var notified = false;
      agentService.addListener(() => notified = true);
      agentService.addGlobalContextNote('note-1');
      expect(notified, isTrue);
    });

    test('notifies listeners when removeGlobalContextNote removes a note', () {
      agentService.addGlobalContextNote('note-1');

      var notified = false;
      agentService.addListener(() => notified = true);
      agentService.removeGlobalContextNote('note-1');
      expect(notified, isTrue);
    });

    test('does not notify when removeGlobalContextNote finds nothing', () {
      var notified = false;
      agentService.addListener(() => notified = true);
      agentService.removeGlobalContextNote('non-existent');
      expect(notified, isFalse);
    });

    test('does not notify when addGlobalContextNote adds duplicate', () {
      agentService.addGlobalContextNote('note-1');

      var notified = false;
      agentService.addListener(() => notified = true);
      agentService.addGlobalContextNote('note-1'); // Duplicate
      expect(notified, isFalse);
    });
  });

  group('AgentService - onProgressUpdate callback', () {
    test('onProgressUpdate can be set', () {
      String? lastStatus;
      agentService.onProgressUpdate = (status) => lastStatus = status;

      // The callback is used during task execution
      expect(agentService.onProgressUpdate, isNotNull);
    });
    group('AgentService - Task Intervention', () {
      // Helper to populate tasks
      Future<void> _populateTasks({
        Completer<String>? executionCompleter,
      }) async {
        var callCount = 0;
        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((invocation) async {
          final context =
              invocation.namedArguments[#generationContext]
                  as GenerationContext?;
          final type = context?.values['type'];

          // Return Plan JSON for planning request
          if (type == 'agent_plan') {
            return '[{"name": "task_1", "description": "d1", "tools": []}, {"name": "task_2", "description": "d2", "tools": [], "dependsOn": ["task_1"]}]';
          }

          // Wait for completer if provided, to simulate long-running task
          if (executionCompleter != null) {
            return await executionCompleter.future;
          }

          // Return Success XML for task execution
          return '<answer>Task Completed Successfully</answer>';
        });

        await agentService.generatePlan('objective');
      }

      test('resumeTask unpauses agent and restarts execution', () async {
        final completer = Completer<String>();
        await _populateTasks(executionCompleter: completer);

        // Start execution but it will hang on first task
        unawaited(agentService.executePlan());

        // Allow loop to start and enter _performTask
        await Future.delayed(const Duration(milliseconds: 50));

        expect(agentService.isRunning, isTrue);

        agentService.pauseExecution();
        expect(agentService.isPaused, isTrue);

        // Now resume
        final tasks = agentService.tasks;
        await agentService.resumeTask(tasks.first.id);

        // resumeTask sets isPaused=false and restarts execution
        expect(agentService.isPaused, isFalse);

        // Finish execution to clean up
        completer.complete('<answer>Done</answer>');
      });

      test('resumeExecution unpauses and restarts execution', () async {
        // 1. Setup a task
        final completer = Completer<String>();
        await _populateTasks(executionCompleter: completer);

        // 2. Start and then pause to set state
        unawaited(agentService.executePlan());
        await Future.delayed(const Duration(milliseconds: 50));
        agentService.pauseExecution();
        expect(agentService.isPaused, isTrue);

        // 3. Resume Execution (global)
        final resumeFuture = agentService.resumeExecution();

        // 4. Verify unpaused immediately
        expect(agentService.isPaused, isFalse);

        // 5. Cleanup
        completer.complete('<answer>Done</answer>');
        await resumeFuture;
      });

      test('resumeTask increases maxTurns if requested', () async {
        await _populateTasks();
        final tasks = agentService.tasks;
        final task1 = tasks.first;
        final initialMaxTurns = task1.maxTurns;

        await agentService.resumeTask(task1.id, increaseLimit: true);

        expect(task1.maxTurns, greaterThan(initialMaxTurns));
      });

      test('concludeTask marks task as completed and proceeds', () async {
        await _populateTasks();
        final tasks = agentService.tasks;
        final task1 = tasks.first;

        agentService.concludeTask(task1.id);

        expect(task1.status, equals(AgentTaskStatus.completed));
        expect(task1.result, contains('Manually concluded'));
        // executePlan is called, but we mostly care about the task state update here
      });

      test('abortTask marks task as failed and stops execution', () async {
        await _populateTasks();
        final tasks = agentService.tasks;
        final task1 = tasks.first;

        agentService.abortTask(task1.id);

        expect(task1.status, equals(AgentTaskStatus.failed));
        expect(task1.result, contains('Aborted by user'));
        expect(agentService.isRunning, isFalse);
      });
    });
  });

  group('AgentService - Constants', () {
    test('kMaxSubtaskDepth constant is defined', () {
      // The constant should be 2 (for backward compatibility)
      expect(kMaxSubtaskDepth, equals(2));
    });
  });

  group('AgentService - AgentCheckpoint enum', () {
    test('AgentCheckpoint has all expected values', () {
      expect(AgentCheckpoint.values.length, equals(4));
      expect(AgentCheckpoint.values, contains(AgentCheckpoint.beforeLlmCall));
      expect(
        AgentCheckpoint.values,
        contains(AgentCheckpoint.afterLlmResponse),
      );
      expect(AgentCheckpoint.values, contains(AgentCheckpoint.beforeToolCall));
      expect(AgentCheckpoint.values, contains(AgentCheckpoint.afterToolResult));
    });
  });
}
