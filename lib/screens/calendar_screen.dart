import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import 'note_detail_screen.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  CalendarFormat _calendarFormat = CalendarFormat.month;

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.today),
            onPressed: () {
              setState(() {
                _focusedDay = DateTime.now();
                _selectedDay = DateTime.now();
              });
            },
          ),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          return Column(
            children: [
              TableCalendar<Note>(
                firstDay: DateTime.utc(2020, 1, 1),
                lastDay: DateTime.utc(2030, 12, 31),
                focusedDay: _focusedDay,
                calendarFormat: _calendarFormat,
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
                  });
                },
                onPageChanged: (focusedDay) {
                  _focusedDay = focusedDay;
                },
                eventLoader: (day) {
                  return appProvider.getTasksForDate(day);
                },
                calendarStyle: CalendarStyle(
                  outsideDaysVisible: false,
                  markersMaxCount: 3,
                  markerDecoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                headerStyle: HeaderStyle(
                  formatButtonVisible: true,
                  titleCentered: true,
                ),
              ),
              const Divider(),
              Expanded(
                child: _selectedDay == null
                    ? const Center(
                        child: Text('Select a day to view notes and tasks'),
                      )
                    : _buildDayContent(appProvider),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDayContent(AppProvider appProvider) {
    final selectedDate = _selectedDay!;
    final tasks = appProvider.getTasksForDate(selectedDate);
    final notes = appProvider.getNotesForDate(selectedDate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (tasks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Tasks (${tasks.length})',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.red[700],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: tasks.length,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    ),
                    subtitle: Text(task.content),
                    trailing: _buildStatusDropdown(task, appProvider),
                    onTap: () => _openNoteDetail(task),
                  ),
                );
              },
            ),
          ),
        ],
        if (notes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Notes (${notes.length})',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.blue[700],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: notes.length,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: notes.length,
              itemBuilder: (context, index) {
                final note = notes[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.note),
                    title: Text(note.title),
                    subtitle: Text(note.content),
                    onTap: () => _openNoteDetail(note),
                  ),
                );
              },
            ),
          ),
        ],
        if (tasks.isEmpty && notes.isEmpty)
          const Center(
            child: Text('No notes or tasks for this day'),
          ),
      ],
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
}
