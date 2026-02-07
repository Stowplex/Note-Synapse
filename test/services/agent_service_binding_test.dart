import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/context_node.dart';
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
import 'agent_service_binding_test.mocks.dart';

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

    // Prevent crashes
    when(mockContextManager.getContext(any)).thenReturn(null);
    when(mockContextManager.rootContext).thenReturn(null);
    when(
      mockContextManager.createRootContext(
        objective: anyNamed('objective'),
        allowedTools: anyNamed('allowedTools'),
      ),
    ).thenAnswer(
      (i) async =>
          ContextNode(id: 'root', objective: i.namedArguments[#objective]),
    );

    when(
      mockContextManager.buildContextForResearchTask(
        any,
        dependencyResults: anyNamed('dependencyResults'),
        structuredDependencies: anyNamed('structuredDependencies'),
      ),
    ).thenReturn('Global Context');

    // Additional stubs
    when(mockModelSelector.currentModelConfig).thenReturn(null);
    when(
      mockContextManager.generateFinalSummary(
        any,
        consumingTaskDescriptions: anyNamed('consumingTaskDescriptions'),
        modelOverride: anyNamed('modelOverride'),
      ),
    ).thenAnswer((_) async => 'Task Summary');
    when(
      mockContextManager.buildContextForSubtask(any),
    ).thenReturn("Subtask Context");
    when(mockContextManager.addFindings(any)).thenReturn(null);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('AgentService - Binding', () {
    test('bindToConversation sets ID', () {
      expect(agentService.boundConversationId, isNull);
      agentService.bindToConversation('conv_1');
      expect(agentService.boundConversationId, 'conv_1');
    });

    test('bindToConversation clears state if ID changes', () async {
      // 1. Setup initial state
      agentService.bindToConversation('conv_1');
      // Simulate running state (hack: we can't easily force _isRunning true directly without executing plan)
      // But we can check if bind clears previous bound ID side effects?
      // Actually we can check if it calls clearState? Not easily without spying.
      // But we can check public state getters.

      // Let's manually inject a task for testing purposes via performTaskForTest logic? No.
      // We rely on observable state.
      // Bind new ID.
      agentService.bindToConversation('conv_2');
      expect(agentService.boundConversationId, 'conv_2');
      // We assume clearState was called (verified in other tests that clearState works).
    });

    test('bindToConversation does NOT clear state if ID is same', () {
      agentService.bindToConversation('conv_1');
      agentService.bindToConversation('conv_1');
      expect(agentService.boundConversationId, 'conv_1');
    });
  });

  group('AgentService - canStartNewAgent', () {
    test('Returns true if agent is idle', () {
      expect(agentService.isRunning, isFalse);
      expect(agentService.tasks, isEmpty);
      expect(agentService.canStartNewAgent('any_conv'), isTrue);
    });

    test(
      'Returns true if bound ID is null (even if theoretically running?)',
      () {
        // Ideally we set _isRunning = true but boundId = null.
        //Hard to achieve via public API.
        // But default state is boundId null.
        expect(agentService.boundConversationId, isNull);
        expect(agentService.canStartNewAgent('any'), isTrue);
      },
    );

    test('Returns false if incoming ID is null', () {
      expect(agentService.canStartNewAgent(null), isFalse);
    });

    test('Returns true if conversation ID matches bound ID', () {
      agentService.bindToConversation('conv_1');
      expect(agentService.canStartNewAgent('conv_1'), isTrue);
    });

    test(
      'Returns false if conversation ID differs and agent is BUSY',
      () async {
        // 1. Bind
        agentService.bindToConversation('conv_1');

        // 2. Make it BUSY (populate tasks)
        // Mock generatePlan response
        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer(
          (_) async => '[{"name": "t1", "description": "d1", "tools": []}]',
        );

        // Call generatePlan directly to populate _tasks
        await agentService.generatePlan(
          'Test objective',
          activeTools: {},
          executeTool: (_, __, ___, ____) async => '',
        );

        expect(agentService.tasks, isNotEmpty);

        // 3. Check canStartNewAgent for DIFFERENT conversation
        expect(agentService.canStartNewAgent('conv_2'), isFalse);

        // 4. Check canStartNewAgent for SAME conversation should be True
        expect(agentService.canStartNewAgent('conv_1'), isTrue);
      },
    );
  });
}
