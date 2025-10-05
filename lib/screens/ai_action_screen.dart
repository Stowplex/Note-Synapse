import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/ai_interaction.dart';
import 'note_detail_screen.dart';

class AIActionScreen extends StatefulWidget {
  final List<Note> selectedNotes;

  const AIActionScreen({super.key, required this.selectedNotes});

  @override
  State<AIActionScreen> createState() => _AIActionScreenState();
}

class _AIActionScreenState extends State<AIActionScreen> {
  final _promptController = TextEditingController();
  AIInteractionType? _selectedAction;
  bool _isProcessing = false;
  String? _response;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Actions'),
        actions: [
          if (_response != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _clearResponse,
            ),
        ],
      ),
      body: _response != null ? _buildResponseView() : _buildActionSelectionView(),
    );
  }

  Widget _buildActionSelectionView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select AI Action',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          if (widget.selectedNotes.length > 1) ...[
            _buildActionCard(
              icon: Icons.quiz,
              title: 'Multi-Note Q&A',
              description: 'Ask questions about your selected notes',
              action: AIInteractionType.multiNoteQa,
            ),
            const SizedBox(height: 12),
          ],
          if (widget.selectedNotes.length == 1) ...[
            _buildActionCard(
              icon: Icons.transform,
              title: 'Transform Note',
              description: 'Rewrite, reorganize, or modify your note',
              action: AIInteractionType.noteTransformation,
            ),
            const SizedBox(height: 12),
          ],
          _buildActionCard(
            icon: Icons.add_circle,
            title: 'Create New Notes',
            description: 'Generate new notes based on your prompt and context',
            action: AIInteractionType.newNoteCreation,
          ),
          const SizedBox(height: 24),
          if (_selectedAction != null) ...[
            Text(
              'Enter your prompt:',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _promptController,
              decoration: InputDecoration(
                hintText: _getPromptHint(),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.edit),
              ),
              maxLines: 4,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _processAction(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isProcessing ? null : _processAction,
                child: _isProcessing
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Process'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String description,
    required AIInteractionType action,
  }) {
    final isSelected = _selectedAction == action;
    
    return Card(
      elevation: isSelected ? 4 : 2,
      shadowColor: isSelected ? Theme.of(context).primaryColor.withOpacity(0.3) : null,
      color: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected 
            ? BorderSide(color: Theme.of(context).primaryColor.withOpacity(0.3), width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedAction = action;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                icon,
                size: 32,
                color: isSelected ? Theme.of(context).primaryColor : Colors.grey[600],
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
                        color: isSelected ? Theme.of(context).primaryColor : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(
                  Icons.check_circle,
                  color: Theme.of(context).primaryColor,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResponseView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI Response',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: Text(
                    _response!,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _clearResponse,
                  child: const Text('New Action'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _saveResponse,
                  child: const Text('Save Response'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getPromptHint() {
    switch (_selectedAction) {
      case AIInteractionType.multiNoteQa:
        return 'Ask a question about your selected notes...';
      case AIInteractionType.noteTransformation:
        return 'Describe how you want to transform this note...';
      case AIInteractionType.newNoteCreation:
        return 'Describe what new notes you want to create...';
      default:
        return 'Enter your prompt...';
    }
  }

  Future<void> _processAction() async {
    if (_promptController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a prompt')),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      String response;

      switch (_selectedAction) {
        case AIInteractionType.multiNoteQa:
          response = await appProvider.answerMultiNoteQuestion(
            _promptController.text.trim(),
            widget.selectedNotes,
          );
          break;
        case AIInteractionType.noteTransformation:
          response = await appProvider.transformNote(
            widget.selectedNotes.first,
            _promptController.text.trim(),
          );
          break;
        case AIInteractionType.newNoteCreation:
          final newNotes = await appProvider.createNewNotes(
            _promptController.text.trim(),
            widget.selectedNotes,
          );
          response = 'Created ${newNotes.length} new notes successfully!';
          break;
        default:
          throw Exception('Invalid action type');
      }

      setState(() {
        _response = response;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _clearResponse() {
    setState(() {
      _response = null;
      _selectedAction = null;
      _promptController.clear();
    });
  }

  void _saveResponse() async {
    if (_response == null || _response!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No response to save')),
      );
      return;
    }

    try {
      // Create a new note from the AI response
      final newNote = Note(
        id: const Uuid().v4(),
        title: _generateNoteTitle(),
        content: _response!,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['AI Generated'], // Tag to identify AI-generated notes
      );

      // Save the note to the database
      await context.read<AppProvider>().addNote(newNote);

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Response saved as new note')),
      );

      // Navigate to the newly created note
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => NoteDetailScreen(note: newNote),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving note: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _generateNoteTitle() {
    if (_response == null || _response!.trim().isEmpty) {
      return 'AI Response';
    }

    // Take the first line or first 50 characters as title
    final lines = _response!.split('\n');
    final firstLine = lines.first.trim();
    
    if (firstLine.length > 50) {
      return '${firstLine.substring(0, 47)}...';
    }
    
    return firstLine.isEmpty ? 'AI Response' : firstLine;
  }
}
