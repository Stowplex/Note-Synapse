import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/models/ai_interaction.dart';
import 'package:note_synapse/models/tag.dart';

void main() {
  group('Model Tests', () {
    test('should create note with all properties', () {
      final note = Note(
        id: 'note-1',
        title: 'Test Note',
        content: 'Test content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['test', 'sample'],
        subNotes: [
          SubNote(
            id: 'sub-1',
            name: 'Sub-note',
            content: 'Sub-content',
            createdAt: DateTime.now(),
          ),
        ],
      );

      expect(note.id, 'note-1');
      expect(note.title, 'Test Note');
      expect(note.content, 'Test content');
      expect(note.type, NoteType.note);
      expect(note.tags, contains('test'));
      expect(note.subNotes.length, 1);
      expect(note.subNotes.first.name, 'Sub-note');
    });

    test('should create task with status and due date', () {
      final task = Note(
        id: 'task-1',
        title: 'Test Task',
        content: 'Task content',
        type: NoteType.task,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        scheduledAt: '2024-12-31',
        completeBy: '2024-12-31',
        status: TaskStatus.todo,
        completionPercentage: 0.0,
      );

      expect(task.isTask, isTrue);
      expect(task.scheduledAt, '2024-12-31');
      expect(task.completeBy, '2024-12-31');
      expect(task.status, TaskStatus.todo);
      expect(task.completionPercentage, 0.0);
    });

    test('should create relationship', () {
      final relationship = Relationship(
        id: 'rel-1',
        fromNoteId: 'note-1',
        toNoteId: 'note-2',
        type: 'related',
        createdAt: DateTime.now(),
      );

      expect(relationship.id, 'rel-1');
      expect(relationship.fromNoteId, 'note-1');
      expect(relationship.toNoteId, 'note-2');
      expect(relationship.type, 'related');
    });

    test('should create AI interaction', () {
      final interaction = AIInteraction(
        id: 'ai-1',
        type: AIInteractionType.noteQa,
        prompt: 'Test prompt',
        response: 'Test response',
        contextNoteIds: ['note-1', 'note-2'],
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      );

      expect(interaction.id, 'ai-1');
      expect(interaction.type, AIInteractionType.noteQa);
      expect(interaction.prompt, 'Test prompt');
      expect(interaction.response, 'Test response');
      expect(interaction.contextNoteIds, contains('note-1'));
    });

    test('should create tag', () {
      final tag = Tag(
        id: 'tag-1',
        name: 'Test Tag',
        color: '#FF0000',
        createdAt: DateTime.now(),
        usageCount: 5,
      );

      expect(tag.id, 'tag-1');
      expect(tag.name, 'Test Tag');
      expect(tag.color, '#FF0000');
      expect(tag.usageCount, 5);
    });

    test('should validate relationship types', () {
      expect(RelationshipType.isValidType('answers'), isTrue);
      expect(RelationshipType.isValidType('causality'), isTrue);
      expect(RelationshipType.isValidType('related'), isTrue);
      expect(RelationshipType.isValidType('custom'), isFalse);
      expect(RelationshipType.isValidType('ANSWERS'), isTrue); // Case insensitive
    });

    test('should check if AI interaction is expired', () {
      final expiredInteraction = AIInteraction(
        id: 'ai-1',
        type: AIInteractionType.noteQa,
        prompt: 'Test',
        response: 'Test',
        contextNoteIds: [],
        createdAt: DateTime.now().subtract(const Duration(days: 11)),
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );

      final validInteraction = AIInteraction(
        id: 'ai-2',
        type: AIInteractionType.noteQa,
        prompt: 'Test',
        response: 'Test',
        contextNoteIds: [],
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      );

      expect(expiredInteraction.isExpired, isTrue);
      expect(validInteraction.isExpired, isFalse);
    });

    test('should copy note with new values', () {
      final originalNote = Note(
        id: 'note-1',
        title: 'Original Title',
        content: 'Original content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final copiedNote = originalNote.copyWith(
        title: 'New Title',
        content: 'New content',
      );

      expect(copiedNote.id, 'note-1'); // Same ID
      expect(copiedNote.title, 'New Title'); // Updated
      expect(copiedNote.content, 'New content'); // Updated
      expect(copiedNote.type, NoteType.note); // Same type
    });
  });
}