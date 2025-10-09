import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/multi_select_tag_filter.dart';
import '../utils/date_utils.dart';
import 'note_detail_screen.dart';
import '../widgets/interactive_checkbox_list.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  CalendarFormat _calendarFormat = CalendarFormat.month;
  int _calendarKey = 0; // Add a key to force rebuild
  Set<String> _selectedTags = {};
  List<String> _availableTags = [];
  String _selectedView = 'calendar'; // 'calendar', 'timeline', 'todo'

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
    _focusedDay = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTags();
    });
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
        title: Text(_getViewTitle()),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              setState(() {
                _selectedView = value;
                if (value == 'calendar') {
                  _calendarKey++; // Force calendar rebuild
                }
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'calendar',
                child: Row(
                  children: [
                    Icon(Icons.calendar_today, size: 20),
                    const SizedBox(width: 8),
                    const Text('Calendar'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'timeline',
                child: Row(
                  children: [
                    Icon(Icons.timeline, size: 20),
                    const SizedBox(width: 8),
                    const Text('Timeline'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'todo',
                child: Row(
                  children: [
                    Icon(Icons.checklist, size: 20),
                    const SizedBox(width: 8),
                    const Text('Todo'),
                  ],
                ),
              ),
            ],
            icon: const Icon(Icons.view_module),
          ),
          MultiSelectTagFilter(
            availableTags: _availableTags,
            selectedTags: _selectedTags,
            onSelectionChanged: (selectedTags) {
              setState(() {
                _selectedTags = selectedTags;
                if (_selectedView == 'calendar') {
                  _calendarKey++; // Force calendar rebuild
                }
              });
            },
          ),
          if (_selectedView == 'calendar')
            IconButton(
              icon: const Icon(Icons.today),
              onPressed: () {
                setState(() {
                  final now = DateTime.now();
                  _focusedDay = now;
                  _selectedDay = now;
                });
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
          
          if (_selectedView == 'timeline') {
            return _buildTimelineView(appProvider);
          } else if (_selectedView == 'todo') {
            return _buildTodoView(appProvider);
          } else {
            return Column(
              children: [
                TableCalendar<Note>(
                key: ValueKey(_calendarKey),
                firstDay: DateTime.utc(2020, 1, 1),
                lastDay: DateTime.utc(2030, 12, 31),
                focusedDay: _focusedDay,
                calendarFormat: _calendarFormat,
                availableCalendarFormats: const {
                  CalendarFormat.month: 'Month',
                  CalendarFormat.twoWeeks: '2 Weeks',
                  CalendarFormat.week: 'Week',
                },
                selectedDayPredicate: (day) {
                  return isSameDay(_selectedDay, day);
                },
                onDaySelected: (selectedDay, focusedDay) {
                  setState(() {
                    _selectedDay = selectedDay;
                    _focusedDay = focusedDay;
                  });
                },
                onFormatChanged: (format) {
                  setState(() {
                    _calendarFormat = format;
                    // Force a complete rebuild by updating the key
                    _calendarKey++;
                    // Ensure focused day is properly set when format changes
                    if (_selectedDay != null) {
                      _focusedDay = _selectedDay!;
                    } else {
                      _focusedDay = DateTime.now();
                    }
                  });
                },
                onPageChanged: (focusedDay) {
                  setState(() {
                    _focusedDay = focusedDay;
                  });
                },
                eventLoader: (day) {
                  final tasks = appProvider.getTasksForDate(day);
                  if (_selectedTags.isEmpty) {
                    return tasks;
                  }
                  return tasks.where((task) {
                    return _selectedTags.any((selectedTag) => task.tags.contains(selectedTag));
                  }).toList();
                },
                calendarStyle: CalendarStyle(
                  outsideDaysVisible: true,
                  markersMaxCount: 3,
                  markerDecoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                headerStyle: HeaderStyle(
                  formatButtonVisible: true,
                  titleCentered: true,
                  formatButtonShowsNext: false,
                ),
              ),
              const Divider(),
              Expanded(
                child: _selectedDay == null
                    ? const Center(
                        child: Text('Select a day to view notes and tasks'),
                      )
                    : _buildTabbedDayContent(appProvider),
              ),
            ],
          );
          }
        },
      ),
    );
  }

  Widget _buildTabbedDayContent(AppProvider appProvider) {
    final selectedDate = _selectedDay!;
    final allTasks = appProvider.getTasksForDate(selectedDate);
    final allNotes = appProvider.getNotesForDate(selectedDate);
    
    // Filter by selected tags (OR logic)
    final tasks = _selectedTags.isEmpty 
        ? allTasks 
        : allTasks.where((task) {
            return _selectedTags.any((selectedTag) => task.tags.contains(selectedTag));
          }).toList();
    final notes = _selectedTags.isEmpty 
        ? allNotes 
        : allNotes.where((note) {
            return _selectedTags.any((selectedTag) => note.tags.contains(selectedTag));
          }).toList();

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          // Date header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // Tab bar
          Container(
            color: Theme.of(context).primaryColor.withOpacity(0.1),
            child: TabBar(
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.task_alt, size: 18),
                      const SizedBox(width: 8),
                      Text('Tasks (${tasks.length})'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.note, size: 18),
                      const SizedBox(width: 8),
                      Text('Notes (${notes.length})'),
                    ],
                  ),
                ),
              ],
              labelColor: Theme.of(context).primaryColor,
              unselectedLabelColor: Colors.grey[600],
              indicatorColor: Theme.of(context).primaryColor,
            ),
          ),
          // Tab content
          Expanded(
            child: TabBarView(
              children: [
                _buildTasksTab(tasks, appProvider),
                _buildNotesTab(notes),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTasksTab(List<Note> tasks, AppProvider appProvider) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.task_alt, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _selectedTags.isEmpty ? 'No tasks for this day' : 'No tasks with selected tags for this day',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedTags.isEmpty ? 'Create a task to get started' : 'Try selecting different tags',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[500],
              ),
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
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: _buildStatusIcon(task),
            title: Text(
              task.title,
              style: TextStyle(
                decoration: task.isCompleted ? TextDecoration.lineThrough : null,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: SelectionArea(
              child: GptMarkdown(
                task.content,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                onLinkTap: _handleLinkTap,
              ),
            ),
            trailing: _buildStatusDropdown(task, appProvider),
            onTap: () => _openNoteDetail(task),
          ),
        );
      },
    );
  }

  Widget _buildNotesTab(List<Note> notes) {
    if (notes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _selectedTags.isEmpty ? 'No notes for this day' : 'No notes with selected tags for this day',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedTags.isEmpty ? 'Create a note to get started' : 'Try selecting different tags',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[500],
              ),
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
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.note),
            title: Text(
              note.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: SelectionArea(
              child: _buildSafeMarkdown(note.content, context),
            ),
            onTap: () => _openNoteDetail(note),
          ),
        );
      },
    );
  }

  void _openNoteDetail(Note note) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => NoteDetailScreen(note: note),
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

  String _getViewTitle() {
    switch (_selectedView) {
      case 'timeline':
        return 'Timeline';
      case 'todo':
        return 'Todo';
      case 'calendar':
      default:
        return 'Calendar';
    }
  }

  Widget _buildTimelineView(AppProvider appProvider) {
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
                color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Text(
                _formatDate(date),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            ...dayNotes.map((note) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: InkWell(
                  onTap: () => _openNoteDetail(note),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (note.isTask) ...[
                              _buildStatusIcon(note),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                note.title,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  decoration: note.isCompleted ? TextDecoration.lineThrough : null,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (note.isTask)
                              _buildStatusDropdown(note, appProvider),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          note.content,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[600],
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (note.tags.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: note.tags.take(3).map((tag) => Chip(
                              label: Text(
                                tag,
                                style: const TextStyle(fontSize: 12),
                              ),
                              backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                              labelStyle: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            )).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            )),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Widget _buildTodoView(AppProvider appProvider) {
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
              onTap: () => _openNoteDetail(task),
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
                          backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                          labelStyle: TextStyle(
                            color: Theme.of(context).brightness == Brightness.dark 
                              ? Colors.white 
                              : Theme.of(context).colorScheme.primary,
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
  }

  List<Note> _filterNotes(List<Note> notes) {
    // Filter to only show tasks that are not archived
    final tasks = notes.where((note) => note.isTask && !note.isArchived).toList();
    
    if (_selectedTags.isEmpty) {
      return tasks;
    }
    
    return tasks.where((task) {
      return _selectedTags.any((selectedTag) => task.tags.contains(selectedTag));
    }).toList();
  }

  List<Note> _filterTasks(List<Note> notes) {
    final tasks = notes.where((note) => note.isTask && !note.isArchived).toList();
    
    if (_selectedTags.isEmpty) {
      return tasks;
    }
    
    return tasks.where((task) {
      return _selectedTags.any((selectedTag) => task.tags.contains(selectedTag));
    }).toList();
  }

  Map<DateTime, List<Note>> _groupNotesByDate(List<Note> notes) {
    final Map<DateTime, List<Note>> grouped = {};
    
    for (final note in notes) {
      DateTime dateToUse;
      
      // Use scheduledAt if available, otherwise fall back to createdAt
      if (note.scheduledAt != null && note.scheduledAt!.isNotEmpty) {
        try {
          dateToUse = DateTime.parse(note.scheduledAt!);
        } catch (e) {
          // If parsing fails, use createdAt
          dateToUse = note.createdAt;
        }
      } else {
        // If no scheduledAt, use createdAt
        dateToUse = note.createdAt;
      }
      
      final date = DateTime(dateToUse.year, dateToUse.month, dateToUse.day);
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


  Widget _buildSafeMarkdown(String content, BuildContext context) {
    try {
      // Use InteractiveCheckboxList approach but limit to first 3 lines
      final lines = content.split('\n');
      final limitedLines = lines.take(3).toList();
      final limitedContent = limitedLines.join('\n');
      
      return ClipRect(
        child: Align(
          alignment: Alignment.topLeft,
          heightFactor: 1.0,
          child: InteractiveCheckboxList(
            originalContent: limitedContent,
            onContentChanged: (newContent) {
              // No-op for read-only display
            },
            style: Theme.of(context).textTheme.bodySmall,
            onLinkTap: _handleLinkTap,
          ),
        ),
      );
    } catch (e) {
      // Fallback to simple text if InteractiveCheckboxList fails
      return Text(
        content,
        style: Theme.of(context).textTheme.bodySmall,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }
  }

  // Link handling function
  void _handleLinkTap(String url, String text) {
    // Note: gpt_markdown passes parameters in reverse order
    // First parameter is the actual URL, second is the display text
    _launchUrl(url);
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Cannot open link: $url'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening link: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
