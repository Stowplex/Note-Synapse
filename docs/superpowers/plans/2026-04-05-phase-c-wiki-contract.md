# Phase C: Wiki Workflow Contract

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the tag-to-workflow binding platform mechanism with execution support, then define the namespace-aware wiki schema and workflow UX spec.

**Architecture:** Five deliverables: (0a) generic tag-to-workflow binding infrastructure (`TagWorkflowService` + `tag_workflow_bindings` table — no wiki-specific code), (0b) workflow execution via `AgentService.runWorkflowTask()` — reuses the existing ReAct loop as a single task, (1) `docs/wiki-schema.md` with namespaced tag conventions, (2) `docs/wiki-workflow-ux.md` with tag-triggered operations, (3) cross-validation. Tags carry namespaces (`wiki-source-ml`, not `wiki-source`). Ingest is triggered by tag-to-workflow binding, not manual skill invocation.

**Tech Stack:** Dart (Tasks 0a, 0b), Markdown (Tasks 1-3)

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase C

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `lib/services/tag_workflow_service.dart` | C0a: Generic tag-to-workflow binding service |
| Modify | `lib/services/database_service.dart` | C0a: Add `tag_workflow_bindings` table and CRUD methods |
| Create | `test/tag_workflow_service_test.dart` | C0a: Tests for tag-to-workflow resolution and immutability |
| Modify | `lib/services/agent_service.dart` | C0b: Add `runWorkflowTask()` method |
| Create | `test/workflow_task_test.dart` | C0b: Tests for workflow task execution |
| Create | `docs/wiki-schema.md` | C1: Namespace-aware schema artifact |
| Create | `docs/wiki-workflow-ux.md` | C2: Namespace + tag-triggered workflow UX spec |

---

### Task 0a: Tag-Workflow Binding Infrastructure (C0a)

**Files:**
- Create: `lib/services/tag_workflow_service.dart` — `TagWorkflowService` with `resolveBindings`, `hasImmutableBinding`, `registerBinding`, `removeBinding`
- Modify: `lib/services/database_service.dart` — add `tag_workflow_bindings` table and CRUD methods
- Create: `test/tag_workflow_service_test.dart`

This is a **generic platform mechanism** — no wiki-specific code. Any tag pattern (exact or prefix) can bind to any skill with properties like `contentImmutable`. The prefix `wiki-source-` is just data registered at runtime by the Wiki Bootstrap skill, not hardcoded in platform code.

The `tag_workflow_bindings` table is separate from the existing `tag_ai_configs` table. Each binding has:
- `pattern`: tag name or prefix (e.g., `wiki-source-` for prefix, `special-tag` for exact)
- `isPrefix`: whether this is a prefix match (`true`) or exact match (`false`)
- `skillNoteId`: the skill note to load
- `prompt`: the objective/system prompt template for the workflow task (supports `{note_id}` and `{matched_tag}` template vars)
- `contentImmutable`: whether notes with this tag should reject content/title modifications

Resolution rules: exact match > prefix match > no match. The binding returns `(skillNoteId, matchedTag, pattern, prompt)`. The **skill** — not the platform — interprets the tag suffix.

- [ ] **Step 1: Read existing tag schema in DatabaseService**

Read: `lib/services/database_service.dart` — find the tags table schema, `tag_ai_configs` table, and migration pattern to understand how to add a new table.

- [ ] **Step 2: Write the failing tests**

```dart
// test/tag_workflow_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'tag_workflow_service_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late TagWorkflowService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = TagWorkflowService(mockDb);
  });

  group('resolveBindings', () {
    test('returns empty list when no tags have bindings', () async {
      when(mockDb.getExactWorkflowBinding(any))
          .thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => []);

      final result = await service.resolveBindings(['regular-tag', 'other']);
      expect(result, isEmpty);
    });

    test('resolves exact match binding', () async {
      when(mockDb.getExactWorkflowBinding('special-tag'))
          .thenAnswer((_) async => WorkflowBindingRow(
            pattern: 'special-tag',
            isPrefix: false,
            skillNoteId: 'skill-1',
            prompt: 'Process this note.',
            contentImmutable: false,
          ));
      when(mockDb.getExactWorkflowBinding('other'))
          .thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => []);

      final result = await service.resolveBindings(['special-tag', 'other']);
      expect(result.length, 1);
      expect(result[0].skillNoteId, 'skill-1');
      expect(result[0].matchedTag, 'special-tag');
    });

    test('resolves prefix match binding', () async {
      when(mockDb.getExactWorkflowBinding('wiki-source-ml'))
          .thenAnswer((_) async => null);
      when(mockDb.getExactWorkflowBinding('other'))
          .thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => [
            WorkflowBindingRow(
              pattern: 'wiki-source-',
              isPrefix: true,
              skillNoteId: 'ingest-skill',
              prompt: 'Ingest source note {note_id} tagged {matched_tag} into the wiki.',
              contentImmutable: true,
            ),
          ]);

      final result = await service.resolveBindings(['wiki-source-ml', 'other']);
      expect(result.length, 1);
      expect(result[0].skillNoteId, 'ingest-skill');
      expect(result[0].matchedTag, 'wiki-source-ml');
      expect(result[0].pattern, 'wiki-source-');
      expect(result[0].contentImmutable, isTrue);
    });

    test('exact match takes precedence over prefix match for same tag', () async {
      when(mockDb.getExactWorkflowBinding('wiki-source-ml'))
          .thenAnswer((_) async => WorkflowBindingRow(
            pattern: 'wiki-source-ml',
            isPrefix: false,
            skillNoteId: 'exact-skill',
            prompt: 'Process ML source {note_id}.',
            contentImmutable: false,
          ));
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => [
            WorkflowBindingRow(
              pattern: 'wiki-source-',
              isPrefix: true,
              skillNoteId: 'prefix-skill',
              prompt: 'Ingest {note_id} from {matched_tag}.',
              contentImmutable: true,
            ),
          ]);

      final result = await service.resolveBindings(['wiki-source-ml']);
      expect(result.length, 1);
      expect(result[0].skillNoteId, 'exact-skill');
    });

    test('returns error when two tags match the same prefix pattern', () async {
      when(mockDb.getExactWorkflowBinding(any))
          .thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => [
            WorkflowBindingRow(
              pattern: 'wiki-source-',
              isPrefix: true,
              skillNoteId: 'ingest-skill',
              prompt: 'Ingest source note {note_id} tagged {matched_tag} into the wiki.',
              contentImmutable: true,
            ),
          ]);

      expect(
        () => service.resolveBindings(['wiki-source-ml', 'wiki-source-ai']),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('ambiguous'))),
      );
    });

    test('two tags matching different prefix patterns is valid', () async {
      when(mockDb.getExactWorkflowBinding(any))
          .thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => [
            WorkflowBindingRow(
              pattern: 'wiki-source-',
              isPrefix: true,
              skillNoteId: 'wiki-skill',
              prompt: 'Ingest wiki source {note_id}.',
              contentImmutable: true,
            ),
            WorkflowBindingRow(
              pattern: 'recipe-source-',
              isPrefix: true,
              skillNoteId: 'recipe-skill',
              prompt: 'Process recipe source {note_id}.',
              contentImmutable: true,
            ),
          ]);

      final result = await service.resolveBindings(['wiki-source-ml', 'recipe-source-italian']);
      expect(result.length, 2);
    });
  });

  group('hasImmutableBinding', () {
    test('returns true when any tag has immutable binding', () async {
      when(mockDb.getExactWorkflowBinding('wiki-source-ml'))
          .thenAnswer((_) async => null);
      when(mockDb.getExactWorkflowBinding('other'))
          .thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => [
            WorkflowBindingRow(
              pattern: 'wiki-source-',
              isPrefix: true,
              skillNoteId: 'ingest-skill',
              prompt: 'Ingest source note {note_id} tagged {matched_tag} into the wiki.',
              contentImmutable: true,
            ),
          ]);

      final result = await service.hasImmutableBinding(['wiki-source-ml', 'other']);
      expect(result, isTrue);
    });

    test('returns false when no immutable bindings', () async {
      when(mockDb.getExactWorkflowBinding(any))
          .thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => []);

      final result = await service.hasImmutableBinding(['regular-tag']);
      expect(result, isFalse);
    });

    test('returns false when binding exists but contentImmutable is false', () async {
      when(mockDb.getExactWorkflowBinding('wiki-compiled-ml'))
          .thenAnswer((_) async => WorkflowBindingRow(
            pattern: 'wiki-compiled-ml',
            isPrefix: false,
            skillNoteId: 'compile-skill',
            prompt: 'Compile {note_id}.',
            contentImmutable: false,
          ));
      when(mockDb.getPrefixWorkflowBindings())
          .thenAnswer((_) async => []);

      final result = await service.hasImmutableBinding(['wiki-compiled-ml']);
      expect(result, isFalse);
    });
  });

  group('registerBinding', () {
    test('inserts a new binding', () async {
      when(mockDb.insertWorkflowBinding(any)).thenAnswer((_) async {});

      await service.registerBinding(
        pattern: 'wiki-source-',
        isPrefix: true,
        skillNoteId: 'ingest-skill',
        prompt: 'Ingest source note {note_id} tagged {matched_tag}.',
        contentImmutable: true,
      );

      verify(mockDb.insertWorkflowBinding(any)).called(1);
    });
  });

  group('removeBinding', () {
    test('deletes a binding by pattern', () async {
      when(mockDb.deleteWorkflowBinding('wiki-source-')).thenAnswer((_) async {});

      await service.removeBinding('wiki-source-');

      verify(mockDb.deleteWorkflowBinding('wiki-source-')).called(1);
    });
  });
}
```

- [ ] **Step 3: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`

- [ ] **Step 4: Add `tag_workflow_bindings` table to DatabaseService**

In `lib/services/database_service.dart`, add the table creation in the migration section. Check the current `DATABASE_VERSION` and increment it.

```dart
  // In _onCreate or migration:
  await db.execute('''
    CREATE TABLE IF NOT EXISTS tag_workflow_bindings (
      pattern TEXT PRIMARY KEY,
      isPrefix INTEGER NOT NULL DEFAULT 0,
      skillNoteId TEXT NOT NULL,
      prompt TEXT NOT NULL DEFAULT '',
      contentImmutable INTEGER NOT NULL DEFAULT 0
    )
  ''');
```

Also update `recovery_screen.dart` per CLAUDE.md instructions.

Add CRUD methods:

```dart
  /// Get an exact-match workflow binding for a tag name.
  Future<WorkflowBindingRow?> getExactWorkflowBinding(String tagName) async {
    final db = await database;
    final result = await db.query(
      'tag_workflow_bindings',
      where: 'pattern = ? AND isPrefix = 0',
      whereArgs: [tagName],
    );
    if (result.isEmpty) return null;
    return WorkflowBindingRow.fromRow(result.first);
  }

  /// Get all prefix-match workflow bindings.
  Future<List<WorkflowBindingRow>> getPrefixWorkflowBindings() async {
    final db = await database;
    final result = await db.query(
      'tag_workflow_bindings',
      where: 'isPrefix = 1',
    );
    return result.map(WorkflowBindingRow.fromRow).toList();
  }

  /// Insert or replace a workflow binding.
  Future<void> insertWorkflowBinding(WorkflowBindingRow binding) async {
    final db = await database;
    await db.insert(
      'tag_workflow_bindings',
      binding.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Delete a workflow binding by pattern.
  Future<void> deleteWorkflowBinding(String pattern) async {
    final db = await database;
    await db.delete(
      'tag_workflow_bindings',
      where: 'pattern = ?',
      whereArgs: [pattern],
    );
  }
```

The `WorkflowBindingRow` data class (place in `database_service.dart` or a dedicated file):

```dart
class WorkflowBindingRow {
  final String pattern;
  final bool isPrefix;
  final String skillNoteId;
  final String prompt;
  final bool contentImmutable;

  const WorkflowBindingRow({
    required this.pattern,
    required this.isPrefix,
    required this.skillNoteId,
    required this.prompt,
    required this.contentImmutable,
  });

  factory WorkflowBindingRow.fromRow(Map<String, dynamic> row) {
    return WorkflowBindingRow(
      pattern: row['pattern'] as String,
      isPrefix: (row['isPrefix'] as int) == 1,
      skillNoteId: row['skillNoteId'] as String,
      prompt: row['prompt'] as String? ?? '',
      contentImmutable: (row['contentImmutable'] as int) == 1,
    );
  }

  Map<String, dynamic> toMap() => {
    'pattern': pattern,
    'isPrefix': isPrefix ? 1 : 0,
    'skillNoteId': skillNoteId,
    'prompt': prompt,
    'contentImmutable': contentImmutable ? 1 : 0,
  };
}
```

- [ ] **Step 5: Create `TagWorkflowService`**

```dart
// lib/services/tag_workflow_service.dart
import 'package:note_synapse/services/database_service.dart';

/// Result of resolving a tag to its workflow binding.
class ResolvedBinding {
  final String skillNoteId;
  final String matchedTag;
  final String pattern;
  final String prompt;
  final bool contentImmutable;

  const ResolvedBinding({
    required this.skillNoteId,
    required this.matchedTag,
    required this.pattern,
    required this.prompt,
    required this.contentImmutable,
  });
}

/// Generic tag-to-workflow binding engine.
///
/// Tags can bind to skills via exact match or prefix match.
/// Resolution: exact match > prefix match > no match.
/// The skill receives the matched tag string and interprets
/// the suffix itself — the platform does not parse namespaces.
class TagWorkflowService {
  final DatabaseService _db;

  TagWorkflowService(this._db);

  /// Resolve all workflow bindings for a list of tags.
  ///
  /// Returns a list of resolved bindings (one per matched tag).
  /// Throws if two tags match the same prefix pattern (ambiguous).
  Future<List<ResolvedBinding>> resolveBindings(List<String> tags) async {
    final results = <ResolvedBinding>[];
    final prefixBindings = await _db.getPrefixWorkflowBindings();

    // Track prefix pattern → list of matched tags (for ambiguity detection)
    final prefixMatches = <String, List<String>>{};

    for (final tag in tags) {
      // Try exact match first
      final exact = await _db.getExactWorkflowBinding(tag);
      if (exact != null) {
        results.add(ResolvedBinding(
          skillNoteId: exact.skillNoteId,
          matchedTag: tag,
          pattern: exact.pattern,
          prompt: exact.prompt,
          contentImmutable: exact.contentImmutable,
        ));
        continue; // Exact match wins, skip prefix check
      }

      // Try prefix match
      for (final binding in prefixBindings) {
        if (tag.startsWith(binding.pattern) && tag.length > binding.pattern.length) {
          prefixMatches.putIfAbsent(binding.pattern, () => []).add(tag);
        }
      }
    }

    // Check for ambiguous prefix matches (two tags match same prefix)
    for (final entry in prefixMatches.entries) {
      if (entry.value.length > 1) {
        throw Exception(
          'Ambiguous workflow binding: tags ${entry.value.join(", ")} '
          'both match prefix pattern "${entry.key}". '
          'Remove all but one.',
        );
      }

      // Find the binding row for this prefix
      final binding = prefixBindings.firstWhere((b) => b.pattern == entry.key);
      results.add(ResolvedBinding(
        skillNoteId: binding.skillNoteId,
        matchedTag: entry.value.first,
        pattern: entry.key,
        prompt: binding.prompt,
        contentImmutable: binding.contentImmutable,
      ));
    }

    return results;
  }

  /// Check if any of the given tags have a workflow binding with
  /// contentImmutable: true.
  Future<bool> hasImmutableBinding(List<String> tags) async {
    final bindings = await resolveBindings(tags);
    return bindings.any((b) => b.contentImmutable);
  }

  /// Register a new tag-to-workflow binding.
  Future<void> registerBinding({
    required String pattern,
    required bool isPrefix,
    required String skillNoteId,
    required String prompt,
    required bool contentImmutable,
  }) async {
    await _db.insertWorkflowBinding(WorkflowBindingRow(
      pattern: pattern,
      isPrefix: isPrefix,
      skillNoteId: skillNoteId,
      prompt: prompt,
      contentImmutable: contentImmutable,
    ));
  }

  /// Remove a binding by its pattern.
  Future<void> removeBinding(String pattern) async {
    await _db.deleteWorkflowBinding(pattern);
  }
}
```

- [ ] **Step 6: Run tests**

Run: `flutter test test/tag_workflow_service_test.dart -v`
Expected: All tests pass.

- [ ] **Step 7: Run full test suite**

Run: `flutter test`
Expected: No regressions.

- [ ] **Step 8: Commit**

```bash
git add lib/services/tag_workflow_service.dart lib/services/database_service.dart test/tag_workflow_service_test.dart test/tag_workflow_service_test.mocks.dart
git commit -m "feat: generic tag-to-workflow binding infrastructure (Phase C0a)

New tag_workflow_bindings table with pattern, isPrefix, skillNoteId,
prompt, contentImmutable. TagWorkflowService resolves exact > prefix
match. Fully generic — no wiki-specific code in platform layer."
```

---

### Task 0b: Workflow Task Execution via AgentService (C0b)

**Files:**
- Modify: `lib/services/agent_service.dart` — add `runWorkflowTask()`
- Create: `test/workflow_task_test.dart`

**Depends on:** Task 0a (`TagWorkflowService` and `ResolvedBinding`).

This task adds the ability to **execute a bound workflow as a single AgentTask**. Instead of the full plan→execute flow, a workflow binding creates one task that:
1. Has the binding's `prompt` (with `{note_id}` and `{matched_tag}` substituted) as the task description
2. Pre-loads the bound skill into pinned context (or lets the LLM load it via `load_skill`)
3. Runs the existing ReAct loop (`_performTask`) with full tool access
4. On max turns → pauses (existing behavior), UI can extend
5. On completion → result available via `AgentService.tasks` / `finalAnswer`

The key design choice: **skill content is pre-loaded into the root context's `loadedSkills`** before the first turn. This avoids wasting a turn on `load_skill` and ensures the LLM has the workflow instructions from the start. The `load_skill` tool remains available for loading additional skills mid-execution.

**Concurrency**: If the agent is already running, the workflow is queued. A `_pendingWorkflows` queue is added. When the current objective completes (or is cancelled), the next queued workflow starts automatically.

- [ ] **Step 1: Write the failing tests**

```dart
// test/workflow_task_test.dart
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

import 'workflow_task_test.mocks.dart';

@GenerateMocks([DatabaseService, AIService, ModelSelector, ContextManagerService])
void main() {
  late MockDatabaseService mockDb;
  late MockAIService mockAi;
  late MockModelSelector mockModelSelector;
  late MockContextManagerService mockContextManager;
  late AgentService agentService;

  final testNote = Note(
    id: 'note-123',
    title: 'Test Source Note',
    content: 'Some content about ML.',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['wiki-source-ml', 'machine-learning'],
    attachmentPaths: [],
  );

  final testBinding = ResolvedBinding(
    skillNoteId: 'ingest-skill-note',
    matchedTag: 'wiki-source-ml',
    pattern: 'wiki-source-',
    prompt: 'Ingest source note {note_id} tagged {matched_tag} into the wiki. '
        'Load the skill first, then follow the workflow instructions.',
    contentImmutable: true,
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockAi = MockAIService();
    mockModelSelector = MockModelSelector();
    mockContextManager = MockContextManagerService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<ModelSelector>(mockModelSelector);
    agentService = AgentService(
      mockContextManager, mockModelSelector, mockAi, mockDb,
    );
  });

  group('runWorkflowTask', () {
    test('creates a single task with prompt template substituted', () async {
      // We only test task creation, not full execution (that requires LLM mocking)
      // Verify the task is properly configured
      agentService.runWorkflowTask(testBinding, testNote);

      // Allow async setup to complete
      await Future.delayed(Duration.zero);

      expect(agentService.tasks.length, 1);
      final task = agentService.tasks.first;
      expect(task.description, contains('note-123'));
      expect(task.description, contains('wiki-source-ml'));
      expect(task.description, isNot(contains('{note_id}')));
      expect(task.description, isNot(contains('{matched_tag}')));
    });

    test('substitutes template variables in prompt', () {
      final result = AgentService.substitutePromptTemplate(
        'Process {note_id} from {matched_tag}.',
        noteId: 'abc-123',
        matchedTag: 'wiki-source-ml',
      );
      expect(result, 'Process abc-123 from wiki-source-ml.');
    });

    test('queues workflow when agent is already running', () async {
      // Start a first workflow
      agentService.runWorkflowTask(testBinding, testNote);
      await Future.delayed(Duration.zero);

      // Queue a second one
      final secondNote = Note(
        id: 'note-456',
        title: 'Second Note',
        content: 'Content.',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        subNotes: [],
        tags: ['wiki-source-ml'],
        attachmentPaths: [],
      );
      agentService.runWorkflowTask(testBinding, secondNote);

      expect(agentService.pendingWorkflowCount, 1);
    });
  });
}
```

- [ ] **Step 2: Generate mocks and run to verify failing**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/workflow_task_test.dart -v`
Expected: Tests fail — `runWorkflowTask`, `substitutePromptTemplate`, `pendingWorkflowCount` don't exist yet.

- [ ] **Step 3: Add `substitutePromptTemplate` static method to AgentService**

In `lib/services/agent_service.dart`:

```dart
  /// Substitute template variables in a workflow prompt.
  /// Supported vars: {note_id}, {matched_tag}
  static String substitutePromptTemplate(
    String template, {
    required String noteId,
    required String matchedTag,
  }) {
    return template
        .replaceAll('{note_id}', noteId)
        .replaceAll('{matched_tag}', matchedTag);
  }
```

- [ ] **Step 4: Add workflow queue and `runWorkflowTask` method**

Add to `AgentService` class fields:

```dart
  /// Pending workflow tasks queued when agent is busy.
  final List<_PendingWorkflow> _pendingWorkflows = [];

  /// Number of workflows waiting to execute.
  int get pendingWorkflowCount => _pendingWorkflows.length;
```

Add a private class (at the bottom of the file, alongside `_UnknownTool`):

```dart
class _PendingWorkflow {
  final ResolvedBinding binding;
  final Note note;
  _PendingWorkflow(this.binding, this.note);
}
```

Add the main method:

```dart
  /// Execute a tag-triggered workflow as a single AgentTask.
  ///
  /// The binding's prompt template is substituted with the note's ID and
  /// matched tag. The bound skill is pre-loaded into pinned context.
  /// If the agent is already running, the workflow is queued.
  Future<void> runWorkflowTask(ResolvedBinding binding, Note note) async {
    if (_isRunning) {
      _pendingWorkflows.add(_PendingWorkflow(binding, note));
      notifyListeners();
      return;
    }

    _isRunning = true;
    _tasks.clear();
    _finalAnswer = null;
    _finalMetadata = null;
    notifyListeners();

    try {
      // Substitute template variables
      final prompt = substitutePromptTemplate(
        binding.prompt,
        noteId: note.id,
        matchedTag: binding.matchedTag,
      );

      // Create root context
      _currentObjective = prompt;
      await _contextManager.createRootContext(
        objective: prompt,
        allowedTools: getAllToolNames(),
      );

      // Pre-load the bound skill into pinned context
      final skillNote = await _databaseService.getNoteById(binding.skillNoteId);
      if (skillNote != null) {
        _contextManager.addLoadedSkill(skillNote.id, skillNote.content);
        // Also resolve tool URIs from the skill content
        final toolUris = getIt<SkillService>().extractToolUris(skillNote.content);
        for (final uri in toolUris) {
          await _resolveSkillToolUri(uri);
        }
      }

      // Create a single task
      final task = AgentTask(
        id: const Uuid().v4(),
        description: prompt,
        maxTurns: 20,  // Reasonable default for a workflow; pauses on hit
        isFinalDeliverable: true,
      );
      _tasks.add(task);
      notifyListeners();

      // Run the execute loop (same code path as plan-based execution)
      await _executeLoop();
    } finally {
      _isRunning = false;
      notifyListeners();
      // Process queued workflows
      await _processWorkflowQueue();
    }
  }

  /// Process the next queued workflow, if any.
  Future<void> _processWorkflowQueue() async {
    if (_pendingWorkflows.isEmpty) return;
    final next = _pendingWorkflows.removeAt(0);
    await runWorkflowTask(next.binding, next.note);
  }
```

- [ ] **Step 5: Add import for ResolvedBinding**

In `lib/services/agent_service.dart`, add:

```dart
import 'tag_workflow_service.dart';
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/workflow_task_test.dart -v`
Expected: All tests pass.

- [ ] **Step 7: Run full test suite**

Run: `flutter test`
Expected: No regressions. Existing agent tests unaffected.

- [ ] **Step 8: Commit**

```bash
git add lib/services/agent_service.dart test/workflow_task_test.dart test/workflow_task_test.mocks.dart
git commit -m "feat: workflow task execution via AgentService (Phase C0b)

runWorkflowTask() executes a tag-triggered workflow as a single
AgentTask, reusing the existing ReAct loop, context management,
and tool infrastructure. Skill pre-loaded into pinned context.
Queues when agent is busy. Background-safe via ChangeNotifier."
```

---

### Task 1: Write the Namespace-Aware Wiki Schema Artifact (C1)

**Files:**
- Create: `docs/wiki-schema.md`

- [ ] **Step 1: Create the schema document**

```markdown
# Note Synapse Wiki Schema

## Purpose

This document defines the canonical schema for wiki workspaces in Note Synapse. All wiki skills must follow these conventions. Two independent agents following this schema should produce structurally similar notes.

## Core Principle

Wiki pages are regular notes. There is no separate "wiki page" type. Wiki workspaces are distinguished from ordinary note collections by namespaced tag conventions, note structure, and workflow rules.

## Namespace Model

Each wiki workspace has a **namespace** — a short identifier like `ml`, `harry-potter`, or `cooking`. All tags in a workspace carry the namespace as a suffix. Multiple independent workspaces coexist without collision.

There is no flat `wiki-source` or `wiki-compiled` tag. Source and compiled identity always includes the namespace.

## Terminology

| Term | Definition |
|------|-----------|
| **source note** | A note treated as raw evidence. Tagged `wiki-source-<ns>`. Content and title are immutable once tagged — enforced by prefix-aware guard in `NoteModificationService`. Tags, links, and attachments can still be modified. |
| **compiled note** | A regular note maintained by agent workflows. Tagged `wiki-compiled-<ns>` plus a type tag. Content is LLM-generated. |
| **wiki workspace** | A namespace — a set of regular notes sharing the same namespace suffix in their tags, plus one index and one log per namespace. |
| **schema skill** | The skill note that defines the workflow contract. References this schema. |

## Tag Conventions

All wiki-related tags use the `wiki-<role>-<namespace>` pattern.

| Tag Pattern | Applied To | Meaning |
|-------------|-----------|---------|
| `wiki-source-<ns>` | Source notes | Raw evidence in namespace `<ns>`. Content immutable via agent tools. |
| `wiki-compiled-<ns>` | All compiled notes | LLM-generated content in namespace `<ns>`. |
| `wiki-index-<ns>` | Index note (one per namespace) | Master catalog for namespace `<ns>`. |
| `wiki-log-<ns>` | Log note (one per namespace) | Append-only operation chronicle for namespace `<ns>`. |
| `wiki-entity-<ns>` | Entity compiled notes | Person, organization, algorithm, concept. |
| `wiki-topic-<ns>` | Topic compiled notes | Subject area grouping multiple entities. |
| `wiki-synthesis-<ns>` | Query-derived compiled notes | Filed from chat via Add to Note. |

A compiled note always has `wiki-compiled-<ns>` AND one type tag (e.g., `wiki-compiled-ml` + `wiki-entity-ml`).

**Examples for namespace `ml`:**
- Source: `wiki-source-ml`
- Entity: `wiki-compiled-ml` + `wiki-entity-ml`
- Index: `wiki-index-ml` + `wiki-compiled-ml`
- Log: `wiki-log-ml` + `wiki-compiled-ml`

## Trigger Mechanism

Tagging a note `wiki-source-<ns>` triggers the wiki ingest workflow via the tag-to-workflow binding system (`TagWorkflowService.resolveBindings`). The resolved binding provides the skill note ID, a prompt template, and the matched tag. The workflow executes as a single `AgentTask` via `AgentService.runWorkflowTask()`, which pre-loads the bound skill and runs the existing multi-turn ReAct loop.

The bootstrap skill registers the `wiki-source-` prefix → ingest skill binding (with prompt template and `contentImmutable: true`) when creating a new workspace.

## Required Compiled Note Structure

Every compiled note must follow this layout:

```
> [!SUMMARY] One-line summary for read_note mode='summary'

## Overview
[2-3 paragraph overview of the entity/topic]

## Claims
[Each claim on its own line with source attribution]
- Claim text. [Source: Note Title](notesynapse://note/{source-note-id})
- Unverified claim. [unverified]

## Sources
- [Source Title](notesynapse://note/{id}) — what it contributed

## See Also
- [Related Note](notesynapse://note/{id}) — relationship description
```

### Index Note Structure

```
> [!SUMMARY] Wiki Index for [Domain] (namespace: <ns>)

## Entities
- [Entity Name](notesynapse://note/{id}) — one-line summary

## Topics
- [Topic Name](notesynapse://note/{id}) — one-line summary

## Syntheses
- [Synthesis Title](notesynapse://note/{id}) — one-line summary

## Sources
- [Source Title](notesynapse://note/{id}) — date added
```

### Log Note Structure

Append-only. Each entry is a markdown heading with timestamp.

```
## [YYYY-MM-DD HH:mm] Operation Type | Context

**Action:** What was done
**Notes affected:** list of note titles/IDs
**Summary:** One-line outcome
```

## Provenance Rules

1. Every claim in `## Claims` must link to a source note or source-linked compiled note.
2. Claims without attribution must be marked `[unverified]`.
3. When a source is removed or superseded, claims derived from it must be re-evaluated in the next lint pass.

## Contradiction Handling

When two sources make conflicting claims:
1. Both versions preserved with source attribution.
2. `[contradiction]` marker added.
3. Contradictions are never collapsed silently.
4. Lint reports them for human review.

## Supersession

When a newer source supersedes an older one:
1. Old claim marked `[superseded by: Source Title]`.
2. New claim added with its source.
3. Supersession recorded in `## Sources`.

## Source Immutability

- Notes with any `wiki-source-*` tag cannot have content or title modified by agent tools.
- Enforced by the generic tag-workflow immutability mechanism: the `wiki-source-` prefix binding has `contentImmutable: true`, and `NoteModificationService` checks `TagWorkflowService.hasImmutableBinding()`.
- `ContentIngestionService` redirects output to a new note for immutable-bound sources.
- Manual editing by the user is still possible.
- Multiple tags matching the same prefix pattern on one note is an error (ambiguous binding).

## Cross-Namespace Rules

A compiled note in namespace A can reference a source from namespace B in its `## Sources` section. But the compiled note carries only its own namespace tags. Cross-namespace references are explicit, not implicit.
```

- [ ] **Step 2: Verify no flat tags appear in the document**

Search the document for bare `wiki-source`, `wiki-compiled`, `wiki-index`, `wiki-log` without namespace suffix. None should appear except in the "there is no flat tag" rule.

- [ ] **Step 3: Commit**

```bash
git add docs/wiki-schema.md
git commit -m "docs: add namespace-aware wiki schema artifact (Phase C1)

All tags carry namespace suffix (wiki-source-<ns>, wiki-compiled-<ns>).
No flat wiki-source tag. Multiple independent workspaces supported."
```

---

### Task 2: Write the Workflow UX Spec (C2)

**Files:**
- Create: `docs/wiki-workflow-ux.md`

- [ ] **Step 1: Create the workflow UX spec**

```markdown
# Note Synapse Wiki Workflow UX

## Purpose

This document defines the four user-visible wiki operations using namespaced tags and tag-to-workflow bindings. Ingest is triggered by tagging, not by manually invoking a skill.

## Prerequisites

- Tag-to-workflow bindings: `SkillService.resolveTagWorkflow` (Phase C0)
- Wiki schema: `docs/wiki-schema.md` (Phase C1)
- Source immutability: prefix-aware guard (Phase B5)
- `create_notes` link field (Phase B1)

---

## 1. Bootstrap

### Goal
Create a namespaced wiki workspace.

### Entry Point
User runs the agent with the "Wiki Bootstrap" skill, providing a domain name.

Example: "Bootstrap a wiki workspace for machine learning"

### What the Agent Does
1. Derives namespace from domain (e.g., "Machine Learning" → `ml`)
2. Checks for existing `wiki-index-ml` to avoid duplicates
3. Creates **Index note**: "Wiki Index: Machine Learning"
   - Tags: `wiki-index-ml`, `wiki-compiled-ml`
4. Creates **Log note**: "Wiki Log: Machine Learning"
   - Tags: `wiki-log-ml`, `wiki-compiled-ml`
5. Registers `wiki-source-ml` prefix → Wiki Ingest skill binding
6. Appends bootstrap entry to log

### Outputs
- 1 index note (tagged `wiki-index-ml`)
- 1 log note (tagged `wiki-log-ml`)
- Tag-to-workflow binding registered

---

## 2. Ingest

### Goal
Process one source note into compiled notes within a namespace.

### Entry Point
User tags a note `wiki-source-<ns>`. The tag-to-workflow binding automatically resolves to the Wiki Ingest skill with namespace context. The workflow executes as a single `AgentTask` via `AgentService.runWorkflowTask()` — multi-turn, background-safe, with progress tracking.

Example: User tags a note `wiki-source-ml` → `TagWorkflowService.resolveBindings()` matches the `wiki-source-` prefix binding → `AgentService.runWorkflowTask()` creates and runs a task with the binding's prompt (substituting `{note_id}` and `{matched_tag}`) and the pre-loaded ingest skill.

**No manual skill invocation needed.** The tag IS the trigger. The agent runs in the background — user can switch to other screens.

### What the Agent Does
1. Receives the matched tag (`wiki-source-ml`) and derives namespace (`ml`)
2. Reads the source note using progressive discovery
3. Identifies entities, topics, and claims
4. For each entity/topic:
   - `search_notes` with tags `['wiki-compiled-ml']` to find existing notes
   - Update or create with correct namespaced tags
5. Updates namespace-scoped index (`wiki-index-ml`)
6. Appends to namespace-scoped log (`wiki-log-ml`)
7. Creates relationships from source to compiled notes

### Source Note Handling
- Content NEVER modified (enforced by prefix-aware guard)
- Tags and links CAN be modified (e.g., adding `ingested` tag)

### Disambiguation
If a note has both `wiki-source-ml` and `wiki-source-ai`, ingest fails with: "Ambiguous: note belongs to multiple wiki namespaces. Remove all but one wiki-source-* tag."

---

## 3. Query and Filing

### Goal
Answer questions from compiled notes, optionally scoped by namespace.

### Entry Point
User asks a question in chat mode with wiki skills enabled.

### Namespace Scoping
- "How does attention work?" → searches all `wiki-compiled-*` notes
- "Ask the ML wiki: how does attention work?" → searches only `wiki-compiled-ml`

### Filing Path
Same three existing surfaces:

1. **Single response**: Add to Note → new note, user tags `wiki-compiled-<ns>`, `wiki-synthesis-<ns>`
2. **Multi-turn**: Conversation tree → consolidate → user tags appropriately
3. **Append**: Add to Note → existing compiled note

---

## 4. Lint

### Goal
Audit wiki health within a specific namespace.

### Entry Point
User runs agent with "Wiki Lint" skill, specifying namespace.

Example: "Lint the ML wiki"

### Namespace Scoping
All checks scoped to the namespace:
- Index: `wiki-index-ml`
- Compiled notes: `wiki-compiled-ml`
- Orphan detection: notes with `wiki-compiled-ml` but no relationships

Lint does NOT report notes from other namespaces.

---

## Summary: Operation → Trigger Mapping

| Operation | Trigger | Namespace Source |
|-----------|---------|-----------------|
| Bootstrap | Manual (agent + skill) | User provides domain name |
| Ingest | Tag-to-workflow binding (`wiki-source-<ns>`) | Derived from tag suffix |
| Query | Chat (+ optional namespace in question) | Explicit or all namespaces |
| Lint | Manual (agent + skill + namespace) | User specifies namespace |
```

- [ ] **Step 2: Verify ingest entry point is tag-triggered, not manual**

The workflow spec must state that ingest is triggered by tagging, not by "run the ingest skill." Verify the ingest section says "the tag IS the trigger."

- [ ] **Step 3: Commit**

```bash
git add docs/wiki-workflow-ux.md
git commit -m "docs: add namespace + tag-triggered workflow UX spec (Phase C2)

Ingest triggered by wiki-source-<ns> tag binding, not manual skill
invocation. All operations namespace-scoped."
```

---

### Task 3: Cross-validate schema and workflow spec

- [ ] **Step 1: Check internal consistency**

- Tag patterns in workflow spec match schema tag conventions
- Namespace model consistent between documents
- Trigger mechanism in workflow spec matches schema trigger section
- Lint scope in workflow matches schema rules

- [ ] **Step 2: Fix any inconsistencies inline and commit**

```bash
git add docs/wiki-schema.md docs/wiki-workflow-ux.md
git commit -m "docs: cross-validate wiki schema and workflow spec"
```
