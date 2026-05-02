import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:note_synapse/utils/markdown_block_tracker.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';
import '../models/chip_action.dart';
import '../services/chips_block_parser.dart';

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

  // New props for selection
  final Set<int> selectedBlockIndices;
  final Function(List<MarkdownBlock>)? onBlocksParsed;
  final Function(int index, MarkdownBlock block, Offset position)?
  onBlockDropped;

  /// Fires after a chips block is detected and stripped from [content].
  /// Called on first build for a given content value, and again only when
  /// [content] changes and produces a different chip list. Use this to
  /// render a chip footer below the message body (see ChipsFooter widget).
  ///
  /// Optional — omit for messages where chip rendering is not desired
  /// (e.g. user messages, scratchpad notes).
  final void Function(List<ChipAction>)? onChipsExtracted;

  const BlockMarkdownBody({
    super.key,
    required this.content,
    required this.noteId,
    this.onContentChanged,
    this.onLinkTap,
    this.style,
    this.onBlockEditRequested,
    this.selectedBlockIndices = const {},
    this.onBlocksParsed,
    this.onBlockDropped,
    this.onFetchImage,
    this.onChipsExtracted,
  });

  final Function(String)? onFetchImage;

  @override
  State<BlockMarkdownBody> createState() => _BlockMarkdownBodyState();
}

class _BlockMarkdownBodyState extends State<BlockMarkdownBody> {
  final _tracker = MarkdownBlockTracker();
  late List<MarkdownBlock> _blocks;

  // Chips caching: keyed on content to avoid re-parsing on unrelated rebuilds.
  ChipsParseResult? _cachedChipsResult;
  String? _cachedChipsFor;
  List<ChipAction>? _lastNotifiedChips;

  ChipsParseResult _ensureChipsParsed(String content) {
    if (_cachedChipsFor == content && _cachedChipsResult != null) {
      return _cachedChipsResult!;
    }
    _cachedChipsResult = ChipsBlockParser().parse(content);
    _cachedChipsFor = content;
    return _cachedChipsResult!;
  }

  void _maybeNotifyChips(List<ChipAction> chips) {
    final cb = widget.onChipsExtracted;
    if (cb == null) return;
    if (listEquals(_lastNotifiedChips, chips)) return;
    _lastNotifiedChips = List.of(chips);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb(chips);
    });
  }

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
    final parsed = _ensureChipsParsed(widget.content);
    _blocks = _tracker.parseBlocks(parsed.strippedMarkdown);
    // Notify parent of parsed blocks (deferred to avoid build-phase callback issues if needed, but usually safe here if parent handles it well)
    // Using post-frame callback just in case parent calls setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onBlocksParsed?.call(_blocks);
    });
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _ensureChipsParsed(widget.content);
    _maybeNotifyChips(parsed.chips);

    if (_blocks.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        return _buildBlockItem(index, _blocks[index]);
      }, childCount: _blocks.length),
    );
  }

  Widget _buildBlockItem(int index, MarkdownBlock block) {
    final isSelected = widget.selectedBlockIndices.contains(index);

    // We wrap each block in a DragTarget to handle the "Edit" drop
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data ==
          'block_edit_drag', // Match kBlockEditDragData in NoteDetailScreen
      onAcceptWithDetails: (details) {
        // Prefer onBlockDropped with index, fallback to legacy onBlockEditRequested
        if (widget.onBlockDropped != null) {
          widget.onBlockDropped!(index, block, details.offset);
        } else {
          widget.onBlockEditRequested?.call(block);
        }
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

        final showHighlight = isHovered || isSelected;

        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: showHighlight ? highlightColor : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(8),
            // Only add background color for selection/hover feedback
            color: showHighlight ? backgroundColor : Colors.transparent,
          ),
          child: InteractiveCheckboxMarkdown(
            key: ValueKey(
              '${widget.noteId}_${block.startOffset}_${block.endOffset}',
            ),
            noteId: widget.noteId,
            originalContent: block.content,
            onContentChanged: (newBlockContent) {
              _handleBlockContentChanged(block, newBlockContent);
            },
            onLinkTap: widget.onLinkTap,
            style: widget.style,
            maxLines: null,
            overflow: null,
            onFetchImage: widget.onFetchImage,
          ),
        );
      },
    );
  }

  void _handleBlockContentChanged(MarkdownBlock block, String newBlockContent) {
    if (widget.onContentChanged == null) return;

    final newFullContent = _tracker.replaceBlock(
      widget.content,
      block,
      newBlockContent,
    );

    widget.onContentChanged!(newFullContent);
  }
}
