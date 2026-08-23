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

    if (applied.isEmpty && missing.isNotEmpty) {
      final supersededRecessive = await _supersedeRecessiveAdds(
        txn,
        entityTable: entityTable,
        entityId: entityId,
        fieldName: fieldName,
        memberUuid: memberUuid,
      );
      if (supersededRecessive) {
        return SetRemoveResult(appliedTargets: targetDots, missingTargets: []);
      }
    }

    return SetRemoveResult(appliedTargets: applied, missingTargets: missing);
  }

  /// A `set_remove` supersedes a **recessive** (post-reset) add of the same
  /// member, even though it names a dot this replica has never seen.
  ///
  /// Why this exception exists, and why it is safe (M2.13, review round 3):
  /// `Hlc.zero`-stamped seeds were introduced so a post-reset re-seed LOSES
  /// rather than wins — but that mechanism reaches only field conflicts,
  /// because this resolver is add-wins plus `contentKey` dedup and stores
  /// the HLC without ever reading it. So a reset re-minted every live
  /// membership under a brand-new GENESIS dot, a peer's already-published
  /// `set_remove` targeting the OLD dot parked in `missing_referenced_dot`
  /// forever, and a tag assignment (or note/message linkage) the user had
  /// deliberately removed came back — on both devices. Same defect class as
  /// the one recessive seeds exist to close, surviving because "recessive"
  /// had been reasoned about only against the field path.
  ///
  /// The rule fires only when **every** live add-dot for the member is
  /// recessive, which is exactly the "all this replica has is its own
  /// re-statement" case:
  ///
  ///  * Outside a reset no operation is ever stamped [Hlc.zero], so no
  ///    ordinary path can reach this branch at all — add-wins is untouched.
  ///  * A genuine concurrent re-add (post-reset or otherwise) is drained
  ///    through the ordinary path with a real generated HLC, so the member
  ///    has a non-recessive live dot and the rule does not fire. Add-wins
  ///    still beats a remove that never saw it, as it must.
  ///  * A remove whose target resolves through [DotRedirectResolver] never
  ///    reaches here — `applied` is non-empty and the caller sees an
  ///    ordinary removal.
  ///
  /// Returning every target as applied (rather than parking the unresolved
  /// ones) is deliberate: the membership is gone, so re-attempting this
  /// remove later has nothing left to act on, and leaving a
  /// `missing_referenced_dot` entry behind would be a queue row no arrival
  /// can ever clear.
  Future<bool> _supersedeRecessiveAdds(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String memberUuid,
  }) async {
    const where =
        'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?';
    final args = [entityTable, entityId, fieldName, memberUuid];

    final rows = await txn.query(
      'sync_set_state',
      columns: const ['hlc'],
      where: where,
      whereArgs: args,
    );
    if (rows.isEmpty) return false;

    final recessiveHlc = Hlc.zero.toString();
    final allRecessive = rows.every((r) => r['hlc'] == recessiveHlc);
    if (!allRecessive) return false;

    await txn.delete('sync_set_state', where: where, whereArgs: args);
    return true;
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
