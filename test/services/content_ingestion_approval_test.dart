import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/model_capabilities.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/content_ingestion_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/widgets/local_model_workflow_warning_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'content_ingestion_approval_test.mocks.dart';

@GenerateMocks([DatabaseService, AgentService, TagWorkflowService, AppProvider])
void main() {
  late MockDatabaseService mockDb;
  late MockAgentService mockAgentService;
  late MockTagWorkflowService mockTagWorkflowService;
  late MockAppProvider mockAppProvider;
  late ContentIngestionService service;

  final testNote = Note(
    id: 'note-1',
    title: 'Test',
    content: '',
    type: NoteType.note,
    tags: ['wiki-tag'],
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  final testBinding = ResolvedBinding(
    skillNoteId: 'skill-1',
    matchedTag: 'wiki-tag',
    pattern: 'wiki-tag',
    prompt: 'Process.',
    contentImmutable: false,
  );

  ModelConfig localModelConfig({bool supportsOrchestration = false}) =>
      ModelConfig(
        type: ModelType.localMnn,
        modelName: 'gemma4_e2b',
        isConfigured: true,
        customCapabilitiesObject: ModelCapabilities(
          maxInputTokens: 8192,
          maxOutputTokens: 2048,
          supportsImages: false,
          supportsDocuments: false,
          supportsAudio: false,
          supportsVideo: false,
          supportsToolOrchestration: supportsOrchestration,
        ),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();

    mockDb = MockDatabaseService();
    mockAgentService = MockAgentService();
    mockTagWorkflowService = MockTagWorkflowService();
    mockAppProvider = MockAppProvider();

    getIt.registerLazySingleton<AgentService>(() => mockAgentService);
    getIt.registerLazySingleton<TagWorkflowService>(() => mockTagWorkflowService);

    service = ContentIngestionService(mockDb);
    ContentIngestionService.onLocalModelApprovalRequired = null;

    when(mockTagWorkflowService.resolveBindings(any))
        .thenAnswer((_) async => [testBinding]);
    when(mockAgentService.runWorkflowTask(
      binding: anyNamed('binding'),
      note: anyNamed('note'),
    )).thenAnswer((_) async {});
    when(mockAppProvider.modelConfig)
        .thenReturn(localModelConfig(supportsOrchestration: false));
    when(mockDb.getAllTags()).thenAnswer((_) async => []);
  });

  tearDown(() {
    ContentIngestionService.onLocalModelApprovalRequired = null;
  });

  group('processNote approval callback', () {
    test('calls callback before running workflow when orchestration unsupported', () async {
      var callbackCalled = false;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callbackCalled = true;
        return LocalModelWorkflowApproval.proceed;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callbackCalled, isTrue);
      verify(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      )).called(1);
    });

    test('skips workflow when callback returns cancel', () async {
      ContentIngestionService.onLocalModelApprovalRequired =
          () async => LocalModelWorkflowApproval.cancel;

      await service.processNote(testNote, mockAppProvider);

      verifyNever(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      ));
    });

    test('cancel with multiple bindings skips all of them', () async {
      when(mockTagWorkflowService.resolveBindings(any))
          .thenAnswer((_) async => [testBinding, testBinding]);

      var callCount = 0;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callCount++;
        return LocalModelWorkflowApproval.cancel;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callCount, 1);
      verifyNever(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      ));
    });

    test('runs workflow and suppresses subsequent dialogs on proceedAndSuppress', () async {
      when(mockTagWorkflowService.resolveBindings(any))
          .thenAnswer((_) async => [testBinding, testBinding]);

      var callCount = 0;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callCount++;
        return LocalModelWorkflowApproval.proceedAndSuppress;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callCount, 1);
      verify(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      )).called(2);
    });

    test('does not call callback when orchestration is supported', () async {
      when(mockAppProvider.modelConfig)
          .thenReturn(localModelConfig(supportsOrchestration: true));

      var callbackCalled = false;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callbackCalled = true;
        return LocalModelWorkflowApproval.proceed;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callbackCalled, isFalse);
      verify(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      )).called(1);
    });

    test('does not call callback when no workflow bindings match', () async {
      when(mockTagWorkflowService.resolveBindings(any))
          .thenAnswer((_) async => []);

      var callbackCalled = false;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callbackCalled = true;
        return LocalModelWorkflowApproval.proceed;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callbackCalled, isFalse);
    });
  });
}
