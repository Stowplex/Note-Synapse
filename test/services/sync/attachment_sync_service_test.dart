import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/sync_operation.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/attachment_sync_service.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory remoteDir;
  late Directory localDir;
  late FolderSyncProvider provider;
  late AttachmentSyncService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() {
    remoteDir = Directory.systemTemp.createTempSync('remote_');
    localDir = Directory.systemTemp.createTempSync('local_');
    provider = FolderSyncProvider(rootPath: remoteDir.path);
    service = AttachmentSyncService(provider: provider);
  });

  tearDown(() {
    remoteDir.deleteSync(recursive: true);
    localDir.deleteSync(recursive: true);
  });

  SyncOperation makeOp({
    required String table,
    required SyncAction action,
    required String filePath,
    String id = 'op-1',
    String rowId = 'att-1',
  }) {
    return SyncOperation(
      id: id,
      deviceId: 'dev-1',
      sequence: 1,
      timestamp: DateTime.utc(2026, 2, 5),
      table: table,
      rowId: rowId,
      action: action,
      fields: {
        'filePath': SyncFieldValue(value: filePath, minVersion: 1),
      },
      schemaVersion: 36,
    );
  }

  group('uploadNewAttachments', () {
    test('uploads file from insert op', () async {
      // Write a local file
      final localFile = File('${localDir.path}/attachments/test-file.pdf');
      localFile.createSync(recursive: true);
      localFile.writeAsBytesSync([1, 2, 3, 4, 5]);

      final ops = [
        makeOp(
          table: 'attachments',
          action: SyncAction.insert,
          filePath: 'attachments/test-file.pdf',
        ),
      ];

      final count = await service.uploadNewAttachments(ops, localDir.path);

      expect(count, 1);
      expect(await provider.exists('attachments/test-file.pdf'), isTrue);
      final remoteBytes =
          await provider.readFile('attachments/test-file.pdf');
      expect(remoteBytes, equals(Uint8List.fromList([1, 2, 3, 4, 5])));
    });

    test('skips already-uploaded files', () async {
      // Write a local file
      final localFile = File('${localDir.path}/attachments/test-file.pdf');
      localFile.createSync(recursive: true);
      localFile.writeAsBytesSync([1, 2, 3]);

      // Also write to remote (already uploaded)
      await provider.writeFile(
        'attachments/test-file.pdf',
        Uint8List.fromList([1, 2, 3]),
      );

      final ops = [
        makeOp(
          table: 'attachments',
          action: SyncAction.insert,
          filePath: 'attachments/test-file.pdf',
        ),
      ];

      final count = await service.uploadNewAttachments(ops, localDir.path);
      expect(count, 0);
    });

    test('skips non-attachment ops', () async {
      // Write a local file for safety
      final localFile = File('${localDir.path}/notes/note1.txt');
      localFile.createSync(recursive: true);
      localFile.writeAsBytesSync([1, 2, 3]);

      final ops = [
        makeOp(
          table: 'notes',
          action: SyncAction.insert,
          filePath: 'notes/note1.txt',
        ),
      ];

      final count = await service.uploadNewAttachments(ops, localDir.path);
      expect(count, 0);
    });

    test('handles update ops on attachments table', () async {
      final localFile = File('${localDir.path}/attachments/updated.pdf');
      localFile.createSync(recursive: true);
      localFile.writeAsBytesSync([10, 20, 30]);

      final ops = [
        makeOp(
          table: 'conversation_attachments',
          action: SyncAction.update,
          filePath: 'attachments/updated.pdf',
        ),
      ];

      final count = await service.uploadNewAttachments(ops, localDir.path);
      expect(count, 1);
      expect(await provider.exists('attachments/updated.pdf'), isTrue);
    });
  });

  group('downloadMissingAttachments', () {
    test('downloads to local dir', () async {
      // Write file to remote
      await provider.writeFile(
        'attachments/remote-file.pdf',
        Uint8List.fromList([10, 20, 30]),
      );

      final ops = [
        makeOp(
          table: 'attachments',
          action: SyncAction.insert,
          filePath: 'attachments/remote-file.pdf',
        ),
      ];

      final count =
          await service.downloadMissingAttachments(ops, localDir.path);

      expect(count, 1);
      final localFile =
          File('${localDir.path}/attachments/remote-file.pdf');
      expect(localFile.existsSync(), isTrue);
      expect(localFile.readAsBytesSync(), equals([10, 20, 30]));
    });

    test('skips already-local files', () async {
      // Write file locally
      final localFile =
          File('${localDir.path}/attachments/existing-file.pdf');
      localFile.createSync(recursive: true);
      localFile.writeAsBytesSync([1, 2, 3]);

      // Also on remote
      await provider.writeFile(
        'attachments/existing-file.pdf',
        Uint8List.fromList([1, 2, 3]),
      );

      final ops = [
        makeOp(
          table: 'attachments',
          action: SyncAction.insert,
          filePath: 'attachments/existing-file.pdf',
        ),
      ];

      final count =
          await service.downloadMissingAttachments(ops, localDir.path);
      expect(count, 0);
    });

    test('handles missing remote file gracefully', () async {
      final ops = [
        makeOp(
          table: 'attachments',
          action: SyncAction.insert,
          filePath: 'attachments/nonexistent.pdf',
        ),
      ];

      // Should not throw
      final count =
          await service.downloadMissingAttachments(ops, localDir.path);
      expect(count, 0);

      final localFile =
          File('${localDir.path}/attachments/nonexistent.pdf');
      expect(localFile.existsSync(), isFalse);
    });
  });

  group('garbageCollect', () {
    test('removes unreferenced files', () async {
      // Write files to remote attachments/
      await provider.writeFile(
        'attachments/keep.pdf',
        Uint8List.fromList([1]),
      );
      await provider.writeFile(
        'attachments/remove-me.pdf',
        Uint8List.fromList([2]),
      );
      await provider.writeFile(
        'attachments/also-remove.pdf',
        Uint8List.fromList([3]),
      );

      final count = await service.garbageCollect(['keep.pdf']);

      expect(count, 2);
      expect(await provider.exists('attachments/keep.pdf'), isTrue);
      expect(await provider.exists('attachments/remove-me.pdf'), isFalse);
      expect(await provider.exists('attachments/also-remove.pdf'), isFalse);
    });

    test('keeps referenced files', () async {
      await provider.writeFile(
        'attachments/file-a.pdf',
        Uint8List.fromList([1]),
      );
      await provider.writeFile(
        'attachments/file-b.pdf',
        Uint8List.fromList([2]),
      );

      final count = await service.garbageCollect(['file-a.pdf', 'file-b.pdf']);

      expect(count, 0);
      expect(await provider.exists('attachments/file-a.pdf'), isTrue);
      expect(await provider.exists('attachments/file-b.pdf'), isTrue);
    });
  });

  /// Helper: inserts a parent note row so FK constraints are satisfied.
  Future<void> insertParentNote(Database db, String noteId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('notes', {
      'id': noteId,
      'title': 'Test Note',
      'content': '',
      'type': 'note',
      'createdAt': now,
      'updatedAt': now,
    });
  }

  /// Helper: inserts a parent conversation message so FK constraints are satisfied.
  Future<void> insertParentMessage(Database db, String messageId) async {
    await db.insert('conversation_messages', {
      'id': messageId,
      'type': 'user',
      'content': 'test',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  group('DB-scan: path normalization', () {
    test('relative path stays as-is', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      await insertParentNote(db, 'note-1');
      await db.insert('attachments', {
        'id': 'att-1',
        'noteId': 'note-1',
        'filePath': 'attachments/uuid.pdf',
        'fileName': 'uuid.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });

      // Create local file
      final localFile = File('${localDir.path}/attachments/uuid.pdf');
      localFile.createSync(recursive: true);
      localFile.writeAsBytesSync([1, 2, 3]);

      final count = await service.uploadMissingFromDb(db, localDir.path);

      expect(count, 1);
      expect(await provider.exists('attachments/uuid.pdf'), isTrue);
      final remoteBytes = await provider.readFile('attachments/uuid.pdf');
      expect(remoteBytes, equals(Uint8List.fromList([1, 2, 3])));

      await dbService.close();
    });

    test('absolute path normalized to attachments/filename.ext', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      final absolutePath = '${localDir.path}/attachments/uuid.pdf';

      await insertParentNote(db, 'note-1');
      await db.insert('attachments', {
        'id': 'att-2',
        'noteId': 'note-1',
        'filePath': absolutePath,
        'fileName': 'uuid.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });

      // Create local file at the absolute path
      final localFile = File(absolutePath);
      localFile.createSync(recursive: true);
      localFile.writeAsBytesSync([10, 20, 30]);

      final count = await service.uploadMissingFromDb(db, localDir.path);

      expect(count, 1);
      // Remote key should be relative
      expect(await provider.exists('attachments/uuid.pdf'), isTrue);

      await dbService.close();
    });
  });

  group('DB-scan: uploadMissingFromDb', () {
    test('scans DB and uploads missing files', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      // Insert parent rows for FK constraints
      await insertParentNote(db, 'note-1');
      await insertParentMessage(db, 'msg-1');

      // Insert attachment rows in both tables
      await db.insert('attachments', {
        'id': 'att-1',
        'noteId': 'note-1',
        'filePath': 'attachments/file-a.pdf',
        'fileName': 'file-a.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });
      await db.insert('conversation_attachments', {
        'id': 'ca-1',
        'messageId': 'msg-1',
        'filePath': 'attachments/file-b.png',
        'fileName': 'file-b.png',
        'fileType': 'image/png',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });

      // Create local files
      File('${localDir.path}/attachments/file-a.pdf')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      File('${localDir.path}/attachments/file-b.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync([4, 5, 6]);

      final count = await service.uploadMissingFromDb(db, localDir.path);

      expect(count, 2);
      expect(await provider.exists('attachments/file-a.pdf'), isTrue);
      expect(await provider.exists('attachments/file-b.png'), isTrue);

      await dbService.close();
    });

    test('skips files already on remote', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      await insertParentNote(db, 'note-1');
      await db.insert('attachments', {
        'id': 'att-1',
        'noteId': 'note-1',
        'filePath': 'attachments/already-there.pdf',
        'fileName': 'already-there.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });

      // File already on remote
      await provider.writeFile(
        'attachments/already-there.pdf',
        Uint8List.fromList([1, 2, 3]),
      );

      // Also create local file
      File('${localDir.path}/attachments/already-there.pdf')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);

      final count = await service.uploadMissingFromDb(db, localDir.path);

      expect(count, 0);

      await dbService.close();
    });

    test('handles missing local files gracefully', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      await insertParentNote(db, 'note-1');
      // DB references a file that does not exist locally
      await db.insert('attachments', {
        'id': 'att-1',
        'noteId': 'note-1',
        'filePath': 'attachments/ghost.pdf',
        'fileName': 'ghost.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });

      // Should not throw, should return 0
      final count = await service.uploadMissingFromDb(db, localDir.path);
      expect(count, 0);

      await dbService.close();
    });
  });

  group('DB-scan: downloadMissingFromDb', () {
    test('scans DB and downloads missing files', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      await insertParentNote(db, 'note-1');
      await db.insert('attachments', {
        'id': 'att-1',
        'noteId': 'note-1',
        'filePath': 'attachments/remote-only.pdf',
        'fileName': 'remote-only.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });

      // Put file on remote
      await provider.writeFile(
        'attachments/remote-only.pdf',
        Uint8List.fromList([7, 8, 9]),
      );

      final count = await service.downloadMissingFromDb(db, localDir.path);

      expect(count, 1);
      final localFile = File('${localDir.path}/attachments/remote-only.pdf');
      expect(localFile.existsSync(), isTrue);
      expect(localFile.readAsBytesSync(), equals([7, 8, 9]));

      await dbService.close();
    });

    test('skips files already present locally', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      await insertParentNote(db, 'note-1');
      await db.insert('attachments', {
        'id': 'att-1',
        'noteId': 'note-1',
        'filePath': 'attachments/local-exists.pdf',
        'fileName': 'local-exists.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });

      // Create local file
      File('${localDir.path}/attachments/local-exists.pdf')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);

      // Also on remote
      await provider.writeFile(
        'attachments/local-exists.pdf',
        Uint8List.fromList([1, 2, 3]),
      );

      final count = await service.downloadMissingFromDb(db, localDir.path);
      expect(count, 0);

      await dbService.close();
    });

    test('handles missing remote file gracefully', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      await insertParentNote(db, 'note-1');
      await db.insert('attachments', {
        'id': 'att-1',
        'noteId': 'note-1',
        'filePath': 'attachments/not-on-remote.pdf',
        'fileName': 'not-on-remote.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });

      // No file on remote, no file locally
      final count = await service.downloadMissingFromDb(db, localDir.path);
      expect(count, 0);

      final localFile = File('${localDir.path}/attachments/not-on-remote.pdf');
      expect(localFile.existsSync(), isFalse);

      await dbService.close();
    });

    test('downloads conversation_attachments with absolute path', () async {
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      final absolutePath = '${localDir.path}/absolute/attachments/conv-file.png';

      await insertParentMessage(db, 'msg-1');
      await db.insert('conversation_attachments', {
        'id': 'ca-1',
        'messageId': 'msg-1',
        'filePath': absolutePath,
        'fileName': 'conv-file.png',
        'fileType': 'image/png',
        'isRelativePath': 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });

      // Remote key is normalized to attachments/conv-file.png
      await provider.writeFile(
        'attachments/conv-file.png',
        Uint8List.fromList([10, 20]),
      );

      final count = await service.downloadMissingFromDb(db, localDir.path);

      // The absolute path doesn't exist locally, so it should download
      expect(count, 1);
      // File should be at the absolute path
      final localFile = File(absolutePath);
      expect(localFile.existsSync(), isTrue);
      expect(localFile.readAsBytesSync(), equals([10, 20]));

      await dbService.close();
    });
  });
}
