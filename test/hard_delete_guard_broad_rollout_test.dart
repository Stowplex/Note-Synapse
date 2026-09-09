// Tests for the M1.13 "clearAllData + broad hard-delete guard rollout"
// milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Phased
// delivery, M1.13 — "Extends `_hardDeleteGuardedTables` to every converted
// entity table... final, hard-depends on M1.7-M1.12 all landing first").
//
// This is the M1.5 `hard_delete_guard_test.dart` pattern (that file's own
// scope note explains why it only covers the original four User-App-family
// tables), applied to the ten additional tables M1.13 adds to
// `_hardDeleteGuardedTables`: `notes`, `subnotes`, `attachments`, `tags`,
// `filters`, `relationships`, `tag_workflow_bindings`, `conversations`,
// `conversation_messages`, `conversation_attachments`.
//
// What this file verifies, matching M1.13's own acceptance bar:
//  1. Fresh install: each of the ten tables already has its guard trigger
//     installed, and a real `db.delete(...)` against any of them throws —
//     one test per table, mirroring hard_delete_guard_test.dart exactly.
//  2. The guard is not overly broad: ordinary INSERT/UPDATE against every
//     one of the ten tables still works completely normally.
//  3. Migration round-trip (DATABASE_VERSION 55 -> 56): an existing,
//     already-on-v56 database (post-M1.12, no guard yet on these ten
//     tables) gains the guard triggers after migrating, and a real DELETE
//     against any of them then throws afterward — while data already in
//     the tables is untouched by the migration itself (pure-additive,
//     CREATE TRIGGER IF NOT EXISTS).
//  4. `clearAllData`'s guard-bypass mechanism: the function still fully
//     empties every table it always has (proving the drop-trigger step
//     actually works), and — the part a naive "just drop the triggers"
//     implementation could get wrong — the guard is fully reinstalled
//     afterward, so a real delete attempted right after `clearAllData()`
//     still throws exactly as it did before the call.
//  5. Comprehensive regression, the final safety net for the whole M1.7-
//     M1.13 broad-scope soft-delete effort: one smoke test per
//     already-converted delete function (spanning all ten tables) proving
//     none of them accidentally still issues a real delete the
//     newly-installed guard would now catch.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_attachment.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/services/database_service.dart';

/// The ten tables M1.13 adds to `_hardDeleteGuardedTables`, on top of the
/// four User-App-family tables M1.5 already guards (see
/// hard_delete_guard_test.dart for those).
const _newlyGuardedTables = [
  'notes',
  'subnotes',
  'attachments',
  'tags',
  'filters',
  'relationships',
  'tag_workflow_bindings',
  'conversations',
  'conversation_messages',
  'conversation_attachments',
];

/// The original four M1.5 tables -- exactly what migration step 50 must
/// install, and ONLY those, even now that `_hardDeleteGuardedTables` has
/// grown to fourteen entries (see `_migrateToVersion51`'s own doc comment
/// in database_service.dart for the bug this guards against).
const _originalGuardedTables = [
  'user_apps',
  'app_revisions',
  'user_app_libraries',
  'user_app_library_dependencies',
];

Future<bool> _hasGuardTrigger(Database db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='trigger' AND name=?",
    ['guard_no_hard_delete_$table'],
  );
  return rows.isNotEmpty;
}

Note _buildNote(
  String id, {
  List<SubNote> subNotes = const [],
  List<String> tags = const [],
  List<String> attachmentPaths = const [],
}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Note(
    id: id,
    title: 'Note $id',
    content: 'content for $id',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    subNotes: subNotes,
    tags: tags,
    attachmentPaths: attachmentPaths,
  );
}

Relationship _buildRelationship({
  required String id,
  required String fromNoteId,
  required String toNoteId,
}) {
  return Relationship(
    id: id,
    fromNoteId: fromNoteId,
    toNoteId: toNoteId,
    type: 'related',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

Filter _buildFilter(String id) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Filter(
    id: id,
    name: 'Filter $id',
    includeTags: const ['work'],
    noteTypes: const [NoteType.note],
    createdAt: now,
    updatedAt: now,
  );
}

Conversation _buildConversation(String id) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Conversation(id: id, title: 'Conv $id', createdAt: now, updatedAt: now);
}

ConversationMessage _buildMessage(String id) {
  return ConversationMessage(
    id: id,
    conversationId: '',
    type: MessageType.user,
    content: 'content for $id',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

/// Inserts one row into [table] and returns a fresh [DatabaseService] plus
/// the underlying [Database] handle, so each per-table test is fully
/// self-contained. Uses the same ordinary service-level insert helpers
/// every other soft-delete milestone's own test file uses, not a
/// hand-written raw INSERT, so this stays honest to what a real row in
/// that table looks like.
Future<(DatabaseService, Database)> _freshDbWithRowIn(String table) async {
  final service = DatabaseService.createNew();
  final db = await service.database;
  await _insertRowInto(service, table);
  return (service, db);
}

/// Inserts one row into [table] via [service]'s own ordinary insert
/// helpers (the same ones every other soft-delete milestone's own test
/// file uses, not a hand-written raw INSERT) -- shared by
/// [_freshDbWithRowIn] (fresh database) and the `clearAllData` bypass
/// tests below (reusing an existing, already-wiped database, to prove the
/// guard still works against the SAME connection afterward).
Future<void> _insertRowInto(DatabaseService service, String table) async {
  switch (table) {
    case 'notes':
      await service.insertNote(_buildNote('note-1'));
    case 'subnotes':
      await service.insertNote(
        _buildNote(
          'note-1',
          subNotes: [
            SubNote(
              id: 'sub-1',
              name: 'Sub 1',
              content: 'x',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
        ),
      );
    case 'attachments':
      await service.insertNote(
        _buildNote('note-1', attachmentPaths: ['attachments/foo.png']),
      );
    case 'tags':
      await service.insertNote(_buildNote('note-1', tags: ['urgent']));
    case 'filters':
      await service.insertFilter(_buildFilter('filter-1'));
    case 'relationships':
      await service.insertNote(_buildNote('note-1'));
      await service.insertNote(_buildNote('note-2'));
      await service.insertRelationship(
        _buildRelationship(id: 'rel-1', fromNoteId: 'note-1', toNoteId: 'note-2'),
      );
    case 'tag_workflow_bindings':
      await service.insertWorkflowBinding(
        const WorkflowBindingRow(
          pattern: 'proj/',
          isPrefix: true,
          skillNoteId: 'skill-1',
          prompt: 'p',
          contentImmutable: false,
        ),
      );
    case 'conversations':
      await service.insertConversation(_buildConversation('conv-1'));
    case 'conversation_messages':
      await service.insertConversationMessage(_buildMessage('msg-1'));
    case 'conversation_attachments':
      await service.insertConversationMessage(_buildMessage('msg-1'));
      await service.insertConversationAttachment(
        ConversationAttachment(
          id: 'att-1',
          messageId: 'msg-1',
          filePath: 'attachments/foo.png',
          fileName: 'foo.png',
          fileType: 'image/png',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
    default:
      throw ArgumentError('no row builder for table $table');
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.13 broad hard-delete guard rollout — fresh install', () {
    test('every newly-guarded table has its guard trigger installed', () async {
      final service = DatabaseService.createNew();
      final db = await service.database;
      for (final table in _newlyGuardedTables) {
        expect(
          await _hasGuardTrigger(db, table),
          isTrue,
          reason: '$table should have a guard_no_hard_delete_$table trigger',
        );
      }
      await service.close();
    });

    for (final table in _newlyGuardedTables) {
      test(
        'a real db.delete() against $table throws with a clear message, row survives',
        () async {
          final (service, db) = await _freshDbWithRowIn(table);
          try {
            final before = await db.query(table);
            expect(before, isNotEmpty, reason: 'setup should have inserted a row');

            expect(
              () => db.delete(table),
              throwsA(
                isA<DatabaseException>().having(
                  (e) => e.toString(),
                  'message',
                  allOf(contains(table), contains('soft-delete')),
                ),
              ),
            );

            final after = await db.query(table);
            expect(
              after.length,
              before.length,
              reason: 'RAISE(ABORT) must roll back the whole statement',
            );
          } finally {
            await service.close();
          }
        },
      );
    }

    test(
      'the guard is not overly broad: ordinary UPDATE against every newly-'
      'guarded table still works normally',
      () async {
        for (final table in _newlyGuardedTables) {
          final (service, db) = await _freshDbWithRowIn(table);
          try {
            final before = (await db.query(table)).single;
            final idColumn = before.containsKey('id')
                ? 'id'
                : before.containsKey('pattern')
                ? 'pattern'
                : throw StateError('$table has neither id nor pattern');
            final idValue = before[idColumn];

            // Pick a text column that isn't the identity column to touch,
            // proving UPDATE itself is untouched by the guard (it only
            // reacts to DELETE).
            await db.update(
              table,
              {'__deleted__': 0},
              where: '$idColumn = ?',
              whereArgs: [idValue],
            );

            final after = (await db.query(
              table,
              where: '$idColumn = ?',
              whereArgs: [idValue],
            )).single;
            expect(after[idColumn], idValue);
          } finally {
            await service.close();
          }
        }
      },
    );
  });

  group('M1.13 broad hard-delete guard rollout — migration round-trip '
      '(v56 -> v57)', () {
    // Deliberately does NOT hand-reconstruct a "v56 shape" database from
    // DatabaseService.getSchema() the way other milestones' migration
    // round-trip tests do (see e.g. filters_workflow_bindings_soft_delete_
    // test.dart): getSchema() itself deliberately omits several tables
    // added outside it in _onCreate (tag_workflow_bindings/tag_ai_configs/
    // tag_images/the sync control-plane tables -- see
    // tags_identity_schema_test.dart's own doc comment for this same,
    // pre-existing, unrelated gap), which would require re-deriving every
    // one of those tables' CURRENT shape by hand here just to stand up a
    // realistic v56 database. Since v56 -> v57 is purely additive (ten new
    // guard triggers, no column/table change at all -- every one of these
    // tables' `__deleted__` column already existed by v56), an actual
    // fresh (current-version) install with just those ten triggers dropped
    // is byte-for-byte the same "v56 shape" this migration is meant to
    // upgrade from, without needing to reconstruct anything by hand.
    late DatabaseService preMigrationService;
    late Database preMigrationDb;

    setUp(() async {
      preMigrationService = DatabaseService.createNew();
      preMigrationDb = await preMigrationService.database;
      for (final table in _newlyGuardedTables) {
        await preMigrationDb.execute(
          'DROP TRIGGER IF EXISTS guard_no_hard_delete_$table',
        );
      }
      for (final table in _newlyGuardedTables) {
        expect(await _hasGuardTrigger(preMigrationDb, table), isFalse);
      }
    });

    tearDown(() async {
      await preMigrationService.close();
    });

    test(
      'migrating v56 -> v57 installs the guard trigger on all ten tables, '
      'and existing data survives untouched',
      () async {
        await preMigrationDb.insert('notes', {
          'id': 'note-1',
          'title': 'T',
          'content': 'C',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });

        await preMigrationService.migrateBackupDatabase(preMigrationDb, 56, 57);

        for (final table in _newlyGuardedTables) {
          expect(
            await _hasGuardTrigger(preMigrationDb, table),
            isTrue,
            reason: '$table should have the guard trigger after migrating to v57',
          );
        }

        final notes = await preMigrationDb.query('notes');
        expect(notes.single['id'], 'note-1');

        expect(
          () => preMigrationDb.delete('notes', where: 'id = ?', whereArgs: ['note-1']),
          throwsA(isA<DatabaseException>()),
        );
      },
    );

    test(
      'running the v56 -> v57 migration twice does not error (CREATE '
      'TRIGGER IF NOT EXISTS is idempotent)',
      () async {
        await preMigrationService.migrateBackupDatabase(preMigrationDb, 56, 57);
        await preMigrationService.migrateBackupDatabase(preMigrationDb, 56, 57);

        for (final table in _newlyGuardedTables) {
          expect(await _hasGuardTrigger(preMigrationDb, table), isTrue);
        }
      },
    );
  });

  group(
    'M1.13 real multi-step upgrade chain (v50 -> v57, the chain a real '
    'pre-M1.5 device upgrading today would actually run) -- regression '
    'test for the _migrateToVersion51 over-installation bug',
    () {
      // The bug this group exists to catch: _migrateToVersion51 used to
      // iterate the SHARED `_hardDeleteGuardTriggerStatements` field
      // directly. That field reflects `_hardDeleteGuardedTables`, which
      // M1.13 grew from 4 to 14 entries -- so a real device migrating
      // straight from v50 to v57 in one run (exactly what
      // `migrateBackupDatabase`/the real app-upgrade path both do) would
      // have installed all fourteen guard triggers at step 50, contradicting
      // that step's own doc comment/log message ("installs the four
      // User-App-family guard triggers") and silently pulling the M1.13
      // guard rollout ten versions earlier than intended. Harmless by
      // accident today (migrations 51-55 are pure idempotent `ALTER TABLE
      // ADD COLUMN`, nothing that could trip a trigger before its own
      // dedicated step installs it) but a latent trap for any future
      // migration ever inserted between 50 and 56. Fixed by giving
      // `_migrateToVersion51` its own frozen, local four-table list.
      //
      // Uses a fresh (current-shape) database with every guard trigger
      // dropped, rather than hand-reconstructing a literal v50 DDL
      // snapshot (see the v56->v57 group's own doc comment above for why
      // that reconstruction is unnecessary/expensive: getSchema() omits
      // several tables added outside it in _onCreate, and every ADD
      // COLUMN migration in this chain, 51-55, is independently
      // idempotent -- verified by their own `if (!columnNames.contains(...))`
      // guards -- so re-running them against a database that already has
      // the columns is a safe, faithful no-op, identical in effect to
      // running them against a genuinely pre-v52..v56 database). This
      // exercises the exact same `_migrationSteps` map and the exact same
      // step functions a real v50 device hitting this app today would run,
      // for every version in the chain: 51 (filters/tag_workflow_bindings
      // __deleted__), 52 (relationships/conversation_attachments
      // __deleted__), 53 (notes __deleted__), 54 (subnotes/attachments
      // __deleted__), 55 (conversations/conversation_messages __deleted__),
      // and the two guard-trigger-install steps this group's own bug was
      // found in: 50 and 56.
      late DatabaseService service;
      late Database db;

      setUp(() async {
        service = DatabaseService.createNew();
        db = await service.database;
        for (final table in [..._originalGuardedTables, ..._newlyGuardedTables]) {
          await db.execute('DROP TRIGGER IF EXISTS guard_no_hard_delete_$table');
        }
        for (final table in [..._originalGuardedTables, ..._newlyGuardedTables]) {
          expect(await _hasGuardTrigger(db, table), isFalse);
        }
      });

      tearDown(() async {
        await service.close();
      });

      test(
        'migration step 50 in isolation installs ONLY the original four '
        'tables -- not all fourteen -- even though the shared '
        'guarded-table list has since grown to fourteen',
        () async {
          await service.migrateBackupDatabase(db, 50, 51);

          for (final table in _originalGuardedTables) {
            expect(
              await _hasGuardTrigger(db, table),
              isTrue,
              reason: '$table is one of the original four; step 50 must install it',
            );
          }
          for (final table in _newlyGuardedTables) {
            expect(
              await _hasGuardTrigger(db, table),
              isFalse,
              reason: '$table is an M1.13 addition; step 50 alone must NOT '
                  'install it (that is step 56\'s job) -- this is the exact '
                  'over-installation bug this test exists to catch',
            );
          }
        },
      );

      test(
        'the full v50 -> v57 chain ends with all fourteen tables guarded, '
        'data intact, and a real delete throwing for every one of them',
        () async {
          await service.insertUserApp(
            UserApp(
              id: 'app-1',
              uuid: 'uuid-1',
              name: 'App',
              description: 'd',
              steps: const ['s'],
              htmlContent: '<html></html>',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
              updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          );
          await service.insertNote(_buildNote('note-1'));

          await service.migrateBackupDatabase(db, 50, 57);

          for (final table in [..._originalGuardedTables, ..._newlyGuardedTables]) {
            expect(
              await _hasGuardTrigger(db, table),
              isTrue,
              reason: '$table must be guarded after the full v50 -> v57 chain',
            );
          }

          final apps = await db.query('user_apps', where: "id = 'app-1'");
          expect(apps.single['id'], 'app-1');
          final notes = await db.query('notes', where: "id = 'note-1'");
          expect(notes.single['id'], 'note-1');

          expect(
            () => db.delete('user_apps', where: "id = 'app-1'"),
            throwsA(isA<DatabaseException>()),
          );
          expect(
            () => db.delete('notes', where: "id = 'note-1'"),
            throwsA(isA<DatabaseException>()),
          );
        },
      );

      test(
        'running the full chain twice does not error (every step is '
        'independently idempotent)',
        () async {
          await service.migrateBackupDatabase(db, 50, 57);
          await service.migrateBackupDatabase(db, 50, 57);

          for (final table in [..._originalGuardedTables, ..._newlyGuardedTables]) {
            expect(await _hasGuardTrigger(db, table), isTrue);
          }
        },
      );
    },
  );

  group('M1.13 clearAllData — guard bypass mechanism', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'clearAllData empties every table it always has, without throwing '
      'under the now-installed guard',
      () async {
        await databaseService.insertNote(
          _buildNote(
            'note-1',
            subNotes: [
              SubNote(
                id: 'sub-1',
                name: 'S',
                content: 'x',
                createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
              ),
            ],
            attachmentPaths: ['attachments/foo.png'],
            tags: ['urgent'],
          ),
        );
        await databaseService.insertFilter(_buildFilter('filter-1'));
        await databaseService.insertConversation(_buildConversation('conv-1'));
        await databaseService.insertConversationMessage(_buildMessage('msg-1'));

        await expectLater(databaseService.clearAllData(), completes);

        const wipedTables = [
          'relationships',
          'attachments',
          'note_tags',
          'subnotes',
          'notes',
          'tags',
          'filters',
          'conversation_messages',
          'conversation_attachments',
          'conversation_message_mapping',
          'conversation_note_mapping',
          'conversation_tags',
          'message_parents',
          'conversations',
        ];
        for (final table in wipedTables) {
          expect(
            await db.query(table),
            isEmpty,
            reason: '$table should be genuinely empty after clearAllData, '
                'not merely tombstoned',
          );
        }
      },
    );

    test(
      'the guard is fully reinstalled after clearAllData -- on the SAME '
      'connection, a real delete attempted right afterward still throws '
      'for every table it wiped',
      () async {
        // One isolated database per table (rather than reusing
        // `databaseService` for all nine in a single loop) so inserting a
        // fresh row to re-arm each table's guard check never collides with
        // an id a previous iteration already committed -- a real delete
        // the guard correctly aborts leaves its row in place (RAISE(ABORT)
        // rolls back), so reusing one connection across tables that share
        // an insert helper (e.g. `notes`/`subnotes`/`attachments`/`tags`/
        // `relationships` all insert a `note-1` row) would otherwise hit a
        // PRIMARY KEY conflict on the second such table.
        const guardedEntityTablesClearAllDataWipes = [
          'relationships',
          'attachments',
          'subnotes',
          'notes',
          'tags',
          'filters',
          'conversation_messages',
          'conversation_attachments',
          'conversations',
        ];
        for (final table in guardedEntityTablesClearAllDataWipes) {
          final service = DatabaseService.createNew();
          final tableDb = await service.database;
          try {
            await _insertRowInto(service, table);
            await service.clearAllData();

            // Re-arm: a real DELETE against an already-empty table never
            // fires a BEFORE DELETE trigger at all (SQLite only invokes a
            // row trigger once per row actually matched), so this test
            // must insert a fresh row post-clearAllData before attempting
            // the delete it expects to throw.
            await _insertRowInto(service, table);

            expect(
              await _hasGuardTrigger(tableDb, table),
              isTrue,
              reason: '$table guard trigger must be reinstalled after clearAllData',
            );
            expect(
              () => tableDb.delete(table),
              throwsA(isA<DatabaseException>()),
              reason: '$table must still be guarded after clearAllData',
            );
          } finally {
            await service.close();
          }
        }
      },
    );

    test(
      'clearAllData is safe to call twice in a row (guard drop/reinstall '
      'does not accumulate state)',
      () async {
        await databaseService.insertNote(_buildNote('note-1'));
        await databaseService.clearAllData();
        await expectLater(databaseService.clearAllData(), completes);
      },
    );
  });

  group(
    'M1.13 comprehensive regression: every tombstone-only delete function '
    'from M1.7-M1.13 still works under the now-installed guard',
    () {
      late DatabaseService databaseService;
      late Database db;

      setUp(() async {
        databaseService = DatabaseService.createNew();
        db = await databaseService.database;
      });

      tearDown(() async {
        await databaseService.close();
      });

      test('deleteNote tombstones the note AND its subnotes/attachments '
          '(M1.10 + M1.13 step 0)', () async {
        await databaseService.insertNote(
          _buildNote(
            'note-1',
            subNotes: [
              SubNote(
                id: 'sub-1',
                name: 'S',
                content: 'x',
                createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
              ),
            ],
            attachmentPaths: ['attachments/foo.png'],
          ),
        );

        await databaseService.deleteNote('note-1');

        final note = (await db.query('notes', where: "id = 'note-1'")).single;
        expect(note['__deleted__'], 1);
        final sub = (await db.query('subnotes', where: "noteId = 'note-1'")).single;
        expect(sub['__deleted__'], 1);
        final att = (await db.query('attachments', where: "noteId = 'note-1'")).single;
        expect(att['__deleted__'], 1);
      });

      test('updateNote tombstones a removed subnote/attachment via the '
          'diff helpers (M1.11)', () async {
        await databaseService.insertNote(
          _buildNote(
            'note-1',
            subNotes: [
              SubNote(
                id: 'sub-1',
                name: 'S',
                content: 'x',
                createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
              ),
            ],
            attachmentPaths: ['attachments/foo.png'],
          ),
        );

        await databaseService.updateNote(_buildNote('note-1'));

        final sub = (await db.query('subnotes', where: "noteId = 'note-1'")).single;
        expect(sub['__deleted__'], 1);
        final att = (await db.query('attachments', where: "noteId = 'note-1'")).single;
        expect(att['__deleted__'], 1);
      });

      test('deleteTag tombstones the tag row (M1.9)', () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
        await databaseService.deleteTag('urgent');
        final tag = (await db.query('tags')).single;
        expect(tag['__deleted__'], 1);
      });

      test('replaceTag tombstones the old tag row (M1.9)', () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['old-name']));
        await databaseService.replaceTag('old-name', 'new-name');
        final oldTag = (await db.query('tags', where: "name = 'old-name'")).single;
        expect(oldTag['__deleted__'], 1);
      });

      test('deleteFilter tombstones the filter row (M1.7)', () async {
        await databaseService.insertFilter(_buildFilter('filter-1'));
        await databaseService.deleteFilter('filter-1');
        final filter = (await db.query('filters')).single;
        expect(filter['__deleted__'], 1);
      });

      test(
        'deleteWorkflowBinding tombstones the binding row (M1.7)',
        () async {
          await databaseService.insertWorkflowBinding(
            const WorkflowBindingRow(
              pattern: 'proj/',
              isPrefix: true,
              skillNoteId: 'skill-1',
              prompt: 'p',
              contentImmutable: false,
            ),
          );
          await databaseService.deleteWorkflowBinding('proj/');
          final binding = (await db.query('tag_workflow_bindings')).single;
          expect(binding['__deleted__'], 1);
        },
      );

      test('deleteRelationship tombstones the relationship row (M1.8)', () async {
        await databaseService.insertNote(_buildNote('note-1'));
        await databaseService.insertNote(_buildNote('note-2'));
        await databaseService.insertRelationship(
          _buildRelationship(id: 'rel-1', fromNoteId: 'note-1', toNoteId: 'note-2'),
        );
        await databaseService.deleteRelationship('rel-1');
        final rel = (await db.query('relationships')).single;
        expect(rel['__deleted__'], 1);
      });

      test(
        'deleteConversationAttachment tombstones the attachment row (M1.8)',
        () async {
          await databaseService.insertConversationMessage(_buildMessage('msg-1'));
          await databaseService.insertConversationAttachment(
            ConversationAttachment(
              id: 'att-1',
              messageId: 'msg-1',
              filePath: 'attachments/foo.png',
              fileName: 'foo.png',
              fileType: 'image/png',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          );
          await databaseService.deleteConversationAttachment('att-1');
          final att = (await db.query('conversation_attachments')).single;
          expect(att['__deleted__'], 1);
        },
      );

      test('deleteConversation tombstones the conversation row (M1.12)', () async {
        await databaseService.insertConversation(_buildConversation('conv-1'));
        await databaseService.deleteConversation('conv-1');
        final conv = (await db.query('conversations')).single;
        expect(conv['__deleted__'], 1);
      });

      test(
        'deleteConversationMessage tombstones the message row (M1.12)',
        () async {
          await databaseService.insertConversation(_buildConversation('conv-1'));
          await databaseService.insertConversationMessage(_buildMessage('msg-1'));
          await databaseService.insertConversationMessageMapping(
            conversationId: 'conv-1',
            messageId: 'msg-1',
          );

          await databaseService.deleteConversationMessage('msg-1');

          final msg = (await db.query('conversation_messages')).single;
          expect(msg['__deleted__'], 1);
        },
      );
    },
  );
}
