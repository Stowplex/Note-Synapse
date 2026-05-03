import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/fork_service.dart';
import 'package:note_synapse/services/service_locator.dart';
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
}
