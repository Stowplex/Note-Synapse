// The top-level causal-engine facade — ties `content_key_dedup.dart`,
// `field_conflict_resolver.dart`, and `or_set_resolver.dart` together
// behind one entry point, mirroring `test/sync_protocol/replica.dart`'s
// own `apply(Operation op)` orchestration (the dedup-then-materialize-or-
// recheck dispatch, generalized over all four operation kinds).
//
// M2.5, § Architecture 11.4 ("local causal engine"). This is a PURE
// RESOLUTION ENGINE, callable in isolation — not the pull loop that feeds
// operations into it (M2.6) and not materialization into real app-table
// rows (M2.7). It answers exactly one question: "given a new candidate
// `Operation` for some field or OR-Set slot, and the current state of
// `sync_field_state`/`sync_set_state`/`sync_conflict_copies`/`sync_dedup_
// index`/`sync_dot_redirects` for that slot, compute the correct resulting
// state." Idempotency/observation-frontier bookkeeping for a real pull loop
// (§ 11.7 Phase B: "frontier bump, unconditionally, on observation... even
// if the operation then blocks on a missing prerequisite") is explicitly
// M2.6's job — this milestone's own scope is the resolution algorithm
// itself, callable directly against a hand-built [IncomingOperation] by a
// test, and later by M2.6's pull loop once it exists.
//
// ---------------------------------------------------------------------
// Reconciliation with `OutboxDrainer` (M2.4), stated explicitly per the
// milestone brief.
// ---------------------------------------------------------------------
// `outbox_drainer.dart`'s own class doc comment already states its scope
// boundary precisely: it is "the ONLY writer of `sync_field_state`/
// `sync_set_state` that exists anywhere in this codebase today," and its
// correctness argument ("a device's own newly-minted operation always wins
// against that same device's own immediately-prior state — there is no
// conflict to resolve... unlike materializing a REMOTE operation, which
// might lose a field conflict against a value this device itself wrote
// more recently — a judgment call M2.5's causal comparator owns") is
// exactly right and needs no correction here.
//
// **Judgment call, made and documented rather than executed**: this
// milestone does NOT rewire `OutboxDrainer` to route its own local mints
// through `CausalEngine.apply`. Reasoning: `OutboxDrainer` only ever
// mints and applies operations for THIS device's own, brand-new local
// edits, each compared only against THIS SAME device's own immediately-
// prior `sync_field_state`/`sync_set_state` row — by construction (no pull
// loop exists yet, so no remote/competing candidate can be present at
// drain time), there is never more than one live candidate for
// `OutboxDrainer` to reconcile. Every code path this milestone's engine
// adds real value on — `contentKey` dedup against an ALREADY-DIFFERENT
// dot, multi-candidate SCC/`chainDom` resolution, OR-Set redirect
// resolution against a dot this device didn't itself just mint — requires
// a second, independently-arrived candidate that only a pull loop can ever
// produce. Routing `OutboxDrainer`'s single-candidate local mints through
// this engine today would be a no-op by the Exclusion Lemma's own local-
// minting-closure argument (§ Architecture 1: a device can never locally
// produce two candidates sharing a `contentKey`, and `OutboxDrainer` never
// mints a `contentKey` at all — it only mints ordinary device-namespace
// operations, § its own doc comment: "no `seed:`/`external:` authorId
// namespace minting") — so wiring it in now would add a transaction-
// boundary/API dependency between M2.4 and M2.5 for zero observable
// behavior change. The real integration point is M2.6/M2.7's pull loop,
// which is where a second, independently-arrived candidate can first
// exist at all — `CausalEngine.apply` is written and tested now so that
// wiring, when it happens, is a straightforward call-site change, not a
// design question.

import 'package:sqflite/sqflite.dart';

import '../hlc.dart';
import 'content_key_dedup.dart';
import 'dot.dart';
import 'dot_redirect_resolver.dart';
import 'field_candidate.dart';
import 'field_conflict_resolver.dart';
import 'or_set_resolver.dart';

/// The `fieldName` sentinel used for a whole-row `__exists__` touch —
/// matches `outbox_drainer.dart`'s private `_existsFieldSentinel` and
/// `sync_field_state`'s own stored convention exactly (kept as its own
/// public constant here since this file has no access to that private
/// one, and needs the same value for constructing/interpreting
/// [IncomingOperation]s of kind `'__exists__'`).
const String existsFieldSentinel = '__exists__';

/// One candidate operation being fed into the causal engine — the SQL-
/// shaped equivalent of `test/sync_protocol/model.dart`'s `Operation`,
/// covering all four kinds. Field names mirror `sync_pending_ops`'s own
/// columns directly (`database_service.dart`).
class IncomingOperation {
  const IncomingOperation({
    required this.dot,
    required this.hlc,
    this.contentKey,
    required this.kind,
    required this.entityTable,
    required this.entityId,
    this.fieldName,
    this.memberUuid,
    this.valueJson,
    this.blobHash,
    this.targetDots,
    required this.frontier,
  });

  final Dot dot;
  final Hlc hlc;
  final String? contentKey;

  /// `'__exists__' | 'field' | 'set_add' | 'set_remove'`.
  final String kind;
  final String entityTable;
  final String entityId;

  /// The register field name for `kind == 'field'`, [existsFieldSentinel]
  /// for `kind == '__exists__'`, or the OR-Set's own field name (e.g.
  /// `'tags'`) for `kind == 'set_add' | 'set_remove'`.
  final String? fieldName;

  /// The set member being added/removed — only for `kind == 'set_add' |
  /// 'set_remove'`.
  final String? memberUuid;
  final String? valueJson;
  final String? blobHash;

  /// The add-dot(s) being observed as removed — only for `kind ==
  /// 'set_remove'`.
  final List<Dot>? targetDots;
  final Map<String, int> frontier;
}

enum AppliedKind { fieldOrExists, setAdd, setRemove }

/// Result of one [CausalEngine.apply] call.
class ApplyResult {
  const ApplyResult._({
    required this.kind,
    this.fieldRecompute,
    this.setAddResult,
    this.setRemoveResult,
  });

  factory ApplyResult.fieldOrExists(FieldRecomputeResult? recompute) =>
      ApplyResult._(kind: AppliedKind.fieldOrExists, fieldRecompute: recompute);

  factory ApplyResult.setAdd(SetAddResult result) =>
      ApplyResult._(kind: AppliedKind.setAdd, setAddResult: result);

  factory ApplyResult.setRemove(SetRemoveResult result) =>
      ApplyResult._(kind: AppliedKind.setRemove, setRemoveResult: result);

  final AppliedKind kind;

  /// Non-null for `kind == fieldOrExists` unless the incoming operation
  /// was a pure idempotent re-apply (its `contentKey` was already fully
  /// processed) — mirrors `replica.dart`'s `apply()` returning early on
  /// `cls.containsKey(op.dot)` before ever reaching `_materialize`/
  /// `_recomputeField`.
  final FieldRecomputeResult? fieldRecompute;
  final SetAddResult? setAddResult;
  final SetRemoveResult? setRemoveResult;
}

/// The single entry point: given one [IncomingOperation], resolves it
/// against current `sync_*` state and writes back the result, exactly
/// mirroring `replica.dart`'s `apply()` dispatch (minus the frontier-bump/
/// idempotent-re-apply-detection steps that only make sense with a real
/// pull loop feeding it, § this file's own top doc comment).
class CausalEngine {
  CausalEngine({
    ContentKeyDedupEngine? dedup,
    DotRedirectResolver? redirects,
    FieldConflictResolver? fieldResolver,
    OrSetResolver? orSetResolver,
  }) : _dedup = dedup ?? const ContentKeyDedupEngine(),
       _redirects = redirects ?? const DotRedirectResolver(),
       _fieldResolver =
           fieldResolver ??
           FieldConflictResolver(redirects ?? const DotRedirectResolver()),
       _orSetResolver =
           orSetResolver ??
           OrSetResolver(
             dedup ?? const ContentKeyDedupEngine(),
             redirects ?? const DotRedirectResolver(),
           );

  final ContentKeyDedupEngine _dedup;
  // ignore: unused_field
  final DotRedirectResolver _redirects;
  final FieldConflictResolver _fieldResolver;
  final OrSetResolver _orSetResolver;

  /// Applies [op] inside [txn] (the caller's transaction — every write
  /// this call makes must be atomic with whatever else the caller is
  /// doing in the same pass, exactly like `replica.dart`'s single
  /// synchronous `apply()` call).
  Future<ApplyResult> apply(DatabaseExecutor txn, IncomingOperation op) async {
    switch (op.kind) {
      case 'set_add':
        final result = await _orSetResolver.applySetAdd(
          txn,
          entityTable: op.entityTable,
          entityId: op.entityId,
          fieldName: op.fieldName!,
          memberUuid: op.memberUuid!,
          dot: op.dot,
          hlc: op.hlc,
          contentKey: op.contentKey,
          valueJson: op.valueJson,
          frontier: op.frontier,
        );
        return ApplyResult.setAdd(result);

      case 'set_remove':
        final result = await _orSetResolver.applySetRemove(
          txn,
          entityTable: op.entityTable,
          entityId: op.entityId,
          fieldName: op.fieldName!,
          memberUuid: op.memberUuid!,
          targetDots: op.targetDots ?? const [],
        );
        return ApplyResult.setRemove(result);

      case '__exists__':
      case 'field':
        return ApplyResult.fieldOrExists(await _applyFieldOrExists(txn, op));

      default:
        throw ArgumentError(
          'CausalEngine.apply: unknown operation kind "${op.kind}"',
        );
    }
  }

  /// Direct port of `apply()`'s field/`__exists__` branch:
  /// ```
  /// if (ck != null) {
  ///   ... dedup ...
  ///   if (cls.containsKey(op.dot)) return; // already processed
  ///   ... skipMaterialize / recheckTrigger ...
  /// }
  /// if (!skipMaterialize) { _materialize(op); }
  /// if (recheckTrigger != null) { _recomputeField(op.fieldKey, extraCandidate: recheckTrigger); }
  /// ```
  /// Collapsed here into one call: whether the outcome is "materialize
  /// normally" (no contentKey, or first-seen) or "recheck-on-discovery"
  /// (a redirect was just recorded), `_fieldResolver.recompute` is called
  /// exactly once, with the incoming operation as its `extraCandidate` —
  /// the resolver's own candidate-set construction (current winner +
  /// retained conflict copies + this extra candidate) makes "materialize"
  /// and "recheck" the same call, not two separate code paths, which is
  /// itself a faithful reflection of `replica.dart`'s own unification
  /// (`_materialize`'s field/exists branch calls `_recomputeField` too —
  /// see `replica.dart`'s `_materialize`).
  Future<FieldRecomputeResult?> _applyFieldOrExists(
    DatabaseExecutor txn,
    IncomingOperation op,
  ) async {
    final candidate = FieldCandidate(
      dot: op.dot,
      hlc: op.hlc,
      contentKey: op.contentKey,
      valueJson: op.valueJson,
      blobHash: op.blobHash,
      frontier: op.frontier,
    );

    if (op.contentKey != null) {
      final dedupResult = await _dedup.process(
        txn,
        contentKey: op.contentKey!,
        dot: op.dot,
      );
      if (dedupResult.outcome == DedupOutcome.alreadyProcessed) {
        return null; // pure idempotent re-apply — nothing to recompute
      }
      // firstSeen / redirectedNonCanonical / canonicalSwapped all fall
      // through to the same recompute call below — the resolver's own
      // candidate-set construction handles each case correctly (see this
      // method's own doc comment).
    }

    return _fieldResolver.recompute(
      txn,
      entityTable: op.entityTable,
      entityId: op.entityId,
      fieldName: op.fieldName!,
      extraCandidate: candidate,
    );
  }
}
