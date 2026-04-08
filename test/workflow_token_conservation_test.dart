import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workflow_task_test.mocks.dart';

void main() {
  group('WorkflowStatusSnapshot extensions', () {
    test('snapshot includes turnsUsed, maxTurns, noteTitle', () {
      final snapshot = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.running,
        message: 'Running',
        noteTitle: 'Attention is all you need',
        turnsUsed: 3,
        maxTurns: 10,
      );
      expect(snapshot.noteTitle, 'Attention is all you need');
      expect(snapshot.turnsUsed, 3);
      expect(snapshot.maxTurns, 10);
    });
  });

  group('PendingWorkflowInfo', () {
    test('holds noteId, noteTitle, matchedTag', () {
      final info = PendingWorkflowInfo(
        noteId: 'note-2',
        noteTitle: 'BERT paper',
        matchedTag: 'wiki-source-ai',
      );
      expect(info.noteId, 'note-2');
      expect(info.noteTitle, 'BERT paper');
      expect(info.matchedTag, 'wiki-source-ai');
    });
  });

  group('AgentService queue API', () {
    late MockDatabaseService mockDb;
    late MockAIService mockAIService;
    late MockModelSelector mockModelSelector;
    late MockContextManagerService mockContextManager;
    late AgentService agentService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await resetForTesting();
      mockDb = MockDatabaseService();
      mockAIService = MockAIService();
      mockModelSelector = MockModelSelector();
      mockContextManager = MockContextManagerService();

      getIt.registerLazySingleton<DatabaseService>(() => mockDb);
      getIt.registerLazySingleton<AIService>(() => mockAIService);
      getIt.registerLazySingleton<ModelSelector>(() => mockModelSelector);
      getIt.registerLazySingleton<ContextManagerService>(
        () => mockContextManager,
      );
      getIt.registerLazySingleton<SkillService>(() => SkillService(mockDb));

      agentService = AgentService(
        mockContextManager,
        mockModelSelector,
        mockAIService,
        mockDb,
      );
    });

    test('pendingWorkflows returns empty list when no pending workflows', () {
      expect(agentService.pendingWorkflows, isEmpty);
    });

    test('cancelPendingWorkflow is no-op for out-of-range index', () {
      // Should not throw
      agentService.cancelPendingWorkflow(-1);
      agentService.cancelPendingWorkflow(0);
      agentService.cancelPendingWorkflow(100);
      expect(agentService.pendingWorkflows, isEmpty);
    });
  });
}
