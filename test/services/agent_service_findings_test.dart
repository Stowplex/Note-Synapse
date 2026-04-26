import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
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
import 'agent_service_findings_test.mocks.dart';
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
    getIt.registerLazySingleton<SkillService>(() => SkillService(mockDatabaseService));
    when(mockDatabaseService.searchNotesFTS(any, tags: anyNamed('tags')))
        .thenAnswer((_) async => []);
    when(mockDatabaseService.getNotesByTag(any))
        .thenAnswer((_) async => []);
    await registerTestPromptTemplateService();

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );

    // Prevent crashes
    when(mockContextManager.getContext(any)).thenReturn(null);
    when(mockContextManager.rootContext).thenReturn(null);
    when(
      mockContextManager.createRootContext(
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
        maxTokens: anyNamed('maxTokens'),
      ),
    ).thenAnswer(
      (i) async =>
          ContextNode(id: 'root', objective: i.namedArguments[#objective]),
    );

    when(
      mockContextManager.buildContextForResearchTask(
        any,
        dependencyResults: anyNamed('dependencyResults'),
        structuredDependencies: anyNamed('structuredDependencies'),
      ),
    ).thenReturn('Global Context');

    // Additional stubs
    when(mockModelSelector.currentModelConfig).thenReturn(null);
    when(
      mockContextManager.generateFinalSummary(
        any,
        consumingTaskDescriptions: anyNamed('consumingTaskDescriptions'),
        modelOverride: anyNamed('modelOverride'),
      ),
    ).thenAnswer((_) async => 'Task Summary');
    when(
      mockContextManager.buildContextForSubtask(any),
    ).thenReturn("Subtask Context");
    when(mockContextManager.addFindings(any)).thenReturn(null);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('AgentService - Findings Extraction', () {
    test('Tasks with extractFindings=true trigger extraction logic', () async {
      // Setup mocked plan with one task that has extractFindings=true
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        final context =
            invocation.namedArguments[#generationContext] as GenerationContext?;

        // 1. Planner response
        if (context?.values['type'] == 'agent_plan') {
          return '[{"name": "research_task", "description": "Research stuff", "tools": [], "extractFindings": true}]';
        }

        // 2. Extraction response (extractStructuredFindings calls AI)
        // Checking if call is for extraction
        if (context?.values['type'] == 'extract_findings') {
          return '''
```json
[{"finding": "Finding 1", "source": "Test", "url": "", "artifacts": []}, {"finding": "Finding 2", "source": "Test", "url": "", "artifacts": []}]
```
''';
        }

        // 3. Task Execution response
        return '<Action type="answer"><Content>Task Done with significant results.</Content></Action>';
      });

      // Execute
      await agentService.startObjective('Find stuff');

      // Verify
      final tasks = agentService.tasks;
      expect(tasks, isNotEmpty);
      final task = tasks.first;
      expect(task.extractFindings, isTrue);
      expect(task.status, AgentTaskStatus.completed);

      // Verify findings call happened
      verify(
        mockContextManager.addFindings(
          argThat(
            predicate(
              (list) =>
                  (list as List).any((item) => item['finding'] == 'Finding 1'),
            ),
          ),
        ),
      ).called(1);

      expect(task.structuredFindings?.first['finding'], 'Finding 1');
    });
  });

  group('AgentService - Spawned Subtasks Findings', () {
    test('Completed subtasks trigger finding extraction', () async {
      // Ideally we simulate subtask spawning via AI response `spawn_subtasks`.

      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        final context =
            invocation.namedArguments[#generationContext] as GenerationContext?;

        // 1. Planner response
        if (context?.values['type'] == 'agent_plan') {
          return '[{"name": "parent", "description": "Parent task", "tools": [], "isFinalDeliverable": true}]';
        }

        // 4. Extraction response for subtask
        if (context?.values['instructions'] != null &&
            (context!.values['instructions'] as String).contains(
              'Extract key findings',
            )) {
          return '["Subtask Finding"]';
        }

        // 2. Parent Execution -> Spawn Subtask
        // We use a counter or check task status to sequence responses?
        // Simpler: Determine by task description in context?
        // Or just return SPAWN first time.

        // Hacky sequence detection:
        // Use a persistent counter in closure?
        // Not easily possible with `thenAnswer` unless defined outside.
        return '<Action type="spawn_subtasks"><Subtasks>[{"description": "Subtask 1", "tools": []}]</Subtasks></Action>';
      });

      // Wait, if it spawns subtask, it loops.
      // Next call is for Subtask Execution.
      // Subtask Exec returns Answer.
      // Then Parent Logic sees subtask complete.
      // Then Runs Extraction.
      // Then Parent Exec resumes.

      // This is complicated to mock correctly with a single `thenAnswer`.
      // I'll define a mutable answer handler.

      int callCount = 0;
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((invocation) async {
        final context =
            invocation.namedArguments[#generationContext] as GenerationContext?;
        if (context?.values['type'] == 'agent_plan')
          return '[{"name": "parent", "description": "Parent", "tools": []}]';

        if (context?.values['type'] == 'extract_findings') {
          return '''
```json
[{"finding": "Subtask Finding", "source": "Test", "url": "", "artifacts": []}]
```
''';
        }

        callCount++;

        if (callCount == 1) {
          // Parent running -> Spawn
          return '''
<Action type="spawn_subtasks">
  <Content>
    [
      { "description": "Subtask 1", "tools": [] }
    ]
  </Content>
</Action>
''';
        } else if (callCount == 2) {
          // Subtask running
          return '<Action type="answer"><Content>Subtask Done</Content></Action>';
        } else {
          // Parent running (Resume after spawn)
          // Agent might execute subtask first, then parent?
          // If parent "spawned", it remains inProgress.
          // Next turn, if parent selected, it will see subtasks completed?
          return '<Action type="answer"><Content>Parent Done</Content></Action>';
        }
      });

      // Need stub for buildContextForSubtask
      when(
        mockContextManager.buildContextForSubtask(any),
      ).thenReturn("Subtask Context");
      when(
        mockContextManager.createChildContext(
          parent: anyNamed('parent'),
          objective: anyNamed('objective'),
          allowedTools: anyNamed('allowedTools'),
        ),
      ).thenAnswer((_) => ContextNode(id: 'child', objective: 'Subtask'));

      await agentService.startObjective('Test Spawn');

      // Verify findings call happened
      verify(
        mockContextManager.addFindings(
          argThat(
            predicate(
              (list) => (list as List).any(
                (item) => item['finding'] == 'Subtask Finding',
              ),
            ),
          ),
        ),
      ).called(1);
    });
  });
}
