import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/note_selection_service.dart';
import 'package:note_synapse/models/note.dart';

void main() {
  group('NoteSelectionService', () {
    late NoteSelectionService service;

    setUp(() {
      service = NoteSelectionService();
    });

    group('filterNotes', () {
      test('should return all notes when search query is empty', () {
        final now = DateTime.now();
        final notes = [
          Note(
            id: '1',
            title: 'Test Note 1',
            content: 'Content 1',
            type: NoteType.note,
            createdAt: now.subtract(const Duration(hours: 1)),
            updatedAt: now,
          ),
          Note(
            id: '2',
            title: 'Test Note 2',
            content: 'Content 2',
            type: NoteType.note,
            createdAt: now,
            updatedAt: now,
          ),
        ];

        final result = service.filterNotes(allNotes: notes, searchQuery: '');

        expect(result.length, equals(2));
        // Expect newest first (Note 2 then Note 1)
        expect(result[0].id, equals('2'));
        expect(result[1].id, equals('1'));
      });

      test('should filter notes by title', () {
        final notes = [
          Note(
            id: '1',
            title: 'Test Note 1',
            content: 'Content 1',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          Note(
            id: '2',
            title: 'Another Note',
            content: 'Content 2',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ];

        final result = service.filterNotes(
          allNotes: notes,
          searchQuery: 'Test',
        );

        expect(result.length, equals(1));
        expect(result[0].id, equals('1'));
      });

      test('should filter notes by content', () {
        final notes = [
          Note(
            id: '1',
            title: 'Note 1',
            content: 'This is a test content',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          Note(
            id: '2',
            title: 'Note 2',
            content: 'Different content',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ];

        final result = service.filterNotes(
          allNotes: notes,
          searchQuery: 'test',
        );

        expect(result.length, equals(1));
        expect(result[0].id, equals('1'));
      });

      test('should filter notes by tags', () {
        final notes = [
          Note(
            id: '1',
            title: 'Note 1',
            content: 'Content 1',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            tags: ['work', 'important'],
          ),
          Note(
            id: '2',
            title: 'Note 2',
            content: 'Content 2',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            tags: ['personal'],
          ),
        ];

        final result = service.filterNotes(
          allNotes: notes,
          searchQuery: 'work',
        );

        expect(result.length, equals(1));
        expect(result[0].id, equals('1'));
      });

      test('should be case-insensitive', () {
        final notes = [
          Note(
            id: '1',
            title: 'Test Note',
            content: 'Content',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ];

        final result = service.filterNotes(
          allNotes: notes,
          searchQuery: 'TEST',
        );

        expect(result.length, equals(1));
      });
    });

    group('toggleSingleSelection', () {
      test('should select note when none selected', () {
        final note = Note(
          id: '1',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.toggleSingleSelection(
          selectedNotes: [],
          note: note,
        );

        expect(result.length, equals(1));
        expect(result[0].id, equals('1'));
      });

      test('should deselect note when already selected', () {
        final note = Note(
          id: '1',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.toggleSingleSelection(
          selectedNotes: [note],
          note: note,
        );

        expect(result.isEmpty, isTrue);
      });

      test('should replace selection when different note is selected', () {
        final note1 = Note(
          id: '1',
          title: 'Note 1',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final note2 = Note(
          id: '2',
          title: 'Note 2',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.toggleSingleSelection(
          selectedNotes: [note1],
          note: note2,
        );

        expect(result.length, equals(1));
        expect(result[0].id, equals('2'));
      });
    });

    group('toggleMultiSelection', () {
      test('should add note when not selected', () {
        final note = Note(
          id: '1',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.toggleMultiSelection(
          selectedNotes: [],
          note: note,
        );

        expect(result.length, equals(1));
        expect(result[0].id, equals('1'));
      });

      test('should remove note when already selected', () {
        final note = Note(
          id: '1',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.toggleMultiSelection(
          selectedNotes: [note],
          note: note,
        );

        expect(result.isEmpty, isTrue);
      });

      test('should add multiple notes', () {
        final note1 = Note(
          id: '1',
          title: 'Note 1',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final note2 = Note(
          id: '2',
          title: 'Note 2',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.toggleMultiSelection(
          selectedNotes: [note1],
          note: note2,
        );

        expect(result.length, equals(2));
        expect(result.map((n) => n.id).toList(), containsAll(['1', '2']));
      });
    });

    group('isNoteSelected', () {
      test('should return true when note is selected', () {
        final note = Note(
          id: '1',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.isNoteSelected(
          selectedNotes: [note],
          note: note,
        );

        expect(result, isTrue);
      });

      test('should return false when note is not selected', () {
        final note1 = Note(
          id: '1',
          title: 'Note 1',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final note2 = Note(
          id: '2',
          title: 'Note 2',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.isNoteSelected(
          selectedNotes: [note1],
          note: note2,
        );

        expect(result, isFalse);
      });

      test('should match by ID even if objects are different', () {
        final note1 = Note(
          id: '1',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        // Create a different instance with the same ID
        final note2 = Note(
          id: '1',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final result = service.isNoteSelected(
          selectedNotes: [note1],
          note: note2,
        );

        expect(result, isTrue);
      });
    });
  });
}
