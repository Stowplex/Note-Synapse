// Tests for the M1.5 "DDL rejection" half of the hard-delete guard
// milestone (.claude/plans/plan-and-propse-the-glistening-dolphin.md, §
// Architecture 1, "mutation capture, the hard-delete guard with the
// required sql_query_service.dart DDL-rejection change").
//
// The hard-delete guard installed by DatabaseService (see
// test/hard_delete_guard_test.dart) is itself just schema: a
// `DROP TRIGGER guard_no_hard_delete_user_apps`, a `DROP TABLE`, or an
// `ALTER TABLE ... RENAME TO` dance approved through SqlQueryService's
// ordinary write-approval flow could silently remove or neuter it — the
// exact vulnerability named in executeQuery's own pre-existing comment ("a
// DROP TABLE takes its triggers with it"). This file verifies
// SqlQueryService.executeQuery now rejects DDL outright, before it ever
// reaches that approval flow, while leaving ordinary DML
// (INSERT/UPDATE/DELETE) working exactly as before.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sql_query_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('SqlQueryService.isDdlQuery', () {
    late SqlQueryService service;

    setUp(() {
      service = SqlQueryService(DatabaseService());
    });

    test('CREATE TABLE/INDEX/TRIGGER/VIEW are DDL', () {
      expect(service.isDdlQuery(SqlQueryType.createTable), isTrue);
      expect(service.isDdlQuery(SqlQueryType.createIndex), isTrue);
      expect(service.isDdlQuery(SqlQueryType.createTrigger), isTrue);
      expect(service.isDdlQuery(SqlQueryType.createView), isTrue);
    });

    test('DROP TABLE/INDEX/TRIGGER/VIEW are DDL', () {
      expect(service.isDdlQuery(SqlQueryType.dropTable), isTrue);
      expect(service.isDdlQuery(SqlQueryType.dropIndex), isTrue);
      expect(service.isDdlQuery(SqlQueryType.dropTrigger), isTrue);
      expect(service.isDdlQuery(SqlQueryType.dropView), isTrue);
    });

    test('ALTER TABLE is DDL', () {
      expect(service.isDdlQuery(SqlQueryType.alterTable), isTrue);
    });

    test('ordinary DML/SELECT/PRAGMA/other are NOT DDL', () {
      expect(service.isDdlQuery(SqlQueryType.select), isFalse);
      expect(service.isDdlQuery(SqlQueryType.insert), isFalse);
      expect(service.isDdlQuery(SqlQueryType.update), isFalse);
      expect(service.isDdlQuery(SqlQueryType.delete), isFalse);
      expect(service.isDdlQuery(SqlQueryType.replace), isFalse);
      expect(service.isDdlQuery(SqlQueryType.pragma), isFalse);
      expect(service.isDdlQuery(SqlQueryType.other), isFalse);
    });
  });

  group('SqlQueryService.executeQuery — DDL rejection (real sqflite)', () {
    late DatabaseService databaseService;
    late SqlQueryService sqlQueryService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database; // ensure _onCreate has run
      sqlQueryService = SqlQueryService(databaseService);
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'DROP TRIGGER targeting a hard-delete guard is rejected without any '
      'approval callback configured',
      () async {
        final result = await sqlQueryService.executeQuery(
          'DROP TRIGGER guard_no_hard_delete_user_apps',
        );

        expect(result.success, isFalse);
        expect(result.error, contains('DDL'));

        // The trigger must still be there — the statement never ran.
        final db = await databaseService.database;
        final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='trigger' "
          "AND name='guard_no_hard_delete_user_apps'",
        );
        expect(rows, hasLength(1));
      },
    );

    test(
      'DROP TRIGGER targeting a hard-delete guard is STILL rejected even '
      'when writes are approved for the session',
      () async {
        sqlQueryService.approveWritesForSession();

        final result = await sqlQueryService.executeQuery(
          'DROP TRIGGER guard_no_hard_delete_user_apps',
        );

        expect(result.success, isFalse);
        expect(result.error, contains('DDL'));

        final db = await databaseService.database;
        final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='trigger' "
          "AND name='guard_no_hard_delete_user_apps'",
        );
        expect(rows, hasLength(1));
      },
    );

    test(
      'DROP TRIGGER is STILL rejected even when an approval callback would '
      'say yes (the callback is never even invoked for DDL)',
      () async {
        var callbackInvoked = false;
        sqlQueryService.onWriteApprovalRequest = (source, sql, type) async {
          callbackInvoked = true;
          return true;
        };

        final result = await sqlQueryService.executeQuery(
          'DROP TRIGGER guard_no_hard_delete_user_apps',
        );

        expect(result.success, isFalse);
        expect(callbackInvoked, isFalse);
      },
    );

    test('a generic CREATE TABLE is rejected outright', () async {
      final result = await sqlQueryService.executeQuery(
        'CREATE TABLE evil (id TEXT PRIMARY KEY)',
      );

      expect(result.success, isFalse);
      expect(result.error, contains('DDL'));

      final db = await databaseService.database;
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='evil'",
      );
      expect(rows, isEmpty);
    });

    test(
      'a generic CREATE TABLE is STILL rejected when writes are approved '
      'for the session',
      () async {
        sqlQueryService.approveWritesForSession();

        final result = await sqlQueryService.executeQuery(
          'CREATE TABLE evil (id TEXT PRIMARY KEY)',
        );

        expect(result.success, isFalse);
        expect(result.error, contains('DDL'));
      },
    );

    test('a generic ALTER TABLE is rejected outright', () async {
      final result = await sqlQueryService.executeQuery(
        'ALTER TABLE notes ADD COLUMN evil_column TEXT',
      );

      expect(result.success, isFalse);
      expect(result.error, contains('DDL'));

      final db = await databaseService.database;
      final cols = await db.rawQuery("PRAGMA table_info('notes')");
      expect(cols.any((c) => c['name'] == 'evil_column'), isFalse);
    });

    test(
      'an ALTER TABLE that could rewrite a guarded table (e.g. renaming it '
      'out from under its trigger) is rejected outright',
      () async {
        final result = await sqlQueryService.executeQuery(
          'ALTER TABLE user_apps RENAME TO user_apps_old',
        );

        expect(result.success, isFalse);
        expect(result.error, contains('DDL'));

        final db = await databaseService.database;
        final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='user_apps'",
        );
        expect(rows, hasLength(1));
      },
    );

    test(
      'ordinary approved INSERT against a non-guarded table still works '
      'normally',
      () async {
        sqlQueryService.approveWritesForSession();

        final result = await sqlQueryService.executeQuery('''
          INSERT INTO notes (id, title, content, type, createdAt, updatedAt)
          VALUES ('n1', 'Title', 'Content', 'note', 1, 1)
        ''');

        expect(result.success, isTrue);

        final db = await databaseService.database;
        final rows = await db.query('notes', where: 'id = ?', whereArgs: ['n1']);
        expect(rows, hasLength(1));
      },
    );

    test(
      'ordinary approved UPDATE against a non-guarded table still works '
      'normally',
      () async {
        final db = await databaseService.database;
        await db.insert('notes', {
          'id': 'n1',
          'title': 'Title',
          'content': 'Content',
          'type': 'note',
          'createdAt': 1,
          'updatedAt': 1,
        });
        sqlQueryService.approveWritesForSession();

        final result = await sqlQueryService.executeQuery(
          "UPDATE notes SET title = 'New Title' WHERE id = 'n1'",
        );

        expect(result.success, isTrue);
        final rows = await db.query('notes', where: 'id = ?', whereArgs: ['n1']);
        expect(rows.single['title'], 'New Title');
      },
    );

    test(
      'ordinary approved DELETE against a non-guarded table still works '
      'normally (the DDL check does not over-reach into plain DML)',
      () async {
        final db = await databaseService.database;
        // `tag_ai_configs` deliberately has no `__deleted__` column and no
        // guard trigger of its own (M1.9's "derive, don't tombstone"
        // design -- its visibility derives entirely from the owning tag's
        // liveness, see _hardDeleteGuardedTables's doc comment in
        // database_service.dart) -- `notes` was used here before M1.13
        // extended the hard-delete guard to cover it too, which is exactly
        // the over-reach this test exists to rule out for a genuinely
        // still-unguarded table.
        await db.insert('tags', {
          'id': 't1',
          'name': 'tag',
          'color': '#fff',
          'createdAt': 1,
        });
        await db.insert('tag_ai_configs', {
          'tagId': 't1',
          'extractionPrompt': 'p',
        });
        sqlQueryService.approveWritesForSession();

        final result = await sqlQueryService.executeQuery(
          "DELETE FROM tag_ai_configs WHERE tagId = 't1'",
        );

        expect(result.success, isTrue);
        final rows = await db.query(
          'tag_ai_configs',
          where: 'tagId = ?',
          whereArgs: ['t1'],
        );
        expect(rows, isEmpty);
      },
    );

    test(
      'a real DELETE against a guarded User-App-family table is still '
      'blocked by the hard-delete guard trigger itself, not by DDL '
      'rejection (queryType is delete, not DDL) — surfaces as a query '
      'execution failure, not a DDL rejection',
      () async {
        final db = await databaseService.database;
        await db.insert('user_apps', {
          'id': 'a1',
          'uuid': 'u1',
          'name': 'App',
          'description': 'd',
          'steps': 's1',
          'htmlContent': '<html></html>',
          'type': 'normal',
          'createdAt': 1,
          'updatedAt': 1,
        });
        sqlQueryService.approveWritesForSession();

        final result = await sqlQueryService.executeQuery(
          "DELETE FROM user_apps WHERE id = 'a1'",
        );

        expect(result.success, isFalse);
        expect(result.error, isNot(contains('DDL')));

        final rows = await db.query('user_apps', where: 'id = ?', whereArgs: ['a1']);
        expect(rows, hasLength(1));
      },
    );
  });
}
