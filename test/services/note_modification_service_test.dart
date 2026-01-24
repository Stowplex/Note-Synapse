import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/models/note.dart';

@GenerateMocks([DatabaseService])
import 'note_modification_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late NoteModificationService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteModificationService(getIt<DatabaseService>());
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('NoteModificationService', () {
    test('applyModifications fetches note from database', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Original content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      await service.applyModifications('test-id', {});

      verify(mockDb.getNoteById('test-id')).called(1);
    });

    test('applyModifications throws when note not found', () async {
      when(mockDb.getNoteById('missing-id')).thenAnswer((_) async => null);

      expect(
        () => service.applyModifications('missing-id', {}),
        throwsA(isA<Exception>()),
      );
    });

    test('applyModifications appends content when action is append', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Original',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      await service.applyModifications('test-id', {
        'content': {'action': 'append', 'text': ' appended'},
      });

      final captured = verify(mockDb.updateNote(captureAny)).captured.single as Note;
      expect(captured.content, 'Original\n appended');
    });
  });
}
