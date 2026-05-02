import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_context.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/fork_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'fork_service_test.mocks.dart';

@GenerateMocks([ConversationService])
void main() {
  late MockConversationService mockConv;

  setUp(() async {
    await resetForTesting();
    mockConv = MockConversationService();
    getIt.registerSingleton<ConversationService>(mockConv);
  });

  test('forkFromMessageInContext emits parentMessageId on forkCreatedStream',
      () async {
    final now = DateTime.now();
    final fakeForked = Conversation(
      id: 'forked-id',
      title: 'Fork',
      noteIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    final fakeContext = ConversationContext(
      conversationId: 'src-conv',
      title: 'Source',
      noteIds: const [],
      notes: const [],
      createdAt: now,
      messageCount: 0,
    );
    final selection = ForkContextSelection(
      forkMessageId: 'parent-msg',
      availableContexts: [fakeContext],
      selectedContext: fakeContext,
    );
    when(mockConv.prepareForkContextSelection('parent-msg'))
        .thenAnswer((_) async => selection);
    when(
      mockConv.forkConversationWithContext(
        forkFromMessageId: anyNamed('forkFromMessageId'),
        selectedContext: anyNamed('selectedContext'),
        newTitle: anyNamed('newTitle'),
      ),
    ).thenAnswer((_) async => fakeForked);

    final service = ForkService();
    final emissions = <String>[];
    final sub = service.forkCreatedStream.listen(emissions.add);

    final result = await service.forkFromMessageInContext(
      forkFromMessageId: 'parent-msg',
      sourceConversationId: 'src-conv',
      suggestedTitle: 'My new branch',
    );

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(result, isNotNull);
    expect(result!.id, 'forked-id');
    expect(emissions, ['parent-msg']);
  });

  test(
      'forkFromMessageInContext returns null when source conversation does not contain the message',
      () async {
    final now = DateTime.now();
    final fakeContext = ConversationContext(
      conversationId: 'other-conv',
      title: 'Other',
      noteIds: const [],
      notes: const [],
      createdAt: now,
      messageCount: 0,
    );
    when(mockConv.prepareForkContextSelection('parent-msg')).thenAnswer(
      (_) async => ForkContextSelection(
        forkMessageId: 'parent-msg',
        availableContexts: [fakeContext],
      ),
    );

    final service = ForkService();
    final emissions = <String>[];
    final sub = service.forkCreatedStream.listen(emissions.add);

    final result = await service.forkFromMessageInContext(
      forkFromMessageId: 'parent-msg',
      sourceConversationId: 'nonexistent-conv',
      suggestedTitle: 'X',
    );

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(result, isNull);
    expect(emissions, isEmpty);
  });
}
