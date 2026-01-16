import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/markdown_block_tracker.dart';

void main() {
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
  });
}
