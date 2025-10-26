import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';
import 'ai_note_creator_dialog.dart';

/// Dialog for choosing how to add a note from conversation messages
/// Options: Add as-is or Let AI create note
class AddNoteDialog extends StatelessWidget {
  final String content;
  final List<Note> contextNotes;
  
  const AddNoteDialog({
    Key? key,
    required this.content,
    this.contextNotes = const [],
  }) : super(key: key);
  
  /// Show the dialog and return the created note(s) if any
  static Future<List<Note>?> show({
    required BuildContext context,
    required String content,
    List<Note> contextNotes = const [],
  }) async {
    return await showDialog<List<Note>?>(
      context: context,
      builder: (context) => AddNoteDialog(
        content: content,
        contextNotes: contextNotes,
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return AlertDialog(
      title: Text(l10n.addNoteDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.addNoteDialogMessage),
          const SizedBox(height: 16),
          _buildOptionCard(
            context: context,
            icon: Icons.note_add,
            title: l10n.addAsIs,
            description: l10n.addAsIsDescription,
            onTap: () => _addAsIs(context),
          ),
          const SizedBox(height: 12),
          _buildOptionCard(
            context: context,
            icon: Icons.psychology,
            title: l10n.letAICreateNote,
            description: l10n.letAICreateNoteDescription,
            onTap: () => _letAICreate(context),
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
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
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
    );
  }
  
  Future<void> _addAsIs(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    
    // Show title input dialog (don't close the main dialog yet)
    final titleController = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.noteTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.enterNoteTitlePrompt),
            const SizedBox(height: 16),
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                hintText: l10n.noteTitleHint,
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
            child: Text(l10n.createNote),
          ),
        ],
      ),
    );
    
    // If user cancelled the title dialog, close the main dialog without creating a note
    if (title == null || title.isEmpty) {
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      return;
    }
    
    try {
      // Get the AppProvider reference before any async operations
      final appProvider = context.read<AppProvider>();
      
      // Create the note
      final newNote = Note(
        id: const Uuid().v4(),
        title: title,
        content: content,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        subNotes: [],
        tags: [],
        attachmentPaths: [],
        scheduledAt: null,
        completeBy: null,
        status: null,
        pinned: false,
        isArchived: false,
      );
      
      // Save to database
      await appProvider.addNote(newNote);
      
      if (context.mounted) {
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.noteCreatedSuccessfully(title)),
            backgroundColor: Colors.green,
          ),
        );
        
        // Close the main dialog and return the created note to the caller
        Navigator.of(context).pop([newNote]);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorCreatingNote(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
        // Close the main dialog without returning anything on error
        Navigator.of(context).pop();
      }
    }
  }
  
  Future<void> _letAICreate(BuildContext context) async {
    // Show AI note creator dialog (don't close the main dialog yet)
    final createdNotes = await AINoteCreatorDialog.show(
      context: context,
      conversationContent: content,
      contextNotes: contextNotes,
    );
    
    // Close the main dialog and return the created notes to the caller
    if (context.mounted) {
      Navigator.of(context).pop(createdNotes);
    }
  }
}

