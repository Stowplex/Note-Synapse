import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../services/share_service.dart';

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
  bool _isGenerating = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return AlertDialog(
      title: Text(l10n.shareDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.shareDialogDescription,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Checkbox(
                value: _includeSubNotesAndLinkedNotes,
                onChanged: (value) {
                  setState(() {
                    _includeSubNotesAndLinkedNotes = value ?? false;
                  });
                },
              ),
              Expanded(
                child: Text(
                  l10n.shareSubNotesAndLinkedNotes,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Notes to share: ${widget.notes.length}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        ElevatedButton.icon(
          onPressed: _isGenerating ? null : _shareAsText,
          icon: _isGenerating 
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.text_snippet),
          label: Text(l10n.shareAsText),
        ),
        ElevatedButton.icon(
          onPressed: _isGenerating ? null : _copyToClipboard,
          icon: _isGenerating 
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.copy),
          label: Text(l10n.copyToClipboard),
        ),
      ],
    );
  }

  Future<void> _shareAsText() async {
    if (_isGenerating) return;
    
    setState(() {
      _isGenerating = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      final l10n = AppLocalizations.of(context)!;
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
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorSharingText(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _copyToClipboard() async {
    if (_isGenerating) return;
    
    setState(() {
      _isGenerating = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      final l10n = AppLocalizations.of(context)!;
      final markdownText = await ShareService.generateMarkdownText(
        notes: widget.notes,
        includeSubNotesAndLinkedNotes: _includeSubNotesAndLinkedNotes,
        appProvider: appProvider,
        l10n: l10n,
      );

      await ShareService.copyToClipboard(markdownText);

      if (mounted) {
        Navigator.of(context).pop();
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.textCopiedToClipboard),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorCopyingToClipboard(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }
}
