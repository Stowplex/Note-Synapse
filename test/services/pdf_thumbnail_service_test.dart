import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/pdf_thumbnail_service.dart';

void main() {
  late PdfThumbnailService service;

  setUp(() {
    service = PdfThumbnailService();
  });

  group('input validation', () {
    test('returns null for empty path', () async {
      final result = await service.renderPage(pdfPath: '', page: 0);
      expect(result, isNull);
    });

    test('returns null for negative page', () async {
      final result =
          await service.renderPage(pdfPath: '/some/path.pdf', page: -1);
      expect(result, isNull);
    });

    test('returns null for page = -100', () async {
      final result =
          await service.renderPage(pdfPath: '/some/path.pdf', page: -100);
      expect(result, isNull);
    });

    test('returns null for empty path with negative page', () async {
      final result = await service.renderPage(pdfPath: '', page: -1);
      expect(result, isNull);
    });
  });

  group('renderPage with nonexistent file', () {
    test('returns null for nonexistent file', () async {
      final result = await service.renderPage(
        pdfPath: '/nonexistent/path/to/file.pdf',
        page: 0,
      );
      expect(result, isNull);
    });
  });

  group('cache behavior', () {
    test('starts with empty cache', () {
      expect(service.cacheSize, 0);
    });

    test('clearCache resets cache size to zero', () {
      service.putCache('test:0', Uint8List.fromList([1, 2, 3]));
      expect(service.cacheSize, 1);
      service.clearCache();
      expect(service.cacheSize, 0);
    });

    test('putCache stores and getCache retrieves entries', () {
      final data = Uint8List.fromList([10, 20, 30]);
      service.putCache('/path.pdf:0', data);
      expect(service.getCache('/path.pdf:0'), equals(data));
    });

    test('cache returns same result for same key', () {
      final data = Uint8List.fromList([1, 2, 3]);
      service.putCache('/a.pdf:1', data);
      expect(service.getCache('/a.pdf:1'), same(data));
      expect(service.getCache('/a.pdf:1'), same(data));
    });

    test('getCache returns null for missing key', () {
      expect(service.getCache('nonexistent:0'), isNull);
    });

    test('cache respects maxSize and evicts oldest entries', () {
      final smallService = PdfThumbnailService(maxCacheSize: 3);

      smallService.putCache('a:0', Uint8List.fromList([1]));
      smallService.putCache('b:0', Uint8List.fromList([2]));
      smallService.putCache('c:0', Uint8List.fromList([3]));
      expect(smallService.cacheSize, 3);

      // Adding a 4th entry should evict the first (oldest)
      smallService.putCache('d:0', Uint8List.fromList([4]));
      expect(smallService.cacheSize, 3);
      expect(smallService.getCache('a:0'), isNull); // evicted
      expect(smallService.getCache('b:0'), isNotNull);
      expect(smallService.getCache('c:0'), isNotNull);
      expect(smallService.getCache('d:0'), isNotNull);
    });

    test('eviction removes entries in insertion order', () {
      final smallService = PdfThumbnailService(maxCacheSize: 2);

      smallService.putCache('first:0', Uint8List.fromList([1]));
      smallService.putCache('second:0', Uint8List.fromList([2]));
      smallService.putCache('third:0', Uint8List.fromList([3]));

      // 'first' should be evicted
      expect(smallService.getCache('first:0'), isNull);
      expect(smallService.getCache('second:0'), isNotNull);
      expect(smallService.getCache('third:0'), isNotNull);

      // Adding another evicts 'second'
      smallService.putCache('fourth:0', Uint8List.fromList([4]));
      expect(smallService.getCache('second:0'), isNull);
      expect(smallService.getCache('third:0'), isNotNull);
      expect(smallService.getCache('fourth:0'), isNotNull);
    });

    test('multiple instances have independent caches', () {
      final service1 = PdfThumbnailService();
      final service2 = PdfThumbnailService();

      service1.putCache('key:0', Uint8List.fromList([1]));
      expect(service1.cacheSize, 1);
      expect(service2.cacheSize, 0);
    });
  });
}
