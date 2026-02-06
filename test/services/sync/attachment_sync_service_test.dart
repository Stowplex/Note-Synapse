import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/sync_operation.dart';
import 'package:note_synapse/services/sync/attachment_sync_service.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';

void main() {
  late Directory remoteDir;
  late Directory localDir;
  late FolderSyncProvider provider;
  late AttachmentSyncService service;

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
}
