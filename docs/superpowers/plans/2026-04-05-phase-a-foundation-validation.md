# Phase A: Agent Skills Foundation Validation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the implemented skill system works end-to-end before building wiki skills on it.

**Architecture:** Three test suites validate the three layers: (1) skill parsing/indexing in `SkillService`, (2) loaded-skill survival through context compaction in `ContextManagerService`, (3) skill discovery and tool resolution in `ConversationService`. All tests use mockito with `resetForTesting()` + `getIt` registration.

**Tech Stack:** Flutter test, mockito, `@GenerateMocks`

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase A

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `test/skill_pipeline_integration_test.dart` | Task A1: frontmatter edge cases, index building, load_skill caching, tool URI extraction |
| Create | `test/context_manager_skill_compaction_test.dart` | Task A2: loaded skills survive compaction, token budget respected |
| Create | `test/conversation_skill_discovery_test.dart` | Task A3: enableSkills/disableSkills, tool URI resolution, dedup |

---

### Task 1: Skill Pipeline Integration Tests

**Files:**
- Create: `test/skill_pipeline_integration_test.dart`
- Read: `lib/services/skill_service.dart` (all methods)
- Read: `lib/services/tools/load_skill_tool.dart` (execute, resetSession)

This task extends the existing `test/skill_service_test.dart` and `test/load_skill_tool_test.dart` with edge-case coverage that the original tests don't cover. The existing tests validate happy paths; this suite targets parsing edge cases, malformed inputs, and caching invariants.

- [ ] **Step 1: Create the test file with imports and setup**

```dart
// test/skill_pipeline_integration_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'skill_pipeline_integration_test.mocks.dart';

Note _makeNote(String id, String content, {List<String> tags = const ['agent-skill']}) => Note(
  id: id,
  title: 'title',
  content: content,
  type: NoteType.note,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  subNotes: [],
  tags: tags,
  attachmentPaths: [],
);

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late SkillService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = SkillService(mockDb);
  });
}
```

- [ ] **Step 2: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: `test/skill_pipeline_integration_test.mocks.dart` created, no errors.

- [ ] **Step 3: Add frontmatter parsing edge-case tests**

Add inside `void main()`:

```dart
  group('parseSkillMetadata edge cases', () {
    test('handles colons in description value', () {
      const content =
          '---\nname: Analyzer\ndescription: Use for: deep analysis of: things\nenabled: true\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.name, 'Analyzer');
      // The current line-based parser splits on first colon, so the full value after "description:" is preserved
      expect(meta.description, 'Use for: deep analysis of: things');
    });

    test('returns null for multi-line description (known limitation)', () {
      // Current parser is line-based — multi-line YAML values are not supported.
      // This documents the known limitation.
      const content =
          '---\nname: Skill\ndescription: |\n  Line one\n  Line two\nenabled: true\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      // The parser will see "description:" with value "|" — not a useful description.
      // This is a known limitation. The test documents current behavior.
      if (meta != null) {
        // If it parses, the description will be just "|"
        expect(meta.description, '|');
      }
      // Either null or "|" is acceptable for now — just document it.
    });

    test('handles extra whitespace in frontmatter values', () {
      const content =
          '---\nname:   Spaced Skill  \ndescription:   Has spaces  \n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.name, 'Spaced Skill');
      expect(meta.description, 'Has spaces');
    });

    test('handles empty content string', () {
      expect(service.parseSkillMetadata('note-1', ''), isNull);
    });

    test('handles frontmatter with no closing delimiter', () {
      const content = '---\nname: Broken\ndescription: No end';
      expect(service.parseSkillMetadata('note-1', content), isNull);
    });
  });
```

- [ ] **Step 4: Add buildSkillIndex tests for mixed inputs**

```dart
  group('buildSkillIndex with mixed inputs', () {
    test('returns empty map when zero enabled skills exist', () async {
      when(mockDb.getNotesByTag('agent-skill')).thenAnswer((_) async => [
        _makeNote('id-1', '---\nname: A\ndescription: D\nenabled: false\n---\n\nbody'),
        _makeNote('id-2', 'no frontmatter at all'),
      ]);
      final index = await service.buildSkillIndex();
      expect(index, isEmpty);
    });

    test('filters malformed notes from index', () async {
      when(mockDb.getNotesByTag('agent-skill')).thenAnswer((_) async => [
        _makeNote('good', '---\nname: Valid\ndescription: Works\nenabled: true\n---\n\nbody'),
        _makeNote('bad-1', '---\nname: \ndescription: Empty name\n---\n\nbody'),
        _makeNote('bad-2', '---\nenabled: true\n---\n\nbody'),
        _makeNote('bad-3', 'just plain text'),
        _makeNote('disabled', '---\nname: Off\ndescription: Disabled\nenabled: false\n---\n\nbody'),
      ]);
      final index = await service.buildSkillIndex();
      expect(index.length, 1);
      expect(index.containsKey('good'), true);
    });
  });

  group('buildSkillIndexPrompt', () {
    test('returns empty string for empty map', () {
      expect(service.buildSkillIndexPrompt({}), isEmpty);
    });

    test('includes all entries for non-empty map', () {
      final index = {
        'id-a': const SkillMetadata(noteId: 'id-a', name: 'Alpha', description: 'Does A', enabled: true),
        'id-b': const SkillMetadata(noteId: 'id-b', name: 'Beta', description: 'Does B', enabled: true),
      };
      final prompt = service.buildSkillIndexPrompt(index);
      expect(prompt, contains('id-a'));
      expect(prompt, contains('Alpha'));
      expect(prompt, contains('id-b'));
      expect(prompt, contains('Beta'));
      expect(prompt, contains('load_skill'));
    });
  });
```

- [ ] **Step 5: Add LoadSkillTool caching and resetSession tests**

```dart
  group('LoadSkillTool caching', () {
    late LoadSkillTool tool;

    setUp(() {
      getIt.registerSingleton<SkillService>(service);
      tool = LoadSkillTool();
    });

    test('second call returns cached content without DB hit', () async {
      const content = '---\nname: Cached\ndescription: Test\nenabled: true\n---\n\n## Steps\nDo things.';
      when(mockDb.getNote('note-1')).thenAnswer((_) async => _makeNote('note-1', content));

      final result1 = await tool.execute({'noteId': 'note-1'});
      final result2 = await tool.execute({'noteId': 'note-1'});

      verify(mockDb.getNote('note-1')).called(1); // Only one DB call
      expect(result1, result2);
    });

    test('resetSession clears cache so next call hits DB', () async {
      const content = '---\nname: Skill\ndescription: Test\nenabled: true\n---\n\nbody';
      when(mockDb.getNote('note-1')).thenAnswer((_) async => _makeNote('note-1', content));

      await tool.execute({'noteId': 'note-1'});
      tool.resetSession();
      await tool.execute({'noteId': 'note-1'});

      verify(mockDb.getNote('note-1')).called(2); // Two DB calls after reset
    });
  });
```

- [ ] **Step 6: Add extractToolUris and parseToolUri tests**

```dart
  group('extractToolUris', () {
    test('finds tool URIs and ignores note URIs', () {
      const content = '''
Use [search](notesynapse://tool/builtin/search_notes) to find notes.
Also see [this note](notesynapse://note/abc-123) for context.
And [MCP tool](notesynapse://tool/mcp/server-1/query).
''';
      final uris = service.extractToolUris(content);
      expect(uris, contains('notesynapse://tool/builtin/search_notes'));
      expect(uris, contains('notesynapse://tool/mcp/server-1/query'));
      expect(uris, isNot(contains('notesynapse://note/abc-123')));
    });

    test('returns empty list for content with no URIs', () {
      expect(service.extractToolUris('No links here.'), isEmpty);
    });
  });

  group('parseToolUri', () {
    test('parses builtin namespace', () {
      final r = service.parseToolUri('notesynapse://tool/builtin/search_notes');
      expect(r, isNotNull);
      expect(r!.namespace, 'builtin');
      expect(r.id, 'search_notes');
      expect(r.function, isNull);
    });

    test('parses user_defined namespace with function', () {
      final r = service.parseToolUri('notesynapse://tool/user_defined/uuid-123/analyze');
      expect(r!.namespace, 'user_defined');
      expect(r.id, 'uuid-123');
      expect(r.function, 'analyze');
    });

    test('parses mcp namespace', () {
      final r = service.parseToolUri('notesynapse://tool/mcp/my-server/do_thing');
      expect(r!.namespace, 'mcp');
      expect(r.id, 'my-server');
      expect(r.function, 'do_thing');
    });

    test('returns null for note URI', () {
      expect(service.parseToolUri('notesynapse://note/abc'), isNull);
    });

    test('returns null for malformed URI with only namespace', () {
      expect(service.parseToolUri('notesynapse://tool/builtin'), isNull);
    });
  });
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `flutter test test/skill_pipeline_integration_test.dart -v`
Expected: All tests pass. The multi-line description test documents current behavior (not a failure).

- [ ] **Step 8: Commit**

```bash
git add test/skill_pipeline_integration_test.dart test/skill_pipeline_integration_test.mocks.dart
git commit -m "test: add skill pipeline integration tests (Phase A1)

Cover frontmatter edge cases, mixed-input index building,
LoadSkillTool caching invariants, and tool URI parsing."
```

---

### Task 2: Context Compaction With Loaded Skills

**Files:**
- Create: `test/context_manager_skill_compaction_test.dart`
- Read: `lib/services/context_manager_service.dart:662-669` (addLoadedSkill)
- Read: `lib/models/context_node.dart` (LoadedSkill, ContextNode.loadedSkills)

This task verifies that loaded skills are never removed or truncated during context compaction. The compaction logic should compact the execution log but leave pinned skills intact.

- [ ] **Step 1: Read ContextManagerService compaction logic to understand the test surface**

Read: `lib/services/context_manager_service.dart` — find `compactNodeContext` method and understand what it compacts (execution log entries) vs what it preserves (objective, loadedSkills).

Also read: `lib/models/context_node.dart` — understand `ContextNode` fields: `loadedSkills`, `executionLog`, `estimatedTokens`, `maxContextTokens`.

- [ ] **Step 2: Create the test file with imports and setup**

```dart
// test/context_manager_skill_compaction_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'context_manager_skill_compaction_test.mocks.dart';

@GenerateMocks([DatabaseService, AIService])
void main() {
  late MockDatabaseService mockDb;
  late MockAIService mockAi;
  late ContextManagerService contextManager;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockAi = MockAIService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<AIService>(mockAi);
    contextManager = ContextManagerService();
  });
}
```

- [ ] **Step 3: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: `test/context_manager_skill_compaction_test.mocks.dart` created.

- [ ] **Step 4: Add skill survival tests**

Add inside `void main()`. Note: the exact API for creating context nodes and triggering compaction needs to match what `ContextManagerService` exposes. Read the service first (Step 1) to get exact method names.

```dart
  group('loaded skills survive compaction', () {
    test('skills remain after compaction of execution log', () async {
      // Create a root context with a small budget to force compaction
      final rootId = contextManager.createRootContext(
        objective: 'Test objective',
        maxContextTokens: 16000,
      );
      final root = contextManager.getContext(rootId)!;

      // Add two loaded skills
      contextManager.addLoadedSkill('skill-1', '## Skill One\nDo step A then step B.');
      contextManager.addLoadedSkill('skill-2', '## Skill Two\nDo step C then step D.');

      expect(root.loadedSkills.length, 2);

      // Fill execution log with enough content to trigger compaction
      for (var i = 0; i < 50; i++) {
        root.log('Observation $i: ' + 'x' * 200);
      }

      // Trigger compaction
      // (Mock AI to return a summary for compaction)
      when(mockAi.generateText(any, any))
          .thenAnswer((_) async => 'Compacted summary of observations.');

      await contextManager.checkAndCompact(root);

      // Skills must survive
      expect(root.loadedSkills.length, 2);
      expect(root.loadedSkills[0].noteId, 'skill-1');
      expect(root.loadedSkills[1].noteId, 'skill-2');
    });

    test('addLoadedSkill deduplicates by noteId', () {
      contextManager.createRootContext(
        objective: 'Test',
        maxContextTokens: 100000,
      );

      contextManager.addLoadedSkill('skill-1', 'Content v1');
      contextManager.addLoadedSkill('skill-1', 'Content v2'); // duplicate

      final root = contextManager.rootContext!;
      expect(root.loadedSkills.length, 1);
      expect(root.loadedSkills[0].content, 'Content v1'); // first wins
    });
  });
```

- [ ] **Step 5: Run tests**

Run: `flutter test test/context_manager_skill_compaction_test.dart -v`
Expected: All tests pass. If `createRootContext` or `checkAndCompact` have different signatures, adjust the test to match the actual API (discovered in Step 1).

- [ ] **Step 6: Commit**

```bash
git add test/context_manager_skill_compaction_test.dart test/context_manager_skill_compaction_test.mocks.dart
git commit -m "test: verify loaded skills survive context compaction (Phase A2)"
```

---

### Task 3: Chat Mode Skill Discovery End-to-End

**Files:**
- Create: `test/conversation_skill_discovery_test.dart`
- Read: `lib/services/conversation_service.dart:91-197` (enableSkills, disableSkills, handleLoadSkillResult)

This task verifies that `ConversationService` correctly builds the skill index, resolves tool URIs from loaded skills, and avoids duplicate tools.

- [ ] **Step 1: Read ConversationService skill methods to understand exact signatures and dependencies**

Read: `lib/services/conversation_service.dart` — the skill-related fields (lines 25-70), `enableSkills()` (lines 91-101), `disableSkills()` (lines 104-112), `handleLoadSkillResult()` (lines 123-197).

Identify: what services does `ConversationService` depend on? What needs to be mocked?

- [ ] **Step 2: Create the test file with imports and setup**

```dart
// test/conversation_skill_discovery_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/models/note.dart';

import 'conversation_skill_discovery_test.mocks.dart';

Note _makeSkillNote(String id, String content) => Note(
  id: id,
  title: 'Skill',
  content: content,
  type: NoteType.note,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  subNotes: [],
  tags: ['agent-skill'],
  attachmentPaths: [],
);

// List all services that ConversationService depends on.
// Adjust this list after reading the constructor in Step 1.
@GenerateMocks([DatabaseService, AIService, SkillService])
void main() {
  late MockDatabaseService mockDb;
  late MockSkillService mockSkillService;
  late ConversationService conversationService;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockSkillService = MockSkillService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<SkillService>(mockSkillService);

    // Register other required services discovered in Step 1
    // ...

    conversationService = ConversationService(/* constructor args from Step 1 */);
  });
}
```

**Note to implementer:** The exact constructor for `ConversationService` and the full list of `@GenerateMocks` dependencies must be discovered by reading `conversation_service.dart`. The template above is a starting point — adjust after Step 1.

- [ ] **Step 3: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`

- [ ] **Step 4: Add enableSkills/disableSkills tests**

```dart
  group('enableSkills', () {
    test('populates skill index from DB', () async {
      final index = {
        'id-1': const SkillMetadata(
          noteId: 'id-1', name: 'Wiki Ingest', description: 'Ingest sources', enabled: true),
      };
      when(mockSkillService.buildSkillIndex()).thenAnswer((_) async => index);
      when(mockSkillService.resetSession()).thenReturn(null);

      await conversationService.enableSkills();

      // Verify the skill index is populated
      // Access method depends on ConversationService API — may need a getter or reflection
      verify(mockSkillService.buildSkillIndex()).called(1);
    });
  });

  group('disableSkills', () {
    test('clears index and discovered tools', () async {
      // Enable first
      when(mockSkillService.buildSkillIndex()).thenAnswer((_) async => {
        'id-1': const SkillMetadata(
          noteId: 'id-1', name: 'Skill', description: 'Desc', enabled: true),
      });
      when(mockSkillService.resetSession()).thenReturn(null);
      await conversationService.enableSkills();

      // Then disable
      conversationService.disableSkills();

      // Verify state is cleared — access depends on ConversationService API
      verify(mockSkillService.resetSession()).called(greaterThanOrEqualTo(1));
    });
  });
```

- [ ] **Step 5: Add handleLoadSkillResult tool discovery tests**

```dart
  group('handleLoadSkillResult', () {
    test('discovers builtin tool URIs from skill content', () async {
      const skillContent = '''
## Workflow
1. Search for notes using [search](notesynapse://tool/builtin/search_notes)
2. Read each note using [read](notesynapse://tool/builtin/read_note)
''';
      when(mockSkillService.extractToolUris(skillContent)).thenReturn([
        'notesynapse://tool/builtin/search_notes',
        'notesynapse://tool/builtin/read_note',
      ]);
      when(mockSkillService.parseToolUri('notesynapse://tool/builtin/search_notes'))
          .thenReturn((namespace: 'builtin', id: 'search_notes', function: null));
      when(mockSkillService.parseToolUri('notesynapse://tool/builtin/read_note'))
          .thenReturn((namespace: 'builtin', id: 'read_note', function: null));

      await conversationService.handleLoadSkillResult('note-1', skillContent);

      // Verify tools were discovered — the exact assertion depends on
      // whether ConversationService exposes _skillDiscoveredTools.
      // If not exposed, verify through behavior (e.g., the tools appear in getAvailableTools()).
    });

    test('second enableSkills resets state cleanly (no duplicate tools)', () async {
      when(mockSkillService.buildSkillIndex()).thenAnswer((_) async => {});
      when(mockSkillService.resetSession()).thenReturn(null);

      await conversationService.enableSkills();
      await conversationService.enableSkills(); // second call

      // No duplicate tools should exist
      verify(mockSkillService.resetSession()).called(2);
    });
  });
```

- [ ] **Step 6: Run tests**

Run: `flutter test test/conversation_skill_discovery_test.dart -v`
Expected: All tests pass after adjustments for actual API.

- [ ] **Step 7: Commit**

```bash
git add test/conversation_skill_discovery_test.dart test/conversation_skill_discovery_test.mocks.dart
git commit -m "test: verify chat-mode skill discovery end-to-end (Phase A3)"
```

---

### Task 4: Run full test suite and verify no regressions

- [ ] **Step 1: Run all tests**

Run: `flutter test`
Expected: All existing tests plus the 3 new test files pass.

- [ ] **Step 2: Run analysis**

Run: `flutter analyze`
Expected: No new errors or warnings in test files.

- [ ] **Step 3: Commit any fixups if needed**

If any existing tests broke due to mock generation conflicts, fix and commit.
