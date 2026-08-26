// M2.8, § Architecture 11.8 item 6 — the minimal manual-sync-trigger UI
// hook's backend. `SyncSession` (M2.6) has been reachable and correct since
// M2.6 landed, but only ever from tests — this file plus
// `debug_menu_screen.dart`'s new "Trigger sync" tile is what makes it
// reachable from the app itself for the first time.
//
// **Why this is a NEW, small, `lib/`-resident class rather than reusing
// `test/sync_backend/mock_sync_backend.dart`.** `MockSyncBackend`'s own top
// doc comment records a deliberate M2.1 placement decision: it lives under
// `test/`, not `lib/`, specifically because it is "a large... test-only
// harness with a pluggable fault-injection subsystem" with "no `getIt`
// registration anywhere." Importing a `test/`-resident class into `lib/`
// production code would be a real, unprecedented boundary crossing in this
// codebase (confirmed: no existing `lib/` file imports anything from
// `test/`) — bundling test-only code (and its `flutter_test`-adjacent
// dependency surface) into the shipped app. This class is the "acceptable
// minimum viable version" the milestone brief anticipates instead: a
// deliberately tiny (no fault injection, no encryption, no blob/snapshot
// support — none of which `SyncSession.run()`'s drain -> pull -> push path
// ever touches), plain in-memory `SyncBackend` implementation that belongs
// in `lib/` on its own merits, mirroring this codebase's existing small-fake-
// in-lib precedent (`FakeScreenCaptureService`/`FakeVideoSource` in
// `lib/services/world_clip/`, cited by `MockSyncBackend`'s own doc comment
// as the precedent it does NOT fit, being too large — this class is
// deliberately sized to fit that precedent instead).
//
// **What this proves, and what it explicitly does not.** A single device
// syncing against ONE persistent instance of this backend exercises real
// `DeviceIdentity`/`OutboxDrainer` (Phase 0 drain), a real `PullPhase` pass
// (Phase B — trivially a no-op the first time, since there is only one
// device's own log to skip), and a real `PushPhase` pass (Phase A — real
// wire-format encoding, real hash-chain-respecting `appendCommit` calls,
// real publish-intent bookkeeping) — proving the mechanism is wired
// end-to-end and reachable from the UI. It does NOT prove multi-device
// convergence (there is no second device in this debug flow) — that is
// already covered, thoroughly, by `test/sync_engine/sync_session_test.dart`,
// `test/sync_engine/mock_backend_multi_device_e2e_test.dart`, and
// `test/sync_engine/google_drive_backend_e2e_test.dart`. This file's job is
// narrower and different: proving reachability from the app, not
// re-proving correctness tests already cover.
//
// **No backend-selection/persistence**: this backend's data lives only in
// memory for the lifetime of the object a debug-menu action creates it in
// (a debug menu that keeps the same instance across repeated taps within
// one screen visit will show "nothing new to pull" on a second tap, an
// intentional, informative signal that the loop is idempotent — see
// `debug_menu_screen.dart`).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sync_backend.dart';

class _StoredLog {
  final List<StoredCommit> commits = [];
  final Set<String> publishIntentIds = {};
}

/// A minimal, in-memory, single-process `SyncBackend` — see this file's top
/// doc comment for why it exists instead of reusing `MockSyncBackend`, and
/// what it deliberately does not attempt to cover.
class DebugLoopbackSyncBackend implements SyncBackend {
  DebugLoopbackSyncBackend()
    : capabilities = const SyncBackendCapabilities(
        supportsConditionalDelete: false,
        supportsPersistentExternalFolder: false,
      );

  @override
  final SyncBackendCapabilities capabilities;

  DatasetInitMarker? _datasetMarker;
  final Map<String, _StoredLog> _logs = {};

  static String _hashCommit(
    String deviceLogId,
    int deviceSeq,
    String? parentCommitHash,
    Uint8List commitBytes,
  ) {
    // Identical framing to `MockSyncBackend._hashCommit`/
    // `GoogleDriveBackend._hashCommit` — required, not a stylistic choice:
    // `PullPhase._recomputeCommitHash` (`pull_phase.dart`) independently
    // re-derives this exact formula and rejects any commit whose stored
    // hash disagrees, § 8.2 item 15(b)'s content-integrity check.
    final framing = '$deviceLogId|$deviceSeq|${parentCommitHash ?? ''}|';
    return sha256.convert(utf8.encode(framing) + commitBytes).toString();
  }

  @override
  Future<void> initializeDatasetOnce(DatasetInitMarker marker) async {
    _datasetMarker ??= marker;
  }

  @override
  Future<DatasetInitMarker?> readDatasetInitMarker() async => _datasetMarker;

  @override
  Future<AppendCommitOutcome> appendCommit({
    required String deviceLogId,
    required int deviceSeq,
    required String publishIntentId,
    required String? parentCommitHash,
    required Uint8List commitBytes,
  }) async {
    final log = _logs.putIfAbsent(deviceLogId, () => _StoredLog());

    // Idempotent retry under the identical publishIntentId (§ 11.7 Phase A
    // step 0's resume procedure) — a real, if simplified, implementation of
    // the same guarantee `MockSyncBackend`/`GoogleDriveBackend` provide.
    if (log.publishIntentIds.contains(publishIntentId)) {
      final existing = log.commits.firstWhere((c) => c.deviceSeq == deviceSeq);
      return AppendCommitSucceeded(existing.commitHash);
    }

    final actualTip = log.commits.isEmpty ? null : log.commits.last.commitHash;
    if (parentCommitHash != actualTip) {
      return AppendCommitParentMismatch(actualTip ?? '');
    }

    final commitHash = _hashCommit(
      deviceLogId,
      deviceSeq,
      parentCommitHash,
      commitBytes,
    );
    log.commits.add(
      StoredCommit(
        deviceSeq: deviceSeq,
        commitHash: commitHash,
        parentCommitHash: parentCommitHash,
        commitBytes: commitBytes,
      ),
    );
    log.publishIntentIds.add(publishIntentId);
    return AppendCommitSucceeded(commitHash);
  }

  @override
  Future<List<String>> listDeviceLogIds() async => _logs.keys.toList();

  @override
  Future<CommitPage> readCommits({
    required String deviceLogId,
    required int afterSeq,
    int? limit,
  }) async {
    final log = _logs[deviceLogId];
    if (log == null) return const CommitPage(commits: [], hasGap: false);
    final matching = log.commits.where((c) => c.deviceSeq > afterSeq).toList()
      ..sort((a, b) => a.deviceSeq.compareTo(b.deviceSeq));
    final page = limit == null ? matching : matching.take(limit).toList();
    return CommitPage(commits: page, hasGap: false);
  }

  // -- Deliberately unimplemented: never called by SyncSession.run()'s
  // drain -> pull -> push path (no blob/snapshot machinery is wired into
  // the outbox drainer, causal engine, or materializer yet — the User-App/
  // attachment content-addressed-blob mechanism § Architecture 4 designs
  // for is explicitly M3 scope, per every M2.x milestone's own disclosed
  // residual). Throwing a clear, typed error rather than a silent no-op
  // means any FUTURE code path that does start calling one of these fails
  // loudly during debug-menu use, not silently.
  @override
  Future<bool> blobExists(String contentHash) => throw UnimplementedError(
    'DebugLoopbackSyncBackend: blob support is out of scope (M3) — never called by SyncSession.run()',
  );

  @override
  Future<void> uploadBlob({
    required String contentHash,
    required Stream<List<int>> data,
    required int length,
    bool sealed = false,
  }) => throw UnimplementedError(
    'DebugLoopbackSyncBackend: blob support is out of scope (M3) — never called by SyncSession.run()',
  );

  @override
  Future<Stream<List<int>>> downloadBlob(
    String contentHash, {
    bool sealed = false,
  }) => throw UnimplementedError(
    'DebugLoopbackSyncBackend: blob support is out of scope (M3) — never called by SyncSession.run()',
  );

  @override
  Future<DeleteOutcome> deleteConditionally({
    required BackendRef ref,
    required DeletePrecondition precondition,
  }) => throw UnimplementedError(
    'DebugLoopbackSyncBackend: GC/deletion is out of scope (§ Architecture 6, deferred) — never called by '
    'SyncSession.run()',
  );

  @override
  Future<void> publishSnapshot(
    String snapshotHash,
    Uint8List snapshotBytes,
  ) => throw UnimplementedError(
    'DebugLoopbackSyncBackend: snapshot support is out of scope (§ Architecture 6, deferred) — never called '
    'by SyncSession.run()',
  );

  @override
  Future<SnapshotRef?> latestSnapshotRef() => throw UnimplementedError(
    'DebugLoopbackSyncBackend: snapshot support is out of scope (§ Architecture 6, deferred) — never called '
    'by SyncSession.run()',
  );

  @override
  Future<Uint8List> readSnapshot(
    String snapshotHash,
  ) => throw UnimplementedError(
    'DebugLoopbackSyncBackend: snapshot support is out of scope (§ Architecture 6, deferred) — never called '
    'by SyncSession.run()',
  );
}
