import 'dart:typed_data';
import 'package:note_synapse/models/sync_file_info.dart';

/// Abstract interface for cloud sync storage backends.
/// Implementations: FolderSyncProvider, WebDavSyncProvider, (future) OAuthCloudProvider.
abstract class SyncStorageProvider {
  /// List files at a remote path (non-recursive).
  Future<List<SyncFileInfo>> listFiles(String path);

  /// Read a file's contents as bytes.
  Future<Uint8List> readFile(String path);

  /// Write bytes to a file (creates or overwrites).
  Future<void> writeFile(String path, Uint8List data);

  /// Delete a file.
  Future<void> deleteFile(String path);

  /// Check if a file exists.
  Future<bool> exists(String path);

  /// Get metadata for a single file.
  Future<SyncFileInfo> getFileInfo(String path);
}
