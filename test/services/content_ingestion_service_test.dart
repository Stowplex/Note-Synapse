import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/content_ingestion_service.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/providers/app_provider.dart';

@GenerateMocks([DatabaseService, AppProvider])
import 'content_ingestion_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late ContentIngestionService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = ContentIngestionService(getIt<DatabaseService>());
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('ContentIngestionService', () {
    test('processNote returns early when note has no tags', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Content',
        type: NoteType.note,
        tags: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final mockAppProvider = MockAppProvider();

      // Should return without calling database
      await service.processNote(note, mockAppProvider);

      verifyNever(mockDb.getAllTags());
    });

    test('processNote fetches tags from database when note has tags', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Content',
        type: NoteType.note,
        tags: ['work'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final mockAppProvider = MockAppProvider();
      when(mockDb.getAllTags()).thenAnswer((_) async => []);

      await service.processNote(note, mockAppProvider);

      verify(mockDb.getAllTags()).called(1);
    });
  });
}
