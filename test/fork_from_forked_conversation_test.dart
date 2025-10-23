import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';

void main() {
  group('Fork from Forked Conversation Tests', () {
    late ConversationService conversationService;

    setUp(() {
      conversationService = ConversationService();
    });

    test('should fork from a forked conversation without throwing "Fork message not found"', () async {
      // Given: Initial conversation structure ROOT -> A -> B
      // Create original conversation
      final originalConversation = await conversationService.createConversation(
        title: 'Original Conversation',
      );

      // Add interaction A (user + AI)
      final userMessageA = await conversationService.addUserMessage(
        conversationId: originalConversation.id,
        content: 'Question A',
      );
      final aiMessageA = await conversationService.addAIResponse(
        conversationId: originalConversation.id,
        content: 'Answer A',
        modelUsed: 'gpt-4',
      );

      // Add interaction B (user + AI) 
      await conversationService.addUserMessage(
        conversationId: originalConversation.id,
        content: 'Question B',
      );
      final aiMessageB = await conversationService.addAIResponse(
        conversationId: originalConversation.id,
        content: 'Answer B',
        modelUsed: 'gpt-4',
      );

      // Fork from A (creates forked conversation)
      final forkedConversation = await conversationService.forkConversation(
        originalConversationId: originalConversation.id,
        forkFromMessageId: aiMessageA.id, // Fork from AI message A
        newTitle: 'Forked Conversation A',
      );

      // Add interaction C to the forked conversation (user + AI)
      await conversationService.addUserMessage(
        conversationId: forkedConversation.id,
        content: 'Question C',
      );
      final aiMessageC = await conversationService.addAIResponse(
        conversationId: forkedConversation.id,
        content: 'Answer C',
        modelUsed: 'gpt-4',
      );

      // When: Try to fork from the forked conversation at message A
      // This should NOT throw "Fork message not found" exception
      Conversation? secondForkedConversation;
      Exception? caughtException;

      try {
        secondForkedConversation = await conversationService.forkConversation(
          originalConversationId: forkedConversation.id, // Forking from the forked conversation
          forkFromMessageId: aiMessageA.id, // Trying to fork from message A (which exists in forked conversation)
          newTitle: 'Second Forked Conversation',
        );
      } catch (e) {
        caughtException = e as Exception;
      }

      // Then: The fork should succeed without throwing "Fork message not found"
      expect(caughtException, isNull, reason: 'Should not throw "Fork message not found" exception');
      expect(secondForkedConversation, isNotNull, reason: 'Second forked conversation should be created');
      expect(secondForkedConversation!.title, equals('Second Forked Conversation'));
      expect(secondForkedConversation.parentConversationId, equals(forkedConversation.id));
      expect(secondForkedConversation.forkFromMessageId, equals(aiMessageA.id));
    });

    test('should handle forking from forked conversation with correct message lookup', () async {
      // This test verifies that when forking from a forked conversation,
      // the system correctly looks for the message in the forked conversation,
      // not in the original conversation

      // Create original conversation with messages
      final originalConversation = await conversationService.createConversation(
        title: 'Original',
      );

      final userMsg = await conversationService.addUserMessage(
        conversationId: originalConversation.id,
        content: 'Original question',
      );
      final aiMsg = await conversationService.addAIResponse(
        conversationId: originalConversation.id,
        content: 'Original answer',
      );

      // Fork the conversation
      final forkedConversation = await conversationService.forkConversation(
        originalConversationId: originalConversation.id,
        forkFromMessageId: aiMsg.id,
        newTitle: 'Forked',
      );

      // Add new messages to the forked conversation
      final forkedUserMsg = await conversationService.addUserMessage(
        conversationId: forkedConversation.id,
        content: 'Forked question',
      );
      final forkedAiMsg = await conversationService.addAIResponse(
        conversationId: forkedConversation.id,
        content: 'Forked answer',
      );

      // Now try to fork from the forked conversation using the forked message
      // This should work because we're looking in the correct conversation
      Conversation? secondFork;
      Exception? exception;

      try {
        secondFork = await conversationService.forkConversation(
          originalConversationId: forkedConversation.id,
          forkFromMessageId: forkedAiMsg.id, // This message exists in forkedConversation
          newTitle: 'Second Fork',
        );
      } catch (e) {
        exception = e as Exception;
      }

      expect(exception, isNull, reason: 'Should not throw exception when forking from forked conversation');
      expect(secondFork, isNotNull);
      expect(secondFork!.parentConversationId, equals(forkedConversation.id));
      expect(secondFork.forkFromMessageId, equals(forkedAiMsg.id));
    });

    test('should throw exception when trying to fork from non-existent message', () async {
      // Create a conversation
      final conversation = await conversationService.createConversation(
        title: 'Test Conversation',
      );

      // Try to fork from a non-existent message ID
      Exception? caughtException;
      try {
        await conversationService.forkConversation(
          originalConversationId: conversation.id,
          forkFromMessageId: 'non-existent-message-id',
          newTitle: 'Should Fail',
        );
      } catch (e) {
        caughtException = e as Exception;
      }

      expect(caughtException, isNotNull);
      expect(caughtException.toString(), contains('Fork message not found'));
    });
  });
}
