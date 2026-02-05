import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/sync_operation.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/field_version_registry.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:note_synapse/services/sync/oplog_service.dart';
import 'package:note_synapse/services/sync/sync_encryption_service.dart';

void main() {
  group('OplogWriter', () {
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
      await databaseService.enableSyncTriggers();

      tempDir = Directory.systemTemp.createTempSync('oplog_test_');
      provider = FolderSyncProvider(rootPath: tempDir.path);
    });

    tearDown(() async {
      await databaseService.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('insert changelog produces SyncOperation with insert action and all fields',
        () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert a note
      await db.insert('notes', {
        'id': 'note-insert-1',
        'title': 'Test Note',
        'content': 'Test content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'device-1',
        schemaVersion: 32,
      );

      final nextSeq = await writer.writeOplogBatch(1);

      // Should have written one batch file
      expect(nextSeq, 2);

      // Verify the file exists and contains the operation
      final files = await provider.listFiles('oplog');
      expect(files.length, 1);
      expect(files.first.path, 'oplog/device-1-1-1.json');

      // Read and parse the content
      final bytes = await provider.readFile('oplog/device-1-1-1.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      expect(json.length, 1);

      final op = SyncOperation.fromJson(json[0] as Map<String, dynamic>);
      expect(op.action, SyncAction.insert);
      expect(op.table, 'notes');
      expect(op.rowId, 'note-insert-1');
      expect(op.deviceId, 'device-1');
      expect(op.sequence, 1);
      expect(op.schemaVersion, 32);

      // Check fields with minVersion
      expect(op.fields['id']!.value, 'note-insert-1');
      expect(op.fields['id']!.minVersion, fieldVersionRegistry['notes']!['id']);
      expect(op.fields['title']!.value, 'Test Note');
      expect(op.fields['title']!.minVersion, fieldVersionRegistry['notes']!['title']);
      expect(op.fields['content']!.value, 'Test content');
    });

    test('update changelog produces SyncOperation with update action', () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert a note first (before triggers capture it)
      await databaseService.disableSyncTriggers();
      await db.insert('notes', {
        'id': 'note-update-1',
        'title': 'Original Title',
        'content': 'Original content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Re-enable triggers and update
      await databaseService.enableSyncTriggers();
      await db.update(
        'notes',
        {'title': 'Updated Title', 'updatedAt': now + 1000},
        where: 'id = ?',
        whereArgs: ['note-update-1'],
      );

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'device-2',
        schemaVersion: 32,
      );

      final nextSeq = await writer.writeOplogBatch(5);
      expect(nextSeq, 6);

      // Read and parse the content
      final bytes = await provider.readFile('oplog/device-2-5-5.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      expect(json.length, 1);

      final op = SyncOperation.fromJson(json[0] as Map<String, dynamic>);
      expect(op.action, SyncAction.update);
      expect(op.table, 'notes');
      expect(op.rowId, 'note-update-1');
      expect(op.sequence, 5);

      // Fields should contain current values (after update)
      expect(op.fields['title']!.value, 'Updated Title');
    });

    test('delete changelog produces SyncOperation with delete action and empty fields',
        () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert a note first
      await databaseService.disableSyncTriggers();
      await db.insert('notes', {
        'id': 'note-delete-1',
        'title': 'Note to Delete',
        'content': 'Will be deleted',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Re-enable triggers and delete
      await databaseService.enableSyncTriggers();
      await db.delete('notes', where: 'id = ?', whereArgs: ['note-delete-1']);

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'device-3',
        schemaVersion: 32,
      );

      final nextSeq = await writer.writeOplogBatch(10);
      expect(nextSeq, 11);

      // Read and parse the content
      final bytes = await provider.readFile('oplog/device-3-10-10.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      expect(json.length, 1);

      final op = SyncOperation.fromJson(json[0] as Map<String, dynamic>);
      expect(op.action, SyncAction.delete);
      expect(op.table, 'notes');
      expect(op.rowId, 'note-delete-1');
      expect(op.fields, isEmpty);
    });

    test('batch multiple operations into one oplog file', () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert multiple notes
      await db.insert('notes', {
        'id': 'batch-note-1',
        'title': 'Batch Note 1',
        'content': 'Content 1',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'batch-note-2',
        'title': 'Batch Note 2',
        'content': 'Content 2',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'batch-note-3',
        'title': 'Batch Note 3',
        'content': 'Content 3',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'device-batch',
        schemaVersion: 32,
      );

      final nextSeq = await writer.writeOplogBatch(100);
      expect(nextSeq, 103);

      // Verify single file with correct name
      final files = await provider.listFiles('oplog');
      expect(files.length, 1);
      expect(files.first.path, 'oplog/device-batch-100-102.json');

      // Verify all three operations in the file
      final bytes = await provider.readFile('oplog/device-batch-100-102.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      expect(json.length, 3);

      // Verify sequences are correct
      expect((json[0] as Map<String, dynamic>)['sequence'], 100);
      expect((json[1] as Map<String, dynamic>)['sequence'], 101);
      expect((json[2] as Map<String, dynamic>)['sequence'], 102);
    });

    test('correct filename format: deviceId-startSeq-endSeq.json', () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('notes', {
        'id': 'filename-note',
        'title': 'Filename Test',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'my-device-uuid',
        schemaVersion: 32,
      );

      await writer.writeOplogBatch(42);

      final files = await provider.listFiles('oplog');
      expect(files.length, 1);
      expect(files.first.path, 'oplog/my-device-uuid-42-42.json');
    });

    test('encryption: output is encrypted when encryption service provided',
        () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('notes', {
        'id': 'encrypted-note',
        'title': 'Encrypted Note',
        'content': 'Secret content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      final encryption = await SyncEncryptionService.create(
        passphrase: 'test-passphrase',
        cipherId: 'aes-256-gcm',
        salt: 'dGVzdC1zYWx0LWZvci10ZXN0aW5n',
      );

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        encryption: encryption,
        deviceId: 'encrypted-device',
        schemaVersion: 32,
      );

      await writer.writeOplogBatch(1);

      // Read the raw bytes
      final bytes = await provider.readFile('oplog/encrypted-device-1-1.json');

      // Trying to parse as JSON should fail (it's encrypted)
      expect(() => jsonDecode(utf8.decode(bytes)), throwsFormatException);

      // But decrypting should give valid JSON
      final decrypted = await encryption.decrypt(bytes);
      final json = jsonDecode(utf8.decode(decrypted)) as List<dynamic>;
      expect(json.length, 1);
      expect((json[0] as Map<String, dynamic>)['table'], 'notes');
    });

    test('no pending changes: returns startSequence unchanged and writes nothing',
        () async {
      // Don't create any changes

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'empty-device',
        schemaVersion: 32,
      );

      final nextSeq = await writer.writeOplogBatch(50);
      expect(nextSeq, 50);

      // No files should be written
      final files = await provider.listFiles('oplog');
      expect(files, isEmpty);
    });

    test('composite key tables produce correct row_id in SyncOperation', () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Create prerequisites - use simple IDs without dashes to avoid
      // row_id parsing issues (row_id uses '-' as separator)
      await db.insert('notes', {
        'id': 'noteComposite',
        'title': 'Note for composite test',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('tags', {
        'id': 'tagComposite',
        'name': 'Composite Tag',
        'color': '#FF0000',
        'createdAt': now,
        'usageCount': 0,
      });

      // Clear previous changelog entries
      await db.delete('sync_changelog');

      // Create note_tag (composite key: noteId-tagId)
      await db.insert('note_tags', {
        'noteId': 'noteComposite',
        'tagId': 'tagComposite',
      });

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'composite-device',
        schemaVersion: 32,
      );

      final nextSeq = await writer.writeOplogBatch(1);
      expect(nextSeq, 2);

      final bytes = await provider.readFile('oplog/composite-device-1-1.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      final op = SyncOperation.fromJson(json[0] as Map<String, dynamic>);

      expect(op.table, 'note_tags');
      expect(op.rowId, 'noteComposite-tagComposite');
      expect(op.fields['noteId']!.value, 'noteComposite');
      expect(op.fields['tagId']!.value, 'tagComposite');
    });

    test('each SyncOperation has a unique UUID id', () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('notes', {
        'id': 'uuid-note-1',
        'title': 'UUID Note 1',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'uuid-note-2',
        'title': 'UUID Note 2',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'uuid-device',
        schemaVersion: 32,
      );

      await writer.writeOplogBatch(1);

      final bytes = await provider.readFile('oplog/uuid-device-1-2.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;

      final id1 = (json[0] as Map<String, dynamic>)['id'] as String;
      final id2 = (json[1] as Map<String, dynamic>)['id'] as String;

      // IDs should be non-empty UUIDs
      expect(id1, isNotEmpty);
      expect(id2, isNotEmpty);
      // IDs should be different
      expect(id1, isNot(equals(id2)));
      // Should look like UUIDs (contains dashes, 36 chars)
      expect(id1.length, 36);
      expect(id1.contains('-'), isTrue);
    });

    test('timestamp from changelog is used in SyncOperation', () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('notes', {
        'id': 'timestamp-note',
        'title': 'Timestamp Test',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'timestamp-device',
        schemaVersion: 32,
      );

      await writer.writeOplogBatch(1);

      final bytes = await provider.readFile('oplog/timestamp-device-1-1.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      final op = SyncOperation.fromJson(json[0] as Map<String, dynamic>);

      // The timestamp should be a valid DateTime (the SQLite trigger uses datetime('now'))
      // We just verify it's parseable and reasonable (within last hour to account for timezone)
      final opTimestamp = op.timestamp;
      expect(opTimestamp.year, greaterThanOrEqualTo(2024));
      // The timestamp should be within a reasonable range of now (accounting for UTC vs local)
      final nowUtc = DateTime.now().toUtc();
      final diff = opTimestamp.difference(nowUtc).inHours.abs();
      expect(diff, lessThan(24)); // Within 24 hours to be safe across timezones
    });

    test('fields include minVersion from fieldVersionRegistry', () async {
      final db = await databaseService.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Use attachments table which has fields with different minVersions
      await databaseService.disableSyncTriggers();
      await db.insert('notes', {
        'id': 'note-for-attachment',
        'title': 'Note',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await databaseService.enableSyncTriggers();

      await db.insert('attachments', {
        'id': 'attachment-1',
        'noteId': 'note-for-attachment',
        'filePath': '/path/to/file',
        'fileName': 'file.txt',
        'fileType': 'text/plain',
        'isRelativePath': 0,
        'createdAt': now,
        'includeInAIContext': 1,
        'metadata': '{}',
      });

      final writer = OplogWriter(
        db: databaseService,
        provider: provider,
        deviceId: 'minversion-device',
        schemaVersion: 32,
      );

      await writer.writeOplogBatch(1);

      final bytes = await provider.readFile('oplog/minversion-device-1-1.json');
      final json = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      final op = SyncOperation.fromJson(json[0] as Map<String, dynamic>);

      // Check different minVersions
      expect(op.fields['id']!.minVersion, 1); // id is from version 1
      expect(op.fields['includeInAIContext']!.minVersion, 25); // added in v25
      expect(op.fields['metadata']!.minVersion, 32); // added in v32
    });
  });
}
