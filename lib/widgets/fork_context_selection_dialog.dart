import 'package:flutter/material.dart';
import '../models/conversation_context.dart';

class ForkContextSelectionDialog extends StatefulWidget {
  final ForkContextSelection selection;
  final Function(ConversationContext?, String?) onConfirm;

  const ForkContextSelectionDialog({
    super.key,
    required this.selection,
    required this.onConfirm,
  });

  @override
  State<ForkContextSelectionDialog> createState() => _ForkContextSelectionDialogState();
}

class _ForkContextSelectionDialogState extends State<ForkContextSelectionDialog> {
  ConversationContext? _selectedContext;
  final TextEditingController _titleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Pre-select the first context if only one available
    if (widget.selection.availableContexts.length == 1) {
      _selectedContext = widget.selection.availableContexts.first;
    }
    _titleController.text = widget.selection.customTitle ?? '';
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Conversation Context'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.selection.hasConflictingContexts)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Multiple conversations contain this message with different contexts. Please select which context to use for the fork.',
                        style: TextStyle(color: Colors.orange.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            
            const Text(
              'Available Contexts:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            
            Expanded(
              child: ListView.builder(
                itemCount: widget.selection.availableContexts.length,
                itemBuilder: (context, index) {
                  final conversationContext = widget.selection.availableContexts[index];
                  final isSelected = _selectedContext?.conversationId == conversationContext.conversationId;
                  
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
                    child: RadioListTile<ConversationContext>(
                      title: Text(
                        conversationContext.title,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            conversationContext.displaySummary,
                            style: const TextStyle(fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Created: ${_formatDate(conversationContext.createdAt)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      value: conversationContext,
                      groupValue: _selectedContext,
                      onChanged: (value) {
                        setState(() {
                          _selectedContext = value;
                        });
                      },
                    ),
                  );
                },
              ),
            ),
            
            const SizedBox(height: 16),
            const Text(
              'Fork Title:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                hintText: 'Enter title for the new conversation',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedContext != null && _titleController.text.trim().isNotEmpty
              ? () {
                  widget.onConfirm(_selectedContext, _titleController.text.trim());
                  Navigator.of(context).pop(true); // Return true to indicate fork was confirmed
                }
              : null,
          child: const Text('Create Fork'),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}
