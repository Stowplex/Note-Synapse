import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/fork_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/marker_chat_panel_host.dart';

import 'marker_chat_panel_host_test.mocks.dart';

@GenerateMocks([ConversationService, ForkService, ModelStorageService])
void main() {
  late MockConversationService mockConv;
  late MockForkService mockFork;
  late MockModelStorageService mockModelStorage;

  setUp(() async {
    await resetForTesting();
    mockConv = MockConversationService();
    mockFork = MockForkService();
    mockModelStorage = MockModelStorageService();
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

  testWidgets('renders ChatPanel + text field + send button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkerChatPanelHost(
          marker: stubMarker(),
          resolvedConversationId: 'c',
          contextCard: const SizedBox.shrink(),
          onActiveConversationChanged: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('typing then tapping send clears the field', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkerChatPanelHost(
          marker: stubMarker(),
          resolvedConversationId: 'c',
          contextCard: const SizedBox.shrink(),
          onActiveConversationChanged: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsNothing,
        reason: 'Input should be cleared after send');
  });

  testWidgets('empty input — tapping send is a no-op (no error)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkerChatPanelHost(
          marker: stubMarker(),
          resolvedConversationId: 'c',
          contextCard: const SizedBox.shrink(),
          onActiveConversationChanged: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    // No exception thrown; widget still renders.
    expect(find.byType(TextField), findsOneWidget);
  });
}
