import '../models/note.dart';
import '../utils/note_text_match.dart';

/// Service for handling note selection and filtering logic.
/// This service is extracted to make the logic testable.
class NoteSelectionService {
  /// Filters and sorts notes based on a search query.
  ///
  /// The search matches against title, content, and tags via the shared
  /// [matchesSubstringQuery] predicate (case-insensitive, NFKC-folded — so
  /// full-width characters compare equal, matching the search index).
  /// The API stays synchronous substring filtering: the note pickers this
  /// serves don't need ranked SearchService results (plan §1.6 keeps full
  /// SearchService integration to the notes screen).
  ///
  /// Returns a list of notes that match the search query, sorted by:
  /// - Pinned notes first
  /// - Then by creation date (newest first)
  ///
  /// If the search query is empty, returns all notes sorted.
  List<Note> filterNotes({
    required List<Note> allNotes,
    required String searchQuery,
  }) {
    List<Note> filteredNotes;

    if (searchQuery.isEmpty) {
      filteredNotes = List.from(allNotes);
    } else {
      filteredNotes = allNotes
          .where((note) => matchesSubstringQuery(note, searchQuery))
          .toList();
    }

    // Sort by pinned status first, then by creation date (newest first)
    filteredNotes.sort((a, b) {
      if (a.pinned && !b.pinned) return -1;
      if (!a.pinned && b.pinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });

    return filteredNotes;
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
  bool isNoteSelected({required List<Note> selectedNotes, required Note note}) {
    return selectedNotes.any((n) => n.id == note.id);
  }
}
