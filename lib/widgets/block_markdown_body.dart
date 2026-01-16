import 'package:flutter/material.dart';
import 'package:note_synapse/utils/markdown_block_tracker.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

/// Callback for when a block edit is requested
typedef BlockEditCallback = void Function(MarkdownBlock block);

/// A widget that renders markdown content as a list of interactive blocks.
///
/// Each block is wrapped in a defined DragTarget, allowing "drag-to-edit" interactions.
/// This replaces the monolithic markdown rendering which was fragile for partial edits.
class BlockMarkdownBody extends StatefulWidget {
  final String content;
  final String noteId;
  final ValueChanged<String>? onContentChanged;
  final Function(String, String?)? onLinkTap;
  final TextStyle? style;
  final BlockEditCallback? onBlockEditRequested;

  const BlockMarkdownBody({
    super.key,
    required this.content,
    required this.noteId,
    this.onContentChanged,
    this.onLinkTap,
    this.style,
    this.onBlockEditRequested,
  });

  @override
  State<BlockMarkdownBody> createState() => _BlockMarkdownBodyState();
}

class _BlockMarkdownBodyState extends State<BlockMarkdownBody> {
  final _tracker = MarkdownBlockTracker();
  late List<MarkdownBlock> _blocks;

  @override
  void initState() {
    super.initState();
    _parseBlocks();
  }

  @override
  void didUpdateWidget(BlockMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _parseBlocks();
    }
  }

  void _parseBlocks() {
    _blocks = _tracker.parseBlocks(widget.content);
  }

  @override
  Widget build(BuildContext context) {
    if (_blocks.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _blocks.map((block) => _buildBlockItem(block)).toList(),
    );
  }

  Widget _buildBlockItem(MarkdownBlock block) {
    // We wrap each block in a DragTarget to handle the "Edit" drop
    return DragTarget<String>(
      onWillAccept: (data) =>
          data ==
          'block_edit_drag', // Match kBlockEditDragData in NoteDetailScreen
      onAccept: (data) {
        widget.onBlockEditRequested?.call(block);
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        final brightness = Theme.of(context).brightness;
        final highlightColor = brightness == Brightness.dark
            ? Colors.blue.shade400
            : Colors.blue.shade700;
        final backgroundColor = brightness == Brightness.dark
            ? Colors.blue.shade900.withOpacity(0.3)
            : Colors.blue.shade50.withOpacity(0.5);

        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: isHovered ? highlightColor : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(8),
            color: isHovered ? backgroundColor : Colors.transparent,
          ),
          // We assume InteractiveCheckboxMarkdown can handle being given a snippet.
          // Since we are parsing blocks, the snippet is valid markdown (e.g. a whole list, or a header).
          child: InteractiveCheckboxMarkdown(
            key: ValueKey(
              '${widget.noteId}_${block.startOffset}_${block.endOffset}',
            ),
            noteId: widget.noteId,
            originalContent: block.content,
            // Internal content changes (checkboxes) need to be mapped back to the whole document.
            // But InteractiveCheckboxMarkdown usually calls onContentChanged with the *whole* content?
            // Wait, InteractiveCheckboxMarkdown was previously managing the *whole* note.
            // If we give it just a snippet, it will callback with the changed snippet (e.g. checkbox toggled).
            // We need to patch that back into the full document.
            onContentChanged: (newBlockContent) {
              _handleBlockContentChanged(block, newBlockContent);
            },
            onLinkTap: widget.onLinkTap,
            style: widget.style,
            maxLines: null,
            overflow: null,
            // Drag-to-edit is now handled by this outer wrapper,
            // so we don't pass onBlockEditRequested to the child.
          ),
        );
      },
    );
  }

  void _handleBlockContentChanged(MarkdownBlock block, String newBlockContent) {
    if (widget.onContentChanged == null) return;

    // We need to replace the block in the original full content.
    // Using the block's offsets which are valid for 'widget.content'.
    final newFullContent = _tracker.replaceBlock(
      widget.content,
      block,
      newBlockContent,
    );

    widget.onContentChanged!(newFullContent);
  }
}
