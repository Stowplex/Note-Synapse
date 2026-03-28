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

      final markdown = WebContentProcessor.processHtml(html);

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

      final markdown = WebContentProcessor.processHtml(html);

      expect(
        markdown,
        contains('''```python
def main():
    value = 42
    print(value)
```'''),
      );
    });
  });
}
