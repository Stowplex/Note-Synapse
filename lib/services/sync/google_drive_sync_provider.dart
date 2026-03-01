import 'dart:typed_data';
import 'package:note_synapse/models/sync_file_info.dart';
import 'package:note_synapse/services/sync/google_drive_api_client.dart';
import 'package:note_synapse/services/sync/sync_storage_provider.dart';
import 'package:path/path.dart' as p;

/// A [SyncStorageProvider] backed by Google Drive.
///
/// Translates the path-based [SyncStorageProvider] interface to Drive's
/// ID-based API using an in-memory path→fileId cache ([_idCache]).
///
/// Call [initialize()] once before use to locate or create the sync root folder.
class GoogleDriveSyncProvider implements SyncStorageProvider {
  final GoogleDriveApiClient _client;

  /// User-configured name for the sync root folder in My Drive.
  /// All sync files live under `My Drive/<syncRootName>/`.
  final String syncRootName;

  String? _rootFolderId;

  /// Maps virtual path segments → Drive file ID.
  /// Populated lazily when listing directories.
  /// e.g. 'oplogs' → 'folder-id', 'oplogs/op-001.bin' → 'file-id'
  final Map<String, String> _idCache = {};

  GoogleDriveSyncProvider({
    required GoogleDriveApiClient client,
    required this.syncRootName,
  }) : _client = client;

  /// Finds or creates the [syncRootName] folder directly under Drive root.
  /// Must be called once before any other method.
  Future<void> initialize() async {
    final children = await _client.listChildren('root');
    final existing = children.where((f) => f.name == syncRootName).firstOrNull;
    if (existing != null) {
      _rootFolderId = existing.id;
    } else {
      final created = await _client.createFolder(
        name: syncRootName,
        parentId: 'root',
      );
      _rootFolderId = created.id;
    }
  }

  String get _root {
    if (_rootFolderId == null) {
      throw StateError(
        'GoogleDriveSyncProvider not initialized — call initialize() first',
      );
    }
    return _rootFolderId!;
  }

  /// Normalizes a path (strips leading slash, trims trailing slash).
  static String _normalize(String path) {
    var s = path;
    if (s.startsWith('/')) s = s.substring(1);
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// Resolves a normalized path to a Drive file/folder ID.
  /// Populates [_idCache] by listing parent directories on cache miss.
  /// Returns null if the path does not exist in Drive.
  Future<String?> _resolveId(String normalizedPath) async {
    if (normalizedPath.isEmpty) return _root;
    if (_idCache.containsKey(normalizedPath)) return _idCache[normalizedPath];

    final parts = p.split(normalizedPath);
    String currentParentId = _root;

    for (int i = 0; i < parts.length; i++) {
      final partialPath = parts.sublist(0, i + 1).join('/');

      if (_idCache.containsKey(partialPath)) {
        currentParentId = _idCache[partialPath]!;
        continue;
      }

      // Cache miss — list parent and populate cache for all its children
      final children = await _client.listChildren(currentParentId);
      final parentPrefix =
          i == 0 ? '' : parts.sublist(0, i).join('/');
      for (final child in children) {
        final childPath =
            parentPrefix.isEmpty ? child.name : '$parentPrefix/${child.name}';
        _idCache[childPath] = child.id;
      }

      if (!_idCache.containsKey(partialPath)) return null;
      currentParentId = _idCache[partialPath]!;
    }

    return _idCache[normalizedPath];
  }

  /// Finds or creates a folder at [normalizedFolderPath] relative to sync root.
  Future<String> _ensureFolder(String normalizedFolderPath) async {
    final existing = await _resolveId(normalizedFolderPath);
    if (existing != null) return existing;

    final parts = p.split(normalizedFolderPath);
    final folderName = parts.last;
    final parentNormalized =
        parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
    final parentId = parentNormalized.isEmpty
        ? _root
        : await _ensureFolder(parentNormalized);

    final folder = await _client.createFolder(
      name: folderName,
      parentId: parentId,
    );
    _idCache[normalizedFolderPath] = folder.id;
    return folder.id;
  }

  @override
  Future<List<SyncFileInfo>> listFiles(String path) async {
    final normalized = _normalize(path);
    final folderId =
        normalized.isEmpty ? _root : await _resolveId(normalized);
    if (folderId == null) return [];

    final children = await _client.listChildren(folderId);
    return children.map((f) {
      final filePath =
          normalized.isEmpty ? f.name : '$normalized/${f.name}';
      _idCache[filePath] = f.id;
      return SyncFileInfo(
        path: filePath,
        sizeBytes: f.size ?? 0,
        lastModified: f.modifiedTime ?? DateTime.now(),
      );
    }).toList();
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final normalized = _normalize(path);
    final fileId = await _resolveId(normalized);
    if (fileId == null) {
      throw GoogleDriveException('File not found: $path');
    }
    return _client.downloadFile(fileId);
  }

  @override
  Future<void> writeFile(String path, Uint8List data) async {
    final normalized = _normalize(path);
    final existingId = await _resolveId(normalized);
    if (existingId != null) {
      await _client.updateFile(fileId: existingId, content: data);
    } else {
      final parts = p.split(normalized);
      final fileName = parts.last;
      final parentNormalized =
          parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
      final parentId = parentNormalized.isEmpty
          ? _root
          : await _ensureFolder(parentNormalized);

      final info = await _client.uploadFile(
        name: fileName,
        parentId: parentId,
        content: data,
      );
      _idCache[normalized] = info.id;
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    final normalized = _normalize(path);
    final fileId = await _resolveId(normalized);
    if (fileId == null) return;
    await _client.trashFile(fileId);
    _idCache.remove(normalized);
  }

  @override
  Future<bool> exists(String path) async {
    final fileId = await _resolveId(_normalize(path));
    return fileId != null;
  }

  @override
  Future<SyncFileInfo> getFileInfo(String path) async {
    final normalized = _normalize(path);
    final fileId = await _resolveId(normalized);
    if (fileId == null) {
      throw GoogleDriveException('File not found: $path');
    }
    final info = await _client.getFileInfo(fileId);
    if (info == null) {
      throw GoogleDriveException('File metadata not found: $path');
    }
    return SyncFileInfo(
      path: normalized,
      sizeBytes: info.size ?? 0,
      lastModified: info.modifiedTime ?? DateTime.now(),
    );
  }
}
