import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// Service for rendering PDF page thumbnails with an LRU cache.
///
/// Usage:
/// ```dart
/// final service = PdfThumbnailService();
/// final pngBytes = await service.renderPage(pdfPath: '/path/to.pdf', page: 0);
/// ```
class PdfThumbnailService {
  /// Maximum number of cached thumbnails.
  final int maxCacheSize;

  /// LRU cache: key is "$path:$page", value is rendered PNG bytes.
  final Map<String, Uint8List> _cache = {};

  PdfThumbnailService({this.maxCacheSize = 20});

  /// Renders a PDF page to a PNG image.
  ///
  /// [page] is 0-indexed.
  /// [width] controls the rendered width in pixels; height is scaled
  /// proportionally.
  /// Returns PNG bytes or null on error.
  Future<Uint8List?> renderPage({
    required String pdfPath,
    required int page,
    double width = 200,
  }) async {
    if (pdfPath.isEmpty || page < 0) return null;

    final cacheKey = '$pdfPath:$page';
    if (_cache.containsKey(cacheKey)) {
      // Move to end (most recently used)
      final value = _cache.remove(cacheKey)!;
      _cache[cacheKey] = value;
      return value;
    }

    try {
      // Ensure pdfrx cache directory is set
      Pdfrx.getCacheDirectory ??= () async {
        final tempDir = await getTemporaryDirectory();
        return tempDir.path;
      };

      final document = await PdfDocument.openFile(pdfPath);
      try {
        if (page >= document.pages.length) return null;

        final pdfPage = document.pages[page];
        final pageWidth = pdfPage.width;
        final pageHeight = pdfPage.height;
        final scale = width / pageWidth;
        final renderWidth = (pageWidth * scale).toInt();
        final renderHeight = (pageHeight * scale).toInt();

        final pdfImage = await pdfPage.render(
          width: renderWidth,
          height: renderHeight,
          fullWidth: renderWidth.toDouble(),
          fullHeight: renderHeight.toDouble(),
        );
        if (pdfImage == null) return null;

        final uiImage = await pdfImage.createImage();
        try {
          final byteData = await uiImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (byteData == null) return null;

          final pngBytes = Uint8List.fromList(byteData.buffer.asUint8List());

          // Add to cache, evicting oldest if full
          if (_cache.length >= maxCacheSize) {
            _cache.remove(_cache.keys.first);
          }
          _cache[cacheKey] = pngBytes;

          return pngBytes;
        } finally {
          uiImage.dispose();
        }
      } finally {
        document.dispose();
      }
    } catch (e) {
      debugPrint('PdfThumbnailService.renderPage error: $e');
      return null;
    }
  }

  /// Clears the thumbnail cache.
  void clearCache() {
    _cache.clear();
  }

  /// Number of entries currently in the cache.
  @visibleForTesting
  int get cacheSize => _cache.length;

  /// Inserts a value directly into the cache (for testing).
  @visibleForTesting
  void putCache(String key, Uint8List value) {
    if (_cache.length >= maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = value;
  }

  /// Retrieves a cached value by key (for testing).
  @visibleForTesting
  Uint8List? getCache(String key) => _cache[key];
}
