// Bounded exhaustive model-checking: for small, fixed configurations,
// enumerate every possible arrival order (not just random samples) and
// assert protocol invariants hold under all of them — the complement to
// the randomized suite (randomized_test.dart), covering the exact
// adversarial orderings a random run might miss by chance.

import 'package:flutter_test/flutter_test.dart';

import 'gc.dart';
import 'model.dart';
import 'replica.dart';
import 'simulator.dart';
import 'tag_ops.dart';

/// All permutations of a list (n! — only used for small n in this file).
Iterable<List<T>> permutations<T>(List<T> items) sync* {
  if (items.isEmpty) {
    yield [];
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = [...items.sublist(0, i), ...items.sublist(i + 1)];
    for (final perm in permutations(rest)) {
      yield [items[i], ...perm];
    }
  }
}

/// All ways to interleave two sequences while preserving each sequence's
/// internal order (the "shuffle"/"riffle" of two ordered lists) — models
/// every valid no-gap-skipping delivery order of two independent authors'
/// operation streams.
Iterable<List<T>> interleavings<T>(List<T> a, List<T> b) sync* {
  if (a.isEmpty) {
    yield List.of(b);
    return;
  }
  if (b.isEmpty) {
    yield List.of(a);
    return;
  }
  for (final rest in interleavings(a.sublist(1), b)) {
    yield [a.first, ...rest];
  }
  for (final rest in interleavings(a, b.sublist(1))) {
    yield [b.first, ...rest];
  }
}

Operation mintSeed(Replica r, {required String field, required dynamic value, int? hlcOverride}) {
  final contentKey = 'note:n1:$field:GENESIS:$value';
  return r.mintField(
    table: 'note',
    id: 'n1',
    field: field,
    value: value,
    contentKey: contentKey,
    authorNamespace: 'seed:${r.id}',
    hlcOverride: hlcOverride,
  );
}

void main() {
  group('exhaustive: genesis alias-expansion + recheck-on-discovery', () {
    test('every arrival order of {seedA, seedB, Y} converges to Y with no lingering conflict', () {
      final a = Replica('A');
      final b = Replica('B');
      final seedA = mintSeed(a, field: 'title', value: 'X', hlcOverride: 1);
      final seedB = mintSeed(b, field: 'title', value: 'X', hlcOverride: 2);
      final y = a.mintField(table: 'note', id: 'n1', field: 'title', value: 'Y', hlcOverride: 500);

      var checked = 0;
      for (final order in permutations([seedA, seedB, y])) {
        final r = Replica('R-${order.map((o) => o.dot).join(",")}');
        for (final op in order) {
          r.apply(op);
        }
        expect(r.fieldState['note:n1:title']!.value, 'Y',
            reason: 'order $order should converge to Y');
        expect(r.conflictCopies['note:n1:title'] ?? [], isEmpty,
            reason: 'order $order should leave no spurious conflict');
        checked++;
      }
      expect(checked, 6); // 3! permutations
    });

    test('every arrival order where the stale seed briefly wins still self-heals', () {
      final a = Replica('A');
      final b = Replica('B');
      // seedB has a later HLC than Y, so Y loses the tiebreak if b arrives
      // before a — the "case (i)" repair must fire regardless of order.
      final seedA = mintSeed(a, field: 'title', value: 'X', hlcOverride: 1);
      final seedB = mintSeed(b, field: 'title', value: 'X', hlcOverride: 1000);
      final y = a.mintField(table: 'note', id: 'n1', field: 'title', value: 'Y', hlcOverride: 5);

      for (final order in permutations([seedA, seedB, y])) {
        final r = Replica('R2-${order.map((o) => o.dot).join(",")}');
        for (final op in order) {
          r.apply(op);
        }
        expect(r.fieldState['note:n1:title']!.value, 'Y',
            reason: 'order $order must self-heal to Y once both seeds are known');
        expect(r.conflictCopies['note:n1:title'] ?? [], isEmpty);
      }
    });
  });

  group('exhaustive: same-name tag creation interleavings', () {
    test('every interleaving of two devices\' independent tag-creation streams converges with no live collision', () {
      final d1 = Replica('D1');
      final d2 = Replica('D2');
      final e1 = TagEngine(d1);
      final e2 = TagEngine(d2);
      final t1 = e1.createTag('urgent');
      final t2 = e2.createTag('urgent');

      final d1Ops = d1.outbox.where((o) => o.entityId == t1).toList();
      final d2Ops = d2.outbox.where((o) => o.entityId == t2).toList();
      expect(d1Ops.length, 3);
      expect(d2Ops.length, 3);

      var checked = 0;
      for (final order in interleavings(d1Ops, d2Ops)) {
        final r = Replica('R-$checked');
        for (final op in order) {
          r.apply(op);
        }
        TagEngine(r).resolveAllNameCollisions();
        assertNoLiveTagNameCollision(r);
        assertNoStaleConflictCopies(r);
        checked++;
      }
      // C(6,3) = 20 interleavings.
      expect(checked, 20);
    });
  });

  group('exhaustive: 2-cycle tag merge suppression', () {
    test('every interleaving of the two offline renames converges to exactly one visible tag', () {
      final d1 = Replica('D1');
      final e1 = TagEngine(d1);
      final urgent = e1.createTag('urgent');
      final important = e1.createTag('important');
      // Simulate two independently-authored merge intents as if minted by
      // two different devices (distinct authorId namespaces) racing to
      // redirect each other.
      final d2 = Replica('D2');
      final urgentToImportant = [
        d1.mintField(table: 'tags', id: urgent, field: 'redirectTarget', value: important, hlcOverride: 10),
        d1.mintField(table: 'tags', id: urgent, field: '__deleted__', value: true, hlcOverride: 11),
      ];
      final importantToUrgent = [
        d2.mintField(table: 'tags', id: important, field: 'redirectTarget', value: urgent, hlcOverride: 20),
        d2.mintField(table: 'tags', id: important, field: '__deleted__', value: true, hlcOverride: 21),
      ];

      var checked = 0;
      for (final order in interleavings(urgentToImportant, importantToUrgent)) {
        final r = Replica('R-$checked');
        // seed r with the two tags' own creation info first (not part of
        // the interleaving under test).
        for (final op in d1.outbox.where((o) => o.entityId == urgent || o.entityId == important)) {
          if (!order.contains(op)) r.apply(op);
        }
        for (final op in order) {
          r.apply(op);
        }
        final state = TagEngine(r).computeEffectiveState();
        final visibleCount =
            [urgent, important].where((t) => state.effectiveDeleted[t] == false).length;
        expect(visibleCount, 1, reason: 'order $order must leave exactly one tag visible');
        checked++;
      }
      expect(checked, 6); // C(4,2) = 6
    });
  });

  group('exhaustive: orphan-message effective deletedness under every write-arrival order', () {
    test('a raw tombstone and a concurrent live-membership-add always leave the message never GC-eligible, regardless of order',
        () {
      var checked = 0;
      for (final order in permutations(['tombstone', 'membership'])) {
        final r = Replica('R-$checked');
        final gc = MessageGcEngine(r);
        GcCandidate? candidate;
        for (final action in order) {
          if (action == 'tombstone') {
            r.mintField(table: 'message', id: 'm1', field: '__deleted__', value: true);
            candidate = gc.considerCandidate('m1', 0, existing: candidate);
          } else {
            r.addMembershipRef('conv-1', 'm1');
          }
        }
        expect(gc.effectiveDeleted('m1'), isFalse, reason: 'order $order must never leave the message effectively deleted');
        final outcome = gc.evaluate(candidate: candidate, currentTick: 1000); // well past any grace period
        expect(outcome, isNot(GcOutcome.eligibleForRemoval), reason: 'order $order must never become GC-eligible');
        checked++;
      }
      expect(checked, 2); // 2! permutations
    });
  });
}
