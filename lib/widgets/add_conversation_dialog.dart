import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../models/note.dart';
import '../l10n/app_localizations.dart';
import 'ai_conversation_creator_dialog.dart';
import '../services/conversation_service.dart';
import '../services/logger_service.dart';

/// Dialog for choosing how to add a conversation from selected nodes
/// Options: Add directly or Let AI process first
class AddConversationDialog extends StatelessWidget {
  final List<String> selectedNodeIds;
  final String conversationContent;
  final List<Note> contextNotes;
  
  const AddConversationDialog({
    super.key,
    required this.selectedNodeIds,
    required this.conversationContent,
    this.contextNotes = const [],
  });
  
  /// Show the dialog and return the created conversation if any
  static Future<Conversation?> show({
    required BuildContext context,
    required List<String> selectedNodeIds,
    required String conversationContent,
    List<Note> contextNotes = const [],
  }) async {
    return await showDialog<Conversation?>(
      context: context,
      builder: (context) => AddConversationDialog(
        selectedNodeIds: selectedNodeIds,
        conversationContent: conversationContent,
        contextNotes: contextNotes,
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return AlertDialog(
      title: Text(l10n.addConversationDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.addConversationDialogMessage),
          const SizedBox(height: 16),
          _buildOptionCard(
            context: context,
            icon: Icons.add,
            title: l10n.addDirectly,
            description: l10n.addDirectlyDescription,
            onTap: () => _addDirectly(context),
          ),
          const SizedBox(height: 12),
          _buildOptionCard(
            context: context,
            icon: Icons.psychology,
            title: l10n.addWithAIProcessing,
            description: l10n.addWithAIProcessingDescription,
            onTap: () => _addWithAIProcessing(context),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
  
  Widget _buildOptionCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          splashColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
          highlightColor: Theme.of(context).colorScheme.primary.withOpacity(0.05),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(
                    icon,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Future<void> _addDirectly(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    
    // Add a small delay to allow InkWell tap animation to complete
    await Future.delayed(const Duration(milliseconds: 100));
    
    if (!context.mounted) return;
    
    // Show title input dialog (don't close the main dialog yet)
    final titleController = TextEditingController(
      text: 'Conversation from ${selectedNodeIds.length} selected nodes',
    );
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.conversationTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.enterConversationTitlePrompt),
            const SizedBox(height: 16),
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                hintText: l10n.conversationTitleHint,
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              final text = titleController.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(dialogContext).pop(text);
              }
            },
            child: Text(l10n.createConversation),
          ),
        ],
      ),
    );
    
    // If user cancelled the title dialog, close the main dialog without creating a conversation
    if (title == null || title.isEmpty) {
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      return;
    }
    
    try {
      final conversationService = ConversationService();
      
      // Create conversation directly with selected nodes
      final newConversation = await conversationService.createConversationFromSelectedNodes(
        selectedNodeIds: selectedNodeIds,
        title: title,
      );
      
      // Return the created conversation - let the caller show success messages
      if (context.mounted) {
        Navigator.of(context).pop(newConversation);
      }
    } catch (e) {
      if (!context.mounted) return;
      
      LoggerService.error('Error creating conversation: $e', error: e);
      
      // Show error message before popping
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorCreatingConversation(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      } catch (_) {
        // Context may be deactivated, skip snackbar
      }
      
      // Pop with null to indicate error
      if (context.mounted) {
        Navigator.of(context).pop(null);
      }
    }
  }
  
  Future<void> _addWithAIProcessing(BuildContext context) async {
    // Add a small delay to allow InkWell tap animation to complete
    await Future.delayed(const Duration(milliseconds: 100));
    
    if (!context.mounted) return;
    
    // Show AI conversation creator dialog (don't close the main dialog yet)
    final createdConversation = await AIConversationCreatorDialog.show(
      context: context,
      selectedNodeIds: selectedNodeIds,
      conversationContent: conversationContent,
      contextNotes: contextNotes,
    );
    
    // Close the main dialog and return the created conversation to the caller
    // The top-level caller will show success/error messages based on the result
    if (context.mounted) {
      Navigator.of(context).pop(createdConversation);
    }
  }
}
