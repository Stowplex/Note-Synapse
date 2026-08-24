// Outbox drain — M2.4, § Architecture 11.3 ("Mutation capture: from
// ordinary writes to a durable outbox") and § 11.7's "Phase 0 — drain" of
// the CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// `database_service.dart`'s new mutation-capture triggers durably record
// THAT something changed (`sync_touch_log`), deliberately never WHAT it
// changed to (§ 11.3: "Deliberately, sync_touch_log does not record what
// changed, only that something did"). This file is the other half: turning
// each accumulated touch into a real `Operation`, minted into
// `sync_pending_ops`, only when the entity/field/membership's CURRENT live
// value actually differs from what this device last recorded.
//
// **What "last recorded" means for THIS milestone, precisely.** The design
// doc's real materialization layer (§ 11.6, "writing a resolved value back
// into a real app-table row") is M2.7's job — it does not exist yet. So
// there is no real "last-materialized CRDT winner" for drain to compare
// against. Per this milestone's own brief: for THIS milestone's purposes,
// "last-materialized winner" means whatever `sync_field_state`/
// `sync_set_state` currently holds for that (entityTable, entityId,
// fieldName[, memberUuid]) — and if no such row exists yet, ANY current
// value needs a fresh operation (the bootstrap/first-sync case: there is
// nothing to compare against). [drain] is the ONLY writer of
// `sync_field_state`/`sync_set_state` that exists anywhere in this
// codebase today — see the class doc comment below for why that's
// necessary (not just permissible) for double-drain correctness, and why
// it's still safe against M2.7 later becoming the "real" writer for
// REMOTE operations.
//
// **What this milestone does NOT do**, named explicitly per its own scope
// boundary: no causal comparator, no `contentKey` dedup, no field-conflict
// resolution (all M2.5); no wire format encoding or push/pull against
// `SyncBackend` (M2.6); no materialization of INCOMING remote operations
// (M2.7 — this file only ever handles the LOCAL-write-to-outbox
// direction); no `seed:`/`external:` authorId namespace minting (every
// operation this file mints uses the ordinary device authorId, via
// [DeviceIdentity.ensureDeviceId]).

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'device_identity.dart';
import 'frontier.dart';
import 'hlc.dart';
// For `missingExistsBlockingReason` only. `_repairExistsRegisters` manufactures
// a queue row for `SyncMaterializer.sweepMissingExists` to retry, and naming
// the reason from the file that owns it is what stops the two spelling it
// differently — the drift class `sync_table_shape.dart` was extracted to end.
import 'blob_sync.dart';
import 'large_row_reader.dart';
import 'materializer.dart';
import 'seed_scanner.dart';
import 'seq_counter.dart';
import 'sync_table_shape.dart';

/// One `Operation` minted into `sync_pending_ops` by a drain pass. Mirrors
/// that table's own columns (`database_service.dart`'s
/// `_createSyncPendingOpsTable`) directly — this class exists purely for
/// [DrainResult] to report what happened in a typed way (tests, and future
/// M2.6 push-loop consumption), not as a second, independently-maintained
/// encoding of the wire format (§ 11.5 owns that, a later milestone).
class MintedOperation {
  const MintedOperation({
    required this.authorId,
    required this.authorSeq,
    required this.hlc,
    required this.kind,
    required this.entityTable,
    required this.entityId,
    this.fieldName,
    this.memberUuid,
    this.valueJson,
    this.targetDots,
  });

  final String authorId;
  final int authorSeq;
  final Hlc hlc;

  /// `'__exists__' | 'field' | 'set_add' | 'set_remove'` — § Architecture
  /// 1's canonical `Operation.kind` values.
  final String kind;
  final String entityTable;
  final String entityId;
  final String? fieldName;
  final String? memberUuid;
  final String? valueJson;

  /// `set_remove` only: the add-dot(s) being observed as removed, as
  /// `(authorId, authorSeq)` pairs. Always this device's OWN previously
  /// locally-recorded add-dot(s) from `sync_set_state` — this milestone
  /// mints purely from local state, so no `sync_dot_redirects` resolution
  /// is needed or attempted (that mechanism, and remote dots in general,
  /// are out of scope until M2.5/M2.6/M2.7 build the pull loop).
  final List<(String authorId, int authorSeq)>? targetDots;
}

/// Summary of one [OutboxDrainer.drain] call.
class DrainResult {
  const DrainResult({
    required this.touchesProcessed,
    required this.mintedOperations,
    this.nonPortableTablesSkipped = const [],
  });

  final int touchesProcessed;
  final List<MintedOperation> mintedOperations;

  /// Tables whose touches were deliberately dropped without minting
  /// anything, because their primary key is a non-portable `INTEGER PRIMARY
  /// KEY AUTOINCREMENT` — see `hasPortableEntityId`
  /// (`sync_table_shape.dart`).
  ///
  /// **Reported for the same reason `SeedScanResult.nonPortableTablesSkipped`
  /// is, and its absence here was a real problem, not a cosmetic one.** A
  /// user with User-App libraries gets no sync for them at all; silently
  /// dropping the touches gave them — and this codebase's own tests — no
  /// signal whatsoever. That invisibility is literally why the
  /// materialization-side half of this same guard shipped with zero test
  /// coverage: nothing anywhere could observe the refusal, so nothing
  /// asserted on it.
  final List<String> nonPortableTablesSkipped;
}

/// Drains `sync_touch_log` into `sync_pending_ops` (§ 11.3/§ 11.7 Phase 0).
///
/// **The double-drain / no-op-revert question, answered and enforced by
/// construction, not merely hoped for.** [drain] is the only place in this
/// codebase that writes to `sync_field_state`/`sync_set_state` today — a
/// deliberate decision, not an oversight of "someone else will write these
/// eventually": drain's own correctness criterion ("does the current value
/// differ from what's already recorded?") is meaningless unless something
/// keeps that record up to date as drain itself mints operations. A
/// device's own newly-minted operation always wins against that same
/// device's own immediately-prior state — there is no conflict to resolve
/// (unlike materializing a REMOTE operation, which might lose a field
/// conflict against a value this device itself wrote more recently — a
/// judgment call M2.5's causal comparator owns). So it is safe, not merely
/// convenient, for drain to immediately record its own mint as the new
/// "current winner" in the same transaction. Concretely, this is what makes
/// three required behaviors fall out for free, verified in
/// `test/sync_engine/outbox_drainer_test.dart`:
///   1. **Draining twice in a row mints nothing new the second time.** The
///      second pass finds `sync_field_state`/`sync_set_state` already
///      reflecting the first pass's writes, so "current value == recorded
///      value" for everything, everywhere.
///   2. **Multiple touch rows for the SAME field, accumulated in the SAME
///      batch (e.g. two edits before the next sync), collapse to at most
///      ONE minted operation, not one per touch.** The first touch's
///      processing mints and immediately records the (already-final, since
///      drain runs after all touches have accumulated) current value; every
///      subsequent touch for that same field in the same pass then sees
///      "current == just-recorded" and mints nothing.
///   3. **A field changed and changed back to its PREVIOUSLY-SYNCED value
///      before drain runs produces no operation.** If a prior drain already
///      recorded that value as current, this drain's comparison finds no
///      difference — a real no-op, not something drain has to special-case.
///
/// **This is deliberately NOT the same thing as § 11.6 materialization.**
/// M2.7 will still need its own, separate write path for REMOTE operations
/// (real field-conflict resolution against a possibly-different local
/// value, writing back into the real app-table row, not just
/// `sync_field_state`) — drain's writes here are scoped purely to keeping
/// its OWN comparison baseline correct for this device's own local writes,
/// never a substitute for that.
class OutboxDrainer {
  OutboxDrainer(
    this._databaseService,
    this._deviceIdentity,
    this._seqCounter,
    this._hlc,
  );

  final DatabaseService _databaseService;
  final DeviceIdentity _deviceIdentity;
  final SeqCounter _seqCounter;
  final HybridLogicalClock _hlc;

  static const _existsFieldSentinel = '__exists__';

  /// **M2.7 closes the disclosed residual this helper used to describe.**
  /// § Architecture 2's frontier is `{authorId: maxSeq}` over every author
  /// this device has ever OBSERVED. Before M2.6's pull loop existed, no
  /// durable per-remote-author record existed to fold in, so this helper
  /// stamped only `{authorId: authorSeq}` for the operation just minted —
  /// correct only for a device that had never merged a remote author's
  /// operations. M2.6 built the missing piece
  /// (`sync_state['frontier:<authorId>']`, maintained unconditionally on
  /// every observed pulled commit, § 11.7 Phase B step 4), and this now
  /// delegates to the shared [currentFrontierJson] helper (`frontier.dart`)
  /// — the same one `materializer.dart`'s own auto-merge mints use — so
  /// every freshly, locally-minted operation (whether an ordinary drained
  /// edit or an M2.7 auto-merge write) stamps as informative a frontier as
  /// this device's current knowledge allows, not just its own dot.
  Future<String> _currentFrontierJson(
    DatabaseExecutor txn,
    String authorId,
    int authorSeq,
  ) {
    return currentFrontierJson(txn, authorId, authorSeq);
  }

  late final Map<String, SyncEntityCaptureScope> _entityScopesByTable = {
    for (final scope in DatabaseService.syncEntityCaptureScopes)
      scope.table: scope,
  };

  /// Memoizes [entitySyncability] for this drainer's lifetime. Scoped to the
  /// instance rather than to one `drain()` call, which is still exactly the
  /// scoping that function's doc comment requires (schema shape is immutable
  /// for an open database, and one `OutboxDrainer` holds one
  /// `DatabaseService`) — `_processExistsTouch` needs the same answer
  /// `drain()` already computed, and threading a local map through three
  /// call layers to say so buys nothing.
  final Map<String, EntitySyncability> _syncabilityCache = {};

  // M2.7 note: this composite-key string literal (and the identically-shaped
  // one in `_processSetTouch` below) was found, during M2.7 development, to
  // contain a literal NUL byte (0x00) in place of the space between
  // `${scope.entityTable}` and `${scope.fieldName}` — a byte-level file
  // corruption invisible in any text-rendering tool (it displays as a plain
  // space), only detectable by inspecting the file's raw bytes. Both sites
  // were fixed by replacing the NUL byte with an ordinary space. Left as an
  // inline note (rather than only in the milestone report) since this file
  // predates M2.7 and is untracked in git, so there is no commit/diff trail
  // to point to otherwise.
  late final Map<String, SyncSetCaptureScope> _setScopesByTableAndField = {
    for (final scope in DatabaseService.syncSetCaptureScopes)
      '${scope.entityTable} ${scope.fieldName}': scope,
  };

  /// Processes every `sync_touch_log` row with `processedAt IS NULL`, in
  /// `id` order (§ 11.3's drain-ordering invariant). Safe to call
  /// repeatedly (including with zero pending touches).
  Future<DrainResult> drain() async {
    final db = await _databaseService.database;
    final authorId = await _deviceIdentity.ensureDeviceId();

    // Runs BEFORE the touch query, so the touches it manufactures drain in
    // this very pass rather than waiting for the next sync.
    await _repairExistsRegisters(db);

    final touches = await db.query(
      'sync_touch_log',
      where: 'processedAt IS NULL',
      orderBy: 'id ASC',
    );

    final minted = <MintedOperation>[];
    final skipped = <String, bool>{};
    // Schema shape is immutable for this pass — see `entitySyncability`.
    final syncabilityCache = _syncabilityCache;
    for (final touch in touches) {
      final touchId = touch['id'] as int;
      final entityTable = touch['entityTable'] as String;
      final entityId = touch['entityId'] as String;
      final fieldName = touch['fieldName'] as String?;
      final memberUuid = touch['memberUuid'] as String?;

      // M2.10's syncability gate, checked ONCE here rather than inside each
      // per-kind handler. Two distinct failures, one predicate
      // (`entitySyncability`, `sync_table_shape.dart`):
      //
      //  * a non-portable `INTEGER PRIMARY KEY` means this row's `entityId`
      //    identifies a DIFFERENT row on every other device, so minting for
      //    it silently corrupts whatever occupies that id there;
      //  * a `NOT NULL` column outside sync scope (an owner FK, or
      //    `user_apps.uuid`) means no receiving device can ever build the
      //    row at all — so every operation minted for it becomes a
      //    permanent, undrainable `missing_exists` queue entry on every
      //    peer, forever, for data that can never appear.
      //
      // The touch is still marked processed (there is no future point at
      // which it becomes mintable) and the table is recorded on
      // [DrainResult.nonPortableTablesSkipped], which feeds the sync health
      // surface — silently dropping it is the failure mode this milestone
      // kept rediscovering.
      final ownerScope = _entityScopesByTable[entityTable];
      final syncability = ownerScope == null
          ? const EntitySyncability.ok()
          : await entitySyncability(db, ownerScope, cache: syncabilityCache);
      if (!syncability.canSync) {
        skipped['$entityTable (${syncability.reasonLabel})'] = true;
        await db.update(
          'sync_touch_log',
          {'processedAt': DateTime.now().millisecondsSinceEpoch},
          where: 'id = ?',
          whereArgs: [touchId],
        );
        continue;
      }

      final result = await db.transaction((txn) async {
        final ops = <MintedOperation>[];
        if (memberUuid != null) {
          final op = await _processSetTouch(
            txn,
            authorId: authorId,
            entityTable: entityTable,
            entityId: entityId,
            fieldName: fieldName,
            memberUuid: memberUuid,
          );
          if (op != null) ops.add(op);
        } else if (fieldName == null) {
          ops.addAll(
            await _processExistsTouch(
              txn,
              authorId: authorId,
              entityTable: entityTable,
              entityId: entityId,
            ),
          );
        } else {
          final op = await _processFieldTouch(
            txn,
            authorId: authorId,
            entityTable: entityTable,
            entityId: entityId,
            fieldName: fieldName,
          );
          if (op != null) ops.add(op);
        }

        await txn.update(
          'sync_touch_log',
          {'processedAt': DateTime.now().millisecondsSinceEpoch},
          where: 'id = ?',
          whereArgs: [touchId],
        );
        return ops;
      });
      minted.addAll(result);
    }

    return DrainResult(
      touchesProcessed: touches.length,
      mintedOperations: minted,
      nonPortableTablesSkipped: List.unmodifiable(
        skipped.keys.toList()..sort(),
      ),
    );
  }

  /// `sync_state` key marking that the one-shot `__exists__` register repair
  /// has run on this device.
  ///
  /// **`v2`, and the bump is load-bearing.** M2.14 shipped a `v1` pass that
  /// only ever looked in ONE direction (a local row whose recorded register
  /// is stale). A device that already wrote the `v1` marker still has the
  /// two other halves of the same hole unrepaired, so it has to run again.
  static const String existsRegisterRepairStateKey =
      'exists_register_repair_v2_completed_at';

  /// `sync_state` key marking that the ORPHAN half (arm 2 — a complete
  /// register with no local row) has run.
  ///
  /// **Separate from [existsRegisterRepairStateKey] because the two arms have
  /// different preconditions** (review round 3, finding H1). Arm 1 waits for
  /// the seed scan; arm 2 must not, because a device whose seed is
  /// indefinitely deferred is exactly the device whose orphaned registers
  /// nothing else will ever rebuild. One shared marker meant a single parked
  /// queue entry could disable the whole repair permanently.
  static const String existsOrphanRepairStateKey =
      'exists_orphan_repair_v1_completed_at';

  /// **One reconciliation of `__exists__` registers against real rows, in
  /// both directions — the single mechanism for defects that were reported
  /// as two.**
  ///
  /// ---------------------------------------------------------------------
  /// **The invariant.** For every entity table whose `__exists__` carries
  /// columns, a complete register and a local row must coexist. Each side
  /// can go missing on its own, by a different route, and each leaves no
  /// retry record — which is the actual shape of the defect, not two
  /// separate ones:
  ///
  ///  * **A row with no complete register.** Two populations. Entities
  ///    created on an **M2.10..M2.13** build, where `drain()`'s syncability
  ///    gate marked the `AFTER INSERT` touch processed and minted nothing on
  ///    the stated assumption that "there is no future point at which it
  ///    becomes mintable" — M2.14 is exactly the falsification of that, and
  ///    the seed scan cannot rescue them either because it short-circuits on
  ///    [seedScanCompletedAtKey]. And entities whose register was minted
  ///    **before M2.14**, carrying the constant `true`, which no ordinary
  ///    mint site would ever replace because its condition is "no register
  ///    recorded" and one IS recorded. Without this arm, every subnote, note
  ///    link, note attachment, chat attachment and mini app a user already
  ///    had stays invisible to sync permanently, with no error anywhere —
  ///    the exact failure this milestone exists to end, on precisely the
  ///    data that prompted it.
  ///  * **A complete register with no row.** An M2.13 build that pulls a
  ///    NEW-format `__exists__` consumes the operation, records the register
  ///    as complete, builds no row, and enqueues nothing for the `__exists__`
  ///    itself (only for the field operations, which then wait forever on a
  ///    row nothing will create). After that device upgrades, nothing
  ///    rebuilds it: `_materializeExists`'s two call sites are a
  ///    `winnerChanged` gate, which a re-delivered or dominated operation
  ///    never satisfies, and `sweepMissingExists`, which only ever retries
  ///    rows already IN the queue. **This milestone's own upgrade arm is
  ///    what triggers it** — the first device to upgrade re-mints for every
  ///    stale child row, and a second device still on the old build consumes
  ///    that stream and silently loses it. Staggered updates across two
  ///    devices is the normal deployment, not an exotic one.
  ///
  /// **Why one pass and not two.** Both arms are the same enumeration over
  /// the same tables under the same gate, and both do the same thing with
  /// what they find: **manufacture exactly the input the existing machinery
  /// already knows how to consume**, rather than re-implementing minting or
  /// materialization here. Arm 1 writes an `AFTER INSERT`-shaped touch
  /// (`fieldName IS NULL`) that `_processExistsTouch` drains in this very
  /// pass; arm 2 writes a `missing_exists` queue row that
  /// `SyncMaterializer.sweepMissingExists` retries during this same session's
  /// pull (Phase 0 runs before Phase B), complete with its owner-blocker
  /// re-derivation and its `__exists__`-entries-first ordering, so one sweep
  /// drains the rebuilt entity's parked field operations along with it.
  /// Splitting them would mean two markers, two enumerations and two places
  /// to notice the next time this invariant acquires a third way to break.
  ///
  /// Arm 2 costs no operations on the wire and neither arm costs a wire
  /// change, and this is the mechanism M3 will need unchanged the day
  /// `appCode` becomes supplyable and every parked `app_revisions` register
  /// needs rebuilding: that table enters the loop automatically the moment
  /// `entitySyncability` stops blocking it.
  ///
  /// ---------------------------------------------------------------------
  /// **Completeness is tested in Dart, by the same function the runtime
  /// uses, and that is a fix rather than a style choice.** The `v1` pass
  /// tested staleness in SQL with `valueJson NOT LIKE '{%'` while
  /// `_processExistsTouch` and `_materializeExists` both test it with
  /// [existsPayloadIsComplete]. The two disagree about a PARTIALLY complete
  /// object payload — one carried column present, a second missing — which
  /// is exactly what adding a carried column to an existing table produces,
  /// and the SQL side would call such a register fresh and skip it forever.
  /// They agreed only because there is one payload generation today. No SQL
  /// predicate both stays narrow and provably matches
  /// [existsPayloadIsComplete] (an explicit null value defeats every
  /// key-presence `LIKE`, and a value containing the key's own text defeats
  /// it in the other direction), so the candidate rows are read and the ONE
  /// function decides — the same agree-by-construction argument
  /// `shellRowPlaceholderValue` makes for the shell-row defaults.
  ///
  /// ---------------------------------------------------------------------
  /// **Gated on the seed scan having completed, which is a correctness gate
  /// and not an optimization.** Phase 0 (drain) runs BEFORE Phase 0.5 (the
  /// seed scan). On a device whose seed scan has not finished, every
  /// pre-existing row legitimately has no register yet, and arm 1 would mint
  /// all of them through the ORDINARY namespace — preempting the seed scan's
  /// `seed:` namespace and its GENESIS `contentKey`s, and destroying the
  /// cross-device seed dedup § Architecture 1's M2.10 addendum rests on.
  /// Before the seed completes there is nothing here to repair; the seed
  /// scan covers those rows itself, correctly.
  ///
  /// **Why a `sync_state` marker and not a schema migration.** No column or
  /// table changes, so there is nothing for a migration's `PRAGMA table_info`
  /// guard to guard and nothing for `recovery_screen.dart` to mirror; the
  /// work is entirely about sync-engine state, which is where
  /// [seedScanCompletedAtKey] already lives. Correctness does not depend on
  /// the marker either — both arms select only rows that are genuinely out
  /// of sync, so deleting the marker and re-running is a no-op on a repaired
  /// device (asserted by a test). The marker is what keeps a full scan of
  /// every carried table off every ordinary sync.
  ///
  /// **The re-mint dominates rather than merely out-timestamping the
  /// register it replaces**, which is what makes it uncontested (no
  /// `sync_conflict_copies` row, no tie-break) — and that rests on
  /// `frontier.dart`'s M2.10 fix, not on luck: a locally-minted operation's
  /// frontier folds in every `next_seq:` namespace this device mints under
  /// (so a legacy `seed:<self>` dot is covered) as well as every
  /// `frontier:<author>` it has pulled (so a legacy dot authored elsewhere
  /// is covered too).
  Future<void> _repairExistsRegisters(Database db) async {
    final markers = await db.query(
      'sync_state',
      columns: const ['key'],
      where: 'key IN (?, ?, ?)',
      whereArgs: [
        existsRegisterRepairStateKey,
        existsOrphanRepairStateKey,
        seedScanCompletedAtKey,
      ],
    );
    final keys = {for (final row in markers) row['key'] as String};

    // **The seed gate applies to arm 1 ONLY, and the two arms therefore carry
    // separate markers** (review round 3, finding H1). Gating the whole pass
    // was this fix round introducing its own failure mode: `SeedScanner`
    // withholds [seedScanCompletedAtKey] whenever ANY `sync_materialize_queue`
    // row defers a local entity+field, and that state can be permanent — a
    // `missing_referenced_dot` for an add-dot in a log a peer's reset retired
    // never resolves, and retired logs are never reclaimed. Reproduced: one
    // parked entry, three full rounds, neither marker ever written.
    //
    // The split is sound because the gate's own argument is arm-1-specific.
    // Arm 1 MINTS, through the ordinary namespace, so running it mid-seed
    // would preempt the seed's `seed:` namespace and its GENESIS
    // `contentKey`s. Arm 2 mints NOTHING — it enqueues a `missing_exists` row
    // for `sweepMissingExists`, which is pure local materialization of a
    // register this device already holds. There is no namespace to preempt
    // and no `contentKey` to destroy, so nothing about the seed's state makes
    // it unsafe.
    //
    // The asymmetry also matters in the other direction: a device stuck in
    // seed deferral does NOT need arm 1, because the seed scan itself walks
    // local rows and mints their `__exists__`. It is arm 2 that has no
    // substitute there — the seed only ever walks local rows, so a complete
    // register with no row (defect A) would go unrepaired forever, which is
    // precisely the cohort this whole mechanism exists for.
    final arm1Done = keys.contains(existsRegisterRepairStateKey);
    final arm2Done = keys.contains(existsOrphanRepairStateKey);
    final runArm1 = !arm1Done && keys.contains(seedScanCompletedAtKey);
    final runArm2 = !arm2Done;
    if (!runArm1 && !runArm2) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final scope in DatabaseService.syncEntityCaptureScopes) {
      final syncability = await entitySyncability(
        db,
        scope,
        cache: _syncabilityCache,
      );
      final carried = syncability.existsCarriedColumns;
      if (carried.isEmpty) continue;
      // A table that still cannot sync at all (`app_revisions`, blocked by
      // `appCode`) would have arm 1's touches dropped by drain's own gate a
      // moment later, and arm 2 must never enqueue for it — a queue entry
      // whose prerequisite can never arrive is the permanent, undrainable
      // per-peer backlog M2.10 spent a milestone deleting.
      if (!syncability.canSync) continue;

      // ── Arm 1: a local row with no complete register ──────────────────
      if (runArm1) {
      final rowsWithoutRegister = await db.rawQuery(
        'SELECT CAST(t.${scope.idColumn} AS TEXT) AS entityId, '
        's.valueJson AS valueJson '
        'FROM ${scope.table} t '
        'LEFT JOIN sync_field_state s '
        'ON s.entityTable = ? '
        'AND s.entityId = CAST(t.${scope.idColumn} AS TEXT) '
        'AND s.fieldName = ?',
        [scope.table, _existsFieldSentinel],
      );
      for (final row in rowsWithoutRegister) {
        final valueJson = row['valueJson'] as String?;
        if (valueJson != null &&
            existsPayloadIsComplete(carried, decodeExistsPayload(valueJson))) {
          continue;
        }
        await db.insert('sync_touch_log', {
          'entityTable': scope.table,
          'entityId': row['entityId'],
          'fieldName': null,
          'memberUuid': null,
          'touchedAt': now,
        });
      }
      }

      // ── Arm 2: a complete register with no local row ──────────────────
      if (!runArm2) continue;
      final registersWithoutRow = await db.rawQuery(
        'SELECT s.entityId AS entityId, s.valueJson AS valueJson, '
        's.hlc AS hlc '
        'FROM sync_field_state s '
        'LEFT JOIN ${scope.table} t '
        'ON CAST(t.${scope.idColumn} AS TEXT) = s.entityId '
        'WHERE s.entityTable = ? AND s.fieldName = ? '
        'AND t.${scope.idColumn} IS NULL',
        [scope.table, _existsFieldSentinel],
      );
      for (final row in registersWithoutRow) {
        final valueJson = row['valueJson'] as String?;
        if (valueJson == null ||
            !existsPayloadIsComplete(carried, decodeExistsPayload(valueJson))) {
          // An incomplete register with no row is not repairable from here:
          // there is no owner value to build a row with, and this device has
          // no row to re-mint from either. The OTHER device's arm 1 is what
          // fixes it, by republishing a complete payload. Nothing is queued,
          // deliberately, so no undrainable entry is created.
          continue;
        }
        final entityId = row['entityId'] as String;
        final already = await db.query(
          'sync_materialize_queue',
          columns: const ['id'],
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: [scope.table, entityId, _existsFieldSentinel],
          limit: 1,
        );
        if (already.isNotEmpty) continue; // already deferred — keep its aging
        await db.insert('sync_materialize_queue', {
          'blockingReason': missingExistsBlockingReason,
          'entityTable': scope.table,
          'entityId': entityId,
          'fieldName': _existsFieldSentinel,
          'operationJson': jsonEncode({
            'kind': _existsFieldSentinel,
            'fieldName': _existsFieldSentinel,
            // The register's own winning HLC, so the rebuilt row derives the
            // same createdAt the original materialization would have
            // (`_createdAtFromHlcWall`) rather than "whenever the repair ran".
            'hlcWallMs': _hlcWallMsOrZero(row['hlc'] as String?),
            // Re-derived in full by the sweep; recorded so a queued row is
            // self-describing without re-running any of this.
            'waitingOnTable': scope.table,
            'waitingOnId': entityId,
          }),
          'blockingKey': '${scope.table}:$entityId',
          'enqueuedAt': now,
        });
      }
    }

    // Each arm marks its own completion. Arm 1's marker is only written when
    // it actually ran, so a device that drained while its seed scan was still
    // deferred retries arm 1 on a later round rather than being permanently
    // skipped — the H1 failure this split exists to remove.
    if (runArm1) {
      await db.insert('sync_state', {
        'key': existsRegisterRepairStateKey,
        'value': '$now',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (runArm2) {
      await db.insert('sync_state', {
        'key': existsOrphanRepairStateKey,
        'value': '$now',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// The wall-clock component of a stored `sync_field_state.hlc`, or `0` when
  /// it is absent or unparseable. `0` is a real, expected value rather than a
  /// sentinel — a post-reset re-seed stamps [Hlc.zero] — and
  /// `_createdAtFromHlcWall` already handles it by falling back to this
  /// device's own clock.
  static int _hlcWallMsOrZero(String? raw) {
    if (raw == null) return 0;
    try {
      return Hlc.parse(raw).wallMs;
    } catch (_) {
      return 0;
    }
  }

  // ── Entity whole-row (__exists__) touches ────────────────────────────

  /// An `AFTER INSERT` touch (`fieldName = NULL`, `memberUuid = NULL`) on an
  /// entity table. Two things happen, independently:
  ///  1. Mint a `kind: '__exists__'` operation, recording the sentinel, when
  ///     no complete one is recorded yet for this entity. "Complete" rather
  ///     than merely "present" as of M2.14: the payload now carries this
  ///     table's owner references and identity columns, and a register
  ///     holding the pre-M2.14 constant `true` supplies none of them — see
  ///     [_repairExistsRegisters]. So this covers both the "entity did
  ///     not exist before, from this device's point of view" case (a
  ///     genuinely fresh insert, or the FIRST time this entity's insert is
  ///     drained) and the stale-register upgrade. If a COMPLETE sentinel is
  ///     already recorded (e.g. `tag_workflow_bindings`' `INSERT OR
  ///     REPLACE`-driven "re-insert" — see
  ///     `_syncEntityCaptureStatementGroups`'s own doc comment in
  ///     database_service.dart, and note that the eight tables carrying no
  ///     payload at all are complete the moment they are present), nothing
  ///     is minted here.
  ///  2. Regardless, EVERY sync-scope column for this table is re-checked
  ///     against `sync_field_state` exactly like an ordinary field touch
  ///     would be — necessary because an `AFTER INSERT` touch carries no
  ///     per-column information at all, and because the REPLACE-driven
  ///     "re-insert" case above needs exactly this full-row re-check to
  ///     capture whatever actually changed (no `AFTER UPDATE` trigger ever
  ///     fires for that write path).
  Future<List<MintedOperation>> _processExistsTouch(
    DatabaseExecutor txn, {
    required String authorId,
    required String entityTable,
    required String entityId,
  }) async {
    final scope = _entityScopesByTable[entityTable];
    if (scope == null) {
      // Not a table this drainer knows about (defensive — every entity
      // touch this milestone's triggers ever produce comes from a table in
      // this map by construction; this only guards against a future schema
      // drift making that no longer true).
      return const [];
    }
    final row = await _currentRow(txn, scope, entityId);
    if (row == null) {
      // The entity no longer physically exists (e.g. `clearAllData`'s
      // deliberate real-delete bypass, see its own doc comment in
      // database_service.dart -- entity tables never get a real DELETE
      // through any other path, since the hard-delete guard blocks it).
      // Nothing live to capture; the touch is still marked processed by
      // the caller.
      return const [];
    }

    final minted = <MintedOperation>[];

    // M2.14: the payload is no longer the constant `true` for every table —
    // it carries this row's owner references and identity columns where it
    // has any (`encodeExistsPayloadJson`). `syncability` is already computed
    // once per table by `drain()`; re-read from the same cache here.
    final syncability = await entitySyncability(
      txn,
      scope,
      cache: _syncabilityCache,
    );
    final existsValueJson = encodeExistsPayloadJson(
      syncability.existsCarriedColumns,
      row,
    );

    final recordedExistsValueJson = await _readFieldStateValueJson(
      txn,
      entityTable: entityTable,
      entityId: entityId,
      fieldName: _existsFieldSentinel,
    );
    // **Two conditions, not one, and the second is the upgrade path for
    // operations this device published before M2.14.** Every one of these
    // tables minted and published `__exists__` normally until M2.10 gated
    // them, so a device that has been syncing for a while holds
    // `sync_field_state` registers whose payload is the constant `true` —
    // and nothing would ever replace them, because the ordinary condition is
    // "no register recorded". A peer would then keep skipping exactly the
    // subnotes/attachments/links/apps that already existed when the user
    // asked why they were not syncing. Re-minting when the recorded payload
    // is missing a carried column closes that, through the ordinary drain
    // namespace: no `contentKey`, a real current frontier that dominates the
    // register it replaces, and therefore an uncontested win on every peer.
    // See [_repairExistsRegisters] for what generates the touch, and note
    // that it also manufactures one for a row that has NO register at all —
    // an entity created while an M2.10..M2.13 build gated this table.
    final recordedIsComplete =
        recordedExistsValueJson != null &&
        existsPayloadIsComplete(
          syncability.existsCarriedColumns,
          decodeExistsPayload(recordedExistsValueJson),
        );
    if (!recordedIsComplete) {
      final op = await _mintFieldOperation(
        txn,
        authorId: authorId,
        kind: '__exists__',
        entityTable: entityTable,
        entityId: entityId,
        fieldName: _existsFieldSentinel,
        valueJson: existsValueJson,
      );
      minted.add(op);
    }

    for (final column in scope.syncScopeColumns) {
      final op = await _diffAndMaybeMintField(
        txn,
        authorId: authorId,
        entityTable: entityTable,
        entityId: entityId,
        fieldName: column,
        currentValueJson: jsonEncode(row[column]),
      );
      if (op != null) minted.add(op);
    }

    return minted;
  }

  // ── Entity single-column touches ─────────────────────────────────────

  Future<MintedOperation?> _processFieldTouch(
    DatabaseExecutor txn, {
    required String authorId,
    required String entityTable,
    required String entityId,
    required String fieldName,
  }) async {
    final scope = _entityScopesByTable[entityTable];
    if (scope == null) return null;
    final row = await _currentRow(txn, scope, entityId);
    if (row == null) {
      // Entity vanished (see _processExistsTouch's doc comment) — nothing
      // live to compare against.
      return null;
    }
    if (!row.containsKey(fieldName)) {
      // Defensive: a touch row naming a column that isn't in the live
      // schema/row (should not happen given the trigger-completeness
      // scanner in mutation_capture_test.dart, but drain must not crash on
      // a stale/foreign touch row).
      return null;
    }

    return _diffAndMaybeMintField(
      txn,
      authorId: authorId,
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      currentValueJson: jsonEncode(row[fieldName]),
    );
  }

  /// The `blobHash` recorded on a field's winning register, or null.
  Future<String?> _readFieldStateBlobHash(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
  }) async {
    final rows = await txn.query(
      'sync_field_state',
      columns: const ['blobHash'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['blobHash'] as String?;
  }

  /// Shared by both entity-touch paths: mint a `kind: 'field'` operation
  /// and update `sync_field_state` IFF `currentValueJson` differs from (or
  /// no row exists for) `sync_field_state`'s currently-recorded value.
  Future<MintedOperation?> _diffAndMaybeMintField(
    DatabaseExecutor txn, {
    required String authorId,
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String currentValueJson,
  }) async {
    final recorded = await _readFieldStateValueJson(
      txn,
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
    );
    if (recorded == currentValueJson) {
      // No-op: either already recorded with this exact value (a duplicate
      // touch, or a second drain pass), or -- the "changed and changed back
      // before drain" case -- the live value now matches what was already
      // recorded from before this batch of touches.
      return null;
    }

    // **A content-blob column compares by HASH, not by value, and skipping
    // this would push an empty mini app over a real one** (M3.1, found by a
    // test rather than by reading).
    //
    // The chain: a peer's `appCode` operation carries a `blobHash` and a
    // null value, so `_writeResolvedFieldValue` leaves the shell row's
    // placeholder `''` in place until Phase C downloads the bytes. That
    // INSERT fires this device's own capture triggers, and the ordinary
    // value comparison above sees live `''` against a recorded null, calls
    // them different, and mints `appCode = ''` — which then wins on recency
    // and replaces the real source on every other device with nothing.
    //
    // The register's `blobHash` is what the live content must be compared
    // against, and an empty column while a hash is recorded means the bytes
    // simply have not arrived yet — never a local edit to publish.
    if (isContentBlobColumn(entityTable, fieldName)) {
      final recordedHash = await _readFieldStateBlobHash(
        txn,
        entityTable: entityTable,
        entityId: entityId,
        fieldName: fieldName,
      );
      if (recordedHash != null) {
        final live = BlobSyncPhase.decodeValue(currentValueJson);
        if (live is! String || live.isEmpty) return null;
        if (BlobSyncPhase.hashString(live) == recordedHash) return null;
      }
    }

    return _mintFieldOperation(
      txn,
      authorId: authorId,
      kind: 'field',
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      valueJson: currentValueJson,
    );
  }

  // ── OR-Set membership touches ────────────────────────────────────────

  /// An `AFTER INSERT`/`AFTER DELETE` touch on an OR-Set membership table.
  /// `sync_touch_log` does not record which of the two fired (§ 11.3's own
  /// design: capture is deliberately ignorant of what changed) -- drain
  /// recovers that by checking whether the membership row currently exists
  /// in the real membership table right now:
  ///  - **Currently exists** (live membership) and no live `sync_set_state`
  ///    row already records an add-dot for this exact member: mint
  ///    `set_add`, record the new add-dot.
  ///  - **Does not currently exist** and a live `sync_set_state` row DOES
  ///    record an existing add-dot (or dots) for this member: mint
  ///    `set_remove` targeting those dot(s) (this device's own previously
  ///    locally-recorded ones -- no `sync_dot_redirects` resolution needed
  ///    or attempted this milestone, see [MintedOperation.targetDots]'s doc
  ///    comment), then delete those `sync_set_state` rows.
  ///  - Either "currently exists + already recorded" or "does not exist +
  ///    nothing recorded" is a no-op: nothing minted.
  Future<MintedOperation?> _processSetTouch(
    DatabaseExecutor txn, {
    required String authorId,
    required String entityTable,
    required String entityId,
    required String? fieldName,
    required String memberUuid,
  }) async {
    if (fieldName == null) return null; // defensive; never true by construction
    // The other of the two M2.7 NUL-byte fix sites — see
    // _setScopesByTableAndField's own doc comment above.
    final scope = _setScopesByTableAndField['$entityTable $fieldName'];
    if (scope == null) return null;

    final liveRows = await txn.query(
      scope.membershipTable,
      where: '${scope.entityIdColumn} = ? AND ${scope.memberIdColumn} = ?',
      whereArgs: [entityId, memberUuid],
      limit: 1,
    );
    final currentlyMember = liveRows.isNotEmpty;

    final recordedDots = await txn.query(
      'sync_set_state',
      columns: ['authorId', 'authorSeq'],
      where:
          'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
      whereArgs: [entityTable, entityId, fieldName, memberUuid],
    );

    if (currentlyMember) {
      if (recordedDots.isNotEmpty) return null; // already recorded — no-op
      return _mintSetAdd(
        txn,
        authorId: authorId,
        entityTable: entityTable,
        entityId: entityId,
        fieldName: fieldName,
        memberUuid: memberUuid,
        // M2.10: carry the add-event's own payload (the mapping tables'
        // `createdAt`). Not a cosmetic addition — `materializer.dart` has no
        // other source for those `NOT NULL` columns, and without it an
        // ordinary, post-trigger mapping add still cannot produce a real
        // membership row on the receiving device. Empty (the bare sentinel)
        // for `note_tags`/`conversation_tags`, whose two id columns are the
        // whole row.
        valueJson: encodeSetAddPayloadJson(scope, liveRows.first),
      );
    }

    if (recordedDots.isEmpty) return null; // nothing to remove — no-op
    return _mintSetRemove(
      txn,
      authorId: authorId,
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      memberUuid: memberUuid,
      targetDots: [
        for (final r in recordedDots)
          (r['authorId'] as String, r['authorSeq'] as int),
      ],
    );
  }

  Future<MintedOperation> _mintSetAdd(
    DatabaseExecutor txn, {
    required String authorId,
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String memberUuid,
    required String valueJson,
  }) async {
    final authorSeq = await _seqCounter.mintNextSeq(authorId, executor: txn);
    final hlc = await _hlc.generate(executor: txn);
    final now = DateTime.now().millisecondsSinceEpoch;
    final frontierJson = await _currentFrontierJson(txn, authorId, authorSeq);

    await txn.insert('sync_pending_ops', {
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': null,
      'kind': 'set_add',
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'memberUuid': memberUuid,
      'valueJson': valueJson,
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': frontierJson,
      'createdAt': now,
      'publishedAt': null,
    });

    await txn.insert('sync_set_state', {
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'memberUuid': memberUuid,
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': null,
      'frontierJson': frontierJson,
      'updatedAt': now,
    });

    return MintedOperation(
      authorId: authorId,
      authorSeq: authorSeq,
      hlc: hlc,
      kind: 'set_add',
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      memberUuid: memberUuid,
      valueJson: valueJson,
    );
  }

  Future<MintedOperation> _mintSetRemove(
    DatabaseExecutor txn, {
    required String authorId,
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String memberUuid,
    required List<(String authorId, int authorSeq)> targetDots,
  }) async {
    final authorSeq = await _seqCounter.mintNextSeq(authorId, executor: txn);
    final hlc = await _hlc.generate(executor: txn);
    final now = DateTime.now().millisecondsSinceEpoch;
    final frontierJson = await _currentFrontierJson(txn, authorId, authorSeq);
    final targetDotsJson = jsonEncode([
      for (final dot in targetDots) {'authorId': dot.$1, 'authorSeq': dot.$2},
    ]);

    await txn.insert('sync_pending_ops', {
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': null,
      'kind': 'set_remove',
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'memberUuid': memberUuid,
      'valueJson': null,
      'blobHash': null,
      'targetDotsJson': targetDotsJson,
      'frontierJson': frontierJson,
      'createdAt': now,
      'publishedAt': null,
    });

    for (final dot in targetDots) {
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
          dot.$1,
          dot.$2,
        ],
      );
    }

    return MintedOperation(
      authorId: authorId,
      authorSeq: authorSeq,
      hlc: hlc,
      kind: 'set_remove',
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      memberUuid: memberUuid,
      targetDots: targetDots,
    );
  }

  // ── Shared field-mint/state helpers ──────────────────────────────────

  Future<MintedOperation> _mintFieldOperation(
    DatabaseExecutor txn, {
    required String authorId,
    required String kind,
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String valueJson,
  }) async {
    final authorSeq = await _seqCounter.mintNextSeq(authorId, executor: txn);
    final hlc = await _hlc.generate(executor: txn);
    final now = DateTime.now().millisecondsSinceEpoch;
    final frontierJson = await _currentFrontierJson(txn, authorId, authorSeq);

    await txn.insert('sync_pending_ops', {
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': null,
      'kind': kind,
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'memberUuid': null,
      'valueJson': valueJson,
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': frontierJson,
      'createdAt': now,
      'publishedAt': null,
    });

    await txn.insert('sync_field_state', {
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'valueJson': valueJson,
      'blobHash': null,
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': null,
      'frontierJson': frontierJson,
      'updatedAt': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return MintedOperation(
      authorId: authorId,
      authorSeq: authorSeq,
      hlc: hlc,
      kind: kind,
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      valueJson: valueJson,
    );
  }

  Future<String?> _readFieldStateValueJson(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
  }) async {
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

  /// The entity's current live row, keyed by real column name -> raw
  /// SQLite value (int/double/String/null — never a BLOB for any
  /// sync-scope column; see `syncEntityCaptureScopes`'s own per-table doc
  /// comments in database_service.dart for why every excluded BLOB/large
  /// column stays excluded). `null` if the row no longer physically exists
  /// (see `_processExistsTouch`'s doc comment for the one way that can
  /// happen in this codebase).
  Future<Map<String, Object?>?> _currentRow(
    DatabaseExecutor txn,
    SyncEntityCaptureScope scope,
    String entityId,
  ) async {
    // **Not `SELECT *`** (M3.8). The doc comment above has always claimed
    // "every excluded BLOB/large column stays excluded"; `SELECT *` had
    // been quietly making that false, and on a device with a large mini app
    // Android refused the read outright with `Row too big to fit into
    // CursorWindow`. `readSyncRow` asks only for what this scope syncs and
    // chunks anything oversized.
    final syncability = await entitySyncability(
      txn,
      scope,
      cache: _syncabilityCache,
    );
    final info = await syncTableInfo(txn, scope.table);
    return readSyncRow(
      txn,
      table: scope.table,
      idColumn: scope.idColumn,
      entityId: entityId,
      columns: [
        for (final column in info)
          if (column['name'] == scope.idColumn ||
              scope.syncScopeColumns.contains(column['name']) ||
              syncability.existsCarriedColumns.contains(column['name']))
            column['name'] as String,
      ],
    );
  }
}
