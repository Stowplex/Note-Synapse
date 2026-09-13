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
// `createdAt`-equivalent (preserved in the `__exists__` payload, with a
// legacy HLC fallback — see `syncEntityCreatedAtColumnByTable`
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
// `syncScopeColumns` at all used to be unresolvable here by construction —
// and that is what M2.14 fixed.** For six tables the missing column was an
// owner pointer or a second required identity column
// (`subnotes.noteId`, `attachments.noteId`,
// `relationships.fromNoteId`/`toNoteId`,
// `conversation_attachments.messageId`, `app_revisions.appId`,
// `user_apps.uuid`). Those values now travel ON the `__exists__` operation
// (`encodeExistsPayloadJson`, `sync_table_shape.dart`) and
// `_materializeExists` reads them back, so five of those six tables now
// produce real rows on a peer: `subnotes`, `relationships`, `attachments`,
// `conversation_attachments` and `user_apps`. Read "rows", not "content" —
// an `attachments` row arrives complete while the file it names does not,
// and a `user_apps` row arrives without any `app_revisions`. The next
// paragraph is that boundary, stated in full.
//
// **What the carried-column rule deliberately will NOT carry, because the
// obvious version of the rule got this wrong.** "Every `NOT NULL`,
// no-default column outside sync scope" also selects `app_revisions.appCode`
// (an entire mini app's HTML/JS source) and
// `user_app_library_dependencies.bytes` (a dependency's raw file), which
// would inline a blob into a permanent CRDT operation and hash it into a
// GENESIS `contentKey`. So the rule is narrowed to REFERENCE and IDENTITY
// columns — a declared `FOREIGN KEY`, or a sole-column non-partial `UNIQUE`
// index — and everything else still blocks. See `entitySyncability`'s doc
// comment for the full reasoning.
//
// **So the residual is smaller and sharper, not gone.** `app_revisions` is
// still skipped here, now for `appCode` alone: a mini app syncs its row,
// name, description, steps, pinned-revision id and app state, and does NOT
// sync the revision that holds its runnable code — that waits for §
// Architecture 4's content-addressed blobs (M3). `attachments`/
// `conversation_attachments` rows arrive complete while the FILES they
// point at do not, for the same reason. `app_revisions` IS on the health
// surface (it is `canSync == false`, so `tablesNotSynced` names it, with
// `appCode` as the reason) — **and that claim was flatly false on the
// one device that most needs it until review round 1 fixed the
// detector.** `tablesNotSynced` guarded on `if (count == 0) continue`
// over the blocked table's OWN rows, and a RECEIVING device has zero
// `app_revisions` rows by construction — so M2.14 is precisely what
// manufactures the state "this device holds mini apps and not one line
// of their code, and its sync card is green." `sync_health.dart` now
// also fires when a blocked table's OWNER table is populated locally,
// which is what makes the sentence above true on the receiving device
// and not only on the authoring one. The attachment tables
// deliberately are NOT on that surface —
// see `SyncHealthIssueKind.tablesNotSynced`'s own doc comment for why a
// health kind for them was written and then removed, and where the
// per-attachment "File not found" affordance lives instead. The SAME
// generic check still skips any table whose
// `idColumn` is a non-portable `INTEGER PRIMARY KEY AUTOINCREMENT`
// (`user_app_libraries`/`user_app_library_dependencies`) — a
// locally-assigned integer id from one device is meaningless on another,
// so materializing a brand-new row for these under a remote `entityId`
// would be actively wrong, not merely incomplete.
//
// **An `__exists__` minted before M2.14 carries the constant `true` and
// therefore no owner value, and those operations are real and on real
// backends** (every one of these tables minted and published normally until
// M2.10 gated them — `user_apps` accumulated 11 permanent `missing_exists`
// entries on a real device that way). This file reads such a payload
// without throwing and declines to build the row, exactly as before;
// `OutboxDrainer._upgradeLegacyExistsPayloads` is what replaces those stale
// registers with complete ones.
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
import 'large_row_reader.dart';
import 'sync_change_publisher.dart';
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

/// `sync_materialize_queue.blockingReason` for an `__exists__` whose shell
/// row would violate a UNIQUE identity constraint already held by a
/// DIFFERENT local row — M2.14, review round 1, finding C.
///
/// **The shape, because it is an ordinary distribution path and not an
/// exotic one.** `import_app_screen.dart`'s `_createNewApp` keeps the YAML's
/// `uuid` verbatim and mints a fresh `id` from the local wall clock, so
/// installing the same bundled contrib plugin on two devices produces two
/// rows with the SAME `user_apps.uuid` and DIFFERENT `user_apps.id`. When one
/// device's row syncs to the other, the shell `INSERT` carries the remote
/// `id` and the shared `uuid` and hits `uuid TEXT NOT NULL UNIQUE`.
/// `user_apps.uuid` is also the one carried column in the schema that is an
/// identity rather than a foreign key, so `_existsOwnerBlocker` — which only
/// checks references — guards nothing for it.
///
/// **Retryable rather than unresolvable, and the distinction is mechanical,
/// not aspirational.** The condition is a property of this device's CURRENT
/// local rows, not of the protocol: the sweep re-derives it on every pull and
/// inserts the row — draining the entity's parked field operations in the
/// same pass — the moment nothing local holds that value any more. That is
/// what makes parking it correct where
/// [ExistsInsertOutcome.unresolvable]'s deliberate enqueue-nothing would be
/// wrong.
///
/// **But no user action available today reaches that state, and saying so is
/// the point of this paragraph.** `user_apps` is in
/// `_hardDeleteGuardedTables`, so "delete the duplicate mini app" writes
/// `__deleted__ = 1` and leaves the row — and its `uuid` — exactly where it
/// was, still occupying the `UNIQUE` index. A dataset reset clears it; M4
/// resolves it properly; nothing in between does. The user-facing string
/// therefore states the fact and prescribes no remedy, because a health
/// surface that tells people to do something that does not work is worse
/// than one that tells them only what happened.
///
/// Reported on the health surface under
/// [SyncHealthIssueKind.entityIdentityConflict], with the colliding column,
/// value and local row id recorded on the entry: this parks ONE entry that
/// explains the entity's other parked field operations, which park with or
/// without it. "N operations are waiting" with nothing saying what for is
/// the shape this engine's health spine exists to end.
///
/// **What it deliberately does NOT do: reconcile the two rows.** Deciding
/// that the remote `app1` and the local `1724...` are the same app and
/// picking a winning `id` means rewriting a live primary key and everything
/// that points at it (`app_revisions.appId`, `user_apps.selectedRevisionId`,
/// every `sync_field_state`/`sync_pending_ops` row keyed on the old id), and
/// doing it convergently on both devices without either losing revisions.
/// That is identity mapping, which this design assigns to **M4**
/// ("Implement the fully identity-mapped User Apps + revision history") —
/// and inventing a rule for it inside a materializer is how a milestone
/// acquires a residual it cannot name.
const String existsIdentityConflictBlockingReason = 'exists_identity_conflict';

/// What one shell-row (`__exists__`) insert attempt actually did — M2.14.
///
/// Returned rather than inferred for the same reason
/// [MembershipInsertOutcome] is: [SyncMaterializer.sweepMissingExists] has
/// to tell "this queue entry is resolved, delete it" from "still blocked,
/// leave `enqueuedAt` alone", and a retry that re-enqueued itself would
/// destroy the only aging signal the row has.
enum ExistsInsertOutcome {
  /// The shell row was written.
  inserted,

  /// A row for this entity was already there — an idempotent re-apply, and a
  /// legitimate success (a queued retry for it is resolved).
  alreadyPresent,

  /// The row cannot be built from what this protocol carries: a non-portable
  /// integer id, a `NOT NULL` column that is neither in `syncScopeColumns`
  /// nor carried on `__exists__` (`app_revisions.appCode`), or an
  /// `__exists__` payload minted before M2.14 that carries no owner values
  /// at all.
  ///
  /// **Nothing is enqueued for it**, deliberately: a queue entry whose
  /// prerequisite can never arrive is exactly the permanent, undrainable
  /// per-peer backlog M2.10 spent a milestone deleting. The condition is
  /// reported at the TABLE level instead, by `entitySyncability` through the
  /// health surface, where one line covers every row rather than one row
  /// covering every line.
  unresolvable,

  /// Every value is available, but a row this one references does not exist
  /// locally yet — the ordinary cross-log ordering case. See
  /// [SyncMaterializer.sweepMissingExists].
  blockedOnOwner,

  /// Every value is available and every reference is satisfied, but a
  /// DIFFERENT local row already holds one of the carried identity values
  /// under a `UNIQUE` constraint — see
  /// [existsIdentityConflictBlockingReason]. Parked and retried, not dropped.
  identityConflict,
}

/// Which carried identity value collided, and with which local row —
/// recorded on the parked queue entry so the health surface can say what is
/// actually wrong instead of counting anonymous blocked operations.
typedef ExistsIdentityConflict = ({
  String column,
  String value,
  String existingId,
});

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

  /// The same memoization for [entitySyncability], which M2.14 makes a
  /// per-`__exists__` lookup (it now answers "which columns does this
  /// table's `__exists__` carry, and what do they reference?"). Four
  /// `PRAGMA` round trips per call, so caching it is the difference between
  /// four and four-thousand on a first sync.
  final Map<String, EntitySyncability> _syncabilityCache = {};

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
  ///
  /// **Returns the rows it actually wrote** ([SyncChangeCollector],
  /// `sync_change_publisher.dart`), so the caller can announce them once its
  /// transaction has COMMITTED — the write-path hooks this file deliberately
  /// bypasses (§ 11.6(c)) never fire, so without this a pulled edit reached
  /// the real row and nothing else: no reindex, no UI refresh. The value is
  /// returned rather than pushed into a caller-supplied sink precisely so a
  /// rolled-back transaction discards it with the writes it described.
  ///
  /// Empty for every no-op this file already declines to perform — an
  /// idempotent re-apply (`result.fieldRecompute == null`), an unchanged
  /// winner (`winnerChanged: false`), a `contentKey`-deduped `set_add`, a
  /// `set_remove` with live add-dots remaining, an operation parked on a
  /// missing `__exists__`. Nothing announces a write that did not happen.
  Future<SyncChangeCollector> materialize(
    DatabaseExecutor txn, {
    required IncomingOperation op,
    required ApplyResult result,
    required String ownAuthorId,
  }) async {
    final changes = SyncChangeCollector();
    switch (result.kind) {
      case AppliedKind.fieldOrExists:
        await _materializeFieldOrExists(
          txn,
          op: op,
          result: result.fieldRecompute,
          ownAuthorId: ownAuthorId,
          changes: changes,
        );
      case AppliedKind.setAdd:
        await _materializeSetAdd(
          txn,
          op: op,
          result: result.setAddResult!,
          changes: changes,
        );
      case AppliedKind.setRemove:
        await _materializeSetRemove(
          txn,
          op: op,
          result: result.setRemoveResult!,
          changes: changes,
        );
    }
    return changes;
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
  /// [changes] collects the rows this sweep writes, for the caller to
  /// announce after `pull()` finishes. Unlike [materialize] this method owns
  /// its own transactions, so each one's result is merged into [changes] only
  /// after that transaction has returned — a sweep entry whose retry throws
  /// contributes nothing.
  Future<int> sweepMissingExists(
    Database db, {
    required String ownAuthorId,
    SyncChangeCollector? changes,
  }) async {
    var resolved = 0;
    final rows = await db.query(
      'sync_materialize_queue',
      where: 'blockingReason IN (?, ?, ?)',
      whereArgs: [
        missingExistsBlockingReason,
        unfillableMembershipColumnBlockingReason,
        // M2.14 review round 1, finding C. Swept for the same reason the
        // unfillable-membership rows are: the blocking condition is local
        // state a user can change (delete the duplicate app), so an entry
        // nothing ever retries would turn a recoverable collision into a
        // permanent one.
        existsIdentityConflictBlockingReason,
      ],
      // **`__exists__` entries first, then everything else in id order —
      // M2.14, and this ordering is load-bearing, not cosmetic.** A blocked
      // child entity produces one queue entry for its own `__exists__` plus
      // one per field operation that arrived while its row was missing. If a
      // field entry is retried before the `__exists__` entry in the same
      // pass, it finds no row, stays queued, and the whole entity needs an
      // extra sync round to appear — for every field, on every peer. Doing
      // the row-creating entries first means one sweep drains the entity
      // completely. Ties keep `id ASC`, which is the drain order the rest of
      // this engine is built on.
      orderBy:
          "CASE WHEN fieldName = '$existsFieldSentinel' THEN 0 ELSE 1 END, id ASC",
    );
    for (final row in rows) {
      final id = row['id'] as int;
      final entityTable = row['entityTable'] as String;
      final entityId = row['entityId'] as String;
      final payload =
          jsonDecode(row['operationJson'] as String) as Map<String, dynamic>;

      if (payload['kind'] == existsFieldSentinel) {
        final scope = _entityScopesByTable[entityTable];
        if (scope == null) continue;
        // Fully re-derived, exactly like the `set_add` branch below: a table
        // with two references (`relationships`) can have the recorded
        // blocker resolve while the other has not, and trusting the one
        // recorded blocker was a reproduced outage one kind over.
        final result = await db.transaction(
          (txn) => _materializeExists(
            txn,
            scope,
            entityId,
            payload['hlcWallMs'] as int? ?? 0,
          ),
        );
        switch (result.outcome) {
          case ExistsInsertOutcome.inserted:
          case ExistsInsertOutcome.alreadyPresent:
            // `alreadyPresent` wrote nothing — only a real INSERT is a change
            // worth announcing.
            if (result.outcome == ExistsInsertOutcome.inserted) {
              changes?.recordRow(entityTable, entityId);
            }
            await db.delete(
              'sync_materialize_queue',
              where: 'id = ?',
              whereArgs: [id],
            );
            resolved++;
          case ExistsInsertOutcome.blockedOnOwner:
            final blocker = result.blocker!;
            if (blocker.$1 != payload['waitingOnTable'] ||
                blocker.$2 != payload['waitingOnId'] ||
                row['blockingReason'] != missingExistsBlockingReason) {
              await db.update(
                'sync_materialize_queue',
                {
                  // An entry can arrive here having been parked under a
                  // DIFFERENT reason (an identity conflict whose duplicate the
                  // user deleted, uncovering a missing owner underneath). The
                  // reason is rewritten with the record so the health surface
                  // never names a condition that has already changed.
                  'blockingReason': missingExistsBlockingReason,
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
          case ExistsInsertOutcome.identityConflict:
            // Still colliding — re-describe in place (the colliding local row
            // may be a different one than last time) and leave it queued.
            // `enqueuedAt` is untouched, which is the only aging signal the
            // row has.
            await db.transaction(
              (txn) => _enqueueExistsIdentityConflict(
                txn,
                scope: scope,
                entityId: entityId,
                hlcWallMs: payload['hlcWallMs'] as int? ?? 0,
                conflict: result.identityConflict,
              ),
            );
          case ExistsInsertOutcome.unresolvable:
            // **Defensive, and not claimed reachable.** There are exactly
            // two ways an entry gets into this branch, and both require a
            // COMPLETE payload for a `canSync` table: it was once
            // `blockedOnOwner` or `identityConflict`, or
            // `OutboxDrainer._repairExistsRegisters` enqueued it after
            // checking both conditions itself. A register's payload never
            // regresses from complete to incomplete. (The two genuinely
            // unresolvable cases — a pre-M2.14 `true` payload, and
            // `app_revisions.appCode` — are rejected on the FIRST attempt,
            // which enqueues nothing at all, and the repair pass skips them
            // for the same reason, precisely so they cannot produce the
            // permanent undrainable backlog M2.10 removed.)
            // Left queued rather than deleted if it ever does happen:
            // dropping a row on a state nobody predicted is how a change
            // becomes invisible, and the health surface counts what is
            // queued.
            break;
        }
        continue;
      }

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
        // `alreadyLive` is the OR-Set duplicate-add no-op: nothing was
        // written, so nothing is announced.
        if (outcome == MembershipInsertOutcome.inserted) {
          changes?.recordRow(setScope.entityTable, entityId);
        }
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

      // The local collector is built INSIDE the transaction body and returned
      // from it, so a retry that throws contributes nothing to what gets
      // announced.
      final fieldChanges = await db.transaction((txn) async {
        final local = SyncChangeCollector();
        await _writeResolvedFieldValue(
          txn,
          scope: ownerScope,
          entityId: entityId,
          fieldName: payload['fieldName'] as String,
          ownAuthorId: ownAuthorId,
          changes: local,
        );
        await txn.delete(
          'sync_materialize_queue',
          where: 'id = ?',
          whereArgs: [id],
        );
        return local;
      });
      changes?.addAll(fieldChanges);
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
    required SyncChangeCollector changes,
  }) async {
    if (result == null) return; // pure idempotent re-apply — nothing to do
    if (!result.winnerChanged) {
      return; // resolved winner is unchanged — no app-table work needed
    }

    final scope = _entityScopesByTable[op.entityTable];
    if (scope == null) return; // not a materializable table (defensive)

    if (op.kind == existsFieldSentinel) {
      final result = await _materializeExists(
        txn,
        scope,
        op.entityId,
        op.hlc.wallMs,
      );
      if (result.outcome == ExistsInsertOutcome.inserted) {
        changes.recordRow(op.entityTable, op.entityId);
      }
      if (result.blocker case final blocker?) {
        // The owner row has not arrived yet — reuse the existing
        // `missing_exists` queue and its sweep rather than inventing a
        // second dependency mechanism. `hlcWallMs` travels with the entry so
        // the retry derives the identical createdAt the first attempt would
        // have (`_createdAtFromHlcWall`).
        await _enqueueMissingExists(
          txn,
          entityTable: op.entityTable,
          entityId: op.entityId,
          fieldName: existsFieldSentinel,
          kind: existsFieldSentinel,
          hlcWallMs: op.hlc.wallMs,
          waitingOnTable: blocker.$1,
          waitingOnId: blocker.$2,
        );
      } else if (result.outcome == ExistsInsertOutcome.identityConflict) {
        // A different local row already holds this row's carried identity
        // value — parked under its own retryable reason rather than silently
        // reported as inserted. See
        // [existsIdentityConflictBlockingReason].
        await _enqueueExistsIdentityConflict(
          txn,
          scope: scope,
          entityId: op.entityId,
          hlcWallMs: op.hlc.wallMs,
          conflict: result.identityConflict,
        );
      }
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
      changes: changes,
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
    required SyncChangeCollector changes,
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
        changes: changes,
      );
    }

    await txn.update(
      scope.table,
      toWrite,
      where: '${scope.idColumn} = ?',
      whereArgs: [entityId],
    );
    changes.recordRow(scope.table, entityId);
  }

  /// Backward-compatible timestamp for operations whose immutable payload
  /// predates source-date preservation. New payloads carry the original
  /// creation date, so seeding an existing library no longer dates all its
  /// notes/messages/revisions at first-sync time. A legacy recessive seed has
  /// Hlc.zero and must use the receiver's clock instead of inventing 1970.
  static int _createdAtFromHlcWall(int hlcWallMs) =>
      hlcWallMs > 0 ? hlcWallMs : DateTime.now().millisecondsSinceEpoch;

  /// Turns a resolved `__exists__` into a real `INSERT` — a shell row for
  /// any not-yet-arrived `syncScopeColumns` entry, corrected in place as
  /// each column's own field commit materializes. See this file's top doc
  /// comment for the full reasoning, including why some tables are
  /// generically, deliberately skipped.
  ///
  /// **M2.14: the owner columns now come off the operation itself.** The
  /// values for `subnotes.noteId`, `attachments.noteId`,
  /// `relationships.fromNoteId`/`toNoteId`,
  /// `conversation_attachments.messageId`, `app_revisions.appId` and
  /// `user_apps.uuid` are carried in the `__exists__` payload
  /// (`encodeExistsPayloadJson`, `sync_table_shape.dart`) and read back here.
  /// Every one of those tables used to fall out of the `resolvable = false`
  /// branch below and never produce a row on any peer.
  ///
  /// **The payload is read from `sync_field_state`, not from the arriving
  /// operation**, and that is deliberate on two counts. It is the RESOLVED
  /// winner of the `__exists__` register rather than whichever candidate
  /// happens to be in hand, so two devices that somehow hold competing
  /// `__exists__` dots insert from the same one. And it is the only source
  /// available to [sweepMissingExists]'s retry, which has no operation —
  /// re-reading here means the first attempt and the retry cannot build
  /// different rows.
  ///
  /// **The residual that survives the convergence argument, named because it
  /// is real.** This method returns early when the row already exists, so a
  /// device that inserted under one `__exists__` payload and LATER sees a
  /// different payload win the register keeps the row it already has. Every
  /// carried column is one this codebase never reassigns (that is why they
  /// sit outside `syncScopeColumns` — see each table's scope comment in
  /// `database_service.dart`), so reaching this needs two devices to hold the
  /// same row uuid under different owners: a uuid collision or a hand-edited
  /// database, not any flow the app can produce. Rewriting an owner FK
  /// underneath a live row would be a worse answer than declining to.
  Future<
    ({
      ExistsInsertOutcome outcome,
      (String, String)? blocker,
      ExistsIdentityConflict? identityConflict,
    })
  >
  _materializeExists(
    DatabaseExecutor txn,
    SyncEntityCaptureScope scope,
    String entityId,
    int existsHlcWallMs,
  ) async {
    if (await _rowExists(txn, scope, entityId)) {
      return (
        outcome: ExistsInsertOutcome.alreadyPresent,
        blocker: null,
        identityConflict: null,
      );
    }

    final columns = await syncTableInfo(txn, scope.table);
    final idColumnInfo = columns
        .where((c) => c['name'] == scope.idColumn)
        .firstOrNull;
    if (idColumnInfo == null) {
      return _unresolvable;
    }
    if (isNonPortableIntegerPrimaryKey(idColumnInfo)) {
      // e.g. user_app_libraries/user_app_library_dependencies — see top doc
      // comment, and `hasPortableEntityId` (`sync_table_shape.dart`), which
      // is the same predicate this and `_writeResolvedFieldValue` both use.
      return _unresolvable;
    }

    final syncability = await entitySyncability(
      txn,
      scope,
      cache: _syncabilityCache,
    );
    if (!syncability.canSync) {
      // **Checked BEFORE the owner-existence check below, and the order is
      // the point.** A table that can never materialize must never produce a
      // `missing_exists` queue entry — that permanent, undrainable per-peer
      // backlog is exactly what M2.10 removed. Without this line an
      // `app_revisions` `__exists__` carrying a complete `appId` would park
      // waiting for its `user_apps` row and only THEN discover that `appCode`
      // makes the row unbuildable anyway. Not reachable today (the same
      // predicate gates minting, so no such operation is produced), which is
      // why it is a guard rather than a fix.
      return _unresolvable;
    }
    final carried = syncability.existsCarriedColumns;
    final payload = decodeExistsPayload(
      await _readFieldStateValueJson(
        txn,
        scope.table,
        entityId,
        existsFieldSentinel,
      ),
    );
    if (!existsPayloadIsComplete(carried, payload)) {
      // Either this table has an unresolvable column that is not a reference
      // at all (`app_revisions.appCode`), or the winning `__exists__` was
      // minted by a build older than M2.14 and carries the constant `true`.
      // Both mean the same thing here: no row, no guess.
      return _unresolvable;
    }

    // Ordering. A child cannot be inserted before the row it references, and
    // this codebase runs with `PRAGMA foreign_keys = ON`, so an unchecked
    // INSERT is a thrown constraint failure rather than a skipped write.
    // Checked here, and re-checked in full on every retry, for exactly the
    // reason `_setAddBlocker`'s doc comment records: a table with TWO
    // references (`relationships`) can have the recorded blocker resolve
    // while the other one has not.
    final ownerBlocker = await _existsOwnerBlocker(txn, syncability, payload);
    if (ownerBlocker != null) {
      return (
        outcome: ExistsInsertOutcome.blockedOnOwner,
        blocker: ownerBlocker,
        identityConflict: null,
      );
    }

    final createdAtColumn = syncEntityCreatedAtColumnByTable[scope.table];
    final row = <String, Object?>{scope.idColumn: entityId};
    var resolvable = true;

    for (final col in columns) {
      final name = col['name'] as String;
      if (name == scope.idColumn) continue;
      if (name == createdAtColumn) {
        // New senders preserve the source timestamp, including epoch and
        // pre-epoch dates. Legacy payloads had none, so retain their HLC
        // fallback. Re-read the winning payload on queue retries as well.
        row[name] = payload[name] is int
            ? payload[name]
            : _createdAtFromHlcWall(existsHlcWallMs);
        continue;
      }
      if (carried.contains(name)) {
        row[name] = payload[name];
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
        // Neither in sync scope nor carried — `app_revisions.appCode` is the
        // one column in the whole schema still in this position, and it is a
        // blob in a TEXT column awaiting M3 (`syncContentDeferredTables`).
        //
        // **Unreachable, and kept anyway — a deliberate, disclosed
        // duplication of a predicate `entitySyncability` owns.** The
        // `!syncability.canSync` guard above rejects every table that has
        // such a column, using this exact condition, so no operation reaches
        // this line. It stays because it is the last check before an
        // unchecked `INSERT` into a schema with `PRAGMA foreign_keys = ON`
        // and live `NOT NULL` constraints, and because of where the failure
        // would land: `sweepMissingExists` calls this inside its own
        // `db.transaction`, with nothing between it and `SyncSession.run`, so
        // a thrown constraint failure aborts the user's entire sync session
        // including their unrelated pending pushes — the precise wedge
        // `_setAddBlocker`'s doc comment records as a reproduced outage.
        // Deleting a fail-closed net because the predicate in front of it is
        // currently equivalent trades a boolean for a session-level failure
        // mode the moment the two drift.
        resolvable = false;
        break;
      }
      // Nullable, or has its own SQL default — omit; SQLite fills it in.
    }

    if (!resolvable) {
      return _unresolvable;
    }

    // Forced shell-row overrides — `tags.__deleted__ = 1` today (forced
    // tombstone-at-insert; see this file's top doc comment, "Why
    // _materializeExists forcibly writes __deleted__ = 1"). Read from the
    // shared table in `sync_table_shape.dart` rather than inlined here, so
    // `SeedScanner`'s default-skip and this INSERT can never disagree about
    // what a shell row actually holds (M2.12).
    //
    // ── TRACKED RESIDUAL (pre-existing; identical before and after M2.12,
    //    NOT introduced by the default-skip and NOT fixed by it) ──────────
    //
    // This override is unconditional: it overwrites `row[entry.key]` even
    // when the loop above resolved a REAL value for that column out of
    // `sync_field_state`. So a `tags.__deleted__ = 0` that resolved BEFORE
    // its entity's own `__exists__` materialized is discarded here, and
    // nothing re-applies it — `_materializeField` only writes when a field
    // RESOLVES, and that field has already resolved. The tag stays
    // tombstoned on this device while every other replica shows it live.
    //
    // Reaching it requires a `field` operation for `tags.__deleted__` to be
    // applied before the `__exists__` for the same tag, which the ordinary
    // same-log ordering (`__exists__` is always minted first, at a lower
    // `authorSeq`) prevents — but NOT across independently-pulled device
    // logs, which is exactly the case `sweepMissingExists` exists for.
    //
    // Left unfixed here deliberately: the correct repair is for
    // `sweepMissingExists` to re-apply already-resolved field state after a
    // late `__exists__` insert (or for this override to apply only when no
    // resolved value exists, which changes the § Architecture 10 partial-
    // unique-index argument the forced tombstone is there to protect). Both
    // are materializer-scoped decisions with their own reasoning to redo,
    // and neither belongs in a traffic milestone.
    for (final entry in shellRowForcedValuesFor(scope.table).entries) {
      if (row.containsKey(entry.key)) row[entry.key] = entry.value;
    }

    // **The returned rowid is checked, and not checking it was a real,
    // silent data-loss bug (M2.14 review round 1, finding C).**
    // `ConflictAlgorithm.ignore` turns a `UNIQUE` violation into a
    // no-op that returns rowid `0` — so an `INSERT` that wrote nothing at
    // all used to be reported as `inserted`, the queue entry was resolved (or
    // never created), and every one of the entity's field operations then
    // parked forever against a row that does not exist. That reproduces
    // exactly the "11 permanent `missing_exists` entries on `user_apps`"
    // symptom this file's own top doc comment cites as the pre-M2.14 bug.
    //
    // `ignore` is retained rather than dropped: the conflict has to be
    // OBSERVED rather than thrown, because a throw here escapes
    // `sweepMissingExists` and aborts the whole session (see the
    // `resolvable` branch above for the same reasoning).
    final rowId = await txn.insert(
      scope.table,
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (rowId == 0) {
      return (
        outcome: ExistsInsertOutcome.identityConflict,
        blocker: null,
        identityConflict: await _existsIdentityConflict(
          txn,
          scope,
          syncability,
          payload,
          entityId,
        ),
      );
    }
    return (
      outcome: ExistsInsertOutcome.inserted,
      blocker: null,
      identityConflict: null,
    );
  }

  /// The shorthand every "this row cannot be built" exit uses.
  static const ({
    ExistsInsertOutcome outcome,
    (String, String)? blocker,
    ExistsIdentityConflict? identityConflict,
  })
  _unresolvable = (
    outcome: ExistsInsertOutcome.unresolvable,
    blocker: null,
    identityConflict: null,
  );

  /// Which carried IDENTITY value (a carried column that is not a declared
  /// foreign key — `user_apps.uuid` is the only one in today's schema) is
  /// already held by a different local row, and which row that is.
  ///
  /// Best-effort by design: it names the collision for the queue entry and
  /// the health surface, and returns null when it cannot attribute one (a
  /// `UNIQUE` constraint over a column this rule does not carry, a `CHECK`,
  /// anything else `ConflictAlgorithm.ignore` swallowed). The caller parks
  /// the operation either way — an unattributed conflict is still a
  /// conflict, and reporting "an identity constraint rejected this row"
  /// beats reporting a successful insert that never happened.
  Future<ExistsIdentityConflict?> _existsIdentityConflict(
    DatabaseExecutor txn,
    SyncEntityCaptureScope scope,
    EntitySyncability syncability,
    Map<String, Object?> payload,
    String entityId,
  ) async {
    final referenceColumns = {
      for (final reference in syncability.existsOwnerReferences)
        reference.column,
    };
    for (final column in syncability.existsCarriedColumns) {
      if (referenceColumns.contains(column)) continue;
      final value = payload[column];
      if (value == null) continue;
      final rows = await txn.query(
        scope.table,
        columns: [scope.idColumn],
        where: '$column = ? AND ${scope.idColumn} != ?',
        whereArgs: [value, entityId],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      return (
        column: column,
        value: '$value',
        existingId: '${rows.first[scope.idColumn]}',
      );
    }
    return null;
  }

  /// The first row an `__exists__` shell insert references that does not
  /// exist locally yet, as `(table, id)`, or `null` when every reference is
  /// satisfied.
  ///
  /// Queried directly against the referenced `(table, column)` rather than
  /// through [_entityScopesByTable], because a foreign key is free to point
  /// at a column that is not that table's sync `idColumn` — and because a
  /// reference to a table with no capture scope at all still has to be
  /// checked before SQLite checks it for us.
  ///
  /// **The comparison is against the raw payload value, with no
  /// `CAST(... AS TEXT)` around the column.** Wrapping a column in a
  /// function makes the expression non-sargable, so SQLite cannot use the
  /// index on the referenced key and scans the whole owner table — once per
  /// carried reference, per `__exists__`, on a first sync that is one full
  /// `notes` scan per arriving subnote. The cast bought nothing: SQLite
  /// applies the COLUMN's own type affinity to the other operand of a
  /// comparison, so an INTEGER key compared against the string `'5'` still
  /// matches the row with `5`, and a TEXT key compared against `5` still
  /// matches `'5'`. This is the identical treatment SQLite will apply when it
  /// enforces the foreign key on the `INSERT` a moment later, which is the
  /// property this check actually needs — a check that answers a different
  /// question from the constraint it is pre-empting is worse than no check.
  Future<(String, String)?> _existsOwnerBlocker(
    DatabaseExecutor txn,
    EntitySyncability syncability,
    Map<String, Object?> payload,
  ) async {
    for (final reference in syncability.existsOwnerReferences) {
      final ownerId = payload[reference.column];
      if (ownerId == null) continue; // completeness was checked by the caller
      final rows = await txn.query(
        reference.table,
        columns: [reference.toColumn],
        where: '${reference.toColumn} = ?',
        whereArgs: [ownerId],
        limit: 1,
      );
      if (rows.isEmpty) return (reference.table, '$ownerId');
    }
    return null;
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
    required SyncChangeCollector changes,
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
      // The auto-merge just tombstoned a DIFFERENT, pre-existing local tag —
      // a real row write for a row no arriving operation names, so it needs
      // announcing on its own account.
      changes.recordRow('tags', collisionId);
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
    required SyncChangeCollector changes,
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

    final outcome = await _insertMembershipRow(
      txn,
      scope: scope,
      entityId: op.entityId,
      memberUuid: op.memberUuid!,
      payloadJson: op.valueJson,
      hlcWallMs: op.hlc.wallMs,
    );
    // The membership belongs to the OWNING entity, which is what
    // `SyncChangeCollector` maps: `note_tags`' scope names `notes`, so a
    // tag add/remove announces the note whose tag list changed.
    if (outcome == MembershipInsertOutcome.inserted) {
      changes.recordRow(scope.entityTable, op.entityId);
    }
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
        //
        // **F5 (M2.13, review round 5): the wall-0 case is handled here too,
        // and it was previously masked rather than absent.** A post-reset
        // re-seed can stamp `Hlc.zero`, so `hlcWallMs` can legitimately be
        // `0` — and this line would then date the mapping row 1970-01-01,
        // the identical defect `_materializeExists` had one layer up. The
        // only reason it was not reachable is that all three
        // createdAt-bearing membership scopes declare
        // `payloadColumns: ['createdAt']` and that column is `NOT NULL`, so
        // the payload branch above always wins first — a masking nothing
        // anywhere recorded, and one a single scope losing its payload
        // column (or a pre-M2.10 `set_add`, which carries no payload at all,
        // arriving in the same round as a reset) would remove. Routed
        // through the same [_createdAtFromHlcWall] derivation as the entity
        // path so the two can never disagree about what a wall-0 operation
        // means. (`set_add` seeds are NOT recessive today — see
        // `seed_scanner.dart`'s mint site for why — so this branch is belt
        // and braces, not the live path. It is written anyway because
        // "unreachable given today's scope declarations" is exactly the kind
        // of claim this milestone has been wrong about four times.)
        row[name] = _createdAtFromHlcWall(hlcWallMs);
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
    required SyncChangeCollector changes,
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

    final deleted = await txn.delete(
      scope.membershipTable,
      where: '${scope.entityIdColumn} = ? AND ${scope.memberIdColumn} = ?',
      whereArgs: [op.entityId, op.memberUuid],
    );
    // A `set_remove` whose real row was already gone (a duplicate resolution,
    // or a cascade that beat it) changed nothing to announce.
    if (deleted > 0) changes.recordRow(scope.entityTable, op.entityId);
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
    String blockingReason = missingExistsBlockingReason,
  }) async {
    await txn.insert('sync_materialize_queue', {
      'blockingReason': blockingReason,
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

  /// Parks (or re-describes) one `__exists__` under
  /// [existsIdentityConflictBlockingReason].
  ///
  /// Written through the same queue and swept by the same sweep as every
  /// other deferral, deliberately: a reason with no reader is a wedge with
  /// better paperwork (see [sweepMissingExists]'s own note on
  /// [unfillableMembershipColumnBlockingReason]). `blockingKey` names the
  /// colliding `table.column:value` so the health surface can say what is
  /// actually wrong, and so a second arriving operation for the same
  /// collision re-describes the existing entry instead of stacking a new one.
  Future<void> _enqueueExistsIdentityConflict(
    DatabaseExecutor txn, {
    required SyncEntityCaptureScope scope,
    required String entityId,
    required int hlcWallMs,
    required ExistsIdentityConflict? conflict,
  }) async {
    final existing = await txn.query(
      'sync_materialize_queue',
      columns: const ['id'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [scope.table, entityId, existsFieldSentinel],
      limit: 1,
    );
    final blockingKey = conflict == null
        ? '${scope.table}:$entityId'
        : '${scope.table}.${conflict.column}:${conflict.value}';
    final operationJson = jsonEncode({
      'kind': existsFieldSentinel,
      'fieldName': existsFieldSentinel,
      'hlcWallMs': hlcWallMs,
      if (conflict != null) ...{
        'conflictColumn': conflict.column,
        'conflictValue': conflict.value,
        'conflictExistingId': conflict.existingId,
      },
      // The sweep re-derives its blocker from scratch; these keep a queued
      // row self-describing without re-running any of this logic.
      'waitingOnTable': scope.table,
      'waitingOnId': entityId,
    });
    if (existing.isNotEmpty) {
      await txn.update(
        'sync_materialize_queue',
        {
          'blockingReason': existsIdentityConflictBlockingReason,
          'operationJson': operationJson,
          'blockingKey': blockingKey,
        },
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      return;
    }
    await txn.insert('sync_materialize_queue', {
      'blockingReason': existsIdentityConflictBlockingReason,
      'entityTable': scope.table,
      'entityId': entityId,
      'fieldName': existsFieldSentinel,
      'operationJson': operationJson,
      'blockingKey': blockingKey,
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
    // **Chunked (M3.8).** A register holds the same values the wire does,
    // so `app_revisions.appCode` and `user_apps.htmlContent` land here at
    // whatever size the authoring device had them — this is the read that
    // writes a mini app's source into the real row, and on Android an
    // oversized one is an exception rather than a truncation.
    final rows = await readSyncRowsWhere(
      txn,
      table: 'sync_field_state',
      columns: const ['valueJson'],
      keyColumns: const ['entityTable', 'entityId', 'fieldName'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [entityTable, entityId, fieldName],
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

  /// Delegates to [shellRowPlaceholderValue] (`sync_table_shape.dart`) —
  /// M2.12 moved the body there because `SeedScanner`'s default-skip needs
  /// the identical answer and must get it from the same function, not a
  /// copy. See that function's own doc comment.
  Object? _placeholderDefault(Map<String, Object?> column) =>
      shellRowPlaceholderValue(column);

  /// § Architecture 10 round 19's `hash(...)` — the same `sha256` hex-digest
  /// convention `field_conflict_resolver.dart`'s `_rowId` already uses for
  /// every other deterministic id in this codebase.
  String _sha256Hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();
}
