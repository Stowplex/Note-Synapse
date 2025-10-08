import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/multi_select_tag_filter.dart';
import '../utils/date_utils.dart';
import 'note_detail_screen.dart';

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  Set<String> _selectedTags = {};
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
          MultiSelectTagFilter(
            availableTags: _availableTags,
            selectedTags: _selectedTags,
            onSelectionChanged: (selectedTags) {
              setState(() {
                _selectedTags = selectedTags;
              });
            },
            allNotesLabel: 'All Tasks',
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
          // Load tags when data becomes available
          if (!appProvider.isLoading && appProvider.notes.isNotEmpty && _availableTags.length <= 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _loadTags();
            });
          }
          
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
                    _selectedTags.isEmpty ? 'No tasks yet' : 'No tasks with selected tags',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _selectedTags.isEmpty
                        ? 'Create your first task'
                        : 'Try selecting different tags',
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
                              _buildStatusIcon(task),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  task.title,
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              _buildStatusDropdown(task, appProvider),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            task.content,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (task.scheduledAt != null || task.completeBy != null) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                if (task.scheduledAt != null)
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.green[100],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      'Start: ${AppDateUtils.formatDateForDisplay(task.scheduledAt)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.green[700],
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                if (task.completeBy != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppDateUtils.isOverdue(task.completeBy) ? Colors.red[100] : Colors.blue[100],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      'Due: ${AppDateUtils.formatDateForDisplay(task.completeBy)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppDateUtils.isOverdue(task.completeBy) ? Colors.red[700] : Colors.blue[700],
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
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
                              children: task.tags.take(3).map((tag) => Chip(
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
    
    if (_selectedTags.isEmpty) {
      return tasks;
    }
    
    return tasks.where((task) {
      return _selectedTags.any((selectedTag) => task.tags.contains(selectedTag));
    }).toList();
  }


  void _openTaskDetail(Note task) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => NoteDetailScreen(note: task),
      ),
    );
  }

  Widget _buildStatusIcon(Note task) {
    IconData iconData;
    Color iconColor;
    
    switch (task.status) {
      case TaskStatus.complete:
        iconData = Icons.check_circle;
        iconColor = Colors.green;
        break;
      case TaskStatus.inProgress:
        iconData = Icons.play_circle;
        iconColor = Colors.orange;
        break;
      case TaskStatus.abandoned:
        iconData = Icons.cancel;
        iconColor = Colors.red;
        break;
      case TaskStatus.todo:
      default:
        iconData = Icons.radio_button_unchecked;
        iconColor = Colors.grey;
        break;
    }
    
    return Icon(
      iconData,
      color: iconColor,
      size: 24,
    );
  }

  Widget _buildStatusDropdown(Note task, AppProvider appProvider) {
    return PopupMenuButton<TaskStatus>(
      onSelected: (TaskStatus status) {
        appProvider.updateTaskStatus(task.id, status);
      },
      itemBuilder: (BuildContext context) => [
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.todo,
          child: Row(
            children: [
              Icon(Icons.radio_button_unchecked, color: Colors.grey, size: 20),
              const SizedBox(width: 8),
              const Text('To Do'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.inProgress,
          child: Row(
            children: [
              Icon(Icons.play_circle, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              const Text('In Progress'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.complete,
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 20),
              const SizedBox(width: 8),
              const Text('Complete'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.abandoned,
          child: Row(
            children: [
              Icon(Icons.cancel, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              const Text('Cancelled'),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _getStatusText(task.status),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }

  String _getStatusText(TaskStatus? status) {
    switch (status) {
      case TaskStatus.complete:
        return 'Complete';
      case TaskStatus.inProgress:
        return 'In Progress';
      case TaskStatus.abandoned:
        return 'Cancelled';
      case TaskStatus.todo:
      default:
        return 'To Do';
    }
  }
}
