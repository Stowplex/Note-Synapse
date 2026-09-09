import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';

/// `isSpace` and `isPinned` are *role* flags: they say how a filter is
/// presented, not what it selects. `Filter.isChildOf` (and the
/// `_isContentEqual` guard inside it) must therefore ignore both, or flagging
/// a filter as a Space would silently move it in the filter hierarchy that
/// M3's space chrome is built on.
///
/// These tests drive `_isContentEqual` through `isChildOf`, which is the only
/// caller and the only observable behaviour.
Filter buildFilter({
  required String id,
  String name = 'Filter',
  String? includeText,
  List<String> includeTags = const [],
  List<String> excludeTags = const [],
  List<NoteType> noteTypes = const [NoteType.note, NoteType.task],
  bool includeArchived = false,
  bool isPinned = false,
  bool isSpace = false,
}) {
  final now = DateTime(2026, 9, 8);
  return Filter(
    id: id,
    name: name,
    includeText: includeText,
    includeTags: includeTags,
    excludeTags: excludeTags,
    noteTypes: noteTypes,
    includeArchived: includeArchived,
    isPinned: isPinned,
    isSpace: isSpace,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('role flags never create a hierarchy of their own', () {
    test('two filters differing only in isSpace are not parent or child', () {
      final plain = buildFilter(id: 'a', includeTags: const ['work']);
      final space = buildFilter(
        id: 'b',
        includeTags: const ['work'],
        isSpace: true,
      );

      expect(space.isChildOf(plain), isFalse);
      expect(plain.isChildOf(space), isFalse);
    });

    test('two filters differing only in isPinned are not parent or child', () {
      final plain = buildFilter(id: 'a', includeTags: const ['work']);
      final pinned = buildFilter(
        id: 'b',
        includeTags: const ['work'],
        isPinned: true,
      );

      expect(pinned.isChildOf(plain), isFalse);
      expect(plain.isChildOf(pinned), isFalse);
    });

    test('differing in both role flags at once is still no hierarchy', () {
      final neither = buildFilter(id: 'a', includeTags: const ['work']);
      final both = buildFilter(
        id: 'b',
        includeTags: const ['work'],
        isPinned: true,
        isSpace: true,
      );

      expect(both.isChildOf(neither), isFalse);
      expect(neither.isChildOf(both), isFalse);
    });

    test('identical criteria are not a hierarchy even with both flags set', () {
      final one = buildFilter(
        id: 'a',
        includeText: 'draft',
        includeTags: const ['work'],
        excludeTags: const ['done'],
        isPinned: true,
        isSpace: true,
      );
      final two = buildFilter(
        id: 'b',
        includeText: 'draft',
        includeTags: const ['work'],
        excludeTags: const ['done'],
        isPinned: true,
        isSpace: true,
      );

      expect(one.isChildOf(two), isFalse);
      expect(two.isChildOf(one), isFalse);
    });
  });

  group('a genuine hierarchy survives every role-flag combination', () {
    // `child` narrows `parent`: same text criterion, a strictly larger tag set.
    Filter parentWith({bool isPinned = false, bool isSpace = false}) =>
        buildFilter(
          id: 'parent',
          name: 'Thesis',
          includeText: 'draft',
          includeTags: const ['thesis'],
          isPinned: isPinned,
          isSpace: isSpace,
        );

    Filter childWith({bool isPinned = false, bool isSpace = false}) =>
        buildFilter(
          id: 'child',
          name: 'Thesis 2026',
          includeText: 'draft chapter',
          includeTags: const ['thesis', '2026'],
          isPinned: isPinned,
          isSpace: isSpace,
        );

    test('the baseline pair really is a child and not the reverse', () {
      expect(childWith().isChildOf(parentWith()), isTrue);
      expect(parentWith().isChildOf(childWith()), isFalse);
    });

    test('flipping isSpace on either side changes nothing', () {
      for (final parentIsSpace in [false, true]) {
        for (final childIsSpace in [false, true]) {
          final parent = parentWith(isSpace: parentIsSpace);
          final child = childWith(isSpace: childIsSpace);
          final label = 'parent=$parentIsSpace child=$childIsSpace';

          expect(child.isChildOf(parent), isTrue, reason: 'isSpace $label');
          expect(parent.isChildOf(child), isFalse, reason: 'isSpace $label');
        }
      }
    });

    test('flipping isPinned on either side changes nothing', () {
      for (final parentIsPinned in [false, true]) {
        for (final childIsPinned in [false, true]) {
          final parent = parentWith(isPinned: parentIsPinned);
          final child = childWith(isPinned: childIsPinned);
          final label = 'parent=$parentIsPinned child=$childIsPinned';

          expect(child.isChildOf(parent), isTrue, reason: 'isPinned $label');
          expect(parent.isChildOf(child), isFalse, reason: 'isPinned $label');
        }
      }
    });

    test('copyWith(isSpace:) leaves the hierarchy exactly as it was', () {
      final parent = parentWith();
      final child = childWith();
      expect(child.isChildOf(parent), isTrue);

      // Turning the parent into a Space — what M3's "Activate as space" does —
      // must not detach its children.
      expect(child.isChildOf(parent.copyWith(isSpace: true)), isTrue);
      expect(child.copyWith(isSpace: true).isChildOf(parent), isTrue);
      expect(
        child.copyWith(isSpace: true).isChildOf(parent.copyWith(isSpace: true)),
        isTrue,
      );
    });

    test('a real criteria difference is still respected', () {
      // Sanity check that the tests above are not passing vacuously: a filter
      // that drops the parent's tag is not a child, whatever its role flags.
      final unrelated = buildFilter(
        id: 'other',
        includeText: 'draft chapter',
        includeTags: const ['2026'],
        isSpace: true,
      );
      expect(unrelated.isChildOf(parentWith()), isFalse);
      expect(unrelated.isChildOf(parentWith(isSpace: true)), isFalse);
    });
  });
}
