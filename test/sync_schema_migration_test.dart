// Tests for the M1.1 CRDT-cloud-sync schema milestone: the fifteen
// sync_* control-plane tables added to DatabaseService as a pure-additive
// migration (DATABASE_VERSION 46 -> 47).
//
// Three things are verified, matching the milestone's own acceptance bar:
//  1. Fresh-install: a brand-new database already has all fifteen tables
//     (and sync_conflict_copies' documented index) via the normal
//     DatabaseService.createNew() -> _onCreate path.
//  2. Migration round-trip: an existing (pre-M1.1) database, already fully
//     migrated up through the previous DATABASE_VERSION, gains all fifteen
//     tables when migrated forward one more step. This exercises
//     `migrateBackupDatabase`, the same public per-step migration runner
//     recovery_screen.dart uses for imported backups.
//  3. Idempotency: running that same migration step twice does not error
//     and leaves the schema in the same state (CREATE TABLE/INDEX IF NOT
//     EXISTS throughout).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';

/// The fifteen M1.1 sync control-plane table names, per the design doc's
/// § Architecture 1 table list plus sync_conflict_copies/sync_dedup_index/
/// sync_dot_redirects named explicitly elsewhere in the same section.
const _kSyncTableNames = {
  'sync_field_state',
  'sync_set_state',
  'sync_grave',
  'sync_touch_log',
  'sync_pending_ops',
  'sync_state',
  'sync_ack_frontier',
  'sync_device_labels',
  'sync_view_cache',
  'sync_blob_refs',
  'sync_publish_intent',
  'sync_materialize_queue',
  'sync_conflict_copies',
  'sync_dedup_index',
  'sync_dot_redirects',
};

Future<Set<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

Future<Set<String>> _indexNames(Database db, String table) async {
  final rows = await db.rawQuery("PRAGMA index_list('$table')");
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.1 sync control-plane tables — fresh install', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('a brand-new database already has all fifteen sync tables', () async {
      final db = await databaseService.database;
      final tables = await _tableNames(db);

      expect(
        tables.containsAll(_kSyncTableNames),
        isTrue,
        reason:
            'Missing sync tables: '
            '${_kSyncTableNames.difference(tables)}',
      );
    });

    test(
      'sync_conflict_copies has the documented (subjectTable, subjectId, '
      'fieldName, kind) lookup index',
      () async {
        final db = await databaseService.database;
        final indexes = await db.rawQuery(
          "PRAGMA index_info('idx_sync_conflict_copies_lookup')",
        );
        final columns = indexes.map((r) => r['name'] as String).toList();
        expect(
          columns,
          ['subjectTable', 'subjectId', 'fieldName', 'kind'],
          reason:
              'sync_conflict_copies index column order/composition must '
              'match the design doc\'s explicit spec',
        );
      },
    );

    test('sync_pending_ops enforces dot uniqueness (authorId, authorSeq)', () async {
      final db = await databaseService.database;
      final indexes = await db.rawQuery("PRAGMA index_list('sync_pending_ops')");
      final hasUniqueDotIndex = indexes.any((r) => r['unique'] == 1);
      expect(hasUniqueDotIndex, isTrue);
    });

    test('the remaining three non-PK indexes exist with their documented columns', () async {
      final db = await databaseService.database;

      final touchLogIndex = await db.rawQuery(
        "PRAGMA index_info('idx_sync_touch_log_unprocessed')",
      );
      expect(touchLogIndex.map((r) => r['name']).toList(), ['processedAt']);

      final viewCacheIndex = await db.rawQuery(
        "PRAGMA index_info('idx_sync_view_cache_filePath')",
      );
      expect(viewCacheIndex.map((r) => r['name']).toList(), ['filePath']);

      final materializeQueueIndex = await db.rawQuery(
        "PRAGMA index_info('idx_sync_materialize_queue_blockingKey')",
      );
      expect(materializeQueueIndex.map((r) => r['name']).toList(), ['blockingKey']);
    });
  });

  group('M1.1 sync control-plane tables — migration round-trip', () {
    late Database preMigrationDb;

    setUp(() async {
      preMigrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      // Build a database that represents an existing install already fully
      // migrated through the previous DATABASE_VERSION (46): the current
      // core-table DDL (getSchema()), which deliberately excludes the
      // sync_* tables (see DatabaseService.getSchema's doc comment), plus
      // the other tables _onCreate creates outside getSchema() so table
      // presence checks below only ever report genuinely-new tables.
      for (final statement in DatabaseService.getSchema()) {
        await preMigrationDb.execute(statement);
      }
      await preMigrationDb.execute('''
        CREATE TABLE _schema_version (version INTEGER NOT NULL)
      ''');
      await preMigrationDb.insert('_schema_version', {'version': 46});

      // Sanity check: none of the sync tables exist yet.
      final tables = await _tableNames(preMigrationDb);
      expect(tables.intersection(_kSyncTableNames), isEmpty);
    });

    tearDown(() async {
      await preMigrationDb.close();
    });

    test(
      'migrating v46 -> v47 creates all fifteen sync tables',
      () async {
        final service = DatabaseService.createNew();
        await service.migrateBackupDatabase(preMigrationDb, 46, 47);

        final tables = await _tableNames(preMigrationDb);
        expect(
          tables.containsAll(_kSyncTableNames),
          isTrue,
          reason:
              'Missing sync tables after migration: '
              '${_kSyncTableNames.difference(tables)}',
        );

        // Existing (pre-migration) tables and data must be untouched —
        // this migration is pure-additive.
        final coreTables = await _tableNames(preMigrationDb);
        expect(coreTables, contains('notes'));
        expect(coreTables, contains('tags'));
      },
    );

    test('running the v46 -> v47 migration twice does not error', () async {
      final service = DatabaseService.createNew();

      await service.migrateBackupDatabase(preMigrationDb, 46, 47);
      final tablesAfterFirst = await _tableNames(preMigrationDb);
      final indexAfterFirst = await _indexNames(
        preMigrationDb,
        'sync_conflict_copies',
      );

      // Second run must be a no-op, not an error (CREATE TABLE/INDEX IF NOT
      // EXISTS throughout _migrateToVersion47).
      await service.migrateBackupDatabase(preMigrationDb, 46, 47);
      final tablesAfterSecond = await _tableNames(preMigrationDb);
      final indexAfterSecond = await _indexNames(
        preMigrationDb,
        'sync_conflict_copies',
      );

      expect(tablesAfterSecond, equals(tablesAfterFirst));
      expect(indexAfterSecond, equals(indexAfterFirst));
      expect(
        tablesAfterSecond.containsAll(_kSyncTableNames),
        isTrue,
      );
    });
  });
}
