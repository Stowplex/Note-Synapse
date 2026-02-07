import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'sync_setup_screen.dart';
import '../services/service_locator.dart';
import '../services/sync/android_saf_sync_provider.dart';
import '../services/sync/folder_sync_provider.dart';
import '../services/sync/sync_service.dart';
import '../services/sync/device_identity_service.dart';
import '../services/database_service.dart';
import 'sync_conflicts_screen.dart';

class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  bool _isSyncing = false;
  SyncResult? _lastSyncResult;
  DateTime? _lastSyncTime;
  int _pendingChangesCount = 0;
  int _unresolvedConflictsCount = 0;
  String? _currentCipher;
  bool _isEncrypted = false;
  bool _isConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final identity = DeviceIdentityService();
      final isEncrypted = await identity.isEncryptionEnabled();
      final cipherId = await identity.getCipherId();
      final providerType = await identity.getSyncProviderType();

      int pendingCount = 0;
      int conflictsCount = 0;

      try {
        final db = getIt<DatabaseService>();
        final pendingChanges = await db.getPendingSyncChanges();
        pendingCount = pendingChanges.length;

        final conflicts = await db.getSyncConflicts();
        conflictsCount = conflicts.length;
      } catch (_) {
        // Tables may not exist yet
      }

      if (mounted) {
        setState(() {
          _isEncrypted = isEncrypted;
          _currentCipher = cipherId;
          _pendingChangesCount = pendingCount;
          _unresolvedConflictsCount = conflictsCount;
          _isConfigured = providerType != null;
        });
      }
    } catch (_) {
      // Ignore errors during status load
    }
  }

  /// Ensures the sync service has a configured provider by restoring
  /// the persisted provider type and URI from secure storage.
  Future<void> _ensureProviderConfigured() async {
    final syncService = getIt<SyncService>();
    if (syncService.isConfigured) return;

    final identity = DeviceIdentityService();
    final providerType = await identity.getSyncProviderType();
    final providerUri = await identity.getSyncProviderUri();

    if (providerType == null || providerUri == null) {
      throw StateError(
        'Sync provider not configured. Please set up sync first.',
      );
    }

    if (providerType == 'saf') {
      syncService.configure(
        provider: AndroidSafSyncProvider(treeUri: providerUri),
      );
    } else {
      syncService.configure(
        provider: FolderSyncProvider(rootPath: providerUri),
      );
    }
  }

  Future<void> _syncNow() async {
    setState(() => _isSyncing = true);
    try {
      await _ensureProviderConfigured();
      final result = await getIt<SyncService>().sync();
      if (mounted) {
        setState(() {
          _lastSyncResult = result;
          _lastSyncTime = DateTime.now();
        });
        await _loadStatus();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _resetSync() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.syncResetTitle),
        content: Text(l10n.syncResetBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.syncResetConfirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await getIt<SyncService>().resetSyncFromThisDevice();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.syncResetSuccess),
              backgroundColor: Colors.green,
            ),
          );
          await _loadStatus();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString()),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _disableSync() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.syncDisableTitle),
        content: Text(l10n.syncDisableBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.syncDisableConfirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final db = getIt<DatabaseService>();
        await db.disableSyncTriggers();

        final identity = DeviceIdentityService();
        await identity.clearSyncIdentity();

        // Reset in-memory service state
        getIt<SyncService>().resetConfiguration();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.syncDisableSuccess),
              backgroundColor: Colors.green,
            ),
          );
          // Stay on screen, just reload status to unlock "Set Up Sync" UI
          await _loadStatus();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString()),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.syncSettingsTitle),
        leading: const BackButton(),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Section 1: Sync Status
              _buildSectionTitle(l10n.syncStatusSection),
              const SizedBox(height: 8),
              _buildStatusCard(l10n, theme),
              const SizedBox(height: 16),

              // Section 2: Sync Action (Sync Now OR Set Up)
              SizedBox(
                height: 48,
                child: _isConfigured
                    ? FilledButton.icon(
                        onPressed: _isSyncing ? null : _syncNow,
                        icon: _isSyncing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.sync),
                        label: Text(
                          _isSyncing ? l10n.syncSyncing : l10n.syncNow,
                        ),
                      )
                    : FilledButton.icon(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SyncSetupScreen(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.settings_suggest),
                        label: Text(l10n.syncSetupTitle),
                      ),
              ),

              // Sync result summary
              if (_lastSyncResult != null) ...[
                const SizedBox(height: 8),
                _buildSyncResultCard(l10n, theme),
              ],
              const SizedBox(height: 24),

              // Section 3: Encryption
              _buildSectionTitle(l10n.syncEncryption),
              const SizedBox(height: 8),
              _buildEncryptionCard(l10n, theme),
              const SizedBox(height: 24),

              // Section 4: Danger Zone
              if (_isConfigured) ...[
                _buildSectionTitle(l10n.syncDangerZone),
                const SizedBox(height: 8),
                _buildDangerCard(l10n, theme),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    );
  }

  Widget _buildStatusCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Last synced
            Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  _lastSyncTime != null
                      ? l10n.syncLastSynced(_formatTimestamp(_lastSyncTime!))
                      : l10n.syncNeverSynced,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Pending changes
            Row(
              children: [
                Icon(
                  Icons.upload_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.syncPendingChanges(_pendingChangesCount),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Unresolved conflicts
            InkWell(
              onTap: _unresolvedConflictsCount > 0
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SyncConflictsScreen(),
                        ),
                      ).then((_) => _loadStatus());
                    }
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Icon(
                    _unresolvedConflictsCount > 0
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_outline,
                    size: 20,
                    color: _unresolvedConflictsCount > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.syncUnresolvedConflicts(_unresolvedConflictsCount),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _unresolvedConflictsCount > 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                  if (_unresolvedConflictsCount > 0)
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncResultCard(AppLocalizations l10n, ThemeData theme) {
    final result = _lastSyncResult!;
    return Card(
      color: result.success
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : theme.colorScheme.errorContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Icon(
              result.success ? Icons.check_circle : Icons.error_outline,
              size: 20,
              color: result.success
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.syncResultSummary(
                  result.opsPulled,
                  result.opsPushed,
                  result.conflictsCreated,
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEncryptionCard(AppLocalizations l10n, ThemeData theme) {
    final cipherDisplay = _isConfigured
        ? (_isEncrypted
              ? (_currentCipher == 'aes-256-gcm'
                    ? 'AES-256-GCM'
                    : _currentCipher == 'xchacha20-poly1305'
                    ? 'XChaCha20-Poly1305'
                    : _currentCipher ?? l10n.syncEncryptionUnknown)
              : l10n.syncEncryptionNone)
        : l10n.syncNotConfigured;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isEncrypted ? Icons.lock : Icons.lock_open,
                  size: 20,
                  color: _isEncrypted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.syncCurrentCipher(cipherDisplay),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDangerCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Reset Sync
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.restart_alt, color: theme.colorScheme.error),
              title: Text(
                l10n.syncResetFromDevice,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              subtitle: Text(
                l10n.syncResetFromDeviceDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: _resetSync,
            ),
            Divider(color: theme.colorScheme.error.withValues(alpha: 0.2)),
            // Disable Sync
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.sync_disabled,
                color: theme.colorScheme.error,
              ),
              title: Text(
                l10n.syncDisable,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              subtitle: Text(
                l10n.syncDisableDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: _disableSync,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) {
      return AppLocalizations.of(context)!.syncJustNow;
    } else if (diff.inMinutes < 60) {
      return AppLocalizations.of(context)!.syncMinutesAgo(diff.inMinutes);
    } else if (diff.inHours < 24) {
      return AppLocalizations.of(context)!.syncHoursAgo(diff.inHours);
    } else {
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }
}
