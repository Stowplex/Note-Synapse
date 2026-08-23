// Top-level sync orchestration — M2.6, § Architecture 11.7 of the
// CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// The first piece of code that actually chains M2.3 (device identity/HLC/
// seq), M2.4 (mutation capture -> outbox), M2.5 (the local causal engine),
// and M2.1/M2.2 (`SyncBackend`) together into one callable "do a sync"
// operation: **Phase 0 (drain) -> Phase B (pull) -> Phase A (push)**, in
// that order — § 11.7's "pull before push, recommended": merging remote
// HLCs before minting/pushing anything new this round keeps freshly-minted
// HLCs properly informed by whatever was just learned, and (§ 11.6(e)'s
// auto-merge write-minting, `materializer.dart`, M2.7 — now built) running
// push AFTER pull is what lets a same-session auto-merge write pair
// actually get published without a second sync round —
// `materializer_test.dart`'s own collision test exercises exactly this
// file's `run()` method end-to-end to confirm it.
//
// No UI trigger exists yet (M2.8's job) — this is a plain, directly callable
// Dart method, exactly as this milestone's brief asks for.
//
// **M2.13 review round 2 added one exception to that phase order — the
// single round after a `DatasetReset` ran Phase B before the seed scan — and
// review round 3 REMOVED it again**, because a device can never know it has
// observed everything the backend holds, so no ordering rule could make the
// seed's precondition sufficient. The seed is made recessive instead. See
// `run()`'s own inline comment and `dataset_reset.dart`'s F1 section — not
// repeated here, so there is one place to keep true.
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import '../logger_service.dart';
import 'dataset_reset.dart';
import 'device_identity.dart';
import 'hlc.dart';
import 'outbox_drainer.dart';
import 'blob_sync.dart';
import 'pull_phase.dart';
import 'push_phase.dart';
import 'seed_scanner.dart';
import 'sync_crypto.dart';
import 'seq_counter.dart';
import 'sync_backend.dart';
import 'sync_health.dart';

/// Summary of one [SyncSession.run] call — each phase's own result type,
/// untouched, so a caller/test can inspect exactly what each phase did
/// without this file re-deriving or narrowing any of it.
class SyncSessionResult {
  const SyncSessionResult({
    required this.drain,
    required this.seed,
    required this.pull,
    required this.push,
    required this.seedPush,
    this.divergedAuthorIds = const [],
    this.blobs = const BlobSyncResult(),
  });

  final DrainResult drain;

  /// M2.10's initial seed scan (`seed_scanner.dart`). On every device that
  /// has already completed one, this is [SeedScanResult.noop].
  final SeedScanResult seed;

  final PullResult pull;

  /// Phase A for this device's ORDINARY `authorId` namespace.
  final PushResult push;

  /// Phase A for this device's `seed:<deviceId>` namespace — a separate
  /// append-only log with its own tip/parent chain, so it is genuinely a
  /// second push, not extra rows in the first one.
  final PushResult seedPush;

  /// **M2.13.** Owned namespaces this device's log and the backend's have
  /// diverged on — either because a push halted on `ParentMismatch` this
  /// round, or (review finding F2) because a pre-flight tip comparison found
  /// the divergence before the round started. The second source is what
  /// covers a log deleted while the outbox was empty, which attempts no
  /// append and therefore produces no mismatch to observe.
  final List<String> divergedAuthorIds;

  /// **M3.1.** What Phase C moved: attachment bytes downloaded for rows this
  /// device received, and the blobs still outstanding because the peer that
  /// owns them has not uploaded them yet. Upload counts live on
  /// [PushPhase.lastBlobResult], since uploading happens inside Phase A.
  final BlobSyncResult blobs;

  /// Total operations published this round across both owned namespaces —
  /// what a "pushed N" UI counter should show.
  int get totalPublished => push.publishedCount + seedPush.publishedCount;
}

/// Runs one full sync round against [backend] for this device's ordinary
/// `authorId` namespace. Stateless/reusable — construct once, call [run] as
/// many times as needed (each call re-reads whatever local/remote state has
/// changed since the last one).
class SyncSession {
  SyncSession(
    DatabaseService databaseService, {
    DeviceIdentity? deviceIdentity,
    SeqCounter? seqCounter,
    HybridLogicalClock? hlc,
    OutboxDrainer? drainer,
    SeedScanner? seedScanner,
    PullPhase? pullPhase,
    PushPhase? pushPhase,
    BlobSyncPhase? blobs,
    DatasetCrypto crypto = const DatasetCrypto.plaintext(),
  }) : this._(
         databaseService,
         deviceIdentity: deviceIdentity,
         seqCounter: seqCounter,
         hlc: hlc,
         drainer: drainer,
         seedScanner: seedScanner,
         pullPhase: pullPhase,
         pushPhase: pushPhase,
         crypto: crypto,
         // **One blob phase, shared by push and fetch.** Built here rather
         // than defaulted independently in each: `PushPhase` used to
         // construct its own, which meant an encrypted dataset uploaded
         // PLAINTEXT bytes (push's phase had no key) while Phase C tried to
         // decrypt them (the session's phase did), so every blob failed to
         // open and no attachment or mini-app source ever arrived. Two
         // defaults for one collaborator is the bug; one is the fix.
         blobs: blobs ?? BlobSyncPhase(databaseService, crypto: crypto),
       );

  SyncSession._(
    DatabaseService databaseService, {
    DeviceIdentity? deviceIdentity,
    SeqCounter? seqCounter,
    HybridLogicalClock? hlc,
    OutboxDrainer? drainer,
    SeedScanner? seedScanner,
    PullPhase? pullPhase,
    PushPhase? pushPhase,
    required DatasetCrypto crypto,
    required BlobSyncPhase blobs,
  }) : _databaseService = databaseService,
       _blobs = blobs,
       _deviceIdentity = deviceIdentity ?? DeviceIdentity(databaseService),
       _hlc = hlc ?? HybridLogicalClock(databaseService),
       _drainer =
           drainer ??
           OutboxDrainer(
             databaseService,
             deviceIdentity ?? DeviceIdentity(databaseService),
             seqCounter ?? SeqCounter(databaseService),
             hlc ?? HybridLogicalClock(databaseService),
           ),
       _seedScanner =
           seedScanner ??
           SeedScanner(
             databaseService,
             deviceIdentity ?? DeviceIdentity(databaseService),
             seqCounter ?? SeqCounter(databaseService),
             hlc ?? HybridLogicalClock(databaseService),
           ),
       _pullPhase =
           pullPhase ??
           PullPhase(
             databaseService,
             hlc ?? HybridLogicalClock(databaseService),
             crypto: crypto,
           ),
       _pushPhase =
           pushPhase ??
           PushPhase(databaseService, blobs: blobs, crypto: crypto);

  final DatabaseService _databaseService;
  final DeviceIdentity _deviceIdentity;
  // ignore: unused_field
  final HybridLogicalClock _hlc;
  final OutboxDrainer _drainer;
  final SeedScanner _seedScanner;
  final PullPhase _pullPhase;
  final PushPhase _pushPhase;
  final BlobSyncPhase _blobs;

  /// Optional progress callback for the M2.10 seed scan — the one phase
  /// that can take a while on a large pre-existing library, and the one a
  /// user would otherwise experience as a frozen "Syncing…" button.
  void Function(SeedScanProgress)? onSeedProgress;

  /// Optional progress callback for Phase A (M2.12), fired once per commit
  /// confirmed, for BOTH owned namespaces (the callback's own
  /// [PushProgress.authorId] says which).
  ///
  /// **Push is the phase that actually takes the minutes**, and until M2.12
  /// it reported nothing at all: the UI went on showing the seed scan's last
  /// message for the whole of it, so a first sync of a pre-existing library
  /// looked like it had hung on a phase that had already finished.
  void Function(PushProgress)? onPushProgress;

  /// Phase 0 (drain) -> Phase 0.5 (seed) -> Phase B (pull) -> Phase A (push,
  /// per owned namespace), unconditionally — the post-reset inversion review
  /// round 2 added here was removed in round 3 (see the inline argument in
  /// [run] and [postResetRecessiveSeedStateKey]). Propagates whatever the
  /// phases throw
  /// (`PushAmbiguousUnresolvedException`, `SyncChainVerificationException`,
  /// or any `SyncBackend`-thrown exception) uncaught.
  ///
  /// **`PushParentMismatchException` is the one exception to that, as of
  /// M2.13.** It used to propagate too, on M2.6's reading that § 11.7 step
  /// 3's "surface a real error" meant "throw". What that produced on a real
  /// device was a settings screen showing
  /// `PushParentMismatchException(authorId: seed:b89a…, deviceSeq: 150,
  /// actualTipHash: , publishedBeforeHalt: 0)` in a red box, on every sync,
  /// forever, with no stated remedy — the raw form of an error is not the
  /// same thing as surfacing it. It is now caught per namespace and reported
  /// through [divergedAuthorIds] -> `sync_health.dart` ->
  /// `SyncHealthIssueKind.deviceLogDiverged`, which says what happened and
  /// what to do about it.
  ///
  /// Three things this deliberately does NOT do:
  ///  * **It does not retarget.** The halt is still a halt: nothing is
  ///    re-parented onto the backend's actual tip, which is § Architecture
  ///    3's whole point (forking a device's own log is worse than stopping).
  ///  * **It does not auto-reset.** A reset discards unpublished local
  ///    operations, so it needs consent; the app says what to do and the
  ///    user does it.
  ///  * **It does not abandon the round.** Drain, seed and pull all
  ///    completed before the push, and their work is durable and useful —
  ///    a diverged device can still RECEIVE everything other devices send.
  ///    Throwing away a successful pull because a later push halted was pure
  ///    loss. Each namespace is also its own hash-linked chain, so one
  ///    diverging says nothing about the other, and both are attempted.
  /// [preDivergedAuthorIds] (M2.13, review finding F2) are owned namespaces
  /// a caller has ALREADY established are diverged before this round started
  /// — `DatasetBootstrap.verifyOwnedLogsStillExist`'s tip comparison. They
  /// are unioned into [SyncSessionResult.divergedAuthorIds] and into the
  /// durable `sync_state` row.
  ///
  /// **Not merely additive — load-bearing.** [_recordDivergedNamespaces]
  /// rewrites that row in full every round and deletes it when the round
  /// finds nothing, by design. A device whose log was deleted while its
  /// outbox was empty pushes nothing, therefore never attempts an append,
  /// therefore never sees `ParentMismatch` — so without this parameter the
  /// round would clear a divergence that the pre-flight check had just
  /// correctly detected, and report a clean bill of health over a backend
  /// holding none of the user's data.
  Future<SyncSessionResult> run(
    SyncBackend backend, {
    List<String> preDivergedAuthorIds = const [],
  }) async {
    final ownAuthorId = await _deviceIdentity.ensureDeviceId();

    final drainResult = await _drainer.drain();

    // Phase 0.5 — the M2.10 initial seed scan, placed here deliberately.
    //
    // **After drain, not before.** A row created since the last sync
    // already has `sync_touch_log` evidence, and drain turns that into an
    // ordinary device-namespace operation and records `sync_field_state`
    // for it. Running drain first therefore means the seed scan's own
    // precondition sees those fields as already-having-history and skips
    // them — brand-new local content keeps its ordinary authorship instead
    // of being misattributed to the `seed:` namespace, and no field is ever
    // covered twice. Seeding first would invert that: the seed would claim
    // fields whose real, trigger-captured mutation was already pending.
    // (This is also what makes the post-reset re-touch in
    // `dataset_reset.dart` work: those touches are drained into ORDINARY
    // operations with real HLCs here, so the seed then skips those fields
    // and an unpublished local edit competes as an edit rather than as a
    // recessive seed.)
    //
    // **Before pull, not after.**
    // § Architecture 1's seed ordering is "join-then-seed-then-recheck":
    // everything this device holds locally is in the outbox before any
    // remote operation is compared against it. That is what lets a second
    // device holding IDENTICAL pre-existing content converge through the
    // GENESIS `contentKey` in a single round — its own seed is registered in
    // `sync_dedup_index` first, so the other device's identical operation
    // arrives into the dedup fast path (canonical winner +
    // `sync_dot_redirects`) instead of materializing as a second,
    // permanently-competing candidate. Seeding after pull would still be
    // correct (the corrected precondition would simply skip whatever the
    // pull just materialized) but would quietly bypass the one mechanism the
    // GENESIS sentinel exists for.
    //
    // **Safe on every sync**, which is why it is unconditional here rather
    // than guarded by a call site somewhere: an already-seeded device
    // short-circuits on `sync_state['seed_scan_completed_at']`, and even
    // with that key gone the precondition makes a re-run mint nothing.
    //
    // **M2.13 review round 3: there is no longer any exception to this
    // order, and the one that briefly existed is the interesting part.**
    // Round 2's fix for F1 ran Phase B before Phase 0.5 for the single round
    // after a `DatasetReset`, on the reasoning that pulling first would make
    // the seed's own precondition see the peer values. It was reproduced
    // failing three separate ways (`dataset_reset_test.dart` section 6b),
    // and the generalizable reason is worth keeping written down: **a device
    // can never know it has observed everything the backend holds**, so no
    // phase order can make [SeedScanner]'s precondition sufficient. The fix
    // moved to the tie-break — a post-reset seed is stamped `Hlc.zero` and
    // therefore loses to any concurrent real edit whenever that edit turns
    // up, in any round (`dataset_reset.dart`'s F1 section).
    //
    // Restoring seed-before-pull is not merely "the inversion is no longer
    // needed". It is strictly better for requirement 2: pulling first
    // overwrites a real app row before anything has minted an operation
    // describing what that row held, so a pre-reset local value the dataset
    // has no operation for was destroyed with no dot and therefore no
    // conflict copy. Seeding first mints a candidate for every such field,
    // which either wins uncontested or loses and is retained by
    // `FieldConflictResolver`.
    final seedResult = await _seedScanner.scan(onProgress: onSeedProgress);
    final pullResult = await _pullPhase.pull(
      backend: backend,
      ownAuthorId: ownAuthorId,
    );

    // Phase A runs against whatever sync_pending_ops contains AFTER Phase B
    // has run, per § 11.6(e)'s requirement that a same-session auto-merge
    // write pair (minted mid-pull by `SyncMaterializer`, M2.7, inside
    // `_pullPhase.pull` above) must be pushed this same session — reading
    // pending ops fresh inside PushPhase.push (rather than a snapshot taken
    // before pull started) already gives this for free, with no
    // special-casing needed here. Verified, not just reasoned about:
    // `materializer_test.dart`'s collision test asserts the minted pair
    // already carries a non-null `publishedAt` by the end of this ONE
    // `run()` call.
    final diverged = <String>[...preDivergedAuthorIds];

    /// Runs Phase A for one owned namespace, converting the halt-not-retarget
    /// outcome into a reported condition rather than a thrown one.
    ///
    /// **The halted attempt reports what it actually landed** (M2.13, review
    /// finding F4). This used to return `PushResult(publishedCount: 0)` and
    /// throw `PushParentMismatchException.publishedBeforeHalt` away, on the
    /// reasoning that "this call published nothing further" was true of the
    /// attempt that halted. It is not: `PushPhase` commits per commit and
    /// rolls nothing back, so a push that lands 40 commits and then halts has
    /// durably published 40 commits' worth of operations. Reporting 0 put
    /// "pushed 0" in the snackbar and in the stored `LastSyncOutcome` for a
    /// round that had in fact uploaded most of the user's library — the same
    /// class of under-reporting `sync_health.dart` exists to end.
    ///
    /// `resumedCount`/`commitCount` stay 0: the exception carries neither,
    /// and inventing a number for them would be worse than an obvious zero
    /// next to a real `publishedCount`. Both are diagnostics; neither is
    /// rendered.
    Future<PushResult> pushNamespace(String authorId) async {
      try {
        final result = await _pushPhase.push(
          backend: backend,
          authorId: authorId,
          onProgress: onPushProgress,
        );
        // **M2.13, review round 3, finding 4b.** A commit the backend
        // ACCEPTED is proof that the chain this device recorded still
        // continues the backend's — `ParentMismatch` is exactly the check it
        // passed. So a namespace the pre-flight comparison reported as
        // diverged, which then publishes successfully in the same round, is
        // not diverged and must not have a durable divergence row written
        // for it. Without this, `preDivergedAuthorIds` was unioned in
        // unconditionally and the row was written even for a round in which
        // both pushes fully succeeded — self-correcting next round, but the
        // documented claim "a successful push clears its own divergence" was
        // untrue of the round that actually did the clearing.
        //
        // **Gated on `publishedCount > 0`, deliberately.** A push with an
        // empty outbox attempts no append and therefore proves nothing —
        // that is finding F2's whole point, and treating it as a clean bill
        // of health here would re-open F2 through the back door.
        if (result.publishedCount > 0) diverged.remove(authorId);
        return result;
      } on PushParentMismatchException catch (error) {
        LoggerService.error(
          'SyncSession: push halted — $authorId has diverged from the backend '
          '($error). Local state references commits the backend does not '
          'have; a sync reset is required.',
        );
        if (!diverged.contains(authorId)) diverged.add(authorId);
        return PushResult(
          publishedCount: error.publishedBeforeHalt,
          resumedCount: 0,
        );
      }
    }

    final pushResult = await pushNamespace(ownAuthorId);

    // The `seed:<deviceId>` namespace is its own append-only log with its
    // own tip/parent chain (`PushPhase.push` has always been namespace-
    // parameterized for exactly this — see its own top doc comment, which
    // notes it pushed only the ordinary namespace purely because nothing
    // minted into the others yet). Pushed after the ordinary namespace so
    // an existing device's live edits reach the cloud first even if a large
    // seed push is later interrupted.
    final seedPushResult = await pushNamespace(
      await _seedScanner.seedAuthorId(),
    );

    // Rewritten in full every round, including the empty case (which deletes
    // the row) — see [divergedAuthorLogsStateKey]. A namespace that pushes
    // successfully after a reset therefore clears its own divergence without
    // anything having to remember to.
    await _recordDivergedNamespaces(diverged);

    // ── Phase C — blob fetch (M3.1, § Architecture 4) ──────────────────
    //
    // LAST, and outside every transaction. A pulled attachment row names a
    // file this device does not have yet; the bytes are fetched only once
    // the row that references them exists, so the work is derived from
    // durable state rather than queued — an interrupted fetch simply finds
    // the same gap next round. Deliberately after push as well as pull: a
    // device that has just uploaded its own blobs is the device a peer is
    // about to fetch from, and doing our own downloads first would delay
    // that for no benefit.
    //
    // Its failures are reported, never thrown: a download that fails leaves
    // the row intact and the file absent, which is the state the app
    // already renders per attachment, and taking the whole round down for
    // it would discard a successful drain, seed, pull and push.
    final blobResult = await _blobs.fetchMissing(backend);

    return SyncSessionResult(
      drain: drainResult,
      seed: seedResult,
      pull: pullResult,
      push: pushResult,
      seedPush: seedPushResult,
      divergedAuthorIds: List.unmodifiable(diverged),
      blobs: blobResult,
    );
  }

  Future<void> _recordDivergedNamespaces(List<String> diverged) async {
    final db = await _databaseService.database;
    if (diverged.isEmpty) {
      await db.delete(
        'sync_state',
        where: 'key = ?',
        whereArgs: [divergedAuthorLogsStateKey],
      );
      return;
    }
    await db.insert('sync_state', {
      'key': divergedAuthorLogsStateKey,
      'value': jsonEncode(diverged),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
