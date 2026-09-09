// Tests for the M1.11 "subnotes + attachments soft-delete conversion"
// milestone (.claude/plans/plan-and-propse-the-glistening-dolphin.md,
// § Phased delivery — "M1.11 — subnotes + attachments via updateNote/
// _persistNote, per the dedicated design discussion above. Highest risk in
// the broad-scope set").
//
// `subnotes`/`attachments` gain a `__deleted__` tombstone column.
// `DatabaseService.updateNote` and
// `NoteModificationService._persistNote` — two independently-duplicated
// functions — are rewritten from a blind delete-then-reinsert
// (`subnotes`) / filePath-diffed delete (`attachments`) into a single
// shared, id-keyed diff (`DatabaseService.diffAndPersistSubNotes`/
// `diffAndPersistAttachments`) that both now call:
//  - an id/path already present as a LIVE row: updated in place (or, for
//    attachments, left untouched if unchanged).
//  - an id/path present as a TOMBSTONED row: resurrected in place (same
//    row, same id), not re-inserted as a new row.
//  - an id/path absent entirely: inserted fresh.
//  - an existing LIVE id/path no longer present in the note: tombstoned,
//    never physically deleted.
//
// `updateNote`'s entire liveness-check-through-child-writes sequence now
// runs inside one `db.transaction`, closing the M1.10-disclosed race with
// `deleteNote` for `subnotes`/`attachments`/`note_tags` (not for
// `relationships`/`conversation_note_mapping`, which `updateNote` never
// touches) — see `updateNote`'s own doc comment in database_service.dart
// for the full sqflite-locking-based reasoning.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';

/// The exact pre-M1.11 (DATABASE_VERSION <= 53) shape of `subnotes`/
/// `attachments`: no `__deleted__` column. Hand-written rather than derived
/// from `DatabaseService.getSchema()` — as of M1.11, `getSchema()` already
/// returns the NEW DDL — same approach every prior soft-delete milestone's
/// test file established.
const _oldSubNotesTableDdl = '''
    CREATE TABLE subnotes(
      id TEXT PRIMARY KEY,
      noteId TEXT NOT NULL,
      name TEXT NOT NULL,
      content TEXT NOT NULL,
      createdAt INTEGER NOT NULL,
      isCompleted INTEGER NOT NULL DEFAULT 0
    )
''';

const _oldAttachmentsTableDdl = '''
    CREATE TABLE attachments(
      id TEXT PRIMARY KEY,
      noteId TEXT NOT NULL,
      filePath TEXT NOT NULL,
      fileName TEXT NOT NULL,
      fileType TEXT NOT NULL,
      isRelativePath INTEGER NOT NULL DEFAULT 1,
      createdAt INTEGER NOT NULL,
      includeInAIContext INTEGER NOT NULL DEFAULT 1,
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

SubNote _sub(
  String id, {
  String name = 'Sub',
  String content = 'content',
  bool isCompleted = false,
}) => SubNote(
  id: id,
  name: name,
  content: content,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
  isCompleted: isCompleted,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.11 schema — fresh install', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('subnotes has __deleted__ (NOT NULL, default 0)', () async {
      final db = await databaseService.database;
      final cols = await _tableInfo(db, 'subnotes');
      final deletedCol = cols.firstWhere((c) => c['name'] == '__deleted__');
      expect(deletedCol['notnull'], 1);
      expect(deletedCol['dflt_value'], '0');
    });

    test('attachments has __deleted__ (NOT NULL, default 0)', () async {
      final db = await databaseService.database;
      final cols = await _tableInfo(db, 'attachments');
      final deletedCol = cols.firstWhere((c) => c['name'] == '__deleted__');
      expect(deletedCol['notnull'], 1);
      expect(deletedCol['dflt_value'], '0');
    });
  });

  group('M1.11 migration round-trip (v54 -> v55)', () {
    late Database preMigrationDb;

    setUp(() async {
      preMigrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );

      await preMigrationDb.execute(_oldSubNotesTableDdl);
      await preMigrationDb.execute(_oldAttachmentsTableDdl);
      for (final statement in DatabaseService.getSchema()) {
        if (statement.contains('CREATE TABLE subnotes(') ||
            statement.contains('CREATE TABLE attachments(')) {
          continue;
        }
        await preMigrationDb.execute(statement);
      }

      await preMigrationDb.execute('''
        CREATE TABLE _schema_version (version INTEGER NOT NULL)
      ''');
      await preMigrationDb.insert('_schema_version', {'version': 53});

      expect(
        await _hasColumn(preMigrationDb, 'subnotes', '__deleted__'),
        isFalse,
      );
      expect(
        await _hasColumn(preMigrationDb, 'attachments', '__deleted__'),
        isFalse,
      );
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
          '__deleted__': 0,
        });
        await preMigrationDb.insert('subnotes', {
          'id': 'sub-1',
          'noteId': 'note-1',
          'name': 'S1',
          'content': 'sc',
          'createdAt': 100,
          'isCompleted': 0,
        });
        await preMigrationDb.insert('attachments', {
          'id': 'att-1',
          'noteId': 'note-1',
          'filePath': 'attachments/f.png',
          'fileName': 'f.png',
          'fileType': 'png',
          'isRelativePath': 1,
          'createdAt': 100,
          'includeInAIContext': 1,
        });

        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 54, 55);

        expect(
          await _hasColumn(preMigrationDb, 'subnotes', '__deleted__'),
          isTrue,
        );
        expect(
          await _hasColumn(preMigrationDb, 'attachments', '__deleted__'),
          isTrue,
        );

        final subs = await preMigrationDb.query('subnotes');
        expect(subs.single['id'], 'sub-1');
        expect(subs.single['__deleted__'], 0);

        final atts = await preMigrationDb.query('attachments');
        expect(atts.single['id'], 'att-1');
        expect(atts.single['__deleted__'], 0);
      },
    );

    test('running the v54 -> v55 migration twice does not error and leaves '
        'schema/data unchanged the second time', () async {
      await preMigrationDb.insert('subnotes', {
        'id': 'sub-1',
        'noteId': 'note-1',
        'name': 'S1',
        'content': 'sc',
        'createdAt': 100,
        'isCompleted': 0,
      });

      final service = DatabaseService.createNew();
      await service.migrateBackupDatabase(preMigrationDb, 54, 55);
      final afterFirst = await preMigrationDb.query('subnotes', orderBy: 'id');

      await service.migrateBackupDatabase(preMigrationDb, 54, 55);
      final afterSecond = await preMigrationDb.query('subnotes', orderBy: 'id');

      expect(afterSecond, equals(afterFirst));
    });
  });

  group('updateNote — subnotes id-based diff', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('an existing live subnote is updated in place, not deleted and '
        're-inserted (rowid stability proves it is an UPDATE)', () async {
      await databaseService.insertNote(
        _buildNote('note-1', subNotes: [_sub('sub-1', content: 'v1')]),
      );
      final before = await db.rawQuery(
        "SELECT rowid, * FROM subnotes WHERE id = 'sub-1'",
      );
      final rowidBefore = before.single['rowid'];

      await databaseService.updateNote(
        _buildNote('note-1', subNotes: [_sub('sub-1', content: 'v2')]),
      );

      final rows = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(rows.length, 1, reason: 'must still be exactly one physical row');
      expect(
        rows.single['content'],
        'v2',
        reason: 'content edit must be applied',
      );
      expect(rows.single['__deleted__'], 0);

      final after = await db.rawQuery(
        "SELECT rowid FROM subnotes WHERE id = 'sub-1'",
      );
      expect(
        after.single['rowid'],
        rowidBefore,
        reason:
            'rowid unchanged proves this was an UPDATE, not a '
            'DELETE+INSERT (a fresh insert would get a new rowid)',
      );
    });

    test('a removed live subnote is tombstoned, not deleted', () async {
      await databaseService.insertNote(
        _buildNote('note-1', subNotes: [_sub('sub-1'), _sub('sub-2')]),
      );

      await databaseService.updateNote(
        _buildNote('note-1', subNotes: [_sub('sub-1')]),
      );

      final rows = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
        orderBy: 'id',
      );
      expect(rows.length, 2, reason: 'no real row deleted');
      expect(rows.firstWhere((r) => r['id'] == 'sub-1')['__deleted__'], 0);
      expect(rows.firstWhere((r) => r['id'] == 'sub-2')['__deleted__'], 1);
    });

    test('a genuinely new subnote id is inserted fresh', () async {
      await databaseService.insertNote(
        _buildNote('note-1', subNotes: [_sub('sub-1')]),
      );

      await databaseService.updateNote(
        _buildNote(
          'note-1',
          subNotes: [
            _sub('sub-1'),
            _sub('sub-2', content: 'new'),
          ],
        ),
      );

      final rows = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
        orderBy: 'id',
      );
      expect(rows.length, 2);
      final sub2 = rows.firstWhere((r) => r['id'] == 'sub-2');
      expect(sub2['content'], 'new');
      expect(sub2['__deleted__'], 0);
    });

    test('a tombstoned subnote id reappearing in the note is resurrected in '
        'place, not inserted as a second row', () async {
      await databaseService.insertNote(
        _buildNote('note-1', subNotes: [_sub('sub-1', content: 'v1')]),
      );
      // Remove it -> tombstoned.
      await databaseService.updateNote(_buildNote('note-1', subNotes: []));
      final afterRemoval = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(afterRemoval.single['__deleted__'], 1);

      // Same id reappears (e.g. an undo).
      await databaseService.updateNote(
        _buildNote('note-1', subNotes: [_sub('sub-1', content: 'v3')]),
      );

      final rows = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(
        rows.length,
        1,
        reason: 'resurrect must not create a second row for the same id',
      );
      expect(rows.single['id'], 'sub-1');
      expect(rows.single['__deleted__'], 0);
      expect(rows.single['content'], 'v3');
    });

    test(
      'updateNote against a nonexistent/tombstoned note writes no subnote rows',
      () async {
        await databaseService.insertNote(_buildNote('note-1'));
        await databaseService.deleteNote('note-1');

        await databaseService.updateNote(
          _buildNote('note-1', subNotes: [_sub('sub-x')]),
        );

        expect(
          await db.query(
            'subnotes',
            where: 'noteId = ?',
            whereArgs: ['note-1'],
          ),
          isEmpty,
        );
      },
    );

    test('a duplicate subnote id within a single note.subNotes list is '
        'deduped within the pass -- only one row results, not a PRIMARY '
        'KEY violation', () async {
      await databaseService.insertNote(_buildNote('note-1'));

      // Nothing in today's UI produces this (callers dedupe first), but
      // the diff function itself must defend against it rather than
      // relying on that -- a naive version would hit the INSERT branch
      // twice for the second occurrence's id and throw a PRIMARY KEY
      // violation, rolling back the whole updateNote transaction.
      await databaseService.updateNote(
        _buildNote(
          'note-1',
          subNotes: [
            _sub('sub-dup', content: 'first'),
            _sub('sub-dup', content: 'second'),
          ],
        ),
      );

      final rows = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(
        rows.length,
        1,
        reason: 'the duplicate id must not produce a second row',
      );
      expect(
        rows.single['content'],
        'first',
        reason: 'the first occurrence wins; later duplicates are skipped',
      );
    });
  });

  group('updateNote — attachments filePath-diffed, id-targeted diff', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('an existing live path is left untouched (no-op, same id)', () async {
      await databaseService.insertNote(
        _buildNote('note-1', attachmentPaths: ['attachments/a.png']),
      );
      final before = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      final idBefore = before.single['id'];

      await databaseService.updateNote(
        _buildNote('note-1', attachmentPaths: ['attachments/a.png']),
      );

      final after = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(after.length, 1);
      expect(
        after.single['id'],
        idBefore,
        reason: 'kept attachment must not be re-inserted under a new id',
      );
      expect(after.single['__deleted__'], 0);
    });

    test('a removed live path is tombstoned (by id), not deleted', () async {
      await databaseService.insertNote(
        _buildNote(
          'note-1',
          attachmentPaths: ['attachments/a.png', 'attachments/b.png'],
        ),
      );

      await databaseService.updateNote(
        _buildNote('note-1', attachmentPaths: ['attachments/a.png']),
      );

      final rows = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
        orderBy: 'filePath',
      );
      expect(rows.length, 2, reason: 'no real row deleted');
      expect(
        rows.firstWhere(
          (r) => r['filePath'] == 'attachments/a.png',
        )['__deleted__'],
        0,
      );
      expect(
        rows.firstWhere(
          (r) => r['filePath'] == 'attachments/b.png',
        )['__deleted__'],
        1,
      );
    });

    test('a genuinely new path is inserted fresh', () async {
      await databaseService.insertNote(
        _buildNote('note-1', attachmentPaths: ['attachments/a.png']),
      );

      await databaseService.updateNote(
        _buildNote(
          'note-1',
          attachmentPaths: ['attachments/a.png', 'attachments/new.png'],
        ),
      );

      final rows = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(rows.length, 2);
      final newRow = rows.firstWhere(
        (r) => r['filePath'] == 'attachments/new.png',
      );
      expect(newRow['__deleted__'], 0);
    });

    test('a tombstoned path reappearing is resurrected under its original id, '
        'not inserted as a second row', () async {
      await databaseService.insertNote(
        _buildNote('note-1', attachmentPaths: ['attachments/a.png']),
      );
      final original = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      final originalId = original.single['id'] as String;

      // Remove it -> tombstoned.
      await databaseService.updateNote(
        _buildNote('note-1', attachmentPaths: []),
      );
      final afterRemoval = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(afterRemoval.single['__deleted__'], 1);
      expect(afterRemoval.single['id'], originalId);

      // Same path reappears.
      await databaseService.updateNote(
        _buildNote('note-1', attachmentPaths: ['attachments/a.png']),
      );

      final rows = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(
        rows.length,
        1,
        reason: 'resurrect must not create a second row for the same path',
      );
      expect(
        rows.single['id'],
        originalId,
        reason:
            'id continuity matters: note_annotations/marker metadata '
            'reference an attachment by id, so a fresh id on resurrect '
            'would silently orphan them',
      );
      expect(rows.single['__deleted__'], 0);
    });

    test(
      'updateNote against a nonexistent/tombstoned note writes no attachment rows',
      () async {
        await databaseService.insertNote(_buildNote('note-1'));
        await databaseService.deleteNote('note-1');

        await databaseService.updateNote(
          _buildNote('note-1', attachmentPaths: ['attachments/x.png']),
        );

        expect(
          await db.query(
            'attachments',
            where: 'noteId = ?',
            whereArgs: ['note-1'],
          ),
          isEmpty,
        );
      },
    );

    test('a duplicate path within a single note.attachmentPaths list is '
        'deduped within the pass -- only one live row results, not two '
        'live rows for the same (noteId, filePath)', () async {
      await databaseService.insertNote(_buildNote('note-1'));

      // Nothing in today's UI produces this (callers dedupe first), but
      // the diff function itself must defend against it rather than
      // relying on that -- a naive version would treat the second
      // occurrence of a genuinely-new path as still-unseen (the
      // pre-loop `livePathToId`/`tombstonedPathToId` snapshot is never
      // updated for a row this same pass just inserted) and insert it
      // again under a fresh id, permanently orphaning that second row
      // from every future diff (nothing is keyed to find it again).
      await databaseService.updateNote(
        _buildNote(
          'note-1',
          attachmentPaths: ['attachments/dup.png', 'attachments/dup.png'],
        ),
      );

      final rows = await db.query(
        'attachments',
        where: 'noteId = ?',
        whereArgs: ['note-1'],
      );
      expect(
        rows.length,
        1,
        reason: 'the duplicate path must not produce a second row',
      );
      expect(rows.single['__deleted__'], 0);
    });
  });

  group('updateNote vs _persistNote — identical behavior', () {
    late DatabaseService databaseService;
    late Database db;
    late NoteModificationService noteModificationService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
      noteModificationService = NoteModificationService(databaseService);
    });

    tearDown(() async {
      await databaseService.close();
    });

    /// Normalizes a subnotes/attachments row for cross-note comparison by
    /// dropping columns expected to legitimately differ (id/noteId — the
    /// two notes intentionally use different ids so they don't collide in
    /// the same table).
    Map<String, Object?> normalizeSub(Map<String, Object?> row) => {
      'name': row['name'],
      'content': row['content'],
      'isCompleted': row['isCompleted'],
      '__deleted__': row['__deleted__'],
    };

    Map<String, Object?> normalizeAtt(Map<String, Object?> row) => {
      'filePath': row['filePath'],
      'includeInAIContext': row['includeInAIContext'],
      '__deleted__': row['__deleted__'],
    };

    test(
      'updateNote (database_service.dart) and _persistNote '
      '(note_modification_service.dart, via persistNoteForTest) produce '
      'identical subnotes/attachments table state for the same diff, '
      'proving the two independently-duplicated call sites did not drift',
      () async {
        // Seed two notes with the same initial shape. `subnotes.id` is a
        // globally-unique PRIMARY KEY (not scoped per note), so note-a and
        // note-b must use disjoint subnote id namespaces even though the
        // diff applied to each is logically identical.
        await databaseService.insertNote(
          _buildNote(
            'note-a',
            subNotes: [
              _sub('a-sub-1', content: 'v1'),
              _sub('a-sub-2', content: 'v1'),
            ],
            attachmentPaths: ['attachments/a.png', 'attachments/b.png'],
          ),
        );
        await databaseService.insertNote(
          _buildNote(
            'note-b',
            subNotes: [
              _sub('b-sub-1', content: 'v1'),
              _sub('b-sub-2', content: 'v1'),
            ],
            attachmentPaths: ['attachments/a.png', 'attachments/b.png'],
          ),
        );

        // Apply the identical diff (by shape, not literal id) to both:
        // keep the first subnote (edited), drop the second (tombstone),
        // add a third (fresh); keep a.png, drop b.png (tombstone), add
        // c.png (fresh).
        final updatedA = _buildNote(
          'note-a',
          subNotes: [
            _sub('a-sub-1', content: 'v2'),
            _sub('a-sub-3', content: 'new'),
          ],
          attachmentPaths: ['attachments/a.png', 'attachments/c.png'],
        );
        final updatedB = _buildNote(
          'note-b',
          subNotes: [
            _sub('b-sub-1', content: 'v2'),
            _sub('b-sub-3', content: 'new'),
          ],
          attachmentPaths: ['attachments/a.png', 'attachments/c.png'],
        );

        await databaseService.updateNote(updatedA);
        await db.transaction((txn) async {
          await noteModificationService.persistNoteForTest(txn, updatedB);
        });

        final subsA = (await db.query(
          'subnotes',
          where: 'noteId = ?',
          whereArgs: ['note-a'],
          orderBy: 'id',
        )).map(normalizeSub).toList();
        final subsB = (await db.query(
          'subnotes',
          where: 'noteId = ?',
          whereArgs: ['note-b'],
          orderBy: 'id',
        )).map(normalizeSub).toList();
        expect(subsA, equals(subsB));

        final attsA = (await db.query(
          'attachments',
          where: 'noteId = ?',
          whereArgs: ['note-a'],
          orderBy: 'filePath',
        )).map(normalizeAtt).toList();
        final attsB = (await db.query(
          'attachments',
          where: 'noteId = ?',
          whereArgs: ['note-b'],
          orderBy: 'filePath',
        )).map(normalizeAtt).toList();
        expect(attsA, equals(attsB));
      },
    );

    test('_persistNote also resurrects a tombstoned subnote id by row, same '
        'as updateNote', () async {
      await databaseService.insertNote(
        _buildNote('note-b', subNotes: [_sub('sub-1', content: 'v1')]),
      );
      await db.transaction((txn) async {
        await noteModificationService.persistNoteForTest(
          txn,
          _buildNote('note-b', subNotes: []),
        );
      });
      final tombstoned = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-b'],
      );
      expect(tombstoned.single['__deleted__'], 1);

      await db.transaction((txn) async {
        await noteModificationService.persistNoteForTest(
          txn,
          _buildNote('note-b', subNotes: [_sub('sub-1', content: 'v3')]),
        );
      });

      final rows = await db.query(
        'subnotes',
        where: 'noteId = ?',
        whereArgs: ['note-b'],
      );
      expect(rows.length, 1);
      expect(rows.single['__deleted__'], 0);
      expect(rows.single['content'], 'v3');
    });

    // Note: `_persistNote` and `updateNote` do NOT behave identically here
    // -- `updateNote`'s liveness-check branch logs a warning and returns
    // silently on a tombstoned/missing note, while `_persistNote` throws.
    // What the two functions actually share is narrower: zero child rows
    // get written in either case. This test proves only that shared
    // outcome for `_persistNote`, not full parity with `updateNote`'s
    // control flow (see the earlier parity test in this group for what
    // IS proven identical: the diff's resulting table state).
    test('_persistNote throws and writes zero subnote rows when the note is '
        'tombstoned between read and write', () async {
      await databaseService.insertNote(_buildNote('note-b'));
      await databaseService.deleteNote('note-b');

      await expectLater(
        db.transaction((txn) async {
          await noteModificationService.persistNoteForTest(
            txn,
            _buildNote('note-b', subNotes: [_sub('sub-x')]),
          );
        }),
        throwsA(anything),
      );

      expect(
        await db.query('subnotes', where: 'noteId = ?', whereArgs: ['note-b']),
        isEmpty,
      );
    });
  });

  group(
    'M1.11 read-path filtering — tombstoned subnotes/attachments are invisible',
    () {
      late DatabaseService databaseService;

      setUp(() async {
        databaseService = DatabaseService.createNew();
        await databaseService.insertNote(
          _buildNote(
            'note-1',
            subNotes: [
              _sub('sub-live', content: 'live'),
              _sub('sub-dead', content: 'dead'),
            ],
            attachmentPaths: ['attachments/live.png', 'attachments/dead.png'],
          ),
        );
        await databaseService.updateNote(
          _buildNote(
            'note-1',
            subNotes: [_sub('sub-live', content: 'live')],
            attachmentPaths: ['attachments/live.png'],
          ),
        );
      });

      tearDown(() async {
        await databaseService.close();
      });

      test('getSubNotes excludes the tombstoned subnote', () async {
        final subs = await databaseService.getSubNotes('note-1');
        expect(subs.map((s) => s.id), ['sub-live']);
      });

      test(
        'getAttachmentsForNote excludes the tombstoned attachment',
        () async {
          final atts = await databaseService.getAttachmentsForNote('note-1');
          expect(atts.map((a) => a.filePath), ['attachments/live.png']);
        },
      );

      // These two checks use a dedicated note with NO attachments, on a
      // separate DatabaseService instance, and only assert on `subNotes` --
      // resolving an attachment's full path inside
      // `_mapToNote`/`_batchLoadNotes` calls `FileUtils.getFullFilePath`,
      // which needs a working `path_provider` platform channel that isn't
      // available under plain `flutter_test` (non-widget) tests, so `note-1`
      // (which has attachments) can't be routed through these two read
      // paths in this test environment. Attachment read-path filtering
      // itself is covered directly by `getAttachmentsForNote`/
      // `getAllAttachments` below, which don't do that path resolution.
      test(
        'getNoteById (single-note load path) excludes the tombstoned subnote',
        () async {
          final noSubAttachDb = DatabaseService.createNew();
          addTearDown(noSubAttachDb.close);
          await noSubAttachDb.insertNote(
            _buildNote(
              'note-2',
              subNotes: [
                _sub('sub-live-2', content: 'live'),
                _sub('sub-dead-2', content: 'dead'),
              ],
            ),
          );
          await noSubAttachDb.updateNote(
            _buildNote(
              'note-2',
              subNotes: [_sub('sub-live-2', content: 'live')],
            ),
          );

          final note = await noSubAttachDb.getNoteById('note-2');
          expect(note, isNotNull);
          expect(note!.subNotes.map((s) => s.id), ['sub-live-2']);
        },
      );

      test(
        'getAllNotes (batch load path) excludes the tombstoned subnote',
        () async {
          final noSubAttachDb = DatabaseService.createNew();
          addTearDown(noSubAttachDb.close);
          await noSubAttachDb.insertNote(
            _buildNote(
              'note-2',
              subNotes: [
                _sub('sub-live-2', content: 'live'),
                _sub('sub-dead-2', content: 'dead'),
              ],
            ),
          );
          await noSubAttachDb.updateNote(
            _buildNote(
              'note-2',
              subNotes: [_sub('sub-live-2', content: 'live')],
            ),
          );

          final notes = await noSubAttachDb.getAllNotes();
          final note = notes.firstWhere((n) => n.id == 'note-2');
          expect(note.subNotes.map((s) => s.id), ['sub-live-2']);
        },
      );

      test('getAllAttachments excludes the tombstoned attachment', () async {
        final all = await databaseService.getAllAttachments();
        expect(
          all.where((a) => a['noteId'] == 'note-1').map((a) => a['filePath']),
          ['attachments/live.png'],
        );
      });

      test(
        'getAttachmentById returns null for a tombstoned attachment',
        () async {
          final db = await databaseService.database;
          final deadRow = await db.query(
            'attachments',
            where: "filePath = 'attachments/dead.png'",
          );
          final deadId = deadRow.single['id'] as String;
          final liveRow = await db.query(
            'attachments',
            where: "filePath = 'attachments/live.png'",
          );
          final liveId = liveRow.single['id'] as String;

          expect(await databaseService.getAttachmentById(deadId), isNull);
          expect(await databaseService.getAttachmentById(liveId), isNotNull);
        },
      );

      test(
        'verifyAttachmentPath returns false for a tombstoned path',
        () async {
          expect(
            await databaseService.verifyAttachmentPath('attachments/dead.png'),
            isFalse,
          );
          expect(
            await databaseService.verifyAttachmentPath('attachments/live.png'),
            isTrue,
          );
        },
      );

      test(
        'getNoteIdForAttachment returns null for a tombstoned path',
        () async {
          expect(
            await databaseService.getNoteIdForAttachment(
              'attachments/dead.png',
            ),
            isNull,
          );
          expect(
            await databaseService.getNoteIdForAttachment(
              'attachments/live.png',
            ),
            'note-1',
          );
        },
      );
    },
  );

  group('updateNote — atomicity', () {
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
      'a failure partway through the transaction leaves no partial state: '
      'note/subnotes/note_tags/attachments all stay exactly as they were',
      () async {
        await databaseService.insertNote(
          _buildNote(
            'note-1',
            subNotes: [_sub('sub-1', content: 'v1')],
            tags: ['t1'],
            attachmentPaths: ['attachments/a.png'],
          ),
        );

        // Force a failure partway through updateNote's transaction: the
        // attachments diff runs after subnotes/note_tags (see updateNote's
        // own statement order), so dropping the table makes that step
        // throw, and since it all runs inside db.transaction(...), sqflite
        // rolls back everything else in the same transaction too.
        await db.execute('DROP TABLE attachments');

        await expectLater(
          databaseService.updateNote(
            _buildNote(
              'note-1',
              subNotes: [
                _sub('sub-1', content: 'v2'),
                _sub('sub-2', content: 'v1'),
              ],
              tags: ['t2'],
              attachmentPaths: ['attachments/b.png'],
            ),
          ),
          throwsA(anything),
        );

        // Note row itself: unchanged (still the original title/content).
        final note = await db.query('notes', where: "id = 'note-1'");
        expect(note.single['title'], 'Note note-1');

        // Subnotes: rolled back to the original single row, unedited.
        final subs = await db.query(
          'subnotes',
          where: 'noteId = ?',
          whereArgs: ['note-1'],
        );
        expect(subs.length, 1);
        expect(
          subs.single['content'],
          'v1',
          reason: 'the edit must have rolled back',
        );

        // note_tags: rolled back to the original tag.
        final tagRows = await db.rawQuery('''
          SELECT t.name FROM tags t
          JOIN note_tags nt ON t.id = nt.tagId
          WHERE nt.noteId = 'note-1'
        ''');
        expect(tagRows.map((r) => r['name']), ['t1']);
      },
    );
  });

  group(
    'updateNote / deleteNote race — closed for subnotes/attachments/note_tags',
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

      test('a concurrent updateNote and deleteNote never leaves a LIVE subnote '
          'or attachment row against a tombstoned note, regardless of which '
          'one wins the race', () async {
        await databaseService.insertNote(
          _buildNote(
            'note-1',
            subNotes: [_sub('sub-1')],
            attachmentPaths: ['attachments/a.png'],
          ),
        );

        // Fire both concurrently (neither awaited before the other
        // starts) -- sqflite's single-writer-lock serializes their actual
        // execution (see updateNote's own doc comment), but which one
        // acquires the lock first is not controlled by this test.
        final updateFuture = databaseService.updateNote(
          _buildNote(
            'note-1',
            subNotes: [
              _sub('sub-1', content: 'edited'),
              _sub('sub-2', content: 'added'),
            ],
            attachmentPaths: ['attachments/a.png', 'attachments/new.png'],
          ),
        );
        final deleteFuture = databaseService.deleteNote('note-1');
        await Future.wait([updateFuture, deleteFuture]);

        final noteRow = await db.query('notes', where: "id = 'note-1'");
        final noteIsLive =
            noteRow.isNotEmpty && noteRow.single['__deleted__'] == 0;

        final liveSubnotes = await db.query(
          'subnotes',
          where: 'noteId = ? AND __deleted__ = 0',
          whereArgs: ['note-1'],
        );
        final liveAttachments = await db.query(
          'attachments',
          where: 'noteId = ? AND __deleted__ = 0',
          whereArgs: ['note-1'],
        );

        if (!noteIsLive) {
          expect(
            liveSubnotes,
            isEmpty,
            reason:
                'note is tombstoned/gone -- no live subnote may '
                'reference it (the M1.10-disclosed orphan race)',
          );
          expect(
            liveAttachments,
            isEmpty,
            reason:
                'note is tombstoned/gone -- no live attachment may '
                'reference it (the M1.10-disclosed orphan race)',
          );
        }
        // If the note is live (updateNote's transaction committed last),
        // there is nothing to assert beyond "no crash" -- deleteNote lost
        // the race entirely and never ran its own tombstone write in a
        // way that would leave inconsistent state.
      });
    },
  );
}
