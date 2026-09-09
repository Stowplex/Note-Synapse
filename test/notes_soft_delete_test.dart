// Tests for the M1.10 "notes soft-delete conversion" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Phased
// delivery — "M1.10 — `notes` (`deleteNote` only). Must land together with
// (not strictly before) M1.11, since `deleteNote`'s current correctness
// depends on the `ON DELETE CASCADE` into `subnotes`/`attachments`/
// `note_tags`/`relationships`/`conversation_note_mapping` — cascades stop
// firing the moment `notes` is soft-delete-only, so every one of those
// cascade-only baseline entries needs an explicit tombstone/
// membership-cleanup step added at the same time or child rows silently
// stop being cleaned up on note deletion.").
//
// `notes` gains a `__deleted__` tombstone column; `deleteNote` becomes an
// ordinary tombstone write instead of a real SQL delete, wrapped in a
// transaction (it was not transactional before). Since cascades only fire
// on a real `DELETE`, `deleteNote` now does the child-table cleanup the
// cascade used to do implicitly, explicitly:
//  - `conversation_note_mapping` / `note_tags`: OR-Set membership rows,
//    real deletion is correct (unchanged in shape from before this
//    milestone).
//  - `relationships`: already tombstoned (M1.8) — reused via
//    `deleteRelationshipsForNote`.
//  - `subnotes` / `attachments`: at the time this milestone landed, still
//    real-deleted, NOT tombstoned here — that column, and the
//    accompanying rewrite of `updateNote`/`_persistNote`'s diff logic, was
//    M1.11's job, and `deleteNote` itself was explicitly out of M1.11's
//    scope. M1.13 step 0 later closed that gap: `deleteNote` now
//    tombstones both tables too, matching the shape M1.11 established for
//    the edit path (see the tests below).
//
// Every notes read path (getAllNotes/getNote/getNoteById/getNotesByIds/
// getNotesByTag/getPinnedNotes/getArchivedNotes/getNotesByArchiveStatus/
// searchNotes/searchNotesFTS) filters on `__deleted__ = 0`.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';

/// The exact pre-M1.10 (DATABASE_VERSION <= 52) shape of `notes`: no
/// `__deleted__` column. Hand-written rather than derived from
/// DatabaseService.getSchema() — as of M1.10, getSchema() already returns
/// the NEW DDL — same approach every prior soft-delete milestone's test
/// file established (test/filters_workflow_bindings_soft_delete_test.dart,
/// test/relationships_conversation_attachments_soft_delete_test.dart).
const _oldNotesTableDdl = '''
    CREATE TABLE notes(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      type TEXT NOT NULL,
      createdAt INTEGER NOT NULL,
      updatedAt INTEGER NOT NULL,
      scheduledAt TEXT,
      completeBy TEXT,
      status TEXT,
      completionPercentage REAL,
      pinned INTEGER NOT NULL DEFAULT 0,
      isArchived INTEGER NOT NULL DEFAULT 0,
      recurrenceRule TEXT,
      metadata TEXT
    )
''';

Future<List<Map<String, Object?>>> _tableInfo(Database db, String table) =>
    db.rawQuery("PRAGMA table_info('$table')");

Future<bool> _hasColumn(Database db, String table, String column) async {
  final cols = await _tableInfo(db, table);
  return cols.any((c) => c['name'] == column);
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
  String type = 'related',
}) {
  return Relationship(
    id: id,
    fromNoteId: fromNoteId,
    toNoteId: toNoteId,
    type: type,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

Conversation _buildConversation(String id) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Conversation(
    id: id,
    title: 'Conv $id',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.10 notes soft-delete — fresh install', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('notes has __deleted__ (NOT NULL, default 0)', () async {
      final db = await databaseService.database;
      final cols = await _tableInfo(db, 'notes');
      final deletedCol = cols.firstWhere((c) => c['name'] == '__deleted__');
      expect(
        deletedCol['notnull'],
        1,
        reason: 'notes.__deleted__ should be NOT NULL',
      );
      expect(
        deletedCol['dflt_value'],
        '0',
        reason: 'notes.__deleted__ should default to 0',
      );
    });

    // M1.11 update: subnotes/attachments now DO gain a `__deleted__`
    // column -- this was deliberately deferred by M1.10 (see this file's
    // own header comment) and is now implemented, consumed by
    // `updateNote`/`NoteModificationService._persistNote`'s rewritten
    // diff logic. Full M1.11 behavior coverage (diff correctness,
    // resurrect-on-reappear, read-path filtering, `updateNote`/
    // `_persistNote` parity, atomicity, the closed race with
    // `deleteNote`) lives in
    // test/subnotes_attachments_soft_delete_test.dart, not here -- this
    // assertion is kept only so this file's own "fresh install" schema
    // group stays accurate about the two tables it otherwise only
    // exercises via `deleteNote`'s real-delete behavior below.
    test('subnotes and attachments now DO have __deleted__ (M1.11)', () async {
      final db = await databaseService.database;
      expect(await _hasColumn(db, 'subnotes', '__deleted__'), isTrue);
      expect(await _hasColumn(db, 'attachments', '__deleted__'), isTrue);
    });
  });

  group('M1.10 notes soft-delete — migration round-trip (v53 -> v54)', () {
    late Database preMigrationDb;

    setUp(() async {
      preMigrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );

      // Old-shape table must exist before getSchema()'s own statements run
      // below (everything except notes itself, which we create with the
      // pre-M1.10 DDL instead).
      await preMigrationDb.execute(_oldNotesTableDdl);

      for (final statement in DatabaseService.getSchema()) {
        if (statement.contains('CREATE TABLE notes(')) continue;
        await preMigrationDb.execute(statement);
      }

      await preMigrationDb.execute('''
        CREATE TABLE _schema_version (version INTEGER NOT NULL)
      ''');
      await preMigrationDb.insert('_schema_version', {'version': 52});

      expect(await _hasColumn(preMigrationDb, 'notes', '__deleted__'), isFalse);
    });

    tearDown(() async {
      await preMigrationDb.close();
    });

    test(
      'existing rows survive migration with __deleted__=0, ids unchanged',
      () async {
        await preMigrationDb.insert('notes', {
          'id': 'note-1',
          'title': 'N1',
          'content': 'c1',
          'type': 'note',
          'createdAt': 100,
          'updatedAt': 100,
        });

        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 53, 54);

        expect(
          await _hasColumn(preMigrationDb, 'notes', '__deleted__'),
          isTrue,
        );

        final notes = await preMigrationDb.query('notes');
        expect(notes.single['id'], 'note-1');
        expect(notes.single['__deleted__'], 0);
      },
    );

    test('running the v53 -> v54 migration twice does not error and leaves '
        'schema/data unchanged the second time', () async {
      await preMigrationDb.insert('notes', {
        'id': 'note-1',
        'title': 'N1',
        'content': 'c1',
        'type': 'note',
        'createdAt': 100,
        'updatedAt': 100,
      });

      final service = DatabaseService.createNew();
      await service.migrateBackupDatabase(preMigrationDb, 53, 54);
      final afterFirst = await preMigrationDb.query('notes', orderBy: 'id');

      await service.migrateBackupDatabase(preMigrationDb, 53, 54);
      final afterSecond = await preMigrationDb.query('notes', orderBy: 'id');

      expect(afterSecond, equals(afterFirst));
    });
  });

  group('M1.10 deleteNote — tombstone + explicit child-table cleanup', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('tombstones the note row (__deleted__=1); row count unchanged, '
        'not a real delete', () async {
      await databaseService.insertNote(_buildNote('note-1'));

      final rowsBefore = await db.query('notes');
      await databaseService.deleteNote('note-1');
      final rowsAfter = await db.query('notes');

      expect(
        rowsAfter.length,
        rowsBefore.length,
        reason: 'no real row deleted',
      );
      expect(rowsAfter.single['id'], 'note-1');
      expect(rowsAfter.single['__deleted__'], 1);
    });

    test(
      'really deletes note_tags rows for the note (OR-Set membership)',
      () async {
        await databaseService.insertNote(
          _buildNote('note-1', tags: ['alpha', 'beta']),
        );
        final tagIdsBefore = await db.query(
          'note_tags',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        );
        expect(tagIdsBefore.length, 2);

        await databaseService.deleteNote('note-1');

        final tagRowsAfter = await db.query(
          'note_tags',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        );
        expect(tagRowsAfter, isEmpty);
      },
    );

    test(
      'tombstones subnotes rows for the note (M1.13 step 0 -- deleteNote '
      'used to real-delete these, deliberately deferred by M1.10/M1.11; '
      'now matches the tombstone shape '
      'test/subnotes_attachments_soft_delete_test.dart already covers for '
      'the updateNote/_persistNote edit path); row count unchanged',
      () async {
        await databaseService.insertNote(
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
        expect(
          await db.query(
            'subnotes',
            where: 'noteId = ? AND __deleted__ = 0',
            whereArgs: ['note-1'],
          ),
          isNotEmpty,
        );

        await databaseService.deleteNote('note-1');

        final rowsAfter = await db.query(
          'subnotes',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        );
        expect(rowsAfter, hasLength(1));
        expect(rowsAfter.single['__deleted__'], 1);
      },
    );

    test(
      'tombstones attachments rows for the note (M1.13 step 0 -- '
      'deleteNote used to real-delete these, deliberately deferred by '
      'M1.10/M1.11; now matches the tombstone shape '
      'test/subnotes_attachments_soft_delete_test.dart already covers for '
      'the updateNote/_persistNote edit path); row count unchanged',
      () async {
        await databaseService.insertNote(
          _buildNote('note-1', attachmentPaths: ['attachments/foo.png']),
        );
        expect(
          await db.query(
            'attachments',
            where: 'noteId = ? AND __deleted__ = 0',
            whereArgs: ['note-1'],
          ),
          isNotEmpty,
        );

        await databaseService.deleteNote('note-1');

        final rowsAfter = await db.query(
          'attachments',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        );
        expect(rowsAfter, hasLength(1));
        expect(rowsAfter.single['__deleted__'], 1);
      },
    );

    test('tombstones relationships touching the note in either direction '
        '(reusing deleteRelationshipsForNote); row count unchanged', () async {
      await databaseService.insertNote(_buildNote('note-1'));
      await databaseService.insertNote(_buildNote('note-2'));
      await databaseService.insertNote(_buildNote('note-3'));
      await databaseService.insertRelationship(
        _buildRelationship(
          id: 'rel-1',
          fromNoteId: 'note-1',
          toNoteId: 'note-2',
        ),
      );
      await databaseService.insertRelationship(
        _buildRelationship(
          id: 'rel-2',
          fromNoteId: 'note-3',
          toNoteId: 'note-1',
        ),
      );
      // Unrelated relationship, must survive live.
      await databaseService.insertRelationship(
        _buildRelationship(
          id: 'rel-3',
          fromNoteId: 'note-2',
          toNoteId: 'note-3',
        ),
      );

      await databaseService.deleteNote('note-1');

      final rows = await db.query('relationships', orderBy: 'id');
      expect(rows.length, 3, reason: 'no real row deleted');
      expect(rows.firstWhere((r) => r['id'] == 'rel-1')['__deleted__'], 1);
      expect(rows.firstWhere((r) => r['id'] == 'rel-2')['__deleted__'], 1);
      expect(
        rows.firstWhere((r) => r['id'] == 'rel-3')['__deleted__'],
        0,
        reason: 'does not touch note-1, must stay live',
      );
    });

    test('really deletes conversation_note_mapping rows for the note '
        '(OR-Set membership, via deleteNoteConversationMappings)', () async {
      await databaseService.insertNote(_buildNote('note-1'));
      await databaseService.insertConversation(_buildConversation('conv-1'));
      await databaseService.insertConversationNoteMapping(
        conversationId: 'conv-1',
        noteId: 'note-1',
      );
      expect(
        await db.query(
          'conversation_note_mapping',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        ),
        isNotEmpty,
      );

      await databaseService.deleteNote('note-1');

      expect(
        await db.query(
          'conversation_note_mapping',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        ),
        isEmpty,
      );
    });

    test('deleting one note does not touch another note\'s subnotes/'
        'attachments/tags/relationships', () async {
      await databaseService.insertNote(
        _buildNote(
          'note-1',
          subNotes: [
            SubNote(
              id: 'sub-1',
              name: 'S1',
              content: 'x',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
          tags: ['keep-me'],
          attachmentPaths: ['attachments/keep.png'],
        ),
      );
      await databaseService.insertNote(_buildNote('note-2'));
      await databaseService.insertRelationship(
        _buildRelationship(
          id: 'rel-1',
          fromNoteId: 'note-1',
          toNoteId: 'note-2',
        ),
      );

      await databaseService.deleteNote('note-2');

      expect(
        await db.query('subnotes', where: 'noteId = ?', whereArgs: ['note-1']),
        isNotEmpty,
      );
      expect(
        await db.query(
          'attachments',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        ),
        isNotEmpty,
      );
      expect(
        await db.query('note_tags', where: 'noteId = ?', whereArgs: ['note-1']),
        isNotEmpty,
      );
      final rel = await db.query('relationships', where: "id = 'rel-1'");
      expect(
        rel.single['__deleted__'],
        1,
        reason: 'note-2 is an endpoint of rel-1, so it is correctly tombstoned',
      );
      final note1 = await db.query('notes', where: "id = 'note-1'");
      expect(note1.single['__deleted__'], 0);
    });
  });

  group('M1.10 deleteNote — atomicity', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('a failure partway through the transaction leaves no partial '
        'state: note stays live, no child table is touched', () async {
      await databaseService.insertNote(
        _buildNote(
          'note-1',
          subNotes: [
            SubNote(
              id: 'sub-1',
              name: 'S1',
              content: 'x',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
          tags: ['t1'],
        ),
      );
      await databaseService.insertNote(_buildNote('note-2'));
      await databaseService.insertRelationship(
        _buildRelationship(
          id: 'rel-1',
          fromNoteId: 'note-1',
          toNoteId: 'note-2',
        ),
      );
      await databaseService.insertConversation(_buildConversation('conv-1'));
      await databaseService.insertConversationNoteMapping(
        conversationId: 'conv-1',
        noteId: 'note-1',
      );

      // Force a failure partway through deleteNote's transaction: the
      // 'attachments' delete runs after note_tags/subnotes but before the
      // notes tombstone write itself (see deleteNote's own statement
      // order). Dropping the table makes that statement throw, and since
      // it all runs inside db.transaction(...), sqflite rolls back
      // everything else in the same transaction too.
      await db.execute('DROP TABLE attachments');

      await expectLater(
        databaseService.deleteNote('note-1'),
        throwsA(anything),
      );

      // Nothing committed: note-1 is still live...
      final note1 = await db.query('notes', where: "id = 'note-1'");
      expect(
        note1.single['__deleted__'],
        0,
        reason: 'tombstone write must have rolled back',
      );

      // ...its note_tags/subnotes rows are still present...
      expect(
        await db.query('note_tags', where: 'noteId = ?', whereArgs: ['note-1']),
        isNotEmpty,
        reason: 'note_tags delete must have rolled back',
      );
      expect(
        await db.query('subnotes', where: 'noteId = ?', whereArgs: ['note-1']),
        isNotEmpty,
        reason: 'subnotes delete must have rolled back',
      );

      // ...its relationship is still live (not tombstoned)...
      final rel = await db.query('relationships', where: "id = 'rel-1'");
      expect(
        rel.single['__deleted__'],
        0,
        reason: 'relationships tombstone must have rolled back',
      );

      // ...and its conversation_note_mapping row is still present.
      expect(
        await db.query(
          'conversation_note_mapping',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        ),
        isNotEmpty,
        reason: 'conversation_note_mapping delete must have rolled back',
      );
    });
  });

  group('M1.10 read-path filtering — tombstoned notes are invisible', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.insertNote(_buildNote('live-1'));
      await databaseService.insertNote(
        _buildNote('dead-1', tags: ['shared-tag']),
      );
      await databaseService.deleteNote('dead-1');
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('getAllNotes excludes the tombstoned note', () async {
      final notes = await databaseService.getAllNotes();
      expect(notes.map((n) => n.id), contains('live-1'));
      expect(notes.map((n) => n.id), isNot(contains('dead-1')));
    });

    test('getNoteById returns null for the tombstoned note', () async {
      expect(await databaseService.getNoteById('dead-1'), isNull);
      expect(await databaseService.getNoteById('live-1'), isNotNull);
    });

    test('getNote returns null for the tombstoned note', () async {
      expect(await databaseService.getNote('dead-1'), isNull);
      expect(await databaseService.getNote('live-1'), isNotNull);
    });

    test('getNoteMetadata returns null for the tombstoned note even when '
        'the row still has metadata set', () async {
      // Write metadata directly (bypassing updateNoteMetadata's own
      // __deleted__ = 0 guard, exercised separately below) so this test
      // isolates the read-path filter itself.
      final db = await databaseService.database;
      await db.update('notes', {
        'metadata': '{"markers":[{"id":"m1"}]}',
      }, where: "id = 'dead-1'");

      expect(await databaseService.getNoteMetadata('dead-1'), isNull);
      expect(await databaseService.getNoteMetadata('live-1'), isNull);
    });

    test('updateNoteMetadata does not write metadata for the tombstoned '
        'note', () async {
      await databaseService.updateNoteMetadata('dead-1', {
        'markers': [
          {'id': 'm1'},
        ],
      });

      final db = await databaseService.database;
      final row = await db.query(
        'notes',
        columns: ['metadata'],
        where: "id = 'dead-1'",
      );
      expect(
        row.single['metadata'],
        isNull,
        reason: 'updateNoteMetadata must not write to a tombstoned note',
      );
    });

    test('getNotesByIds excludes the tombstoned note', () async {
      final notes = await databaseService.getNotesByIds(['live-1', 'dead-1']);
      expect(notes.map((n) => n.id), ['live-1']);
    });

    test('searchNotes (LIKE fallback) excludes the tombstoned note', () async {
      final results = await databaseService.searchNotes('content for');
      expect(results.map((n) => n.id), contains('live-1'));
      expect(results.map((n) => n.id), isNot(contains('dead-1')));
    });

    test('searchNotesFTS excludes the tombstoned note', () async {
      final results = await databaseService.searchNotesFTS('content');
      expect(results.map((n) => n.id), contains('live-1'));
      expect(results.map((n) => n.id), isNot(contains('dead-1')));
    });

    test('getNotesByTag excludes a tombstoned note even when a note_tags '
        'row still references it (defense-in-depth: deleteNote already '
        'real-deletes note_tags, so this exercises the n.__deleted__ = 0 '
        'filter itself, not just the join)', () async {
      final db = await databaseService.database;
      final tagRow = await db.query(
        'tags',
        where: 'name = ?',
        whereArgs: ['shared-tag'],
      );
      // shared-tag was created (and tombstoned-note's own membership row
      // real-deleted) via the setUp's deleteNote('dead-1') call; re-attach
      // it directly to simulate a stray note_tags row surviving against a
      // tombstoned note (e.g. the recovery-merge residual documented in
      // recovery_merge_service.dart).
      await db.insert('note_tags', {
        'noteId': 'dead-1',
        'tagId': tagRow.single['id'],
      });

      final results = await databaseService.getNotesByTag('shared-tag');

      expect(results.map((n) => n.id), isNot(contains('dead-1')));
    });

    test(
      'validateConversationNotes treats a tombstoned note as missing',
      () async {
        await databaseService.insertConversation(_buildConversation('conv-1'));
        final db = await databaseService.database;
        // Insert the mapping directly (bypassing insertConversationNoteMapping's
        // own FK-safe path) since dead-1 is tombstoned, not really gone, so
        // the FK to notes(id) is still satisfied.
        await db.insert('conversation_note_mapping', {
          'conversationId': 'conv-1',
          'noteId': 'dead-1',
          'createdAt': 1000,
        });

        final missing = await databaseService.validateConversationNotes(
          'conv-1',
        );

        expect(missing, contains('dead-1'));
      },
    );

    test('getPinnedNotes/getArchivedNotes/getNotesByArchiveStatus exclude a '
        'tombstoned note even if pinned/archived', () async {
      // dead-1's note_tags/subnotes/attachments were already really
      // deleted by deleteNote in setUp, but the notes row itself (with
      // pinned/isArchived) is still there, tombstoned -- set both flags
      // directly to exercise every branch.
      final db = await databaseService.database;
      await db.update('notes', {
        'pinned': 1,
        'isArchived': 1,
      }, where: "id = 'dead-1'");

      expect(
        (await databaseService.getPinnedNotes()).map((n) => n.id),
        isNot(contains('dead-1')),
      );
      expect(
        (await databaseService.getArchivedNotes()).map((n) => n.id),
        isNot(contains('dead-1')),
      );
      expect(
        (await databaseService.getNotesByArchiveStatus(
          isArchived: true,
        )).map((n) => n.id),
        isNot(contains('dead-1')),
      );
      expect(
        (await databaseService.getNotesByArchiveStatus()).map((n) => n.id),
        isNot(contains('dead-1')),
      );
    });
  });
}
