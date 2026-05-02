import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/chip_action.dart';
import 'package:note_synapse/services/chips_block_parser.dart';

void main() {
  final parser = ChipsBlockParser();

  group('happy paths', () {
    test('parses single chip with H2 label and body prompt', () {
      const md = '''Some AI reply text.

```chips
## explain transformer
You are a tutor in CS. I know basic calculus.
Explain transformers at my level.
```
''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(1));
      expect(r.chips[0].label, 'explain transformer');
      expect(r.chips[0].prompt, contains('You are a tutor'));
      expect(r.chips[0].prompt, contains('Explain transformers at my level.'));
      expect(r.strippedMarkdown, isNot(contains('```chips')));
      expect(r.strippedMarkdown, contains('Some AI reply text.'));
    });

    test('parses multiple chips in one block', () {
      const md = '''Reply.
```chips
## A
Prompt for A.
## B
Prompt for B.
```''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(2));
      expect(r.chips[0], const ChipAction(label: 'A', prompt: 'Prompt for A.'));
      expect(r.chips[1], const ChipAction(label: 'B', prompt: 'Prompt for B.'));
    });

    test('concatenates multiple chips blocks in document order', () {
      const md = '''Reply.
```chips
## A
Prompt A.
```
Mid.
```chips
## B
Prompt B.
```''';
      final r = parser.parse(md);
      expect(r.chips.map((c) => c.label).toList(), ['A', 'B']);
      expect(r.strippedMarkdown, isNot(contains('```chips')));
      expect(r.strippedMarkdown, contains('Mid.'));
    });
  });

  group('defensive filters', () {
    test('drops chips with empty label', () {
      const md = '''```chips
## valid
Valid prompt.
##
Body without label.
```''';
      final r = parser.parse(md);
      expect(r.chips.map((c) => c.label).toList(), ['valid']);
    });

    test('drops chips with empty prompt body (label only)', () {
      const md = '''```chips
## label without body
## next label
Has body.
```''';
      final r = parser.parse(md);
      expect(r.chips.map((c) => c.label).toList(), ['next label']);
    });

    test('drops chips with whitespace-only prompt body', () {
      const md = '''```chips
## label A


## label B
Real body.
```''';
      final r = parser.parse(md);
      expect(r.chips.map((c) => c.label).toList(), ['label B']);
    });
  });

  group('non-matching cases', () {
    test('returns empty chips and original markdown when no chips block present', () {
      const md = 'Just an AI reply with no chip block.';
      final r = parser.parse(md);
      expect(r.chips, isEmpty);
      expect(r.strippedMarkdown, md);
    });

    test('does not split on # (single hash) inside body — only ##', () {
      const md = '''```chips
## label
Body with # single hash heading should stay in prompt.
Also #hashtag should be fine.
```''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(1));
      expect(r.chips[0].prompt, contains('# single hash'));
      expect(r.chips[0].prompt, contains('#hashtag'));
    });

    test('handles malformed fence (missing closing) — drops the block, leaves markdown intact for debug', () {
      const md = '''Reply.
```chips
## A
Prompt A unterminated...''';
      final r = parser.parse(md);
      expect(r.chips, isEmpty);
      expect(r.strippedMarkdown, contains('```chips'),
          reason: 'Unterminated block stays in markdown for debug visibility');
    });

    test('does not match a fenced block with a different language', () {
      const md = '''```dart
## still a heading
not chips
```''';
      final r = parser.parse(md);
      expect(r.chips, isEmpty);
      // Markdown is unchanged.
      expect(r.strippedMarkdown, md);
    });
  });

  group('edge cases', () {
    test('trims label whitespace', () {
      const md = '''```chips
##    label with leading and trailing spaces
Body.
```''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(1));
      expect(r.chips[0].label, 'label with leading and trailing spaces');
    });

    test('preserves multi-line prompt body with internal blank lines', () {
      const md = '''```chips
## L
para one
para one continued

para two
```''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(1));
      expect(r.chips[0].prompt, contains('para one continued'));
      expect(r.chips[0].prompt, contains('para two'));
    });

    test('strip collapses 3+ consecutive blank lines left by the strip', () {
      const md = '''Before.



```chips
## L
Body.
```



After.''';
      final r = parser.parse(md);
      expect(r.strippedMarkdown, isNot(contains('\n\n\n\n')));
      expect(r.strippedMarkdown, contains('Before.'));
      expect(r.strippedMarkdown, contains('After.'));
    });
  });
}
