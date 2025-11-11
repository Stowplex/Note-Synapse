import '../models/note.dart';

/// Service for handling note selection and filtering logic.
/// This service is extracted to make the logic testable.
class NoteSelectionService {
  /// Filters notes based on a search query.
  /// 
  /// The search matches against:
  /// - Note title (case-insensitive)
  /// - Note content (case-insensitive)
  /// - Note tags (case-insensitive)
  /// 
  /// Returns a list of notes that match the search query.
  /// If the search query is empty, returns all notes.
  List<Note> filterNotes({
    required List<Note> allNotes,
    required String searchQuery,
  }) {
    if (searchQuery.isEmpty) {
      return allNotes;
    }

    final query = searchQuery.toLowerCase();
    return allNotes.where((note) {
      return note.title.toLowerCase().contains(query) ||
          note.content.toLowerCase().contains(query) ||
          note.tags.any((tag) => tag.toLowerCase().contains(query));
    }).toList();
  }

  /// Toggles note selection in single selection mode.
  /// 
  /// If the note is already selected, it will be deselected.
  /// If another note is selected, it will be replaced with the new note.
  List<Note> toggleSingleSelection({
    required List<Note> selectedNotes,
    required Note note,
  }) {
    if (selectedNotes.contains(note)) {
      return selectedNotes.where((n) => n != note).toList();
    } else {
      return [note];
    }
  }

  /// Toggles note selection in multi-selection mode.
  /// 
  /// If the note is already selected, it will be deselected.
  /// Otherwise, it will be added to the selection.
  List<Note> toggleMultiSelection({
    required List<Note> selectedNotes,
    required Note note,
  }) {
    if (selectedNotes.contains(note)) {
      return selectedNotes.where((n) => n != note).toList();
    } else {
      return [...selectedNotes, note];
    }
  }

  /// Checks if a note is selected.
  bool isNoteSelected({
    required List<Note> selectedNotes,
    required Note note,
  }) {
    return selectedNotes.any((n) => n.id == note.id);
  }
}

