import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/field_version_registry.dart';
import 'package:note_synapse/services/sync/sync_spec_generator.dart';

void main() {
  group('SyncSpecGenerator', () {
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

    test('generated spec contains all required sections', () async {
      final generator = SyncSpecGenerator(db: databaseService);
      final spec = await generator.generate(schemaVersion: 36);

      // Title
      expect(spec, contains('# Note-Synapse Sync Specification v1'));

      // Format Version
      expect(spec, contains('## Format Version'));
      expect(spec, contains('Spec version: 1'));
      expect(spec, contains('Schema version: 36'));

      // Cipher Registry
      expect(spec, contains('## Cipher Registry'));
      expect(spec, contains('aes-256-gcm'));
      expect(spec, contains('xchacha20-poly1305'));
      expect(spec, contains('### Encryption Procedure'));
      expect(spec, contains('### HMAC Verification'));

      // KDF Specification
      expect(spec, contains('## KDF Specification'));
      expect(spec, contains('Argon2id'));

      // Oplog Format
      expect(spec, contains('## Oplog Format'));
      expect(spec, contains('### Operation Schema'));
      expect(spec, contains('### Merge Rules'));
      expect(spec, contains('### Replay Algorithm'));

      // Snapshot Format
      expect(spec, contains('## Snapshot Format'));

      // Attachment Convention
      expect(spec, contains('## Attachment Convention'));

      // SQLite Schema
      expect(spec, contains('## SQLite Schema'));
    });

    test('SQLite schema section includes CREATE TABLE for all synced tables',
        () async {
      final generator = SyncSpecGenerator(db: databaseService);
      final spec = await generator.generate(schemaVersion: 36);

      for (final table in syncedTables) {
        expect(spec, contains('CREATE TABLE $table'),
            reason:
                'Expected CREATE TABLE statement for synced table "$table"');
      }
    });

    test('schema version is correctly embedded', () async {
      final generator = SyncSpecGenerator(db: databaseService);

      final spec42 = await generator.generate(schemaVersion: 42);
      expect(spec42, contains('Schema version: 42'));

      final spec1 = await generator.generate(schemaVersion: 1);
      expect(spec1, contains('Schema version: 1'));
    });

    test('spec is valid markdown (basic structure check)', () async {
      final generator = SyncSpecGenerator(db: databaseService);
      final spec = await generator.generate(schemaVersion: 36);

      // Should start with a top-level heading
      expect(spec.trimLeft(), startsWith('#'));

      // Should have multiple sections (h2 headings)
      final h2Matches = RegExp(r'^## ', multiLine: true).allMatches(spec);
      expect(h2Matches.length, greaterThanOrEqualTo(6),
          reason: 'Expected at least 6 h2 sections');

      // Should contain code blocks (triple backticks)
      final codeBlockMatches = RegExp(r'```').allMatches(spec);
      // Code blocks come in pairs (open + close)
      expect(codeBlockMatches.length % 2, equals(0),
          reason: 'Code blocks should be properly paired');
      expect(codeBlockMatches.length, greaterThan(0),
          reason: 'Expected at least one code block');

      // Should contain table syntax (pipe characters for cipher registry table)
      expect(spec, contains('|'));
    });
  });
}
