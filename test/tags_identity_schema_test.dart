// Tests for the M1.3 "tags identity schema" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Architecture
// 10, "Round 20 correction" + M1 sub-milestone scoping): `tags.name`'s
// blanket column-level `UNIQUE` constraint is replaced with a partial
// unique index scoped to live, non-redirecting rows —
// `idx_tags_name_live`, `WHERE __deleted__ = 0 AND redirectTarget IS
// NULL` — and `tags` gains the `__deleted__`/`redirectTarget` columns that
// predicate depends on. Every tag-identity-by-name lookup in the app
// (previously three independently-duplicated, unguarded `WHERE name = ?`
// copies: `_getOrCreateTagId` in DatabaseService and
// NoteModificationService, plus `replaceTag`'s own two lookups) is
// consolidated into DatabaseService.findLiveTagByName /
// DatabaseService.getOrCreateLiveTagId, matching the index's predicate
// exactly.
//
// Four things are verified, matching the milestone's own acceptance bar:
//  1. Fresh-install: a brand-new database already has the new columns and
//     the partial unique index (DatabaseService.createNew() -> _onCreate).
//  2. Migration round-trip (DATABASE_VERSION 47 -> 48): an existing
//     pre-M1.3 database's tags (plus every table with a real FK into
//     tags: note_tags, conversation_tags, tag_images, tag_ai_configs)
//     survive migration with __deleted__=0/redirectTarget=NULL, ids
//     unchanged, and PRAGMA foreign_key_check clean afterward. Also
//     exercises `migrateBackupDatabase`, the same runner
//     recovery_screen.dart uses for imported backups.
//  3. Constraint behavior: two live same-named tags collide; a tombstoned
//     tag plus a new live tag with the same name does not; two tombstoned
//     same-named tags do not either.
//  4. Behavioral: DatabaseService.getOrCreateLiveTagId returns a NEW tag
//     id — not a tombstoned row's id — when the only existing row with a
//     given name is tombstoned (the exact bug the design doc's "Round 20
//     correction" identified in the pre-M1.3 `_getOrCreateTagId` copies).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';

/// The exact pre-M1.3 (DATABASE_VERSION <= 47) `tags` schema: a blanket
/// column-level UNIQUE on `name`, no `__deleted__`/`redirectTarget`
/// columns. Deliberately hand-written rather than derived from
/// DatabaseService.getSchema() — as of M1.3, getSchema() already returns
/// the NEW tags DDL (getSchema() has no notion of "a specific historical
/// version"), so the pre-migration snapshot below must be built from this
/// literal instead.
const _oldTagsTableDdl = '''
    CREATE TABLE tags(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      color TEXT NOT NULL,
      createdAt INTEGER NOT NULL,
      usageCount INTEGER NOT NULL DEFAULT 0
    )
''';

// Child tables with a real FK into `tags` (per test/hard_delete_audit_test
// .dart's kFkEdgeBaseline: tags -> conversation_tags, tags -> note_tags,
// tags -> tag_ai_configs, tags -> tag_images), reproduced verbatim from
// database_service.dart's schema constants so the round-trip test can
// verify PRAGMA foreign_key_check stays clean against every one of them,
// not just tags itself. getSchema() already includes note_tags/
// conversation_tags verbatim (unaffected by M1.3), so only tag_images/
// tag_ai_configs — which getSchema() omits — need to be added by hand.
const _tagImagesTableDdl = '''
    CREATE TABLE tag_images(
      tagId TEXT PRIMARY KEY,
      imagePath TEXT NOT NULL,
      FOREIGN KEY (tagId) REFERENCES tags(id) ON DELETE CASCADE
    )
''';

const _tagAiConfigsTableDdl = '''
    CREATE TABLE tag_ai_configs (
      tagId TEXT PRIMARY KEY,
      extractionPrompt TEXT,
      FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
    )
''';

Future<List<Map<String, Object?>>> _tableInfo(Database db, String table) =>
    db.rawQuery("PRAGMA table_info('$table')");

Future<bool> _hasColumn(Database db, String table, String column) async {
  final cols = await _tableInfo(db, table);
  return cols.any((c) => c['name'] == column);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.3 tags identity schema — fresh install', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'tags has __deleted__ (default 0) and redirectTarget (nullable) columns, '
      'and name is no longer column-UNIQUE',
      () async {
        final db = await databaseService.database;
        final cols = await _tableInfo(db, 'tags');

        final deletedCol = cols.firstWhere((c) => c['name'] == '__deleted__');
        expect(deletedCol['notnull'], 1);
        expect(deletedCol['dflt_value'], '0');

        final redirectCol = cols.firstWhere(
          (c) => c['name'] == 'redirectTarget',
        );
        expect(redirectCol['notnull'], 0);

        final nameCol = cols.firstWhere((c) => c['name'] == 'name');
        expect(nameCol['notnull'], 1);

        // No column-level UNIQUE on name means the auto-created single-
        // column unique index sqlite normally adds for `UNIQUE` no longer
        // exists. `id TEXT PRIMARY KEY` still gets its own implicit
        // `sqlite_autoindex_*` unique index (unrelated to this change,
        // present before and after) — excluded here so the assertion is
        // specifically about `name`'s uniqueness mechanism, not an
        // unrelated PK-index count.
        final indexes = await db.rawQuery("PRAGMA index_list('tags')");
        final uniqueNonAutoIndexes = indexes.where(
          (i) =>
              i['unique'] == 1 &&
              !(i['name'] as String).startsWith('sqlite_autoindex_'),
        );
        expect(uniqueNonAutoIndexes.length, 1);
        expect(uniqueNonAutoIndexes.first['name'], 'idx_tags_name_live');
      },
    );

    test(
      'idx_tags_name_live is a partial unique index on (name) matching the '
      'design doc\'s corrected predicate',
      () async {
        final db = await databaseService.database;
        final indexInfo = await db.rawQuery(
          "PRAGMA index_info('idx_tags_name_live')",
        );
        expect(indexInfo.map((r) => r['name']).toList(), ['name']);

        // sqlite_master's sql column carries the partial predicate text.
        final master = await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_tags_name_live'",
        );
        final sql = master.single['sql'] as String;
        expect(sql, contains('__deleted__ = 0'));
        expect(sql, contains('redirectTarget IS NULL'));
      },
    );
  });

  group('M1.3 tags identity schema — migration round-trip (v47 -> v48)', () {
    late Database preMigrationDb;

    setUp(() async {
      preMigrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );

      // Build a v47 (pre-M1.3) database: every current-schema statement
      // EXCEPT the (now-updated) tags table and its new partial index,
      // replaced with the literal old-schema equivalents, plus the two
      // tag-referencing child tables getSchema() omits.
      for (final statement in DatabaseService.getSchema()) {
        if (statement.contains('CREATE TABLE tags(') ||
            statement.contains('idx_tags_name_live')) {
          continue;
        }
        await preMigrationDb.execute(statement);
      }
      await preMigrationDb.execute(_oldTagsTableDdl);
      await preMigrationDb.execute(_tagImagesTableDdl);
      await preMigrationDb.execute(_tagAiConfigsTableDdl);

      await preMigrationDb.execute('''
        CREATE TABLE _schema_version (version INTEGER NOT NULL)
      ''');
      await preMigrationDb.insert('_schema_version', {'version': 47});

      // Sanity check: pre-migration schema really is the old shape.
      expect(await _hasColumn(preMigrationDb, 'tags', '__deleted__'), isFalse);
      expect(
        await _hasColumn(preMigrationDb, 'tags', 'redirectTarget'),
        isFalse,
      );
    });

    tearDown(() async {
      await preMigrationDb.close();
    });

    test(
      'existing tags survive migration with __deleted__=0, redirectTarget=NULL, '
      'unchanged ids, and every FK-referencing child row intact '
      '(PRAGMA foreign_key_check clean)',
      () async {
        // Seed pre-migration data: two tags, each referenced by note_tags,
        // conversation_tags, tag_images, and tag_ai_configs, so the
        // rename/recreate dance's FK preservation is exercised against
        // every real child table, not just tags itself.
        await preMigrationDb.insert('notes', {
          'id': 'note-1',
          'title': 't',
          'content': 'c',
          'type': 'note',
          'createdAt': 1,
          'updatedAt': 1,
          'pinned': 0,
          'isArchived': 0,
        });
        await preMigrationDb.insert('conversations', {
          'id': 'conv-1',
          'title': 'c',
          'createdAt': 1,
          'updatedAt': 1,
          'isArchived': 0,
        });
        await preMigrationDb.insert('tags', {
          'id': 'tag-1',
          'name': 'urgent',
          'color': '#ff0000',
          'createdAt': 100,
          'usageCount': 3,
        });
        await preMigrationDb.insert('tags', {
          'id': 'tag-2',
          'name': 'later',
          'color': '#00ff00',
          'createdAt': 200,
          'usageCount': 0,
        });
        await preMigrationDb.insert('note_tags', {
          'noteId': 'note-1',
          'tagId': 'tag-1',
        });
        await preMigrationDb.insert('conversation_tags', {
          'conversationId': 'conv-1',
          'tagId': 'tag-1',
        });
        await preMigrationDb.insert('tag_images', {
          'tagId': 'tag-1',
          'imagePath': '/tmp/urgent.png',
        });
        await preMigrationDb.insert('tag_ai_configs', {
          'tagId': 'tag-2',
          'extractionPrompt': 'extract dates',
        });

        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 47, 48);

        // New columns present, existing rows carry the documented defaults.
        expect(await _hasColumn(preMigrationDb, 'tags', '__deleted__'), isTrue);
        expect(
          await _hasColumn(preMigrationDb, 'tags', 'redirectTarget'),
          isTrue,
        );

        final tags = await preMigrationDb.query('tags', orderBy: 'id');
        expect(tags.length, 2);
        for (final tag in tags) {
          expect(tag['__deleted__'], 0);
          expect(tag['redirectTarget'], isNull);
        }
        expect(tags[0]['id'], 'tag-1');
        expect(tags[0]['name'], 'urgent');
        expect(tags[0]['color'], '#ff0000');
        expect(tags[0]['createdAt'], 100);
        expect(tags[0]['usageCount'], 3);
        expect(tags[1]['id'], 'tag-2');
        expect(tags[1]['name'], 'later');

        // Child rows still resolve to the same (unchanged) tag ids.
        final noteTags = await preMigrationDb.query('note_tags');
        expect(noteTags.single['tagId'], 'tag-1');
        final conversationTags = await preMigrationDb.query(
          'conversation_tags',
        );
        expect(conversationTags.single['tagId'], 'tag-1');
        final tagImages = await preMigrationDb.query('tag_images');
        expect(tagImages.single['tagId'], 'tag-1');
        final tagAiConfigs = await preMigrationDb.query('tag_ai_configs');
        expect(tagAiConfigs.single['tagId'], 'tag-2');

        // The rename/recreate dance must not have introduced any dangling
        // FK — this is the direct check that tags' id-stability claim
        // (child FKs reference tagId, which never changes) actually holds
        // against the real schema, not merely by inspection.
        final fkViolations = await preMigrationDb.rawQuery(
          'PRAGMA foreign_key_check',
        );
        expect(fkViolations, isEmpty);

        // The partial unique index exists post-migration.
        final indexes = await preMigrationDb.rawQuery(
          "PRAGMA index_list('tags')",
        );
        expect(
          indexes.any(
            (i) => i['name'] == 'idx_tags_name_live' && i['unique'] == 1,
          ),
          isTrue,
        );

        // The rename-target temp table must not survive.
        final leftoverTables = await preMigrationDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='tags_old'",
        );
        expect(leftoverTables, isEmpty);
      },
    );

    test(
      'running the v47 -> v48 migration twice does not error and leaves '
      'schema/data unchanged the second time',
      () async {
        await preMigrationDb.insert('tags', {
          'id': 'tag-1',
          'name': 'urgent',
          'color': '#ff0000',
          'createdAt': 100,
          'usageCount': 0,
        });

        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 47, 48);
        final afterFirst = await preMigrationDb.query('tags', orderBy: 'id');

        // Second run is guarded by the __deleted__-column idempotency
        // check inside _migrateToVersion48 (see its doc comment), not by
        // an unconditional rename dance that would fail the second time
        // (tags_old already having been dropped) or duplicate the index
        // (already IF NOT EXISTS).
        await service.migrateBackupDatabase(preMigrationDb, 47, 48);
        final afterSecond = await preMigrationDb.query('tags', orderBy: 'id');

        expect(afterSecond, equals(afterFirst));
        final fkViolations = await preMigrationDb.rawQuery(
          'PRAGMA foreign_key_check',
        );
        expect(fkViolations, isEmpty);
      },
    );
  });

  group('M1.3 tags identity schema — constraint behavior', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    Future<void> insertTag({
      required String id,
      required String name,
      int deleted = 0,
      String? redirectTarget,
    }) {
      return db.insert('tags', {
        'id': id,
        'name': name,
        'color': '#000000',
        'createdAt': 1,
        'usageCount': 0,
        '__deleted__': deleted,
        'redirectTarget': redirectTarget,
      });
    }

    test('two live tags with the same name violate idx_tags_name_live', () async {
      await insertTag(id: 'a', name: 'urgent');
      expect(
        () => insertTag(id: 'b', name: 'urgent'),
        throwsA(isA<DatabaseException>()),
      );
    });

    test(
      'a tombstoned tag plus a new live tag with the same name succeeds',
      () async {
        await insertTag(id: 'a', name: 'urgent', deleted: 1);
        await insertTag(id: 'b', name: 'urgent'); // should not throw

        final rows = await db.query('tags', orderBy: 'id');
        expect(rows.length, 2);
        expect(rows[0]['__deleted__'], 1);
        expect(rows[1]['__deleted__'], 0);
      },
    );

    test('two tombstoned tags with the same name succeed', () async {
      await insertTag(id: 'a', name: 'urgent', deleted: 1);
      await insertTag(id: 'b', name: 'urgent', deleted: 1); // should not throw

      final rows = await db.query('tags', orderBy: 'id');
      expect(rows.length, 2);
      expect(rows.every((r) => r['__deleted__'] == 1), isTrue);
    });

    test(
      'a live redirecting tag (redirectTarget set, __deleted__=0 transitional '
      'state) does not block a new live tag with the same name',
      () async {
        // Round 20 correction's exact scenario: a tagMerge's redirectTarget
        // write observed before its __deleted__ write.
        await insertTag(id: 'a', name: 'urgent', redirectTarget: 'winner');
        await insertTag(id: 'b', name: 'urgent'); // should not throw

        final rows = await db.query('tags', orderBy: 'id');
        expect(rows.length, 2);
      },
    );
  });

  group(
    'M1.3 tags identity schema — DatabaseService.getOrCreateLiveTagId',
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

      test(
        'returns a NEW tag id, not a tombstoned row\'s id, when the only '
        'existing row with that name is tombstoned',
        () async {
          await db.insert('tags', {
            'id': 'old-tombstoned-id',
            'name': 'urgent',
            'color': '#ff0000',
            'createdAt': 1,
            'usageCount': 5,
            '__deleted__': 1,
            'redirectTarget': null,
          });

          final newId = await DatabaseService.getOrCreateLiveTagId(
            db,
            'urgent',
          );

          expect(newId, isNot('old-tombstoned-id'));

          final rows = await db.query(
            'tags',
            where: 'id = ?',
            whereArgs: [newId],
          );
          expect(rows.single['__deleted__'], 0);
          expect(rows.single['redirectTarget'], isNull);
          expect(rows.single['name'], 'urgent');

          // The tombstoned row is untouched.
          final tombstoned = await db.query(
            'tags',
            where: 'id = ?',
            whereArgs: ['old-tombstoned-id'],
          );
          expect(tombstoned.single['__deleted__'], 1);
        },
      );

      test(
        'returns the existing live tag\'s id when one already exists',
        () async {
          await db.insert('tags', {
            'id': 'live-id',
            'name': 'urgent',
            'color': '#ff0000',
            'createdAt': 1,
            'usageCount': 0,
            '__deleted__': 0,
            'redirectTarget': null,
          });

          final id = await DatabaseService.getOrCreateLiveTagId(db, 'urgent');
          expect(id, 'live-id');

          final rows = await db.query('tags');
          expect(rows.length, 1); // no duplicate created
        },
      );

      test(
        'findLiveTagByName returns null when no live tag with that name exists',
        () async {
          await db.insert('tags', {
            'id': 'tombstoned',
            'name': 'urgent',
            'color': '#ff0000',
            'createdAt': 1,
            'usageCount': 0,
            '__deleted__': 1,
            'redirectTarget': null,
          });

          final found = await DatabaseService.findLiveTagByName(db, 'urgent');
          expect(found, isNull);
        },
      );
    },
  );
}
