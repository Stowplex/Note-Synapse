import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:note_synapse/utils/markdown_block_tracker.dart';
import 'package:note_synapse/widgets/heading_anchor_registry.dart';
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

  // New props for selection
  final Set<int> selectedBlockIndices;
  final Function(List<MarkdownBlock>)? onBlocksParsed;
  final Function(int index, MarkdownBlock block, Offset position)?
  onBlockDropped;

  /// External scroll controller used by the parent's CustomScrollView. When
  /// provided, [BlockMarkdownBodyState.scrollToSlug] uses it to coarse-jump to
  /// off-screen heading blocks before retrying ensureVisible.
  final ScrollController? scrollController;

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
    this.scrollController,
  });

  final Function(String)? onFetchImage;

  @override
  State<BlockMarkdownBody> createState() => BlockMarkdownBodyState();
}

class BlockMarkdownBodyState extends State<BlockMarkdownBody> {
  final _tracker = MarkdownBlockTracker();
  final HeadingAnchorRegistry _anchorRegistry = HeadingAnchorRegistry();
  final Map<int, GlobalKey> _blockKeys = {};
  final Map<String, int> _slugToBlockIndex = {};
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

    // Reset slug bookkeeping before re-registering so duplicate-suffix
    // counters are deterministic across re-parses.
    _anchorRegistry.clear();
    _blockKeys.clear();
    _slugToBlockIndex.clear();

    for (var i = 0; i < _blocks.length; i++) {
      final block = _blocks[i];
      if (block.type != MarkdownBlockType.heading) continue;
      final slug = _anchorRegistry.registerHeading(block.content);
      final key = _anchorRegistry.keyForSlug(slug);
      if (key != null) {
        _blockKeys[i] = key;
        _slugToBlockIndex[slug] = i;
      }
    }

    // Notify parent of parsed blocks (deferred to avoid build-phase callback issues if needed, but usually safe here if parent handles it well)
    // Using post-frame callback just in case parent calls setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onBlocksParsed?.call(_blocks);
    });
  }

  /// Scroll the heading whose anchor slug matches [slug] into view.
  ///
  /// Returns true on success. Returns false if no heading uses that slug.
  /// Handles the lazy SliverList case: if the heading block isn't built yet,
  /// estimates an offset by character position and jumps the scroll view to
  /// force a build, then retries ensureVisible.
  Future<bool> scrollToSlug(String slug) async {
    if (await _anchorRegistry.scrollToSection(slug)) return true;

    final blockIndex = _slugToBlockIndex[slug];
    if (blockIndex == null) return false;

    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return false;

    final block = _blocks[blockIndex];
    final contentLength = widget.content.length;
    if (contentLength == 0) return false;

    final position = controller.position;
    final fraction = (block.startOffset / contentLength).clamp(0.0, 1.0);
    final estimated = position.maxScrollExtent * fraction;
    controller.jumpTo(estimated);

    // Wait for the SliverList to build the now-visible region, then retry.
    await _waitForFrame();
    if (await _anchorRegistry.scrollToSection(slug)) return true;

    // One more attempt after another frame — extents can change as new
    // children measure.
    await _waitForFrame();
    return _anchorRegistry.scrollToSection(slug);
  }

  Future<void> _waitForFrame() {
    final completer = Completer<void>();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
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
    final anchorKey = _blockKeys[index];

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
          key: anchorKey,
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
