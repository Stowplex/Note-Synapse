// test/workflow_task_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
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
}) =>
    ResolvedBinding(
      skillNoteId: skillNoteId,
      matchedTag: matchedTag,
      pattern: pattern,
      prompt: prompt,
      contentImmutable: contentImmutable,
    );

@GenerateMocks([DatabaseService, AIService, ModelSelector, ContextManagerService])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockDatabaseService mockDb;
  late MockAIService mockAIService;
  late MockModelSelector mockModelSelector;
  late MockContextManagerService mockContextManager;
  late AgentService agentService;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockAIService = MockAIService();
    mockModelSelector = MockModelSelector();
    mockContextManager = MockContextManagerService();

    getIt.registerLazySingleton<DatabaseService>(() => mockDb);
    getIt.registerLazySingleton<AIService>(() => mockAIService);
    getIt.registerLazySingleton<ModelSelector>(() => mockModelSelector);
    getIt.registerLazySingleton<ContextManagerService>(() => mockContextManager);
    getIt.registerLazySingleton<SkillService>(() => SkillService(mockDb));

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDb,
    );

    // Default stubs
    when(mockDb.searchNotesFTS(any, tags: anyNamed('tags')))
        .thenAnswer((_) async => []);
    when(mockDb.getNoteById(any)).thenAnswer((_) async => null);
    when(mockDb.getRelationships(any)).thenAnswer((_) async => []);

    when(mockContextManager.rootContext).thenReturn(null);
    when(mockContextManager.createRootContext(
      objective: anyNamed('objective'),
      allowedTools: anyNamed('allowedTools'),
      maxTokens: anyNamed('maxTokens'),
    )).thenAnswer((inv) async => ContextNode(
          id: 'root',
          objective: inv.namedArguments[#objective] as String,
        ));
    when(mockContextManager.createChildContext(
      parent: anyNamed('parent'),
      objective: anyNamed('objective'),
      allowedTools: anyNamed('allowedTools'),
    )).thenAnswer((inv) => ContextNode(
          id: 'child',
          objective: inv.namedArguments[#objective] as String,
        ));
    when(mockContextManager.getContext(any)).thenReturn(null);
    when(mockContextManager.buildContextForResearchTask(
      any,
      dependencyResults: anyNamed('dependencyResults'),
      structuredDependencies: anyNamed('structuredDependencies'),
    )).thenReturn('Mock context');
    when(mockContextManager.buildContextForSubtask(any))
        .thenReturn('Mock subtask context');
    when(mockContextManager.buildSynthesisContext(
      any,
      structuredDependencies: anyNamed('structuredDependencies'),
    )).thenReturn('Mock synthesis context');
    when(mockContextManager.checkAndCompact(any)).thenAnswer((_) async {});

    when(mockAIService.generateWithAttachments(
      any,
      any,
      generationContext: anyNamed('generationContext'),
    )).thenAnswer((_) async =>
        '<Action type="answer"><Content>Done</Content></Action>');
  });

  group('runWorkflowTask', () {
    test('creates a single task with prompt template substituted', () async {
      final note = _makeNote('note-42');
      final binding = _makeBinding(
        prompt: 'Process note {note_id} tagged {matched_tag}',
        matchedTag: 'test-tag',
      );

      // Run without await so we can inspect tasks while running (or after it
      // settles if the mock AI responds immediately).
      final future = agentService.runWorkflowTask(binding: binding, note: note);
      // Give micro-tasks a chance to execute setup before loop starts
      await Future.microtask(() {});

      // The task should have been created and added to _tasks
      expect(agentService.tasks.length, 1);

      final task = agentService.tasks.first;
      expect(task.description, contains('note-42'));
      expect(task.description, contains('test-tag'));

      // Wait for completion (mock AI returns an answer immediately)
      await future;
    });

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
      when(mockAIService.generateWithAttachments(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) => completer.future);

      // Start first workflow (don't await — it will stall)
      unawaited(
          agentService.runWorkflowTask(binding: binding, note: note));
      // Let first task begin
      await Future.delayed(const Duration(milliseconds: 10));

      // Start second workflow while first is running
      final binding2 = _makeBinding(matchedTag: 'other-tag');
      unawaited(
          agentService.runWorkflowTask(binding: binding2, note: note));
      await Future.microtask(() {});

      expect(agentService.pendingWorkflowCount, 1);

      // Unblock
      completer.complete('<Action type="answer"><Content>Done</Content></Action>');
      // Give the queue time to drain after unblocking
      await Future.delayed(const Duration(milliseconds: 20));
    });
  });
}
