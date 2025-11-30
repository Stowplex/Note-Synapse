import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/filter.dart';

void main() {
  group('Filter Hierarchy', () {
    final now = DateTime.now();

    Filter createFilter({
      required String id,
      String? includeText,
      List<String> includeTags = const [],
    }) {
      return Filter(
        id: id,
        name: id,
        includeText: includeText,
        includeTags: includeTags,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('isChildOf basic logic', () {
      final parent = createFilter(id: 'parent', includeTags: ['A']);
      final child = createFilter(id: 'child', includeTags: ['A', 'B']);
      final unrelated = createFilter(id: 'unrelated', includeTags: ['B']);

      expect(child.isChildOf(parent), isTrue);
      expect(parent.isChildOf(child), isFalse);
      expect(unrelated.isChildOf(parent), isFalse);
    });

    test('isChildOf with text', () {
      final parent = createFilter(id: 'parent', includeText: 'foo');
      final child = createFilter(id: 'child', includeText: 'foobar');
      final unrelated = createFilter(id: 'unrelated', includeText: 'bar');

      expect(child.isChildOf(parent), isTrue);
      expect(parent.isChildOf(child), isFalse);
      expect(unrelated.isChildOf(parent), isFalse);
    });

    test('isChildOf with mixed criteria', () {
      final parent = createFilter(
        id: 'parent',
        includeText: 'foo',
        includeTags: ['A'],
      );
      final child = createFilter(
        id: 'child',
        includeText: 'foobar',
        includeTags: ['A', 'B'],
      );

      expect(child.isChildOf(parent), isTrue);
    });

    test('isChildOf empty parent', () {
      final parent = createFilter(id: 'parent'); // Empty criteria
      final child = createFilter(id: 'child', includeTags: ['A']);

      // Parent has no criteria, so it matches everything?
      // Logic:
      // other.includeText (null) -> check skipped.
      // other.includeTags (empty) -> check skipped.
      // Returns true.
      expect(child.isChildOf(parent), isTrue);
    });

    test('Hierarchy building logic', () {
      // A -> B -> C
      // A -> D
      final a = createFilter(id: 'A', includeTags: ['1']);
      final b = createFilter(id: 'B', includeTags: ['1', '2']);
      final c = createFilter(id: 'C', includeTags: ['1', '2', '3']);
      final d = createFilter(id: 'D', includeTags: ['1', '4']);

      final allFilters = [a, b, c, d];

      // 1. Find roots (FilterTabStrip logic)
      final roots = allFilters.where((f) {
        return !allFilters.any((other) => f != other && f.isChildOf(other));
      }).toList();

      expect(roots.length, 1);
      expect(roots.first.id, 'A');

      // 2. Find direct children of A (HierarchyDialog logic)
      // Scope = descendants of A
      final descendantsOfA = allFilters.where((f) => f.isChildOf(a)).toList();
      expect(descendantsOfA.map((f) => f.id), containsAll(['B', 'C', 'D']));
      expect(descendantsOfA.contains(a), isFalse);

      final directChildrenOfA = descendantsOfA.where((child) {
        return !descendantsOfA.any(
          (other) => child != other && child.isChildOf(other),
        );
      }).toList();

      // B is child of A. Is B child of any other descendant?
      // C is child of B. So C is child of a descendant.
      // D is child of A. D is not child of B or C.

      // So direct children should be B and D.
      // C should be filtered out because it is a child of B.

      expect(directChildrenOfA.map((f) => f.id), containsAll(['B', 'D']));
      expect(directChildrenOfA.map((f) => f.id), isNot(contains('C')));
    });

    test('Identical filters logic', () {
      final f1 = createFilter(id: '1', includeTags: ['A']);
      final f2 = createFilter(id: '2', includeTags: ['A']);

      final allFilters = [f1, f2];

      // f1 is child of f2? Yes.
      // f2 is child of f1? Yes.

      // FilterTabStrip logic with tie-breaker
      final roots = allFilters.where((f) {
        return !allFilters.any((other) {
          if (f == other) return false;
          if (!f.isChildOf(other)) return false;
          if (other.isChildOf(f)) {
            return f.id.compareTo(other.id) > 0;
          }
          return true;
        });
      }).toList();

      // f1 vs f2. f1.id < f2.id.
      // For f1: other=f2. f1 is child of f2. f2 is child of f1.
      // f1.id (1) < f2.id (2). compareTo returns < 0.
      // condition `f.id > other.id` is false.
      // returns false.
      // So f1 is NOT hidden by f2.

      // For f2: other=f1. f2 is child of f1. f1 is child of f2.
      // f2.id (2) > f1.id (1). compareTo returns > 0.
      // condition `f.id > other.id` is true.
      // returns true.
      // So f2 IS hidden by f1.

      expect(roots.length, 1);
      expect(roots.first.id, '1');
    });
  });
}
