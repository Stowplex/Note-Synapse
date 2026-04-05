# Phase B: Critical Tool Gaps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the narrow tool and enforcement gaps that block reliable wiki workflows: expose `link` in `create_notes` schema, add source immutability enforcement, and add relationship deletion support.

**Architecture:** Three changes to `note_tools.dart` (schema) and `note_modification_service.dart` (enforcement logic). PDF text extraction and image reading (Tasks B2/B3 from the parent plan) are split into a separate plan because they require package evaluation — this plan covers B1, B4, and B5 which are pure logic changes.

**Tech Stack:** Flutter, Dart, mockito

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase B (Tasks B1, B4, B5)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Modify | `lib/services/tools/note_tools.dart:935-1007` | B1: Add `link` to CreateNotesTool.inputSchema |
| Modify | `lib/services/tools/note_tools.dart:841-849` | B4: Extend ModifyNoteTool link schema with `removed` |
| Modify | `lib/services/note_modification_service.dart:20-153` | B4: Handle `link.removed` in applyModifications; B5: wiki-source guard |
| Modify | `lib/services/content_ingestion_service.dart:166-172` | B5: Redirect output for wiki-source notes |
| Create | `test/create_notes_link_test.dart` | B1 tests |
| Create | `test/relationship_deletion_test.dart` | B4 tests |
| Create | `test/source_immutability_test.dart` | B5 tests |

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
            'tags': ['wiki-compiled'],
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
    tags: ['wiki-compiled'],
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

### Task 3: Source Immutability Enforcement — Prefix-Aware (B5)

**Files:**
- Create: `lib/utils/wiki_tag_utils.dart` — prefix matching and namespace extraction
- Modify: `lib/services/note_modification_service.dart:20-32` — add prefix-aware wiki-source guard
- Modify: `lib/services/content_ingestion_service.dart:166-172` — redirect output for wiki-source-* notes
- Create: `test/wiki_tag_utils_test.dart`
- Create: `test/source_immutability_test.dart`

Notes with any `wiki-source-*` tag must not have their content or title modified by agent tools. There is no flat `wiki-source` tag — all source tags carry a namespace suffix (e.g., `wiki-source-ml`, `wiki-source-harry-potter`). Multiple `wiki-source-*` tags on one note is an error.

- [ ] **Step 1: Write the wiki_tag_utils tests**

```dart
// test/wiki_tag_utils_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/wiki_tag_utils.dart';

void main() {
  group('isWikiSourceTag', () {
    test('matches wiki-source-ml', () {
      expect(WikiTagUtils.isWikiSourceTag('wiki-source-ml'), isTrue);
    });

    test('matches wiki-source-harry-potter', () {
      expect(WikiTagUtils.isWikiSourceTag('wiki-source-harry-potter'), isTrue);
    });

    test('rejects flat wiki-source (no namespace)', () {
      expect(WikiTagUtils.isWikiSourceTag('wiki-source'), isFalse);
    });

    test('rejects wiki-compiled-ml', () {
      expect(WikiTagUtils.isWikiSourceTag('wiki-compiled-ml'), isFalse);
    });

    test('rejects unrelated tags', () {
      expect(WikiTagUtils.isWikiSourceTag('machine-learning'), isFalse);
    });
  });

  group('getWikiSourceNamespace', () {
    test('extracts namespace from single wiki-source tag', () {
      final result = WikiTagUtils.getWikiSourceNamespace(['wiki-source-ml', 'other-tag']);
      expect(result, 'ml');
    });

    test('extracts multi-word namespace', () {
      final result = WikiTagUtils.getWikiSourceNamespace(['wiki-source-harry-potter']);
      expect(result, 'harry-potter');
    });

    test('returns null when no wiki-source tag present', () {
      final result = WikiTagUtils.getWikiSourceNamespace(['regular', 'wiki-compiled-ml']);
      expect(result, isNull);
    });

    test('returns null for empty tags', () {
      expect(WikiTagUtils.getWikiSourceNamespace([]), isNull);
    });
  });

  group('getWikiSourceNamespaceStrict', () {
    test('returns namespace for single wiki-source tag', () {
      final result = WikiTagUtils.getWikiSourceNamespaceStrict(['wiki-source-ml']);
      expect(result, 'ml');
    });

    test('throws on multiple wiki-source tags (ambiguous)', () {
      expect(
        () => WikiTagUtils.getWikiSourceNamespaceStrict(
          ['wiki-source-ml', 'wiki-source-ai']),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('ambiguous'))),
      );
    });
  });

  group('hasWikiSourceTag', () {
    test('true when wiki-source-* present', () {
      expect(WikiTagUtils.hasWikiSourceTag(['wiki-source-ml', 'other']), isTrue);
    });

    test('false when no wiki-source-* present', () {
      expect(WikiTagUtils.hasWikiSourceTag(['wiki-compiled-ml', 'other']), isFalse);
    });
  });

  group('compiledTagForNamespace', () {
    test('generates wiki-compiled-ml', () {
      expect(WikiTagUtils.compiledTagForNamespace('ml'), 'wiki-compiled-ml');
    });
  });
}
```

- [ ] **Step 2: Implement wiki_tag_utils.dart**

```dart
// lib/utils/wiki_tag_utils.dart

/// Utilities for wiki namespaced tag operations.
/// Wiki tags follow the pattern: wiki-<role>-<namespace>
/// e.g., wiki-source-ml, wiki-compiled-harry-potter
class WikiTagUtils {
  static const String _sourcePrefix = 'wiki-source-';

  /// Returns true if the tag is a wiki-source tag with a namespace.
  /// Rejects bare 'wiki-source' (no namespace).
  static bool isWikiSourceTag(String tag) {
    return tag.startsWith(_sourcePrefix) && tag.length > _sourcePrefix.length;
  }

  /// Returns true if any tag in the list is a wiki-source-* tag.
  static bool hasWikiSourceTag(List<String> tags) {
    return tags.any(isWikiSourceTag);
  }

  /// Extracts the namespace from the first wiki-source-* tag found.
  /// Returns null if no wiki-source tag is present.
  static String? getWikiSourceNamespace(List<String> tags) {
    for (final tag in tags) {
      if (isWikiSourceTag(tag)) {
        return tag.substring(_sourcePrefix.length);
      }
    }
    return null;
  }

  /// Like getWikiSourceNamespace, but throws if multiple wiki-source-* tags
  /// are present (ambiguous namespace).
  static String? getWikiSourceNamespaceStrict(List<String> tags) {
    final sourceTags = tags.where(isWikiSourceTag).toList();
    if (sourceTags.isEmpty) return null;
    if (sourceTags.length > 1) {
      throw Exception(
        'Ambiguous wiki namespace: note has multiple wiki-source tags '
        '(${sourceTags.join(", ")}). Remove all but one.',
      );
    }
    return sourceTags.first.substring(_sourcePrefix.length);
  }

  /// Returns the wiki-compiled tag for a namespace.
  static String compiledTagForNamespace(String namespace) =>
      'wiki-compiled-$namespace';

  /// Returns the wiki-index tag for a namespace.
  static String indexTagForNamespace(String namespace) =>
      'wiki-index-$namespace';

  /// Returns the wiki-log tag for a namespace.
  static String logTagForNamespace(String namespace) =>
      'wiki-log-$namespace';
}
```

- [ ] **Step 3: Run wiki_tag_utils tests**

Run: `flutter test test/wiki_tag_utils_test.dart -v`
Expected: All tests pass.

- [ ] **Step 4: Commit wiki_tag_utils**

```bash
git add lib/utils/wiki_tag_utils.dart test/wiki_tag_utils_test.dart
git commit -m "feat: add WikiTagUtils for prefix-aware wiki tag operations

Supports wiki-source-<namespace> pattern with strict disambiguation
when multiple source tags are present."
```

- [ ] **Step 5: Write the source immutability test (prefix-aware)**

```dart
// test/source_immutability_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'source_immutability_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late NoteModificationService service;

  final sourceNoteMl = Note(
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

  final sourceNoteHp = Note(
    id: 'source-2',
    title: 'HP Source',
    content: 'Harry Potter content.',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['wiki-source-harry-potter'],
    attachmentPaths: [],
  );

  final ambiguousNote = Note(
    id: 'source-3',
    title: 'Ambiguous',
    content: 'Content.',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['wiki-source-ml', 'wiki-source-ai'],
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
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteModificationService(mockDb);
  });

  group('prefix-aware wiki-source immutability', () {
    test('rejects content modification on wiki-source-ml note', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => sourceNoteMl);

      expect(
        () => service.applyModifications('source-1', {
          'content': {'action': 'append', 'text': 'Appended'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('wiki-source'))),
      );
    });

    test('rejects title modification on wiki-source-harry-potter note', () async {
      when(mockDb.getNoteById('source-2')).thenAnswer((_) async => sourceNoteHp);

      expect(
        () => service.applyModifications('source-2', {
          'title': {'new_title': 'Changed'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('wiki-source'))),
      );
    });

    test('allows tag modification on wiki-source-ml note', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => sourceNoteMl);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      final result = await service.applyModifications('source-1', {
        'tags': {'added': ['reviewed']},
      });

      expect(result.tags, contains('reviewed'));
    });

    test('allows link creation on wiki-source-ml note', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => sourceNoteMl);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async {});

      await service.applyModifications('source-1', {
        'link': [{'relation': 'related', 'target': 'other'}],
      });

      verify(mockDb.insertRelationship(any)).called(1);
    });

    test('does not affect non-wiki-source notes', () async {
      when(mockDb.getNoteById('regular-1')).thenAnswer((_) async => regularNote);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      final result = await service.applyModifications('regular-1', {
        'content': {'action': 'append', 'text': 'New text'},
      });

      expect(result.content, contains('New text'));
    });

    test('rejects modification when multiple wiki-source tags (ambiguous)', () async {
      when(mockDb.getNoteById('source-3')).thenAnswer((_) async => ambiguousNote);

      expect(
        () => service.applyModifications('source-3', {
          'content': {'action': 'append', 'text': 'text'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('ambiguous'))),
      );
    });
  });
}
```

- [ ] **Step 6: Generate mocks and run to verify failing**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/source_immutability_test.dart -v`
Expected: Tests fail — no prefix-aware guard exists yet.

- [ ] **Step 7: Add the prefix-aware guard to `applyModifications`**

In `lib/services/note_modification_service.dart`, add import and guard after the note fetch (after line 32):

```dart
import '../utils/wiki_tag_utils.dart';
```

Then in `applyModifications`, after `if (note == null)` check:

```dart
    // Wiki-source immutability guard (prefix-aware)
    // Any tag matching wiki-source-* triggers protection
    if (WikiTagUtils.hasWikiSourceTag(note.tags)) {
      // Also check for ambiguous multiple wiki-source tags
      WikiTagUtils.getWikiSourceNamespaceStrict(note.tags);

      final hasContentMod = modifications.containsKey('content') &&
          (modifications['content'] as Map<String, dynamic>)['action'] != 'no-op';
      final hasTitleMod = modifications.containsKey('title');

      if (hasContentMod || hasTitleMod) {
        throw Exception(
          'Cannot modify content or title of a wiki-source note. '
          'Source notes are immutable to preserve provenance. '
          'Tags, links, and attachments can still be modified.',
        );
      }
    }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `flutter test test/source_immutability_test.dart -v`
Expected: All tests pass.

- [ ] **Step 9: Run full test suite**

Run: `flutter test`
Expected: No regressions.

- [ ] **Step 10: Commit**

```bash
git add lib/services/note_modification_service.dart test/source_immutability_test.dart test/source_immutability_test.mocks.dart
git commit -m "feat: prefix-aware wiki-source immutability enforcement (Phase B5)

Notes with any wiki-source-* tag reject content/title modifications.
Uses WikiTagUtils prefix matching — supports multiple namespaces.
Multiple wiki-source-* tags on one note produces an ambiguity error."
```

- [ ] **Step 11: Add ContentIngestionService redirect for wiki-source-* notes**

In `lib/services/content_ingestion_service.dart`, add import and modify the write-back logic:

```dart
import '../utils/wiki_tag_utils.dart';
```

Then at line ~166, replace the write-back block:

```dart
      if (json is Map<String, dynamic>) {
        json.remove('attachments');

        final service = getIt<NoteModificationService>();

        // If source is wiki-source-*, redirect output to a new compiled note
        final namespace = WikiTagUtils.getWikiSourceNamespace(note.tags);
        if (namespace != null) {
          final compiledData = <String, dynamic>{
            'title': 'Compiled: ${note.title}',
            'content': json['content']?['text'] ?? '',
            'tags': [WikiTagUtils.compiledTagForNamespace(namespace)],
            'link': [
              {'relation': 'derived_from', 'target': note.id},
            ],
          };
          final compiledNote = await service.createNote(compiledData);
          await appProvider.addNote(compiledNote);
        } else {
          final updatedNote = await service.applyModifications(note.id, json);
          await appProvider.updateNote(updatedNote);
        }
      }
```

- [ ] **Step 12: Run full test suite and commit**

Run: `flutter test && flutter analyze`

```bash
git add lib/services/content_ingestion_service.dart
git commit -m "feat: redirect content ingestion for wiki-source-* notes

Namespace-aware: wiki-source-ml creates wiki-compiled-ml note.
Source note content unchanged."
```

---

### Task 4: Final validation

- [ ] **Step 1: Run flutter analyze**

Run: `flutter analyze`
Expected: No errors in modified files.

- [ ] **Step 2: Run full test suite**

Run: `flutter test`
Expected: All tests pass including the 3 new test files from this phase.
