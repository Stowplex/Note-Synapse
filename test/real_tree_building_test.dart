import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  group('Real Tree Building Algorithm Tests', () {
    late ConversationService conversationService;
    late DatabaseService databaseService;

    setUp(() async {
      // Initialize the real services
      conversationService = ConversationService();
      databaseService = DatabaseService();
      
      // Clear any existing data for clean tests
      await databaseService.clearAllData();
    });

    test('Real fork conversation and tree building test', () async {
      // This test will use the actual database and services
      // It will create real conversations, fork them, and verify the tree structure
      
      try {
        // Step 1: Create an original conversation
        final originalConversation = await conversationService.createConversation(
          title: 'Test Original Conversation',
        );
        
        // Step 2: Add some messages to create interactions
        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Hello, how are you?',
        );
        
        await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'I am doing well, thank you!',
        );
        
        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'What can you help me with?',
        );
        
        await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'I can help with various tasks!',
        );
        
        // Step 3: Get the conversation tree after building it
        final treeAfterOriginal = await conversationService.refreshConversationTree();
        expect(treeAfterOriginal, isNotNull);
        expect(treeAfterOriginal!.nodes.length, equals(3)); // root + 2 interactions
        
        // Step 4: Fork the conversation from the first AI response
        final firstInteractionNode = treeAfterOriginal.nodes.values
            .firstWhere((n) => n.conversationId == originalConversation.id);
        
        final forkedConversation = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: firstInteractionNode.messageId!,
          newTitle: 'Forked Test Conversation',
        );
        
        // Step 5: Add a new interaction to the forked conversation
        await conversationService.addUserMessage(
          conversationId: forkedConversation.id,
          content: 'Can you help me with coding?',
        );
        
        await conversationService.addAIResponse(
          conversationId: forkedConversation.id,
          content: 'Yes, I can help with coding!',
        );
        
        // Step 6: Get the updated tree and verify structure
        final finalTree = await conversationService.getConversationTree();
        expect(finalTree, isNotNull);
        
        // Verify the tree structure
        expect(finalTree!.nodes.length, equals(4)); // root + 2 original + 1 forked
        
        // Find the fork point node (should have 2 children now)
        final forkPointNode = finalTree.nodes.values
            .firstWhere((n) => n.conversationId == originalConversation.id && n.messageId == firstInteractionNode.messageId);
        
        expect(forkPointNode.children.length, equals(2)); // Should have 2 children
        
        // Find the forked interaction node
        final forkedInteractionNode = finalTree.nodes.values
            .firstWhere((n) => n.conversationId == forkedConversation.id);
        
        expect(forkedInteractionNode.parentId, equals(forkPointNode.id));
        expect(forkedInteractionNode.level, equals(forkPointNode.level + 1));
        
        print('✅ Test passed! Tree structure is correct.');
        print('Root children: ${finalTree.nodes['root']!.children.length}');
        print('Fork point children: ${forkPointNode.children.length}');
        print('Forked node parent: ${forkedInteractionNode.parentId}');
        print('Forked node level: ${forkedInteractionNode.level}');
        
      } catch (e) {
        print('❌ Test failed with error: $e');
        rethrow;
      }
    });

    test('Real multiple fork test', () async {
      // Test multiple forks from the same point
      
      try {
        // Step 1: Create original conversation
        final originalConversation = await conversationService.createConversation(
          title: 'Multi-Fork Test Original',
        );
        
        // Step 2: Add one interaction
        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Hello',
        );
        
        await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Hi there!',
        );
        
        // Step 3: Get the user message ID for forking
        final messages = await conversationService.getConversationWithMessages(originalConversation.id);
        final userMessage = messages!.messages.firstWhere((m) => m.type == MessageType.user);
        
        // Step 4: Create first fork
        final fork1 = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: userMessage.id,
          newTitle: 'Fork 1',
        );
        
        await conversationService.addUserMessage(
          conversationId: fork1.id,
          content: 'Fork 1 question',
        );
        
        await conversationService.addAIResponse(
          conversationId: fork1.id,
          content: 'Fork 1 answer',
        );
        
        // Step 5: Create second fork
        final fork2 = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: userMessage.id,
          newTitle: 'Fork 2',
        );
        
        await conversationService.addUserMessage(
          conversationId: fork2.id,
          content: 'Fork 2 question',
        );
        
        await conversationService.addAIResponse(
          conversationId: fork2.id,
          content: 'Fork 2 answer',
        );
        
        // Step 6: Verify final tree structure
        final finalTree = await conversationService.getConversationTree();
        expect(finalTree, isNotNull);
        
        // Should have: root + 1 original + 2 forked = 4 nodes total
        expect(finalTree!.nodes.length, equals(4));
        
        // The original interaction node should have 2 children (both forks)
        final originalInteractionNode = finalTree.nodes.values
            .firstWhere((n) => n.conversationId == originalConversation.id);
        
        expect(originalInteractionNode.children.length, equals(2));
        
        // Both forked nodes should be children of the original interaction
        final forkedNodes = finalTree.nodes.values
            .where((n) => n.conversationId != originalConversation.id && n.id != 'root')
            .toList();
        
        expect(forkedNodes.length, equals(2));
        for (final forkedNode in forkedNodes) {
          expect(forkedNode.parentId, equals(originalInteractionNode.id));
          expect(forkedNode.level, equals(originalInteractionNode.level + 1));
        }
        
        print('✅ Multiple fork test passed!');
        print('Original node children: ${originalInteractionNode.children.length}');
        print('Forked nodes: ${forkedNodes.map((n) => n.conversationId).toList()}');
        
      } catch (e) {
        print('❌ Multiple fork test failed with error: $e');
        rethrow;
      }
    });
  });
}
