import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:note_synapse/models/sync_operation.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/merge_engine.dart';

void main() {
  group('MergeEngine', () {
    late Database stagingDb;
    late DatabaseService databaseService;
    late MergeEngine mergeEngine;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      // Create a separate in-memory database for staging
      stagingDb = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: (db, version) async {
          // Create notes table for testing
          await db.execute('''
            CREATE TABLE notes(
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              content TEXT NOT NULL,
              type TEXT NOT NULL,
              createdAt INTEGER NOT NULL,
              updatedAt INTEGER NOT NULL,
              scheduledAt TEXT,
              completeBy TEXT,
              status TEXT,
              completionPercentage REAL,
              pinned INTEGER NOT NULL DEFAULT 0,
              isArchived INTEGER NOT NULL DEFAULT 0,
              recurrenceRule TEXT
            )
          ''');

          // Create tags table for testing
          await db.execute('''
            CREATE TABLE tags(
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE,
              color TEXT NOT NULL,
              createdAt INTEGER NOT NULL,
              usageCount INTEGER NOT NULL DEFAULT 0
            )
          ''');

          // Create note_tags table for testing composite keys
          await db.execute('''
            CREATE TABLE note_tags(
              noteId TEXT NOT NULL,
              tagId TEXT NOT NULL,
              PRIMARY KEY (noteId, tagId)
            )
          ''');

          // Create sync_conflicts table
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sync_conflicts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              table_name TEXT NOT NULL,
              row_id TEXT NOT NULL,
              field_name TEXT NOT NULL,
              local_value TEXT,
              remote_value TEXT,
              remote_device_id TEXT NOT NULL,
              remote_timestamp TEXT NOT NULL,
              resolved INTEGER DEFAULT 0,
              created_at TEXT NOT NULL
            )
          ''');
        },
      );

      // Create a database service for testing ensureSyncConflictsTable
      databaseService = DatabaseService.createNew();
      await databaseService.database;

      mergeEngine = MergeEngine(
        db: stagingDb,
        currentSchemaVersion: 32,
      );
    });

    tearDown(() async {
      await stagingDb.close();
      await databaseService.close();
    });

    /// Helper to create a SyncOperation for testing.
    SyncOperation makeOp({
      required String table,
      required String rowId,
      required SyncAction action,
      required Map<String, SyncFieldValue> fields,
      String deviceId = 'device-1',
      int sequence = 1,
      DateTime? timestamp,
      int schemaVersion = 32,
    }) {
      return SyncOperation(
        id: 'op-$deviceId-$sequence',
        deviceId: deviceId,
        sequence: sequence,
        timestamp: timestamp ?? DateTime.now(),
        table: table,
        rowId: rowId,
        action: action,
        fields: fields,
        schemaVersion: schemaVersion,
      );
    }

    group('INSERT operations', () {
      test('creates new row in database', () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final op = makeOp(
          table: 'notes',
          rowId: 'note-1',
          action: SyncAction.insert,
          fields: {
            'id': SyncFieldValue(value: 'note-1', minVersion: 1),
            'title': SyncFieldValue(value: 'Test Note', minVersion: 1),
            'content': SyncFieldValue(value: 'Content here', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: now, minVersion: 1),
            'updatedAt': SyncFieldValue(value: now, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.inserted, 1);
        expect(result.updated, 0);
        expect(result.deleted, 0);
        expect(result.errors, isEmpty);

        // Verify the row exists
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-1']);
        expect(rows.length, 1);
        expect(rows.first['title'], 'Test Note');
        expect(rows.first['content'], 'Content here');
      });

      test('skips fields with minVersion > current schema version', () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final op = makeOp(
          table: 'notes',
          rowId: 'note-2',
          action: SyncAction.insert,
          fields: {
            'id': SyncFieldValue(value: 'note-2', minVersion: 1),
            'title': SyncFieldValue(value: 'Note with future field', minVersion: 1),
            'content': SyncFieldValue(value: 'Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: now, minVersion: 1),
            'updatedAt': SyncFieldValue(value: now, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
            // Future field that should be skipped
            'recurrenceRule': SyncFieldValue(value: '{"freq":"daily"}', minVersion: 50),
          },
        );

        // Use schema version 32 so minVersion 50 field is skipped
        final result = await mergeEngine.applyOperations([op]);

        expect(result.inserted, 1);
        expect(result.errors, isEmpty);

        // Verify the row exists but recurrenceRule is not set (null)
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-2']);
        expect(rows.length, 1);
        expect(rows.first['title'], 'Note with future field');
        expect(rows.first['recurrenceRule'], isNull);
      });

      test('treats INSERT as UPDATE when row already exists', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // Pre-insert a row
        await stagingDb.insert('notes', {
          'id': 'note-3',
          'title': 'Original Title',
          'content': 'Original Content',
          'type': 'note',
          'createdAt': now - 1000,
          'updatedAt': now - 1000,
          'pinned': 0,
          'isArchived': 0,
        });

        // Try to insert the same row
        final op = makeOp(
          table: 'notes',
          rowId: 'note-3',
          action: SyncAction.insert,
          timestamp: DateTime.fromMillisecondsSinceEpoch(now),
          fields: {
            'id': SyncFieldValue(value: 'note-3', minVersion: 1),
            'title': SyncFieldValue(value: 'Updated Title', minVersion: 1),
            'content': SyncFieldValue(value: 'Updated Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: now, minVersion: 1),
            'updatedAt': SyncFieldValue(value: now, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        // Should be counted as update, not insert
        expect(result.inserted, 0);
        expect(result.updated, 1);

        // Verify the row was updated
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-3']);
        expect(rows.length, 1);
        expect(rows.first['title'], 'Updated Title');
      });
    });

    group('UPDATE operations', () {
      test('modifies existing row with changed fields', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // Pre-insert a row
        await stagingDb.insert('notes', {
          'id': 'note-update-1',
          'title': 'Original Title',
          'content': 'Original Content',
          'type': 'note',
          'createdAt': now - 1000,
          'updatedAt': now - 1000,
          'pinned': 0,
          'isArchived': 0,
        });

        // Update some fields
        final op = makeOp(
          table: 'notes',
          rowId: 'note-update-1',
          action: SyncAction.update,
          timestamp: DateTime.fromMillisecondsSinceEpoch(now),
          fields: {
            'id': SyncFieldValue(value: 'note-update-1', minVersion: 1),
            'title': SyncFieldValue(value: 'New Title', minVersion: 1),
            'content': SyncFieldValue(value: 'Original Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: now - 1000, minVersion: 1),
            'updatedAt': SyncFieldValue(value: now, minVersion: 1),
            'pinned': SyncFieldValue(value: 1, minVersion: 1), // changed
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.updated, 1);
        expect(result.inserted, 0);

        // Verify the row was updated
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-update-1']);
        expect(rows.length, 1);
        expect(rows.first['title'], 'New Title');
        expect(rows.first['pinned'], 1);
        expect(rows.first['content'], 'Original Content'); // unchanged
      });

      test('creates row if it does not exist (upsert behavior)', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // Update a non-existent row
        final op = makeOp(
          table: 'notes',
          rowId: 'note-upsert-1',
          action: SyncAction.update,
          timestamp: DateTime.fromMillisecondsSinceEpoch(now),
          fields: {
            'id': SyncFieldValue(value: 'note-upsert-1', minVersion: 1),
            'title': SyncFieldValue(value: 'Upserted Note', minVersion: 1),
            'content': SyncFieldValue(value: 'Upserted Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: now, minVersion: 1),
            'updatedAt': SyncFieldValue(value: now, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        // Should be counted as insert since row didn't exist
        expect(result.inserted, 1);
        expect(result.updated, 0);

        // Verify the row was created
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-upsert-1']);
        expect(rows.length, 1);
        expect(rows.first['title'], 'Upserted Note');
      });
    });

    group('DELETE operations', () {
      test('removes existing row', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // Pre-insert a row
        await stagingDb.insert('notes', {
          'id': 'note-delete-1',
          'title': 'Note to Delete',
          'content': 'Content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });

        // Delete the row
        final op = makeOp(
          table: 'notes',
          rowId: 'note-delete-1',
          action: SyncAction.delete,
          fields: {}, // delete ops have empty fields
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.deleted, 1);

        // Verify the row was deleted
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-delete-1']);
        expect(rows, isEmpty);
      });

      test('is idempotent - deleting non-existent row does not error', () async {
        // Delete a row that doesn't exist
        final op = makeOp(
          table: 'notes',
          rowId: 'note-nonexistent',
          action: SyncAction.delete,
          fields: {},
        );

        final result = await mergeEngine.applyOperations([op]);

        // Should not error, but count as 0 deleted
        expect(result.deleted, 0);
        expect(result.errors, isEmpty);
      });
    });

    group('Timestamp-based conflict resolution', () {
      test('newer timestamp wins - remote wins', () async {
        final oldTime = DateTime.now().subtract(const Duration(minutes: 5));
        final newTime = DateTime.now();

        // Pre-insert a row with old timestamp
        await stagingDb.insert('notes', {
          'id': 'note-conflict-1',
          'title': 'Old Title',
          'content': 'Old Content',
          'type': 'note',
          'createdAt': oldTime.millisecondsSinceEpoch,
          'updatedAt': oldTime.millisecondsSinceEpoch,
          'pinned': 0,
          'isArchived': 0,
        });

        // Remote update with newer timestamp
        final op = makeOp(
          table: 'notes',
          rowId: 'note-conflict-1',
          action: SyncAction.update,
          timestamp: newTime,
          fields: {
            'id': SyncFieldValue(value: 'note-conflict-1', minVersion: 1),
            'title': SyncFieldValue(value: 'New Title from Remote', minVersion: 1),
            'content': SyncFieldValue(value: 'Old Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: oldTime.millisecondsSinceEpoch, minVersion: 1),
            'updatedAt': SyncFieldValue(value: newTime.millisecondsSinceEpoch, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.updated, 1);

        // Remote should win
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-conflict-1']);
        expect(rows.first['title'], 'New Title from Remote');
      });

      test('newer timestamp wins - local wins', () async {
        final newTime = DateTime.now();
        final oldTime = newTime.subtract(const Duration(minutes: 5));

        // Pre-insert a row with new timestamp
        await stagingDb.insert('notes', {
          'id': 'note-conflict-2',
          'title': 'New Local Title',
          'content': 'Content',
          'type': 'note',
          'createdAt': newTime.millisecondsSinceEpoch,
          'updatedAt': newTime.millisecondsSinceEpoch,
          'pinned': 0,
          'isArchived': 0,
        });

        // Remote update with older timestamp
        final op = makeOp(
          table: 'notes',
          rowId: 'note-conflict-2',
          action: SyncAction.update,
          timestamp: oldTime,
          fields: {
            'id': SyncFieldValue(value: 'note-conflict-2', minVersion: 1),
            'title': SyncFieldValue(value: 'Old Remote Title', minVersion: 1),
            'content': SyncFieldValue(value: 'Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: oldTime.millisecondsSinceEpoch, minVersion: 1),
            'updatedAt': SyncFieldValue(value: oldTime.millisecondsSinceEpoch, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        // Local should win (no update applied)
        expect(result.updated, 0);

        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-conflict-2']);
        expect(rows.first['title'], 'New Local Title');
      });
    });

    group('Conflict record creation', () {
      test('creates conflict record when timestamps are close and values differ', () async {
        final baseTime = DateTime.now();
        // Both within 1 second of each other
        final localTime = baseTime;
        final remoteTime = baseTime.add(const Duration(milliseconds: 500));

        // Pre-insert a row
        await stagingDb.insert('notes', {
          'id': 'note-close-conflict',
          'title': 'Local Title',
          'content': 'Content',
          'type': 'note',
          'createdAt': localTime.millisecondsSinceEpoch,
          'updatedAt': localTime.millisecondsSinceEpoch,
          'pinned': 0,
          'isArchived': 0,
        });

        // Remote update with close timestamp but different value
        final op = makeOp(
          table: 'notes',
          rowId: 'note-close-conflict',
          action: SyncAction.update,
          deviceId: 'remote-device',
          timestamp: remoteTime,
          fields: {
            'id': SyncFieldValue(value: 'note-close-conflict', minVersion: 1),
            'title': SyncFieldValue(value: 'Remote Title', minVersion: 1), // different!
            'content': SyncFieldValue(value: 'Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: localTime.millisecondsSinceEpoch, minVersion: 1),
            'updatedAt': SyncFieldValue(value: remoteTime.millisecondsSinceEpoch, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.conflictsCreated, greaterThan(0));

        // Check that conflict record was created
        final conflicts = await stagingDb.query('sync_conflicts', where: 'resolved = 0');
        expect(conflicts, isNotEmpty);

        final conflict = conflicts.firstWhere((c) => c['field_name'] == 'title');
        expect(conflict['table_name'], 'notes');
        expect(conflict['row_id'], 'note-close-conflict');
        expect(conflict['remote_device_id'], 'remote-device');
      });
    });

    group('Schema version filtering', () {
      test('fields with minVersion > currentSchemaVersion are not applied', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // Create engine with lower schema version
        final oldVersionEngine = MergeEngine(
          db: stagingDb,
          currentSchemaVersion: 25, // Lower than recurrenceRule's minVersion (30)
        );

        final op = makeOp(
          table: 'notes',
          rowId: 'note-schema-filter',
          action: SyncAction.insert,
          schemaVersion: 30,
          fields: {
            'id': SyncFieldValue(value: 'note-schema-filter', minVersion: 1),
            'title': SyncFieldValue(value: 'Schema Test', minVersion: 1),
            'content': SyncFieldValue(value: 'Content', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(value: now, minVersion: 1),
            'updatedAt': SyncFieldValue(value: now, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
            'recurrenceRule': SyncFieldValue(value: '{"freq":"weekly"}', minVersion: 30),
          },
        );

        final result = await oldVersionEngine.applyOperations([op]);

        expect(result.inserted, 1);

        // recurrenceRule should not be set because engine is at version 25
        final rows = await stagingDb.query('notes', where: 'id = ?', whereArgs: ['note-schema-filter']);
        expect(rows.length, 1);
        expect(rows.first['recurrenceRule'], isNull);
      });
    });

    group('MergeResult counts', () {
      test('correctly counts inserted, updated, deleted, and conflicts', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // Pre-insert rows for update and delete
        await stagingDb.insert('notes', {
          'id': 'note-to-update',
          'title': 'Update Me',
          'content': 'Content',
          'type': 'note',
          'createdAt': now - 10000,
          'updatedAt': now - 10000,
          'pinned': 0,
          'isArchived': 0,
        });
        await stagingDb.insert('notes', {
          'id': 'note-to-delete',
          'title': 'Delete Me',
          'content': 'Content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });

        final ops = [
          // Insert
          makeOp(
            table: 'notes',
            rowId: 'note-new',
            action: SyncAction.insert,
            sequence: 1,
            timestamp: DateTime.fromMillisecondsSinceEpoch(now),
            fields: {
              'id': SyncFieldValue(value: 'note-new', minVersion: 1),
              'title': SyncFieldValue(value: 'New Note', minVersion: 1),
              'content': SyncFieldValue(value: 'Content', minVersion: 1),
              'type': SyncFieldValue(value: 'note', minVersion: 1),
              'createdAt': SyncFieldValue(value: now, minVersion: 1),
              'updatedAt': SyncFieldValue(value: now, minVersion: 1),
              'pinned': SyncFieldValue(value: 0, minVersion: 1),
              'isArchived': SyncFieldValue(value: 0, minVersion: 1),
            },
          ),
          // Update
          makeOp(
            table: 'notes',
            rowId: 'note-to-update',
            action: SyncAction.update,
            sequence: 2,
            timestamp: DateTime.fromMillisecondsSinceEpoch(now),
            fields: {
              'id': SyncFieldValue(value: 'note-to-update', minVersion: 1),
              'title': SyncFieldValue(value: 'Updated!', minVersion: 1),
              'content': SyncFieldValue(value: 'Content', minVersion: 1),
              'type': SyncFieldValue(value: 'note', minVersion: 1),
              'createdAt': SyncFieldValue(value: now - 10000, minVersion: 1),
              'updatedAt': SyncFieldValue(value: now, minVersion: 1),
              'pinned': SyncFieldValue(value: 0, minVersion: 1),
              'isArchived': SyncFieldValue(value: 0, minVersion: 1),
            },
          ),
          // Delete
          makeOp(
            table: 'notes',
            rowId: 'note-to-delete',
            action: SyncAction.delete,
            sequence: 3,
            fields: {},
          ),
        ];

        final result = await mergeEngine.applyOperations(ops);

        expect(result.inserted, 1);
        expect(result.updated, 1);
        expect(result.deleted, 1);
        expect(result.errors, isEmpty);
      });
    });

    group('Composite primary keys', () {
      test('handles tables with composite primary keys', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // First insert the parent rows
        await stagingDb.insert('notes', {
          'id': 'note-for-tag',
          'title': 'Note',
          'content': 'Content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });
        await stagingDb.insert('tags', {
          'id': 'tag-1',
          'name': 'Tag 1',
          'color': '#FF0000',
          'createdAt': now,
          'usageCount': 0,
        });

        // Insert into note_tags with composite key
        final op = makeOp(
          table: 'note_tags',
          rowId: 'note-for-tag-tag-1', // Composite key: noteId-tagId
          action: SyncAction.insert,
          fields: {
            'noteId': SyncFieldValue(value: 'note-for-tag', minVersion: 1),
            'tagId': SyncFieldValue(value: 'tag-1', minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.inserted, 1);

        // Verify the row exists
        final rows = await stagingDb.query(
          'note_tags',
          where: 'noteId = ? AND tagId = ?',
          whereArgs: ['note-for-tag', 'tag-1'],
        );
        expect(rows.length, 1);
      });

      test('deletes rows with composite primary keys', () async {
        final now = DateTime.now().millisecondsSinceEpoch;

        // Insert parent rows and note_tag
        // Use IDs without dashes to avoid ambiguity in composite rowId parsing
        await stagingDb.insert('notes', {
          'id': 'noteDeleteTag',
          'title': 'Note',
          'content': 'Content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });
        await stagingDb.insert('tags', {
          'id': 'tagDelete',
          'name': 'Tag Delete',
          'color': '#FF0000',
          'createdAt': now,
          'usageCount': 0,
        });
        await stagingDb.insert('note_tags', {
          'noteId': 'noteDeleteTag',
          'tagId': 'tagDelete',
        });

        // Delete with composite key (noteId-tagId format)
        final op = makeOp(
          table: 'note_tags',
          rowId: 'noteDeleteTag-tagDelete',
          action: SyncAction.delete,
          fields: {},
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.deleted, 1);

        // Verify the row is deleted
        final rows = await stagingDb.query(
          'note_tags',
          where: 'noteId = ? AND tagId = ?',
          whereArgs: ['noteDeleteTag', 'tagDelete'],
        );
        expect(rows, isEmpty);
      });
    });

    group('Error handling', () {
      test('handles database errors gracefully', () async {
        // Try to insert into a non-existent table
        final op = makeOp(
          table: 'nonexistent_table',
          rowId: 'row-1',
          action: SyncAction.insert,
          fields: {
            'id': SyncFieldValue(value: 'row-1', minVersion: 1),
          },
        );

        final result = await mergeEngine.applyOperations([op]);

        expect(result.errors, isNotEmpty);
        expect(result.errors.first, contains('nonexistent_table'));
      });
    });
  });

  group('DatabaseService.ensureSyncConflictsTable', () {
    late DatabaseService databaseService;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('creates sync_conflicts table', () async {
      await databaseService.ensureSyncConflictsTable();

      final db = await databaseService.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_conflicts'",
      );

      expect(tables.length, 1);
    });

    test('table has correct schema', () async {
      await databaseService.ensureSyncConflictsTable();

      final db = await databaseService.database;
      final columns = await db.rawQuery("PRAGMA table_info(sync_conflicts)");

      final columnNames = columns.map((c) => c['name'] as String).toSet();

      expect(columnNames, contains('id'));
      expect(columnNames, contains('table_name'));
      expect(columnNames, contains('row_id'));
      expect(columnNames, contains('field_name'));
      expect(columnNames, contains('local_value'));
      expect(columnNames, contains('remote_value'));
      expect(columnNames, contains('remote_device_id'));
      expect(columnNames, contains('remote_timestamp'));
      expect(columnNames, contains('resolved'));
      expect(columnNames, contains('created_at'));
    });

    test('is idempotent - can be called multiple times', () async {
      await databaseService.ensureSyncConflictsTable();
      await databaseService.ensureSyncConflictsTable();
      await databaseService.ensureSyncConflictsTable();

      final db = await databaseService.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_conflicts'",
      );

      expect(tables.length, 1);
    });
  });

  group('DatabaseService.getSyncConflicts', () {
    late DatabaseService databaseService;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
      await databaseService.ensureSyncConflictsTable();
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('returns empty list when no conflicts', () async {
      final conflicts = await databaseService.getSyncConflicts();
      expect(conflicts, isEmpty);
    });

    test('returns only unresolved conflicts', () async {
      final db = await databaseService.database;

      // Insert unresolved conflict
      await db.insert('sync_conflicts', {
        'table_name': 'notes',
        'row_id': 'note-1',
        'field_name': 'title',
        'local_value': 'Local',
        'remote_value': 'Remote',
        'remote_device_id': 'device-1',
        'remote_timestamp': DateTime.now().toIso8601String(),
        'resolved': 0,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Insert resolved conflict
      await db.insert('sync_conflicts', {
        'table_name': 'notes',
        'row_id': 'note-2',
        'field_name': 'title',
        'local_value': 'Local',
        'remote_value': 'Remote',
        'remote_device_id': 'device-2',
        'remote_timestamp': DateTime.now().toIso8601String(),
        'resolved': 1,
        'created_at': DateTime.now().toIso8601String(),
      });

      final conflicts = await databaseService.getSyncConflicts();

      expect(conflicts.length, 1);
      expect(conflicts.first['row_id'], 'note-1');
    });
  });
}
