import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/service_locator.dart';
import '../services/database_service.dart';

class SyncConflictsScreen extends StatefulWidget {
  const SyncConflictsScreen({super.key});

  @override
  State<SyncConflictsScreen> createState() => _SyncConflictsScreenState();
}

class _SyncConflictsScreenState extends State<SyncConflictsScreen> {
  List<Map<String, dynamic>> _conflicts = [];
  bool _isLoading = true;
  int? _resolvingId;

  /// Tables that use composite primary keys instead of a single `id` column.
  /// Mirrors the map in MergeEngine so we can build correct WHERE clauses.
  static const Map<String, List<String>> _compositeKeyTables = {
    'note_tags': ['noteId', 'tagId'],
    'conversation_message_mapping': ['conversationId', 'messageId'],
    'conversation_note_mapping': ['conversationId', 'noteId'],
    'conversation_tags': ['conversationId', 'tagId'],
  };

  @override
  void initState() {
    super.initState();
    _loadConflicts();
  }

  Future<void> _loadConflicts() async {
    setState(() => _isLoading = true);
    try {
      final conflicts = await getIt<DatabaseService>().getSyncConflicts();
      if (mounted) {
        setState(() {
          _conflicts = conflicts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _resolveConflict(int conflictId, String resolution) async {
    setState(() => _resolvingId = conflictId);
    final l10n = AppLocalizations.of(context)!;

    try {
      final db = await getIt<DatabaseService>().database;

      if (resolution == 'remote') {
        final conflict =
            _conflicts.firstWhere((c) => c['id'] == conflictId);
        final tableName = conflict['table_name'] as String;
        final rowId = conflict['row_id'] as String;
        final fieldName = conflict['field_name'] as String;
        final remoteValue = conflict['remote_value'];

        // Build the correct WHERE clause depending on key type.
        final compositeKeys = _compositeKeyTables[tableName];
        String where;
        List<dynamic> whereArgs;

        if (compositeKeys != null) {
          final parts = _splitCompositeRowId(rowId, compositeKeys.length);
          where = compositeKeys.map((k) => '$k = ?').join(' AND ');
          whereArgs = parts;
        } else {
          where = 'id = ?';
          whereArgs = [rowId];
        }

        await db.update(
          tableName,
          {fieldName: remoteValue},
          where: where,
          whereArgs: whereArgs,
        );
      }

      // Mark as resolved
      await db.update(
        'sync_conflicts',
        {'resolved': 1},
        where: 'id = ?',
        whereArgs: [conflictId],
      );

      await _loadConflicts();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(resolution == 'remote'
                ? l10n.syncConflictResolvedRemote
                : l10n.syncConflictResolvedLocal),
            backgroundColor: Colors.green,
          ),
        );
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
        setState(() => _resolvingId = null);
      }
    }
  }

  /// Splits a composite rowId into the expected number of parts.
  /// Mirrors [MergeEngine._splitCompositeRowId].
  List<String> _splitCompositeRowId(String rowId, int partCount) {
    final segments = rowId.split('-');
    if (segments.length <= partCount) return segments;

    final result = <String>[];
    for (var i = 0; i < partCount; i++) {
      if (i == partCount - 1) {
        result.add(segments.sublist(i).join('-'));
      } else {
        result.add(segments[i]);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.syncConflictsTitle),
            if (_conflicts.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_conflicts.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onError,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        leading: const BackButton(),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _conflicts.isEmpty
              ? _buildEmptyState(l10n, theme)
              : _buildConflictList(l10n, theme),
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.syncConflictsEmpty,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConflictList(AppLocalizations l10n, ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _conflicts.length,
      itemBuilder: (context, index) {
        final conflict = _conflicts[index];
        return _buildConflictCard(conflict, l10n, theme);
      },
    );
  }

  Widget _buildConflictCard(
    Map<String, dynamic> conflict,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final conflictId = conflict['id'] as int;
    final tableName = conflict['table_name'] as String;
    final rowId = conflict['row_id'] as String;
    final fieldName = conflict['field_name'] as String;
    final localValue = conflict['local_value'] as String? ?? '';
    final remoteValue = conflict['remote_value'] as String? ?? '';
    final remoteDeviceId = conflict['remote_device_id'] as String;
    final createdAt = conflict['created_at'] as String;
    final isResolving = _resolvingId == conflictId;

    // Shorten device ID for display
    final shortDeviceId = remoteDeviceId.length > 12
        ? '${remoteDeviceId.substring(0, 12)}...'
        : remoteDeviceId;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: table.field
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$tableName.$fieldName',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),

            // Row ID
            Text(
              '${l10n.syncConflictRowId}: $rowId',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),

            // Side-by-side comparison
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Local value
                Expanded(
                  child: _buildValueColumn(
                    label: l10n.syncConflictLocalValue,
                    value: localValue,
                    color: theme.colorScheme.primaryContainer,
                    textColor: theme.colorScheme.onPrimaryContainer,
                    theme: theme,
                  ),
                ),
                const SizedBox(width: 8),
                // Remote value
                Expanded(
                  child: _buildValueColumn(
                    label: l10n.syncConflictRemoteValue,
                    value: remoteValue,
                    color: theme.colorScheme.tertiaryContainer,
                    textColor: theme.colorScheme.onTertiaryContainer,
                    theme: theme,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Metadata row
            Row(
              children: [
                Icon(
                  Icons.devices,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  shortDeviceId,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  Icons.schedule,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  _formatTimestamp(createdAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: isResolving
                      ? null
                      : () => _resolveConflict(conflictId, 'local'),
                  child: Text(l10n.syncConflictKeepLocal),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: isResolving
                      ? null
                      : () => _resolveConflict(conflictId, 'remote'),
                  child: isResolving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(l10n.syncConflictKeepRemote),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildValueColumn({
    required String label,
    required String value,
    required Color color,
    required Color textColor,
    required ThemeData theme,
  }) {
    const int maxDisplayLength = 200;
    final isTruncated = value.length > maxDisplayLength;
    final displayValue =
        isTruncated ? '${value.substring(0, maxDisplayLength)}...' : value;

    return GestureDetector(
      onTap: isTruncated
          ? () => _showFullValueDialog(label, value, theme)
          : null,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              displayValue.isEmpty
                  ? AppLocalizations.of(context)!.syncConflictValueEmpty
                  : displayValue,
              style: theme.textTheme.bodySmall?.copyWith(
                color: displayValue.isEmpty
                    ? theme.colorScheme.onSurfaceVariant
                    : textColor,
                fontStyle:
                    displayValue.isEmpty ? FontStyle.italic : FontStyle.normal,
              ),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
            if (isTruncated)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  AppLocalizations.of(context)!.syncConflictTapToExpand,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showFullValueDialog(String label, String value, ThemeData theme) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: SingleChildScrollView(
          child: SelectableText(
            value,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.close),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(String isoTimestamp) {
    try {
      final dt = DateTime.parse(isoTimestamp);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoTimestamp;
    }
  }
}
