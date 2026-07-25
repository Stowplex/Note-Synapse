import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
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

  /// Whether the details box is expanded past [_collapsedDetailsHeight].
  bool _detailsExpanded = false;

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
            // Capped: `description` embeds the app's own name, which comes
            // verbatim from an imported YAML. Left unbounded, a name padded
            // with newlines pushes the scope notice below the fold while the
            // Approve button stays put (it lives in `actions`, outside the
            // scroll view).
            Text(
              widget.request.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            if (widget.request.type == ApprovalType.noteModification) ...[
              const SizedBox(height: 4),
              _isBatchModification
                  ? _buildNoteIdsDisplay(colorScheme)
                  : _buildNoteIdDisplay(colorScheme),
            ],
            // ABOVE the details body on purpose. The body echoes
            // plugin-controlled text, so rendering the scope notice after it let
            // a plugin pad a field with newlines and push this line far below
            // the Approve button while showing its own forged reassurance.
            ..._buildScopeNotice(colorScheme),
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
            // Capped for the same reason as the description above: a long or
            // newline-padded title must not be able to scroll the scope notice
            // out of view.
            maxLines: 2,
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
                            // Capped so a padded title cannot scroll the scope
                            // notice out of view.
                            maxLines: 2,
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
        // Bounded and expandable for the same reason as the single-note body:
        // 20 entries of plugin text must not be able to push the notice or the
        // Approve button out of view, but the user must still be able to read
        // all of it.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _detailsExpanded
                    ? double.infinity
                    : _collapsedDetailsHeight,
              ),
              child: SingleChildScrollView(
                child: _buildBatchModificationDisplay(
                  colorScheme,
                  modification as Map<String, dynamic>,
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _detailsExpanded = !_detailsExpanded),
                icon: Icon(
                  _detailsExpanded ? Icons.unfold_less : Icons.unfold_more,
                  size: 16,
                ),
                label: Text(
                  _detailsExpanded ? 'Show less' : 'Show full change',
                  style: const TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: colorScheme.primary,
                ),
              ),
            ),
          ],
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

  /// Height the details box occupies before the user expands it.
  ///
  /// Bounding the box — rather than truncating the text — is what keeps the
  /// scope notice and the Approve button in view no matter how much text a
  /// plugin sends, while still letting the user read the WHOLE change by
  /// scrolling inside the box or expanding it.
  static const double _collapsedDetailsHeight = 180;

  Widget _buildTextContainer(String text, ColorScheme colorScheme) {
    final capped = _capForRendering(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: _detailsExpanded
                ? double.infinity
                : _collapsedDetailsHeight,
          ),
          child: SingleChildScrollView(
            child: _buildTextBody(capped, colorScheme),
          ),
        ),
        _buildExpandToggle(capped, colorScheme),
      ],
    );
  }

  /// Shown only when the text does not fit collapsed, so simple approvals stay
  /// uncluttered.
  Widget _buildExpandToggle(String text, ColorScheme colorScheme) {
    // Cheap proxy for "taller than the collapsed box": either many lines or a
    // lot of characters.
    final lines = text.split('\n').length;
    if (lines <= 8 && text.length <= 400) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => setState(() => _detailsExpanded = !_detailsExpanded),
        icon: Icon(
          _detailsExpanded ? Icons.unfold_less : Icons.unfold_more,
          size: 16,
        ),
        label: Text(
          _detailsExpanded ? 'Show less' : 'Show full change',
          style: const TextStyle(fontSize: 12),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildTextBody(String text, ColorScheme colorScheme) {
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

  /// Localized: this is the one string in this dialog that the user must
  /// understand to give informed consent, so it is not left hardcoded English
  /// like the rest of the file. Falls back to English when no Localizations are
  /// in scope (e.g. a bare widget test).
  /// The scope notice, rendered directly under the dialog description so no
  /// amount of plugin-supplied text can push it out of view.
  ///
  /// Batches get it too: otherwise adding one extra entry hides a whole-note
  /// rewrite behind what reads as a block edit.
  List<Widget> _buildScopeNotice(ColorScheme colorScheme) {
    final details = widget.request.details;
    final modification = details is Map ? details['modification'] : details;
    final notice = _scopeNotice(modification);
    if (notice == null) return const [];

    final isWholeNote =
        modification is Map &&
        modification[ApprovalRequest.scopeWholeNoteKey] == true;
    final color = isWholeNote
        ? colorScheme.error
        : colorScheme.onSurfaceVariant;
    return [
      const SizedBox(height: 8),
      Row(
        children: [
          Icon(
            isWholeNote ? Icons.warning_amber_rounded : Icons.crop_free,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              notice,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: isWholeNote ? FontWeight.bold : null,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  String? _scopeNotice(dynamic modification) {
    if (modification is! Map) return null;
    final l10n = AppLocalizations.of(context);
    // Whole-note is checked FIRST so that if both keys are somehow present the
    // user sees the WIDER scope, never the reassuring one. Defence in depth:
    // the bridge already strips plugin-supplied `__` keys.
    if (modification[ApprovalRequest.scopeWholeNoteKey] == true) {
      return l10n?.approvalScopeWholeNote ??
          'Applies to the ENTIRE note, not just the selected block.';
    }
    if (modification[ApprovalRequest.scopeBlockKey] == true) {
      return l10n?.approvalScopeBlockOnly ??
          'Applies to the selected block only.';
    }
    return null;
  }

  String _formatModification(dynamic modification) {
    if (modification is! Map) return modification.toString();

    final buffer = StringBuffer();
    final map = modification;

    map.forEach((key, value) {
      // Internal scope hints are surfaced separately, not as note fields.
      if (key is String && key.startsWith('__')) {
        return;
      }
      if (key == 'title') {
        buffer.writeln('• Set Title: "${value?.toString() ?? ''}"');
      } else if (key == 'content') {
        if (value is Map && value['action'] == 'append') {
          buffer.writeln(
            '• Append Content: "${value['text']?.toString() ?? ''}"',
          );
        } else if (value is Map && value['action'] == 'prepend') {
          buffer.writeln(
            '• Insert Before: "${value['text']?.toString() ?? ''}"',
          );
        } else if (value is Map && value['action'] == 'replace') {
          final text = value['text']?.toString() ?? '';
          // A block delete arrives as replace-with-empty; rendering the raw map
          // ('{action: replace, text: }') is unreadable at a consent surface.
          buffer.writeln(
            text.isEmpty
                ? '• Delete the selected content'
                : '• Replace Content With: "$text"',
          );
        } else if (value is String) {
          buffer.writeln('• Set Content: "$value"');
        } else {
          buffer.writeln('• Content: ${value.toString()}');
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
        buffer.writeln('• Set $key: ${value?.toString() ?? ''}');
      }
    });

    if (buffer.isEmpty) return modification.toString();
    return buffer.toString().trim();
  }

  /// Upper bound on rendered detail text.
  ///
  /// Not a consent measure — the scope notice sits above this text and the box
  /// is height-bounded, so long values cannot hide anything. This only stops a
  /// pathological payload (a multi-megabyte note body) from stalling layout.
  static const int _maxDetailChars = 20000;

  String _capForRendering(String text) => text.length <= _maxDetailChars
      ? text
      : '${text.substring(0, _maxDetailChars)}\n… (truncated for display)';
}
