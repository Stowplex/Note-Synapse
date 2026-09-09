// test/workflow_shell_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/user_app_session_service.dart';
import 'package:note_synapse/utils/global_keys.dart';
import 'package:note_synapse/widgets/user_app_background_pill.dart';
import 'package:note_synapse/widgets/user_app_background_shell.dart';
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
    getIt.registerLazySingleton<ContextManagerService>(
      () => mockContextManager,
    );

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDb,
    );
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

    testWidgets('mini-player gets active status from agent service', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WorkflowShell(
            child: const Scaffold(body: Text('Main Content')),
          ),
        ),
      );

      // Verify the shell renders and mini-player exists with null status
      final miniPlayer = tester.widget<WorkflowMiniPlayer>(
        find.byType(WorkflowMiniPlayer),
      );
      expect(miniPlayer.activeStatus, isNull);
    });

    testWidgets(
      'composes with UserAppBackgroundShell as main.dart nests them',
      (tester) async {
        appRouteObserver.resetForTesting();
        final session = UserAppSessionService(
          homeBuilder: (_) => const Scaffold(body: Text('HOME_PRIME')),
        );
        getIt.registerSingleton<UserAppSessionService>(session);

        // Exactly the `builder:` from `main.dart`: the background shell inside
        // the workflow shell, so the pill floats over page content instead of
        // fighting the mini-player for the bottom edge.
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: [appRouteObserver],
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en', '')],
            builder: (context, child) => WorkflowShell(
              child: UserAppBackgroundShell(
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            home: const Scaffold(body: Text('Main Content')),
          ),
        );

        expect(find.text('Main Content'), findsOneWidget);
        expect(find.byType(WorkflowMiniPlayer), findsOneWidget);
        expect(find.byType(UserAppBackgroundPill), findsNothing);

        final appRoute = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('APP')),
        );
        navigatorKey.currentState!.push(appRoute);
        await tester.pumpAndSettle();
        session.register(
          UserApp(
            id: '1',
            uuid: 'uuid-1',
            name: 'Cartograph',
            description: '',
            steps: const [],
            htmlContent: '',
            createdAt: DateTime(2024),
            updatedAt: DateTime(2024),
          ),
          appRoute,
        );
        await session.moveToBackground();
        await tester.pumpAndSettle();

        // Both shells are doing their jobs at the same time.
        expect(find.byType(UserAppBackgroundPill), findsOneWidget);
        expect(find.byType(WorkflowMiniPlayer), findsOneWidget);
        expect(find.text('HOME_PRIME'), findsOneWidget);

        // Let the pill's collapse timer fire so none is left pending.
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      },
    );
  });
}
