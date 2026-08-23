// Hybrid logical clock — M2.3, § Architecture 11.2 ("Durable per-author-seq
// and HLC generation") of the CRDT-cloud-sync design
// (`plan-and-propse-the-glistening-dolphin.md`). Standard HLC algorithm
// (Kulkarni et al.), exactly as that section's pseudocode specifies — one
// clock per physical device, shared by all three of its `authorId`
// namespaces (ordinary/`seed:`/`external:`), backed by
// `sync_state['hlc_wall_ms']`/`sync_state['hlc_logical']`.
//
// This file builds the primitive only. Wiring `generate()` into an actual
// operation-minting call site is M2.4's job; wiring `merge()` into a pull
// loop is M2.6/M2.7's. Nothing here is called from production code yet.

import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';

/// One HLC value: a wall-clock component (milliseconds since epoch) plus a
/// logical tie-breaker, per § 11.2's pseudocode.
///
/// **Encoding: `"<wall>:<logical>"`, zero-padded so that lexicographic
/// (string) comparison agrees with numeric comparison of `(wallMs,
/// logical)`.** § 11.2's own text says the format is "lexicographically
/// sortable when zero-padded" — this class is what actually implements
/// that, rather than asserting it holds without it. Both components are
/// padded to 19 digits: Dart's `int` is a 64-bit signed integer on every
/// platform this app ships on (native; `dart:core`'s `int` is only
/// unsafely truncated on the dart2js/web backend, which this sync engine
/// does not target for its local-database code), and the largest 64-bit
/// signed value (`9223372036854775807`) is 19 digits — so 19-digit
/// zero-padding is the tightest width that can never be exceeded by any
/// representable non-negative `int`, for either component. (`wallMs` in
/// practice needs far fewer digits — 13 covers milliseconds until the year
/// 2286 — but `logical` has no such natural bound: a clock that never
/// observes physical time advancing, e.g. a fake clock frozen in a
/// pathological test or a real clock stuck at `physNow <= lastWall`
/// forever, would keep incrementing `logical` indefinitely. Padding both
/// fields to the same, maximally-safe width means this class never has to
/// reason about "is this specific value large enough to need the wider
/// field" — the encoding stays correct unconditionally.)
class Hlc implements Comparable<Hlc> {
  final int wallMs;
  final int logical;

  const Hlc(this.wallMs, this.logical);

  /// The minimum representable HLC — smaller than any value this device's
  /// clock can ever [HybridLogicalClock.generate], since `generate` returns
  /// `Hlc(physNow, 0)` or `Hlc(lastWall, lastLogical + 1)` and both
  /// components are non-negative.
  ///
  /// Two uses, and they are not the same thing:
  ///
  ///  * **Inert placeholder** — `pull_phase.dart`'s `set_remove` queue sweep
  ///    builds an `IncomingOperation` whose `hlc` the `set_remove` branch of
  ///    `CausalEngine.apply` never reads. Nothing depends on the value.
  ///  * **Load-bearing, and a deliberate documented exception to § 11.2
  ///    (M2.13, review round 3).** `seed_scanner.dart` stamps this on the
  ///    `field` and `__exists__` operations of a POST-RESET re-seed, so that
  ///    seed is *recessive*: it loses every conflict it is in on the
  ///    `(hlc, authorId, authorSeq)` tie-break and decides only content the
  ///    dataset genuinely lacks.
  ///
  ///    **The scope is per-KIND, and three review rounds moved its
  ///    boundary — so read the list, not the slogan.** `field` and
  ///    `__exists__` are stamped. `set_add` is NOT: `OrSetResolver` never
  ///    compares an HLC, so the stamp would decide nothing there, while a
  ///    `set_add`'s `wallMs` *is* read by `materializer.dart` as a
  ///    membership row's `createdAt` fallback — a zero there is a hazard
  ///    with no compensating benefit. `set_remove` is never seed-minted at
  ///    all.
  ///
  ///    **Any consumer that reads a `wallMs` as a TIMESTAMP must handle
  ///    zero explicitly.** That is not hypothetical: `materializer.dart`
  ///    writes an `__exists__` HLC's wall component into the entity's
  ///    `createdAt`, a column outside `syncScopeColumns` that nothing ever
  ///    corrects, and a recessive seed dated a whole rebuilt library
  ///    1970-01-01 until that derivation grew its own fallback
  ///    (`_createdAtFromHlcWall`). Round 4 tried to fix it by exempting
  ///    `__exists__` from the stamp instead, which silently re-parented
  ///    every entity's creation DOT on every peer — the register stores the
  ///    winner's dot as well as its HLC. Stamping is the correct behaviour;
  ///    deriving a date from a value defined to be the minimum is what has
  ///    to be handled.
  ///
  ///    § 11.2's rule that "seed operations must
  ///    get a real HLC value... never a placeholder" is about a first-ever
  ///    seed of never-synced content, where the HLC really is a statement
  ///    about when this device first knew the value; a post-reset seed is a
  ///    re-statement of content the dataset may already hold, and must not
  ///    out-rank a real edit it simply has not seen yet. See
  ///    `dataset_reset.dart`'s F1 section for the failure that forced this
  ///    and for why no phase ordering could substitute for it.
  ///
  /// **Stamping this never moves the clock.** It bypasses
  /// [HybridLogicalClock.generate] entirely, so `sync_state['hlc_wall_ms']`
  /// / `['hlc_logical']` are not written and § 11.2 property (a) —
  /// monotonicity of a device's own successive GENERATED values — is
  /// untouched. A peer that [HybridLogicalClock.merge]s a wall-0 value is
  /// likewise unaffected: `merge` takes `max(physNow, lastWall, remoteWall)`,
  /// so a zero can never drag any clock backwards.
  static const zero = Hlc(0, 0);

  static const _fieldWidth = 19; // see class doc comment.

  @override
  String toString() =>
      '${wallMs.toString().padLeft(_fieldWidth, '0')}:'
      '${logical.toString().padLeft(_fieldWidth, '0')}';

  /// Parses the `"<wall>:<logical>"` format [toString] produces. Tolerant of
  /// the zero-padding being present or absent (an un-padded `"5:0"` parses
  /// the same as `"0000000000000000005:0000000000000000000"`) since
  /// [int.parse] ignores leading zeros — only [toString]'s *output* needs to
  /// be padded for sortability, not every valid input to [parse].
  factory Hlc.parse(String encoded) {
    final parts = encoded.split(':');
    if (parts.length != 2) {
      throw FormatException(
        'Hlc.parse: expected "<wall>:<logical>", got "$encoded"',
      );
    }
    final wall = int.tryParse(parts[0]);
    final logicalValue = int.tryParse(parts[1]);
    if (wall == null || logicalValue == null) {
      throw FormatException('Hlc.parse: non-integer component in "$encoded"');
    }
    return Hlc(wall, logicalValue);
  }

  @override
  int compareTo(Hlc other) {
    final wallCmp = wallMs.compareTo(other.wallMs);
    if (wallCmp != 0) return wallCmp;
    return logical.compareTo(other.logical);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.wallMs == wallMs && other.logical == logical;

  @override
  int get hashCode => Object.hash(wallMs, logical);
}

/// The two `sync_state` keys [HybridLogicalClock] owns, named at top level
/// (M2.13) so `dataset_reset.dart` can name them as the ONLY keys a sync
/// reset preserves without reaching into a private member or re-typing the
/// strings. Monotonicity of this clock must survive a reset — see that
/// file's own reasoning.
const String hlcWallStateKey = 'hlc_wall_ms';
const String hlcLogicalStateKey = 'hlc_logical';

/// Per-device hybrid logical clock, backed by `sync_state`. One instance is
/// meant to be shared for the lifetime of a device's sync engine — not
/// because this class holds any load-bearing in-memory state of its own
/// (every [generate]/[merge] call re-reads `sync_state` before deciding),
/// but so the whole engine agrees on one [physicalClockMs] source, which
/// matters for deterministic testing (see the injectable-clock parameter
/// below).
class HybridLogicalClock {
  HybridLogicalClock(this._databaseService, {int Function()? physicalClockMs})
    : _physicalClockMs = physicalClockMs ?? _systemClockMs;

  final DatabaseService _databaseService;

  /// Injectable so tests can drive `generate()`/`merge()` through specific
  /// physical-clock-ahead/behind scenarios deterministically, rather than
  /// depending on real `DateTime.now()` timing (per the M2.3 brief's
  /// explicit ask for the bounded-drift property test).
  final int Function() _physicalClockMs;

  static int _systemClockMs() => DateTime.now().millisecondsSinceEpoch;

  static const _wallKey = hlcWallStateKey;
  static const _logicalKey = hlcLogicalStateKey;

  Future<Hlc> _readState(DatabaseExecutor db) async {
    final rows = await db.query(
      'sync_state',
      where: 'key IN (?, ?)',
      whereArgs: [_wallKey, _logicalKey],
    );
    var wall = 0;
    var logicalValue = 0;
    for (final row in rows) {
      final value = row['value'] as String?;
      if (value == null) continue;
      if (row['key'] == _wallKey) wall = int.parse(value);
      if (row['key'] == _logicalKey) logicalValue = int.parse(value);
    }
    return Hlc(wall, logicalValue);
  }

  Future<void> _writeState(DatabaseExecutor db, Hlc value) async {
    await db.insert('sync_state', {
      'key': _wallKey,
      'value': '${value.wallMs}',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('sync_state', {
      'key': _logicalKey,
      'value': '${value.logical}',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// § 11.2's `generate()`: called when minting a new local operation.
  /// `newWall = max(physNow, lastWall)`… actually, per the spec exactly:
  /// if `physNow > lastWall`, jump the wall component forward and reset
  /// `logical` to 0; otherwise stay at `lastWall` and increment `logical`.
  /// The read-then-write is one transaction — "persist(newWall, newLogical)
  /// -- same transaction as the mint it stamps" — so a caller (M2.4) can
  /// pass its own outer transaction via [executor] to fold this into a
  /// single atomic unit with the operation it's stamping, the same
  /// optional-executor idiom `SeqCounter.mintNextSeq` and
  /// `deleteRelationshipsForNote` (`database_service.dart`) already use.
  Future<Hlc> generate({DatabaseExecutor? executor}) async {
    Future<Hlc> body(DatabaseExecutor txn) async {
      final physNow = _physicalClockMs();
      final last = await _readState(txn);
      final next = physNow > last.wallMs
          ? Hlc(physNow, 0)
          : Hlc(last.wallMs, last.logical + 1);
      await _writeState(txn, next);
      return next;
    }

    if (executor != null) return body(executor);
    final db = await _databaseService.database;
    return db.transaction((txn) => body(txn));
  }

  /// § 11.2's `merge()`: called on every applied incoming `Operation`, not
  /// only on mint — folds a remote HLC value into this device's own clock
  /// state so a *subsequent* `generate()` call is guaranteed to exceed it
  /// (the causality-consistency property). This milestone builds and tests
  /// the primitive only; wiring this into an actual pull loop is
  /// M2.6/M2.7's job.
  Future<Hlc> merge(
    int remoteWall,
    int remoteLogical, {
    DatabaseExecutor? executor,
  }) async {
    Future<Hlc> body(DatabaseExecutor txn) async {
      final physNow = _physicalClockMs();
      final last = await _readState(txn);
      final newWall = [physNow, last.wallMs, remoteWall].reduce(max);

      final int newLogical;
      if (newWall == last.wallMs && newWall == remoteWall) {
        newLogical = max(last.logical, remoteLogical) + 1;
      } else if (newWall == last.wallMs) {
        newLogical = last.logical + 1;
      } else if (newWall == remoteWall) {
        newLogical = remoteLogical + 1;
      } else {
        newLogical = 0;
      }

      final next = Hlc(newWall, newLogical);
      await _writeState(txn, next);
      return next;
    }

    if (executor != null) return body(executor);
    final db = await _databaseService.database;
    return db.transaction((txn) => body(txn));
  }
}
