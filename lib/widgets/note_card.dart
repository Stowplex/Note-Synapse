import 'package:flutter/material.dart';
import '../models/note.dart';

class NoteCard extends StatelessWidget {
  final Note note;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Function(TaskStatus)? onStatusChanged;

  const NoteCard({
    super.key,
    required this.note,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.onStatusChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: isSelected ? 8 : 2,
      color: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
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
                  if (note.isTask && onStatusChanged != null)
                    _buildStatusDropdown(note),
                  if (isSelected)
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).primaryColor,
                    ),
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
              if (note.subNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.list, size: 16, color: Colors.grey[500]),
                    const SizedBox(width: 4),
                    Text(
                      '${note.subNotes.length} sub-notes',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[500],
                      ),
                    ),
                    if (note.isTask && note.subNotes.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        '(${note.subNotes.where((sn) => sn.isCompleted).length}/${note.subNotes.length} completed)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
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
                    backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                    labelStyle: TextStyle(
                      color: Theme.of(context).primaryColor,
                    ),
                  )).toList(),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    size: 14,
                    color: Colors.grey[500],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDate(note.createdAt),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[500],
                    ),
                  ),
                  if (note.isTask && (note.scheduledAt != null || note.completeBy != null)) ...[
                    const SizedBox(width: 16),
                    if (note.scheduledAt != null) ...[
                      Icon(
                        Icons.play_arrow,
                        size: 14,
                        color: Colors.green[600],
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Start: ${note.scheduledAt}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.green[600],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                    if (note.completeBy != null) ...[
                      const SizedBox(width: 16),
                      Icon(
                        Icons.schedule,
                        size: 14,
                        color: Colors.orange[600],
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Due: ${note.completeBy}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.orange[600],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                  const Spacer(),
                  if (note.attachmentPaths.isNotEmpty)
                    Icon(
                      Icons.attach_file,
                      size: 16,
                      color: Colors.grey[500],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(Note note) {
    if (!note.isTask) return const SizedBox.shrink();
    
    IconData iconData;
    Color iconColor;
    
    switch (note.status) {
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
      size: 20,
    );
  }

  Widget _buildStatusDropdown(Note note) {
    if (!note.isTask || onStatusChanged == null) return const SizedBox.shrink();
    
    return PopupMenuButton<TaskStatus>(
      onSelected: (TaskStatus status) {
        onStatusChanged!(status);
      },
      itemBuilder: (BuildContext context) => [
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.todo,
          child: Row(
            children: [
              Icon(Icons.radio_button_unchecked, color: Colors.grey, size: 16),
              const SizedBox(width: 8),
              const Text('To Do'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.inProgress,
          child: Row(
            children: [
              Icon(Icons.play_circle, color: Colors.orange, size: 16),
              const SizedBox(width: 8),
              const Text('In Progress'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.complete,
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 16),
              const SizedBox(width: 8),
              const Text('Complete'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.abandoned,
          child: Row(
            children: [
              Icon(Icons.cancel, color: Colors.red, size: 16),
              const SizedBox(width: 8),
              const Text('Cancelled'),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _getStatusText(note.status),
              style: const TextStyle(fontSize: 10),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 12),
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

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    
    if (difference.inDays == 0) {
      return 'Today';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
