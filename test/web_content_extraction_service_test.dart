import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/services/web_content_extraction_service.dart';

void main() {
  // What pageSourceInfoScript reports for a typical article page.
  const pageInfo = <String, String>{
    'href': 'https://www.example.com/post/123?utm_source=x',
    'canonical': 'https://example.com/post/123',
    'ogUrl': 'https://example.com/post/123',
    'siteName': 'Example',
    'title': 'Post title',
    'byline': 'Jane Doe',
    'published': '2026-08-30T12:00:00Z',
  };

  group('WebContentExtractionService.parsePageSourceInfo', () {
    test('decodes the JSON text the script returns', () {
      // iOS hands the JS string back as is; Android JSON-decodes the native
      // result once, which also leaves a Dart String holding this text.
      final info = WebContentExtractionService.parsePageSourceInfo(
        jsonEncode(pageInfo),
      );
      expect(info, isA<Map<String, dynamic>>());
      expect(info, equals(pageInfo));
    });

    test('unwraps a payload wrapped in a second JSON string layer', () {
      final info = WebContentExtractionService.parsePageSourceInfo(
        jsonEncode(jsonEncode(pageInfo)),
      );
      expect(info, equals(pageInfo));
    });

    test('accepts a Map, stringifying keys and passing values through', () {
      final info = WebContentExtractionService.parsePageSourceInfo(
        <Object?, Object?>{
          'href': 'https://example.com/',
          'published': 1756555200000,
          'title': null,
          'byline': ['not', 'a', 'string'],
          7: true,
        },
      );
      expect(info, isA<Map<String, dynamic>>());
      expect(info['href'], 'https://example.com/');
      expect(info['published'], 1756555200000);
      expect(info['title'], isNull);
      expect(info['byline'], ['not', 'a', 'string']);
      expect(info['7'], isTrue);
    });

    test('yields an empty map for null, garbage and non-object results', () {
      const inputs = <Object?>[
        null,
        '',
        '   ',
        'not json',
        '{not json either',
        '"just a string"',
        '[1, 2]',
        '42',
        'null',
        42,
        true,
        [1, 2],
      ];
      for (final input in inputs) {
        final info = WebContentExtractionService.parsePageSourceInfo(input);
        expect(info, isA<Map<String, dynamic>>(), reason: 'input: $input');
        expect(info, isEmpty, reason: 'input: $input');
      }
    });

    test('returns a fresh mutable map so a fallback href can be added', () {
      final info = WebContentExtractionService.parsePageSourceInfo(null);
      info['href'] = 'https://example.com/';
      expect(info['href'], 'https://example.com/');
      expect(WebContentExtractionService.parsePageSourceInfo(null), isEmpty);
    });

    test('feeds NoteSource.fromPageInfo with the keys it expects', () {
      final source = NoteSource.fromPageInfo(
        WebContentExtractionService.parsePageSourceInfo(jsonEncode(pageInfo)),
        sharedUrl: 'https://www.example.com/post/123?utm_source=x',
        method: NoteSourceMethod.extract,
      );
      expect(source.url, 'https://example.com/post/123');
      expect(source.sharedUrl, 'https://www.example.com/post/123?utm_source=x');
      expect(source.canonicalUrl, 'https://example.com/post/123');
      expect(source.title, 'Post title');
      expect(source.siteName, 'Example');
      expect(source.byline, 'Jane Doe');
      expect(source.publishedAt, DateTime.utc(2026, 8, 30, 12));
      expect(source.clippedAt, isNotNull);
      expect(source.method, NoteSourceMethod.extract);
      expect(source.kind, NoteSourceKind.web);
    });
  });

  group('WebContentExtractionService.pageSourceInfoScript', () {
    const script = WebContentExtractionService.pageSourceInfoScript;

    test('reads the page location, title and head metadata', () {
      for (final needle in const [
        'window.location.href',
        'document.title',
        'link[rel~="canonical"]',
        'meta[property="og:url"]',
        'meta[name="og:url"]',
        'meta[property="og:site_name"]',
        'meta[name="author"]',
        'meta[property="article:author"]',
        'meta[property="article:published_time"]',
        'meta[name="date"]',
      ]) {
        expect(script, contains(needle));
      }
    });

    test('reports every key fromPageInfo reads, as guarded JSON text', () {
      for (final key in pageInfo.keys) {
        expect(script, contains('$key:'));
      }
      expect(script, contains('JSON.stringify'));
      expect(script, contains('try {'));
    });

    test('skips a URL-valued article:author and caps the display strings', () {
      // Open Graph's article:author is a profile URL; only a name may stand
      // in for a missing author.
      expect(script, contains(r'/^https?:/i'));
      // title, siteName and byline are display strings; a runaway
      // document.title must not land whole in notes.metadata. URLs and the
      // published date are identity data and stay uncapped.
      for (final field in ['title', 'siteName', 'byline']) {
        expect(script, contains('info.$field.slice(0, 1000)'));
      }
      for (final field in ['href', 'canonical', 'ogUrl', 'published']) {
        expect(script, isNot(contains('info.$field.slice')));
      }
    });
  });
}
