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

  bool get _isBatchModification {
    final details = widget.request.details;
    if (details is! Map) {
      return false;
    }
    final modification = details['modification'];
    return modification is Map && modification['isBatch'] == true;
  }

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
              _isBatchModification
                  ? _buildNoteIdsDisplay(colorScheme)
                  : _buildNoteIdDisplay(colorScheme),
            ],
            if (widget.request.type == ApprovalType.noteDeletion) ...[
              const SizedBox(height: 4),
              _buildNoteIdsDisplay(colorScheme),
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
    final title = details is Map ? details['noteTitle']?.toString() : null;
    final snippet = details is Map ? details['noteSnippet']?.toString() : null;

    if (title == null && snippet == null) {
      return SelectableText(
        'Note ID: $noteId',
        style: const TextStyle(fontWeight: FontWeight.bold),
      );
    }

    return Container(
      width: double.maxFinite,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: 'Note: ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: title ?? 'Untitled'),
                TextSpan(
                  text: ' ($noteId)',
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (snippet != null) ...[
            const SizedBox(height: 4),
            Text(
              snippet,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNoteIdsDisplay(ColorScheme colorScheme) {
    final details = widget.request.details;
    // Check for enriched noteDetails first
    final noteDetails = details is Map && details['noteDetails'] is List
        ? (details['noteDetails'] as List).cast<Map<String, String>>()
        : <Map<String, String>>[];

    final noteIds = details is Map
        ? (details['noteIds'] as List<dynamic>?)?.cast<String>() ?? []
        : <String>[];

    if (noteIds.isEmpty) {
      return const Text('No notes specified');
    }

    return Container(
      width: double.maxFinite,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: noteDetails.isNotEmpty
            ? noteDetails
                  .map(
                    (note) => Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText.rich(
                            TextSpan(
                              children: [
                                const TextSpan(text: '• '),
                                TextSpan(
                                  text: note['title'] ?? 'Untitled',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                TextSpan(
                                  text: ' (${note['id']})',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (note['snippet'] != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 12.0),
                              child: Text(
                                note['snippet']!,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                  .toList()
            : noteIds
                  .map(
                    (id) => SelectableText(
                      '• $id',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                  .toList(),
      ),
    );
  }

  Widget _buildDetailsContainer(ColorScheme colorScheme) {
    if (widget.request.type == ApprovalType.noteModification) {
      final details = widget.request.details;
      final modification = details is Map ? details['modification'] : details;

      if (modification is Map && modification['isBatch'] == true) {
        return _buildBatchModificationDisplay(
          colorScheme,
          modification as Map<String, dynamic>,
        );
      }

      String displayText = widget.request.formattedDetails;
      if (modification != null) {
        displayText = _formatModification(modification);
      }
      return _buildTextContainer(displayText, colorScheme);
    } else if (widget.request.type == ApprovalType.noteDeletion) {
      // For deletion, the note IDs are already shown above
      // Don't show the details container for deletion
      return const SizedBox.shrink();
    }

    return _buildTextContainer(widget.request.formattedDetails, colorScheme);
  }

  Widget _buildTextContainer(String text, ColorScheme colorScheme) {
    return Container(
      width: double.maxFinite,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: widget.request.type == ApprovalType.sqlWrite ? 11 : 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildBatchModificationDisplay(
    ColorScheme colorScheme,
    Map<String, dynamic> modification,
  ) {
    final updates =
        (modification['updates'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final totalCount = modification['count'] as int? ?? 0;

    if (updates.isEmpty) {
      return _buildTextContainer(
        'Batch update of $totalCount notes',
        colorScheme,
      );
    }

    return Container(
      width: double.maxFinite,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Batch update of $totalCount notes (showing first ${updates.length}):',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...updates.map((update) {
            final id = update['id'] ?? 'unknown';
            final title = update['title'];
            final changes = update['changes'];

            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title != null ? '$title ($id)' : 'Note ID: $id',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Text(
                      _formatModification(changes),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
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

  String _formatModification(dynamic modification) {
    if (modification is! Map) return modification.toString();

    final buffer = StringBuffer();
    final map = modification;

    map.forEach((key, value) {
      if (key == 'title') {
        buffer.writeln('• Set Title: "$value"');
      } else if (key == 'content') {
        if (value is Map && value['action'] == 'append') {
          buffer.writeln(
            '• Append Content: "${_truncate(value['text']?.toString() ?? '')}"',
          );
        } else if (value is String) {
          buffer.writeln('• Set Content: "${_truncate(value)}"');
        } else {
          buffer.writeln('• Content: $value');
        }
      } else if (key == 'tags') {
        if (value is Map) {
          final added = value['added'];
          final removed = value['removed'];
          if (added != null && (added is List) && added.isNotEmpty) {
            buffer.writeln('• Add Tags: ${added.join(", ")}');
          }
          if (removed != null && (removed is List) && removed.isNotEmpty) {
            buffer.writeln('• Remove Tags: ${removed.join(", ")}');
          }
        } else {
          buffer.writeln('• Tags: $value');
        }
      } else if (key == 'type') {
        buffer.writeln('• Set Type: "$value"');
      } else if (key == 'status') {
        buffer.writeln('• Set Status: "$value"');
      } else if (key == 'pinned') {
        buffer.writeln('• ${value == true ? "Pin" : "Unpin"} Note');
      } else if (key == 'isArchived') {
        buffer.writeln('• ${value == true ? "Archive" : "Unarchive"} Note');
      } else {
        buffer.writeln('• Set $key: $value');
      }
    });

    if (buffer.isEmpty) return modification.toString();
    return buffer.toString().trim();
  }

  String _truncate(String text, {int length = 100}) {
    // Replace newlines with spaces for compact display
    final cleanText = text.replaceAll('\n', ' ');
    if (cleanText.length <= length) return cleanText;
    return '${cleanText.substring(0, length)}...';
  }
}
