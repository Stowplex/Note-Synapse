import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_branch_summary.dart';
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

  testWidgets('renders message list for the given conversationId', (
    tester,
  ) async {
    when(
      mockConv.getConversation('conv-1'),
    ).thenAnswer((_) async => stubConv('conv-1'));
    when(mockConv.getConversationMessages('conv-1')).thenAnswer(
      (_) async => [
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
      ],
    );
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Hello'), findsOneWidget);
    expect(find.textContaining('Hi back'), findsOneWidget);
  });

  testWidgets('renders contextCard pinned at top when provided', (
    tester,
  ) async {
    when(
      mockConv.getConversation('conv-1'),
    ).thenAnswer((_) async => stubConv('conv-1'));
    when(
      mockConv.getConversationMessages('conv-1'),
    ).thenAnswer((_) async => const []);
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
            contextCard: const Text('CONTEXT_CARD_MARKER'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CONTEXT_CARD_MARKER'), findsOneWidget);
  });

  testWidgets(
    'renders MessageBranchStrip below messages with multiple children',
    (tester) async {
      final now = DateTime.now();
      when(mockConv.getConversation('conv-1')).thenAnswer(
        (_) async => Conversation(
          id: 'conv-1',
          title: 'T',
          noteIds: const ['note-X'],
          createdAt: now,
          updatedAt: now,
        ),
      );
      when(mockConv.getConversationMessages('conv-1')).thenAnswer(
        (_) async => [
          ConversationMessage(
            id: 'm1',
            conversationId: 'conv-1',
            type: MessageType.user,
            content: 'Q?',
            timestamp: now,
          ),
        ],
      );
      when(mockConv.getAllForkPointBranches('conv-1')).thenAnswer(
        (_) async => {
          'm1': [
            ConversationBranchSummary(
              conversationId: 'child-a',
              title: 'Child A',
              forkPointMessageId: 'm1',
              firstChildMessageId: 'cm1',
              noteIds: const ['note-X'],
            ),
            ConversationBranchSummary(
              conversationId: 'child-b',
              title: 'Child B',
              forkPointMessageId: 'm1',
              firstChildMessageId: 'cm2',
              noteIds: const ['note-X'],
            ),
          ],
        },
      );
      when(mockConv.skillsEnabled).thenReturn(false);
      when(mockConv.skillIndex).thenReturn(const {});

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPanel(
              conversationId: 'conv-1',
              isStreaming: false,
              onActiveConversationChanged: (_, __) {},
              onSendUserPrompt: (_, __) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Child A'), findsOneWidget);
      expect(find.text('Child B'), findsOneWidget);
    },
  );

  testWidgets('renders active branch plus one sibling and highlights active', (
    tester,
  ) async {
    final now = DateTime.now();
    when(mockConv.getConversation('conv-1')).thenAnswer(
      (_) async => Conversation(
        id: 'conv-1',
        title: 'Current',
        noteIds: const ['note-X'],
        createdAt: now,
        updatedAt: now,
      ),
    );
    when(mockConv.getConversationMessages('conv-1')).thenAnswer(
      (_) async => [
        ConversationMessage(
          id: 'm1',
          conversationId: 'conv-1',
          type: MessageType.ai,
          content: 'A',
          timestamp: now,
        ),
      ],
    );
    when(mockConv.getAllForkPointBranches('conv-1')).thenAnswer(
      (_) async => {
        'm1': const [
          ConversationBranchSummary(
            conversationId: 'child-a',
            title: 'Child A',
            forkPointMessageId: 'm1',
            firstChildMessageId: 'cm1',
            noteIds: ['note-X'],
          ),
        ],
      },
    );
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Child A'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('branch-row-active-conv-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'chip tap switches to forked conversation before onSendUserPrompt',
    (tester) async {
      final now = DateTime.now();
      when(mockConv.getConversation('conv-1')).thenAnswer(
        (_) async => Conversation(
          id: 'conv-1',
          title: 'T',
          noteIds: const [],
          createdAt: now,
          updatedAt: now,
        ),
      );
      final aiMsg = ConversationMessage(
        id: 'mAI',
        conversationId: 'conv-1',
        type: MessageType.ai,
        content: '''Reply.
```chips
## explain X
You are a tutor. Explain X.
```''',
        timestamp: now,
      );
      when(
        mockConv.getConversationMessages('conv-1'),
      ).thenAnswer((_) async => [aiMsg]);
      when(
        mockConv.getAllForkPointBranches('conv-1'),
      ).thenAnswer((_) async => const {});
      when(mockConv.skillsEnabled).thenReturn(false);
      when(mockConv.skillIndex).thenReturn(const {});
      when(
        mockFork.forkFromMessageInContext(
          forkFromMessageId: anyNamed('forkFromMessageId'),
          sourceConversationId: anyNamed('sourceConversationId'),
          suggestedTitle: anyNamed('suggestedTitle'),
        ),
      ).thenAnswer(
        (_) async => Conversation(
          id: 'forked',
          title: 'explain X',
          noteIds: const [],
          createdAt: now,
          updatedAt: now,
        ),
      );
      when(
        mockConv.addUserMessage(
          conversationId: anyNamed('conversationId'),
          content: anyNamed('content'),
        ),
      ).thenAnswer(
        (_) async => ConversationMessage(
          id: 'umsg',
          conversationId: 'forked',
          type: MessageType.user,
          content: 'You are a tutor. Explain X.',
          timestamp: now,
        ),
      );

      String? switchedConversation;
      String? switchedForkPoint;
      String? sentConversation;
      String? sentPrompt;
      final events = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPanel(
              conversationId: 'conv-1',
              isStreaming: false,
              onActiveConversationChanged: (id, forkPoint) async {
                events.add('switch');
                switchedConversation = id;
                switchedForkPoint = forkPoint;
              },
              onSendUserPrompt: (id, p) async {
                events.add('send');
                sentConversation = id;
                sentPrompt = p;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('explain X'));
      await tester.pumpAndSettle();
      expect(switchedConversation, 'forked');
      expect(switchedForkPoint, 'mAI');
      expect(sentConversation, 'forked');
      expect(sentPrompt, 'You are a tutor. Explain X.');
      expect(events, ['switch', 'send']);
    },
  );

  testWidgets('manual fork button creates fork and asks host to switch', (
    tester,
  ) async {
    final now = DateTime.now();
    when(mockConv.getConversation('conv-1')).thenAnswer(
      (_) async => Conversation(
        id: 'conv-1',
        title: 'T',
        noteIds: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );
    final aiMsg = ConversationMessage(
      id: 'mAI',
      conversationId: 'conv-1',
      type: MessageType.ai,
      content: 'Reply.',
      timestamp: now,
    );
    when(
      mockConv.getConversationMessages('conv-1'),
    ).thenAnswer((_) async => [aiMsg]);
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});
    when(
      mockFork.forkFromMessageInContext(
        forkFromMessageId: 'mAI',
        sourceConversationId: 'conv-1',
        suggestedTitle: 'Forked conversation',
      ),
    ).thenAnswer(
      (_) async => Conversation(
        id: 'forked',
        title: 'Forked conversation',
        noteIds: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );

    String? switchedConversation;
    String? switchedForkPoint;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (id, forkPoint) {
              switchedConversation = id;
              switchedForkPoint = forkPoint;
            },
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fork from here'));
    await tester.pumpAndSettle();

    expect(switchedConversation, 'forked');
    expect(switchedForkPoint, 'mAI');
  });

  testWidgets('manual fork button is disabled while streaming', (tester) async {
    final now = DateTime.now();
    when(
      mockConv.getConversation('conv-1'),
    ).thenAnswer((_) async => stubConv('conv-1'));
    when(mockConv.getConversationMessages('conv-1')).thenAnswer(
      (_) async => [
        ConversationMessage(
          id: 'mAI',
          conversationId: 'conv-1',
          type: MessageType.ai,
          content: 'Reply.',
          timestamp: now,
        ),
      ],
    );
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: true,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('chat_panel_manual_fork_mAI')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('scrolls to initialMessageId on mount', (tester) async {
    final now = DateTime.now();
    when(mockConv.getConversation('conv-1')).thenAnswer(
      (_) async => Conversation(
        id: 'conv-1',
        title: 'T',
        noteIds: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );
    final messages = List.generate(
      40,
      (i) => ConversationMessage(
        id: 'm$i',
        conversationId: 'conv-1',
        type: i.isEven ? MessageType.user : MessageType.ai,
        content: 'Message $i',
        timestamp: now,
      ),
    );
    when(
      mockConv.getConversationMessages('conv-1'),
    ).thenAnswer((_) async => messages);
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            initialMessageId: 'm20',
            isStreaming: false,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Message 20'), findsOneWidget);
    expect(find.text('Message 0'), findsNothing);
  });

  testWidgets('refreshes branches when forkCreatedStream emits', (
    tester,
  ) async {
    final controller = StreamController<String>.broadcast();
    addTearDown(controller.close);
    when(mockFork.forkCreatedStream).thenAnswer((_) => controller.stream);
    final now = DateTime.now();
    when(mockConv.getConversation('conv-1')).thenAnswer(
      (_) async => Conversation(
        id: 'conv-1',
        title: 'T',
        noteIds: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );
    when(mockConv.getConversationMessages('conv-1')).thenAnswer(
      (_) async => [
        ConversationMessage(
          id: 'm1',
          conversationId: 'conv-1',
          type: MessageType.user,
          content: 'Q?',
          timestamp: now,
        ),
      ],
    );
    int callCount = 0;
    when(mockConv.getAllForkPointBranches('conv-1')).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) return const {};
      return {
        'm1': [
          const ConversationBranchSummary(
            conversationId: 'new-child',
            title: 'New Child',
            forkPointMessageId: 'm1',
            firstChildMessageId: 'cm',
            noteIds: [],
          ),
          const ConversationBranchSummary(
            conversationId: 'sibling',
            title: 'Sibling',
            forkPointMessageId: 'm1',
            firstChildMessageId: 'cm2',
            noteIds: [],
          ),
        ],
      };
    });
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New Child'), findsNothing);
    controller.add('m1');
    await tester.pumpAndSettle();
    expect(find.text('New Child'), findsOneWidget);
    expect(find.text('Sibling'), findsOneWidget);
  });

  testWidgets(
    'shows streaming bubble at tail when streamingContent is non-empty',
    (tester) async {
      final now = DateTime.now();
      when(
        mockConv.getConversation('conv-1'),
      ).thenAnswer((_) async => stubConv('conv-1'));
      when(mockConv.getConversationMessages('conv-1')).thenAnswer(
        (_) async => [
          ConversationMessage(
            id: 'mAI',
            conversationId: 'conv-1',
            type: MessageType.ai,
            content: 'Already-finalized AI reply.',
            timestamp: now,
          ),
        ],
      );
      when(
        mockConv.getAllForkPointBranches('conv-1'),
      ).thenAnswer((_) async => const {});
      when(mockConv.skillsEnabled).thenReturn(false);
      when(mockConv.skillIndex).thenReturn(const {});

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPanel(
              conversationId: 'conv-1',
              isStreaming: true,
              streamingContent: 'LIVE_PARTIAL_TEXT',
              onActiveConversationChanged: (_, __) {},
              onSendUserPrompt: (_, __) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('LIVE_PARTIAL_TEXT'), findsOneWidget);
      // Sanity: the prior finalized message also still renders.
      expect(
        find.textContaining('Already-finalized AI reply.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('does not show streaming bubble for empty streamingContent', (
    tester,
  ) async {
    final now = DateTime.now();
    when(
      mockConv.getConversation('conv-1'),
    ).thenAnswer((_) async => stubConv('conv-1'));
    when(mockConv.getConversationMessages('conv-1')).thenAnswer(
      (_) async => [
        ConversationMessage(
          id: 'mAI',
          conversationId: 'conv-1',
          type: MessageType.ai,
          content: 'Already-finalized AI reply.',
          timestamp: now,
        ),
      ],
    );
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: true,
            streamingContent: '',
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('chat_panel_streaming_message')),
      findsNothing,
    );
    expect(find.textContaining('Already-finalized AI reply.'), findsOneWidget);
  });

  testWidgets(
    'shows tool-details icon when message has parts_history metadata',
    (tester) async {
      final now = DateTime.now();
      when(
        mockConv.getConversation('conv-1'),
      ).thenAnswer((_) async => stubConv('conv-1'));
      final aiMsg = ConversationMessage(
        id: 'mAI',
        conversationId: 'conv-1',
        type: MessageType.ai,
        content: 'Reply.',
        timestamp: now,
        metadata: const {
          'parts_history': [<String, dynamic>{}],
        },
      );
      when(
        mockConv.getConversationMessages('conv-1'),
      ).thenAnswer((_) async => [aiMsg]);
      when(
        mockConv.getAllForkPointBranches('conv-1'),
      ).thenAnswer((_) async => const {});
      when(mockConv.skillsEnabled).thenReturn(false);
      when(mockConv.skillIndex).thenReturn(const {});

      ConversationMessage? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPanel(
              conversationId: 'conv-1',
              isStreaming: false,
              onActiveConversationChanged: (_, __) {},
              onSendUserPrompt: (_, __) async {},
              onShowToolDetails: (m) => captured = m,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final iconFinder = find.byTooltip('View Tool Usage');
      expect(iconFinder, findsOneWidget);
      await tester.tap(iconFinder);
      await tester.pumpAndSettle();
      expect(captured?.id, 'mAI');
    },
  );

  testWidgets('reload() refetches messages and updates the rendered list', (
    tester,
  ) async {
    final now = DateTime.now();
    when(
      mockConv.getConversation('conv-1'),
    ).thenAnswer((_) async => stubConv('conv-1'));
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    var callCount = 0;
    when(mockConv.getConversationMessages('conv-1')).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) {
        return [
          ConversationMessage(
            id: 'm1',
            conversationId: 'conv-1',
            type: MessageType.user,
            content: 'first',
            timestamp: now,
          ),
        ];
      }
      return [
        ConversationMessage(
          id: 'm1',
          conversationId: 'conv-1',
          type: MessageType.user,
          content: 'first',
          timestamp: now,
        ),
        ConversationMessage(
          id: 'm2',
          conversationId: 'conv-1',
          type: MessageType.ai,
          content: 'second',
          timestamp: now,
        ),
      ];
    });

    final key = GlobalKey<ChatPanelState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            key: key,
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('first'), findsOneWidget);
    expect(find.textContaining('second'), findsNothing);

    await key.currentState!.reload();
    await tester.pumpAndSettle();
    expect(find.textContaining('first'), findsOneWidget);
    expect(find.textContaining('second'), findsOneWidget);
  });

  testWidgets('user message edit icon fires onUserMessageEdit when tapped', (
    tester,
  ) async {
    final now = DateTime.now();
    when(
      mockConv.getConversation('conv-1'),
    ).thenAnswer((_) async => stubConv('conv-1'));
    final userMsg = ConversationMessage(
      id: 'mU',
      conversationId: 'conv-1',
      type: MessageType.user,
      content: 'My question?',
      timestamp: now,
    );
    when(
      mockConv.getConversationMessages('conv-1'),
    ).thenAnswer((_) async => [userMsg]);
    when(
      mockConv.getAllForkPointBranches('conv-1'),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    ConversationMessage? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_, __) {},
            onSendUserPrompt: (_, __) async {},
            onUserMessageEdit: (m) => captured = m,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editFinder = find.byTooltip('Use this message');
    expect(editFinder, findsOneWidget);
    await tester.tap(editFinder);
    await tester.pumpAndSettle();
    expect(captured?.id, 'mU');
  });
}
