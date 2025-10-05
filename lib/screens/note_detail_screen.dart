import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import 'ai_action_screen.dart';

class NoteDetailScreen extends StatefulWidget {
  final Note note;
  final bool isNewNote;

  const NoteDetailScreen({super.key, required this.note, this.isNewNote = false});

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  bool _isEditing = false;
  bool _hasChanges = false;
  Timer? _autoSaveTimer;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _contentController = TextEditingController(text: widget.note.content);
    
    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
    
    // Start in editing mode for new notes
    if (widget.isNewNote) {
      _isEditing = true;
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!_hasChanges) {
      setState(() {
        _hasChanges = true;
      });
    }
    
    // Auto-save after 2 seconds of no typing
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      if (_hasChanges) {
        _autoSave();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.note.title),
        actions: [
          if (_isEditing) ...[
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _hasChanges ? _saveChanges : null,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _cancelEditing,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _startEditing,
            ),
            IconButton(
              icon: const Icon(Icons.psychology),
              onPressed: _openAIAction,
            ),
            PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete, color: Colors.red),
                      const SizedBox(width: 8),
                      Text('Delete', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
                if (widget.note.isTask)
                  PopupMenuItem(
                    value: 'convert',
                    child: Row(
                      children: [
                        Icon(Icons.note),
                        const SizedBox(width: 8),
                        Text('Convert to Note'),
                      ],
                    ),
                  ),
                if (!widget.note.isTask)
                  PopupMenuItem(
                    value: 'convert',
                    child: Row(
                      children: [
                        Icon(Icons.task),
                        const SizedBox(width: 8),
                        Text('Convert to Task'),
                      ],
                    ),
                  ),
              ],
              onSelected: (value) {
                if (value == 'delete') {
                  _deleteNote();
                } else if (value == 'convert') {
                  _convertNoteType();
                }
              },
            ),
          ],
        ],
      ),
      body: _isEditing ? _buildEditingView() : _buildViewingView(),
      bottomNavigationBar: _isEditing ? null : _buildBottomBar(),
    );
  }

  Widget _buildViewingView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.note.isTask) ...[
            _buildTaskStatus(),
            const SizedBox(height: 16),
          ],
          Text(
            widget.note.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            widget.note.content,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (widget.note.subNotes.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Sub-notes',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...widget.note.subNotes.map((subNote) => Card(
              child: ListTile(
                leading: Icon(
                  subNote.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: subNote.isCompleted ? Colors.green : Colors.grey,
                ),
                title: Text(subNote.name),
                subtitle: Text(subNote.content),
                onTap: () => _toggleSubNoteCompletion(subNote),
              ),
            )),
          ],
          if (widget.note.tags.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Tags',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: widget.note.tags.map((tag) => Chip(
                label: Text(tag),
                backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                labelStyle: TextStyle(color: Theme.of(context).primaryColor),
              )).toList(),
            ),
          ],
          if (widget.note.attachmentPaths.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Attachments',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...widget.note.attachmentPaths.map((path) => Card(
              child: ListTile(
                leading: const Icon(Icons.attach_file),
                title: Text(path.split('/').last),
                subtitle: Text(path),
              ),
            )),
          ],
          const SizedBox(height: 24),
          Text(
            'Created: ${_formatDate(widget.note.createdAt)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          if (widget.note.updatedAt != widget.note.createdAt)
            Text(
              'Updated: ${_formatDate(widget.note.updatedAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditingView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: TextField(
              controller: _contentController,
              decoration: const InputDecoration(
                labelText: 'Content',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskStatus() {
    if (!widget.note.isTask) return const SizedBox.shrink();
    
    return Card(
      color: _getStatusColor().withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _getStatusIcon(),
              color: _getStatusColor(),
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Status: ${_getStatusText()}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _getStatusColor(),
                    ),
                  ),
                  if (widget.note.dueDate != null)
                    Text(
                      'Due: ${widget.note.dueDate}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Colors.grey[300]!),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _openAIAction,
              icon: const Icon(Icons.psychology),
              label: const Text('AI Actions'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _addAttachment,
              icon: const Icon(Icons.attach_file),
              label: const Text('Attach'),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    switch (widget.note.status) {
      case TaskStatus.complete:
        return Colors.green;
      case TaskStatus.abandoned:
        return Colors.red;
      case TaskStatus.todo:
      default:
        return Colors.orange;
    }
  }

  IconData _getStatusIcon() {
    switch (widget.note.status) {
      case TaskStatus.complete:
        return Icons.check_circle;
      case TaskStatus.abandoned:
        return Icons.cancel;
      case TaskStatus.todo:
      default:
        return Icons.radio_button_unchecked;
    }
  }

  String _getStatusText() {
    switch (widget.note.status) {
      case TaskStatus.complete:
        return 'Complete';
      case TaskStatus.abandoned:
        return 'Abandoned';
      case TaskStatus.todo:
      default:
        return 'To Do';
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} at ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
      _hasChanges = false;
    });
  }

  void _cancelEditing() {
    setState(() {
      _isEditing = false;
      _hasChanges = false;
      _titleController.text = widget.note.title;
      _contentController.text = widget.note.content;
    });
  }

  void _autoSave() {
    if (_titleController.text.trim().isEmpty && _contentController.text.trim().isEmpty) {
      return; // Don't save empty notes
    }
    
    final updatedNote = widget.note.copyWith(
      title: _titleController.text.trim().isEmpty ? 'Untitled' : _titleController.text.trim(),
      content: _contentController.text.trim(),
      updatedAt: DateTime.now(),
    );
    
    if (widget.isNewNote) {
      // Add new note to the database
      context.read<AppProvider>().addNote(updatedNote);
    } else {
      // Update existing note
      context.read<AppProvider>().updateNote(updatedNote);
    }
    
    setState(() {
      _hasChanges = false;
    });
  }

  void _saveChanges() {
    _autoSave();
    setState(() {
      _isEditing = false;
    });
  }

  void _deleteNote() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Are you sure you want to delete this note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.read<AppProvider>().deleteNote(widget.note.id);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _convertNoteType() {
    final newType = widget.note.isTask ? NoteType.note : NoteType.task;
    final updatedNote = widget.note.copyWith(
      type: newType,
      updatedAt: DateTime.now(),
    );
    
    context.read<AppProvider>().updateNote(updatedNote);
    Navigator.pop(context);
  }

  void _toggleSubNoteCompletion(SubNote subNote) {
    // TODO: Implement sub-note completion toggle
  }

  void _openAIAction() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AIActionScreen(selectedNotes: [widget.note]),
      ),
    );
  }

  void _addAttachment() {
    // TODO: Implement attachment functionality
  }
}
