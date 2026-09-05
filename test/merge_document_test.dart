import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/utils/merge_document.dart';

Note _note(String id, String content, {String title = ''}) => Note(
  id: id,
  title: title.isEmpty ? id : title,
  content: content,
  type: NoteType.note,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

const _a = '''# Alpha

First paragraph of A.

Second paragraph of A.

## Sub of Alpha

Under the sub heading.

# Beta

Beta body.
''';

const _b = '''Only paragraph of B.

- item one
- item two
''';

void main() {
  late MergeDocument doc;
  late MergeSource a;
  late MergeSource b;

  setUp(() {
    doc = MergeDocument();
    a = doc.addSource(_note('a', _a, title: 'Note A'));
    b = doc.addSource(_note('b', _b, title: 'Note B'));
  });

  List<String> texts() => doc.segments.map((s) => s.text).toList();

  group('sources', () {
    test('blank lines are not selectable and do not count', () {
      expect(a.blocks.length, greaterThan(a.selectableCount));
      expect(a.selectableCount, 7);
      expect(b.selectableCount, 2);
      for (final i in a.selectableIndices) {
        expect(a.blocks[i].content.trim(), isNotEmpty);
      }
    });

    test('adding the same note twice returns the existing source', () {
      expect(doc.addSource(_note('a', 'x')), same(a));
      expect(doc.sources.length, 2);
    });

    test('colours are monotonic even after a removal', () {
      expect(a.colorIndex, 0);
      expect(b.colorIndex, 1);
      doc.removeSource(a);
      final c = doc.addSource(_note('c', 'c'));
      expect(c.colorIndex, 2);
    });

    test('removing a source keeps its segments as plain text', () {
      final i = a.selectableIndices.first;
      doc.add(a, i);
      doc.add(b, b.selectableIndices.first);
      doc.removeSource(a);
      expect(doc.sources, [b]);
      expect(doc.segments.length, 2);
      expect(doc.segments.first.source, isNull);
      expect(doc.segments.first.text, '# Alpha');
      expect(doc.segments.last.source, same(b));
    });
  });

  group('add / remove', () {
    test('tick, untick, status', () {
      final i = a.selectableIndices.elementAt(1);
      expect(doc.statusOf(a, i), MergeBlockStatus.none);
      expect(doc.add(a, i), isTrue);
      expect(doc.statusOf(a, i), MergeBlockStatus.added);
      expect(doc.contains(a, i), isTrue);
      expect(doc.add(a, i), isFalse, reason: 'toggle, never duplicates');
      expect(doc.remove(a, i), 1);
      expect(doc.statusOf(a, i), MergeBlockStatus.none);
      expect(doc.isEmpty, isTrue);
    });

    test('unselectable index is refused', () {
      final blank = List.generate(
        a.blocks.length,
        (i) => i,
      ).firstWhere((i) => !a.isSelectable(i));
      expect(doc.add(a, blank), isFalse);
      expect(doc.add(a, 999), isFalse);
    });

    test('addAll / removeAll / addedCount', () {
      expect(doc.addAll(a), a.selectableCount);
      expect(doc.addedCount(a), a.selectableCount);
      expect(doc.addAll(a), 0);
      doc.add(b, b.selectableIndices.first);
      expect(doc.removeAll(a), a.selectableCount);
      expect(doc.segments.length, 1);
      expect(doc.segments.single.source, same(b));
    });

    test('flatten joins trimmed blocks with a blank line', () {
      doc.add(b, b.selectableIndices.first);
      doc.add(a, a.selectableIndices.first);
      expect(doc.flatten(), 'Only paragraph of B.\n\n# Alpha');
    });
  });

  group('sections', () {
    test('addSection takes the heading and its body up to the next peer', () {
      final alpha = a.selectableIndices.first;
      expect(MergeDocument.headingLevel(a.blocks[alpha].content), 1);
      final n = doc.addSection(a, alpha);
      expect(n, 5, reason: '# Alpha, 2 paragraphs, ## Sub, its paragraph');
      expect(texts().last, 'Under the sub heading.');
      expect(texts(), isNot(contains('# Beta')));
    });

    test('a level-2 section stops at the next level-1 heading', () {
      final sub = a.selectableIndices.firstWhere(
        (i) => a.blocks[i].content.startsWith('## '),
      );
      expect(doc.sectionIndices(a, sub).length, 2);
      expect(doc.addSection(a, sub), 2);
    });

    test('addSection on a paragraph adds just that block', () {
      final p = a.selectableIndices.elementAt(1);
      expect(doc.addSection(a, p), 1);
    });

    test('headingLevel', () {
      expect(MergeDocument.headingLevel('### x'), 3);
      expect(MergeDocument.headingLevel('####### x'), isNull);
      expect(MergeDocument.headingLevel('#x'), isNull);
      expect(MergeDocument.headingLevel('plain'), isNull);
    });
  });

  group('order', () {
    test('blocks land in tick order and positionOf reports it', () {
      final i = a.selectableIndices.toList();
      doc.add(a, i[2]);
      doc.add(a, i[0]);
      doc.add(a, i[1]);
      expect(texts(), ['Second paragraph of A.', '# Alpha', 'First paragraph of A.']);
      expect(doc.positionOf(a, i[2]), 1);
      expect(doc.positionOf(a, i[0]), 2);
      expect(doc.positionOf(a, i[1]), 3);
      expect(doc.positionOf(a, i[3]), isNull);
      doc.move(0, 2);
      expect(doc.positionOf(a, i[2]), 3);
    });

    test('move uses the already-adjusted target index', () {
      doc.addAll(a);
      final before = texts();
      doc.move(0, 2);
      expect(texts().sublist(0, 3), [before[1], before[2], before[0]]);
      doc.move(2, 0);
      expect(texts(), before);
    });

    test('move keeps the insertion marker on the same gap', () {
      doc.addAll(a); // 7 segments
      doc.insertionIndex = 3;
      doc.move(0, 5); // an item from above the gap goes below it
      expect(doc.insertionIndex, 2);
      doc.move(6, 0); // an item from below the gap goes above it
      expect(doc.insertionIndex, 3);
      doc.move(0, 1); // both sides above the gap: unchanged
      expect(doc.insertionIndex, 3);
    });

    test('removeAt clears the taken mark and shifts the marker', () {
      doc.addAll(a);
      doc.insertionIndex = 3;
      final second = doc.segments[1];
      doc.removeAt(1);
      expect(doc.statusOf(second.source!, second.sourceBlockIndex!),
          MergeBlockStatus.none);
      expect(doc.insertionIndex, 2);
    });

    test('insertion point inserts there and advances', () {
      doc.addAll(b); // 2 segments
      doc.insertionIndex = 1;
      final i0 = a.selectableIndices.elementAt(0);
      final i1 = a.selectableIndices.elementAt(1);
      doc.add(a, i0);
      doc.add(a, i1);
      expect(texts(), [
        'Only paragraph of B.',
        '# Alpha',
        'First paragraph of A.',
        '- item one\n- item two',
      ]);
      expect(doc.insertionIndex, 3);
    });

    test('insertion point at the end is explicit and sticks', () {
      doc.addAll(b);
      doc.insertionIndex = doc.segments.length;
      doc.add(a, a.selectableIndices.first);
      expect(texts().last, '# Alpha');
      expect(doc.insertionIndex, doc.segments.length);
    });
  });

  group('flatten', () {
    test('block text is never altered, and fused lists split back apart', () {
      final c = doc.addSource(
        _note('c', '- [ ] one\n- [x] two\n\n# Split\n\n- three\n  - nested\n'),
      );
      final lists = c.selectableIndices
          .where((i) => c.blocks[i].content.startsWith('- '))
          .toList();
      expect(lists.length, 2);
      doc.add(c, lists[0]);
      doc.add(c, lists[1]);
      expect(doc.flatten(), '- [ ] one\n- [x] two\n\n- three\n  - nested');

      // The parser reads that back as one list; provenance survives anyway.
      doc.replaceFromText(doc.flatten());
      expect(doc.segments.length, 2);
      expect(doc.segments[0].source, same(c));
      expect(doc.segments[0].sourceBlockIndex, lists[0]);
      expect(doc.segments[1].sourceBlockIndex, lists[1]);
      expect(doc.statusOf(c, lists[1]), MergeBlockStatus.added);
    });

    test('a fused list with foreign lines stays one plain segment', () {
      doc.add(b, b.selectableIndices.last); // "- item one\n- item two"
      doc.replaceFromText('- item one\n- item two\n- typed');
      expect(doc.segments.length, 1);
      expect(doc.segments.single.source, isNull);
    });

    test('tidy keeps an indented code block intact and normalises CRLF', () {
      expect(MergeDocument.tidy('\n\n    code\n    more\n  '), '    code\n    more');
      expect(MergeDocument.tidy('  \n# H\n'), '# H');
      expect(MergeDocument.tidy('\r\n\r\n# H\r\nx\r\n'), '# H\nx');
    });
  });

  group('replaceFromText', () {
    test('recovers provenance for untouched blocks', () {
      doc.add(a, a.selectableIndices.first);
      doc.add(b, b.selectableIndices.first);
      final text = '${doc.flatten()}\n\nTyped by hand.';
      doc.replaceFromText(text);
      expect(doc.segments.length, 3);
      expect(doc.segments[0].source, same(a));
      expect(doc.segments[1].source, same(b));
      expect(doc.segments[2].source, isNull);
      expect(doc.segments[2].text, 'Typed by hand.');
    });

    test('an edited block shows as edited in the source tab', () {
      final i = a.selectableIndices.elementAt(1);
      doc.add(a, i);
      doc.replaceFromText('First paragraph of A, but shorter.');
      expect(doc.contains(a, i), isFalse);
      expect(doc.statusOf(a, i), MergeBlockStatus.edited);
      expect(doc.segments.single.source, isNull);

      doc.forget(a, i);
      expect(doc.statusOf(a, i), MergeBlockStatus.none);
    });

    test('addCopy adds a second copy despite the taken mark', () {
      final i = a.selectableIndices.elementAt(1);
      doc.add(a, i);
      doc.replaceFromText('changed');
      expect(doc.addCopy(a, i), isTrue);
      expect(doc.statusOf(a, i), MergeBlockStatus.added);
      expect(doc.segments.length, 2);
    });

    test('a deleted block shows as edited too, and clears the marker', () {
      final i = a.selectableIndices.first;
      doc.add(a, i);
      doc.insertionIndex = 0;
      doc.replaceFromText('');
      expect(doc.isEmpty, isTrue);
      expect(doc.insertionIndex, isNull);
      expect(doc.statusOf(a, i), MergeBlockStatus.edited);
    });

    test('duplicate text across sources resolves to the first source', () {
      final c = doc.addSource(_note('c', 'Only paragraph of B.'));
      doc.replaceFromText('Only paragraph of B.');
      expect(doc.segments.single.source, same(b));
      expect(doc.contains(c, c.selectableIndices.first), isFalse);
    });
  });

  group('syncBlocks', () {
    test('identical blocks are a no-op, different ones re-derive', () {
      final i = a.selectableIndices.first;
      doc.add(a, i);
      doc.syncBlocks(a, List.of(a.blocks));
      expect(doc.contains(a, i), isTrue);

      // Renderer saw a different split: same text lands at a new index.
      final shuffled = [...a.blocks.skip(1), a.blocks.first];
      doc.syncBlocks(a, shuffled);
      final newIndex = a.blocks.indexWhere((b) => b.content == '# Alpha');
      expect(doc.contains(a, newIndex), isTrue);
      expect(doc.segments.single.text, '# Alpha');
    });
  });
}
