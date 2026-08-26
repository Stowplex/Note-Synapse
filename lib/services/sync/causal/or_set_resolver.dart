// OR-Set (observed-remove set) membership resolution against
// `sync_set_state` — § Architecture 1's canonical-winner-plus-redirect
// design for set membership, deliberately simpler than field-conflict
// resolution: no domination-based winner-picking at all. Direct SQL port
// of `test/sync_protocol/replica.dart`'s `_materializeSetAdd`/
// `_materializeSetRemove`/`setContains`, reusing `content_key_dedup.dart`
// for the `contentKey` case and `dot_redirect_resolver.dart` for
// `set_remove`'s `targetDots` resolution.
//
// M2.5, § Architecture 11.4 ("local causal engine").
//
// ---------------------------------------------------------------------
// **`test/sync_protocol/replica.dart` is the CORRECTNESS REFERENCE, not
// merely the historical source of this code — and any future divergence
// from it must be written down here.**
// ---------------------------------------------------------------------
// That model is the artifact the M0 abstract suite (`exhaustive_test.dart`,
// `randomized_test.dart`, `regression_test.dart`) actually proves properties
// about; this file is a port of it, and inherits those properties only for
// as long as it agrees with it. The M0 suite does not execute this file, so
// it cannot notice a divergence — which is exactly how the M2.13 round-4
// divergence shipped: an extra rule was added to `applySetRemove` here
// (a `set_remove` naming an unresolvable dot superseded a member whose live
// add-dots were all `Hlc.zero`), nothing recorded that the port had stopped
// being a port, the abstract suite stayed green because it never ran this
// code, and the rule turned out to be non-convergent under reordering.
// Round 5 removed it and restored ordinary add-wins (see "post-reset
// re-add" below).
//
// So: a deliberate deviation from the model is allowed — the faithful-port
// note below is itself one axis of that discussion — but it must be
// STATED, here, with its reason, and it must come with a test in
// `test/sync_engine/causal/` that pins the new behaviour, because no other
// test in this repository is looking.
//
// ---------------------------------------------------------------------
// **The post-reset re-add residual (M2.13, review rounds 3–5).**
// ---------------------------------------------------------------------
// A dataset reset (`dataset_reset.dart`) re-seeds this device's whole
// library. `field` operations from that re-seed are stamped [Hlc.zero] so
// they LOSE every conflict they enter. That mechanism cannot reach here:
// membership is add-wins plus `contentKey` dedup, and this resolver stores
// an add's HLC without ever reading it.
//
// The consequence, stated plainly rather than mechanised away: **a reset can
// resurrect a membership a peer deliberately removed.** The re-seed mints a
// brand-new add-dot; the peer's `set_remove` names the retired dot, which
// this replica has no record of, so it resolves nothing and the re-asserted
// membership stays live — and then the peer pulls the re-add and applies
// add-wins too.
//
// **This is a disclosed residual, and it is the right answer for this
// schema.** It is convergent (every replica sees the same re-add and applies
// the same rule), it loses nothing (requirement 2 is about losing edits, and
// this preserves), and it is honest OR-Set semantics — the resetting device
// genuinely IS re-asserting the membership.
//
// **Round 4's attempt to remove it instead, and why it was retracted.** The
// rule was "a `set_remove` whose targets do not resolve supersedes a member
// whose live add-dots are all recessive". Three confirmed defects:
//
//   1. **Order-dependent, so replicas diverge permanently.** Both conjuncts
//      (`applied.isEmpty && missing.isNotEmpty`, and "every live dot is
//      `Hlc.zero`") were predicates over `sync_set_state` as it stood when
//      the remove happened to be processed. Add-then-remove left 0 live
//      dots; remove-then-add left 1. Nothing constrains delivery order, so
//      two devices ended with the tag assignment present on one and absent
//      on the other, forever.
//   2. **Unrecoverable.** `pull_phase.dart`'s `missing_referenced_dot` sweep
//      gates every replay behind `_referencedDotIsResolvable`, which
//      implements the ordinary matching rule and returns `false` in exactly
//      the shape the new rule was written for — so the parked remove was
//      never retried.
//   3. **It did not fix its own target case** in the `deviceLogDiverged`
//      state. A reset re-pulls this device's retired logs by design, and an
//      ordinary post-trigger `set_add` carries `contentKey: null`, so it
//      does not dedup against the GENESIS-keyed re-seed. Both dots are live,
//      the peer's remove resolves the ordinary one, `applied` is non-empty,
//      and the rule is skipped.
//
// Removing the residual for real needs a durable ledger of applied removes
// — a permanent record that dot `X` was once live and has been removed —
// which this milestone's schema does not have (see
// [SetRemoveResult.missingTargets], whose own doc comment discloses that
// absence). Without it, every candidate rule is a predicate over current
// state, and every predicate over current state is order-dependent. The
// residual is therefore recorded in `dataset_reset.dart`, in the reset
// confirmation dialog's user-facing text, and pinned by an explicitly
// reasoned test in `test/sync_engine/causal/or_set_resolver_test.dart`.
//
// **The one subtle, faithfully-preserved behavior**: `replica.dart`'s
// `apply()` only ever calls `_materialize` (which is what actually inserts
// into `setState`) for the FIRST-seen operation sharing a given
// `contentKey` — every later arrival sharing that `contentKey`, even one
// that becomes the new lexicographically-canonical dot via a canonical
// swap, is `skipMaterialize`d unconditionally:
// ```
// if (existingCanonical == null) {
//   dedupIndex[ck] = op.dot; // first-seen becomes canonical...
// } else {
//   ... skipMaterialize = true ...   // ...but EVERY later arrival, canonical-swap or not, skips materialize
// }
// if (!skipMaterialize) { _materialize(op); }
// ```
// So the row actually recorded live in `setState`/`sync_set_state` is
// whichever dot was FIRST LOCALLY OBSERVED, not necessarily the
// lexicographically-canonical one — the canonical/redirect bookkeeping
// still converges correctly across replicas (`sync_dedup_index`/`sync_dot_
// redirects` always reflect the true global-minimum dot), but the actual
// materialized row's identity does not need to move once written, because
// OR-Set membership only ever cares about "is there at least one live
// dot for this member" (`setContains`), and any `set_remove` targeting
// ANY alias (canonical or not) still finds and removes the live row via
// `resolveDot`. This is ported here exactly as coded, not "fixed" to
// re-point the materialized row at the canonical dot on every swap — doing
// so would be a behavior change from the proven abstract model, not a
// faithful port.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../hlc.dart';
import 'content_key_dedup.dart';
import 'dot.dart';
import 'dot_redirect_resolver.dart';

enum SetAddOutcome {
  /// A live `sync_set_state` row was inserted for this exact dot.
  materialized,

  /// This dot shares a `contentKey` with an already-known member of the
  /// same logical add-event; a redirect was recorded (possibly a
  /// canonical swap), but per the faithful-port note above, nothing is
  /// (re-)materialized for it — the already-live row (whichever dot was
  /// first-seen) continues to represent the membership.
  dedupSkipped,

  /// This exact dot has already been fully processed before (idempotent
  /// re-apply) — a pure no-op.
  alreadyProcessed,
}

class SetAddResult {
  const SetAddResult({required this.outcome, required this.canonicalDot});

  final SetAddOutcome outcome;

  /// The contentKey class's canonical dot after this call (== [dot]
  /// itself when there was no `contentKey`).
  final Dot canonicalDot;
}

/// Result of resolving one `set_remove` operation's `targetDots`.
class SetRemoveResult {
  const SetRemoveResult({
    required this.appliedTargets,
    required this.missingTargets,
  });

  /// Target dots that resolved to a currently-live `sync_set_state` row —
  /// that row has already been deleted by this call.
  final List<Dot> appliedTargets;

  /// Target dots that could not be resolved to any currently-live
  /// `sync_set_state` row — § Architecture 1's `missing_referenced_dot`
  /// blocking reason. **Disclosed limitation, precisely stated**: this
  /// milestone's schema (`sync_set_state`/`sync_dedup_index`/`sync_dot_
  /// redirects`) has no permanent ledger of add-dots that were once live
  /// and have since been legitimately removed — once a row is deleted, no
  /// trace of its having ever existed survives here. This resolver
  /// therefore cannot distinguish "this dot has genuinely never been
  /// observed at all" (the case § Architecture 1 names — this replica
  /// hasn't pulled the seeding replica yet) from "this dot WAS observed
  /// and has already been correctly removed by an earlier, already-
  /// applied `set_remove`" — both surface identically as "no live row
  /// found." This is the conservative, safe direction: a redundant
  /// duplicate remove is reported as blocked (and would sit harmlessly,
  /// permanently un-resolved, in a future `sync_materialize_queue` entry)
  /// rather than ever being silently misapplied or silently dropped. See
  /// the milestone report for why building the permanent ledger needed to
  /// fully disambiguate this is judged out of scope for this milestone
  /// (no schema for it exists yet, and § Architecture 1 does not name one).
  final List<Dot> missingTargets;

  /// Whether this operation, as a whole, could not be fully applied and
  /// should be queued (`missing_referenced_dot`) for retry once the
  /// missing dot(s) are observed. Per this milestone's scope (see class
  /// doc comment on `or_set_resolver.dart`), the actual enqueue into
  /// `sync_materialize_queue` and the retry-when-unblocked sweep are
  /// M2.6/M2.7's job — this is a pure detection/reporting result.
  bool get blocked => missingTargets.isNotEmpty;
}

/// Resolves `set_add`/`set_remove` candidates against `sync_set_state`.
class OrSetResolver {
  const OrSetResolver(this._dedup, this._redirects);

  final ContentKeyDedupEngine _dedup;
  final DotRedirectResolver _redirects;

  /// Applies one `set_add` candidate. [contentKey] mirrors § Architecture
  /// 1's `contentKey` — present for a genesis-seed or external-edit-
  /// originated add (e.g. a conversation-message mapping seeded
  /// identically by two replicas, § Architecture 10), absent for an
  /// ordinary local add (e.g. an ordinary tag-note membership), exactly
  /// like a field/`__exists__` operation's `contentKey`.
  Future<SetAddResult> applySetAdd(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String memberUuid,
    required Dot dot,
    required Hlc hlc,
    String? contentKey,
    String? valueJson,
    required Map<String, int> frontier,
  }) async {
    if (contentKey != null) {
      final dedupResult = await _dedup.process(
        txn,
        contentKey: contentKey,
        dot: dot,
      );
      if (dedupResult.outcome == DedupOutcome.alreadyProcessed) {
        return SetAddResult(
          outcome: SetAddOutcome.alreadyProcessed,
          canonicalDot: dedupResult.canonicalDot,
        );
      }
      if (dedupResult.outcome != DedupOutcome.firstSeen) {
        return SetAddResult(
          outcome: SetAddOutcome.dedupSkipped,
          canonicalDot: dedupResult.canonicalDot,
        );
      }
      // firstSeen: fall through and materialize under this dot's own
      // identity, exactly like replica.dart's `_materialize` gating.
    }

    await txn.insert(
      'sync_set_state',
      {
        'entityTable': entityTable,
        'entityId': entityId,
        'fieldName': fieldName,
        'memberUuid': memberUuid,
        'authorId': dot.authorId,
        'authorSeq': dot.authorSeq,
        'hlc': hlc.toString(),
        'contentKey': contentKey,
        'frontierJson': _encodeFrontier(frontier),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      // Idempotent: re-applying the exact same dot (e.g. an overlapping
      // partial pull) must never throw against the PRIMARY KEY.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    return SetAddResult(outcome: SetAddOutcome.materialized, canonicalDot: dot);
  }

  /// Applies one `set_remove` candidate's [targetDots] (§ Architecture 1:
  /// "the add-dot(s) being observed as removed; each resolved through
  /// `sync_dot_redirects` before comparison/application" — direct port of
  /// `_materializeSetRemove`'s `resolveDot`-then-match-then-delete loop,
  /// extended only to REPORT (not silently swallow) an unresolvable
  /// target, per this milestone's brief).
  Future<SetRemoveResult> applySetRemove(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String memberUuid,
    required List<Dot> targetDots,
  }) async {
    final applied = <Dot>[];
    final missing = <Dot>[];

    for (final target in targetDots) {
      final resolvedTarget = await _redirects.resolveDot(txn, target);
      final rows = await txn.query(
        'sync_set_state',
        columns: const ['authorId', 'authorSeq'],
        where:
            'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
        whereArgs: [entityTable, entityId, fieldName, memberUuid],
      );

      Map<String, Object?>? matched;
      for (final r in rows) {
        final rowDot = Dot(r['authorId'] as String, r['authorSeq'] as int);
        final rowResolved = await _redirects.resolveDot(txn, rowDot);
        if (rowResolved == resolvedTarget) {
          matched = r;
          break;
        }
      }

      if (matched == null) {
        missing.add(target);
        continue;
      }

      await txn.delete(
        'sync_set_state',
        where:
            'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ? '
            'AND authorId = ? AND authorSeq = ?',
        whereArgs: [
          entityTable,
          entityId,
          fieldName,
          memberUuid,
          matched['authorId'],
          matched['authorSeq'],
        ],
      );
      applied.add(target);
    }

    return SetRemoveResult(appliedTargets: applied, missingTargets: missing);
  }

  /// Direct port of `setContains`: is there at least one live add-dot for
  /// this member?
  Future<bool> setContains(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String memberUuid,
  }) async {
    final rows = await txn.query(
      'sync_set_state',
      columns: const ['authorId'],
      where:
          'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
      whereArgs: [entityTable, entityId, fieldName, memberUuid],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Reuses the same flat `{authorId: maxSeq}` JSON convention as
  /// `outbox_drainer.dart`'s `_singleAuthorFrontierJson` and
  /// `field_candidate.dart` — no baseline-snapshot wrapper.
  String _encodeFrontier(Map<String, int> frontier) => jsonEncode(frontier);
}
