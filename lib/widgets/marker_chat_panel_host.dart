import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/in_note_marker.dart';
import '../mixins/note_action_mixin.dart';
import '../services/agent_service.dart';
import '../services/chat_tool_session.dart';
import '../services/conversation_service.dart';
import '../services/conversation_ai_engine.dart';
import '../services/marker_chat_send_service.dart';
import '../services/service_locator.dart';
import '../utils/conversation_title_directive.dart';
import 'chat_panel.dart';
import 'chat_tool_selection_panel.dart';
import 'model_selector_button.dart';

/// Hosts [ChatPanel] inside the marker bottom sheet, adding a text input
/// row, model picker, and send button below the panel. Visible to the
/// user when they tap an AI-type marker on a note.
///
/// Send orchestration is delegated to [MarkerChatSendService] (Task 23):
/// addUserMessage → ConversationAiEngine.generate → addAIResponse, with
/// streamed partials surfaced through [_streamingContent] and a final
/// [ChatPanel.reload] to bring the persisted messages into view.
class MarkerChatPanelHost extends StatefulWidget {
  final InNoteMarker marker;
  final String resolvedConversationId;
  final Widget contextCard;
  final ScrollController? scrollController;

  /// Fired when the user switches branches via the embedded [ChatPanel].
  /// Caller is responsible for persisting `lastViewedConversationId` on
  /// the marker (Task 24).
  final void Function(String newConversationId) onActiveConversationChanged;

  const MarkerChatPanelHost({
    super.key,
    required this.marker,
    required this.resolvedConversationId,
    required this.contextCard,
    required this.onActiveConversationChanged,
    this.scrollController,
  });

  @override
  State<MarkerChatPanelHost> createState() => _MarkerChatPanelHostState();
}

class _MarkerChatPanelHostState extends State<MarkerChatPanelHost>
    with NoteActionMixin<MarkerChatPanelHost> {
  final TextEditingController _textController = TextEditingController();
  final GlobalKey<ChatPanelState> _chatPanelKey = GlobalKey<ChatPanelState>();
  late final ChatToolSession _toolSession = ChatToolSession(
    initialSkillsEnabled: true,
    statusLabelBuilder: (serviceName, toolName) => '$serviceName -> $toolName',
  );
  bool _isSending = false;
  late String _activeConversationId;
  String? _initialMessageId;
  bool _didInitTools = false;

  /// Live partial AI text fed to [ChatPanel.streamingContent] during
  /// generation. Cleared when the request completes (success or failure).
  String? _streamingContent;

  @override
  void initState() {
    super.initState();
    _activeConversationId = widget.resolvedConversationId;
    _initialMessageId = widget.marker.messageId;
    _toolSession.addListener(_onToolSessionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didInitTools) {
      _didInitTools = true;
      _toolSession.initialize(context);
    }
  }

  void _onToolSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MarkerChatPanelHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.marker.id != widget.marker.id ||
        oldWidget.resolvedConversationId != widget.resolvedConversationId) {
      _activeConversationId = widget.resolvedConversationId;
      _initialMessageId = widget.marker.messageId;
      _streamingContent = null;
      _isSending = false;
    }
  }

  @override
  void dispose() {
    _toolSession.removeListener(_onToolSessionChanged);
    _toolSession.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('ai-marker-chat-panel-host-content'),
      children: [
        Expanded(
          child: ChatPanel(
            key: _chatPanelKey,
            conversationId: _activeConversationId,
            initialMessageId: _initialMessageId,
            contextCard: widget.contextCard,
            scrollController: widget.scrollController,
            isStreaming: _isSending,
            streamingContent: _streamingContent,
            onActiveConversationChanged: (newId, forkPoint) {
              setState(() {
                _activeConversationId = newId;
                _initialMessageId = forkPoint;
              });
              widget.onActiveConversationChanged(newId);
            },
            onSendUserPrompt: _continueAfterExistingPrompt,
            onCopyAiMessage: (message) =>
                copyContentToClipboard(message.content),
            onAddAiMessageToNote: (message) async {
              final notes = await getIt<ConversationService>()
                  .getConversationNotes(_activeConversationId);
              if (!mounted) return;
              await handleAddContentToNote(
                content: message.content,
                contextNotes: notes,
              );
            },
          ),
        ),
        if (!_isSending && _toolSession.hasAvailableTools)
          ChatToolSelectionPanel(
            session: _toolSession,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            maxHeight: MediaQuery.of(context).size.height * 0.3,
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildToolExecutionIndicator(),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        enabled: !_isSending,
                        decoration: const InputDecoration(
                          hintText: 'Continue this exploration...',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: _isSending ? null : _onSubmit,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: _isSending
                              ? null
                              : () => _onSubmit(_textController.text),
                        ),
                        ModelSelectorButton(
                          selectedModel: _toolSession.selectedModel,
                          onModelSelected: (m) {
                            _toolSession.setSelectedModel(m);
                            _toolSession.refreshForModel(context);
                          },
                          isSendButton: true,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToolExecutionIndicator() {
    final prompt = _toolSession.iterationPrompt;
    if (prompt != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const Icon(Icons.loop, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Tool iteration limit reached (${prompt.exhaustedIterations}).',
              ),
            ),
            TextButton(
              onPressed: () => _toolSession.resolveIterationPrompt(
                prompt.exhaustedIterations + 5,
              ),
              child: const Text('Continue'),
            ),
            TextButton(
              onPressed: () => _toolSession.resolveIterationPrompt(null),
              child: const Text('Abort'),
            ),
          ],
        ),
      );
    }
    final status = _toolSession.toolExecutionStatus;
    if (status == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Future<void> _onSubmit(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    _textController.clear();
    await _sendNewPrompt(_activeConversationId, t);
  }

  Future<void> _sendNewPrompt(String conversationId, String prompt) async {
    setState(() => _isSending = true);
    try {
      await getIt<ConversationService>().addUserMessage(
        conversationId: conversationId,
        content: prompt,
      );
      await _chatPanelKey.currentState?.reload();
      await _runSendOrchestration(
        conversationId: conversationId,
        prompt: prompt,
        promptAlreadyPersisted: true,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _continueAfterExistingPrompt(
    String conversationId,
    String prompt,
  ) async {
    setState(() => _isSending = true);
    try {
      await _runSendOrchestration(
        conversationId: conversationId,
        prompt: prompt,
        promptAlreadyPersisted: true,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Delegates to [MarkerChatSendService.sendUserPrompt]. Streams partial
  /// AI text into [_streamingContent], then on completion reloads the
  /// embedded [ChatPanel] so the persisted user + AI messages appear.
  Future<void> _runSendOrchestration({
    required String conversationId,
    required String prompt,
    required bool promptAlreadyPersisted,
  }) async {
    final agentService = context.read<AgentService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _chatPanelKey.currentState?.reload();
      final sendService = getIt<MarkerChatSendService>();
      final titleStreamFilter = ConversationTitleStreamFilter();
      final onStreamChunk = (String chunk) {
        final visibleChunk = titleStreamFilter.addChunk(chunk);
        if (visibleChunk.isEmpty) return;
        if (!mounted) return;
        setState(() {
          _streamingContent = (_streamingContent ?? '') + visibleChunk;
        });
      };
      final onCompleted = () {
        if (!mounted) return;
        setState(() => _streamingContent = null);
        _chatPanelKey.currentState?.reload();
      };
      if (promptAlreadyPersisted) {
        await sendService.continueAfterExistingUserPrompt(
          conversationId: conversationId,
          agentService: agentService,
          toolSession: _toolSession,
          toolContext: context,
          modelOverride: _toolSession.selectedModel,
          currentPdfPage: widget.marker.page,
          onStreamChunk: onStreamChunk,
          onCompleted: onCompleted,
        );
      } else {
        await sendService.sendNewUserPrompt(
          conversationId: conversationId,
          prompt: prompt,
          agentService: agentService,
          toolSession: _toolSession,
          toolContext: context,
          modelOverride: _toolSession.selectedModel,
          currentPdfPage: widget.marker.page,
          onStreamChunk: onStreamChunk,
          onCompleted: onCompleted,
        );
      }
    } on ConversationCancelledException {
      if (mounted) {
        setState(() => _streamingContent = null);
        messenger.showSnackBar(
          const SnackBar(content: Text('AI request cancelled.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _streamingContent = null);
        messenger.showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    }
  }
}
