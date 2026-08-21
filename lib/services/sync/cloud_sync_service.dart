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
import 'device_identity.dart';
import 'google_drive_auth_service.dart';
import 'google_drive_backend.dart';
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
  bool get needsDatasetSetup =>
      (connection == GoogleDriveConnectionState.connected ||
          connection ==
              GoogleDriveConnectionState.connectedWithoutRefreshToken) &&
      bootstrapStatus != DatasetBootstrapStatus.ready;
}

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

  /// One full sync round: drain -> seed -> pull -> push. Propagates every exception
  /// (`Sync*Exception`, `PushParentMismatchException`, ...) uncaught —
  /// `SyncSession` is explicit that a parent mismatch must surface as a real
  /// error rather than be retried silently, and the UI shows the message.
  ///
  /// Records the outcome (success or failure) in `sync_state` before
  /// returning/rethrowing, so the settings screen can show what happened last
  /// even after a restart.
  /// [onSeedProgress] surfaces M2.10's seed scan as it walks. It fires only
  /// on a device that still has a seed scan to do — at most once per sync,
  /// per sync-scope table — so a UI can show real movement during the one
  /// phase that can take a while on a large pre-existing library instead of
  /// a button that looks stuck.
  Future<SyncSessionResult> syncNow({
    void Function(SeedScanProgress)? onSeedProgress,
  }) async {
    try {
      final session = SyncSession(_databaseService)
        ..onSeedProgress = onSeedProgress;
      final result = await session.run(backend);
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
              '${result.pull.commitsApplied}/'
              '${result.totalPublished}',
        ),
      );
      return result;
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
