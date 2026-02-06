import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:note_synapse/models/sync_operation.dart';
import 'package:note_synapse/services/sync/sync_encryption_service.dart';
import 'package:note_synapse/services/sync/sync_storage_provider.dart';
import 'package:path/path.dart' as p;

/// Handles syncing binary attachment files separately from the oplog.
///
/// Attachments are stored under `attachments/` on the remote provider.
/// Upload happens after push (so the oplog references files that exist),
/// and download happens after pull (ops applied, files fetched afterward).
class AttachmentSyncService {
  final SyncStorageProvider _provider;
  final SyncEncryptionService? _encryption;

  AttachmentSyncService({
    required SyncStorageProvider provider,
    SyncEncryptionService? encryption,
  })  : _provider = provider,
        _encryption = encryption;

  static const _attachmentTables = {'attachments', 'conversation_attachments'};

  /// Extracts file paths from ops that target attachment tables with a
  /// `filePath` field and are INSERT or UPDATE actions.
  List<String> _extractAttachmentPaths(List<SyncOperation> ops) {
    final paths = <String>[];
    for (final op in ops) {
      if (!_attachmentTables.contains(op.table)) continue;
      if (op.action != SyncAction.insert && op.action != SyncAction.update) {
        continue;
      }
      final filePathField = op.fields['filePath'];
      if (filePathField == null || filePathField.value == null) continue;
      paths.add(filePathField.value as String);
    }
    return paths;
  }

  /// Uploads new attachment files referenced by pushed ops.
  ///
  /// Scans [pushedOps] for INSERT/UPDATE on attachment tables that include a
  /// `filePath` field. For each, reads the local file, optionally encrypts,
  /// and writes to the remote provider if not already present.
  ///
  /// Returns the count of files uploaded.
  Future<int> uploadNewAttachments(
    List<SyncOperation> pushedOps,
    String localAttachmentDir,
  ) async {
    final paths = _extractAttachmentPaths(pushedOps);
    var uploaded = 0;

    for (final filePath in paths) {
      // Check if already on remote
      if (await _provider.exists(filePath)) {
        continue;
      }

      // Resolve local file
      final localFile = File(p.join(localAttachmentDir, filePath));
      if (!localFile.existsSync()) {
        developer.log(
          'AttachmentSyncService: local file not found: ${localFile.path}',
          name: 'sync',
        );
        continue;
      }

      Uint8List bytes = await localFile.readAsBytes();

      if (_encryption != null) {
        bytes = await _encryption!.encrypt(bytes);
      }

      await _provider.writeFile(filePath, bytes);
      uploaded++;
    }

    return uploaded;
  }

  /// Downloads missing attachment files referenced by pulled ops.
  ///
  /// Scans [pulledOps] for INSERT/UPDATE on attachment tables that include a
  /// `filePath` field. For each, downloads from remote if not already present
  /// locally.
  ///
  /// Returns the count of files downloaded.
  Future<int> downloadMissingAttachments(
    List<SyncOperation> pulledOps,
    String localAttachmentDir,
  ) async {
    final paths = _extractAttachmentPaths(pulledOps);
    var downloaded = 0;

    for (final filePath in paths) {
      // Check if already local
      final localFile = File(p.join(localAttachmentDir, filePath));
      if (localFile.existsSync()) {
        continue;
      }

      // Check if remote has it
      if (!await _provider.exists(filePath)) {
        developer.log(
          'AttachmentSyncService: remote file not found: $filePath',
          name: 'sync',
        );
        continue;
      }

      try {
        Uint8List bytes = await _provider.readFile(filePath);

        if (_encryption != null) {
          bytes = await _encryption!.decrypt(bytes);
        }

        await localFile.parent.create(recursive: true);
        await localFile.writeAsBytes(bytes);
        downloaded++;
      } catch (e) {
        developer.log(
          'AttachmentSyncService: failed to download $filePath: $e',
          name: 'sync',
        );
      }
    }

    return downloaded;
  }

  /// Removes unreferenced attachment files from remote storage.
  ///
  /// Compares files in `attachments/` on the remote against
  /// [referencedAttachments] (filenames only, no directory prefix).
  /// Deletes any file not in the referenced set.
  ///
  /// Returns the count of files deleted.
  Future<int> garbageCollect(List<String> referencedAttachments) async {
    final referencedSet = referencedAttachments.toSet();
    final remoteFiles = await _provider.listFiles('attachments');
    var deleted = 0;

    for (final fileInfo in remoteFiles) {
      final filename = p.basename(fileInfo.path);
      if (!referencedSet.contains(filename)) {
        await _provider.deleteFile(fileInfo.path);
        deleted++;
      }
    }

    return deleted;
  }
}
