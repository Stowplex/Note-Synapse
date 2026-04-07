import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/content_ingestion_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/providers/app_provider.dart';

@GenerateMocks([DatabaseService, AppProvider])
import 'content_ingestion_service_test.mocks.dart';
import '../conversation_skill_discovery_test.mocks.dart' as conversation_mocks;
import '../immutability_enforcement_test.mocks.dart' as immutability_mocks;

void main() {
  late MockDatabaseService mockDb;
  late immutability_mocks.MockTagWorkflowService mockTagWorkflowService;
  late conversation_mocks.MockAgentService mockAgentService;
  late ContentIngestionService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockTagWorkflowService = immutability_mocks.MockTagWorkflowService();
    mockAgentService = conversation_mocks.MockAgentService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<TagWorkflowService>(mockTagWorkflowService);
    getIt.registerSingleton<AgentService>(mockAgentService);
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
      when(
        mockTagWorkflowService.resolveBindings(note.tags),
      ).thenAnswer((_) async => const []);
      when(mockDb.getAllTags()).thenAnswer((_) async => []);

      await service.processNote(note, mockAppProvider);

      verify(mockDb.getAllTags()).called(1);
    });

    test(
      'processNote triggers workflow bindings even without extraction prompt',
      () async {
        final note = Note(
          id: 'test-id',
          title: 'Test Note',
          content: 'Content',
          type: NoteType.note,
          tags: ['wiki-source-ml'],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final mockAppProvider = MockAppProvider();
        final binding = ResolvedBinding(
          skillNoteId: 'skill-1',
          matchedTag: 'wiki-source-ml',
          pattern: 'wiki-source-',
          prompt: 'Ingest {note_id} from {matched_tag}',
          contentImmutable: true,
        );
        var onSuccessCalled = false;

        when(
          mockTagWorkflowService.resolveBindings(note.tags),
        ).thenAnswer((_) async => [binding]);
        when(mockAgentService.runWorkflowTask(binding: binding, note: note))
            .thenAnswer((_) async {});
        when(mockDb.getAllTags()).thenAnswer((_) async => []);

        await service.processNote(
          note,
          mockAppProvider,
          onSuccess: () => onSuccessCalled = true,
        );

        verify(
          mockAgentService.runWorkflowTask(binding: binding, note: note),
        ).called(1);
        verify(mockDb.getAllTags()).called(1);
        expect(onSuccessCalled, isTrue);
      },
    );
  });
}
