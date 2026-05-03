import 'dart:io';
import 'package:flutter/material.dart';
import '../models/in_note_marker.dart';
import '../models/conversation.dart';
import '../services/database_service.dart';
import '../services/service_locator.dart';
import '../screens/conversation_chat_screen.dart';
import '../utils/file_utils.dart';
import 'interactive_checkbox_markdown.dart';
import 'marker_chat_panel_host.dart';

class InNoteMarkerPreview extends StatefulWidget {
  final InNoteMarker marker;

  const InNoteMarkerPreview({super.key, required this.marker});

  @override
  State<InNoteMarkerPreview> createState() => _InNoteMarkerPreviewState();
}

class _InNoteMarkerPreviewState extends State<InNoteMarkerPreview> {
  bool _loading = true;
  List<String> _imagePaths = [];
  String? _userMessageContent;
  String? _aiReplyContent;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final db = getIt<DatabaseService>();

    // Load user message content.
    final userMessage = await db.getConversationMessage(
      widget.marker.messageId,
    );
    final userContent = userMessage?.content;

    // Find AI reply: load all messages for the conversation, find the user
    // message by ID, then take the next message if it is an AI message.
    String? aiContent;
    try {
      final messages = await db.getConversationMessages(
        widget.marker.conversationId,
      );
      final userIndex = messages.indexWhere(
        (m) => m.id == widget.marker.messageId,
      );
      if (userIndex >= 0 && userIndex + 1 < messages.length) {
        final next = messages[userIndex + 1];
        if (next.type == MessageType.ai) {
          aiContent = next.content;
        }
      }
    } catch (_) {
      // If loading messages fails, show no reply.
    }

    // Find all image attachments for the user message.
    List<String> imagePaths = [];
    try {
      if (userMessage != null && userMessage.attachmentPaths.isNotEmpty) {
        const imageExtensions = {'png', 'jpg', 'jpeg'};
        for (final path in userMessage.attachmentPaths) {
          final ext = path.split('.').last.toLowerCase();
          if (imageExtensions.contains(ext)) {
            imagePaths.add(await FileUtils.resolvePortableAttachmentPath(path));
          }
        }
      }
    } catch (_) {
      // If attachment loading fails, continue with empty list
    }

    if (mounted) {
      setState(() {
        _userMessageContent = userContent;
        _aiReplyContent = aiContent;
        _imagePaths = imagePaths;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.marker.type == MarkerType.annotation) {
      return _buildLegacyAnnotationPreview();
    }
    return _buildAiMarkerChatPanelHost();
  }

  /// Legacy preview path used for annotation markers. Renders the
  /// captured image, the original user message, the AI reply, and a
  /// "Open Conversation" button. Behavior preserved verbatim from the
  /// pre-marker-anchored-subtree implementation.
  Widget _buildLegacyAnnotationPreview() {
    return DraggableScrollableSheet(
      key: const ValueKey('legacy-annotation-preview'),
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _buildContent(context, scrollController),
        );
      },
    );
  }

  /// AI marker preview path. Hosts ChatPanel inside the marker sheet
  /// so the user can continue the conversation in place.
  Widget _buildAiMarkerChatPanelHost() {
    return DraggableScrollableSheet(
      key: const ValueKey('ai-marker-chat-panel-host'),
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: MarkerChatPanelHost(
            marker: widget.marker,
            // resolveLastViewed implemented in Task 24 — for now use the
            // marker's recorded conversationId verbatim.
            resolvedConversationId: widget.marker.conversationId,
            contextCard: _buildAiMarkerContextCard(context),
            onActiveConversationChanged: _persistLastViewed,
          ),
        );
      },
    );
  }

  /// Tiny context card pinned at the top of the embedded ChatPanel.
  /// Reuses the legacy preview's image + user-message rendering so the
  /// reader still sees what they originally circled. Static — no deps
  /// on _loading/_userMessageContent so it can render before _loadData
  /// completes (kept as a TODO for Task 24 to refine).
  Widget _buildAiMarkerContextCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          'Marker ${widget.marker.index}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
    );
  }

  /// Stub — full persistence chain wired in Task 24.
  void _persistLastViewed(String newConversationId) {
    // Intentionally empty for Task 22.
  }

  Widget _buildContent(
    BuildContext context,
    ScrollController scrollController,
  ) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // Drag handle
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Theme.of(context).dividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Marker index header
        Text(
          'Marker ${widget.marker.index}',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),

        // Captured annotation image
        _buildImageSection(context),
        const SizedBox(height: 16),

        // User message
        if (_userMessageContent != null && _userMessageContent!.isNotEmpty) ...[
          Text(
            'Your message',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            _userMessageContent!,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
        ],

        // AI reply
        Text(
          'AI reply',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.secondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        if (_aiReplyContent != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: InteractiveCheckboxMarkdown(
                originalContent: _aiReplyContent!,
                onLinkTap: (url, _) {},
              ),
            ),
          )
        else
          Text(
            'No response yet',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).disabledColor,
            ),
          ),
        const SizedBox(height: 20),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ConversationChatScreen(
                        conversationId: widget.marker.conversationId,
                        initialMessageId: widget.marker.messageId,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.chat_outlined, size: 18),
                label: const Text('Open Conversation'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => _confirmDelete(context),
              icon: const Icon(Icons.delete_outline),
              color: Theme.of(context).colorScheme.error,
              tooltip: 'Delete Marker',
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Marker?'),
        content: const Text(
          'This will remove the marker from the note. '
          'The conversation messages will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      // Return true to indicate deletion
      Navigator.of(context).pop(true);
    }
  }

  Widget _buildImageSection(BuildContext context) {
    if (_imagePaths.isEmpty) {
      return Container(
        height: 120,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 40,
            color: Theme.of(context).disabledColor,
          ),
        ),
      );
    }

    if (_imagePaths.length == 1) {
      return _buildSingleImage(context, _imagePaths.first);
    }

    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _imagePaths.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return SizedBox(
            width: 140,
            child: _buildSingleImage(context, _imagePaths[index]),
          );
        },
      ),
    );
  }

  Widget _buildSingleImage(BuildContext context, String path) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(path),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) {
          return Container(
            height: 120,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 40,
                color: Theme.of(context).disabledColor,
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<bool?> showInNoteMarkerPreview(
  BuildContext context,
  InNoteMarker marker,
) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => InNoteMarkerPreview(marker: marker),
  );
}
