import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';

import 'skill_index_scope_version_test.mocks.dart';

/// M6: the three holders of a cached skill index re-check
/// [SpaceScopeService.scopeVersion] before reuse and rebuild when it moved.
///
/// Pull, not push: the scope is not a listenable, and a chat session or an
/// agent run routinely outlives several Space switches. A stale index is not a
/// cosmetic problem — it offers the model skills the current Space cannot load.
@GenerateMocks([
  ContextManagerService,
  ModelSelector,
  AIService,
  DatabaseService,
  PromptTemplateService,
])
Note skillNote(String id, String name, List<String> tags) {
  final now = DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: name,
    content: '---\nname: $name\ndescription: Use for $name\n---\n\nbody',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: [SkillService.agentSkillTag, ...tags],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockDatabaseService mockDb;
  late SpaceScopeService scope;

  const spaceS = SpaceSnapshot(id: 'space-s', includeTags: ['thesis']);
  const spaceT = SpaceSnapshot(id: 'space-t', includeTags: ['reading']);

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    scope = SpaceScopeService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<SpaceScopeService>(scope);
    getIt.registerSingleton<SkillService>(
      SkillService(mockDb, spaceScope: scope),
    );
    scope.setSpaceSnapshots([spaceS, spaceT]);
    when(mockDb.getNotesByTag(SkillService.agentSkillTag)).thenAnswer(
      (_) async => [
        skillNote('skill-thesis', 'Thesis', ['thesis']),
        skillNote('skill-reading', 'Reading', ['reading']),
      ],
    );
  });

  group('ConversationService', () {
    late ConversationService conversations;

    setUp(() {
      conversations = ConversationService(mockDb);
    });

    test('enableSkills builds a scoped index', () async {
      scope.setActive(spaceS.id, spaceS.includeTags);
      await conversations.enableSkills();
      expect(conversations.skillIndex.keys, ['skill-thesis']);
    });

    test('the index is not stale straight after enableSkills', () async {
      scope.setActive(spaceS.id, spaceS.includeTags);
      await conversations.enableSkills();
      expect(conversations.isSkillIndexStale, isFalse);
    });

    test('activating another Space makes it stale', () async {
      scope.setActive(spaceS.id, spaceS.includeTags);
      await conversations.enableSkills();
      scope.setActive(spaceT.id, spaceT.includeTags);
      expect(conversations.isSkillIndexStale, isTrue);
    });

    test('ensureSkillIndex rebuilds against the new Space', () async {
      scope.setActive(spaceS.id, spaceS.includeTags);
      await conversations.enableSkills();
      scope.setActive(spaceT.id, spaceT.includeTags);

      final index = await conversations.ensureSkillIndex();
      expect(index.keys, ['skill-reading']);
      expect(conversations.skillIndex.keys, ['skill-reading']);
      expect(conversations.isSkillIndexStale, isFalse);
    });

    test(
      'ensureSkillIndex does not rebuild when the scope did not move',
      () async {
        scope.setActive(spaceS.id, spaceS.includeTags);
        await conversations.enableSkills();
        await conversations.ensureSkillIndex();
        await conversations.ensureSkillIndex();
        verify(mockDb.getNotesByTag(SkillService.agentSkillTag)).called(1);
      },
    );

    test('a rename does not invalidate the index', () async {
      // `activeSpaceName` deliberately does not bump scopeVersion: a rename
      // changes nothing about what is in scope, so a cached index stays valid.
      scope.setActive(spaceS.id, spaceS.includeTags, name: 'Thesis');
      await conversations.enableSkills();
      scope.setActive(spaceS.id, spaceS.includeTags, name: 'PhD');
      expect(conversations.isSkillIndexStale, isFalse);
      await conversations.ensureSkillIndex();
      verify(mockDb.getNotesByTag(SkillService.agentSkillTag)).called(1);
    });

    test('a changed Space list invalidates it too', () async {
      // The "no active Space" column of the visibility table reads the snapshot
      // list, so an index built against a stale list must be rebuilt.
      await conversations.enableSkills();
      scope.setSpaceSnapshots([spaceS]);
      expect(conversations.isSkillIndexStale, isTrue);
    });

    test('ensureSkillIndex is empty and cheap while skills are off', () async {
      await conversations.enableSkills();
      conversations.disableSkills();
      scope.setActive(spaceT.id, spaceT.includeTags);
      expect(conversations.isSkillIndexStale, isFalse);
      expect(await conversations.ensureSkillIndex(), isEmpty);
      verify(mockDb.getNotesByTag(SkillService.agentSkillTag)).called(1);
    });
  });

  group('AgentService', () {
    late AgentService agent;

    setUp(() {
      getIt.registerSingleton<ContextManagerService>(
        MockContextManagerService(),
      );
      getIt.registerSingleton<ModelSelector>(MockModelSelector());
      getIt.registerSingleton<AIService>(MockAIService());
      getIt.registerSingleton<PromptTemplateService>(
        MockPromptTemplateService(),
      );
      agent = AgentService(
        getIt<ContextManagerService>(),
        getIt<ModelSelector>(),
        getIt<AIService>(),
        mockDb,
      );
    });

    test('the first check builds the index', () async {
      scope.setActive(spaceS.id, spaceS.includeTags);
      await agent.refreshSkillIndexIfScopeChanged();
      verify(mockDb.getNotesByTag(SkillService.agentSkillTag)).called(1);
    });

    test('a second check with an unchanged scope rebuilds nothing', () async {
      scope.setActive(spaceS.id, spaceS.includeTags);
      await agent.refreshSkillIndexIfScopeChanged();
      await agent.refreshSkillIndexIfScopeChanged();
      verify(mockDb.getNotesByTag(SkillService.agentSkillTag)).called(1);
    });

    test('switching Space rebuilds', () async {
      scope.setActive(spaceS.id, spaceS.includeTags);
      await agent.refreshSkillIndexIfScopeChanged();
      scope.setActive(spaceT.id, spaceT.includeTags);
      await agent.refreshSkillIndexIfScopeChanged();
      verify(mockDb.getNotesByTag(SkillService.agentSkillTag)).called(2);
    });
  });

  group('the wiring the three holders depend on', () {
    // The chat screen caches a *count* derived from the same index; its refresh
    // is a private method on a 4000-line StatefulWidget whose send path needs a
    // model, a conversation and an AI service to reach. The behaviour it
    // delegates to is covered above; what a source assertion adds is that the
    // delegation is still on the prompt path, which is where a stale index
    // actually reaches the model.
    String source(String path) => File(path).readAsStringSync();

    test('the chat screen refreshes before building its system message', () {
      final src = source('lib/screens/conversation_chat_screen.dart');
      final start = src.indexOf('_buildConversationSystemMessage({');
      expect(start, greaterThan(0));
      final head = src.substring(start, start + 900);
      expect(head, contains('await _refreshSkillIndexIfScopeChanged()'));
    });

    test('the chat screen refresh goes through ensureSkillIndex, '
        'with nothing returning before it', () {
      // Positional, not merely present. The screen used to carry a staleness
      // guard of its own in front of this call; inverting its single `!` made
      // it rebuild only when the index was *already* fresh, which fed the
      // previous Space's skills to the model — and the prompt reads the
      // cached `skillIndex` getter, so this call is what makes it fresh.
      // The guard was redundant (`ensureSkillIndex` returns the cache when the
      // scope has not moved) and is gone; nothing may reintroduce an early
      // return in front of it.
      final src = source('lib/screens/conversation_chat_screen.dart');
      final start = src.indexOf(
        'Future<void> _refreshSkillIndexIfScopeChanged',
      );
      expect(start, greaterThan(0));
      final body = src.substring(start, start + 700);
      final open = body.indexOf('{');
      final call = body.indexOf('ensureSkillIndex()');
      expect(call, greaterThan(open));
      expect(
        body.substring(open, call),
        isNot(contains('return')),
        reason:
            'a guard in front of the rebuild is a polarity that can be '
            'inverted into "refresh only when already fresh"',
      );
      expect(body, isNot(contains('isSkillIndexStale')));
    });

    test('the agent refreshes before performing a task', () {
      final src = source('lib/services/agent_service.dart');
      final start = src.indexOf('Future<void> _performTask(');
      expect(start, greaterThan(0));
      final head = src.substring(start, start + 500);
      expect(head, contains('await refreshSkillIndexIfScopeChanged()'));
    });
  });
}
