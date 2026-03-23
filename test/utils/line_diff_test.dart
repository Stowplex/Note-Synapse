import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/line_diff.dart';

void main() {
  group('computeLineDiff', () {
    test('identical inputs produce all unchanged lines', () {
      final diff = computeLineDiff('hello\nworld', 'hello\nworld');
      expect(diff.length, 2);
      expect(diff.every((l) => l.type == DiffLineType.unchanged), isTrue);
    });

    test('completely different inputs', () {
      final diff = computeLineDiff('aaa\nbbb', 'ccc\nddd');
      final removed = diff.where((l) => l.type == DiffLineType.removed);
      final added = diff.where((l) => l.type == DiffLineType.added);
      expect(removed.length, 2);
      expect(added.length, 2);
    });

    test('empty original produces all added lines', () {
      final diff = computeLineDiff('', 'new line');
      expect(diff.any((l) => l.type == DiffLineType.added && l.text == 'new line'), isTrue);
    });

    test('empty transformed produces all removed lines', () {
      final diff = computeLineDiff('old line', '');
      expect(diff.any((l) => l.type == DiffLineType.removed && l.text == 'old line'), isTrue);
    });

    test('interleaved changes', () {
      final diff = computeLineDiff(
        'line1\nline2\nline3',
        'line1\nmodified\nline3',
      );
      expect(diff.where((l) => l.type == DiffLineType.unchanged).length, 2);
      expect(diff.any((l) => l.type == DiffLineType.removed && l.text == 'line2'), isTrue);
      expect(diff.any((l) => l.type == DiffLineType.added && l.text == 'modified'), isTrue);
    });

    test('added lines at end', () {
      final diff = computeLineDiff('line1', 'line1\nline2');
      expect(diff.where((l) => l.type == DiffLineType.unchanged).length, 1);
      expect(diff.where((l) => l.type == DiffLineType.added).length, 1);
    });
  });
}
