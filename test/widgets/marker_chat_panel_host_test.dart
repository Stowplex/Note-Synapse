import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/services/agent_service.dart';
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

  @override
  Future<void> sendUserPrompt({
    required String conversationId,
    required String prompt,
    required AgentService agentService,
    ModelConfig? modelOverride,
    required void Function(String chunk) onStreamChunk,
    required void Function() onCompleted,
  }) async {
    sentPrompts.add(prompt);
    onCompleted();
  }

  @override
  void cancelRequest(String requestId) {}

  // The fake doesn't need to implement the private helpers; noSuchMethod
  // catches any unexpected access during these widget tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@GenerateMocks([ConversationService, ForkService, ModelStorageService, AgentService])
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
    when(mockModelStorage.getConfiguredModels())
        .thenAnswer((_) async => const []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    final now = DateTime.now();
    when(mockConv.getConversation(any)).thenAnswer((_) async => Conversation(
          id: 'c',
          title: 'T',
          noteIds: const [],
          createdAt: now,
          updatedAt: now,
        ));
    when(mockConv.getConversationMessages(any))
        .thenAnswer((_) async => const []);
    when(mockConv.getAllForkPointBranches(any))
        .thenAnswer((_) async => const {});
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

  testWidgets('typing then tapping send clears the field and forwards to send service',
      (tester) async {
    await tester.pumpWidget(hostUnderTest());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsNothing,
        reason: 'Input should be cleared after send');
    expect(fakeSendService.sentPrompts, ['hello']);
  });

  testWidgets('empty input — tapping send is a no-op (no error)',
      (tester) async {
    await tester.pumpWidget(hostUnderTest());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    // No exception thrown; widget still renders.
    expect(find.byType(TextField), findsOneWidget);
    expect(fakeSendService.sentPrompts, isEmpty);
  });
}
