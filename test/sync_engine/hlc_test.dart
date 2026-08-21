// Tests for M2.3's `Hlc`/`HybridLogicalClock` (`lib/services/sync/hlc.dart`)
// — § Architecture 11.2's hybrid logical clock (Kulkarni et al.). See
// `device_identity_test.dart` for the `test/sync_engine/` placement
// rationale.
//
// This milestone builds and tests the primitive only — `generate()` is not
// yet wired into any operation-minting call site (M2.4), and `merge()` is
// not yet wired into a pull loop (M2.6/M2.7). Every scenario below uses an
// injected fake physical clock, never real `DateTime.now()` timing, so the
// three cited properties (monotonicity, causality-consistency, bounded
// drift) are deterministic.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/hlc.dart';

/// A mutable, manually-advanced fake physical clock — stands in for
/// `wall_clock_now_ms()` in § 11.2's pseudocode. Never advances on its own;
/// every scenario below controls exactly what `HybridLogicalClock` observes
/// as "physical now" at each call.
class _FakeClock {
  int ms;
  _FakeClock(this.ms);
  int call() => ms;
}

Future<void> _setHlcState(DatabaseService db, int wallMs, int logical) async {
  final raw = await db.database;
  await raw.insert('sync_state', {'key': 'hlc_wall_ms', 'value': '$wallMs'});
  await raw.insert('sync_state', {'key': 'hlc_logical', 'value': '$logical'});
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('Hlc value type — encoding and ordering', () {
    test('toString() produces "<wall>:<logical>", zero-padded to 19 digits each', () {
      expect(const Hlc(5, 3).toString(), '0000000000000000005:0000000000000000003');
      expect(const Hlc(0, 0).toString(), '0000000000000000000:0000000000000000000');
      expect(
        const Hlc(1732900000123, 42).toString(),
        '0000001732900000123:0000000000000000042',
      );
    });

    test('parse() round-trips toString() output', () {
      const original = Hlc(1732900000123, 42);
      expect(Hlc.parse(original.toString()), original);
    });

    test('compareTo() orders primarily by wall, then by logical', () {
      expect(const Hlc(5, 100).compareTo(const Hlc(10, 1)) < 0, isTrue);
      expect(const Hlc(10, 1).compareTo(const Hlc(10, 2)) < 0, isTrue);
      expect(const Hlc(10, 2).compareTo(const Hlc(10, 2)), 0);
      expect(const Hlc(10, 2).compareTo(const Hlc(10, 1)) > 0, isTrue);
    });

    test(
      'zero-padded string comparison agrees with numeric Hlc comparison — '
      'and would NOT without the padding (the property the design doc requires)',
      () {
        final values = [
          const Hlc(2, 100),
          const Hlc(10, 1),
          const Hlc(10, 2),
          const Hlc(0, 0),
          const Hlc(9999999999999, 0),
          const Hlc(100, 99999),
        ];

        final byNumericOrder = [...values]..sort();
        final byStringOrder = [...values]..sort((a, b) => a.toString().compareTo(b.toString()));
        expect(
          byStringOrder,
          byNumericOrder,
          reason: 'lexicographic string ordering of the padded encoding must match numeric Hlc ordering',
        );

        // Concretely demonstrate *why* padding matters: without it,
        // "2:100" sorts before "10:1" lexicographically (because '1' < '2'
        // as the first character), which disagrees with the correct
        // numeric order (wall 2 < wall 10). The padded encoding must not
        // exhibit this.
        const smallerWall = Hlc(2, 100);
        const largerWall = Hlc(10, 1);
        expect(smallerWall.compareTo(largerWall) < 0, isTrue);
        expect(
          smallerWall.toString().compareTo(largerWall.toString()) < 0,
          isTrue,
          reason: 'padded string comparison must agree with numeric comparison',
        );
        // The unpadded equivalent would disagree (sanity-check the claim
        // itself, not just the class under test):
        final unpaddedSmaller = '${smallerWall.wallMs}:${smallerWall.logical}';
        final unpaddedLarger = '${largerWall.wallMs}:${largerWall.logical}';
        expect(
          unpaddedSmaller.compareTo(unpaddedLarger) < 0,
          isFalse,
          reason: 'unpadded "2:100" vs "10:1" is the exact failure mode zero-padding exists to prevent',
        );
      },
    );

    test('parse() throws FormatException on malformed input', () {
      expect(() => Hlc.parse('not-an-hlc'), throwsFormatException);
      expect(() => Hlc.parse('5'), throwsFormatException);
      expect(() => Hlc.parse('a:b'), throwsFormatException);
    });
  });

  group('HybridLogicalClock.generate — monotonicity', () {
    late DatabaseService databaseService;
    late _FakeClock clock;
    late HybridLogicalClock hlc;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
      clock = _FakeClock(1000);
      hlc = HybridLogicalClock(databaseService, physicalClockMs: clock.call);
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('first generate() jumps to the physical clock with logical 0 (default last state is 0,0)', () async {
      final value = await hlc.generate();
      expect(value, const Hlc(1000, 0));
    });

    test('successive generate() calls strictly increase, with the physical clock advancing each time', () async {
      Hlc? previous;
      for (var i = 0; i < 20; i++) {
        clock.ms += 10;
        final value = await hlc.generate();
        if (previous != null) {
          expect(value > previous, isTrue, reason: 'call #$i must strictly exceed the previous value');
        }
        previous = value;
      }
    });

    test('successive generate() calls strictly increase even when the physical clock is frozen', () async {
      // physNow never exceeds lastWall after the first call -> every
      // subsequent call falls into the "else" branch of generate(),
      // incrementing only the logical component. Monotonicity must still
      // hold by construction.
      final first = await hlc.generate();
      Hlc previous = first;
      for (var i = 0; i < 50; i++) {
        final value = await hlc.generate(); // clock.ms unchanged
        expect(value > previous, isTrue);
        expect(value.wallMs, previous.wallMs, reason: 'frozen physical clock: wall must not change');
        expect(value.logical, previous.logical + 1);
        previous = value;
      }
    });

    test('successive generate() calls strictly increase even when the physical clock moves backward', () async {
      // A physical clock that goes backward (NTP correction, DST, buggy
      // hardware clock) must never cause generate() to go backward or
      // stall — this is exactly what the wall-vs-logical split protects
      // against.
      final first = await hlc.generate(); // Hlc(1000, 0)
      clock.ms = 500; // clock jumps backward
      final second = await hlc.generate();
      clock.ms = 200; // jumps backward again, further
      final third = await hlc.generate();

      expect(second > first, isTrue);
      expect(third > second, isTrue);
      // Wall component must have stayed pinned at the last known wall
      // value (1000) throughout, since physNow never exceeded it.
      expect(second.wallMs, 1000);
      expect(third.wallMs, 1000);
      expect(second.logical, 1);
      expect(third.logical, 2);
    });

    test('generate() persists its result durably — a fresh instance continues from the same state', () async {
      final first = await hlc.generate();
      final freshInstanceSameClock = HybridLogicalClock(databaseService, physicalClockMs: clock.call);
      final second = await freshInstanceSameClock.generate();
      expect(second > first, isTrue);
      expect(second, const Hlc(1000, 1)); // clock frozen at 1000, so logical increments.
    });
  });

  group('HybridLogicalClock.merge — causality consistency', () {
    late DatabaseService databaseService;
    late _FakeClock clock;
    late HybridLogicalClock hlc;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
      clock = _FakeClock(1000);
      hlc = HybridLogicalClock(databaseService, physicalClockMs: clock.call);
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'if operation a was received and merged before b was minted on the same device, '
      'b\'s HLC exceeds a\'s',
      () async {
        // a's HLC, as minted on some *other* device and now arriving here.
        const remoteA = Hlc(5000, 3);

        // This device's own physical clock is behind remoteA's wall value
        // the whole time (a real, common case — clocks are never
        // perfectly synchronized).
        final mergedA = await hlc.merge(remoteA.wallMs, remoteA.logical);
        expect(mergedA >= remoteA, isTrue, reason: 'merge must fold the remote value in, not ignore it');

        // Immediately after, this device mints its own local operation b.
        final b = await hlc.generate();

        expect(
          b > mergedA,
          isTrue,
          reason: 'b, minted after merging a, must exceed a\'s (merged) HLC value',
        );
        expect(b > remoteA, isTrue, reason: 'b must also exceed the original remote value a arrived with');
      },
    );

    test('merge() with a larger remote value is reflected in the next generate()', () async {
      // Local clock generates once first.
      final localFirst = await hlc.generate(); // Hlc(1000, 0)
      expect(localFirst, const Hlc(1000, 0));

      // A remote operation arrives with a much larger HLC (e.g. another
      // device with a faster clock, or one that's been running longer).
      final merged = await hlc.merge(9000, 7);
      expect(merged, const Hlc(9000, 8)); // remoteWall wins, logical = remoteLogical + 1

      // Physical clock still frozen at 1000 (well behind 9000) — the next
      // generate() must still build on the merged state, not silently
      // regress to the stale local physical time.
      final next = await hlc.generate();
      expect(next > merged, isTrue);
      expect(next.wallMs, 9000, reason: 'must stay pinned at the merged wall value, not fall back to physNow');
      expect(next.logical, 9);
    });

    test('merge() is a no-op advance when the remote value is already behind local state', () async {
      await _setHlcState(databaseService, 5000, 10);
      final merged = await hlc.merge(1000, 2); // remote is far behind
      // newWall = max(physNow=1000, lastWall=5000, remoteWall=1000) = 5000 = lastWall
      expect(merged, const Hlc(5000, 11));
    });
  });

  group('HybridLogicalClock — bounded drift across physical-clock-ahead/behind/tied scenarios', () {
    late DatabaseService databaseService;
    late _FakeClock clock;
    late HybridLogicalClock hlc;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
      clock = _FakeClock(0);
      hlc = HybridLogicalClock(databaseService, physicalClockMs: clock.call);
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('physical clock strictly ahead of both local last state and remote: wall = physNow, logical = 0', () async {
      await _setHlcState(databaseService, 0, 0);
      clock.ms = 10000;
      final merged = await hlc.merge(2000, 5);
      expect(merged, const Hlc(10000, 0));
    });

    test('remote strictly ahead of both physical clock and local last state: wall = remoteWall, logical = remoteLogical + 1', () async {
      await _setHlcState(databaseService, 0, 0);
      clock.ms = 100;
      final merged = await hlc.merge(5000, 2);
      expect(merged, const Hlc(5000, 3));
    });

    test('local last state strictly ahead of both physical clock and remote: wall = lastWall, logical = lastLogical + 1', () async {
      await _setHlcState(databaseService, 9000, 7);
      clock.ms = 50;
      final merged = await hlc.merge(1000, 1);
      expect(merged, const Hlc(9000, 8));
    });

    test('all three tied: wall stays, logical = max(lastLogical, remoteLogical) + 1', () async {
      await _setHlcState(databaseService, 5000, 4);
      clock.ms = 5000;
      final merged = await hlc.merge(5000, 9);
      expect(merged, const Hlc(5000, 10)); // max(4, 9) + 1
    });

    test('local last state and remote tied, both ahead of physical clock: logical = max(lastLogical, remoteLogical) + 1', () async {
      await _setHlcState(databaseService, 5000, 4);
      clock.ms = 100; // physical clock behind both
      final merged = await hlc.merge(5000, 1);
      expect(merged, const Hlc(5000, 5)); // max(4, 1) + 1, wall unchanged at 5000
    });

    test(
      'the wall component of every generate()/merge() result never exceeds '
      'max(physical clock ever observed, every remote wall value ever observed)',
      () async {
        // A longer scenario mixing generate() and merge() calls with a
        // physical clock that moves both forward and backward, asserting
        // the bounded-drift invariant holds at every step.
        var maxObserved = 0;

        Future<void> checkAndAdvance(Hlc result, {int? remoteWall}) async {
          if (remoteWall != null && remoteWall > maxObserved) maxObserved = remoteWall;
          if (clock.ms > maxObserved) maxObserved = clock.ms;
          expect(
            result.wallMs <= maxObserved,
            isTrue,
            reason: 'wall component ${result.wallMs} exceeded the bound $maxObserved',
          );
        }

        clock.ms = 1000;
        await checkAndAdvance(await hlc.generate());

        clock.ms = 500; // clock regresses
        await checkAndAdvance(await hlc.generate());

        await checkAndAdvance(await hlc.merge(3000, 2), remoteWall: 3000);

        clock.ms = 3500; // clock advances past the merged remote value
        await checkAndAdvance(await hlc.generate());

        await checkAndAdvance(await hlc.merge(100, 1), remoteWall: 100); // stale remote

        clock.ms = 2000; // clock regresses again, still below current state
        await checkAndAdvance(await hlc.merge(2500, 0), remoteWall: 2500);
      },
    );
  });
}
