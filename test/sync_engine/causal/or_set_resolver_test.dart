// Tests for `or_set_resolver.dart` — OR-Set `set_add`/`set_remove`
// resolution against `sync_set_state`, including `contentKey` dedup reuse
// and `missing_referenced_dot` detection/reporting (M2.5, § Architecture
// 11.4). Exercised through `CausalEngine.apply` (the real dispatch path a
// future pull loop would use) plus `TestMintingDevice` for realistic
// dot/frontier construction.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/content_key_dedup.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/causal/dot_redirect_resolver.dart';
import 'package:note_synapse/services/sync/causal/or_set_resolver.dart';

import 'test_minting_device.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;
  late CausalEngine engine;

  setUp(() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
    engine = CausalEngine();
  });

  tearDown(() async {
    await databaseService.close();
  });

  Future<ApplyResult> apply(IncomingOperation op) => db.transaction((txn) => engine.apply(txn, op));

  Future<List<Map<String, Object?>>> liveDots(String table, String id, String field, String member) {
    return db.query(
      'sync_set_state',
      where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
      whereArgs: [table, id, field, member],
    );
  }

  group('set_add — no contentKey (ordinary local add)', () {
    test('materializes a live row', () async {
      final dev = TestMintingDevice('A');
      final op = dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      final result = await apply(op);
      expect(result.setAddResult!.outcome, SetAddOutcome.materialized);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), hasLength(1));
    });

    test('two different devices adding the same member both materialize as independent OR-Set dots', () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      await apply(devA.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1'));
      await apply(devB.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1'));
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), hasLength(2),
          reason: 'no contentKey -> no dedup -> genuine OR-Set concurrent-add duplication, both retained');
    });

    test('re-applying the exact same dot is idempotent (no duplicate row, no PK violation)', () async {
      final dev = TestMintingDevice('A');
      final op = dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      await apply(op);
      await apply(op);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), hasLength(1));
    });
  });

  group('set_add — with contentKey (seed/external-edit dedup)', () {
    test('the first-seen op materializes; a later duplicate is dedup-skipped, no second row', () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      final first = devA.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:A');
      final dup = devB.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:B');

      final r1 = await apply(first);
      expect(r1.setAddResult!.outcome, SetAddOutcome.materialized);
      final r2 = await apply(dup);
      expect(r2.setAddResult!.outcome, SetAddOutcome.dedupSkipped);

      expect(await liveDots('conversations', 'c1', 'members', 'm1'), hasLength(1),
          reason: 'only the first-seen dot is ever materialized -- the faithful-port behavior documented in '
              'or_set_resolver.dart (canonical bookkeeping still converges via sync_dedup_index/sync_dot_redirects, '
              'but the live row does not move)');
    });

    test('a canonical swap (a lexicographically-smaller dot arrives later) still does not move the materialized row',
        () async {
      final devB = TestMintingDevice('B'); // 'seed:B' > 'seed:A'
      final devA = TestMintingDevice('A');
      final first = devB.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:B');
      final smaller = devA.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:A');

      await apply(first); // materializes under seed:B
      final r2 = await apply(smaller);
      expect(r2.setAddResult!.outcome, SetAddOutcome.dedupSkipped);
      expect(r2.setAddResult!.canonicalDot, Dot('seed:A', 1), reason: 'canonical index correctly swapped to the smaller dot');

      final rows = await liveDots('conversations', 'c1', 'members', 'm1');
      expect(rows, hasLength(1));
      expect(rows.single['authorId'], 'seed:B', reason: 'the materialized row stays at the first-observed dot');
    });

    test('idempotent re-apply of an already-redirected dot is a pure no-op', () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      final first = devA.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:A');
      final dup = devB.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:B');
      await apply(first);
      await apply(dup);
      final r3 = await apply(dup);
      expect(r3.setAddResult!.outcome, SetAddOutcome.alreadyProcessed);
      expect(await liveDots('conversations', 'c1', 'members', 'm1'), hasLength(1));
    });
  });

  group('set_remove — ordinary case', () {
    test('removes the live row for a directly-targeted dot', () async {
      final dev = TestMintingDevice('A');
      final add = dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      await apply(add);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), hasLength(1));

      final remove = dev.mintSetRemove(table: 'notes', entityId: 'n1', memberUuid: 'tag1', targetDots: [add.dot]);
      final result = await apply(remove);
      expect(result.setRemoveResult!.blocked, isFalse);
      expect(result.setRemoveResult!.appliedTargets, [add.dot]);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), isEmpty);
    });

    test('removes only the specifically-targeted dot, leaving other concurrent add-dots for the same member live',
        () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      final addA = devA.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      final addB = devB.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      await apply(addA);
      await apply(addB);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), hasLength(2));

      final remove = devA.mintSetRemove(table: 'notes', entityId: 'n1', memberUuid: 'tag1', targetDots: [addA.dot]);
      await apply(remove);

      final remaining = await liveDots('notes', 'n1', 'members', 'tag1');
      expect(remaining, hasLength(1));
      expect(remaining.single['authorId'], 'B');
    });

    test('resolves the target through sync_dot_redirects before matching — removing via a NON-canonical alias '
        'dot still finds and deletes the (first-observed) materialized row', () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      final first = devA.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:A');
      final dup = devB.mintSetAdd(
          table: 'conversations', entityId: 'c1', memberUuid: 'm1', contentKey: 'ck1', authorNamespace: 'seed:B');
      await apply(first); // materializes under seed:A
      await apply(dup); // dedup-skipped, redirected to seed:A

      // A remove referencing the NON-canonical alias's dot (seed:B) — which
      // was never itself materialized — must still resolve (via
      // sync_dot_redirects) to the live seed:A row and remove it.
      final remove = devA.mintSetRemove(
        table: 'conversations',
        entityId: 'c1',
        memberUuid: 'm1',
        targetDots: [dup.dot],
      );
      final result = await apply(remove);
      expect(result.setRemoveResult!.blocked, isFalse);
      expect(await liveDots('conversations', 'c1', 'members', 'm1'), isEmpty);
    });
  });

  group('set_remove — missing_referenced_dot detection', () {
    test('a remove targeting a dot never observed at all is reported as blocked, not silently dropped', () async {
      final dev = TestMintingDevice('A');
      final neverObserved = Dot('someOtherDevice', 7);
      final remove = dev.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [neverObserved],
      );
      final result = await apply(remove);
      expect(result.setRemoveResult!.blocked, isTrue);
      expect(result.setRemoveResult!.missingTargets, [neverObserved]);
      expect(result.setRemoveResult!.appliedTargets, isEmpty);
    });

    test('a remove with multiple targets applies whichever are found and reports only the missing ones', () async {
      final devA = TestMintingDevice('A');
      final addA = devA.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      await apply(addA);

      final neverObserved = Dot('someOtherDevice', 7);
      final remove = devA.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [addA.dot, neverObserved],
      );
      final result = await apply(remove);
      expect(result.setRemoveResult!.blocked, isTrue);
      expect(result.setRemoveResult!.appliedTargets, [addA.dot]);
      expect(result.setRemoveResult!.missingTargets, [neverObserved]);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), isEmpty,
          reason: 'the found target is still removed even though the operation as a whole is reported as blocked');
    });

    test(
        'disclosed limitation: a duplicate remove of an already-removed dot is ALSO reported as blocked (cannot be '
        'distinguished from "never observed" with this milestone\'s schema — see or_set_resolver.dart\'s doc comment)',
        () async {
      final dev = TestMintingDevice('A');
      final add = dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      await apply(add);
      final remove = dev.mintSetRemove(table: 'notes', entityId: 'n1', memberUuid: 'tag1', targetDots: [add.dot]);
      await apply(remove); // first remove: applied normally
      final secondResult = await apply(remove); // idempotent re-delivery of the SAME remove op
      expect(secondResult.setRemoveResult!.blocked, isTrue,
          reason: 'documented, safe-direction limitation: no live row remains to match against, and this schema '
              'has no permanent add-dot ledger to disambiguate "already removed" from "never observed"');
    });
  });

  // =====================================================================
  // M2.13, review round 5 — the post-reset membership question, and why
  // this resolver answers it with ORDINARY add-wins rather than with a
  // special rule.
  // =====================================================================
  //
  // **History, because the shape of the mistake is the useful part.**
  // Round 3 introduced `Hlc.zero` recessive seeds so a post-reset re-seed
  // LOSES rather than wins. That reaches only field conflicts: this
  // resolver is add-wins plus `contentKey` dedup and never reads an HLC.
  // Round 4 tried to extend the mechanism here with an explicit rule — "a
  // `set_remove` whose targets do not resolve supersedes a member whose
  // live add-dots are all recessive" — aimed at the case where a reset
  // re-mints a membership the peer had deliberately removed.
  //
  // **Round 5 removed that rule.** It was defective at the root, not at the
  // edges, and the first test below is the reproduction: both of its
  // conjuncts were predicates over `sync_set_state` *as it stands when the
  // remove is processed*, so add-then-remove and remove-then-add left
  // different states. Nothing constrains delivery order (`listDeviceLogIds`
  // is unordered), so two replicas holding the identical operation set
  // ended up permanently disagreeing about whether the membership exists.
  // A convergent surprise beats a non-convergent mechanism, so the rule is
  // gone and the surprise is pinned below as expected behaviour.
  //
  // See `or_set_resolver.dart`'s "post-reset re-add" section and
  // `dataset_reset.dart`'s round-5 correction for the full argument,
  // including the two further defects (the queue sweep could never retry
  // the parked remove, and the rule did not fire at all in the
  // `deviceLogDiverged` state, which is one of the two states a reset is
  // actually offered in).
  group('set_remove vs. a post-reset re-add (M2.13 round 5)', () {
    const recessiveHlc = 0; // `Hlc.zero`, what SeedScanner stamps post-reset.

    /// One independent replica: its own database, its own engine.
    Future<(DatabaseService, Database)> freshReplica() async {
      final service = DatabaseService.createNew();
      addTearDown(service.close);
      return (service, await service.database);
    }

    Future<void> applyTo(Database target, IncomingOperation op) =>
        target.transaction((txn) => engine.apply(txn, op));

    /// The live add-dots for the member, as a comparable, order-independent
    /// value — this is what "the two replicas agree" means concretely.
    Future<Set<String>> liveDotSet(Database target) async {
      final rows = await target.query(
        'sync_set_state',
        columns: const ['authorId', 'authorSeq'],
        where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
        whereArgs: ['notes', 'n1', 'members', 'tag1'],
      );
      return {for (final r in rows) '${r['authorId']}#${r['authorSeq']}'};
    }

    test(
        'F1: the same operation set delivered in either order leaves the two replicas in the SAME state '
        '(the round-4 rule made this diverge permanently)', () async {
      // One operation set, minted once, so the two replicas genuinely see
      // identical operations and only the ORDER differs.
      final reseeded = TestMintingDevice('A-after-reset');
      final peer = TestMintingDevice('B');
      final reseedAdd = reseeded.mintSetAdd(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        contentKey: 'genesis:n1:tag1',
        authorNamespace: 'seed:A-after-reset',
        hlcOverride: recessiveHlc,
      );
      final remove = peer.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [const Dot('A-before-reset', 7)],
      );

      final (_, addFirst) = await freshReplica();
      await applyTo(addFirst, reseedAdd);
      await applyTo(addFirst, remove);

      final (_, removeFirst) = await freshReplica();
      await applyTo(removeFirst, remove);
      await applyTo(removeFirst, reseedAdd);

      expect(
        await liveDotSet(addFirst),
        await liveDotSet(removeFirst),
        reason: 'convergence is not negotiable: nothing constrains the order in which a replica pulls a '
            'peer log versus completes its own re-seed, so a rule whose predicate reads the CURRENT '
            'sync_set_state leaves two replicas permanently disagreeing about a tag assignment',
      );
    });

    test(
        'DISCLOSED RESIDUAL, pinned deliberately: a post-reset re-add resurrects a membership the peer '
        'had removed — and that is the CORRECT, convergent outcome, not a bug to be fixed here', () async {
      final reseeded = TestMintingDevice('A-after-reset');
      final peer = TestMintingDevice('B');

      await apply(reseeded.mintSetAdd(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        contentKey: 'genesis:n1:tag1',
        authorNamespace: 'seed:A-after-reset',
        hlcOverride: recessiveHlc,
      ));

      final result = await apply(peer.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [const Dot('A-before-reset', 7)],
      ));

      // ── READ THIS BEFORE CHANGING THE EXPECTATION ────────────────────
      // The membership staying live here is ordinary OR-Set add-wins: the
      // resetting device is genuinely re-ASSERTING the membership under a
      // brand-new dot, and the peer's remove observed only the retired dot.
      // Round 4 tried to special-case it and produced a non-convergent
      // engine (see the test above). Making this membership disappear again
      // requires a durable ledger of applied removes, which this schema does
      // not have — `SetRemoveResult.missingTargets`' own doc comment states
      // that absence. Anything short of that ledger reintroduces an
      // order-dependent predicate. If you are here to "fix" this, the fix is
      // a schema, not a branch in `applySetRemove`.
      expect(
        result.setRemoveResult!.blocked,
        isTrue,
        reason: 'the remove names a dot this replica has never observed; reporting it as blocked is the '
            'conservative direction the schema can actually support',
      );
      expect(
        await liveDots('notes', 'n1', 'members', 'tag1'),
        hasLength(1),
        reason: 'DISCLOSED, CONVERGENT residual (M2.13 round 5): every replica sees the same re-add and '
            'applies the same add-wins rule, so nobody diverges and nothing is lost — a membership '
            'reappears, which is a surprise, not a corruption',
      );
    });

    test(
        'F3: the deviceLogDiverged shape — a retired ORDINARY add, a recessive re-seed of the same '
        'member, and the peer\'s remove — converges under either delivery order', () async {
      // The state a reset against a LIVE dataset actually produces: the
      // device re-pulls its own retired log (by design), so the retired
      // ordinary add-dot is live alongside the GENESIS-keyed re-seed. They
      // do NOT dedup — an ordinary post-trigger `set_add` carries no
      // `contentKey` at all.
      final retired = TestMintingDevice('A-before-reset');
      final reseeded = TestMintingDevice('A-after-reset');
      final peer = TestMintingDevice('B');

      final retiredAdd =
          retired.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
      final reseedAdd = reseeded.mintSetAdd(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        contentKey: 'genesis:n1:tag1',
        authorNamespace: 'seed:A-after-reset',
        hlcOverride: recessiveHlc,
      );
      final remove = peer.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [retiredAdd.dot],
      );

      // Each replica ends its round the way `pull_phase.dart` does: one
      // replay of the parked `set_remove`. That sweep is what makes the
      // reverse order converge — a remove that arrives BEFORE the add it
      // targets is reported `blocked`, parked as `missing_referenced_dot`,
      // and retried once the add-dot is observed. (On the forward replica
      // the replay finds nothing left to match and changes nothing, which is
      // the ordinary idempotent-redelivery case two groups above.)
      Future<void> deliver(Database target, List<IncomingOperation> ops) async {
        for (final op in ops) {
          await applyTo(target, op);
        }
        await applyTo(target, remove); // the missing_referenced_dot sweep
      }

      final (_, forward) = await freshReplica();
      await deliver(forward, [retiredAdd, reseedAdd, remove]);

      final (_, reversed) = await freshReplica();
      await deliver(reversed, [remove, reseedAdd, retiredAdd]);

      expect(
        await liveDotSet(forward),
        await liveDotSet(reversed),
        reason: 'the two devices in a post-reset session see these three operations in whichever order '
            'their pulls happen to land; they must still agree afterwards',
      );
      expect(
        await liveDotSet(forward),
        {'${reseedAdd.dot.authorId}#${reseedAdd.dot.authorSeq}'},
        reason: 'the targeted retired dot is removed; the re-asserted one survives — the residual above, '
            'in the state the reset is actually offered in',
      );
    });

    test('CONTROL: an ordinary (non-recessive) live add still wins over a remove that never saw it', () async {
      final devA = TestMintingDevice('A');
      final peer = TestMintingDevice('B');

      await apply(devA.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1'));

      final result = await apply(peer.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [const Dot('C', 3)],
      ));

      expect(result.setRemoveResult!.blocked, isTrue);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), hasLength(1),
          reason: 'OR-Set add-wins, unchanged — the reference behaviour the round-4 rule departed from');
    });

    test('CONTROL: a remove whose target DOES resolve still removes the recessive re-seed\'s own dot',
        () async {
      final reseeded = TestMintingDevice('A-after-reset');
      final peer = TestMintingDevice('B');

      final add = reseeded.mintSetAdd(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        contentKey: 'genesis:n1:tag1',
        authorNamespace: 'seed:A-after-reset',
        hlcOverride: recessiveHlc,
      );
      await apply(add);

      final result = await apply(peer.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [add.dot],
      ));

      expect(result.setRemoveResult!.blocked, isFalse);
      expect(result.setRemoveResult!.appliedTargets, hasLength(1));
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), isEmpty,
          reason: 'a recessive HLC is not a marker of any kind here — a resolved target removes the row '
              'exactly as it does for any other add');
    });
  });

  group('setContains helper', () {
    test('reflects live membership state directly', () async {
      const resolver = OrSetResolver(ContentKeyDedupEngine(), DotRedirectResolver());
      final dev = TestMintingDevice('A');
      expect(await resolver.setContains(db, entityTable: 'notes', entityId: 'n1', fieldName: 'members', memberUuid: 'tag1'),
          isFalse);
      await apply(dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1'));
      expect(await resolver.setContains(db, entityTable: 'notes', entityId: 'n1', fieldName: 'members', memberUuid: 'tag1'),
          isTrue);
    });
  });
}
