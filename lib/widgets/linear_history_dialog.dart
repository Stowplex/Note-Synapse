import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../screens/conversation_chat_screen.dart';

class LinearHistoryDialog extends StatefulWidget {
  const LinearHistoryDialog({Key? key}) : super(key: key);

  @override
  State<LinearHistoryDialog> createState() => _LinearHistoryDialogState();
}

class _LinearHistoryDialogState extends State<LinearHistoryDialog> {
  final ConversationService _conversationService = ConversationService();
  List<Conversation> _conversations = [];
  Duration _selectedTimeRange = const Duration(days: 3);
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConversations();
  }

  Future<void> _loadConversations() async {
    setState(() => _isLoading = true);
    final conversations = await _conversationService.getAllConversations(maxAge: _selectedTimeRange);
    setState(() {
      _conversations = conversations;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Linear Conversation History'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTimeRangeFilter(),
            const SizedBox(height: 16),
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : Expanded(
                    child: ListView.builder(
                      itemCount: _conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = _conversations[index];
                        return Card(
                          child: ListTile(
                            title: Text(conversation.title),
                            subtitle: Text('Last updated: ${_getFormattedDuration(DateTime.now().difference(conversation.updatedAt))}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
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
                          ),
                        );
                      },
                    ),
                  ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildTimeRangeFilter() {
    return DropdownButton<Duration>(
      value: _selectedTimeRange,
      onChanged: (Duration? value) {
        if (value != null) {
          setState(() {
            _selectedTimeRange = value;
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

  String _getFormattedDuration(Duration duration) {
    if (duration.inHours < 1) {
      return '${duration.inMinutes}m ago';
    } else if (duration.inDays < 1) {
      return '${duration.inHours}h ago';
    } else {
      return '${duration.inDays}d ago';
    }
  }
}
