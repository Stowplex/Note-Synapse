import 'package:flutter/material.dart';

import '../models/in_note_marker.dart';
import '../models/model_config.dart';
import 'chat_panel.dart';
import 'model_selector_button.dart';

/// Hosts [ChatPanel] inside the marker bottom sheet, adding a text input
/// row, model picker, and send button below the panel. Visible to the
/// user when they tap an AI-type marker on a note.
///
/// Send orchestration is wired in Task 23. For now [_runSendOrchestration]
/// is a no-op stub that completes immediately.
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
  bool _isSending = false;
  ModelConfig? _selectedModel;
  String? _initialMessageId;

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
            conversationId: widget.resolvedConversationId,
            initialMessageId: _initialMessageId,
            contextCard: widget.contextCard,
            isStreaming: _isSending,
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

  /// Stub — wired to ConversationAiEngine in Task 23.
  Future<void> _runSendOrchestration(
    String conversationId,
    String prompt,
  ) async {
    // Intentionally empty for Task 22.
  }
}
