import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_branch_summary.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/fork_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/widgets/chat_panel.dart';

import 'chat_panel_test.mocks.dart';

@GenerateMocks([ConversationService, ForkService])
void main() {
  late MockConversationService mockConv;
  late MockForkService mockFork;

  setUp(() async {
    await resetForTesting();
    mockConv = MockConversationService();
    mockFork = MockForkService();
    when(mockFork.forkCreatedStream).thenAnswer((_) => const Stream.empty());
    getIt.registerSingleton<ConversationService>(mockConv);
    getIt.registerSingleton<ForkService>(mockFork);
  });

  tearDown(() async {
    await resetForTesting();
  });

  Conversation stubConv(String id) {
    final now = DateTime.now();
    return Conversation(
      id: id,
      title: 'T',
      noteIds: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  testWidgets('renders message list for the given conversationId',
      (tester) async {
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => stubConv('conv-1'));
    when(mockConv.getConversationMessages('conv-1')).thenAnswer((_) async => [
          ConversationMessage(
            id: 'm1',
            conversationId: 'conv-1',
            type: MessageType.user,
            content: 'Hello',
            timestamp: DateTime.now(),
          ),
          ConversationMessage(
            id: 'm2',
            conversationId: 'conv-1',
            type: MessageType.ai,
            content: 'Hi back',
            timestamp: DateTime.now(),
          ),
        ]);
    when(mockConv.getAllForkPointBranches('conv-1'))
        .thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, __) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hello'), findsOneWidget);
    expect(find.textContaining('Hi back'), findsOneWidget);
  });

  testWidgets('renders contextCard pinned at top when provided',
      (tester) async {
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => stubConv('conv-1'));
    when(mockConv.getConversationMessages('conv-1'))
        .thenAnswer((_) async => const []);
    when(mockConv.getAllForkPointBranches('conv-1'))
        .thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, __) async {},
          contextCard: const Text('CONTEXT_CARD_MARKER'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('CONTEXT_CARD_MARKER'), findsOneWidget);
  });

  testWidgets('renders MessageBranchStrip below messages with multiple children', (tester) async {
    final now = DateTime.now();
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => Conversation(
              id: 'conv-1', title: 'T', noteIds: const ['note-X'],
              createdAt: now, updatedAt: now,
            ));
    when(mockConv.getConversationMessages('conv-1'))
        .thenAnswer((_) async => [
              ConversationMessage(
                id: 'm1', conversationId: 'conv-1',
                type: MessageType.user, content: 'Q?',
                timestamp: now,
              ),
            ]);
    when(mockConv.getAllForkPointBranches('conv-1'))
        .thenAnswer((_) async => {
              'm1': [
                ConversationBranchSummary(
                  conversationId: 'child-a', title: 'Child A',
                  forkPointMessageId: 'm1', firstChildMessageId: 'cm1',
                  noteIds: const ['note-X'],
                ),
                ConversationBranchSummary(
                  conversationId: 'child-b', title: 'Child B',
                  forkPointMessageId: 'm1', firstChildMessageId: 'cm2',
                  noteIds: const ['note-X'],
                ),
              ],
            });
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, __) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Child A'), findsOneWidget);
    expect(find.text('Child B'), findsOneWidget);
  });

  testWidgets('chip tap fires ChipTapHandler with onSendUserPrompt', (tester) async {
    final now = DateTime.now();
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => Conversation(
              id: 'conv-1', title: 'T', noteIds: const [],
              createdAt: now, updatedAt: now,
            ));
    final aiMsg = ConversationMessage(
      id: 'mAI', conversationId: 'conv-1',
      type: MessageType.ai,
      content: '''Reply.
```chips
## explain X
You are a tutor. Explain X.
```''',
      timestamp: now,
    );
    when(mockConv.getConversationMessages('conv-1'))
        .thenAnswer((_) async => [aiMsg]);
    when(mockConv.getAllForkPointBranches('conv-1'))
        .thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(true);
    // Stub a skill index containing a default-action skill so chips render.
    final stubMeta = const SkillMetadata(
      noteId: 'n', skillRef: 's', name: 'S', description: 'd',
      enabled: true, defaultAction: 'something',
    );
    when(mockConv.skillIndex).thenReturn({'n': stubMeta});
    when(mockFork.forkFromMessageInContext(
      forkFromMessageId: anyNamed('forkFromMessageId'),
      sourceConversationId: anyNamed('sourceConversationId'),
      suggestedTitle: anyNamed('suggestedTitle'),
    )).thenAnswer((_) async => Conversation(
          id: 'forked', title: 'explain X', noteIds: const [],
          createdAt: now, updatedAt: now,
        ));
    when(mockConv.addUserMessage(
      conversationId: anyNamed('conversationId'),
      content: anyNamed('content'),
    )).thenAnswer((_) async => ConversationMessage(
          id: 'umsg', conversationId: 'forked',
          type: MessageType.user, content: 'You are a tutor. Explain X.',
          timestamp: now,
        ));

    String? sentPrompt;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, p) async => sentPrompt = p,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('explain X'));
    await tester.pumpAndSettle();
    expect(sentPrompt, 'You are a tutor. Explain X.');
  });
}
