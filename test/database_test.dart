import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';

void main() {
  group('Database Service Tests', () {
    late DatabaseService databaseService;

    setUpAll(() {
      // Initialize FFI for testing
      sqfliteFfiInit();
      // Use in-memory database for speed (no isolate for testing)
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      // Create a new database service instance for each test
      databaseService = DatabaseService.createNew();
      // Wait for database initialization
      await databaseService.database;
    });

    tearDown(() async {
      // Close database after each test
      await databaseService.close();
    });

    test('should create database tables successfully', () async {
      final db = await databaseService.database;
      
      // Check if tables exist
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
      );
      
      expect(tables.length, 9); // notes, subnotes, tags, note_tags, attachments, relationships, filters, user_apps, app_revisions
      expect(tables.any((table) => table['name'] == 'notes'), isTrue);
      expect(tables.any((table) => table['name'] == 'subnotes'), isTrue);
      expect(tables.any((table) => table['name'] == 'tags'), isTrue);
      expect(tables.any((table) => table['name'] == 'note_tags'), isTrue);
      expect(tables.any((table) => table['name'] == 'attachments'), isTrue);
      expect(tables.any((table) => table['name'] == 'relationships'), isTrue);
    });

    test('should insert and retrieve note', () async {
      final note = Note(
        id: 'test-note-1',
        title: 'Test Note',
        content: 'This is a test note',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['test', 'sample'],
        subNotes: [
          SubNote(
            id: 'sub-1',
            name: 'Sub-note 1',
            content: 'Sub-note content',
            createdAt: DateTime.now(),
          ),
        ],
      );

      // Insert note
      final insertedId = await databaseService.insertNote(note);
      expect(insertedId, 'test-note-1');

      // Retrieve note
      final retrievedNote = await databaseService.getNote('test-note-1');
      expect(retrievedNote, isNotNull);
      expect(retrievedNote!.title, 'Test Note');
      expect(retrievedNote.content, 'This is a test note');
      expect(retrievedNote.type, NoteType.note);
      expect(retrievedNote.tags, contains('test'));
      expect(retrievedNote.tags, contains('sample'));
      expect(retrievedNote.subNotes.length, 1);
      expect(retrievedNote.subNotes.first.name, 'Sub-note 1');
    });

    test('should insert and retrieve task', () async {
      final task = Note(
        id: 'test-task-1',
        title: 'Test Task',
        content: 'This is a test task',
        type: NoteType.task,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        scheduledAt: '2024-12-31',
        completeBy: '2024-12-31',
        status: TaskStatus.todo,
        completionPercentage: 0.0,
        tags: ['work', 'urgent'],
      );

      // Insert task
      await databaseService.insertNote(task);

      // Retrieve task
      final retrievedTask = await databaseService.getNote('test-task-1');
      expect(retrievedTask, isNotNull);
      expect(retrievedTask!.type, NoteType.task);
      expect(retrievedTask.scheduledAt, '2024-12-31');
      expect(retrievedTask.completeBy, '2024-12-31');
      expect(retrievedTask.status, TaskStatus.todo);
      expect(retrievedTask.completionPercentage, 0.0);
    });

    test('should update note', () async {
      final note = Note(
        id: 'test-note-2',
        title: 'Original Title',
        content: 'Original content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Insert note
      await databaseService.insertNote(note);

      // Update note
      final updatedNote = note.copyWith(
        title: 'Updated Title',
        content: 'Updated content',
        updatedAt: DateTime.now(),
      );
      await databaseService.updateNote(updatedNote);

      // Retrieve and verify update
      final retrievedNote = await databaseService.getNote('test-note-2');
      expect(retrievedNote!.title, 'Updated Title');
      expect(retrievedNote.content, 'Updated content');
    });

    test('should insert and retrieve relationship', () async {
      final relationship = Relationship(
        id: 'rel-1',
        fromNoteId: 'note-1',
        toNoteId: 'note-2',
        type: 'related',
        createdAt: DateTime.now(),
      );

      // Insert relationship
      final insertedId = await databaseService.insertRelationship(relationship);
      expect(insertedId, 'rel-1');

      // Retrieve relationships
      final relationships = await databaseService.getRelationships('note-1');
      expect(relationships.length, 1);
      expect(relationships.first.type, 'related');
      expect(relationships.first.toNoteId, 'note-2');
    });


    test('should handle multiple notes correctly', () async {
      final notes = [
        Note(
          id: 'note-1',
          title: 'First Note',
          content: 'First content',
          type: NoteType.note,
          createdAt: DateTime.now().subtract(const Duration(hours: 2)),
          updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
          tags: ['tag1'],
        ),
        Note(
          id: 'note-2',
          title: 'Second Note',
          content: 'Second content',
          type: NoteType.task,
          createdAt: DateTime.now().subtract(const Duration(hours: 1)),
          updatedAt: DateTime.now().subtract(const Duration(hours: 1)),
          scheduledAt: '2024-12-31',
        completeBy: '2024-12-31',
          status: TaskStatus.todo,
          tags: ['tag2'],
        ),
        Note(
          id: 'note-3',
          title: 'Third Note',
          content: 'Third content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          tags: ['tag1', 'tag2'],
        ),
      ];

      for (final note in notes) {
        await databaseService.insertNote(note);
      }

      // Retrieve all notes (should be ordered by createdAt DESC)
      final retrievedNotes = await databaseService.getAllNotes();
      expect(retrievedNotes.length, 3);
      expect(retrievedNotes[0].id, 'note-3'); // Most recent first
      expect(retrievedNotes[1].id, 'note-2');
      expect(retrievedNotes[2].id, 'note-1');
    });

    test('should handle empty database', () async {
      final notes = await databaseService.getAllNotes();
      final tags = await databaseService.getAllTags();
      expect(notes.length, 0);
      expect(tags.length, 0);
    });

    test('should delete note and cascade to related data', () async {
      final note = Note(
        id: 'note-to-delete',
        title: 'Note to Delete',
        content: 'This note will be deleted',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['test'],
        subNotes: [
          SubNote(
            id: 'sub-to-delete',
            name: 'Sub-note',
            content: 'Sub-content',
            createdAt: DateTime.now(),
          ),
        ],
      );

      // Insert note
      await databaseService.insertNote(note);

      // Verify note exists
      final retrievedNote = await databaseService.getNote('note-to-delete');
      expect(retrievedNote, isNotNull);

      // Delete note
      await databaseService.deleteNote('note-to-delete');

      // Verify note is deleted
      final deletedNote = await databaseService.getNote('note-to-delete');
      expect(deletedNote, isNull);
    });
  });
}
