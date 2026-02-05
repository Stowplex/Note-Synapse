import 'dart:io';
import 'dart:typed_data';

import 'package:note_synapse/models/sync_file_info.dart';
import 'package:note_synapse/services/sync/sync_storage_provider.dart';
import 'package:path/path.dart' as p;

/// A [SyncStorageProvider] backed by a local filesystem directory.
///
/// Suitable for iCloud Drive folder on iOS, FolderSync-managed folder
/// on Android, or any local/mounted directory.
class FolderSyncProvider implements SyncStorageProvider {
  final String rootPath;

  FolderSyncProvider({required this.rootPath});

  String _resolve(String path) => p.join(rootPath, path);

  @override
  Future<List<SyncFileInfo>> listFiles(String path) async {
    final dir = Directory(_resolve(path));
    if (!dir.existsSync()) {
      return [];
    }

    final results = <SyncFileInfo>[];
    await for (final entity in dir.list(recursive: false)) {
      if (entity is File) {
        final stat = entity.statSync();
        final relativePath = p.relative(entity.path, from: rootPath);
        results.add(SyncFileInfo(
          path: relativePath,
          sizeBytes: stat.size,
          lastModified: stat.modified,
        ));
      }
    }
    return results;
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final file = File(_resolve(path));
    return file.readAsBytes();
  }

  @override
  Future<void> writeFile(String path, Uint8List data) async {
    final file = File(_resolve(path));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data);
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = File(_resolve(path));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  @override
  Future<bool> exists(String path) async {
    final file = File(_resolve(path));
    return file.existsSync();
  }

  @override
  Future<SyncFileInfo> getFileInfo(String path) async {
    final file = File(_resolve(path));
    final stat = file.statSync();
    return SyncFileInfo(
      path: path,
      sizeBytes: stat.size,
      lastModified: stat.modified,
    );
  }
}
