import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chip_action.dart';
import '../models/conversation.dart';
import '../models/conversation_branch_summary.dart';
import '../services/conversation_service.dart';
import '../services/fork_service.dart';
import '../services/service_locator.dart';
import 'block_markdown_body.dart';

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
  // ignore: unused_field, wired in Task 18 for active-branch metadata.
  Conversation? _conversation;
  List<ConversationMessage> _messages = const [];
  // ignore: unused_field, populated here for Task 16's branch strip.
  Map<String, List<ConversationBranchSummary>> _branchesByParent = const {};
  // ignore: unused_field, populated here for Task 16's chip footer.
  final Map<String, List<ChipAction>> _chipsByMessage = {};
  StreamSubscription<String>? _forkSub;

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
    // Refresh branches map; cheap because the query is batched.
    final branches = await getIt<ConversationService>()
        .getAllForkPointBranches(widget.conversationId);
    if (!mounted) return;
    setState(() => _branchesByParent = branches);
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
              ],
            ],
          ),
        ),
      ],
    );
  }
}
