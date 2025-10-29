import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../screens/conversation_chat_screen.dart';

class LinearHistoryDialog extends StatefulWidget {
  final Duration initialTimeRange;
  final ValueChanged<Duration> onTimeRangeChanged;

  const LinearHistoryDialog({
    Key? key,
    required this.initialTimeRange,
    required this.onTimeRangeChanged,
  }) : super(key: key);

  @override
  State<LinearHistoryDialog> createState() => _LinearHistoryDialogState();
}

class _LinearHistoryDialogState extends State<LinearHistoryDialog> {
  final ConversationService _conversationService = ConversationService();
  List<Conversation> _conversations = [];
  late Duration _selectedTimeRange;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _selectedTimeRange = widget.initialTimeRange;
    _loadConversations();
    _conversationService.deleteEmptyConversations(olderThan: const Duration(days: 1));
  }

  Future<void> _loadConversations() async {
    setState(() => _isLoading = true);
    final conversations = await _conversationService.getAllConversations(maxAge: _selectedTimeRange);
    final List<Conversation> conversationsWithMessages = [];
    for (final conversation in conversations) {
      final withMessages = await _conversationService.getConversationWithMessages(conversation.id);
      if (withMessages != null && withMessages.messages.isNotEmpty) {
        conversationsWithMessages.add(conversation);
      }
    }
    setState(() {
      _conversations = conversationsWithMessages;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(child: Text('Conversations')),
            _buildTimeRangeFilter(),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _conversations.length,
              itemBuilder: (context, index) {
                final conversation = _conversations[index];
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
                            Expanded(child: Text(conversation.title, style: Theme.of(context).textTheme.titleMedium)),
                            Row(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.open_in_new),
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => ConversationChatScreen(conversationId: conversation.id),
                                      ),
                                    );
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () async {
                                    await _conversationService.deleteConversation(conversation.id);
                                    _loadConversations();
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        FutureBuilder<ConversationWithMessages?>(
                          future: _conversationService.getConversationWithMessages(conversation.id),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData || snapshot.data!.messages.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            final messages = snapshot.data!.messages;
                            return Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'First: ${messages.first.content}',
                                    style: Theme.of(context).textTheme.bodySmall,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(width: 1, height: 40, color: Colors.grey),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Last: ${messages.last.content}',
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
              },
            ),
    );
  }

  Widget _buildTimeRangeFilter() {
    return DropdownButton<Duration>(
      value: _selectedTimeRange,
      onChanged: (Duration? value) {
        if (value != null) {
          setState(() {
            _selectedTimeRange = value;
            widget.onTimeRangeChanged(_selectedTimeRange);
            _loadConversations();
          });
        }
      },
      items: const [
        DropdownMenuItem(
          value: Duration(hours: 1),
          child: Text('1 hour ago'),
        ),
        DropdownMenuItem(
          value: Duration(hours: 12),
          child: Text('12 hours ago'),
        ),
        DropdownMenuItem(
          value: Duration(days: 1),
          child: Text('1 day ago'),
        ),
        DropdownMenuItem(
          value: Duration(days: 3),
          child: Text('3 days ago'),
        ),
        DropdownMenuItem(
          value: Duration(days: 7),
          child: Text('7 days ago'),
        ),
        DropdownMenuItem(
          value: Duration(days: 15),
          child: Text('15 days ago'),
        ),
        DropdownMenuItem(
          value: Duration(days: 30),
          child: Text('1 month ago'),
        ),
        DropdownMenuItem(
          value: Duration(days: 180),
          child: Text('6 months ago'),
        ),
        DropdownMenuItem(
          value: Duration(days: 365 * 10),
          child: Text('All time'),
        ),
      ],
    );
  }
}
