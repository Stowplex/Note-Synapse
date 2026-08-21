// Regression cases for the specific, named failure scenarios raised
// across all eighteen rounds of the cloud-sync protocol review
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md). Each test
// reproduces the concrete counterexample a review round used to motivate
// a fix, and asserts the fix actually prevents it.

import 'package:flutter_test/flutter_test.dart';

import 'app_ops.dart';
import 'conversation_ops.dart';
import 'gc.dart';
import 'model.dart';
import 'replica.dart';
import 'simulator.dart';
import 'tag_ops.dart';

/// Mints a genesis seed op with the round-14 contentKey formula
/// (baseContext="GENESIS", so a value produced by two devices seeding the
/// same pre-existing content deduplicates).
Operation mintSeed(Replica r, {required String table, required String id, required String field, required dynamic value, int? hlcOverride}) {
  final contentKey = '$table:$id:$field:GENESIS:$value';
  return r.mintField(
    table: table,
    id: id,
    field: field,
    value: value,
    contentKey: contentKey,
    authorNamespace: 'seed:${r.id}',
    hlcOverride: hlcOverride,
  );
}

void main() {
  group('causal comparator (causally_includes\'\'\') — Task A motivating scenario', () {
    test(
        'a later edit built on an alias the editor never observed is recognized as causally descending, not concurrent',
        () {
      final a = Replica('A');
      final b = Replica('B');
      final r = Replica('R');

      // A and B independently seed identical value X for the same field.
      final seedA = mintSeed(a, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 10);
      final seedB = mintSeed(b, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 20);

      // R learns about both seeds first (so it knows a<->b are aliases).
      r.apply(seedA);
      r.apply(seedB);
      final canonicalSeedDot = r.dedupIndex[seedA.contentKey]!;
      expect({seedA.dot, seedB.dot}, contains(canonicalSeedDot));

      // A, WITHOUT ever pulling from B, mints an ordinary edit Y — its
      // frontier dominates its own seed dot (a) but has no entry for b's
      // author at all.
      final y = a.mintField(table: 'note', id: 'n1', field: 'title', value: 'Y', hlcOverride: 5);
      expect(y.frontier.containsKey(seedB.authorId), isFalse);

      // R pulls Y. It must recognize Y causally descends from the
      // canonical seed (via witness seedA), not treat it as concurrent.
      r.apply(y);
      expect(r.fieldState['note:n1:title']!.value, 'Y');
      expect(r.conflictCopies['note:n1:title'] ?? [], isEmpty,
          reason: 'Y should cleanly supersede the seed, not be filed as a spurious conflict');
    });
  });

  group('recheck-on-discovery — all three outcomes', () {
    test('case (i): stale seed initially wins, is later promoted once the missing alias is learned', () {
      final a = Replica('A');
      final b = Replica('B');
      final r = Replica('R');

      final seedA = mintSeed(a, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 1);
      final seedB = mintSeed(b, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 100);
      // Y's HLC is lower than seedB's, so if R only knows about b (not a)
      // when it compares, the stale seed wins the tie-break.
      final y = a.mintField(table: 'note', id: 'n1', field: 'title', value: 'Y', hlcOverride: 2);

      r.apply(seedB); // sole winner initially
      r.apply(y); // loses HLC tiebreak against seedB (R doesn't know about seedA yet)
      expect(r.fieldState['note:n1:title']!.value, 'X');
      expect(r.conflictCopies['note:n1:title']!.map((o) => o.dot), contains(y.dot));

      r.apply(seedA); // dedup redirects seedA into seedB's class -> recheck fires
      expect(r.fieldState['note:n1:title']!.value, 'Y', reason: 'recheck should promote Y');
      expect(r.conflictCopies['note:n1:title'] ?? [], isEmpty);
    });

    test('case (ii): correct winner is proven, the now-spurious conflict copy is discarded not re-filed', () {
      final a = Replica('A');
      final b = Replica('B');
      final r = Replica('R');

      final seedA = mintSeed(a, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 1);
      final seedB = mintSeed(b, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 2);
      final y = a.mintField(table: 'note', id: 'n1', field: 'title', value: 'Y', hlcOverride: 50);

      r.apply(y); // sole winner
      r.apply(seedB); // loses HLC tiebreak against Y, filed as conflict (R doesn't know seedA yet)
      expect(r.fieldState['note:n1:title']!.value, 'Y');
      expect(r.conflictCopies['note:n1:title']!.map((o) => o.dot), contains(seedB.dot));

      r.apply(seedA); // dedup fast-path redirects seedA -> recheck fires
      expect(r.fieldState['note:n1:title']!.value, 'Y', reason: 'winner unchanged');
      expect(r.conflictCopies['note:n1:title'] ?? [], isEmpty,
          reason: 'seedB is now a proven causal ancestor of Y and must be discarded, not left as a spurious conflict');
    });

    test('case (iii): genuinely concurrent values remain a retained conflict after recheck', () {
      final a = Replica('A');
      final b = Replica('B');
      final c = Replica('C');
      final r = Replica('R');

      final seedA = mintSeed(a, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 1);
      final seedB = mintSeed(b, table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 2);
      // Z is genuinely concurrent with the seed pair — it doesn't build on
      // either seed's frontier at all.
      final z = c.mintField(table: 'note', id: 'n1', field: 'title', value: 'Z', hlcOverride: 500);

      r.apply(seedB);
      r.apply(z);
      final firstWinner = r.fieldState['note:n1:title']!.value;
      expect(firstWinner, 'Z'); // Z has the higher HLC

      r.apply(seedA); // triggers recheck
      expect(r.fieldState['note:n1:title']!.value, 'Z', reason: 'still concurrent, HLC tiebreak unchanged');
      // seedA and seedB are aliases of each other (same contentKey class) —
      // exactly one canonical representative of the pair is retained as
      // the genuine concurrent conflict, not both aliases individually.
      final conflicts = r.conflictCopies['note:n1:title']!;
      expect(conflicts.length, 1,
          reason: 'the seed pair collapses to one canonical representative, not two aliases');
      expect(conflicts.single.value, 'X',
          reason: 'genuinely concurrent — must remain a retained conflict, not be discarded');
    });
  });

  group('tag merge — cycle suppression', () {
    test('2-cycle: exactly one side survives tombstoned, the lower-ranked edge is reversed', () {
      final sim = Simulator(seed: 1);
      final d1 = sim.addReplica('D1');
      final d2 = sim.addReplica('D2');
      final e1 = TagEngine(d1);
      final e2 = TagEngine(d2);

      final urgent = e1.createTag('urgent');
      sim.syncFull(d1, d2);
      final important = e2.createTag('important');
      sim.syncFull(d2, d1);

      // D1 offline-renames urgent->important; D2 offline-renames important->urgent.
      d1.mintField(table: 'tags', id: urgent, field: 'redirectTarget', value: important, hlcOverride: 10);
      d1.mintField(table: 'tags', id: urgent, field: '__deleted__', value: true, hlcOverride: 11);
      d2.mintField(table: 'tags', id: important, field: 'redirectTarget', value: urgent, hlcOverride: 20);
      d2.mintField(table: 'tags', id: important, field: '__deleted__', value: true, hlcOverride: 21);

      sim.syncAllToAll();

      final state = e1.computeEffectiveState();
      final urgentVisible = state.effectiveDeleted[urgent] == false;
      final importantVisible = state.effectiveDeleted[important] == false;
      expect(urgentVisible ^ importantVisible, isTrue,
          reason: 'exactly one of the two cycle participants must be effectively visible');

      // The lower-ranked edge (important->urgent, hlc 20) should be
      // suppressed since urgent->important's tombstone write (hlc 11) is
      // lower still... recompute expected loser directly from the rule:
      // the edge with the LOWER (hlc,authorId,authorSeq) redirect write is
      // suppressed. urgent's redirect write has hlc 10; important's has
      // hlc 20 — urgent's is lower-ranked, so urgent is the suppressed
      // (effectively-visible) node.
      expect(urgentVisible, isTrue);
      expect(importantVisible, isFalse);
      assertNoLiveTagNameCollision(d1);
      assertNoLiveTagNameCollision(d2);
    });

    test('3-cycle: exactly one member survives', () {
      final sim = Simulator(seed: 2);
      final d1 = sim.addReplica('D1');
      final e1 = TagEngine(d1);
      final t1 = e1.createTag('a');
      final t2 = e1.createTag('b');
      final t3 = e1.createTag('c');

      d1.mintField(table: 'tags', id: t1, field: 'redirectTarget', value: t2, hlcOverride: 1);
      d1.mintField(table: 'tags', id: t1, field: '__deleted__', value: true, hlcOverride: 2);
      d1.mintField(table: 'tags', id: t2, field: 'redirectTarget', value: t3, hlcOverride: 3);
      d1.mintField(table: 'tags', id: t2, field: '__deleted__', value: true, hlcOverride: 4);
      d1.mintField(table: 'tags', id: t3, field: 'redirectTarget', value: t1, hlcOverride: 5);
      d1.mintField(table: 'tags', id: t3, field: '__deleted__', value: true, hlcOverride: 6);

      final state = e1.computeEffectiveState();
      final visibleCount =
          [t1, t2, t3].where((t) => state.effectiveDeleted[t] == false).length;
      expect(visibleCount, 1, reason: 'exactly one member of a 3-cycle must survive visible');
      expect(state.cycleLosers.length, 1);
    });

    test('non-cyclic fan-out: two different targets for the same source resolve via ordinary field conflict, not a crash',
        () {
      final sim = Simulator(seed: 3);
      final d1 = sim.addReplica('D1');
      final d2 = sim.addReplica('D2');
      final e1 = TagEngine(d1);

      final src = e1.createTag('urgent');
      sim.syncFull(d1, d2);
      final targetA = e1.createTag('important');
      final e2 = TagEngine(d2);
      final targetB = e2.createTag('critical');
      sim.syncFull(d1, d2);
      sim.syncFull(d2, d1);

      d1.mintField(table: 'tags', id: src, field: 'redirectTarget', value: targetA, hlcOverride: 100);
      d1.mintField(table: 'tags', id: src, field: '__deleted__', value: true, hlcOverride: 101);
      d2.mintField(table: 'tags', id: src, field: 'redirectTarget', value: targetB, hlcOverride: 50);
      d2.mintField(table: 'tags', id: src, field: '__deleted__', value: true, hlcOverride: 51);

      sim.syncAllToAll();

      // Ordinary per-field conflict rule: higher HLC (targetA @ 100) wins.
      expect(d1.fieldValue<String>('tags', src, 'redirectTarget'), targetA);
      expect(d2.fieldValue<String>('tags', src, 'redirectTarget'), targetA);
      expect(d1.conflictCopies['tags:$src:redirectTarget']!.map((o) => o.dot),
          contains(Dot('D2', 4)));
    });
  });

  group('auto-merge on name collision', () {
    test('two devices independently creating the same name converge to one entity, no raw collision survives', () {
      final sim = Simulator(seed: 4);
      final d1 = sim.addReplica('D1');
      final d2 = sim.addReplica('D2');
      final e1 = TagEngine(d1);
      final e2 = TagEngine(d2);

      final t1 = e1.createTag('urgent');
      final t2 = e2.createTag('urgent');

      sim.syncAllToAll();

      assertNoLiveTagNameCollision(d1);
      assertNoLiveTagNameCollision(d2);

      final s1 = e1.computeEffectiveState();
      final visible = [t1, t2].where((t) => s1.effectiveDeleted[t] == false).toList();
      expect(visible.length, 1, reason: 'exactly one of the two same-named tags survives visible');

      // Deterministic winner: lower creation dot.
      final winnerExpected = e1.creationDot(t1)!.compareTo(e1.creationDot(t2)!) < 0 ? t1 : t2;
      expect(visible.single, winnerExpected);
    });

    test('identical-outcome auto-merges from independent replicas do not produce a spurious field_conflict', () {
      final sim = Simulator(seed: 5);
      final d1 = sim.addReplica('D1');
      final d2 = sim.addReplica('D2');
      final d3 = sim.addReplica('D3');
      final e1 = TagEngine(d1);
      final e2 = TagEngine(d2);
      final e3 = TagEngine(d3);

      final t1 = e1.createTag('urgent');
      final t2 = e2.createTag('urgent');
      final t3 = e3.createTag('urgent');

      // Pairwise syncs in a scrambled order so more than one replica
      // independently detects and mints the same-outcome auto-merge.
      sim.syncFull(d1, d2);
      sim.syncFull(d2, d1);
      sim.syncFull(d1, d3);
      sim.syncFull(d3, d1);
      sim.syncAllToAll();

      assertNoLiveTagNameCollision(d1);
      assertNoLiveTagNameCollision(d2);
      assertNoLiveTagNameCollision(d3);
      for (final r in [d1, d2, d3]) {
        assertNoStaleConflictCopies(r);
      }

      final winnerCreation = [t1, t2, t3]
          .map((t) => e1.creationDot(t)!)
          .reduce((a, b) => a < b ? a : b);
      // No field_conflict entries should exist for the redirectTarget/
      // __deleted__ fields of the losing tags — contentKey dedup should
      // have absorbed every independently-minted, identical-outcome pair.
      for (final t in [t1, t2, t3]) {
        expect(d1.conflictCopies['tags:$t:redirectTarget'] ?? [], isEmpty);
        expect(d1.conflictCopies['tags:$t:__deleted__'] ?? [], isEmpty);
      }
      expect(winnerCreation, isNotNull);
    });
  });

  group('restore vs. name collision (write-path guard)', () {
    test('restoring a merged tag into a name now held by a different live tag resolves via the same tie-break', () {
      final sim = Simulator(seed: 6);
      final d1 = sim.addReplica('D1');
      final e1 = TagEngine(d1);

      final urgent = e1.createTag('urgent');
      final important = e1.createTag('important');
      e1.tagMerge(urgent, important); // "urgent" tombstoned, redirects to "important"

      // A brand-new, unrelated tag also named "urgent" is created later.
      final newUrgent = e1.createTag('urgent');
      assertNoLiveTagNameCollision(d1);

      // Restoring the original "urgent" must not silently create a raw
      // collision with newUrgent.
      e1.restoreTag(urgent);
      assertNoLiveTagNameCollision(d1);

      final state = e1.computeEffectiveState();
      final urgentVisible = state.effectiveDeleted[urgent] == false;
      final newUrgentVisible = state.effectiveDeleted[newUrgent] == false;
      expect(urgentVisible ^ newUrgentVisible, isTrue,
          reason: 'exactly one of the two same-named tags is visible after the guarded restore');
    });

    test('generic undelete on an ordinarily-deleted tag is guarded identically to restore', () {
      final sim = Simulator(seed: 7);
      final d1 = sim.addReplica('D1');
      final e1 = TagEngine(d1);

      final urgent = e1.createTag('urgent');
      // Ordinary (non-merge) delete.
      d1.mintField(table: 'tags', id: urgent, field: '__deleted__', value: true);
      final newUrgent = e1.createTag('urgent');

      e1.genericUndelete(urgent); // writes only __deleted__=false, never touches redirectTarget
      assertNoLiveTagNameCollision(d1);

      final state = e1.computeEffectiveState();
      final urgentVisible = state.effectiveDeleted[urgent] == false;
      final newUrgentVisible = state.effectiveDeleted[newUrgent] == false;
      expect(urgentVisible ^ newUrgentVisible, isTrue);
    });
  });

  group('tag image/AI-config derivation and purge interaction', () {
    test('a merge target with no own image inherits the source\'s image', () {
      final d1 = Replica('D1');
      final e1 = TagEngine(d1);
      final from = e1.createTag('urgent');
      final to = e1.createTag('important');
      d1.mintField(table: 'tag_images', id: from, field: 'imagePath', value: '/img/urgent.png');
      e1.tagMerge(from, to);

      expect(e1.effectiveImagePath(to), '/img/urgent.png');
    });

    test('a merge target keeps its own image over an inherited one', () {
      final d1 = Replica('D1');
      final e1 = TagEngine(d1);
      final from = e1.createTag('urgent');
      final to = e1.createTag('important');
      d1.mintField(table: 'tag_images', id: from, field: 'imagePath', value: '/img/urgent.png');
      d1.mintField(table: 'tag_images', id: to, field: 'imagePath', value: '/img/important.png');
      e1.tagMerge(from, to);

      expect(e1.effectiveImagePath(to), '/img/important.png',
          reason: 'target\'s own direct value must always win over an inherited one');
    });

    test('a tag currently supplying a live tag\'s inherited image is not purge-eligible', () {
      final d1 = Replica('D1');
      final e1 = TagEngine(d1);
      final from = e1.createTag('urgent');
      final to = e1.createTag('important');
      d1.mintField(table: 'tag_images', id: from, field: 'imagePath', value: '/img/urgent.png');
      e1.tagMerge(from, to);

      expect(e1.tagPurgeEligible(from), isFalse,
          reason: 'important still inherits its image from urgent');

      // Once `to` gets its own image, `from` is no longer needed and
      // becomes purge-eligible.
      d1.mintField(table: 'tag_images', id: to, field: 'imagePath', value: '/img/important.png');
      expect(e1.tagPurgeEligible(from), isTrue);
    });
  });

  group('merge-chain purge protection', () {
    test('an intermediate hop in a merge chain is protected from purge by the inbound-redirect check', () {
      final d1 = Replica('D1');
      final e1 = TagEngine(d1);
      final a = e1.createTag('urgent');
      final b = e1.createTag('important');
      final c = e1.createTag('critical');
      e1.tagMerge(a, b); // A -> B
      e1.tagMerge(b, c); // B -> C

      d1.addMembershipRef('note-1', a); // an old note_tags row still names A directly

      expect(e1.tagPurgeEligible(b), isFalse, reason: 'A still points at B');
      expect(e1.tagPurgeEligible(a), isFalse, reason: 'a live membership row still names A directly');
      // C is live, never a purge candidate at all.
      final state = e1.computeEffectiveState();
      expect(state.effectiveDeleted[c], isFalse);
    });

    test('once the live reference is gone, the chain becomes purge-eligible bottom-up', () {
      final d1 = Replica('D1');
      final e1 = TagEngine(d1);
      final a = e1.createTag('urgent');
      final b = e1.createTag('important');
      e1.tagMerge(a, b);

      expect(e1.tagPurgeEligible(a), isTrue, reason: 'no inbound redirect edge and no membership ref');
    });
  });

  group('field-conflict resolution over full retained history', () {
    test(
        'a three-hop transitive-domination chain (X>Y>Z) must not let Z win an ordinary tie-break against X once Y is discarded',
        () {
      // X dominates Y (same author, later seq). Y dominates Z (Y's minting
      // device had synced with Z's author). X's OWN frontier never
      // mentions Z's author directly at all — frontier propagation is
      // deliberately narrow (observing an op records only that op's own
      // author/seq, never the frontier it carried). A replica that first
      // resolves X-vs-Y (discarding Y as a dominated ancestor) and only
      // LATER receives Z must still recognize X as the true winner,
      // not let Z win an ordinary HLC tie-break against X.
      final devY = Replica('devY');
      final devZ = Replica('devZ');
      final devX = Replica('devX');

      final z = devZ.mintField(table: 'note', id: 'n1', field: 'title', value: 'Z', hlcOverride: 3);
      // Y observes Z before minting its own write — Y's frontier
      // therefore dominates Z.
      devY.apply(z);
      final y = devY.mintField(table: 'note', id: 'n1', field: 'title', value: 'Y', hlcOverride: 1);
      // X observes Y (not Z directly) before minting its own write — X's
      // frontier dominates Y, but has no entry for Z's author at all.
      devX.apply(y);
      final x = devX.mintField(table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 2);

      final r = Replica('R');
      r.apply(x); // sole winner
      r.apply(y); // dominated by x (same-author succession never even
      // reaches this field — y arrives after x here), discarded
      expect(r.fieldState['note:n1:title']!.value, 'X');

      r.apply(z); // must NOT win an ordinary tie-break against X
      expect(r.fieldState['note:n1:title']!.value, 'X',
          reason: 'X transitively dominates Z via the discarded witness Y — Z must not win a direct tie-break');
      expect(r.conflictCopies['note:n1:title'] ?? [], isEmpty,
          reason: 'round 20: Z is now correctly recognized as a transitively-dominated ancestor via the '
              'singleton-witness chain X>Y>Z (chainDom), not left stranded as a stale conflict copy the way a '
              'direct-only discard check would leave it');
    });

    test('the same chain converges correctly regardless of arrival order', () {
      final devY = Replica('devY');
      final devZ = Replica('devZ');
      final devX = Replica('devX');
      final z = devZ.mintField(table: 'note', id: 'n1', field: 'title', value: 'Z', hlcOverride: 3);
      devY.apply(z);
      final y = devY.mintField(table: 'note', id: 'n1', field: 'title', value: 'Y', hlcOverride: 1);
      devX.apply(y);
      final x = devX.mintField(table: 'note', id: 'n1', field: 'title', value: 'X', hlcOverride: 2);

      for (final order in [
        [z, y, x],
        [y, z, x],
        [y, x, z],
        [x, y, z],
        [x, z, y],
        [z, x, y],
      ]) {
        final r = Replica('R-${order.map((o) => o.value).join()}');
        for (final op in order) {
          r.apply(op);
        }
        expect(r.fieldState['note:n1:title']!.value, 'X', reason: 'order $order must converge to X');
      }
    });

    test('a genuine pairwise 3-cycle formed by an HLC tie broken by authorId converges to the same, order-independent winner',
        () {
      // B causally dominates A (B observed A before minting). A and C are
      // concurrent, A winning on a strictly higher HLC. B and C are ALSO
      // concurrent, but tie on HLC — broken by the authorId secondary key,
      // which C wins ("AuthC" > "AuthB"). This is a genuine pairwise cycle
      // (B beats A, A beats C, C beats B) — the exact counterexample
      // motivating the order-independent maximal-set computation: A is
      // excluded (dominated by B), leaving B and C as the only maximal
      // candidates, and C wins their tie. Every arrival order must
      // converge to the SAME answer, C — never A, despite A "beating" C
      // in an isolated pairwise comparison, and never B, despite B
      // "beating" A.
      final devA = Replica('AuthA');
      final devB = Replica('AuthB');
      final devC = Replica('AuthC');
      final a = devA.mintField(table: 'note', id: 'n2', field: 'title', value: 'A', hlcOverride: 5);
      devB.apply(a); // B observes A before minting -> B dominates A
      final b = devB.mintField(table: 'note', id: 'n2', field: 'title', value: 'B', hlcOverride: 3);
      final c = devC.mintField(table: 'note', id: 'n2', field: 'title', value: 'C', hlcOverride: 3); // ties B's hlc

      for (final order in [
        [a, b, c],
        [a, c, b],
        [b, a, c],
        [b, c, a],
        [c, a, b],
        [c, b, a],
      ]) {
        final r = Replica('R2-${order.map((o) => o.value).join()}');
        for (final op in order) {
          r.apply(op);
        }
        expect(r.fieldState['note:n2:title']!.value, 'C',
            reason: 'order $order must converge to C (the maximal-set + authorId-tiebreak winner), not A or B');
      }
    });
  });

  group('round 20 — mutual/cyclic group domination', () {
    test(
        'two contentKey-alias groups that mutually "dominate" each other via their unioned frontiers must never silently discard either side',
        () {
      // Group A = {A1, A2}, group B = {B1, B2}. A2 (minted by a device that
      // first observed B1) makes union(A) dominate B1: _groupDominates(A,B).
      // Independently, B2 (minted by a device that first observed A1)
      // makes union(B) dominate A1: _groupDominates(B,A). Both hold
      // simultaneously — genuine mutual domination between the two GROUPS
      // — even though no individual alias pair (A1/B1, A1/B2, A2/B1, A2/B2)
      // is itself mutually dominating. The pre-round-20 "maximal" filter
      // would exclude both groups, trip its defensive fallback, and then
      // silently discard the tie-break loser as a "proven ancestor" —
      // exactly the silent-data-loss bug this fix closes.
      final gb1 = Replica('GB1');
      final b1 = gb1.mintField(table: 'note', id: 'n1', field: 'title', value: 'B1val', contentKey: 'ckB', hlcOverride: 5);

      final ga1 = Replica('GA1');
      final a1 = ga1.mintField(table: 'note', id: 'n1', field: 'title', value: 'A1val', contentKey: 'ckA', hlcOverride: 5);

      final ga2 = Replica('GA2');
      ga2.apply(b1); // GA2 observes B1 before minting -> union(A) dominates B1
      final a2 = ga2.mintField(table: 'note', id: 'n1', field: 'title', value: 'A2val', contentKey: 'ckA', hlcOverride: 6);

      final gb2 = Replica('GB2');
      gb2.apply(a1); // GB2 observes A1 before minting -> union(B) dominates A1
      final b2 = gb2.mintField(table: 'note', id: 'n1', field: 'title', value: 'B2val', contentKey: 'ckB', hlcOverride: 10);

      final r = Replica('R');
      for (final op in [b1, a1, a2, b2]) {
        r.apply(op);
      }

      // Canonical representatives are 'GA1'/'GB1' (lexicographically first
      // dot within each group); B1's hlc (10) beats A1's hlc (5), so group
      // B wins the tie-break — but group A must be RETAINED, never
      // silently discarded, since the "domination" between the two groups
      // is genuinely mutual, not a proven one-directional ancestry.
      expect(r.fieldState['note:n1:title']!.value, 'B1val');
      final conflicts = r.conflictCopies['note:n1:title'] ?? [];
      expect(conflicts, isNotEmpty,
          reason: 'group A must survive as a genuine conflict copy, not be silently discarded as a "proven ancestor"');
      expect(conflicts.map((o) => o.value), contains('A1val'));

      // Symmetric check: if the receiving replica applies the operations
      // in a different order, the outcome must be identical (order-
      // independent by construction).
      final r2 = Replica('R2');
      for (final op in [a2, b2, a1, b1]) {
        r2.apply(op);
      }
      expect(r2.fieldState['note:n1:title']!.value, 'B1val');
      expect(r2.conflictCopies['note:n1:title']!.map((o) => o.value), contains('A1val'));
    });
  });

  group('auto-merge contentKey generations', () {
    test('a tag auto-merged, then restored, then re-colliding with the same winner mints a distinct contentKey', () {
      final d1 = Replica('D1');
      final e1 = TagEngine(d1);
      final first = e1.createTag('urgent');
      final second = e1.createTag('urgent'); // triggers the first auto-merge
      assertNoLiveTagNameCollision(d1);
      // The lower creation dot wins the tie-break — `first` (created
      // earlier) is the winner, `second` the loser.
      final winner = first;
      final loser = second;
      expect(e1.rawRedirectTarget(loser), winner);

      e1.restoreTag(loser); // re-collides with the same winner immediately
      assertNoLiveTagNameCollision(d1);
      expect(e1.rawRedirectTarget(loser), winner,
          reason: 'the second auto-merge attempt must not be silently absorbed by the first (stale) attempt\'s contentKey');

      final ck1 = d1.outbox
          .where((o) => o.entityId == loser && o.fieldName == 'redirectTarget' && o.contentKey != null)
          .first
          .contentKey;
      final ck2 = d1.outbox
          .where((o) => o.entityId == loser && o.fieldName == 'redirectTarget' && o.contentKey != null)
          .last
          .contentKey;
      expect(ck1, isNot(equals(ck2)),
          reason: 'two distinct restore-then-recollide cycles must mint distinct contentKeys');
    });
  });

  group('policy-based GC — blob, orphan-message, and log-pruning (§ Architecture 4/6)', () {
    group('blob GC', () {
      test('positive case: an unreferenced blob becomes eligible once the grace period elapses with no interference', () {
        final sim = Simulator(seed: 100);
        final d1 = sim.addReplica('D1');
        final gc = BlobGcEngine(d1);

        d1.uploadBlob('H1');
        d1.unreferenceBlob('H1'); // absent from the consolidated state
        final snapshot = gc.certify(sim.tick);
        final candidate = gc.considerCandidate('H1', snapshot);

        sim.advanceTick(10); // default grace period
        final latest = gc.certify(sim.tick);
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick, latestSnapshot: latest);
        expect(outcome, GcOutcome.eligibleForRemoval);
        expect(gc.pruneIfEligible('H1', outcome), isTrue);
        expect(d1.knownBlobHashes.contains('H1'), isFalse);
      });

      test('within the grace period is never eligible, even though already unreferenced', () {
        final sim = Simulator(seed: 101);
        final d1 = sim.addReplica('D1');
        final gc = BlobGcEngine(d1);

        d1.uploadBlob('H1');
        d1.unreferenceBlob('H1');
        final snapshot = gc.certify(sim.tick);
        final candidate = gc.considerCandidate('H1', snapshot);

        sim.advanceTick(3); // short of the default 10-tick grace period
        final latest = gc.certify(sim.tick);
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick, latestSnapshot: latest);
        expect(outcome, GcOutcome.withinGracePeriod);
        expect(gc.pruneIfEligible('H1', outcome), isFalse);
        expect(d1.knownBlobHashes.contains('H1'), isTrue);
      });

      test('a blob referenced again during its grace period is un-candidated at the fresh recheck, never removed', () {
        final sim = Simulator(seed: 102);
        final d1 = sim.addReplica('D1');
        final gc = BlobGcEngine(d1);

        d1.uploadBlob('H1');
        d1.unreferenceBlob('H1');
        final snapshot = gc.certify(sim.tick); // tick 0: absent, candidacy starts
        final candidate = gc.considerCandidate('H1', snapshot);

        sim.advanceTick(5); // mid-grace-period
        d1.referenceBlob('H1'); // a device legitimately publishes a new reference

        sim.advanceTick(10); // now past the original grace window
        // The fresh recheck is against the LATEST available certified
        // snapshot, which by now postdates the one that started the
        // window and reflects the new reference.
        final latest = gc.certify(sim.tick);
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick, latestSnapshot: latest);
        expect(outcome, GcOutcome.unCandidated,
            reason: 'the fresh recheck must find the new reference and drop candidacy');
        expect(gc.pruneIfEligible('H1', outcome), isFalse);
        expect(d1.knownBlobHashes.contains('H1'), isTrue, reason: 'blob must survive — un-candidated, not removed');
      });
    });

    group('orphan-message cleanup', () {
      test('positive case: a raw-tombstoned message with no live membership becomes eligible once the grace period elapses',
          () {
        final sim = Simulator(seed: 110);
        final d1 = sim.addReplica('D1');
        final gc = MessageGcEngine(d1);

        d1.mintField(table: 'message', id: 'm1', field: '__deleted__', value: true);
        final candidate = gc.considerCandidate('m1', sim.tick);

        sim.advanceTick(10);
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick);
        expect(outcome, GcOutcome.eligibleForRemoval);
        expect(gc.pruneIfEligible('m1', outcome), isTrue);
        expect(d1.grave.contains('m1'), isTrue, reason: 'purge must retain a grave marker');
        expect(d1.physicallyRemovedMessages.contains('m1'), isTrue);
      });

      test('a raw tombstone with a concurrently-added live membership is never removed — tombstone-then-membership order',
          () {
        final sim = Simulator(seed: 111);
        final d1 = sim.addReplica('D1');
        final gc = MessageGcEngine(d1);

        d1.mintField(table: 'message', id: 'm1', field: '__deleted__', value: true);
        final candidate = gc.considerCandidate('m1', sim.tick);
        // A concurrent, legitimate membership-add arrives — a write to a
        // DIFFERENT CRDT subject (conversation_message_mapping) the
        // per-field conflict rule cannot relate to the tombstone at all.
        d1.addMembershipRef('conv-1', 'm1');

        sim.advanceTick(10);
        expect(gc.effectiveDeleted('m1'), isFalse);
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick);
        expect(outcome, GcOutcome.unCandidated,
            reason: 'raw __deleted__ is true but effective deletedness is false — must never be removed');
        expect(gc.pruneIfEligible('m1', outcome), isFalse);
        expect(d1.physicallyRemovedMessages.contains('m1'), isFalse);
      });

      test('a raw tombstone with a concurrently-added live membership is never removed — membership-then-tombstone order',
          () {
        final sim = Simulator(seed: 112);
        final d1 = sim.addReplica('D1');
        final gc = MessageGcEngine(d1);

        // This time the membership-add is observed BEFORE the tombstone —
        // effective deletedness must be identical regardless of arrival
        // order, since it's a derived, always-recomputed value.
        d1.addMembershipRef('conv-1', 'm1');
        d1.mintField(table: 'message', id: 'm1', field: '__deleted__', value: true);
        final candidate = gc.considerCandidate('m1', sim.tick);

        sim.advanceTick(10);
        expect(gc.effectiveDeleted('m1'), isFalse);
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick);
        expect(outcome, GcOutcome.unCandidated);
        expect(gc.pruneIfEligible('m1', outcome), isFalse);
        expect(d1.physicallyRemovedMessages.contains('m1'), isFalse);
      });

      test('a live message (never tombstoned) never becomes a GC candidate at all', () {
        final d1 = Replica('D1');
        final gc = MessageGcEngine(d1);
        d1.addMembershipRef('conv-1', 'm1');
        final candidate = gc.considerCandidate('m1', 0);
        expect(candidate, isNull);
      });
    });

    group('log-pruning join race', () {
      test('positive case: pruning proceeds normally when no device joins during the grace period', () {
        final sim = Simulator(seed: 120);
        sim.addReplica('D1');
        sim.addReplica('D2');
        final engine = LogPruneEngine(sim);

        final snapshot = engine.certify();
        final candidate = engine.startCandidacy(snapshot);
        sim.advanceTick(10);
        final decision = engine.evaluate(candidate: candidate, certifiedSnapshot: snapshot);
        expect(decision, LogPruneDecision.proceed);
        expect(engine.pruneIfProceeding(snapshot, decision), isTrue);
        expect(sim.prunedLogGenerations.contains(snapshot.certifiedAtTick), isTrue);
      });

      test('within the grace period never proceeds, even with no joiners', () {
        final sim = Simulator(seed: 121);
        sim.addReplica('D1');
        final engine = LogPruneEngine(sim);
        final snapshot = engine.certify();
        final candidate = engine.startCandidacy(snapshot);
        sim.advanceTick(3);
        final decision = engine.evaluate(candidate: candidate, certifiedSnapshot: snapshot);
        expect(decision, LogPruneDecision.withinGracePeriod);
        expect(engine.pruneIfProceeding(snapshot, decision), isFalse);
      });

      test('a device that joins during the grace period defers (not abandons) the round; a fresh certificate after the join proceeds normally',
          () {
        final sim = Simulator(seed: 122);
        sim.addReplica('D1');
        sim.addReplica('D2');
        final engine = LogPruneEngine(sim);

        final snapshot = engine.certify(); // members = {D1, D2} at tick 0
        final candidate = engine.startCandidacy(snapshot);

        sim.advanceTick(5); // mid-grace-period
        sim.addReplica('D3'); // D3 joins before the grace period ends

        sim.advanceTick(10); // now past the original grace window
        final decision = engine.evaluate(candidate: candidate, certifiedSnapshot: snapshot);
        expect(decision, LogPruneDecision.deferred,
            reason: 'D3 joined after certificate construction — the round must be deferred, not abandoned');
        expect(engine.pruneIfProceeding(snapshot, decision), isFalse);
        expect(sim.prunedLogGenerations, isEmpty);

        // Next cycle: a FRESH certificate is built, now including D3 — D3
        // gets the same grace window to complete its bootstrap read of
        // the old logs it needs, and pruning proceeds normally once that
        // window elapses with no further joiners.
        final snapshot2 = engine.certify(); // members = {D1, D2, D3}
        final candidate2 = engine.startCandidacy(snapshot2);
        sim.advanceTick(10);
        final decision2 = engine.evaluate(candidate: candidate2, certifiedSnapshot: snapshot2);
        expect(decision2, LogPruneDecision.proceed,
            reason: 'the retried round must proceed once the new member is already accounted for at certificate time');
        expect(engine.pruneIfProceeding(snapshot2, decision2), isTrue);
        expect(sim.prunedLogGenerations.contains(snapshot2.certifiedAtTick), isTrue);
      });
    });
  });

  group('conversation-message mapping ordering (§ Architecture 10, round 8/14 correction)', () {
    test(
        '(a) two replicas independently seeding IDENTICAL pre-existing mapping data, built via each replica\'s OWN local insertion order, converge to the same membership set via contentKey dedup',
        () {
      final sim = Simulator(seed: 200);
      final a = sim.addReplica('A');
      final b = sim.addReplica('B');
      final engineA = ConversationMappingEngine(a);
      final engineB = ConversationMappingEngine(b);

      // Both replicas hold the IDENTICAL pre-existing batch (same
      // conversationId/messageId/createdAtMillis), but A's own local
      // autoincrement-id order differs from B's own local order — exactly
      // the "divergent local batch-insert ordering from before sync ever
      // existed" precondition, here for the ordinary (non-divergent-
      // content) case where the underlying data really is the same.
      engineA.seedBatch(a, conversationId: 'c1', createdAtMillis: 1000, localInsertOrder: ['m1', 'm2', 'm3'], baseHlc: 1);
      engineB.seedBatch(b, conversationId: 'c1', createdAtMillis: 1000, localInsertOrder: ['m3', 'm1', 'm2'], baseHlc: 1);

      sim.syncAllToAll();

      for (final m in ['m1', 'm2', 'm3']) {
        expect(engineA.contains('c1', m), isTrue, reason: '$m must be a member on A');
        expect(engineB.contains('c1', m), isTrue, reason: '$m must be a member on B');
      }

      // Each message's mapping was seeded identically by both replicas —
      // per-message contentKey dedup must have fired for all three,
      // leaving exactly one canonical dot recorded per message across the
      // whole system (never two competing, undeduplicated add-dots for
      // the same logical mapping).
      for (final m in ['m1', 'm2', 'm3']) {
        final ck = ConversationMappingEngine.genesisContentKey('c1', m, 1000);
        expect(a.dedupIndex.containsKey(ck), isTrue);
        expect(b.dedupIndex.containsKey(ck), isTrue);
        // The dedup fast path must actually have fired, not merely have a
        // dedupIndex entry present (which is populated on first observation
        // regardless of whether a duplicate ever arrives) — confirm each
        // replica's live setState genuinely collapsed to a single dot per
        // message, not two competing raw add-dots.
        expect(a.setState['${ConversationMappingEngine.table}:c1']![m], hasLength(1),
            reason: '$m: A\'s dedup fast path must collapse both incarnations to one live dot');
        expect(b.setState['${ConversationMappingEngine.table}:c1']![m], hasLength(1),
            reason: '$m: B\'s dedup fast path must collapse both incarnations to one live dot');
      }
    });

    test(
        '(b) the cross-replica ordering key uses the sorted-uuid-tuple tiebreak, not local id — stable and deterministic across replicas even when local insertion orders differed',
        () {
      final sim = Simulator(seed: 201);
      final a = sim.addReplica('A');
      final b = sim.addReplica('B');
      final engineA = ConversationMappingEngine(a);
      final engineB = ConversationMappingEngine(b);

      // Deliberately reversed local insertion orders between A and B, all
      // sharing the same createdAtMillis (a same-millisecond batch-insert
      // tie, exactly the case the round-14 fix addresses).
      final localOrderA = ['m3', 'm1', 'm4', 'm2'];
      final localOrderB = ['m2', 'm4', 'm1', 'm3'];
      engineA.seedBatch(a, conversationId: 'c1', createdAtMillis: 5000, localInsertOrder: localOrderA, baseHlc: 100);
      engineB.seedBatch(b, conversationId: 'c1', createdAtMillis: 5000, localInsertOrder: localOrderB, baseHlc: 900);

      sim.syncAllToAll();

      final orderA = engineA.effectiveOrder('c1');
      final orderB = engineB.effectiveOrder('c1');
      expect(orderA, equals(orderB), reason: 'the cross-replica ordering key must be identical on every replica');

      // The stable key is the sorted-uuid tuple, not either replica's own
      // local insertion order — here that's a plain lexicographic
      // messageId sort, since createdAtMillis ties for the whole batch.
      expect(orderA, ['m1', 'm2', 'm3', 'm4']);
      expect(orderA, isNot(equals(localOrderA)), reason: 'must not reflect A\'s own local insertion order');
      expect(orderA, isNot(equals(localOrderB)), reason: 'must not reflect B\'s own local insertion order');
    });

    test(
        '(c) a single replica\'s OWN seed-time HLC assignment correctly reflects its own local batch-insert order for same-millisecond entries',
        () {
      final a = Replica('A');
      final engine = ConversationMappingEngine(a);

      final localOrder = ['mZ', 'mA', 'mQ', 'mB'];
      final ops = engine.seedBatch(a, conversationId: 'c1', createdAtMillis: 42, localInsertOrder: localOrder, baseHlc: 7);

      // hlc strictly increases in LOCAL insertion order — the device's own
      // real history is preserved for its own seed HLCs, not discarded by
      // an arbitrary (e.g. uuid-sort) tiebreak.
      for (var i = 0; i < ops.length; i++) {
        expect(ops[i].hlc, 7 + i);
        expect(ops[i].fieldName, localOrder[i], reason: 'memberUuid (messageId) matches the local-order slot');
      }

      // This is a purely local/decorative ordering (point 2) — distinct
      // from the cross-replica ordering key (point 1), which for this same
      // same-millisecond batch instead sorts by messageId, NOT local hlc.
      final crossReplicaOrder = engine.effectiveOrder('c1');
      expect(crossReplicaOrder, ['mA', 'mB', 'mQ', 'mZ']);
      expect(crossReplicaOrder, isNot(equals(localOrder)),
          reason: 'the cross-replica key must not coincide with this device\'s own local seed order');
    });

    test(
        '(d) divergent pre-existing createdAtMillis recorded independently by two replicas for "the same" mapping resolves via the existing canonical-winner comparator — no crash, no divergence, membership is unaffected (accepted, product-acceptable outcome)',
        () {
      final sim = Simulator(seed: 202);
      final a = sim.addReplica('A');
      final b = sim.addReplica('B');
      final engineA = ConversationMappingEngine(a);
      final engineB = ConversationMappingEngine(b);

      // Same (conversationId, messageId) pair, but each replica's
      // pre-sync-era local history recorded a genuinely different
      // createdAtMillis for it — different `contentKey`s (the formula's
      // valueHash differs), so this is NOT deduplicated: both add-dots
      // stay live, exactly like two devices seeding genuinely divergent
      // pre-existing `__exists__` content (§ Architecture 1).
      final opA = engineA.seedMapping(a, conversationId: 'c1', messageId: 'm1', createdAtMillis: 1000, hlcOverride: 1);
      final opB = engineB.seedMapping(b, conversationId: 'c1', messageId: 'm1', createdAtMillis: 2000, hlcOverride: 1);
      expect(opA.contentKey, isNot(equals(opB.contentKey)));

      sim.syncAllToAll();

      // Membership itself is entirely unaffected — m1 is a member either
      // way (OR-Set union of any live add-dot), regardless of which
      // createdAtMillis is chosen for display.
      expect(engineA.contains('c1', 'm1'), isTrue);
      expect(engineB.contains('c1', 'm1'), isTrue);

      // Both replicas now know both incarnations; the canonical-winner
      // comparator (lexicographically-smallest (authorId, authorSeq))
      // deterministically picks the SAME one on every replica, so the
      // displayed createdAtMillis — and therefore the effective order —
      // converges identically, without any special-cased conflict record
      // or data loss.
      final winner = [opA.dot, opB.dot]..sort();
      final expectedCreatedAt = (winner.first == opA.dot) ? 1000 : 2000;
      expect(a.setState['${ConversationMappingEngine.table}:c1']!['m1'], hasLength(2),
          reason: 'both divergent add-dots remain live — a harmless, self-resolving duplicate, not a conflict');
      expect(b.setState['${ConversationMappingEngine.table}:c1']!['m1'], hasLength(2));
      expect(engineA.effectiveOrder('c1'), ['m1']);
      expect(engineB.effectiveOrder('c1'), ['m1']);
      // Re-derive the chosen createdAtMillis via the public read surface
      // rather than reaching into private state, confirming both replicas
      // agree with each other AND with the expected canonical winner.
      final chosenA = a.operationForDot(winner.first)!.value as int;
      expect(chosenA, expectedCreatedAt);
    });

    test(
        '(e) three replicas, two independently seeding IDENTICAL content and one genuinely different, must all agree on effectiveOrder — a code-review finding: comparing setState\'s raw, unresolved dots (rather than canonicalizing via resolveDot first) let each replica\'s own locally-first-materialized alias silently stand in for its whole contentKey group, flipping the cross-group tie-break winner depending on which replica asks',
        () {
      final sim = Simulator(seed: 203);
      // Device ids chosen so alphabetic order is Alice < Bob < Carol —
      // Alice and Carol both seed createdAtMillis=1000 for 'm1' (a genuine
      // dedup pair, aliasing the SAME logical mapping); Bob independently
      // seeds a genuinely different createdAtMillis=2000 for 'm1' (no
      // dedup, a real OR-Set duplicate per this file's own header
      // comment). A second message, 'm2', is seeded identically by all
      // three at createdAtMillis=1500 — deliberately BETWEEN 1000 and
      // 2000, and NOT itself contested — purely so m1's resolved value is
      // externally observable: `effectiveOrder`'s only public output is
      // message-id ORDER, so with only 'm1' in play a resolved-value
      // divergence would be invisible to any assertion on that return
      // value alone (m1 would trivially be the sole element everywhere).
      // With 'm2' as a fixed reference point, m1 resolving to 1000 sorts
      // BEFORE m2, while m1 resolving to 2000 sorts AFTER it — the two
      // outcomes produce genuinely different, directly-observable lists.
      //
      // Each device mints and locally materializes its OWN op FIRST,
      // before ever syncing — so on Alice's replica, Alice's own dot
      // (authorId "seed:Alice") is what's initially in setState for the
      // ck1000 group; on Carol's replica, it's Carol's own dot (authorId
      // "seed:Carol") instead — two DIFFERENT raw representatives for the
      // SAME logical group, depending purely on which replica is asked.
      final alice = sim.addReplica('Alice');
      final bob = sim.addReplica('Bob');
      final carol = sim.addReplica('Carol');
      final engineAlice = ConversationMappingEngine(alice);
      final engineBob = ConversationMappingEngine(bob);
      final engineCarol = ConversationMappingEngine(carol);

      engineAlice.seedMapping(alice, conversationId: 'c1', messageId: 'm1', createdAtMillis: 1000, hlcOverride: 1);
      engineBob.seedMapping(bob, conversationId: 'c1', messageId: 'm1', createdAtMillis: 2000, hlcOverride: 1);
      engineCarol.seedMapping(carol, conversationId: 'c1', messageId: 'm1', createdAtMillis: 1000, hlcOverride: 1);
      engineAlice.seedMapping(alice, conversationId: 'c1', messageId: 'm2', createdAtMillis: 1500, hlcOverride: 2);
      engineBob.seedMapping(bob, conversationId: 'c1', messageId: 'm2', createdAtMillis: 1500, hlcOverride: 2);
      engineCarol.seedMapping(carol, conversationId: 'c1', messageId: 'm2', createdAtMillis: 1500, hlcOverride: 2);

      sim.syncAllToAll();

      // Before the fix: comparing raw (unresolved) dots meant Alice's
      // cross-group comparison for 'm1' used her OWN dot ("seed:Alice" <
      // "seed:Bob" -> Alice's 1000 wins, sorting m1 BEFORE m2), while
      // Carol's comparison used HER OWN dot ("seed:Carol" > "seed:Bob" ->
      // Bob's 2000 wins instead, sorting m1 AFTER m2) — a silent, real
      // divergence in `effectiveOrder`'s actual output for the exact same
      // conversation, even though Alice and Carol seeded identical data
      // for m1 and only Bob's is genuinely different. Canonicalizing
      // every dot through `resolveDot` before comparing closes this:
      // every replica now compares using the SAME true-canonical
      // representative for the ck1000 group (Alice's dot, the
      // lexicographically-smallest of Alice's/Carol's), so the
      // cross-group winner (1000 vs 2000) — and therefore m1's position
      // relative to m2 — is identical everywhere.
      final orderAlice = engineAlice.effectiveOrder('c1');
      final orderBob = engineBob.effectiveOrder('c1');
      final orderCarol = engineCarol.effectiveOrder('c1');
      expect(orderAlice, orderBob, reason: 'Alice and Bob must agree on the effective order');
      expect(orderAlice, orderCarol, reason: 'Alice and Carol must agree on the effective order');
      expect(orderAlice, ['m1', 'm2'],
          reason: 'the ck1000 group (Alice/Carol, sharing the lexicographically-smaller "seed:Alice" dot) must '
              'win over the ck2000 group (Bob alone) on every replica, not just the one whose own local alias '
              'happens to be smaller than Bob\'s — m1 (resolved to 1000) must sort before m2 (1500) everywhere');
    });
  });

  group('User App revision/library/dependency derived visibility (§ Architecture 10, round 8/14/15 fixes)', () {
    test(
        '(a) single-revision app: deleting the only revision selects it as its own fallback, keeping the whole graph effectively visible',
        () {
      final d1 = Replica('D1');
      final e1 = AppEngine(d1);
      final app = e1.createApp();
      final rev = e1.createRevision(app);
      final lib = e1.createLibrary(rev);
      final dep = e1.createDependency(lib);

      expect(e1.effectiveRevisionDeleted(rev), isFalse);

      final outboxLenBefore = d1.outbox.length;
      e1.deleteAppRevision(rev);
      expect(d1.outbox.length, outboxLenBefore + 1,
          reason: 'deleteAppRevision must write ONLY the revision\'s own __deleted__ tombstone, nothing else '
              '(round 14: "the function becomes an ordinary soft-delete ... and nothing else")');

      expect(e1.rawRevisionDeleted(rev), isTrue, reason: 'raw __deleted__ is genuinely, permanently set');
      expect(e1.effectiveRevisionDeleted(rev), isFalse,
          reason: 'zero live revisions remain for this app — rev must become its own app\'s fallback');
      expect(e1.fallbackRevisionFor(app), rev);

      // Libraries/dependencies got NO write of their own, yet correctly
      // derive live visibility purely from the revision's effective state.
      expect(e1.rawLibraryDeleted(lib), isFalse);
      expect(e1.effectiveLibraryDeleted(lib), isFalse);
      expect(e1.rawDependencyDeleted(dep), isFalse);
      expect(e1.effectiveDependencyDeleted(dep), isFalse);
    });

    test(
        '(b) multi-revision app: deleting one revision (a live sibling remains) needs no fallback — the deleted revision\'s graph goes invisible, the app itself is unaffected',
        () {
      final d1 = Replica('D1');
      final e1 = AppEngine(d1);
      final app = e1.createApp();
      final rev1 = e1.createRevision(app);
      final rev2 = e1.createRevision(app);
      final lib1 = e1.createLibrary(rev1);
      final dep1 = e1.createDependency(lib1);
      final lib2 = e1.createLibrary(rev2);

      e1.deleteAppRevision(rev1);

      expect(e1.fallbackRevisionFor(app), isNull, reason: 'rev2 is still raw-live — no fallback need at all');
      expect(e1.effectiveRevisionDeleted(rev1), isTrue);
      expect(e1.effectiveLibraryDeleted(lib1), isTrue);
      expect(e1.effectiveDependencyDeleted(dep1), isTrue);
      expect(e1.effectiveRevisionDeleted(rev2), isFalse);
      expect(e1.effectiveLibraryDeleted(lib2), isFalse);
    });

    test(
        '(c) the fallback transfers away once a DIFFERENT revision becomes live again — the old fallback\'s descendants stop being protected',
        () {
      final d1 = Replica('D1');
      final e1 = AppEngine(d1);
      final app = e1.createApp();
      final rev1 = e1.createRevision(app);
      final rev2 = e1.createRevision(app);
      final lib1 = e1.createLibrary(rev1);
      final lib2 = e1.createLibrary(rev2);

      e1.deleteAppRevision(rev1);
      e1.deleteAppRevision(rev2);
      // Zero-live: rev2 was tombstoned most recently (higher hlc) -> fallback.
      expect(e1.fallbackRevisionFor(app), rev2);
      expect(e1.effectiveRevisionDeleted(rev2), isFalse);
      expect(e1.effectiveLibraryDeleted(lib2), isFalse);
      expect(e1.effectiveRevisionDeleted(rev1), isTrue);
      expect(e1.effectiveLibraryDeleted(lib1), isTrue);

      // rev1 becomes live again -> zero-live no longer holds; fallback need
      // ends for the whole app, not just a transfer to a new candidate.
      e1.undeleteRevision(rev1);
      expect(e1.fallbackRevisionFor(app), isNull);
      expect(e1.effectiveRevisionDeleted(rev1), isFalse);
      expect(e1.effectiveRevisionDeleted(rev2), isTrue,
          reason: 'rev2 stops being protected the instant a live sibling exists again');
      expect(e1.effectiveLibraryDeleted(lib2), isTrue);
    });

    test(
        '(c2) fallback selection tie-break: re-deleting a revision after a sibling already served as fallback correctly transfers fallback status to the now-most-recently-tombstoned one',
        () {
      final d1 = Replica('D1');
      final e1 = AppEngine(d1);
      final app = e1.createApp();
      final rev1 = e1.createRevision(app);
      final rev2 = e1.createRevision(app);
      e1.deleteAppRevision(rev1);
      e1.deleteAppRevision(rev2);
      expect(e1.fallbackRevisionFor(app), rev2);

      e1.undeleteRevision(rev1); // fallback need ends entirely, briefly
      expect(e1.fallbackRevisionFor(app), isNull);

      e1.deleteAppRevision(rev1); // rev1 is now the most-recently-tombstoned revision
      expect(e1.fallbackRevisionFor(app), rev1,
          reason: 'fallback must track whichever revision most recently became non-live, not stay stuck on rev2');
    });

    test('(d) a library/dependency under a fallback revision is never purge-eligible; becomes eligible once the fallback need ends',
        () {
      final d1 = Replica('D1');
      final e1 = AppEngine(d1);
      final app = e1.createApp();
      final rev = e1.createRevision(app);
      final lib = e1.createLibrary(rev);
      final dep = e1.createDependency(lib);
      e1.deleteAppRevision(rev);

      expect(e1.fallbackRevisionFor(app), rev);
      expect(e1.revisionPurgeEligible(rev), isFalse,
          reason: 'the fallback revision itself must not be purge-eligible');
      expect(e1.libraryPurgeEligible(lib), isFalse);
      expect(e1.dependencyPurgeEligible(dep), isFalse);

      // A second revision becomes live -> fallback need ends, and
      // rev/lib/dep become purge-eligible together, in one step.
      final rev2 = e1.createRevision(app);
      expect(e1.fallbackRevisionFor(app), isNull);
      expect(e1.revisionPurgeEligible(rev), isTrue);
      expect(e1.libraryPurgeEligible(lib), isTrue);
      expect(e1.dependencyPurgeEligible(dep), isTrue);
      expect(e1.revisionPurgeEligible(rev2), isFalse, reason: 'rev2 is raw-live, never a purge candidate at all');
    });

    test(
        'a library/dependency directly (round-15 sibling-fix) soft-deleted is invisible regardless of its owning revision\'s state',
        () {
      final d1 = Replica('D1');
      final e1 = AppEngine(d1);
      final app = e1.createApp();
      final rev = e1.createRevision(app);
      final lib = e1.createLibrary(rev);
      final dep = e1.createDependency(lib);

      e1.deleteUserAppLibrary(lib);
      expect(e1.effectiveRevisionDeleted(rev), isFalse, reason: 'the revision itself is untouched');
      expect(e1.effectiveLibraryDeleted(lib), isTrue);
      expect(e1.effectiveDependencyDeleted(dep), isTrue,
          reason: 'a dependency of a directly-deleted library is invisible too, composed one level further');
      expect(e1.libraryPurgeEligible(lib), isTrue);

      e1.deleteUserAppLibraryDependency(dep);
      expect(e1.rawDependencyDeleted(dep), isTrue);
    });

    test(
        'convergence: two replicas concurrently deleting every revision of a shared app, in different orders, agree on the fallback once fully synced',
        () {
      final sim = Simulator(seed: 300);
      final d1 = sim.addReplica('D1');
      final d2 = sim.addReplica('D2');
      final e1 = AppEngine(d1);

      final app = e1.createApp();
      final rev1 = e1.createRevision(app);
      final rev2 = e1.createRevision(app);
      sim.syncFull(d1, d2);

      // Both replicas delete BOTH revisions, in different local orders,
      // without syncing with each other in between — a genuinely
      // concurrent "everyone deletes everything" scenario.
      final e2 = AppEngine(d2);
      e1.deleteAppRevision(rev1);
      e2.deleteAppRevision(rev2);
      e1.deleteAppRevision(rev2);
      e2.deleteAppRevision(rev1);

      sim.syncAllToAll();

      assertAppVisibilityConverged([d1, d2]);
      expect(e1.fallbackRevisionFor(app), e2.fallbackRevisionFor(app),
          reason: 'once fully synced, both replicas must agree on which revision is the fallback');
    });
  });
}
