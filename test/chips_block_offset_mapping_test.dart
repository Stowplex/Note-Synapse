import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/chips_block_parser.dart';
import 'package:note_synapse/utils/markdown_block_tracker.dart';

/// Blocks are parsed from the chips-STRIPPED markdown but every edit splices
/// into the RAW note content. Before the offsets were translated, any note
/// containing a ```chips fence had every later block shifted, so editing,
/// deleting, AI-editing or even ticking a checkbox rewrote the wrong
/// characters.
void main() {
  final parser = ChipsBlockParser();
  final tracker = MarkdownBlockTracker();

  /// Reproduces what BlockMarkdownBody does: parse the stripped markdown, then
  /// express the offsets in the original content's coordinates.
  List<MarkdownBlock> blocksInRawCoordinates(String raw) {
    final parsed = parser.parse(raw);
    final blocks = tracker.parseBlocks(parsed.strippedMarkdown);
    if (parsed.isUnchanged) return blocks;
    return blocks
        .map(
          (b) => MarkdownBlock(
            type: b.type,
            content: b.content,
            startOffset: parsed.rawOffsetFor(b.startOffset),
            endOffset: parsed.rawOffsetFor(b.endOffset),
          ),
        )
        .toList();
  }

  group('chips offset mapping', () {
    test('offsets are identical when there is no chips block', () {
      const raw = 'Alpha\n\nBeta\n\nGamma';
      final parsed = parser.parse(raw);
      expect(parsed.isUnchanged, isTrue);
      expect(parsed.rawOffsetFor(7), 7);
    });

    test('every block still slices its own text out of the RAW content', () {
      const raw =
          'Alpha\n\n'
          '```chips\n'
          '## Ask more\n'
          'Tell me more\n'
          '```\n\n'
          'Beta\n\n'
          'Gamma';

      final blocks = blocksInRawCoordinates(raw);

      expect(
        MarkdownBlockTracker.offsetsMatchContent(raw, blocks),
        isTrue,
        reason: 'this is the invariant every splice path depends on',
      );
    });

    test('editing a block after a chips fence rewrites the right text', () {
      const raw =
          'Alpha\n\n'
          '```chips\n'
          '## Ask more\n'
          'Tell me more\n'
          '```\n\n'
          'Beta\n\n'
          'Gamma';

      final blocks = blocksInRawCoordinates(raw);
      final beta = blocks.firstWhere((b) => b.content == 'Beta');

      final edited = tracker.replaceBlock(raw, beta, 'BETA EDITED');

      expect(edited, contains('BETA EDITED'));
      expect(edited, isNot(contains('Beta')));
      // The chips block and its neighbours must be untouched.
      expect(edited, contains('```chips\n## Ask more\nTell me more\n```'));
      expect(edited, startsWith('Alpha'));
      expect(edited, endsWith('Gamma'));
    });

    test('deleting a block after a chips fence deletes the right text', () {
      const raw = 'Alpha\n\n```chips\n## L\nP\n```\n\nBeta\n\nGamma';

      final blocks = blocksInRawCoordinates(raw);
      final beta = blocks.firstWhere((b) => b.content == 'Beta');

      final deleted = tracker.deleteBlock(raw, beta);

      expect(deleted, isNot(contains('Beta')));
      expect(deleted, contains('```chips\n## L\nP\n```'));
      expect(deleted, contains('Alpha'));
      expect(deleted, contains('Gamma'));
    });

    test('a checkbox after a chips fence toggles the right line', () {
      const raw = 'Alpha\n\n```chips\n## L\nP\n```\n\n- [ ] buy milk\n\nGamma';

      final blocks = blocksInRawCoordinates(raw);
      final task = blocks.firstWhere((b) => b.content.contains('buy milk'));

      final toggled = tracker.replaceBlock(raw, task, '- [x] buy milk');

      expect(toggled, contains('- [x] buy milk'));
      expect(toggled, isNot(contains('- [ ] buy milk')));
      expect(toggled, contains('```chips\n## L\nP\n```'));
    });

    test('handles a chips block at the very start of the note', () {
      const raw = '```chips\n## L\nP\n```\n\nBeta\n\nGamma';

      final blocks = blocksInRawCoordinates(raw);
      expect(MarkdownBlockTracker.offsetsMatchContent(raw, blocks), isTrue);

      final gamma = blocks.firstWhere((b) => b.content == 'Gamma');
      final edited = tracker.replaceBlock(raw, gamma, 'GAMMA!');
      expect(edited, contains('GAMMA!'));
      expect(edited, contains('```chips\n## L\nP\n```'));
      expect(edited, contains('Beta'));
    });

    test('handles several chips blocks in one note', () {
      const raw =
          'One\n\n```chips\n## A\na\n```\n\n'
          'Two\n\n```chips\n## B\nb\n```\n\n'
          'Three';

      final blocks = blocksInRawCoordinates(raw);
      expect(MarkdownBlockTracker.offsetsMatchContent(raw, blocks), isTrue);

      final three = blocks.firstWhere((b) => b.content == 'Three');
      final edited = tracker.replaceBlock(raw, three, 'THREE!');
      expect(edited, contains('THREE!'));
      expect(edited, contains('## A'));
      expect(edited, contains('## B'));
      expect(edited, contains('Two'));
    });

    test('an unterminated fence is left in place and needs no mapping', () {
      // Malformed blocks stay visible, so nothing is stripped.
      const raw = 'Alpha\n\n```chips\n## L\nP\n\nBeta';
      final parsed = parser.parse(raw);
      expect(parsed.isUnchanged, isTrue);

      final blocks = blocksInRawCoordinates(raw);
      expect(MarkdownBlockTracker.offsetsMatchContent(raw, blocks), isTrue);
    });
  });
}
