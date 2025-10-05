import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/note_card.dart';
import 'note_detail_screen.dart';
import 'ai_action_screen.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _searchController = TextEditingController();
  List<Note> _selectedNotes = [];
  bool _isMultiSelectMode = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _toggleSearch,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                context.read<AppProvider>().loadData();
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
                    _searchController.text.isNotEmpty
                        ? 'No notes found'
                        : 'No notes yet',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _searchController.text.isNotEmpty
                        ? 'Try adjusting your search terms'
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
    if (_searchController.text.isEmpty) {
      return notes;
    }
    
    final query = _searchController.text.toLowerCase();
    return notes.where((note) {
      return note.title.toLowerCase().contains(query) ||
             note.content.toLowerCase().contains(query) ||
             note.tags.any((tag) => tag.toLowerCase().contains(query));
    }).toList();
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
}
