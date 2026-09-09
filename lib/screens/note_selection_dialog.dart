import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/note_card.dart';
import '../widgets/tag_selection_dialog.dart';
import '../l10n/app_localizations.dart';
import '../services/note_selection_service.dart';

class NoteSelectionDialog extends StatefulWidget {
  final Function(List<Note>) onNotesSelected;
  final String? title;
  final bool singleSelection;
  final List<String> initialSelectedNoteIds;
  final List<String>? initialTags;

  /// Restricts the picker to exactly these notes instead of every note the
  /// provider holds. *Add existing notes…* passes the complement of the active
  /// Space, so the list cannot offer a note that is already in it.
  final List<Note>? candidateNotes;

  /// Notes listed ahead of the rest, whatever the default sort would do.
  /// *Add existing notes…* puts the unfiled notes here: they are what a user
  /// is normally filing, and the default newest-first order buries them.
  final Set<String> priorityNoteIds;

  /// The Space scope this dialog starts in.
  ///
  /// With no [candidateNotes] the picker lists `scopedNotes` — which is what
  /// scopes AI context picking, merge and the plugin `pickNotes` in one place
  /// — and offers *Include notes outside «Space»* to widen it back to every
  /// note. Pass false to start widened.
  ///
  /// Ignored when [candidateNotes] is given: an explicit candidate list is the
  /// caller's own answer to "which notes may be picked" (*Add existing notes…*
  /// passes the **complement** of the scope, which a scoped default would
  /// reduce to nothing), so the switch is not shown at all.
  final bool scopeToSpace;

  const NoteSelectionDialog({
    super.key,
    required this.onNotesSelected,
    this.title,
    this.singleSelection = false,
    this.initialSelectedNoteIds = const [],
    this.initialTags,
    this.candidateNotes,
    this.priorityNoteIds = const {},
    this.scopeToSpace = true,
  });

  @override
  State<NoteSelectionDialog> createState() => _NoteSelectionDialogState();
}

class _NoteSelectionDialogState extends State<NoteSelectionDialog> {
  final List<Note> _selectedNotes = [];
  final _searchController = TextEditingController();
  String _searchQuery = '';
  final NoteSelectionService _noteSelectionService = NoteSelectionService();
  bool _initialized = false;
  List<String> _activeTagFilters = [];

  /// False once the user has asked for notes from outside the active Space.
  /// Only ever consulted when the caller gave no explicit [candidateNotes].
  bool _scoped = true;

  @override
  void initState() {
    super.initState();
    _activeTagFilters = List.from(widget.initialTags ?? []);
    _scoped = widget.scopeToSpace;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized && widget.initialSelectedNoteIds.isNotEmpty) {
      _initialized = true;
      // Pre-select notes based on IDs
      final allNotes = context.read<AppProvider>().notes;
      for (final noteId in widget.initialSelectedNoteIds) {
        final note = allNotes.where((n) => n.id == noteId).firstOrNull;
        if (note != null) {
          _selectedNotes.add(note);
        }
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dialogTitle = widget.title ?? l10n.selectNotesForNoteActionApp;

    return Dialog(
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.note_add,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dialogTitle,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Stack(
                      children: [
                        Icon(
                          Icons.filter_list,
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                        if (_activeTagFilters.isNotEmpty)
                          Positioned(
                            right: 0,
                            top: 0,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.tertiary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                    onPressed: _showTagFilterDialog,
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ),

            // Search bar
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: l10n.searchNotes,
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value.toLowerCase();
                  });
                },
              ),
            ),

            // Space escape. Shown only where the scope is actually in force:
            // a Space is active and no explicit candidate list overrode it.
            if (widget.candidateNotes == null)
              Builder(
                builder: (context) {
                  final space = context.watch<AppProvider>().activeSpace;
                  if (space == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SwitchListTile(
                      key: const ValueKey('include-outside-space'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        l10n.includeNotesOutsideSpace(space.name),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      value: !_scoped,
                      onChanged: (value) => setState(() => _scoped = !value),
                    ),
                  );
                },
              ),

            // Selected notes count
            if (_selectedNotes.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.notesSelected(_selectedNotes.length),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

            // Notes list
            Expanded(
              child: Consumer<AppProvider>(
                builder: (context, appProvider, child) {
                  // An explicit candidate list always wins: the caller has
                  // already decided which notes may be picked.
                  final allNotes =
                      widget.candidateNotes ??
                      (_scoped ? appProvider.scopedNotes : appProvider.notes);

                  // Use the service to filter and sort notes
                  var filteredNotes = _noteSelectionService.filterNotes(
                    allNotes: allNotes,
                    searchQuery: _searchQuery,
                  );

                  // Apply tag filters if active
                  if (_activeTagFilters.isNotEmpty) {
                    filteredNotes = filteredNotes.where((note) {
                      return _activeTagFilters.every(
                        (tag) => note.tags.contains(tag),
                      );
                    }).toList();
                  }

                  // Stable partition, applied last so it survives the
                  // service's pinned-then-newest sort.
                  if (widget.priorityNoteIds.isNotEmpty) {
                    filteredNotes = [
                      ...filteredNotes.where(
                        (n) => widget.priorityNoteIds.contains(n.id),
                      ),
                      ...filteredNotes.where(
                        (n) => !widget.priorityNoteIds.contains(n.id),
                      ),
                    ];
                  }

                  if (filteredNotes.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.note_outlined,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _searchQuery.isEmpty
                                ? l10n.noNotesAvailable
                                : l10n.noNotesFoundMatching(_searchQuery),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredNotes.length,
                    itemBuilder: (context, index) {
                      final note = filteredNotes[index];
                      // Use note ID comparison instead of object equality
                      // to ensure newly created notes are properly detected
                      final isSelected = _noteSelectionService.isNoteSelected(
                        selectedNotes: _selectedNotes,
                        note: note,
                      );

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GestureDetector(
                          onTap: () => _toggleNoteSelection(note),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey[300]!,
                                width: isSelected ? 2 : 1,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              color: isSelected
                                  ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                        .withOpacity(0.3)
                                  : null,
                            ),
                            child: NoteCard(
                              note: note,
                              isSelected: isSelected,
                              onTap: () => _toggleNoteSelection(note),
                              onLongPress: () => _toggleNoteSelection(note),
                              onStatusChanged: note.isTask
                                  ? (status) =>
                                        _updateTaskStatus(note.id, status)
                                  : null,
                              onAddSubNote: () {}, // Disabled in selection mode
                              onPinToggle: () {}, // Disabled in selection mode
                              onArchiveToggle:
                                  () {}, // Disabled in selection mode
                              // Do not pass onShare to hide share icon
                              showAttachmentIndicator: false,
                              onContentChanged: (newContent) =>
                                  _updateNoteContent(note.id, newContent),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // Action buttons
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey[300]!)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                  ElevatedButton(
                    onPressed: _selectedNotes.isNotEmpty
                        ? _proceedWithSelectedNotes
                        : null,
                    child: Text(
                      widget.singleSelection
                          ? l10n.proceed
                          : l10n.proceedWithNotes(_selectedNotes.length),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleNoteSelection(Note note) {
    setState(() {
      if (widget.singleSelection) {
        final newSelection = _noteSelectionService.toggleSingleSelection(
          selectedNotes: _selectedNotes,
          note: note,
        );
        _selectedNotes.clear();
        _selectedNotes.addAll(newSelection);
      } else {
        final newSelection = _noteSelectionService.toggleMultiSelection(
          selectedNotes: _selectedNotes,
          note: note,
        );
        _selectedNotes.clear();
        _selectedNotes.addAll(newSelection);
      }
    });
  }

  void _proceedWithSelectedNotes() {
    widget.onNotesSelected(_selectedNotes);
  }

  void _updateTaskStatus(String noteId, TaskStatus status) {
    context.read<AppProvider>().updateTaskStatus(noteId, status);
  }

  void _updateNoteContent(String noteId, String newContent) {
    context.read<AppProvider>().updateNoteContent(noteId, newContent);
  }

  void _applyFilters() {
    setState(() {
      // Trigger rebuild with updated _activeTagFilters
    });
  }

  Future<void> _showTagFilterDialog() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => TagSelectionDialog(
        title: l10n.filter,
        initialSelectedTags: _activeTagFilters,
        allowCreateNew: false,
        allowEmptySelection: true,
        showManageTagsButton: true,
        returnAsSet: true,
      ),
    );
    if (selected != null) {
      setState(() {
        _activeTagFilters = selected.toList();
      });
      _applyFilters();
    }
  }
}
