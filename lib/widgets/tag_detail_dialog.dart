import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/conversation.dart';
import '../models/tag.dart';
import '../services/conversation_service.dart';
import '../screens/conversation_chat_screen.dart';
import '../screens/note_detail_screen.dart';

class TagDetailDialog extends StatefulWidget {
  final String tagName;
  final Tag tag;

  const TagDetailDialog({
    super.key,
    required this.tagName,
    required this.tag,
  });

  @override
  State<TagDetailDialog> createState() => _TagDetailDialogState();
}

class _TagDetailDialogState extends State<TagDetailDialog> {
  final ConversationService _conversationService = ConversationService();
  List<Note> _notes = [];
  List<Conversation> _conversations = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      final notes = appProvider.getNotesByTag(widget.tagName);
      
      final conversations = await _conversationService.getAllConversations(
        tagNames: [widget.tagName],
      );
      
      // Filter out conversations without messages
      final List<Conversation> conversationsWithMessages = [];
      for (final conversation in conversations) {
        final withMessages = await _conversationService
            .getConversationWithMessages(conversation.id);
        if (withMessages != null && withMessages.messages.isNotEmpty) {
          conversationsWithMessages.add(conversation);
        }
      }

      if (mounted) {
        setState(() {
          _notes = notes;
          _conversations = conversationsWithMessages;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading data: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _unlinkNote(Note note) async {
    final appProvider = context.read<AppProvider>();
    try {
      await appProvider.removeTagFromNote(note.id, widget.tagName);
      if (mounted) {
        // Reload notes from provider to ensure consistency
        setState(() {
          _notes = appProvider.getNotesByTag(widget.tagName);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Tag removed from note'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error removing tag: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _unlinkConversation(Conversation conversation) async {
    final appProvider = context.read<AppProvider>();
    try {
      await _conversationService.removeTagFromConversation(
        conversation.id,
        widget.tagName,
      );
      if (mounted) {
        setState(() {
          _conversations.removeWhere((c) => c.id == conversation.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Tag removed from conversation'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      // Notify app provider to refresh tags
      appProvider.refreshTags();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error removing tag: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tagColor = Color(
      int.parse(widget.tag.color.replaceFirst('#', '0xFF')),
    );

    return Dialog(
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: tagColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.tagName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ),
            
            // Content with divider
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        // Notes section
                        Expanded(
                          flex: 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Colors.grey[300]!,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.note, size: 20),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${l10n.notes} (${_notes.length})',
                                      style: Theme.of(context)
                                          .textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: _notes.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.note_outlined,
                                              size: 48,
                                              color: Colors.grey[400],
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              l10n.noNotesAvailable,
                                              style: Theme.of(context)
                                                  .textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: Colors.grey[600],
                                                  ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.all(16),
                                        itemCount: _notes.length,
                                        itemBuilder: (context, index) {
                                          final note = _notes[index];
                                          return _buildNoteCard(
                                            context,
                                            note,
                                            l10n,
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                        
                        // Divider
                        Container(
                          height: 1,
                          color: Colors.grey[300],
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        
                        // Conversations section
                        Expanded(
                          flex: 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Colors.grey[300]!,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.chat_bubble_outline,
                                        size: 20),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${l10n.conversations} (${_conversations.length})',
                                      style: Theme.of(context)
                                          .textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: _conversations.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.chat_bubble_outline,
                                              size: 48,
                                              color: Colors.grey[400],
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              'No conversations found',
                                              style: Theme.of(context)
                                                  .textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: Colors.grey[600],
                                                  ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.all(16),
                                        itemCount: _conversations.length,
                                        itemBuilder: (context, index) {
                                          final conversation =
                                              _conversations[index];
                                          return _buildConversationCard(
                                            context,
                                            conversation,
                                            l10n,
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteCard(
    BuildContext context,
    Note note,
    AppLocalizations l10n,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => NoteDetailScreen(note: note),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (note.isTask) ...[
                          _buildStatusIcon(note),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            note.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  decoration: note.isCompleted
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      note.content,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600],
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (note.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: note.tags.take(3).map((tag) => Chip(
                              label: Text(
                                tag,
                                style: const TextStyle(fontSize: 12),
                              ),
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.1),
                              labelStyle: TextStyle(
                                color:
                                    Theme.of(context).colorScheme.primary,
                              ),
                            )).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.link_off, color: Colors.red),
                onPressed: () => _unlinkNote(note),
                tooltip: 'Remove tag',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConversationCard(
    BuildContext context,
    Conversation conversation,
    AppLocalizations l10n,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    conversation.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => ConversationChatScreen(
                              conversationId: conversation.id,
                            ),
                          ),
                        );
                      },
                      tooltip: 'Open conversation',
                    ),
                    IconButton(
                      icon: const Icon(Icons.link_off, size: 20, color: Colors.red),
                      onPressed: () => _unlinkConversation(conversation),
                      tooltip: 'Remove tag',
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            FutureBuilder<ConversationWithMessages?>(
              future: _conversationService.getConversationWithMessages(
                conversation.id,
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData ||
                    snapshot.data!.messages.isEmpty) {
                  return const SizedBox.shrink();
                }
                final messages = snapshot.data!.messages;
                return Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${l10n.first}: ${messages.first.content}',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 1,
                      height: 40,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${l10n.last}: ${messages.last.content}',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(Note note) {
    IconData iconData;
    Color? color;

    if (note.isCompleted) {
      iconData = Icons.check_circle;
      color = Colors.green;
    } else if (note.isAbandoned) {
      iconData = Icons.cancel;
      color = Colors.grey;
    } else if (note.status == TaskStatus.inProgress) {
      iconData = Icons.play_circle_outline;
      color = Colors.blue;
    } else {
      iconData = Icons.radio_button_unchecked;
      color = Colors.grey;
    }

    return Icon(iconData, color: color, size: 20);
  }
}
