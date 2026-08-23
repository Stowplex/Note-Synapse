// Cloud sync settings — M2.9. The first non-debug-gated entry point to the
// sync engine built in M2.1-M2.8.
//
// Deliberately minimal but real: connection state, connect/disconnect, the
// create-or-join dataset step, "Sync now", and the last result or error. No
// encryption/passphrase UI (still deferred), no conflict resolution, no
// backend picker — all of it out of scope for this milestone. All the
// non-widget logic lives in `CloudSyncService`.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/service_locator.dart';
import '../../services/sync/cloud_sync_service.dart';
import '../../services/sync/dataset_bootstrap.dart';
import '../../services/sync/drive_folder_identity.dart';
import '../../services/sync/google_drive_auth_service.dart';
import '../../services/sync/google_drive_backend.dart';
import '../../services/sync/sync_backend_exceptions.dart';
import '../../services/sync/sync_health.dart';

/// What the M2.11 folder dialog collected.
///
/// **Both fields, always — changed in review round 2 (finding F1).** It used
/// to carry exactly one: a name *or* an id. That made "I no longer want the
/// id this device has recorded" inexpressible, so a device welded to the
/// wrong folder had no way back: `setUpDataset(folderName:)` merged the name
/// over the existing identity and went on resolving by the old id.
/// [folderName] is always set (the dialog refuses an empty one); [folderId]
/// is null exactly when the user left the id field empty, which is the
/// explicit "resolve by name instead" answer.
class _FolderChoice {
  const _FolderChoice({required this.folderName, this.folderId});
  final String folderName;
  final String? folderId;
}

class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final CloudSyncService _service = getIt<CloudSyncService>();

  CloudSyncStatus? _status;
  bool _loading = true;
  bool _connecting = false;
  bool _disconnecting = false;
  bool _settingUp = false;
  bool _syncing = false;
  bool _resetting = false;

  /// Message from the most recent action taken *in this screen session*
  /// (dataset setup, or a status-read failure). Sync outcomes themselves are
  /// persisted by `CloudSyncService` and read back via
  /// [CloudSyncStatus.lastSync], so they survive leaving the screen; this
  /// slot only holds the things that are not worth persisting.
  String? _transientMessage;
  bool _transientIsError = false;

  /// Live progress from the phase currently running, shown only while a sync
  /// is actually running. Without it, the FIRST sync of a pre-existing
  /// library — the one that has the most work to do, because every row
  /// predates the mutation-capture triggers and has to be seeded, and then
  /// uploaded — is also the one that shows nothing at all for the longest.
  /// Cleared when the sync ends.
  ///
  /// **One slot for both phases, updated in phase order (M2.12).** It used
  /// to hold only M2.10's seed progress, which meant that once seeding
  /// finished the screen kept showing its final message ("… 19 of 19
  /// tables, 441 operations so far") for the whole of the much longer
  /// upload — the phase that actually took the minutes reported nothing,
  /// and the frozen line read as a hang. Push now writes over the same slot
  /// as it goes.
  String? _syncProgress;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await _service.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _transientMessage = '$e';
        _transientIsError = true;
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Clears the banner at the START of every action.
  ///
  /// Set only on failure, so a later success leaves it null and the card
  /// falls through to the persisted sync outcome. Clearing on failure-only
  /// (or not at all) was the earlier bug: an error from one run survived a
  /// subsequent successful one, leaving the screen permanently accusing the
  /// user of a problem they had already fixed.
  void _beginAction(VoidCallback setBusy) {
    setState(() {
      _transientMessage = null;
      _transientIsError = false;
      setBusy();
    });
  }

  Future<void> _connect() async {
    final l10n = AppLocalizations.of(context)!;
    if (_connecting) return;
    _beginAction(() => _connecting = true);
    try {
      await _service.connect();
      _snack(l10n.cloudSyncConnected);
    } catch (e) {
      _snack(l10n.cloudSyncConnectError('$e'));
      _setError(l10n.cloudSyncConnectError('$e'));
    } finally {
      if (mounted) setState(() => _connecting = false);
      await _refreshStatus();
    }
  }

  Future<void> _disconnect() async {
    final l10n = AppLocalizations.of(context)!;
    // Guarded exactly like the other three actions: without this, a
    // double-tap opens two confirmation dialogs, and confirming both runs
    // disconnect twice against a token store the first call already
    // cleared.
    if (_disconnecting || _connecting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudSyncDisconnect),
        content: Text(l10n.cloudSyncDisconnectConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.cloudSyncDisconnect),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _beginAction(() => _disconnecting = true);
    try {
      await _service.disconnect();
      _snack(l10n.cloudSyncDisconnected);
    } catch (e) {
      _setError('$e');
      _snack('$e');
    } finally {
      if (mounted) setState(() => _disconnecting = false);
      await _refreshStatus();
    }
  }

  /// M2.11's folder dialog: name the folder, or paste the folder ID from a
  /// device that is already syncing.
  ///
  /// **Review round 2, finding F1: this is no longer a one-time question.**
  /// It used to be shown only while `folder.folderId == null`, on the
  /// reasoning that once an ID exists the folder is addressed by it forever
  /// and asking again would change nothing. The second half is true and the
  /// conclusion did not follow: the ID that gets recorded can be the *wrong*
  /// one — a device that failed to discover its peer's folder and created
  /// its own, or a valid-but-wrong pasted ID — and that gate is what made
  /// both states permanent. A reset did not help either, because a reset
  /// deliberately preserves the ID, so the setup that follows it skipped the
  /// dialog and silently built yet another folder. The dialog is now offered
  /// wherever a folder decision can still take effect: any not-yet-`ready`
  /// device (including one that has just been reset), and — via
  /// [_changeFolder] — a `ready` one that needs to be re-pointed.
  Future<_FolderChoice?> _askForFolder({
    required String initialName,
    required String initialId,
  }) => showDialog<_FolderChoice>(
    context: context,
    builder: (context) =>
        _FolderSetupDialog(initialName: initialName, initialId: initialId),
  );

  /// Collects a folder choice and, when the user typed an ID this device does
  /// not already hold, shows them what is actually inside it before anything
  /// is recorded. Returns null when the user backs out of either step.
  ///
  /// **The preview step exists because "valid" and "correct" are different
  /// questions** (finding F1). `adoptRootFolder` can only check that an ID
  /// resolves, is not trashed, and carries the dataset-root tag — all true
  /// of somebody else's sync folder, or of the user's own abandoned one. The
  /// dataset marker is the only thing that says *which* dataset is in there,
  /// and reading it while cancelling is still free is the difference between
  /// a mistake that is visible and one that is discovered later as an empty
  /// library.
  Future<_FolderChoice?> _chooseFolder(AppLocalizations l10n) async {
    final current = _status?.folder ?? DriveFolderIdentity.empty;
    final choice = await _askForFolder(
      initialName: current.folderName ?? defaultDriveRootFolderName,
      initialId: current.folderId ?? '',
    );
    if (choice == null || !mounted) return null;

    final id = choice.folderId;
    if (id == null || id == current.folderId) return choice;

    DriveRootFolderPreview preview;
    try {
      preview = await _service.inspectFolder(id);
    } on SyncRootFolderMissingException {
      _snack(l10n.cloudSyncFolderNotFound);
      _setError(l10n.cloudSyncFolderNotFound);
      return null;
    } catch (e) {
      _snack(l10n.cloudSyncDatasetError('$e'));
      _setError(l10n.cloudSyncDatasetError('$e'));
      return null;
    }
    if (!mounted) return null;

    final folderName = preview.identity.folderName ?? choice.folderName;
    final marker = preview.marker;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudSyncFolderPreviewTitle),
        content: SingleChildScrollView(
          child: Text(
            marker == null
                ? l10n.cloudSyncFolderPreviewEmpty(folderName)
                : l10n.cloudSyncFolderPreviewHolds(
                    folderName,
                    _formatTime(marker.createdAt),
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.cloudSyncFolderPreviewUse),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return null;
    return choice;
  }

  /// Runs create-or-join with [choice], and reports created-vs-joined.
  ///
  /// Shared by [_setUpDataset] and [_changeFolder] so the two cannot drift in
  /// how they translate a folder decision into `CloudSyncService` arguments —
  /// in particular the `forgetRecordedFolderId` rule, which is the whole of
  /// "the user emptied the ID field" and is easy to get subtly wrong twice.
  Future<void> _applyFolderChoice(
    AppLocalizations l10n,
    _FolderChoice? choice,
  ) async {
    final marker = await _service.setUpDataset(
      folderName: choice?.folderName,
      folderId: choice?.folderId,
      forgetRecordedFolderId: choice != null && choice.folderId == null,
    );
    _snack(l10n.cloudSyncDatasetDone);
    // Created-vs-joined, spelled out rather than left to be inferred from
    // a folder that happens to be empty. A device that meant to join and
    // silently created its own instead is the one failure this flow can
    // produce that otherwise looks like complete success.
    final created = await _service.datasetWasCreatedByThisDevice(marker);
    _setNotice(
      created ? l10n.cloudSyncDatasetCreated : l10n.cloudSyncDatasetJoined,
    );
  }

  /// Reports a failure from the dataset-setup path. Split out for the same
  /// reason [_applyFolderChoice] is: two entry points, one translation.
  void _reportSetUpFailure(
    AppLocalizations l10n,
    Object error,
    _FolderChoice? choice,
  ) {
    final String message;
    if (error is SyncAmbiguousRootFolderException) {
      message = l10n.cloudSyncFolderAmbiguous(
        error.candidateCount,
        error.folderName,
      );
    } else if (error is SyncRootFolderMissingException) {
      // During setup this can only come from validating a pasted folder ID
      // (`adoptRootFolder`); a vanished folder on an already-set-up device
      // is reported through M2.13's missing-dataset path instead, never
      // here. The `else` branch is defensive, not expected.
      message = choice?.folderId != null
          ? l10n.cloudSyncFolderNotFound
          : l10n.cloudSyncDatasetError('$error');
    } else {
      message = l10n.cloudSyncDatasetError('$error');
    }
    _snack(message);
    _setError(message);
  }

  Future<void> _setUpDataset() async {
    final l10n = AppLocalizations.of(context)!;
    if (_settingUp || _resetting || _syncing) return;
    // **Busy first, dialog second (review round 2).** The guard above used to
    // be checked before the dialog while the flag was only set after it, so
    // `busy` was false for the whole time the dialog was open — invisible
    // only because a modal barrier happened to be covering the buttons it
    // should have been disabling.
    _beginAction(() => _settingUp = true);
    _FolderChoice? choice;
    try {
      // Offered on every device that is not already `ready` — which now
      // includes a device that has just been reset, the case that previously
      // skipped the dialog and silently built a second folder.
      if (_status?.bootstrapStatus != DatasetBootstrapStatus.ready) {
        choice = await _chooseFolder(l10n);
        if (choice == null || !mounted) return;
      }
      await _applyFolderChoice(l10n, choice);
    } catch (e) {
      _reportSetUpFailure(l10n, e, choice);
    } finally {
      if (mounted) setState(() => _settingUp = false);
      await _refreshStatus();
    }
  }

  /// Re-points an already-`ready` device at a different folder — review
  /// round 2, finding F1.
  ///
  /// **Why this needs its own action rather than reusing "Set up dataset".**
  /// That button is deliberately hidden once the device is `ready`, and the
  /// state this exists for looks exactly like success: name discovery found
  /// nothing, so this device created its own folder, reported "Created a new
  /// sync folder", and went green. Nothing else on the screen offers a way
  /// out of it — "Reset sync" is offered only for a missing dataset or a
  /// diverged log — so the honest fallback was reinstalling the app, while
  /// `google_drive_backend.dart` claimed the paste-an-ID remedy was "already
  /// on the same screen". It is now.
  ///
  /// **It resets first, and the confirmation says so.** Leaving one dataset
  /// for another means this device's recorded tips, frontiers and publish
  /// intents describe commits the new folder does not have; without the
  /// reset the next push would halt on `ParentMismatch` and the user would
  /// be sent to "Reset sync" by an alarming error instead. The wording is a
  /// separate string from `cloudSyncResetConfirm` on purpose —
  /// `CloudSyncStatus.canReset` argues at length that a reset offered to a
  /// working device needs a warning naming its own costs, not one written
  /// for a device that is already broken.
  Future<void> _changeFolder() async {
    final l10n = AppLocalizations.of(context)!;
    if (_settingUp || _resetting || _syncing) return;
    _beginAction(() => _settingUp = true);
    _FolderChoice? choice;
    try {
      choice = await _chooseFolder(l10n);
      if (choice == null || !mounted) return;

      final current = _status?.folder ?? DriveFolderIdentity.empty;

      // **Compare against what the dialog was PRE-FILLED with, not against
      // the raw stored values** (M2.11 review round 3, finding 1). Those are
      // not the same on an upgraded pre-M2.11 install, where neither
      // `drive_root_folder_*` row exists: `current.folderName` is null while
      // `_chooseFolder` pre-fills `defaultDriveRootFolderName`, so accepting
      // the untouched defaults compared unequal and read as "changed" —
      // retiring the device identity, wiping the control plane and
      // re-seeding, for a user who edited nothing and then rejoined the same
      // folder by name. That is the "reset offered to a working device"
      // hazard `CloudSyncStatus.canReset` exists to forbid, reached in one
      // tap, on precisely the upgrade population this milestone serves — and
      // the confirmation shown first ("This device leaves the dataset it is
      // in now") was false for that path.
      final prefilledName = current.folderName ?? defaultDriveRootFolderName;
      final unchanged = choice.folderId != null
          ? choice.folderId == current.folderId
          : current.folderId == null && choice.folderName == prefilledName;
      if (unchanged) {
        // A name edit made while an id is recorded is deliberately inert —
        // once `folderId` is set the name is never read for resolution, and
        // `_findRootFolder` overwrites the stored copy from Drive on the next
        // round. Say so rather than dropping the edit in silence (finding 3):
        // an editable field whose edit vanishes without acknowledgement reads
        // as a bug even when the behaviour is correct.
        if (choice.folderId != null &&
            choice.folderName.trim().isNotEmpty &&
            choice.folderName.trim() != current.folderName) {
          _snack(l10n.cloudSyncFolderNameFollowsDrive);
        }
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.cloudSyncFolderChangeTitle),
          content: SingleChildScrollView(
            child: Text(l10n.cloudSyncFolderChangeConfirm),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.cloudSyncFolderChange),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      // **Not atomic, and the intermediate state is deliberately a benign
      // one.** If the create-or-join below fails (the pasted folder is
      // suddenly unreachable, the network drops), the reset has already
      // happened and this device lands in `bootstrapStatus == none` with its
      // previous folder identity still recorded — i.e. exactly the ordinary
      // "not set up yet" state, from which the screen offers "Set up
      // dataset", which now re-opens this same dialog pre-filled. The error
      // is reported either way. Making it atomic would mean deferring the
      // reset until after a successful join, which is worse: the join is the
      // step that writes the new identity, so a failure *there* would leave
      // the device pointed at the new folder with the old dataset's tips.
      await _service.resetSyncState();
      await _applyFolderChoice(l10n, choice);
    } catch (e) {
      _reportSetUpFailure(l10n, e, choice);
    } finally {
      if (mounted) setState(() => _settingUp = false);
      await _refreshStatus();
    }
  }

  /// M2.13's recovery action. Guarded against a double tap the same way
  /// `_disconnect` is (two dialogs, two resets, the second minting a second
  /// fresh identity over the first).
  ///
  /// The confirmation is not boilerplate: this is the one action in the app
  /// that discards local sync operations, and it is offered precisely when
  /// the user is already alarmed by an error, so it has to state plainly
  /// what it does NOT touch as well as what it does.
  Future<void> _resetSyncState() async {
    final l10n = AppLocalizations.of(context)!;
    if (_resetting || _syncing || _settingUp) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudSyncResetTitle),
        content: SingleChildScrollView(child: Text(l10n.cloudSyncResetConfirm)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.cloudSyncReset),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _beginAction(() => _resetting = true);
    try {
      await _service.resetSyncState();
      _snack(l10n.cloudSyncResetDone);
    } catch (e) {
      _snack(l10n.cloudSyncResetError('$e'));
      _setError(l10n.cloudSyncResetError('$e'));
    } finally {
      if (mounted) setState(() => _resetting = false);
      await _refreshStatus();
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _transientMessage = message;
      _transientIsError = true;
    });
  }

  /// Same slot as [_setError], rendered as ordinary text rather than an
  /// error — for something the user should read but has not gone wrong
  /// (M2.11's created-vs-joined line).
  void _setNotice(String message) {
    if (!mounted) return;
    setState(() {
      _transientMessage = message;
      _transientIsError = false;
    });
  }

  Future<void> _syncNow() async {
    final l10n = AppLocalizations.of(context)!;
    if (_syncing) return;
    _beginAction(() {
      _syncing = true;
      _syncProgress = null;
    });
    try {
      final result = await _service.syncNow(
        onSeedProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _syncProgress = l10n.cloudSyncSeeding(
              progress.table,
              progress.tablesDone,
              progress.tablesTotal,
              progress.operationsSeededSoFar,
            );
          });
        },
        onPushProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _syncProgress = l10n.cloudSyncPushing(
              progress.commitsSent,
              progress.commitsTotal,
              progress.operationsPublished,
            );
          });
        },
      );
      // The outcome itself is persisted by CloudSyncService and re-read by
      // the _refreshStatus() in `finally`; the snackbar is just the
      // immediate acknowledgement.
      _snack(
        l10n.cloudSyncNowResult(
          result.drain.touchesProcessed,
          result.seed.operationsSeeded,
          result.pull.operationsApplied,
          result.totalPublished,
        ),
      );
    } on DatasetMissingException {
      // Not shown as an exception: `CloudSyncService` has already recorded
      // the stable sentinel and flipped the bootstrap status, so the
      // `_refreshStatus()` below repaints the dataset card as "Sync dataset
      // is missing" with the reset action on it. A snackbar quoting the
      // exception would be the old behaviour in a new place.
      _snack(l10n.cloudSyncDatasetMissing);
    } on SyncAmbiguousRootFolderException catch (e) {
      // **Review round 2, finding F2.** This is where an install that
      // predates M2.11 actually hits an ambiguous folder name: it is already
      // `ready`, so it never enters `_setUpDataset` (which had the only
      // handler) and never sees a "Set up dataset" button. Without this
      // clause the snackbar AND the persisted outcome were the raw
      // `toString()`, re-rendered on every visit, while the one piece of
      // actionable text the app owns was unreachable. `CloudSyncService` has
      // also recorded it durably, so the `_refreshStatus()` below repaints
      // the same sentence into the sync card and the health section — which
      // is what makes it survive leaving the screen.
      _snack(l10n.cloudSyncFolderAmbiguous(e.candidateCount, e.folderName));
    } catch (e) {
      _snack(l10n.cloudSyncNowError('$e'));
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _syncProgress = null;
        });
      }
      await _refreshStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.cloudSync)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshStatus,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _sectionLabel(theme, l10n.cloudSyncAccountSection),
                  _accountCard(l10n, theme),
                  const SizedBox(height: 16),
                  _sectionLabel(theme, l10n.cloudSyncDatasetSection),
                  _datasetCard(l10n, theme),
                  const SizedBox(height: 16),
                  _sectionLabel(theme, l10n.cloudSyncNowSection),
                  _syncCard(l10n, theme),
                  const SizedBox(height: 16),
                  _noticeCard(l10n, theme),
                ],
              ),
            ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
    ),
  );

  Widget _accountCard(AppLocalizations l10n, ThemeData theme) {
    final connection =
        _status?.connection ?? GoogleDriveConnectionState.disconnected;

    final (
      String title,
      String detail,
      IconData icon,
      Color color,
    ) = switch (connection) {
      GoogleDriveConnectionState.notConfigured => (
        l10n.cloudSyncStateNotConfigured,
        l10n.cloudSyncStateNotConfiguredDetail,
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      GoogleDriveConnectionState.disconnected => (
        l10n.cloudSyncStateDisconnected,
        l10n.cloudSyncStateDisconnectedDetail,
        Icons.cloud_off,
        theme.colorScheme.onSurfaceVariant,
      ),
      GoogleDriveConnectionState.connected => (
        l10n.cloudSyncStateConnected,
        l10n.cloudSyncStateConnectedDetail,
        Icons.cloud_done,
        theme.colorScheme.primary,
      ),
      GoogleDriveConnectionState.connectedWithoutRefreshToken => (
        l10n.cloudSyncStateNoRefreshToken,
        l10n.cloudSyncStateNoRefreshTokenDetail,
        Icons.cloud_queue,
        theme.colorScheme.error,
      ),
    };

    final isConnected =
        connection == GoogleDriveConnectionState.connected ||
        connection == GoogleDriveConnectionState.connectedWithoutRefreshToken;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(icon, color: color),
            title: Text(title),
            subtitle: Text(detail),
          ),
          if (connection != GoogleDriveConnectionState.notConfigured)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isConnected)
                    TextButton(
                      onPressed: (_connecting || _disconnecting)
                          ? null
                          : _disconnect,
                      child: Text(l10n.cloudSyncDisconnect),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: (_connecting || _disconnecting)
                        ? null
                        : _connect,
                    icon: _connecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link),
                    label: Text(
                      _connecting
                          ? l10n.cloudSyncConnecting
                          : l10n.cloudSyncConnect,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _datasetCard(AppLocalizations l10n, ThemeData theme) {
    final bootstrapStatus =
        _status?.bootstrapStatus ?? DatasetBootstrapStatus.none;
    final connected =
        _status?.canSync == true || _status?.needsDatasetSetup == true;

    // M2.13: `needsReset` is why this card can no longer be trusted to read
    // "Ready" forever. The status it renders used to be a purely local flag
    // that nothing re-checked, so a user whose Drive folder had been deleted
    // was told their device had joined a dataset that did not exist while
    // every sync failed.
    final (
      String title,
      String detail,
      IconData icon,
    ) = switch (bootstrapStatus) {
      DatasetBootstrapStatus.none => (
        l10n.cloudSyncDatasetPending,
        l10n.cloudSyncDatasetPendingDetail,
        Icons.dataset_outlined,
      ),
      DatasetBootstrapStatus.bootstrapping => (
        l10n.cloudSyncDatasetInProgress,
        l10n.cloudSyncDatasetInProgressDetail,
        Icons.hourglass_bottom,
      ),
      DatasetBootstrapStatus.ready => (
        l10n.cloudSyncDatasetReady,
        l10n.cloudSyncDatasetReadyDetail,
        Icons.dataset,
      ),
      DatasetBootstrapStatus.needsReset => (
        l10n.cloudSyncDatasetMissing,
        l10n.cloudSyncDatasetMissingDetail,
        Icons.cloud_off,
      ),
    };

    final isMissing = bootstrapStatus == DatasetBootstrapStatus.needsReset;
    // Offered ONLY in the two states a reset is the remedy for — dataset
    // missing, or one of this device's own logs diverged. It used to be
    // offered whenever there was any local sync state to clear, including on
    // a healthy multi-device install; see `CloudSyncStatus.canReset` for the
    // data loss that made reachable, and for why there is no "start over"
    // escape hatch behind this button.
    final canReset = _status?.canReset == true;
    final showSetUp =
        bootstrapStatus != DatasetBootstrapStatus.ready && !isMissing;
    // Review round 2, finding F1: the one state where a folder decision can
    // still be wrong and "Set up dataset" is deliberately gone. Not offered
    // in the missing state, where the remedy is the reset already on this
    // row and a second button would only compete with it.
    final showChangeFolder =
        bootstrapStatus == DatasetBootstrapStatus.ready && connected;
    final busy = _settingUp || _resetting || _syncing;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(
              icon,
              color: isMissing
                  ? theme.colorScheme.error
                  : bootstrapStatus == DatasetBootstrapStatus.ready
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            title: Text(title),
            subtitle: Text(detail),
          ),
          _folderIdentitySection(l10n, theme),
          if (bootstrapStatus != DatasetBootstrapStatus.ready ||
              canReset ||
              showChangeFolder)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (showChangeFolder)
                    TextButton(
                      onPressed: busy ? null : _changeFolder,
                      child: Text(l10n.cloudSyncFolderChange),
                    ),
                  if (canReset)
                    TextButton(
                      // Deliberately NOT gated on `connected`: the reset is a
                      // purely local operation, and the state it recovers
                      // from is one a user may well hit while offline.
                      onPressed: busy ? null : _resetSyncState,
                      child: Text(
                        _resetting
                            ? l10n.cloudSyncResetting
                            : l10n.cloudSyncReset,
                      ),
                    ),
                  // Only between two buttons that both render — this row can
                  // legitimately hold one button or none.
                  if (canReset && showSetUp) const SizedBox(width: 8),
                  // Hidden in the missing state: `setUpDataset` now throws
                  // there rather than quietly creating a second dataset the
                  // stale local logs still could not push to, so offering it
                  // would offer a button that only produces an error.
                  if (showSetUp)
                    FilledButton.icon(
                      // Requires a connection: the bootstrap sequence talks to
                      // Drive (read marker / create marker / re-read).
                      onPressed: (!connected || busy) ? null : _setUpDataset,
                      icon: _settingUp
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.playlist_add_check),
                      label: Text(
                        _settingUp
                            ? l10n.cloudSyncDatasetSettingUp
                            : l10n.cloudSyncDatasetSetUp,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// M2.11: which Drive folder this dataset lives in.
  ///
  /// The ID is [SelectableText] deliberately — it is the input to setting up
  /// a second device, and the only join mechanism that does not depend on
  /// `drive.file` letting one device see another's folder in a listing (see
  /// `google_drive_backend.dart`). A user who cannot copy it out of this
  /// screen has no way to use it.
  /// **Review round 2: it also renders for an UPGRADED install, which has
  /// neither row recorded.** The ID is written lazily, by the backend, the
  /// first time it resolves the folder — so an install that predates M2.11
  /// showed no folder section at all until its first sync on the new build,
  /// which is exactly when a user goes looking for the "copy this ID to set
  /// up device 2" affordance the release notes promise. It now says the
  /// folder's (default) name and that the ID is not recorded yet, rather
  /// than saying nothing and looking like a missing feature.
  Widget _folderIdentitySection(AppLocalizations l10n, ThemeData theme) {
    final folder = _status?.folder ?? DriveFolderIdentity.empty;
    final bootstrapStatus =
        _status?.bootstrapStatus ?? DatasetBootstrapStatus.none;
    final isSetUp =
        bootstrapStatus == DatasetBootstrapStatus.ready ||
        bootstrapStatus == DatasetBootstrapStatus.needsReset;
    if (folder.isEmpty && !isSetUp) return const SizedBox.shrink();
    // A set-up device with no recorded name is a pre-M2.11 install, whose
    // folder genuinely carries the hardcoded default — see
    // `defaultDriveRootFolderName` for why that literal is not localized.
    final name =
        folder.folderName ?? (isSetUp ? defaultDriveRootFolderName : null);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name != null)
            SelectableText(l10n.cloudSyncFolderName(name), style: style),
          if (folder.folderId != null) ...[
            SelectableText(
              l10n.cloudSyncFolderId(folder.folderId!),
              style: style,
            ),
            Text(l10n.cloudSyncFolderIdHint, style: style),
            // Created-vs-joined, as a STANDING line rather than the one-shot
            // transient it used to be (M2.11 review round 3, finding 5). This
            // is the signal that distinguishes "joined the other device's
            // dataset" from "silently made a second one" — the whole
            // diagnosability story for the unverified `drive.file`
            // cross-device listing question — and it was previously lost on
            // the next tap and on any navigate-away-and-return, while three
            // doc comments cited it in the present tense as if it stayed put.
            //
            // Inside the recorded-id branch deliberately: the sentence is
            // about which Drive folder holds this dataset, so it has nothing
            // to say before an id exists, and keeping it here costs no height
            // on a screen driven by a non-Drive backend.
            if (_status?.datasetCreatedHere == true)
              Text(l10n.cloudSyncFolderCreatedHere, style: style),
          ] else if (isSetUp)
            Text(l10n.cloudSyncFolderIdPending, style: style),
        ],
      ),
    );
  }

  Widget _syncCard(AppLocalizations l10n, ThemeData theme) {
    final canSync = _status?.canSync == true;
    final lastSync = _status?.lastSync;

    // A transient message (dataset-setup failure, status-read failure) takes
    // precedence over the persisted sync outcome: it is newer, and it is what
    // the user just triggered.
    String? body;
    var isError = false;
    if (_syncing && _syncProgress != null) {
      // Live progress outranks everything while the sync is in flight: it is
      // the only thing on this card describing what is happening right now.
      body = _syncProgress;
    } else if (_transientMessage != null) {
      body = _transientMessage;
      isError = _transientIsError;
    } else if (lastSync != null) {
      body = lastSync.succeeded
          ? _formatCounters(l10n, lastSync.detail)
          : _formatFailure(l10n, lastSync.detail);
      isError = !lastSync.succeeded;
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: _syncing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            title: Text(
              _syncing ? l10n.cloudSyncNowRunning : l10n.cloudSyncNow,
            ),
            subtitle: Text(
              lastSync == null
                  ? l10n.cloudSyncNeverRun
                  : l10n.cloudSyncLastRun(_formatTime(lastSync.at)),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: canSync && !_syncing,
            onTap: (canSync && !_syncing) ? _syncNow : null,
          ),
          if (body != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SelectableText(
                body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isError
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          // The degraded state: the round finished, but something did not
          // sync. Rendered from the persisted health snapshot rather than
          // from this session's in-memory result, because the transient
          // signals (a parked operation, a skipped table) are non-empty for
          // exactly one round while the underlying problem persists.
          if (!_syncing) _healthSection(l10n, theme),
        ],
      ),
    );
  }

  /// Renders [SyncHealth] — the "finished, but not everything got through"
  /// state. Empty (renders nothing) when the device is healthy.
  Widget _healthSection(AppLocalizations l10n, ThemeData theme) {
    final health = _status?.health;
    if (health == null || !health.isDegraded) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_outlined,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.cloudSyncDegraded,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final issue in health.issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                _describeIssue(l10n, issue),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A failed round's stored `detail`. Known causes are stored as stable
  /// sentinels (`syncFailureDatasetMissing`) rather than as messages, so
  /// they re-render in the language active now; anything else is an
  /// exception string, which is at least honest even when it is ugly.
  String _formatFailure(AppLocalizations l10n, String detail) =>
      switch (detail) {
        syncFailureDatasetMissing => l10n.cloudSyncDatasetMissingDetail,
        // M2.11 review round 2: the count and the name live in
        // `CloudSyncStatus.folderAmbiguity` rather than in the sentinel,
        // because they are facts about the CURRENT Drive contents and the
        // sentinel is a fact about one past round. If the condition has
        // since cleared, the generic rendering is the honest fallback.
        syncFailureFolderAmbiguous =>
          _folderAmbiguityMessage(l10n) ?? l10n.cloudSyncNowError(detail),
        _ => l10n.cloudSyncNowError(detail),
      };

  String? _folderAmbiguityMessage(AppLocalizations l10n) {
    final ambiguity = _status?.folderAmbiguity;
    if (ambiguity == null) return null;
    return l10n.cloudSyncFolderAmbiguous(
      ambiguity.candidateCount,
      ambiguity.folderName,
    );
  }

  String _describeIssue(AppLocalizations l10n, SyncHealthIssue issue) {
    final line = switch (issue.kind) {
      // M2.13's two: the only kinds that mean "nothing is getting through",
      // and the only ones whose text names the action that fixes them.
      SyncHealthIssueKind.datasetMissing => l10n.cloudSyncHealthDatasetMissing,
      SyncHealthIssueKind.deviceLogDiverged => l10n.cloudSyncHealthLogDiverged(
        issue.count,
      ),
      // M2.11 review round 2: `count` is how many folders answered to the
      // name and `detail` is the name — the same two values the setup path
      // renders, from the same string, so the two surfaces cannot drift.
      SyncHealthIssueKind.rootFolderAmbiguous => l10n.cloudSyncFolderAmbiguous(
        issue.count,
        issue.detail,
      ),
      // The one kind whose subjects are raw table names: rendered as
      // localized, non-technical labels rather than schema jargon. A user
      // reading "subnotes (1, unresolvable column noteId)" learns nothing
      // they can act on.
      SyncHealthIssueKind.tablesNotSynced => l10n
          .cloudSyncHealthTablesNotSynced(
            issue.count,
            issue.subjects.map((t) => _tableLabel(l10n, t)).join(', '),
          ),
      SyncHealthIssueKind.operationsFailed =>
        l10n.cloudSyncHealthOperationsFailed(issue.count, issue.detail),
      SyncHealthIssueKind.waitingOnMissingEntity =>
        l10n.cloudSyncHealthWaitingOnEntity(issue.count, issue.detail),
      SyncHealthIssueKind.waitingOnMissingDot =>
        l10n.cloudSyncHealthWaitingOnDot(issue.count, issue.detail),
      SyncHealthIssueKind.membershipNotBuilt =>
        l10n.cloudSyncHealthMembershipNotBuilt(issue.count, issue.detail),
      // The one backlog kind with NO remedy — and the string deliberately
      // names none, which is what this comment used to get wrong (M2.14
      // review round 3, finding M3). It claimed the remedy was "on THIS
      // device… deleting that duplicate is what unblocks it". Both halves are
      // false: the entity cannot be built because a duplicate local row holds
      // its identity (two installs of the same bundled mini app), and
      // `user_apps` is hard-delete guarded — so deleting it writes a
      // tombstone and leaves the row, and its `uuid`, occupying the UNIQUE
      // index. Verified: after the delete the queue and the health snapshot
      // are byte-identical. The entry is retryable mechanically; no user
      // action available today reaches that state, and real reconciliation is
      // M4's identity mapping. See `SyncHealthIssueKind.entityIdentityConflict`.
      SyncHealthIssueKind.entityIdentityConflict =>
        l10n.cloudSyncHealthIdentityConflict(issue.count, issue.detail),
    };
    final since = issue.oldestEntryAt;
    if (since == null) return line;
    return '$line — ${l10n.cloudSyncHealthSince(_formatTime(since))}';
  }

  /// Localized, user-facing name for a sync-scope table. Falls back to the
  /// raw name for anything not in this list — better a table name than a
  /// crash or a blank.
  String _tableLabel(AppLocalizations l10n, String table) => switch (table) {
    'subnotes' => l10n.syncItemsSubnotes,
    'relationships' => l10n.syncItemsRelationships,
    'attachments' => l10n.syncItemsAttachments,
    'conversation_attachments' => l10n.syncItemsConversationAttachments,
    'user_apps' => l10n.syncItemsUserApps,
    'app_revisions' => l10n.syncItemsAppRevisions,
    'user_app_libraries' => l10n.syncItemsUserAppLibraries,
    'user_app_library_dependencies' =>
      l10n.syncItemsUserAppLibraryDependencies,
    _ => table,
  };

  /// `CloudSyncService` stores a successful round's counters as
  /// `drained/seeded/pulled/pushed` (see [LastSyncOutcome.detail]) rather
  /// than as a pre-localized sentence, so that a stored outcome renders in
  /// whatever language is active *now*, not the one that was active when it
  /// was written. This turns it back into that sentence.
  ///
  /// Outcomes written before M2.10 have three parts (`drained/pulled/pushed`
  /// — there was no seed phase yet); those still render, with a seeded count
  /// of zero, rather than falling back to raw digits.
  String _formatCounters(AppLocalizations l10n, String detail) {
    final parts = detail.split('/');
    if (parts.length != 3 && parts.length != 4) return detail;
    final counters = parts.map(int.tryParse).toList();
    if (counters.any((c) => c == null)) return detail;
    if (counters.length == 3) {
      return l10n.cloudSyncNowResult(counters[0]!, 0, counters[1]!, counters[2]!);
    }
    return l10n.cloudSyncNowResult(
      counters[0]!,
      counters[1]!,
      counters[2]!,
      counters[3]!,
    );
  }

  static String _formatTime(DateTime time) =>
      time.toLocal().toString().split('.').first;

  Widget _noticeCard(AppLocalizations l10n, ThemeData theme) => Card(
    color: theme.colorScheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.cloudSyncEncryptionNotice,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    ),
  );
}

/// M2.11's setup dialog: name the folder, or paste the folder ID from a
/// device that is already syncing.
///
/// **A `StatefulWidget` rather than an inline `AlertDialog` closure, for one
/// concrete reason.** The obvious shape — build two `TextEditingController`s
/// beside the `showDialog` call and dispose them in a `finally` — disposes
/// them the instant the dialog's future completes, while the route is still
/// running its exit animation and the `TextField`s are still mounted. That
/// throws "A TextEditingController was used after being disposed" on the
/// very next frame, in debug builds and in widget tests alike. Owning the
/// controllers in a `State` and disposing them in [dispose] hands that
/// lifetime to the framework, which is the only thing that actually knows
/// when the fields are gone.
class _FolderSetupDialog extends StatefulWidget {
  const _FolderSetupDialog({required this.initialName, this.initialId = ''});

  final String initialName;

  /// The folder ID this device currently has recorded, pre-filled so the
  /// dialog can be re-opened as an EDIT rather than only as a first-time
  /// question (review round 2, finding F1). Accepting it unchanged is a
  /// no-op; replacing it re-points the device; **emptying it** is the
  /// explicit "forget this ID, look the folder up by name again" that no
  /// caller could previously express.
  final String initialId;

  @override
  State<_FolderSetupDialog> createState() => _FolderSetupDialogState();
}

class _FolderSetupDialogState extends State<_FolderSetupDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _idController = TextEditingController(
    text: widget.initialId,
  );

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    super.dispose();
  }

  void _submit(AppLocalizations l10n) {
    final id = _idController.text.trim();
    final name = _nameController.text.trim();
    // The name is required even when an ID is given: it is what a folder
    // created later (after this dataset's folder is deleted, say) will be
    // called, and losing the user's choice there is the "silently lost"
    // failure `dataset_reset.dart` preserves the name to avoid.
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cloudSyncFolderNameRequired)),
      );
      return;
    }
    // An ID is an identity and a name is a guess, so an ID still wins for
    // *resolution* whenever both are filled in.
    Navigator.pop(
      context,
      _FolderChoice(folderName: name, folderId: id.isEmpty ? null : id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.cloudSyncFolderDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.cloudSyncFolderNameLabel,
              ),
            ),
            const SizedBox(height: 6),
            Text(l10n.cloudSyncFolderNameHelp, style: theme.textTheme.bodySmall),
            const SizedBox(height: 20),
            TextField(
              controller: _idController,
              decoration: InputDecoration(
                labelText: l10n.cloudSyncFolderJoinLabel,
              ),
            ),
            const SizedBox(height: 6),
            Text(l10n.cloudSyncFolderJoinHelp, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => _submit(l10n),
          child: Text(l10n.cloudSyncFolderContinue),
        ),
      ],
    );
  }
}
