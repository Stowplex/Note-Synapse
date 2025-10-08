import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../widgets/note_card.dart';
import '../widgets/multi_select_tag_filter.dart';
import 'note_detail_screen.dart';
import 'ai_action_screen.dart';
import 'subnote_edit_screen.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _searchController = TextEditingController();
  List<Note> _selectedNotes = [];
  bool _isMultiSelectMode = false;
  Set<String> _selectedTags = {};
  List<String> _availableTags = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTags();
    });
  }


  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadTags() {
    final appProvider = context.read<AppProvider>();
    final allTags = appProvider.getAllAvailableTags();
    setState(() {
      _availableTags = ['all', ...allTags];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isMultiSelectMode
            ? Text('${_selectedNotes.length} selected')
            : const Text('Notes'),
        actions: [
          if (_isMultiSelectMode) ...[
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: _selectedNotes.length >= 2 ? _linkSelectedNotes : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _selectedNotes.isNotEmpty ? _deleteSelectedNotes : null,
            ),
            IconButton(
              icon: const Icon(Icons.psychology),
              onPressed: _selectedNotes.isNotEmpty ? _openAIAction : null,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _exitMultiSelectMode,
            ),
          ] else ...[
            MultiSelectTagFilter(
              availableTags: _availableTags,
              selectedTags: _selectedTags,
              onSelectionChanged: (selectedTags) {
                setState(() {
                  _selectedTags = selectedTags;
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _toggleSearch,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                context.read<AppProvider>().loadData();
                _loadTags();
              },
            ),
          ],
        ],
        bottom: _isMultiSelectMode ? null : PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search notes...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onChanged: (value) {
                setState(() {});
              },
            ),
          ),
        ),
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          // Load tags when data becomes available
          if (!appProvider.isLoading && appProvider.notes.isNotEmpty && _availableTags.length <= 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _loadTags();
            });
          }
          
          if (appProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (appProvider.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: Colors.red[300]),
                  const SizedBox(height: 16),
                  Text(
                    'Error loading notes',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    appProvider.error!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => appProvider.loadData(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final notes = _filterNotes(appProvider.notes);
          
          if (notes.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.note_add, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    _searchController.text.isNotEmpty || _selectedTags.isNotEmpty
                        ? 'No notes found'
                        : 'No notes yet',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _searchController.text.isNotEmpty || _selectedTags.isNotEmpty
                        ? _searchController.text.isNotEmpty
                            ? 'Try adjusting your search terms'
                            : 'Try selecting different tags'
                        : 'Tap the + button to create your first note',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: notes.length,
            itemBuilder: (context, index) {
              final note = notes[index];
              final isSelected = _selectedNotes.contains(note);
              
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GestureDetector(
                  onTap: () => _handleNoteTap(note),
                  onLongPress: () => _handleNoteLongPress(note),
                  child: NoteCard(
                    note: note,
                    isSelected: isSelected,
                    onTap: () => _handleNoteTap(note),
                    onLongPress: () => _handleNoteLongPress(note),
                    onStatusChanged: note.isTask ? (status) => _updateTaskStatus(note.id, status) : null,
                    onAddSubNote: () => _addSubNote(note),
                    onPinToggle: () => _toggleNotePin(note.id),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  List<Note> _filterNotes(List<Note> notes) {
    List<Note> filteredNotes = notes;
    
    // Filter by tags (OR logic - show notes that have ANY of the selected tags)
    if (_selectedTags.isNotEmpty) {
      filteredNotes = filteredNotes.where((note) {
        return _selectedTags.any((selectedTag) => note.tags.contains(selectedTag));
      }).toList();
    }
    
    // Filter by search query
    if (_searchController.text.isNotEmpty) {
      final query = _searchController.text.toLowerCase();
      filteredNotes = filteredNotes.where((note) {
        return note.title.toLowerCase().contains(query) ||
               note.content.toLowerCase().contains(query) ||
               note.tags.any((tag) => tag.toLowerCase().contains(query));
      }).toList();
    }
    
    // Sort by pinned status first, then by creation date
    filteredNotes.sort((a, b) {
      if (a.pinned && !b.pinned) return -1;
      if (!a.pinned && b.pinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    
    return filteredNotes;
  }

  void _handleNoteTap(Note note) {
    if (_isMultiSelectMode) {
      setState(() {
        if (_selectedNotes.contains(note)) {
          _selectedNotes.remove(note);
        } else {
          _selectedNotes.add(note);
        }
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => NoteDetailScreen(note: note),
        ),
      );
    }
  }

  void _handleNoteLongPress(Note note) {
    if (!_isMultiSelectMode) {
      setState(() {
        _isMultiSelectMode = true;
        _selectedNotes = [note];
      });
    }
  }

  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedNotes.clear();
    });
  }

  void _deleteSelectedNotes() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Notes'),
        content: Text('Are you sure you want to delete ${_selectedNotes.length} note(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              for (final note in _selectedNotes) {
                context.read<AppProvider>().deleteNote(note.id);
              }
              _exitMultiSelectMode();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _openAIAction() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AIActionScreen(selectedNotes: _selectedNotes),
      ),
    );
  }

  void _toggleSearch() {
    // Search is always visible in the app bar
  }

  void _updateTaskStatus(String noteId, TaskStatus status) {
    context.read<AppProvider>().updateTaskStatus(noteId, status);
  }

  void _toggleNotePin(String noteId) {
    context.read<AppProvider>().toggleNotePin(noteId);
  }

  void _linkSelectedNotes() {
    if (_selectedNotes.length < 2) return;
    
    final firstNote = _selectedNotes.first;
    final otherNotes = _selectedNotes.skip(1).toList();
    
    showDialog(
      context: context,
      builder: (context) => _LinkNotesDialog(
        fromNote: firstNote,
        toNotes: otherNotes,
        onLink: (relationshipType) {
          Navigator.pop(context);
          context.read<AppProvider>().createNoteRelationships(
            firstNote.id,
            otherNotes.map((n) => n.id).toList(),
            relationshipType,
          );
          _exitMultiSelectMode();
        },
      ),
    );
  }

  void _addSubNote(Note note) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubNoteEditScreen(parentNote: note),
      ),
    );
  }

}

class _LinkNotesDialog extends StatefulWidget {
  final Note fromNote;
  final List<Note> toNotes;
  final Function(String) onLink;

  const _LinkNotesDialog({
    required this.fromNote,
    required this.toNotes,
    required this.onLink,
  });

  @override
  State<_LinkNotesDialog> createState() => _LinkNotesDialogState();
}

class _LinkNotesDialogState extends State<_LinkNotesDialog> {
  String _selectedRelationshipType = RelationshipType.related;
  final TextEditingController _customTypeController = TextEditingController();

  @override
  void dispose() {
    _customTypeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Link Notes'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Link "${widget.fromNote.title}" to:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...widget.toNotes.map((note) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '• ${note.title}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )),
            const SizedBox(height: 16),
            Text(
              'Relationship Type:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedRelationshipType,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                ...RelationshipType.predefined.map((type) => DropdownMenuItem(
                  value: type,
                  child: Row(
                    children: [
                      Icon(RelationshipType.getIcon(type), size: 20),
                      const SizedBox(width: 8),
                      Text(RelationshipType.getDisplayName(type)),
                    ],
                  ),
                )),
                const DropdownMenuItem(
                  value: 'custom',
                  child: Row(
                    children: [
                      Icon(Icons.edit, size: 20),
                      SizedBox(width: 8),
                      Text('Custom...'),
                    ],
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedRelationshipType = value!;
                });
              },
            ),
            if (_selectedRelationshipType == 'custom') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _customTypeController,
                decoration: const InputDecoration(
                  labelText: 'Custom Relationship Type',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  setState(() {
                    _selectedRelationshipType = value;
                  });
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final relationshipType = _selectedRelationshipType == 'custom' 
                ? _customTypeController.text.trim()
                : _selectedRelationshipType;
            if (relationshipType.isNotEmpty) {
              widget.onLink(relationshipType);
            }
          },
          child: const Text('Link'),
        ),
      ],
    );
  }
}

