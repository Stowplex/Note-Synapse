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
        timeout: Timeout(Duration(seconds: 60)), () async {
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
        kdfMemory: 1024,
        kdfIterations: 1,
        kdfParallelism: 1,
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

  group('OplogReader', () {
    late Directory tempDir;
    late FolderSyncProvider provider;
    late SyncEncryptionService encryption;

    setUpAll(() async {
      encryption = await SyncEncryptionService.create(
        passphrase: 'test-passphrase',
        cipherId: 'aes-256-gcm',
        salt: 'dGVzdC1zYWx0LWZvci10ZXN0aW5n',
        kdfMemory: 1024,
        kdfIterations: 1,
        kdfParallelism: 1,
      );
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('oplog_reader_test_');
      provider = FolderSyncProvider(rootPath: tempDir.path);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// Helper to create an oplog file with the given operations.
    Future<void> writeRawOplogFile(
      String filename,
      List<Map<String, dynamic>> operations, {
      SyncEncryptionService? encryptWith,
    }) async {
      final jsonBytes = utf8.encode(jsonEncode(operations));
      final Uint8List dataToWrite;
      if (encryptWith != null) {
        dataToWrite = await encryptWith.encrypt(Uint8List.fromList(jsonBytes));
      } else {
        dataToWrite = Uint8List.fromList(jsonBytes);
      }
      await provider.writeFile('oplog/$filename', dataToWrite);
    }

    /// Helper to create a SyncOperation JSON map.
    Map<String, dynamic> makeOpJson({
      required String deviceId,
      required int sequence,
      required int schemaVersion,
      String table = 'notes',
      String rowId = 'row-1',
      SyncAction action = SyncAction.insert,
    }) {
      return {
        'id': 'op-$deviceId-$sequence',
        'deviceId': deviceId,
        'sequence': sequence,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'table': table,
        'rowId': rowId,
        'action': action.name,
        'fields': {
          'id': {'value': rowId, 'minVersion': 1},
          'title': {'value': 'Test', 'minVersion': 1},
        },
        'schemaVersion': schemaVersion,
      };
    }

    group('listOplogFiles', () {
      test('parses filenames correctly extracting deviceId/seqStart/seqEnd',
          () async {
        // Create some oplog files with known names
        await writeRawOplogFile('device-a-1-5.json', [makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 32)]);
        await writeRawOplogFile('device-b-10-20.json', [makeOpJson(deviceId: 'device-b', sequence: 10, schemaVersion: 32)]);
        await writeRawOplogFile('uuid-123-456-789-100-150.json', [makeOpJson(deviceId: 'uuid-123-456-789', sequence: 100, schemaVersion: 32)]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final files = await reader.listOplogFiles();

        expect(files.length, 3);

        // Find by path to verify parsing
        final fileA = files.firstWhere((f) => f.path.contains('device-a'));
        expect(fileA.deviceId, 'device-a');
        expect(fileA.seqStart, 1);
        expect(fileA.seqEnd, 5);

        final fileB = files.firstWhere((f) => f.path.contains('device-b'));
        expect(fileB.deviceId, 'device-b');
        expect(fileB.seqStart, 10);
        expect(fileB.seqEnd, 20);

        // Device ID with dashes: uuid-123-456-789
        final fileUuid = files.firstWhere((f) => f.path.contains('uuid-123-456-789'));
        expect(fileUuid.deviceId, 'uuid-123-456-789');
        expect(fileUuid.seqStart, 100);
        expect(fileUuid.seqEnd, 150);
      });

      test('returns empty list when no oplog files exist', () async {
        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final files = await reader.listOplogFiles();
        expect(files, isEmpty);
      });
    });

    group('readOplogFile', () {
      test('reads and parses unencrypted oplog file', () async {
        await writeRawOplogFile('device-x-1-2.json', [
          makeOpJson(deviceId: 'device-x', sequence: 1, schemaVersion: 32),
          makeOpJson(deviceId: 'device-x', sequence: 2, schemaVersion: 32),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final ops = await reader.readOplogFile('oplog/device-x-1-2.json');

        expect(ops.length, 2);
        expect(ops[0].deviceId, 'device-x');
        expect(ops[0].sequence, 1);
        expect(ops[1].sequence, 2);
      });

      test('decrypts and parses encrypted oplog file', () async {
        await writeRawOplogFile(
          'encrypted-device-1-1.json',
          [makeOpJson(deviceId: 'encrypted-device', sequence: 1, schemaVersion: 32)],
          encryptWith: encryption,
        );

        final reader = OplogReader(
          provider: provider,
          encryption: encryption,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final ops = await reader.readOplogFile('oplog/encrypted-device-1-1.json');

        expect(ops.length, 1);
        expect(ops[0].deviceId, 'encrypted-device');
        expect(ops[0].sequence, 1);
      });
    });

    group('readNewOperations', () {
      test('filters out own device oplog files', () async {
        // Create ops from own device and other device
        await writeRawOplogFile('own-device-1-5.json', [
          makeOpJson(deviceId: 'own-device', sequence: 1, schemaVersion: 32),
        ]);
        await writeRawOplogFile('other-device-1-5.json', [
          makeOpJson(deviceId: 'other-device', sequence: 1, schemaVersion: 32),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'own-device',
          currentSchemaVersion: 32,
        );

        final result = await reader.readNewOperations({});

        // Should only include other-device ops
        expect(result.applicableOps.length, 1);
        expect(result.applicableOps.first.deviceId, 'other-device');
      });

      test('filters by sequence number - only ops newer than lastSeen', () async {
        await writeRawOplogFile('device-a-1-10.json', [
          makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 32, rowId: 'row-1'),
          makeOpJson(deviceId: 'device-a', sequence: 2, schemaVersion: 32, rowId: 'row-2'),
          makeOpJson(deviceId: 'device-a', sequence: 5, schemaVersion: 32, rowId: 'row-5'),
          makeOpJson(deviceId: 'device-a', sequence: 10, schemaVersion: 32, rowId: 'row-10'),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        // We've already seen up to sequence 5
        final result = await reader.readNewOperations({'device-a': 5});

        // Should only include ops with sequence > 5
        expect(result.applicableOps.length, 1);
        expect(result.applicableOps.first.sequence, 10);
      });

      test('handles partial overlap - file with seqStart before lastSeen but seqEnd after',
          () async {
        // File covers seq 5-15, but we've seen up to 10
        await writeRawOplogFile('device-a-5-15.json', [
          makeOpJson(deviceId: 'device-a', sequence: 5, schemaVersion: 32, rowId: 'row-5'),
          makeOpJson(deviceId: 'device-a', sequence: 8, schemaVersion: 32, rowId: 'row-8'),
          makeOpJson(deviceId: 'device-a', sequence: 10, schemaVersion: 32, rowId: 'row-10'),
          makeOpJson(deviceId: 'device-a', sequence: 12, schemaVersion: 32, rowId: 'row-12'),
          makeOpJson(deviceId: 'device-a', sequence: 15, schemaVersion: 32, rowId: 'row-15'),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        // We've seen up to sequence 10
        final result = await reader.readNewOperations({'device-a': 10});

        // Should only include ops with sequence > 10 (i.e., 12 and 15)
        expect(result.applicableOps.length, 2);
        expect(result.applicableOps.map((op) => op.sequence).toList(), [12, 15]);
      });

      test('defers high schema version ops to deferredOps', () async {
        await writeRawOplogFile('device-a-1-3.json', [
          makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 30, rowId: 'row-1'),
          makeOpJson(deviceId: 'device-a', sequence: 2, schemaVersion: 32, rowId: 'row-2'),
          makeOpJson(deviceId: 'device-a', sequence: 3, schemaVersion: 35, rowId: 'row-3'), // future version
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32, // current schema version
        );

        final result = await reader.readNewOperations({});

        // Ops with schemaVersion <= 32 are applicable
        expect(result.applicableOps.length, 2);
        expect(result.applicableOps.map((op) => op.sequence).toList(), [1, 2]);

        // Ops with schemaVersion > 32 are deferred
        expect(result.deferredOps.length, 1);
        expect(result.deferredOps.first.sequence, 3);
        expect(result.deferredOps.first.schemaVersion, 35);
      });

      test('sorts applicable ops by (deviceId, sequence)', () async {
        // Create ops from multiple devices in non-sorted order
        await writeRawOplogFile('device-b-5-10.json', [
          makeOpJson(deviceId: 'device-b', sequence: 10, schemaVersion: 32, rowId: 'b-10'),
          makeOpJson(deviceId: 'device-b', sequence: 5, schemaVersion: 32, rowId: 'b-5'),
        ]);
        await writeRawOplogFile('device-a-1-3.json', [
          makeOpJson(deviceId: 'device-a', sequence: 3, schemaVersion: 32, rowId: 'a-3'),
          makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 32, rowId: 'a-1'),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final result = await reader.readNewOperations({});

        // Should be sorted by (deviceId, sequence)
        expect(result.applicableOps.length, 4);

        // device-a comes before device-b
        expect(result.applicableOps[0].deviceId, 'device-a');
        expect(result.applicableOps[0].sequence, 1);
        expect(result.applicableOps[1].deviceId, 'device-a');
        expect(result.applicableOps[1].sequence, 3);
        expect(result.applicableOps[2].deviceId, 'device-b');
        expect(result.applicableOps[2].sequence, 5);
        expect(result.applicableOps[3].deviceId, 'device-b');
        expect(result.applicableOps[3].sequence, 10);
      });

      test('handles corrupted file gracefully - returns warning', () async {
        // Write valid file
        await writeRawOplogFile('device-good-1-1.json', [
          makeOpJson(deviceId: 'device-good', sequence: 1, schemaVersion: 32),
        ]);

        // Write corrupted file (invalid JSON)
        await provider.writeFile(
          'oplog/device-bad-1-1.json',
          Uint8List.fromList(utf8.encode('{ invalid json')),
        );

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final result = await reader.readNewOperations({});

        // Should still return the good ops
        expect(result.applicableOps.length, 1);
        expect(result.applicableOps.first.deviceId, 'device-good');

        // Should have a warning about the corrupted file
        expect(result.warnings.length, 1);
        expect(result.warnings.first, contains('device-bad'));
      });

      test('handles malformed SyncOperation gracefully - skips and warns', () async {
        // Write a file with one valid and one invalid operation
        final validOp = makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 32);
        final invalidOp = {
          'id': 'invalid-op',
          // Missing required fields like deviceId, sequence, etc.
        };

        final jsonBytes = utf8.encode(jsonEncode([validOp, invalidOp]));
        await provider.writeFile(
          'oplog/device-a-1-2.json',
          Uint8List.fromList(jsonBytes),
        );

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final result = await reader.readNewOperations({});

        // Should have the valid op
        expect(result.applicableOps.length, 1);
        expect(result.applicableOps.first.sequence, 1);

        // Should have a warning about the malformed op
        expect(result.warnings.length, 1);
        expect(result.warnings.first, contains('device-a-1-2.json'));
      });

      test('updates lastSeenSequences in result', () async {
        await writeRawOplogFile('device-a-1-5.json', [
          makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 32),
          makeOpJson(deviceId: 'device-a', sequence: 5, schemaVersion: 32),
        ]);
        await writeRawOplogFile('device-b-10-15.json', [
          makeOpJson(deviceId: 'device-b', sequence: 10, schemaVersion: 32),
          makeOpJson(deviceId: 'device-b', sequence: 15, schemaVersion: 32),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        final result = await reader.readNewOperations({});

        // Should have updated lastSeenSequences for both devices
        expect(result.newLastSeenSequences['device-a'], 5);
        expect(result.newLastSeenSequences['device-b'], 15);
      });

      test('preserves existing lastSeenSequences for devices with no new ops',
          () async {
        await writeRawOplogFile('device-a-1-5.json', [
          makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 32),
          makeOpJson(deviceId: 'device-a', sequence: 5, schemaVersion: 32),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        // We've already seen all of device-a's ops and device-c had ops before
        final result = await reader.readNewOperations({
          'device-a': 10, // higher than any in file
          'device-c': 100, // device-c doesn't even have files
        });

        // No new ops from device-a (all <= 10)
        expect(result.applicableOps, isEmpty);

        // Should preserve the lastSeenSequences
        expect(result.newLastSeenSequences['device-a'], 10);
        expect(result.newLastSeenSequences['device-c'], 100);
      });

      test('skips files entirely when seqEnd <= lastSeen', () async {
        await writeRawOplogFile('device-a-1-5.json', [
          makeOpJson(deviceId: 'device-a', sequence: 1, schemaVersion: 32),
          makeOpJson(deviceId: 'device-a', sequence: 5, schemaVersion: 32),
        ]);
        await writeRawOplogFile('device-a-10-15.json', [
          makeOpJson(deviceId: 'device-a', sequence: 10, schemaVersion: 32),
          makeOpJson(deviceId: 'device-a', sequence: 15, schemaVersion: 32),
        ]);

        final reader = OplogReader(
          provider: provider,
          ownDeviceId: 'my-device',
          currentSchemaVersion: 32,
        );

        // We've seen up to sequence 8, so first file (1-5) should be skipped entirely
        final result = await reader.readNewOperations({'device-a': 8});

        // Should only include ops from the second file (10-15)
        expect(result.applicableOps.length, 2);
        expect(result.applicableOps.map((op) => op.sequence).toList(), [10, 15]);
      });
    });
  });
}
