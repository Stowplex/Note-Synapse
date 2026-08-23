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
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import '../logger_service.dart';
import '../network_provider.dart';
import 'dataset_bootstrap.dart';
import 'dataset_reset.dart';
import 'device_identity.dart';
import 'drive_folder_identity.dart';
import 'google_drive_auth_service.dart';
import 'google_drive_backend.dart';
import 'push_phase.dart';
import 'seed_scanner.dart';
import 'sync_health.dart';
import 'sync_backend.dart';
import 'sync_backend_exceptions.dart';
import 'sync_crypto.dart';
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

/// Thrown when an encrypted dataset is opened without a passphrase.
///
/// Its own type so the settings screen can ask for one rather than
/// rendering a raw exception — the pattern M2.13 and M2.11 both had to fix
/// after shipping the raw string first.
class PassphraseRequiredException implements Exception {
  const PassphraseRequiredException();
  @override
  String toString() =>
      'PassphraseRequiredException: this dataset is encrypted and needs its '
      'passphrase';
}

/// Everything the settings screen needs to render, in one snapshot so the UI
/// never has to make two independent async reads that could disagree.
class CloudSyncStatus {
  const CloudSyncStatus({
    required this.connection,
    required this.bootstrapStatus,
    this.lastSync,
    this.health = SyncHealth.healthy,
    this.folder = DriveFolderIdentity.empty,
    this.folderAmbiguity,
    this.datasetCreatedHere = false,
  });

  final GoogleDriveConnectionState connection;
  final DatasetBootstrapStatus bootstrapStatus;
  final LastSyncOutcome? lastSync;

  /// M2.11: which Drive folder this dataset lives in, read from `sync_state`
  /// — no backend call, so the settings screen can render it offline like
  /// everything else in this snapshot.
  ///
  /// The **id** is the part that matters to a user: it is what a second
  /// device pastes to join this exact dataset, and it is the only join
  /// mechanism that does not depend on the unverified `drive.file`
  /// cross-device listing question (see `google_drive_backend.dart`). The
  /// name is shown alongside it so the folder is findable by eye in Drive.
  final DriveFolderIdentity folder;

  /// **M2.11 review round 2 (finding F2).** Set when this device cannot
  /// resolve its root folder because several folders answer to the name and
  /// it has no recorded id — the state an install that predates M2.11 lands
  /// in, where `bootstrapStatus` is still `ready` and nothing else on this
  /// snapshot says anything is wrong.
  ///
  /// Carried alongside [health] (which reports the same condition) rather
  /// than derived from it, because the two are used differently: the health
  /// list is the "what is not syncing" surface, while this is what
  /// `cloud_sync_screen.dart` needs in order to render the last *failed*
  /// round's stored sentinel as the localized sentence with the count and
  /// the name in it.
  final RootFolderAmbiguity? folderAmbiguity;

  /// Whether this device CREATED the dataset it is in, rather than joining
  /// one — durable, so it survives leaving the screen. See
  /// `CloudSyncService._readDatasetCreatedHere` for why a transient was not
  /// good enough: this is the signal that distinguishes "joined device 1's
  /// dataset" from "silently made a second one", which is the whole
  /// diagnosability story for the unverified `drive.file` cross-device
  /// listing question.
  final bool datasetCreatedHere;

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
  ///
  /// **M2.11 review round 2 added exactly one such path, under exactly that
  /// condition.** `CloudSyncScreen._changeFolder` resets a `ready` device —
  /// but only as the unavoidable second half of *leaving one dataset for
  /// another*, which the screen has to offer because a device that failed to
  /// discover its peer's folder is Ready, healthy-looking, and alone (finding
  /// F1). It is not reachable as "start over here": it runs only after the
  /// user has chosen a folder identity that differs from the recorded one,
  /// and it carries `cloudSyncFolderChangeConfirm`, its own warning naming
  /// its own costs, precisely as the paragraph above requires. [canReset]
  /// itself is unchanged — the "Reset sync" button is still offered only for
  /// the two states a reset is the remedy for.
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

/// **M2.11 review round 2.** The round could not resolve the dataset's root
/// folder because more than one folder answers to its name. The count and
/// the name are not in the sentinel — they live in
/// [CloudSyncStatus.folderAmbiguity], which is durable for exactly as long
/// as the condition is.
const String syncFailureFolderAmbiguous = 'folder_ambiguous';

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
      folderIdentityStore: folderStore,
    );
  }

  /// M2.11's durable folder identity, in `sync_state`. Owned here rather
  /// than inside `GoogleDriveBackend` because the settings screen reads it
  /// for display and writes the user's chosen name to it at setup, neither
  /// of which involves the backend at all.
  late final DriveFolderIdentityStore folderStore =
      SyncStateDriveFolderIdentityStore(_databaseService);

  /// Drops the cached backend so the next call rebuilds it (and re-resolves
  /// the Drive root folder). Called after disconnecting.
  void invalidateBackend() => _backend = null;

  DatasetBootstrap _bootstrapFor(
    SyncBackend backend, {
    SyncCrypto? crypto,
  }) => DatasetBootstrap(
    _databaseService,
    backend,
    DeviceIdentity(_databaseService),
    // **M3.5 fills in the hook M2.3 deliberately left throwing.** That
    // placeholder refused to claim a passphrase had been verified when
    // nothing had verified it — the one behaviour that mattered while the
    // KDF did not exist. The real verifier is a single closure so exactly
    // one place decides: derive with the dataset's own recorded salt, open
    // the canary, and let a mismatch be a WRONG PASSPHRASE rather than an
    // integrity failure.
    passphraseVerifier: crypto == null
        ? null
        : (marker) async {
            try {
              await crypto.verifyCanary(marker.passphraseCanary!);
              return true;
            } on WrongPassphraseException {
              return false;
            }
          },
  );

  /// `sync_state` key holding the JSON-encoded [LastSyncOutcome].
  static const String lastSyncStateKey = 'last_sync_outcome';

  /// The dataset's key material for this session, resolved by
  /// [setUpDataset]. Memory-only and never persisted — § 8.5's whole point
  /// is that the database is exactly what a backup or a stolen device
  /// exposes, so a key living in it would make the passphrase decorative.
  DatasetCrypto _crypto = const DatasetCrypto.plaintext();

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
      folder: await folderStore.read(),
      folderAmbiguity: await _readFolderAmbiguity(),
      datasetCreatedHere: await _readDatasetCreatedHere(),
    );
  }

  /// Whether the dataset in the recorded folder was created BY this device
  /// rather than joined — read from a durable `sync_state` row, so it is a
  /// standing property of the screen rather than a message.
  ///
  /// **This was a one-shot transient until M2.11 review round 3 (finding
  /// 5).** It lived in a `State` field, so it was lost on the next tap and on
  /// any genuine navigate-away-and-return — while three separate doc comments
  /// (`google_drive_backend.dart`'s header, `_createRootFolder`, and
  /// [datasetWasCreatedByThisDevice]) cited it in the present tense as *the*
  /// diagnosable signal for the milestone's central unverified assumption. If
  /// `drive.file` cross-device listing turns out not to work, a second device
  /// silently creates its own dataset, and the only thing distinguishing that
  /// from a successful join was a line the user saw once. Persisted here so
  /// the claim those comments make is true.
  ///
  /// Written by [setUpDataset], which already holds the marker; not derived
  /// at read time, because deriving it means a backend call and [status] is
  /// deliberately local-only so the screen renders offline.
  Future<bool> _readDatasetCreatedHere() async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [datasetCreatedHereStateKey],
      limit: 1,
    );
    return rows.isNotEmpty && rows.first['value'] == '1';
  }

  Future<RootFolderAmbiguity?> _readFolderAmbiguity() async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [rootFolderAmbiguityStateKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RootFolderAmbiguity.fromJsonString(rows.first['value'] as String?);
  }

  /// Records an ambiguous folder name durably and refreshes the health
  /// snapshot, so the condition survives leaving the screen — M2.11 review
  /// round 2, finding F2.
  Future<void> _reportFolderAmbiguity(
    SyncAmbiguousRootFolderException e,
  ) async {
    final db = await _databaseService.database;
    await db.insert('sync_state', {
      'key': rootFolderAmbiguityStateKey,
      'value': RootFolderAmbiguity(
        folderName: e.folderName,
        candidateCount: e.candidateCount,
      ).toJsonString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _recomputeHealthBestEffort();
  }

  /// Clears a previously-recorded ambiguity. Called from every path that
  /// *proves* it is over — a completed sync round, or a completed
  /// create-or-join — rather than on a screen refresh, which proves nothing.
  ///
  /// **Recomputes health, symmetrically with the record path** (M2.11 review
  /// round 3, finding 4). `recomputeSyncHealth` persists a snapshot; deleting
  /// the durable row without re-deriving that snapshot left the issue latched
  /// on. Concretely: ambiguity recorded, the user removes the duplicate in
  /// Drive as instructed, the next round clears the row and then fails for an
  /// unrelated reason (the connection drops) — the outer `catch` recomputes
  /// nothing, so the screen kept telling a user who had already fixed Drive
  /// to go fix Drive, and did so until some later round succeeded in full. A
  /// health issue that latches on is the mirror image of one that never
  /// fires, and this surface exists because of the second.
  Future<void> _clearFolderAmbiguity() async {
    final db = await _databaseService.database;
    final removed = await db.delete(
      'sync_state',
      where: 'key = ?',
      whereArgs: [rootFolderAmbiguityStateKey],
    );
    if (removed > 0) await _recomputeHealthBestEffort();
  }

  Future<void> _recomputeHealthBestEffort() async {
    try {
      await recomputeSyncHealth(_databaseService);
    } catch (e) {
      LoggerService.error(
        'CloudSyncService: sync health recompute failed',
        error: e,
      );
    }
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
  ///
  /// **A residual M2.11 makes concrete rather than introduces, recorded here
  /// because this is the method a maintainer will be looking at when they
  /// hit it: reconnecting as a DIFFERENT Google account is reported to the
  /// user as "your sync dataset is missing".** The recorded folder id
  /// belongs to the previous account, so `files.get` on it 404s under the
  /// new grant, `verifyDatasetStillExists` sees no marker, and the settings
  /// screen offers a reset — which is in fact the right remedy (the reset
  /// re-runs create-or-join, the preserved id 404s once more, and a fresh
  /// folder is built in the new account under the same chosen name). So it
  /// recovers correctly; it just says something alarming and slightly untrue
  /// on the way. The obvious "fix" — clearing the folder identity on
  /// disconnect — is worse: a user who disconnects and reconnects the SAME
  /// account (the common case, e.g. re-granting after a revoked refresh
  /// token) would fall back to name resolution and lose exactly the
  /// rename-tolerance this milestone bought. Distinguishing the two needs
  /// the account identity, which nothing in this app records today.
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
  ///
  /// **M2.11's two optional inputs, and the asymmetry between them.**
  /// [folderName] is a *creation-time convenience*: it names the folder this
  /// device would create, and is the discovery key if this device has to
  /// find one by name. It is recorded and then stops mattering — nothing
  /// resolves by it once a folder id exists, so renaming the folder in Drive
  /// afterwards is harmless. [folderId] is the opposite: it is an identity,
  /// it is validated against Drive before anything is written down, and it
  /// is the join path that works whether or not `drive.file` lets a second
  /// device see the first device's folder in a listing (the open question
  /// documented in `google_drive_backend.dart`).
  ///
  /// Passing both prefers [folderId] — an explicit identity beats a guess.
  ///
  /// ---------------------------------------------------------------------
  /// **Review round 2, finding F1: this is also the RE-point path, and it
  /// has to be able to undo a previous answer.**
  /// ---------------------------------------------------------------------
  /// As shipped, every route that could change the recorded folder was
  /// welded shut once any id existed: the settings screen only opened its
  /// folder dialog while `folderId == null`, a reset deliberately preserves
  /// the id, and `DriveFolderIdentity.copyWith` could not express "clear
  /// it". So a device that failed to discover its peer's folder and created
  /// its own — the exact outcome the milestone's fail-loud argument is built
  /// around — had no remedy but reinstalling, and a valid-but-wrong pasted
  /// id was permanent. Three rules make it reversible:
  ///
  ///  * [folderId] **different** from the recorded one is adopted, which
  ///    validates against Drive first (see [GoogleDriveBackend.adoptRootFolder]).
  ///  * [folderId] **equal** to the recorded one is left exactly as it is
  ///    and NOT re-validated. This is not an optimization: it is what the
  ///    re-opened dialog submits when the user accepts what it was pre-filled
  ///    with, and re-validating there would break the one flow that must
  ///    work — a reset taken *because* the folder was deleted, where the
  ///    recorded id 404s on purpose and `initializeDatasetOnce` is entitled
  ///    to rebuild under the preserved name.
  ///  * [forgetRecordedFolderId] clears the id and falls back to name
  ///    resolution. Only the folder dialog passes it, and only when the user
  ///    emptied the id field — an explicit "this is not my folder", which is
  ///    the one thing no caller could previously say.
  /// **[passphrase] (M3.5) turns encryption on for a NEW dataset, and opens
  /// an existing encrypted one.** Requirement 5 makes the choice immutable
  /// once the dataset exists, and this signature is what enforces that: the
  /// marker is written once by whichever device creates the dataset, and
  /// every later device only ever reads it. Passing a passphrase to a
  /// plaintext dataset, or omitting one for an encrypted dataset, is
  /// reported rather than silently ignored.
  Future<DatasetInitMarker> setUpDataset({
    String? folderName,
    String? folderId,
    bool forgetRecordedFolderId = false,
    String? passphrase,
  }) async {
    final trimmedId = folderId?.trim();
    final trimmedName = folderName?.trim();
    final current = await folderStore.read();
    final wantsId = trimmedId != null && trimmedId.isNotEmpty;

    if (wantsId && trimmedId != current.folderId) {
      final target = backend;
      if (target is! GoogleDriveBackend) {
        throw StateError(
          'CloudSyncService: joining by folder id is a Google Drive concept; '
          'the active backend is ${target.runtimeType}',
        );
      }
      // Validates first and throws `SyncRootFolderMissingException` if the
      // pasted id resolves to nothing — deliberately BEFORE it is recorded,
      // so a typo cannot become a stored handle that quietly turns into a
      // brand-new empty folder at the next bootstrap.
      final adopted = await target.adoptRootFolder(trimmedId);
      LoggerService.info(
        'CloudSyncService: adopted existing Drive sync folder '
        '${adopted.folderId} ("${adopted.folderName}")',
      );
    } else if (!wantsId && forgetRecordedFolderId && current.folderId != null) {
      LoggerService.info(
        'CloudSyncService: forgetting recorded Drive folder id '
        '${current.folderId}; resolving by name again',
      );
      await folderStore.write(
        DriveFolderIdentity(folderName: trimmedName ?? current.folderName),
      );
    } else if (trimmedName != null &&
        trimmedName.isNotEmpty &&
        trimmedName != current.folderName) {
      // Only load-bearing before a folder exists; once `folderId` is set the
      // backend never reads the name back for resolution. Recorded anyway so
      // the settings screen shows what the user chose, and so a folder
      // rebuilt after a deletion carries it.
      await folderStore.write(current.copyWith(folderName: trimmedName));
    }

    // Encryption is decided ONCE, by whoever creates the dataset. A new
    // dataset gets a fresh salt and a canary sealed under the derived key;
    // an existing one is opened with the salt it already recorded.
    final existing = await backend.readDatasetInitMarker();
    final wantsEncryption = passphrase != null && passphrase.isNotEmpty;
    SyncCrypto? crypto;
    Uint8List? salt;
    Uint8List? canary;
    if (existing == null && wantsEncryption) {
      salt = SyncCrypto.newSalt();
      crypto = await SyncCrypto.deriveFromPassphrase(
        passphrase: passphrase,
        salt: salt,
      );
      canary = await crypto.buildCanary();
    } else if (existing != null && existing.encryptionEnabled) {
      if (!wantsEncryption) throw const PassphraseRequiredException();
      crypto = await SyncCrypto.deriveFromPassphrase(
        passphrase: passphrase,
        salt: existing.kdfSalt!,
      );
      // Verified by `DatasetBootstrap` through the injected verifier below,
      // which is where the create-or-join sequence already checks it — one
      // check, in the step § 11.1 assigns it to, rather than a second
      // independent one here that could drift from it.
    }

    final marker = await _bootstrapFor(backend, crypto: crypto).bootstrap(
      encryptionEnabled: existing == null && wantsEncryption,
      kdfSalt: salt,
      passphraseCanary: canary,
    );
    _crypto = crypto == null
        ? const DatasetCrypto.plaintext()
        : DatasetCrypto(crypto);
    // Reaching here means the root folder resolved to exactly one thing, so
    // any recorded ambiguity is over — proved, not assumed (M2.11 review
    // round 2, finding F2).
    await _clearFolderAmbiguity();
    // Durable created-vs-joined (finding 5). Written on every completed
    // create-or-join, including a re-point to a different folder, so it
    // always describes the dataset this device is CURRENTLY in.
    final createdHere = await datasetWasCreatedByThisDevice(marker);
    await (await _databaseService.database).insert('sync_state', {
      'key': datasetCreatedHereStateKey,
      'value': createdHere ? '1' : '0',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _recomputeHealthBestEffort();
    LoggerService.info(
      'CloudSyncService: dataset ready (created by ${marker.createdByDeviceId} '
      'at ${marker.createdAt.toIso8601String()})',
    );
    return marker;
  }

  /// What a pasted folder id actually points at, **without recording
  /// anything** — the "look before you commit" half of finding F1.
  ///
  /// The settings screen calls this between the folder dialog and
  /// [setUpDataset], so a user pointing a device at a folder can see whose
  /// dataset is in it (or that it holds none yet) while cancelling is still
  /// free. Throws exactly what [setUpDataset] would have thrown for an
  /// unusable id, at the same moment the user would otherwise have hit it.
  Future<DriveRootFolderPreview> inspectFolder(String folderId) async {
    final target = backend;
    if (target is! GoogleDriveBackend) {
      throw StateError(
        'CloudSyncService: inspecting a folder id is a Google Drive concept; '
        'the active backend is ${target.runtimeType}',
      );
    }
    return target.inspectRootFolder(folderId);
  }

  /// Whether [marker] describes a dataset THIS device created, as opposed to
  /// one it joined — M2.11.
  ///
  /// **Not cosmetic.** A second device that fails to discover the first
  /// device's folder does not error; it creates its own and reports a
  /// perfectly successful setup against an empty dataset. That is the exact
  /// "looks fine, is not" failure the join path has to be diagnosable
  /// against, so the settings screen says which of the two happened and,
  /// when it created one, points at the folder id as the way to join for
  /// real instead.
  Future<bool> datasetWasCreatedByThisDevice(DatasetInitMarker marker) async {
    final deviceId = await DeviceIdentity(_databaseService).ensureDeviceId();
    return marker.createdByDeviceId == deviceId;
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
    // The cached backend holds an in-memory resolved Drive folder id.
    // Dropping it forces the next call to re-read the durable identity and
    // re-verify it against Drive — which is the whole point after a reset,
    // since the commonest reason to reset is that the folder is gone (M2.11:
    // the id survives the wipe, so this re-verification is what turns a
    // preserved-but-dead handle into a fresh folder at the next bootstrap).
    invalidateBackend();
    return result;
  }

  /// Persists "the dataset is gone" as the last outcome, and refreshes the
  /// health snapshot so the settings screen's dataset card and its health
  /// section agree. Best-effort by the same logic as the failure path below:
  /// reporting must not be able to fail louder than what it reports on.
  Future<void> _reportDatasetMissing() async {
    await _recomputeHealthBestEffort();
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

      // The root folder resolved to exactly one thing on the pre-flight, so
      // a previously-recorded ambiguity is over (M2.11 review round 2).
      // Cleared before the round rather than after, so the health recompute
      // below sees the cleared state in the same pass.
      await _clearFolderAmbiguity();

      final session = SyncSession(_databaseService, crypto: _crypto)
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
    } on SyncAmbiguousRootFolderException catch (e) {
      // **M2.11 review round 2, finding F2.** This is not a hypothetical
      // branch: an install that predates M2.11 has no recorded folder id, so
      // its first sync on the new build resolves by name — and a second
      // folder answering to that name (a Drive cleanup, an earlier run, the
      // leftover of a create/create race) lands here. That device is
      // `ready`, is not `needsReset`, and is offered no reset, so before
      // this handler existed the snackbar AND the persisted outcome were
      // both the raw exception string, re-rendered on every visit, with the
      // one piece of actionable text the app owns (`cloudSyncFolderAmbiguous`)
      // never shown. Recorded as a durable condition on M2.10's health spine
      // plus a stable sentinel, exactly like the missing-dataset state.
      await _reportFolderAmbiguity(e);
      try {
        await _writeLastSync(
          LastSyncOutcome(
            at: DateTime.now(),
            succeeded: false,
            degraded: true,
            detail: syncFailureFolderAmbiguous,
          ),
        );
      } catch (_) {}
      rethrow;
    } on SyncRootFolderMissingException catch (e) {
      // The root folder was definitively gone at a point where the pre-flight
      // could not have seen it — either because the pre-flight was skipped
      // (a device that never finished bootstrap is not re-checked, correctly)
      // or because the folder vanished mid-round. `SyncRootFolderMissingException`'s
      // own doc calls this the case the user "ordinarily never sees"; when
      // they do see it, it means precisely what `DatasetMissingException`
      // means, so it is reported as that rather than quoted at them.
      LoggerService.error(
        'CloudSyncService: the recorded Drive root folder (${e.folderId}) is '
        'gone; reporting it as a missing dataset',
      );
      try {
        // Re-runs M2.13's own check so a locally-'ready' device is durably
        // moved to `needsReset` and gets the reset button, rather than this
        // path inventing a second status transition of its own. Best-effort:
        // it makes one more backend call, and failing it must not replace
        // the answer we already have.
        await _bootstrapFor(backend).verifyDatasetStillExists();
      } catch (_) {}
      await _reportDatasetMissing();
      throw const DatasetMissingException();
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
