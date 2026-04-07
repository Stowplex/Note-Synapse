// test/workflow_task_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workflow_task_test.mocks.dart';

Note _makeNote(String id) => Note(
  id: id,
  title: 'Test Note $id',
  content: 'Test content',
  type: NoteType.note,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  subNotes: [],
  tags: ['test-tag'],
  attachmentPaths: [],
);

ResolvedBinding _makeBinding({
  String skillNoteId = 'skill-1',
  String matchedTag = 'test-tag',
  String pattern = 'test-tag',
  String prompt = 'Process note {note_id} with tag {matched_tag}',
  bool contentImmutable = false,
}) => ResolvedBinding(
  skillNoteId: skillNoteId,
  matchedTag: matchedTag,
  pattern: pattern,
  prompt: prompt,
  contentImmutable: contentImmutable,
);

@GenerateMocks([
  DatabaseService,
  AIService,
  ModelSelector,
  ContextManagerService,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockDatabaseService mockDb;
  late MockAIService mockAIService;
  late MockModelSelector mockModelSelector;
  late MockContextManagerService mockContextManager;
  late AgentService agentService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockAIService = MockAIService();
    mockModelSelector = MockModelSelector();
    mockContextManager = MockContextManagerService();

    getIt.registerLazySingleton<DatabaseService>(() => mockDb);
    getIt.registerLazySingleton<AIService>(() => mockAIService);
    getIt.registerLazySingleton<ModelSelector>(() => mockModelSelector);
    getIt.registerLazySingleton<ContextManagerService>(
      () => mockContextManager,
    );
    getIt.registerLazySingleton<SkillService>(() => SkillService(mockDb));

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDb,
    );

    // Default stubs
    when(
      mockDb.searchNotesFTS(any, tags: anyNamed('tags')),
    ).thenAnswer((_) async => []);
    when(mockDb.getNotesByTag(any)).thenAnswer((_) async => []);
    when(mockDb.getNoteById(any)).thenAnswer((_) async => null);
    when(mockDb.getRelationships(any)).thenAnswer((_) async => []);

    when(mockContextManager.rootContext).thenReturn(null);
    when(mockContextManager.currentContext).thenReturn(null);
    when(
      mockContextManager.createRootContext(
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
        maxTokens: anyNamed('maxTokens'),
      ),
    ).thenAnswer(
      (inv) async => ContextNode(
        id: 'root',
        objective: inv.namedArguments[#objective] as String,
      ),
    );
    when(
      mockContextManager.createChildContext(
        parent: anyNamed('parent'),
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
      ),
    ).thenAnswer(
      (inv) => ContextNode(
        id: 'child',
        objective: inv.namedArguments[#objective] as String,
      ),
    );
    when(mockContextManager.getContext(any)).thenReturn(null);
    when(
      mockContextManager.buildContextForResearchTask(
        any,
        dependencyResults: anyNamed('dependencyResults'),
        structuredDependencies: anyNamed('structuredDependencies'),
      ),
    ).thenReturn('Mock context');
    when(
      mockContextManager.buildContextForSubtask(any),
    ).thenReturn('Mock subtask context');
    when(
      mockContextManager.buildSynthesisContext(
        any,
        structuredDependencies: anyNamed('structuredDependencies'),
      ),
    ).thenReturn('Mock synthesis context');
    when(mockContextManager.checkAndCompact(any)).thenAnswer((_) async {});
    when(mockModelSelector.currentModelConfig).thenReturn(null);

    when(
      mockAIService.generateWithAttachments(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      ),
    ).thenAnswer(
      (_) async => '<Action type="answer"><Content>Done</Content></Action>',
    );
  });

  group('runWorkflowTask', () {
    test('creates a single task with prompt template substituted', () async {
      final note = _makeNote('note-42');
      final binding = _makeBinding(
        prompt: 'Process note {note_id} tagged {matched_tag}',
        matchedTag: 'test-tag',
      );

      await agentService.runWorkflowTask(binding: binding, note: note);

      // The task should have been created and added to _tasks
      expect(agentService.tasks.length, 1);

      final task = agentService.tasks.first;
      expect(task.description, contains('note-42'));
      expect(task.description, contains('test-tag'));
    });

    test(
      'adds explicit source note and tag context to workflow objective',
      () async {
        final note = Note(
          id: 'source-123',
          title: 'Source Note',
          content: 'Source content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          subNotes: [],
          tags: ['wiki-source-ml', 'research', 'important'],
          attachmentPaths: [],
        );
        final binding = _makeBinding(
          skillNoteId: 'skill-123',
          matchedTag: 'wiki-source-ml',
          pattern: 'wiki-source-',
          prompt: 'Ingest this note according to the wiki ingest skill.',
        );

        await agentService.runWorkflowTask(binding: binding, note: note);

        final task = agentService.tasks.single;
        expect(
          task.description,
          contains('Ingest this note according to the wiki ingest skill.'),
        );
        expect(
          task.description,
          contains('This workflow was triggered automatically'),
        );
        expect(task.description, contains('source-123'));
        expect(task.description, contains('Source Note'));
        expect(task.description, contains('wiki-source-ml'));
        expect(task.description, contains('research, important'));
        expect(task.description, contains('skill-123'));
        expect(
          task.description,
          contains('Use load_skill with the bound skill note ID'),
        );
        expect(
          task.description,
          contains('Do not search for a candidate source note'),
        );
      },
    );

    test(
      'starts workflows with only load_skill and read_task_result allowed',
      () async {
        final note = _makeNote('note-99');
        final binding = _makeBinding(
          prompt: 'Ingest this note according to the wiki ingest skill.',
        );

        await agentService.runWorkflowTask(binding: binding, note: note);

        final task = agentService.tasks.single;
        expect(
          task.allowedTools,
          containsAll(['load_skill', 'read_task_result']),
        );
        expect(task.allowedTools, isNot(contains('search_notes')));
        expect(task.allowedTools, isNot(contains('read_note')));
        expect(task.allowedTools, isNot(contains('modify_note')));
        expect(task.allowedTools, isNot(contains('create_notes')));

        verify(
          mockContextManager.createRootContext(
            objective: anyNamed('objective'),
            allowedTools: argThat(
              allOf(
                contains('load_skill'),
                contains('read_task_result'),
                isNot(contains('search_notes')),
                isNot(contains('read_note')),
                isNot(contains('modify_note')),
                isNot(contains('create_notes')),
              ),
              named: 'allowedTools',
            ),
            maxTokens: anyNamed('maxTokens'),
          ),
        );
      },
    );

    test(
      'builtin tools referenced by a loaded skill become executable on later turns',
      () async {
        final note = _makeNote('note-skill');
        final binding = _makeBinding(
          skillNoteId: 'skill-1',
          prompt: 'Ingest this note according to the wiki ingest skill.',
        );
        const skillContent = '''
---
name: Wiki Ingest
description: Ingest sources
enabled: true
---

Use [search_notes](notesynapse://tool/builtin/search_notes) to find the workspace.
''';

        when(mockDb.getNote('skill-1')).thenAnswer(
          (_) async => Note(
            id: 'skill-1',
            title: 'Wiki Ingest',
            content: skillContent,
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            subNotes: [],
            tags: const ['agent-skill'],
            attachmentPaths: [],
          ),
        );

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
            return '''
<MyThought>Load the workflow skill first.</MyThought>
<Action type="tool">
  <ToolName>load_skill</ToolName>
  <Content>{"noteId":"skill-1"}</Content>
</Action>
''';
          }
          if (callCount == 2) {
            return '''
<MyThought>Now search for the wiki index.</MyThought>
<Action type="tool">
  <ToolName>search_notes</ToolName>
  <Content>{"query":"","tags":["wiki-index-ai-research"]}</Content>
</Action>
''';
          }
          return '<Action type="answer"><Content>Done</Content></Action>';
        });

        await agentService.runWorkflowTask(binding: binding, note: note);

        verify(mockDb.getNotesByTag('wiki-index-ai-research')).called(1);
      },
    );

    test('uses the configured agentic max turns for workflow tasks', () async {
      SharedPreferences.setMockInitialValues({'agentic_max_turns': 30});
      final note = _makeNote('note-max-turns');
      final binding = _makeBinding();

      await agentService.runWorkflowTask(binding: binding, note: note);

      expect(agentService.tasks.single.maxTurns, 30);
    });

    test('counts real turns instead of execution history entries', () async {
      final note = _makeNote('note-turns');
      final binding = _makeBinding();

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
          return '''
<MyThought>Load the skill first.</MyThought>
<Action type="tool">
  <ToolName>load_skill</ToolName>
  <Content>{"noteId":"skill-1"}</Content>
</Action>
''';
        }
        return '''
<MyThought>Done.</MyThought>
<Action type="answer">
  <Content>Completed</Content>
</Action>
''';
      });

      await agentService.runWorkflowTask(binding: binding, note: note);

      final history = agentService.tasks.single.executionHistory;
      expect(history.where((entry) => entry == 'Turn 1:').length, 1);
      expect(history.where((entry) => entry == 'Turn 2:').length, 1);
      expect(history.where((entry) => entry == 'Turn 3:').length, 0);
    });

    test(
      'classifies workflow pauses caused by hitting the turn limit',
      () async {
        SharedPreferences.setMockInitialValues({'agentic_max_turns': 1});
        final note = _makeNote('note-pause');
        final binding = _makeBinding();

        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer(
          (_) async => '''
<MyThought>Load the skill first.</MyThought>
<Action type="tool">
  <ToolName>load_skill</ToolName>
  <Content>{"noteId":"skill-1"}</Content>
</Action>
''',
        );

        await agentService.runWorkflowTask(binding: binding, note: note);

        final task = agentService.tasks.single;
        expect(task.status, AgentTaskStatus.paused);
        expect(task.result, 'Max turns reached. Paused.');
        expect(
          agentService.activeWorkflowStatus?.state,
          WorkflowExecutionState.pausedTurnLimit,
        );
      },
    );

    test('substitutes template variables in prompt', () {
      const template = 'Process note {note_id} because tag={matched_tag}';
      final result = AgentService.substitutePromptTemplate(
        template,
        noteId: 'abc-123',
        matchedTag: 'project/work',
      );
      expect(result, 'Process note abc-123 because tag=project/work');
      expect(result, isNot(contains('{note_id}')));
      expect(result, isNot(contains('{matched_tag}')));
    });

    test('queues workflow when agent is already running', () async {
      final note = _makeNote('note-1');
      final binding = _makeBinding();

      // Make the AI stall so the agent stays running
      final completer = Completer<String>();
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) => completer.future);

      // Start first workflow (don't await — it will stall)
      unawaited(agentService.runWorkflowTask(binding: binding, note: note));
      // Let first task begin
      await Future.delayed(const Duration(milliseconds: 10));

      // Start second workflow while first is running
      final binding2 = _makeBinding(matchedTag: 'other-tag');
      unawaited(agentService.runWorkflowTask(binding: binding2, note: note));
      await Future.microtask(() {});

      expect(agentService.pendingWorkflowCount, 1);

      // Unblock
      completer.complete(
        '<Action type="answer"><Content>Done</Content></Action>',
      );
      // Give the queue time to drain after unblocking
      await Future.delayed(const Duration(milliseconds: 20));
    });
  });
}
