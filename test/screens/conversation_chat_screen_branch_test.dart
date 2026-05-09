import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_branch_summary.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/screens/conversation_chat_screen.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/mcp_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../conversation_service_test.mocks.dart' as mocks;
import '../widgets/marker_chat_panel_host_test.mocks.dart' as widget_mocks;

void main() {
  late widget_mocks.MockConversationService mockConversationService;
  late mocks.MockMcpService mockMcpService;
  late mocks.MockSkillService mockSkillService;
  late mocks.MockAgentService mockAgentService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();

    mockConversationService = widget_mocks.MockConversationService();
    mockMcpService = mocks.MockMcpService();
    mockSkillService = mocks.MockSkillService();
    mockAgentService = mocks.MockAgentService();

    when(mockMcpService.getEndpoints()).thenAnswer((_) async => const []);
    when(mockSkillService.buildSkillIndex()).thenAnswer((_) async => const {});
    when(mockConversationService.skillsEnabled).thenReturn(false);
    when(mockConversationService.skillIndex).thenReturn(const {});
    when(
      mockConversationService.getConversationTagNames(any),
    ).thenAnswer((_) async => const []);
    when(
      mockConversationService.validateConversationNotes(any),
    ).thenAnswer((_) async => const []);
    when(
      mockConversationService.getConversationNotes(any),
    ).thenAnswer((_) async => const []);
    when(mockAgentService.isRunning).thenReturn(false);
    when(mockAgentService.isPaused).thenReturn(false);

    getIt.registerSingleton<ConversationService>(mockConversationService);
    getIt.registerSingleton<McpService>(mockMcpService);
    getIt.registerSingleton<SkillService>(mockSkillService);
  });

  tearDown(() async {
    await resetForTesting();
  });

  testWidgets('renders branch strip and switches sibling branch in place', (
    tester,
  ) async {
    final now = DateTime(2026);
    final parentConversation = Conversation(
      id: 'conv-1',
      title: 'Current',
      noteIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    final childConversation = Conversation(
      id: 'child-1',
      title: 'Child A',
      noteIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    final message = ConversationMessage(
      id: 'ai-1',
      conversationId: 'conv-1',
      type: MessageType.ai,
      content: 'Answer',
      timestamp: now,
    );

    when(
      mockConversationService.getConversationWithFullHistory('conv-1'),
    ).thenAnswer(
      (_) async => ConversationWithMessages(
        conversation: parentConversation,
        messages: [message],
      ),
    );
    when(
      mockConversationService.getConversationWithFullHistory('child-1'),
    ).thenAnswer(
      (_) async => ConversationWithMessages(
        conversation: childConversation,
        messages: [message.copyWith(conversationId: 'child-1')],
      ),
    );
    when(mockConversationService.getAllForkPointBranches('conv-1')).thenAnswer(
      (_) async => {
        'ai-1': const [
          ConversationBranchSummary(
            conversationId: 'child-1',
            title: 'Child A',
            forkPointMessageId: 'ai-1',
            firstChildMessageId: 'child-user-1',
            noteIds: [],
          ),
        ],
      },
    );
    when(
      mockConversationService.getAllForkPointBranches('child-1'),
    ).thenAnswer((_) async => const {});

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppProvider>(create: (_) => AppProvider()),
          ChangeNotifierProvider<AgentService>.value(value: mockAgentService),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: [Locale('en', ''), Locale('zh', '')],
          home: ConversationChatScreen(
            conversationId: 'conv-1',
            skillsEnabled: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current'), findsAtLeastNWidgets(1));
    expect(find.text('Child A'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('branch-row-active-conv-1')),
      findsOneWidget,
    );

    await tester.tap(find.text('Child A'));
    await tester.pumpAndSettle();

    verify(
      mockConversationService.getConversationWithFullHistory('child-1'),
    ).called(1);
  });
}
