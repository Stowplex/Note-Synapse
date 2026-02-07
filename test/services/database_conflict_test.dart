import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/logger_service.dart';

void main() {
  group('DatabaseService Sync Conflicts', () {
    late DatabaseService dbService;

    setUpAll(() {
      // Initialize FFI for testing
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // LoggerService.initialize(verbose: false);
    });

    tearDown(() async {
      try {
        final dbPath = await dbService.getDatabasePath();
        await dbService.close();
        await databaseFactory.deleteDatabase(dbPath);
      } catch (e) {
        // Ignore close errors
      }
    });

    test('sync_conflicts table is created in new database', () async {
      // Create a fresh database
      dbService = DatabaseService.createNew();
      final db = await dbService.database;

      // Check for table existence
      final result = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_conflicts'",
      );

      expect(result, isNotEmpty, reason: 'sync_conflicts table should exist');
    });

    test('ensureSyncConflictsTable is safe to call multiple times', () async {
      dbService = DatabaseService.createNew();
      final db = await dbService.database;

      // Should not throw
      await dbService.ensureSyncConflictsTable();
      await dbService.ensureSyncConflictsTable();

      // Verify still exists
      final result = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_conflicts'",
      );
      expect(result, isNotEmpty);
    });

    test('can insert and retrieve conflicts', () async {
      dbService = DatabaseService.createNew();
      final db = await dbService.database;

      // Insert a fake conflict manually to verify schema
      await db.insert('sync_conflicts', {
        'table_name': 'notes',
        'row_id': 'test-note-1',
        'field_name': 'title',
        'local_value': 'Local Title',
        'remote_value': 'Remote Title',
        'remote_device_id': 'device-x',
        'remote_timestamp': DateTime.now().toIso8601String(),
        'resolved': 0,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Retrieve using service method
      final conflicts = await dbService.getSyncConflicts();
      expect(conflicts.length, 1);
      expect(conflicts.first['local_value'], 'Local Title');
      expect(conflicts.first['remote_value'], 'Remote Title');
    });
  });
}
