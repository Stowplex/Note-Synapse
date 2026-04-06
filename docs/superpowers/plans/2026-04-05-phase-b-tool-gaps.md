# Phase B: Critical Tool Gaps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the narrow tool and enforcement gaps that block reliable agent workflows: expose `link` in `create_notes` schema, add relationship deletion support, and add generic tag-workflow immutability enforcement.

**Architecture:** Three changes to `note_tools.dart` (schema) and `note_modification_service.dart` (enforcement logic). PDF text extraction and image reading (Tasks B2/B3 from the parent plan) are split into a separate plan because they require package evaluation — this plan covers B1, B4, and B5 which are pure logic changes. **Task 3 (B5) depends on Phase C Task 0a** (`TagWorkflowService` infrastructure) and must be implemented after it.

**Tech Stack:** Flutter, Dart, mockito

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase B (Tasks B1, B4, B5)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Modify | `lib/services/tools/note_tools.dart:935-1007` | B1: Add `link` to CreateNotesTool.inputSchema |
| Modify | `lib/services/tools/note_tools.dart:841-849` | B4: Extend ModifyNoteTool link schema with `removed` |
| Modify | `lib/services/note_modification_service.dart:20-153` | B4: Handle `link.removed` in applyModifications; B5: immutability guard |
| Modify | `lib/services/content_ingestion_service.dart:166-172` | B5: Redirect output for immutable-bound notes |
| Create | `test/create_notes_link_test.dart` | B1 tests |
| Create | `test/relationship_deletion_test.dart` | B4 tests |
| Create | `test/immutability_enforcement_test.dart` | B5 tests |

---

### Task 1: Expose `link` Field in `create_notes` Schema (B1)

**Files:**
- Modify: `lib/services/tools/note_tools.dart:935-1007` — `CreateNotesTool.inputSchema`
- Create: `test/create_notes_link_test.dart`

The `createNote()` implementation in `note_modification_service.dart:246` already handles `link` data. The gap is that `CreateNotesTool.inputSchema` doesn't advertise the field, so LLMs don't know it exists.

- [ ] **Step 1: Write the failing test**

```dart
// test/create_notes_link_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'create_notes_link_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late NoteModificationService modService;
  late CreateNotesTool tool;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    modService = NoteModificationService(mockDb);
    getIt.registerSingleton<NoteModificationService>(modService);
    tool = CreateNotesTool();
  });

  group('CreateNotesTool inputSchema', () {
    test('includes link property in items schema', () {
      final items = (tool.inputSchema['properties'] as Map)['notes']['items'] as Map;
      final props = items['properties'] as Map;
      expect(props.containsKey('link'), isTrue,
          reason: 'inputSchema must advertise the link field so LLMs know it exists');
      final linkSchema = props['link'] as Map;
      expect(linkSchema['type'], 'array');
      final itemSchema = linkSchema['items'] as Map;
      expect((itemSchema['properties'] as Map).containsKey('relation'), isTrue);
      expect((itemSchema['properties'] as Map).containsKey('target'), isTrue);
    });
  });

  group('create_notes with link field', () {
    test('creates note AND relationship when link provided', () async {
      when(mockDb.insertNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async {});
      when(mockDb.verifyAttachmentPath(any)).thenAnswer((_) async => true);

      final result = await tool.execute({
        'notes': [
          {
            'title': 'Compiled: Attention',
            'content': '## Summary\nAttention mechanisms...',
            'tags': ['wiki-compiled-ml'],
            'link': [
              {'relation': 'derived_from', 'target': 'source-note-123'},
            ],
          },
        ],
      });

      expect((result as Map)['status'], 'success');
      expect(result['created_count'], 1);

      // Verify relationship was created
      final captured = verify(mockDb.insertRelationship(captureAny)).captured;
      expect(captured.length, 1);
      final rel = captured[0] as Relationship;
      expect(rel.toNoteId, 'source-note-123');
      expect(rel.type, 'derived_from');
    });

    test('creates note without relationship when link absent', () async {
      when(mockDb.insertNote(any)).thenAnswer((_) async {});
      when(mockDb.verifyAttachmentPath(any)).thenAnswer((_) async => true);

      final result = await tool.execute({
        'notes': [
          {
            'title': 'Plain note',
            'content': 'No links.',
          },
        ],
      });

      expect((result as Map)['status'], 'success');
      verifyNever(mockDb.insertRelationship(any));
    });
  });
}
```

- [ ] **Step 2: Generate mocks and run to verify test fails**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/create_notes_link_test.dart -v`
Expected: Schema test FAILS because `link` is not in `inputSchema`. The functional tests should PASS because `createNote()` already handles `link`.

- [ ] **Step 3: Add `link` to CreateNotesTool.inputSchema**

In `lib/services/tools/note_tools.dart`, inside `CreateNotesTool.inputSchema`, add `link` to the items properties, after the `status` property (around line 1000):

```dart
            'status': {
              'type': 'string',
              'enum': ['todo', 'in_progress', 'complete', 'abandoned'],
              'description': 'For tasks: current status.',
              'default': 'todo',
            },
            'link': {
              'type': 'array',
              'description':
                  'Optional relationships to other notes. Created at note-creation time.',
              'items': {
                'type': 'object',
                'properties': {
                  'relation': {
                    'type': 'string',
                    'description':
                        'Relationship type (e.g., derived_from, related, references).',
                  },
                  'target': {
                    'type': 'string',
                    'description': 'The ID of the target note.',
                  },
                },
                'required': ['relation', 'target'],
              },
            },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/create_notes_link_test.dart -v`
Expected: All tests pass.

- [ ] **Step 5: Run existing tests to verify no regression**

Run: `flutter test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/services/tools/note_tools.dart test/create_notes_link_test.dart test/create_notes_link_test.mocks.dart
git commit -m "feat: expose link field in create_notes schema (Phase B1)

The createNote() implementation already handled link data, but the
inputSchema didn't advertise it. LLMs can now create notes with
relationships in a single tool call."
```

---

### Task 2: Relationship Deletion via `modify_note` (B4)

**Files:**
- Modify: `lib/services/tools/note_tools.dart:841-849` — ModifyNoteTool link schema
- Modify: `lib/services/note_modification_service.dart:129-150` — handle `link.removed`
- Create: `test/relationship_deletion_test.dart`

Currently `modify_note` link field only supports creation. Add `removed` support matching the pattern used by `tags` and `attachments`.

- [ ] **Step 1: Write the failing test**

```dart
// test/relationship_deletion_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'relationship_deletion_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late NoteModificationService service;

  final testNote = Note(
    id: 'note-1',
    title: 'Test Note',
    content: 'Content',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['wiki-compiled-ml'],
    attachmentPaths: [],
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteModificationService(mockDb);
  });

  group('link.removed in modify_note', () {
    test('deletes relationship when removed contains target noteId', () async {
      when(mockDb.getNoteById('note-1')).thenAnswer((_) async => testNote);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.deleteRelationshipBetween('note-1', 'note-b'))
          .thenAnswer((_) async {});

      await service.applyModifications('note-1', {
        'link': {
          'removed': ['note-b'],
        },
      });

      verify(mockDb.deleteRelationshipBetween('note-1', 'note-b')).called(1);
    });

    test('creates AND deletes relationships in same call', () async {
      when(mockDb.getNoteById('note-1')).thenAnswer((_) async => testNote);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async {});
      when(mockDb.deleteRelationshipBetween('note-1', 'old-target'))
          .thenAnswer((_) async {});

      await service.applyModifications('note-1', {
        'link': {
          'added': [
            {'relation': 'related', 'target': 'new-target'},
          ],
          'removed': ['old-target'],
        },
      });

      verify(mockDb.insertRelationship(any)).called(1);
      verify(mockDb.deleteRelationshipBetween('note-1', 'old-target')).called(1);
    });

    test('existing link creation behavior unchanged (array of objects)', () async {
      when(mockDb.getNoteById('note-1')).thenAnswer((_) async => testNote);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async {});

      // Old format: link is a list of objects (backwards compatible)
      await service.applyModifications('note-1', {
        'link': [
          {'relation': 'related', 'target': 'note-c'},
        ],
      });

      verify(mockDb.insertRelationship(any)).called(1);
    });
  });
}
```

- [ ] **Step 2: Generate mocks and run to verify failing**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/relationship_deletion_test.dart -v`
Expected: Tests fail because `link.removed` is not handled and the new map format isn't parsed.

- [ ] **Step 3: Check if `deleteRelationshipBetween` exists in DatabaseService**

Run: Read `lib/services/database_service.dart` and search for relationship deletion methods. If `deleteRelationshipBetween(fromId, toId)` doesn't exist, it needs to be added. The implementer should check the actual DB method name and adjust the test accordingly.

- [ ] **Step 4: Update `applyModifications` to handle the new link format**

In `lib/services/note_modification_service.dart`, replace the link handling block (lines 129-150):

```dart
    // 6. Links (Relationship) Modification
    if (modifications.containsKey('link')) {
      final linkData = modifications['link'];

      // Support both formats:
      // Old: link: [{relation: ..., target: ...}]  (list of objects — creation only)
      // New: link: {added: [{relation: ..., target: ...}], removed: ['noteId']}
      List<dynamic> addedLinks = [];
      List<String> removedTargets = [];

      if (linkData is List) {
        // Old format: treat entire list as additions
        addedLinks = linkData;
      } else if (linkData is Map<String, dynamic>) {
        addedLinks = (linkData['added'] as List?) ?? [];
        removedTargets =
            (linkData['removed'] as List?)?.cast<String>() ?? [];
      }

      // Create new relationships
      for (final link in addedLinks) {
        if (link is Map<String, dynamic>) {
          final relationType = link['relation'] as String? ?? 'related';
          final targetId = link['target'] as String?;
          if (targetId != null) {
            await _db.insertRelationship(
              Relationship(
                id: _uuid.v4(),
                fromNoteId: updatedNote.id,
                toNoteId: targetId,
                type: relationType,
                createdAt: DateTime.now(),
              ),
            );
          }
        }
      }

      // Delete relationships
      for (final targetId in removedTargets) {
        await _db.deleteRelationshipBetween(updatedNote.id, targetId);
      }
    }
```

- [ ] **Step 5: Add `deleteRelationshipBetween` to DatabaseService if missing**

If the method doesn't exist, add it:

```dart
  Future<void> deleteRelationshipBetween(String fromNoteId, String toNoteId) async {
    final db = await database;
    await db.delete(
      'relationships',
      where: '(fromNoteId = ? AND toNoteId = ?) OR (fromNoteId = ? AND toNoteId = ?)',
      whereArgs: [fromNoteId, toNoteId, toNoteId, fromNoteId],
    );
  }
```

- [ ] **Step 6: Update ModifyNoteTool inputSchema to document the new format**

In `lib/services/tools/note_tools.dart`, update the `link` property in `ModifyNoteTool.inputSchema` (around line 841):

```dart
          'link': {
            'type': 'object',
            'description': 'Add or remove relationships to other notes.',
            'properties': {
              'added': {
                'type': 'array',
                'description': 'Relationships to create.',
                'items': {
                  'type': 'object',
                  'properties': {
                    'relation': {'type': 'string', 'description': 'Relationship type.'},
                    'target': {'type': 'string', 'description': 'Target note ID.'},
                  },
                  'required': ['relation', 'target'],
                },
              },
              'removed': {
                'type': 'array',
                'description': 'Target note IDs whose relationships should be deleted.',
                'items': {'type': 'string'},
              },
            },
          },
```

**Important:** The old format (bare array of `{relation, target}`) must still work for backwards compatibility. The implementation in Step 4 handles both formats.

- [ ] **Step 7: Run tests**

Run: `flutter test test/relationship_deletion_test.dart -v`
Expected: All tests pass.

- [ ] **Step 8: Run full test suite**

Run: `flutter test`
Expected: No regressions. The old `link` format (bare array) is still handled.

- [ ] **Step 9: Commit**

```bash
git add lib/services/tools/note_tools.dart lib/services/note_modification_service.dart lib/services/database_service.dart test/relationship_deletion_test.dart test/relationship_deletion_test.mocks.dart
git commit -m "feat: add relationship deletion to modify_note link field (Phase B4)

Support link: {added: [...], removed: [...]} format alongside the
existing bare-array format for backwards compatibility. Enables
wiki lint to clean up stale cross-references."
```

---

### Task 3: Tag-Workflow Immutability Enforcement (B5)

**Files:**
- Modify: `lib/services/note_modification_service.dart:20-32` — add generic immutability guard via `TagWorkflowService`
- Modify: `lib/services/content_ingestion_service.dart:166-172` — redirect output for immutable-bound notes
- Create: `test/immutability_enforcement_test.dart`

**Depends on:** Phase C Task 0a (`TagWorkflowService` and `tag_workflow_bindings` table). Must be implemented AFTER C0a.

Notes whose tags have a workflow binding with `contentImmutable: true` must not have their content or title modified by agent tools. This is a **generic platform mechanism** — no wiki-specific code. The platform checks `TagWorkflowService.hasImmutableBinding(tags)`. Wiki is just one use case that registers immutable bindings at runtime.

- [ ] **Step 1: Write the immutability enforcement tests**

```dart
// test/immutability_enforcement_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'immutability_enforcement_test.mocks.dart';

@GenerateMocks([DatabaseService, TagWorkflowService])
void main() {
  late MockDatabaseService mockDb;
  late MockTagWorkflowService mockTagWorkflow;
  late NoteModificationService service;

  final immutableNote = Note(
    id: 'source-1',
    title: 'Original Title',
    content: 'Original content.',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['wiki-source-ml', 'machine-learning'],
    attachmentPaths: ['doc.pdf'],
  );

  final anotherImmutableNote = Note(
    id: 'source-2',
    title: 'Recipe Source',
    content: 'Grandma recipe.',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['recipe-source-italian'],
    attachmentPaths: [],
  );

  final regularNote = Note(
    id: 'regular-1',
    title: 'Regular Note',
    content: 'Can be modified.',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['wiki-compiled-ml'],
    attachmentPaths: [],
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockTagWorkflow = MockTagWorkflowService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<TagWorkflowService>(mockTagWorkflow);
    service = NoteModificationService(mockDb);
  });

  group('generic tag-workflow immutability enforcement', () {
    test('rejects content modification when tag has immutable binding', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => immutableNote);
      when(mockTagWorkflow.hasImmutableBinding(immutableNote.tags))
          .thenAnswer((_) async => true);

      expect(
        () => service.applyModifications('source-1', {
          'content': {'action': 'append', 'text': 'Appended'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('immutable'))),
      );
    });

    test('rejects title modification when tag has immutable binding', () async {
      when(mockDb.getNoteById('source-2')).thenAnswer((_) async => anotherImmutableNote);
      when(mockTagWorkflow.hasImmutableBinding(anotherImmutableNote.tags))
          .thenAnswer((_) async => true);

      expect(
        () => service.applyModifications('source-2', {
          'title': {'new_title': 'Changed'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('immutable'))),
      );
    });

    test('allows tag modification on immutable-bound note', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => immutableNote);
      when(mockTagWorkflow.hasImmutableBinding(immutableNote.tags))
          .thenAnswer((_) async => true);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      final result = await service.applyModifications('source-1', {
        'tags': {'added': ['reviewed']},
      });

      expect(result.tags, contains('reviewed'));
    });

    test('allows link creation on immutable-bound note', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => immutableNote);
      when(mockTagWorkflow.hasImmutableBinding(immutableNote.tags))
          .thenAnswer((_) async => true);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async {});

      await service.applyModifications('source-1', {
        'link': [{'relation': 'related', 'target': 'other'}],
      });

      verify(mockDb.insertRelationship(any)).called(1);
    });

    test('does not check immutability when no bindings exist', () async {
      when(mockDb.getNoteById('regular-1')).thenAnswer((_) async => regularNote);
      when(mockTagWorkflow.hasImmutableBinding(regularNote.tags))
          .thenAnswer((_) async => false);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      final result = await service.applyModifications('regular-1', {
        'content': {'action': 'append', 'text': 'New text'},
      });

      expect(result.content, contains('New text'));
    });

    test('works for non-wiki immutable bindings (generic)', () async {
      // recipe-source-italian also has contentImmutable: true — no wiki code involved
      when(mockDb.getNoteById('source-2')).thenAnswer((_) async => anotherImmutableNote);
      when(mockTagWorkflow.hasImmutableBinding(anotherImmutableNote.tags))
          .thenAnswer((_) async => true);

      expect(
        () => service.applyModifications('source-2', {
          'content': {'action': 'append', 'text': 'text'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('immutable'))),
      );
    });
  });
}
```

- [ ] **Step 2: Generate mocks and run to verify failing**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/immutability_enforcement_test.dart -v`
Expected: Tests fail — no immutability guard exists yet.

- [ ] **Step 3: Add the generic immutability guard to `applyModifications`**

In `lib/services/note_modification_service.dart`, add import:

```dart
import 'tag_workflow_service.dart';
```

Then in `applyModifications`, after `if (note == null)` check:

```dart
    // Tag-workflow immutability guard (generic)
    // If any of this note's tags have a workflow binding with contentImmutable: true,
    // reject content and title modifications.
    final tagWorkflow = getIt<TagWorkflowService>();
    if (await tagWorkflow.hasImmutableBinding(note.tags)) {
      final hasContentMod = modifications.containsKey('content') &&
          (modifications['content'] as Map<String, dynamic>)['action'] != 'no-op';
      final hasTitleMod = modifications.containsKey('title');

      if (hasContentMod || hasTitleMod) {
        throw Exception(
          'Cannot modify content or title: this note has a tag with an immutable '
          'workflow binding. Tags, links, and attachments can still be modified.',
        );
      }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/immutability_enforcement_test.dart -v`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `flutter test`
Expected: No regressions.

- [ ] **Step 6: Commit**

```bash
git add lib/services/note_modification_service.dart test/immutability_enforcement_test.dart test/immutability_enforcement_test.mocks.dart
git commit -m "feat: generic tag-workflow immutability enforcement (Phase B5)

Notes whose tags have a workflow binding with contentImmutable: true
reject content/title modifications. Fully generic — no wiki-specific
code. Wiki is just one consumer that registers immutable bindings."
```

- [ ] **Step 7: Add ContentIngestionService redirect for immutable-bound notes**

In `lib/services/content_ingestion_service.dart`, add import:

```dart
import 'tag_workflow_service.dart';
```

Then at line ~166, replace the write-back block:

```dart
      if (json is Map<String, dynamic>) {
        json.remove('attachments');

        final modService = getIt<NoteModificationService>();
        final tagWorkflow = getIt<TagWorkflowService>();

        // If any of this note's tags have an immutable workflow binding,
        // redirect output to a new note instead of mutating the source.
        // The skill (not the platform) determines what tags the new note gets.
        if (await tagWorkflow.hasImmutableBinding(note.tags)) {
          final newNoteData = <String, dynamic>{
            'title': 'Extracted: ${note.title}',
            'content': json['content']?['text'] ?? '',
            'link': [
              {'relation': 'derived_from', 'target': note.id},
            ],
          };
          final newNote = await modService.createNote(newNoteData);
          await appProvider.addNote(newNote);
        } else {
          final updatedNote = await modService.applyModifications(note.id, json);
          await appProvider.updateNote(updatedNote);
        }
      }
```

**Note:** The new note does NOT get wiki-specific tags like `wiki-compiled-<ns>`. That's the skill's responsibility — the platform just redirects to a new note. The skill's extraction prompt (from `tag_ai_configs`) can include instructions for the AI to set appropriate tags.

- [ ] **Step 8: Run full test suite and commit**

Run: `flutter test && flutter analyze`

```bash
git add lib/services/content_ingestion_service.dart
git commit -m "feat: redirect content ingestion for immutable-bound notes

When a note's tags have an immutable workflow binding, extracted
content goes to a new note instead of mutating the source. Tags
on the new note are determined by the skill, not hardcoded."
```

---

### Task 4: Final validation

- [ ] **Step 1: Run flutter analyze**

Run: `flutter analyze`
Expected: No errors in modified files.

- [ ] **Step 2: Run full test suite**

Run: `flutter test`
Expected: All tests pass including the 3 new test files from this phase.
