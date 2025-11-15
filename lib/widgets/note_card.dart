import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../utils/date_utils.dart';
import '../services/logger_service.dart';
import 'interactive_checkbox_markdown.dart';

class NoteCard extends StatelessWidget {
  final Note note;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Function(TaskStatus)? onStatusChanged;
  final VoidCallback? onAddSubNote;
  final VoidCallback? onPinToggle;
  final VoidCallback? onArchiveToggle;
  final VoidCallback? onShare;
  final Function(String)? onContentChanged;
  final bool showAttachmentIndicator;

  const NoteCard({
    super.key,
    required this.note,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.onStatusChanged,
    this.onAddSubNote,
    this.onPinToggle,
    this.onArchiveToggle,
    this.onShare,
    this.onContentChanged,
    this.showAttachmentIndicator = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      elevation: isSelected ? 8 : 2,
      color: isSelected
          ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
          : null,
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
                        decoration: note.isCompleted
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onPinToggle != null)
                    IconButton(
                      icon: Icon(
                        note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                        color: note.pinned
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.onSurface.withOpacity(0.6),
                        size: 20,
                      ),
                      onPressed: onPinToggle,
                      tooltip: note.pinned ? l10n.unpinNote : l10n.pinNote,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  if (onShare != null)
                    IconButton(
                      icon: Icon(
                        Icons.share,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.6),
                        size: 20,
                      ),
                      onPressed: onShare,
                      tooltip: l10n.share,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  if (onArchiveToggle != null)
                    IconButton(
                      icon: Icon(
                        note.isArchived
                            ? Icons.archive
                            : Icons.archive_outlined,
                        color: note.isArchived
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(
                                context,
                              ).colorScheme.onSurface.withOpacity(0.6),
                        size: 20,
                      ),
                      onPressed: onArchiveToggle,
                      tooltip: note.isArchived
                          ? l10n.unarchiveNote
                          : l10n.archiveNote,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  if (note.isTask && onStatusChanged != null)
                    _buildStatusDropdown(note, context),
                  if (isSelected)
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _buildSafeMarkdown(note, context),
              if (note.subNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.list,
                      size: 16,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.6),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${note.subNotes.length} sub-notes',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                    if (note.isTask && note.subNotes.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        '(${note.subNotes.where((sn) => sn.isCompleted).length}/${note.subNotes.length} completed)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
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
                  children: note.tags
                      .take(3)
                      .map(
                        (tag) => Chip(
                          label: Text(
                            tag,
                            style: const TextStyle(fontSize: 12),
                          ),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary.withOpacity(0.1),
                          labelStyle: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 8),
              // Use LayoutBuilder to determine if we have enough space for horizontal layout
              LayoutBuilder(
                builder: (context, constraints) {
                  // Check if we have enough space for horizontal layout
                  final hasTaskDates =
                      note.isTask &&
                      (note.scheduledAt != null || note.completeBy != null);
                  double estimatedWidth = 200.0; // Base width for created date
                  if (hasTaskDates) {
                    if (note.scheduledAt != null) estimatedWidth += 120.0;
                    if (note.completeBy != null) estimatedWidth += 120.0;
                  }
                  final useHorizontalLayout =
                      constraints.maxWidth > estimatedWidth;

                  if (useHorizontalLayout) {
                    // Horizontal layout when there's enough space
                    return Row(
                      children: [
                        // Created date
                        Icon(
                          Icons.access_time,
                          size: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatDate(note.createdAt, context),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.6),
                              ),
                        ),
                        // Task dates
                        if (hasTaskDates) ...[
                          const SizedBox(width: 16),
                          if (note.scheduledAt != null) ...[
                            Icon(
                              Icons.play_arrow,
                              size: 14,
                              color: Colors.green[600],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Start: ${AppDateUtils.formatDateForDisplayLocalized(note.scheduledAt, context)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
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
                              'Due: ${AppDateUtils.formatDateForDisplayLocalized(note.completeBy, context)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Colors.orange[600],
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ],
                        ],
                        const Spacer(),
                        // Action buttons
                        if (onAddSubNote != null)
                          IconButton(
                            icon: const Icon(Icons.add, size: 16),
                            onPressed: onAddSubNote,
                            tooltip: 'Add sub-note',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        if (showAttachmentIndicator &&
                            note.attachmentPaths.isNotEmpty)
                          Icon(
                            Icons.attach_file,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.6),
                          ),
                      ],
                    );
                  } else {
                    // Vertical layout when space is limited
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Created date row
                        Row(
                          children: [
                            Icon(
                              Icons.access_time,
                              size: 14,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withOpacity(0.6),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatDate(note.createdAt, context),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.6),
                                  ),
                            ),
                            const Spacer(),
                            // Action buttons
                            if (onAddSubNote != null)
                              IconButton(
                                icon: const Icon(Icons.add, size: 16),
                                onPressed: onAddSubNote,
                                tooltip: 'Add sub-note',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            if (showAttachmentIndicator &&
                                note.attachmentPaths.isNotEmpty)
                              Icon(
                                Icons.attach_file,
                                size: 16,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.6),
                              ),
                          ],
                        ),
                        // Task dates in separate rows if needed
                        if (hasTaskDates) ...[
                          const SizedBox(height: 4),
                          if (note.scheduledAt != null)
                            Row(
                              children: [
                                Icon(
                                  Icons.play_arrow,
                                  size: 14,
                                  color: Colors.green[600],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Start: ${AppDateUtils.formatDateForDisplayLocalized(note.scheduledAt, context)}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Colors.green[600],
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                          if (note.completeBy != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.schedule,
                                  size: 14,
                                  color: Colors.orange[600],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Due: ${AppDateUtils.formatDateForDisplayLocalized(note.completeBy, context)}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Colors.orange[600],
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ],
                    );
                  }
                },
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
      case null:
        iconData = Icons.radio_button_unchecked;
        iconColor = Colors.grey;
        break;
    }

    return Icon(iconData, color: iconColor, size: 20);
  }

  Widget _buildStatusDropdown(Note note, BuildContext context) {
    if (!note.isTask || onStatusChanged == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;

    return PopupMenuButton<TaskStatus>(
      onSelected: (TaskStatus status) {
        onStatusChanged?.call(status);
      },
      itemBuilder: (BuildContext context) => [
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.todo,
          child: Row(
            children: [
              Icon(Icons.radio_button_unchecked, color: Colors.grey, size: 16),
              const SizedBox(width: 8),
              Text(l10n.toDo),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.inProgress,
          child: Row(
            children: [
              Icon(Icons.play_circle, color: Colors.orange, size: 16),
              const SizedBox(width: 8),
              Text(l10n.inProgress),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.complete,
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 16),
              const SizedBox(width: 8),
              Text(l10n.completed),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.abandoned,
          child: Row(
            children: [
              Icon(Icons.cancel, color: Colors.red, size: 16),
              const SizedBox(width: 8),
              Text(l10n.cancelled),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _getStatusText(note.status, context),
              style: const TextStyle(fontSize: 10),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 12),
          ],
        ),
      ),
    );
  }

  String _getStatusText(TaskStatus? status, BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    switch (status) {
      case TaskStatus.complete:
        return l10n.completed;
      case TaskStatus.inProgress:
        return l10n.inProgress;
      case TaskStatus.abandoned:
        return l10n.cancelled;
      case TaskStatus.todo:
      default:
        return l10n.toDo;
    }
  }

  String _formatDate(DateTime date, BuildContext context) {
    final now = DateTime.now();
    final difference = now.difference(date);
    final l10n = AppLocalizations.of(context)!;

    if (difference.inDays == 0) {
      return l10n.today;
    } else if (difference.inDays == 1) {
      return l10n.yesterday;
    } else if (difference.inDays < 7) {
      return l10n.daysAgo(difference.inDays);
    } else {
      return AppDateUtils.formatDateNumeric(date, context);
    }
  }

  Widget _buildSafeMarkdown(Note note, BuildContext context) {
    final content = note.content;
    try {
      // Use InteractiveCheckboxMarkdown approach but limit to first 3 lines
      final lines = content.split('\n');
      final limitedLines = lines.take(3).toList();
      final limitedContent = limitedLines.join('\n');

      return ClipRect(
        child: Align(
          alignment: Alignment.topLeft,
          heightFactor: 1.0,
          child: InteractiveCheckboxMarkdown(
            noteId: note.id,
            originalContent: limitedContent,
            onContentChanged:
                onContentChanged ??
                (newContent) {
                  // No-op if no callback provided
                },
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
            onLinkTap: _handleLinkTap,
            // Truncate content in card view
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    } catch (e) {
      // Fallback to simple text if InteractiveCheckboxMarkdown fails
      return Text(
        content,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
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
        // Note: We can't show a snackbar here since this is a stateless widget
        // The error will be silently handled
        LoggerService.warning('Cannot open link: $url');
      }
    } catch (e) {
      // Note: We can't show a snackbar here since this is a stateless widget
      // The error will be silently handled
      LoggerService.error('Error opening link: $e', error: e);
    }
  }
}
