// The "thin adapter" § Architecture 11.4/11.8 both call for: drives the
// REAL, SQL-backed `CausalEngine` (M2.5) through the exact same per-
// operation minting/sync shape `test/sync_protocol/replica.dart`'s
// `Replica`/`Simulator` already use for the abstract M0 suites, so the
// SAME randomized/regression scenario generators can be run against BOTH
// side by side (M2.8, § Architecture 11.8's required "differential testing
// against Replica, at scale").
//
// ---------------------------------------------------------------------
// The minting-granularity decision (§ 11.4's own flagged open question,
// carried forward as M2.8's to resolve — see the milestone report for the
// full reasoning; summarized here since it's exactly what this file is).
// ---------------------------------------------------------------------
// DECIDED: per-operation, matching `Replica.mintField`/`apply()`'s
// one-call-per-event model directly — NOT via `OutboxDrainer`'s
// drain-at-sync-time batching. Reasoning, in brief:
//
//  1. `CausalEngine` (not `OutboxDrainer`) is the actual ported algorithm
//     this differential suite exists to validate — the dedup/SCC/
//     `chainDom`/field-conflict-resolution machinery `field_conflict_
//     resolver.dart`'s own top doc comment identifies as "the single most
//     adversarially-reviewed piece of logic in the whole design doc."
//     `CausalEngine.apply` has no notion of "was this locally drained or
//     pulled from the network" — it only ever takes one `IncomingOperation`
//     at a time, and resolves it exactly the same way regardless of what
//     fed it. Driving it directly, per operation, is not a shortcut around
//     production behavior — it is EXACTLY `pull_phase.dart`'s own real,
//     already-production granularity: § 11.7 Phase B step 4 feeds decoded
//     commits into the causal engine "for each StoredCommit, in order" —
//     literally one operation at a time already, in the real pull loop.
//  2. `OutboxDrainer`'s batching is a *capture-layer* question (how many
//     raw touch-log rows collapse into how many minted operations), not a
//     *resolution-layer* one — and it only ever applies to THIS device's
//     OWN local mints, which `causal_engine.dart`'s own top doc comment
//     already argues (the Exclusion Lemma) can never produce a second,
//     independently-arrived candidate for the same field: by construction,
//     there is nothing for a multi-candidate differential comparison to
//     even exercise there. `outbox_drainer_test.dart` already covers that
//     batching behavior directly (double-drain idempotence, same-batch
//     collapse, revert-before-drain) — re-deriving it here through a full
//     randomized/exhaustive harness would not exercise any NEW algorithmic
//     risk, only re-prove an already-tested, structurally-simpler
//     invariant at much higher cost (this file's own real-SQLite-backed
//     multi-device scenarios are already the practical bottleneck on scale
//     — see the milestone report's scale discussion).
//
// This adapter is therefore built directly on `TestMintingDevice`
// (`test_minting_device.dart`, M2.5's own regression-replay minting
// helper) plus `CausalEngine` against a real per-replica `DatabaseService`
// — the identical pairing M2.5's `field_conflict_resolver_test.dart`/
// `causal_engine_test.dart`/`or_set_resolver_test.dart` already use for
// regression-parity replay, just generalized here into a full `Replica`-
// shaped API (mint-and-self-apply, an outbox, sync/syncPartial/
// syncAllToAll) so the abstract suite's OWN generator code can drive it.
//
// One deliberate, disclosed adaptation from `Simulator.syncFull`/
// `syncPartial`'s literal shape: those rely on `Replica.apply`'s own
// top-of-function idempotency guard (`if (!_appliedDots.add(op.dot))
// return;`) to make redelivering an already-applied op from `outbox` a
// safe no-op — `CausalEngine.apply` documents no equivalent standalone
// redelivery-safety guarantee of its own (in real production, nothing
// ever redelivers an already-observed dot at all: `pull_phase.dart`'s own
// `afterSeq`, read from the durably-persisted `sync_state['frontier:...']`
// row, is what prevents it, § 11.7 Phase B step 3). `RealSimulator` below
// mirrors that REAL mechanism instead — skipping any op whose `authorSeq`
// the target's own frontier already covers before ever calling
// `CausalEngine.apply` — which is MORE faithful to production, not less:
// it is the literal mechanism `PullPhase` already uses, not a new
// invention for this test file, and it keeps this suite's differential
// comparison focused on the SAME question the abstract suite's own
// idempotency guard exists to make safe to ignore (does resolution
// converge correctly), rather than accidentally introducing a second,
// untested question (is raw re-application of an already-applied dot
// itself idempotent) that production never actually depends on.
import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';

import 'test_minting_device.dart';

/// One "replica" backed by a real, independent, in-memory `DatabaseService`
/// — the real-engine analog of `test/sync_protocol/replica.dart`'s
/// `Replica`. Every mint immediately self-applies (matching `Replica.
/// mintField`'s own internal `apply(op)` call), and every mint is recorded
/// in [outbox] for later delivery to other `RealReplica`s via
/// [RealSimulator].
class RealReplica {
  RealReplica(this.id) : minter = TestMintingDevice(id);

  final String id;
  final TestMintingDevice minter;
  final CausalEngine engine = CausalEngine();
  final List<IncomingOperation> outbox = [];

  late final DatabaseService databaseService;
  late final Database db;

  /// Must be called (and awaited) before any mint/apply — mirrors
  /// `Replica`'s constructor being all a caller needs, but a real
  /// `DatabaseService.database` getter is itself async.
  Future<void> open() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
  }

  Future<void> close() => databaseService.close();

  /// Observation-based delta frontier — the real-engine analog of
  /// `Replica.frontier`, exposed for `RealSimulator`'s partial-sync
  /// "already observed" check.
  Map<String, int> get frontier => minter.frontier;

  Future<IncomingOperation> _mintAndApply(IncomingOperation op) async {
    await db.transaction((txn) => engine.apply(txn, op));
    outbox.add(op);
    return op;
  }

  Future<IncomingOperation> mintExists({
    required String table,
    required String entityId,
    required dynamic value,
    String? contentKey,
    int? hlcOverride,
  }) =>
      _mintAndApply(
        minter.mintExists(table: table, entityId: entityId, value: value, contentKey: contentKey, hlcOverride: hlcOverride),
      );

  Future<IncomingOperation> mintField({
    required String table,
    required String entityId,
    required String field,
    required dynamic value,
    String? contentKey,
    int? hlcOverride,
  }) =>
      _mintAndApply(
        minter.mintField(
          table: table,
          entityId: entityId,
          field: field,
          value: value,
          contentKey: contentKey,
          hlcOverride: hlcOverride,
        ),
      );

  /// Applies an operation MINTED BY ANOTHER `RealReplica` (received via
  /// sync) — bumps this replica's own observation frontier first (§
  /// Architecture 2 round 14's "unconditional, before dedup/materialize
  /// outcome is known" ordering, mirrored from `Replica.apply`), then
  /// resolves it through the real causal engine.
  Future<void> applyRemote(IncomingOperation op) async {
    minter.observe(op);
    await db.transaction((txn) => engine.apply(txn, op));
  }

  // ---- convenience reads, mirroring Replica's own reads -----------------

  Future<Map<String, Object?>?> fieldStateRow(String table, String id, String field) async {
    final rows = await db.query(
      'sync_field_state',
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [table, id, field],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> liveConflictRows(String table, String id, String field) {
    return db.query(
      'sync_conflict_copies',
      where: 'subjectTable = ? AND subjectId = ? AND fieldName = ? AND kind = ?',
      whereArgs: [table, id, field, 'field_conflict'],
    );
  }
}

/// The real-engine analog of `test/sync_protocol/simulator.dart`'s
/// `Simulator` — same network-simulation shape (full/partial sync,
/// all-to-all convergence), driving `RealReplica`s instead of `Replica`s.
class RealSimulator {
  RealSimulator({int? seed, this.onAfterSyncTo}) : random = Random(seed);

  final Map<String, RealReplica> replicas = {};
  final Random random;

  /// Run after EVERY successful delivery into a replica, in both
  /// [syncFull] and [syncPartial] — mirrors `Simulator.syncFull`/
  /// `syncPartial`'s own unconditional `TagEngine(to).
  /// resolveAllNameCollisions()` call exactly (see `simulator.dart`: both
  /// methods call it once, right after applying whatever ops they
  /// delivered). This matters for more than surface fidelity: `Simulator.
  /// syncAllToAll` calls `syncFull` — and therefore this hook — once per
  /// (a, b) PAIR, every round, not just once at the very end; a scenario
  /// driver that only ever calls its own collision-resolution pass AFTER
  /// `syncAllToAll` returns (rather than plumbing it through this hook)
  /// resolves collisions against different, later information than the
  /// abstract suite does at each intermediate step, which is a real
  /// adapter-fidelity gap, not a difference in the real engine's own
  /// correctness — confirmed empirically: an earlier version of this
  /// adapter omitted this hook entirely, and `differential_random_test.
  /// dart` immediately found spurious disagreements (seed=4 in that run)
  /// that vanished once every pairwise sync got its own resolution pass,
  /// matching `Simulator`'s own timing exactly.
  final Future<void> Function(RealReplica to)? onAfterSyncTo;

  Future<RealReplica> addReplica(String id) async {
    final r = RealReplica(id);
    await r.open();
    replicas[id] = r;
    return r;
  }

  Future<void> closeAll() async {
    for (final r in replicas.values) {
      await r.close();
    }
  }

  /// Delivers every op in [from]'s outbox [to] hasn't yet observed (by
  /// frontier, § this file's top doc comment on why that's the faithful
  /// real-engine analog of `Replica.apply`'s own idempotency guard), in
  /// outbox order. Callers should also run whatever collision-resolution
  /// pass their scenario needs afterward (mirrors `Simulator.syncFull`
  /// calling `TagEngine(to).resolveAllNameCollisions()` — this generic
  /// simulator has no tag-specific knowledge, so that's the caller's job
  /// here, unlike the abstract version).
  Future<void> syncFull(RealReplica from, RealReplica to) async {
    for (final op in from.outbox) {
      final already = to.frontier[op.dot.authorId] ?? 0;
      if (op.dot.authorSeq <= already) continue;
      await to.applyRemote(op);
    }
    if (onAfterSyncTo != null) await onAfterSyncTo!(to);
  }

  /// Delivers a random-length prefix of each author's pending operations —
  /// mirrors `Simulator.syncPartial` exactly, including the no-gap-
  /// skipping-per-author invariant.
  Future<void> syncPartial(RealReplica from, RealReplica to) async {
    final byAuthor = <String, List<IncomingOperation>>{};
    for (final op in from.outbox) {
      byAuthor.putIfAbsent(op.dot.authorId, () => []).add(op);
    }
    for (final entry in byAuthor.entries) {
      final already = to.frontier[entry.key] ?? 0;
      final pending = entry.value.where((op) => op.dot.authorSeq > already).toList();
      if (pending.isEmpty) continue;
      final n = 1 + random.nextInt(pending.length);
      for (var i = 0; i < n; i++) {
        await to.applyRemote(pending[i]);
      }
    }
    if (onAfterSyncTo != null) await onAfterSyncTo!(to);
  }

  Future<void> syncAllToAll({int rounds = 3}) async {
    final all = replicas.values.toList();
    for (var r = 0; r < rounds; r++) {
      for (final a in all) {
        for (final b in all) {
          if (a == b) continue;
          await syncFull(a, b);
        }
      }
    }
  }
}
