import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/note_card.dart';
import 'note_detail_screen.dart';

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
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
      if (note.isTask) {
        allTags.addAll(note.tags);
      }
    }
    
    setState(() {
      _availableTags = ['all', ...allTags.toList()..sort()];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Todo'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              setState(() {
                _selectedTag = value;
              });
            },
            itemBuilder: (context) => _availableTags.map((tag) => PopupMenuItem(
              value: tag,
              child: Text(tag == 'all' ? 'All Tasks' : tag),
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

          final tasks = _filterTasks(appProvider.notes);
          
          if (tasks.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.checklist, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    _selectedTag == 'all' ? 'No tasks yet' : 'No tasks with this tag',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _selectedTag == 'all'
                        ? 'Create your first task'
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
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final task = tasks[index];
              final completionPercentage = appProvider.calculateTaskCompletionPercentage(task);
              
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: InkWell(
                    onTap: () => _openTaskDetail(task),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                task.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                                color: task.isCompleted ? Colors.green : Colors.grey,
                                size: 24,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  task.title,
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                                  ),
                                ),
                              ),
                              if (task.dueDate != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _isOverdue(task.dueDate!) ? Colors.red[100] : Colors.blue[100],
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    task.dueDate!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _isOverdue(task.dueDate!) ? Colors.red[700] : Colors.blue[700],
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            task.content,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (task.subNotes.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              value: completionPercentage,
                              backgroundColor: Colors.grey[300],
                              valueColor: AlwaysStoppedAnimation<Color>(
                                completionPercentage == 1.0 ? Colors.green : Colors.blue,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.list, size: 16, color: Colors.grey[500]),
                                const SizedBox(width: 4),
                                Text(
                                  '${task.subNotes.where((sn) => sn.isCompleted).length}/${task.subNotes.length} subtasks completed',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[500],
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${(completionPercentage * 100).toInt()}%',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (task.tags.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: task.tags.map((tag) => Chip(
                                label: Text(
                                  tag,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                                labelStyle: TextStyle(
                                  color: Theme.of(context).primaryColor,
                                ),
                              )).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  List<Note> _filterTasks(List<Note> notes) {
    final tasks = notes.where((note) => note.isTask).toList();
    
    if (_selectedTag == 'all') {
      return tasks;
    }
    
    return tasks.where((task) => task.tags.contains(_selectedTag)).toList();
  }

  bool _isOverdue(String dueDate) {
    final due = DateTime.tryParse(dueDate);
    if (due == null) return false;
    return due.isBefore(DateTime.now());
  }

  void _openTaskDetail(Note task) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => NoteDetailScreen(note: task),
      ),
    );
  }
}
