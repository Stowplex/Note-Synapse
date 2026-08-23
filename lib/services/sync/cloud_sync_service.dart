// Cloud sync coordinator — M2.9.
//
// The one place that wires the pieces M2.1-M2.8 built into something a user
// can actually operate: auth (`GoogleDriveAuthService`) -> a real
// `GoogleDriveBackend` over the app's rhttp stack -> `DatasetBootstrap`'s
// create-or-join sequence -> `SyncSession.run()`.
//
// Before this milestone every one of those had exactly one caller: a test.
// `cloud_sync_screen.dart` is deliberately thin on top of this class so that
// "what a sync actually does" stays testable and out of a widget.
//
// **Scope, deliberately small.** One backend (Drive), no backend picker, no
// passphrase/encryption (M2.x, still deferred — `DatasetBootstrap` is called
// with `encryptionEnabled: false`), no conflict-resolution UI, no background
// scheduling. Sync happens when the user taps Sync now.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import '../logger_service.dart';
import '../network_provider.dart';
import 'dataset_bootstrap.dart';
import 'dataset_reset.dart';
import 'device_identity.dart';
import 'google_drive_auth_service.dart';
import 'google_drive_backend.dart';
import 'push_phase.dart';
import 'seed_scanner.dart';
import 'sync_health.dart';
import 'sync_backend.dart';
import 'sync_session.dart';

/// The outcome of the last [CloudSyncService.syncNow] attempt on this device,
/// persisted in `sync_state` so it survives leaving and reopening the screen
/// (and app restarts). Without persistence the settings screen would claim
/// "not synced on this device yet" the moment the user navigates away, which
/// is worse than saying nothing.
class LastSyncOutcome {
  const LastSyncOutcome({
    required this.at,
    required this.succeeded,
    required this.detail,
    this.degraded = false,
  });

  final DateTime at;

  /// Whether the round completed without throwing. **Not the same as "all
  /// your data synced"** — see [degraded].
  final bool succeeded;

  /// The round completed, but something did not sync (`sync_health.dart`).
  ///
  /// This third state is the point of the whole health surface: before it
  /// existed, `succeeded: true` was reported for a session that had
  /// permanently dropped a remote operation, silently skipped every row of
  /// a table, or parked a backlog that could never drain. A green checkmark
  /// over undelivered data is worse than an error, because nothing prompts
  /// anyone to look.
  final bool degraded;

  /// For a success, the phase counters as `drained/seeded/pulled/pushed`
  /// (M2.10 added `seeded` — a first sync of a pre-existing library does all
  /// its work there, and reporting only `0/0/0` was exactly the complaint
  /// that surfaced the missing seed scan); for a failure, the exception's
  /// `toString()`. Stored pre-rendered rather than structured because the UI
  /// only ever displays it, and because a failure has no counters to
  /// structure. Values written before M2.10 have three parts, which
  /// `cloud_sync_screen.dart`'s formatter still renders.
  final String detail;

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'succeeded': succeeded,
    'detail': detail,
    'degraded': degraded,
  };

  static LastSyncOutcome? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.tryParse(json['at'] as String? ?? '');
      if (at == null) return null;
      return LastSyncOutcome(
        at: at,
        succeeded: json['succeeded'] as bool? ?? false,
        detail: json['detail'] as String? ?? '',
        // Absent in rows written before the health surface existed; those
        // rounds were reported as plain successes and stay that way.
        degraded: json['degraded'] as bool? ?? false,
      );
    } catch (_) {
      // A corrupt/legacy row is not worth failing the whole settings screen
      // over — "no last outcome" is a truthful fallback.
      return null;
    }
  }
}

/// Everything the settings screen needs to render, in one snapshot so the UI
/// never has to make two independent async reads that could disagree.
class CloudSyncStatus {
  const CloudSyncStatus({
    required this.connection,
    required this.bootstrapStatus,
    this.lastSync,
    this.health = SyncHealth.healthy,
  });

  final GoogleDriveConnectionState connection;
  final DatasetBootstrapStatus bootstrapStatus;
  final LastSyncOutcome? lastSync;

  /// What, if anything, is not syncing — recomputed at the end of every
  /// round and persisted, so it survives leaving the screen.
  final SyncHealth health;

  /// True when a sync can actually be attempted.
  bool get canSync =>
      (connection == GoogleDriveConnectionState.connected ||
          connection ==
              GoogleDriveConnectionState.connectedWithoutRefreshToken) &&
      bootstrapStatus == DatasetBootstrapStatus.ready;

  /// True when the account is linked but the dataset has not been
  /// created/joined yet — the one step between connecting and syncing.
  ///
  /// [DatasetBootstrapStatus.needsReset] is excluded (M2.13): that device is
  /// not un-set-up, it is mis-set-up, and offering "Set up dataset" there
  /// would offer an action that now deliberately throws.
  bool get needsDatasetSetup =>
      (connection == GoogleDriveConnectionState.connected ||
          connection ==
              GoogleDriveConnectionState.connectedWithoutRefreshToken) &&
      bootstrapStatus != DatasetBootstrapStatus.ready &&
      bootstrapStatus != DatasetBootstrapStatus.needsReset;

  /// True when this device's local sync state references a dataset that is
  /// gone, or its own log has diverged from the backend — the two states
  /// only [CloudSyncService.resetSyncState] can leave.
  ///
  /// **Deliberately does not require a connection — but that buys less than
  /// an earlier version of this comment claimed (M2.13, review round 3,
  /// finding 5).** It used to read "the state is a fact about local data,
  /// and the reset is a purely local operation that must stay available
  /// offline". Only the second half is true. Both underlying conditions are
  /// *recorded* locally and both are *entered* only by a successful backend
  /// read: `needsReset` by `DatasetBootstrap.verifyDatasetStillExists`
  /// (which deliberately treats a transport error as a transport error, not
  /// as absence), and `deviceLogDiverged` by a sync round that either
  /// pre-flight-compared a tip or attempted an append. So a user whose Drive
  /// folder was deleted while they were offline still sees "Ready" and is
  /// offered no remedy until one sync round completes against a reachable
  /// backend.
  ///
  /// That is not fixable by making the state reachable offline: "the backend
  /// no longer holds my dataset" is not knowable without asking the backend,
  /// and guessing it from a transport failure would tell every user on a
  /// flaky connection that their data had been deleted — a far worse bug
  /// than the one being described. What IS true, and what the offline
  /// tolerance here is actually for: once the state has been recorded, it is
  /// durable, and the remedy stays offered and executable with no connection
  /// at all.
  bool get needsReset =>
      bootstrapStatus == DatasetBootstrapStatus.needsReset ||
      health.issues.any(
        (issue) => issue.kind == SyncHealthIssueKind.deviceLogDiverged,
      );

  /// Whether the reset action is offered at all.
  ///
  /// **Identical to [needsReset], deliberately (M2.13, review finding
  /// F1(a)).** It used to be `bootstrapStatus != none || needsReset` — "there
  /// is local sync state worth clearing" — which offered the action on a
  /// healthy, Ready, multi-device install, on the reasoning that a user who
  /// simply wants to start over should not have to break something first.
  /// That reasoning was wrong in a way that cost real data: a reset makes
  /// every field pristine again, so the round after it re-published this
  /// device's own stale values over every peer edit it had not yet
  /// materialized, dataset-wide (`dataset_reset.dart`'s F1 section). The
  /// recessive-seed mechanism there closes the mechanism; this gate closes
  /// the exposure, and the two are independent on purpose. (An earlier
  /// version of this comment credited "the ordering fix", which was the
  /// round-2 attempt — pull before seed for one round — and was itself
  /// reproduced failing three ways before being removed entirely.)
  ///
  /// **There is no "start over on a healthy dataset" escape hatch**, and its
  /// absence is a decision rather than an omission. A reset is a recovery
  /// operation with real, disclosed costs — a retired identity every peer
  /// keeps a cursor for forever, a backend log that is never reclaimed, a
  /// wiped `sync_conflict_copies` — and none of them buys a user with a
  /// working dataset anything. If one is ever added it needs its own
  /// explicit warning naming those costs, not `cloudSyncResetConfirm`, which
  /// is written for a device that is already broken.
  bool get canReset => needsReset;
}

/// `LastSyncOutcome.detail` sentinels for failures that have a real, known
/// cause rather than an exception to quote.
///
/// Stored instead of a message for the same reason a success stores raw
/// counters: `cloud_sync_screen.dart` re-renders a persisted outcome in
/// whatever language is active *now*, not the one active when it was
/// written. A sentinel round-trips through that; a sentence does not.
const String syncFailureDatasetMissing = 'dataset_missing';

class CloudSyncService {
  CloudSyncService(
    this._databaseService, {
    GoogleDriveAuthService? authService,
    http.Client? httpClient,
    SyncBackend Function()? backendFactory,
  }) : authService = authService ?? GoogleDriveAuthService(),
       _httpClient = httpClient,
       _backendFactory = backendFactory;

  final DatabaseService _databaseService;
  final GoogleDriveAuthService authService;

  /// Injectable for tests. In production this is left null and resolved to
  /// [NetworkProvider.sharedClient] lazily — deliberately lazily, because
  /// `NetworkProvider.init()` runs during app startup and this service may
  /// be constructed (via GetIt) before or after it.
  final http.Client? _httpClient;

  /// Injectable for tests so the whole coordinator can be exercised against
  /// `MockSyncBackend` without any Drive/HTTP involvement.
  final SyncBackend Function()? _backendFactory;

  SyncBackend? _backend;

  /// The Drive backend, constructed once per connected session.
  ///
  /// **Drive API traffic** goes through [NetworkProvider.sharedClient] — the
  /// app's rhttp client — rather than a bare `http.Client()`, so it inherits
  /// the same TLS/timeouts/connection pooling as everything else the app
  /// does. See that member's doc comment for why it is HTTP/1.1, why it is a
  /// delegating wrapper rather than the client object itself, and (
  /// importantly) which `NetworkProvider` behaviours it does NOT provide.
  ///
  /// **Not all Drive-related HTTP goes through rhttp**, and it would be
  /// wrong to imply otherwise:
  ///
  ///  * Drive REST calls (this backend): rhttp.
  ///  * OAuth *refresh* grant (`OAuthTokenManager` -> `NetworkProvider.post`):
  ///    rhttp.
  ///  * OAuth *authorization-code exchange*, i.e. the one-time
  ///    code -> token POST at the end of consent: **a bare `http.Client()`**,
  ///    inside `OAuthService._postWithRetry`. That code path is shared
  ///    verbatim with the MCP OAuth flow and predates this milestone;
  ///    rerouting it would change MCP's behaviour for no benefit to sync, so
  ///    M2.9 deliberately left it alone. It has its own retry/backoff loop.
  SyncBackend get backend {
    final factory = _backendFactory;
    if (factory != null) return _backend ??= factory();
    return _backend ??= GoogleDriveBackend(
      tokenManager: authService.tokenManager,
      httpClient: _httpClient ?? NetworkProvider.sharedClient,
    );
  }

  /// Drops the cached backend so the next call rebuilds it (and re-resolves
  /// the Drive root folder). Called after disconnecting.
  void invalidateBackend() => _backend = null;

  DatasetBootstrap _bootstrapFor(SyncBackend backend) => DatasetBootstrap(
    _databaseService,
    backend,
    DeviceIdentity(_databaseService),
  );

  /// `sync_state` key holding the JSON-encoded [LastSyncOutcome].
  static const String lastSyncStateKey = 'last_sync_outcome';

  Future<CloudSyncStatus> status() async {
    final connection = await authService.connectionState();
    // Reading bootstrap status is purely local (a `sync_state` row) and does
    // not touch the backend, so it is safe to read even while disconnected.
    final bootstrapStatus = await _bootstrapFor(backend).currentStatus();
    return CloudSyncStatus(
      connection: connection,
      bootstrapStatus: bootstrapStatus,
      lastSync: await _readLastSync(),
      health: await readSyncHealth(_databaseService),
    );
  }

  Future<LastSyncOutcome?> _readLastSync() async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: [lastSyncStateKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LastSyncOutcome.fromJsonString(rows.first['value'] as String?);
  }

  Future<void> _writeLastSync(LastSyncOutcome outcome) async {
    final db = await _databaseService.database;
    await db.insert('sync_state', {
      'key': lastSyncStateKey,
      'value': jsonEncode(outcome.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Runs the Google consent flow. Throws on failure/cancellation.
  Future<void> connect() async {
    await authService.connect();
    // A new grant may be for a different Google account; force the backend
    // (and its cached Drive root folder ID) to be rebuilt.
    invalidateBackend();
  }

  Future<void> disconnect() async {
    await authService.disconnect();
    invalidateBackend();
  }

  /// Create-or-join the Drive-side dataset (§ 11.1 via [DatasetBootstrap]).
  /// Idempotent — safe to call again after a failure or a crash partway
  /// through, which is exactly why the UI can offer it as a plain button.
  ///
  /// Encryption is off: no AEAD implementation exists yet, and
  /// `DatasetBootstrap` deliberately throws rather than pretending to verify
  /// a passphrase, so requesting an encrypted dataset here would fail.
  Future<DatasetInitMarker> setUpDataset() async {
    final marker = await _bootstrapFor(backend).bootstrap();
    LoggerService.info(
      'CloudSyncService: dataset ready (created by ${marker.createdByDeviceId} '
      'at ${marker.createdAt.toIso8601String()})',
    );
    return marker;
  }

  /// Clears this device's local sync control plane so it can re-bootstrap
  /// and re-seed from scratch — M2.13's recovery action, and the only way
  /// out of [DatasetBootstrapStatus.needsReset] or a diverged log.
  ///
  /// **Touches no user content**; see `dataset_reset.dart`, which owns both
  /// the operation and the reasoning (including why the device takes a fresh
  /// `device_id`). The caller is responsible for confirming with the user
  /// first — `cloud_sync_screen.dart` does, and the dialog is not optional
  /// decoration. What it must actually warn about is narrower than an earlier
  /// version of this comment claimed ("a reset discards operations this
  /// device minted but never managed to publish" — untrue, since
  /// `DatasetReset` carries the identity of unfinished local work across the
  /// wipe and the drain re-mints it from current row values): the real loss
  /// is an unpublished local **deletion**, which `sync_grave` is cleared for
  /// and whose row is already gone, so it is never published and the entity
  /// comes back on the next pull.
  ///
  /// Afterwards the device reports [DatasetBootstrapStatus.none]: the
  /// settings screen falls back to its ordinary "Set up dataset" step, which
  /// now runs § 11.1's create-or-join against whatever is actually in Drive.
  Future<DatasetResetResult> resetSyncState() async {
    final result = await DatasetReset(_databaseService).reset();
    // The cached backend holds a resolved Drive folder id from the previous
    // dataset. Re-resolving costs one request and removes any chance of the
    // next bootstrap writing its marker into a stale folder handle.
    invalidateBackend();
    return result;
  }

  /// Persists "the dataset is gone" as the last outcome, and refreshes the
  /// health snapshot so the settings screen's dataset card and its health
  /// section agree. Best-effort by the same logic as the failure path below:
  /// reporting must not be able to fail louder than what it reports on.
  Future<void> _reportDatasetMissing() async {
    try {
      await recomputeSyncHealth(_databaseService);
    } catch (e) {
      LoggerService.error(
        'CloudSyncService: sync health recompute failed',
        error: e,
      );
    }
    try {
      await _writeLastSync(
        LastSyncOutcome(
          at: DateTime.now(),
          succeeded: false,
          degraded: true,
          detail: syncFailureDatasetMissing,
        ),
      );
    } catch (_) {}
  }

  /// One full sync round: drain -> seed -> pull -> push. Propagates
  /// `Sync*Exception` and friends uncaught, and the UI shows the message.
  ///
  /// **Two M2.13 exceptions to "just runs the round".** A vanished dataset
  /// is detected up front and reported as [DatasetMissingException] with a
  /// stable [syncFailureDatasetMissing] sentinel rather than an exception
  /// string; and a `ParentMismatch` no longer reaches here at all —
  /// `SyncSession` reports it through the health surface (see its own doc
  /// comment for why a raw thrown exception was not, in fact, "surfacing"
  /// it).
  ///
  /// Records the outcome (success or failure) in `sync_state` before
  /// returning/rethrowing, so the settings screen can show what happened last
  /// even after a restart.
  /// [onSeedProgress] surfaces M2.10's seed scan as it walks. It fires only
  /// on a device that still has a seed scan to do — at most once per sync,
  /// per sync-scope table — so a UI can show real movement during the one
  /// phase that can take a while on a large pre-existing library instead of
  /// a button that looks stuck.
  ///
  /// [onPushProgress] (M2.12) does the same for Phase A, once per commit
  /// confirmed. It is a separate callback rather than a widened
  /// `onSeedProgress` because the two phases count different things
  /// (tables walked vs. commits sent) and a caller that renders one line for
  /// both still needs to know which it is looking at.
  Future<SyncSessionResult> syncNow({
    void Function(SeedScanProgress)? onSeedProgress,
    void Function(PushProgress)? onPushProgress,
  }) async {
    try {
      // M2.13, before anything else: confirm the dataset this device thinks
      // it belongs to still exists. One `readDatasetInitMarker` call, at the
      // only moment the answer can change anything.
      //
      // **Before the session, not after a failure**, because the failure it
      // pre-empts is not clean: a session run against a vanished dataset
      // drains, seeds and pulls (finding nothing) before halting in push,
      // and the seed scan in particular can mint hundreds of operations into
      // the outbox that cannot be published. Checking first turns a long,
      // pointless, confusing round into one round trip and a clear answer.
      final bootstrap = _bootstrapFor(backend);
      final presence = await bootstrap.verifyDatasetStillExists();
      if (presence == DatasetPresence.missing) {
        await _reportDatasetMissing();
        throw const DatasetMissingException();
      }

      // M2.13, review finding F2: the dataset can be perfectly present while
      // THIS device's own log inside it is not, and with an empty outbox no
      // push ever attempts the append that would notice. Checked here, in the
      // same pre-flight the marker read already pays for, and handed to the
      // session so the round's own "nothing diverged" cannot erase it. See
      // `DatasetBootstrap.verifyOwnedLogsStillExist` for the cost bound.
      final preDiverged = await bootstrap.verifyOwnedLogsStillExist();
      if (preDiverged.isNotEmpty) {
        LoggerService.error(
          'CloudSyncService: ${preDiverged.join(', ')} — the backend does not '
          'hold the commit this device recorded as its tip. A sync reset is '
          'required before this device can publish again.',
        );
      }

      final session = SyncSession(_databaseService)
        ..onSeedProgress = onSeedProgress
        ..onPushProgress = onPushProgress;
      final result = await session.run(
        backend,
        preDivergedAuthorIds: preDiverged,
      );
      // Recompute health BEFORE reporting the outcome: "the round finished"
      // and "everything synced" are different questions, and only asking the
      // first is what let four separate silent-data-loss defects each report
      // a clean success.
      //
      // **Guarded, because reporting must never be able to fail the thing it
      // reports on.** This runs a `COUNT(*)` per gated table and several
      // queue queries, all after a round that has already succeeded and
      // already durably committed its work. Left unguarded, a throw here
      // (a locked database, a table dropped by a concurrent migration) would
      // fall into the outer `catch` and record `succeeded: false` for a
      // sync that in fact completed — turning the health surface into a
      // source of false alarms about itself.
      SyncHealth health;
      try {
        health = await recomputeSyncHealth(
          _databaseService,
          failedOperations: result.pull.failedOperations,
          unreadableCommits: result.pull.unreadableCommits,
        );
      } catch (e) {
        LoggerService.error('CloudSyncService: sync health recompute failed', error: e);
        health = SyncHealth.healthy;
      }
      await _writeLastSync(
        LastSyncOutcome(
          at: DateTime.now(),
          succeeded: true,
          degraded: health.isDegraded,
          detail:
              '${result.drain.touchesProcessed}/'
              '${result.seed.operationsSeeded}/'
              '${result.pull.operationsApplied}/'
              '${result.totalPublished}',
        ),
      );
      return result;
    } on DatasetMissingException {
      // Already reported, with a sentinel the settings screen can localize
      // (`_reportDatasetMissing`). Falling into the generic handler below
      // would overwrite that sentinel with this exception's `toString()` —
      // i.e. would put the raw exception text back on the screen, which is
      // the exact defect M2.13 exists to remove.
      rethrow;
    } catch (e) {
      // Best-effort: a failure to record the failure must not replace the
      // real error the caller needs to see.
      try {
        await _writeLastSync(
          LastSyncOutcome(at: DateTime.now(), succeeded: false, detail: '$e'),
        );
      } catch (_) {}
      rethrow;
    }
  }
}
