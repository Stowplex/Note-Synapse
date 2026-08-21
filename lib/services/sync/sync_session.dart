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
import '../database_service.dart';
import 'device_identity.dart';
import 'hlc.dart';
import 'outbox_drainer.dart';
import 'pull_phase.dart';
import 'push_phase.dart';
import 'seed_scanner.dart';
import 'seq_counter.dart';
import 'sync_backend.dart';

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
  }) : _databaseService = databaseService,
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
           ),
       _pushPhase = pushPhase ?? PushPhase(databaseService);

  // ignore: unused_field
  final DatabaseService _databaseService;
  final DeviceIdentity _deviceIdentity;
  // ignore: unused_field
  final HybridLogicalClock _hlc;
  final OutboxDrainer _drainer;
  final SeedScanner _seedScanner;
  final PullPhase _pullPhase;
  final PushPhase _pushPhase;

  /// Optional progress callback for the M2.10 seed scan — the one phase
  /// that can take a while on a large pre-existing library, and the one a
  /// user would otherwise experience as a frozen "Syncing…" button.
  void Function(SeedScanProgress)? onSeedProgress;

  /// Phase 0 (drain) -> Phase 0.5 (seed) -> Phase B (pull) -> Phase A (push,
  /// per owned namespace). Propagates
  /// whatever either phase throws (`PushParentMismatchException`,
  /// `PushAmbiguousUnresolvedException`, `SyncChainVerificationException`,
  /// or any `SyncBackend`-thrown exception) uncaught — this milestone's
  /// brief is explicit that `ParentMismatch` in particular must surface as
  /// "a real, unresolved error," not be swallowed or retried automatically.
  Future<SyncSessionResult> run(SyncBackend backend) async {
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
    //
    // **Before pull, not after.** § Architecture 1's seed ordering is
    // "join-then-seed-then-recheck": everything this device holds locally
    // is in the outbox before any remote operation is compared against it.
    // That is what lets a second device holding IDENTICAL pre-existing
    // content converge through the GENESIS `contentKey` in a single round —
    // its own seed is registered in `sync_dedup_index` first, so the
    // other device's identical operation arrives into the dedup fast path
    // (canonical winner + `sync_dot_redirects`) instead of materializing as
    // a second, permanently-competing candidate. Seeding after pull would
    // still be correct (the corrected precondition would simply skip
    // whatever the pull just materialized) but would quietly bypass the one
    // mechanism the GENESIS sentinel exists for.
    //
    // **Safe on every sync**, which is why it is unconditional here rather
    // than guarded by a call site somewhere: an already-seeded device
    // short-circuits on `sync_state['seed_scan_completed_at']`, and even
    // with that key gone the precondition makes a re-run mint nothing.
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
    final pushResult = await _pushPhase.push(
      backend: backend,
      authorId: ownAuthorId,
    );

    // The `seed:<deviceId>` namespace is its own append-only log with its
    // own tip/parent chain (`PushPhase.push` has always been namespace-
    // parameterized for exactly this — see its own top doc comment, which
    // notes it pushed only the ordinary namespace purely because nothing
    // minted into the others yet). Pushed after the ordinary namespace so
    // an existing device's live edits reach the cloud first even if a large
    // seed push is later interrupted.
    final seedPushResult = await _pushPhase.push(
      backend: backend,
      authorId: await _seedScanner.seedAuthorId(),
    );

    return SyncSessionResult(
      drain: drainResult,
      seed: seedResult,
      pull: pullResult,
      push: pushResult,
      seedPush: seedPushResult,
    );
  }
}
