import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/utils/note_metadata.dart';

void main() {
  final clippedAt = DateTime.utc(2026, 9, 6, 17, 4, 11);

  NoteSource source(String url, {String? title, String? id}) => NoteSource(
    id: id,
    url: url,
    title: title,
    clippedAt: clippedAt,
    method: NoteSourceMethod.extract,
  );

  group('NoteSource JSON', () {
    test('round-trips every field', () {
      final original = NoteSource(
        id: 'src-1',
        url: 'https://example.com/post/123',
        sharedUrl: 'https://example.com/post/123?utm_source=x',
        canonicalUrl: 'https://example.com/post/123',
        title: 'Post title',
        siteName: 'Example',
        byline: 'Jane Doe',
        publishedAt: DateTime.utc(2026, 8, 30, 12),
        clippedAt: clippedAt,
        kind: NoteSourceKind.web,
        method: NoteSourceMethod.ai,
      );

      final json = original.toJson();
      final restored = NoteSource.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );

      expect(restored.id, 'src-1');
      expect(restored.url, 'https://example.com/post/123');
      expect(restored.sharedUrl, 'https://example.com/post/123?utm_source=x');
      expect(restored.canonicalUrl, 'https://example.com/post/123');
      expect(restored.title, 'Post title');
      expect(restored.siteName, 'Example');
      expect(restored.byline, 'Jane Doe');
      expect(restored.publishedAt, DateTime.utc(2026, 8, 30, 12));
      expect(restored.clippedAt, clippedAt);
      expect(restored.kind, 'web');
      expect(restored.method, 'ai');
    });

    test('writes dates as UTC ISO strings and omits absent fields', () {
      final json = source('https://example.com/a', id: 'src-2').toJson();

      expect(json.keys.toSet(), {'id', 'url', 'clippedAt', 'kind', 'method'});
      expect(json['clippedAt'], '2026-09-06T17:04:11.000Z');
      expect(json['kind'], 'web');
      expect(json['method'], 'extract');
    });

    test('local clippedAt is stored as the same UTC instant', () {
      final local = DateTime(2026, 9, 6, 10, 30);
      final json = NoteSource(
        url: 'https://example.com',
        clippedAt: local,
        method: NoteSourceMethod.manual,
      ).toJson();

      expect(json['clippedAt'], endsWith('Z'));
      expect(
        DateTime.parse(json['clippedAt'] as String).isAtSameMomentAs(local),
        isTrue,
      );
    });

    test('clippedAt is optional: omitted when null, null when missing', () {
      final json = NoteSource(
        url: 'https://example.com',
        method: NoteSourceMethod.manual,
      ).toJson();
      expect(json.containsKey('clippedAt'), isFalse);

      expect(
        NoteSource.fromJson({'url': 'https://example.com'}).clippedAt,
        isNull,
      );
      expect(
        NoteSource.fromJson({
          'url': 'https://example.com',
          'clippedAt': 'not a date',
        }).clippedAt,
        isNull,
      );
    });

    test('fromJson degrades gracefully on missing optional data', () {
      final restored = NoteSource.fromJson({'url': ' https://example.com '});

      expect(restored.id, isNotEmpty);
      expect(restored.url, 'https://example.com');
      expect(restored.clippedAt, isNull);
      expect(restored.kind, NoteSourceKind.web);
      expect(restored.method, NoteSourceMethod.manual);
      expect(restored.title, isNull);
      expect(restored.publishedAt, isNull);
    });

    test(
      'fromJson accepts epoch milliseconds and keeps unknown kind/method',
      () {
        final restored = NoteSource.fromJson({
          'url': 'https://example.com',
          'clippedAt': clippedAt.millisecondsSinceEpoch,
          'publishedAt': 'not a date',
          'kind': 'podcast',
          'method': 'telepathy',
          'title': 42,
        });

        expect(restored.clippedAt, clippedAt);
        expect(restored.publishedAt, isNull);
        expect(restored.kind, 'podcast');
        expect(restored.method, 'telepathy');
        expect(restored.title, isNull);
      },
    );

    test('fromJson ignores epoch numbers a DateTime cannot hold', () {
      final restored = NoteSource.fromJson({
        'url': 'https://example.com',
        'clippedAt': 1e300,
        'publishedAt': -1e300,
      });

      expect(restored.clippedAt, isNull);
      expect(restored.publishedAt, isNull);
      expect(
        NoteSource.fromJson({
          'url': 'https://example.com',
          'clippedAt': 8640000000000000,
        }).clippedAt?.millisecondsSinceEpoch,
        8640000000000000,
      );
    });

    test('fromJson derives a stable id from the url when none is stored', () {
      final entry = <String, dynamic>{'url': 'https://example.com/post/123'};

      final first = NoteSource.fromJson(entry).id;
      final second = NoteSource.fromJson(Map.of(entry)).id;

      expect(first, isNotEmpty);
      expect(second, first);
      expect(NoteSource.fromJson({...entry, 'id': ' '}).id, first);
      expect(
        NoteSource.fromJson({'url': 'https://example.com/post/124'}).id,
        isNot(first),
      );
    });

    test('fromJson rejects entries without a url', () {
      expect(() => NoteSource.fromJson({}), throwsFormatException);
      expect(() => NoteSource.fromJson({'url': '  '}), throwsFormatException);
      expect(() => NoteSource.fromJson({'url': 12}), throwsFormatException);
    });

    test('constructor generates a unique id and stores clippedAt as given', () {
      final a = NoteSource(url: 'https://a', method: NoteSourceMethod.manual);
      final b = NoteSource(url: 'https://a', method: NoteSourceMethod.manual);

      expect(a.id, isNot(b.id));
      expect(a.clippedAt, isNull);
      expect(
        NoteSource(
          url: 'https://a',
          clippedAt: clippedAt,
          method: NoteSourceMethod.manual,
        ).clippedAt,
        clippedAt,
      );
    });

    test('constructor stores blank optional strings as null', () {
      final s = NoteSource(
        url: 'https://example.com',
        sharedUrl: '',
        canonicalUrl: ' ',
        title: '\n',
        siteName: '  Example  ',
        byline: '',
        method: NoteSourceMethod.manual,
      );

      expect(s.sharedUrl, isNull);
      expect(s.canonicalUrl, isNull);
      expect(s.title, isNull);
      expect(s.siteName, 'Example');
      expect(s.byline, isNull);
    });

    test('copyWith replaces only the given fields', () {
      final copy = source(
        'https://example.com',
        title: 'Old',
        id: 'src-3',
      ).copyWith(title: 'New', method: NoteSourceMethod.manual);

      expect(copy.id, 'src-3');
      expect(copy.url, 'https://example.com');
      expect(copy.title, 'New');
      expect(copy.method, 'manual');
      expect(copy.clippedAt, clippedAt);
    });

    test('copyWith clears an optional string when given an empty string', () {
      final cleared = NoteSource(
        id: 'src-4',
        url: 'https://example.com',
        title: 'Old',
        siteName: 'Example',
        method: NoteSourceMethod.extract,
      ).copyWith(title: '', siteName: '  ');

      expect(cleared.title, isNull);
      expect(cleared.siteName, isNull);
      final json = cleared.toJson();
      expect(json.containsKey('title'), isFalse);
      expect(json.containsKey('siteName'), isFalse);
    });
  });

  group('NoteSource.fromPageInfo', () {
    const shared = 'https://example.com/post/123?utm_source=x';

    test('canonical wins over ogUrl, href and sharedUrl', () {
      final s = NoteSource.fromPageInfo(
        {
          'href': 'https://example.com/post/123?utm_source=x&ref=y',
          'canonical': 'https://example.com/post/123',
          'ogUrl': 'https://example.com/og/123',
          'title': 'Post title',
          'siteName': 'Example',
          'byline': 'Jane Doe',
          'published': '2026-08-30T12:00:00Z',
        },
        sharedUrl: shared,
        method: NoteSourceMethod.extract,
        clippedAt: clippedAt,
      );

      expect(s.url, 'https://example.com/post/123');
      expect(s.canonicalUrl, 'https://example.com/post/123');
      expect(s.sharedUrl, shared);
      expect(s.title, 'Post title');
      expect(s.siteName, 'Example');
      expect(s.byline, 'Jane Doe');
      expect(s.publishedAt, DateTime.utc(2026, 8, 30, 12));
      expect(s.clippedAt, clippedAt);
      expect(s.kind, NoteSourceKind.web);
      expect(s.method, NoteSourceMethod.extract);
      expect(s.id, isNotEmpty);
    });

    test('falls back to ogUrl, then href', () {
      final viaOg = NoteSource.fromPageInfo(
        {'href': 'https://example.com/h', 'ogUrl': 'https://example.com/og'},
        sharedUrl: shared,
        method: NoteSourceMethod.ai,
      );
      expect(viaOg.url, 'https://example.com/og');
      expect(viaOg.canonicalUrl, isNull);

      final viaHref = NoteSource.fromPageInfo(
        {'href': 'https://example.com/h', 'canonical': '', 'ogUrl': 42},
        sharedUrl: shared,
        method: NoteSourceMethod.ai,
      );
      expect(viaHref.url, 'https://example.com/h');
    });

    test('defaults clippedAt to now', () {
      final before = DateTime.now();
      final s = NoteSource.fromPageInfo(
        {'href': 'https://example.com/h'},
        sharedUrl: shared,
        method: NoteSourceMethod.extract,
      );
      final after = DateTime.now();

      expect(s.clippedAt, isNotNull);
      expect(s.clippedAt!.isBefore(before), isFalse);
      expect(s.clippedAt!.isAfter(after), isFalse);
    });

    test('falls back to sharedUrl and only records it when different', () {
      final fromShared = NoteSource.fromPageInfo(
        const {},
        sharedUrl: ' $shared ',
        method: NoteSourceMethod.extract,
      );
      expect(fromShared.url, shared);
      expect(fromShared.sharedUrl, isNull);

      final same = NoteSource.fromPageInfo(
        {'href': shared},
        sharedUrl: shared,
        method: NoteSourceMethod.extract,
      );
      expect(same.sharedUrl, isNull);

      final different = NoteSource.fromPageInfo(
        {'href': 'https://example.com/post/123'},
        sharedUrl: shared,
        method: NoteSourceMethod.extract,
      );
      expect(different.sharedUrl, shared);
    });

    test('resolves a relative canonical and ignores non-http candidates', () {
      final relative = NoteSource.fromPageInfo(
        {
          'href': 'https://example.com/post/123?utm=x',
          'canonical': '/post/123',
        },
        sharedUrl: shared,
        method: NoteSourceMethod.extract,
      );
      expect(relative.url, 'https://example.com/post/123');

      final junk = NoteSource.fromPageInfo(
        {
          'href': 'https://example.com/h',
          'canonical': 'javascript:void(0)',
          'ogUrl': 'mailto:someone@example.com',
        },
        sharedUrl: shared,
        method: NoteSourceMethod.extract,
      );
      expect(junk.url, 'https://example.com/h');
      expect(junk.canonicalUrl, isNull);
    });

    test('tolerates missing, empty and non-string keys', () {
      final s = NoteSource.fromPageInfo(
        {
          'title': '  Line one\n\n  line two  ',
          'siteName': '',
          'byline': null,
          'published': 'yesterday',
          'href': ['nope'],
        },
        sharedUrl: '',
        method: NoteSourceMethod.extract,
        kind: NoteSourceKind.file,
      );

      expect(s.url, '');
      expect(s.sharedUrl, isNull);
      expect(s.title, 'Line one line two');
      expect(s.siteName, isNull);
      expect(s.byline, isNull);
      expect(s.publishedAt, isNull);
      expect(s.kind, NoteSourceKind.file);
      expect(s.host, '');
      expect(s.displayTitle, 'Line one line two');
    });
  });

  group('NoteSource.host / displayTitle', () {
    test('strips www. and lower-cases the host', () {
      expect(source('https://www.Example.COM/x').host, 'example.com');
      expect(source('https://blog.example.com/').host, 'blog.example.com');
      expect(source('http://wwwexample.com').host, 'wwwexample.com');
    });

    test('decodes a Unicode host and leaves punycode alone', () {
      expect(source('https://例え.jp/').host, '例え.jp');
      expect(source('https://www.例え.jp/path').host, '例え.jp');
      expect(source('https://xn--r8jz45g.jp/').host, 'xn--r8jz45g.jp');
      expect(source('https://例え.jp/path').compactUrl, '例え.jp/path');
    });

    test('handles scheme-less and garbage urls without throwing', () {
      expect(source('example.com/path').host, 'example.com');
      expect(source('').host, '');
      expect(source('not a url at all ::: ###').host, '');
    });

    test('displayTitle falls back to host, then url', () {
      expect(source('https://www.example.com/a', title: 'T').displayTitle, 'T');
      expect(
        source('https://www.example.com/a', title: ' ').displayTitle,
        'example.com',
      );
      expect(source('https://www.example.com/a').displayTitle, 'example.com');
      expect(source('???').displayTitle, '???');
    });
  });

  group('NoteSource.compactUrl', () {
    test('shortens a 300-character url to host plus an ellipsized path', () {
      final path = List.generate(40, (i) => 'segment$i').join('/');
      final url = 'https://www.example.com/$path?utm_source=x#frag';
      expect(url.length, greaterThanOrEqualTo(300));

      final compact = source(url).compactUrl;

      expect(compact, startsWith('example.com/segment0/'));
      expect(compact, endsWith('/segment39'));
      expect(compact, contains('/…/'));
      expect(compact, isNot(contains('https://')));
      expect(compact, isNot(contains('www.')));
      expect(compact, isNot(contains('utm_source')));
      expect(compact, isNot(contains('#')));
      expect(compact.length, lessThanOrEqualTo('example.com/'.length + 48));
      expect(compact, isNot(contains('\n')));
    });

    test('middle-ellipsizes a single overlong segment', () {
      final compact = source('https://example.com/${'x' * 300}').compactUrl;

      expect(compact, startsWith('example.com/xxx'));
      expect(compact, endsWith('xxx'));
      expect(compact, contains('…'));
      expect(compact.length, 'example.com/'.length + 48);
    });

    test('keeps the query for a one-segment path', () {
      expect(
        source('https://www.youtube.com/watch?v=abc').compactUrl,
        'youtube.com/watch?v=abc',
      );
      expect(source('https://example.com/?q=1').compactUrl, 'example.com/?q=1');
    });

    test('drops the query once the path has two or more segments', () {
      expect(
        source('https://example.com/blog/post?utm_source=x&ref=y').compactUrl,
        'example.com/blog/post',
      );
    });

    test('renders a bare host', () {
      expect(source('https://www.example.com').compactUrl, 'example.com');
      expect(source('https://example.com/').compactUrl, 'example.com');
      expect(source('http://localhost:8080/a').compactUrl, 'localhost:8080/a');
    });

    test('drops the fragment', () {
      expect(
        source('https://example.com/docs#section-2').compactUrl,
        'example.com/docs',
      );
      expect(source('https://example.com/#top').compactUrl, 'example.com');
    });

    test('decodes percent-encoded paths and never wraps', () {
      expect(
        source('https://zh.wikipedia.org/wiki/%E4%B8%AD%E6%96%87').compactUrl,
        'zh.wikipedia.org/wiki/中文',
      );
      expect(
        source('https://example.com/a%0Ab%20c').compactUrl,
        'example.com/a b c',
      );
    });

    test('never throws on scheme-less, garbage or badly escaped urls', () {
      expect(source('example.com/path').compactUrl, 'example.com/path');
      expect(source('www.example.com').compactUrl, 'example.com');
      final garbage = source('not a url at all ::: ###').compactUrl;
      expect(garbage, isNotEmpty);
      expect(garbage, isNot(contains('#')));
      expect(source('').compactUrl, '');

      // Percent-escapes that are not valid UTF-8 (Uri.pathSegments throws).
      expect(
        source('https://example.com/caf%E9').compactUrl,
        'example.com/caf%E9',
      );
      expect(
        source('https://example.com/%FF').compactUrl,
        startsWith('example.com/'),
      );
      expect(
        source('https://example.com/%E4%B8').compactUrl,
        startsWith('example.com/'),
      );
    });
  });

  group('NoteMetadata.decode', () {
    test('returns null for null, blank, invalid or non-object JSON', () {
      expect(NoteMetadata.decode(null), isNull);
      expect(NoteMetadata.decode('   '), isNull);
      expect(NoteMetadata.decode('{not json'), isNull);
      expect(NoteMetadata.decode('[1, 2]'), isNull);
      expect(NoteMetadata.decode('"text"'), isNull);
    });

    test('returns the object for valid JSON', () {
      final map = NoteMetadata.decode('{"markers": [], "sources": []}');
      expect(map, {'markers': [], 'sources': []});
    });
  });

  test('stores url trimmed so the persisted value is the identity key', () {
    final source = NoteSource(
      url: '  https://example.com/a \n',
      method: 'manual',
    );
    expect(source.url, 'https://example.com/a');
    expect(source.toJson()['url'], 'https://example.com/a');
    expect(NoteMetadata.sourceKey(source), source.url);
  });

  group('NoteMetadata.readSources', () {
    test('keeps the first entry for a repeated url, like withSources', () {
      final sources = NoteMetadata.readSources({
        'sources': [
          {'url': 'https://example.com/a', 'title': 'first'},
          {'url': 'https://example.com/a ', 'title': 'second'},
          {'url': 'https://example.com/b'},
        ],
      });
      expect(sources.map((s) => s.url), [
        'https://example.com/a',
        'https://example.com/b',
      ]);
      expect(sources.first.title, 'first');
      expect(sources.map((s) => s.id).toSet().length, 2);
    });

    test('returns an empty list when absent or not a list', () {
      expect(NoteMetadata.readSources(null), isEmpty);
      expect(NoteMetadata.readSources({}), isEmpty);
      expect(NoteMetadata.readSources({'sources': 'nope'}), isEmpty);
      expect(
        NoteMetadata.readSources({
          'sources': {'url': 'x'},
        }),
        isEmpty,
      );
    });

    test('ignores malformed entries and keeps the rest in order', () {
      final sources = NoteMetadata.readSources({
        'sources': [
          {
            'id': 'a',
            'url': 'https://a.example',
            'clippedAt': '2026-09-06T00:00:00Z',
            'method': 'extract',
          },
          'just a string',
          42,
          null,
          {'id': 'no-url', 'title': 'Missing url'},
          {'url': ''},
          {'id': 'b', 'url': 'https://b.example'},
        ],
      });

      expect(sources.map((s) => s.url), [
        'https://a.example',
        'https://b.example',
      ]);
      expect(sources.first.id, 'a');
      expect(sources.first.clippedAt, DateTime.utc(2026, 9, 6));
      expect(sources.last.id, 'b');
    });

    test('reads entries whose map type is not Map<String, dynamic>', () {
      final metadata = <String, dynamic>{
        'sources': <Map<String, String>>[
          {'url': 'https://typed.example'},
        ],
      };
      expect(
        NoteMetadata.readSources(metadata).single.url,
        'https://typed.example',
      );
    });
  });

  group('NoteMetadata.withSources', () {
    test('preserves markers and other keys and does not mutate the input', () {
      final markers = [
        {'id': 'm1', 'index': 1},
      ];
      final original = <String, dynamic>{'markers': markers, 'custom': 'kept'};

      final result = NoteMetadata.withSources(original, [
        source('https://a.example', id: 'a'),
      ]);

      expect(result['markers'], same(markers));
      expect(result['custom'], 'kept');
      expect((result['sources'] as List).single['id'], 'a');
      expect(original.containsKey('sources'), isFalse);
      expect(identical(result, original), isFalse);
    });

    test('replaces an existing sources list', () {
      final original = NoteMetadata.withSources(null, [
        source('https://old.example', id: 'old'),
      ]);

      final result = NoteMetadata.withSources(original, [
        source('https://new.example', id: 'new'),
      ]);

      expect((result['sources'] as List).map((e) => e['id']), ['new']);
      expect((original['sources'] as List).map((e) => e['id']), ['old']);
    });

    test('de-duplicates on url keeping the first occurrence', () {
      final result = NoteMetadata.withSources(null, [
        source('https://a.example', id: 'first', title: 'First'),
        source('https://b.example', id: 'b'),
        source(' https://a.example ', id: 'second', title: 'Second'),
      ]);

      final list = result['sources'] as List;
      expect(list.map((e) => e['id']), ['first', 'b']);
      expect(list.first['title'], 'First');
    });

    test('drops sources with a blank url so reads and writes agree', () {
      final result = NoteMetadata.withSources(null, [
        source('', id: 'blank'),
        source('   ', id: 'spaces'),
        source('https://a.example', id: 'a'),
      ]);

      expect((result['sources'] as List).map((e) => e['id']), ['a']);
      expect(NoteMetadata.withSources(null, [source('')]), isEmpty);
      expect(
        NoteMetadata.readSources(
          NoteMetadata.decode(NoteMetadata.encodeSources([source('')])),
        ),
        isEmpty,
      );
    });

    test('removes the key for an empty list', () {
      final result = NoteMetadata.withSources({
        'markers': [],
        'sources': [
          {'url': 'x'},
        ],
      }, []);
      expect(result.containsKey('sources'), isFalse);
      expect(result['markers'], []);
      expect(NoteMetadata.withSources(null, []), isEmpty);
    });
  });

  group('NoteMetadata.encodeSources', () {
    test('produces JSON that decode/readSources round-trip', () {
      final encoded = NoteMetadata.encodeSources([
        source('https://a.example', id: 'a', title: 'A'),
        source('https://a.example', id: 'dup'),
      ]);

      final sources = NoteMetadata.readSources(NoteMetadata.decode(encoded));
      expect(sources.single.id, 'a');
      expect(sources.single.title, 'A');
      expect(sources.single.clippedAt, clippedAt);
    });

    test('merges into existing metadata when asked', () {
      final encoded = NoteMetadata.encodeSources(
        [source('https://a.example', id: 'a')],
        into: {
          'markers': [
            {'id': 'm1'},
          ],
        },
      );

      final map = NoteMetadata.decode(encoded)!;
      expect((map['markers'] as List).single['id'], 'm1');
      expect((map['sources'] as List).single['id'], 'a');
      expect(NoteMetadata.encodeSources([]), '{}');
    });
  });
}
