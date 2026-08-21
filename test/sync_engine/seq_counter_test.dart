// Tests for M2.3's `SeqCounter` (`lib/services/sync/seq_counter.dart`) —
// § Architecture 11.2's durable per-`authorId`-namespace sequence counters.
// See `device_identity_test.dart` for the `test/sync_engine/` placement
// rationale.
//
// This milestone does not yet write to `sync_pending_ops` (M2.4's job), so
// what's tested here is the primitive itself: sequential minting per
// namespace, namespace independence, and the transactional-atomicity
// guarantee `mintNextSeq`'s optional `executor` parameter is meant to give
// M2.4 to compose with (a failure inside the same transaction rolls back
// the seq advance too, not just whatever else was in that transaction).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('SeqCounter', () {
    late DatabaseService databaseService;
    late SeqCounter seqCounter;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
      seqCounter = SeqCounter(databaseService);
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('sequential calls for the same authorId produce 1, 2, 3, ...', () async {
      final first = await seqCounter.mintNextSeq('device-a');
      final second = await seqCounter.mintNextSeq('device-a');
      final third = await seqCounter.mintNextSeq('device-a');

      expect([first, second, third], [1, 2, 3]);
    });

    test('peek() reflects the last-minted value without minting', () async {
      expect(await seqCounter.peek('device-a'), 0, reason: 'unused namespace defaults to 0');
      await seqCounter.mintNextSeq('device-a');
      await seqCounter.mintNextSeq('device-a');
      expect(await seqCounter.peek('device-a'), 2);
      // peek() itself must not have advanced the counter.
      expect(await seqCounter.mintNextSeq('device-a'), 3);
    });

    test('an ordinary device, its seed: namespace, and its external: namespace are independent counters', () async {
      const deviceId = 'device-a';
      const seedNamespace = 'seed:$deviceId';
      const externalNamespace = 'external:$deviceId';

      final ordinary1 = await seqCounter.mintNextSeq(deviceId);
      final seed1 = await seqCounter.mintNextSeq(seedNamespace);
      final ordinary2 = await seqCounter.mintNextSeq(deviceId);
      final external1 = await seqCounter.mintNextSeq(externalNamespace);
      final seed2 = await seqCounter.mintNextSeq(seedNamespace);
      final ordinary3 = await seqCounter.mintNextSeq(deviceId);

      expect([ordinary1, ordinary2, ordinary3], [1, 2, 3]);
      expect([seed1, seed2], [1, 2]);
      expect([external1], [1]);
    });

    test('different authorIds never observe each other\'s counts', () async {
      await seqCounter.mintNextSeq('device-a');
      await seqCounter.mintNextSeq('device-a');
      final firstForB = await seqCounter.mintNextSeq('device-b');

      expect(firstForB, 1, reason: 'device-b must start from 0, unaffected by device-a\'s two prior mints');
    });

    test('persists across a fresh SeqCounter instance against the same database', () async {
      await seqCounter.mintNextSeq('device-a');
      await seqCounter.mintNextSeq('device-a');

      final freshCounter = SeqCounter(databaseService);
      expect(await freshCounter.mintNextSeq('device-a'), 3);
    });

    group('transaction-boundary composition (the primitive M2.4 will build on)', () {
      test('mintNextSeq participates in a caller-supplied transaction via executor', () async {
        final db = await databaseService.database;
        late int minted;
        await db.transaction((txn) async {
          minted = await seqCounter.mintNextSeq('device-a', executor: txn);
          // A second write inside the same transaction, standing in for
          // M2.4's future sync_pending_ops insert — proves the executor
          // parameter genuinely composes with other writes in the same
          // transaction rather than opening a nested/independent one.
          await txn.insert('sync_state', {
            'key': 'test_companion_write:$minted',
            'value': 'ok',
          });
        });

        expect(minted, 1);
        final rows = await db.query(
          'sync_state',
          where: 'key = ?',
          whereArgs: ['test_companion_write:1'],
        );
        expect(rows, hasLength(1));
      });

      test(
        'a failure later in the same transaction rolls back the seq advance too '
        '(the atomicity primitive M2.4\'s sync_pending_ops insert will rely on)',
        () async {
          final db = await databaseService.database;

          // Baseline: establish that device-a's counter starts at 0.
          expect(await seqCounter.peek('device-a'), 0);

          await expectLater(
            db.transaction((txn) async {
              await seqCounter.mintNextSeq('device-a', executor: txn);
              // Simulate a crash / companion-write failure *inside the same
              // transaction* that would, in M2.4, be the sync_pending_ops
              // insert. Throwing here must abort the whole transaction,
              // including the seq-counter's own write above — this is
              // exactly the "a crash between the two is impossible to
              // observe as 'seq consumed, no operation to show for it'"
              // guarantee § 11.2 requires, tested at the primitive level
              // since no sync_pending_ops row exists yet to pair it with.
              throw Exception('simulated failure before the companion write commits');
            }),
            throwsException,
          );

          // The seq advance must have been rolled back along with
          // everything else in the aborted transaction.
          expect(
            await seqCounter.peek('device-a'),
            0,
            reason: 'a rollback must undo the seq mint, not just leave it "consumed but unrecorded"',
          );

          // And the counter must resume cleanly from 1 on the next real
          // (successful) mint — no gap, no corruption from the aborted
          // attempt.
          expect(await seqCounter.mintNextSeq('device-a'), 1);
        },
      );

      test('a failure in one authorId\'s transaction does not affect a different authorId\'s counter', () async {
        final db = await databaseService.database;
        await seqCounter.mintNextSeq('device-b'); // device-b already at 1

        await expectLater(
          db.transaction((txn) async {
            await seqCounter.mintNextSeq('device-a', executor: txn);
            throw Exception('simulated failure');
          }),
          throwsException,
        );

        expect(await seqCounter.peek('device-a'), 0);
        expect(await seqCounter.peek('device-b'), 1, reason: 'unrelated namespace must be untouched by the aborted transaction');
      });
    });
  });
}
