// A minimal, TEST-ONLY operation-minting helper mirroring
// `test/sync_protocol/replica.dart`'s `Replica` MINTING side (local
// per-authorId seq counters, observation-based frontier tracking, HLC
// stamping) — deliberately not a port of the receiving/resolution side.
// In every regression replay that uses this helper, `CausalEngine` plus a
// real sqlite database plays the abstract suite's own "receiving replica"
// role (the `r` in `test/sync_protocol/regression_test.dart`'s own
// scenarios); `TestMintingDevice` plays the role of the OTHER replicas in
// those same scenarios (`a`, `b`, `devX`, `devY`, `devZ`, ...), which only
// ever mint operations and are never themselves the thing under test.
//
// M2.5, § Architecture 11.4 — differential/regression replay harness.
import 'dart:convert';

import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/hlc.dart';

class TestMintingDevice {
  TestMintingDevice(this.id);

  final String id;
  final Map<String, int> _localSeq = {};

  /// Observation-based delta frontier — public so tests can assert on it,
  /// mirroring `Replica.frontier`.
  final Map<String, int> frontier = {};

  int _hlcSeq = 0;

  int _nextSeq(String authorId) {
    final n = (_localSeq[authorId] ?? 0) + 1;
    _localSeq[authorId] = n;
    return n;
  }

  /// `hlcOverride` maps directly onto `Hlc(wallMs, 0)` — the abstract
  /// suite's own `hlcOverride` is a plain, totally-ordered int; encoding it
  /// as the wall-clock component (with a zero logical component) preserves
  /// an identical total order under the real `Hlc` type.
  Hlc _nextHlc(int? override) => Hlc(override ?? (++_hlcSeq), 0);

  /// Direct port of `Replica._frontierSnapshot` plus the unconditional
  /// frontier-bump half of `Replica.apply` (applying one's own just-minted
  /// operation to oneself, § Architecture 1 round 14's observation-based
  /// frontier update) — building the op's own self-inclusive frontier
  /// snapshot BEFORE bumping, exactly like the abstract model's `_mint`
  /// (`_frontierSnapshot` then `apply(op)`).
  Map<String, int> _snapshotAndBumpOwn(String authorId, int seq) {
    final snap = Map<String, int>.of(frontier);
    final snapCur = snap[authorId] ?? 0;
    if (seq > snapCur) snap[authorId] = seq;

    final ownCur = frontier[authorId] ?? 0;
    if (seq > ownCur) frontier[authorId] = seq;

    return snap;
  }

  /// Direct port of `Replica.mintExists` — M2.8's differential-testing
  /// adapter (`differential_random_test.dart`) is the first user: unlike
  /// [mintField], which always stamps `kind: 'field'`, this stamps
  /// `kind: '__exists__'`. `CausalEngine.apply` resolves both kinds through
  /// the identical `_applyFieldOrExists` path (dedup/field-conflict
  /// resolution does not distinguish them) — the `kind` value only matters
  /// downstream, at materialization time (M2.7, out of scope for anything
  /// that uses this helper) — but stamping it correctly still matters for
  /// byte-faithful `sync_field_state`/`sync_pending_ops` rows a test might
  /// assert on directly.
  IncomingOperation mintExists({
    required String table,
    required String entityId,
    required dynamic value,
    String? contentKey,
    String authorNamespace = '',
    int? hlcOverride,
  }) {
    final authorId = authorNamespace.isEmpty ? id : authorNamespace;
    final seq = _nextSeq(authorId);
    final hlc = _nextHlc(hlcOverride);
    final snap = _snapshotAndBumpOwn(authorId, seq);
    return IncomingOperation(
      dot: Dot(authorId, seq),
      hlc: hlc,
      contentKey: contentKey,
      kind: '__exists__',
      entityTable: table,
      entityId: entityId,
      fieldName: existsFieldSentinel,
      valueJson: jsonEncode(value),
      frontier: snap,
    );
  }

  /// Direct port of `Replica.mintField`.
  IncomingOperation mintField({
    required String table,
    required String entityId,
    required String field,
    required dynamic value,
    String? contentKey,
    String authorNamespace = '',
    int? hlcOverride,
  }) {
    final authorId = authorNamespace.isEmpty ? id : authorNamespace;
    final seq = _nextSeq(authorId);
    final hlc = _nextHlc(hlcOverride);
    final snap = _snapshotAndBumpOwn(authorId, seq);
    return IncomingOperation(
      dot: Dot(authorId, seq),
      hlc: hlc,
      contentKey: contentKey,
      kind: 'field',
      entityTable: table,
      entityId: entityId,
      fieldName: field,
      valueJson: jsonEncode(value),
      frontier: snap,
    );
  }

  /// Direct port of `test/sync_protocol/regression_test.dart`'s own
  /// top-level `mintSeed` helper (the round-14 contentKey formula,
  /// `baseContext="GENESIS"`) — same formula, so replaying the same
  /// scenario against the real engine exercises the identical dedup
  /// grouping the abstract suite's regression tests check.
  IncomingOperation mintSeed({
    required String table,
    required String entityId,
    required String field,
    required dynamic value,
    int? hlcOverride,
  }) {
    final contentKey = '$table:$entityId:$field:GENESIS:$value';
    return mintField(
      table: table,
      entityId: entityId,
      field: field,
      value: value,
      contentKey: contentKey,
      authorNamespace: 'seed:$id',
      hlcOverride: hlcOverride,
    );
  }

  /// Direct port of `Replica.mintSetAdd`.
  IncomingOperation mintSetAdd({
    required String table,
    required String entityId,
    required String memberUuid,
    String fieldName = 'members',
    dynamic value = true,
    String? contentKey,
    String authorNamespace = '',
    int? hlcOverride,
  }) {
    final authorId = authorNamespace.isEmpty ? id : authorNamespace;
    final seq = _nextSeq(authorId);
    final hlc = _nextHlc(hlcOverride);
    final snap = _snapshotAndBumpOwn(authorId, seq);
    return IncomingOperation(
      dot: Dot(authorId, seq),
      hlc: hlc,
      contentKey: contentKey,
      kind: 'set_add',
      entityTable: table,
      entityId: entityId,
      fieldName: fieldName,
      memberUuid: memberUuid,
      valueJson: jsonEncode(value),
      frontier: snap,
    );
  }

  /// Direct port of `Replica.mintSetRemove`.
  IncomingOperation mintSetRemove({
    required String table,
    required String entityId,
    required String memberUuid,
    required List<Dot> targetDots,
    String fieldName = 'members',
  }) {
    final authorId = id;
    final seq = _nextSeq(authorId);
    final hlc = _nextHlc(null);
    final snap = _snapshotAndBumpOwn(authorId, seq);
    return IncomingOperation(
      dot: Dot(authorId, seq),
      hlc: hlc,
      kind: 'set_remove',
      entityTable: table,
      entityId: entityId,
      fieldName: fieldName,
      memberUuid: memberUuid,
      targetDots: targetDots,
      frontier: snap,
    );
  }

  /// Bumps this device's own observation frontier for [op] without
  /// otherwise processing it — mirrors calling `Replica.apply` purely for
  /// its unconditional frontier-bump side effect, the pattern several
  /// regression scenarios use to set up "device Y observed device Z's
  /// operation before minting its own" (§ Architecture 1's transitive-
  /// domination witness scenarios).
  void observe(IncomingOperation op) {
    final cur = frontier[op.dot.authorId] ?? 0;
    if (op.dot.authorSeq > cur) frontier[op.dot.authorId] = op.dot.authorSeq;
  }
}
