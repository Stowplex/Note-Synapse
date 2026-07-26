import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/markdown_block_tracker.dart';

void main() {
  _offsetInvariantTests();
  late MarkdownBlockTracker tracker;

  setUp(() {
    tracker = MarkdownBlockTracker();
  });

  group('MarkdownBlockTracker', () {
    group('parseBlocks', () {
      test('parses code blocks', () {
        const content = '''
Some text

```dart
void main() {}
```

More text
''';
        final blocks = tracker.parseBlocks(content);
        final codeBlocks = blocks
            .where((b) => b.type == MarkdownBlockType.codeBlock)
            .toList();

        expect(codeBlocks.length, 1);
        expect(codeBlocks[0].content, contains('void main()'));
      });

      test('parses chips fenced blocks as code blocks', () {
        const content = '''
Before

```chips
## Explain
Explain this note.
```

After
''';
        final blocks = tracker.parseBlocks(content);
        final codeBlocks = blocks
            .where((b) => b.type == MarkdownBlockType.codeBlock)
            .toList();

        expect(codeBlocks.length, 1);
        expect(codeBlocks[0].content, contains('```chips'));
        expect(codeBlocks[0].content, contains('Explain this note.'));
        expect(blocks.where((b) => b.type == MarkdownBlockType.link), isEmpty);
      });

      test('parses headings', () {
        const content = '''
# Heading 1
## Heading 2
### Heading 3
''';
        final blocks = tracker.parseBlocks(content);
        final headings = blocks
            .where((b) => b.type == MarkdownBlockType.heading)
            .toList();

        expect(headings.length, 3);
        expect(headings[0].content, '# Heading 1');
        expect(headings[1].content, '## Heading 2');
        expect(headings[2].content, '### Heading 3');
      });

      test('parses a cross-line link as a single link block', () {
        const content = '''
Intro paragraph.

[

### Leaders vs Managers: Is There a Real Difference?

](https://davidburkus.com/2024/11/leaders-vs-managers/)

Trailing paragraph.
''';
        final blocks = tracker.parseBlocks(content);
        final links = blocks
            .where((b) => b.type == MarkdownBlockType.link)
            .toList();

        expect(links.length, 1);
        expect(links[0].content, contains('### Leaders vs Managers'));
        expect(
          links[0].content,
          contains('](https://davidburkus.com/2024/11/leaders-vs-managers/)'),
        );
        // Offsets must bracket the original substring exactly.
        final span = content.substring(
          links[0].startOffset,
          links[0].endOffset,
        );
        expect(span, links[0].content);
      });

      test('does not promote single-line links to a link block', () {
        const content = 'See [the docs](https://example.com) for details.';
        final blocks = tracker.parseBlocks(content);
        // Should still be parsed as a single paragraph, no `link` block.
        expect(blocks.where((b) => b.type == MarkdownBlockType.link), isEmpty);
      });

      test('does not promote image links spanning lines', () {
        const content = '''
![alt
text](https://example.com/img.png)
''';
        final blocks = tracker.parseBlocks(content);
        expect(blocks.where((b) => b.type == MarkdownBlockType.link), isEmpty);
      });

      test('bare `[` line with no closer falls through to paragraph', () {
        const content = '''
[

Some unrelated text with no closing link.

More text.
''';
        final blocks = tracker.parseBlocks(content);
        expect(blocks.where((b) => b.type == MarkdownBlockType.link), isEmpty);
      });

      test('replaceBlock round-trips on a cross-line link block', () {
        const content =
            'Header\n\n[\n### Title\n](https://example.com)\n\nFooter';
        final blocks = tracker.parseBlocks(content);
        final link = blocks.firstWhere((b) => b.type == MarkdownBlockType.link);
        final updated = tracker.replaceBlock(
          content,
          link,
          '[Renamed](https://example.com)',
        );
        expect(updated, 'Header\n\n[Renamed](https://example.com)\n\nFooter');
      });

      test('parses lists', () {
        const content = '''
- Item 1
- Item 2

1. Ordered 1
2. Ordered 2
''';
        final blocks = tracker.parseBlocks(content);
        final ul = blocks
            .where((b) => b.type == MarkdownBlockType.unorderedList)
            .toList();
        final ol = blocks
            .where((b) => b.type == MarkdownBlockType.orderedList)
            .toList();

        expect(ul.length, 1); // One list block
        expect(ul[0].content, contains('Item 1'));
        expect(ol.length, 1); // One list block
        expect(ol[0].content, contains('Ordered 1'));
      });
    });

    group('replaceBlock', () {
      test('replaces block content correctly using offsets', () {
        const content = '''
# Hello

Some text

# World
''';
        final blocks = tracker.parseBlocks(content);
        final firstHeading = blocks.firstWhere(
          (b) =>
              b.type == MarkdownBlockType.heading &&
              b.content.contains('Hello'),
        );

        final result = tracker.replaceBlock(content, firstHeading, '# Goodbye');

        expect(result, contains('# Goodbye'));
        expect(result, isNot(contains('# Hello')));
        expect(result, contains('# World'));
      });

      test('handling duplicate content correctly via unique block objects', () {
        const content = '''
# Hello
text
# Hello
more text
''';
        final blocks = tracker.parseBlocks(content);
        final headings = blocks
            .where((b) => b.type == MarkdownBlockType.heading)
            .toList();

        expect(headings.length, 2);
        // Replace second occurrence
        final secondHeading = headings[1];

        final result = tracker.replaceBlock(
          content,
          secondHeading,
          '# Changed',
        );

        expect(result.startsWith('# Hello'), isTrue); // First one untouched
        expect(result, contains('# Changed'));
      });
    });

    group('deleteBlock', () {
      test('removes block content', () {
        final content =
            '''
# First

# Second

# Third
'''
                .replaceAll(RegExp(r'^\s+', multiLine: true), '');
        final blocks = tracker.parseBlocks(content);
        for (var b in blocks) print('BLOCK: ${b.type} [${b.content}]');
        final secondHeading = blocks.firstWhere(
          (b) =>
              b.type == MarkdownBlockType.heading &&
              b.content.contains('# Second'),
        );

        final result = tracker.deleteBlock(content, secondHeading);

        expect(result, contains('# First'));
        expect(result, isNot(contains('# Second')));
        expect(result, contains('# Third'));
      });
    });
    group('range operations', () {
      test(
        'deleteBlockRange removes multiple blocks and consumes structural newline',
        () {
          const content = 'Block 1\n\nBlock 2\n\nBlock 3';
          final blocks = tracker.parseBlocks(content);
          final visibleBlocks = blocks
              .where((b) => b.content.trim().isNotEmpty)
              .toList();

          expect(visibleBlocks.length, 3);

          // Delete Block 1 and Block 2
          final toDelete = visibleBlocks.sublist(0, 2);
          final result = tracker.deleteBlockRange(content, toDelete);

          // B1 start: 0.
          // B2 end: 16.
          // deleteBlock consumes one trailing newline (at 16).
          // end -> 17.
          // content[17] is \n. content[18] starts B3.
          // Result: "\nBlock 3".

          expect(result, '\nBlock 3');
        },
      );

      test(
        'replaceBlockRange replaces multiple blocks with single content',
        () {
          const content = 'Block 1\n\nBlock 2\n\nBlock 3';
          final blocks = tracker.parseBlocks(content);
          final visibleBlocks = blocks
              .where((b) => b.content.trim().isNotEmpty)
              .toList();

          // Replace Block 1 and Block 2 with "New Block"
          final toReplace = visibleBlocks.sublist(0, 2);
          final result = tracker.replaceBlockRange(
            content,
            toReplace,
            'New Block',
          );

          // Range 0 to 16.
          // substring(16) starts at 16 (\n).
          // Result: "New Block\n\nBlock 3"

          expect(result, 'New Block\n\nBlock 3');
        },
      );

      test(
        'deleteBlockRange handles non-contiguous blocks by deleting the whole range',
        () {
          const content = '# 1\n# 2\n# 3\n# 4';
          final blocks = tracker.parseBlocks(content);
          // Headers are contiguous lines here, no empty blocks between them in source
          // # 1 (0-3). \n at 3.
          // # 2 (4-7).

          // Delete 1 and 3. Range is start(1) to end(3). Includes 2.
          final toDelete = [blocks[0], blocks[2]];

          final result = tracker.deleteBlockRange(content, toDelete);

          // Block 3 end at 11. \n at 11.
          // Consume \n -> 12.
          // # 4 starts at 12.
          // content[12..] is "# 4".

          expect(result, '# 4');
        },
      );
    });
  });
}

void _offsetInvariantTests() {
  group('offsetsMatchContent', () {
    final tracker = MarkdownBlockTracker();

    test('accepts blocks parsed from the same content', () {
      const content = 'Intro.\n\n```mermaid\ngraph TD\n```\n\nOutro.';
      final blocks = tracker.parseBlocks(content);
      expect(MarkdownBlockTracker.offsetsMatchContent(content, blocks), isTrue);
    });

    test('rejects offsets parsed from chips-stripped content', () {
      // This is the real hazard: block offsets come from the chips-STRIPPED
      // markdown while callers splice into the raw note content, so every
      // offset after a ```chips fence is shifted.
      const raw =
          'Alpha\n\n```chips\n## Ask more\nTell me more\n```\n\nBeta\n\nGamma';
      const stripped = 'Alpha\n\nBeta\n\nGamma';
      final blocks = tracker.parseBlocks(stripped);
      expect(
        MarkdownBlockTracker.offsetsMatchContent(raw, blocks),
        isFalse,
        reason: 'a shifted window must never be handed to a plugin to rewrite',
      );
    });

    test('rejects a selection that a blank-line block would make vacuous', () {
      // The tracker emits a zero-width block with EMPTY content per blank line,
      // so contains/startsWith/endsWith checks all pass on shifted offsets.
      const stripped = 'Alpha\n\nBeta\n\nGamma';
      final blocks = tracker.parseBlocks(stripped);
      final empties = blocks.where((b) => b.content.isEmpty).toList();
      expect(empties, isNotEmpty, reason: 'blank lines produce empty blocks');
      // A shifted content still "contains"/"startsWith" an empty block's text.
      const shifted = 'XXXXXXXXXX$stripped';
      expect(
        MarkdownBlockTracker.offsetsMatchContent(shifted, blocks),
        isFalse,
      );
    });

    test('rejects out-of-range offsets after the note shrank', () {
      const content = 'Intro.\n\nBeta\n\nGamma';
      final blocks = tracker.parseBlocks(content);
      expect(
        MarkdownBlockTracker.offsetsMatchContent('short', blocks),
        isFalse,
      );
    });
  });
}
