import 'dart:typed_data';

import 'package:note_synapse/models/sync_file_info.dart';
import 'package:note_synapse/services/sync/sync_storage_provider.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

/// A [SyncStorageProvider] backed by Android's Storage Access Framework (SAF).
///
/// Uses content URIs via [SafUtil] (directory ops) and [SafStream] (read/write)
/// to work within Android 11+ scoped storage restrictions.
class AndroidSafSyncProvider implements SyncStorageProvider {
  final String treeUri;
  final SafUtil _safUtil;
  final SafStream _safStream;

  AndroidSafSyncProvider({
    required this.treeUri,
    SafUtil? safUtil,
    SafStream? safStream,
  }) : _safUtil = safUtil ?? SafUtil(),
       _safStream = safStream ?? SafStream();

  /// Splits a sync path like "oplog/device-abc_seq42.json" into
  /// directory segments and a filename.
  /// Returns (dirSegments, fileName).
  (List<String>, String) _parsePath(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) {
      return ([], '');
    }
    final fileName = parts.last;
    final dirSegments = parts.sublist(0, parts.length - 1);
    return (dirSegments, fileName);
  }

  /// Navigates from [treeUri] through the given path segments using
  /// [SafUtil.child] to find the target [SafDocumentFile].
  /// Returns null if any segment doesn't exist.
  Future<SafDocumentFile?> _resolve(String path) async {
    final parts = path.split('/');
    return _safUtil.child(treeUri, parts);
  }

  @override
  Future<List<SyncFileInfo>> listFiles(String path) async {
    final subdir = await _safUtil.child(treeUri, path.split('/'));
    if (subdir == null) return [];

    final entries = await _safUtil.list(subdir.uri);
    return entries
        .where((e) => !e.isDir)
        .map(
          (e) => SyncFileInfo(
            path: '$path/${e.name}',
            sizeBytes: e.length,
            lastModified: DateTime.fromMillisecondsSinceEpoch(e.lastModified),
          ),
        )
        .toList();
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final doc = await _resolve(path);
    if (doc == null) {
      throw Exception('SAF file not found: $path');
    }
    return _safStream.readFileBytes(doc.uri);
  }

  @override
  Future<void> writeFile(String path, Uint8List data) async {
    final (dirSegments, fileName) = _parsePath(path);

    // Ensure parent directory exists
    final String parentUri;
    if (dirSegments.isEmpty) {
      parentUri = treeUri;
    } else {
      final parent = await _safUtil.mkdirp(treeUri, dirSegments);
      parentUri = parent.uri;
    }

    await _safStream.writeFileBytes(
      parentUri,
      fileName,
      'application/octet-stream',
      data,
      overwrite: true,
    );
  }

  @override
  Future<void> deleteFile(String path) async {
    final doc = await _resolve(path);
    if (doc != null) {
      await _safUtil.delete(doc.uri, false);
    }
  }

  @override
  Future<bool> exists(String path) async {
    final doc = await _resolve(path);
    return doc != null;
  }

  @override
  Future<SyncFileInfo> getFileInfo(String path) async {
    final doc = await _resolve(path);
    if (doc == null) {
      throw Exception('SAF file not found: $path');
    }
    return SyncFileInfo(
      path: path,
      sizeBytes: doc.length,
      lastModified: DateTime.fromMillisecondsSinceEpoch(doc.lastModified),
    );
  }
}
