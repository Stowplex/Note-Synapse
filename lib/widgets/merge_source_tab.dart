import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../utils/markdown_block_tracker.dart';
import '../utils/merge_document.dart';
import 'block_markdown_body.dart';

/// One source note inside the merge editor: the note rendered block by block,
/// where a tap ticks a block into the merged note and a long press offers the
/// manual options (copy, select text, whole section).
class MergeSourceTab extends StatefulWidget {
  const MergeSourceTab({
    super.key,
    required this.document,
    required this.source,
    required this.color,
    required this.onChanged,
  });

  final MergeDocument document;
  final MergeSource source;
  final Color color;

  /// Called after every change to [document] so the owner can rebuild.
  final VoidCallback onChanged;

  @override
  State<MergeSourceTab> createState() => _MergeSourceTabState();
}

class _MergeSourceTabState extends State<MergeSourceTab>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  MergeDocument get _doc => widget.document;
  MergeSource get _source => widget.source;

  void _notify() {
    if (mounted) setState(() {});
    widget.onChanged();
  }

  // ------------------------------------------------------------ gestures

  void _onTap(int index, MarkdownBlock block) {
    if (!_source.isSelectable(index)) return;
    switch (_doc.statusOf(_source, index)) {
      case MergeBlockStatus.none:
        _doc.add(_source, index);
      case MergeBlockStatus.added:
        _doc.remove(_source, index);
      case MergeBlockStatus.edited:
        _showEditedDialog(index);
        return;
    }
    _notify();
  }

  Future<void> _showEditedDialog(int index) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mergeEditedTitle),
        content: Text(l10n.mergeEditedBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'forget'),
            child: Text(l10n.mergeForget),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'copy'),
            child: Text(l10n.mergeAddAnotherCopy),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      _doc.addCopy(_source, index);
      _notify();
    } else if (action == 'forget') {
      _doc.forget(_source, index);
      _notify();
    }
  }

  Future<void> _onLongPress(int index, MarkdownBlock block) async {
    if (!_source.isSelectable(index)) return;
    final l10n = AppLocalizations.of(context)!;
    final status = _doc.statusOf(_source, index);
    final isHeading = MergeDocument.headingLevel(block.content) != null;
    final sectionSize = isHeading
        ? _doc.sectionIndices(_source, index).length
        : 0;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status == MergeBlockStatus.added)
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: Text(l10n.mergeRemoveFromMerged),
                onTap: () => Navigator.pop(context, 'remove'),
              )
            else
              ListTile(
                leading: Icon(Icons.add_circle_outline, color: widget.color),
                title: Text(l10n.mergeAddToMerged),
                onTap: () => Navigator.pop(context, 'add'),
              ),
            if (isHeading && sectionSize > 1)
              ListTile(
                leading: Icon(Icons.segment, color: widget.color),
                title: Text(l10n.mergeAddSection(sectionSize)),
                onTap: () => Navigator.pop(context, 'section'),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(l10n.mergeCopyText),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: Text(l10n.mergeSelectText),
              onTap: () => Navigator.pop(context, 'select'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'add':
        if (status == MergeBlockStatus.edited) {
          _doc.addCopy(_source, index);
        } else {
          _doc.add(_source, index);
        }
        _notify();
      case 'remove':
        _doc.remove(_source, index);
        _notify();
      case 'section':
        _doc.addSection(_source, index);
        _notify();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: block.content));
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.mergeCopied)));
        }
      case 'select':
        _showSelectTextDialog(block);
    }
  }

  void _showSelectTextDialog(MarkdownBlock block) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        content: SingleChildScrollView(
          child: SelectableText(
            block.content,
            style: const TextStyle(fontFamily: 'Roboto Mono', fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: block.content));
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(l10n.copy),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ rendering

  Widget _wrapBlock(int index, MarkdownBlock block, Widget child) {
    if (!_source.isSelectable(index)) return child;
    final status = _doc.statusOf(_source, index);
    final theme = Theme.of(context);

    final Widget leading;
    switch (status) {
      case MergeBlockStatus.added:
        // The block's position in the merged note: blocks land in the order
        // they were ticked, which the document order on screen would
        // otherwise hide.
        final position = _doc.positionOf(_source, index);
        leading = Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
          child: Text(
            '$position',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              height: 1,
            ),
          ),
        );
      case MergeBlockStatus.edited:
        leading = Icon(
          Icons.edit_note,
          color: theme.colorScheme.onSurfaceVariant,
          size: 22,
        );
      case MergeBlockStatus.none:
        leading = Icon(
          Icons.radio_button_unchecked,
          color: theme.colorScheme.outline,
          size: 22,
        );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: status == MergeBlockStatus.added
                ? widget.color
                : Colors.transparent,
            width: 3,
          ),
        ),
        color: status == MergeBlockStatus.added
            ? widget.color.withValues(alpha: 0.06)
            : null,
      ),
      padding: const EdgeInsets.only(left: 6, right: 4, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: leading),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final added = _doc.addedCount(_source);
    final total = _source.selectableCount;

    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 24),
                sliver: BlockMarkdownBody(
                  content: _source.note.content,
                  noteId: _source.note.id,
                  scrollController: _scroll,
                  onBlocksParsed: (blocks) {
                    _doc.syncBlocks(_source, blocks);
                    if (mounted) setState(() {});
                  },
                  onBlockTap: _onTap,
                  onBlockLongPress: _onLongPress,
                  blockWrapper: _wrapBlock,
                ),
              ),
            ],
          ),
        ),
        Material(
          elevation: 4,
          color: theme.colorScheme.surface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        Text(
                          l10n.mergeBlocksAdded(added, total),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (_doc.insertionIndex != null)
                          InputChip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.vertical_align_center),
                            label: Text(
                              l10n.mergeInsertingAt(_doc.insertionIndex! + 1),
                            ),
                            onDeleted: () {
                              _doc.insertionIndex = null;
                              _notify();
                            },
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: added == total
                        ? null
                        : () {
                            _doc.addAll(_source);
                            _notify();
                          },
                    child: Text(l10n.mergeAddAll),
                  ),
                  TextButton(
                    onPressed: added == 0
                        ? null
                        : () {
                            _doc.removeAll(_source);
                            _notify();
                          },
                    child: Text(l10n.mergeRemoveAll),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
