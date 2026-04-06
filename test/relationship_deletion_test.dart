import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'relationship_deletion_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late NoteModificationService service;

  final testNote = Note(
    id: 'note-1',
    title: 'Test Note',
    content: 'Content',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    subNotes: [],
    tags: ['wiki-compiled-ml'],
    attachmentPaths: [],
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteModificationService(mockDb);
  });

  group('link.removed in modify_note', () {
    test('deletes relationship when removed contains target noteId', () async {
      when(mockDb.getNoteById('note-1')).thenAnswer((_) async => testNote);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.deleteRelationshipBetween('note-1', 'note-b'))
          .thenAnswer((_) async {});

      await service.applyModifications('note-1', {
        'link': {
          'removed': ['note-b'],
        },
      });

      verify(mockDb.deleteRelationshipBetween('note-1', 'note-b')).called(1);
    });

    test('creates AND deletes relationships in same call', () async {
      when(mockDb.getNoteById('note-1')).thenAnswer((_) async => testNote);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async => 'rel-id');
      when(mockDb.deleteRelationshipBetween('note-1', 'old-target'))
          .thenAnswer((_) async {});

      await service.applyModifications('note-1', {
        'link': {
          'added': [
            {'relation': 'related', 'target': 'new-target'},
          ],
          'removed': ['old-target'],
        },
      });

      verify(mockDb.insertRelationship(any)).called(1);
      verify(mockDb.deleteRelationshipBetween('note-1', 'old-target')).called(1);
    });

    test('existing link creation behavior unchanged (array of objects)', () async {
      when(mockDb.getNoteById('note-1')).thenAnswer((_) async => testNote);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async => 'rel-id');

      await service.applyModifications('note-1', {
        'link': [
          {'relation': 'related', 'target': 'note-c'},
        ],
      });

      verify(mockDb.insertRelationship(any)).called(1);
    });
  });
}
