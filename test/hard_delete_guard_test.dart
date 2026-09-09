// Tests for the M1.5 "hard-delete guard" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Architecture
// 1, "the hard-delete guard... `BEFORE DELETE... RAISE(ABORT, ...)` on
// every synced table"; § Status, M1 status section's "M1.5" entry).
//
// Scope, deliberately narrow (see the doc comment above
// DatabaseService._hardDeleteGuardTriggerStatements for the full
// narrow-vs-broad discussion this mirrors): only the four User-App-family
// tables M1.3/M1.4 already fully converted to soft-delete —
// `user_apps`, `app_revisions`, `user_app_libraries`,
// `user_app_library_dependencies`. NOT `notes`/`tags`/`filters`/
// `conversations`/etc. — those still have real, unconverted hard-delete
// call sites per test/hard_delete_audit_test.dart's own baseline, so
// guarding them would break live functionality.
//
// What this file verifies, matching the milestone's own acceptance bar:
//  1. Fresh install: each of the four tables already has its guard trigger
//     installed (DatabaseService.createNew() -> _onCreate), and a real
//     `db.delete(...)` against any of them throws with a clear message.
//  2. The guard is not overly broad: ordinary INSERT/UPDATE against all
//     four tables still works completely normally.
//  3. Migration round-trip (DATABASE_VERSION 49 -> 50): an existing,
//     already-on-v50 database (post-M1.4, no guard yet) gains the guard
//     triggers after migrating, and a real DELETE against any of the four
//     tables then throws — while data already in the table is untouched by
//     the migration itself (pure-additive, CREATE TRIGGER IF NOT EXISTS).
//  4. Regression check proving M1.4 and M1.5 compose correctly together:
//     the now-soft-delete-only functions (`deleteUserApp`,
//     `deleteAppRevision`, `deleteUserAppLibrary`,
//     `deleteUserAppLibraryDependency`) still work correctly with the
//     guard installed — they never issue a real DELETE anymore, so the
//     guard must never fire for them.
//  5. A known, pre-existing, disclosed exception within the narrow scope:
//     `deleteAppRevisions` (plural — dead code, zero call sites in `lib/`,
//     deliberately left unconverted by M1.4, still a real hard delete per
//     test/hard_delete_audit_test.dart's own baseline) now throws when
//     called, since it still issues a real `db.delete('app_revisions', ...)`
//     and the guard has no knowledge of "this call site happens to be
//     unreachable" — exactly the "backstop against any future regression"
//     behavior the design doc describes.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/app_revision.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/database_service.dart';

const _hardDeleteGuardedTables = [
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

UserApp _buildApp({
  required String id,
  required String uuid,
  String name = 'App',
  String? selectedRevisionId,
}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return UserApp(
    id: id,
    uuid: uuid,
    name: name,
    description: 'desc',
    steps: const ['step1'],
    htmlContent: '<html></html>',
    selectedRevisionId: selectedRevisionId,
    createdAt: now,
    updatedAt: now,
  );
}

AppRevision _buildRevision({
  required String id,
  required String appId,
  required int revisionNumber,
}) {
  return AppRevision(
    id: id,
    appId: appId,
    revisionNumber: revisionNumber,
    revisionTimestamp: DateTime.fromMillisecondsSinceEpoch(1000),
    userPrompt: 'prompt',
    aiResponse: 'response',
    appCode: '<html>code</html>',
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.5 hard-delete guard — fresh install', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('every guarded table has its guard trigger installed', () async {
      for (final table in _hardDeleteGuardedTables) {
        expect(
          await _hasGuardTrigger(db, table),
          isTrue,
          reason: '$table should have a guard_no_hard_delete_$table trigger',
        );
      }
    });

    test(
      'a real db.delete() against user_apps throws with a clear message',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
        expect(
          () => db.delete('user_apps', where: 'id = ?', whereArgs: ['a1']),
          throwsA(
            isA<DatabaseException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('user_apps'), contains('soft-delete')),
            ),
          ),
        );
        // The row must still be there — RAISE(ABORT) rolls back the whole
        // statement, not just "some of it".
        final rows = await db.query('user_apps', where: 'id = ?', whereArgs: ['a1']);
        expect(rows, hasLength(1));
      },
    );

    test(
      'a real db.delete() against app_revisions throws with a clear message',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'r1', appId: 'a1', revisionNumber: 1),
        );
        expect(
          () => db.delete('app_revisions', where: 'id = ?', whereArgs: ['r1']),
          throwsA(
            isA<DatabaseException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('app_revisions'), contains('soft-delete')),
            ),
          ),
        );
        final rows = await db.query('app_revisions', where: 'id = ?', whereArgs: ['r1']);
        expect(rows, hasLength(1));
      },
    );

    test(
      'a real db.delete() against user_app_libraries throws with a clear message',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
        final libId = await databaseService.insertUserAppLibrary(
          appUuid: 'u1',
          revisionId: 1,
          name: 'lib',
        );
        expect(
          () => db.delete('user_app_libraries', where: 'id = ?', whereArgs: [libId]),
          throwsA(
            isA<DatabaseException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('user_app_libraries'), contains('soft-delete')),
            ),
          ),
        );
        final rows = await db.query(
          'user_app_libraries',
          where: 'id = ?',
          whereArgs: [libId],
        );
        expect(rows, hasLength(1));
      },
    );

    test(
      'a real db.delete() against user_app_library_dependencies throws with '
      'a clear message',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
        final libId = await databaseService.insertUserAppLibrary(
          appUuid: 'u1',
          revisionId: 1,
          name: 'lib',
        );
        final depId = await databaseService.insertUserAppLibraryDependency(
          localPath: 'x.js',
          bytes: [1, 2, 3],
          libraryId: libId,
        );
        expect(
          () => db.delete(
            'user_app_library_dependencies',
            where: 'id = ?',
            whereArgs: [depId],
          ),
          throwsA(
            isA<DatabaseException>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('user_app_library_dependencies'),
                contains('soft-delete'),
              ),
            ),
          ),
        );
        final rows = await db.query(
          'user_app_library_dependencies',
          where: 'id = ?',
          whereArgs: [depId],
        );
        expect(rows, hasLength(1));
      },
    );

    test(
      'the guard is not overly broad: ordinary INSERT/UPDATE against all '
      'four tables still works normally',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'r1', appId: 'a1', revisionNumber: 1),
        );
        final libId = await databaseService.insertUserAppLibrary(
          appUuid: 'u1',
          revisionId: 1,
          name: 'lib',
        );
        final depId = await databaseService.insertUserAppLibraryDependency(
          localPath: 'x.js',
          bytes: [1, 2, 3],
          libraryId: libId,
        );

        // UPDATE every table directly, bypassing the higher-level helper
        // methods, to prove the guard trigger only reacts to DELETE.
        await db.update(
          'user_apps',
          {'name': 'renamed'},
          where: 'id = ?',
          whereArgs: ['a1'],
        );
        await db.update(
          'app_revisions',
          {'userPrompt': 'changed'},
          where: 'id = ?',
          whereArgs: ['r1'],
        );
        await db.update(
          'user_app_libraries',
          {'name': 'renamed-lib'},
          where: 'id = ?',
          whereArgs: [libId],
        );
        await db.update(
          'user_app_library_dependencies',
          {'local_path': 'y.js'},
          where: 'id = ?',
          whereArgs: [depId],
        );

        final app = (await db.query('user_apps', where: 'id = ?', whereArgs: ['a1'])).single;
        expect(app['name'], 'renamed');
        final rev = (await db.query('app_revisions', where: 'id = ?', whereArgs: ['r1'])).single;
        expect(rev['userPrompt'], 'changed');
        final lib = (await db.query(
          'user_app_libraries',
          where: 'id = ?',
          whereArgs: [libId],
        )).single;
        expect(lib['name'], 'renamed-lib');
        final dep = (await db.query(
          'user_app_library_dependencies',
          where: 'id = ?',
          whereArgs: [depId],
        )).single;
        expect(dep['local_path'], 'y.js');
      },
    );

    test(
      'deleteAppRevisions (plural, dead code, still a real hard delete per '
      'the M1.2 audit baseline) now throws under the installed guard',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'r1', appId: 'a1', revisionNumber: 1),
        );
        expect(
          () => databaseService.deleteAppRevisions('a1'),
          throwsA(isA<DatabaseException>()),
        );
        // Untouched: the guard aborted before any row was removed.
        final rows = await db.query('app_revisions', where: 'appId = ?', whereArgs: ['a1']);
        expect(rows, hasLength(1));
      },
    );
  });

  group(
    'M1.5 hard-delete guard — regression: M1.4 soft-delete functions still '
    'work correctly with the guard installed',
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

      test('deleteUserApp still soft-deletes (no real DELETE, no throw)', () async {
        await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));

        await databaseService.deleteUserApp('a1');

        final rows = await db.query('user_apps', where: 'id = ?', whereArgs: ['a1']);
        expect(rows, hasLength(1), reason: 'row must still physically exist');
        expect(rows.single['__deleted__'], 1);
      });

      test(
        'deleteAppRevision still soft-deletes (no real DELETE, no throw)',
        () async {
          await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
          await databaseService.insertAppRevision(
            _buildRevision(id: 'r1', appId: 'a1', revisionNumber: 1),
          );
          // deleteAppRevision refuses to delete the only remaining
          // revision, so seed a second one first.
          await databaseService.insertAppRevision(
            _buildRevision(id: 'r2', appId: 'a1', revisionNumber: 2),
          );

          await databaseService.deleteAppRevision('r1');

          final rows = await db.query('app_revisions', where: 'id = ?', whereArgs: ['r1']);
          expect(rows, hasLength(1), reason: 'row must still physically exist');
          expect(rows.single['__deleted__'], 1);
        },
      );

      test(
        'deleteUserAppLibrary still soft-deletes (no real DELETE, no throw)',
        () async {
          await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
          final libId = await databaseService.insertUserAppLibrary(
            appUuid: 'u1',
            revisionId: 1,
            name: 'lib',
          );

          await databaseService.deleteUserAppLibrary(libId);

          final rows = await db.query(
            'user_app_libraries',
            where: 'id = ?',
            whereArgs: [libId],
          );
          expect(rows, hasLength(1), reason: 'row must still physically exist');
          expect(rows.single['__deleted__'], 1);
        },
      );

      test(
        'deleteUserAppLibraryDependency still soft-deletes (no real DELETE, '
        'no throw)',
        () async {
          await databaseService.insertUserApp(_buildApp(id: 'a1', uuid: 'u1'));
          final libId = await databaseService.insertUserAppLibrary(
            appUuid: 'u1',
            revisionId: 1,
            name: 'lib',
          );
          final depId = await databaseService.insertUserAppLibraryDependency(
            localPath: 'x.js',
            bytes: [1, 2, 3],
            libraryId: libId,
          );

          await databaseService.deleteUserAppLibraryDependency(depId);

          final rows = await db.query(
            'user_app_library_dependencies',
            where: 'id = ?',
            whereArgs: [depId],
          );
          expect(rows, hasLength(1), reason: 'row must still physically exist');
          expect(rows.single['__deleted__'], 1);
        },
      );
    },
  );

  group('M1.5 hard-delete guard — migration round-trip (v50 -> v51)', () {
    late Database preMigrationDb;

    setUp(() async {
      preMigrationDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

      // v50 shape: every CREATE TABLE from the current schema constants
      // (which, as of M1.4, already include __deleted__/deletedAt), but
      // deliberately NOT run through _onCreate, so none of the M1.5 guard
      // triggers exist yet — exactly what an existing v50 install looks
      // like today, before this migration runs.
      for (final statement in DatabaseService.getSchema()) {
        await preMigrationDb.execute(statement);
      }
      await preMigrationDb.execute('''
        CREATE TABLE _schema_version (version INTEGER NOT NULL)
      ''');
      await preMigrationDb.insert('_schema_version', {'version': 49});

      for (final table in _hardDeleteGuardedTables) {
        expect(await _hasGuardTrigger(preMigrationDb, table), isFalse);
      }
    });

    tearDown(() async {
      await preMigrationDb.close();
    });

    test(
      'migrating v50 -> v51 installs the guard trigger on all four tables, '
      'and existing data survives untouched',
      () async {
        await preMigrationDb.insert('user_apps', {
          'id': 'app-1',
          'uuid': 'uuid-1',
          'name': 'App One',
          'description': 'd',
          'steps': 's1',
          'htmlContent': '<html></html>',
          'type': 'normal',
          'createdAt': 100,
          'updatedAt': 100,
        });

        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 50, 51);

        for (final table in _hardDeleteGuardedTables) {
          expect(
            await _hasGuardTrigger(preMigrationDb, table),
            isTrue,
            reason: '$table should have the guard trigger after migrating to v51',
          );
        }

        final apps = await preMigrationDb.query('user_apps');
        expect(apps.single['id'], 'app-1');

        expect(
          () => preMigrationDb.delete('user_apps', where: 'id = ?', whereArgs: ['app-1']),
          throwsA(isA<DatabaseException>()),
        );
      },
    );

    test(
      'running the v50 -> v51 migration twice does not error (CREATE '
      'TRIGGER IF NOT EXISTS is idempotent)',
      () async {
        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 50, 51);
        await service.migrateBackupDatabase(preMigrationDb, 50, 51);

        for (final table in _hardDeleteGuardedTables) {
          expect(await _hasGuardTrigger(preMigrationDb, table), isTrue);
        }
      },
    );
  });
}
