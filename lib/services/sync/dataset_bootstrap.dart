// Dataset bootstrap — M2.3, § Architecture 11.1 ("Device identity and
// dataset bootstrap") of the CRDT-cloud-sync design
// (`plan-and-propse-the-glistening-dolphin.md`). Implements the 5-step
// create-or-join sequence that section specifies, verbatim:
//
//   1. readDatasetInitMarker(). If non-null, join path continues at step 3.
//   2. If null: build a local DatasetInitMarker, call
//      initializeDatasetOnce(marker).
//   3. Always re-read via readDatasetInitMarker() after step 2 — never
//      trust the locally-built marker directly. This is what makes
//      "create" and "join" the *same* code path.
//   4. If the authoritative marker has encryptionEnabled == true: verify
//      the passphrase before proceeding.
//   5. sync_state['dataset_bootstrap_status'] = 'ready'. Sync may proceed.
//
// **What this milestone does NOT implement**: real KDF/canary derivation.
// § 11.1 defers that to "the AEAD-selection milestone" explicitly (§ 8.5,
// item 2 — no AEAD library chosen yet). The encrypted path here is a
// structural hook only: [PassphraseVerifier] is an injectable callback the
// bootstrap sequence calls before proceeding past a marker with
// `encryptionEnabled == true`. No default verifier is supplied — if the
// authoritative marker is encrypted and no verifier was injected, this
// throws [UnimplementedError] rather than silently pretending to verify
// anything. Tests exercise both branches (verified / rejected) by injecting
// a fake verifier; real crypto is out of scope here by design.
//
// **Not registered in `service_locator.dart`/GetIt.** An accepted, disclosed
// residual, not an oversight: this class (and its three siblings in this
// directory — `DeviceIdentity`, `SeqCounter`, `HybridLogicalClock`) has no
// production call site yet, matching how `SyncBackend`/`GoogleDriveBackend`
// (M2.1/M2.2) were likewise left unregistered until something actually
// needs to construct one. Wiring these into GetIt is deferred to whichever
// later milestone (M2.4 onward) builds the `SyncEngine` facade that is
// their first real consumer — every constructor here already takes its
// `DatabaseService` (and, for this class, `SyncBackend`/`DeviceIdentity`) by
// injection specifically so that registration is a mechanical follow-up,
// not a redesign, once that consumer exists.

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'device_identity.dart';
import 'push_phase.dart';
import 'sync_backend.dart';

/// `sync_state` key holding the bootstrap status, and the stored spelling of
/// [DatasetBootstrapStatus.needsReset]. Both are named at top level because
/// `sync_health.dart` recomputes health from durable state (its documented
/// design) and therefore reads this row itself.
const String datasetBootstrapStatusKey = 'dataset_bootstrap_status';
const String needsResetStatusValue = 'needs_reset';

/// `sync_state['dataset_bootstrap_status']`'s states (§ 11.1's three, so a
/// crash mid-bootstrap is detectable and resumable rather than silently
/// re-running from scratch or silently getting stuck — plus M2.13's fourth).
enum DatasetBootstrapStatus {
  none,
  bootstrapping,
  ready,

  /// **M2.13.** Local state references a dataset that is gone: this device
  /// completed bootstrap ('ready'), and a later authoritative read found no
  /// `DatasetInitMarker` on the backend.
  ///
  /// This state exists because 'ready' was, until M2.13, a purely local
  /// claim that nothing ever re-checked — so a user who deleted their Drive
  /// sync folder kept being told "Ready — This device has joined the sync
  /// dataset" while every sync died on a `ParentMismatch` against a log that
  /// no longer existed. Persisted (as `'needs_reset'`) rather than recomputed
  /// on demand, so the settings screen can report it without a backend call:
  /// `CloudSyncService.status()` is read on every screen open, including
  /// offline, and a test pins that it touches nothing remote.
  ///
  /// Only [DatasetReset] (`dataset_reset.dart`) leaves this state.
  needsReset,
}

/// What [DatasetBootstrap.verifyDatasetStillExists] found.
enum DatasetPresence {
  /// The backend holds an authoritative [DatasetInitMarker]. Sync may run.
  present,

  /// This device is locally 'ready' (or already `needsReset`) and the
  /// backend has no marker. Only a reset leaves this state.
  missing,

  /// This device has not completed bootstrap, so there is nothing to
  /// verify — not a divergence, and not something a reset would fix.
  notBootstrapped,
}

/// Thrown when an operation that needs a live dataset is attempted while the
/// backend has no [DatasetInitMarker] — the M2.13 state above, surfaced as
/// its own type so the UI can say "your sync dataset is gone, reset to start
/// over" instead of rendering a raw exception string in a red box.
class DatasetMissingException implements Exception {
  const DatasetMissingException();

  @override
  String toString() =>
      'DatasetMissingException: this device has joined a sync dataset that '
      'no longer exists on the backend — a sync reset is required';
}

/// Injectable passphrase-verification hook (§ 11.1 step 4). Given the
/// authoritative [DatasetInitMarker] (`encryptionEnabled == true`,
/// `kdfSalt`/`passphraseCanary` populated), returns whether the
/// user-supplied passphrase is correct. **This milestone provides no real
/// implementation** — real KDF derivation and AEAD-canary decryption are
/// deferred to the AEAD-selection milestone the design doc names
/// explicitly. Tests inject a fake verifier (returning `true`/`false`
/// directly) to exercise [DatasetBootstrap.bootstrap]'s branching without
/// needing real crypto.
typedef PassphraseVerifier = Future<bool> Function(DatasetInitMarker marker);

/// Thrown when [PassphraseVerifier] returns `false` — "a wrong-passphrase
/// error, not a downstream decrypt failure buried inside ordinary sync
/// logic" (§ 11.1).
class DatasetPassphraseVerificationFailedException implements Exception {
  const DatasetPassphraseVerificationFailedException();

  @override
  String toString() =>
      'DatasetPassphraseVerificationFailedException: passphrase verification failed for this dataset';
}

/// Runs the create-or-join bootstrap sequence (§ 11.1) against one
/// [SyncBackend], one local [DatabaseService]. One instance is scoped to
/// "this device, this dataset" — the same scoping [SyncBackend] itself
/// already assumes (§ 8.1).
class DatasetBootstrap {
  DatasetBootstrap(
    this._databaseService,
    this._backend,
    this._deviceIdentity, {
    PassphraseVerifier? passphraseVerifier,
    DateTime Function()? now,
  }) : _passphraseVerifier = passphraseVerifier,
       _now = now ?? DateTime.now;

  final DatabaseService _databaseService;
  final SyncBackend _backend;
  final DeviceIdentity _deviceIdentity;
  final PassphraseVerifier? _passphraseVerifier;
  final DateTime Function() _now;

  static const _statusKey = datasetBootstrapStatusKey;

  Future<DatasetBootstrapStatus> _readStatus() async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: [_statusKey],
      limit: 1,
    );
    if (rows.isEmpty) return DatasetBootstrapStatus.none;
    switch (rows.first['value'] as String?) {
      case 'bootstrapping':
        return DatasetBootstrapStatus.bootstrapping;
      case 'ready':
        return DatasetBootstrapStatus.ready;
      case _needsResetValue:
        return DatasetBootstrapStatus.needsReset;
      default:
        return DatasetBootstrapStatus.none;
    }
  }

  /// The persisted spelling of [DatasetBootstrapStatus.needsReset]. Named
  /// once, here, because `sync_health.dart` reads the same `sync_state` row
  /// directly (it recomputes health from durable state by design) and the
  /// two must not drift.
  static const String _needsResetValue = needsResetStatusValue;

  Future<void> _writeStatus(DatasetBootstrapStatus status) async {
    final db = await _databaseService.database;
    final value = switch (status) {
      DatasetBootstrapStatus.none => 'none',
      DatasetBootstrapStatus.bootstrapping => 'bootstrapping',
      DatasetBootstrapStatus.ready => 'ready',
      DatasetBootstrapStatus.needsReset => _needsResetValue,
    };
    await db.insert('sync_state', {
      'key': _statusKey,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// This device's LOCAL belief about the dataset. Read by
  /// `CloudSyncService.status()` on every settings-screen open, which is why
  /// it must stay purely local (no backend call): the screen is openable
  /// offline, and a test pins that rendering it touches nothing remote.
  ///
  /// **This is a belief, not a fact** — that distinction is the whole of
  /// M2.13's first half. `ready` means "the last time anything checked, this
  /// device had joined a dataset." [verifyDatasetStillExists] is what turns
  /// it back into a fact, and is what can move this to
  /// [DatasetBootstrapStatus.needsReset].
  Future<DatasetBootstrapStatus> currentStatus() => _readStatus();

  /// Re-checks a locally-'ready' device against the backend and, if the
  /// dataset is gone, records [DatasetBootstrapStatus.needsReset] durably.
  ///
  /// **One backend call, and it is the same one § 11.1 step 3 already makes
  /// load-bearing.** That step's "always re-read, never trust the locally-
  /// built marker" rule exists because a local claim about a shared dataset
  /// is not authoritative; this method is the same rule applied to the one
  /// local claim that outlives bootstrap. Called from
  /// `CloudSyncService.syncNow()` — at sync time, not at screen-render time,
  /// so it costs a round trip only when the user is already paying for a
  /// round of them.
  ///
  /// A device that has not finished bootstrap at all returns
  /// [DatasetPresence.notBootstrapped] without touching the backend: there
  /// is nothing to verify, and nothing about that state is a divergence —
  /// keeping it distinct from [DatasetPresence.missing] is what stops a
  /// never-set-up device from being told its dataset was deleted.
  Future<DatasetPresence> verifyDatasetStillExists() async {
    final status = await _readStatus();
    if (status == DatasetBootstrapStatus.needsReset) {
      return DatasetPresence.missing;
    }
    if (status != DatasetBootstrapStatus.ready) {
      return DatasetPresence.notBootstrapped;
    }

    // Deliberately NOT guarded against a throw: `readDatasetInitMarker`
    // throws for transport failures and returns null only for "there is no
    // marker" (`sync_backend.dart`). Treating an offline device as a missing
    // dataset would be a far worse bug than the one this method fixes — it
    // would tell every user on a flaky connection that their dataset had
    // been deleted — so a thrown error propagates as the ordinary sync
    // failure it is, and only a definitive `null` counts as absence.
    final marker = await _backend.readDatasetInitMarker();
    if (marker != null) return DatasetPresence.present;

    await _writeStatus(DatasetBootstrapStatus.needsReset);
    return DatasetPresence.missing;
  }

  /// **M2.13, review finding F2.** Which of this device's OWN namespaces the
  /// backend no longer holds the log this device thinks it wrote.
  ///
  /// ---------------------------------------------------------------------
  /// **The hole this closes: a deleted log with an empty outbox reported as
  /// fully healthy.**
  /// ---------------------------------------------------------------------
  /// Divergence detection used to have exactly two sources — the dataset
  /// marker being absent ([verifyDatasetStillExists] above), and a push that
  /// actually attempted an append and got `ParentMismatch`. A log deleted
  /// while nothing was pending hits neither: the round pushes nothing,
  /// therefore appends nothing, therefore never learns. Probed: sync fully,
  /// delete this device's log from the backend with the marker intact, sync
  /// again with an empty outbox -> `diverged=[]`, `degraded=false`,
  /// `bootstrap=ready`, and a fresh peer rebuilds ZERO notes. The user's
  /// entire library is absent from the backend and the app says everything
  /// is fine. That is precisely the partially-deleted-folder case
  /// `SyncHealthIssueKind.deviceLogDiverged`'s own doc comment claims to
  /// cover.
  ///
  /// **What it compares.** For each owned namespace, `sync_state
  /// ['tip:<authorId>']` (the last commit hash this device durably confirmed)
  /// against the commit the backend actually holds at
  /// `sync_state['commit_seq:<authorId>']`. Absent, short, or a different
  /// hash — deleted log, truncated log, or an identity reused after a
  /// reinstall — all read as diverged, which is right: in every one of them
  /// the local chain no longer continues the remote one.
  ///
  /// **Cost, which was an explicit constraint.** At most ONE `readCommits`
  /// (`limit: 1`) per owned namespace, i.e. at most two per `syncNow`, and
  /// zero on any device that has never confirmed a commit (no `tip:` row ->
  /// nothing to verify -> no call). It is deliberately not routed through
  /// `listDeviceLogIds`, which would add a third round trip in the healthy
  /// case to save two in the rare broken one.
  ///
  /// **A transport error is never a divergence.** Same stance, and the same
  /// reasoning, as [verifyDatasetStillExists]: `readCommits` throws for
  /// transport failures and returns an empty page only for "the backend has
  /// nothing there", so a thrown error propagates as the ordinary sync
  /// failure it is. Telling an offline user their log had been deleted would
  /// be a worse bug than the one this closes.
  ///
  /// Returns an empty list unless this device is [DatasetBootstrapStatus
  /// .ready] — there is nothing to verify before bootstrap, and the caller
  /// only reaches here after [verifyDatasetStillExists] has already confirmed
  /// the dataset itself is present.
  Future<List<String>> verifyOwnedLogsStillExist() async {
    if (await _readStatus() != DatasetBootstrapStatus.ready) return const [];
    final db = await _databaseService.database;
    final deviceId = await _deviceIdentity.ensureDeviceId();

    final diverged = <String>[];
    for (final authorId in [deviceId, 'seed:$deviceId']) {
      final tip = await _readStateValue(db, 'tip:$authorId');
      // No confirmed commit under this namespace: nothing has ever been
      // published there, so there is no chain for the backend to have lost.
      if (tip == null || tip.isEmpty) continue;

      final commitSeq = await _readCommitSeq(db, authorId);
      if (commitSeq <= 0) continue;

      final page = await _backend.readCommits(
        deviceLogId: authorId,
        afterSeq: commitSeq - 1,
        limit: 1,
      );
      final matches = page.commits.any(
        (commit) => commit.deviceSeq == commitSeq && commit.commitHash == tip,
      );
      if (!matches) diverged.add(authorId);
    }
    return diverged;
  }

  Future<String?> _readStateValue(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// This namespace's last confirmed commit-chain position, read as
  /// `PushPhase._readCommitSeq` reads it — including its pre-M2.12 fallback
  /// to `MAX(sync_publish_intent.deviceSeq)`, so a device whose log predates
  /// commit batching verifies against the right position rather than
  /// reporting itself diverged. Duplicated rather than shared because the
  /// alternative is a bootstrap -> push-phase dependency for two queries;
  /// [PushPhase.commitSeqKey] is imported so at least the KEY cannot drift.
  ///
  /// **`status = 'confirmed'` is not cosmetic (M2.13, review round 3,
  /// finding 4a), and it is the one place this copy must NOT match
  /// `PushPhase`'s verbatim.** `PushPhase` runs its step-0 resume before it
  /// ever calls its own version: a `pending` intent is either confirmed or
  /// re-appended by then, so an unfiltered `MAX(deviceSeq)` is correct
  /// there. Nothing resumes anything before this pre-flight check. A
  /// pre-M2.12 device carrying one dangling unconfirmed intent at seq N —
  /// the ordinary residue of a crash between `appendCommit` and the local
  /// write that would have confirmed it — would therefore read
  /// `commitSeq = N`, ask the backend for a commit at a position no commit
  /// was ever durably recorded at, get an empty page, and be reported
  /// **diverged**: a healthy user told to retire their device identity and
  /// wipe `sync_conflict_copies`. Only a CONFIRMED intent is evidence that a
  /// commit exists at that position, which is the only thing this comparison
  /// is entitled to assume.
  Future<int> _readCommitSeq(DatabaseExecutor db, String authorId) async {
    final raw = await _readStateValue(db, PushPhase.commitSeqKey(authorId));
    final parsed = int.tryParse(raw ?? '');
    if (parsed != null) return parsed;
    final legacy = await db.rawQuery(
      'SELECT MAX(deviceSeq) AS maxSeq FROM sync_publish_intent '
      "WHERE authorId = ? AND status = 'confirmed'",
      [authorId],
    );
    return (legacy.first['maxSeq'] as int?) ?? 0;
  }

  /// Runs the 5-step sequence and returns the authoritative
  /// [DatasetInitMarker] on success. Idempotent and safe to call again
  /// after a crash mid-bootstrap (`dataset_bootstrap_status ==
  /// 'bootstrapping'`) or even after success (`'ready'`, short-circuits by
  /// re-reading the backend's marker rather than re-running the whole
  /// sequence) — see the "resume" doc comment inline below for why re-
  /// running steps 1-2 again is always safe even when it turns out to have
  /// been unnecessary.
  ///
  /// [encryptionEnabled]/[kdfSalt]/[passphraseCanary] are this device's own
  /// choice for the *local* marker it would build if it turns out to be the
  /// one creating the dataset (§ 11.1 step 2) — irrelevant, and never used,
  /// if this device turns out to be joining an already-created dataset
  /// instead (step 1 finds a marker, or step 3's re-read returns a
  /// different device's winning marker). This milestone does not implement
  /// real KDF/canary derivation (see file doc comment); callers that want
  /// to exercise the encrypted-creation path in a test populate these
  /// fields directly, matching how `GoogleDriveBackend` already round-trips
  /// them as opaque, nullable fields.
  Future<DatasetInitMarker> bootstrap({
    bool encryptionEnabled = false,
    Uint8List? kdfSalt,
    Uint8List? passphraseCanary,
  }) async {
    final status = await _readStatus();

    // M2.13: a device already known to reference a vanished dataset must not
    // quietly bootstrap its way out. Re-creating the marker here would look
    // like a fix and would not be one — every `tip:`/`commit_seq:`/frontier
    // row still points into logs that no longer exist, so the very next push
    // would `ParentMismatch` again. `DatasetReset` is the only way out, and
    // saying so is more useful than a second, subtly different failure.
    if (status == DatasetBootstrapStatus.needsReset) {
      throw const DatasetMissingException();
    }

    // 'ready' short-circuits: this device has already completed bootstrap
    // in some earlier call/process. Re-confirm the backend still reports a
    // marker (it always should — nothing in this protocol ever un-sets one)
    // rather than trusting a purely-local "we're done" flag with no
    // corroborating read, then return without repeating any backend calls.
    if (status == DatasetBootstrapStatus.ready) {
      final marker = await _backend.readDatasetInitMarker();
      if (marker != null) return marker;
      // Locally 'ready' but the backend has no marker.
      //
      // **M2.13 changed what happens here, and this is the exact line the
      // reported failure walked through.** This branch used to fall through
      // and re-run the whole create-or-join sequence, on the reasoning that
      // "nothing in this protocol ever un-sets a marker" made the case
      // unreachable. It is reachable — a user deleted the Drive folder — and
      // falling through actively produced the dead end: a brand-new dataset
      // was created and marked ready while this device's local logs, tips
      // and counters still described the deleted one, so it was READY and
      // permanently unable to push. Recorded as needsReset and surfaced
      // instead; see [verifyDatasetStillExists].
      await _writeStatus(DatasetBootstrapStatus.needsReset);
      throw const DatasetMissingException();
    }

    // Mark 'bootstrapping' *before* touching the backend, so a crash after
    // this point and before step 5 is observable on restart as
    // 'bootstrapping', not silently indistinguishable from 'none'.
    await _writeStatus(DatasetBootstrapStatus.bootstrapping);

    // --- Step 1 ------------------------------------------------------
    var marker = await _backend.readDatasetInitMarker();

    // --- Step 2 --------------------------------------------------------
    // Also covers the crash-mid-bootstrap "resume" case: a fresh instance
    // constructed against a DB left at 'bootstrapping' re-enters here and
    // re-runs exactly this step. That is safe, not merely "not obviously
    // unsafe": initializeDatasetOnce's own contract (sync_backend.dart) is
    // "writes marker iff no marker has been written yet... must be atomic
    // against a second, concurrent first-write" — so calling it again from
    // the *same* device, whether or not an earlier crashed attempt already
    // won the race, is indistinguishable from any other "losing" (or
    // idempotent no-op) racer the interface already has to tolerate. It
    // never produces a second marker.
    if (marker == null) {
      final deviceId = await _deviceIdentity.ensureDeviceId();
      final localMarker = DatasetInitMarker(
        encryptionEnabled: encryptionEnabled,
        kdfSalt: kdfSalt,
        passphraseCanary: passphraseCanary,
        createdByDeviceId: deviceId,
        createdAt: _now(),
      );
      await _backend.initializeDatasetOnce(localMarker);
    }

    // --- Step 3 ----------------------------------------------------------
    // Always re-read — never trust `localMarker`/the step-1 `marker`
    // directly. If this device won the creation race, this simply confirms
    // its own marker; if it lost (or was joining all along), this
    // transparently returns the winner's marker instead. This re-read is
    // what unifies "create" and "join" into the same code path, per § 11.1.
    final authoritative = await _backend.readDatasetInitMarker();
    if (authoritative == null) {
      // Contract violation by the backend: initializeDatasetOnce succeeded
      // (or a marker already existed) yet readDatasetInitMarker still
      // reports none. Leave status at 'bootstrapping' (not 'ready') so a
      // retry is attempted again rather than silently proceeding unsynced.
      throw StateError(
        'DatasetBootstrap: backend reports no DatasetInitMarker after '
        'initializeDatasetOnce — violates SyncBackend\'s documented contract',
      );
    }

    // --- Step 4 ------------------------------------------------------
    if (authoritative.encryptionEnabled) {
      final verifier = _passphraseVerifier;
      if (verifier == null) {
        // Deliberately not "always return verified" — see file doc
        // comment. Real KDF/canary derivation is deferred to the
        // AEAD-selection milestone; without an injected verifier, this
        // path must fail loudly, not silently pretend the passphrase was
        // checked. Status stays 'bootstrapping', not 'ready'.
        throw UnimplementedError(
          'DatasetBootstrap: encrypted dataset bootstrap requires a PassphraseVerifier; '
          'real KDF/canary verification is not implemented in this milestone (deferred to '
          'the AEAD-selection milestone). Inject a PassphraseVerifier to exercise this path.',
        );
      }
      final verified = await verifier(authoritative);
      if (!verified) {
        // Status stays 'bootstrapping' — a wrong passphrase is not
        // "bootstrap is done," and the caller is expected to re-prompt and
        // call bootstrap() again.
        throw const DatasetPassphraseVerificationFailedException();
      }
    }

    // --- Step 5 ------------------------------------------------------
    await _writeStatus(DatasetBootstrapStatus.ready);
    return authoritative;
  }
}
