import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/web_content_processor.dart';

void main() {
  group('WebContentProcessor', () {
    test('preserves multiline code blocks from pre tags', () {
      const html = '''
        <html>
          <body>
            <pre class="language-js">const a = 1;
const b = 2;
console.log(a + b);</pre>
          </body>
        </html>
      ''';

      final markdown = WebContentProcessor.processHtml((
        html: html,
        baseUrl: 'https://example.com/post',
      ));

      expect(
        markdown,
        contains('''```js
const a = 1;
const b = 2;
console.log(a + b);
```'''),
      );
    });

    test('preserves multiline code blocks from nested code tags', () {
      const html = '''
        <html>
          <body>
            <pre><code class="language-python">def main():
    value = 42
    print(value)</code></pre>
          </body>
        </html>
      ''';

      final markdown = WebContentProcessor.processHtml((
        html: html,
        baseUrl: null,
      ));

      expect(
        markdown,
        contains('''```python
def main():
    value = 42
    print(value)
```'''),
      );
    });

    test('resolves relative image URLs so they can be downloaded', () {
      const html = '''
        <html>
          <body>
            <p>Intro</p>
            <img src="/media/hero.png" alt="Hero" />
            <img src="../img/a.jpg" alt="A" />
          </body>
        </html>
      ''';

      final markdown = WebContentProcessor.processHtml((
        html: html,
        baseUrl: 'https://example.com/docs/guide/index.html',
      ));

      expect(markdown, contains('https://example.com/media/hero.png'));
      expect(markdown, contains('https://example.com/docs/img/a.jpg'));

      // End-to-end: the download pipeline only sees http(s) URLs, so this is
      // the assertion that resolving actually unblocks image fetching.
      final images = WebContentProcessor.extractImages(markdown);
      expect(
        images.map((i) => i.url),
        containsAll(<String>[
          'https://example.com/media/hero.png',
          'https://example.com/docs/img/a.jpg',
        ]),
      );
    });

    test('leaves relative image URLs alone when no base URL is known', () {
      const html = '<html><body><img src="/media/hero.png" /></body></html>';

      final markdown = WebContentProcessor.processHtml((
        html: html,
        baseUrl: null,
      ));

      expect(markdown, contains('/media/hero.png'));
      expect(markdown, isNot(contains('https://')));
    });

    test('resolves relative links in anchors but keeps in-page anchors', () {
      const html = '''
        <html>
          <body>
            <a href="/docs/intro">Intro</a>
            <a href="#install">Install</a>
          </body>
        </html>
      ''';

      final markdown = WebContentProcessor.processHtml((
        html: html,
        baseUrl: 'https://example.com/docs/guide/index.html',
      ));

      expect(markdown, contains('(https://example.com/docs/intro)'));
      expect(markdown, contains('(#install)'));
    });
  });
}
