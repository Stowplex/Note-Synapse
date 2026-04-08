// test/workflow_shell_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/workflow_mini_player.dart';
import 'package:note_synapse/widgets/workflow_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workflow_task_test.mocks.dart';

void main() {
  late AgentService agentService;
  late MockDatabaseService mockDb;
  late MockAIService mockAIService;
  late MockModelSelector mockModelSelector;
  late MockContextManagerService mockContextManager;

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
    getIt.registerLazySingleton<ContextManagerService>(() => mockContextManager);

    agentService = AgentService(mockContextManager, mockModelSelector, mockAIService, mockDb);
    getIt.registerSingleton<AgentService>(agentService);
  });

  group('WorkflowShell', () {
    testWidgets('renders child when no active workflow', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WorkflowShell(
            child: const Scaffold(body: Text('Main Content')),
          ),
        ),
      );
      expect(find.text('Main Content'), findsOneWidget);
      // Mini-player is present but hidden (no active workflow)
      expect(find.byType(WorkflowMiniPlayer), findsOneWidget);
    });

    testWidgets('mini-player gets active status from agent service', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WorkflowShell(
            child: const Scaffold(body: Text('Main Content')),
          ),
        ),
      );

      // Verify the shell renders and mini-player exists with null status
      final miniPlayer = tester.widget<WorkflowMiniPlayer>(find.byType(WorkflowMiniPlayer));
      expect(miniPlayer.activeStatus, isNull);
    });
  });
}
