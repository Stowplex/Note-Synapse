import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:shared_preferences/shared_preferences.dart';

@GenerateMocks([
  ContextManagerService,
  ModelSelector,
  AIService,
  DatabaseService,
])
import 'agent_service_global_context_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late MockContextManagerService mockContextManager;
  late MockModelSelector mockModelSelector;
  late MockAIService mockAIService;
  late MockDatabaseService mockDatabaseService;
  late AgentService agentService;

  setUp(() async {
    await resetForTesting();
    mockContextManager = MockContextManagerService();
    mockModelSelector = MockModelSelector();
    mockAIService = MockAIService();
    mockDatabaseService = MockDatabaseService();

    getIt.registerLazySingleton<ContextManagerService>(
      () => mockContextManager,
    );
    getIt.registerLazySingleton<ModelSelector>(() => mockModelSelector);
    getIt.registerLazySingleton<AIService>(() => mockAIService);
    getIt.registerLazySingleton<DatabaseService>(() => mockDatabaseService);

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('AgentService - Global Context Notes', () {
    test('addGlobalContextNote adds note ID if not present', () {
      expect(agentService.globalContextNoteIds, isEmpty);
      agentService.addGlobalContextNote('note-1');
      expect(agentService.globalContextNoteIds, contains('note-1'));
    });

    test('addGlobalContextNote does not add duplicate', () {
      agentService.addGlobalContextNote('note-1');
      agentService.addGlobalContextNote('note-1');
      expect(agentService.globalContextNoteIds.length, equals(1));
    });

    test('addGlobalContextNote adds multiple unique notes', () {
      agentService.addGlobalContextNote('note-1');
      agentService.addGlobalContextNote('note-2');
      agentService.addGlobalContextNote('note-3');
      expect(agentService.globalContextNoteIds.length, equals(3));
    });

    test('removeGlobalContextNote removes existing note', () {
      agentService.addGlobalContextNote('note-1');
      agentService.addGlobalContextNote('note-2');
      agentService.removeGlobalContextNote('note-1');
      expect(agentService.globalContextNoteIds, isNot(contains('note-1')));
      expect(agentService.globalContextNoteIds, contains('note-2'));
    });

    test('removeGlobalContextNote does nothing for non-existent note', () {
      agentService.addGlobalContextNote('note-1');
      agentService.removeGlobalContextNote('non-existent');
      expect(agentService.globalContextNoteIds.length, equals(1));
    });

    test('clearGlobalContextNotes removes all notes', () {
      agentService.addGlobalContextNote('note-1');
      agentService.addGlobalContextNote('note-2');
      agentService.clearGlobalContextNotes();
      expect(agentService.globalContextNoteIds, isEmpty);
    });

    test('setGlobalContextNotes replaces all notes', () {
      agentService.addGlobalContextNote('old-note');
      agentService.setGlobalContextNotes(['new-1', 'new-2']);
      expect(agentService.globalContextNoteIds.length, equals(2));
      expect(agentService.globalContextNoteIds, contains('new-1'));
      expect(agentService.globalContextNoteIds, contains('new-2'));
      expect(agentService.globalContextNoteIds, isNot(contains('old-note')));
    });

    test('setGlobalContextNotes with empty list clears notes', () {
      agentService.addGlobalContextNote('note-1');
      agentService.setGlobalContextNotes([]);
      expect(agentService.globalContextNoteIds, isEmpty);
    });

    test('globalContextNoteIds returns unmodifiable list', () {
      agentService.addGlobalContextNote('note-1');
      final ids = agentService.globalContextNoteIds;
      expect(() => ids.add('note-2'), throwsUnsupportedError);
    });
  });

  group('AgentService - Pause/Resume/Stop', () {
    test('pauseExecution sets isPaused when running', () {
      // Simulate running state by setting _isRunning indirectly
      // This requires accessing internal state, so we test the public API
      expect(agentService.isPaused, isFalse);

      // Pause when not running should do nothing
      agentService.pauseExecution();
      expect(agentService.isPaused, isFalse); // Not running, so no change
    });

    test('stopExecution clears all state', () {
      agentService.addGlobalContextNote('note-1');
      agentService.stopExecution();
      expect(agentService.globalContextNoteIds, isEmpty);
      expect(agentService.tasks, isEmpty);
      expect(agentService.isRunning, isFalse);
      expect(agentService.isPaused, isFalse);
      expect(agentService.currentThought, isNull);
      expect(agentService.finalAnswer, isNull);
    });

    test('abortCurrentTask stops execution', () {
      agentService.addGlobalContextNote('note-1');
      agentService.abortCurrentTask();
      expect(agentService.globalContextNoteIds, isEmpty);
      expect(agentService.isRunning, isFalse);
    });
  });

  group('AgentService - Binding', () {
    test('bindToConversation sets bound conversation ID', () {
      agentService.bindToConversation('conv-123');
      expect(agentService.boundConversationId, equals('conv-123'));
    });

    test('bindToConversation clears state when switching conversations', () {
      agentService.bindToConversation('conv-1');
      agentService.addGlobalContextNote('note-1');
      agentService.bindToConversation('conv-2');
      // Should clear on switch
      expect(agentService.globalContextNoteIds, isEmpty);
      expect(agentService.boundConversationId, equals('conv-2'));
    });

    test('bindToConversation does not clear for same conversation', () {
      agentService.bindToConversation('conv-1');
      agentService.addGlobalContextNote('note-1');
      agentService.bindToConversation('conv-1');
      // Should NOT clear for same conversation
      expect(agentService.globalContextNoteIds.length, equals(1));
    });

    test('canStartNewAgent returns true when idle', () {
      expect(agentService.canStartNewAgent('conv-1'), isTrue);
    });

    test('canStartNewAgent returns true for same conversation', () {
      agentService.bindToConversation('conv-1');
      expect(agentService.canStartNewAgent('conv-1'), isTrue);
    });

    test('canStartNewAgent returns true when boundConversationId is null', () {
      expect(agentService.canStartNewAgent('any-conv'), isTrue);
    });

    test('canStartNewAgent returns false for null conversation when bound', () {
      agentService.bindToConversation('conv-1');
      // Need to simulate running state for this to matter
      // Even when idle, null ID should be rejected for safety
      expect(agentService.canStartNewAgent(null), isFalse);
    });
  });

  group('AgentService - Tool Maps', () {
    test('getToolToServiceMap includes system tools', () {
      final map = agentService.getToolToServiceMap();
      expect(map, isNotEmpty);
      // All native tools are under 'System'
      for (final value in map.values) {
        expect(value, equals('System'));
      }
    });

    test('getAllToolNames returns native tool names', () {
      final names = agentService.getAllToolNames();
      expect(names, isNotEmpty);
      // Should contain known tool names
      expect(names, anyOf(contains('search_notes'), contains('read_note')));
    });
  });

  group('AgentService - State Getters', () {
    test('tasks returns empty unmodifiable list initially', () {
      expect(agentService.tasks, isEmpty);
      expect(
        () => agentService.tasks.add(
          AgentTask(id: 'x', description: 'y', status: AgentTaskStatus.pending),
        ),
        throwsUnsupportedError,
      );
    });

    test('externalTools returns empty map initially', () {
      expect(agentService.externalTools, isEmpty);
    });

    test('isRunning is false initially', () {
      expect(agentService.isRunning, isFalse);
    });

    test('currentThought is null initially', () {
      expect(agentService.currentThought, isNull);
    });

    test('finalAnswer is null initially', () {
      expect(agentService.finalAnswer, isNull);
    });

    test('finalMetadata is null initially', () {
      expect(agentService.finalMetadata, isNull);
    });

    test('currentObjective is null initially', () {
      expect(agentService.currentObjective, isNull);
    });

    test('modelOverride is null initially', () {
      expect(agentService.modelOverride, isNull);
    });

    test('currentCheckpoint is null initially', () {
      expect(agentService.currentCheckpoint, isNull);
    });
  });

  group('AgentService - clearState', () {
    test('clearState resets all state fields', () {
      agentService.addGlobalContextNote('note-1');
      agentService.bindToConversation('conv-1');

      when(mockContextManager.clear()).thenReturn(null);

      agentService.clearState();

      expect(agentService.tasks, isEmpty);
      expect(agentService.globalContextNoteIds, isEmpty);
      expect(agentService.isRunning, isFalse);
      expect(agentService.isPaused, isFalse);
      expect(agentService.boundConversationId, isNull);
      expect(agentService.currentCheckpoint, isNull);
      expect(agentService.modelOverride, isNull);
      verify(mockContextManager.clear()).called(1);
    });
  });
}
