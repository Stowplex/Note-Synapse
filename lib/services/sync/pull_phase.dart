// Phase B — pull — M2.6, § Architecture 11.7 of the CRDT-cloud-sync design
// (`plan-and-propse-the-glistening-dolphin.md`).
//
// Feeds decoded incoming operations into M2.5's `CausalEngine` (which
// resolves field/`__exists__`/OR-Set conflicts at the `sync_field_state`/
// `sync_set_state`/`sync_conflict_copies` level), then — as of M2.7 — hands
// whatever it resolved to `SyncMaterializer` (`materializer.dart`) to write
// into the real `notes`/`tags`/... app-table row (§ 11.6, "materialization").
// `CausalEngine.apply` itself stays uniform, `tags` included, with no
// special-casing here — § 11.6(e)'s tags auto-merge/collision-detection
// lives entirely inside `SyncMaterializer`, triggered from its own generic
// field-write path whenever a `tags` write flips `__deleted__`->false or
// `redirectTarget`->null on an existing row, not from anything in this file.
//
// **Hash-chain verification — two distinct, independent checks.**
//
// 1. **Linkage**: each commit's own `parentCommitHash` must equal the
//    previous commit's `commitHash` (or, for the very first commit this
//    device has ever pulled from a log, `null`) — a structural chain-
//    continuity check. A linkage failure on an otherwise-contiguous
//    `deviceSeq` run throws [SyncChainVerificationException] (real
//    corruption or tampering, not an ordinary eventually-consistent-listing
//    gap); a missing `deviceSeq` in the run is instead treated as an
//    ordinary gap per § 11.7 ("stop applying at the gap for this log this
//    round... rather than treating it as an error").
//
// 2. **Content integrity**: [_recomputeCommitHash] re-derives `commitHash`
//    from `commitBytes` and compares it against the backend-reported value,
//    throwing [SyncCommitHashMismatchException] on a mismatch — catching
//    exactly § 8.2 item 15b's scenario ("a commit-log object mutated in
//    place after being written"), which `MockSyncBackend.debugTamperCommit`'s
//    own doc comment says should be "expected to fail" a hash recomputation
//    on read, and which `test/sync_backend/`'s own conformance suite only
//    ever exercised as a white-box check against the mock directly, never
//    through an actual pull loop. **This is NOT backend-opaque, contrary to
//    an earlier draft of this comment**: `MockSyncBackend._hashCommit` and
//    `GoogleDriveBackend._hashCommit` use the identical, simple framing —
//    `sha256(utf8.encode('$deviceLogId|$deviceSeq|${parentCommitHash ??
//    ''}|') + bytes)` — confirmed by reading both files directly, not
//    assumed. `SyncBackend` itself does not mandate this scheme (a future
//    third backend could pick a different one), but every backend that
//    exists in this codebase today does, so a generic caller recomputing it
//    is a real, closable verification, not a hypothetical one. Neither
//    check is a substitute for the other: linkage alone would miss a commit
//    whose own bytes were corrupted in place without touching its recorded
//    `parentCommitHash`/`commitHash` pointers (exactly § 8.2 item 15b);
//    content-hash verification alone would miss a chain assembled out of
//    otherwise-individually-valid commits in the wrong order/lineage.
//
// **M2.12: a commit now carries N operations, not 1.** Three consequences,
// all of them local to this file:
//
//  * Decoding goes through `decodeCommitOperations` (`wire_format.dart`),
//    which reads both the v1 single-operation envelope and the v2 batch and
//    returns a list either way. `deviceSeq` is passed as what it now is — a
//    commit-chain position — and is only cross-checked against an operation's
//    `authorSeq` for v1, where the two really are the same number.
//  * **A commit is still applied atomically, in ONE transaction**, and that
//    is load-bearing rather than tidy: this file's duplicate/gap guards are
//    keyed on `deviceSeq`, so "half a commit applied, frontier not advanced"
//    would re-apply the applied half on the next round — and `set_remove`
//    specifically cannot tell "already applied" from "never observed" (see
//    `OrSetResolver.applySetRemove`'s own disclosed limitation). All-or-
//    nothing per commit keeps the M2.6 crash-safety story exactly as it was.
//  * M2.10's per-operation containment survives batching via a **fallback,
//    not a weakening**: if the whole-commit transaction throws, the commit is
//    retried operation-by-operation using savepoints within one transaction.
//    An unapplicable operation parks only itself, while the operations and
//    frontier still commit together. A crash cannot leave half a commit
//    durable and replay a removal on the next round.
//
// **An unknown FUTURE envelope version stops that log for the round rather
// than parking it.** Parking advances the frontier past a commit, which is
// right for an operation this build understands and cannot apply, and wrong
// for one it cannot even read: the data would be permanently invisible to
// this device. Stopping the log is the same treatment an ordinary gap gets
// (§ 11.7: "retry on the next manual sync") — every other log still pulls,
// and this device's own push still runs, so it is not the wedge M2.10
// removed either.
//
// **Duplicate delivery, handled without a separate per-dot ledger.** Since
// `readCommits(afterSeq: X)` only ever returns `deviceSeq > X`, the only way
// this device can see an already-applied `deviceSeq` again is within a
// single page (§ 8.2's `DuplicateDelivery` fault literally re-sends the
// first commit of a page) or an already-resumed frontier position. A local
// high-water-mark check (`commit.deviceSeq <= localFrontier`) catches both
// cases with no new bookkeeping — this matters concretely for `set_remove`:
// `OrSetResolver.applySetRemove` cannot itself distinguish "already applied"
// from "never observed" (its own disclosed limitation), so re-running an
// already-applied `set_remove` through `CausalEngine.apply` a second time
// would incorrectly look blocked without this earlier guard.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../data_change_notifier.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'causal/causal_engine.dart';
import 'causal/dot.dart';
import 'causal/dot_redirect_resolver.dart';
import 'hlc.dart';
import 'materializer.dart';
import 'seq_counter.dart';
import 'sync_backend.dart';
import 'sync_change_publisher.dart';
import 'sync_crypto.dart';
import 'wire_format.dart';

/// Re-derives a commit's `commitHash` from its own framing + `commitBytes`,
/// using the identical formula `MockSyncBackend._hashCommit`/
/// `GoogleDriveBackend._hashCommit` both already use — see this file's top
/// doc comment for why this is confirmed consistent across both, not
/// assumed.
String _recomputeCommitHash(
  String deviceLogId,
  int deviceSeq,
  String? parentCommitHash,
  Uint8List commitBytes,
) {
  final framing = '$deviceLogId|$deviceSeq|${parentCommitHash ?? ''}|';
  return sha256.convert(utf8.encode(framing) + commitBytes).toString();
}

/// A structural hash-chain-linkage failure — [PullPhase] found a commit
/// whose `parentCommitHash` does not equal the previous commit's
/// `commitHash` (or this device's own last-recorded tip for that log)
/// despite the `deviceSeq` run being contiguous. See this file's top doc
/// comment for why this is distinguished from an ordinary gap, and from
/// [SyncCommitHashMismatchException].
class SyncChainVerificationException implements Exception {
  final String deviceLogId;
  final int deviceSeq;
  final String? expectedParentHash;
  final String? actualParentHash;
  const SyncChainVerificationException({
    required this.deviceLogId,
    required this.deviceSeq,
    required this.expectedParentHash,
    required this.actualParentHash,
  });
  @override
  String toString() =>
      'SyncChainVerificationException(deviceLogId: $deviceLogId, deviceSeq: $deviceSeq, '
      'expectedParentHash: $expectedParentHash, actualParentHash: $actualParentHash)';
}

/// A content-integrity failure — [PullPhase] recomputed a commit's hash from
/// its own `commitBytes` and it disagrees with the `commitHash` the backend
/// reported. Catches § 8.2 item 15b ("a commit-log object mutated in place
/// after being written") — see this file's top doc comment for why this is
/// a distinct check from [SyncChainVerificationException], not a
/// duplicate: linkage alone cannot detect a commit corrupted in place
/// without its pointers being touched.
class SyncCommitHashMismatchException implements Exception {
  final String deviceLogId;
  final int deviceSeq;
  final String expectedHash;
  final String actualHash;
  const SyncCommitHashMismatchException({
    required this.deviceLogId,
    required this.deviceSeq,
    required this.expectedHash,
    required this.actualHash,
  });
  @override
  String toString() =>
      'SyncCommitHashMismatchException(deviceLogId: $deviceLogId, deviceSeq: $deviceSeq, '
      'expectedHash (recomputed from commitBytes): $expectedHash, '
      'actualHash (backend-reported): $actualHash)';
}

/// `sync_materialize_queue.blockingReason` for an operation whose
/// apply/materialize step threw. See [PullPhase]'s per-operation guard.
const String operationFailedBlockingReason = 'operation_failed';

/// `sync_materialize_queue.blockingReason` for a `set_remove` naming an
/// add-dot this device has never observed (§ Architecture 1). Public so the
/// sync health surface can count the backlog by reason.
const String missingReferencedDotBlockingReason = 'missing_referenced_dot';

/// How many times a parked operation is re-attempted before this device
/// gives up on it and reports it permanently.
///
/// **Why a retry exists at all, having previously argued it should not.** An
/// earlier version of this file parked a failed operation once and never
/// retried, reasoning that a throw means a real defect and that silently
/// re-running a failing write every sync would only hide it. That reasoning
/// is sound for a DETERMINISTIC failure — and wrong overall, because this
/// code cannot tell a deterministic failure from a transient one. A
/// `SQLITE_BUSY` from lock contention, a full disk, an I/O error, or an OOM
/// while writing a large `notes.content` all arrive at the same bare
/// `catch` as a genuine constraint violation. Combined with never retrying,
/// one moment of lock contention would permanently drop a remote edit.
///
/// A bounded retry resolves both without picking a side: a transient fault
/// clears on the next sync, a deterministic one exhausts its attempts and is
/// then reported as permanently failed rather than retried forever.
const int maxParkedOperationAttempts = 3;

class PullResult {
  const PullResult({
    required this.operationsApplied,
    required this.operationsBlocked,
    required this.gappedDeviceLogIds,
    required this.materializeQueueResolved,
    this.failedOperations = const [],
    this.unreadableCommits = const [],
  });

  /// Operations successfully routed through `CausalEngine.apply` (field/
  /// `__exists__`/`set_add`, or a `set_remove` whose targets were all
  /// resolved).
  ///
  /// **Renamed from `commitsApplied` in M2.12**, when a commit stopped being
  /// one operation: this has always counted the things that were applied,
  /// and after batching those are operations, not commits. Keeping the old
  /// name would have made "pulled N" mean something different from "pushed
  /// N" on the very same screen.
  final int operationsApplied;

  /// `set_remove` operations that hit `missing_referenced_dot` and were
  /// queued into `sync_materialize_queue` instead, plus (M2.12) any
  /// operation parked by the per-operation fallback.
  final int operationsBlocked;

  /// `deviceLogId`s where this pull round stopped early on a gap (§ 11.7:
  /// "retry on the next manual sync rather than treating it as an error").
  final List<String> gappedDeviceLogIds;

  /// `sync_materialize_queue` rows resolved by this call's own end-of-round
  /// sweep (§ 11.7 step 6).
  final int materializeQueueResolved;

  /// Operations whose apply/materialize step threw and were parked under
  /// [operationFailedBlockingReason] so the session could continue —
  /// `(authorId, authorSeq, error)`, i.e. the operation's own DOT (M2.12; it
  /// used to be the commit's `(deviceLogId, deviceSeq)`, which was the same
  /// pair only while a commit carried exactly one operation). Matching
  /// `sync_materialize_queue.blockingKey` is what lets `sync_health.dart`
  /// avoid double-counting a parked operation that also failed this round.
  /// Non-empty means something is wrong and needs a human, but the device is
  /// still syncing everything else.
  final List<(String authorId, int authorSeq, String error)> failedOperations;

  /// Commits whose envelope version this build does not implement —
  /// `(deviceLogId, deviceSeq, error)`, a COMMIT POSITION, not a dot, since
  /// nothing inside such a commit was ever decoded. Kept separate from
  /// [failedOperations] for exactly that reason.
  ///
  /// Non-empty means a peer is running a newer build: that log stopped at
  /// this position for the round and will be retried, having lost nothing.
  final List<(String deviceLogId, int deviceSeq, String error)>
  unreadableCommits;
}

/// § 11.7 Phase B.
class PullPhase {
  PullPhase(
    this._databaseService,
    this._hlc, {
    CausalEngine? engine,
    SyncMaterializer? materializer,
    SeqCounter? seqCounter,
    DatasetCrypto crypto = const DatasetCrypto.plaintext(),
    DataChangeNotifier? changeNotifier,
  }) : _crypto = crypto,
       _engine = engine ?? CausalEngine(),
       _redirects = const DotRedirectResolver(),
       _changes = SyncChangePublisher(changeNotifier: changeNotifier),
       _materializer =
           materializer ??
           SyncMaterializer(seqCounter ?? SeqCounter(_databaseService), _hlc);

  final DatabaseService _databaseService;
  final HybridLogicalClock _hlc;

  /// Plaintext by default, so every existing dataset and every test that
  /// does not care about encryption behaves byte-identically.
  final DatasetCrypto _crypto;
  final CausalEngine _engine;

  /// Used only by [_referencedDotIsResolvable]'s read-only pre-check; the
  /// authoritative resolution still happens inside `OrSetResolver`.
  final DotRedirectResolver _redirects;

  /// A pull-round-scoped, generic dispatch to `SyncMaterializer` (M2.7,
  /// § 11.6) — the piece that actually writes a resolved winner into the
  /// real app-table row this file's own top doc comment describes. Not
  /// forced to share `_engine`'s exact instance: `CausalEngine` is stateless
  /// (holds no mutable fields of its own, only delegates to equally
  /// stateless resolvers), so two independently-constructed instances are
  /// behaviorally identical.
  final SyncMaterializer _materializer;

  /// Turns what the materializer wrote into one `DataChangeEvent` per round
  /// (`sync_change_publisher.dart`) — the reason a pulled edit now reaches
  /// the search index and `AppProvider`'s caches at all. See [pull] for why
  /// it fires where it does.
  final SyncChangePublisher _changes;

  /// Page size passed to `readCommits` — a defensive cap on how much is
  /// held in memory per round-trip, not a correctness requirement (the
  /// per-deviceLogId loop below re-queries with an advanced `afterSeq` until
  /// a page comes back short, so pagination is transparent regardless of
  /// whether a given backend enforces its own internal cap even without an
  /// explicit `limit`).
  static const int _pageLimit = 500;

  /// Runs § 11.7 Phase B in full: `listDeviceLogIds` (raw, uncollapsed —
  /// `collapsePhysicalDeviceIds` is display-only, per `sync_backend.dart`'s
  /// own doc comment on `appendCommit`), skip this device's own `authorId`s,
  /// pull and apply every remaining log's new commits, then one bounded
  /// `sync_materialize_queue` sweep.
  ///
  /// **Ends by announcing what it materialized** — one merged
  /// `DataChangeEvent` per round (`sync_change_publisher.dart`), so the
  /// search indexer reindexes the notes that changed and `AppProvider`
  /// refreshes its caches. Both were previously blind to sync entirely: § 11.6
  /// (c)'s deliberate bypass of `DatabaseService`'s named mutation methods
  /// means neither of its write-path hooks fires for a materialized row.
  ///
  /// Published HERE, at the end of `pull()`, for three reasons:
  ///
  ///  * **After every transaction has committed.** Every materialization
  ///    transaction this round opens is owned by this file (the per-commit
  ///    fast path, its per-operation fallback, the parked-operation replay,
  ///    both sweeps), and each hands its collector out through its own
  ///    transaction body's return value — so a rolled-back commit's writes
  ///    are discarded along with the description of them. Publishing from
  ///    inside a transaction would also let a listener re-enter the database
  ///    while this round still holds the write lock.
  ///  * **Once, not per commit.** A pull round is exactly the unit a
  ///    consumer wants to react to; `DataChangeNotifier` would coalesce
  ///    per-commit events anyway, and one round-scoped event is what makes
  ///    the large-pull `bulk` degradation decidable at all.
  ///  * **In a `finally`.** A later log throwing (chain verification, commit
  ///    hash mismatch, a backend error) does not undo the commits earlier
  ///    logs already landed, so those must still be announced.
  Future<PullResult> pull({
    required SyncBackend backend,
    required String ownAuthorId,
  }) async {
    final db = await _databaseService.database;
    final changes = SyncChangeCollector();
    try {
      return await _pull(
        db,
        backend: backend,
        ownAuthorId: ownAuthorId,
        changes: changes,
      );
    } finally {
      await _changes.publish(db, changes);
    }
  }

  Future<PullResult> _pull(
    Database db, {
    required SyncBackend backend,
    required String ownAuthorId,
    required SyncChangeCollector changes,
  }) async {
    final rawIds = await backend.listDeviceLogIds();
    final ownPhysicalIds = _ownNamespaceIds(ownAuthorId);

    var applied = 0;
    var blocked = 0;
    final gapped = <String>[];
    final failed = <(String, int, String)>[];
    final unreadable = <(String, int, String)>[];

    for (final deviceLogId in rawIds) {
      if (ownPhysicalIds.contains(deviceLogId)) continue;

      final result = await _pullOneLog(
        db,
        backend,
        deviceLogId,
        ownAuthorId,
        changes,
      );
      applied += result.applied;
      blocked += result.blocked;
      failed.addAll(result.failed);
      unreadable.addAll(result.unreadable);
      if (result.gapped) gapped.add(deviceLogId);
    }

    // Retry parked operations BEFORE the other sweeps: one that succeeds
    // this round may be the very prerequisite (`__exists__`, or an add-dot)
    // that unblocks a `missing_exists`/`missing_referenced_dot` row below.
    final replayed = await _replayParkedOperations(
      db,
      ownAuthorId,
      failed,
      changes,
      // Anything parked moments ago in THIS round is not re-attempted here:
      // it just failed against the same state, so a same-session retry tests
      // nothing new and would report the identical dot twice in one round.
      skipDots: {for (final f in failed) '${f.$1}#${f.$2}'},
    );

    var resolved = await _sweepMaterializeQueue(db, changes);
    // § 11.6's own "gated on __exists__ having materialized first" — a
    // field/set_add op that resolved before its entity's own __exists__ had
    // materialized (possible across independently-pulled device logs; see
    // materializer.dart's top doc comment) is retried here, once, after
    // every log in this round has had a chance to advance.
    //
    // Its return value is INCLUDED, not discarded: it resolves real queue
    // rows, and dropping the count made `materializeQueueResolved`
    // systematically under-report progress the engine had actually made.
    resolved += await _materializer.sweepMissingExists(
      db,
      ownAuthorId: ownAuthorId,
      changes: changes,
    );
    resolved += replayed;

    return PullResult(
      operationsApplied: applied,
      operationsBlocked: blocked,
      gappedDeviceLogIds: gapped,
      materializeQueueResolved: resolved,
      failedOperations: List.unmodifiable(failed),
      unreadableCommits: List.unmodifiable(unreadable),
    );
  }

  /// This device's own raw namespace ids — the ordinary `authorId` plus its
  /// `seed:`/`external:` pseudo-device forms, since § Architecture 1 lets
  /// one physical device own up to three independent `deviceLogId` chains.
  /// `seed:` is minted for real as of M2.10 (`seed_scanner.dart`);
  /// `external:` still is not (requirement 8) and is included defensively.
  ///
  /// **This is computed from the CURRENT device id, so after an M2.13 reset
  /// it deliberately does NOT cover the retired one — and that is a
  /// decision, not an oversight (review finding F5).** A reset mints a fresh
  /// `device_id`, so this device's pre-reset logs (`<oldUuid>`,
  /// `seed:<oldUuid>`) are pulled back as if they were a peer's. Skipping
  /// them was considered and rejected: the dataset genuinely holds that
  /// history, and M2.13's post-reset seed is RECESSIVE precisely so it
  /// defers to whatever the dataset holds. Skipping the retired namespaces
  /// would make the re-seed win by DEFAULT over content the backend has —
  /// the F1 shape, aimed at this device's own history — and would leave the
  /// device with no way to re-learn what it had published. (The retired id
  /// is still recoverable — `sync_device_labels` keeps it with `retiredAt`
  /// set — so the option remains open if a future milestone finds a reason.)
  ///
  /// The cost is disclosed in `dataset_reset.dart`: retired backend logs are
  /// never reclaimed, so each reset permanently adds to what this device
  /// contributes to backend size.
  Set<String> _ownNamespaceIds(String ownAuthorId) => {
    ownAuthorId,
    'seed:$ownAuthorId',
    'external:$ownAuthorId',
  };

  Future<_LogPullOutcome> _pullOneLog(
    Database db,
    SyncBackend backend,
    String deviceLogId,
    String ownAuthorId,
    SyncChangeCollector changes,
  ) async {
    var localFrontier = await _readFrontier(db, deviceLogId);
    var lastKnownHash = await _readPullTip(db, deviceLogId);
    var applied = 0;
    var blocked = 0;
    var gapped = false;
    var unsupported = false;
    final failed = <(String, int, String)>[];
    final unreadable = <(String, int, String)>[];

    outer:
    while (true) {
      final page = await backend.readCommits(
        deviceLogId: deviceLogId,
        afterSeq: localFrontier,
        limit: _pageLimit,
      );
      if (page.commits.isEmpty) break;

      for (final commit in page.commits) {
        if (commit.deviceSeq <= localFrontier) {
          // Duplicate delivery (§ 8.2's DuplicateDelivery fault, or an
          // already-observed position) — already fully processed, skip.
          continue;
        }
        if (commit.deviceSeq != localFrontier + 1) {
          // A real gap: some intermediate deviceSeq is missing from what
          // was returned. Stop applying for this log this round.
          gapped = true;
          break outer;
        }
        if (commit.parentCommitHash != lastKnownHash) {
          throw SyncChainVerificationException(
            deviceLogId: deviceLogId,
            deviceSeq: commit.deviceSeq,
            expectedParentHash: lastKnownHash,
            actualParentHash: commit.parentCommitHash,
          );
        }

        // Content integrity — § 8.2 item 15b: a commit-log object mutated in
        // place after being written must be detected via hash-chain
        // verification on read, not silently trusted. Independent of the
        // linkage check above (see this file's top doc comment).
        final recomputedHash = _recomputeCommitHash(
          deviceLogId,
          commit.deviceSeq,
          commit.parentCommitHash,
          commit.commitBytes,
        );
        if (recomputedHash != commit.commitHash) {
          throw SyncCommitHashMismatchException(
            deviceLogId: deviceLogId,
            deviceSeq: commit.deviceSeq,
            expectedHash: recomputedHash,
            actualHash: commit.commitHash,
          );
        }

        // M2.12: one commit, N operations (v2) or exactly one (v1). An
        // envelope version this build does not implement stops this log for
        // the round WITHOUT advancing past it — see this file's top doc
        // comment for why that is different from parking.
        // ── M3.3: decrypt the payload, AFTER the chain check ────────────
        //
        // Order matters and is not arbitrary. The hash chain authenticates
        // the bytes AS STORED, so it must run against exactly what the
        // backend returned; decrypting first would verify a hash of
        // something the backend never held. And § 8.5's framing
        // (`deviceLogId`, `deviceSeq`, `parentCommitHash`) stays cleartext
        // precisely so this check needs no key at all.
        //
        // A payload that fails to authenticate here is NOT a passphrase
        // problem — the canary settled that at bootstrap — so it surfaces as
        // the integrity failure it is.
        final Uint8List payloadBytes;
        try {
          payloadBytes = await _crypto.open(
            commit.commitBytes,
            'commit ${commit.deviceSeq} of $deviceLogId',
          );
        } on SyncDecryptionFailedException catch (error) {
          LoggerService.error('PullPhase: $error');
          rethrow;
        }

        final List<WireOperation> wireOps;
        try {
          wireOps = decodeCommitOperations(
            payloadBytes,
            expectedAuthorId: deviceLogId,
            deviceSeq: commit.deviceSeq,
          );
        } on WireFormatUnsupportedVersionException catch (error) {
          LoggerService.error(
            'PullPhase: stopping log $deviceLogId at commit '
            '#${commit.deviceSeq} — $error',
          );
          // Reported on its own channel, NOT folded into [failedOperations]:
          // that list is typed and documented as operation DOTS
          // (`authorId#authorSeq`) and is matched against
          // `sync_materialize_queue.blockingKey` on exactly that basis. A
          // commit whose envelope could not be read has no dots to name —
          // its operations were never decoded — so putting its
          // `(deviceLogId, deviceSeq)` there would have quietly broken the
          // invariant the field's own doc states.
          unreadable.add((deviceLogId, commit.deviceSeq, '$error'));
          unsupported = true;
          break outer;
        }

        // ── Per-operation resilience (M2.10) ──────────────────────────
        //
        // **A single unapplicable operation must never be able to stop an
        // entire device from syncing.** Everything below runs inside one
        // transaction per commit, and until now any throw from it escaped
        // `SyncSession.run()` uncaught. Because push runs AFTER pull, that
        // did not merely skip the operation — it permanently blocked the
        // device's own unrelated local work from ever being published.
        // Reproduced twice during this milestone's review: a `set_add`
        // carrying an explicit `{"createdAt": null}` threw
        // `NOT NULL constraint failed` on six consecutive sessions while 33
        // unpushed local operations sat unsent, and an earlier round hit the
        // same shape via a FOREIGN KEY violation on a retry.
        //
        // Both were fixed at their own root cause, but the CLASS is what
        // matters: an operation is written by another device, possibly a
        // different build, possibly a future one, and this device cannot
        // assume it can always be applied. So the failure is contained
        // instead: the operation is parked with its full payload and the
        // real error text, the log's own pointers still advance past it, and
        // the session continues — the rest of the pull, the queue sweep, and
        // the entire push all still run.
        //
        // **Advancing the frontier/pull-tip past a parked operation is
        // correct, not a shortcut.** § Architecture 2's frontier records
        // OBSERVATION, not successful materialization (round 14's
        // observation-vs-materialization split), and `pull_phase` already
        // bumps it unconditionally for a `missing_referenced_dot`-blocked
        // commit on the line below. A parked operation is observed in
        // exactly the same sense. Not advancing would re-read and re-fail
        // the same commit on every future sync, which is the wedge again
        // wearing a different hat.
        //
        // **What is deliberately NOT caught here**: commit-chain
        // verification and wire-format integrity failures. Those are raised
        // above this point, before the transaction, and mean the LOG is
        // untrustworthy rather than one operation being unapplicable —
        // § 11.7 is explicit that they must surface as real errors.
        int appliedHere;
        int blockedHere;
        SyncChangeCollector changesHere;
        try {
          // Fast path: the whole commit, atomically.
          (appliedHere, blockedHere, changesHere) = await _applyOneCommit(
            db,
            deviceLogId: deviceLogId,
            commit: commit,
            wireOps: wireOps,
            ownAuthorId: ownAuthorId,
          );
        } catch (error, stack) {
          LoggerService.error(
            'PullPhase: commit $deviceLogId#${commit.deviceSeq} '
            '(${wireOps.length} operation(s)) failed to apply as a unit; '
            'retrying operation by operation so one unapplicable operation '
            'parks only itself',
            error: error,
            stackTrace: stack,
          );
          (
            appliedHere,
            blockedHere,
            changesHere,
          ) = await _applyCommitOperationByOperation(
            db,
            deviceLogId: deviceLogId,
            commit: commit,
            wireOps: wireOps,
            ownAuthorId: ownAuthorId,
            failed: failed,
          );
        }

        localFrontier = commit.deviceSeq;
        lastKnownHash = commit.commitHash;
        applied += appliedHere;
        blocked += blockedHere;
        // Merged only now — `changesHere` came out of a transaction body, so
        // it describes writes that are already durable. The whole-commit fast
        // path that threw above produced no collector at all.
        changes.addAll(changesHere);
      }

      if (page.commits.length < _pageLimit) break;
    }

    return _LogPullOutcome(
      applied: applied,
      blocked: blocked,
      // An unreadable-envelope stop is ALSO reported as a gap: both mean
      // "this log has more, and this device will try again next round."
      gapped: gapped || unsupported,
      failed: failed,
      unreadable: unreadable,
    );
  }

  /// One commit's operations — apply + materialize for each, plus this
  /// log's bookkeeping — in a **single transaction**. Returns
  /// `(applied, blocked, changes)` — the operation counts and what was
  /// materialized. See this file's top doc comment for why commit-level
  /// atomicity is load-bearing and not merely tidy.
  ///
  /// Extracted from [_pullOneLog] so its caller can wrap exactly this step
  /// in the guard documented there — the guard needs a clean transaction
  /// boundary to roll back to.
  ///
  /// The collector is created INSIDE the transaction body and travels out as
  /// part of its return value, so a commit that throws part-way through
  /// announces nothing: the rollback takes the description of the writes with
  /// the writes themselves.
  Future<(int, int, SyncChangeCollector)> _applyOneCommit(
    Database db, {
    required String deviceLogId,
    required StoredCommit commit,
    required List<WireOperation> wireOps,
    required String ownAuthorId,
  }) async {
    return db.transaction((txn) async {
      var applied = 0;
      var blocked = 0;
      final changes = SyncChangeCollector();
      for (final wireOp in wireOps) {
        if (await _applyOneOperation(
          txn,
          deviceLogId: deviceLogId,
          wireOp: wireOp,
          ownAuthorId: ownAuthorId,
          changes: changes,
        )) {
          blocked++;
        } else {
          applied++;
        }
      }

      // Frontier bump, unconditionally, on observation (round 14's
      // observation-vs-materialization split) — persisted in the same
      // transaction as this commit's own processing. Commit-scoped, not
      // operation-scoped: `deviceSeq` counts commits.
      await _writeFrontier(txn, deviceLogId, commit.deviceSeq);
      await _writePullTip(txn, deviceLogId, commit.commitHash);

      return (applied, blocked, changes);
    });
  }

  /// One operation's apply + materialize + per-operation bookkeeping,
  /// inside whatever transaction the caller opened. Returns whether the
  /// operation ended up blocked (`missing_referenced_dot`).
  ///
  /// The dot is built from the operation's OWN `authorSeq`, never from the
  /// commit's `deviceSeq` — those are different counters as of M2.12 (see
  /// `push_phase.dart`'s top doc comment).
  Future<bool> _applyOneOperation(
    DatabaseExecutor txn, {
    required String deviceLogId,
    required WireOperation wireOp,
    required String ownAuthorId,
    required SyncChangeCollector changes,
  }) async {
    // Same construction the parked-operation replay uses, so a replayed
    // operation is byte-identical to the live one.
    final op = _incomingFrom(wireOp, wireOp.authorId, wireOp.authorSeq);

    final result = await _engine.apply(txn, op);
    var blockedThisOp = false;
    if (result.kind == AppliedKind.setRemove &&
        result.setRemoveResult!.blocked) {
      await _enqueueMissingReferencedDot(
        txn,
        wireOp,
        result.setRemoveResult!.missingTargets,
      );
      blockedThisOp = true;
    }

    // M2.7, § 11.6: write whatever `_engine.apply` just resolved into
    // the real app-table row. Called unconditionally (not gated on
    // `blockedThisOp`) — a partially-applied `set_remove` (some
    // targets resolved, one still missing) still needs its resolved
    // targets' consequences materialized; `SyncMaterializer` itself
    // gates each op kind's own no-op cases (unchanged winner, nothing
    // newly live/removed, entity not yet materialized) internally.
    changes.addAll(
      await _materializer.materialize(
        txn,
        op: op,
        result: result,
        ownAuthorId: ownAuthorId,
      ),
    );

    // § 11.2 merge: fold the remote HLC into this device's own clock
    // on every observed operation, whether or not it ended up
    // blocked — mirrors the frontier bump, which is also
    // unconditional-on-observation.
    await _hlc.merge(wireOp.hlc.wallMs, wireOp.hlc.logical, executor: txn);

    // Opportunistic sync_ack_frontier update from this operation's
    // own carried frontier field.
    await _updateAckFrontier(txn, deviceLogId, wireOp.frontier);

    return blockedThisOp;
  }

  /// Isolates failed operations with savepoints while preserving commit-level
  /// atomicity. The successful writes, parked payloads, frontier and pull tip
  /// must commit together: otherwise a crash before the frontier write would
  /// replay already-applied OR-Set removals on the next pull.
  Future<(int, int, SyncChangeCollector)> _applyCommitOperationByOperation(
    Database db, {
    required String deviceLogId,
    required StoredCommit commit,
    required List<WireOperation> wireOps,
    required String ownAuthorId,
    required List<(String, int, String)> failed,
  }) async {
    return db.transaction((txn) async {
      var applied = 0;
      var blocked = 0;
      final changes = SyncChangeCollector();
      for (final wireOp in wireOps) {
        await txn.execute('SAVEPOINT sync_pull_operation');
        try {
          final local = SyncChangeCollector();
          final wasBlocked = await _applyOneOperation(
            txn,
            deviceLogId: deviceLogId,
            wireOp: wireOp,
            ownAuthorId: ownAuthorId,
            changes: local,
          );
          await txn.execute('RELEASE SAVEPOINT sync_pull_operation');
          changes.addAll(local);
          if (wasBlocked) {
            blocked++;
          } else {
            applied++;
          }
        } catch (error, stack) {
          await txn.execute('ROLLBACK TO SAVEPOINT sync_pull_operation');
          await txn.execute('RELEASE SAVEPOINT sync_pull_operation');
          LoggerService.error(
            'PullPhase: parking operation '
            '${wireOp.authorId}#${wireOp.authorSeq} (${wireOp.kind} '
            '${wireOp.entityTable}/${wireOp.entityId}) from commit '
            '$deviceLogId#${commit.deviceSeq} after its apply/materialize step '
            'failed; the rest of this sync continues',
            error: error,
            stackTrace: stack,
          );
          await _parkFailedOperation(txn, wireOp: wireOp, error: error);
          failed.add((wireOp.authorId, wireOp.authorSeq, '$error'));
          blocked++;
        }
      }

      await _writeFrontier(txn, deviceLogId, commit.deviceSeq);
      await _writePullTip(txn, deviceLogId, commit.commitHash);
      return (applied, blocked, changes);
    });
  }

  /// Re-attempts every parked operation that has attempts left, replaying it
  /// verbatim from the `commitBytes` [_parkFailedOperation] stored.
  ///
  /// Returns how many were successfully applied (folded into
  /// [PullResult.materializeQueueResolved]). A replay that fails again
  /// increments the entry's `attempts`; once it reaches
  /// [maxParkedOperationAttempts] the entry stops being retried and stands
  /// as a permanent, reported failure — see that constant's doc comment for
  /// why a bounded retry is the right shape and an unconditional
  /// never-retry was not.
  ///
  /// Any still-failing replay is added to [failed] so this round reports it
  /// too, rather than only the round that first parked it.
  Future<int> _replayParkedOperations(
    Database db,
    String ownAuthorId,
    List<(String, int, String)> failed,
    SyncChangeCollector changes, {
    Set<String> skipDots = const {},
  }) async {
    final rows = await db.query(
      'sync_materialize_queue',
      where: 'blockingReason = ?',
      whereArgs: [operationFailedBlockingReason],
    );
    var replayed = 0;

    for (final row in rows) {
      final id = row['id'] as int;
      if (skipDots.contains(row['blockingKey'])) continue;
      final payload =
          jsonDecode(row['operationJson'] as String) as Map<String, dynamic>;
      final attempts = payload['attempts'] as int? ?? 1;
      if (attempts >= maxParkedOperationAttempts) continue;

      final encoded = payload['commitBytes'] as String?;
      final authorId = payload['authorId'] as String?;
      final authorSeq = payload['authorSeq'] as int?;
      if (encoded == null || authorId == null || authorSeq == null) {
        continue; // parked by an older build with no replayable payload
      }

      WireOperation wireOp;
      try {
        wireOp = decodeCommitBytes(
          Uint8List.fromList(base64Decode(encoded)),
          expectedAuthorId: authorId,
          expectedAuthorSeq: authorSeq,
        );
      } catch (_) {
        continue; // undecodable: leave parked and reported, never crash here
      }

      try {
        changes.addAll(
          await db.transaction((txn) async {
            final local = SyncChangeCollector();
            // A replay can now apply but still await an unseen OR-Set add.
            // Use the live path so it retains those missing target dots and
            // the same clock/acknowledgment bookkeeping before retiring the
            // failed-operation entry.
            await _applyOneOperation(
              txn,
              deviceLogId: authorId,
              wireOp: wireOp,
              ownAuthorId: ownAuthorId,
              changes: local,
            );
            await txn.delete(
              'sync_materialize_queue',
              where: 'id = ?',
              whereArgs: [id],
            );
            return local;
          }),
        );
        replayed++;
      } catch (error) {
        // Still failing. Bump attempts in place — deliberately NOT
        // re-inserting, so `enqueuedAt` keeps its original value and stays a
        // usable aging signal.
        await db.update(
          'sync_materialize_queue',
          {
            'operationJson': jsonEncode({
              ...payload,
              'attempts': attempts + 1,
              'error': '$error',
            }),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        failed.add((authorId, authorSeq, '$error'));
      }
    }
    return replayed;
  }

  /// Shared [IncomingOperation] construction, so the live pull path and the
  /// parked-operation replay build byte-identical operations from the same
  /// decoded wire payload.
  IncomingOperation _incomingFrom(
    WireOperation wireOp,
    String authorId,
    int authorSeq,
  ) => IncomingOperation(
    dot: Dot(authorId, authorSeq),
    hlc: wireOp.hlc,
    contentKey: wireOp.contentKey,
    kind: wireOp.kind,
    entityTable: wireOp.entityTable,
    entityId: wireOp.entityId,
    fieldName: wireOp.fieldName,
    memberUuid: wireOp.memberUuid,
    valueJson: wireOp.valueJson,
    blobHash: wireOp.blobHash,
    targetDots: wireOp.targetDots,
    frontier: wireOp.frontier,
  );

  /// Records a failed operation under [operationFailedBlockingReason].
  ///
  /// **The stored record is a complete, self-contained re-encoding of the
  /// operation, and that is load-bearing rather than convenient.** An early
  /// version stored a hand-picked subset (`kind`/`authorId`/`authorSeq`/
  /// `fieldName`/`valueJson`/`hlcWallMs`) and claimed the operation stayed
  /// replayable. It did not: `hlc.logical`, `contentKey`, `blobHash` and
  /// `frontier` were all dropped, and `targetDots` with them — so a parked
  /// `set_remove`, the one kind whose entire meaning is its target dots,
  /// could not be reconstructed at all. Since the whole park-and-continue
  /// decision rests on the parked operation remaining recoverable, storing
  /// anything less makes that argument false.
  ///
  /// **M2.12 stores a re-encoded SINGLE-operation (`v: 1`) envelope rather
  /// than the commit's raw bytes**, which a batched commit made necessary
  /// rather than merely tidier: raw batch bytes would replay all N of a
  /// commit's operations to retry the one that failed, re-applying 63
  /// already-applied operations every sweep. The re-encoding is lossless
  /// (`encodeCommitBytes` is the exact inverse of the decode that produced
  /// [wireOp], over every field of every kind) and decodes back through the
  /// same `decodeCommitBytes` the replay has always used, with the same
  /// integrity check — now against the operation's own dot, which is the
  /// thing it was always meant to check.
  ///
  /// The log's frontier/pull-tip are NOT advanced here — the caller
  /// ([_applyCommitOperationByOperation]) advances them once for the whole
  /// commit after every operation has had its turn, since `deviceSeq` counts
  /// commits.
  Future<void> _parkFailedOperation(
    DatabaseExecutor txn, {
    required WireOperation wireOp,
    required Object error,
    int attempts = 1,
  }) async {
    await txn.insert('sync_materialize_queue', {
      'blockingReason': operationFailedBlockingReason,
      'entityTable': wireOp.entityTable,
      'entityId': wireOp.entityId,
      'fieldName': wireOp.fieldName,
      'operationJson': jsonEncode({
        'kind': wireOp.kind,
        'authorId': wireOp.authorId,
        'authorSeq': wireOp.authorSeq,
        // The complete, verbatim operation — every field, for every kind.
        'commitBytes': base64Encode(encodeCommitBytes(wireOp)),
        'attempts': attempts,
        'error': '$error',
      }),
      'blockingKey': '${wireOp.authorId}#${wireOp.authorSeq}',
      'enqueuedAt': DateTime.now().millisecondsSinceEpoch,
    });

    // Same unconditional-on-observation bookkeeping the successful path
    // performs. The operation was observed; only its effect was not
    // applied.
    await _hlc.merge(wireOp.hlc.wallMs, wireOp.hlc.logical, executor: txn);
  }

  // ── sync_materialize_queue: enqueue + bounded sweep ──────────────────

  /// Queues one row per still-missing target dot — never the full original
  /// `targetDots` list. `OrSetResolver.applySetRemove` already durably
  /// deleted every dot that DID resolve in the same call that produced
  /// [missing]; re-queuing the whole original list would make a future
  /// retry see those already-applied targets as "missing" too (no live row
  /// left to find), since the resolver cannot distinguish "already removed"
  /// from "never observed" — queuing only the genuinely-still-missing
  /// subset avoids ever exercising that ambiguity for a target this device
  /// has already correctly processed.
  Future<void> _enqueueMissingReferencedDot(
    DatabaseExecutor txn,
    WireOperation op,
    List<Dot> missing,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final target in missing) {
      await txn.insert('sync_materialize_queue', {
        'blockingReason': missingReferencedDotBlockingReason,
        'entityTable': op.entityTable,
        'entityId': op.entityId,
        'fieldName': op.fieldName,
        'operationJson': jsonEncode({
          'entityTable': op.entityTable,
          'entityId': op.entityId,
          'fieldName': op.fieldName,
          'memberUuid': op.memberUuid,
          'targetAuthorId': target.authorId,
          'targetAuthorSeq': target.authorSeq,
        }),
        'blockingKey': target
            .toString(), // "authorId#authorSeq", matches Dot.toString()
        'enqueuedAt': now,
      });
    }
  }

  /// § 11.7 step 6: "one bounded sweep... retries entries whose
  /// `blockingKey` may now be satisfied." One linear pass over currently-
  /// queued `missing_referenced_dot` rows — not a fixpoint/recursive retry
  /// loop — resolving each via the same `CausalEngine.apply` path a fresh
  /// `set_remove` would take (`op.dot`/`op.hlc`/`op.contentKey`/
  /// `op.frontier` are all unused by `CausalEngine.apply`'s `set_remove`
  /// branch — see `causal_engine.dart`'s dispatch — so the placeholder
  /// values here are inert, not load-bearing). M2.7: a resolved retry is
  /// also materialized (real-table `DELETE` if zero live dots remain),
  /// exactly like an ordinary first-attempt `set_remove` would be.
  Future<int> _sweepMaterializeQueue(
    Database db,
    SyncChangeCollector changes,
  ) async {
    var resolved = 0;
    final rows = await db.query(
      'sync_materialize_queue',
      where: 'blockingReason = ?',
      whereArgs: [missingReferencedDotBlockingReason],
    );
    for (final row in rows) {
      final id = row['id'] as int;
      final payload =
          jsonDecode(row['operationJson'] as String) as Map<String, dynamic>;
      final target = Dot(
        payload['targetAuthorId'] as String,
        payload['targetAuthorSeq'] as int,
      );

      // **Cheap read-only pre-check, and deliberately NO attempt bound.**
      //
      // The real complaint about this loop was cost: it opened a full write
      // transaction per queued row on every pull, before `_engine.apply`
      // had decided whether there was anything to do. A previous version of
      // this file answered that with a pass-count ageout, which is a
      // data-losing remedy for a cost problem — and in a CRDT specifically a
      // **resurrected deletion**: a `set_remove` that ages out leaves the
      // membership live on this device forever while every other replica
      // converges on "removed". Worse, the budget was spent by rounds that
      // could not possibly have helped (an increment happened even when the
      // pull observed no new commits at all), so a user tapping Sync three
      // times in thirty seconds could burn it while the backend's own
      // read-after-write gap was still open. Removed.
      //
      // What replaces it is a resolution of the actual cost: work out
      // read-only whether this target is resolvable, and only then open a
      // transaction. This mirrors what `sweepMissingExists` already does
      // for its own two branches (`_setAddBlocker`/`_rowExists`, both
      // checked against `db` before any transaction) — so both "waiting on
      // data that has not arrived" sweeps now follow one policy: unbounded
      // retry, made cheap by a pre-check, made visible by `sync_health.dart`.
      //
      // **That policy is chosen over bounding, for both, on purpose.**
      // `missing_exists` and `missing_referenced_dot` are both waiting for
      // an operation that may still arrive; abandoning either loses data
      // that would otherwise converge, and neither has a bound that can
      // distinguish "will never arrive" from "has not arrived yet". The
      // parked-operation replay above is the one case that IS bounded, and
      // it is categorically different: it is not waiting for anything, it is
      // re-running a write that already failed, which costs real work every
      // time and may never succeed. Waiting is free once it is cheap;
      // retrying a failing write is not.
      if (!await _referencedDotIsResolvable(db, payload, target)) continue;

      final (didResolve, sweepChanges) = await db.transaction((txn) async {
        final local = SyncChangeCollector();
        final op = IncomingOperation(
          dot: target, // placeholder — unused by the set_remove branch
          hlc: Hlc.zero, // placeholder — unused by the set_remove branch
          kind: 'set_remove',
          entityTable: payload['entityTable'] as String,
          entityId: payload['entityId'] as String,
          fieldName: payload['fieldName'] as String?,
          memberUuid: payload['memberUuid'] as String?,
          targetDots: [target],
          frontier: const {}, // placeholder — unused by the set_remove branch
        );
        final result = await _engine.apply(txn, op);
        final applied = result.setRemoveResult!.appliedTargets.isNotEmpty;
        if (applied) {
          local.addAll(
            await _materializer.materialize(
              txn,
              op: op,
              result: result,
              ownAuthorId: '', // unused by the set_remove materialization path
            ),
          );
          await txn.delete(
            'sync_materialize_queue',
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        return (applied, local);
      });

      changes.addAll(sweepChanges);
      if (didResolve) resolved++;
    }
    return resolved;
  }

  /// Read-only: could a `set_remove` for [target] possibly apply right now?
  ///
  /// Mirrors `OrSetResolver.applySetRemove`'s own matching rule (resolve
  /// both sides through `sync_dot_redirects`, then compare) without opening
  /// a write transaction or mutating anything. A `false` here means the
  /// queued row would have been a guaranteed no-op — which is the steady
  /// state for a target this device has never observed, and exactly the
  /// case that used to cost a transaction per pull, forever.
  Future<bool> _referencedDotIsResolvable(
    DatabaseExecutor db,
    Map<String, dynamic> payload,
    Dot target,
  ) async {
    final liveDots = await db.query(
      'sync_set_state',
      columns: const ['authorId', 'authorSeq'],
      where:
          'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
      whereArgs: [
        payload['entityTable'],
        payload['entityId'],
        payload['fieldName'],
        payload['memberUuid'],
      ],
    );
    // No live add-dot for this member at all: nothing to remove. The common
    // case, and the one this pre-check exists for.
    if (liveDots.isEmpty) return false;

    final resolvedTarget = await _redirects.resolveDot(db, target);
    for (final row in liveDots) {
      final rowDot = Dot(row['authorId'] as String, row['authorSeq'] as int);
      if (await _redirects.resolveDot(db, rowDot) == resolvedTarget) {
        return true;
      }
    }
    // The member is live, but under a dot unrelated to this target.
    return false;
  }

  // ── sync_state: per-remote-log frontier/pull-tip bookkeeping ─────────

  Future<int> _readFrontier(DatabaseExecutor db, String deviceLogId) async {
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: ['frontier:$deviceLogId'],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return int.parse(rows.first['value'] as String);
  }

  Future<void> _writeFrontier(
    DatabaseExecutor txn,
    String deviceLogId,
    int seq,
  ) async {
    await txn.insert('sync_state', {
      'key': 'frontier:$deviceLogId',
      'value': '$seq',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> _readPullTip(DatabaseExecutor db, String deviceLogId) async {
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: ['pull_tip:$deviceLogId'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _writePullTip(
    DatabaseExecutor txn,
    String deviceLogId,
    String commitHash,
  ) async {
    await txn.insert('sync_state', {
      'key': 'pull_tip:$deviceLogId',
      'value': commitHash,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── sync_ack_frontier: opportunistic per-remote-device update ────────

  Future<void> _updateAckFrontier(
    DatabaseExecutor txn,
    String deviceId,
    Map<String, int> carriedFrontier,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in carriedFrontier.entries) {
      final existing = await txn.query(
        'sync_ack_frontier',
        columns: const ['ackedSeq'],
        where: 'deviceId = ? AND authorId = ?',
        whereArgs: [deviceId, entry.key],
        limit: 1,
      );
      final currentMax = existing.isEmpty
          ? -1
          : existing.first['ackedSeq'] as int;
      if (entry.value > currentMax) {
        await txn.insert('sync_ack_frontier', {
          'deviceId': deviceId,
          'authorId': entry.key,
          'ackedSeq': entry.value,
          'updatedAt': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }
}

class _LogPullOutcome {
  const _LogPullOutcome({
    required this.applied,
    required this.blocked,
    required this.gapped,
    this.failed = const [],
    this.unreadable = const [],
  });
  final int applied;
  final int blocked;
  final bool gapped;

  /// Operations parked under [operationFailedBlockingReason] while pulling
  /// this one log — `(authorId, authorSeq, error)`, the operation's own dot.
  final List<(String, int, String)> failed;

  /// Commits this build could not decode at all — `(deviceLogId, deviceSeq,
  /// error)`, a commit position rather than a dot, which is exactly why it
  /// is a separate list.
  final List<(String, int, String)> unreadable;
}
