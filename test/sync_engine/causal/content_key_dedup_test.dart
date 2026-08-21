// Tests for `content_key_dedup.dart` — the `contentKey`-based
// dedup/canonical-winner/redirect algorithm against `sync_dedup_index`/
// `sync_dot_redirects` (M2.5, § Architecture 11.4, round 8/9/14 fixes).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/content_key_dedup.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/causal/dot_redirect_resolver.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;
  const dedup = ContentKeyDedupEngine();
  const redirects = DotRedirectResolver();

  setUp(() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
  });

  tearDown(() async {
    await databaseService.close();
  });

  group('first-seen', () {
    test('the first dot observed for a contentKey becomes canonical', () async {
      final dot = Dot('seed:A', 1);
      final result = await dedup.process(db, contentKey: 'ck1', dot: dot);
      expect(result.outcome, DedupOutcome.firstSeen);
      expect(result.canonicalDot, dot);
      expect(result.skipMaterialize, isFalse);
      expect(result.recheckNeeded, isFalse);

      final rows = await db.query('sync_dedup_index', where: 'contentKey = ?', whereArgs: ['ck1']);
      expect(rows, hasLength(1));
      expect(rows.single['canonicalAuthorId'], 'seed:A');
      expect(rows.single['canonicalAuthorSeq'], 1);
    });
  });

  group('non-canonical duplicate (existing canonical stays smaller)', () {
    test('a lexicographically-larger dot is redirected to the existing canonical', () async {
      final smaller = Dot('seed:A', 1);
      final larger = Dot('seed:B', 1);
      await dedup.process(db, contentKey: 'ck1', dot: smaller);
      final result = await dedup.process(db, contentKey: 'ck1', dot: larger);

      expect(result.outcome, DedupOutcome.redirectedNonCanonical);
      expect(result.canonicalDot, smaller);
      expect(result.skipMaterialize, isTrue);
      expect(result.recheckNeeded, isTrue);

      expect(await redirects.resolveDot(db, larger), smaller);
      // Canonical index itself is unchanged.
      final canonicalRows = await db.query('sync_dedup_index', where: 'contentKey = ?', whereArgs: ['ck1']);
      expect(canonicalRows.single['canonicalAuthorId'], 'seed:A');
    });
  });

  group('canonical swap', () {
    test('a lexicographically-smaller dot arriving later becomes the new canonical', () async {
      final larger = Dot('seed:B', 1);
      final smaller = Dot('seed:A', 1);
      await dedup.process(db, contentKey: 'ck1', dot: larger); // first-seen, becomes canonical
      final result = await dedup.process(db, contentKey: 'ck1', dot: smaller);

      expect(result.outcome, DedupOutcome.canonicalSwapped);
      expect(result.canonicalDot, smaller);
      expect(result.skipMaterialize, isTrue);
      expect(result.recheckNeeded, isTrue);

      // The OLD canonical (larger) now redirects to the NEW one (smaller).
      expect(await redirects.resolveDot(db, larger), smaller);
      final canonicalRows = await db.query('sync_dedup_index', where: 'contentKey = ?', whereArgs: ['ck1']);
      expect(canonicalRows.single['canonicalAuthorId'], 'seed:A');
    });

    test('a THIRD, even smaller dot triggers a second swap; a dot redirected to the OLD canonical still '
        'resolves transitively to the newest one', () async {
      final b = Dot('seed:B', 1);
      final a = Dot('seed:A', 1); // smaller than B
      // '0' (ASCII 48) sorts before 'A' (ASCII 65) -- an explicitly
      // smaller author id for the second swap, rather than relying on
      // string-length intuition (e.g. "AAA" > "A" lexicographically).
      final zero = Dot('seed:0', 1);

      await dedup.process(db, contentKey: 'ck1', dot: b); // canonical = B
      await dedup.process(db, contentKey: 'ck1', dot: a); // canonical swaps to A; B -> A
      final result = await dedup.process(db, contentKey: 'ck1', dot: zero); // canonical swaps to '0'; A -> '0'

      expect(result.outcome, DedupOutcome.canonicalSwapped);
      expect(result.canonicalDot, zero);

      // B's redirect entry is STALE (still points at A, one hop) -- must
      // resolve transitively through A -> zero.
      expect(await redirects.resolveDot(db, b), zero);
      expect(await redirects.resolveDot(db, a), zero);
      expect(await redirects.resolveDot(db, zero), zero);
    });
  });

  group('idempotent re-apply', () {
    test('re-processing the current canonical dot itself is a pure no-op', () async {
      final dot = Dot('seed:A', 1);
      await dedup.process(db, contentKey: 'ck1', dot: dot);
      final result = await dedup.process(db, contentKey: 'ck1', dot: dot);
      expect(result.outcome, DedupOutcome.alreadyProcessed);
      expect(result.skipMaterialize, isTrue);
      expect(result.recheckNeeded, isFalse);
    });

    test('re-processing an already-redirected non-canonical dot is a pure no-op, not a re-recorded redirect', () async {
      final smaller = Dot('seed:A', 1);
      final larger = Dot('seed:B', 1);
      await dedup.process(db, contentKey: 'ck1', dot: smaller);
      await dedup.process(db, contentKey: 'ck1', dot: larger);
      final result = await dedup.process(db, contentKey: 'ck1', dot: larger);
      expect(result.outcome, DedupOutcome.alreadyProcessed);
      expect(result.canonicalDot, smaller);

      final redirectRows = await db.query('sync_dot_redirects');
      expect(redirectRows, hasLength(1), reason: 'no duplicate redirect row was written');
    });
  });

  group('independent contentKeys never interact', () {
    test('two different contentKeys get independent canonical dots', () async {
      final dotA = Dot('seed:A', 1);
      final dotB = Dot('seed:B', 1);
      final r1 = await dedup.process(db, contentKey: 'ckX', dot: dotA);
      final r2 = await dedup.process(db, contentKey: 'ckY', dot: dotB);
      expect(r1.outcome, DedupOutcome.firstSeen);
      expect(r2.outcome, DedupOutcome.firstSeen);
      expect(r1.canonicalDot, dotA);
      expect(r2.canonicalDot, dotB);
    });
  });
}
