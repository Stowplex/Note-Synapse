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
import 'sync_backend.dart';

/// `sync_state['dataset_bootstrap_status']`'s three states (§ 11.1), so a
/// crash mid-bootstrap is detectable and resumable rather than silently
/// re-running from scratch or silently getting stuck.
enum DatasetBootstrapStatus { none, bootstrapping, ready }

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

  static const _statusKey = 'dataset_bootstrap_status';

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
      default:
        return DatasetBootstrapStatus.none;
    }
  }

  Future<void> _writeStatus(DatasetBootstrapStatus status) async {
    final db = await _databaseService.database;
    final value = switch (status) {
      DatasetBootstrapStatus.none => 'none',
      DatasetBootstrapStatus.bootstrapping => 'bootstrapping',
      DatasetBootstrapStatus.ready => 'ready',
    };
    await db.insert('sync_state', {
      'key': _statusKey,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Test/diagnostic accessor — no production call site needs to read this
  /// independently of [bootstrap] in this milestone.
  Future<DatasetBootstrapStatus> currentStatus() => _readStatus();

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
    // 'ready' short-circuits: this device has already completed bootstrap
    // in some earlier call/process. Re-confirm the backend still reports a
    // marker (it always should — nothing in this protocol ever un-sets one)
    // rather than trusting a purely-local "we're done" flag with no
    // corroborating read, then return without repeating any backend calls.
    if (await _readStatus() == DatasetBootstrapStatus.ready) {
      final marker = await _backend.readDatasetInitMarker();
      if (marker != null) return marker;
      // Locally 'ready' but the backend has no marker — should not happen
      // under this protocol (no operation ever clears a written marker),
      // but if it somehow did, falling through to re-run the full sequence
      // below is strictly safer than returning a value we can't produce.
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
