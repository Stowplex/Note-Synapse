import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../services/logger_service.dart';
import '../screens/conversation_chat_screen.dart';
import '../providers/app_provider.dart';
import '../widgets/tag_selection_dialog.dart';

class LinearHistoryDialog extends StatefulWidget {
  final Duration initialTimeRange;
  final ValueChanged<Duration> onTimeRangeChanged;
  final VoidCallback? onConversationDeleted;
  final List<String> initialSelectedTags;
  final ValueChanged<List<String>>? onTagsChanged;

  const LinearHistoryDialog({
    super.key,
    required this.initialTimeRange,
    required this.onTimeRangeChanged,
    this.onConversationDeleted,
    this.initialSelectedTags = const [],
    this.onTagsChanged,
  });

  @override
  State<LinearHistoryDialog> createState() => _LinearHistoryDialogState();
}

class _LinearHistoryDialogState extends State<LinearHistoryDialog> {
  final ConversationService _conversationService = ConversationService();
  List<Conversation> _conversations = [];
  late Duration _selectedTimeRange;
  bool _isLoading = true;
  late List<String> _selectedTags;

  @override
  void initState() {
    super.initState();
    _selectedTimeRange = widget.initialTimeRange;
    _selectedTags = List<String>.from(widget.initialSelectedTags);
    _loadConversations();
    _conversationService.deleteEmptyConversations(
      olderThan: const Duration(days: 1),
    );
  }

  Future<void> _loadConversations() async {
    setState(() => _isLoading = true);
    final conversations = await _conversationService.getAllConversations(
      maxAge: _selectedTimeRange,
      tagNames: _selectedTags.isEmpty ? null : _selectedTags,
    );
    final List<Conversation> conversationsWithMessages = [];
    for (final conversation in conversations) {
      final withMessages = await _conversationService
          .getConversationWithMessages(conversation.id);
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
    final l10n = AppLocalizations.of(context)!;

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
                  Icon(
                    Icons.history,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.conversations,
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

            // Time and tag filters
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(child: _buildTimeRangeFilter(l10n)),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _showTagFilter,
                    icon: const Icon(Icons.label_outline),
                    label: Text(
                      _selectedTags.isEmpty
                          ? l10n.filterTags
                          : l10n.filterTagsCount(_selectedTags.length),
                    ),
                  ),
                ],
              ),
            ),
            if (_selectedTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: _selectedTags
                      .map(
                        (tag) => Chip(
                          label: Text(tag),
                          onDeleted: () {
                            _removeTagFilter(tag);
                          },
                        ),
                      )
                      .toList(),
                ),
              ),

            // Conversations list
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _conversations.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No conversations found',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = _conversations[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outline.withOpacity(0.5),
                              width: 1,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        conversation.title,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.open_in_new),
                                          onPressed: () {
                                            Navigator.of(context).pop();
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    ConversationChatScreen(
                                                      conversationId:
                                                          conversation.id,
                                                    ),
                                              ),
                                            );
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete),
                                          onPressed: () =>
                                              _showDeleteConfirmation(
                                                context,
                                                conversation,
                                                l10n,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                FutureBuilder<ConversationWithMessages?>(
                                  future: _conversationService
                                      .getConversationWithMessages(
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
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
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
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
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
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateTagFilters(List<String> tags) async {
    if (!mounted) return;
    setState(() {
      _selectedTags = tags;
    });
    widget.onTagsChanged?.call(tags);
    await _loadConversations();
  }

  Future<void> _showTagFilter() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        title: l10n.filterTagsDialog,
        initialSelectedTags: _selectedTags,
        allowCreateNew: false,
        allowEmptySelection: true,
        confirmLabelBuilder: (count) =>
            count == 0 ? l10n.clearFilters : l10n.applyFilters,
      ),
    );

    if (result == null) return;
    await _updateTagFilters(result);
  }

  Future<void> _removeTagFilter(String tag) async {
    final updated = List<String>.from(_selectedTags)..remove(tag);
    await _updateTagFilters(updated);
  }

  Widget _buildTimeRangeFilter(AppLocalizations l10n) {
    return DropdownButton<Duration>(
      value: _selectedTimeRange,
      onChanged: (Duration? value) {
        if (value != null) {
          setState(() {
            _selectedTimeRange = value;
          });
          widget.onTimeRangeChanged(_selectedTimeRange);
          _loadConversations();
        }
      },
      items: [
        DropdownMenuItem(
          value: const Duration(hours: 1),
          child: Text(l10n.oneHourAgo),
        ),
        DropdownMenuItem(
          value: const Duration(hours: 12),
          child: Text(l10n.twelveHoursAgo),
        ),
        DropdownMenuItem(
          value: const Duration(days: 1),
          child: Text(l10n.oneDayAgo),
        ),
        DropdownMenuItem(
          value: const Duration(days: 3),
          child: Text(l10n.threeDaysAgo),
        ),
        DropdownMenuItem(
          value: const Duration(days: 7),
          child: Text(l10n.sevenDaysAgo),
        ),
        DropdownMenuItem(
          value: const Duration(days: 15),
          child: Text(l10n.fifteenDaysAgo),
        ),
        DropdownMenuItem(
          value: const Duration(days: 30),
          child: Text(l10n.oneMonthAgo),
        ),
        DropdownMenuItem(
          value: const Duration(days: 180),
          child: Text(l10n.sixMonthsAgo),
        ),
        DropdownMenuItem(
          value: const Duration(days: 365 * 10),
          child: Text(l10n.allTime),
        ),
      ],
    );
  }

  void _showDeleteConfirmation(
    BuildContext context,
    Conversation conversation,
    AppLocalizations l10n,
  ) {
    // Capture AppProvider and ScaffoldMessenger before showing dialog
    final appProvider = context.read<AppProvider>();
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteConversation),
        content: Text(l10n.confirmDeleteConversation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _deleteConversation(
                conversation.id,
                l10n,
                appProvider,
                scaffoldMessenger,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteConversation(
    String conversationId,
    AppLocalizations l10n,
    AppProvider appProvider,
    ScaffoldMessengerState scaffoldMessenger,
  ) async {
    try {
      // Perform deletion - this doesn't depend on context
      await appProvider.deleteConversation(conversationId);

      // Check if widget is still mounted before updating UI
      if (!mounted) return;

      // Reload conversations in this dialog
      _loadConversations();

      // Notify parent widget that a conversation was deleted
      if (widget.onConversationDeleted != null) {
        widget.onConversationDeleted!();
      }

      // Show success message
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n.conversationDeletedSuccessfully),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      LoggerService.error('Error deleting conversation: $e', error: e);

      // Check if widget is still mounted before showing error
      if (!mounted) return;

      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n.errorDeletingConversation(e.toString())),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
}
