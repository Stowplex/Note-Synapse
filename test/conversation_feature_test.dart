import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';

void main() {
  group('Conversation Feature Tests', () {
    late ConversationService conversationService;

    setUp(() {
      conversationService = ConversationService();
    });

    test('should create a new conversation', () async {
      final conversation = await conversationService.createConversation(
        title: 'Test Conversation',
        noteIds: ['note1', 'note2'],
      );

      expect(conversation.id, isNotEmpty);
      expect(conversation.title, equals('Test Conversation'));
      expect(conversation.noteIds, contains('note1'));
      expect(conversation.noteIds, contains('note2'));
      expect(conversation.parentConversationId, isNull);
      expect(conversation.forkFromMessageId, isNull);
    });

    test('should add user message to conversation', () async {
      final conversation = await conversationService.createConversation(
        title: 'Test Conversation',
      );

      final message = await conversationService.addUserMessage(
        conversationId: conversation.id,
        content: 'Hello, this is a test message',
      );

      expect(message.id, isNotEmpty);
      expect(message.conversationId, equals(conversation.id));
      expect(message.type, equals(MessageType.user));
      expect(message.content, equals('Hello, this is a test message'));
    });

    test('should add AI response to conversation', () async {
      final conversation = await conversationService.createConversation(
        title: 'Test Conversation',
      );

      final message = await conversationService.addAIResponse(
        conversationId: conversation.id,
        content: 'This is an AI response',
        modelUsed: 'gpt-4',
      );

      expect(message.id, isNotEmpty);
      expect(message.conversationId, equals(conversation.id));
      expect(message.type, equals(MessageType.ai));
      expect(message.content, equals('This is an AI response'));
      expect(message.modelUsed, equals('gpt-4'));
    });

    test('should fork conversation correctly', () async {
      // Create original conversation
      final originalConversation = await conversationService.createConversation(
        title: 'Original Conversation',
      );

      // Add some messages
      final userMessage = await conversationService.addUserMessage(
        conversationId: originalConversation.id,
        content: 'First message',
      );

      await conversationService.addAIResponse(
        conversationId: originalConversation.id,
        content: 'AI response to first message',
      );

      // Fork the conversation
      final forkedConversation = await conversationService.forkConversation(
        originalConversationId: originalConversation.id,
        forkFromMessageId: userMessage.id,
        newTitle: 'Forked Conversation',
      );

      expect(forkedConversation.id, isNotEmpty);
      expect(forkedConversation.title, equals('Forked Conversation'));
      expect(forkedConversation.parentConversationId, equals(originalConversation.id));
      expect(forkedConversation.forkFromMessageId, equals(userMessage.id));
    });

    test('should generate conversation tree', () async {
      // Create some conversations
      final conv1 = await conversationService.createConversation(
        title: 'First Conversation',
      );

      final conv2 = await conversationService.createConversation(
        title: 'Second Conversation',
      );

      // Fork from first conversation
      final userMessage = await conversationService.addUserMessage(
        conversationId: conv1.id,
        content: 'Test message',
      );

      final forkedConv = await conversationService.forkConversation(
        originalConversationId: conv1.id,
        forkFromMessageId: userMessage.id,
        newTitle: 'Forked Conversation',
      );

      // Get conversation tree
      final tree = await conversationService.getConversationTree();

      expect(tree, isNotNull);
      expect(tree!.nodes, isNotEmpty);
      expect(tree.rootNodeId, equals('root'));
      expect(tree.nodes['root'], isNotNull);
    });

    test('should handle conversation context correctly', () async {
      final conversation = await conversationService.createConversation(
        title: 'Context Test',
        noteIds: ['note1'],
      );

      // Add multiple messages
      await conversationService.addUserMessage(
        conversationId: conversation.id,
        content: 'First message',
      );

      await conversationService.addAIResponse(
        conversationId: conversation.id,
        content: 'First AI response',
      );

      await conversationService.addUserMessage(
        conversationId: conversation.id,
        content: 'Second message',
      );

      // Get conversation with messages
      final conversationWithMessages = await conversationService.getConversationWithMessages(conversation.id);

      expect(conversationWithMessages, isNotNull);
      expect(conversationWithMessages!.messages.length, equals(3));
      expect(conversationWithMessages.messages[0].content, equals('First message'));
      expect(conversationWithMessages.messages[1].content, equals('First AI response'));
      expect(conversationWithMessages.messages[2].content, equals('Second message'));
    });
  });
}
