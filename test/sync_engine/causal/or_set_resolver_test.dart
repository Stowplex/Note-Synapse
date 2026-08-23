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

  // M2.13, review round 3 (finding F-B). `Hlc.zero`-stamped recessive seeds
  // were introduced so a post-reset re-seed LOSES rather than wins — but that
  // reaches only field conflicts, since this resolver is add-wins plus
  // `contentKey` dedup and never reads the HLC. So a reset re-minted every
  // live membership under a brand-new GENESIS dot, the peer's already-
  // published `set_remove` targeting the OLD dot parked forever, and a tag
  // assignment the user had deliberately removed came back on BOTH devices.
  //
  // Each test below is paired with a control that must keep the pre-existing
  // add-wins behaviour, so the fix cannot pass by simply weakening removal.
  group('set_remove — recessive (post-reset) adds are superseded', () {
    const recessiveHlc = 0; // `Hlc.zero`, what SeedScanner stamps post-reset.

    test('a remove naming an unseen dot removes a member whose only live dot is recessive', () async {
      final reseeded = TestMintingDevice('A-after-reset');
      final peer = TestMintingDevice('B');

      // The reset device re-seeds the membership: fresh GENESIS dot, HLC 0.
      await apply(reseeded.mintSetAdd(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        contentKey: 'genesis:n1:tag1',
        authorNamespace: 'seed:A-after-reset',
        hlcOverride: recessiveHlc,
      ));
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), hasLength(1));

      // The peer's removal targets the PRE-reset dot, which this replica has
      // no record of — before the fix this parked in `missing_referenced_dot`
      // and the membership stayed live forever.
      final result = await apply(peer.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [const Dot('A-before-reset', 7)],
      ));

      expect(result.setRemoveResult!.blocked, isFalse,
          reason: 'the removal is applied, not parked: nothing can ever arrive to clear that queue entry');
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), isEmpty);
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
          reason: 'OR-Set add-wins is untouched outside a reset — no ordinary path ever stamps Hlc.zero');
    });

    test('CONTROL: a genuine concurrent re-add after the reset keeps the member live', () async {
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
      // A real user action after the reset drains through the ordinary path
      // with a generated HLC — so the member has a non-recessive live dot.
      await apply(reseeded.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1'));

      final result = await apply(peer.mintSetRemove(
        table: 'notes',
        entityId: 'n1',
        memberUuid: 'tag1',
        targetDots: [const Dot('A-before-reset', 7)],
      ));

      expect(result.setRemoveResult!.blocked, isTrue);
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), isNotEmpty,
          reason: 'the rule fires only when EVERY live dot is a re-statement; a real re-add must still beat '
              'a remove that never observed it');
    });

    test('a remove that does resolve is unaffected by the recessive branch', () async {
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
      expect(await liveDots('notes', 'n1', 'members', 'tag1'), isEmpty);
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
