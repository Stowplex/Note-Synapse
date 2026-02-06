import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/sync_staging.dart';

void main() {
  group('SyncStaging', () {
    late DatabaseService databaseService;
    late SyncStaging syncStaging;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database; // initialize
      syncStaging = SyncStaging(db: databaseService);
    });

    tearDown(() async {
      // Clean up staging files
      try {
        await syncStaging.cleanupStaleStagingFiles();
      } catch (_) {}
      await databaseService.close();
    });

    group('createStagingCopy', () {
      test('creates independent copy of database', () async {
        // Insert a note into the live database
        final db = await databaseService.database;
        final now = DateTime.now().millisecondsSinceEpoch;
        await db.insert('notes', {
          'id': 'test-note-1',
          'title': 'Live Note',
          'content': 'Live content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });

        // Create staging copy
        final stagingPath = await syncStaging.createStagingCopy();

        // Open staging database directly
        final stagingDb = await sqflite.openDatabase(stagingPath,
            singleInstance: false);

        // Verify data was copied
        final stagingNotes = await stagingDb.query('notes',
            where: 'id = ?', whereArgs: ['test-note-1']);
        expect(stagingNotes.length, 1);
        expect(stagingNotes.first['title'], 'Live Note');

        // Modify staging database
        await stagingDb.update(
          'notes',
          {'title': 'Modified in staging'},
          where: 'id = ?',
          whereArgs: ['test-note-1'],
        );
        await stagingDb.close();

        // Verify live database is unchanged
        final liveNotes = await db.query('notes',
            where: 'id = ?', whereArgs: ['test-note-1']);
        expect(liveNotes.first['title'], 'Live Note');

        // Cleanup
        await File(stagingPath).delete();
      });

      test('overwrites old staging file from failed sync', () async {
        final dbPath = await databaseService.getDatabasePath();
        final stagingPath = '${dbPath}_sync_staging';

        // Create a fake old staging file
        await File(stagingPath).writeAsString('old staging data');
        expect(await File(stagingPath).exists(), isTrue);

        // Create staging copy - should overwrite old staging
        final resultPath = await syncStaging.createStagingCopy();
        expect(resultPath, stagingPath);

        // Verify the staging file is a valid database, not the old text
        final stagingDb = await sqflite.openDatabase(resultPath,
            singleInstance: false);
        final tables = await stagingDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='notes'",
        );
        expect(tables.length, 1);
        await stagingDb.close();

        // Cleanup
        await File(stagingPath).delete();
      });
    });

    group('openStagingDb', () {
      test('succeeds on valid database', () async {
        final stagingPath = await syncStaging.createStagingCopy();

        final stagingDb = await syncStaging.openStagingDb(stagingPath);
        expect(stagingDb, isNotNull);

        // Verify we can query it
        final tables = await stagingDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        expect(tables.isNotEmpty, isTrue);

        await stagingDb.close();
        await File(stagingPath).delete();
      });

      test('throws on corrupted database', () async {
        final dbPath = await databaseService.getDatabasePath();
        final corruptPath = '${dbPath}_corrupt_staging';

        // Create a file with a valid SQLite header prefix but corrupted content
        // SQLite header is 100 bytes; we write a valid magic string followed by garbage
        final corruptData = List<int>.filled(4096, 0xFF);
        // Write 'SQLite format 3\0' as the first 16 bytes to trick the open
        final header = 'SQLite format 3\x00'.codeUnits;
        for (var i = 0; i < header.length; i++) {
          corruptData[i] = header[i];
        }
        await File(corruptPath).writeAsBytes(corruptData);

        try {
          await expectLater(
            syncStaging.openStagingDb(corruptPath),
            throwsA(isA<Exception>()),
          );
        } finally {
          // Cleanup
          try {
            await File(corruptPath).delete();
          } catch (_) {}
        }
      });
    });

    group('validateStagingDb', () {
      test('returns true for valid database', () async {
        final stagingPath = await syncStaging.createStagingCopy();
        final stagingDb = await sqflite.openDatabase(stagingPath,
            singleInstance: false);

        final result = await syncStaging.validateStagingDb(stagingDb);
        expect(result, isTrue);

        await stagingDb.close();
        await File(stagingPath).delete();
      });
    });

    group('atomicSwap', () {
      test('replaces live DB with staging DB data', () async {
        // Insert data into live DB
        final now = DateTime.now().millisecondsSinceEpoch;
        final db = await databaseService.database;
        await db.insert('notes', {
          'id': 'live-note',
          'title': 'Live Only',
          'content': 'Live content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });

        // Create staging copy
        final stagingPath = await syncStaging.createStagingCopy();

        // Open staging and add different data
        final stagingDb = await sqflite.openDatabase(stagingPath,
            singleInstance: false);
        await stagingDb.insert('notes', {
          'id': 'staging-note',
          'title': 'Staging Only',
          'content': 'Staging content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });
        // Delete the live note from staging to differentiate
        await stagingDb.delete('notes',
            where: 'id = ?', whereArgs: ['live-note']);
        await stagingDb.close();

        // Perform atomic swap
        await syncStaging.atomicSwap(stagingPath);

        // Verify live DB now has staging data
        final newDb = await databaseService.database;
        final notes = await newDb.query('notes');
        final noteIds = notes.map((n) => n['id']).toList();

        expect(noteIds, contains('staging-note'));
        expect(noteIds, isNot(contains('live-note')));
      });
    });

    group('cleanupStaleStagingFiles', () {
      test('removes leftover staging files', () async {
        final dbPath = await databaseService.getDatabasePath();
        final stagingPath = '${dbPath}_sync_staging';

        // Create fake staging files
        await File(stagingPath).writeAsString('stale staging');
        await File('$stagingPath-wal').writeAsString('stale wal');
        await File('$stagingPath-shm').writeAsString('stale shm');

        expect(await File(stagingPath).exists(), isTrue);
        expect(await File('$stagingPath-wal').exists(), isTrue);
        expect(await File('$stagingPath-shm').exists(), isTrue);

        // Cleanup
        await syncStaging.cleanupStaleStagingFiles();

        expect(await File(stagingPath).exists(), isFalse);
        expect(await File('$stagingPath-wal').exists(), isFalse);
        expect(await File('$stagingPath-shm').exists(), isFalse);
      });

      test('succeeds when no staging files exist', () async {
        // Should not throw
        await syncStaging.cleanupStaleStagingFiles();
      });
    });
  });
}
