import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/html_url_absolutizer.dart';

void main() {
  const base = 'https://example.com/docs/guide/index.html';

  group('absolutizeUrls - relative forms', () {
    test('resolves root-relative src', () {
      final result = absolutizeUrls('<img src="/media/hero.png">', base);
      expect(result, contains('src="https://example.com/media/hero.png"'));
    });

    test('resolves parent-relative src', () {
      final result = absolutizeUrls('<img src="../img/a.jpg">', base);
      expect(result, contains('src="https://example.com/docs/img/a.jpg"'));
    });

    test('resolves sibling-relative src', () {
      final result = absolutizeUrls('<img src="a.png">', base);
      expect(result, contains('src="https://example.com/docs/guide/a.png"'));
    });

    test('resolves protocol-relative src using the base scheme', () {
      final result = absolutizeUrls('<img src="//cdn.site/x.png">', base);
      expect(result, contains('src="https://cdn.site/x.png"'));
    });

    test('resolves relative href on anchors', () {
      final result = absolutizeUrls('<a href="/docs/intro">Intro</a>', base);
      expect(result, contains('href="https://example.com/docs/intro"'));
    });

    test('resolves poster attributes', () {
      final result = absolutizeUrls('<video poster="/p.jpg"></video>', base);
      expect(result, contains('poster="https://example.com/p.jpg"'));
    });

    test('resolves query-only and path-with-query values', () {
      final result = absolutizeUrls('<a href="?page=2">Next</a>', base);
      expect(
        result,
        contains('href="https://example.com/docs/guide/index.html?page=2"'),
      );
    });
  });

  group('absolutizeUrls - values left alone', () {
    test('already-absolute URL passes through byte-identical', () {
      const html = '<img src="https://cdn.example.org/a.png">';
      expect(absolutizeUrls(html, base), html);
    });

    test('absolute URLs are never re-encoded by the Uri normalizer', () {
      // Regression guard. Dart's Uri normalizer is not the WHATWG URL parser:
      // routing an already-absolute URL through `Uri.resolve` percent-encodes
      // IDN hosts (breaking DNS), turns `100%.png` into `100%25.png` (a
      // different path), and re-encodes `[`/`]`/`|` in query strings (breaking
      // HMAC-signed CDN URLs). None of these need resolving in the first
      // place, so they must be left alone.
      const cases = [
        '<img src="https://例え.jp/x.png">',
        '<img src="https://x.com/100%.png">',
        '<a href="https://x.com/?filter[]=a&amp;b=1">q</a>',
        '<a href="https://x.com/?a=1|2">pipe</a>',
        '<img src="https://x.com/a%2fb">',
        '<img src="https://x.com:443/a">',
        '<a href="HTTPS://EXAMPLE.COM/A">upper</a>',
      ];
      for (final html in cases) {
        expect(absolutizeUrls(html, base), html, reason: html);
      }
    });

    test('absolute URLs survive untouched beside a rewritten sibling', () {
      // The `changed` short-circuit does not apply here, so this exercises the
      // parse/reserialize path rather than the early return.
      const html =
          '<img src="https://例え.jp/x.png"><img src="/rel.png">';
      final result = absolutizeUrls(html, base);
      expect(result, contains('src="https://例え.jp/x.png"'));
      expect(result, contains('src="https://example.com/rel.png"'));
    });

    test('is idempotent', () {
      const html = '<img src="/a.png"><a href="b.html">b</a>';
      final once = absolutizeUrls(html, base);
      expect(absolutizeUrls(once, base), once);
    });

    test('fragment-only href is preserved byte-identical', () {
      // Regression guard: the note renderer navigates `#...` links in-document
      // via HeadingAnchorRegistry. Resolving them would kick the reader out to
      // a browser.
      const html = '<a href="#top">Back to top</a>';
      expect(absolutizeUrls(html, base), html);
    });

    test('fragment-only href survives alongside a rewritten sibling', () {
      const html = '<a href="#install">Install</a><img src="/a.png">';
      final result = absolutizeUrls(html, base);
      expect(result, contains('href="#install"'));
      expect(result, contains('src="https://example.com/a.png"'));
    });

    test('skips data, mailto, tel, javascript and blob schemes', () {
      const html =
          '<img src="data:image/png;base64,AAAA">'
          '<a href="mailto:a@b.com">mail</a>'
          '<a href="tel:+15551234">call</a>'
          '<a href="javascript:void(0)">js</a>'
          '<img src="blob:https://example.com/1234">'
          '<a href="about:blank">about</a>';
      expect(absolutizeUrls(html, base), html);
    });

    test('skips empty and whitespace-only values', () {
      const html = '<img src=""><a href="   ">x</a>';
      expect(absolutizeUrls(html, base), html);
    });

    test('returns input unchanged for a null base', () {
      const html = '<img src="/a.png">';
      expect(absolutizeUrls(html, null), html);
    });

    test('returns input unchanged for an empty base', () {
      const html = '<img src="/a.png">';
      expect(absolutizeUrls(html, ''), html);
      expect(absolutizeUrls(html, '   '), html);
    });

    test('returns input unchanged for about:blank base', () {
      const html = '<img src="/a.png">';
      expect(absolutizeUrls(html, 'about:blank'), html);
    });

    test('returns input unchanged for a scheme-less base', () {
      const html = '<img src="/a.png">';
      expect(absolutizeUrls(html, '/some/path'), html);
    });

    test('returns empty input unchanged', () {
      expect(absolutizeUrls('', base), '');
    });
  });

  group('absolutizeUrls - srcset', () {
    test('resolves every candidate and preserves descriptors', () {
      final result = absolutizeUrls(
        '<img srcset="/a.png 1x, ../b.png 2x, c.png 640w" src="/a.png">',
        base,
      );
      expect(
        result,
        contains(
          'srcset="https://example.com/a.png 1x, '
          'https://example.com/docs/b.png 2x, '
          'https://example.com/docs/guide/c.png 640w"',
        ),
      );
    });

    test('handles a single candidate with no descriptor', () {
      final result = absolutizeUrls('<img srcset="/a.png">', base);
      expect(result, contains('srcset="https://example.com/a.png"'));
    });

    test('handles candidates separated by a bare comma', () {
      final result = absolutizeUrls('<img srcset="/a.png 1x,/b.png 2x">', base);
      expect(
        result,
        contains('srcset="https://example.com/a.png 1x,'
            'https://example.com/b.png 2x"'),
      );
    });

    test('handles a URL that itself ends with a comma separator', () {
      final result = absolutizeUrls('<img srcset="/a.png, /b.png 2x">', base);
      expect(
        result,
        contains(
          'srcset="https://example.com/a.png, https://example.com/b.png 2x"',
        ),
      );
    });

    test('leaves comma-bearing data URIs intact', () {
      const html = '<img srcset="data:image/png;base64,AAAA 1x">';
      expect(absolutizeUrls(html, base), html);
    });

    test('resolves data-srcset too', () {
      final result = absolutizeUrls('<img data-srcset="/a.png 2x">', base);
      expect(result, contains('data-srcset="https://example.com/a.png 2x"'));
    });
  });

  group('absolutizeUrls - robustness', () {
    test('a malformed URL leaves the rest of the document correct', () {
      // The value must be scheme-less to reach `base.resolve` at all: anything
      // carrying a scheme is skipped before resolution. `//[bad/x.png` is
      // protocol-relative, so it is resolved and throws FormatException on the
      // unmatched '[' — which is exactly the catch this guards.
      final result = absolutizeUrls(
        '<img src="//[bad/x.png"><img src="/good.png">',
        base,
      );
      expect(result, contains('src="//[bad/x.png"'));
      expect(result, contains('src="https://example.com/good.png"'));
    });

    test('rewrites nested elements throughout the tree', () {
      final result = absolutizeUrls(
        '<div><section><p><img src="/deep.png"></p></section></div>',
        base,
      );
      expect(result, contains('src="https://example.com/deep.png"'));
    });

    test('a base carrying its own fragment still resolves correctly', () {
      final result = absolutizeUrls(
        '<img src="a.png">',
        'https://example.com/docs/guide/index.html#section',
      );
      expect(result, contains('src="https://example.com/docs/guide/a.png"'));
    });

    test('a base with a <base href>-style directory resolves against it', () {
      final result = absolutizeUrls(
        '<img src="a.png">',
        'https://cdn.example.com/assets/',
      );
      expect(result, contains('src="https://cdn.example.com/assets/a.png"'));
    });
  });
}
