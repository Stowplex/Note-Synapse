import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chip_action.dart';
import '../models/conversation.dart';
import '../models/conversation_branch_summary.dart';
import '../services/chip_tap_handler.dart';
import '../services/conversation_service.dart';
import '../services/fork_service.dart';
import '../services/service_locator.dart';
import 'block_markdown_body.dart';
import 'chip_preview_popover.dart';
import 'chips_footer.dart';
import 'message_branch_strip.dart';

/// Marker-anchored chat panel.
///
/// Task 15 skeleton: loads conversation + messages + branch summaries on
/// mount, subscribes to [ForkService.forkCreatedStream] to refresh the
/// branch map when a fork happens, and renders an optional [contextCard]
/// pinned at the top above a scrollable list of message bodies.
///
/// Subsequent tasks (16-19) will:
/// - render [MessageBranchStrip] under fork-point messages,
/// - render [ChipsFooter] under AI messages,
/// - wire chip taps + chip preview popover,
/// - honor [initialMessageId] for scroll-to behavior, and
/// - notify via [onActiveConversationChanged] when the active branch changes.
class ChatPanel extends StatefulWidget {
  /// The conversation whose messages this panel renders.
  final String conversationId;

  /// If non-null, the panel scrolls to this message after first paint.
  /// Honored in Task 18.
  final String? initialMessageId;

  /// Optional widget pinned at the top of the panel (e.g. an in-note
  /// marker preview card or a "this is a sub-conversation" banner).
  final Widget? contextCard;

  /// Fired when the user switches branches via [MessageBranchStrip] in
  /// Task 18. Signature widens in later tasks (Task 18/20).
  final ValueChanged<String> onActiveConversationChanged;

  /// True while the parent message is generating; disables chip taps and
  /// branch-strip taps to avoid race conditions. Wired in Tasks 16-17.
  final bool isStreaming;

  /// Sends a user prompt to the active conversation. Wired in Task 17 for
  /// chip-tap follow-ups and (eventually) in Task 22 for the marker chat
  /// composer.
  final Future<void> Function(String conversationId, String prompt)
      onSendUserPrompt;

  const ChatPanel({
    super.key,
    required this.conversationId,
    required this.isStreaming,
    required this.onActiveConversationChanged,
    required this.onSendUserPrompt,
    this.initialMessageId,
    this.contextCard,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  Conversation? _conversation;
  List<ConversationMessage> _messages = const [];
  Map<String, List<ConversationBranchSummary>> _branchesByParent = const {};
  final Map<String, List<ChipAction>> _chipsByMessage = {};
  StreamSubscription<String>? _forkSub;
  OverlayEntry? _activePreview;

  @override
  void initState() {
    super.initState();
    _load();
    _forkSub = getIt<ForkService>().forkCreatedStream.listen(_onForkCreated);
  }

  @override
  void didUpdateWidget(covariant ChatPanel old) {
    super.didUpdateWidget(old);
    if (old.conversationId != widget.conversationId) {
      _branchesByParent = const {};
      _chipsByMessage.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _forkSub?.cancel();
    _activePreview?.remove();
    _activePreview = null;
    super.dispose();
  }

  Future<void> _load() async {
    final conv = getIt<ConversationService>();
    final loaded = await conv.getConversation(widget.conversationId);
    final msgs = await conv.getConversationMessages(widget.conversationId);
    final branches = await conv.getAllForkPointBranches(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _conversation = loaded;
      _messages = msgs;
      _branchesByParent = branches;
    });
  }

  void _onForkCreated(String parentMessageId) async {
    // Capture the conversationId at dispatch time so a mid-flight branch
    // switch (Task 18) doesn't apply this conversation's branches to a
    // different one.
    final cid = widget.conversationId;
    final branches = await getIt<ConversationService>()
        .getAllForkPointBranches(cid);
    if (!mounted || cid != widget.conversationId) return;
    setState(() => _branchesByParent = branches);
  }

  bool _isChipsExpected() {
    final conv = getIt<ConversationService>();
    return conv.skillsEnabled &&
        conv.skillIndex.values.any((s) => s.defaultAction != null);
  }

  Future<void> _handleChipTap(String parentMessageId, ChipAction chip) async {
    await ChipTapHandler().handle(
      parentMessageId: parentMessageId,
      chip: chip,
      sourceConversationId: widget.conversationId,
      onSendUserPrompt: widget.onSendUserPrompt,
    );
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
    return Column(
      children: [
        if (widget.contextCard != null) widget.contextCard!,
        Expanded(
          child: CustomScrollView(
            slivers: [
              for (final m in _messages) ...[
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  // NOTE: noteId is reused as a cache-scope/key prefix for
                  // BlockMarkdownBody. Checkbox toggles inside chat messages
                  // are non-persistent here (no onContentChanged wired). If
                  // a future flow ever lets users tick checkboxes inside an
                  // AI reply, route the toggle through ConversationService.
                  sliver: BlockMarkdownBody(
                    key: ValueKey('chat_msg_${m.id}'),
                    noteId: m.conversationId,
                    content: m.content,
                    onChipsExtracted: m.type == MessageType.ai
                        ? (chips) {
                            if (!mounted) return;
                            setState(() => _chipsByMessage[m.id] = chips);
                          }
                        : null,
                  ),
                ),
                // Chip footer (above branch strip per spec) — AI messages only.
                if (m.type == MessageType.ai)
                  SliverToBoxAdapter(
                    child: ChipsFooter(
                      chips: _chipsByMessage[m.id],
                      isStreaming:
                          widget.isStreaming && m.id == _messages.last.id,
                      isExpected: _isChipsExpected(),
                      onChipTap: widget.isStreaming
                          ? null
                          : (chip) => _handleChipTap(m.id, chip),
                      onChipLongPress: widget.isStreaming
                          ? null
                          : (chip, anchorKey) =>
                              _showChipPreview(chip, anchorKey),
                    ),
                  ),
                // Branch strip — only when at least 2 sibling branches exist
                // off this fork-point message. Gated at the call site for
                // clarity even though MessageBranchStrip also short-circuits.
                if ((_branchesByParent[m.id] ?? const []).length >= 2)
                  SliverToBoxAdapter(
                    child: MessageBranchStrip(
                      branches: _branchesByParent[m.id]!,
                      activeConversationId: widget.conversationId,
                      activeNoteIds: _conversation?.noteIds ?? const [],
                      disabled: widget.isStreaming,
                      onSwitchBranch: (newId, _) =>
                          widget.onActiveConversationChanged(newId),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
