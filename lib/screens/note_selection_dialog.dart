import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/note_card.dart';
import '../l10n/app_localizations.dart';
import '../services/note_selection_service.dart';

class NoteSelectionDialog extends StatefulWidget {
  final Function(List<Note>) onNotesSelected;
  final String? title;
  final bool singleSelection;

  const NoteSelectionDialog({
    super.key,
    required this.onNotesSelected,
    this.title,
    this.singleSelection = false,
  });

  @override
  State<NoteSelectionDialog> createState() => _NoteSelectionDialogState();
}

class _NoteSelectionDialogState extends State<NoteSelectionDialog> {
  final List<Note> _selectedNotes = [];
  final _searchController = TextEditingController();
  String _searchQuery = '';
  final NoteSelectionService _noteSelectionService = NoteSelectionService();

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
            
            // Selected notes count
            if (_selectedNotes.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                  // Get all notes from AppProvider - this will automatically update
                  // when AppProvider.notifyListeners() is called (e.g., when notes
                  // are added via Synapse API)
                  final allNotes = appProvider.notes;
                  
                  // Use the service to filter notes
                  final filteredNotes = _noteSelectionService.filterNotes(
                    allNotes: allNotes,
                    searchQuery: _searchQuery,
                  );
                  
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
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
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
                                  ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                                  : null,
                            ),
                            child: NoteCard(
                              note: note,
                              isSelected: isSelected,
                              onTap: () => _toggleNoteSelection(note),
                              onLongPress: () => _toggleNoteSelection(note),
                              onStatusChanged: note.isTask ? (status) => _updateTaskStatus(note.id, status) : null,
                              onAddSubNote: () {}, // Disabled in selection mode
                              onPinToggle: () {}, // Disabled in selection mode
                              onArchiveToggle: () {}, // Disabled in selection mode
                              // Do not pass onShare to hide share icon
                              showAttachmentIndicator: false,
                              onContentChanged: (newContent) => _updateNoteContent(note.id, newContent),
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
                border: Border(
                  top: BorderSide(color: Colors.grey[300]!),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                  ElevatedButton(
                    onPressed: _selectedNotes.isNotEmpty ? _proceedWithSelectedNotes : null,
                    child: Text(widget.singleSelection 
                        ? l10n.proceed
                        : l10n.proceedWithNotes(_selectedNotes.length)),
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
}
