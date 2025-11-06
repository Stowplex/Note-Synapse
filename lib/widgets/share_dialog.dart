import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../services/share_service.dart';

enum _ShareAction {
  pdf,
  text,
  clipboard,
}

class ShareDialog extends StatefulWidget {
  final List<Note> notes;
  final String title;

  const ShareDialog({
    super.key,
    required this.notes,
    required this.title,
  });

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<ShareDialog> {
  bool _includeSubNotesAndLinkedNotes = false;
  _ShareAction? _activeAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isBusy = _activeAction != null;

    return AlertDialog(
      title: Text(l10n.shareDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.shareDialogDescription,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: _includeSubNotesAndLinkedNotes,
                onChanged: isBusy
                    ? null
                    : (value) {
                        setState(() {
                          _includeSubNotesAndLinkedNotes = value ?? false;
                        });
                      },
              ),
              Expanded(
                child: Text(
                  l10n.shareSubNotesAndLinkedNotes,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            l10n.notesToShare(widget.notes.length),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              _buildShareOption(
                icon: Icons.picture_as_pdf,
                label: l10n.shareAsPdf,
                color: theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.primaryContainer,
                action: _ShareAction.pdf,
                onTap: _shareAsPdf,
              ),
              const SizedBox(width: 16),
              _buildShareOption(
                icon: Icons.text_snippet,
                label: l10n.shareAsText,
                color: theme.colorScheme.secondary,
                backgroundColor: theme.colorScheme.secondaryContainer,
                action: _ShareAction.text,
                onTap: _shareAsText,
              ),
              const SizedBox(width: 16),
              _buildShareOption(
                icon: Icons.copy,
                label: l10n.copyToClipboard,
                color: theme.colorScheme.tertiary,
                backgroundColor: theme.colorScheme.tertiaryContainer,
                action: _ShareAction.clipboard,
                onTap: _copyToClipboard,
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: isBusy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }

  Widget _buildShareOption({
    required IconData icon,
    required String label,
    required Color color,
    required Color backgroundColor,
    required _ShareAction action,
    required Future<void> Function() onTap,
  }) {
    final theme = Theme.of(context);
    final isActive = _activeAction == action;
    final isDisabled = _activeAction != null && !isActive;

    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(48),
            onTap: isDisabled ? null : () => _runWithAction(action, onTap),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: backgroundColor,
                border: Border.all(
                  color: isActive ? color : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Center(
                child: isActive
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                        ),
                      )
                    : Icon(
                        icon,
                        size: 28,
                        color: color,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Future<void> _runWithAction(
    _ShareAction action,
    Future<void> Function() task,
  ) async {
    if (_activeAction != null) return;

    setState(() {
      _activeAction = action;
    });

    try {
      await task();
    } finally {
      if (mounted) {
        setState(() {
          _activeAction = null;
        });
      }
    }
  }

  Future<void> _shareAsPdf() async {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    try {
      final screenSize = MediaQuery.of(context).size;
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      final pdfResult = await ShareService.shareAsPdf(
        notes: widget.notes,
        includeSubNotesAndLinkedNotes: _includeSubNotesAndLinkedNotes,
        appProvider: appProvider,
        l10n: l10n,
        pageSize: screenSize,
      );

      if (!mounted) {
        return;
      }

      navigator.pop();

      if (pdfResult != null && pdfResult.cacheFile != null) {
        final fileName = pdfResult.cacheFile!.path.split('/').last;
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.pdfSavedToCache(fileName)),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorGeneratingPdf(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _shareAsText() async {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    try {
      final markdownText = await ShareService.generateMarkdownText(
        notes: widget.notes,
        includeSubNotesAndLinkedNotes: _includeSubNotesAndLinkedNotes,
        appProvider: appProvider,
        l10n: l10n,
      );

      if (mounted) {
        Navigator.of(context).pop();
        await ShareService.shareAsText(markdownText, context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorSharingText(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _copyToClipboard() async {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    try {
      final markdownText = await ShareService.generateMarkdownText(
        notes: widget.notes,
        includeSubNotesAndLinkedNotes: _includeSubNotesAndLinkedNotes,
        appProvider: appProvider,
        l10n: l10n,
      );

      await ShareService.copyToClipboard(markdownText);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.textCopiedToClipboard),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorCopyingToClipboard(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
