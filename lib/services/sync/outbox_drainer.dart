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

    final touches = await db.query(
      'sync_touch_log',
      where: 'processedAt IS NULL',
      orderBy: 'id ASC',
    );

    final minted = <MintedOperation>[];
    final skipped = <String, bool>{};
    // Schema shape is immutable for this pass — see `entitySyncability`.
    final syncabilityCache = <String, EntitySyncability>{};
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

  // ── Entity whole-row (__exists__) touches ────────────────────────────

  /// An `AFTER INSERT` touch (`fieldName = NULL`, `memberUuid = NULL`) on an
  /// entity table. Two things happen, independently:
  ///  1. If no `__exists__` sentinel is recorded yet for this entity, mint
  ///     a `kind: '__exists__'` operation and record the sentinel — this is
  ///     the "entity did not exist before, from this device's point of
  ///     view" case (a genuinely fresh insert, or the FIRST time this
  ///     entity's insert is drained). If the sentinel is already recorded
  ///     (e.g. `tag_workflow_bindings`' `INSERT OR REPLACE`-driven
  ///     "re-insert" — see `_syncEntityCaptureStatementGroups`'s own doc
  ///     comment in database_service.dart), nothing is minted here.
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

    final existsRecorded = await _fieldStateExists(
      txn,
      entityTable: entityTable,
      entityId: entityId,
      fieldName: _existsFieldSentinel,
    );
    if (!existsRecorded) {
      final op = await _mintFieldOperation(
        txn,
        authorId: authorId,
        kind: '__exists__',
        entityTable: entityTable,
        entityId: entityId,
        fieldName: _existsFieldSentinel,
        valueJson: jsonEncode(true),
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

  Future<bool> _fieldStateExists(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
  }) async {
    final rows = await txn.query(
      'sync_field_state',
      columns: const ['fieldName'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    return rows.isNotEmpty;
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
    final rows = await txn.query(
      scope.table,
      where: 'CAST(${scope.idColumn} AS TEXT) = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }
}
