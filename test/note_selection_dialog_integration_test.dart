import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/note_selection_service.dart';
import 'package:note_synapse/models/note.dart';

/// Integration test to verify that notes created via Synapse API
/// (which calls AppProvider.addNote) are immediately available
/// in the NoteSelectionDialog.
///
/// This test simulates the scenario:
/// 1. Notes are created via Synapse.saveNotes API
/// 2. AppProvider.addNote is called (which happens in _saveNotesFromJavaScript)
/// 3. AppProvider.notifyListeners() is called
/// 4. NoteSelectionDialog should show the newly created notes
void main() {
  group('NoteSelectionDialog Integration - Synapse API', () {
    late AppProvider appProvider;
    late NoteSelectionService noteSelectionService;

    setUpAll(() {
      // Initialize FFI for testing
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      appProvider = AppProvider();
      noteSelectionService = NoteSelectionService();
      // Load initial data
      await appProvider.loadData();
    });

    tearDown(() async {
      // Clean up: close database connections
      // Note: AppProvider doesn't expose a close method, but DatabaseService
      // should handle cleanup automatically
    });

    test(
        'should show newly created notes immediately after creation via Synapse API',
        () async {
      // Simulate initial state: dialog is open with existing notes
      final initialNotes = appProvider.notes;
      final initialCount = initialNotes.length;

      // Simulate creating a note via Synapse API
      // This is what happens when Synapse.saveNotes is called:
      // 1. _saveNotesFromJavaScript creates a Note object
      // 2. appProvider.addNote(note) is called
      // 3. AppProvider.notifyListeners() is called
      final newNote = Note(
        id: 'test-note-${DateTime.now().millisecondsSinceEpoch}',
        title: 'New Note from Synapse API',
        content: 'This note was created via Synapse.saveNotes',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // This simulates what happens in _saveNotesFromJavaScript
      await appProvider.addNote(newNote);

      // Verify that the note is now in AppProvider.notes
      // (This is what NoteSelectionDialog reads via Consumer<AppProvider>)
      final updatedNotes = appProvider.notes;
      expect(updatedNotes.length, equals(initialCount + 1));

      // Verify the new note is in the list
      final foundNote = updatedNotes.firstWhere(
        (note) => note.id == newNote.id,
        orElse: () => throw Exception('New note not found'),
      );
      expect(foundNote.title, equals('New Note from Synapse API'));

      // Simulate what NoteSelectionDialog does: filter notes
      final filteredNotes = noteSelectionService.filterNotes(
        allNotes: updatedNotes,
        searchQuery: '',
      );

      // The new note should be in the filtered list
      expect(
        filteredNotes.any((note) => note.id == newNote.id),
        isTrue,
        reason: 'Newly created note should appear in filtered notes',
      );

      // Test search functionality with the new note
      final searchResults = noteSelectionService.filterNotes(
        allNotes: updatedNotes,
        searchQuery: 'Synapse',
      );
      expect(
        searchResults.any((note) => note.id == newNote.id),
        isTrue,
        reason: 'Newly created note should be searchable',
      );
    });

    test(
        'should show multiple newly created notes immediately after batch creation',
        () async {
      // Simulate creating multiple notes via Synapse API
      // (Synapse.saveNotes accepts an array of notes)
      final newNotes = [
        Note(
          id: 'test-note-1-${DateTime.now().millisecondsSinceEpoch}',
          title: 'First New Note',
          content: 'Content 1',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        Note(
          id: 'test-note-2-${DateTime.now().millisecondsSinceEpoch}',
          title: 'Second New Note',
          content: 'Content 2',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        Note(
          id: 'test-note-3-${DateTime.now().millisecondsSinceEpoch}',
          title: 'Third New Note',
          content: 'Content 3',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      // Simulate batch creation (what happens in _saveNotesFromJavaScript loop)
      final initialCount = appProvider.notes.length;
      for (final note in newNotes) {
        await appProvider.addNote(note);
      }

      // Verify all notes are in AppProvider.notes
      final updatedNotes = appProvider.notes;
      expect(updatedNotes.length, equals(initialCount + newNotes.length));

      // Verify all new notes are in the list
      for (final newNote in newNotes) {
        expect(
          updatedNotes.any((note) => note.id == newNote.id),
          isTrue,
          reason: 'Note ${newNote.id} should be in the list',
        );
      }

      // Simulate what NoteSelectionDialog does: filter notes
      final filteredNotes = noteSelectionService.filterNotes(
        allNotes: updatedNotes,
        searchQuery: '',
      );

      // All new notes should be in the filtered list
      for (final newNote in newNotes) {
        expect(
          filteredNotes.any((note) => note.id == newNote.id),
          isTrue,
          reason: 'Note ${newNote.id} should appear in filtered notes',
        );
      }
    });

    test(
        'should allow selection of newly created notes immediately',
        () async {
      // Create a new note via Synapse API
      final newNote = Note(
        id: 'test-note-${DateTime.now().millisecondsSinceEpoch}',
        title: 'Selectable Note',
        content: 'This note should be selectable',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await appProvider.addNote(newNote);

      // Get the updated notes (what NoteSelectionDialog would see)
      final allNotes = appProvider.notes;
      final noteFromProvider = allNotes.firstWhere(
        (note) => note.id == newNote.id,
      );

      // Simulate selecting the note in single selection mode
      final selectedNotes = noteSelectionService.toggleSingleSelection(
        selectedNotes: [],
        note: noteFromProvider,
      );

      expect(selectedNotes.length, equals(1));
      expect(selectedNotes[0].id, equals(newNote.id));

      // Verify the note can be identified as selected
      final isSelected = noteSelectionService.isNoteSelected(
        selectedNotes: selectedNotes,
        note: noteFromProvider,
      );
      expect(isSelected, isTrue);
    });

    test(
        'should handle note selection with ID comparison (not object equality)',
        () async {
      // This test verifies that note selection works even when
      // the note object in AppProvider is a different instance
      // than the one used for selection (which can happen when
      // notes are reloaded from database)

      final newNote = Note(
        id: 'test-note-${DateTime.now().millisecondsSinceEpoch}',
        title: 'Test Note',
        content: 'Content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await appProvider.addNote(newNote);

      // Get the note from AppProvider (this might be a different instance
      // than the one we created, especially if it was reloaded from DB)
      final allNotes = appProvider.notes;
      final noteFromProvider = allNotes.firstWhere(
        (note) => note.id == newNote.id,
      );

      // Even though noteFromProvider might be a different object instance,
      // selection should work because we compare by ID
      final isSelected = noteSelectionService.isNoteSelected(
        selectedNotes: [noteFromProvider],
        note: newNote, // Different instance, same ID
      );

      expect(isSelected, isTrue,
          reason:
              'Note selection should work with ID comparison, not object equality');
    });
  });
}

