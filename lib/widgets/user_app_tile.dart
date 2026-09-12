import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/user_app.dart';
import '../utils/user_app_localization.dart';

/// Presentational tile for a single [UserApp].
///
/// Renders the icon + name + description + type-label combination used by
/// the Insert App picker and, optionally, the main app list. Purely
/// presentational — action-specific UI (rename, delete, etc.) stays with
/// the caller.
class UserAppTile extends StatelessWidget {
  const UserAppTile({
    super.key,
    required this.app,
    this.onTap,
    this.selected = false,
  });

  final UserApp app;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary,
          child: Icon(
            iconForAppType(app.type),
            color: theme.colorScheme.onPrimary,
          ),
        ),
        title: Text(
          app.displayName(context),
          style: const TextStyle(fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (app.displayDescription(context).trim().isNotEmpty)
              Text(
                app.displayDescription(context),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 4),
            Text(
              labelForAppType(l10n, app.type),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

IconData iconForAppType(UserAppType type) {
  switch (type) {
    case UserAppType.noteAction:
      return Icons.apps;
    case UserAppType.aiTool:
      return Icons.smart_toy;
    case UserAppType.normal:
      return Icons.web;
  }
}

String labelForAppType(AppLocalizations l10n, UserAppType type) {
  switch (type) {
    case UserAppType.noteAction:
      return l10n.appTypeNoteAction;
    case UserAppType.aiTool:
      return l10n.appTypeAiTool;
    case UserAppType.normal:
      return l10n.appTypeNormal;
  }
}
