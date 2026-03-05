import 'dart:io';
import 'package:flutter/material.dart';
import '../models/in_note_marker.dart';
import '../models/conversation.dart';
import '../models/conversation_attachment.dart';
import '../services/database_service.dart';
import '../services/service_locator.dart';
import '../screens/conversation_chat_screen.dart';

class InNoteMarkerPreview extends StatefulWidget {
  final InNoteMarker marker;

  const InNoteMarkerPreview({super.key, required this.marker});

  @override
  State<InNoteMarkerPreview> createState() => _InNoteMarkerPreviewState();
}

class _InNoteMarkerPreviewState extends State<InNoteMarkerPreview> {
  bool _loading = true;
  String? _imagePath;
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
    final userMessage =
        await db.getConversationMessage(widget.marker.messageId);
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

    // Find the first image attachment for the user message.
    String? imagePath;
    try {
      final attachments = await db.getConversationAttachments(
        widget.marker.messageId,
      );
      const imageExtensions = {'png', 'jpg', 'jpeg'};

      ConversationAttachment? imageAttachment;
      for (final a in attachments) {
        final ext = a.fileName.split('.').last.toLowerCase();
        if (imageExtensions.contains(ext)) {
          imageAttachment = a;
          break;
        }
        final ft = a.fileType.toLowerCase();
        if (ft.contains('png') ||
            ft.contains('jpg') ||
            ft.contains('jpeg') ||
            ft.contains('image')) {
          imageAttachment = a;
          break;
        }
      }

      if (imageAttachment != null) {
        imagePath = await imageAttachment.getAbsolutePath();
      }
    } catch (_) {
      // If attachment loading fails, show placeholder.
    }

    if (mounted) {
      setState(() {
        _userMessageContent = userContent;
        _aiReplyContent = aiContent;
        _imagePath = imagePath;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(16),
            ),
          ),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _buildContent(context, scrollController),
        );
      },
    );
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
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),

        // Captured annotation image
        _buildImageSection(context),
        const SizedBox(height: 16),

        // User message
        if (_userMessageContent != null &&
            _userMessageContent!.isNotEmpty) ...[
          Text(
            'Your message',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            _userMessageContent!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
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
        Text(
          _aiReplyContent ?? 'No response yet',
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _aiReplyContent == null
                    ? Theme.of(context).disabledColor
                    : null,
              ),
        ),
        const SizedBox(height: 20),

        // Open Conversation button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ConversationChatScreen(
                    conversationId: widget.marker.conversationId,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.chat_outlined, size: 18),
            label: const Text('Open Conversation'),
          ),
        ),
      ],
    );
  }

  Widget _buildImageSection(BuildContext context) {
    if (_imagePath == null) {
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(_imagePath!),
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

Future<void> showInNoteMarkerPreview(
  BuildContext context,
  InNoteMarker marker,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => InNoteMarkerPreview(marker: marker),
  );
}
