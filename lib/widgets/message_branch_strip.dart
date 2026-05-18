import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/conversation_branch_summary.dart';

/// Inline strip rendered below a fork-point message card. One row per
/// child branch, with the active branch highlighted. Tapping a sibling
/// fires [onSwitchBranch].
///
/// If the sibling branch's notes differ from [activeNoteIds] (i.e. it
/// belongs to a different document), a confirm dialog is shown before
/// the switch fires — so readers don't silently jump papers.
///
/// Renders nothing when fewer than 2 branches (single-child fork-points
/// don't get a strip).
class MessageBranchStrip extends StatefulWidget {
  final List<ConversationBranchSummary> branches;
  final String activeConversationId;
  final List<String> activeNoteIds;

  /// Fired when the user accepts a sibling switch.
  /// [didConfirmDocumentSwap] is true if the user passed through the
  /// document-swap confirm dialog; false for same-document switches.
  final void Function(String conversationId, bool didConfirmDocumentSwap)
  onSwitchBranch;

  /// Wired from ChatPanel.isStreaming — disables tap interactions while
  /// the parent message is generating to avoid race conditions.
  final bool disabled;
  final Future<void> Function(String conversationId, String title)?
  onRenameBranch;

  const MessageBranchStrip({
    super.key,
    required this.branches,
    required this.activeConversationId,
    required this.activeNoteIds,
    required this.onSwitchBranch,
    this.disabled = false,
    this.onRenameBranch,
  });

  @override
  State<MessageBranchStrip> createState() => _MessageBranchStripState();
}

class _MessageBranchStripState extends State<MessageBranchStrip> {
  static const int _visibleLimit = 5;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.branches.length < 2) return const SizedBox.shrink();
    final showAll = _expanded || widget.branches.length <= _visibleLimit;
    final visible = showAll
        ? widget.branches
        : widget.branches.take(_visibleLimit).toList();
    final hidden = widget.branches.length - visible.length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final b in visible) _buildRow(context, b),
          if (!showAll && hidden > 0)
            InkWell(
              onTap: widget.disabled
                  ? null
                  : () => setState(() => _expanded = true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '+$hidden more',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, ConversationBranchSummary b) {
    final isActive = b.conversationId == widget.activeConversationId;
    return InkWell(
      key: isActive ? ValueKey('branch-row-active-${b.conversationId}') : null,
      onTap: widget.disabled ? null : () => _handleTap(b),
      onLongPress: widget.disabled || widget.onRenameBranch == null
          ? null
          : () => _handleRename(b),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Text(
          b.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: isActive ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
      ),
    );
  }

  Future<void> _handleRename(ConversationBranchSummary b) async {
    final controller = TextEditingController(text: b.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename branch'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Branch title'),
          onSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(ctx)?.cancel ?? 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
    final trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == b.title) return;
    await widget.onRenameBranch?.call(b.conversationId, trimmed);
  }

  Future<void> _handleTap(ConversationBranchSummary b) async {
    if (b.conversationId == widget.activeConversationId) return;
    final activeSet = widget.activeNoteIds.toSet();
    final candidateSet = b.noteIds.toSet();
    final differs =
        activeSet.length != candidateSet.length ||
        !activeSet.every(candidateSet.contains);
    if (!differs) {
      widget.onSwitchBranch(b.conversationId, false);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.branchStripDocumentSwapMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.branchStripDocumentSwapConfirm),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      widget.onSwitchBranch(b.conversationId, true);
    }
  }
}
