// Initial seed scan — M2.10, § Architecture 1 ("Initial seed scan ordering",
// the round-8 canonical operation encoding, the round-14 GENESIS
// `contentKey` formula, and the round-18 corrected minting precondition) of
// the CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// ---------------------------------------------------------------------
// **The gap this closes.**
// ---------------------------------------------------------------------
// M2.4's mutation-capture triggers (`database_service.dart`'s
// `_syncMutationCaptureTriggerStatements`, installed by `_onCreate` and
// `_migrateToVersion57`) fire on INSERT/UPDATE/DELETE and nothing else.
// `_migrateToVersion57` installs them but deliberately does not backfill, so
// every row that already existed when the migration ran has **zero**
// `sync_touch_log` rows. `OutboxDrainer` reads exactly that table, so it
// mints nothing for those rows: sync works perfectly for data created AFTER
// the triggers and not at all for data created before. A user who connects
// Drive and taps "Sync now" on an existing library gets "drained 0, pulled
// 0, pushed 0" — their whole notebook is invisible to the sync engine.
//
// This file is the missing "initial seed scan": a one-per-device walk over
// every row already present in every sync-scope table, minting the
// operations the triggers never got a chance to.
//
// ---------------------------------------------------------------------
// **Author identity: a real `seed:<deviceUuid>` namespace, not a synthetic
// per-event author (round 8).**
// ---------------------------------------------------------------------
// Every operation minted here uses `authorId = "seed:" + deviceId` with a
// real, monotonic, contiguous `authorSeq` from the SAME [SeqCounter]
// primitive an ordinary device operation uses — `mintNextSeq` has always
// been namespace-agnostic for exactly this reason (see its own doc comment,
// which names `"seed:" + device_id` explicitly). This matters structurally,
// not cosmetically: a frontier's `{authorId: maxSeq}` entry means "I have
// observed this author through sequence N, and therefore everything below N
// too", a property that only holds for a genuine counter. Round 7's
// content-hash-derived `authorSeq` broke that outright; round 8 replaced it
// with this. Frontier growth stays bounded by device count (× 3 namespaces),
// never by event count.
//
// `pull_phase.dart` already knows about this namespace
// (`_ownNamespaceIds` excludes `seed:<own>` from being pulled back), and
// `dot.dart` already has `isSeedAuthor`, which `causal_comparator.dart`'s
// genesis-aware alias expansion (`causally_includes'''`) keys off. Nothing
// downstream needed changing to accept these operations.
//
// ---------------------------------------------------------------------
// **HLC: a real one, from this device's own clock — never a placeholder.**
// ---------------------------------------------------------------------
// § 11.2's "load-bearing distinction, stated precisely": § Architecture 1
// calls seed HLCs "decorative", but ONLY for the `contentKey` dedup
// mechanism, whose canonical-winner rule is the purely lexicographic
// `(authorId, authorSeq)` comparison and never consults an HLC at all. The
// moment a seed operation is submitted to ordinary field-conflict
// resolution as a live candidate — which the round-14 "stale seed wins"
// scenario shows happens in real cases — its HLC is exactly as load-bearing
// for the `(hlc, authorId, authorSeq)` tie-break as any ordinary edit's. So
// every operation minted here is stamped with a real [HybridLogicalClock]
// value, from the same per-device clock every other mint in this codebase
// uses.
//
// **Conversation-mapping ordering (round 14's deliberate exception).** For
// `conversation_message_mapping` the local autoincrement `id` order IS the
// real historical message order (`database_service.dart`'s batch insert
// computes one `createdAt` millisecond outside the insert loop, so several
// mappings genuinely share a millisecond and only insertion order
// distinguishes them — the app's own existing justification for
// `orderBy: 'id ASC'`). Round 8 removed local ids from *ongoing,
// cross-replica-compared* keys, correctly; round 14 restored them for the
// one-time seed-time HLC specifically, because using each device's own real
// local order preserves that device's actual history faithfully and costs
// nothing (convergence is `contentKey`'s job, not the HLC's). This scanner
// gets that property structurally rather than by computing HLCs by hand:
// membership rows are enumerated in `rowid ASC` order (== insertion order
// for these tables) and HLCs are strictly increasing per `generate()` call,
// so seed HLCs come out in real historical order. The same ordering is
// applied uniformly to every membership table since it costs nothing.
//
// ---------------------------------------------------------------------
// **`contentKey` with `baseContext = "GENESIS"` (round 14).**
// ---------------------------------------------------------------------
// Two devices that independently seed the SAME pre-existing content must
// converge to one canonical operation instead of permanently duplicating
// it. Seed dots are real-device-scoped, so the two operations have
// genuinely different dots; convergence is handled by the orthogonal
// `contentKey` mechanism (`causal/content_key_dedup.dart`, M2.5): identical
// content produces an identical `contentKey`, the lexicographically
// smallest dot in that class wins, and the loser gets a permanent
// `sync_dot_redirects` entry rather than being silently dropped (round 9).
//
// [genesisContentKey] implements § Architecture 1's formula
// `hash(entityUuid + ":" + fieldName [+ ":" + memberUuid] + ":" +
// baseContext + ":" + valueHash)` with `baseContext = "GENESIS"`, the fixed
// sentinel shared by every device seeding the same never-before-synced
// field (there is by definition no prior state to distinguish). The exact
// string hashed is:
//
//     sha256( entityTable ":" entityId ":" fieldName
//             [ ":" memberUuid ] ":" "GENESIS" ":" sha256(valueJson) )
//
// Two deliberate deviations from the doc's literal formula, disclosed
// separately because their standing differs:
//   * The key is **table-qualified** (`entityTable` prefixed). The doc's
//     formula assumes a globally unique `entityUuid`; this codebase has
//     entity ids that are not (`tag_workflow_bindings.pattern` is a
//     free-form pattern), so an unqualified key could collide two genuinely
//     different rows in different tables. **This one has direct precedent**:
//     `test/sync_protocol/conversation_ops.dart`'s validated
//     `genesisContentKey` is table-qualified too, and its own doc comment
//     says so.
//   * `valueHash` is `sha256(valueJson)` rather than the value inlined.
//     **This has NO simulator precedent** — the simulator inlines its
//     values, which are small by construction. It is justified on its own
//     terms rather than by precedent: `notes.content` can be megabytes, and
//     since a `contentKey` is only ever compared for equality against
//     another key computed by this same function, hashing preserves every
//     property the protocol asks of it while keeping the key bounded. The
//     doc's own formula names a `valueHash` component, so this is arguably
//     the literal reading rather than a deviation at all.
//
// ---------------------------------------------------------------------
// **The minting precondition (round 18's corrected gate) — and why it is
// also, by itself, the idempotency mechanism.**
// ---------------------------------------------------------------------
// The Key Lemma requires: *if `d` is a genesis seed of field `(e,g)` minted
// by device `p`, then `d.frontier` dominates no operation on `(e,g)` — by
// any device, including `p` itself.* Round 18 broadened the gate from "no
// existing `sync_field_state` record" to also cover
// `sync_materialize_queue`, because round 14's observation-vs-materialization
// split means a replica's frontier updates on OBSERVATION
// (`pull_phase.dart` bumps `sync_state['frontier:<log>']` unconditionally,
// even for a commit that then blocks) while a materialized-state table need
// not have caught up.
//
// **How that lands in THIS implementation, stated precisely rather than
// restated from the design.** `pull_phase.dart` calls `CausalEngine.apply`
// and `SyncMaterializer.materialize` in that order, inside ONE transaction
// per commit — and `apply` is what writes `sync_field_state` (via
// `recompute` -> `_writeWinner`), while only `materialize` enqueues
// `missing_exists`. So for a `field`/`__exists__` operation the two are
// simultaneous: a blocked field operation has BOTH a `sync_field_state` row
// AND a queue entry, never a queue entry alone. The queue half of this gate
// is therefore currently redundant for field-scoped operations. It is kept,
// for three reasons that are not stylistic: the design mandates it; it is
// the only correct gate the moment apply-and-materialize stop sharing a
// transaction (a plausible future change, since materialization is the
// expensive half); and for MEMBERSHIPS it is genuinely load-bearing today —
// `applySetRemove` deletes `sync_set_state` rows rather than writing one,
// so a `missing_referenced_dot` entry really can be the only local evidence
// that a membership has history.
//
// So [_isPristine] checks BOTH tables: a field/entity/membership is seeded
// only if it has no `sync_field_state`/`sync_set_state` row AND no
// `sync_materialize_queue` entry referencing it.
//
// **For `field` and `__exists__` operations that gate is complete**, and
// the completeness argument is specifically theirs: an arriving
// field-scoped operation either materializes (populating
// `sync_field_state`, win or lose — `field_conflict_resolver.dart`'s
// `recompute` always writes a winner) or fails a named blocking reason and
// enters the queue. There is no third resting state for that kind.
// (`sync_dedup_index`/`sync_dot_redirects` need no separate check: they
// only ever gain an entry for the second-or-later observed member of a
// `contentKey` class, and that class's first-observed member necessarily
// already passed through the ordinary pipeline into one of the two checked
// tables.)
//
// **For `set_add` the same claim would be false, and is not made.** A
// membership genuinely can be observed with neither a `sync_set_state` row
// nor a queue entry: `OrSetResolver.applySetAdd` returns `dedupSkipped` for
// a `contentKey`-deduped add without writing either, and an applied
// `set_remove` deletes the `sync_set_state` row outright. So for
// memberships this gate is a best-effort filter, not a completeness proof —
// which is exactly the status § Architecture 1 assigns it: membership
// seeding needs the gate only for BOUNDEDNESS, never for soundness, since
// OR-Set membership uses no domination-based winner-picking at all (the
// canonical-winner rule plus `sync_dot_redirects` decides it). The worst
// case a missed gate produces there is a duplicate add-dot that resolves
// itself.
//
// This applies to `field` and `__exists__` seeding for a **soundness**
// reason, not merely to avoid duplicates: `__exists__` conflicts follow the
// ordinary path and compete under the same domination-based
// `causally_includes'''` comparator the Key Lemma protects for fields, so
// an under-gated `__exists__` seed risks the identical cyclic-domination
// failure mode. `set_add` seeding is the one genuine exception — OR-Set
// membership never uses domination-based winner-picking at all, so an
// under-gated membership seed could at worst produce a harmless,
// self-resolving duplicate add-dot. The gate is applied uniformly anyway,
// since checking the same two tables for memberships costs nothing.
//
// **Idempotency and resumability, and the mid-flight window.** The
// precondition is not merely *checked* before minting; the very same
// transaction that mints an operation also makes that precondition false,
// because the mint is routed through `CausalEngine.apply` (see below),
// which writes `sync_field_state`/`sync_set_state` for it. Mint and gate
// therefore commit or roll back together. Concretely, the window the brief
// asks about — between an operation being minted and it being
// materialized/pushed — does not exist for this scanner:
//   * A crash/kill anywhere in a scan leaves a prefix of entities fully
//     seeded and the rest untouched (each entity is one transaction). A
//     re-run finds every already-seeded field gated by its own
//     `sync_field_state` row and mints nothing for it.
//   * An operation sitting unpushed in `sync_pending_ops` (Drive
//     unreachable, app killed before Phase A) is still gated, because the
//     gate is `sync_field_state`, not `publishedAt`.
//   * A field seeded here and then edited by the user before the seed was
//     ever pushed is still gated: drain overwrites the `sync_field_state`
//     row with its own ordinary-namespace dot, but the ROW still exists.
//   * The `sync_state` completion marker ([seedScanCompletedAtKey]) is a
//     pure fast path — it lets an already-seeded device skip the walk
//     instead of re-deriving "nothing to do" row by row. Correctness never
//     depends on it: deleting that key and re-running mints nothing new.
//     This is deliberate, per the brief's "do not rely on progress-tracking
//     alone when the precondition can do it correctly."
//
// **Interaction with `clearAllData`, checked rather than assumed.** That
// function wipes `sync_field_state`/`sync_set_state`/`sync_pending_ops` and
// friends but deliberately keeps `sync_state` (device identity, HLC, seq
// counters — see its own doc comment for why). So the completion marker
// survives a clear while the gate tables do not. That is the correct
// outcome and needs no special handling: every app row is gone too, so
// there is nothing left to seed, and anything the user subsequently imports
// arrives through ordinary INSERTs that fire M2.4's triggers and are drained
// normally. (The triggers are real, persistent SQLite triggers, so they fire
// regardless of which code path performs the insert.)
//
// **One disclosed, narrow, non-default-path exception**, for the
// boundedness-only membership case the design already singles out: a
// membership that was seeded and has since been legitimately removed leaves
// neither a real membership row nor a `sync_set_state` row, so a re-scan
// correctly does not resurrect it — UNLESS the marker is manually cleared
// while a pulled `set_remove` is still un-materialized, in which case the
// still-present local row would be seeded a second time. That produces a
// duplicate add-dot, which OR-Set semantics resolve harmlessly (membership
// never uses domination-based winner-picking), never a soundness violation
// — exactly the boundedness-only characterization § Architecture 1 gives
// for `set_add` seeding.
//
// ---------------------------------------------------------------------
// **Why mints are routed through `CausalEngine.apply`.**
// ---------------------------------------------------------------------
// `materializer.dart`'s `_mintAndApplyTagField` (M2.7's auto-merge write
// pair) already established this pattern for the same reason: a locally
// minted `contentKey`-bearing operation must register itself in
// `sync_dedup_index` as the first-seen member of its class, or the device
// will fail to recognize ANOTHER device's identical-`contentKey` operation
// as a duplicate when it later pulls it — each would materialize as an
// independent, permanently-competing candidate, which is exactly the
// duplication the GENESIS sentinel exists to prevent. Routing through the
// engine also gets `sync_field_state`/`sync_set_state` written by the same
// resolvers that write them for remote operations, rather than a second,
// independently-maintained copy of that logic. `test/sync_protocol/
// replica.dart`'s own `_mint` does the same thing (`apply(op); outbox.add
// (op);`).
//
// Nothing here writes to a real app table: the app row IS the source the
// seed was derived from. That also means no capture trigger fires, so a
// seed scan never pollutes `sync_touch_log`.
//
// ---------------------------------------------------------------------
// **What is deliberately NOT here.** No `external:` namespace (that is
// requirement 8, plain-file external edits, much later). No Drive folder
// naming/identity changes (M2.11). No encryption, no conflict-resolution
// UI.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'causal/causal_engine.dart';
import 'causal/dot.dart';
import 'device_identity.dart';
import 'frontier.dart';
import 'hlc.dart';
import 'seq_counter.dart';
import 'sync_table_shape.dart';

/// § Architecture 1's reserved `baseContext` sentinel for seed operations:
/// "a fixed sentinel shared by every device seeding the same pre-existing,
/// never-before-synced field, since there is by definition no prior state
/// to distinguish."
const String genesisBaseContext = 'GENESIS';

String _sha256Hex(String input) =>
    sha256.convert(utf8.encode(input)).toString();

/// § Architecture 1's `contentKey` formula, `baseContext = "GENESIS"`:
/// `hash(entityUuid + ":" + fieldName [+ ":" + memberUuid] + ":" +
/// baseContext + ":" + valueHash)`. See this file's top doc comment for the
/// two disclosed, equality-only-safe deviations (table qualification, and
/// hashing the value rather than inlining it).
///
/// [valueJson] must be the already-JSON-encoded value, exactly as it is
/// stored in `sync_pending_ops.valueJson`/`sync_field_state.valueJson` —
/// two replicas holding the same logical value must produce the same string
/// here, which the shared `jsonEncode` of the same raw SQLite value gives.
String genesisContentKey({
  required String entityTable,
  required String entityId,
  required String fieldName,
  String? memberUuid,
  required String valueJson,
}) {
  final parts = <String>[
    entityTable,
    entityId,
    fieldName,
    if (memberUuid != null) memberUuid,
    genesisBaseContext,
    _sha256Hex(valueJson),
  ];
  return _sha256Hex(parts.join(':'));
}

/// Summary of one [SeedScanner.scan] call.
class SeedScanResult {
  const SeedScanResult({
    required this.operationsSeeded,
    required this.entitiesScanned,
    required this.membershipsScanned,
    required this.nonPortableTablesSkipped,
    required this.fieldsDeferred,
    required this.completed,
    required this.skippedAlreadyComplete,
  });

  /// How many operations this call minted into `sync_pending_ops` — the
  /// number the UI needs so a first sync of a pre-existing library does not
  /// read as "0/0/0" while it is in fact doing all the work.
  final int operationsSeeded;

  /// Rows visited in the entity tables (`syncEntityCaptureScopes`),
  /// regardless of whether anything was minted for them.
  final int entitiesScanned;

  /// Rows visited in the OR-Set membership tables
  /// (`syncSetCaptureScopes`).
  final int membershipsScanned;

  /// Tables skipped wholesale because their primary key is a non-portable
  /// `INTEGER PRIMARY KEY AUTOINCREMENT` — see `hasPortableEntityId`
  /// (`sync_table_shape.dart`), the single shared predicate every minting
  /// and materializing site now uses. Reported so a test can assert the
  /// guard actually fires rather than inferring it from an absence.
  final List<String> nonPortableTablesSkipped;

  /// Fields/memberships skipped because a `sync_materialize_queue` entry
  /// referenced them — a TRANSIENT blocker (a pulled operation waiting on a
  /// prerequisite), unlike a `sync_field_state` row, which is permanent and
  /// correct evidence that the field already has real history. A non-zero
  /// count suppresses the completion marker so the next sync re-checks.
  final int fieldsDeferred;

  /// Whether this call finished a full pass with nothing deferred and no
  /// budget exhaustion — i.e. whether [seedScanCompletedAtKey] was written.
  final bool completed;

  /// True when the scan was skipped outright because
  /// [seedScanCompletedAtKey] was already set (the steady state on any
  /// device that has synced once).
  final bool skippedAlreadyComplete;

  static const SeedScanResult noop = SeedScanResult(
    operationsSeeded: 0,
    entitiesScanned: 0,
    membershipsScanned: 0,
    nonPortableTablesSkipped: [],
    fieldsDeferred: 0,
    completed: true,
    skippedAlreadyComplete: true,
  );
}

/// Progress callback payload — emitted once per entity table / membership
/// table finished, so a caller can drive a determinate-ish progress UI
/// without this class knowing anything about Flutter.
class SeedScanProgress {
  const SeedScanProgress({
    required this.table,
    required this.tablesDone,
    required this.tablesTotal,
    required this.operationsSeededSoFar,
  });

  final String table;
  final int tablesDone;
  final int tablesTotal;
  final int operationsSeededSoFar;
}

/// `sync_state` key marking that a full seed pass has completed on this
/// device. Purely a fast path — see this file's top doc comment on why
/// correctness never depends on it.
const String seedScanCompletedAtKey = 'seed_scan_completed_at';

/// Walks every table in [DatabaseService.syncEntityCaptureScopes] /
/// [DatabaseService.syncSetCaptureScopes] and mints the operations M2.4's
/// triggers could never have produced for rows that predate them.
///
/// Safe to call on every sync: the first call does the work, every
/// subsequent one short-circuits on [seedScanCompletedAtKey], and even with
/// that key deleted a re-run mints nothing new (see the top doc comment's
/// idempotency argument).
class SeedScanner {
  SeedScanner(
    this._databaseService,
    this._deviceIdentity,
    this._seqCounter,
    this._hlc, {
    CausalEngine? engine,
  }) : _engine = engine ?? CausalEngine();

  final DatabaseService _databaseService;
  final DeviceIdentity _deviceIdentity;
  final SeqCounter _seqCounter;
  final HybridLogicalClock _hlc;
  final CausalEngine _engine;

  static const String _existsFieldSentinel = existsFieldSentinel;

  /// Column aliases for the membership walk's projected owner/member ids —
  /// named so they can never collide with a real payload column.
  static const String _seedEntityIdAlias = 'seedEntityId';
  static const String _seedMemberIdAlias = 'seedMemberId';

  /// How many membership rows share one transaction. Entity rows get one
  /// transaction each (an entity's `__exists__` plus all its fields belong
  /// together); membership rows are individually tiny, so batching them
  /// keeps transaction overhead sane on a large `note_tags` without
  /// weakening resumability — an interrupted batch simply rolls back whole
  /// and is redone identically on the next run.
  static const int _membershipBatchSize = 100;

  /// The `seed:` namespace this device mints under.
  Future<String> seedAuthorId() async =>
      'seed:${await _deviceIdentity.ensureDeviceId()}';

  /// Runs (or resumes) the seed scan.
  ///
  /// [maxOperations] optionally caps how many operations one call will mint
  /// before stopping early — the scan is fully resumable, so a capped call
  /// simply leaves the rest for the next sync. Defaults to `null` (no cap):
  /// a partial seed is worse UX than a slow first sync, and the real
  /// bottleneck for a large library is Phase A's one-network-round-trip-per-
  /// operation push, not this walk. The parameter exists so a caller that
  /// does want to bound a single round (a future background scheduler) can.
  Future<SeedScanResult> scan({
    int? maxOperations,
    void Function(SeedScanProgress)? onProgress,
  }) async {
    final db = await _databaseService.database;
    if (await _isAlreadyComplete(db)) return SeedScanResult.noop;

    final authorId = await seedAuthorId();

    var seeded = 0;
    var entities = 0;
    var memberships = 0;
    var deferred = 0;
    var budgetExhausted = false;
    final nonPortable = <String>[];
    final syncabilityCache = <String, EntitySyncability>{};

    final entityScopes = DatabaseService.syncEntityCaptureScopes;
    final setScopes = DatabaseService.syncSetCaptureScopes;
    final tablesTotal = entityScopes.length + setScopes.length;
    var tablesDone = 0;

    /// Emitted for every table the walk finishes, INCLUDING one it skipped —
    /// a skipped table is still one fewer left to do, and swallowing its
    /// callback would make `tablesDone` jump, which is exactly what a
    /// progress UI must not do.
    void reportTableDone(String table) {
      tablesDone++;
      onProgress?.call(
        SeedScanProgress(
          table: table,
          tablesDone: tablesDone,
          tablesTotal: tablesTotal,
          operationsSeededSoFar: seeded,
        ),
      );
    }

    for (final scope in entityScopes) {
      if (budgetExhausted) break;
      // Same syncability gate the drain path and the materializer apply —
      // one predicate, `entitySyncability` (`sync_table_shape.dart`). Seeding
      // a table no receiving device can build would mint an operation per
      // field per row and produce a permanent `missing_exists` entry for
      // each, on every peer.
      final syncability = await entitySyncability(
        db,
        scope,
        cache: syncabilityCache,
      );
      if (!syncability.canSync) {
        nonPortable.add('${scope.table} (${syncability.reasonLabel})');
        reportTableDone(scope.table);
        continue;
      }
      final ids = await _entityIds(db, scope);
      for (final entityId in ids) {
        if (maxOperations != null && seeded >= maxOperations) {
          budgetExhausted = true;
          break;
        }
        final outcome = await db.transaction(
          (txn) => _seedEntity(
            txn,
            authorId: authorId,
            scope: scope,
            entityId: entityId,
          ),
        );
        entities++;
        seeded += outcome.$1;
        deferred += outcome.$2;
      }
      // Not reported when the budget cut this table off partway: the table
      // is not done, and claiming otherwise would make a resumed scan look
      // like it was re-walking finished work.
      if (!budgetExhausted) reportTableDone(scope.table);
    }

    for (final scope in setScopes) {
      if (budgetExhausted) break;
      // A membership's own `entityId`/`memberUuid` are the OWNING entity's
      // and member's ids, never the membership table's own surrogate key
      // (`conversation_note_mapping.id` is an autoincrement integer, but the
      // dot it seeds is keyed on `conversationId`/`noteId`, both portable
      // uuids). Guarded generically anyway, on the owning entity table, so a
      // future non-portable owner can never slip through the same way
      // `user_app_libraries` did.
      final ownerScope = DatabaseService.syncEntityCaptureScopes
          .where((s) => s.table == scope.entityTable)
          .firstOrNull;
      if (ownerScope != null &&
          !(await entitySyncability(
            db,
            ownerScope,
            cache: syncabilityCache,
          )).canSync) {
        nonPortable.add(scope.membershipTable);
        reportTableDone(scope.membershipTable);
        continue;
      }
      final rows = await _membershipRows(db, scope);
      for (var i = 0; i < rows.length; i += _membershipBatchSize) {
        if (maxOperations != null && seeded >= maxOperations) {
          budgetExhausted = true;
          break;
        }
        final batch = rows.sublist(
          i,
          (i + _membershipBatchSize).clamp(0, rows.length),
        );
        final outcome = await db.transaction(
          (txn) => _seedMembershipBatch(
            txn,
            authorId: authorId,
            scope: scope,
            batch: batch,
          ),
        );
        memberships += batch.length;
        seeded += outcome.$1;
        deferred += outcome.$2;
      }
      if (!budgetExhausted) reportTableDone(scope.membershipTable);
    }

    final completed = !budgetExhausted && deferred == 0;
    if (completed) await _markComplete(db);

    return SeedScanResult(
      operationsSeeded: seeded,
      entitiesScanned: entities,
      membershipsScanned: memberships,
      nonPortableTablesSkipped: List.unmodifiable(nonPortable),
      fieldsDeferred: deferred,
      completed: completed,
      skippedAlreadyComplete: false,
    );
  }

  // ── Entity rows: __exists__ + one operation per sync-scope column ─────

  /// Returns `(operationsMinted, fieldsDeferred)` for one entity row.
  ///
  /// `__exists__` is minted first, then one `field` operation per
  /// [SyncEntityCaptureScope.syncScopeColumns] entry **in list order** —
  /// the same order `OutboxDrainer._processExistsTouch` uses, which is
  /// load-bearing for `tags` specifically (`name`/`color` must materialize
  /// before `__deleted__`/`redirectTarget` so `materializer.dart`'s
  /// liveness-collision check always has the real name to check against;
  /// see that file's own ordering argument). Since `authorSeq` and the HLC
  /// both increase per mint, minting in list order is what preserves that
  /// property on the receiving device.
  Future<(int, int)> _seedEntity(
    DatabaseExecutor txn, {
    required String authorId,
    required SyncEntityCaptureScope scope,
    required String entityId,
  }) async {
    final rows = await txn.query(
      scope.table,
      where: 'CAST(${scope.idColumn} AS TEXT) = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    if (rows.isEmpty) return (0, 0); // deleted between enumeration and now
    final row = rows.first;

    var minted = 0;
    var deferred = 0;

    final existsState = await _isPristine(
      txn,
      entityTable: scope.table,
      entityId: entityId,
      fieldName: _existsFieldSentinel,
    );
    switch (existsState) {
      case _Pristine.yes:
        await _mintAndApplyField(
          txn,
          authorId: authorId,
          kind: '__exists__',
          entityTable: scope.table,
          entityId: entityId,
          fieldName: _existsFieldSentinel,
          valueJson: jsonEncode(true),
        );
        minted++;
      case _Pristine.hasHistory:
        break;
      case _Pristine.queued:
        deferred++;
    }

    for (final column in scope.syncScopeColumns) {
      if (!row.containsKey(column)) {
        // Defensive: a scope column that is not in the live schema. The
        // trigger-completeness scanner (`mutation_capture_test.dart`) makes
        // this unreachable today; a seed scan must not crash on schema
        // drift regardless.
        continue;
      }
      final state = await _isPristine(
        txn,
        entityTable: scope.table,
        entityId: entityId,
        fieldName: column,
      );
      switch (state) {
        case _Pristine.yes:
          await _mintAndApplyField(
            txn,
            authorId: authorId,
            kind: 'field',
            entityTable: scope.table,
            entityId: entityId,
            fieldName: column,
            valueJson: jsonEncode(row[column]),
          );
          minted++;
        case _Pristine.hasHistory:
          break;
        case _Pristine.queued:
          deferred++;
      }
    }

    return (minted, deferred);
  }

  // ── OR-Set membership rows: one set_add each ─────────────────────────

  Future<(int, int)> _seedMembershipBatch(
    DatabaseExecutor txn, {
    required String authorId,
    required SyncSetCaptureScope scope,
    required List<Map<String, Object?>> batch,
  }) async {
    var minted = 0;
    var deferred = 0;
    for (final row in batch) {
      final entityId = row[_seedEntityIdAlias] as String;
      final memberUuid = row[_seedMemberIdAlias] as String;
      final state = await _isPristine(
        txn,
        entityTable: scope.entityTable,
        entityId: entityId,
        fieldName: scope.fieldName,
        memberUuid: memberUuid,
      );
      switch (state) {
        case _Pristine.yes:
          await _mintAndApplySetAdd(
            txn,
            authorId: authorId,
            scope: scope,
            entityId: entityId,
            memberUuid: memberUuid,
            valueJson: encodeSetAddPayloadJson(scope, row),
          );
          minted++;
        case _Pristine.hasHistory:
          break;
        case _Pristine.queued:
          deferred++;
      }
    }
    return (minted, deferred);
  }

  // ── The minting precondition ─────────────────────────────────────────

  /// The round-18 corrected gate. [memberUuid] non-null selects the
  /// `sync_set_state` variant (an OR-Set membership); otherwise
  /// `sync_field_state` (a `field` or `__exists__` register).
  ///
  /// The `sync_materialize_queue` half is checked at
  /// `(entityTable, entityId, fieldName)` granularity — matching how
  /// `materializer.dart`'s `_enqueueMissingExists` and `pull_phase.dart`'s
  /// `missing_referenced_dot` enqueue both populate those three columns —
  /// plus any entry with a NULL `fieldName`, which cannot be ruled out as
  /// unrelated to this field. For memberships that is coarser than strictly
  /// necessary (a queued `set_remove` for a DIFFERENT member of the same
  /// set also defers), which is harmless: membership seeding needs the gate
  /// only for boundedness, and deferring is always the safe direction.
  Future<_Pristine> _isPristine(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    String? memberUuid,
  }) async {
    final stateRows = memberUuid == null
        ? await txn.query(
            'sync_field_state',
            columns: const ['fieldName'],
            where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
            whereArgs: [entityTable, entityId, fieldName],
            limit: 1,
          )
        : await txn.query(
            'sync_set_state',
            columns: const ['fieldName'],
            where:
                'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
            whereArgs: [entityTable, entityId, fieldName, memberUuid],
            limit: 1,
          );
    if (stateRows.isNotEmpty) return _Pristine.hasHistory;

    final queued = await txn.query(
      'sync_materialize_queue',
      columns: const ['id'],
      where:
          'entityTable = ? AND entityId = ? AND (fieldName = ? OR fieldName IS NULL)',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    if (queued.isNotEmpty) return _Pristine.queued;

    return _Pristine.yes;
  }

  // ── Mint + local apply ───────────────────────────────────────────────

  /// Mints one `field`/`__exists__` seed operation into `sync_pending_ops`
  /// and applies it locally through [CausalEngine] — the same
  /// mint-then-apply shape `materializer.dart`'s `_mintAndApplyTagField`
  /// uses, minus its real-table write (the real row is what this value was
  /// read FROM).
  Future<void> _mintAndApplyField(
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
    final frontierJson = await currentFrontierJson(txn, authorId, authorSeq);
    final contentKey = genesisContentKey(
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      valueJson: valueJson,
    );

    await txn.insert('sync_pending_ops', {
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': contentKey,
      'kind': kind,
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'memberUuid': null,
      'valueJson': valueJson,
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': frontierJson,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'publishedAt': null,
    });

    await _engine.apply(
      txn,
      IncomingOperation(
        dot: Dot(authorId, authorSeq),
        hlc: hlc,
        contentKey: contentKey,
        kind: kind,
        entityTable: entityTable,
        entityId: entityId,
        fieldName: fieldName,
        valueJson: valueJson,
        frontier: _decodeFrontier(frontierJson),
      ),
    );
  }

  /// [valueJson] is the add-event's payload per
  /// [SyncSetCaptureScope.payloadColumns] (the mapping tables' `createdAt`)
  /// or the bare-membership sentinel. It is folded into the `contentKey` AND
  /// carried on the operation itself: keying on a value the operation does
  /// not transmit would leave the fact that decided dedup unrecoverable to
  /// every other replica. `OutboxDrainer._mintSetAdd` writes `null` here for
  /// an ordinary post-trigger add, which is not a divergence — that path has
  /// no payload to carry, and every consumer (`wire_format.dart`,
  /// `OrSetResolver.applySetAdd`, `materializer.dart`'s membership INSERT)
  /// already treats a `set_add` value as optional.
  Future<void> _mintAndApplySetAdd(
    DatabaseExecutor txn, {
    required String authorId,
    required SyncSetCaptureScope scope,
    required String entityId,
    required String memberUuid,
    required String valueJson,
  }) async {
    final authorSeq = await _seqCounter.mintNextSeq(authorId, executor: txn);
    final hlc = await _hlc.generate(executor: txn);
    final frontierJson = await currentFrontierJson(txn, authorId, authorSeq);
    final contentKey = genesisContentKey(
      entityTable: scope.entityTable,
      entityId: entityId,
      fieldName: scope.fieldName,
      memberUuid: memberUuid,
      valueJson: valueJson,
    );

    await txn.insert('sync_pending_ops', {
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': contentKey,
      'kind': 'set_add',
      'entityTable': scope.entityTable,
      'entityId': entityId,
      'fieldName': scope.fieldName,
      'memberUuid': memberUuid,
      'valueJson': valueJson,
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': frontierJson,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'publishedAt': null,
    });

    await _engine.apply(
      txn,
      IncomingOperation(
        dot: Dot(authorId, authorSeq),
        hlc: hlc,
        contentKey: contentKey,
        kind: 'set_add',
        entityTable: scope.entityTable,
        entityId: entityId,
        fieldName: scope.fieldName,
        memberUuid: memberUuid,
        valueJson: valueJson,
        frontier: _decodeFrontier(frontierJson),
      ),
    );
  }

  // ── Row enumeration ──────────────────────────────────────────────────

  /// Entity ids only — never the whole row. `notes.content`,
  /// `conversation_messages.metadata` and friends are exactly the columns
  /// CLAUDE.md flags as "can be very large"; holding one table's worth of
  /// them in memory to seed them would be a real regression on a big
  /// library. Each row is re-read individually inside its own transaction
  /// instead, mirroring `OutboxDrainer._currentRow`.
  ///
  /// `rowid ASC` is insertion order; see the top doc comment on why that
  /// matters (conversation-mapping ordering) and why it is applied
  /// uniformly.
  ///
  /// **`rowid` assumption, stated rather than assumed.** A `WITHOUT ROWID`
  /// table has no `rowid` column and this query would throw against one.
  /// No sync-scope table is `WITHOUT ROWID` today (verified by
  /// `seed_scanner_test.dart`'s schema assertion, which fails loudly if one
  /// ever becomes so) — and the fix if that changes is not a fallback here
  /// but a decision about what "insertion order" even means for such a
  /// table, which is exactly the kind of thing that should surface as a
  /// failing test rather than be silently papered over with an
  /// `ORDER BY`-less query.
  Future<List<String>> _entityIds(
    DatabaseExecutor db,
    SyncEntityCaptureScope scope,
  ) async {
    final rows = await db.rawQuery(
      'SELECT CAST(${scope.idColumn} AS TEXT) AS seedEntityId '
      'FROM ${scope.table} ORDER BY rowid ASC',
    );
    return [
      for (final row in rows)
        if (row['seedEntityId'] != null) row['seedEntityId'] as String,
    ];
  }

  /// Membership rows, each carrying its owner id, member id, and whatever
  /// [SyncSetCaptureScope.payloadColumns] names — the payload goes into both
  /// the seed's `contentKey` and the operation itself, so it has to come
  /// back with the row. Unlike the entity walk, the whole row set is read at
  /// once: a membership row is three or four small columns, never a
  /// large-data column. Same `rowid` assumption as [_entityIds] — see there.
  Future<List<Map<String, Object?>>> _membershipRows(
    DatabaseExecutor db,
    SyncSetCaptureScope scope,
  ) async {
    final payloadSelect = [
      for (final column in scope.payloadColumns) ', $column',
    ].join();
    final rows = await db.rawQuery(
      'SELECT CAST(${scope.entityIdColumn} AS TEXT) AS $_seedEntityIdAlias, '
      'CAST(${scope.memberIdColumn} AS TEXT) AS $_seedMemberIdAlias'
      '$payloadSelect '
      'FROM ${scope.membershipTable} ORDER BY rowid ASC',
    );
    return [
      for (final row in rows)
        if (row[_seedEntityIdAlias] != null && row[_seedMemberIdAlias] != null)
          row,
    ];
  }

  // ── Completion marker ────────────────────────────────────────────────

  Future<bool> _isAlreadyComplete(DatabaseExecutor db) async {
    final rows = await db.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [seedScanCompletedAtKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _markComplete(DatabaseExecutor db) async {
    await db.insert('sync_state', {
      'key': seedScanCompletedAtKey,
      'value': '${DateTime.now().millisecondsSinceEpoch}',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Map<String, int> _decodeFrontier(String json) =>
      (jsonDecode(json) as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v as int),
      );
}

/// Outcome of the minting precondition for one field/membership.
enum _Pristine {
  /// No `sync_field_state`/`sync_set_state` row and no
  /// `sync_materialize_queue` entry — safe to seed.
  yes,

  /// Real, materialized history exists. Permanently not seedable, and
  /// correctly so.
  hasHistory,

  /// A pulled operation referencing this field is parked in
  /// `sync_materialize_queue`. Transient — re-checked on the next scan.
  queued,
}
