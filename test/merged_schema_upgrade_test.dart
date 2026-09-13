import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'search/ocr_test_stubs.dart';

const _localizedMetadata = '{"zh":{"name":"保留的应用"}}';

Future<void> _seedRows(Database db, {bool localized = true}) async {
  await db.insert('notes', {
    'id': 'kept-note',
    'title': 'Preserved note',
    'content': 'migrationsearchable body',
    'type': 'note',
    'createdAt': 1000,
    'updatedAt': 2000,
    'pinned': 1,
  });
  await db.insert('tags', {
    'id': 'kept-tag',
    'name': 'retained',
    'color': '#2196F3',
    'createdAt': 1000,
  });
  await db.insert('note_tags', {'noteId': 'kept-note', 'tagId': 'kept-tag'});
  await db.insert('user_apps', {
    'id': 'kept-app',
    'uuid': 'kept-app-uuid',
    'name': 'Preserved app',
    'description': 'Original description',
    'steps': '[]',
    'htmlContent': '<main>Original code</main>',
    'appState': '{"retained":true}',
    if (localized) 'i18n': _localizedMetadata,
    'createdAt': 1000,
    'updatedAt': 2000,
  });
  await db.insert('app_revisions', {
    'id': 'kept-revision',
    'appId': 'kept-app',
    'revisionNumber': 1,
    'revisionTimestamp': 1000,
    'userPrompt': 'Original prompt',
    'aiResponse': 'Original response',
    'appCode': '<main>Original revision</main>',
  });
}

Future<Database> _main48Fixture(String path, {int recordedVersion = 48}) async {
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  // Frozen from origin/main's v48 database_service.dart, including its
  // indexes and FTS triggers. Using historical DDL prevents current schema
  // constants from hiding missing migration steps in this regression.
  final statements =
      jsonDecode(
            await File('test/fixtures/main_v48_schema.json').readAsString(),
          )
          as List<dynamic>;
  for (final statement in statements.cast<String>()) {
    await db.execute(statement);
  }
  await db.execute('CREATE TABLE _schema_version (version INTEGER NOT NULL)');
  await db.insert('_schema_version', {'version': recordedVersion});
  await db.execute('PRAGMA user_version = 999');
  await _seedRows(db);
  return db;
}

Future<void> _verifyUpgrade(
  DatabaseService service, {
  required bool localized,
}) async {
  final db = await service.database;
  expect(
    (await db.query('_schema_version')).single['version'],
    DatabaseService.DATABASE_VERSION,
  );
  expect(
    (await service.getNote('kept-note'))?.content,
    'migrationsearchable body',
  );
  expect(await db.query('note_tags'), [
    {'noteId': 'kept-note', 'tagId': 'kept-tag'},
  ]);
  expect(
    (await db.query('app_revisions')).single['appCode'],
    '<main>Original revision</main>',
  );
  expect((await db.query('user_apps')).single['appState'], '{"retained":true}');
  final app = await service.getUserApp('kept-app');
  expect(app?.name, 'Preserved app');
  expect(app?.i18n['zh']?.name, localized ? '保留的应用' : null);
  expect(
    (await service.getAllUserApps()).single.i18n['zh']?.name,
    localized ? '保留的应用' : null,
  );
  expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

  // Localized edits must enter the durable outbox after either lineage's
  // upgrade; these triggers did not exist on either previously shipped v48
  // main or v63 index builds.
  await db.delete('sync_touch_log');
  await db.update(
    'user_apps',
    {'i18n': '{"zh":{"name":"更新"}}'},
    where: 'id = ?',
    whereArgs: ['kept-app'],
  );
  expect(
    await db.query('sync_touch_log', columns: ['entityTable', 'fieldName']),
    [
      {'entityTable': 'user_apps', 'fieldName': 'i18n'},
    ],
  );

  final indexer = NoteIndexService(
    service,
    ocrExtractor: stubOcrExtractor(service),
    figureExtractor: stubFigureExtractor(),
  );
  try {
    await indexer.reindexNote('kept-note');
    await indexer.flushPending();
    final matches = await service.searchChunksLexical('migrationsearchable');
    expect(matches, isNotEmpty);
    final chunks = await service.getSearchChunksByIds(
      matches.map((match) => match.docid).toList(),
    );
    expect(chunks.map((chunk) => chunk.noteId), everyElement('kept-note'));
  } finally {
    indexer.dispose();
  }

  await db.update(
    'user_apps',
    {'__deleted__': 1},
    where: 'id = ?',
    whereArgs: ['kept-app'],
  );
  expect(await service.getUserApp('kept-app'), isNull);
  expect(await service.getAllUserApps(), isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('merged_schema_');
    path = p.join(directory.path, 'notes.db');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  for (final recordedVersion in [48, 999]) {
    test(
      'main v48 with recorded version $recordedVersion upgrades completely',
      () async {
        final raw = await _main48Fixture(
          path,
          recordedVersion: recordedVersion,
        );
        await raw.close();
        final service = DatabaseService.createNew(databaseName: path);
        try {
          await _verifyUpgrade(service, localized: true);
          // Real databases retain PRAGMA999, so checking that pragma alone
          // would silently skip the pre-migration backup.
          final backups = directory.listSync().whereType<File>().where(
            (file) => p.basename(file.path).contains('_pre_migration_'),
          );
          expect(backups, hasLength(1));
          final backup = await databaseFactory.openDatabase(
            backups.single.path,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          try {
            expect(
              (await backup.query('user_apps')).single['i18n'],
              _localizedMetadata,
            );
            expect(
              await backup.rawQuery(
                "SELECT name FROM sqlite_master WHERE name='sync_pending_ops'",
              ),
              isEmpty,
            );
          } finally {
            await backup.close();
          }
        } finally {
          await service.close();
        }
      },
    );
  }

  for (final recordedVersion in [48, 999]) {
    test(
      'main v48 backup with recorded version $recordedVersion upgrades',
      () async {
        final raw = await _main48Fixture(
          path,
          recordedVersion: recordedVersion,
        );
        final service = DatabaseService.createNew(databaseName: path);
        try {
          await service.migrateBackupDatabase(raw, recordedVersion, 64);
          await raw.update('_schema_version', {'version': 64});
          await raw.close();
          await _verifyUpgrade(service, localized: true);
        } finally {
          if (raw.isOpen) await raw.close();
          await service.close();
        }
      },
    );
  }

  test(
    'index branch v63 gains localization without losing synced rows',
    () async {
      final seed = DatabaseService.createNew(databaseName: path);
      final raw = await seed.database;
      await raw.execute('DROP TRIGGER sync_touch_user_apps_au_i18n');
      await raw.execute('ALTER TABLE user_apps DROP COLUMN i18n');
      await raw.update('_schema_version', {'version': 63});
      await _seedRows(raw, localized: false);
      final touches = await raw.query('sync_touch_log');
      await seed.close();

      final service = DatabaseService.createNew(databaseName: path);
      try {
        expect(await (await service.database).query('sync_touch_log'), touches);
        await _verifyUpgrade(service, localized: false);
      } finally {
        await service.close();
      }
    },
  );

  test(
    'backup migration reports failures instead of merging partial schemas',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      try {
        // v51 requires the User-App-family tables, absent in this malformed
        // backup. A successful return would let recovery merge incomplete data.
        await expectLater(
          DatabaseService().migrateBackupDatabase(db, 50, 51),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    },
  );

  for (final missingTable in [false, true]) {
    test(
      'lost schema tracking is recovered (missing table: $missingTable)',
      () async {
        final raw = await _main48Fixture(path);
        if (missingTable) {
          await raw.execute('DROP TABLE _schema_version');
        } else {
          await raw.delete('_schema_version');
        }
        await raw.close();

        final service = DatabaseService.createNew(databaseName: path);
        try {
          await _verifyUpgrade(service, localized: true);
          expect(
            directory.listSync().whereType<File>().where(
              (file) => p.basename(file.path).contains('_pre_migration_'),
            ),
            hasLength(1),
          );
        } finally {
          await service.close();
        }
      },
    );
  }

  test(
    'partial sync plus complete search tables do not skip sync upgrades',
    () async {
      final raw = await _main48Fixture(path, recordedVersion: 999);
      // The sync control plane and search tables may be present from an
      // interrupted merge/upgrade while all content tables still have the
      // released schema. Table-name probes must not declare this v63 complete.
      final service = DatabaseService.createNew(databaseName: path);
      await service.migrateBackupDatabase(raw, 47, 48);
      await service.migrateBackupDatabase(raw, 62, 63);
      await raw.close();
      try {
        await _verifyUpgrade(service, localized: true);
        expect(
          await (await service.database).rawQuery(
            "SELECT name FROM sqlite_master WHERE type='trigger' "
            "AND name='sync_touch_notes_au_content'",
          ),
          hasLength(1),
        );
      } finally {
        await service.close();
      }
    },
  );

  test(
    'an interrupted pre-Spaces upgrade can replay the notes metadata step',
    () async {
      final raw = await _main48Fixture(path, recordedVersion: 41);
      await raw.execute('ALTER TABLE filters DROP COLUMN isSpace');
      await raw.close();
      final service = DatabaseService.createNew(databaseName: path);
      try {
        await _verifyUpgrade(service, localized: true);
      } finally {
        await service.close();
      }
    },
  );

  test('concurrent startup consumers share one backup and migration', () async {
    final raw = await _main48Fixture(path);
    await raw.close();
    final service = DatabaseService.createNew(databaseName: path);
    try {
      final connections = await Future.wait(
        List.generate(12, (_) => service.database),
      );
      expect(
        connections.every((db) => identical(db, connections.first)),
        isTrue,
      );
      expect(
        directory.listSync().whereType<File>().where(
          (file) => p.basename(file.path).contains('_pre_migration_'),
        ),
        hasLength(1),
      );
      await _verifyUpgrade(service, localized: true);
    } finally {
      await service.close();
    }
  });

  test(
    'failed initialization can retry on the same service after repair',
    () async {
      final raw = await _main48Fixture(path);
      await raw.execute('''
      CREATE TRIGGER reject_version_update BEFORE UPDATE ON _schema_version
      BEGIN SELECT RAISE(ABORT, 'simulated interrupted upgrade'); END
    ''');
      await raw.close();
      final service = DatabaseService.createNew(databaseName: path);
      await expectLater(service.database, throwsA(isA<DatabaseException>()));

      final repaired = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await repaired.execute('DROP TRIGGER reject_version_update');
      await repaired.close();
      try {
        await _verifyUpgrade(service, localized: true);
      } finally {
        await service.close();
      }
    },
  );

  test(
    'busy WAL checkpoint blocks upgrade until a complete backup is possible',
    () async {
      final writer = await _main48Fixture(path);
      await writer.rawQuery('PRAGMA journal_mode = WAL');
      await writer.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final reader = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final service = DatabaseService.createNew(databaseName: path);
      try {
        // This live read snapshot prevents FULL from checkpointing the newer
        // WAL frames below. SQLite returns busy=1 instead of throwing.
        await reader.execute('BEGIN');
        await reader.query('user_apps');
        await writer.update('user_apps', {'appState': '{"latest":true}'});
        await expectLater(
          service.database,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('checkpoint'),
            ),
          ),
        );
        expect((await writer.query('_schema_version')).single['version'], 48);
        expect(
          directory.listSync().whereType<File>().where(
            (file) => p.basename(file.path).contains('_pre_migration_'),
          ),
          isEmpty,
        );
      } finally {
        await reader.execute('ROLLBACK');
        await reader.close();
        await writer.close();
      }

      // Once the read lock clears, the same service must retry normally and
      // its backup must include the latest WAL-only application state.
      try {
        final upgraded = await service.database;
        expect(
          (await upgraded.query('user_apps')).single['appState'],
          '{"latest":true}',
        );
        final backupPath = directory
            .listSync()
            .whereType<File>()
            .singleWhere(
              (file) => p.basename(file.path).contains('_pre_migration_'),
            )
            .path;
        final backup = await databaseFactory.openDatabase(
          backupPath,
          options: OpenDatabaseOptions(singleInstance: false, readOnly: true),
        );
        try {
          expect(
            (await backup.query('user_apps')).single['appState'],
            '{"latest":true}',
          );
        } finally {
          await backup.close();
        }
      } finally {
        await service.close();
      }
    },
  );

  test(
    'close waits for a running upgrade and the next open gets a fresh connection',
    () async {
      final raw = await _main48Fixture(path);
      await raw.close();
      final service = DatabaseService.createNew(databaseName: path);
      final opening = service.database;
      await service.close();
      final first = await opening;
      expect(first.isOpen, isFalse);
      try {
        final reopened = await service.database;
        expect(identical(first, reopened), isFalse);
        expect(reopened.isOpen, isTrue);
        await _verifyUpgrade(service, localized: true);
      } finally {
        await service.close();
      }
    },
  );

  test(
    'released DB repairs FKs left by the historical rename-first v23 upgrade',
    () async {
      final raw = await _main48Fixture(path);
      await raw.execute(
        'ALTER TABLE app_revisions ADD COLUMN legacyExtension TEXT',
      );
      await raw.update('app_revisions', {
        'legacyExtension': 'retained extra data',
      });
      await raw.execute(
        'CREATE INDEX legacy_revision_extension ON app_revisions(legacyExtension)',
      );
      await raw.execute('CREATE TABLE legacy_revision_audit (revisionId TEXT)');
      await raw.execute('''
      CREATE TRIGGER legacy_revision_update AFTER UPDATE OF appCode ON app_revisions
      BEGIN INSERT INTO legacy_revision_audit VALUES(NEW.id); END
    ''');
      await raw.insert('user_app_libraries', {
        'id': 42,
        'app_uuid': 'kept-app-uuid',
        'revision_id': 1,
        'name': 'retained library',
      });
      final dependencyBytes = Uint8List.fromList([1, 2, 3, 4, 255]);
      await raw.rawUpdate(
        'UPDATE sqlite_sequence SET seq = 100 WHERE name = ?',
        ['user_app_libraries'],
      );
      await raw.insert('user_app_library_dependencies', {
        'id': 77,
        'library_id': 42,
        'local_path': 'library.js',
        'bytes': dependencyBytes,
      });
      await raw.insert('multi_function_apps', {
        'appId': 'kept-app',
        'addedAt': 1000,
      });

      // Reproduce the exact old v23 rename-first sequence. Modern SQLite
      // rewrites every child's REFERENCES target even with enforcement off.
      await raw.execute('PRAGMA foreign_keys = OFF');
      final appDdl =
          (await raw.rawQuery(
                "SELECT sql FROM sqlite_master WHERE name='user_apps'",
              )).single['sql']
              as String;
      await raw.execute('ALTER TABLE user_apps RENAME TO user_apps_old');
      await raw.execute(appDdl);
      await raw.execute('INSERT INTO user_apps SELECT * FROM user_apps_old');
      await raw.execute('DROP TABLE user_apps_old');
      for (final table in [
        'app_revisions',
        'user_app_libraries',
        'multi_function_apps',
      ]) {
        expect(
          (await raw.rawQuery(
            'PRAGMA foreign_key_list($table)',
          )).single['table'],
          'user_apps_old',
        );
      }
      await raw.close();

      final service = DatabaseService.createNew(databaseName: path);
      try {
        final repaired = await service.database;
        expect(await repaired.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        expect(
          (await repaired.query('app_revisions')).single['legacyExtension'],
          'retained extra data',
        );
        expect((await repaired.query('user_app_libraries')).single['id'], 42);
        final dependency = (await repaired.query(
          'user_app_library_dependencies',
        )).single;
        expect(dependency['id'], 77);
        expect(dependency['library_id'], 42);
        expect(dependency['bytes'], dependencyBytes);
        expect(await repaired.query('multi_function_apps'), hasLength(1));
        expect(
          await repaired.rawQuery(
            "SELECT name FROM sqlite_master WHERE name='legacy_revision_extension'",
          ),
          hasLength(1),
        );
        await repaired.update('app_revisions', {
          'appCode': '<main>Still writable</main>',
        });
        expect(
          (await repaired.query('legacy_revision_audit')).single['revisionId'],
          'kept-revision',
        );
        // The repaired child must remain writable with FK enforcement on.
        final newLibraryId = await repaired.insert('user_app_libraries', {
          'app_uuid': 'kept-app-uuid',
          'revision_id': 1,
          'name': 'new library',
        });
        expect(newLibraryId, greaterThan(100));
        await repaired.update('app_revisions', {
          'appCode': '<main>Original revision</main>',
        });
        await _verifyUpgrade(service, localized: true);
      } finally {
        await service.close();
      }
    },
  );

  test(
    'v23 adds UUID uniqueness without losing older app data or incoming FKs',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      try {
        final statements =
            (jsonDecode(
                      await File(
                        'test/fixtures/main_v48_schema.json',
                      ).readAsString(),
                    )
                    as List<dynamic>)
                .cast<String>();
        // v22 had no UUID constraint or i18n field. Keep a forward-added
        // custom column to detect accidental loss from a table reconstruction.
        final appDdl = statements
            .singleWhere(
              (statement) => statement.contains('CREATE TABLE user_apps('),
            )
            .replaceFirst('uuid TEXT NOT NULL UNIQUE', 'uuid TEXT NOT NULL')
            .replaceFirst(RegExp(r'        i18n TEXT,[^\n]*\n'), '');
        await db.execute(appDdl);
        await db.execute(
          'ALTER TABLE user_apps ADD COLUMN retainedExtension TEXT',
        );
        for (final table in [
          'app_revisions',
          'user_app_libraries',
          'multi_function_apps',
        ]) {
          await db.execute(
            statements.singleWhere(
              (statement) => statement.contains('CREATE TABLE $table('),
            ),
          );
        }
        await db.insert('user_apps', {
          'id': 'old-app',
          'uuid': 'stable-uuid',
          'name': 'Old app',
          'description': 'Preserve',
          'steps': '[]',
          'htmlContent': 'legacy html',
          'createdAt': 100,
          'updatedAt': 200,
          'retainedExtension': 'keep me',
        });
        await db.insert('app_revisions', {
          'id': 'old-revision',
          'appId': 'old-app',
          'revisionNumber': 7,
          'revisionTimestamp': 100,
          'userPrompt': 'original',
          'aiResponse': 'original',
          'appCode': '<html>preserved revision</html>',
        });
        await db.insert('user_app_libraries', {
          'app_uuid': 'stable-uuid',
          'revision_id': 7,
          'name': 'library',
        });
        await db.insert('multi_function_apps', {
          'appId': 'old-app',
          'addedAt': 100,
        });

        final service = DatabaseService();
        await service.migrateBackupDatabase(db, 22, 23);
        await service.migrateBackupDatabase(db, 22, 23);
        expect(
          (await db.query('user_apps')).single['retainedExtension'],
          'keep me',
        );
        expect(
          (await db.query('app_revisions')).single['appCode'],
          '<html>preserved revision</html>',
        );
        expect(await db.query('user_app_libraries'), hasLength(1));
        expect(await db.query('multi_function_apps'), hasLength(1));
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        await db.execute('PRAGMA foreign_keys = ON');
        await db.update('app_revisions', {'appCode': 'still writable'});
        await expectLater(
          db.insert('user_apps', {
            'id': 'duplicate',
            'uuid': 'stable-uuid',
            'name': 'Duplicate',
            'description': '',
            'steps': '[]',
            'htmlContent': '',
            'createdAt': 100,
            'updatedAt': 200,
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    },
  );
}
