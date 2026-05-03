import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/chip_action.dart';
import '../models/conversation.dart';
import '../models/conversation_branch_summary.dart';
import '../services/chip_tap_handler.dart';
import '../services/chips_block_parser.dart';
import '../services/conversation_service.dart';
import '../services/fork_service.dart';
import '../services/service_locator.dart';
import 'chat_message_action_row.dart';
import 'chip_preview_popover.dart';
import 'chips_footer.dart';
import 'interactive_checkbox_markdown.dart';
import 'message_branch_strip.dart';

/// Marker-anchored chat panel.
///
/// Renders a conversation as right-aligned user bubbles and left-aligned AI
/// bubbles (mirroring the immersive note screen's chat look-and-feel) with:
/// - synchronously-extracted chip actions (no `BlockMarkdownBody` dependency),
/// - an optional [contextCard] pinned at the top,
/// - an optional "streaming bubble" tail driven by [streamingContent],
/// - per-message branch strips below messages with sibling branches,
/// - per-AI-message chip footer + chip preview popover,
/// - per-AI-message tool-usage indicator (when [onShowToolDetails] is wired),
/// - per-AI-message Copy / Add-to-note action row (when both callbacks wired),
/// - per-user-message edit affordance (when [onUserMessageEdit] is wired).
class ChatPanel extends StatefulWidget {
  /// The conversation whose messages this panel renders.
  final String conversationId;

  /// If non-null, the panel scrolls to this message after first paint.
  final String? initialMessageId;

  /// Optional widget pinned at the top of the panel (e.g. an in-note
  /// marker preview card or a "this is a sub-conversation" banner).
  final Widget? contextCard;

  /// Fired when the user switches branches via [MessageBranchStrip].
  /// [forkPointMessageId] is the message at which the branches diverged —
  /// hosts use this to re-render with `initialMessageId = forkPointMessageId`
  /// so the new branch lands with the fork-point at viewport top.
  final void Function(String newConversationId, String forkPointMessageId)
      onActiveConversationChanged;

  /// True while the parent message is generating; disables chip taps and
  /// branch-strip taps to avoid race conditions.
  final bool isStreaming;

  /// Sends a user prompt to the active conversation.
  final Future<void> Function(String conversationId, String prompt)
      onSendUserPrompt;

  /// Live partial text shown as a "streaming bubble" tail when non-null.
  /// Parent updates this on each AI chunk; when null, no tail is rendered.
  final String? streamingContent;

  /// Fired when the user taps the edit icon on one of THEIR messages
  /// (typical immersive UX: copy content back into the input field).
  /// If null, no edit icon is shown.
  final void Function(ConversationMessage)? onUserMessageEdit;

  /// Fired when the user taps the tool-usage icon on an AI message that
  /// has `parts_history` or `function_calls` metadata. If null, no icon
  /// is shown even if the message has tool metadata.
  final void Function(ConversationMessage)? onShowToolDetails;

  /// Fired when the user taps the "Copy" affordance on an AI message
  /// (under-bubble action row). If null AND [onAddAiMessageToNote] is also
  /// null, the action row is hidden entirely.
  final void Function(ConversationMessage)? onCopyAiMessage;

  /// Fired when the user taps the "Add to note" affordance on an AI
  /// message (under-bubble action row). If null AND [onCopyAiMessage] is
  /// also null, the action row is hidden entirely.
  final void Function(ConversationMessage)? onAddAiMessageToNote;

  const ChatPanel({
    super.key,
    required this.conversationId,
    required this.isStreaming,
    required this.onActiveConversationChanged,
    required this.onSendUserPrompt,
    this.initialMessageId,
    this.contextCard,
    this.streamingContent,
    this.onUserMessageEdit,
    this.onShowToolDetails,
    this.onCopyAiMessage,
    this.onAddAiMessageToNote,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  Conversation? _conversation;
  List<ConversationMessage> _messages = const [];
  Map<String, List<ConversationBranchSummary>> _branchesByParent = const {};

  /// Cache: messageId -> chip actions parsed out of the AI message body.
  /// Populated synchronously during build via [ChipsBlockParser]; never
  /// recomputed for the same (id + content) pair.
  final Map<String, List<ChipAction>> _chipsByMessage = {};

  /// Cache: messageId -> markdown with all `chips` fenced blocks removed.
  /// Sibling to [_chipsByMessage]; same key + invalidation policy.
  final Map<String, String> _strippedByMessage = {};

  /// Cache: messageId -> the raw content string used to populate the two
  /// caches above. If a message body changes (e.g. live streaming updates
  /// an in-place AI reply), we re-parse on the next build.
  final Map<String, String> _contentSnapshotByMessage = {};

  final ChipsBlockParser _chipsParser = ChipsBlockParser();

  StreamSubscription<String>? _forkSub;
  OverlayEntry? _activePreview;

  // Scroll plumbing for [ChatPanel.initialMessageId]. We hand a [GlobalKey]
  // to each per-message bubble container so we can locate it after the first
  // frame and call [Scrollable.ensureVisible] to land on the right message.
  // Because [ListView.builder] is lazy, the initial target may not be built
  // yet — we coarse-jump first, then re-attempt up to a small retry cap to
  // avoid a [pumpAndSettle] deadlock.
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _messageKeys = {};

  GlobalKey _keyFor(String id) =>
      _messageKeys.putIfAbsent(id, () => GlobalKey());

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
      _strippedByMessage.clear();
      _contentSnapshotByMessage.clear();
      _messageKeys.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _forkSub?.cancel();
    _activePreview?.remove();
    _activePreview = null;
    _scrollController.dispose();
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
    if (widget.initialMessageId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToInitialMessage(widget.initialMessageId!, attempt: 0);
      });
    }
  }

  /// Scrolls the viewport so the message with [id] is visible.
  ///
  /// [ListView.builder] is lazy: a key for an off-screen target may not have
  /// a [BuildContext] yet. We do a coarse [jumpTo] estimate first to force
  /// the items near the target to build, then call
  /// [Scrollable.ensureVisible] on the next frame for an exact landing.
  /// Capped at 3 attempts so [pumpAndSettle] never hangs.
  void _scrollToInitialMessage(String id, {required int attempt}) {
    if (!mounted) return;
    if (attempt > 3) return;
    final key = _messageKeys[id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: Duration.zero,
        alignment: 0.0,
      );
      return;
    }
    // Target hasn't been laid out yet. Coarse-jump toward its likely
    // offset and retry next frame.
    if (_scrollController.hasClients && _messages.isNotEmpty) {
      final idx = _messages.indexWhere((m) => m.id == id);
      if (idx >= 0) {
        final position = _scrollController.position;
        final maxExtent = position.maxScrollExtent;
        final fraction = idx / _messages.length;
        final target = (fraction * maxExtent).clamp(0.0, maxExtent);
        _scrollController.jumpTo(target);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToInitialMessage(id, attempt: attempt + 1);
    });
  }

  void _onForkCreated(String parentMessageId) async {
    // Capture the conversationId at dispatch time so a mid-flight branch
    // switch doesn't apply this conversation's branches to a different one.
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

  /// Returns true if the AI action row should render. The row is hidden
  /// unless at least one of the action callbacks is wired; when only one
  /// is wired, the unwired button renders disabled (onPressed: null).
  bool _shouldShowActionRow() {
    return widget.onCopyAiMessage != null ||
        widget.onAddAiMessageToNote != null;
  }

  /// Returns true when the message has the metadata keys that indicate the
  /// AI used tools (parts_history / function_calls) AND the host wired a
  /// tool-details callback. Both conditions must hold for the icon to show.
  bool _hasToolMetadata(ConversationMessage m) {
    if (widget.onShowToolDetails == null) return false;
    final meta = m.metadata;
    if (meta == null) return false;
    return meta.containsKey('parts_history') ||
        meta.containsKey('function_calls');
  }

  /// Returns the (chips, stripped) pair for an AI message, parsing on first
  /// access and re-parsing only when the content changes. User messages get
  /// a (const [], original content) result without invoking the parser.
  ({List<ChipAction> chips, String stripped}) _chipsFor(ConversationMessage m) {
    if (m.type != MessageType.ai) {
      return (chips: const [], stripped: m.content);
    }
    final snapshot = _contentSnapshotByMessage[m.id];
    if (snapshot != m.content) {
      final parsed = _chipsParser.parse(m.content);
      _chipsByMessage[m.id] = parsed.chips;
      _strippedByMessage[m.id] = parsed.strippedMarkdown;
      _contentSnapshotByMessage[m.id] = m.content;
    }
    return (
      chips: _chipsByMessage[m.id] ?? const [],
      stripped: _strippedByMessage[m.id] ?? m.content,
    );
  }

  /// Localized "AI" header label. Falls back to the literal string "AI"
  /// when the host doesn't provide [AppLocalizations] (e.g. unit tests that
  /// build `MaterialApp` without `localizationsDelegates`).
  String _aiLabel(BuildContext context) =>
      AppLocalizations.of(context)?.ai ?? 'AI';

  @override
  Widget build(BuildContext context) {
    final hasStreamingTail = widget.streamingContent != null;
    final itemCount = _messages.length + (hasStreamingTail ? 1 : 0);

    return Column(
      children: [
        if (widget.contextCard != null) widget.contextCard!,
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (hasStreamingTail && index == _messages.length) {
                return _buildStreamingBubble(context);
              }
              return _buildMessageItem(context, _messages[index]);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStreamingBubble(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: const ValueKey('chat_panel_streaming_message'),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.7,
          ),
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAiHeader(context, trailing: null),
              const SizedBox(height: 8),
              SelectableText(widget.streamingContent ?? ''),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageItem(
    BuildContext context,
    ConversationMessage m,
  ) {
    final isUser = m.type == MessageType.user;
    return Column(
      key: ValueKey('chat_panel_msg_col_${m.id}'),
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (isUser)
          _buildUserBubble(context, m)
        else
          _buildAiBubble(context, m),
        // Chip footer (above branch strip per spec) — AI messages only.
        if (m.type == MessageType.ai)
          ChipsFooter(
            chips: _chipsByMessage[m.id],
            isStreaming:
                widget.isStreaming && m.id == _messages.last.id,
            isExpected: _isChipsExpected(),
            onChipTap: widget.isStreaming
                ? null
                : (chip) => _handleChipTap(m.id, chip),
            onChipLongPress: widget.isStreaming
                ? null
                : (chip, anchorKey) => _showChipPreview(chip, anchorKey),
          ),
        // Branch strip — only when at least 2 sibling branches exist off
        // this fork-point message. Gated at the call site for clarity even
        // though MessageBranchStrip also short-circuits.
        if ((_branchesByParent[m.id] ?? const []).length >= 2)
          MessageBranchStrip(
            branches: _branchesByParent[m.id]!,
            activeConversationId: widget.conversationId,
            activeNoteIds: _conversation?.noteIds ?? const [],
            disabled: widget.isStreaming,
            onSwitchBranch: (newId, _) =>
                widget.onActiveConversationChanged(newId, m.id),
          ),
      ],
    );
  }

  Widget _buildUserBubble(BuildContext context, ConversationMessage m) {
    final scheme = Theme.of(context).colorScheme;
    final showEdit = widget.onUserMessageEdit != null;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        key: _keyFor(m.id),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SelectableText(
                m.content,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurface),
              ),
            ),
            if (showEdit) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  Icons.edit,
                  size: 16,
                  color: scheme.onSurface.withOpacity(0.5),
                ),
                tooltip: 'Use this message',
                onPressed: () => widget.onUserMessageEdit!(m),
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                padding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAiBubble(
    BuildContext context,
    ConversationMessage m,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = _chipsFor(m);
    final showActions = _shouldShowActionRow();
    final hasTools = _hasToolMetadata(m);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: _keyFor(m.id),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAiHeader(
              context,
              trailing: hasTools
                  ? IconButton(
                      icon: const Icon(
                        Icons.build_circle_outlined,
                        size: 18,
                      ),
                      tooltip: 'View Tool Usage',
                      onPressed: () => widget.onShowToolDetails!(m),
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            SelectionArea(
              child: InteractiveCheckboxMarkdown(
                originalContent: parsed.stripped,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurface),
                // Markdown link tap handling deferred to a follow-up task.
                onLinkTap: null,
              ),
            ),
            // TODO(task-22): render attachment chips here for messages with
            // m.attachmentPaths.isNotEmpty (mirrors immersive screen's
            // _buildMessageAttachmentChips).
            if (showActions) ...[
              const SizedBox(height: 12),
              ChatMessageActionRow(
                onCopy: widget.onCopyAiMessage == null
                    ? () {}
                    : () => widget.onCopyAiMessage!(m),
                onAddNote: widget.onAddAiMessageToNote == null
                    ? () {}
                    : () => widget.onAddAiMessageToNote!(m),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAiHeader(
    BuildContext context, {
    required Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.smart_toy, size: 16, color: scheme.secondary),
        const SizedBox(width: 8),
        Text(
          _aiLabel(context),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.secondary,
                fontWeight: FontWeight.bold,
              ),
        ),
        const Spacer(),
        if (trailing != null) trailing,
      ],
    );
  }
}
