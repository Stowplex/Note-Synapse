import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/models/conversation.dart';

void main() {
  group('Tree Fork from Forked Conversation Tests', () {
    late ConversationService conversationService;

    setUp(() {
      conversationService = ConversationService();
    });

    test('should show both C and D as children of A when forking from forked conversation', () async {
      // Create original conversation with messages A and B
      final originalConversation = await conversationService.createConversation(
        title: 'Original Conversation',
      );
      final userMessageA = await conversationService.addUserMessage(
        conversationId: originalConversation.id,
        content: 'User message A',
      );
      final aiMessageA = await conversationService.addAIResponse(
        conversationId: originalConversation.id,
        content: 'AI response A',
      );
      final userMessageB = await conversationService.addUserMessage(
        conversationId: originalConversation.id,
        content: 'User message B',
      );
      final aiMessageB = await conversationService.addAIResponse(
        conversationId: originalConversation.id,
        content: 'AI response B',
      );

      // Fork from message A (AI message)
      final forkedConversation1 = await conversationService.forkConversation(
        originalConversationId: originalConversation.id,
        forkFromMessageId: aiMessageA.id,
        newTitle: 'Forked Conversation 1',
      );

      // Add message C to the first forked conversation
      await conversationService.addUserMessage(
        conversationId: forkedConversation1.id,
        content: 'User message C',
      );
      await conversationService.addAIResponse(
        conversationId: forkedConversation1.id,
        content: 'AI response C',
      );

      // Fork from the first forked conversation at message A again
      final forkedConversation2 = await conversationService.forkConversation(
        originalConversationId: forkedConversation1.id,
        forkFromMessageId: aiMessageA.id, // Forking from the same message A
        newTitle: 'Forked Conversation 2',
      );

      // Add message D to the second forked conversation
      await conversationService.addUserMessage(
        conversationId: forkedConversation2.id,
        content: 'User message D',
      );
      await conversationService.addAIResponse(
        conversationId: forkedConversation2.id,
        content: 'AI response D',
      );

      // Build the conversation tree
      final tree = await conversationService.getConversationTree();
      expect(tree, isNotNull, reason: 'Tree should not be null');

      // Verify that both C and D appear as children of A
      // The tree should look like:
      // ROOT -- A -- B
      //             |-- C
      //             |-- D

      // Find the node for message A (should be the fork point)
      final messageANode = tree!.nodes.values.firstWhere(
        (node) => node.messageId == aiMessageA.id,
        orElse: () => throw Exception('Message A node not found'),
      );

      // Message A should have at least 2 children: C and D
      expect(messageANode.children.length, greaterThanOrEqualTo(2), 
        reason: 'Message A should have at least 2 children (C and D)');

      // Verify that both C and D are present as children
      final childNodes = messageANode.children
          .map((childId) => tree.nodes[childId])
          .where((node) => node != null)
          .cast<ConversationTreeNode>()
          .toList();

      expect(childNodes.length, greaterThanOrEqualTo(2), 
        reason: 'Should have at least 2 child nodes');

      // Check that we can find nodes with summaries containing C and D
      final childSummaries = childNodes.map((node) => node.summary).toList();
      expect(childSummaries.any((summary) => summary.contains('C')), isTrue, 
        reason: 'Child C should be present');
      expect(childSummaries.any((summary) => summary.contains('D')), isTrue, 
        reason: 'Child D should be present');

      // Verify the tree structure
      expect(tree.nodes.length, greaterThan(0), 
        reason: 'Tree should have nodes');
    });
  });
}
