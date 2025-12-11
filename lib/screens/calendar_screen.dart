import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/multi_select_tag_filter.dart';
import '../utils/date_utils.dart';
import 'note_detail_screen.dart';
import '../widgets/interactive_checkbox_markdown.dart';
import '../widgets/filter_tab_strip.dart';
import 'package:uuid/uuid.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, List<Note>>? _groupedNotes;

  // Drag and Drop State
  Note? _draggingTask;
  DateTime? _hoverDate;
  int _dragDurationDays = 1;
  double _lastPinchScale = 1.0;
  DateTime? _dragStartDate;

  // Raw Pointer Tracking for custom pinch
  final Map<int, Offset> _activePointers = {};
  double? _lastPinchDistance;
  CalendarFormat _calendarFormat = CalendarFormat.month;
  int _calendarKey = 0; // Add a key to force rebuild
  Set<String> _selectedTags = {};
  List<String> _availableTags = [];
  String _selectedView = 'calendar'; // 'calendar', 'timeline', 'todo'
  Set<String> _selectedFilterIds = {'default'};
  Set<Note> _selectedNotes = {}; // For multi-select

  bool get _isMultiSelectMode => _selectedNotes.isNotEmpty;

  void _enterMultiSelectMode(Note note) {
    setState(() {
      _selectedNotes.add(note);
    });
  }

  void _exitMultiSelectMode() {
    setState(() {
      _selectedNotes.clear();
    });
  }

  void _toggleNoteSelection(Note note) {
    setState(() {
      if (_selectedNotes.contains(note)) {
        _selectedNotes.remove(note);
        // If the last item is deselected, we could exit mode,
        // but typically standard behavior might be to stay in mode until explicit exit or back.
        // However user request "When it's multi-selected", implies mode active.
        // Let's keep mode active even if empty if that's standard, OR exit if empty.
        // Let's match NotesScreen logic or user expectation.
        // NotesScreen logic: "switch (value) { case 'deselectAll': ... }"
        // If we deselect all, does it exit?
        // Let's implement auto-exit if empty for now for smoother UX on mobile.
      } else {
        _selectedNotes.add(note);
      }
    });
  }

  Future<void> _archiveAllSelected() async {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.archiveAll),
        content: Text(
          'Are you sure you want to archive ${_selectedNotes.length} selected items?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.yes),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final note in _selectedNotes) {
        final updatedNote = note.copyWith(
          isArchived: true,
          pinned: false,
          updatedAt: DateTime.now(),
        );
        appProvider.updateNote(updatedNote);
      }
      _exitMultiSelectMode();
    }
  }

  Future<void> _showMarkAllAsDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final status = await showDialog<TaskStatus>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.markAllAs),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, TaskStatus.todo),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.toDo),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, TaskStatus.inProgress),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.inProgress),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, TaskStatus.complete),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.completed),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, TaskStatus.abandoned),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.cancelled),
            ),
          ),
        ],
      ),
    );

    if (status != null) {
      final appProvider = context.read<AppProvider>();
      for (final note in _selectedNotes) {
        if (note.isTask) {
          appProvider.updateTaskStatus(note.id, status);
        }
      }
      _exitMultiSelectMode();
    }
  }

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

  void _onTaskDropped(Note task, DateTime targetDate) {
    if (task.scheduledAt == null) return;

    final appProvider = context.read<AppProvider>();
    final currentScheduledDate = DateTime.parse(task.scheduledAt!);
    // Convert targetDate (which might be UTC from TableCalendar) to local time midnight
    // to ensure day difference calculation is exact days, not affected by timezone offsets
    final targetDateLocal = DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
    );

    final duration = targetDateLocal.difference(
      DateTime(
        currentScheduledDate.year,
        currentScheduledDate.month,
        currentScheduledDate.day,
      ),
    );

    // Calculate new scheduled date
    final newScheduledDate = currentScheduledDate.add(duration);

    // Calculate new complete by date
    // If pinch-to-resize was used, _dragDurationDays will be > 1.
    final newStart = newScheduledDate;
    final newEnd = newStart.add(Duration(days: _dragDurationDays - 1));
    String newCompleteBy = newEnd.toIso8601String();

    if (task.completeBy != null) {
      // Optional: Preserve time component logic could go here
    }

    final updatedTask = task.copyWith(
      scheduledAt: newScheduledDate.toIso8601String(),
      completeBy: newCompleteBy,
      updatedAt: DateTime.now(),
    );

    appProvider.updateNote(updatedTask);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.taskRescheduled),
        action: SnackBarAction(
          label: AppLocalizations.of(context)!.undo,
          onPressed: () {
            appProvider.updateNote(task);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(_getViewTitle(l10n)),
        actions: [
          if (_isMultiSelectMode) ...[
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                switch (value) {
                  case 'markAllAs':
                    await _showMarkAllAsDialog();
                    break;
                  case 'archiveAll':
                    await _archiveAllSelected();
                    break;
                  case 'selectAll':
                    // We need to implement selectAll.
                    // This is tricky as we need the list of currently visible/filtered notes.
                    // We'll handle this by passing the current list to the action or keeping track of it.
                    // For now, let's just use the current timeline notes.
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'markAllAs', child: Text(l10n.markAllAs)),
                PopupMenuItem(
                  value: 'archiveAll',
                  child: Text(l10n.archiveAll),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _exitMultiSelectMode,
            ),
          ] else ...[
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
                      Text(l10n.calendar),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'timeline',
                  child: Row(
                    children: [
                      Icon(Icons.timeline, size: 20),
                      const SizedBox(width: 8),
                      Text(l10n.timeline),
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
              allNotesLabel: l10n.allNotes,
              filterLabel: l10n.filter,
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
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          // Load tags when data becomes available
          if (!appProvider.isLoading &&
              appProvider.notes.isNotEmpty &&
              _availableTags.length <= 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _loadTags();
            });
          }

          if (_selectedView == 'timeline') {
            return Column(
              children: [
                FilterTabStrip(
                  selectedFilterIds: _selectedFilterIds,
                  additionalSelectedTags: _selectedTags,
                  customFilters: appProvider.filters,
                  availableTags: _availableTags,
                  onFilterSelected: (ids) {
                    setState(() {
                      _selectedFilterIds = ids;
                    });
                  },
                  onFilterCreated: (filter) => appProvider.addFilter(filter),
                  onFilterUpdated: (filter) => appProvider.updateFilter(filter),
                  onFilterDeleted: (id) => appProvider.deleteFilter(id),
                  onTagsUpdated: (tags) {
                    setState(() {
                      _selectedTags = tags;
                    });
                  },
                ),
                Expanded(child: _buildTimelineView(appProvider, l10n)),
              ],
            );
          } else {
            return SingleChildScrollView(
              child: Listener(
                onPointerDown: (event) {
                  _activePointers[event.pointer] = event.position;
                },
                onPointerMove: (event) {
                  _activePointers[event.pointer] = event.position;

                  if (_draggingTask != null && _activePointers.length >= 2) {
                    // Get two pointers
                    final pointers = _activePointers.values.take(2).toList();
                    final distance = (pointers[0] - pointers[1]).distance;

                    if (_lastPinchDistance == null) {
                      _lastPinchDistance = distance;
                    } else {
                      // Simple distance delta logic
                      final delta = distance - _lastPinchDistance!;

                      // Threshold to trigger change (e.g. 50 logical pixels)
                      if (delta.abs() > 30) {
                        if (delta > 0) {
                          // Growing
                          setState(() {
                            _dragDurationDays++;
                            _lastPinchDistance = distance;
                          });
                        } else {
                          // Shrinking
                          if (_dragDurationDays > 1) {
                            setState(() {
                              _dragDurationDays--;
                              _lastPinchDistance = distance;
                            });
                          }
                        }
                      }
                    }
                  }
                },
                onPointerUp: (event) {
                  _activePointers.remove(event.pointer);
                  if (_activePointers.length < 2) {
                    _lastPinchDistance = null;
                  }
                },
                onPointerCancel: (event) {
                  _activePointers.remove(event.pointer);
                  _lastPinchDistance = null;
                },
                child: Column(
                  children: [
                    FilterTabStrip(
                      selectedFilterIds: _selectedFilterIds,
                      additionalSelectedTags: _selectedTags,
                      customFilters: appProvider.filters,
                      availableTags: _availableTags,
                      onFilterSelected: (ids) {
                        setState(() {
                          _selectedFilterIds = ids;
                          _calendarKey++; // Force calendar rebuild
                        });
                      },
                      onFilterCreated: (filter) =>
                          appProvider.addFilter(filter),
                      onFilterUpdated: (filter) =>
                          appProvider.updateFilter(filter),
                      onFilterDeleted: (id) => appProvider.deleteFilter(id),
                      onTagsUpdated: (tags) {
                        setState(() {
                          _selectedTags = tags;
                          _calendarKey++;
                        });
                      },
                    ),
                    TableCalendar<Note>(
                      key: ValueKey(
                        '${_calendarKey}_${appProvider.dataVersion}',
                      ),
                      firstDay: DateTime.utc(2020, 1, 1),
                      lastDay: DateTime.utc(2030, 12, 31),
                      focusedDay: _focusedDay,
                      calendarFormat: _calendarFormat,
                      availableCalendarFormats: {
                        CalendarFormat.month: l10n.month,
                        CalendarFormat.twoWeeks: l10n.twoWeeks,
                        CalendarFormat.week: l10n.week,
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
                        final filteredNotes = _filterNotes(
                          appProvider.notes,
                          appProvider,
                        );
                        return filteredNotes.where((note) {
                          return note.isTask && _isTaskActiveOnDay(note, day);
                        }).toList();
                      },
                      calendarBuilders: CalendarBuilders(
                        markerBuilder: (context, day, events) {
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: DragTarget<Note>(
                                  onWillAccept: (data) {
                                    if (data == null) return false;
                                    if (_hoverDate != day) {
                                      setState(() {
                                        _hoverDate = day;
                                        _dragStartDate = day;
                                      });
                                    }
                                    return true;
                                  },
                                  onLeave: (data) {
                                    if (_hoverDate == day) {
                                      setState(() {
                                        _hoverDate = null;
                                        _dragStartDate = null;
                                      });
                                    }
                                  },
                                  onAccept: (data) => _onTaskDropped(data, day),
                                  builder: (context, candidateData, rejectedData) {
                                    // Determine if this day should be highlighted
                                    Color? highlightColor;

                                    // 1. Target Preview (Hover)
                                    if (_hoverDate != null) {
                                      final end = _hoverDate!.add(
                                        Duration(days: _dragDurationDays - 1),
                                      );
                                      // Check if 'day' is within hover start and end
                                      final isWithinHover =
                                          !day.isBefore(_hoverDate!) &&
                                          !day.isAfter(end);
                                      if (isWithinHover) {
                                        highlightColor = Theme.of(
                                          context,
                                        ).colorScheme.primary.withOpacity(0.3);
                                      }
                                    }

                                    // 2. Source Highlight (Drag Start) - only if no target highlight yet
                                    if (highlightColor == null &&
                                        _draggingTask != null &&
                                        _draggingTask!.scheduledAt != null) {
                                      final start = DateTime.parse(
                                        _draggingTask!.scheduledAt!,
                                      );
                                      // Use original duration for source highlight, or we could track original end date
                                      // final endStr = _draggingTask!.completeBy;
                                      // final end = endStr != null
                                      //    ? DateTime.parse(endStr)
                                      //    : start;

                                      // Normalize dates to midnight for comparison
                                      final dayDate = DateTime(
                                        day.year,
                                        day.month,
                                        day.day,
                                      );
                                      final startDate = DateTime(
                                        start.year,
                                        start.month,
                                        start.day,
                                      );

                                      // Use _dragDurationDays to calculate current visual end date
                                      final endDate = startDate.add(
                                        Duration(days: _dragDurationDays - 1),
                                      );

                                      final isWithinSource =
                                          !dayDate.isBefore(startDate) &&
                                          !dayDate.isAfter(endDate);
                                      if (isWithinSource) {
                                        highlightColor = Theme.of(context)
                                            .colorScheme
                                            .secondary
                                            .withOpacity(0.2);
                                      }
                                    }

                                    return Container(
                                      decoration: BoxDecoration(
                                        color: highlightColor,
                                        borderRadius: BorderRadius.circular(4),
                                        border: highlightColor != null
                                            ? Border.all(
                                                color: highlightColor
                                                    .withOpacity(0.5),
                                                width: 1,
                                              )
                                            : null,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              // Existing markers
                              if (events.isNotEmpty)
                                Positioned(
                                  bottom: 1,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Container(
                                      width: 30,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: Row(
                                        children: [
                                          if (events
                                              .where(
                                                (n) =>
                                                    !n.isArchived &&
                                                    n.status == TaskStatus.todo,
                                              )
                                              .isNotEmpty)
                                            Expanded(
                                              flex: events
                                                  .where(
                                                    (n) =>
                                                        !n.isArchived &&
                                                        n.status ==
                                                            TaskStatus.todo,
                                                  )
                                                  .length,
                                              child: Container(
                                                color: Colors.red,
                                              ),
                                            ),
                                          if (events
                                              .where(
                                                (n) =>
                                                    !n.isArchived &&
                                                    n.status ==
                                                        TaskStatus.inProgress,
                                              )
                                              .isNotEmpty)
                                            Expanded(
                                              flex: events
                                                  .where(
                                                    (n) =>
                                                        !n.isArchived &&
                                                        n.status ==
                                                            TaskStatus
                                                                .inProgress,
                                                  )
                                                  .length,
                                              child: Container(
                                                color: Colors.amber,
                                              ),
                                            ),
                                          if (events
                                              .where(
                                                (n) =>
                                                    !n.isArchived &&
                                                    n.status ==
                                                        TaskStatus.complete,
                                              )
                                              .isNotEmpty)
                                            Expanded(
                                              flex: events
                                                  .where(
                                                    (n) =>
                                                        !n.isArchived &&
                                                        n.status ==
                                                            TaskStatus.complete,
                                                  )
                                                  .length,
                                              child: Container(
                                                color: Colors.green,
                                              ),
                                            ),
                                          if (events
                                              .where(
                                                (n) =>
                                                    !n.isArchived &&
                                                    n.status ==
                                                        TaskStatus.abandoned,
                                              )
                                              .isNotEmpty)
                                            Expanded(
                                              flex: events
                                                  .where(
                                                    (n) =>
                                                        !n.isArchived &&
                                                        n.status ==
                                                            TaskStatus
                                                                .abandoned,
                                                  )
                                                  .length,
                                              child: Container(
                                                color: Colors.grey,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      calendarStyle: CalendarStyle(outsideDaysVisible: true),
                      headerStyle: HeaderStyle(
                        formatButtonVisible: true,
                        titleCentered: true,
                        formatButtonShowsNext: false,
                      ),
                    ),
                    const Divider(),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        // Calculate a reasonable height for content area
                        final screenHeight = MediaQuery.of(context).size.height;
                        final contentHeight = (screenHeight * 0.4).clamp(
                          300.0,
                          500.0,
                        );

                        return SizedBox(
                          height: contentHeight,
                          child: _selectedDay == null
                              ? const Center(
                                  child: Text(
                                    'Select a day to view notes and tasks',
                                  ),
                                )
                              : _buildTabbedDayContent(appProvider, l10n),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildTabbedDayContent(
    AppProvider appProvider,
    AppLocalizations l10n,
  ) {
    final selectedDate = _selectedDay!;
    final filteredNotes = _filterNotes(appProvider.notes, appProvider);

    final tasks = filteredNotes
        .where((n) => n.isTask && _isTaskActiveOnDay(n, selectedDate))
        .toList();
    final notes = filteredNotes
        .where((n) => !n.isTask && isSameDay(_getNoteDate(n), selectedDate))
        .toList();

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          // Date header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              AppDateUtils.formatDateNumeric(selectedDate, context),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          // Tab bar
          Container(
            color: Theme.of(context).colorScheme.surface,
            child: TabBar(
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.task_alt, size: 18),
                      const SizedBox(width: 8),
                      Text('${l10n.tasks} (${tasks.length})'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.note, size: 18),
                      const SizedBox(width: 8),
                      Text('${l10n.notes} (${notes.length})'),
                    ],
                  ),
                ),
              ],
              labelColor: Theme.of(context).colorScheme.onSurface,
              unselectedLabelColor: Theme.of(
                context,
              ).colorScheme.onSurface.withOpacity(0.6),
              indicatorColor: Theme.of(context).colorScheme.primary,
              indicatorWeight: 2.0,
              dividerColor: Theme.of(
                context,
              ).colorScheme.outline.withOpacity(0.2),
            ),
          ),
          // Tab content - use Expanded to fill remaining space
          Expanded(
            child: TabBarView(
              physics: _draggingTask != null
                  ? const NeverScrollableScrollPhysics()
                  : null,
              children: [
                _buildTasksTab(tasks, appProvider, l10n),
                _buildNotesTab(notes, l10n),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTasksTab(
    List<Note> tasks,
    AppProvider appProvider,
    AppLocalizations l10n,
  ) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.task_alt, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _selectedTags.isEmpty
                  ? l10n.noTasksForToday
                  : l10n.noTasksWithSelectedTagsForThisDay,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedTags.isEmpty
                  ? l10n.createFirstTask
                  : l10n.trySelectingDifferentTags,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[500]),
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
        return LongPressDraggable<Note>(
          data: task,
          onDragStarted: () {
            setState(() {
              _draggingTask = task;
              // Calculate initial duration
              final start = DateTime.parse(task.scheduledAt!);
              final end = task.completeBy != null
                  ? DateTime.parse(task.completeBy!)
                  : start;
              _dragDurationDays = end.difference(start).inDays + 1; // inclusive
              if (_dragDurationDays < 1) _dragDurationDays = 1;
              _lastPinchScale = 1.0;
            });
          },
          onDragEnd: (details) {
            setState(() {
              _draggingTask = null;
              _hoverDate = null;
              _dragDurationDays = 1;
              _dragStartDate = null;
            });
          },
          feedback: SizedBox(
            width: MediaQuery.of(context).size.width * 0.8,
            child: Card(
              elevation: 4,
              child: ListTile(
                leading: _buildStatusIcon(task),
                title: Text(task.title),
                subtitle: Text(
                  AppDateUtils.formatDateNumeric(
                    DateTime.parse(task.scheduledAt!),
                    context,
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.5,
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: _buildStatusIcon(task),
                title: Text(
                  task.title,
                  style: TextStyle(
                    decoration: task.isCompleted
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: SelectionArea(
                  child: InteractiveCheckboxMarkdown(
                    noteId: task.id,
                    originalContent: task.content,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    onLinkTap: _handleLinkTap,
                  ),
                ),
                trailing: _buildStatusDropdown(task, appProvider),
                onTap: () => _openNoteDetail(task),
              ),
            ),
          ),
          child: Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: _buildStatusIcon(task),
              title: Text(
                task.title,
                style: TextStyle(
                  decoration: task.isCompleted
                      ? TextDecoration.lineThrough
                      : null,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectionArea(
                    child: InteractiveCheckboxMarkdown(
                      noteId: task.id,
                      originalContent: task.content,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      onLinkTap: _handleLinkTap,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.updated}: ${AppDateUtils.formatDateTimeNumeric(task.updatedAt, context)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[500],
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildStatusDropdown(task, appProvider),
                  IconButton(
                    icon: const Icon(Icons.add_task, size: 20),
                    onPressed: () => _showCheckInDialog(task),
                    tooltip: l10n.checkIn,
                  ),
                ],
              ),
              onTap: () => _openNoteDetail(task),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNotesTab(List<Note> notes, AppLocalizations l10n) {
    if (notes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _selectedTags.isEmpty
                  ? l10n.noNotesForToday
                  : l10n.noNotesWithSelectedTagsForThisDay,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedTags.isEmpty
                  ? l10n.createFirstNote
                  : l10n.trySelectingDifferentTags,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[500]),
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
            subtitle: SelectionArea(child: _buildSafeMarkdown(note, context)),
            onTap: () => _openNoteDetail(note),
          ),
        );
      },
    );
  }

  void _openNoteDetail(Note note) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => NoteDetailScreen(note: note)),
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

    return Icon(iconData, color: iconColor, size: 24);
  }

  Widget _buildStatusDropdown(Note task, AppProvider appProvider) {
    final l10n = AppLocalizations.of(context)!;
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
              Text(l10n.toDo),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.inProgress,
          child: Row(
            children: [
              Icon(Icons.play_circle, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Text(l10n.inProgress),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.complete,
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 20),
              const SizedBox(width: 8),
              Text(l10n.completed),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.abandoned,
          child: Row(
            children: [
              Icon(Icons.cancel, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              Text(l10n.cancelled),
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

  String _getViewTitle(AppLocalizations l10n) {
    switch (_selectedView) {
      case 'timeline':
        return l10n.timeline;
      case 'calendar':
      default:
        return l10n.calendar;
    }
  }

  Widget _buildTimelineView(AppProvider appProvider, AppLocalizations l10n) {
    if (appProvider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final notes = _filterNotes(
      appProvider.notes,
      appProvider,
    ).where((n) => n.isTask).toList();
    if (notes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.timeline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _selectedTags.isEmpty
                  ? l10n.createFirstTimelineNote
                  : l10n.noTasksWithSelectedTags,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _selectedTags.isEmpty
                  ? l10n.createFirstTimelineNote
                  : l10n.trySelectingDifferentTags,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Group notes by date
    final groupedNotes = _groupNotesByDate(notes);

    // Split into Future, Today, Past
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final futureMap = <DateTime, List<Note>>{};
    final todayMap = <DateTime, List<Note>>{};
    final pastMap = <DateTime, List<Note>>{};

    for (final entry in groupedNotes.entries) {
      final date = entry.key;
      final compareDate = DateTime(date.year, date.month, date.day);

      if (compareDate.isAfter(today)) {
        futureMap[date] = entry.value;
      } else if (compareDate.isBefore(today)) {
        pastMap[date] = entry.value;
      } else {
        todayMap[date] = entry.value;
      }
    }

    // Future: Ascending (Near -> Far) for Reverse Growth list
    final sortedFutureEntries = futureMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    // Past: Descending (Recent -> Old)
    final sortedPastEntries = pastMap.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    // Flatten lists with headers
    final futureWidgets = _buildFlattenedTimeline(
      sortedFutureEntries,
      l10n,
      appProvider,
      isFuture: true,
      reverseHeader:
          true, // Future grows upwards, so headers must be *after* items
    );

    final pastWidgets = _buildFlattenedTimeline(
      sortedPastEntries,
      l10n,
      appProvider,
      isPast: true,
      startingMonth: today, // Past starts checking against Today's month
    );

    return CustomScrollView(
      center: const ValueKey('today-section'),
      slivers: [
        // Future Section
        if (futureWidgets.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => futureWidgets[index],
              childCount: futureWidgets.length,
            ),
          ),

        // Today Section (Center)
        SliverPadding(
          padding: EdgeInsets.zero,
          key: const ValueKey('today-section'),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              if (todayMap.isNotEmpty)
                ...todayMap.entries.map(
                  (entry) => _buildTimelineDateGroup(
                    entry.key,
                    entry.value,
                    l10n,
                    appProvider,
                    isToday: true,
                  ),
                )
              else
                _buildEmptyTodayPlaceholder(l10n),
            ]),
          ),
        ),

        // Past Section
        if (pastWidgets.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => pastWidgets[index],
              childCount: pastWidgets.length,
            ),
          ),
      ],
    );
  }

  DateTime _getNoteDate(Note note) {
    if (note.scheduledAt != null && note.scheduledAt!.isNotEmpty) {
      try {
        return DateTime.parse(note.scheduledAt!);
      } catch (e) {
        return note.createdAt;
      }
    }
    return note.createdAt;
  }

  bool _isTaskActiveOnDay(Note note, DateTime day) {
    if (!note.isTask) return false;

    DateTime start = _getNoteDate(note);
    DateTime? end;

    if (note.completeBy != null && note.completeBy!.isNotEmpty) {
      try {
        end = DateTime.parse(note.completeBy!);
      } catch (e) {
        // invalid completeBy, ignore it
      }
    }

    // Normalize dates to remove time components for comparison
    final dayDate = DateTime(day.year, day.month, day.day);
    final startDate = DateTime(start.year, start.month, start.day);

    if (end != null) {
      final endDate = DateTime(end.year, end.month, end.day);
      return (dayDate.isAtSameMomentAs(startDate) ||
              dayDate.isAfter(startDate)) &&
          (dayDate.isAtSameMomentAs(endDate) || dayDate.isBefore(endDate));
    }

    return isSameDay(start, day);
  }

  List<Widget> _buildFlattenedTimeline(
    List<MapEntry<DateTime, List<Note>>> entries,
    AppLocalizations l10n,
    AppProvider appProvider, {
    bool isFuture = false,
    bool isPast = false,
    DateTime? startingMonth,
    bool reverseHeader = false,
  }) {
    if (entries.isEmpty) return [];

    final widgets = <Widget>[];

    // Logic split based on growth direction
    if (reverseHeader) {
      // Future / Reverse Growth: [Item, Header] visual order means [Item, Header] in list (index 0 is bottom).
      // We process Near -> Far.
      // List: [Near Item, Header(Near)?, Far Item, Header(Far)?]

      int? currentMonth;
      int? currentYear;
      DateTime?
      previousDateForHeader; // Stores a date from the month group that just finished

      for (final entry in entries) {
        final date = entry.key;

        if (currentMonth == null) {
          // First item, initialize tracking
          currentMonth = date.month;
          currentYear = date.year;
          previousDateForHeader = date;
        } else if (currentMonth != date.month || currentYear != date.year) {
          // Month changed, add header for the *previous* month group
          widgets.add(_buildMonthHeader(previousDateForHeader!, l10n));
          // Update tracking for the new month group
          currentMonth = date.month;
          currentYear = date.year;
          previousDateForHeader = date;
        }

        widgets.add(
          _buildTimelineDateGroup(
            date,
            entry.value,
            l10n,
            appProvider,
            isFuture: isFuture,
            isPast: isPast,
          ),
        );
      }

      // Add final header for the last processed group
      if (previousDateForHeader != null) {
        widgets.add(_buildMonthHeader(previousDateForHeader, l10n));
      }
    } else {
      // Past / Normal Growth: [Header, Item] visual order.
      // Past starts checking against startingMonth (Today).

      int? currentMonth = startingMonth?.month;
      int? currentYear = startingMonth?.year;

      for (final entry in entries) {
        final date = entry.key;

        if (currentMonth != date.month || currentYear != date.year) {
          widgets.add(_buildMonthHeader(date, l10n));
          currentMonth = date.month;
          currentYear = date.year;
        }

        widgets.add(
          _buildTimelineDateGroup(
            date,
            entry.value,
            l10n,
            appProvider,
            isFuture: isFuture,
            isPast: isPast,
          ),
        );
      }
    }

    return widgets;
  }

  Widget _buildMonthHeader(DateTime date, AppLocalizations l10n) {
    // Format: "MMMM yyyy"
    final months = [
      l10n.january,
      l10n.february,
      l10n.march,
      l10n.april,
      l10n.may,
      l10n.june,
      l10n.july,
      l10n.august,
      l10n.september,
      l10n.october,
      l10n.november,
      l10n.december,
    ];
    final title = '${months[date.month - 1]} ${date.year}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).disabledColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).disabledColor,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyTodayPlaceholder(AppLocalizations l10n) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              l10n.today,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.noNotesForToday,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineDateGroup(
    DateTime date,
    List<Note> notes,
    AppLocalizations l10n,
    AppProvider appProvider, {
    bool isFuture = false,
    bool isToday = false,
    bool isPast = false,
  }) {
    Color backgroundColor;
    Color headerColor;

    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    if (isToday) {
      backgroundColor = isDark
          ? Colors.teal.shade900.withOpacity(0.3)
          : Colors.teal.shade50.withOpacity(0.7);
      headerColor = Colors.teal;
    } else if (isFuture) {
      // Subtle Future Color
      backgroundColor = isDark
          ? Colors.blueGrey.shade900.withOpacity(0.2) // Subtle Dark
          : Colors.blueGrey.shade50.withOpacity(0.5); // Subtle Light
      headerColor = isDark ? Colors.blueGrey.shade300 : Colors.blueGrey;
    } else {
      // Past
      backgroundColor = Theme.of(context).colorScheme.surface;
      headerColor = Colors.grey;
    }

    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isToday ? headerColor : headerColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: headerColor.withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: Text(
                  _formatDate(date, l10n),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isToday ? Colors.white : headerColor,
                  ),
                ),
              ),
              if (isToday) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    "NOW",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          ...notes.map((note) {
            final isSelected = _selectedNotes.contains(note);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                elevation: isSelected ? 4 : (isToday ? 2 : 1),
                color: isSelected
                    ? Theme.of(
                        context,
                      ).colorScheme.primaryContainer.withOpacity(0.3)
                    : null,
                shape: isSelected
                    ? RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2,
                        ),
                      )
                    : null,
                child: InkWell(
                  onTap: () {
                    if (_isMultiSelectMode) {
                      _toggleNoteSelection(note);
                    } else {
                      _openNoteDetail(note);
                    }
                  },
                  onLongPress: () {
                    // Enter multi-select mode only for tasks in timeline view if needed,
                    // but the user requirement implies "timeline view in calendar screen".
                    // Assuming all notes here are eligible.
                    if (!_isMultiSelectMode) {
                      _enterMultiSelectMode(note);
                    } else {
                      // Already in mode, toggle
                      _toggleNoteSelection(note);
                    }
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // In multi-select mode, maybe show checkbox? user didn't specificially ask for it but it's good UX.
                            // But let's stick to the highlighting for now as requested.
                            if (note.isTask) ...[
                              _buildStatusIcon(note),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                note.title,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      decoration: note.isCompleted
                                          ? TextDecoration.lineThrough
                                          : null,
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
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.grey[600]),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (note.isTask)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _TaskProgressBar(
                                  note: note,
                                  appProvider: appProvider,
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${l10n.updated}: ${AppDateUtils.formatDateTimeNumeric(note.updatedAt, context)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Colors.grey[500],
                                            fontSize: 10,
                                          ),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _showCheckInDialog(note),
                                      icon: const Icon(
                                        Icons.add_task,
                                        size: 16,
                                      ),
                                      label: Text(l10n.checkIn),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),

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
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  List<Note> _filterNotes(List<Note> notes, AppProvider appProvider) {
    List<Note> filteredNotes = notes;

    // Combine notes from all selected filters (Union)
    Set<String> noteIds = {};
    List<Note> unionNotes = [];

    // If 'all' is selected, it overrides everything else
    if (_selectedFilterIds.contains('all')) {
      filteredNotes = notes;
    } else {
      for (final filterId in _selectedFilterIds) {
        List<Note> subset = [];
        if (filterId == 'default') {
          subset = notes.where((note) => !note.isArchived).toList();
        } else if (filterId == 'pinned') {
          subset = notes
              .where((note) => note.pinned && !note.isArchived)
              .toList();
        } else if (filterId == 'archived') {
          subset = notes.where((note) => note.isArchived).toList();
        } else {
          // Custom filter
          try {
            final customFilter = appProvider.filters.firstWhere(
              (filter) => filter.id == filterId,
            );
            subset = appProvider.getFilteredNotes(customFilter);
          } catch (e) {
            continue;
          }
        }

        for (final note in subset) {
          if (noteIds.add(note.id)) {
            unionNotes.add(note);
          }
        }
      }
      filteredNotes = unionNotes;
    }

    // Filter by tasks only? No, Timeline shows Notes and Tasks.
    // And Calendar shows both (in separate tabs).
    // Original _filterNotes logic: "Filter to only show tasks that are not archived"
    // Wait, the original method was named `_filterNotes` but it did:
    // final tasks = notes.where((note) => note.isTask && !note.isArchived).toList();
    // It filtered out non-tasks AND archived notes hardcoded!
    // But `_buildTabbedDayContent` used `getNotesForDate` which includes notes.
    // The previous `_buildTimelineView` called `_filterNotes` which seemingly ONLY returned TASKS?
    // Let's check the original code again.
    // Line 1028: List<Note> _filterNotes(List<Note> notes) {
    // Line 1030:   final tasks = notes.where((note) => note.isTask && !note.isArchived).toList();
    // So previously, Timeline View ONLY showed unarchived TASKS?
    // And Tag filtering.
    //
    // NOW, with FilterStrip, we support "Archived" and "All".
    // AND we probably want to support Notes in Timeline if they have dates?
    // `_groupNotesByDate` uses `scheduledAt` or `createdAt`. So Notes are valid in Timeline.
    //
    // If we want to maintain "Tasks Only" for Timeline... the user didn't explicitly ask to change that behavior,
    // but they asked for "Calendar Screen" filtering which implies the whole screen.
    // However, `_buildTimelineView` called `_filterNotes` which returned `tasks`.
    // If I change this to return Notes too, Timeline will show Notes.
    // Is this desired?
    // "Timeline view should clearly render 'TODAY', 'Things in the future'..."
    // "Tasks" usually have dates. Notes have created dates.
    //
    // The previous implementation of `_filterNotes` was:
    // final tasks = notes.where((note) => note.isTask && !note.isArchived).toList();
    //
    // If I switch to general filtering, `Timeline` might show regular notes.
    // Given the previous code explicitly filtered for `note.isTask`, I should probably respect that for now?
    // OR, since we are adding "Filter Strip", maybe the user WANTS to see notes?
    // "It will work the same way as the main screen."
    // Main screen shows Notes AND Tasks.
    // So safe bet: Show everything that matches the filter.
    //
    // However, for correct integration:
    // 1. `_filterNotes` (new) returns ALL matching notes (Tasks + Notes).
    // 2. `_buildTimelineView` uses this. If we want only Tasks, we should filter `isTask` there.
    //    But Timeline usually implies a history/schedule. Notes fit in history (createdAt).
    //    Let's allow Notes.
    //
    // Tag Filtering (Intersection)
    if (_selectedTags.isNotEmpty) {
      filteredNotes = filteredNotes.where((note) {
        return _selectedTags.any(
          (selectedTag) => note.tags.contains(selectedTag),
        );
      }).toList();
    }

    return filteredNotes;
  }

  // Removed _buildTodoView and _filterTasks as per instruction

  Map<DateTime, List<Note>> _groupNotesByDate(List<Note> notes) {
    final Map<DateTime, List<Note>> grouped = {};

    for (final note in notes) {
      DateTime start;
      DateTime? end;

      // Determine start date
      if (note.scheduledAt != null && note.scheduledAt!.isNotEmpty) {
        try {
          start = DateTime.parse(note.scheduledAt!);
        } catch (e) {
          start = note.createdAt;
        }
      } else {
        start = note.createdAt;
      }

      // Determine end date
      if (note.isTask &&
          note.completeBy != null &&
          note.completeBy!.isNotEmpty) {
        try {
          end = DateTime.parse(note.completeBy!);
        } catch (e) {
          // invalid completeBy, ignore it
        }
      }

      // Normalize start/end to dates only
      final startDate = DateTime(start.year, start.month, start.day);
      final endDate = end != null
          ? DateTime(end.year, end.month, end.day)
          : startDate;

      // Add note to all dates in range [startDate, endDate]
      // Loop: curr <= endDate
      DateTime curr = startDate;
      while (curr.isBefore(endDate) || curr.isAtSameMomentAs(endDate)) {
        if (grouped[curr] == null) {
          grouped[curr] = [];
        }
        grouped[curr]!.add(note);
        curr = curr.add(const Duration(days: 1));
      }
    }

    // Sort by date (most recent first)
    final sortedEntries = grouped.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    return Map.fromEntries(sortedEntries);
  }

  Future<void> _showCheckInDialog(Note task) async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.checkIn),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.enterCheckInNote,
            border: const OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final now = DateTime.now();
                // Create subnote
                // NOTE: Creating a subnote as a separate Note type, but logically linked via parent logic if needed.
                // However, the Note model definition viewer showed 'subNotes' field but not 'parentNoteId' in constructor.
                // We should check how SubNotes are handled.
                // Based on Note definition: final List<SubNote> subNotes;
                // It seems we should add this to the parent's subNotes list instead of creating a standalone linked Note?
                // OR if we want it to be a standalone Note, we need to verify if 'parentNoteId' exists.
                // The view of note.dart showed lines 1-50, and I don't see 'parentNoteId' field in the class fields list (lines 24-40).
                // Let's assume we maintain the behavior requested: "save a subnote to the task".

                // Let's try to add it to the task's subNotes list.
                final newSubNote = SubNote(
                  id: const Uuid().v4(),
                  name: AppDateUtils.formatDateNumeric(now, context),
                  content: controller.text,
                  createdAt: now,
                  isCompleted: false,
                );

                final updatedSubNotes = List<SubNote>.from(task.subNotes)
                  ..add(newSubNote);

                // Update task's updatedAt and subNotes
                final updatedTask = task.copyWith(
                  updatedAt: now,
                  subNotes: updatedSubNotes,
                );

                final appProvider = Provider.of<AppProvider>(
                  context,
                  listen: false,
                );
                await appProvider.updateNote(updatedTask);

                if (mounted) {
                  Navigator.of(context).pop();
                }
              }
            },
            child: Text(AppLocalizations.of(context)!.save),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date, AppLocalizations l10n) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dateOnly = DateTime(date.year, date.month, date.day);

    if (dateOnly == today) {
      return l10n.today;
    } else if (dateOnly == yesterday) {
      return l10n.yesterday;
    } else {
      final months = [
        l10n.january,
        l10n.february,
        l10n.march,
        l10n.april,
        l10n.may,
        l10n.june,
        l10n.july,
        l10n.august,
        l10n.september,
        l10n.october,
        l10n.november,
        l10n.december,
      ];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
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
            onContentChanged: (newContent) {
              // No-op for read-only display
            },
            style: Theme.of(context).textTheme.bodySmall,
            onLinkTap: _handleLinkTap,
          ),
        ),
      );
    } catch (e) {
      // Fallback to simple text if InteractiveCheckboxMarkdown fails
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
    final l10n = AppLocalizations.of(context)!;
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${l10n.cannotOpenLink}: $url'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l10n.errorOpeningLink}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// Helper widget for task progress
class _TaskProgressBar extends StatelessWidget {
  final Note note;
  final AppProvider appProvider;

  const _TaskProgressBar({required this.note, required this.appProvider});

  @override
  Widget build(BuildContext context) {
    // 1. Calculate subnote progress immediately
    final subNotes = note.subNotes;
    final subNoteCount = subNotes.length;
    final subNoteCompleted = subNotes.where((s) => s.isCompleted).length;

    // 2. Fetch linked tasks asynchronously
    return FutureBuilder<List<Note>>(
      future: _getLinkedChildTasks(),
      builder: (context, snapshot) {
        final childTasks = snapshot.data ?? [];
        final childTaskCount = childTasks.length;
        final childTaskCompleted = childTasks
            .where((t) => t.isCompleted)
            .length;

        final totalCount = subNoteCount + childTaskCount;
        final totalCompleted = subNoteCompleted + childTaskCompleted;

        if (totalCount == 0) {
          return const SizedBox.shrink();
        }

        final progress = totalCompleted / totalCount;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.grey[200],
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _getProgressColor(progress),
                    ),
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$totalCompleted/$totalCount',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<List<Note>> _getLinkedChildTasks() async {
    try {
      final relationships = await appProvider.getNoteRelationships(note.id);
      // Filter for 'subnote' type where this note is the 'from' (parent)
      final childRelIds = relationships
          .where((r) => r.type == 'subnote' && r.fromNoteId == note.id)
          .map((r) => r.toNoteId)
          .toSet();

      if (childRelIds.isEmpty) return [];

      // Find the actual Task objects from the provider's in-memory list
      // We only care about Tasks for progress
      return appProvider.notes
          .where((n) => childRelIds.contains(n.id) && n.isTask)
          .toList();
    } catch (e) {
      return [];
    }
  }

  Color _getProgressColor(double progress) {
    if (progress >= 1.0) return Colors.green;
    if (progress > 0.5) return Colors.lightGreen;
    if (progress > 0.0) return Colors.orangeAccent;
    return Colors.grey;
  }
}
