import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/chip_action.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/chip_tap_handler.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/fork_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'chip_tap_handler_test.mocks.dart';

@GenerateMocks([ConversationService, ForkService])
void main() {
  late MockConversationService mockConv;
  late MockForkService mockFork;

  setUp(() async {
    await resetForTesting();
    mockConv = MockConversationService();
    mockFork = MockForkService();
    getIt.registerSingleton<ConversationService>(mockConv);
    getIt.registerSingleton<ForkService>(mockFork);
  });

  tearDown(() async {
    await resetForTesting();
  });

  ConversationMessage stubMsg(String id, String content) {
    return ConversationMessage(
      id: id,
      conversationId: 'forked-id',
      type: MessageType.user,
      content: content,
      timestamp: DateTime.now(),
    );
  }

  Conversation stubConv(String id, String title) {
    final now = DateTime.now();
    return Conversation(
      id: id,
      title: title,
      noteIds: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  test(
    'handle() forks with pending title, adds user message with chip.prompt, and returns fork',
    () async {
      const chip = ChipAction(
        label: 'explain X',
        prompt: 'You are a tutor. Explain X.',
      );
      when(
        mockFork.forkFromMessageInContext(
          forkFromMessageId: anyNamed('forkFromMessageId'),
          sourceConversationId: anyNamed('sourceConversationId'),
          suggestedTitle: anyNamed('suggestedTitle'),
        ),
      ).thenAnswer((_) async => stubConv('forked-id', 'Forked conversation'));
      when(
        mockConv.addUserMessage(
          conversationId: anyNamed('conversationId'),
          content: anyNamed('content'),
        ),
      ).thenAnswer(
        (_) async => stubMsg('msg-1', 'You are a tutor. Explain X.'),
      );

      final handler = ChipTapHandler();
      final forked = await handler.handle(
        parentMessageId: 'parent-msg',
        chip: chip,
        sourceConversationId: 'src-conv',
      );

      expect(forked?.id, 'forked-id');
      verify(
        mockFork.forkFromMessageInContext(
          forkFromMessageId: 'parent-msg',
          sourceConversationId: 'src-conv',
          suggestedTitle: 'Forked conversation',
        ),
      ).called(1);
      verify(
        mockConv.addUserMessage(
          conversationId: 'forked-id',
          content: 'You are a tutor. Explain X.',
        ),
      ).called(1);
    },
  );

  test(
    'handle() short-circuits if fork returns null — no addUserMessage',
    () async {
      const chip = ChipAction(label: 'l', prompt: 'p');
      when(
        mockFork.forkFromMessageInContext(
          forkFromMessageId: anyNamed('forkFromMessageId'),
          sourceConversationId: anyNamed('sourceConversationId'),
          suggestedTitle: anyNamed('suggestedTitle'),
        ),
      ).thenAnswer((_) async => null);

      final handler = ChipTapHandler();
      final forked = await handler.handle(
        parentMessageId: 'parent',
        chip: chip,
        sourceConversationId: 'src',
      );

      verifyNever(
        mockConv.addUserMessage(
          conversationId: anyNamed('conversationId'),
          content: anyNamed('content'),
        ),
      );
      expect(forked, isNull);
    },
  );

  test(
    'handle() rethrows if forkFromMessageInContext throws (unexpected error)',
    () async {
      const chip = ChipAction(label: 'l', prompt: 'p');
      when(
        mockFork.forkFromMessageInContext(
          forkFromMessageId: anyNamed('forkFromMessageId'),
          sourceConversationId: anyNamed('sourceConversationId'),
          suggestedTitle: anyNamed('suggestedTitle'),
        ),
      ).thenThrow(Exception('DB went sideways'));

      final handler = ChipTapHandler();
      // Pass the Future directly to expect (not a synchronous lambda) so the
      // matcher actually awaits it. A wrapped-in-lambda form would silently
      // pass even if the rethrow behavior were removed.
      await expectLater(
        handler.handle(
          parentMessageId: 'parent',
          chip: chip,
          sourceConversationId: 'src',
        ),
        throwsA(isA<Exception>()),
      );
    },
  );
}
