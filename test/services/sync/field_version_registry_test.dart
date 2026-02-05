import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/field_version_registry.dart';

void main() {
  group('FieldVersionRegistry enforcement', () {
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

    test('registry covers all synced tables', () {
      for (final table in syncedTables) {
        expect(
          fieldVersionRegistry.containsKey(table),
          isTrue,
          reason: 'Synced table "$table" is missing from fieldVersionRegistry. '
              'Add it with all its columns.',
        );
      }
    });

    test('registry does not contain non-synced tables', () {
      for (final table in fieldVersionRegistry.keys) {
        expect(
          syncedTables.contains(table),
          isTrue,
          reason:
              'Table "$table" is in fieldVersionRegistry but not in syncedTables. '
              'Either add it to syncedTables or remove it from the registry.',
        );
      }
    });

    test('every actual column is in the registry for each synced table',
        () async {
      final db = await databaseService.database;

      for (final table in syncedTables) {
        final columns = await db.rawQuery('PRAGMA table_info($table)');
        final actualColumnNames =
            columns.map((c) => c['name'] as String).toSet();
        final registryColumns =
            fieldVersionRegistry[table]?.keys.toSet() ?? <String>{};

        final missingFromRegistry = actualColumnNames.difference(registryColumns);
        expect(
          missingFromRegistry,
          isEmpty,
          reason:
              'Table "$table" has columns $missingFromRegistry in the database '
              'but missing from fieldVersionRegistry. '
              'Did you add a migration without updating the registry?',
        );
      }
    });

    test('registry does not reference non-existent columns', () async {
      final db = await databaseService.database;

      for (final table in syncedTables) {
        final columns = await db.rawQuery('PRAGMA table_info($table)');
        final actualColumnNames =
            columns.map((c) => c['name'] as String).toSet();
        final registryColumns =
            fieldVersionRegistry[table]?.keys.toSet() ?? <String>{};

        final extraInRegistry = registryColumns.difference(actualColumnNames);
        expect(
          extraInRegistry,
          isEmpty,
          reason: 'Table "$table" has columns $extraInRegistry in '
              'fieldVersionRegistry that do not exist in the actual database. '
              'Did you remove a column without updating the registry?',
        );
      }
    });

    test('no minVersion exceeds DATABASE_VERSION', () {
      for (final entry in fieldVersionRegistry.entries) {
        final table = entry.key;
        for (final colEntry in entry.value.entries) {
          expect(
            colEntry.value,
            lessThanOrEqualTo(DatabaseService.DATABASE_VERSION),
            reason:
                'Column "$table.${colEntry.key}" has minVersion ${colEntry.value} '
                'which exceeds DATABASE_VERSION '
                '(${DatabaseService.DATABASE_VERSION}). '
                'Update DATABASE_VERSION or fix the registry.',
          );
        }
      }
    });

    test('all minVersion values are positive', () {
      for (final entry in fieldVersionRegistry.entries) {
        final table = entry.key;
        for (final colEntry in entry.value.entries) {
          expect(
            colEntry.value,
            greaterThan(0),
            reason:
                'Column "$table.${colEntry.key}" has minVersion ${colEntry.value} '
                'which must be a positive integer.',
          );
        }
      }
    });

    test('all synced tables exist in the live database', () async {
      final db = await databaseService.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final actualTables =
          tables.map((t) => t['name'] as String).toSet();

      for (final table in syncedTables) {
        expect(
          actualTables.contains(table),
          isTrue,
          reason: 'Synced table "$table" does not exist in the live database. '
              'Was the table dropped or renamed?',
        );
      }
    });
  });
}
