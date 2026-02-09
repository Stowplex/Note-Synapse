import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  group('CustomATagMd', () {
    final atag = CustomATagMd();
    final regex = atag.exp;

    test('matches standard link', () {
      const input = '[hello](https://www.google.com)';
      final match = regex.firstMatch(input);
      expect(match, isNotNull);
      expect(match!.group(0), equals('[hello](https://www.google.com)'));
    });

    test('matches link with title (optional title)', () {
      const input = '[hello](https://www.google.com "google")';
      final match = regex.firstMatch(input);
      expect(match, isNotNull, reason: 'Should match link with title');
      expect(
        match!.group(0),
        equals('[hello](https://www.google.com "google")'),
      );
    });

    test('matches link with nested parentheses', () {
      const input = '[text](url(nested))';
      final match = regex.firstMatch(input);
      expect(match, isNotNull);
      expect(match!.group(0), equals('[text](url(nested))'));
    });

    test('matches link with double nested parentheses', () {
      const input = '[text](url(a(b)c))';
      final match = regex.firstMatch(input);
      expect(match, isNotNull);
      expect(match!.group(0), equals('[text](url(a(b)c))'));
    });

    test('matches user reported failure case', () {
      const input =
          'Three-sector [circular flow of income](https://en.wikipedia.org/wiki/Circular_flow_of_income "Circular flow of income") diagram';
      final match = regex.firstMatch(input);
      expect(match, isNotNull, reason: 'Should match user reported link');
      expect(
        match!.group(0),
        equals(
          '[circular flow of income](https://en.wikipedia.org/wiki/Circular_flow_of_income "Circular flow of income")',
        ),
      );
    });

    test('matches linked image (nested brackets)', () {
      const input =
          '[![](https://example.com/image.jpg)](https://example.com/link)';
      final match = regex.firstMatch(input);
      expect(match, isNotNull);
      expect(match!.group(0), equals(input));
    });

    test(
      'does not strictly match multiple links as one greedy block (if spaces exist)',
      () {
        // Logic check: if we have multiple links, it shouldn't be greedy across them
        const input = '[link1](url1) and [link2](url2)';
        final matches = regex.allMatches(input);
        expect(matches.length, equals(2));
        expect(matches.first.group(0), equals('[link1](url1)'));
        expect(matches.last.group(0), equals('[link2](url2)'));
      },
    );
    test('does NOT match standard image syntax with base64', () {
      const input =
          '![img](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAAHElEQVQI12P4//8/w38GIAXDIBKE0DHxgljNBAAO9TXL0Y4OHwAAAABJRU5E5rkJggg==)';
      final match = regex.firstMatch(input);
      expect(match, isNull);
    });
  });
}
