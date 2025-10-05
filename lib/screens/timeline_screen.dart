import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/note_card.dart';
import 'note_detail_screen.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key});

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  String _selectedTag = 'all';
  List<String> _availableTags = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTags();
    });
  }

  void _loadTags() {
    final appProvider = context.read<AppProvider>();
    final allTags = <String>{};
    
    for (final note in appProvider.notes) {
      allTags.addAll(note.tags);
    }
    
    setState(() {
      _availableTags = ['all', ...allTags.toList()..sort()];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Timeline'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              setState(() {
                _selectedTag = value;
              });
            },
            itemBuilder: (context) => _availableTags.map((tag) => PopupMenuItem(
              value: tag,
              child: Text(tag == 'all' ? 'All Notes' : tag),
            )).toList(),
            icon: const Icon(Icons.filter_list),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              context.read<AppProvider>().loadData();
              _loadTags();
            },
          ),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          if (appProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          final notes = _filterNotes(appProvider.notes);
          final groupedNotes = _groupNotesByDate(notes);
          
          if (notes.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.timeline, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    _selectedTag == 'all' ? 'No notes yet' : 'No notes with this tag',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _selectedTag == 'all'
                        ? 'Create your first note'
                        : 'Try selecting a different tag',
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
            itemCount: groupedNotes.length,
            itemBuilder: (context, index) {
              final entry = groupedNotes.entries.elementAt(index);
              final date = entry.key;
              final dayNotes = entry.value;
              
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _formatDate(date),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...dayNotes.map((note) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: NoteCard(
                      note: note,
                      onTap: () => _openNoteDetail(note),
                    ),
                  )),
                  const SizedBox(height: 16),
                ],
              );
            },
          );
        },
      ),
    );
  }

  List<Note> _filterNotes(List<Note> notes) {
    if (_selectedTag == 'all') {
      return notes;
    }
    
    return notes.where((note) => note.tags.contains(_selectedTag)).toList();
  }

  Map<DateTime, List<Note>> _groupNotesByDate(List<Note> notes) {
    final Map<DateTime, List<Note>> grouped = {};
    
    for (final note in notes) {
      final date = DateTime(note.createdAt.year, note.createdAt.month, note.createdAt.day);
      if (grouped[date] == null) {
        grouped[date] = [];
      }
      grouped[date]!.add(note);
    }
    
    // Sort by date (most recent first)
    final sortedEntries = grouped.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    
    return Map.fromEntries(sortedEntries);
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dateOnly = DateTime(date.year, date.month, date.day);
    
    if (dateOnly == today) {
      return 'Today';
    } else if (dateOnly == yesterday) {
      return 'Yesterday';
    } else {
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    }
  }

  void _openNoteDetail(Note note) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => NoteDetailScreen(note: note),
      ),
    );
  }
}
