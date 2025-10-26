import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
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
    return AlertDialog(
      title: const Text('Add to Note'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How would you like to add this content to your notes?'),
          const SizedBox(height: 16),
          _buildOptionCard(
            context: context,
            icon: Icons.note_add,
            title: 'Add as-is',
            description: 'Add the content directly without modification',
            onTap: () => _addAsIs(context),
          ),
          const SizedBox(height: 12),
          _buildOptionCard(
            context: context,
            icon: Icons.psychology,
            title: 'Let AI create note',
            description: 'Use AI to summarize or transform the content',
            onTap: () => _letAICreate(context),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
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
    // Close the dialog first
    Navigator.of(context).pop();
    
    // Show title input dialog
    final titleController = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Note Title'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter a title for the new note:'),
            const SizedBox(height: 16),
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                hintText: 'Note title',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = titleController.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(context).pop(text);
              }
            },
            child: const Text('Create Note'),
          ),
        ],
      ),
    );
    
    if (title == null || title.isEmpty) return;
    
    try {
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
      await context.read<AppProvider>().addNote(newNote);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Note "$title" created successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating note: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  Future<void> _letAICreate(BuildContext context) async {
    // Close the initial dialog
    Navigator.of(context).pop();
    
    // Show AI note creator dialog
    final createdNotes = await AINoteCreatorDialog.show(
      context: context,
      conversationContent: content,
      contextNotes: contextNotes,
    );
    
    // Return the created notes through the original dialog's result
    if (context.mounted && createdNotes != null && createdNotes.isNotEmpty) {
      Navigator.of(context).pop(createdNotes);
    }
  }
}

