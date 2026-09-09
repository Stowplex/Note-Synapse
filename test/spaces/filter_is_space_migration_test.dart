import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// The filters table exactly as v46 shipped it: no isSpace column.
const String _v46FiltersTable = '''
  CREATE TABLE filters(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    includeText TEXT,
    includeTags TEXT NOT NULL,
    excludeTags TEXT NOT NULL DEFAULT '',
    noteTypes TEXT NOT NULL DEFAULT '',
    includeArchived INTEGER NOT NULL DEFAULT 0,
    isPinned INTEGER NOT NULL DEFAULT 0,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL
  )
''';

const String _tagsTable = '''
  CREATE TABLE tags(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    color TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    usageCount INTEGER NOT NULL DEFAULT 0
  )
''';

const String _notesTable = '''
  CREATE TABLE notes(
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    type TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    pinned INTEGER NOT NULL DEFAULT 0,
    isArchived INTEGER NOT NULL DEFAULT 0
  )
''';

const String _noteTagsTable = '''
  CREATE TABLE note_tags(
    noteId TEXT NOT NULL,
    tagId TEXT NOT NULL,
    PRIMARY KEY (noteId, tagId),
    FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
    FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
  )
''';

String _uniqueName() => 'spaces_migration_${const Uuid().v4()}.db';

Future<void> _insertNote(Database db, String id) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.insert('notes', {
    'id': id,
    'title': 'Note $id',
    'content': 'body',
    'type': 'note',
    'createdAt': now,
    'updatedAt': now,
  });
}

Future<void> _insertTag(Database db, String id, String name) async {
  await db.insert('tags', {
    'id': id,
    'name': name,
    'color': '#2196F3',
    'createdAt': DateTime.now().millisecondsSinceEpoch,
    'usageCount': 0,
  });
}

/// Builds a database file that looks exactly like a v46 install: the v46
/// filters table, `_schema_version` = 46, and `user_version` = the sentinel
/// every real Note Synapse database carries.
Future<Database> _openRawV46(String dbName) async {
  final path = p.join(await databaseFactory.getDatabasesPath(), dbName);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute(
    'PRAGMA user_version = ${DatabaseService.SQFLITE_VERSION}',
  );
  await db.execute('CREATE TABLE _schema_version (version INTEGER NOT NULL)');
  await db.insert('_schema_version', {'version': 46});
  await db.execute(_v46FiltersTable);
  await db.execute(_tagsTable);
  await db.execute(_notesTable);
  await db.execute(_noteTagsTable);
  return db;
}

Future<List<String>> _columnsOf(Database db, String table) async {
  final cols = await db.rawQuery("PRAGMA table_info('$table')");
  return cols.map((c) => c['name'] as String).toList();
}

Future<int> _schemaVersionOf(Database db) async {
  final rows = await db.query('_schema_version');
  return rows.first['version'] as int;
}

/// Note ids linked to the tag named [tagName].
Future<List<String>> _notesWithTag(Database db, String tagName) async {
  final rows = await db.rawQuery(
    '''
    SELECT nt.noteId AS noteId FROM note_tags nt
    JOIN tags t ON t.id = nt.tagId
    WHERE t.name = ?
    ORDER BY nt.noteId
    ''',
    [tagName],
  );
  return rows.map((r) => r['noteId'] as String).toList();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('DATABASE_VERSION is 47', () {
    expect(DatabaseService.DATABASE_VERSION, 47);
  });

  // getSchema() is the DDL DatabaseService exports about itself. It is what
  // the schema viewer shows (database_manager_tab.dart:185), what the AI is
  // told the tables look like (user_app_service.dart:721, note_tools.dart:654)
  // and what test/services/note_modification_service_test.dart:47 builds its
  // in-memory database from. It is *not* how recovery gets the column:
  // recovery copies the live database file byte-for-byte into staging
  // (recovery_screen.dart:482-494) and never calls getSchema().
  test('the exported schema declares isSpace', () {
    final filtersDdl = DatabaseService.getSchema().firstWhere(
      (s) => s.contains('CREATE TABLE filters('),
    );
    expect(filtersDdl, contains('isSpace INTEGER NOT NULL DEFAULT 0'));
  });

  test('a fresh database has the isSpace column at version 47', () async {
    final service = DatabaseService.createNew();
    final db = await service.database;

    expect(await _columnsOf(db, 'filters'), contains('isSpace'));
    expect(await _schemaVersionOf(db), 47);

    await service.close();
  });

  test('a v46 database is at 46, migrates to 47 and gains the column', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    expect(await _columnsOf(raw, 'filters'), isNot(contains('isSpace')));
    expect(await _schemaVersionOf(raw), 46);
    await raw.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final db = await service.database;

    expect(await _columnsOf(db, 'filters'), contains('isSpace'));
    expect(await _schemaVersionOf(db), 47);

    await service.close();
  });

  test('a pre-v47 filter row reads back with isSpace false', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    final now = DateTime.now().millisecondsSinceEpoch;
    await raw.insert('filters', {
      'id': 'f-old',
      'name': 'Legacy',
      'includeText': null,
      'includeTags': 'work',
      'excludeTags': '',
      'noteTypes': 'note,task',
      'includeArchived': 0,
      'isPinned': 1,
      'createdAt': now,
      'updatedAt': now,
    });
    await raw.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final filters = await service.getAllFilters();

    expect(filters, hasLength(1));
    expect(filters.single.isSpace, isFalse);
    // The existing role flag is untouched by the migration.
    expect(filters.single.isPinned, isTrue);

    await service.close();
  });

  test('getAllFilters and getFilter round-trip isSpace both ways', () async {
    final service = DatabaseService.createNew();
    final now = DateTime.now();

    await service.insertFilter(
      Filter(
        id: 'space-1',
        name: 'Thesis',
        includeTags: const ['thesis'],
        isSpace: true,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await service.insertFilter(
      Filter(
        id: 'plain-1',
        name: 'Reading',
        includeTags: const ['reading'],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final byId = {for (final f in await service.getAllFilters()) f.id: f};
    expect(byId['space-1']!.isSpace, isTrue);
    expect(byId['plain-1']!.isSpace, isFalse);
    expect((await service.getFilter('space-1'))!.isSpace, isTrue);
    expect((await service.getFilter('plain-1'))!.isSpace, isFalse);

    // updateFilter carries the flag in both directions.
    await service.updateFilter(byId['plain-1']!.copyWith(isSpace: true));
    await service.updateFilter(byId['space-1']!.copyWith(isSpace: false));

    final after = {for (final f in await service.getAllFilters()) f.id: f};
    expect(after['plain-1']!.isSpace, isTrue);
    expect(after['space-1']!.isSpace, isFalse);

    await service.close();
  });

  test('every agent-skill note carries all-spaces after migration', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    await _insertTag(raw, 'tag-skill', 'agent-skill');
    await _insertTag(raw, 'tag-other', 'work');
    await _insertNote(raw, 'skill-1');
    await _insertNote(raw, 'skill-2');
    await _insertNote(raw, 'plain-1');
    await raw.insert('note_tags', {'noteId': 'skill-1', 'tagId': 'tag-skill'});
    await raw.insert('note_tags', {'noteId': 'skill-2', 'tagId': 'tag-skill'});
    await raw.insert('note_tags', {'noteId': 'skill-2', 'tagId': 'tag-other'});
    await raw.insert('note_tags', {'noteId': 'plain-1', 'tagId': 'tag-other'});
    await raw.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final db = await service.database;

    expect(await _notesWithTag(db, SpaceScopeService.allSpacesTag), [
      'skill-1',
      'skill-2',
    ]);
    // Existing links are left alone.
    expect(await _notesWithTag(db, 'work'), ['plain-1', 'skill-2']);

    await service.close();
  });

  test('the all-spaces tag row is created when absent', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    await _insertTag(raw, 'tag-skill', 'agent-skill');
    await _insertNote(raw, 'skill-1');
    await raw.insert('note_tags', {'noteId': 'skill-1', 'tagId': 'tag-skill'});
    await raw.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final db = await service.database;

    final rows = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [SpaceScopeService.allSpacesTag],
    );
    expect(rows, hasLength(1));
    // Shaped like _getOrCreateTagId creates tags.
    expect(rows.single['color'], '#2196F3');
    expect(rows.single['usageCount'], 0);
    expect(rows.single['id'], isNotEmpty);

    await service.close();
  });

  test('an existing all-spaces tag row is reused, not duplicated', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    await _insertTag(raw, 'tag-skill', 'agent-skill');
    await _insertTag(raw, 'tag-all', SpaceScopeService.allSpacesTag);
    await _insertNote(raw, 'skill-1');
    await _insertNote(raw, 'note-1');
    await raw.insert('note_tags', {'noteId': 'skill-1', 'tagId': 'tag-skill'});
    // Someone already tagged an ordinary note all-spaces by hand.
    await raw.insert('note_tags', {'noteId': 'note-1', 'tagId': 'tag-all'});
    await raw.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final db = await service.database;

    final rows = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [SpaceScopeService.allSpacesTag],
    );
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'tag-all');
    expect(await _notesWithTag(db, SpaceScopeService.allSpacesTag), [
      'note-1',
      'skill-1',
    ]);

    await service.close();
  });

  test('a note already tagged all-spaces is not duplicated', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    await _insertTag(raw, 'tag-skill', 'agent-skill');
    await _insertTag(raw, 'tag-all', SpaceScopeService.allSpacesTag);
    await _insertNote(raw, 'skill-1');
    await raw.insert('note_tags', {'noteId': 'skill-1', 'tagId': 'tag-skill'});
    await raw.insert('note_tags', {'noteId': 'skill-1', 'tagId': 'tag-all'});
    await raw.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final db = await service.database;

    final links = await db.query(
      'note_tags',
      where: 'noteId = ? AND tagId = ?',
      whereArgs: ['skill-1', 'tag-all'],
    );
    expect(links, hasLength(1));

    await service.close();
  });

  test('a database with no skills still gets the all-spaces tag', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    await _insertNote(raw, 'plain-1');
    await raw.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final db = await service.database;

    final rows = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [SpaceScopeService.allSpacesTag],
    );
    expect(rows, hasLength(1));
    expect(await _notesWithTag(db, SpaceScopeService.allSpacesTag), isEmpty);

    await service.close();
  });

  test('re-running the migration on a migrated database is a no-op', () async {
    final dbName = _uniqueName();
    final raw = await _openRawV46(dbName);
    await _insertTag(raw, 'tag-skill', 'agent-skill');
    await _insertNote(raw, 'skill-1');
    await raw.insert('note_tags', {'noteId': 'skill-1', 'tagId': 'tag-skill'});
    await raw.close();

    final first = DatabaseService.createNew(databaseName: dbName);
    final firstDb = await first.database;
    final tagsAfterFirst = await firstDb.query('tags');
    final linksAfterFirst = await firstDb.query('note_tags');
    // Rewind the recorded version so opening again replays migration 47.
    await firstDb.update('_schema_version', {'version': 46});
    await first.close();

    final second = DatabaseService.createNew(databaseName: dbName);
    final secondDb = await second.database;

    expect(await _columnsOf(secondDb, 'filters'), contains('isSpace'));
    expect(await _schemaVersionOf(secondDb), 47);
    expect(await secondDb.query('tags'), tagsAfterFirst);
    expect(await secondDb.query('note_tags'), linksAfterFirst);

    await second.close();
  });

  test('the backup migration path adds the column and the tags', () async {
    final dbName = _uniqueName();
    final backup = await _openRawV46(dbName);
    await _insertTag(backup, 'tag-skill', 'agent-skill');
    await _insertNote(backup, 'skill-1');
    await backup.insert('note_tags', {
      'noteId': 'skill-1',
      'tagId': 'tag-skill',
    });

    // migrateBackupDatabase runs the same steps with isBackupMigration: true,
    // against a connection that is not the service's own database.
    final service = DatabaseService.createNew();
    await service.migrateBackupDatabase(backup, 46, 47);

    expect(await _columnsOf(backup, 'filters'), contains('isSpace'));
    expect(await _notesWithTag(backup, SpaceScopeService.allSpacesTag), [
      'skill-1',
    ]);

    // And it is idempotent there too.
    await service.migrateBackupDatabase(backup, 46, 47);
    expect(
      await backup.query(
        'tags',
        where: 'name = ?',
        whereArgs: [SpaceScopeService.allSpacesTag],
      ),
      hasLength(1),
    );

    await backup.close();
    await service.close();
  });

  test('_detectActualSchemaVersion recognises v47 by the isSpace column',
      () async {
    final dbName = _uniqueName();

    // A fully migrated v47 database whose recorded version was corrupted to
    // the sentinel. The probe must answer 47, so no migration is replayed.
    final seed = DatabaseService.createNew(databaseName: dbName);
    final seedDb = await seed.database;
    await _insertTag(seedDb, 'tag-skill', 'agent-skill');
    await _insertNote(seedDb, 'skill-1');
    await seedDb.insert('note_tags', {
      'noteId': 'skill-1',
      'tagId': 'tag-skill',
    });
    await seedDb.update('_schema_version', {
      'version': DatabaseService.SQFLITE_VERSION,
    });
    await seed.close();

    final service = DatabaseService.createNew(databaseName: dbName);
    final db = await service.database;

    expect(await _schemaVersionOf(db), 47);
    // Detection stopped at 47, so the v47 data step did not run again: the
    // skill note was never given all-spaces.
    expect(await _notesWithTag(db, SpaceScopeService.allSpacesTag), isEmpty);

    await service.close();
  });

  group('recovery restores the back-fill', () {
    // Every database mints the all-spaces tag on its own: the live one when it
    // upgrades, and every backup when RecoveryScreen migrates it. Recovery
    // then merges the two by *name* (_mergeTags, recovery_screen.dart:902) and
    // afterwards inserts the backup's note_tags rows *verbatim*, with no id
    // remap (_mergeNoteTags, :971; call order :593 then :602). Staging is a
    // byte-for-byte copy of the live file opened with a plain openDatabase
    // (:482-494), so foreign keys are off and a dangling row inserts silently.
    //
    // A random per-database uuid would therefore leave a restored skill note
    // pointing at a tag id that exists in no tags row: it would lose
    // all-spaces and be hidden in every Space. A fixed id makes both sides
    // id-equal, so the merge is a no-op. These tests pin that.

    /// A v46 database holding one agent-skill note, opened once through
    /// [DatabaseService] so migration 47 runs, then closed. [skillTagId]
    /// differs between the two databases on purpose — two independent installs
    /// mint their own ordinary tag ids.
    Future<String> buildMigratedSkillDb({
      required String noteId,
      required String skillTagId,
    }) async {
      final dbName = _uniqueName();
      final raw = await _openRawV46(dbName);
      await _insertTag(raw, skillTagId, 'agent-skill');
      await _insertNote(raw, noteId);
      await raw.insert('note_tags', {'noteId': noteId, 'tagId': skillTagId});
      await raw.close();

      final service = DatabaseService.createNew(databaseName: dbName);
      await service.database; // runs migration 47
      final path = await service.getDatabasePath();
      await service.close();
      return path;
    }

    Future<String> allSpacesTagIdOf(Database db) async {
      final rows = await db.query(
        'tags',
        where: 'name = ?',
        whereArgs: [SpaceScopeService.allSpacesTag],
      );
      expect(rows, hasLength(1));
      return rows.single['id'] as String;
    }

    Future<Database> openLikeRecovery(String path) => databaseFactory
        .openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));

    /// Reproduces recovery's merge semantics for the three tables that matter
    /// here, in the order recovery applies them.
    Future<void> mergeLikeRecovery(Database staging, Database backup) async {
      // _mergeNotes: insert notes staging does not have.
      for (final note in await backup.query('notes')) {
        final existing = await staging.query(
          'notes',
          where: 'id = ?',
          whereArgs: [note['id']],
        );
        if (existing.isEmpty) await staging.insert('notes', note);
      }

      // _mergeTags: match on name. When staging already has the tag under a
      // different id, only the note_tags rows *already in staging* are remapped.
      for (final tag in await backup.query('tags')) {
        final existing = await staging.query(
          'tags',
          where: 'name = ?',
          whereArgs: [tag['name']],
        );
        if (existing.isEmpty) {
          await staging.insert('tags', tag);
          continue;
        }
        final existingId = existing.first['id'] as String;
        final backupId = tag['id'] as String;
        if (existingId != backupId) {
          await staging.update(
            'note_tags',
            {'tagId': existingId},
            where: 'tagId = ?',
            whereArgs: [backupId],
          );
        }
      }

      // _mergeNoteTags: the backup's rows go in verbatim, id and all.
      for (final noteTag in await backup.query('note_tags')) {
        final existing = await staging.query(
          'note_tags',
          where: 'noteId = ? AND tagId = ?',
          whereArgs: [noteTag['noteId'], noteTag['tagId']],
        );
        if (existing.isEmpty) await staging.insert('note_tags', noteTag);
      }
    }

    test('two independently migrated databases mint the same tag id', () async {
      final livePath = await buildMigratedSkillDb(
        noteId: 'skill-live',
        skillTagId: 'skill-tag-live',
      );
      final backupPath = await buildMigratedSkillDb(
        noteId: 'skill-backup',
        skillTagId: 'skill-tag-backup',
      );

      final live = await openLikeRecovery(livePath);
      final backup = await openLikeRecovery(backupPath);

      expect(await allSpacesTagIdOf(live), await allSpacesTagIdOf(backup));

      await live.close();
      await backup.close();
    });

    test('a restored skill note still resolves to a real all-spaces row',
        () async {
      final stagingPath = await buildMigratedSkillDb(
        noteId: 'skill-live',
        skillTagId: 'skill-tag-live',
      );
      final backupPath = await buildMigratedSkillDb(
        noteId: 'skill-backup',
        skillTagId: 'skill-tag-backup',
      );

      final staging = await openLikeRecovery(stagingPath);
      final backup = await openLikeRecovery(backupPath);
      final allSpacesId = await allSpacesTagIdOf(staging);

      await mergeLikeRecovery(staging, backup);

      // One all-spaces row survives, keeping the id staging already had.
      expect(await allSpacesTagIdOf(staging), allSpacesId);

      // Both skill notes resolve *through the tags table* to it. The restored
      // one would be missing here if each database had minted its own uuid:
      // _mergeTags would have left its note_tags row pointing at the backup's
      // id, which no tags row carries. (The agent-skill link of the restored
      // note is genuinely orphaned that way — a pre-existing recovery
      // limitation for ordinary tags, and the reason this id is fixed.)
      expect(await _notesWithTag(staging, SpaceScopeService.allSpacesTag), [
        'skill-backup',
        'skill-live',
      ]);

      await staging.close();
      await backup.close();
    });
  });
}
