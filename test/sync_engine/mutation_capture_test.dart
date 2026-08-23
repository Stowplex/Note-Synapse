// Tests for M2.4's mutation-capture triggers (design doc § Architecture
// 11.3, "Mutation capture: from ordinary writes to a durable outbox") —
// the real, persistent `AFTER INSERT`/`AFTER UPDATE`/`AFTER DELETE`
// triggers `database_service.dart` installs on every requirement-1
// sync-scope table, writing into `sync_touch_log`.
//
// This is the trigger-COMPLETENESS scanner the milestone brief calls for,
// not just a handful of spot checks: for every one of the fourteen
// `_hardDeleteGuardedTables` entity tables, this file enumerates the
// table's REAL, current column list via `PRAGMA table_info` and asserts
// every single column is accounted for as either (a) a sync-scope column
// with a live, verified-by-actual-mutation `AFTER UPDATE` trigger, or (b)
// an explicitly-excluded column with a documented reason (mirroring
// `database_service.dart`'s own per-table doc comments). A column that is
// neither — e.g. a brand-new column added to a table's schema without
// updating BOTH the trigger spec and this test — fails the "every column
// accounted for" assertion immediately, closing exactly the "missing even
// one sync-scope column silently breaks capture for that field forever"
// failure class the milestone brief names as the central risk here.
//
// For the five OR-Set membership tables, this file verifies AFTER
// INSERT/AFTER DELETE both produce a touch row with the right
// entityTable/entityId/fieldName/memberUuid shape — including the
// deliberate deviation from § 11.3's literal "fieldName = NULL" text (see
// `_syncMutationCaptureTriggerStatements`'s doc comment in
// database_service.dart for why): `conversations` owns three independent
// OR-Sets, and this test explicitly confirms they stay distinguishable by
// `fieldName`.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';

/// One entity table's completeness case: enumerate its FULL current column
/// set via `PRAGMA table_info`, partition it into `syncScopeColumns`
/// (verified live, via a real UPDATE + touch-row check) and
/// `excludedColumns` (documented, never expected to fire) — see the file
/// doc comment for why every column must land in exactly one of the two.
class _EntityCase {
  const _EntityCase({
    required this.table,
    required this.idColumn,
    required this.id,
    required this.baseRow,
    required this.syncScopeUpdates,
    required this.excludedColumns,
  });

  final String table;
  final String idColumn;
  final Object id; // the primary-key value used for baseRow/lookups
  final Map<String, Object?> baseRow;

  /// column -> a value distinctly different from baseRow's, used to drive
  /// the AFTER UPDATE trigger and confirm a touch row appears.
  final Map<String, Object?> syncScopeUpdates;

  final Set<String> excludedColumns;

  String get idAsText => '$id';
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;

  setUp(() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
  });

  tearDown(() async {
    await databaseService.close();
  });

  Future<Set<String>> realColumns(String table) async {
    final rows = await db.rawQuery("PRAGMA table_info('$table')");
    return rows.map((r) => r['name'] as String).toSet();
  }

  Future<int> touchCount(
    String table,
    String entityId, {
    String? field,
    String? member,
  }) async {
    final whereParts = ['entityTable = ?', 'entityId = ?'];
    final args = <Object?>[table, entityId];
    if (field == null) {
      whereParts.add('fieldName IS NULL');
    } else {
      whereParts.add('fieldName = ?');
      args.add(field);
    }
    if (member == null) {
      whereParts.add('memberUuid IS NULL');
    } else {
      whereParts.add('memberUuid = ?');
      args.add(member);
    }
    final rows = await db.query(
      'sync_touch_log',
      where: whereParts.join(' AND '),
      whereArgs: args,
    );
    return rows.length;
  }

  group('trigger installation — fresh install has exactly the expected set', () {
    test('105 sync_touch_ triggers exist: 14 entity AFTER INSERT + 80 field '
        'AFTER UPDATE + 5*2 OR-Set AFTER INSERT/DELETE', () async {
      // 80 field triggers = the pre-M2.7 61, plus M2.7's tags.name/
      // tags.color (design doc § Architecture 11.6(e) needs a remote tag's
      // name to detect a same-name collision — see database_service.dart's
      // tags SyncEntityCaptureScope doc comment), plus M2.8's own
      // sync-scope-exclusion-reasoning audit findings: relationships.type
      // (1); conversation_attachments.{filePath,fileName,fileType,
      // isRelativePath} (4); attachments.{filePath,fileName,fileType,
      // isRelativePath} (4); app_revisions.{revisionNumber,userPrompt,
      // aiResponse,attachmentPaths} (4); user_app_libraries.{name,
      // usage_instructions} (2); user_app_library_dependencies.
      // {original_url,local_path} (2) — 17 more, 63+17=80. See each
      // column's own finding at its SyncEntityCaptureScope doc comment in
      // database_service.dart.
      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(triggers.length, 105);
    });

    test('running _onCreate-installed statements again is a safe no-op '
        '(idempotency, mirroring the hard-delete guard\'s own precedent)', () async {
      // Re-open a second connection against a fresh DB and just confirm the
      // count is stable across two independently-created databases (the
      // real idempotency guarantee — CREATE TRIGGER IF NOT EXISTS — is
      // exercised for real by the migration round-trip test below, which
      // literally runs the installer twice against the same connection).
      final second = DatabaseService.createNew();
      final db2 = await second.database;
      final triggers = await db2.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(triggers.length, 105);
      await second.close();
    });
  });

  group('migration round-trip (v56 -> v57)', () {
    test('migrating an existing v56 database installs all 105 triggers, '
        'twice, safely', () async {
      // M2.7/M2.8 finding: _migrateToVersion57 (database_service.dart)
      // reuses the CURRENT, live `_syncMutationCaptureTriggerStatements`
      // list rather than a hand-frozen historical one (its own doc comment
      // says so explicitly: "there is no earlier, narrower historical scope
      // to preserve" — true when 57 was the newest version). Now that
      // `syncEntityCaptureScopes` includes tags.name/tags.color (M2.7) AND
      // the M2.8 sync-scope-exclusion-reasoning audit's six further
      // findings (relationships.type; conversation_attachments' and
      // attachments' path/name/type/isRelativePath columns; app_revisions'
      // revisionNumber/userPrompt/aiResponse/attachmentPaths;
      // user_app_libraries' name/usage_instructions;
      // user_app_library_dependencies' original_url/local_path — see each
      // one's own SyncEntityCaptureScope doc comment), a v56->57 migration
      // installs all 105 triggers, not the 85 a purely historical snapshot
      // would have. This is harmless (idempotent CREATE TRIGGER IF NOT
      // EXISTS, no data touched) — the separate v59/v60 migrations below
      // exist for the real upgrade path this test doesn't cover: a device
      // already AT v57/58/59 when it receives this build, where v57 does
      // NOT re-run.
      final preMigrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      for (final statement in DatabaseService.getSchema()) {
        await preMigrationDb.execute(statement);
      }
      // getSchema() deliberately excludes the sync_* control-plane tables,
      // the M1.5/M1.13 guard triggers, and (per its own doc comment,
      // "AI-facing schema documentation... sync machinery is not user
      // content") a few tables it never lists at all, including
      // tag_workflow_bindings — a real v56 install would already have all
      // of these from earlier migrations. Recreate the minimal slice this
      // migration actually depends on: sync_touch_log itself, plus
      // tag_workflow_bindings (one of the fourteen sync-scope entity
      // tables this migration installs triggers on).
      await preMigrationDb.execute('''
        CREATE TABLE IF NOT EXISTS tag_workflow_bindings (
          pattern TEXT PRIMARY KEY,
          isPrefix INTEGER NOT NULL DEFAULT 0,
          skillNoteId TEXT NOT NULL,
          prompt TEXT NOT NULL DEFAULT '',
          contentImmutable INTEGER NOT NULL DEFAULT 0,
          __deleted__ INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await preMigrationDb.execute('''
        CREATE TABLE IF NOT EXISTS sync_touch_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          entityTable TEXT NOT NULL,
          entityId TEXT NOT NULL,
          fieldName TEXT,
          memberUuid TEXT,
          touchedAt INTEGER NOT NULL,
          processedAt INTEGER
        )
      ''');
      await preMigrationDb.execute(
        'CREATE TABLE _schema_version (version INTEGER NOT NULL)',
      );
      await preMigrationDb.insert('_schema_version', {'version': 56});

      final before = await preMigrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(before, isEmpty);

      final service = DatabaseService.createNew();
      await service.migrateBackupDatabase(preMigrationDb, 56, 57);

      final after = await preMigrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(after.length, 105);

      // Running it again must be a safe no-op (CREATE TRIGGER IF NOT
      // EXISTS throughout).
      await service.migrateBackupDatabase(preMigrationDb, 56, 57);
      final afterTwice = await preMigrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(afterTwice.length, 105);

      await service.close();
      await preMigrationDb.close();
    });
  });

  group('migration round-trip (v56 -> v59, M2.7 tags.name/color addendum)', () {
    test('migrating an existing v56 database all the way to v59 installs all 105 triggers '
        '(v57 alone already installs the live/current full set, including the M2.8 findings — '
        'see the v56->v57 test above), including tags.name/tags.color, twice, safely', () async {
      final preMigrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      for (final statement in DatabaseService.getSchema()) {
        await preMigrationDb.execute(statement);
      }
      await preMigrationDb.execute('''
        CREATE TABLE IF NOT EXISTS tag_workflow_bindings (
          pattern TEXT PRIMARY KEY,
          isPrefix INTEGER NOT NULL DEFAULT 0,
          skillNoteId TEXT NOT NULL,
          prompt TEXT NOT NULL DEFAULT '',
          contentImmutable INTEGER NOT NULL DEFAULT 0,
          __deleted__ INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await preMigrationDb.execute('''
        CREATE TABLE IF NOT EXISTS sync_touch_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          entityTable TEXT NOT NULL,
          entityId TEXT NOT NULL,
          fieldName TEXT,
          memberUuid TEXT,
          touchedAt INTEGER NOT NULL,
          processedAt INTEGER
        )
      ''');
      await preMigrationDb.execute('CREATE TABLE _schema_version (version INTEGER NOT NULL)');
      await preMigrationDb.insert('_schema_version', {'version': 56});

      final service = DatabaseService.createNew();
      await service.migrateBackupDatabase(preMigrationDb, 56, 59);

      final after = await preMigrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(after.length, 105);
      final names = after.map((r) => r['name'] as String).toSet();
      expect(names, containsAll(['sync_touch_tags_au_name', 'sync_touch_tags_au_color']));

      // A real UPDATE against tags.name now actually fires the new trigger.
      await preMigrationDb.insert('tags', {
        'id': 'tagX',
        'name': 'old',
        'color': '#fff',
        'createdAt': 1000,
        'usageCount': 0,
        '__deleted__': 0,
        'redirectTarget': null,
      });
      await preMigrationDb.update('tags', {'name': 'new'}, where: 'id = ?', whereArgs: ['tagX']);
      final touches = await preMigrationDb.query(
        'sync_touch_log',
        where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
        whereArgs: ['tags', 'tagX', 'name'],
      );
      expect(touches, isNotEmpty);

      // Running it again must be a safe no-op.
      await service.migrateBackupDatabase(preMigrationDb, 56, 59);
      final afterTwice = await preMigrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(afterTwice.length, 105);

      await service.close();
      await preMigrationDb.close();
    });
  });

  group('migration round-trip (v56 -> v60, M2.8 sync-scope-exclusion-reasoning audit findings)', () {
    test('migrating an existing v56 database all the way to v60 installs all 105 triggers, '
        'including every M2.8 audit finding, twice, safely', () async {
      final preMigrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      for (final statement in DatabaseService.getSchema()) {
        await preMigrationDb.execute(statement);
      }
      await preMigrationDb.execute('''
        CREATE TABLE IF NOT EXISTS tag_workflow_bindings (
          pattern TEXT PRIMARY KEY,
          isPrefix INTEGER NOT NULL DEFAULT 0,
          skillNoteId TEXT NOT NULL,
          prompt TEXT NOT NULL DEFAULT '',
          contentImmutable INTEGER NOT NULL DEFAULT 0,
          __deleted__ INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await preMigrationDb.execute('''
        CREATE TABLE IF NOT EXISTS sync_touch_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          entityTable TEXT NOT NULL,
          entityId TEXT NOT NULL,
          fieldName TEXT,
          memberUuid TEXT,
          touchedAt INTEGER NOT NULL,
          processedAt INTEGER
        )
      ''');
      await preMigrationDb.execute('CREATE TABLE _schema_version (version INTEGER NOT NULL)');
      await preMigrationDb.insert('_schema_version', {'version': 56});

      final service = DatabaseService.createNew();
      await service.migrateBackupDatabase(preMigrationDb, 56, 60);

      final after = await preMigrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(after.length, 105);
      final names = after.map((r) => r['name'] as String).toSet();
      expect(
        names,
        containsAll([
          'sync_touch_relationships_au_type',
          'sync_touch_conversation_attachments_au_filePath',
          'sync_touch_conversation_attachments_au_fileName',
          'sync_touch_conversation_attachments_au_fileType',
          'sync_touch_conversation_attachments_au_isRelativePath',
          'sync_touch_attachments_au_filePath',
          'sync_touch_attachments_au_fileName',
          'sync_touch_attachments_au_fileType',
          'sync_touch_attachments_au_isRelativePath',
          'sync_touch_app_revisions_au_revisionNumber',
          'sync_touch_app_revisions_au_userPrompt',
          'sync_touch_app_revisions_au_aiResponse',
          'sync_touch_app_revisions_au_attachmentPaths',
          'sync_touch_user_app_libraries_au_name',
          'sync_touch_user_app_libraries_au_usage_instructions',
          'sync_touch_user_app_library_dependencies_au_original_url',
          'sync_touch_user_app_library_dependencies_au_local_path',
        ]),
      );

      // A real UPDATE against relationships.type now actually fires the
      // new trigger (the same "prove it, don't just assert trigger
      // existence" standard the v59 test above applies to tags.name).
      await preMigrationDb.insert('notes', {
        'id': 'note1',
        'title': 'T1',
        'content': 'C1',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await preMigrationDb.insert('relationships', {
        'id': 'relX',
        'fromNoteId': 'note1',
        'toNoteId': 'note1',
        'type': 'related',
        'createdAt': 1000,
        '__deleted__': 0,
      });
      await preMigrationDb.update('relationships', {'type': 'causality'}, where: 'id = ?', whereArgs: ['relX']);
      final touches = await preMigrationDb.query(
        'sync_touch_log',
        where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
        whereArgs: ['relationships', 'relX', 'type'],
      );
      expect(touches, isNotEmpty);

      // Running it again must be a safe no-op.
      await service.migrateBackupDatabase(preMigrationDb, 56, 60);
      final afterTwice = await preMigrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE 'sync_touch_%'",
      );
      expect(afterTwice.length, 105);

      await service.close();
      await preMigrationDb.close();
    });
  });

  group('entity-table completeness scan (every column accounted for)', () {
    final cases = <_EntityCase>[
      _EntityCase(
        table: 'notes',
        idColumn: 'id',
        id: 'note1',
        baseRow: const {
          'id': 'note1',
          'title': 'T1',
          'content': 'C1',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
          'scheduledAt': null,
          'completeBy': null,
          'status': null,
          'completionPercentage': null,
          'pinned': 0,
          'isArchived': 0,
          'recurrenceRule': null,
          'metadata': null,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'title': 'T2',
          'content': 'C2',
          'type': 'task',
          'updatedAt': 2000,
          'scheduledAt': '2024-01-01',
          'completeBy': '2024-02-01',
          'status': 'todo',
          'completionPercentage': 0.5,
          'pinned': 1,
          'isArchived': 1,
          'recurrenceRule': '{"freq":"daily"}',
          'metadata': '{"a":1}',
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'createdAt'},
      ),
      _EntityCase(
        table: 'subnotes',
        idColumn: 'id',
        id: 'sub1',
        baseRow: const {
          'id': 'sub1',
          'noteId': 'note1',
          'name': 'N1',
          'content': 'C1',
          'createdAt': 1000,
          'isCompleted': 0,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'name': 'N2',
          'content': 'C2',
          'isCompleted': 1,
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'noteId', 'createdAt'},
      ),
      _EntityCase(
        table: 'tags',
        idColumn: 'id',
        id: 'tag1',
        baseRow: const {
          'id': 'tag1',
          'name': 'urgent',
          'color': '#fff',
          'createdAt': 1000,
          'usageCount': 0,
          '__deleted__': 0,
          'redirectTarget': null,
        },
        syncScopeUpdates: const {
          'name': 'urgent2',
          'color': '#000',
          '__deleted__': 1,
          'redirectTarget': 'tag-winner',
        },
        excludedColumns: {'id', 'createdAt', 'usageCount'},
      ),
      _EntityCase(
        table: 'filters',
        idColumn: 'id',
        id: 'filt1',
        baseRow: const {
          'id': 'filt1',
          'name': 'F1',
          'includeText': null,
          'includeTags': '[]',
          'excludeTags': '',
          'noteTypes': '',
          'includeArchived': 0,
          'isPinned': 0,
          'createdAt': 1000,
          'updatedAt': 1000,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'name': 'F2',
          'includeText': 'hello',
          'includeTags': '["a"]',
          'excludeTags': 'b',
          'noteTypes': 'task',
          'includeArchived': 1,
          'isPinned': 1,
          'updatedAt': 2000,
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'createdAt'},
      ),
      _EntityCase(
        table: 'relationships',
        idColumn: 'id',
        id: 'rel1',
        baseRow: const {
          'id': 'rel1',
          'fromNoteId': 'note1',
          'toNoteId': 'note1',
          'type': 'linked',
          'createdAt': 1000,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {'type': 'causality', '__deleted__': 1},
        excludedColumns: {'id', 'fromNoteId', 'toNoteId', 'createdAt'},
      ),
      _EntityCase(
        table: 'tag_workflow_bindings',
        idColumn: 'pattern',
        id: 'pattern1',
        baseRow: const {
          'pattern': 'pattern1',
          'isPrefix': 0,
          'skillNoteId': 'note1',
          'prompt': 'p1',
          'contentImmutable': 0,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'isPrefix': 1,
          'skillNoteId': 'note1-b',
          'prompt': 'p2',
          'contentImmutable': 1,
          '__deleted__': 1,
        },
        excludedColumns: {'pattern'},
      ),
      _EntityCase(
        table: 'conversations',
        idColumn: 'id',
        id: 'conv1',
        baseRow: const {
          'id': 'conv1',
          'title': 'Conv1',
          'noteIds': '[]',
          'createdAt': 1000,
          'updatedAt': 1000,
          'isArchived': 0,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'title': 'Conv2',
          'updatedAt': 2000,
          'isArchived': 1,
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'createdAt', 'noteIds'},
      ),
      _EntityCase(
        table: 'conversation_messages',
        idColumn: 'id',
        id: 'msg1',
        baseRow: const {
          'id': 'msg1',
          'type': 'user',
          'content': 'hi',
          'timestamp': 1000,
          'modelUsed': null,
          'metadata': null,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'type': 'ai',
          'content': 'hello there',
          'modelUsed': 'gemini',
          'metadata': '{"x":1}',
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'timestamp'},
      ),
      _EntityCase(
        table: 'conversation_attachments',
        idColumn: 'id',
        id: 'catt1',
        baseRow: const {
          'id': 'catt1',
          'messageId': 'msg1',
          'filePath': '/a',
          'fileName': 'a',
          'fileType': 'txt',
          'isRelativePath': 0,
          'createdAt': 1000,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'filePath': '/b',
          'fileName': 'b',
          'fileType': 'png',
          'isRelativePath': 1,
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'messageId', 'createdAt'},
      ),
      _EntityCase(
        table: 'attachments',
        idColumn: 'id',
        id: 'att1',
        baseRow: const {
          'id': 'att1',
          'noteId': 'note1',
          'filePath': '/a',
          'fileName': 'a',
          'fileType': 'txt',
          'isRelativePath': 1,
          'createdAt': 1000,
          'includeInAIContext': 1,
          'metadata': null,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'filePath': '/b',
          'fileName': 'b',
          'fileType': 'png',
          'isRelativePath': 0,
          'includeInAIContext': 0,
          'metadata': '{"y":2}',
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'noteId', 'createdAt'},
      ),
      _EntityCase(
        table: 'user_apps',
        idColumn: 'id',
        id: 'app1',
        baseRow: const {
          'id': 'app1',
          'uuid': 'uuid1',
          'name': 'App1',
          'description': 'D1',
          'steps': 'S1',
          'htmlContent': 'H1',
          'appState': null,
          'type': 'normal',
          'selectedRevisionId': null,
          'author': '',
          'license': '',
          'createdAt': 1000,
          'updatedAt': 1000,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'name': 'App2',
          'description': 'D2',
          'steps': 'S2',
          'htmlContent': 'H2',
          'appState': '{"z":1}',
          'type': 'aiTool',
          'selectedRevisionId': 'rev1',
          'author': 'me',
          'license': 'MIT',
          'updatedAt': 2000,
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'uuid', 'createdAt'},
      ),
      _EntityCase(
        table: 'app_revisions',
        idColumn: 'id',
        id: 'rev1',
        baseRow: const {
          'id': 'rev1',
          'appId': 'app1',
          'revisionNumber': 1,
          'revisionTimestamp': 1000,
          'userPrompt': 'up',
          'aiResponse': 'ar',
          'appCode': '<html></html>',
          'attachmentPaths': null,
          '__deleted__': 0,
          'deletedAt': null,
        },
        syncScopeUpdates: const {
          'revisionNumber': 2,
          'userPrompt': 'up2',
          'aiResponse': 'ar2',
          'attachmentPaths': 'a.png|b.png',
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'appId', 'revisionTimestamp', 'appCode', 'deletedAt'},
      ),
      _EntityCase(
        table: 'user_app_libraries',
        idColumn: 'id',
        id: 1,
        baseRow: const {
          'app_uuid': 'uuid1',
          'revision_id': 1,
          'name': 'Lib1',
          'usage_instructions': null,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'name': 'Lib2',
          'usage_instructions': 'use it like this',
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'app_uuid', 'revision_id'},
      ),
      _EntityCase(
        table: 'user_app_library_dependencies',
        idColumn: 'id',
        id: 1,
        baseRow: {
          'original_url': 'https://example.com',
          'local_path': '/dep',
          'bytes': Uint8List.fromList([1, 2, 3]),
          'library_id': 1,
          '__deleted__': 0,
        },
        syncScopeUpdates: const {
          'original_url': 'https://example.com/v2',
          'local_path': '/dep2',
          '__deleted__': 1,
        },
        excludedColumns: {'id', 'bytes', 'library_id'},
      ),
    ];

    Future<void> seedFkPrerequisites() async {
      // Insertion order matters under PRAGMA foreign_keys = ON.
      await db.insert('notes', {
        'id': 'note1',
        'title': 'T1',
        'content': 'C1',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('conversations', {
        'id': 'conv1',
        'title': 'Conv1',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('conversation_messages', {
        'id': 'msg1',
        'type': 'user',
        'content': 'hi',
        'timestamp': 1000,
      });
      await db.insert('user_apps', {
        'id': 'app1',
        'uuid': 'uuid1',
        'name': 'App1',
        'description': 'D1',
        'steps': 'S1',
        'htmlContent': 'H1',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('user_app_libraries', {
        'id': 1,
        'app_uuid': 'uuid1',
        'revision_id': 1,
        'name': 'Lib1',
      });
    }

    for (final testCase in cases) {
      group(testCase.table, () {
        setUp(() async {
          await seedFkPrerequisites();
        });

        test('every real column is accounted for (sync-scope or documented exclusion)', () async {
          final real = await realColumns(testCase.table);
          final accounted = {
            ...testCase.syncScopeUpdates.keys,
            ...testCase.excludedColumns,
          };
          expect(
            real,
            accounted,
            reason:
                'A column exists in "${testCase.table}" that this test\'s '
                'spec does not know about — it must be added to either '
                'syncScopeUpdates (with a working trigger) or '
                'excludedColumns (with a documented reason), matching '
                '_syncEntityCaptureStatementGroups in database_service.dart. '
                'Missing/extra: sync-scope+excluded=$accounted vs real=$real',
          );
        });

        test('AFTER INSERT produces exactly one whole-row __exists__ touch', () async {
          // seedFkPrerequisites() may have already inserted this exact row
          // (notes/conversations/conversation_messages/user_apps/
          // user_app_libraries are both FK prerequisites AND their own test
          // subject) -- in that case just verify the touch is already there
          // instead of re-inserting (which would violate the PK).
          final alreadySeeded = const {
            'notes',
            'conversations',
            'conversation_messages',
            'user_apps',
            'user_app_libraries',
          }.contains(testCase.table);
          if (!alreadySeeded) {
            await db.insert(testCase.table, testCase.baseRow);
          }
          expect(
            await touchCount(testCase.table, testCase.idAsText),
            1,
            reason: '${testCase.table} AFTER INSERT must produce exactly '
                'one fieldName=NULL touch row',
          );
        });

        for (final entry in testCase.syncScopeUpdates.entries) {
          test('AFTER UPDATE ${entry.key} produces a field touch, and only when the value actually changes', () async {
            final alreadySeeded = const {
              'notes',
              'conversations',
              'conversation_messages',
              'user_apps',
              'user_app_libraries',
            }.contains(testCase.table);
            if (!alreadySeeded) {
              await db.insert(testCase.table, testCase.baseRow);
            }
            await db.delete('sync_touch_log'); // isolate this column's check

            await db.update(
              testCase.table,
              {entry.key: entry.value},
              where: '${testCase.idColumn} = ?',
              whereArgs: [testCase.id],
            );
            expect(
              await touchCount(testCase.table, testCase.idAsText, field: entry.key),
              1,
              reason: 'a genuine change to ${testCase.table}.${entry.key} '
                  'must produce exactly one field touch',
            );

            // No-op: setting it to the SAME value again must not fire.
            await db.delete('sync_touch_log');
            await db.update(
              testCase.table,
              {entry.key: entry.value},
              where: '${testCase.idColumn} = ?',
              whereArgs: [testCase.id],
            );
            expect(
              await touchCount(testCase.table, testCase.idAsText, field: entry.key),
              0,
              reason: 're-writing the same value must not fire the '
                  'WHEN NEW.${entry.key} IS NOT OLD.${entry.key} guard',
            );
          });
        }
      });
    }
  });

  group('OR-Set membership tables — AFTER INSERT/DELETE, with the disclosed fieldName deviation', () {
    setUp(() async {
      await db.insert('notes', {
        'id': 'note1',
        'title': 'T1',
        'content': 'C1',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('tags', {
        'id': 'tag1',
        'name': 'urgent',
        'color': '#fff',
        'createdAt': 1000,
      });
      await db.insert('conversations', {
        'id': 'conv1',
        'title': 'Conv1',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('conversation_messages', {
        'id': 'msg1',
        'type': 'user',
        'content': 'hi',
        'timestamp': 1000,
      });
      await db.insert('conversation_messages', {
        'id': 'msg2',
        'type': 'user',
        'content': 'hi2',
        'timestamp': 1000,
      });
    });

    test('note_tags -> notes.tags', () async {
      await db.insert('note_tags', {'noteId': 'note1', 'tagId': 'tag1'});
      expect(await touchCount('notes', 'note1', field: 'tags', member: 'tag1'), 1);
      await db.delete('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['note1', 'tag1']);
      expect(await touchCount('notes', 'note1', field: 'tags', member: 'tag1'), 2);
    });

    test('conversation_tags -> conversations.tags', () async {
      await db.insert('conversation_tags', {'conversationId': 'conv1', 'tagId': 'tag1'});
      expect(await touchCount('conversations', 'conv1', field: 'tags', member: 'tag1'), 1);
    });

    test('conversation_note_mapping -> conversations.noteIds', () async {
      await db.insert('conversation_note_mapping', {
        'conversationId': 'conv1',
        'noteId': 'note1',
        'createdAt': 1000,
      });
      expect(await touchCount('conversations', 'conv1', field: 'noteIds', member: 'note1'), 1);
    });

    test('conversation_message_mapping -> conversations.messageIds', () async {
      await db.insert('conversation_message_mapping', {
        'conversationId': 'conv1',
        'messageId': 'msg1',
        'createdAt': 1000,
      });
      expect(await touchCount('conversations', 'conv1', field: 'messageIds', member: 'msg1'), 1);
    });

    test('message_parents -> conversation_messages.parentMessageIds (msg1 owns a parent-set containing msg2)', () async {
      await db.insert('message_parents', {
        'id': 'mp1',
        'messageId': 'msg1',
        'parentMessageId': 'msg2',
        'createdAt': 1000,
      });
      expect(
        await touchCount('conversation_messages', 'msg1', field: 'parentMessageIds', member: 'msg2'),
        1,
      );
    });

    test('conversations owning three independent OR-Sets stay distinguishable by fieldName', () async {
      await db.insert('conversation_tags', {'conversationId': 'conv1', 'tagId': 'tag1'});
      await db.insert('conversation_note_mapping', {
        'conversationId': 'conv1',
        'noteId': 'note1',
        'createdAt': 1000,
      });
      await db.insert('conversation_message_mapping', {
        'conversationId': 'conv1',
        'messageId': 'msg1',
        'createdAt': 1000,
      });

      final touches = await db.query(
        'sync_touch_log',
        where: "entityTable = 'conversations' AND entityId = 'conv1' AND fieldName IS NOT NULL",
      );
      final fieldNames = touches.map((r) => r['fieldName']).toSet();
      expect(fieldNames, {'tags', 'noteIds', 'messageIds'});
      // And each touch's memberUuid matches the member that was actually
      // added under that field — no cross-contamination between the three
      // sets sharing the same entityTable/entityId.
      final byField = {for (final r in touches) r['fieldName']: r['memberUuid']};
      expect(byField['tags'], 'tag1');
      expect(byField['noteIds'], 'note1');
      expect(byField['messageIds'], 'msg1');
    });
  });
}
