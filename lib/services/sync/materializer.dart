// Materialization — M2.7, § Architecture 11.6 of the CRDT-cloud-sync design
// (`plan-and-propse-the-glistening-dolphin.md`). The final missing piece
// before a pulled remote operation actually changes what a user sees: takes
// whatever M2.5's `CausalEngine.apply()` just resolved into `sync_field_
// state`/`sync_set_state` and writes it into the real `notes`/`tags`/...
// app-table row `pull_phase.dart` (M2.6) deliberately left untouched.
//
// **(c) Deliberately bypasses `DatabaseService`'s named mutation methods.**
// Per § 11.6(c)'s explicit decision: `updateNote`/`_persistNote` diff-and-
// reinsert `subnotes`/`note_tags` on every call regardless of which field
// changed — exactly the side effect a single-field CRDT materialization
// must not trigger. Every write here goes directly through `txn.update`/
// `txn.insert`/`txn.delete` against the real table.
//
// **"Did the winner actually change?" — [FieldRecomputeResult.winnerChanged]
// is trusted directly, not re-derived by diffing the row.** That field's own
// doc comment (`field_conflict_resolver.dart`) names this exact use:
// "Useful for a future M2.7 materializer to know whether app-table work is
// actually needed." `CausalEngine.apply` returns `null` for a pure
// idempotent re-apply (nothing to recompute at all) and a non-null
// [FieldRecomputeResult] with `winnerChanged: false` whenever the resolved
// winner's dot is unchanged from before this call — both cases are a
// correct, cheap no-op here.
//
// ---------------------------------------------------------------------
// **`__exists__` -> a real `INSERT`, and the ordering subtlety that shapes
// this file's whole `_materializeExists` design.**
// ---------------------------------------------------------------------
// A brand-new entity's `__exists__` operation and its initial per-column
// `field` operations are minted as SEPARATE, sequentially-numbered dots by
// `OutboxDrainer._processExistsTouch` (exists first, one field op per
// `syncScopeColumns` entry after) — and `pull_phase.dart` applies each
// commit in its OWN transaction, one at a time, in strict per-author seq
// order. So at the moment `__exists__` materializes, NONE of the entity's
// other sync-scope fields have arrived yet — there is no "current resolved
// value" to read for a NOT-NULL column like `notes.title`. The INSERT this
// file performs is therefore a **shell row**: `idColumn` + entityId,
// `createdAt`-equivalent (derived from the `__exists__` operation's own HLC
// wall-clock component — see `syncEntityCreatedAtColumnByTable`
// (`sync_table_shape.dart`), which is exactly
// what every entity table's `syncEntityCaptureScope` doc comment in
// `database_service.dart` means by "id/createdAt excluded"), and every
// `syncScopeColumns` entry set to a type-appropriate placeholder (its own
// SQL-declared default if one exists, else an empty/zero value for its
// declared type) — corrected into place moments later as each column's own
// field commit arrives and materializes through the ordinary field path.
//
// **Disclosed residual, not fixed here — a genuinely user-visible "ghost
// row" window.** Unlike `tags` (§ 11.6(e) below), which is deliberately
// forced tombstoned (`__deleted__ = 1`) at shell-insert time specifically to
// avoid this class of problem, a `notes` (or any other entity table's)
// shell row is genuinely LIVE the instant it's inserted: `__deleted__`
// takes the column's own SQL default (`0`), and `title`/other `NOT NULL`
// `syncScopeColumns` sit at their placeholder (`''`) until their own field
// commits arrive and correct them. Combined with `pull_phase.dart`'s
// documented `hasGap` mid-log stop and requirement 7's manual-only sync
// trigger (a user may not sync again for a while), a user can plausibly see
// a blank, live note in their UI for a real, if usually short, window
// between pulling `__exists__` and pulling `title`/`content`'s own commits
// — worse, potentially indefinitely if a gap genuinely stalls the rest of
// that log. This was an accepted trade-off of the shell-row design (the
// alternative — withholding the row from the real table until every
// initial field has arrived — would need its own separate "pending
// materialization" bookkeeping this milestone does not build), but it is a
// real, user-facing residual and is named here explicitly rather than left
// implicit: whether to extend `tags`' forced-safe-default treatment to
// other entity tables (or build some other mitigation) is left as an open
// product/design question for later work, not resolved by this milestone.
//
// **Columns that are neither `idColumn`, the createdAt-equivalent, nor in
// `syncScopeColumns` at all (an owner FK excluded from sync scope, e.g.
// `subnotes.noteId`/`attachments.noteId`/`app_revisions.appId`, or
// `user_apps.uuid`) can never be resolved by this file, by construction —
// M2.4's own capture-scope decisions, not something this milestone
// reopens.** If such a column is `NOT NULL` with no SQL-level default, this
// file will never have a real value for it and a placeholder would be
// permanently wrong (never corrected by any future operation, unlike a
// `syncScopeColumns` placeholder). Rather than insert a row with a garbage
// FK, `_materializeExists` detects this generically (via `PRAGMA
// table_info`, not a hardcoded per-table list) and skips the INSERT
// entirely for that entity — a disclosed residual, not a crash: brand-new
// cross-device creation of `subnotes`/`attachments`/`relationships`/
// `conversation_attachments`/`app_revisions`/`user_apps` does not yet
// materialize into a real row (their `__deleted__`-only sync scope already
// signals this — full content sync for the User-App/attachment/conversation
// families is M3/M4 scope per Phased Delivery, not M2).
//
// **Precisely, because "not synced" and "not minted" are different claims
// and have been conflated in review notes before:** every table in that
// list DOES mint and publish operations normally — their ids are portable,
// so `OutboxDrainer`/`SeedScanner` treat them like any other entity. What
// fails is only the receiving end. `user_apps` is the clearest case: its
// `uuid` column is `NOT NULL UNIQUE` and outside `syncScopeColumns`, so a
// receiving device parks every one of its field operations under
// `missing_exists` — 11 entries after four rounds, permanently — rather
// than creating the row. That is separate from, and must not be confused
// with, the `user_app_libraries`/`user_app_library_dependencies` case
// below, where nothing is minted in the first place. The SAME generic
// check also skips any table whose `idColumn` is a non-portable `INTEGER
// PRIMARY KEY AUTOINCREMENT` (`user_app_libraries`/
// `user_app_library_dependencies`) — a locally-assigned integer id from one
// device is meaningless on another, so materializing a brand-new row for
// these under a remote `entityId` would be actively wrong, not merely
// incomplete. See the milestone report for the full table-by-table trace.
//
// A `field` operation that resolves before its entity's `__exists__` has
// materialized (a real, if narrow, possibility across independently-pulled
// device logs, though not reachable through the ordinary "you can't edit
// what you haven't observed" app-usage pattern) is queued into
// `sync_materialize_queue` (`blockingReason = 'missing_exists'` — the value
// the schema's own doc comment already anticipated) and retried by
// [SyncMaterializer.sweepMissingExists], mirroring `pull_phase.dart`'s own
// `missing_referenced_dot` sweep for `set_remove`.
//
// ---------------------------------------------------------------------
// **(d) OR-Set membership materialization.**
// ---------------------------------------------------------------------
// `set_add` -> insert the membership row, if it is not already live. A
// SECOND, concurrent add-dot for the same member is a real and expected
// occurrence (the OR-Set property: `OrSetResolver.applySetAdd` returns
// `SetAddOutcome.materialized` for every dot that isn't `contentKey`-deduped
// away), and must be a harmless no-op against the real table.
//
// **M2.10 correction — this used to be an `INSERT OR IGNORE` of just the two
// id columns, and that combination silently discarded every mapping-table
// membership this codebase has ever synced.** All three mapping tables
// (`conversation_note_mapping`, `conversation_message_mapping`,
// `message_parents`) declare `createdAt INTEGER NOT NULL` with no default,
// and `message_parents` also declares `id TEXT PRIMARY KEY` — none of which
// a two-column INSERT supplies. `OR IGNORE` does not distinguish "this
// member is already live" from "this row violates NOT NULL", so every one
// of those INSERTs failed and was swallowed: a device would hold a live
// `sync_set_state` row for `conversations.noteIds` alongside a completely
// empty `conversation_note_mapping`, with no queue entry and no error.
// Fixed in two parts: `_insertMembershipRow` now builds the FULL row (the
// add-event payload M2.10 puts on the wire, plus a deterministic surrogate
// key where the table has one), and the duplicate-member case is handled by
// an explicit existence check so the INSERT itself can run WITHOUT a
// conflict algorithm — a constraint violation is now a loud error rather
// than an invisible no-op.
//
// `set_remove` -> after `OrSetResolver.applySetRemove` deletes the
// resolved dot's own `sync_set_state` row(s), this file deletes the real
// membership row only if a fresh query finds zero `sync_set_state` rows
// remaining for that member — a real `DELETE`, the one legitimate delete
// this milestone performs (these tables are correctly excluded from
// `_hardDeleteGuardedTables`, § 11.6(d)).
//
// ---------------------------------------------------------------------
// **(e) Auto-merge / collision detection — the architecturally distinct
// piece.**
// ---------------------------------------------------------------------
// Per § Architecture 10's "two categories of liveness-flipping event," any
// write that would set `tags.__deleted__` false or `tags.redirectTarget`
// null on an existing row is write-driven and must run an effective-
// liveness collision check before its own write commits. This file's
// `_resolveTagLivenessTransition` is that check, invoked from
// `_materializeField` for exactly `(table: 'tags', field: '__deleted__' |
// 'redirectTarget')` writes whose OLD row value was the opposite polarity.
//
// **Why `_materializeExists` forcibly writes `__deleted__ = 1` for a brand-
// new `tags` row, unconditionally, regardless of the column's own SQL
// default of 0.** `idx_tags_name_live` is a partial unique index over
// raw-live, non-redirecting tags. If a new tag's shell row were inserted
// raw-live (the schema's own default), a placeholder `name = ''` would
// briefly, genuinely occupy the live-name-index slot for `''` — and if TWO
// different brand-new tags are pulled from the SAME device's log before
// either's real `name` has arrived (an ordinary, reachable interleaving:
// each is its own separate commit), the SECOND such shell INSERT would hit
// a real `UNIQUE` violation on the shared placeholder name, not a
// hypothetical one. Starting every new tag tombstoned sidesteps this
// entirely — `syncScopeColumns` for `tags` is ordered `name, color,
// __deleted__, redirectTarget` (see `database_service.dart`) specifically
// so `name`/`color` always materialize, in the SAME per-author seq order
// they were minted, BEFORE `__deleted__`'s own field commit — so by the
// time `__deleted__` flips this row's raw state toward live (a real
// write-driven transition, per the paragraph above), the collision check
// always has the tag's REAL name to check against, never a placeholder.
//
// **The creation-dot / tie-break lookup.** § Architecture 10's tie-break
// ("lowest `(authorId, authorSeq)` of each tag's own creation dot") is
// directly queryable, not something this file needs to track separately:
// `sync_field_state`'s row for `(entityTable: 'tags', entityId: <tagId>,
// fieldName: '__exists__')` already stores exactly that dot (`authorId`/
// `authorSeq` columns) — every tag this device has ever materialized went
// through `_materializeExists`, which always resolves `__exists__` before
// any other field for that same tag can materialize (per-author seq
// ordering). `_creationDot` is a one-row lookup against that existing
// table.
//
// **The cycle-suppressed-but-effectively-live collision case, and why this
// file's check is narrower than a general read-path walk (deliberately, per
// this milestone's own scope boundary).** `findLiveTagByName`
// (`database_service.dart`) checks RAW liveness only (`__deleted__ = 0 AND
// redirectTarget IS NULL`) — it does NOT treat a raw-tombstoned,
// redirecting cycle-loser as live, so it is insufficient for this file's
// collision check on its own (§ 11.6(e) names this gap explicitly).
// `_findEffectivelyLiveTagByName` extends it with a bounded, NAME-SCOPED
// cycle walk: for each same-named, raw-tombstoned/redirecting candidate,
// walk its `redirectTarget` chain looking for a cycle back to itself, and if
// found, apply the SAME edge tie-break the design's cycle-suppression
// mechanism uses (lowest `(HLC, authorId, authorSeq)` of each cycle edge's
// own redirect-write dot) to determine whether THIS candidate is the
// suppressed (hence effectively-live) member. This is sufficient for what
// this write path needs (an accurate liveness answer for ONE candidate
// name) without building the general, all-tags, `O(total tags)` read-path
// walk § 11.6(e) explicitly defers to later, out-of-scope work (there is no
// production read path yet that consumes "effective" tag visibility
// generally — only this collision check does).
//
// **Minting, and why it goes through `CausalEngine.apply` rather than a
// direct `sync_field_state` write.** § 11.6(e) requires the SAME-outcome
// convergence property § Architecture 10 (round 19) establishes:
// `contentKey`-tagged auto-merge writes, so two replicas independently
// detecting and minting the identical collision resolution silently dedup
// via the ALREADY-BUILT `contentKey` fast path, rather than each showing up
// as a spurious, permanent `sync_conflict_copies` record. Routing the mint
// through `_engine.apply` (exactly like an ordinary incoming operation, just
// with THIS device as author) gets that property for free — the resolved
// value is then materialized into the real row via the same generic field
// path this file already has (never itself re-triggering the collision
// check: both minted fields move the loser's raw state AWAY from live, the
// opposite direction of what the check gates on, so there is no recursion
// risk).
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'causal/causal_comparator.dart' show hlcTieBreakWins;
import 'causal/causal_engine.dart';
import 'causal/dot.dart';
import 'causal/field_conflict_resolver.dart';
import 'causal/or_set_resolver.dart';
import 'frontier.dart';
import 'hlc.dart';
import 'seq_counter.dart';
import 'sync_table_shape.dart';

/// `sync_materialize_queue.blockingReason` for a field/set_add operation
/// whose entity row has not materialized (via its own `__exists__`) yet —
/// the value the schema's own doc comment in `database_service.dart`
/// already anticipated (`'missing_exists'`), not a new one invented here.
const String missingExistsBlockingReason = 'missing_exists';

/// `sync_materialize_queue.blockingReason` for a `set_add` whose membership
/// table declares a `NOT NULL`, no-default column that neither the
/// operation's payload nor any of `_insertMembershipRow`'s fallbacks can
/// supply.
///
/// Not reachable for any of today's five membership tables — but that is a
/// statement about today's schema, checked by a test, NOT a property of this
/// code, and an earlier version of this comment asserted it as if it were
/// the latter while the reason was in fact reachable through an ordinary
/// pre-M2.10 `set_add`. Entries under this reason are retried by
/// [SyncMaterializer.sweepMissingExists] on every pull.
const String unfillableMembershipColumnBlockingReason =
    'unfillable_membership_column';

/// What one membership-row insert attempt actually did. Returned rather
/// than inferred so [SyncMaterializer.sweepMissingExists] can tell "this
/// queue entry is resolved, delete it" from "this entry is STILL
/// unfillable, leave it exactly as it was" — an earlier version could not,
/// so a still-unfillable retry re-inserted a fresh queue row and deleted the
/// original, resetting `enqueuedAt` (destroying the only aging signal the
/// row had) and counting itself as `resolved`.
enum MembershipInsertOutcome {
  /// The real membership row was written.
  inserted,

  /// A row for this member was already live — the OR-Set duplicate-add
  /// no-op, and a legitimate success.
  alreadyLive,

  /// A `NOT NULL` column could not be filled; a queue entry was written (or
  /// re-written) under [unfillableMembershipColumnBlockingReason].
  parkedUnfillable,
}

class SyncMaterializer {
  /// Deliberately takes no `DatabaseService` of its own (unlike
  /// `OutboxDrainer`/`PullPhase`) — every method here takes its `txn`/`db`
  /// explicitly as a parameter instead, matching `CausalEngine`'s own
  /// stateless design (this class only ever runs inside a caller-owned
  /// transaction, never opens one of its own).
  /// Memoizes `PRAGMA`-derived, immutable schema facts for this
  /// instance's lifetime — `_writeResolvedFieldValue` runs once per
  /// materialized field, which is the hottest loop in a pull.
  final Map<String, bool> _portabilityCache = {};

  SyncMaterializer(this._seqCounter, this._hlc, {CausalEngine? engine})
    : _engine = engine ?? CausalEngine();

  final SeqCounter _seqCounter;
  final HybridLogicalClock _hlc;
  final CausalEngine _engine;

  late final Map<String, SyncEntityCaptureScope> _entityScopesByTable = {
    for (final scope in DatabaseService.syncEntityCaptureScopes)
      scope.table: scope,
  };

  late final Map<String, SyncSetCaptureScope> _setScopesByEntityAndField = {
    for (final scope in DatabaseService.syncSetCaptureScopes)
      '${scope.entityTable} ${scope.fieldName}': scope,
  };

  /// `createdAt`-equivalent column per entity table — see this file's top
  /// doc comment. Derived from the `__exists__` operation's own HLC
  /// wall-clock component at insert time; absent entries have no such
  /// column (`tag_workflow_bindings`) or the column is itself unresolvable
  /// for other reasons already (`app_revisions.revisionTimestamp`, whose
  /// entity is unresolvable regardless — see the generic NOT-NULL check).

  // ── Top-level entry point, called by pull_phase.dart per resolved op ──

  /// Materializes whatever [result] resolved for [op] into the real
  /// app-table row(s) — the single call site `pull_phase.dart` needs.
  /// [ownAuthorId] is this device's own `authorId`, needed only for § 11.6
  /// (e)'s auto-merge minting.
  Future<void> materialize(
    DatabaseExecutor txn, {
    required IncomingOperation op,
    required ApplyResult result,
    required String ownAuthorId,
  }) async {
    switch (result.kind) {
      case AppliedKind.fieldOrExists:
        await _materializeFieldOrExists(
          txn,
          op: op,
          result: result.fieldRecompute,
          ownAuthorId: ownAuthorId,
        );
      case AppliedKind.setAdd:
        await _materializeSetAdd(txn, op: op, result: result.setAddResult!);
      case AppliedKind.setRemove:
        await _materializeSetRemove(
          txn,
          op: op,
          result: result.setRemoveResult!,
        );
    }
  }

  /// § 11.7-style bounded sweep, run once per `pull()` call alongside
  /// `pull_phase.dart`'s own `missing_referenced_dot` sweep: retries every
  /// currently-queued `missing_exists` row whose blocking dependency has
  /// since materialized. The row's own `entityTable`/`entityId` columns
  /// always identify the OWNING entity (needed to reconstruct the
  /// operation), which may differ from what was actually being waited on.
  ///
  /// **`set_add` rows are FULLY re-verified via [_setAddBlocker] before any
  /// `INSERT` is attempted — never just "the one recorded blocker now
  /// exists."** A `set_add` has TWO independent prerequisites (owner row,
  /// member row); only one was ever recorded per queue entry (whichever was
  /// checked first and found missing). Trusting that single recorded
  /// blocker having resolved as sufficient proof was a real, confirmed bug
  /// — see [_setAddBlocker]'s own doc comment for the exact failure this
  /// closes. If the full re-check finds a DIFFERENT (or still the same)
  /// blocker, this row's own record is updated in place (not deleted) so
  /// the next sweep checks the right thing, and the row is left queued
  /// rather than the `INSERT` ever being attempted speculatively.
  ///
  /// **[unfillableMembershipColumnBlockingReason] rows are swept here too,
  /// deliberately.** A queue reason that nothing anywhere reads is not a
  /// deferral, it is a wedge with better paperwork: the first version of
  /// this milestone's membership fix parked such rows under a reason no
  /// reader existed for, and a device ended up holding a live
  /// `sync_set_state` row beside a permanently empty
  /// `conversation_note_mapping` — the exact signature the fix was meant to
  /// eliminate. Sweeping them costs one re-attempt per pull and means a
  /// build that learns to fill the column drains the backlog by itself.
  Future<int> sweepMissingExists(
    Database db, {
    required String ownAuthorId,
  }) async {
    var resolved = 0;
    final rows = await db.query(
      'sync_materialize_queue',
      where: 'blockingReason IN (?, ?)',
      whereArgs: [
        missingExistsBlockingReason,
        unfillableMembershipColumnBlockingReason,
      ],
    );
    for (final row in rows) {
      final id = row['id'] as int;
      final entityTable = row['entityTable'] as String;
      final entityId = row['entityId'] as String;
      final payload =
          jsonDecode(row['operationJson'] as String) as Map<String, dynamic>;

      if (payload['kind'] == 'set_add') {
        final fieldName = payload['fieldName'] as String;
        final memberUuid = payload['memberUuid'] as String?;
        // Every set_add enqueue records its memberUuid, so this is defensive
        // only — but a malformed row must leave the entry parked for
        // inspection, never abort the sweep (and with it the user's whole
        // sync session) with a null assertion.
        if (memberUuid == null) continue;
        final blocker = await _setAddBlocker(
          db,
          entityTable: entityTable,
          entityId: entityId,
          fieldName: fieldName,
          memberUuid: memberUuid,
        );
        if (blocker != null) {
          // Still blocked — possibly on a DIFFERENT prerequisite than what
          // was originally recorded (the owner may have just resolved while
          // the member still hasn't). Keep this entry's own record accurate
          // for the next sweep rather than leaving it pointing at an
          // already-resolved dependency forever.
          if (blocker.$1 != payload['waitingOnTable'] ||
              blocker.$2 != payload['waitingOnId']) {
            await db.update(
              'sync_materialize_queue',
              {
                'operationJson': jsonEncode({
                  ...payload,
                  'waitingOnTable': blocker.$1,
                  'waitingOnId': blocker.$2,
                }),
                'blockingKey': '${blocker.$1}:${blocker.$2}',
              },
              where: 'id = ?',
              whereArgs: [id],
            );
          }
          continue;
        }

        final setScope = _setScopesByEntityAndField['$entityTable $fieldName'];
        if (setScope == null) continue;
        final outcome = await db.transaction((txn) async {
          // Same full row build (and same narrowed conflict handling) as the
          // first-attempt path — a retry must not write a thinner row than
          // the original attempt would have. The payload comes from the
          // queued operation itself, which `_enqueueMissingExists` records.
          final result = await _insertMembershipRow(
            txn,
            scope: setScope,
            entityId: entityId,
            memberUuid: memberUuid,
            payloadJson: payload['valueJson'] as String?,
            hlcWallMs: payload['hlcWallMs'] as int? ?? 0,
          );
          if (result == MembershipInsertOutcome.parkedUnfillable) {
            // `_insertMembershipRow` just wrote a NEW queue row for the same
            // still-unfillable membership. Undo that and keep the ORIGINAL
            // entry instead, so `enqueuedAt` keeps telling the truth about
            // how long this has been stuck.
            await txn.delete(
              'sync_materialize_queue',
              where: 'blockingKey = ? AND id != ?',
              whereArgs: [
                '${setScope.membershipTable}:${payload['unfillableColumn'] ?? ''}',
                id,
              ],
            );
            return result;
          }
          await txn.delete(
            'sync_materialize_queue',
            where: 'id = ?',
            whereArgs: [id],
          );
          return result;
        });
        // Only a real resolution counts. Reporting a still-parked row as
        // resolved is how a backlog looks like progress.
        if (outcome != MembershipInsertOutcome.parkedUnfillable) resolved++;
        continue;
      }

      // 'field' kind: a single prerequisite (the owning entity itself).
      final waitingOnTable = payload['waitingOnTable'] as String;
      final waitingOnId = payload['waitingOnId'] as String;
      final waitingOnScope = _entityScopesByTable[waitingOnTable];
      if (waitingOnScope == null) continue;
      if (!await _rowExists(db, waitingOnScope, waitingOnId)) {
        continue; // still blocked
      }

      final ownerScope = _entityScopesByTable[entityTable];
      if (ownerScope == null) continue;

      await db.transaction((txn) async {
        await _writeResolvedFieldValue(
          txn,
          scope: ownerScope,
          entityId: entityId,
          fieldName: payload['fieldName'] as String,
          ownAuthorId: ownAuthorId,
        );
        await txn.delete(
          'sync_materialize_queue',
          where: 'id = ?',
          whereArgs: [id],
        );
      });
      resolved++;
    }
    return resolved;
  }

  // ── Field / __exists__ materialization ────────────────────────────────

  Future<void> _materializeFieldOrExists(
    DatabaseExecutor txn, {
    required IncomingOperation op,
    required FieldRecomputeResult? result,
    required String ownAuthorId,
  }) async {
    if (result == null) return; // pure idempotent re-apply — nothing to do
    if (!result.winnerChanged) {
      return; // resolved winner is unchanged — no app-table work needed
    }

    final scope = _entityScopesByTable[op.entityTable];
    if (scope == null) return; // not a materializable table (defensive)

    if (op.kind == existsFieldSentinel) {
      await _materializeExists(txn, scope, op.entityId, op.hlc.wallMs);
      return;
    }

    if (!scope.syncScopeColumns.contains(op.fieldName)) return; // defensive
    if (!await _rowExists(txn, scope, op.entityId)) {
      await _enqueueMissingExists(
        txn,
        entityTable: op.entityTable,
        entityId: op.entityId,
        fieldName: op.fieldName!,
        waitingOnTable: op.entityTable,
        waitingOnId: op.entityId,
      );
      return;
    }

    await _writeResolvedFieldValue(
      txn,
      scope: scope,
      entityId: op.entityId,
      fieldName: op.fieldName!,
      ownAuthorId: ownAuthorId,
    );
  }

  /// Re-reads `sync_field_state`'s CURRENT winner for
  /// `(scope.table, entityId, fieldName)` and writes it into the real row —
  /// shared by the ordinary pull path and [sweepMissingExists]'s retry.
  ///
  /// **The portability guard here is the one that actually stops
  /// cross-device row corruption, and it was missing.** `_materializeExists`
  /// has always refused to INSERT a row under a non-portable integer id —
  /// but this method does not need an INSERT to do damage: it UPDATEs
  /// `WHERE idColumn = entityId`, so a `field` operation carrying a foreign
  /// device's locally-assigned integer id silently overwrites whatever
  /// local row happens to occupy that id. Reproduced from an everyday
  /// action with no update call site involved at all — see
  /// `hasPortableEntityId`'s doc comment (`sync_table_shape.dart`) for the
  /// full trace. Skipping is correct and complete here: a table whose ids
  /// cannot travel has no cross-device row to write, so there is nothing
  /// being lost by declining, and the operation was never materializable in
  /// the first place (its `__exists__` is skipped by the same predicate).
  Future<void> _writeResolvedFieldValue(
    DatabaseExecutor txn, {
    required SyncEntityCaptureScope scope,
    required String entityId,
    required String fieldName,
    required String ownAuthorId,
  }) async {
    if (!await hasPortableEntityId(
      txn,
      scope.table,
      scope.idColumn,
      cache: _portabilityCache,
    )) {
      return;
    }

    final valueJson = await _readFieldStateValueJson(
      txn,
      scope.table,
      entityId,
      fieldName,
    );
    if (valueJson == null) {
      return; // defensive — should always be present once winnerChanged fired
    }
    final decoded = jsonDecode(valueJson);

    Map<String, Object?> toWrite = {fieldName: decoded};
    if (scope.table == 'tags' &&
        (fieldName == '__deleted__' || fieldName == 'redirectTarget')) {
      final currentRow = (await txn.query(
        'tags',
        where: 'id = ?',
        whereArgs: [entityId],
        limit: 1,
      )).first;
      toWrite = await _resolveTagLivenessTransition(
        txn,
        tagId: entityId,
        fieldName: fieldName,
        proposedValue: decoded,
        currentRow: currentRow,
        ownAuthorId: ownAuthorId,
      );
    }

    await txn.update(
      scope.table,
      toWrite,
      where: '${scope.idColumn} = ?',
      whereArgs: [entityId],
    );
  }

  /// Turns a resolved `__exists__` into a real `INSERT` — a shell row for
  /// any not-yet-arrived `syncScopeColumns` entry, corrected in place as
  /// each column's own field commit materializes. See this file's top doc
  /// comment for the full reasoning, including why some tables are
  /// generically, deliberately skipped.
  Future<void> _materializeExists(
    DatabaseExecutor txn,
    SyncEntityCaptureScope scope,
    String entityId,
    int existsHlcWallMs,
  ) async {
    if (await _rowExists(txn, scope, entityId)) return; // already materialized

    final columns = await syncTableInfo(txn, scope.table);
    final idColumnInfo = columns
        .where((c) => c['name'] == scope.idColumn)
        .firstOrNull;
    if (idColumnInfo == null) return; // defensive
    if (isNonPortableIntegerPrimaryKey(idColumnInfo)) {
      // e.g. user_app_libraries/user_app_library_dependencies — see top doc
      // comment, and `hasPortableEntityId` (`sync_table_shape.dart`), which
      // is the same predicate this and `_writeResolvedFieldValue` both use.
      return;
    }

    final createdAtColumn = syncEntityCreatedAtColumnByTable[scope.table];
    final row = <String, Object?>{scope.idColumn: entityId};
    var resolvable = true;

    for (final col in columns) {
      final name = col['name'] as String;
      if (name == scope.idColumn) continue;
      if (name == createdAtColumn) {
        row[name] = existsHlcWallMs;
        continue;
      }
      if (scope.syncScopeColumns.contains(name)) {
        final resolved = await _readFieldStateValueJson(
          txn,
          scope.table,
          entityId,
          name,
        );
        row[name] = resolved != null
            ? jsonDecode(resolved)
            : _placeholderDefault(col);
        continue;
      }
      final notNull = (col['notnull'] as int) != 0;
      final hasDefault = col['dflt_value'] != null;
      if (notNull && !hasDefault) {
        // An owner FK or other permanently-unresolvable column — see top
        // doc comment. Never materializable under current M2.4 capture
        // scope; skip the whole INSERT rather than write a garbage row.
        resolvable = false;
        break;
      }
      // Nullable, or has its own SQL default — omit; SQLite fills it in.
    }

    if (!resolvable) return;

    if (scope.table == 'tags') {
      // Forced tombstone-at-insert — see top doc comment ("Why
      // _materializeExists forcibly writes __deleted__ = 1").
      row['__deleted__'] = 1;
    }

    await txn.insert(
      scope.table,
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ── § 11.6(e): tags auto-merge / collision detection ──────────────────

  /// Returns the column map that should actually be written for this
  /// `__deleted__`/`redirectTarget` write. For an ordinary (non-liveness-
  /// flipping) write, this is just `{fieldName: proposedValue}` unchanged.
  /// For a write-driven liveness transition (§ Architecture 10), this runs
  /// the effective-liveness collision check first, per this file's top doc
  /// comment.
  Future<Map<String, Object?>> _resolveTagLivenessTransition(
    DatabaseExecutor txn, {
    required String tagId,
    required String fieldName,
    required Object? proposedValue,
    required Map<String, Object?> currentRow,
    required String ownAuthorId,
  }) async {
    final becomingUndeleted =
        fieldName == '__deleted__' &&
        currentRow['__deleted__'] == 1 &&
        proposedValue == 0;
    final becomingUnredirected =
        fieldName == 'redirectTarget' &&
        currentRow['redirectTarget'] != null &&
        proposedValue == null;
    if (!becomingUndeleted && !becomingUnredirected) {
      return {fieldName: proposedValue};
    }

    final name = currentRow['name'] as String?;
    if (name == null) {
      return {
        fieldName: proposedValue,
      }; // defensive — should never happen post-M2.7 name fix
    }

    final collision = await _findEffectivelyLiveTagByName(
      txn,
      name,
      excludeTagId: tagId,
    );
    if (collision == null) {
      return {fieldName: proposedValue}; // no collision — proceed normally
    }
    final collisionId = collision['id'] as String;

    final incomingDot = await _creationDot(txn, tagId);
    final collisionDot = await _creationDot(txn, collisionId);
    if (incomingDot == null || collisionDot == null) {
      // Cannot determine the tie-break (should not happen — every
      // materialized tag has an __exists__ dot). Fail safe: never let this
      // write make the tag raw-live against an unresolved tie-break.
      return {'__deleted__': 1, 'redirectTarget': collisionId};
    }

    final incomingWins = incomingDot.compareTo(collisionDot) < 0;
    if (incomingWins) {
      // The incoming write proceeds live; the pre-existing LOCAL colliding
      // tag becomes the loser — this is new local state nothing minted
      // before now, so it must be minted and pushed.
      await _mintAutoMergeLoserPair(
        txn,
        loserTagId: collisionId,
        winnerTagId: tagId,
        ownAuthorId: ownAuthorId,
      );
      return {fieldName: proposedValue};
    } else {
      // The incoming write loses — amend its own outcome, and mint the
      // durable pair for its OWN row too, so this device's own sync_field_
      // state (and future pushes) carry the resolution forward rather than
      // silently disagreeing with what was just written into the real row.
      await _mintAutoMergeLoserPair(
        txn,
        loserTagId: tagId,
        winnerTagId: collisionId,
        ownAuthorId: ownAuthorId,
      );
      return {'__deleted__': 1, 'redirectTarget': collisionId};
    }
  }

  /// `findLiveTagByName`-equivalent, extended to also match a raw-
  /// tombstoned, redirecting cycle-loser (effectively live) — see this
  /// file's top doc comment for why `findLiveTagByName` itself is
  /// insufficient here.
  Future<Map<String, Object?>?> _findEffectivelyLiveTagByName(
    DatabaseExecutor txn,
    String name, {
    required String excludeTagId,
  }) async {
    final rawLive = await txn.query(
      'tags',
      where:
          'name = ? AND __deleted__ = 0 AND redirectTarget IS NULL AND id != ?',
      whereArgs: [name, excludeTagId],
      limit: 1,
    );
    if (rawLive.isNotEmpty) return rawLive.first;

    final candidates = await txn.query(
      'tags',
      where: 'name = ? AND redirectTarget IS NOT NULL AND id != ?',
      whereArgs: [name, excludeTagId],
    );
    for (final candidate in candidates) {
      if (await _isCycleSuppressedLoser(txn, candidate['id'] as String)) {
        return candidate;
      }
    }
    return null;
  }

  /// Bounded walk of [tagId]'s `redirectTarget` chain looking for a cycle
  /// back to itself; if found, [tagId] is effectively live iff its own
  /// outgoing redirect edge is the lowest-ranked among the cycle's edges
  /// (§ Architecture 10's cycle tie-break, ranked by each edge's own
  /// redirect-write dot).
  Future<bool> _isCycleSuppressedLoser(
    DatabaseExecutor txn,
    String tagId,
  ) async {
    const maxHops = 64;
    final path = <String>[tagId];
    var current = tagId;
    for (var i = 0; i < maxHops; i++) {
      final rows = await txn.query(
        'tags',
        columns: ['redirectTarget'],
        where: 'id = ?',
        whereArgs: [current],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final next = rows.first['redirectTarget'] as String?;
      if (next == null) {
        return false; // chain terminates in an ordinary, non-cyclic tombstone
      }
      if (next == tagId) {
        return _isLowestRankedEdgeInCycle(txn, [...path, next]);
      }
      if (path.contains(next)) {
        return false; // a cycle not involving tagId — irrelevant here
      }
      path.add(next);
      current = next;
    }
    return false; // exceeded the defensive bound — treat conservatively as not-suppressed
  }

  /// [cycleNodes] is a closed loop `[tagId, n2, ..., tagId]`. Each edge
  /// `cycleNodes[i] -> cycleNodes[i+1]` is ranked by `(HLC, authorId,
  /// authorSeq)` of the dot that wrote `cycleNodes[i]`'s own
  /// `redirectTarget` field — § Architecture 10's cycle tie-break exactly
  /// ("ranked by (HLC, authorId, authorSeq) of the redirect-write operation
  /// that established it"), not `(authorId, authorSeq)` alone. This
  /// matters beyond style: this ranking gets baked permanently into a
  /// minted write the moment a collision resolves, so it must agree with
  /// whatever a future spec-faithful general read-path walk would compute,
  /// not merely be internally self-consistent with itself today. Uses
  /// [hlcTieBreakWins] — the same primitive `field_conflict_resolver.dart`
  /// already uses for its own HLC-tie-break — rather than a second,
  /// independently-maintained comparison. Returns whether `cycleNodes.first`'s
  /// own outgoing edge is the lowest-ranked (i.e. loses every pairwise
  /// [hlcTieBreakWins] comparison against every other edge).
  Future<bool> _isLowestRankedEdgeInCycle(
    DatabaseExecutor txn,
    List<String> cycleNodes,
  ) async {
    (Dot, Hlc)? myEdge;
    (Dot, Hlc)? lowest;
    for (var i = 0; i < cycleNodes.length - 1; i++) {
      final edgeOwner = cycleNodes[i];
      final edge = await _fieldDotAndHlc(
        txn,
        'tags',
        edgeOwner,
        'redirectTarget',
      );
      if (edge == null) {
        return false; // defensive — should not happen for a real redirect edge
      }
      if (i == 0) myEdge = edge;
      if (lowest == null ||
          hlcTieBreakWins(
            aHlc: lowest.$2,
            aDot: lowest.$1,
            bHlc: edge.$2,
            bDot: edge.$1,
          )) {
        // `hlcTieBreakWins(a, b)` is true when `a` WINS (ranks higher) over
        // `b` — so `edge` becomes the new lowest exactly when the CURRENT
        // lowest wins against it, i.e. `edge` ranks lower still.
        lowest = edge;
      }
    }
    return myEdge != null && lowest != null && myEdge.$1 == lowest.$1;
  }

  Future<Dot?> _creationDot(DatabaseExecutor txn, String tagId) =>
      _fieldDot(txn, 'tags', tagId, existsFieldSentinel);

  /// § Architecture 10 round 19: "the loser tag's own current `__deleted__`
  /// (or, if never yet written, `__exists__`) dot at the moment of
  /// detection" — the generation marker folded into both minted
  /// `contentKey`s.
  Future<Dot?> _generationDot(DatabaseExecutor txn, String tagId) async {
    return await _fieldDot(txn, 'tags', tagId, '__deleted__') ??
        await _fieldDot(txn, 'tags', tagId, existsFieldSentinel);
  }

  /// Mints the `redirectTarget` + `__deleted__` write pair for [loserTagId]
  /// — § 11.6(e)'s explicit, disclosed exception to § 11.3's "defer minting
  /// to drain": minted immediately, inline, mid-pull, using M2.3's ordinary
  /// `SeqCounter`/`HybridLogicalClock` primitives directly (not
  /// `OutboxDrainer`, which is drain-specific and has no concept of a
  /// collision-triggered mint). Both operations go straight into
  /// `sync_pending_ops`, so `SyncSession.run()`'s Phase B-then-Phase A
  /// ordering makes them visible to THIS SAME session's subsequent push.
  Future<void> _mintAutoMergeLoserPair(
    DatabaseExecutor txn, {
    required String loserTagId,
    required String winnerTagId,
    required String ownAuthorId,
  }) async {
    final generationDot = await _generationDot(txn, loserTagId);
    final generationMarker = generationDot?.toString() ?? 'none';

    final redirectContentKey = _sha256Hex(
      'autoTagMerge:redirectTarget:$loserTagId:$winnerTagId:$generationMarker',
    );
    final deletedContentKey = _sha256Hex(
      'autoTagMerge:deleted:$loserTagId:$generationMarker',
    );

    await _mintAndApplyTagField(
      txn,
      tagId: loserTagId,
      fieldName: 'redirectTarget',
      valueJson: jsonEncode(winnerTagId),
      contentKey: redirectContentKey,
      ownAuthorId: ownAuthorId,
    );
    await _mintAndApplyTagField(
      txn,
      tagId: loserTagId,
      fieldName: '__deleted__',
      // `tags.__deleted__` is a SQLite INTEGER (0/1), not a JSON bool — the
      // same convention every other `__deleted__` write in this codebase
      // uses (e.g. `OutboxDrainer`'s own diff-and-mint always round-trips
      // the column's actual int value). `_resolveTagLivenessTransition`'s
      // own comparisons (`currentRow['__deleted__'] == 1`) already assume
      // this encoding.
      valueJson: jsonEncode(1),
      contentKey: deletedContentKey,
      ownAuthorId: ownAuthorId,
    );
  }

  /// Mints one field operation for `(tags, tagId, fieldName)` as this
  /// device's own next dot, inserts it into `sync_pending_ops` (for the
  /// same session's subsequent push), then routes it through
  /// `CausalEngine.apply` (for the `contentKey` dedup/convergence property,
  /// see this file's top doc comment) and materializes the result directly
  /// into the real `tags` row if it won. Never itself re-triggers
  /// `_resolveTagLivenessTransition`: both `redirectTarget` (becoming
  /// non-null) and `__deleted__` (becoming true) move away from "raw live,"
  /// the opposite of what that check gates on.
  Future<void> _mintAndApplyTagField(
    DatabaseExecutor txn, {
    required String tagId,
    required String fieldName,
    required String valueJson,
    required String contentKey,
    required String ownAuthorId,
  }) async {
    final authorSeq = await _seqCounter.mintNextSeq(ownAuthorId, executor: txn);
    final hlc = await _hlc.generate(executor: txn);
    final dot = Dot(ownAuthorId, authorSeq);
    final frontierJson = await currentFrontierJson(txn, ownAuthorId, authorSeq);

    await txn.insert('sync_pending_ops', {
      'authorId': ownAuthorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': contentKey,
      'kind': 'field',
      'entityTable': 'tags',
      'entityId': tagId,
      'fieldName': fieldName,
      'memberUuid': null,
      'valueJson': valueJson,
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': frontierJson,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'publishedAt': null,
    });

    final op = IncomingOperation(
      dot: dot,
      hlc: hlc,
      contentKey: contentKey,
      kind: 'field',
      entityTable: 'tags',
      entityId: tagId,
      fieldName: fieldName,
      valueJson: valueJson,
      frontier: (jsonDecode(frontierJson) as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v as int),
      ),
    );
    final result = await _engine.apply(txn, op);
    final recompute = result.fieldRecompute;
    if (recompute != null && recompute.winnerChanged) {
      final winnerValue = recompute.winner.valueJson != null
          ? jsonDecode(recompute.winner.valueJson!)
          : null;
      await txn.update(
        'tags',
        {fieldName: winnerValue},
        where: 'id = ?',
        whereArgs: [tagId],
      );
    }
  }

  // ── OR-Set membership materialization (§ 11.6(d)) ──────────────────────

  /// Which real table a `set_add`'s [IncomingOperation.memberUuid] itself
  /// belongs to, keyed the same way as [_setScopesByEntityAndField]
  /// (`'${entityTable} ${fieldName}'`) — needed because every OR-Set
  /// membership table this codebase has is a genuine `FOREIGN KEY`
  /// (`note_tags.tagId -> tags(id)`, etc.), enforced (verified directly,
  /// not assumed): an `INSERT` whose member row does not YET exist locally
  /// throws a real `FOREIGN KEY constraint failed`, not a silent no-op —
  /// so, symmetrically with the owning entity's own `missing_exists` gate,
  /// the member's existence must be checked too, before the `INSERT`, not
  /// discovered via a thrown exception.
  static const Map<String, String> _memberEntityTableByFieldKey = {
    'notes tags': 'tags',
    'conversations tags': 'tags',
    'conversations noteIds': 'notes',
    'conversations messageIds': 'conversation_messages',
    'conversation_messages parentMessageIds': 'conversation_messages',
  };

  /// Checks BOTH of a `set_add`'s prerequisites — the owning entity's row,
  /// then (if that's satisfied) the member's own row — and returns
  /// whichever one is currently missing, or `null` if both are satisfied.
  ///
  /// **Load-bearing for retry correctness, not just for the first attempt.**
  /// A prior version of this file only ever recorded ONE blocker (owner
  /// checked first, short-circuiting before the member was ever checked),
  /// and [sweepMissingExists] trusted that single recorded blocker having
  /// resolved as proof the whole op was now safe to materialize. When BOTH
  /// were missing at enqueue time, only the owner got recorded; if the
  /// owner alone later resolved while the member still hadn't, the retry
  /// would blindly `INSERT` — and `ConflictAlgorithm.ignore` does NOT
  /// suppress a `FOREIGN KEY` violation (confirmed empirically), so this
  /// threw, uncaught, out of `SyncSession.run()`, aborting the entire
  /// session (including the user's own unrelated pending pushes) — and
  /// since the queue row was never cleared on that failure, it recurred on
  /// EVERY future sync attempt: a realistic offline/partial-sync ordering
  /// became a permanent sync outage for that device. Fixed by making BOTH
  /// [_materializeSetAdd] (first attempt) and [sweepMissingExists] (every
  /// retry) call this SAME full re-verification — a retry never trusts
  /// "the one thing I recorded before" in isolation, it always re-derives
  /// the complete, current blocking state before touching the real table.
  Future<(String table, String id)?> _setAddBlocker(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String? memberUuid,
  }) async {
    final entityScope = _entityScopesByTable[entityTable];
    if (entityScope != null && !await _rowExists(txn, entityScope, entityId)) {
      return (entityTable, entityId);
    }

    final memberTable = _memberEntityTableByFieldKey['$entityTable $fieldName'];
    if (memberTable != null && memberUuid != null) {
      final memberScope = _entityScopesByTable[memberTable];
      if (memberScope != null &&
          !await _rowExists(txn, memberScope, memberUuid)) {
        return (memberTable, memberUuid);
      }
    }

    return null;
  }

  Future<void> _materializeSetAdd(
    DatabaseExecutor txn, {
    required IncomingOperation op,
    required SetAddResult result,
  }) async {
    if (result.outcome != SetAddOutcome.materialized) {
      return; // dedup-skipped/already-processed — nothing new live
    }

    final scope =
        _setScopesByEntityAndField['${op.entityTable} ${op.fieldName}'];
    if (scope == null) return;

    final blocker = await _setAddBlocker(
      txn,
      entityTable: op.entityTable,
      entityId: op.entityId,
      fieldName: op.fieldName!,
      memberUuid: op.memberUuid,
    );
    if (blocker != null) {
      await _enqueueMissingExists(
        txn,
        entityTable: op.entityTable,
        entityId: op.entityId,
        fieldName: op.fieldName!,
        kind: 'set_add',
        memberUuid: op.memberUuid,
        valueJson: op.valueJson,
        hlcWallMs: op.hlc.wallMs,
        waitingOnTable: blocker.$1,
        waitingOnId: blocker.$2,
      );
      return;
    }

    await _insertMembershipRow(
      txn,
      scope: scope,
      entityId: op.entityId,
      memberUuid: op.memberUuid!,
      payloadJson: op.valueJson,
      hlcWallMs: op.hlc.wallMs,
    );
  }

  /// Inserts one real membership row, filling every column the table
  /// actually declares — **not just the two id columns**.
  ///
  /// **The bug this replaces, and why it was invisible.** The previous
  /// implementation inserted only `(entityIdColumn, memberIdColumn)` with
  /// `ConflictAlgorithm.ignore`. All three mapping tables
  /// (`conversation_note_mapping`, `conversation_message_mapping`,
  /// `message_parents`) declare `createdAt INTEGER NOT NULL` with no
  /// default, and `message_parents` additionally declares `id TEXT PRIMARY
  /// KEY` — so every one of those INSERTs failed a NOT NULL constraint, and
  /// `OR IGNORE` swallowed the failure whole. Reproduced: after four sync
  /// rounds a device held a live `sync_set_state` row for
  /// `conversations.noteIds` and a completely empty
  /// `conversation_note_mapping`, with an empty queue and no error anywhere.
  /// Conversation/note/message-mapping membership never reached the app
  /// tables at all, on either the seed or the drain path. Pre-existing since
  /// M2.7; fixable now only because M2.10 puts the add-event payload on the
  /// wire (`sync_table_shape.dart`'s `encodeSetAddPayloadJson`).
  ///
  /// **`OR IGNORE` is narrowed accordingly.** Its one legitimate job was
  /// "a second, concurrent add-dot for the same member must be a harmless
  /// no-op" (the OR-Set property — see this file's top doc comment), which
  /// is now done by an explicit existence check inside the caller's
  /// transaction. The INSERT itself runs with no conflict algorithm, so a
  /// constraint violation is a real error rather than a silently skipped
  /// write.
  ///
  /// **What makes that safe is NOT this method's own pre-check, and an
  /// earlier version of this comment claiming otherwise was wrong in a way
  /// that caused a real outage.** [_unfillableMembershipColumn] only
  /// recognizes one shape (`NOT NULL`, no default, no usable value); a
  /// payload carrying an explicit `{"createdAt": null}` sailed through it —
  /// `containsKey` was true — and the resulting `NOT NULL constraint failed`
  /// escaped `SyncSession.run()` entirely. Because push runs after pull,
  /// that wedged the device permanently: six consecutive sessions threw and
  /// 33 unpushed local operations never left. A per-shape pre-check can
  /// never be complete anyway — a future `CHECK`, an extra `UNIQUE`, or a
  /// payload column with its own `FOREIGN KEY` all fail the same way.
  ///
  /// So safety now rests on two things, in this order: this method fills the
  /// row as completely as it can and recognizes the one shape it knows it
  /// cannot satisfy (below), AND `pull_phase.dart` wraps every operation's
  /// apply/materialize step so that ANY failure parks that one operation and
  /// lets the rest of the session — including the whole push — proceed. The
  /// pre-check is an optimization that produces a precise diagnosis; the
  /// per-operation guard is what makes the failure survivable.
  Future<MembershipInsertOutcome> _insertMembershipRow(
    DatabaseExecutor txn, {
    required SyncSetCaptureScope scope,
    required String entityId,
    required String memberUuid,
    required String? payloadJson,
    required int hlcWallMs,
  }) async {
    final existing = await txn.query(
      scope.membershipTable,
      columns: [scope.entityIdColumn],
      where: '${scope.entityIdColumn} = ? AND ${scope.memberIdColumn} = ?',
      whereArgs: [entityId, memberUuid],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return MembershipInsertOutcome.alreadyLive; // the OR-Set no-op case
    }

    final columns = await syncTableInfo(txn, scope.membershipTable);
    final payload = decodeSetAddPayload(payloadJson);
    final createdAtColumn =
        syncMembershipCreatedAtColumnByTable[scope.membershipTable];
    final row = <String, Object?>{
      scope.entityIdColumn: entityId,
      scope.memberIdColumn: memberUuid,
    };

    for (final column in columns) {
      final name = column['name'] as String;
      if (name == scope.entityIdColumn || name == scope.memberIdColumn) {
        continue;
      }
      // A present-and-non-null payload value. `containsKey` alone is not
      // enough: an explicit null satisfies it while satisfying nothing the
      // column needs (see this method's doc comment — that exact gap was a
      // reproduced outage).
      if (payload[name] != null) {
        row[name] = payload[name];
        continue;
      }
      if (name == createdAtColumn) {
        // Falls back to the operation's HLC wall-clock component exactly as
        // `_materializeExists` derives an entity's `createdAt` from its
        // `__exists__` operation's HLC — the same reasoning, same source.
        //
        // **Stated precisely, because "the add event's own time" is only
        // half true.** This value is convergent among RECEIVERS (every
        // device that materializes this operation derives the identical
        // number from the same immutable HLC, and a retry derives it again
        // identically), but it does NOT match the ORIGIN device's own local
        // column: measured, an origin row with `createdAt = 12345`
        // materializes elsewhere as the operation's HLC wall clock, e.g.
        // `1787290502460`. Harmless today — nothing in this codebase orders
        // or compares on a membership table's `createdAt` (the mapping
        // tables' ordering key is their own local `rowid`, per
        // `seed_scanner.dart`) — and it only ever applies to operations that
        // carried no payload at all, since a payload-carrying operation
        // supplies the origin's real value. But it is a real origin/receiver
        // split, not an identity, and anything that later starts ordering on
        // these columns has to know that. **This is what makes a
        // pre-M2.10 `set_add` (minted before any payload was carried at all,
        // `valueJson == null`) materialize instead of parking**, which the
        // first version of this fix got wrong: those operations are normal
        // and expected, not malformed, and parking them reproduced the very
        // "live sync_set_state row, empty mapping table" signature this
        // milestone set out to kill.
        row[name] = hlcWallMs;
        continue;
      }
      if (isNonPortableIntegerPrimaryKey(column)) {
        continue; // a local autoincrement surrogate — let SQLite assign it
      }
      final pk = column['pk'] as int? ?? 0;
      if (pk != 0) {
        // A real, non-integer surrogate key (`message_parents.id`). Derived
        // deterministically from the membership itself so two devices
        // materializing the same edge agree — see
        // `deterministicMembershipRowId`'s doc comment for why this must
        // never be folded into a contentKey.
        row[name] = deterministicMembershipRowId(
          membershipTable: scope.membershipTable,
          entityId: entityId,
          memberUuid: memberUuid,
        );
        continue;
      }
      // Anything else nullable or defaulted is simply omitted; SQLite fills
      // it.
    }

    final unfillable = _unfillableMembershipColumn(columns, row);
    if (unfillable != null) {
      // **Not claimed unreachable.** It is not reachable for any of today's
      // five membership tables given the fallbacks above (asserted by
      // `seed_scanner_test.dart`'s schema-shape scan, which fails if a
      // membership table ever grows a NOT NULL column none of these
      // branches can fill) — but a schema change could reach it tomorrow,
      // which is the entire point of handling it. Entries are RETRIED by
      // [sweepMissingExists] on every subsequent pull, so a build that
      // learns to fill the column drains them automatically; the previous
      // version parked them under a reason nothing anywhere read, which is
      // a wedge wearing a queue row's clothing.
      await txn.insert('sync_materialize_queue', {
        'blockingReason': unfillableMembershipColumnBlockingReason,
        'entityTable': scope.entityTable,
        'entityId': entityId,
        'fieldName': scope.fieldName,
        'operationJson': jsonEncode({
          'kind': 'set_add',
          'fieldName': scope.fieldName,
          'memberUuid': memberUuid,
          'valueJson': payloadJson,
          'hlcWallMs': hlcWallMs,
          'unfillableColumn': unfillable,
          // The retry re-derives its blocker from scratch, exactly like the
          // missing_exists path does; these are recorded so a queued row is
          // self-describing without re-running any of this logic.
          'waitingOnTable': scope.membershipTable,
          'waitingOnId': unfillable,
        }),
        'blockingKey': '${scope.membershipTable}:$unfillable',
        'enqueuedAt': DateTime.now().millisecondsSinceEpoch,
      });
      return MembershipInsertOutcome.parkedUnfillable;
    }

    await txn.insert(scope.membershipTable, row);
    return MembershipInsertOutcome.inserted;
  }

  /// The first `NOT NULL`, no-default column of [columns] that [row] has no
  /// USABLE value for — missing, or present but null. The null half is not a
  /// refinement: `{"createdAt": null}` passing a `containsKey`-only check is
  /// precisely the gap that turned this pre-check into a reproduced sync
  /// outage (see [_insertMembershipRow]'s doc comment).
  ///
  /// Deliberately NOT a general constraint-satisfaction check — it cannot
  /// see `CHECK`, extra `UNIQUE`, or `FOREIGN KEY` constraints, and pretending
  /// otherwise is what made the earlier safety argument false. Everything it
  /// cannot predict is caught by `pull_phase.dart`'s per-operation guard.
  String? _unfillableMembershipColumn(
    List<Map<String, Object?>> columns,
    Map<String, Object?> row,
  ) {
    for (final column in columns) {
      final name = column['name'] as String;
      if (row[name] != null) continue;
      if (isNonPortableIntegerPrimaryKey(column)) continue;
      final notNull = (column['notnull'] as int? ?? 0) != 0;
      final hasDefault = column['dflt_value'] != null;
      if (notNull && !hasDefault) return name;
    }
    return null;
  }

  Future<void> _materializeSetRemove(
    DatabaseExecutor txn, {
    required IncomingOperation op,
    required SetRemoveResult result,
  }) async {
    if (result.appliedTargets.isEmpty) {
      return; // nothing resolved this call — real table is already correct
    }

    final scope =
        _setScopesByEntityAndField['${op.entityTable} ${op.fieldName}'];
    if (scope == null) return;

    final remaining = await txn.query(
      'sync_set_state',
      columns: const ['authorId'],
      where:
          'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
      whereArgs: [op.entityTable, op.entityId, op.fieldName, op.memberUuid],
      limit: 1,
    );
    if (remaining.isNotEmpty) {
      return; // at least one other live add-dot remains — member stays live
    }

    await txn.delete(
      scope.membershipTable,
      where: '${scope.entityIdColumn} = ? AND ${scope.memberIdColumn} = ?',
      whereArgs: [op.entityId, op.memberUuid],
    );
  }

  // ── sync_materialize_queue: missing_exists enqueue ─────────────────────

  /// [entityTable]/[entityId] always identify the OWNING entity (needed to
  /// reconstruct the operation on retry); [waitingOnTable]/[waitingOnId]
  /// identify whatever row is ACTUALLY missing right now — the same pair
  /// for an ordinary field op, but possibly the set MEMBER's own row for a
  /// `set_add` (see `_materializeSetAdd`'s doc comment on
  /// [_memberEntityTableByFieldKey]).
  Future<void> _enqueueMissingExists(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String waitingOnTable,
    required String waitingOnId,
    String kind = 'field',
    String? memberUuid,
    String? valueJson,
    int? hlcWallMs,
  }) async {
    await txn.insert('sync_materialize_queue', {
      'blockingReason': missingExistsBlockingReason,
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'operationJson': jsonEncode({
        'kind': kind,
        'fieldName': fieldName,
        if (memberUuid != null) 'memberUuid': memberUuid,
        // The add-event payload, so a retry can build the SAME full
        // membership row the first attempt would have — see
        // `_insertMembershipRow`. Absent for 'field' entries, which have no
        // payload of their own (they re-read sync_field_state on retry).
        if (valueJson != null) 'valueJson': valueJson,
        // The add event's own time, so a retry can fill a membership
        // table's createdAt-equivalent identically to the first attempt.
        if (hlcWallMs != null) 'hlcWallMs': hlcWallMs,
        'waitingOnTable': waitingOnTable,
        'waitingOnId': waitingOnId,
      }),
      'blockingKey': '$waitingOnTable:$waitingOnId',
      'enqueuedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ── Shared helpers ──────────────────────────────────────────────────

  Future<bool> _rowExists(
    DatabaseExecutor txn,
    SyncEntityCaptureScope scope,
    String entityId,
  ) async {
    final rows = await txn.query(
      scope.table,
      columns: [scope.idColumn],
      where: '${scope.idColumn} = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<String?> _readFieldStateValueJson(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
  ) async {
    final rows = await txn.query(
      'sync_field_state',
      columns: const ['valueJson'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['valueJson'] as String?;
  }

  Future<Dot?> _fieldDot(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
  ) async {
    final rows = await txn.query(
      'sync_field_state',
      columns: const ['authorId', 'authorSeq'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Dot(
      rows.first['authorId'] as String,
      rows.first['authorSeq'] as int,
    );
  }

  /// Same lookup as [_fieldDot], but also returns the write's own HLC —
  /// needed for the cycle-edge tie-break specifically, which § Architecture
  /// 10 ranks by `(HLC, authorId, authorSeq)`, not `(authorId, authorSeq)`
  /// alone (unlike the ordinary name-collision winner tie-break, which the
  /// design doc states is `(authorId, authorSeq)` only — see
  /// `_resolveTagLivenessTransition`'s own comparison).
  Future<(Dot, Hlc)?> _fieldDotAndHlc(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
  ) async {
    final rows = await txn.query(
      'sync_field_state',
      columns: const ['authorId', 'authorSeq', 'hlc'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final dot = Dot(
      rows.first['authorId'] as String,
      rows.first['authorSeq'] as int,
    );
    final hlc = Hlc.parse(rows.first['hlc'] as String);
    return (dot, hlc);
  }

  Object? _placeholderDefault(Map<String, Object?> column) {
    final dflt = column['dflt_value'];
    final type = (column['type'] as String? ?? '').toUpperCase();
    if (dflt != null) {
      final text = dflt as String;
      if (type.contains('INT')) return int.tryParse(text) ?? 0;
      if (type.contains('REAL') ||
          type.contains('FLOA') ||
          type.contains('DOUB')) {
        return double.tryParse(text) ?? 0.0;
      }
      if (text.length >= 2 && text.startsWith("'") && text.endsWith("'")) {
        return text.substring(1, text.length - 1);
      }
      return text;
    }
    final notNull = (column['notnull'] as int? ?? 0) != 0;
    if (!notNull) return null;
    if (type.contains('INT')) return 0;
    if (type.contains('REAL') ||
        type.contains('FLOA') ||
        type.contains('DOUB')) {
      return 0.0;
    }
    return '';
  }

  /// § Architecture 10 round 19's `hash(...)` — the same `sha256` hex-digest
  /// convention `field_conflict_resolver.dart`'s `_rowId` already uses for
  /// every other deterministic id in this codebase.
  String _sha256Hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();
}
