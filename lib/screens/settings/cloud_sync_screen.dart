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
import '../../services/sync/google_drive_auth_service.dart';
import '../../services/sync/sync_health.dart';

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

  Future<void> _setUpDataset() async {
    final l10n = AppLocalizations.of(context)!;
    if (_settingUp) return;
    _beginAction(() => _settingUp = true);
    try {
      await _service.setUpDataset();
      _snack(l10n.cloudSyncDatasetDone);
    } catch (e) {
      _snack(l10n.cloudSyncDatasetError('$e'));
      _setError(l10n.cloudSyncDatasetError('$e'));
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
          if (bootstrapStatus != DatasetBootstrapStatus.ready || canReset)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
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
        _ => l10n.cloudSyncNowError(detail),
      };

  String _describeIssue(AppLocalizations l10n, SyncHealthIssue issue) {
    final line = switch (issue.kind) {
      // M2.13's two: the only kinds that mean "nothing is getting through",
      // and the only ones whose text names the action that fixes them.
      SyncHealthIssueKind.datasetMissing => l10n.cloudSyncHealthDatasetMissing,
      SyncHealthIssueKind.deviceLogDiverged => l10n.cloudSyncHealthLogDiverged(
        issue.count,
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
