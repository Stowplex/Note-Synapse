import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chip_action.dart';
import '../models/conversation.dart';
import '../services/chips_block_parser.dart';
import 'chip_preview_popover.dart';
import 'chips_footer.dart';
import 'interactive_checkbox_markdown.dart';

/// Renders an AI message body with persisted chip blocks stripped from the
/// markdown and exposed as tappable footer chips.
class ChipAwareAiMessageContent extends StatefulWidget {
  final ConversationMessage message;
  final bool isStreaming;
  final bool chipsExpected;
  final FutureOr<void> Function(ChipAction chip)? onChipTap;
  final void Function(String url, String title)? onLinkTap;
  final TextStyle? style;
  final String? noteId;

  const ChipAwareAiMessageContent({
    super.key,
    required this.message,
    required this.isStreaming,
    required this.chipsExpected,
    this.onChipTap,
    this.onLinkTap,
    this.style,
    this.noteId,
  });

  @override
  State<ChipAwareAiMessageContent> createState() =>
      _ChipAwareAiMessageContentState();
}

class _ChipAwareAiMessageContentState extends State<ChipAwareAiMessageContent> {
  final ChipsBlockParser _chipsParser = ChipsBlockParser();

  String? _contentSnapshot;
  List<ChipAction> _chips = const [];
  String? _strippedMarkdown;
  OverlayEntry? _activePreview;

  @override
  void dispose() {
    _activePreview?.remove();
    _activePreview = null;
    super.dispose();
  }

  ({List<ChipAction> chips, String stripped}) _parsedMessage() {
    final content = widget.message.content;
    if (_contentSnapshot != content) {
      final parsed = widget.message.type == MessageType.ai
          ? _chipsParser.parse(content)
          : ChipsParseResult(chips: const [], strippedMarkdown: content);
      _chips = parsed.chips;
      _strippedMarkdown = parsed.strippedMarkdown;
      _contentSnapshot = content;
    }
    return (chips: _chips, stripped: _strippedMarkdown ?? content);
  }

  void _showChipPreview(ChipAction chip, GlobalKey anchorKey) {
    _activePreview?.remove();
    final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final rect = pos & box.size;
    _activePreview = ChipPreviewPopover.show(
      context: context,
      anchorRect: rect,
      chip: chip,
    );
    Future.delayed(const Duration(seconds: 6), () {
      _activePreview?.remove();
      _activePreview = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsedMessage();
    final hasPersistedChips = parsed.chips.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionArea(
          child: InteractiveCheckboxMarkdown(
            originalContent: parsed.stripped,
            style: widget.style,
            noteId: widget.noteId,
            onLinkTap: widget.onLinkTap,
          ),
        ),
        ChipsFooter(
          chips: parsed.chips,
          isStreaming: widget.isStreaming,
          isExpected: hasPersistedChips || widget.chipsExpected,
          onChipTap: widget.isStreaming ? null : widget.onChipTap,
          onChipLongPress: widget.isStreaming ? null : _showChipPreview,
        ),
      ],
    );
  }
}
