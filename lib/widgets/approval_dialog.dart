import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/approval_service.dart';

/// Reusable approval dialog for SQL writes and note modifications.
///
/// This widget can be shown using [ApprovalDialog.show] with a NavigatorState
/// to handle context lifecycle safely.
class ApprovalDialog extends StatefulWidget {
  const ApprovalDialog({super.key, required this.request});

  final ApprovalRequest request;

  /// Show the approval dialog using the provided navigator.
  ///
  /// Uses NavigatorState instead of BuildContext to handle cases where
  /// the original context may be disposed before the dialog closes.
  static Future<ApprovalResult> show(
    NavigatorState navigator,
    ApprovalRequest request,
  ) async {
    final result = await navigator.push<ApprovalResult>(
      DialogRoute<ApprovalResult>(
        context: navigator.context,
        builder: (context) => ApprovalDialog(request: request),
        barrierDismissible: false,
      ),
    );
    return result ?? ApprovalResult(approved: false);
  }

  /// Show the approval dialog using BuildContext.
  ///
  /// Prefer [show] with NavigatorState for better lifecycle handling.
  static Future<ApprovalResult> showWithContext(
    BuildContext context,
    ApprovalRequest request,
  ) async {
    final result = await showDialog<ApprovalResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ApprovalDialog(request: request),
    );
    return result ?? ApprovalResult(approved: false);
  }

  @override
  State<ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<ApprovalDialog> {
  bool _allowForSession = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: Text(widget.request.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.request.description),
            if (widget.request.type == ApprovalType.noteModification) ...[
              const SizedBox(height: 4),
              _buildNoteIdDisplay(colorScheme),
            ],
            const SizedBox(height: 8),
            _buildDetailsContainer(colorScheme),
            if (widget.request.warningMessage != null) ...[
              const SizedBox(height: 16),
              _buildWarningBanner(colorScheme),
            ],
            if (widget.request.sessionApprovalLabel != null) ...[
              const SizedBox(height: 16),
              _buildSessionCheckbox(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, ApprovalResult(approved: false)),
          child: const Text('Deny'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            ApprovalResult(
              approved: true,
              approvedForSession: _allowForSession,
            ),
          ),
          style: widget.request.warningMessage != null
              ? TextButton.styleFrom(foregroundColor: colorScheme.error)
              : null,
          child: const Text('Approve'),
        ),
      ],
    );
  }

  Widget _buildNoteIdDisplay(ColorScheme colorScheme) {
    final details = widget.request.details;
    final noteId = details is Map ? details['noteId']?.toString() ?? '' : '';
    return SelectableText(
      noteId,
      style: const TextStyle(fontWeight: FontWeight.bold),
    );
  }

  Widget _buildDetailsContainer(ColorScheme colorScheme) {
    String displayText;
    if (widget.request.type == ApprovalType.noteModification) {
      final details = widget.request.details;
      final modification = details is Map ? details['modification'] : details;
      displayText = widget.request.formattedDetails;
      if (modification != null) {
        try {
          displayText = const JsonEncoder.withIndent(
            '  ',
          ).convert(modification);
        } catch (_) {
          displayText = modification.toString();
        }
      }
    } else {
      displayText = widget.request.formattedDetails;
    }

    return Container(
      width: double.maxFinite,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        displayText,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: widget.request.type == ApprovalType.sqlWrite ? 11 : 10,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildWarningBanner(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: colorScheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.request.warningMessage!,
              style: TextStyle(color: colorScheme.error, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCheckbox() {
    return Row(
      children: [
        Checkbox(
          value: _allowForSession,
          onChanged: (val) {
            setState(() {
              _allowForSession = val ?? false;
            });
          },
        ),
        Expanded(child: Text(widget.request.sessionApprovalLabel!)),
      ],
    );
  }
}
