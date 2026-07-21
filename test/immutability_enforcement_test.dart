import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'immutability_enforcement_test.mocks.dart';

// Immutability decisions come from the (mocked) TagWorkflowService;
// persistence runs transactionally against a real in-memory database.
@GenerateMocks([TagWorkflowService])
void main() {
  late DatabaseService db;
  late MockTagWorkflowService mockTagWorkflow;
  late NoteModificationService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Note note(String id, {required List<String> tags, String? title}) => Note(
        id: id,
        title: title ?? 'Title of $id',
        content: 'Original content.',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: tags,
      );

  late Note immutableNote;
  late Note anotherImmutableNote;
  late Note regularNote;

  setUp(() async {
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    mockTagWorkflow = MockTagWorkflowService();
    getIt.registerSingleton<DatabaseService>(db);
    getIt.registerSingleton<TagWorkflowService>(mockTagWorkflow);
    service = NoteModificationService(db);

    immutableNote = note(
      'source-1',
      tags: ['wiki-source-ml', 'machine-learning'],
    );
    anotherImmutableNote = note('source-2', tags: ['recipe-source-italian']);
    regularNote = note('regular-1', tags: ['wiki-compiled-ml']);
    for (final n in [immutableNote, anotherImmutableNote, regularNote]) {
      await db.insertNote(n);
    }
  });

  tearDown(() async {
    await db.close();
  });

  group('generic tag-workflow immutability enforcement', () {
    test('rejects content modification when tag has immutable binding',
        () async {
      when(mockTagWorkflow.hasImmutableBinding(any))
          .thenAnswer((_) async => true);

      await expectLater(
        service.applyModifications('source-1', {
          'content': {'action': 'append', 'text': 'Appended'},
        }),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('immutable'))),
      );
    });

    test('rejects title modification when tag has immutable binding',
        () async {
      when(mockTagWorkflow.hasImmutableBinding(any))
          .thenAnswer((_) async => true);

      await expectLater(
        service.applyModifications('source-2', {
          'title': {'new_title': 'Changed'},
        }),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('immutable'))),
      );
    });

    test('allows tag modification on immutable-bound note', () async {
      when(mockTagWorkflow.hasImmutableBinding(any))
          .thenAnswer((_) async => true);

      final result = await service.applyModifications('source-1', {
        'tags': {
          'added': ['reviewed'],
        },
      });

      expect(result.tags, contains('reviewed'));
      final stored = await db.getNote('source-1');
      expect(stored!.tags, contains('reviewed'));
    });

    test('allows link creation on immutable-bound note', () async {
      when(mockTagWorkflow.hasImmutableBinding(any))
          .thenAnswer((_) async => true);

      await service.applyModifications('source-1', {
        'link': [
          {'relation': 'related', 'target': 'regular-1'},
        ],
      });

      final rows = await (await db.database).query(
        'relationships',
        where: 'fromNoteId = ?',
        whereArgs: ['source-1'],
      );
      expect(rows, hasLength(1));
      expect(rows.single['toNoteId'], 'regular-1');
    });

    test('does not block modification when no immutable bindings', () async {
      when(mockTagWorkflow.hasImmutableBinding(any))
          .thenAnswer((_) async => false);

      final result = await service.applyModifications('regular-1', {
        'content': {'action': 'append', 'text': 'New text'},
      });

      expect(result.content, contains('New text'));
      final stored = await db.getNote('regular-1');
      expect(stored!.content, contains('New text'));
    });

    test('works for non-wiki immutable bindings (generic)', () async {
      when(mockTagWorkflow.hasImmutableBinding(any))
          .thenAnswer((_) async => true);

      await expectLater(
        service.applyModifications('source-2', {
          'content': {'action': 'append', 'text': 'text'},
        }),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('immutable'))),
      );
    });
  });
}
