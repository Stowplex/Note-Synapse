import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/prompts/note_prompt_builder.dart';

class ManualMockDatabaseService implements DatabaseService {
  @override
  Future<List<Attachment>> getAttachmentsForNote(String noteId) async => [];

  @override
  Future<List<Relationship>> getRelationships(String noteId) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getAttachmentsForNote)
      return Future.value(<Attachment>[]);
    if (invocation.memberName == #getRelationships)
      return Future.value(<Relationship>[]);
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'buildNoteContext includes ID, Tags and Task metadata with Metadata label',
    () async {
      final mockDb = ManualMockDatabaseService();
      final noteBuilder = NotePromptBuilder(mockDb);

      final note = Note(
        id: 'test-note-123',
        title: 'Test Note',
        content: 'Hello world',
        type: NoteType.task,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['tag1', 'tag2'],
        status: TaskStatus.inProgress,
        scheduledAt: '2026-01-01',
        completeBy: '2026-01-05',
      );

      final context = await noteBuilder.buildNoteContext([note]);

      print('Generated Context:\n$context');

      expect(context, contains('Metadata:'));
      expect(context, contains('ID: test-note-123'));
      expect(context, contains('Tags: tag1, tag2'));
      expect(context, contains('Status: inProgress'));
      expect(context, contains('Scheduled: 2026-01-01'));
      expect(context, contains('Complete By: 2026-01-05'));
      expect(context, contains('Type: task'));

      // Check order (Metadata before Content)
      final metadataIndex = context.indexOf('Metadata:');
      final contentIndex = context.indexOf('Content:');
      expect(
        metadataIndex < contentIndex,
        isTrue,
        reason: 'Metadata should come before Content',
      );
    },
  );

  test('sub-notes include ID', () async {
    final mockDb = ManualMockDatabaseService();
    final noteBuilder = NotePromptBuilder(mockDb);

    final note = Note(
      id: 'parent-note',
      title: 'Parent',
      content: 'Parent content',
      type: NoteType.note,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      subNotes: [
        SubNote(
          id: 'sub-note-456',
          name: 'Child Note',
          content: 'Child content',
          createdAt: DateTime.now(),
          isCompleted: true,
        ),
      ],
    );

    final context = await noteBuilder.buildNoteContext([note]);

    print('Generated Context with Sub-notes:\n$context');

    expect(context, contains('Child Note (ID: sub-note-456, completed)'));
  });
}
