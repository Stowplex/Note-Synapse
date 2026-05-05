import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  group('flattenCrossLineLinks', () {
    test('leaves single-line links untouched', () {
      const input = 'See [docs](https://example.com) please.';
      expect(flattenCrossLineLinks(input), input);
    });

    test('leaves content without any newlines untouched', () {
      const input = 'plain text';
      expect(flattenCrossLineLinks(input), input);
    });

    test('flattens a link whose text spans blank lines', () {
      const input = '[\n\n### Leaders vs Managers: Is There a Real Difference?\n\n](https://davidburkus.com/2024/11/leaders-vs-managers/)';
      expect(
        flattenCrossLineLinks(input),
        '[Leaders vs Managers: Is There a Real Difference?](https://davidburkus.com/2024/11/leaders-vs-managers/)',
      );
    });

    test('strips a leading ATX heading marker from the link text', () {
      const input = '[\n# A Title\n](https://example.com)';
      expect(
        flattenCrossLineLinks(input),
        '[A Title](https://example.com)',
      );
    });

    test('does not touch image links', () {
      const input = '![alt\ntext](https://example.com/x.png)';
      expect(flattenCrossLineLinks(input), input);
    });

    test('preserves surrounding content around the rewrite', () {
      const input = 'Before\n\n[\n### Title\n](https://example.com)\n\nAfter';
      expect(
        flattenCrossLineLinks(input),
        'Before\n\n[Title](https://example.com)\n\nAfter',
      );
    });

    test('is idempotent', () {
      const input = '[\n### Title\n](https://example.com)';
      final once = flattenCrossLineLinks(input);
      final twice = flattenCrossLineLinks(once);
      expect(twice, once);
    });

    test('handles balanced parentheses inside the URL', () {
      const input = '[\nFoo\n](https://en.wikipedia.org/wiki/Foo_(bar))';
      expect(
        flattenCrossLineLinks(input),
        '[Foo](https://en.wikipedia.org/wiki/Foo_(bar))',
      );
    });
  });
}
