import 'dart:convert';
import 'dart:io';

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
  expect((await db.query('_schema_version')).single['version'], 64);
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
}
