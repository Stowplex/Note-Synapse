// Tests for the M1.4 "User-App-family soft-delete conversion" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Architecture
// 10, "User Apps + revision history — round 14 retracts..." + the
// following "User App visibility, extended to be the fallback's actual
// liveness root" paragraph; M1 status section's "M1.4" entry).
//
// `user_apps`/`app_revisions`/`user_app_libraries`/
// `user_app_library_dependencies` gain a `__deleted__` tombstone column
// (`app_revisions` also gains `deletedAt`, the fallback-selection tie-break
// input); `deleteUserApp`/`deleteAppRevision`/`deleteUserAppLibrary`/
// `deleteUserAppLibraryDependency` become ordinary tombstone writes instead
// of real SQL deletes; `deleteUserAppLibrariesForRevision` (the function
// responsible for the original round-8 cross-app scoping bug) is removed
// from the codebase entirely; every list/lookup read path in this family
// filters on *effective* visibility (`DatabaseService
// .computeAppRevisionVisibility` and the library/dependency helpers built
// on it), not raw `__deleted__` — see database_service.dart's own doc
// comment immediately above `computeAppRevisionVisibility` for the full
// derivation rule and the fallback-selection tie-break's reasoning
// (mirrors test/sync_protocol/app_ops.dart's header comment for the
// abstract CRDT simulator).
//
// Six things are verified, matching the milestone's own acceptance bar:
//  1. Fresh-install: a brand-new database already has the new columns
//     (DatabaseService.createNew() -> _onCreate).
//  2. Migration round-trip (DATABASE_VERSION 50 -> 51): an existing
//     pre-M1.4 database's rows across all four tables (plus
//     multi_function_apps, the one other table with a real FK into
//     user_apps) survive migration with __deleted__=0/deletedAt=NULL, ids
//     unchanged, and PRAGMA foreign_key_check clean afterward.
//  3. Fallback selection: the exact scenarios named in the milestone's own
//     acceptance bar (one-revision app becomes its own fallback; a
//     multi-revision app with only one deletion needs no fallback;
//     fallback transfer when a different revision becomes live again; the
//     tie-break rule itself).
//  4. Library/dependency derived visibility: visible under a fallback
//     revision despite the library/dependency's own row never having been
//     touched; hidden when the owning app is deleted (never a "no
//     fallback" dead end, since a zero-live-revisions app always elects
//     one as long as it has any revisions at all).
//  5. Soft-delete confirmation: deleteUserApp/deleteAppRevision/
//     deleteUserAppLibrary/deleteUserAppLibraryDependency write exactly one
//     `__deleted__=1` row update each — the row count in every table is
//     unchanged afterward, and (for deleteUserApp specifically) its
//     descendants' rows are untouched, not soft-deleted in place, matching
//     the "single tombstone write, nothing else" design.
//  6. Read-path filtering: getAllUserApps/getUserApp/getUserAppByUuid/
//     getAppRevisions/getAppRevision/getLatestAppRevision/
//     getUserAppLibraries/getUserAppLibraryDependencies/
//     getDependencyByAppAndPath all stop returning tombstoned rows (except
//     a revision serving as its app's fallback).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/app_revision.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/database_service.dart';

/// The exact pre-M1.4 (DATABASE_VERSION <= 50) shape of the four target
/// tables: no `__deleted__`/`deletedAt` columns. Hand-written rather than
/// derived from DatabaseService.getSchema() — as of M1.4, getSchema()
/// already returns the NEW DDL — same approach
/// test/tags_identity_schema_test.dart established for M1.3.
const _oldUserAppsTableDdl = '''
    CREATE TABLE user_apps(
      id TEXT PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      description TEXT NOT NULL,
      steps TEXT NOT NULL,
      htmlContent TEXT NOT NULL,
      appState TEXT,
      type TEXT NOT NULL DEFAULT 'normal',
      selectedRevisionId TEXT,
      author TEXT DEFAULT "",
      license TEXT DEFAULT "",
      createdAt INTEGER NOT NULL,
      updatedAt INTEGER NOT NULL
    )
''';

const _oldAppRevisionsTableDdl = '''
    CREATE TABLE app_revisions(
      id TEXT PRIMARY KEY,
      appId TEXT NOT NULL,
      revisionNumber INTEGER NOT NULL,
      revisionTimestamp INTEGER NOT NULL,
      userPrompt TEXT NOT NULL,
      aiResponse TEXT NOT NULL,
      appCode TEXT NOT NULL,
      attachmentPaths TEXT,
      FOREIGN KEY (appId) REFERENCES user_apps (id) ON DELETE CASCADE
    )
''';

const _oldUserAppLibrariesTableDdl = '''
    CREATE TABLE user_app_libraries(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      app_uuid TEXT NOT NULL,
      revision_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      usage_instructions TEXT,
      FOREIGN KEY (app_uuid) REFERENCES user_apps (uuid) ON DELETE CASCADE
    )
''';

const _oldUserAppLibraryDependenciesTableDdl = '''
    CREATE TABLE user_app_library_dependencies(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      original_url TEXT,
      local_path TEXT NOT NULL,
      bytes BLOB NOT NULL,
      library_id INTEGER NOT NULL,
      FOREIGN KEY (library_id) REFERENCES user_app_libraries (id) ON DELETE CASCADE
    )
''';

Future<List<Map<String, Object?>>> _tableInfo(Database db, String table) =>
    db.rawQuery("PRAGMA table_info('$table')");

Future<bool> _hasColumn(Database db, String table, String column) async {
  final cols = await _tableInfo(db, table);
  return cols.any((c) => c['name'] == column);
}

UserApp _buildApp({required String id, required String uuid, String name = 'App'}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return UserApp(
    id: id,
    uuid: uuid,
    name: name,
    description: 'desc',
    steps: const ['step1'],
    htmlContent: '<html></html>',
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

  group('M1.4 User-App soft-delete — fresh install', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'user_apps/app_revisions/user_app_libraries/user_app_library_dependencies '
      'all have __deleted__ (default 0); app_revisions also has deletedAt (nullable)',
      () async {
        final db = await databaseService.database;

        for (final table in [
          'user_apps',
          'app_revisions',
          'user_app_libraries',
          'user_app_library_dependencies',
        ]) {
          final cols = await _tableInfo(db, table);
          final deletedCol = cols.firstWhere((c) => c['name'] == '__deleted__');
          expect(deletedCol['notnull'], 1, reason: '$table.__deleted__ should be NOT NULL');
          expect(deletedCol['dflt_value'], '0', reason: '$table.__deleted__ should default to 0');
        }

        final revisionCols = await _tableInfo(db, 'app_revisions');
        final deletedAtCol = revisionCols.firstWhere((c) => c['name'] == 'deletedAt');
        expect(deletedAtCol['notnull'], 0, reason: 'deletedAt should be nullable');
      },
    );
  });

  group('M1.4 User-App soft-delete — migration round-trip (v50 -> v51)', () {
    late Database preMigrationDb;

    setUp(() async {
      preMigrationDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

      // Old-shape tables must exist BEFORE getSchema()'s own
      // ..._createIndexes statements run below (index creation needs the
      // table to already exist, and getSchema() returns every CREATE TABLE
      // followed by every CREATE INDEX as one flat list — the indexes for
      // these four tables would otherwise run before any user_apps/
      // app_revisions/user_app_libraries/user_app_library_dependencies
      // table exists at all).
      await preMigrationDb.execute(_oldUserAppsTableDdl);
      await preMigrationDb.execute(_oldAppRevisionsTableDdl);
      await preMigrationDb.execute(_oldUserAppLibrariesTableDdl);
      await preMigrationDb.execute(_oldUserAppLibraryDependenciesTableDdl);

      for (final statement in DatabaseService.getSchema()) {
        if (statement.contains('CREATE TABLE user_apps(') ||
            statement.contains('CREATE TABLE app_revisions(') ||
            statement.contains('CREATE TABLE user_app_libraries(') ||
            statement.contains('CREATE TABLE user_app_library_dependencies(')) {
          continue;
        }
        await preMigrationDb.execute(statement);
      }

      await preMigrationDb.execute('''
        CREATE TABLE _schema_version (version INTEGER NOT NULL)
      ''');
      await preMigrationDb.insert('_schema_version', {'version': 50});

      expect(await _hasColumn(preMigrationDb, 'user_apps', '__deleted__'), isFalse);
      expect(await _hasColumn(preMigrationDb, 'app_revisions', '__deleted__'), isFalse);
      expect(await _hasColumn(preMigrationDb, 'app_revisions', 'deletedAt'), isFalse);
      expect(await _hasColumn(preMigrationDb, 'user_app_libraries', '__deleted__'), isFalse);
      expect(
        await _hasColumn(preMigrationDb, 'user_app_library_dependencies', '__deleted__'),
        isFalse,
      );
    });

    tearDown(() async {
      await preMigrationDb.close();
    });

    test(
      'existing rows survive migration with __deleted__=0/deletedAt=NULL, unchanged '
      'ids, and every FK-referencing row intact (PRAGMA foreign_key_check clean)',
      () async {
        // Seed one app with a revision, a library, a dependency, and a
        // multi_function_apps row (the one other real FK into user_apps),
        // so the plain ADD COLUMN path is exercised against every real
        // dependent row, not just user_apps itself.
        await preMigrationDb.insert('user_apps', {
          'id': 'app-1',
          'uuid': 'uuid-1',
          'name': 'App One',
          'description': 'd',
          'steps': 's1|s2',
          'htmlContent': '<html></html>',
          'type': 'normal',
          'createdAt': 100,
          'updatedAt': 100,
        });
        await preMigrationDb.insert('app_revisions', {
          'id': 'rev-1',
          'appId': 'app-1',
          'revisionNumber': 1,
          'revisionTimestamp': 100,
          'userPrompt': 'p',
          'aiResponse': 'r',
          'appCode': '<html>code</html>',
        });
        final libraryId = await preMigrationDb.insert('user_app_libraries', {
          'app_uuid': 'uuid-1',
          'revision_id': 1,
          'name': 'lib1',
        });
        await preMigrationDb.insert('user_app_library_dependencies', {
          'original_url': 'https://example.com/x.js',
          'local_path': 'x.js',
          'bytes': Uint8List.fromList([1, 2, 3]),
          'library_id': libraryId,
        });
        await preMigrationDb.insert('multi_function_apps', {
          'appId': 'app-1',
          'isDefault': 0,
          'addedAt': 100,
        });

        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 50, 51);

        expect(await _hasColumn(preMigrationDb, 'user_apps', '__deleted__'), isTrue);
        expect(await _hasColumn(preMigrationDb, 'app_revisions', '__deleted__'), isTrue);
        expect(await _hasColumn(preMigrationDb, 'app_revisions', 'deletedAt'), isTrue);
        expect(await _hasColumn(preMigrationDb, 'user_app_libraries', '__deleted__'), isTrue);
        expect(
          await _hasColumn(preMigrationDb, 'user_app_library_dependencies', '__deleted__'),
          isTrue,
        );

        final apps = await preMigrationDb.query('user_apps');
        expect(apps.single['id'], 'app-1');
        expect(apps.single['__deleted__'], 0);

        final revisions = await preMigrationDb.query('app_revisions');
        expect(revisions.single['id'], 'rev-1');
        expect(revisions.single['__deleted__'], 0);
        expect(revisions.single['deletedAt'], isNull);

        final libraries = await preMigrationDb.query('user_app_libraries');
        expect(libraries.single['app_uuid'], 'uuid-1');
        expect(libraries.single['__deleted__'], 0);

        final dependencies = await preMigrationDb.query('user_app_library_dependencies');
        expect(dependencies.single['local_path'], 'x.js');
        expect(dependencies.single['__deleted__'], 0);

        final multiFunctionApps = await preMigrationDb.query('multi_function_apps');
        expect(multiFunctionApps.single['appId'], 'app-1');

        final fkViolations = await preMigrationDb.rawQuery('PRAGMA foreign_key_check');
        expect(fkViolations, isEmpty);
      },
    );

    test(
      'running the v50 -> v51 migration twice does not error and leaves '
      'schema/data unchanged the second time',
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
        final afterFirst = await preMigrationDb.query('user_apps', orderBy: 'id');

        await service.migrateBackupDatabase(preMigrationDb, 50, 51);
        final afterSecond = await preMigrationDb.query('user_apps', orderBy: 'id');

        expect(afterSecond, equals(afterFirst));
        final fkViolations = await preMigrationDb.rawQuery('PRAGMA foreign_key_check');
        expect(fkViolations, isEmpty);
      },
    );
  });

  group('M1.4 fallback selection — computeAppRevisionVisibility', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    Future<void> insertApp(String id, String uuid) async {
      await databaseService.insertUserApp(_buildApp(id: id, uuid: uuid));
    }

    Future<void> insertRevision(
      String id,
      String appId,
      int revisionNumber,
    ) async {
      await databaseService.insertAppRevision(
        _buildRevision(id: id, appId: appId, revisionNumber: revisionNumber),
      );
    }

    /// Directly tombstones a revision row, bypassing
    /// `deleteAppRevision`'s "cannot delete the only remaining revision"
    /// guard — simulates the post-CRDT-merge states the fallback mechanism
    /// exists for (see database_service.dart's doc comment above
    /// `computeAppRevisionVisibility`), the same way
    /// test/sync_protocol/app_ops.dart's own tests write `__deleted__`
    /// directly against the simulator rather than going through a guarded
    /// application function.
    Future<void> rawTombstoneRevision(String id, int deletedAt) async {
      await db.update(
        'app_revisions',
        {'__deleted__': 1, 'deletedAt': deletedAt},
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    test(
      'an app with one revision, deleted, becomes its own fallback and is '
      'effectively visible',
      () async {
        await insertApp('app-1', 'uuid-1');
        await insertRevision('rev-1', 'app-1', 1);
        await rawTombstoneRevision('rev-1', 5000);

        final vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.fallbackRevisionId, 'rev-1');
        expect(vis.visibleRevisionIds, {'rev-1'});
        expect(
          await databaseService.isAppRevisionEffectivelyVisible('rev-1'),
          isTrue,
        );

        // The read path surfaces it too.
        final revisions = await databaseService.getAppRevisions('app-1');
        expect(revisions.map((r) => r.id), ['rev-1']);
        expect(await databaseService.getAppRevision('rev-1'), isNotNull);
      },
    );

    test(
      'an app with multiple revisions where only one is deleted needs no '
      'fallback — the deleted one is correctly hidden, the others stay live',
      () async {
        await insertApp('app-1', 'uuid-1');
        await insertRevision('rev-1', 'app-1', 1);
        await insertRevision('rev-2', 'app-1', 2);
        await rawTombstoneRevision('rev-1', 5000);

        final vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.fallbackRevisionId, isNull);
        expect(vis.visibleRevisionIds, {'rev-2'});
        expect(
          await databaseService.isAppRevisionEffectivelyVisible('rev-1'),
          isFalse,
        );
        expect(
          await databaseService.isAppRevisionEffectivelyVisible('rev-2'),
          isTrue,
        );

        final revisions = await databaseService.getAppRevisions('app-1');
        expect(revisions.map((r) => r.id), ['rev-2']);
        expect(await databaseService.getAppRevision('rev-1'), isNull);
      },
    );

    test(
      'tie-break rule: among revisions tombstoned in the same millisecond, '
      'the fallback is whichever has the higher revisionNumber',
      () async {
        await insertApp('app-1', 'uuid-1');
        await insertRevision('rev-1', 'app-1', 1);
        await insertRevision('rev-2', 'app-1', 2);
        await rawTombstoneRevision('rev-1', 5000);
        await rawTombstoneRevision('rev-2', 5000); // identical deletedAt

        final vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.fallbackRevisionId, 'rev-2');
      },
    );

    test(
      'fallback selects whichever revision has the highest deletedAt (most '
      'recently made non-live), not revisionNumber, when they differ',
      () async {
        await insertApp('app-1', 'uuid-1');
        await insertRevision('rev-1', 'app-1', 1);
        await insertRevision('rev-2', 'app-1', 2);
        // rev-1 has the higher revisionNumber-irrelevant deletedAt even
        // though rev-2 has the higher revisionNumber — deletedAt wins.
        await rawTombstoneRevision('rev-2', 1000);
        await rawTombstoneRevision('rev-1', 9000);

        final vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.fallbackRevisionId, 'rev-1');
      },
    );

    test(
      'fallback transfers away once a different revision becomes raw-live '
      'again (e.g. a future undelete)',
      () async {
        await insertApp('app-1', 'uuid-1');
        await insertRevision('rev-1', 'app-1', 1);
        await insertRevision('rev-2', 'app-1', 2);
        await rawTombstoneRevision('rev-1', 1000);
        await rawTombstoneRevision('rev-2', 9000);

        // Zero-live: rev-2 (higher deletedAt) is the fallback.
        var vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.fallbackRevisionId, 'rev-2');

        // rev-1 becomes raw-live again (undelete).
        await db.update(
          'app_revisions',
          {'__deleted__': 0},
          where: 'id = ?',
          whereArgs: ['rev-1'],
        );

        vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.fallbackRevisionId, isNull);
        expect(vis.visibleRevisionIds, {'rev-1'});
        expect(
          await databaseService.isAppRevisionEffectivelyVisible('rev-2'),
          isFalse,
          reason: 'rev-2 no longer serves as fallback once rev-1 is live again',
        );
      },
    );

    test(
      'a deleted app has no effectively-visible revisions, regardless of '
      'the revisions\' own raw state (apps have no fallback concept)',
      () async {
        await insertApp('app-1', 'uuid-1');
        await insertRevision('rev-1', 'app-1', 1); // raw-live revision

        await db.update(
          'user_apps',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: ['app-1'],
        );

        final vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.visibleRevisionIds, isEmpty);
        expect(vis.fallbackRevisionId, isNull);
        expect(
          await databaseService.isAppRevisionEffectivelyVisible('rev-1'),
          isFalse,
        );
        expect(await databaseService.getAppRevisions('app-1'), isEmpty);
      },
    );

    test(
      'nonexistent app returns empty visibility, not an error',
      () async {
        final vis = await databaseService.computeAppRevisionVisibility('no-such-app');
        expect(vis.visibleRevisionIds, isEmpty);
        expect(vis.fallbackRevisionId, isNull);
      },
    );
  });

  group('M1.4 library/dependency derived visibility', () {
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
      'a library is visible under a fallback revision even though its own '
      'row was never touched',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );

        // Zero-live-revisions via direct tombstone (bypassing the guard,
        // same as the fallback-selection group above).
        await db.update(
          'app_revisions',
          {'__deleted__': 1, 'deletedAt': 1000},
          where: 'id = ?',
          whereArgs: ['rev-1'],
        );

        expect(
          await databaseService.isUserAppLibraryEffectivelyVisible(libraryId),
          isTrue,
          reason: 'rev-1 is the (sole) fallback, so its library stays visible',
        );
        final libraries = await databaseService.getUserAppLibraries('uuid-1', 1);
        expect(libraries.length, 1);
        expect(libraries.single['id'], libraryId);
      },
    );

    test(
      'a library is hidden when the owning app is deleted, even though the '
      'library and its revision were never touched directly',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );
        final dependencyId = await databaseService.insertUserAppLibraryDependency(
          localPath: 'x.js',
          bytes: const [1, 2, 3],
          libraryId: libraryId,
        );

        await databaseService.deleteUserApp('app-1');

        expect(
          await databaseService.isUserAppLibraryEffectivelyVisible(libraryId),
          isFalse,
        );
        expect(
          await databaseService.isUserAppLibraryDependencyEffectivelyVisible(dependencyId),
          isFalse,
        );
        expect(await databaseService.getUserAppLibraries('uuid-1', 1), isEmpty);
        expect(await databaseService.getUserAppLibraryDependencies(libraryId), isEmpty);

        // The library/dependency rows themselves were never touched —
        // deleteUserApp is a single tombstone write on user_apps only.
        final rawLibrary = await db.query('user_app_libraries', where: 'id = ?', whereArgs: [libraryId]);
        expect(rawLibrary.single['__deleted__'], 0);
        final rawDependency = await db.query(
          'user_app_library_dependencies',
          where: 'id = ?',
          whereArgs: [dependencyId],
        );
        expect(rawDependency.single['__deleted__'], 0);
      },
    );

    test(
      'a directly-tombstoned library is hidden even under an effectively-'
      'visible (raw-live) revision',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );

        await databaseService.deleteUserAppLibrary(libraryId);

        expect(
          await databaseService.isUserAppLibraryEffectivelyVisible(libraryId),
          isFalse,
        );
        expect(await databaseService.getUserAppLibraries('uuid-1', 1), isEmpty);

        // Confirmed soft-delete, not a real DELETE.
        final raw = await db.query('user_app_libraries', where: 'id = ?', whereArgs: [libraryId]);
        expect(raw.length, 1);
        expect(raw.single['__deleted__'], 1);
      },
    );

    test(
      'a dependency composes through its library: hidden when the library '
      'is directly tombstoned, even though the dependency row itself is untouched',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );
        final dependencyId = await databaseService.insertUserAppLibraryDependency(
          localPath: 'x.js',
          bytes: const [1, 2, 3],
          libraryId: libraryId,
        );

        await databaseService.deleteUserAppLibrary(libraryId);

        expect(
          await databaseService.isUserAppLibraryDependencyEffectivelyVisible(dependencyId),
          isFalse,
        );
        final raw = await db.query(
          'user_app_library_dependencies',
          where: 'id = ?',
          whereArgs: [dependencyId],
        );
        expect(raw.single['__deleted__'], 0, reason: 'the dependency row itself was never touched');
      },
    );

    test(
      'zero-live-revisions always elects a fallback when the app has any '
      'revisions at all — never leaves libraries in an inconsistent '
      '(neither-visible-nor-explained) state',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-2', appId: 'app-1', revisionNumber: 2),
        );
        final lib1 = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib-on-rev-1',
        );
        final lib2 = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 2,
          name: 'lib-on-rev-2',
        );

        await db.update(
          'app_revisions',
          {'__deleted__': 1, 'deletedAt': 1000},
          where: 'id = ?',
          whereArgs: ['rev-1'],
        );
        await db.update(
          'app_revisions',
          {'__deleted__': 1, 'deletedAt': 9000}, // more recent -> fallback
          where: 'id = ?',
          whereArgs: ['rev-2'],
        );

        final vis = await databaseService.computeAppRevisionVisibility('app-1');
        expect(vis.fallbackRevisionId, 'rev-2');

        // The fallback's own library stays visible; the non-fallback
        // sibling's library does not — consistent, not orphaned either way.
        expect(await databaseService.isUserAppLibraryEffectivelyVisible(lib2), isTrue);
        expect(await databaseService.isUserAppLibraryEffectivelyVisible(lib1), isFalse);
      },
    );
  });

  group('M1.4 soft-delete confirmation — tombstone writes, not real deletes', () {
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
      'deleteUserApp writes a single __deleted__=1 update on user_apps; '
      'app_revisions/user_app_libraries/user_app_library_dependencies rows '
      'are all left completely untouched (row counts and __deleted__ unchanged)',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );
        await databaseService.insertUserAppLibraryDependency(
          localPath: 'x.js',
          bytes: const [1, 2, 3],
          libraryId: libraryId,
        );

        final appRowsBefore = await db.query('user_apps');
        final revisionRowsBefore = await db.query('app_revisions');
        final libraryRowsBefore = await db.query('user_app_libraries');
        final dependencyRowsBefore = await db.query('user_app_library_dependencies');

        await databaseService.deleteUserApp('app-1');

        final appRowsAfter = await db.query('user_apps');
        expect(appRowsAfter.length, appRowsBefore.length);
        expect(appRowsAfter.single['__deleted__'], 1);

        final revisionRowsAfter = await db.query('app_revisions');
        expect(revisionRowsAfter, equals(revisionRowsBefore));

        final libraryRowsAfter = await db.query('user_app_libraries');
        expect(libraryRowsAfter, equals(libraryRowsBefore));

        final dependencyRowsAfter = await db.query('user_app_library_dependencies');
        expect(dependencyRowsAfter, equals(dependencyRowsBefore));
      },
    );

    test(
      'deleteAppRevision writes a single __deleted__=1/deletedAt update on '
      'app_revisions; the row count is unchanged',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-2', appId: 'app-1', revisionNumber: 2),
        );

        final rowsBefore = await db.query('app_revisions');
        await databaseService.deleteAppRevision('rev-1');
        final rowsAfter = await db.query('app_revisions');

        expect(rowsAfter.length, rowsBefore.length);
        final deletedRow = rowsAfter.firstWhere((r) => r['id'] == 'rev-1');
        expect(deletedRow['__deleted__'], 1);
        expect(deletedRow['deletedAt'], isNotNull);
        final liveRow = rowsAfter.firstWhere((r) => r['id'] == 'rev-2');
        expect(liveRow['__deleted__'], 0);
      },
    );

    test(
      'deleteAppRevision still throws when it is the only EFFECTIVELY '
      'VISIBLE revision (guard reads the filtered list, not a raw row count)',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );

        await expectLater(
          databaseService.deleteAppRevision('rev-1'),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'deleteUserAppLibrary writes a single __deleted__=1 update; row count unchanged',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );

        final rowsBefore = await db.query('user_app_libraries');
        await databaseService.deleteUserAppLibrary(libraryId);
        final rowsAfter = await db.query('user_app_libraries');

        expect(rowsAfter.length, rowsBefore.length);
        expect(rowsAfter.single['__deleted__'], 1);
      },
    );

    test(
      'deleteUserAppLibraryDependency writes a single __deleted__=1 update; '
      'row count unchanged',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );
        final dependencyId = await databaseService.insertUserAppLibraryDependency(
          localPath: 'x.js',
          bytes: const [1, 2, 3],
          libraryId: libraryId,
        );

        final rowsBefore = await db.query('user_app_library_dependencies');
        await databaseService.deleteUserAppLibraryDependency(dependencyId);
        final rowsAfter = await db.query('user_app_library_dependencies');

        expect(rowsAfter.length, rowsBefore.length);
        expect(rowsAfter.single['__deleted__'], 1);
      },
    );

  });

  group('M1.4 read-path filtering', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('getAllUserApps/getUserApp/getUserAppByUuid hide a deleted app', () async {
      await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
      await databaseService.insertUserApp(_buildApp(id: 'app-2', uuid: 'uuid-2'));

      await databaseService.deleteUserApp('app-1');

      final all = await databaseService.getAllUserApps();
      expect(all.map((a) => a.id), ['app-2']);
      expect(await databaseService.getUserApp('app-1'), isNull);
      expect(await databaseService.getUserApp('app-2'), isNotNull);
      expect(await databaseService.getUserAppByUuid('uuid-1'), isNull);
      expect(await databaseService.getUserAppByUuid('uuid-2'), isNotNull);
    });

    test(
      'getLatestAppRevision returns the latest EFFECTIVELY VISIBLE revision, '
      'skipping a tombstoned highest-revisionNumber row',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-2', appId: 'app-1', revisionNumber: 2),
        );

        await databaseService.deleteAppRevision('rev-2');

        final latest = await databaseService.getLatestAppRevision('app-1');
        expect(latest?.id, 'rev-1');
      },
    );

    test(
      'getDependencyByAppAndPath returns null once the owning library is '
      'tombstoned',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        final libraryId = await databaseService.insertUserAppLibrary(
          appUuid: 'uuid-1',
          revisionId: 1,
          name: 'lib1',
        );
        await databaseService.insertUserAppLibraryDependency(
          localPath: 'x.js',
          bytes: const [1, 2, 3],
          libraryId: libraryId,
        );

        expect(
          await databaseService.getDependencyByAppAndPath('uuid-1', 1, 'x.js'),
          isNotNull,
        );

        await databaseService.deleteUserAppLibrary(libraryId);

        expect(
          await databaseService.getDependencyByAppAndPath('uuid-1', 1, 'x.js'),
          isNull,
        );
      },
    );

    test(
      'getNextRevisionNumber is unaffected by tombstoning — never reuses a '
      'deleted revision\'s number',
      () async {
        await databaseService.insertUserApp(_buildApp(id: 'app-1', uuid: 'uuid-1'));
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-1', appId: 'app-1', revisionNumber: 1),
        );
        await databaseService.insertAppRevision(
          _buildRevision(id: 'rev-2', appId: 'app-1', revisionNumber: 2),
        );

        await databaseService.deleteAppRevision('rev-2');

        // Even though rev-2 is now tombstoned (and not the fallback, since
        // rev-1 is still live), the next number must still be 3, not a
        // reused 2 — a reused number would silently re-associate rev-2's
        // still-physically-present library rows with a brand new revision.
        expect(await databaseService.getNextRevisionNumber('app-1'), 3);
      },
    );
  });
}
