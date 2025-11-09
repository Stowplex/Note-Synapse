import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'file_type_utils.dart';

/// Utilities for working with the custom `synapsetemp:///` URI scheme.
///
/// This scheme allows JavaScript apps running inside Synapse to persist
/// transient files into the app's cache directory and reference them by URI.
/// Dart code can then resolve, read, and promote those files into permanent
/// storage when required (e.g. when saving notes or invoking chatAI).
class SynapseTempUtils {
  SynapseTempUtils._();

  static const String scheme = 'synapsetemp';
  static const String _cacheFolderName = 'synapse_temp';

  static final Uuid _uuid = const Uuid();
  static Future<Directory>? _cacheDirectoryFuture;

  /// Returns the cache directory that stores synapsetemp files, creating it if
  /// necessary. The directory is a deterministic sub-folder inside the system
  /// temporary directory to allow safe resolution and validation.
  static Future<Directory> _ensureCacheDirectory() {
    _cacheDirectoryFuture ??= _createCacheDirectory();
    return _cacheDirectoryFuture!;
  }

  static Future<Directory> _createCacheDirectory() async {
    final baseTempDir = await getTemporaryDirectory();
    final cacheDir = Directory(p.join(baseTempDir.path, _cacheFolderName));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  /// Creates a new temporary file from the provided data and returns the
  /// resulting URI alongside metadata.
  static Future<SynapseTempSaveResult> saveTempData({
    required String mimeType,
    String? text,
    String? base64Data,
    Uint8List? bytes,
  }) async {
    if ((text == null || text.isEmpty) &&
        (base64Data == null || base64Data.isEmpty) &&
        (bytes == null || bytes.isEmpty)) {
      throw ArgumentError('Either text, base64Data, or bytes must be provided');
    }

    Uint8List fileBytes;
    if (bytes != null && bytes.isNotEmpty) {
      fileBytes = bytes;
    } else if (text != null) {
      fileBytes = Uint8List.fromList(utf8.encode(text));
    } else {
      var payload = base64Data!;
      if (payload.contains(',')) {
        payload = payload.split(',').last;
      }
      fileBytes = base64Decode(payload);
    }

    final normalizedMime = mimeType.trim().toLowerCase();
    final extension = FileTypeUtils.getExtensionForMime(normalizedMime);
    final cacheDir = await _ensureCacheDirectory();
    final fileName = 'syn_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}.$extension';
    final filePath = p.join(cacheDir.path, fileName);

    final file = File(filePath);
    await file.writeAsBytes(fileBytes, flush: true);

    final uri = buildUriFromFileName(fileName);
    return SynapseTempSaveResult(
      uri: uri,
      file: file,
      mimeType: normalizedMime,
    );
  }

  /// Returns true if the provided string is a synapsetemp URI.
  static bool isSynapseTempUri(String? value) {
    if (value == null) return false;
    return value.toLowerCase().startsWith('$scheme://');
  }

  /// Resolves a synapsetemp URI to a file reference within the cache
  /// directory. Throws [ArgumentError] if the URI is invalid or resolves
  /// outside the managed cache directory.
  static Future<File> resolveUri(String uri) async {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme.toLowerCase() != scheme) {
      throw ArgumentError('Invalid synapsetemp URI: $uri');
    }

    final segments = parsed.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) {
      throw ArgumentError('Synapsetemp URI is missing a file path: $uri');
    }

    final relativePath = p.joinAll(segments);
    final cacheDir = await _ensureCacheDirectory();
    final cachePath = p.normalize(cacheDir.absolute.path);
    final resolvedPath = p.normalize(p.join(cacheDir.path, relativePath));

    if (!p.isWithin(cachePath, resolvedPath)) {
      throw ArgumentError('Synapsetemp URI resolves outside cache directory: $uri');
    }

    return File(resolvedPath);
  }

  /// Loads the bytes and MIME type associated with a synapsetemp URI.
  static Future<SynapseTempFile> loadFile(String uri) async {
    final file = await resolveUri(uri);
    if (!await file.exists()) {
      throw FileSystemException('Synapsetemp file not found', file.path);
    }

    final bytes = await file.readAsBytes();
    final fileName = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : file.path.split(Platform.pathSeparator).last;
    final extension = FileTypeUtils.getFileExtension(fileName);
    final mimeType = await FileTypeUtils.getMimeTypeForFile(file.path, extension: extension);

    return SynapseTempFile(
      file: file,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  /// Builds a synapsetemp URI from a relative file name stored in the cache
  /// directory.
  static String buildUriFromFileName(String fileName) {
    final sanitized = fileName.startsWith('/') ? fileName.substring(1) : fileName;
    return '$scheme:///$sanitized';
  }
}

/// Metadata returned when loading a synapsetemp file.
class SynapseTempFile {
  SynapseTempFile({
    required this.file,
    required this.fileName,
    required this.bytes,
    required this.mimeType,
  });

  final File file;
  final String fileName;
  final Uint8List bytes;
  final String mimeType;
}

/// Metadata returned when creating a synapsetemp file.
class SynapseTempSaveResult {
  SynapseTempSaveResult({
    required this.uri,
    required this.file,
    required this.mimeType,
  });

  final String uri;
  final File file;
  final String mimeType;
}

