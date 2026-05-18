import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../widgets/note_card.dart';
import '../widgets/multi_select_tag_filter.dart';
import '../widgets/share_dialog.dart';
import '../widgets/filter_tab_strip.dart';
import '../widgets/tag_selection_dialog.dart';
import '../models/filter.dart';
import 'note_detail_screen.dart';
import 'ai_action_screen.dart';
import 'subnote_edit_screen.dart';
import 'note_action_app_selection_screen.dart';
import 'conversation_chat_screen.dart';
import 'package:file_picker/file_picker.dart';
import '../services/import_service.dart';
import '../services/logger_service.dart';
import 'immersive_note_screen.dart';

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
  // _availableTags removed - using provider directly

  Set<String> _selectedFilterIds = {
    'default',
  }; // 'default', 'pinned', 'archived', 'all', or custom filter IDs

  @override
  void initState() {
    super.initState();
    // _loadTags removed - tags are now derived directly from provider
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // _loadTags method removed

  Future<void> _importFromZip() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result != null && result.files.single.path != null) {
        if (!mounted) return;

        // Show loading indicator
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const Center(child: CircularProgressIndicator()),
        );

        final file = File(result.files.single.path!);
        final stats = await ImportService().importFromMarkdownZip(
          file,
          context.read<AppProvider>(),
        );

        if (!mounted) return;
        Navigator.of(context).pop(); // Dismiss loader

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import Complete: $stats'),
            backgroundColor: Colors.green,
          ),
        );

        // Refresh
        context.read<AppProvider>().loadData();
        context.read<AppProvider>().loadData();
        // _loadTags(); removed
      }
    } catch (e) {
      if (!mounted) return;
      // Close loader if open?
      // Hard to know if dialog is open easily without tracking.
      // But standard interaction ensures we pop if we error after showing.
      // Assuming loader acts as barrier.
      try {
        Navigator.of(context).pop();
      } catch (_) {}

      LoggerService.error('Import Error', error: e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import Failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();
    final notes = _filterNotes(appProvider.notes, appProvider);

    final allSelected =
        notes.isNotEmpty &&
        notes.every((note) => _selectedNotes.contains(note));
    final noneSelected =
        notes.isNotEmpty && !notes.any((note) => _selectedNotes.contains(note));
    final allArchived =
        _selectedNotes.isNotEmpty &&
        _selectedNotes.every((note) => note.isArchived);

    return Scaffold(
      appBar: AppBar(
        title: _isMultiSelectMode
            ? Text('${_selectedNotes.length} ${l10n.selected}')
            : Text(l10n.notes),
        actions: [
          if (_isMultiSelectMode) ...[
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: _selectedNotes.length >= 2 ? _linkSelectedNotes : null,
              tooltip: l10n.linkSelectedNotes,
            ),
            IconButton(
              icon: const Icon(Icons.chrome_reader_mode),
              onPressed: _selectedNotes.isNotEmpty ? _openImmersiveMode : null,
              tooltip: l10n.immersiveMode,
            ),
            IconButton(
              icon: const Icon(Icons.psychology),
              onPressed: _selectedNotes.isNotEmpty ? _openAIAction : null,
              tooltip: l10n.openAIAction,
            ),
            IconButton(
              icon: const Icon(Icons.apps),
              onPressed: _selectedNotes.isNotEmpty ? _openNoteActionApps : null,
              tooltip: 'Run Note Action App',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: MaterialLocalizations.of(context).showMenuTooltip,
              onSelected: (value) {
                switch (value) {
                  case 'selectAll':
                    _selectAll(notes);
                    break;
                  case 'deselectAll':
                    _deselectAll(notes);
                    break;
                  case 'share':
                    if (_selectedNotes.isNotEmpty) {
                      _shareSelectedNotes();
                    }
                    break;
                  case 'tags':
                    if (_selectedNotes.isNotEmpty) {
                      _selectTagsForSelectedNotes();
                    }
                    break;
                  case 'delete':
                    if (_selectedNotes.isNotEmpty) {
                      _deleteSelectedNotes();
                    }
                    break;
                  case 'archive_all':
                    if (_selectedNotes.isNotEmpty) {
                      _toggleArchiveSelected(archive: true);
                    }
                    break;
                  case 'unarchive_all':
                    if (_selectedNotes.isNotEmpty) {
                      _toggleArchiveSelected(archive: false);
                    }
                    break;
                }
              },
              itemBuilder: (context) => [
                if (!allSelected)
                  PopupMenuItem(
                    value: 'selectAll',
                    child: Row(
                      children: [
                        const Icon(Icons.select_all, size: 20),
                        const SizedBox(width: 8),
                        const Text('Select All'),
                      ],
                    ),
                  ),
                if (!noneSelected)
                  PopupMenuItem(
                    value: 'deselectAll',
                    child: Row(
                      children: [
                        const Icon(Icons.deselect, size: 20),
                        const SizedBox(width: 8),
                        const Text('Deselect All'),
                      ],
                    ),
                  ),
                PopupMenuItem(
                  value: 'share',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      const Icon(Icons.share, size: 20),
                      const SizedBox(width: 8),
                      Text(l10n.shareSelectedNotes),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'tags',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      const Icon(Icons.label, size: 20),
                      const SizedBox(width: 8),
                      Text('Select Tags'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete,
                        color: Theme.of(context).colorScheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.deleteSelectedNotes,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: allArchived ? 'unarchive_all' : 'archive_all',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        allArchived ? Icons.unarchive : Icons.archive,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(allArchived ? l10n.unarchiveAll : l10n.archiveAll),
                    ],
                  ),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _exitMultiSelectMode,
              tooltip: l10n.exitMultiSelectMode,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.chat),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const ConversationChatScreen(),
                  ),
                );
              },
              tooltip: 'AI Conversation',
            ),
            MultiSelectTagFilter(
              availableTags: [
                'all',
                ...context.watch<AppProvider>().getAllAvailableTags(),
              ],

              selectedTags: _selectedTags,
              onSelectionChanged: (selectedTags) {
                setState(() {
                  _selectedTags = selectedTags;
                });
              },
              allNotesLabel: l10n.allNotes,
              filterLabel: l10n.filter,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                context.read<AppProvider>().loadData();
                context.read<AppProvider>().loadData();
                // _loadTags(); removed
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'import_zip') {
                  _importFromZip();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'import_zip',
                  child: Row(
                    children: [
                      Icon(Icons.file_upload, size: 20),
                      SizedBox(width: 8),
                      Text('Import Markdown Zip'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
        bottom: _isMultiSelectMode
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(120),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    children: [
                      // Search bar
                      TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: l10n.searchNotes,
                          prefixIcon: const Icon(Icons.search),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        onChanged: (value) {
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: 8),
                      // Filter tab strip
                      FilterTabStrip(
                        selectedFilterIds: _selectedFilterIds,
                        additionalSelectedTags: _selectedTags,
                        customFilters: appProvider.filters,
                        availableTags: [
                          'all',
                          ...appProvider.getAllAvailableTags(),
                        ],
                        onFilterSelected: _onFilterSelected,
                        onFilterCreated: _onFilterCreated,
                        onFilterUpdated: _onFilterUpdated,
                        onFilterDeleted: _onFilterDeleted,
                        onTagsUpdated: (tags) {
                          setState(() {
                            _selectedTags = tags;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          // Load tags when data becomes available or when provider notifies of changes
          // Load tags callback removed

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
                    l10n.errorLoadingNotes(appProvider.error!),
                    style: Theme.of(context).textTheme.titleLarge,
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

          // final notes = _filterNotes(appProvider.notes, appProvider);
          // Already calculated in build method

          if (notes.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.note_add, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    _searchController.text.isNotEmpty ||
                            _selectedTags.isNotEmpty
                        ? l10n.noNotesFound
                        : l10n.createFirstNote,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _searchController.text.isNotEmpty ||
                            _selectedTags.isNotEmpty
                        ? _searchController.text.isNotEmpty
                              ? 'Try adjusting your search terms'
                              : 'Try selecting different tags'
                        : 'Tap the + button to create your first note',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
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
                    onStatusChanged: note.isTask
                        ? (status) => _updateTaskStatus(note.id, status)
                        : null,
                    onAddSubNote: () => _addSubNote(note),
                    onPinToggle: () => _toggleNotePin(note.id),
                    onArchiveToggle: () => _toggleNoteArchive(note.id),
                    onShare: () => _shareNote(note),
                    onContentChanged: (newContent) =>
                        _updateNoteContent(note.id, newContent),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _onFilterSelected(Set<String> filterIds) {
    setState(() {
      _selectedFilterIds = filterIds;
    });
  }

  void _onFilterCreated(Filter filter) {
    context.read<AppProvider>().addFilter(filter);
  }

  void _onFilterUpdated(Filter filter) {
    context.read<AppProvider>().updateFilter(filter);
  }

  void _onFilterDeleted(String filterId) {
    context.read<AppProvider>().deleteFilter(filterId);
    // If the deleted filter was selected, remove it
    if (_selectedFilterIds.contains(filterId)) {
      setState(() {
        _selectedFilterIds.remove(filterId);
        if (_selectedFilterIds.isEmpty) {
          _selectedFilterIds = {'default'};
        }
      });
    }
  }

  List<Note> _filterNotes(List<Note> notes, AppProvider appProvider) {
    List<Note> filteredNotes = notes;

    // Combine notes from all selected filters (Union)
    Set<String> noteIds = {};
    List<Note> unionNotes = [];

    // If 'all' is selected, it overrides everything else
    if (_selectedFilterIds.contains('all')) {
      // No filtering needed for 'all' (except search/tags later)
      // But we need to handle other filters if 'all' is NOT selected.
      // Wait, if 'all' is selected, we start with ALL notes.
      // If we have 'all' AND 'pinned', do we show all? Yes.
      // So if 'all' is present, we can just use 'notes' as base.
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
            // Filter might not exist (deleted?), skip
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

    // Filter by tags (OR logic - show notes that have ANY of the selected tags)
    if (_selectedTags.isNotEmpty) {
      filteredNotes = filteredNotes.where((note) {
        return _selectedTags.any(
          (selectedTag) => note.tags.contains(selectedTag),
        );
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
        MaterialPageRoute(builder: (context) => NoteDetailScreen(note: note)),
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

  void _selectAll(List<Note> currentNotes) {
    setState(() {
      for (final note in currentNotes) {
        if (!_selectedNotes.contains(note)) {
          _selectedNotes.add(note);
        }
      }
    });
  }

  void _deselectAll(List<Note> currentNotes) {
    setState(() {
      for (final note in currentNotes) {
        _selectedNotes.remove(note);
      }
      // If no notes selected at all, exit multi-select mode?
      // User said: "If none are selected, 'Deselect All' will not be visible."
      // This implies we stay in the mode but with 0 selected?
      // But usually 0 selected means exit.
      // Let's check _handleNoteTap logic. It removes note.
      // If list is empty, it doesn't exit mode automatically there.
      // But _exitMultiSelectMode is called by 'X' button.
      // So we can stay in mode with 0 items.
    });
  }

  void _deleteSelectedNotes() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Notes'),
        content: Text(
          'Are you sure you want to delete ${_selectedNotes.length} note(s)?',
        ),
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

  void _openImmersiveMode() {
    if (_selectedNotes.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            ImmersiveNoteScreen(notes: List<Note>.from(_selectedNotes)),
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

  void _openNoteActionApps() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            NoteActionAppSelectionScreen(selectedNotes: _selectedNotes),
      ),
    );
  }

  void _updateTaskStatus(String noteId, TaskStatus status) {
    context.read<AppProvider>().updateTaskStatus(noteId, status);
  }

  void _toggleNotePin(String noteId) {
    context.read<AppProvider>().toggleNotePin(noteId);
  }

  void _toggleNoteArchive(String noteId) {
    final appProvider = context.read<AppProvider>();
    final note = appProvider.notes.firstWhere((n) => n.id == noteId);

    // Check if trying to archive a pinned note
    if (!note.isArchived && note.pinned) {
      final l10n = AppLocalizations.of(context)!;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cannot Archive Pinned Note'),
          content: const Text(
            'Please unpin the note first before archiving it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.yes),
            ),
          ],
        ),
      );
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final action = note.isArchived ? 'unarchive' : 'archive';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          action == 'archive' ? l10n.archiveNote : l10n.unarchiveNote,
        ),
        content: Text(
          action == 'archive'
              ? 'Are you sure you want to archive this note?'
              : 'Are you sure you want to unarchive this note?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final updatedNote = note.copyWith(
                isArchived: !note.isArchived,
                pinned: note.isArchived
                    ? note.pinned
                    : false, // Unpin when archiving
                updatedAt: DateTime.now(),
              );
              appProvider.updateNote(updatedNote);
            },
            child: Text(
              action == 'archive' ? l10n.archiveNote : l10n.unarchiveNote,
            ),
          ),
        ],
      ),
    );
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

  void _updateNoteContent(String noteId, String newContent) async {
    final appProvider = context.read<AppProvider>();
    await appProvider.updateNoteContent(noteId, newContent);
  }

  void _shareNote(Note note) {
    showDialog(
      context: context,
      builder: (context) => ShareDialog(notes: [note], title: note.title),
    );
  }

  void _shareSelectedNotes() {
    showDialog(
      context: context,
      builder: (context) => ShareDialog(
        notes: _selectedNotes,
        title: '${_selectedNotes.length} Notes',
      ),
    );
  }

  void _selectTagsForSelectedNotes() async {
    if (_selectedNotes.isEmpty) return;

    // Calculate common tags
    final commonTags =
        _selectedNotes.fold<Set<String>?>(null, (common, note) {
          if (common == null) {
            return note.tags.toSet();
          }
          return common.intersection(note.tags.toSet());
        }) ??
        {};

    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    // Show tag selection dialog
    final finalTags = await showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        initialSelectedTags: commonTags.toList(),

        title: l10n.selectTagsForNotes(_selectedNotes.length),
      ),
    );

    if (finalTags == null) return;

    // Calculate tags to add and remove
    final tagsToAdd = finalTags
        .where((tag) => !commonTags.contains(tag))
        .toList();
    final tagsToRemove = commonTags
        .where((tag) => !finalTags.contains(tag))
        .toList();

    if (tagsToAdd.isEmpty && tagsToRemove.isEmpty) return;

    // Apply changes
    await appProvider.batchUpdateTags(
      _selectedNotes.map((n) => n.id).toList(),
      tagsToAdd,
      tagsToRemove,
    );

    _exitMultiSelectMode();
  }

  void _toggleArchiveSelected({required bool archive}) {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    // Check for pinned notes if archiving
    if (archive) {
      final pinnedNotes = _selectedNotes.where((n) => n.pinned).toList();
      if (pinnedNotes.isNotEmpty) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Cannot Archive Pinned Notes'),
            content: Text(
              'There are ${pinnedNotes.length} pinned notes selected. Please unpin them first before archiving.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.yes),
              ),
            ],
          ),
        );
        return;
      }
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(archive ? l10n.archiveAll : l10n.unarchiveAll),
        content: Text(
          archive
              ? 'Are you sure you want to archive ${_selectedNotes.length} notes?'
              : 'Are you sure you want to unarchive ${_selectedNotes.length} notes?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              for (final note in _selectedNotes) {
                // If archiving: set isArchived=true, pinned=false (done by check above but safe to enforce)
                // If unarchiving: set isArchived=false.
                final updatedNote = note.copyWith(
                  isArchived: archive,
                  pinned: archive ? false : note.pinned,
                  updatedAt: DateTime.now(),
                );
                appProvider.updateNote(updatedNote);
              }
              _exitMultiSelectMode();
            },
            child: Text(archive ? l10n.archiveAll : l10n.unarchiveAll),
          ),
        ],
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
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.linkNotesDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.linkNoteTo(widget.fromNote.title),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...widget.toNotes.map(
              (note) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '• ${note.title}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.relationshipType,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _selectedRelationshipType,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: [
                ...RelationshipType.predefined.map(
                  (type) => DropdownMenuItem(
                    value: type,
                    child: Row(
                      children: [
                        Icon(RelationshipType.getIcon(type), size: 20),
                        const SizedBox(width: 8),
                        Text(RelationshipType.getDisplayName(type)),
                      ],
                    ),
                  ),
                ),
                DropdownMenuItem(
                  value: 'custom',
                  child: Row(
                    children: [
                      Icon(Icons.edit, size: 20),
                      const SizedBox(width: 8),
                      Text(l10n.customEllipsis),
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
                decoration: InputDecoration(
                  labelText: l10n.customRelationshipType,
                  border: const OutlineInputBorder(),
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
          child: Text(l10n.cancel),
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
          child: Text(l10n.link),
        ),
      ],
    );
  }
}
