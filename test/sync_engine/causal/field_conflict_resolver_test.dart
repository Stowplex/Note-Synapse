// Differential/regression replay of `test/sync_protocol/regression_test.dart`'s
// named field-conflict scenarios against the REAL, SQL-backed causal engine
// (M2.5, § Architecture 11.4) — required by the milestone brief, not
// deferred to M2.8. Every scenario below is the exact construction from the
// abstract simulator's own regression suite, replayed through
// `CausalEngine`/`FieldConflictResolver` against a real sqlite database, and
// checked against the SAME assertions the abstract test makes against
// `fieldState`/`conflictCopies`.
//
// `TestMintingDevice` (`test_minting_device.dart`) plays the abstract
// suite's OTHER replicas (`a`, `b`, `devX`, `devY`, `devZ`, ...) — pure
// operation minting, exactly mirroring `Replica`'s own minting side.
// `CausalEngine` + a real `DatabaseService` plays the abstract suite's
// receiving replica (`r`).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/field_conflict_resolver.dart';
import 'package:note_synapse/services/sync/hlc.dart';

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

  Future<void> apply(IncomingOperation op) => db.transaction((txn) => engine.apply(txn, op));

  Future<Map<String, Object?>?> fieldStateRow(String table, String id, String field) async {
    final rows = await db.query(
      'sync_field_state',
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [table, id, field],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<dynamic> fieldValue(String table, String id, String field) async {
    final row = await fieldStateRow(table, id, field);
    return row == null ? null : jsonDecode(row['valueJson'] as String);
  }

  Future<List<Map<String, Object?>>> conflictCopyRows(
    String table,
    String id,
    String field, {
    String kind = FieldConflictResolver.kindFieldConflict,
  }) {
    return db.query(
      'sync_conflict_copies',
      where: 'subjectTable = ? AND subjectId = ? AND fieldName = ? AND kind = ?',
      whereArgs: [table, id, field, kind],
    );
  }

  Future<List<dynamic>> liveConflictValues(String table, String id, String field) async {
    final rows = await conflictCopyRows(table, id, field);
    return [
      for (final r in rows)
        jsonDecode((jsonDecode(r['resolvedFieldsJson'] as String) as Map<String, dynamic>)['valueJson'] as String),
    ];
  }

  group('causal comparator — Task A motivating scenario, replayed through the field-conflict resolver', () {
    test(
        'a later edit built on an alias the editor never observed is recognized as causally descending, not concurrent',
        () async {
      final a = TestMintingDevice('A');
      final b = TestMintingDevice('B');

      final seedA = a.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 10);
      final seedB = b.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 20);

      // The receiving engine learns about both seeds first (so it knows
      // seedA<->seedB are aliases).
      await apply(seedA);
      await apply(seedB);

      // A, WITHOUT ever pulling from B, mints an ordinary edit Y — its
      // frontier dominates its own seed dot (seedA) but has no entry at all
      // for seedB's author.
      final y = a.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Y', hlcOverride: 5);
      expect(y.frontier.containsKey(seedB.dot.authorId), isFalse);

      await apply(y);

      expect(await fieldValue('note', 'n1', 'title'), 'Y');
      expect(await liveConflictValues('note', 'n1', 'title'), isEmpty,
          reason: 'Y should cleanly supersede the seed, not be filed as a spurious conflict');
    });
  });

  group('recheck-on-discovery — all three outcomes', () {
    test('case (i): stale seed initially wins, is later promoted once the missing alias is learned', () async {
      final a = TestMintingDevice('A');
      final b = TestMintingDevice('B');

      final seedA = a.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 1);
      final seedB = b.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 100);
      final y = a.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Y', hlcOverride: 2);

      await apply(seedB); // sole winner initially
      await apply(y); // loses HLC tiebreak against seedB (receiver doesn't know about seedA yet)
      expect(await fieldValue('note', 'n1', 'title'), 'X');
      expect((await conflictCopyRows('note', 'n1', 'title')).map((r) => r['id']), isNotEmpty);

      await apply(seedA); // dedup redirects seedA into seedB's class -> recheck fires
      expect(await fieldValue('note', 'n1', 'title'), 'Y', reason: 'recheck should promote Y');
      expect(await liveConflictValues('note', 'n1', 'title'), isEmpty);
    });

    test('case (ii): correct winner is proven, the now-spurious conflict copy is discarded not re-filed', () async {
      final a = TestMintingDevice('A');
      final b = TestMintingDevice('B');

      final seedA = a.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 1);
      final seedB = b.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 2);
      final y = a.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Y', hlcOverride: 50);

      await apply(y); // sole winner
      await apply(seedB); // loses HLC tiebreak against Y, filed as conflict (receiver doesn't know seedA yet)
      expect(await fieldValue('note', 'n1', 'title'), 'Y');
      expect(await liveConflictValues('note', 'n1', 'title'), contains('X'));

      await apply(seedA); // dedup fast-path redirects seedA -> recheck fires
      expect(await fieldValue('note', 'n1', 'title'), 'Y', reason: 'winner unchanged');
      expect(await liveConflictValues('note', 'n1', 'title'), isEmpty,
          reason: 'seedB is now a proven causal ancestor of Y and must be discarded, not left as a spurious conflict');
      // The now-superseded seed must still be retained internally as a
      // chainDom witness (kind=field_conflict_superseded), not physically
      // dropped -- confirms the finding-5 fix (below) is active here too,
      // not merely that the live view happens to be empty.
      final supersededRows = await conflictCopyRows(
        'note',
        'n1',
        'title',
        kind: FieldConflictResolver.kindFieldConflictSuperseded,
      );
      expect(supersededRows, isNotEmpty);
    });

    test('case (iii): genuinely concurrent values remain a retained conflict after recheck', () async {
      final a = TestMintingDevice('A');
      final b = TestMintingDevice('B');
      final c = TestMintingDevice('C');

      final seedA = a.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 1);
      final seedB = b.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 2);
      // Z is genuinely concurrent with the seed pair.
      final z = c.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Z', hlcOverride: 500);

      await apply(seedB);
      await apply(z);
      expect(await fieldValue('note', 'n1', 'title'), 'Z'); // Z has the higher HLC

      await apply(seedA); // triggers recheck
      expect(await fieldValue('note', 'n1', 'title'), 'Z', reason: 'still concurrent, HLC tiebreak unchanged');

      final conflicts = await liveConflictValues('note', 'n1', 'title');
      expect(conflicts.length, 1,
          reason: 'the seed pair collapses to one canonical representative, not two aliases');
      expect(conflicts.single, 'X', reason: 'genuinely concurrent — must remain a retained conflict, not be discarded');
    });
  });

  group('field-conflict resolution over full retained history (finding 5)', () {
    test(
        'a three-hop transitive-domination chain (X>Y>Z) must not let Z win an ordinary tie-break against X once Y is discarded',
        () async {
      final devY = TestMintingDevice('devY');
      final devZ = TestMintingDevice('devZ');
      final devX = TestMintingDevice('devX');

      final z = devZ.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Z', hlcOverride: 3);
      devY.observe(z);
      final y = devY.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Y', hlcOverride: 1);
      devX.observe(y);
      final x = devX.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 2);

      await apply(x); // sole winner
      await apply(y); // dominated by x, discarded (as a chainDom-superseded witness, not dropped)
      expect(await fieldValue('note', 'n1', 'title'), 'X');

      await apply(z); // must NOT win an ordinary tie-break against X
      expect(await fieldValue('note', 'n1', 'title'), 'X',
          reason: 'X transitively dominates Z via the (retained-but-superseded) witness Y — Z must not win a '
              'direct tie-break');
      expect(await liveConflictValues('note', 'n1', 'title'), isEmpty,
          reason: 'round 20: Z is now correctly recognized as a transitively-dominated ancestor via the '
              'singleton-witness chain X>Y>Z (chainDom), not left stranded as a stale conflict copy');
    });

    test(
        'the same three-hop chain, but the middle witness Y is itself contentKey-bearing (a seed with no '
        'duplicate alias) — the permanent alias-witness record for Y must NOT make isSingleton(Y) wrongly '
        'return false and block the chainDom pass-through',
        () async {
      // This specifically exercises field_conflict_resolver.dart's own
      // dot-deduplication fix in `groupMembersFor`: Y ends up with TWO raw
      // rows for its own dot (its superseded/live conflict-copy row AND
      // its permanent kindContentKeyAliasWitness row) once it is
      // discarded -- without deduplicating by dot before counting group
      // members, `isSingleton(Y)` would wrongly see length 2 and refuse
      // to treat Y as a valid chainDom pass-through witness, leaving Z
      // wrongly retained as a live conflict.
      final devY = TestMintingDevice('devY');
      final devZ = TestMintingDevice('devZ');
      final devX = TestMintingDevice('devX');

      final z = devZ.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Z', hlcOverride: 3);
      devY.observe(z);
      final y = devY.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'Y', hlcOverride: 1);
      devX.observe(y);
      final x = devX.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 2);

      await apply(x);
      await apply(y);
      expect(await fieldValue('note', 'n1', 'title'), 'X');

      await apply(z);
      expect(await fieldValue('note', 'n1', 'title'), 'X',
          reason: 'X transitively dominates Z via the singleton (albeit contentKey-bearing) witness Y');
      expect(await liveConflictValues('note', 'n1', 'title'), isEmpty,
          reason: 'Z must be correctly recognized as transitively dominated, not wrongly retained because Y\'s '
              'alias-witness bookkeeping made it look like a non-singleton alias group');
    });

    test('the same chain converges correctly regardless of arrival order', () async {
      for (final orderName in ['zyx', 'yzx', 'yxz', 'xyz', 'xzy', 'zxy']) {
        // Fresh devices AND a fresh receiving database per order, exactly
        // like the abstract test's fresh `Replica('R-...')` per order.
        final devY = TestMintingDevice('devY');
        final devZ = TestMintingDevice('devZ');
        final devX = TestMintingDevice('devX');
        final z = devZ.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Z', hlcOverride: 3);
        devY.observe(z);
        final y = devY.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Y', hlcOverride: 1);
        devX.observe(y);
        final x = devX.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'X', hlcOverride: 2);

        final orderedOps = {'x': x, 'y': y, 'z': z};
        final freshDb = DatabaseService.createNew();
        final freshConn = await freshDb.database;
        final freshEngine = CausalEngine();
        for (final letter in orderName.split('')) {
          final op = orderedOps[letter]!;
          await freshConn.transaction((txn) => freshEngine.apply(txn, op));
        }
        final rows = await freshConn.query(
          'sync_field_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: ['note', 'n1', 'title'],
        );
        expect(jsonDecode(rows.single['valueJson'] as String), 'X', reason: 'order $orderName must converge to X');
        await freshDb.close();
      }
    });

    test(
        'a genuine pairwise 3-cycle formed by an HLC tie broken by authorId converges to the same, order-independent winner',
        () async {
      for (final orderName in ['abc', 'acb', 'bac', 'bca', 'cab', 'cba']) {
        final devA = TestMintingDevice('AuthA');
        final devB = TestMintingDevice('AuthB');
        final devC = TestMintingDevice('AuthC');
        final a = devA.mintField(table: 'note', entityId: 'n2', field: 'title', value: 'A', hlcOverride: 5);
        devB.observe(a); // B observes A before minting -> B dominates A
        final b = devB.mintField(table: 'note', entityId: 'n2', field: 'title', value: 'B', hlcOverride: 3);
        final c = devC.mintField(table: 'note', entityId: 'n2', field: 'title', value: 'C', hlcOverride: 3); // ties B's hlc

        final orderedOps = {'a': a, 'b': b, 'c': c};
        final freshDb = DatabaseService.createNew();
        final freshConn = await freshDb.database;
        final freshEngine = CausalEngine();
        for (final letter in orderName.split('')) {
          final op = orderedOps[letter]!;
          await freshConn.transaction((txn) => freshEngine.apply(txn, op));
        }
        final rows = await freshConn.query(
          'sync_field_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: ['note', 'n2', 'title'],
        );
        expect(jsonDecode(rows.single['valueJson'] as String), 'C',
            reason: 'order $orderName must converge to C (the maximal-set + authorId-tiebreak winner), not A or B');
        await freshDb.close();
      }
    });
  });

  group('round 20 — mutual/cyclic group domination', () {
    test(
        'two contentKey-alias groups that mutually "dominate" each other via their unioned frontiers must never silently discard either side',
        () async {
      final gb1 = TestMintingDevice('GB1');
      final b1 = gb1.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'B1val', contentKey: 'ckB', hlcOverride: 5);

      final ga1 = TestMintingDevice('GA1');
      final a1 = ga1.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'A1val', contentKey: 'ckA', hlcOverride: 5);

      final ga2 = TestMintingDevice('GA2');
      ga2.observe(b1); // GA2 observed B1 before minting -> union(A) dominates B1
      final a2 = ga2.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'A2val', contentKey: 'ckA', hlcOverride: 6);

      final gb2 = TestMintingDevice('GB2');
      gb2.observe(a1); // GB2 observed A1 before minting -> union(B) dominates A1
      final b2 = gb2.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'B2val', contentKey: 'ckB', hlcOverride: 10);

      for (final op in [b1, a1, a2, b2]) {
        await apply(op);
      }

      // B1's hlc (10) beats A1's hlc (5), so group B wins the tie-break —
      // but group A must be RETAINED, never silently discarded, since the
      // "domination" between the two groups is genuinely mutual.
      expect(await fieldValue('note', 'n1', 'title'), 'B1val');
      final conflicts = await liveConflictValues('note', 'n1', 'title');
      expect(conflicts, isNotEmpty,
          reason: 'group A must survive as a genuine conflict copy, not be silently discarded as a "proven ancestor"');
      expect(conflicts, contains('A1val'));
    });

    test('the same construction converges identically under a different arrival order', () async {
      final gb1 = TestMintingDevice('GB1');
      final b1 = gb1.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'B1val', contentKey: 'ckB', hlcOverride: 5);
      final ga1 = TestMintingDevice('GA1');
      final a1 = ga1.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'A1val', contentKey: 'ckA', hlcOverride: 5);
      final ga2 = TestMintingDevice('GA2');
      ga2.observe(b1);
      final a2 = ga2.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'A2val', contentKey: 'ckA', hlcOverride: 6);
      final gb2 = TestMintingDevice('GB2');
      gb2.observe(a1);
      final b2 = gb2.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'B2val', contentKey: 'ckB', hlcOverride: 10);

      for (final op in [a2, b2, a1, b1]) {
        await apply(op);
      }
      expect(await fieldValue('note', 'n1', 'title'), 'B1val');
      expect(await liveConflictValues('note', 'n1', 'title'), contains('A1val'));
    });
  });

  group('hand-constructed SCC/chainDom correctness — W/P/Q counterexample', () {
    test(
        'a winner that directly dominates one group of a mutually-dominating pair must NOT drag the other group '
        'down with it — chainDom is blocked by the non-singleton pass-through', () async {
      // W directly dominates group P (by having observed P1 before
      // minting). P and Q mutually dominate each other for reasons
      // entirely independent of W (P2 observed Q1; Q2 observed P1). W never
      // observed anything about Q directly. The naive "discard every
      // member of a dominated SCC" rule round 20 replaced would wrongly
      // discard BOTH P and Q once {P,Q} is found dominated by {W} — the
      // corrected chainDom rule must discard only P (direct edge) and
      // retain Q (only reachable via P, a non-singleton pass-through).
      final pdev1 = TestMintingDevice('Pdev1');
      final p1 = pdev1.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'Pval1', contentKey: 'ckP', hlcOverride: 1);

      final qdev1 = TestMintingDevice('Qdev1');
      final q1 = qdev1.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'Qval1', contentKey: 'ckQ', hlcOverride: 1);

      final pdev2 = TestMintingDevice('Pdev2');
      pdev2.observe(q1); // P2's frontier dominates Q1 -> union(P) dominates Q
      final p2 = pdev2.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'Pval2', contentKey: 'ckP', hlcOverride: 2);

      final qdev2 = TestMintingDevice('Qdev2');
      qdev2.observe(p1); // Q2's frontier dominates P1 -> union(Q) dominates P
      final q2 = qdev2.mintField(
          table: 'note', entityId: 'n1', field: 'title', value: 'Qval2', contentKey: 'ckQ', hlcOverride: 2);

      final wdev = TestMintingDevice('Wdev');
      wdev.observe(p1); // W directly dominates P1 -- NOT Q at all
      final w = wdev.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'Wval', hlcOverride: 3);

      for (final op in [p1, q1, p2, q2, w]) {
        await apply(op);
      }

      expect(await fieldValue('note', 'n1', 'title'), 'Wval');
      final conflicts = await liveConflictValues('note', 'n1', 'title');
      expect(conflicts, contains('Qval1'),
          reason: 'Q must be retained -- its only path from W runs through the non-singleton group P');
      expect(conflicts, isNot(contains('Pval1')));
      expect(conflicts, isNot(contains('Pval2')));
      expect(conflicts.length, 1, reason: 'exactly the Q group survives, collapsed to its canonical representative');
    });
  });

  group('ordinary, non-conflicting causal succession (sanity)', () {
    test('a plain later edit with no competing candidates cleanly replaces the winner, no conflicts filed', () async {
      final dev = TestMintingDevice('D1');
      final first = dev.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'first');
      await apply(first);
      expect(await fieldValue('note', 'n1', 'title'), 'first');

      final second = dev.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'second');
      await apply(second);
      expect(await fieldValue('note', 'n1', 'title'), 'second');
      expect(await liveConflictValues('note', 'n1', 'title'), isEmpty);
    });

    test('two genuinely concurrent, unrelated edits are both retained (HLC tiebreak decides the winner)', () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      final a = devA.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'A', hlcOverride: 1);
      final b = devB.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'B', hlcOverride: 2);

      await apply(a);
      await apply(b);
      expect(await fieldValue('note', 'n1', 'title'), 'B', reason: 'higher hlc wins');
      expect(await liveConflictValues('note', 'n1', 'title'), contains('A'));
    });
  });

  group('__exists__ operations use the ordinary field path with no special-casing', () {
    test('an __exists__ candidate resolves through the same recompute machinery as a field op', () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      final a = devA.mintField(
          table: 'note', entityId: 'n1', field: existsFieldSentinel, value: true, hlcOverride: 1);
      final b = devB.mintField(
          table: 'note', entityId: 'n1', field: existsFieldSentinel, value: true, hlcOverride: 2);
      await apply(IncomingOperation(
        dot: a.dot,
        hlc: a.hlc,
        contentKey: a.contentKey,
        kind: '__exists__',
        entityTable: a.entityTable,
        entityId: a.entityId,
        fieldName: existsFieldSentinel,
        valueJson: a.valueJson,
        frontier: a.frontier,
      ));
      await apply(IncomingOperation(
        dot: b.dot,
        hlc: b.hlc,
        contentKey: b.contentKey,
        kind: '__exists__',
        entityTable: b.entityTable,
        entityId: b.entityId,
        fieldName: existsFieldSentinel,
        valueJson: b.valueJson,
        frontier: b.frontier,
      ));
      final row = await fieldStateRow('note', 'n1', existsFieldSentinel);
      expect(row, isNotNull);
      expect(row!['authorId'], 'B', reason: 'B has the higher hlc');
    });
  });

  group('idempotent re-apply', () {
    test('applying the exact same contentKey-bearing operation twice is a pure no-op', () async {
      final dev = TestMintingDevice('A');
      final seed = dev.mintSeed(table: 'note', entityId: 'n1', field: 'title', value: 'X');
      await apply(seed);
      final before = await fieldStateRow('note', 'n1', 'title');
      final result = await db.transaction((txn) => engine.apply(txn, seed));
      final after = await fieldStateRow('note', 'n1', 'title');
      expect(after, before);
      expect(result.fieldRecompute, isNull, reason: 'already-processed contentKey -> pure no-op, nothing recomputed');
    });
  });

  group('Hlc plumbing sanity', () {
    test('Hlc(wallMs, 0) round-trips through sync_field_state exactly as stamped', () async {
      final dev = TestMintingDevice('A');
      final op = dev.mintField(table: 'note', entityId: 'n1', field: 'title', value: 'v', hlcOverride: 42);
      await apply(op);
      final row = await fieldStateRow('note', 'n1', 'title');
      expect(Hlc.parse(row!['hlc'] as String), const Hlc(42, 0));
    });
  });
}
