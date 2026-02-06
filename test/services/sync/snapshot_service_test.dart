import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/field_version_registry.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:note_synapse/services/sync/snapshot_service.dart';
import 'package:note_synapse/services/sync/sync_encryption_service.dart';

void main() {
  group('SnapshotService', () {
    late DatabaseService databaseService;
    late Directory tempDir;
    late FolderSyncProvider provider;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
      tempDir = Directory.systemTemp.createTempSync('snapshot_test_');
      provider = FolderSyncProvider(rootPath: tempDir.path);
    });

    tearDown(() async {
      await databaseService.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    group('writeSnapshot', () {
      test('creates correct structure with schemaVersion, timestamp, tables, referencedAttachments',
          () async {
        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        await snapshotService.writeSnapshot(36);

        // Verify file was written
        expect(await provider.exists('snapshots/latest.json'), isTrue);

        // Read and parse the snapshot
        final bytes = await provider.readFile('snapshots/latest.json');
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

        expect(json['schemaVersion'], 36);
        expect(json['timestamp'], isNotNull);
        expect(DateTime.tryParse(json['timestamp'] as String), isNotNull);
        expect(json['tables'], isA<Map<String, dynamic>>());
        expect(json['referencedAttachments'], isA<List>());
      });

      test('includes all synced tables even when empty', () async {
        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        await snapshotService.writeSnapshot(36);

        final bytes = await provider.readFile('snapshots/latest.json');
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final tables = json['tables'] as Map<String, dynamic>;

        // All synced tables should be present
        for (final tableName in syncedTables) {
          expect(tables.containsKey(tableName), isTrue,
              reason: 'Expected table $tableName to be in snapshot');
          expect(tables[tableName], isA<List>());
        }
      });

      test('includes table data in snapshot', () async {
        final db = await databaseService.database;
        final now = DateTime.now().millisecondsSinceEpoch;

        // Insert some test data
        await db.insert('notes', {
          'id': 'note-1',
          'title': 'Test Note',
          'content': 'Test content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });
        await db.insert('tags', {
          'id': 'tag-1',
          'name': 'Test Tag',
          'color': '#FF0000',
          'createdAt': now,
          'usageCount': 5,
        });

        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        await snapshotService.writeSnapshot(36);

        final bytes = await provider.readFile('snapshots/latest.json');
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final tables = json['tables'] as Map<String, dynamic>;

        final notes = tables['notes'] as List<dynamic>;
        expect(notes.length, 1);
        expect((notes[0] as Map<String, dynamic>)['id'], 'note-1');
        expect((notes[0] as Map<String, dynamic>)['title'], 'Test Note');

        final tags = tables['tags'] as List<dynamic>;
        expect(tags.length, 1);
        expect((tags[0] as Map<String, dynamic>)['id'], 'tag-1');
        expect((tags[0] as Map<String, dynamic>)['name'], 'Test Tag');
      });

      test('collects referenced attachments from both attachments and conversation_attachments tables',
          () async {
        final db = await databaseService.database;
        final now = DateTime.now().millisecondsSinceEpoch;

        // Create a note for attachments
        await db.insert('notes', {
          'id': 'note-1',
          'title': 'Note',
          'content': 'Content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });

        // Create a message for conversation_attachments
        await db.insert('conversation_messages', {
          'id': 'msg-1',
          'type': 'user',
          'content': 'Hello',
          'timestamp': now,
        });

        // Insert attachments
        await db.insert('attachments', {
          'id': 'att-1',
          'noteId': 'note-1',
          'filePath': 'attachments/uuid1.pdf',
          'fileName': 'doc.pdf',
          'fileType': 'application/pdf',
          'isRelativePath': 1,
          'createdAt': now,
        });
        await db.insert('attachments', {
          'id': 'att-2',
          'noteId': 'note-1',
          'filePath': 'attachments/uuid2.png',
          'fileName': 'image.png',
          'fileType': 'image/png',
          'isRelativePath': 1,
          'createdAt': now,
        });

        // Insert conversation attachments
        await db.insert('conversation_attachments', {
          'id': 'conv-att-1',
          'messageId': 'msg-1',
          'filePath': 'attachments/uuid3.jpg',
          'fileName': 'photo.jpg',
          'fileType': 'image/jpeg',
          'isRelativePath': 1,
          'createdAt': now,
        });
        // Duplicate path to test deduplication
        await db.insert('conversation_attachments', {
          'id': 'conv-att-2',
          'messageId': 'msg-1',
          'filePath': 'attachments/uuid1.pdf', // same as att-1
          'fileName': 'doc.pdf',
          'fileType': 'application/pdf',
          'isRelativePath': 1,
          'createdAt': now,
        });

        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        await snapshotService.writeSnapshot(36);

        final bytes = await provider.readFile('snapshots/latest.json');
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final attachments = (json['referencedAttachments'] as List<dynamic>)
            .cast<String>()
            .toSet();

        // Should have deduplicated list
        expect(attachments.length, 3);
        expect(attachments.contains('attachments/uuid1.pdf'), isTrue);
        expect(attachments.contains('attachments/uuid2.png'), isTrue);
        expect(attachments.contains('attachments/uuid3.jpg'), isTrue);
      });

      test('encrypts when encryption service provided', () async {
        final encryption = await SyncEncryptionService.create(
          passphrase: 'test-passphrase',
          cipherId: 'aes-256-gcm',
          salt: 'dGVzdC1zYWx0LWZvci10ZXN0aW5n',
          kdfMemory: 1024,
          kdfIterations: 1,
          kdfParallelism: 1,
        );

        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
          encryption: encryption,
        );

        await snapshotService.writeSnapshot(36);

        // Read the raw bytes
        final bytes = await provider.readFile('snapshots/latest.json');

        // Trying to parse as JSON should fail (it's encrypted)
        expect(() => jsonDecode(utf8.decode(bytes)), throwsFormatException);

        // But decrypting should give valid JSON
        final decrypted = await encryption.decrypt(bytes);
        final json = jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
        expect(json['schemaVersion'], 36);
      });
    });

    group('readSnapshot', () {
      test('returns null when no snapshot exists', () async {
        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        final snapshot = await snapshotService.readSnapshot();
        expect(snapshot, isNull);
      });

      test('reads and parses unencrypted snapshot', () async {
        // Manually write a snapshot file
        final snapshotData = {
          'schemaVersion': 36,
          'timestamp': '2026-02-05T10:30:00.000Z',
          'tables': {
            'notes': [
              {'id': 'note-1', 'title': 'Test Note'},
            ],
            'tags': [],
          },
          'referencedAttachments': ['attachments/file1.pdf'],
        };

        await provider.writeFile(
          'snapshots/latest.json',
          Uint8List.fromList(utf8.encode(jsonEncode(snapshotData))),
        );

        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        final snapshot = await snapshotService.readSnapshot();

        expect(snapshot, isNotNull);
        expect(snapshot!.schemaVersion, 36);
        expect(snapshot.timestamp, DateTime.utc(2026, 2, 5, 10, 30));
        expect(snapshot.tables['notes']!.length, 1);
        expect(snapshot.tables['notes']![0]['id'], 'note-1');
        expect(snapshot.referencedAttachments, ['attachments/file1.pdf']);
      });

      test('decrypts and parses encrypted snapshot', () async {
        final encryption = await SyncEncryptionService.create(
          passphrase: 'test-passphrase',
          cipherId: 'aes-256-gcm',
          salt: 'dGVzdC1zYWx0LWZvci10ZXN0aW5n',
          kdfMemory: 1024,
          kdfIterations: 1,
          kdfParallelism: 1,
        );

        final snapshotData = {
          'schemaVersion': 36,
          'timestamp': '2026-02-05T10:30:00.000Z',
          'tables': {
            'notes': [
              {'id': 'encrypted-note', 'title': 'Encrypted Note'},
            ],
          },
          'referencedAttachments': [],
        };

        final encrypted = await encryption.encrypt(
          Uint8List.fromList(utf8.encode(jsonEncode(snapshotData))),
        );
        await provider.writeFile('snapshots/latest.json', encrypted);

        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
          encryption: encryption,
        );

        final snapshot = await snapshotService.readSnapshot();

        expect(snapshot, isNotNull);
        expect(snapshot!.schemaVersion, 36);
        expect(snapshot.tables['notes']![0]['id'], 'encrypted-note');
      });

      test('roundtrip: write snapshot then read it back', () async {
        final db = await databaseService.database;
        final now = DateTime.now().millisecondsSinceEpoch;

        // Insert test data
        await db.insert('notes', {
          'id': 'roundtrip-note',
          'title': 'Roundtrip Test',
          'content': 'Content for roundtrip',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 1,
          'isArchived': 0,
        });

        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        await snapshotService.writeSnapshot(36);
        final snapshot = await snapshotService.readSnapshot();

        expect(snapshot, isNotNull);
        expect(snapshot!.schemaVersion, 36);
        expect(snapshot.tables['notes']!.length, 1);
        expect(snapshot.tables['notes']![0]['id'], 'roundtrip-note');
        expect(snapshot.tables['notes']![0]['title'], 'Roundtrip Test');
        expect(snapshot.tables['notes']![0]['pinned'], 1);
      });
    });

    group('applySnapshotToDb', () {
      late DatabaseService targetDbService;

      setUp(() async {
        targetDbService = DatabaseService.createNew();
        await targetDbService.database;
      });

      tearDown(() async {
        await targetDbService.close();
      });

      test('populates empty database from snapshot', () async {
        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        final snapshot = Snapshot(
          schemaVersion: 36,
          timestamp: DateTime.now().toUtc(),
          tables: {
            'notes': [
              {
                'id': 'snapshot-note-1',
                'title': 'Snapshot Note',
                'content': 'From snapshot',
                'type': 'note',
                'createdAt': DateTime.now().millisecondsSinceEpoch,
                'updatedAt': DateTime.now().millisecondsSinceEpoch,
                'pinned': 0,
                'isArchived': 0,
              },
            ],
            'tags': [
              {
                'id': 'snapshot-tag-1',
                'name': 'Snapshot Tag',
                'color': '#00FF00',
                'createdAt': DateTime.now().millisecondsSinceEpoch,
                'usageCount': 0,
              },
            ],
          },
          referencedAttachments: [],
        );

        final targetDb = await targetDbService.database;
        await snapshotService.applySnapshotToDb(snapshot, targetDb);

        // Verify data was inserted
        final notes = await targetDb.query('notes');
        expect(notes.length, 1);
        expect(notes[0]['id'], 'snapshot-note-1');
        expect(notes[0]['title'], 'Snapshot Note');

        final tags = await targetDb.query('tags');
        expect(tags.length, 1);
        expect(tags[0]['id'], 'snapshot-tag-1');
        expect(tags[0]['name'], 'Snapshot Tag');
      });

      test('replaces existing data in database', () async {
        final targetDb = await targetDbService.database;
        final now = DateTime.now().millisecondsSinceEpoch;

        // Pre-populate with existing data
        await targetDb.insert('notes', {
          'id': 'existing-note',
          'title': 'Existing Note',
          'content': 'Existing content',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });

        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        final snapshot = Snapshot(
          schemaVersion: 36,
          timestamp: DateTime.now().toUtc(),
          tables: {
            'notes': [
              {
                'id': 'new-note-from-snapshot',
                'title': 'New Note',
                'content': 'New content from snapshot',
                'type': 'note',
                'createdAt': now,
                'updatedAt': now,
                'pinned': 1,
                'isArchived': 0,
              },
            ],
          },
          referencedAttachments: [],
        );

        await snapshotService.applySnapshotToDb(snapshot, targetDb);

        // Verify old data was replaced
        final notes = await targetDb.query('notes');
        expect(notes.length, 1);
        expect(notes[0]['id'], 'new-note-from-snapshot');
        expect(notes[0]['title'], 'New Note');
      });

      test('applies all tables atomically in transaction', () async {
        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        final now = DateTime.now().millisecondsSinceEpoch;
        final snapshot = Snapshot(
          schemaVersion: 36,
          timestamp: DateTime.now().toUtc(),
          tables: {
            'notes': [
              {
                'id': 'transaction-note-1',
                'title': 'Transaction Note 1',
                'content': 'Content',
                'type': 'note',
                'createdAt': now,
                'updatedAt': now,
                'pinned': 0,
                'isArchived': 0,
              },
              {
                'id': 'transaction-note-2',
                'title': 'Transaction Note 2',
                'content': 'Content 2',
                'type': 'note',
                'createdAt': now,
                'updatedAt': now,
                'pinned': 0,
                'isArchived': 0,
              },
            ],
            'tags': [
              {
                'id': 'transaction-tag-1',
                'name': 'Transaction Tag',
                'color': '#FF0000',
                'createdAt': now,
                'usageCount': 0,
              },
            ],
          },
          referencedAttachments: [],
        );

        final targetDb = await targetDbService.database;
        await snapshotService.applySnapshotToDb(snapshot, targetDb);

        // Verify all data was inserted
        final notes = await targetDb.query('notes');
        expect(notes.length, 2);

        final tags = await targetDb.query('tags');
        expect(tags.length, 1);
      });

      test('handles empty snapshot gracefully', () async {
        final snapshotService = SnapshotService(
          db: databaseService,
          provider: provider,
        );

        final snapshot = Snapshot(
          schemaVersion: 36,
          timestamp: DateTime.now().toUtc(),
          tables: {}, // Empty tables
          referencedAttachments: [],
        );

        final targetDb = await targetDbService.database;

        // Should not throw
        await snapshotService.applySnapshotToDb(snapshot, targetDb);

        // Tables should exist but be empty
        final notes = await targetDb.query('notes');
        expect(notes, isEmpty);
      });
    });
  });
}
