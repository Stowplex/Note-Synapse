import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_branch_summary.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/chat_tool_session.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/fork_service.dart';
import 'package:note_synapse/services/marker_chat_send_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/marker_chat_panel_host.dart';
import 'package:provider/provider.dart';

import 'marker_chat_panel_host_test.mocks.dart';

/// Test double for [MarkerChatSendService] that records the prompts the host
/// hands off and immediately invokes the [onCompleted] callback so the
/// host's `_isSending` latch resets cleanly.
class _RecordingMarkerSendService implements MarkerChatSendService {
  final List<String> sentPrompts = [];
  final List<String> continuedConversations = [];
  Completer<void>? continueCompleter;
  bool emitEmptyChunk = false;
  bool emitPartialChunk = false;

  @override
  Future<void> sendNewUserPrompt({
    required String conversationId,
    required String prompt,
    required AgentService agentService,
    ChatToolSession? toolSession,
    BuildContext? toolContext,
    ModelConfig? modelOverride,
    int? currentPdfPage,
    required void Function(String chunk) onStreamChunk,
    required void Function() onCompleted,
  }) async {
    sentPrompts.add(prompt);
    onCompleted();
  }

  @override
  Future<void> sendUserPrompt({
    required String conversationId,
    required String prompt,
    required AgentService agentService,
    ChatToolSession? toolSession,
    BuildContext? toolContext,
    ModelConfig? modelOverride,
    int? currentPdfPage,
    required void Function(String chunk) onStreamChunk,
    required void Function() onCompleted,
  }) {
    return sendNewUserPrompt(
      conversationId: conversationId,
      prompt: prompt,
      agentService: agentService,
      toolSession: toolSession,
      toolContext: toolContext,
      modelOverride: modelOverride,
      currentPdfPage: currentPdfPage,
      onStreamChunk: onStreamChunk,
      onCompleted: onCompleted,
    );
  }

  @override
  Future<void> continueAfterExistingUserPrompt({
    required String conversationId,
    required AgentService agentService,
    ChatToolSession? toolSession,
    BuildContext? toolContext,
    ModelConfig? modelOverride,
    int? currentPdfPage,
    required void Function(String chunk) onStreamChunk,
    required void Function() onCompleted,
  }) async {
    continuedConversations.add(conversationId);
    if (emitEmptyChunk) onStreamChunk('');
    if (emitPartialChunk) onStreamChunk('partial');
    if (continueCompleter != null) {
      await continueCompleter!.future;
    }
    onCompleted();
  }

  @override
  void cancelRequest(String requestId) {}

  // The fake doesn't need to implement the private helpers; noSuchMethod
  // catches any unexpected access during these widget tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@GenerateMocks([
  ConversationService,
  ForkService,
  ModelStorageService,
  AgentService,
])
void main() {
  late MockConversationService mockConv;
  late MockForkService mockFork;
  late MockModelStorageService mockModelStorage;
  late MockAgentService mockAgent;
  late _RecordingMarkerSendService fakeSendService;

  setUp(() async {
    await resetForTesting();
    mockConv = MockConversationService();
    mockFork = MockForkService();
    mockModelStorage = MockModelStorageService();
    mockAgent = MockAgentService();
    fakeSendService = _RecordingMarkerSendService();
    when(mockFork.forkCreatedStream).thenAnswer((_) => const Stream.empty());
    when(
      mockModelStorage.getConfiguredModels(),
    ).thenAnswer((_) async => const []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    final now = DateTime.now();
    when(mockConv.getConversation(any)).thenAnswer(
      (_) async => Conversation(
        id: 'c',
        title: 'T',
        noteIds: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );
    when(
      mockConv.getConversationMessages(any),
    ).thenAnswer((_) async => const []);
    when(
      mockConv.addUserMessage(
        conversationId: anyNamed('conversationId'),
        content: anyNamed('content'),
      ),
    ).thenAnswer(
      (invocation) async => ConversationMessage(
        id: 'user-new',
        conversationId: invocation.namedArguments[#conversationId] as String,
        type: MessageType.user,
        content: invocation.namedArguments[#content] as String,
        timestamp: DateTime.now(),
      ),
    );
    when(
      mockConv.getAllForkPointBranches(any),
    ).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});
    getIt.registerSingleton<ConversationService>(mockConv);
    getIt.registerSingleton<ForkService>(mockFork);
    getIt.registerSingleton<ModelStorageService>(mockModelStorage);
    getIt.registerSingleton<MarkerChatSendService>(fakeSendService);
  });

  tearDown(() async {
    await resetForTesting();
  });

  InNoteMarker stubMarker() => InNoteMarker.forNote(
    index: 0,
    charStart: 0,
    charEnd: 5,
    conversationId: 'c',
    messageId: 'm',
  );

  Widget hostUnderTest() => ChangeNotifierProvider<AgentService>.value(
    value: mockAgent,
    child: MaterialApp(
      home: Scaffold(
        body: MarkerChatPanelHost(
          marker: stubMarker(),
          resolvedConversationId: 'c',
          contextCard: const SizedBox.shrink(),
          onActiveConversationChanged: (_) {},
        ),
      ),
    ),
  );

  testWidgets('renders ChatPanel + text field + send button', (tester) async {
    await tester.pumpWidget(hostUnderTest());
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets(
    'typing then tapping send persists prompt and continues existing conversation',
    (tester) async {
      await tester.pumpWidget(hostUnderTest());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(
        find.text('hello'),
        findsNothing,
        reason: 'Input should be cleared after send',
      );
      verify(
        mockConv.addUserMessage(conversationId: 'c', content: 'hello'),
      ).called(1);
      expect(fakeSendService.sentPrompts, isEmpty);
      expect(fakeSendService.continuedConversations, ['c']);
    },
  );

  testWidgets(
    'typed follow-up appears while request is in flight without blank AI tail',
    (tester) async {
      final now = DateTime.now();
      final messages = <ConversationMessage>[];
      fakeSendService.continueCompleter = Completer<void>();
      when(
        mockConv.addUserMessage(
          conversationId: anyNamed('conversationId'),
          content: anyNamed('content'),
        ),
      ).thenAnswer((invocation) async {
        final message = ConversationMessage(
          id: 'user-new',
          conversationId: invocation.namedArguments[#conversationId] as String,
          type: MessageType.user,
          content: invocation.namedArguments[#content] as String,
          timestamp: now,
        );
        messages.add(message);
        return message;
      });
      when(
        mockConv.getConversationMessages(any),
      ).thenAnswer((_) async => List<ConversationMessage>.from(messages));

      await tester.pumpWidget(hostUnderTest());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'show more');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      expect(find.text('show more'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat_panel_streaming_message')),
        findsNothing,
      );

      fakeSendService.continueCompleter!.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('empty stream chunk does not render a blank AI tail', (
    tester,
  ) async {
    fakeSendService.continueCompleter = Completer<void>();
    fakeSendService.emitEmptyChunk = true;

    await tester.pumpWidget(hostUnderTest());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('chat_panel_streaming_message')),
      findsNothing,
    );

    fakeSendService.continueCompleter!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('model picker uses send-button dropdown affordance', (
    tester,
  ) async {
    await tester.pumpWidget(hostUnderTest());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.psychology), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  testWidgets('empty input — tapping send is a no-op (no error)', (
    tester,
  ) async {
    await tester.pumpWidget(hostUnderTest());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    // No exception thrown; widget still renders.
    expect(find.byType(TextField), findsOneWidget);
    expect(fakeSendService.sentPrompts, isEmpty);
  });

  testWidgets(
    'branch switch updates active ChatPanel conversation and persists',
    (tester) async {
      final now = DateTime.now();
      when(mockConv.getConversation('c')).thenAnswer(
        (_) async => Conversation(
          id: 'c',
          title: 'Source',
          noteIds: const [],
          createdAt: now,
          updatedAt: now,
        ),
      );
      when(mockConv.getConversation('branch')).thenAnswer(
        (_) async => Conversation(
          id: 'branch',
          title: 'Branch',
          noteIds: const [],
          createdAt: now,
          updatedAt: now,
        ),
      );
      when(mockConv.getConversationMessages(any)).thenAnswer(
        (_) async => [
          ConversationMessage(
            id: 'm',
            conversationId: 'c',
            type: MessageType.ai,
            content: 'Answer',
            timestamp: now,
          ),
        ],
      );
      when(mockConv.getAllForkPointBranches('c')).thenAnswer(
        (_) async => {
          'm': const [
            ConversationBranchSummary(
              conversationId: 'branch',
              title: 'Branch',
              forkPointMessageId: 'm',
              firstChildMessageId: 'branch-user',
              noteIds: [],
            ),
          ],
        },
      );
      when(
        mockConv.getAllForkPointBranches('branch'),
      ).thenAnswer((_) async => const {});

      String? persisted;
      await tester.pumpWidget(
        ChangeNotifierProvider<AgentService>.value(
          value: mockAgent,
          child: MaterialApp(
            home: Scaffold(
              body: MarkerChatPanelHost(
                marker: stubMarker(),
                resolvedConversationId: 'c',
                contextCard: const SizedBox.shrink(),
                onActiveConversationChanged: (id) => persisted = id,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Branch'));
      await tester.pumpAndSettle();

      expect(persisted, 'branch');
      verify(
        mockConv.getConversation('branch'),
      ).called(greaterThanOrEqualTo(1));
    },
  );
}
