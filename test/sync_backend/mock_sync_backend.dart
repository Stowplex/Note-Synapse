// Full in-memory `SyncBackend` implementation with pluggable fault
// injection (`sync_faults.dart`) — § Architecture 8.6, "MockSyncBackend: a
// full SyncBackend implementation over in-memory state, with § 8.2's
// fault-injection layer as a first-class, pluggable capability."
//
// **Placement decision (M2.1), documented here since the milestone brief
// asked for it explicitly:** this lives in `test/sync_backend/`, not
// `lib/services/sync/`, even though this codebase has one precedent for a
// hand-written fake living in `lib/` — `FakeScreenCaptureService`/
// `FakeVideoSource` in `lib/services/world_clip/`. That precedent was
// considered and distinguished, not overlooked: those fakes are small
// (dozens of lines), are registered into the real `getIt` service locator
// in widget tests as a drop-in substitute for a real, already-wired
// production service, and ship in `lib/` mainly so they sit next to the
// interface they implement for discoverability. `MockSyncBackend` is
// different in kind — a large (this file), test-only harness with a
// pluggable fault-injection subsystem, no `getIt` registration anywhere
// (no sync engine exists yet to register it *for*), and a much closer
// structural match to this project's other precedent for exactly this
// situation: `test/sync_protocol/replica.dart` + `simulator.dart`, M0's
// substantial hand-rolled in-memory CRDT model, which lives entirely under
// `test/` despite being just as central to validating its subsystem as
// this file is to validating this one. `MockSyncBackend` follows that
// precedent.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_backend_exceptions.dart';

import 'sync_faults.dart';

/// Independently controllable clock — § 8.2 items 8 ("device offline for
/// the entire GC grace period... the mock's fault-injection clock must be
/// independently controllable so boundary cases (day 29 vs. day 31 of a
/// 30-day window) are deterministic") and 12 (clock skew). Stands in for
/// "backend-reported time" (what `MockSyncBackend` stamps its own stored
/// objects with), not for a device-local clock — this interface has no
/// concept of device-local time at all, since no sync engine (which would
/// own that) exists yet. True clock-*skew* modeling (two independently
/// wrong clocks disagreeing) needs that not-yet-built engine layer; this
/// class only provides the one, controllable "backend time" half of it.
class MockSyncClock {
  DateTime _now;
  MockSyncClock([DateTime? initial]) : _now = initial ?? DateTime.utc(2026, 1, 1);

  DateTime now() => _now;
  void set(DateTime value) => _now = value;
  void advance(Duration by) => _now = _now.add(by);
}

class _CommitRecord {
  final int deviceSeq;
  final String commitHash;
  final String? parentCommitHash;
  Uint8List commitBytes; // mutable only via debugTamperCommit
  final String publishIntentId;
  final String storageObjectId; // distinct per physically-created object
  final DateTime writtenAt;

  _CommitRecord({
    required this.deviceSeq,
    required this.commitHash,
    required this.parentCommitHash,
    required this.commitBytes,
    required this.publishIntentId,
    required this.storageObjectId,
    required this.writtenAt,
  });
}

class _BlobRecord {
  Uint8List bytes;
  DateTime storedAt; // doubles as this mock's etag/mtime token
  _BlobRecord({required this.bytes, required this.storedAt});
}

/// A full in-memory `SyncBackend`. See the file-level comment for why this
/// lives under `test/` rather than `lib/`.
class MockSyncBackend implements SyncBackend {
  MockSyncBackend({
    SyncBackendCapabilities? capabilities,
    MockSyncClock? clock,
    this.faultSource,
    bool simulateNonAtomicCreate = false,
  })  : capabilities = capabilities ??
            const SyncBackendCapabilities(
              supportsConditionalDelete: true,
              supportsPersistentExternalFolder: true,
            ),
        clock = clock ?? MockSyncClock(),
        _simulateNonAtomicCreate = simulateNonAtomicCreate;

  @override
  final SyncBackendCapabilities capabilities;

  final MockSyncClock clock;

  /// Mutable so a single test can change fault behavior mid-scenario
  /// (e.g. "fault-free setup, then flip on rate limiting").
  FaultSource? faultSource;

  /// § 8.4/8.6 decision point — see the long comment on
  /// [_appendCommitDurable] below for the actual mitigation this flag lets
  /// tests exercise both sides of.
  final bool _simulateNonAtomicCreate;

  DatasetInitMarker? _datasetMarker;
  final Map<String, List<_CommitRecord>> _logs = {};
  final Map<String, _BlobRecord> _blobs = {};
  final Map<String, Uint8List> _snapshots = {};
  SnapshotRef? _latestSnapshot;
  int _objectIdCounter = 0;

  String _newStorageObjectId() => 'obj-${_objectIdCounter++}';

  // -- hashing helpers -----------------------------------------------------

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static String _hashCommit(
    String deviceLogId,
    int deviceSeq,
    String? parentCommitHash,
    Uint8List commitBytes,
  ) {
    final framing = '$deviceLogId|$deviceSeq|${parentCommitHash ?? ''}|';
    final digest = sha256.convert(utf8.encode(framing) + commitBytes);
    return digest.toString();
  }

  static Uint8List _corrupt(Uint8List bytes) {
    if (bytes.isEmpty) return Uint8List.fromList([0xFF]);
    final copy = Uint8List.fromList(bytes);
    copy[copy.length ~/ 2] ^= 0xFF; // flip a byte in the middle
    return copy;
  }

  static Future<Uint8List> _collect(Stream<List<int>> data) async {
    final builder = BytesBuilder();
    await for (final chunk in data) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  void _throwForGenericFault(SyncFault? fault) {
    switch (fault) {
      case null:
        return;
      case NetworkPartitionBeforeWrite():
        throw const SyncNetworkException('connection dropped before the backend received anything');
      case AuthExpired():
        throw const SyncAuthExpiredException();
      case RefreshTokenRevoked():
        throw const SyncRefreshTokenRevokedException();
      case RateLimited(:final retryAfter):
        throw SyncRateLimitedException(retryAfter: retryAfter);
      case QuotaExceeded():
        throw const SyncQuotaExceededException();
      // The remaining fault kinds are write-shaped or read-shaped and
      // handled inline by the methods that can actually produce their
      // effect (TornWrite/NetworkPartitionAfterWrite need to run *after*
      // a real mutation; OutOfOrderDelivery/DuplicateDelivery/
      // ReadAfterWriteGap only make sense inside readCommits/
      // listDeviceLogIds). Falling through here is deliberate, not a
      // missed case.
      case NetworkPartitionAfterWrite():
      case TornWrite():
      case OutOfOrderDelivery():
      case DuplicateDelivery():
      case ReadAfterWriteGap():
        return;
    }
  }

  // -- dataset lifecycle -----------------------------------------------

  @override
  Future<void> initializeDatasetOnce(DatasetInitMarker marker) async {
    final fault = faultSource?.next(SyncOp.initializeDatasetOnce);
    _throwForGenericFault(fault);
    // First writer wins — atomic here because nothing `await`s between the
    // read and the write (this mock has no non-atomic-create mode for the
    // dataset marker; § 8.4's race is specific to appendCommit's per-seq
    // naming, not this write-once marker).
    _datasetMarker ??= marker;
    if (fault is NetworkPartitionAfterWrite) {
      throw const SyncNetworkException('dataset marker written; response lost');
    }
  }

  @override
  Future<DatasetInitMarker?> readDatasetInitMarker() async {
    final fault = faultSource?.next(SyncOp.readDatasetInitMarker);
    _throwForGenericFault(fault);
    return _datasetMarker;
  }

  // -- commit log ------------------------------------------------------

  _CommitRecord? _existingByIntent(String deviceLogId, String publishIntentId) {
    final records = _logs[deviceLogId];
    if (records == null) return null;
    for (final r in records) {
      if (r.publishIntentId == publishIntentId) return r;
    }
    return null;
  }

  /// **§ 8.4's Drive duplicate-create mitigation, resolved concretely for
  /// M2.1 — the second of the two open questions this milestone was asked
  /// to close.**
  ///
  /// Decision: **existence-check-via-listing before create**, exactly the
  /// mitigation § 8.4 names as one candidate, "accepting a real, disclosed
  /// race window." Concretely: before writing a new commit, look for an
  /// existing record under the identical `publishIntentId` in this
  /// `deviceLogId`'s log and short-circuit to `Succeeded` with its hash if
  /// found (this is the same lookup that makes ordinary retried-
  /// `appendCommit` idempotent, § 8.2 item 7 — one mechanism serves both).
  /// Reasoning for picking this over alternatives: it needs no new backend
  /// primitive (every backend already supports "read then write"), unlike
  /// e.g. requiring Drive-side app-managed locking (extra API surface,
  /// extra failure modes of its own) or a server-side function (not
  /// available for a client-only OAuth app using `drive.file` scope,
  /// requirement 12) — and it's the same shape of mitigation § Architecture
  /// 4 already prescribes for the *delete* side ("recheck-before-delete is
  /// the primary mitigation" when `supportsConditionalDelete == false`),
  /// so the create-side and delete-side mitigations are the same idea
  /// applied symmetrically, not two unrelated fixes.
  ///
  /// What makes this a *disclosed*, not eliminated, race: the existence
  /// check and the actual write are two separate backend round-trips on
  /// Drive (no atomic create-if-absent-by-name exists to collapse them
  /// into one). If two callers race with the identical `publishIntentId`
  /// — a crash-and-retry racing a second manual retry, or a double-tap —
  /// both can complete the existence check (see nothing) before either
  /// completes the write, and both then create, producing two distinct
  /// stored objects that share `deviceLogId`/`deviceSeq`/`publishIntentId`.
  /// This is *exactly* what § 8.4 discloses as the residual risk, not a
  /// bug in this mitigation — a full fix (server-side atomic rename,
  /// app-level distributed locking, or a reconciliation pass that detects
  /// and collapses same-seq duplicates after the fact) is real
  /// `GoogleDriveBackend` implementation work, explicitly out of scope for
  /// this milestone (no real Drive backend exists yet). What *this*
  /// milestone owes the future implementer is exactly what's built here:
  /// the race reproduced deterministically and on demand
  /// (`simulateNonAtomicCreate: true`), so the mitigation's boundary is a
  /// tested, known fact rather than a paragraph of prose.
  ///
  /// [_simulateNonAtomicCreate] toggles whether the existence-check and
  /// the write are separated by a real `await` boundary. `false` (default)
  /// models a backend where check-then-write is effectively atomic
  /// (WebDAV/local-folder, or an idealized backend) — concurrent racing
  /// calls under the same intent always converge to one stored commit.
  /// `true` models Drive's actual gap — concurrent racing calls *can*
  /// produce two stored objects at the same `deviceSeq`, observable only
  /// via the test-only [debugStorageObjectCountAtSeq] introspection (no
  /// real backend can offer this cheaply either, which is itself part of
  /// what makes the risk hard to detect operationally, not just hard to
  /// prevent).
  Future<AppendCommitOutcome> _appendCommitDurable({
    required String deviceLogId,
    required int deviceSeq,
    required String publishIntentId,
    required String? parentCommitHash,
    required Uint8List commitBytes,
  }) async {
    final existing = _existingByIntent(deviceLogId, publishIntentId);
    if (existing != null) {
      return AppendCommitSucceeded(existing.commitHash);
    }

    // Validate against the current tip *before* the non-atomic-create yield
    // point below, not after. This is deliberate, not an oversight: a real
    // client already knows its own `deviceSeq`/`parentCommitHash` from
    // local state (both are caller-supplied, § 8.1) and only needs the
    // backend to confirm they're still valid — it does that once, then
    // proceeds to create. Re-validating *after* the yield (i.e. against
    // whatever the tip has become by the time this call resumes) would
    // make a racing duplicate-intent call fail this check instead of
    // reaching the existence-check race at all, which would silently stop
    // reproducing § 8.4's actual finding: two racing creates *under the
    // identical, individually-valid intent* both landing. Validating here,
    // before the gap, is what makes the yield below a faithful model of
    // "the existence-check and the create are two separate round-trips",
    // rather than "the whole operation is re-decided from scratch after
    // waking up."
    final records = _logs[deviceLogId] ?? const <_CommitRecord>[];
    final tip = records.isEmpty ? null : records.last;
    final expectedParent = tip?.commitHash;
    final expectedSeq = (tip?.deviceSeq ?? 0) + 1;
    if (parentCommitHash != expectedParent || deviceSeq != expectedSeq) {
      return AppendCommitParentMismatch(expectedParent ?? '');
    }

    if (_simulateNonAtomicCreate) {
      // The disclosed race window: yields control here so a concurrent
      // second call — having independently passed the same two checks
      // above against the same pre-race state — can also reach the write
      // below before this call's write completes. See the doc comment
      // above for why this precisely reproduces § 8.4's Drive finding
      // rather than merely gesturing at it.
      await Future<void>.delayed(Duration.zero);
    }

    final commitHash = _hashCommit(deviceLogId, deviceSeq, parentCommitHash, commitBytes);
    final record = _CommitRecord(
      deviceSeq: deviceSeq,
      commitHash: commitHash,
      parentCommitHash: parentCommitHash,
      commitBytes: Uint8List.fromList(commitBytes),
      publishIntentId: publishIntentId,
      storageObjectId: _newStorageObjectId(),
      writtenAt: clock.now(),
    );
    _logs.putIfAbsent(deviceLogId, () => []).add(record);
    return AppendCommitSucceeded(commitHash);
  }

  @override
  Future<AppendCommitOutcome> appendCommit({
    required String deviceLogId,
    required int deviceSeq,
    required String publishIntentId,
    required String? parentCommitHash,
    required Uint8List commitBytes,
  }) async {
    final fault = faultSource?.next(SyncOp.appendCommit);
    if (fault is NetworkPartitionBeforeWrite) {
      throw const SyncNetworkException('connection dropped before the backend received anything');
    }
    if (fault is AuthExpired) throw const SyncAuthExpiredException();
    if (fault is RefreshTokenRevoked) throw const SyncRefreshTokenRevokedException();
    if (fault is RateLimited) throw SyncRateLimitedException(retryAfter: fault.retryAfter);
    if (fault is QuotaExceeded) throw const SyncQuotaExceededException();

    final outcome = await _appendCommitDurable(
      deviceLogId: deviceLogId,
      deviceSeq: deviceSeq,
      publishIntentId: publishIntentId,
      parentCommitHash: parentCommitHash,
      commitBytes: commitBytes,
    );

    if (fault is NetworkPartitionAfterWrite && outcome is AppendCommitSucceeded) {
      // § 8.1's central case: the write landed, but the caller must be
      // told they don't know that.
      return const AppendCommitAmbiguous();
    }
    return outcome;
  }

  @override
  Future<List<String>> listDeviceLogIds() async {
    final fault = faultSource?.next(SyncOp.listDeviceLogIds);
    _throwForGenericFault(fault);
    var ids = _logs.entries.where((e) => e.value.isNotEmpty).map((e) => e.key);
    if (fault is ReadAfterWriteGap) {
      final cutoff = clock.now().subtract(fault.delay);
      ids = _logs.entries
          .where((e) => e.value.any((r) => !r.writtenAt.isAfter(cutoff)))
          .map((e) => e.key);
    }
    return ids.toList();
  }

  @override
  Future<CommitPage> readCommits({
    required String deviceLogId,
    required int afterSeq,
    int? limit,
  }) async {
    final fault = faultSource?.next(SyncOp.readCommits);
    _throwForGenericFault(fault);

    var records = (_logs[deviceLogId] ?? const <_CommitRecord>[])
        .where((r) => r.deviceSeq > afterSeq)
        .toList()
      ..sort((a, b) => a.deviceSeq.compareTo(b.deviceSeq));

    if (fault is ReadAfterWriteGap) {
      final cutoff = clock.now().subtract(fault.delay);
      records = records.where((r) => !r.writtenAt.isAfter(cutoff)).toList();
    }

    // Only the first-written object at a given deviceSeq is visible on the
    // ordinary read path — see the long comment on _appendCommitDurable:
    // a duplicate produced by the simulated non-atomic-create race is a
    // storage-layer anomaly a real listing call wouldn't resolve on the
    // backend's behalf either. Deduping here (rather than exposing both)
    // is this mock's modeling choice for "what an ordinary readCommits
    // caller observes" — debugStorageObjectCountAtSeq is the only way to
    // see the duplication itself.
    final byDeviceSeq = <int, _CommitRecord>{};
    for (final r in records) {
      byDeviceSeq.putIfAbsent(r.deviceSeq, () => r);
    }
    var list = byDeviceSeq.values.toList()..sort((a, b) => a.deviceSeq.compareTo(b.deviceSeq));

    var hasGap = list.isNotEmpty && list.first.deviceSeq != afterSeq + 1;
    for (var i = 1; i < list.length && !hasGap; i++) {
      if (list[i].deviceSeq != list[i - 1].deviceSeq + 1) hasGap = true;
    }

    if (fault is OutOfOrderDelivery && list.length > 1) {
      list.removeAt(list.length ~/ 2);
      hasGap = true;
    }

    if (limit != null && list.length > limit) {
      list = list.sublist(0, limit);
    }

    var stored = list
        .map((r) => StoredCommit(
              deviceSeq: r.deviceSeq,
              commitHash: r.commitHash,
              parentCommitHash: r.parentCommitHash,
              commitBytes: r.commitBytes,
            ))
        .toList();

    if (fault is DuplicateDelivery && stored.isNotEmpty) {
      stored = [stored.first, ...stored];
    }

    return CommitPage(commits: stored, hasGap: hasGap);
  }

  // -- blobs -------------------------------------------------------------

  @override
  Future<bool> blobExists(String contentHash) async {
    final fault = faultSource?.next(SyncOp.blobExists);
    _throwForGenericFault(fault);
    return _blobs.containsKey(contentHash);
  }

  @override
  Future<void> uploadBlob({
    required String contentHash,
    required Stream<List<int>> data,
    required int length,
    bool sealed = false,
  }) async {
    final fault = faultSource?.next(SyncOp.uploadBlob);
    final bytes = await _collect(data);
    if (bytes.length != length) {
      throw ArgumentError(
          'uploadBlob: declared length $length does not match actual stream length ${bytes.length}');
    }
    if (fault is NetworkPartitionBeforeWrite) {
      throw const SyncNetworkException('connection dropped before the backend received anything');
    }
    if (fault is AuthExpired) throw const SyncAuthExpiredException();
    if (fault is RefreshTokenRevoked) throw const SyncRefreshTokenRevokedException();
    if (fault is RateLimited) throw SyncRateLimitedException(retryAfter: fault.retryAfter);
    if (fault is QuotaExceeded) throw const SyncQuotaExceededException();

    var storedBytes = Uint8List.fromList(bytes);
    if (fault is TornWrite) {
      storedBytes = _corrupt(storedBytes);
    }

    // **Sealed bytes cannot be re-hashed to `contentHash`** (M3.4): the
    // address is the PLAINTEXT hash, by design, so this check is only
    // meaningful for an unencrypted dataset. The verification does not
    // disappear — it moves to `blob_sync.dart`, which holds the key, and
    // becomes strictly stronger there because AEAD authentication rejects a
    // modified byte before the hash is even computed.
    final actualHash = sealed ? contentHash : _sha256Hex(storedBytes);
    if (actualHash != contentHash) {
      final caughtHere = fault is! TornWrite || fault.manifestsOnUploadCheck;
      if (caughtHere) {
        throw SyncHashMismatchException(expectedHash: contentHash, actualHash: actualHash);
      }
      // else: the torn write slips past this check (manifestsOnUploadCheck
      // == false) and is stored anyway — § 8.2 item 9's later-downloadBlob
      // discovery path.
    }

    _blobs[contentHash] = _BlobRecord(bytes: storedBytes, storedAt: clock.now());

    if (fault is NetworkPartitionAfterWrite) {
      throw const SyncNetworkException(
          'connection dropped after upload durably applied (ambiguous; resolve via blobExists)');
    }
  }

  /// Fails every `downloadBlob` while set — a blunter hook than
  /// [faultSource] for the one case that needs no particular fault KIND, only
  /// "this transfer did not complete" (M3.1's partial-write test, which
  /// asserts a failed download leaves no truncated file behind).
  bool failNextDownload = false;

  @override
  Future<Stream<List<int>>> downloadBlob(
    String contentHash, {
    bool sealed = false,
  }) async {
    if (failNextDownload) {
      throw StateError('downloadBlob: injected failure for $contentHash');
    }
    final fault = faultSource?.next(SyncOp.downloadBlob);
    _throwForGenericFault(fault);

    final record = _blobs[contentHash];
    if (record == null) {
      throw ArgumentError('downloadBlob: no blob stored for contentHash $contentHash');
    }
    final actualHash = sealed ? contentHash : _sha256Hex(record.bytes);
    if (actualHash != contentHash) {
      // "Downloaded blobs are always hash-verified" — catches both
      // ordinary corruption (item 2/9) and external tampering (item 15a),
      // indistinguishable from this side, exactly as § 8.2 item 15
      // discloses.
      throw SyncHashMismatchException(expectedHash: contentHash, actualHash: actualHash);
    }
    return Stream.value(record.bytes);
  }

  /// Every stored blob's bytes, exactly as the backend holds them — used to
  /// assert that an encrypted dataset leaves nothing readable at rest.
  List<Uint8List> debugAllBlobBytes() =>
      [for (final record in _blobs.values) record.bytes];

  // -- conditional deletion -----------------------------------------------

  bool _preconditionHolds(DeletePrecondition precondition, String currentToken) {
    return switch (precondition) {
      Unconditional() => true,
      IfUnmodifiedSince(:final etagOrMtime) => etagOrMtime == currentToken,
    };
  }

  @override
  Future<DeleteOutcome> deleteConditionally({
    required BackendRef ref,
    required DeletePrecondition precondition,
  }) async {
    final fault = faultSource?.next(SyncOp.deleteConditionally);
    _throwForGenericFault(fault);

    if (precondition is IfUnmodifiedSince && !capabilities.supportsConditionalDelete) {
      throw StateError(
          'deleteConditionally called with IfUnmodifiedSince against a backend that does not '
          'support conditional delete (capabilities.supportsConditionalDelete == false) — the '
          'caller must use the recheck-before-delete fallback and Unconditional, per § Architecture 4');
    }

    switch (ref) {
      case BlobRef(:final contentHash):
        final record = _blobs[contentHash];
        if (record == null) return const DeleteNotFound();
        if (!_preconditionHolds(precondition, record.storedAt.toIso8601String())) {
          return const DeletePreconditionFailed();
        }
        _blobs.remove(contentHash);
        return const DeleteSucceeded();

      case DeviceLogPrefixRef(:final deviceLogId, :final throughSeq):
        final records = _logs[deviceLogId];
        if (records == null || records.isEmpty) return const DeleteNotFound();
        if (!_preconditionHolds(precondition, records.last.commitHash)) {
          return const DeletePreconditionFailed();
        }
        records.removeWhere((r) => r.deviceSeq <= throughSeq);
        return const DeleteSucceeded();
    }
  }

  // -- snapshots -----------------------------------------------------------

  @override
  Future<void> publishSnapshot(String snapshotHash, Uint8List snapshotBytes) async {
    final fault = faultSource?.next(SyncOp.publishSnapshot);
    if (fault is NetworkPartitionBeforeWrite) {
      throw const SyncNetworkException('connection dropped before the backend received anything');
    }
    if (fault is AuthExpired) throw const SyncAuthExpiredException();
    if (fault is RateLimited) throw SyncRateLimitedException(retryAfter: fault.retryAfter);
    if (fault is QuotaExceeded) throw const SyncQuotaExceededException();

    var storedBytes = Uint8List.fromList(snapshotBytes);
    if (fault is TornWrite) {
      storedBytes = _corrupt(storedBytes);
    }
    _snapshots[snapshotHash] = storedBytes;
    _latestSnapshot = SnapshotRef(snapshotHash: snapshotHash, publishedAt: clock.now());

    if (fault is NetworkPartitionAfterWrite) {
      throw const SyncNetworkException('connection dropped after publish durably applied');
    }
  }

  @override
  Future<SnapshotRef?> latestSnapshotRef() async {
    final fault = faultSource?.next(SyncOp.readSnapshot);
    _throwForGenericFault(fault);
    return _latestSnapshot;
  }

  @override
  Future<Uint8List> readSnapshot(String snapshotHash) async {
    final fault = faultSource?.next(SyncOp.readSnapshot);
    _throwForGenericFault(fault);
    final bytes = _snapshots[snapshotHash];
    if (bytes == null) {
      throw ArgumentError('readSnapshot: no snapshot stored for hash $snapshotHash');
    }
    final actualHash = _sha256Hex(bytes);
    if (actualHash != snapshotHash) {
      throw SyncHashMismatchException(expectedHash: snapshotHash, actualHash: actualHash);
    }
    return bytes;
  }

  // -- test-only introspection / external-tampering injection -------------
  //
  // None of the methods below are part of `SyncBackend` — they exist only
  // so conformance tests can set up § 8.2's fault scenarios that aren't
  // naturally reachable through the ordinary API surface (items 9, 13, 15)
  // or reach in and observe otherwise-invisible mock-only state (the
  // duplicate-object race, § 8.4/8.6).

  /// § 8.2 item 15a: simulate a blob's bytes being altered by something
  /// other than the sync engine (a user directly editing a file on an
  /// unencrypted WebDAV/local-folder dataset — requirement 8 and §
  /// Architecture 1's `external:<device>` namespace both anticipate this).
  /// Bypasses every normal write-path check. The next `downloadBlob` call
  /// is expected to catch this via its ordinary hash-verification — no
  /// special-case handling exists for "tampered" vs. "corrupted," which is
  /// the point: they're indistinguishable from the caller's side.
  void debugTamperBlob(String contentHash) {
    final record = _blobs[contentHash];
    if (record == null) return;
    record.bytes = _corrupt(record.bytes);
    record.storedAt = clock.now(); // an external write updates mtime too
  }

  /// § 8.2 item 15a (deletion flavor): a blob removed by something other
  /// than `deleteConditionally`.
  void debugDeleteBlobExternally(String contentHash) {
    _blobs.remove(contentHash);
  }

  /// § 8.2 item 15b: a commit-log object mutated in place after being
  /// written — violates the immutability the hash chain depends on.
  /// Deliberately does *not* recompute `commitHash` to match the new
  /// bytes (that would model a *replacement*, not a tamper) — the stored
  /// `commitHash` stays exactly as originally recorded, so re-hashing
  /// `commitBytes` against it on a later read is expected to fail. Note
  /// `readCommits` itself does **not** self-verify this on every call
  /// (see the doc comment on `SyncBackend.readCommits`'s implementation
  /// above for why that's deliberately left to the caller/conformance
  /// suite in this milestone) — detection here happens in the
  /// conformance test, by recomputing the hash over the returned
  /// `StoredCommit`, not inside this method or `readCommits`.
  void debugTamperCommit(String deviceLogId, int deviceSeq) {
    final records = _logs[deviceLogId];
    if (records == null) return;
    final idx = records.indexWhere((r) => r.deviceSeq == deviceSeq);
    if (idx == -1) return;
    records[idx].commitBytes = _corrupt(records[idx].commitBytes);
  }

  /// § 8.2 item 15c: an entire device-log object deleted externally.
  /// **This is the one piece of item 15 the plan document itself flags as
  /// a genuinely unresolved ambiguity ("open for M2 design review"), not
  /// one of the two questions this milestone was asked to resolve** — after
  /// calling this, `listDeviceLogIds`/`readCommits` behave identically to
  /// "this device has never synced." `MockSyncBackend` does not attempt to
  /// distinguish that from "legitimately purged post-grace-period" either
  /// (no grave-marker-equivalent exists at this layer — `sync_grave` is a
  /// *local* table, § Architecture 6, not a backend-stored structure this
  /// interface exposes). The conformance suite has a test asserting this
  /// ambiguity is exactly as disclosed, not worse — it does not attempt to
  /// resolve it.
  void debugDeleteDeviceLogExternally(String deviceLogId) {
    _logs.remove(deviceLogId);
  }

  /// Test-only introspection: how many physically distinct stored commit
  /// objects exist at [deviceSeq] for [deviceLogId]. Normally 0 or 1. Can
  /// be 2+ only when `simulateNonAtomicCreate: true` and two concurrent
  /// `appendCommit` calls under the identical `publishIntentId` raced past
  /// the existence check before either had written (§ 8.4/8.6). Not part
  /// of `SyncBackend`: no real backend can offer this introspection
  /// cheaply, which is itself part of why the race is operationally hard
  /// to detect, not just hard to prevent.
  int debugStorageObjectCountAtSeq(String deviceLogId, int deviceSeq) {
    final records = _logs[deviceLogId] ?? const <_CommitRecord>[];
    return records.where((r) => r.deviceSeq == deviceSeq).length;
  }

  /// The `IfUnmodifiedSince` token that would currently succeed for this
  /// blob — test setup helper for the conditional-delete-race scenario (§
  /// 8.2 item 5): capture this, mutate the blob (re-upload or
  /// [debugTamperBlob]), then attempt a delete with the captured
  /// (now-stale) token and observe `DeletePreconditionFailed`.
  String? debugBlobEtag(String contentHash) => _blobs[contentHash]?.storedAt.toIso8601String();

  /// The `IfUnmodifiedSince` token that would currently succeed for a
  /// device-log-prefix delete — same purpose as [debugBlobEtag], for the
  /// log-pruning half of § Architecture 6's uniform GC mechanism.
  String? debugLogVersionToken(String deviceLogId) => _logs[deviceLogId]?.lastOrNull?.commitHash;
}
