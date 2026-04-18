import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'immutability_enforcement_test.mocks.dart';

@GenerateMocks([DatabaseService, TagWorkflowService])
void main() {
  late MockDatabaseService mockDb;
  late MockTagWorkflowService mockTagWorkflow;
  late NoteModificationService service;

  final immutableNote = Note(
    id: 'source-1', title: 'Original Title', content: 'Original content.',
    type: NoteType.note, createdAt: DateTime.now(), updatedAt: DateTime.now(),
    subNotes: [], tags: ['wiki-source-ml', 'machine-learning'], attachmentPaths: ['doc.pdf'],
  );

  final anotherImmutableNote = Note(
    id: 'source-2', title: 'Recipe Source', content: 'Grandma recipe.',
    type: NoteType.note, createdAt: DateTime.now(), updatedAt: DateTime.now(),
    subNotes: [], tags: ['recipe-source-italian'], attachmentPaths: [],
  );

  final regularNote = Note(
    id: 'regular-1', title: 'Regular Note', content: 'Can be modified.',
    type: NoteType.note, createdAt: DateTime.now(), updatedAt: DateTime.now(),
    subNotes: [], tags: ['wiki-compiled-ml'], attachmentPaths: [],
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockTagWorkflow = MockTagWorkflowService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<TagWorkflowService>(mockTagWorkflow);
    service = NoteModificationService(mockDb);
  });

  group('generic tag-workflow immutability enforcement', () {
    test('rejects content modification when tag has immutable binding', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => immutableNote);
      when(mockTagWorkflow.hasImmutableBinding(immutableNote.tags))
          .thenAnswer((_) async => true);

      await expectLater(
        service.applyModifications('source-1', {
          'content': {'action': 'append', 'text': 'Appended'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('immutable'))),
      );
    });

    test('rejects title modification when tag has immutable binding', () async {
      when(mockDb.getNoteById('source-2')).thenAnswer((_) async => anotherImmutableNote);
      when(mockTagWorkflow.hasImmutableBinding(anotherImmutableNote.tags))
          .thenAnswer((_) async => true);

      await expectLater(
        service.applyModifications('source-2', {
          'title': {'new_title': 'Changed'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('immutable'))),
      );
    });

    test('allows tag modification on immutable-bound note', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => immutableNote);
      when(mockTagWorkflow.hasImmutableBinding(immutableNote.tags))
          .thenAnswer((_) async => true);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      final result = await service.applyModifications('source-1', {
        'tags': {'added': ['reviewed']},
      });

      expect(result.tags, contains('reviewed'));
    });

    test('allows link creation on immutable-bound note', () async {
      when(mockDb.getNoteById('source-1')).thenAnswer((_) async => immutableNote);
      when(mockTagWorkflow.hasImmutableBinding(immutableNote.tags))
          .thenAnswer((_) async => true);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.insertRelationship(any)).thenAnswer((_) async => 'rel-id');

      await service.applyModifications('source-1', {
        'link': [{'relation': 'related', 'target': 'other'}],
      });

      verify(mockDb.insertRelationship(any)).called(1);
    });

    test('does not block modification when no immutable bindings', () async {
      when(mockDb.getNoteById('regular-1')).thenAnswer((_) async => regularNote);
      when(mockTagWorkflow.hasImmutableBinding(regularNote.tags))
          .thenAnswer((_) async => false);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      final result = await service.applyModifications('regular-1', {
        'content': {'action': 'append', 'text': 'New text'},
      });

      expect(result.content, contains('New text'));
    });

    test('works for non-wiki immutable bindings (generic)', () async {
      when(mockDb.getNoteById('source-2')).thenAnswer((_) async => anotherImmutableNote);
      when(mockTagWorkflow.hasImmutableBinding(anotherImmutableNote.tags))
          .thenAnswer((_) async => true);

      await expectLater(
        service.applyModifications('source-2', {
          'content': {'action': 'append', 'text': 'text'},
        }),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('immutable'))),
      );
    });
  });
}
