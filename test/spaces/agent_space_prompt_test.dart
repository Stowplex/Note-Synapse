import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/prompts/space_scope_prompt.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import 'agent_space_prompt_test.mocks.dart';
import '../utils/test_prompt_template_setup.dart';

/// M5 / decision 5: **the agent's Space scoping is announced, never silent.**
///
/// A model whose `search_notes` quietly returned a subset would report "there
/// is nothing about X" when there is, with no way for the user to tell an empty
/// Space from an empty library. So the prompt states the scope, names the tags,
/// and names `scope: "all"` as the escape.
@GenerateMocks([ContextManagerService, ModelSelector, AIService, DatabaseService])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockContextManagerService mockContextManager;
  late MockModelSelector mockModelSelector;
  late MockAIService mockAIService;
  late MockDatabaseService mockDatabaseService;
  late SpaceScopeService scope;
  late AgentService agentService;

  setUp(() async {
    await resetForTesting();
    mockContextManager = MockContextManagerService();
    mockModelSelector = MockModelSelector();
    mockAIService = MockAIService();
    mockDatabaseService = MockDatabaseService();
    scope = SpaceScopeService();

    getIt.registerLazySingleton<ContextManagerService>(() => mockContextManager);
    getIt.registerLazySingleton<ModelSelector>(() => mockModelSelector);
    getIt.registerLazySingleton<AIService>(() => mockAIService);
    getIt.registerLazySingleton<DatabaseService>(() => mockDatabaseService);
    getIt.registerLazySingleton<SkillService>(
      () => SkillService(mockDatabaseService),
    );
    getIt.registerSingleton<SpaceScopeService>(scope);
    when(
      mockDatabaseService.searchNotesFTS(any, tags: anyNamed('tags')),
    ).thenAnswer((_) async => []);
    when(mockDatabaseService.getNotesByTag(any)).thenAnswer((_) async => []);
    await registerTestPromptTemplateService();

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );

    when(mockContextManager.rootContext).thenReturn(null);
    when(mockModelSelector.currentModelConfig).thenReturn(null);
    when(mockContextManager.clear()).thenReturn(null);
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
  });

  tearDown(() async {
    await resetForTesting();
  });

  /// Runs a plan generation and returns the prompt the agent handed the model.
  Future<String> planningPrompt({
    Map<String, List<McpTool>> activeTools = const {},
  }) async {
    late String captured;
    when(
      mockAIService.generateWithAttachments(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      ),
    ).thenAnswer((invocation) async {
      captured = invocation.positionalArguments[0] as String;
      return '[{"name": "task_a", "description": "A", "tools": []}]';
    });
    await agentService.generatePlan(
      'find my thesis notes',
      activeTools: activeTools,
    );
    return captured;
  }

  /// Runs one executor turn and returns the prompt the agent handed the model.
  ///
  /// The executor is the loop that actually calls the note tools, so it needs
  /// the announcement at least as much as the planner does — and it is a
  /// second, independent prompt string: covering only `generatePlan` let the
  /// executor's block be deleted with the suite green.
  Future<String> executorPrompt() async {
    late String captured;
    when(mockContextManager.getContext(any)).thenReturn(
      ContextNode(id: 'node1', objective: 'desc'),
    );
    when(
      mockAIService.generateWithAttachments(
        any,
        any,
        generationContext: anyNamed('generationContext'),
      ),
    ).thenAnswer((invocation) async {
      captured = invocation.positionalArguments[0] as String;
      return '<Action type="answer"><Content>Done</Content></Action>';
    });
    await agentService.performTaskForTest(
      AgentTask(
        id: 't1',
        name: 'task 1',
        description: 'find my thesis notes',
        allowedTools: const [],
      ),
      'global context',
    );
    return captured;
  }

  // ---------------------------------------------------------- the block itself

  group('the prompt block', () {
    test('is empty when no Space is active', () {
      expect(buildSpaceScopePromptSection(scope), isEmpty);
    });

    test('is empty for an id whose stamp tags are not resolved yet', () {
      // `load()` adopts a persisted id before AppProvider resolves it; a scope
      // with no tags narrows nothing and must announce nothing.
      scope.setActive('s1', const []);
      expect(buildSpaceScopePromptSection(scope), isEmpty);
    });

    test('names the Space, its tags, the escape and all-spaces', () {
      scope.setActive('s1', const ['thesis', '2026'], name: 'Thesis');

      final block = buildSpaceScopePromptSection(scope);

      expect(block, contains('"Thesis"'));
      expect(block, contains('thesis, 2026'));
      expect(block, contains('scope: "all"'));
      expect(block, contains(SpaceScopeService.allSpacesTag));
      // The three tools whose behaviour actually changes.
      expect(block, contains('search_notes'));
      expect(block, contains('ls'));
      expect(block, contains('read_note'));
    });

    test('falls back to a generic label when the name is unknown', () {
      scope.setActive('s1', const ['thesis']);

      final block = buildSpaceScopePromptSection(scope);

      expect(block, contains('the current Space'));
      expect(block, contains('thesis'));
    });
  });

  // ------------------------------------------------------------- in the agent

  group('the planning prompt', () {
    test('carries the block when a Space is active', () async {
      scope.setActive('s1', const ['thesis', '2026'], name: 'Thesis');

      final prompt = await planningPrompt();

      expect(prompt, contains('ACTIVE SPACE'));
      expect(prompt, contains('"Thesis"'));
      expect(prompt, contains('scope: "all"'));
    });

    test('says nothing about Spaces when none is active', () async {
      final prompt = await planningPrompt();

      expect(prompt, isNot(contains('ACTIVE SPACE')));
      expect(prompt, isNot(contains('scope: "all"')));
      // ...but the rest of the note guidance is untouched.
      expect(prompt, contains('NOTE EXPLORATION'));
    });

    test('says nothing when the note tools are switched off', () async {
      scope.setActive('s1', const ['thesis'], name: 'Thesis');

      // A non-empty tool map with no 'System' entry disables every native
      // tool. Nothing is being scoped, so there is nothing to announce.
      final prompt = await planningPrompt(
        activeTools: const {'Weather': <McpTool>[]},
      );

      expect(prompt, isNot(contains('ACTIVE SPACE')));
    });
  });

  // --------------------------------------------------------- the executor

  group('the executor prompt', () {
    test('carries the block when a Space is active', () async {
      scope.setActive('s1', const ['thesis', '2026'], name: 'Thesis');

      final prompt = await executorPrompt();

      expect(prompt, contains('ACTIVE SPACE'));
      expect(prompt, contains('"Thesis"'));
      expect(prompt, contains('thesis, 2026'));
      expect(prompt, contains('scope: "all"'));
    });

    test('says nothing about Spaces when none is active', () async {
      final prompt = await executorPrompt();

      expect(prompt, isNot(contains('ACTIVE SPACE')));
      expect(prompt, isNot(contains('scope: "all"')));
      // ...and the rest of the executor prompt is untouched.
      expect(prompt, contains('ITERATION PROTOCOL'));
    });
  });

  // ------------------------------------------------------------- the chat

  group('the chat prompt', () {
    // Chat reaches the note tools through a loaded skill rather than a fixed
    // tool set, so the announcement is gated on what the skill brought. Both
    // halves fail silently — the block simply stops appearing — and the
    // screen's prompt builder is private, so the decision lives in
    // buildChatSpaceScopeSection where a test can reach it.
    const noteTools = {'search_notes'};

    test('announces the scoping when a skill brought the note tools', () {
      scope.setActive('s1', const ['thesis', '2026'], name: 'Thesis');

      final section = buildChatSpaceScopeSection(noteTools, scope);

      expect(section, contains('ACTIVE SPACE'));
      expect(section, contains('"Thesis"'));
      expect(section, contains('scope: "all"'));
      // Trimmed: it is joined into a line list, not concatenated raw.
      expect(section, section.trim());
    });

    test('says nothing when the session has no note tools', () {
      scope.setActive('s1', const ['thesis'], name: 'Thesis');

      expect(buildChatSpaceScopeSection(const {'get_weather'}, scope), isEmpty);
      expect(buildChatSpaceScopeSection(const {}, scope), isEmpty);
    });

    test('says nothing when no Space is active', () {
      expect(buildChatSpaceScopeSection(noteTools, scope), isEmpty);
    });

    test('every gated name is a real tool name, so a rename cannot silence it',
        () {
      // The drift this catches: renaming `search_notes` and leaving the gate
      // spelling the old name turns the announcement off in chat with every
      // other test still green.
      final real = <String>{
        NoteSearchTool().name,
        NoteReadTool().name,
        ListFiltersTool().name,
        RunSqlTool().name,
      };

      expect(spaceScopedNoteToolNames, real);
      // ...and each of them, alone, is enough to trigger the block.
      scope.setActive('s1', const ['thesis'], name: 'Thesis');
      for (final name in real) {
        expect(
          buildChatSpaceScopeSection({name}, scope),
          isNotEmpty,
          reason: '$name should switch the Space announcement on',
        );
      }
    });

    test('the chat screen delegates to it rather than re-implementing the gate',
        () {
      // The one line this pair of tests cannot execute (the builder it sits in
      // is private): the screen must call the shared function and put the
      // result into the prompt.
      final source = File(
        'lib/screens/conversation_chat_screen.dart',
      ).readAsStringSync();

      expect(source, contains('buildChatSpaceScopeSection('));
      expect(
        RegExp(r'lines\.add\(spaceScopeSection\)').hasMatch(source),
        isTrue,
        reason: 'the section must reach the prompt line list',
      );
    });
  });
}
