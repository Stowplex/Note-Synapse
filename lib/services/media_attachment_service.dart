import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../services/logger_service.dart';
import '../services/network_provider.dart';
import '../utils/remote_image_storage.dart';

class RemoteImageDownloadReport {
  final Map<String, String> urlToRelativePath;
  final List<String> downloadedRelativePaths;
  final List<String> failedUrls;

  const RemoteImageDownloadReport({
    this.urlToRelativePath = const {},
    this.downloadedRelativePaths = const [],
    this.failedUrls = const [],
  });

  bool get hasDownloads => downloadedRelativePaths.isNotEmpty;
  bool get hasFailures => failedUrls.isNotEmpty;

  RemoteImageDownloadReport merge(RemoteImageDownloadReport other) {
    return RemoteImageDownloadReport(
      urlToRelativePath: {...urlToRelativePath, ...other.urlToRelativePath},
      downloadedRelativePaths: [
        ...downloadedRelativePaths,
        ...other.downloadedRelativePaths,
      ],
      failedUrls: [...failedUrls, ...other.failedUrls],
    );
  }
}

class MediaAttachmentService {
  static const _supportedExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'tiff',
    'svg',
  };

  static Future<RemoteImageDownloadReport> downloadRemoteImages({
    required String noteId,
    required Iterable<String> imageUrls,
    bool force = false,
  }) async {
    final uniqueUrls = {
      for (final url in imageUrls)
        if (_isHttpUrl(url)) url,
    }.toList(growable: false);

    if (uniqueUrls.isEmpty) {
      return const RemoteImageDownloadReport();
    }

    final Map<String, String> resolvedPaths = {};
    final List<String> downloaded = [];
    final List<String> failures = [];

    for (final url in uniqueUrls) {
      if (!force) {
        final existing = await RemoteImageStorage.resolveRelativePath(
          noteId: noteId,
          imageUrl: url,
        );
        if (existing != null) {
          resolvedPaths[url] = existing;
          continue;
        }
      }

      try {
        final response = await NetworkProvider.get(Uri.parse(url));
        if (response.statusCode != 200) {
          failures.add(url);
          continue;
        }
        final contentType =
            response.headers['content-type']?.toLowerCase() ?? '';
        if (!contentType.startsWith('image/') && !contentType.contains('svg')) {
          failures.add(url);
          continue;
        }

        var extension = _extensionFromUrl(url);
        if (extension == null || !_supportedExtensions.contains(extension)) {
          extension = _extensionFromContentType(contentType) ?? 'bin';
        }

        List<int> bytes = response.bodyBytes;
        if (extension != 'svg') {
          bytes = await _maybeResize(bytes, extension);
        }

        final relativePath = await RemoteImageStorage.saveImage(
          noteId: noteId,
          imageUrl: url,
          bytes: bytes,
          extension: extension,
        );

        downloaded.add(relativePath);
        resolvedPaths[url] = relativePath;
      } catch (e, stackTrace) {
        LoggerService.error(
          'Failed to download image $url',
          error: e,
          stackTrace: stackTrace,
        );
        failures.add(url);
      }
    }

    return RemoteImageDownloadReport(
      urlToRelativePath: resolvedPaths,
      downloadedRelativePaths: downloaded,
      failedUrls: failures,
    );
  }

  static bool _isHttpUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static String? _extensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final lastSegment = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : null;
      if (lastSegment == null || !lastSegment.contains('.')) {
        return null;
      }
      final ext = lastSegment.split('.').last;
      if (ext.isEmpty) return null;
      final clean = ext.split(RegExp(r'[\?\#]')).first.toLowerCase();
      return clean;
    } catch (_) {
      return null;
    }
  }

  static String? _extensionFromContentType(String contentType) {
    if (contentType.contains('jpeg')) return 'jpg';
    if (contentType.contains('png')) return 'png';
    if (contentType.contains('gif')) return 'gif';
    if (contentType.contains('webp')) return 'webp';
    if (contentType.contains('bmp')) return 'bmp';
    if (contentType.contains('tiff')) return 'tiff';
    if (contentType.contains('svg')) return 'svg';
    return null;
  }

  static Future<List<int>> _maybeResize(
    List<int> bytes,
    String extension,
  ) async {
    try {
      // Offload CPU-intensive image processing to a background isolate
      return await compute(
        _processResizeInIsolate,
        _ResizeRequest(bytes, extension),
      );
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Image resize failed, storing original bytes',
        error: e,
        stackTrace: stackTrace,
      );
      return bytes;
    }
  }

  static Future<File?> getLocalFile({
    required String noteId,
    required String imageUrl,
  }) async {
    final absolutePath = await RemoteImageStorage.resolveAbsolutePath(
      noteId: noteId,
      imageUrl: imageUrl,
    );
    if (absolutePath == null) {
      return null;
    }

    final file = File(absolutePath);
    if (await file.exists()) {
      return file;
    }
    return null;
  }
}

class _ResizeRequest {
  final List<int> bytes;
  final String extension;

  _ResizeRequest(this.bytes, this.extension);
}

Future<List<int>> _processResizeInIsolate(_ResizeRequest request) async {
  final bytes = request.bytes;
  final extension = request.extension;

  final image = img.decodeImage(Uint8List.fromList(bytes));
  if (image == null) {
    return bytes;
  }

  // Constants must be duplicated here or made public if they were private in the class
  // Since they are private in the class and this is a top-level function,
  // we either need to start using them from the class (if public) or redefining them.
  // The safest way for a top-level function in the same file is to access them if they are in scope,
  // but static private members of a class are NOT in scope for a top-level function outside the class unless I move them out.
  // OR I can just hardcode them or pass them in the request.
  // Let's check the original file. _maxWidth and _maxHeight are static const private members.
  // I will move them to top-level constants or just redefine them locally to avoid visibility issues if I can't change the class structure easily.
  // Actually, I can just change the class members to public or internal, OR just redefine them here. Re-defining is safest to avoid changing too much.
  const maxWidth = 1080;
  const maxHeight = 1920;

  final width = image.width;
  final height = image.height;
  final widthScale = width > maxWidth ? maxWidth / width : 1.0;
  final heightScale = height > maxHeight ? maxHeight / height : 1.0;
  final scale = math.min(widthScale, heightScale);

  if (scale >= 1.0) {
    return bytes;
  }

  final resized = img.copyResize(
    image,
    width: (width * scale).round(),
    height: (height * scale).round(),
    interpolation: img.Interpolation.average,
  );

  switch (extension) {
    case 'jpg':
    case 'jpeg':
      return img.encodeJpg(resized, quality: 90);
    case 'png':
      return img.encodePng(resized);
    case 'gif':
      return img.encodeGif(resized);
    case 'webp':
      return bytes;
    default:
      return img.encodePng(resized);
  }
}
