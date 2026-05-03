import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/in_note_marker.dart';
import '../models/model_config.dart';
import '../services/agent_service.dart';
import '../services/conversation_ai_engine.dart';
import '../services/marker_chat_send_service.dart';
import '../services/service_locator.dart';
import 'chat_panel.dart';
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
  });

  @override
  State<MarkerChatPanelHost> createState() => _MarkerChatPanelHostState();
}

class _MarkerChatPanelHostState extends State<MarkerChatPanelHost> {
  final TextEditingController _textController = TextEditingController();
  final GlobalKey<ChatPanelState> _chatPanelKey = GlobalKey<ChatPanelState>();
  bool _isSending = false;
  ModelConfig? _selectedModel;
  String? _initialMessageId;

  /// Live partial AI text fed to [ChatPanel.streamingContent] during
  /// generation. Cleared when the request completes (success or failure).
  String? _streamingContent;

  @override
  void initState() {
    super.initState();
    _initialMessageId = widget.marker.messageId;
  }

  @override
  void dispose() {
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
            conversationId: widget.resolvedConversationId,
            initialMessageId: _initialMessageId,
            contextCard: widget.contextCard,
            isStreaming: _isSending,
            streamingContent: _streamingContent,
            onActiveConversationChanged: (newId, forkPoint) {
              widget.onActiveConversationChanged(newId);
              setState(() => _initialMessageId = forkPoint);
            },
            onSendUserPrompt: _sendPrompt,
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ModelSelectorButton(
                  selectedModel: _selectedModel,
                  onModelSelected: (m) => setState(() => _selectedModel = m),
                ),
                const SizedBox(width: 8),
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
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _isSending
                      ? null
                      : () => _onSubmit(_textController.text),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onSubmit(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    _textController.clear();
    await _sendPrompt(widget.resolvedConversationId, t);
  }

  Future<void> _sendPrompt(String conversationId, String prompt) async {
    setState(() => _isSending = true);
    try {
      await _runSendOrchestration(conversationId, prompt);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Delegates to [MarkerChatSendService.sendUserPrompt]. Streams partial
  /// AI text into [_streamingContent], then on completion reloads the
  /// embedded [ChatPanel] so the persisted user + AI messages appear.
  Future<void> _runSendOrchestration(
    String conversationId,
    String prompt,
  ) async {
    final agentService = context.read<AgentService>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _streamingContent = '');
    try {
      await getIt<MarkerChatSendService>().sendUserPrompt(
        conversationId: conversationId,
        prompt: prompt,
        agentService: agentService,
        modelOverride: _selectedModel,
        onStreamChunk: (chunk) {
          if (!mounted) return;
          setState(() {
            _streamingContent = (_streamingContent ?? '') + chunk;
          });
        },
        onCompleted: () {
          if (!mounted) return;
          setState(() => _streamingContent = null);
          _chatPanelKey.currentState?.reload();
        },
      );
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
        messenger.showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    }
  }
}
