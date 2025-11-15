import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'file_utils.dart';

class RemoteImageStorage {
  static final Map<String, Map<String, String>> _noteCache = {};
  static final Map<String, Future<Map<String, String>>> _inflightScans = {};

  static String _hashUrl(String url) {
    return sha256.convert(utf8.encode(url)).toString();
  }

  static Future<Map<String, String>> _loadCacheForNote(String noteId) async {
    if (_noteCache.containsKey(noteId)) {
      return _noteCache[noteId]!;
    }
    if (_inflightScans.containsKey(noteId)) {
      return _inflightScans[noteId]!;
    }

    final future = _scanAttachments(noteId);
    _inflightScans[noteId] = future;
    final result = await future;
    _noteCache[noteId] = result;
    _inflightScans.remove(noteId);
    return result;
  }

  static Future<Map<String, String>> _scanAttachments(String noteId) async {
    final dir = await FileUtils.getPrivateStorageDirectory();
    final Map<String, String> map = {};
    if (!await dir.exists()) {
      return map;
    }

    final prefix = '${noteId}_';
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith(prefix)) continue;
      final withoutExt = name.substring(prefix.length);
      final hash = withoutExt.contains('.')
          ? withoutExt.split('.').first
          : withoutExt;
      map[hash] = name;
    }
    return map;
  }

  static Future<String> saveImage({
    required String noteId,
    required String imageUrl,
    required List<int> bytes,
    required String extension,
  }) async {
    final sanitizedExtension = extension
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
        .toLowerCase();
    final hash = _hashUrl(imageUrl);
    final fileName = '${noteId}_$hash.$sanitizedExtension';
    final dir = await FileUtils.getPrivateStorageDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);

    _noteCache.putIfAbsent(noteId, () => {})[hash] = fileName;
    return 'attachments/$fileName';
  }

  static Future<String?> resolveRelativePath({
    required String noteId,
    required String imageUrl,
  }) async {
    final fileName = await _locateFileName(noteId: noteId, imageUrl: imageUrl);
    if (fileName == null) {
      return null;
    }
    return 'attachments/$fileName';
  }

  static Future<String?> resolveAbsolutePath({
    required String noteId,
    required String imageUrl,
  }) async {
    final fileName = await _locateFileName(noteId: noteId, imageUrl: imageUrl);
    if (fileName == null) {
      return null;
    }
    final dir = await FileUtils.getPrivateStorageDirectory();
    return p.join(dir.path, fileName);
  }

  static Future<String?> _locateFileName({
    required String noteId,
    required String imageUrl,
  }) async {
    final hash = _hashUrl(imageUrl);
    final cache = await _loadCacheForNote(noteId);
    if (cache.containsKey(hash)) {
      return cache[hash];
    }
    return null;
  }
}
