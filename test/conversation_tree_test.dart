import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  group('Conversation Tree Tests', () {
    late ConversationService conversationService;
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      conversationService = ConversationService.createForTesting(databaseService);
      await databaseService.clearAllData();
    });

    tearDown(() async {
      await databaseService.close();
    });

    group('Tree Building', () {
      test('Real fork conversation and tree building test', () async {
        // Create original conversation with 2 interactions
        final originalConversation = await conversationService.createConversation(
          title: 'Original Conversation',
        );
        
        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'First question',
        );
        await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'First answer',
        );
        
        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Second question',
        );
        await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Second answer',
        );
        
        final treeAfterOriginal = await conversationService.refreshConversationTree();
        expect(treeAfterOriginal, isNotNull);
        expect(treeAfterOriginal!.nodes.length, equals(3)); // root + 2 interactions
        
        // Fork from first AI response
        final originalMessages = await conversationService.getConversationWithMessages(originalConversation.id);
        final firstAIResponse = originalMessages!.messages
            .firstWhere((msg) => msg.type == MessageType.ai);
        
        final forkedConversation = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: firstAIResponse.id,
          newTitle: 'Forked Test Conversation',
        );
        
        // Add new interaction to forked conversation
        await conversationService.addUserMessage(
          conversationId: forkedConversation.id,
          content: 'Can you help me with coding?',
        );
        await conversationService.addAIResponse(
          conversationId: forkedConversation.id,
          content: 'Yes, I can help with coding!',
        );
        
        // Verify tree structure
        final finalTree = await conversationService.getConversationTree();
        expect(finalTree, isNotNull);
        expect(finalTree!.nodes.length, equals(4)); // root + 2 original + 1 forked
        
        // Find fork point node
        final forkPointNode = finalTree.nodes.values
            .firstWhere((n) => n.conversationId == originalConversation.id && n.messageId == firstAIResponse.id);
        
        expect(forkPointNode.children.length, equals(2)); // Original continuation + fork
        
        // Find forked interaction node
        final forkedInteractionNode = finalTree.nodes.values
            .firstWhere((n) => n.conversationId == forkedConversation.id && n.id != 'root');
        
        expect(forkedInteractionNode.parentId, equals(forkPointNode.id));
        expect(forkedInteractionNode.level, equals(forkPointNode.level + 1));
      });

      test('Real multiple fork test', () async {
        // Create original conversation
        final originalConversation = await conversationService.createConversation(
          title: 'Original Conversation',
        );
        
        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'What is AI?',
        );
        final aiResponse = await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'AI stands for Artificial Intelligence',
        );
        
        // Create first fork
        final firstFork = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiResponse.id,
          newTitle: 'First Fork',
        );
        
        await conversationService.addUserMessage(
          conversationId: firstFork.id,
          content: 'Tell me more about machine learning',
        );
        await conversationService.addAIResponse(
          conversationId: firstFork.id,
          content: 'Machine learning is a subset of AI',
        );
        
        // Create second fork from same point
        final secondFork = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiResponse.id,
          newTitle: 'Second Fork',
        );
        
        await conversationService.addUserMessage(
          conversationId: secondFork.id,
          content: 'What about deep learning?',
        );
        await conversationService.addAIResponse(
          conversationId: secondFork.id,
          content: 'Deep learning uses neural networks',
        );
        
        // Build and verify tree
        final finalTree = await conversationService.getConversationTree();
        expect(finalTree, isNotNull);
        
        // Find original interaction node (fork point)
        final originalInteractionNode = finalTree!.nodes.values
            .firstWhere((n) => n.conversationId == originalConversation.id && n.messageId == aiResponse.id);
        
        expect(originalInteractionNode.children.length, equals(2)); // Both forks
        
        // Verify both forked nodes
        final forkedNodes = finalTree.nodes.values
            .where((n) => n.conversationId != originalConversation.id && n.id != 'root')
            .toList();
        
        expect(forkedNodes.length, equals(2));
        for (final forkedNode in forkedNodes) {
          expect(forkedNode.parentId, equals(originalInteractionNode.id));
          expect(forkedNode.level, equals(originalInteractionNode.level + 1));
        }
      });

      test('Fork from forked conversation shows correct tree structure', () async {
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

        // Fork from message A
        final forkedConversation1 = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiMessageA.id,
          newTitle: 'Forked Conversation 1',
        );

        // Add message C to first fork
        await conversationService.addUserMessage(
          conversationId: forkedConversation1.id,
          content: 'User message C',
        );
        await conversationService.addAIResponse(
          conversationId: forkedConversation1.id,
          content: 'AI response C',
        );

        // Fork from first fork at message A
        final forkedConversation2 = await conversationService.forkConversation(
          originalConversationId: forkedConversation1.id,
          forkFromMessageId: aiMessageA.id,
          newTitle: 'Forked Conversation 2',
        );

        // Add message D to second fork
        await conversationService.addUserMessage(
          conversationId: forkedConversation2.id,
          content: 'User message D',
        );
        await conversationService.addAIResponse(
          conversationId: forkedConversation2.id,
          content: 'AI response D',
        );

        // Build tree and verify structure
        final tree = await conversationService.refreshConversationTree();
        expect(tree, isNotNull);

        // Find node A (fork point)
        final nodeA = tree!.nodes.values.firstWhere(
          (node) => node.messageId == aiMessageA.id,
        );

        // Node A should have 3 children: B (original), C (fork 1), D (fork 2)
        expect(nodeA.children.length, equals(3));
      });
    });

    group('Tree Logic', () {
      test('Fork from interaction A creates child branch', () {
        final rootNode = ConversationTreeNode(
          id: 'root',
          conversationId: '',
          summary: 'All Interactions',
          level: 0,
          createdAt: DateTime.now(),
          isExpanded: true,
        );

        final nodeA = ConversationTreeNode(
          id: 'interaction_conv1_0',
          conversationId: 'conv1',
          messageId: 'msg_a_ai',
          summary: 'User question A → AI response A',
          level: 1,
          parentId: 'root',
          createdAt: DateTime.now(),
          isExpanded: false,
        );

        final nodeB = ConversationTreeNode(
          id: 'interaction_conv1_1',
          conversationId: 'conv1',
          messageId: 'msg_b_ai',
          summary: 'User question B → AI response B',
          level: 1,
          parentId: 'interaction_conv1_0',
          createdAt: DateTime.now(),
          isExpanded: false,
        );

        final updatedRootNode = rootNode.copyWith(children: ['interaction_conv1_0']);
        final updatedNodeA = nodeA.copyWith(children: ['interaction_conv1_1']);

        final nodes = {
          'root': updatedRootNode,
          'interaction_conv1_0': updatedNodeA,
          'interaction_conv1_1': nodeB,
        };

        final tree = ConversationTree(
          id: 'test_tree',
          nodes: nodes,
          rootNodeId: 'root',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        // Verify tree structure
        expect(tree.nodes.length, equals(3));
        expect(tree.nodes['root']!.children, contains('interaction_conv1_0'));
        expect(tree.nodes['interaction_conv1_0']!.children, contains('interaction_conv1_1'));
        
        // When forking from A, new node C should be child of A
        final nodeC = ConversationTreeNode(
          id: 'interaction_conv2_0',
          conversationId: 'conv2',
          messageId: 'msg_c_ai',
          summary: 'User question C → AI response C',
          level: 2,
          parentId: 'interaction_conv1_0',
          createdAt: DateTime.now(),
          isExpanded: false,
        );

        final updatedNodeAWithFork = updatedNodeA.copyWith(
          children: ['interaction_conv1_1', 'interaction_conv2_0'],
        );

        final updatedNodes = Map<String, ConversationTreeNode>.from(nodes);
        updatedNodes['interaction_conv1_0'] = updatedNodeAWithFork;
        updatedNodes['interaction_conv2_0'] = nodeC;

        expect(updatedNodes['interaction_conv1_0']!.children.length, equals(2));
        expect(updatedNodes['interaction_conv1_0']!.children, contains('interaction_conv2_0'));
      });

      test('Multiple forks from same interaction create multiple children', () {
        final nodeA = ConversationTreeNode(
          id: 'interaction_conv1_0',
          conversationId: 'conv1',
          messageId: 'msg_a_ai',
          summary: 'User question A → AI response A',
          level: 1,
          parentId: 'root',
          createdAt: DateTime.now(),
          isExpanded: false,
        );

        // Create multiple fork nodes
        final nodeB = ConversationTreeNode(
          id: 'interaction_conv2_0',
          conversationId: 'conv2',
          messageId: 'msg_b_ai',
          summary: 'Fork 1',
          level: 2,
          parentId: 'interaction_conv1_0',
          createdAt: DateTime.now(),
          isExpanded: false,
        );

        final nodeC = ConversationTreeNode(
          id: 'interaction_conv3_0',
          conversationId: 'conv3',
          messageId: 'msg_c_ai',
          summary: 'Fork 2',
          level: 2,
          parentId: 'interaction_conv1_0',
          createdAt: DateTime.now(),
          isExpanded: false,
        );

        final nodeD = ConversationTreeNode(
          id: 'interaction_conv4_0',
          conversationId: 'conv4',
          messageId: 'msg_d_ai',
          summary: 'Fork 3',
          level: 2,
          parentId: 'interaction_conv1_0',
          createdAt: DateTime.now(),
          isExpanded: false,
        );

        final updatedNodeA = nodeA.copyWith(
          children: ['interaction_conv2_0', 'interaction_conv3_0', 'interaction_conv4_0'],
        );

        expect(updatedNodeA.children.length, equals(3));
        expect(updatedNodeA.children, containsAll([
          'interaction_conv2_0',
          'interaction_conv3_0',
          'interaction_conv4_0',
        ]));
      });

      test('Tree maintains correct levels after multiple forks', () async {
        final conversation = await conversationService.createConversation(
          title: 'Level Test',
        );
        
        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Q1',
        );
        final ai1 = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'A1',
        );
        
        final fork1 = await conversationService.forkConversation(
          originalConversationId: conversation.id,
          forkFromMessageId: ai1.id,
          newTitle: 'Fork 1',
        );
        
        await conversationService.addUserMessage(
          conversationId: fork1.id,
          content: 'Q2',
        );
        final ai2 = await conversationService.addAIResponse(
          conversationId: fork1.id,
          content: 'A2',
        );
        
        final fork2 = await conversationService.forkConversation(
          originalConversationId: fork1.id,
          forkFromMessageId: ai2.id,
          newTitle: 'Fork 2',
        );
        
        await conversationService.addUserMessage(
          conversationId: fork2.id,
          content: 'Q3',
        );
        await conversationService.addAIResponse(
          conversationId: fork2.id,
          content: 'A3',
        );
        
        final tree = await conversationService.refreshConversationTree();
        expect(tree, isNotNull);
        
        // Verify levels increase correctly
        final node1 = tree!.nodes.values.firstWhere((n) => n.messageId == ai1.id);
        expect(node1.level, equals(1));
        
        final node2 = tree.nodes.values.firstWhere((n) => n.messageId == ai2.id);
        expect(node2.level, equals(2));
        
        final fork2Nodes = tree.nodes.values.where((n) => n.conversationId == fork2.id).toList();
        for (final node in fork2Nodes) {
          expect(node.level, greaterThanOrEqualTo(3));
        }
      });
    });

    group('Tree Node Properties', () {
      test('Tree nodes have correct conversation IDs', () async {
        final conv1 = await conversationService.createConversation(title: 'Conv 1');
        await conversationService.addUserMessage(conversationId: conv1.id, content: 'Q1');
        final ai1 = await conversationService.addAIResponse(conversationId: conv1.id, content: 'A1');
        
        final conv2 = await conversationService.forkConversation(
          originalConversationId: conv1.id,
          forkFromMessageId: ai1.id,
          newTitle: 'Conv 2',
        );
        await conversationService.addUserMessage(conversationId: conv2.id, content: 'Q2');
        await conversationService.addAIResponse(conversationId: conv2.id, content: 'A2');
        
        final tree = await conversationService.refreshConversationTree();
        
        final conv1Nodes = tree!.nodes.values.where((n) => n.conversationId == conv1.id).toList();
        expect(conv1Nodes, isNotEmpty);
        
        final conv2Nodes = tree.nodes.values.where((n) => n.conversationId == conv2.id).toList();
        expect(conv2Nodes, isNotEmpty);
      });

      test('Tree nodes have correct parent-child relationships', () async {
        final conversation = await conversationService.createConversation(title: 'Test');
        
        await conversationService.addUserMessage(conversationId: conversation.id, content: 'Q1');
        final ai1 = await conversationService.addAIResponse(conversationId: conversation.id, content: 'A1');
        
        await conversationService.addUserMessage(conversationId: conversation.id, content: 'Q2');
        final ai2 = await conversationService.addAIResponse(conversationId: conversation.id, content: 'A2');
        
        final tree = await conversationService.refreshConversationTree();
        
        final node1 = tree!.nodes.values.firstWhere((n) => n.messageId == ai1.id);
        final node2 = tree.nodes.values.firstWhere((n) => n.messageId == ai2.id);
        
        expect(node2.parentId, equals(node1.id));
        expect(node1.children, contains(node2.id));
      });

      test('Root node has all top-level conversations as children', () async {
        final conv1 = await conversationService.createConversation(title: 'Conv 1');
        await conversationService.addUserMessage(conversationId: conv1.id, content: 'Q1');
        await conversationService.addAIResponse(conversationId: conv1.id, content: 'A1');
        
        final conv2 = await conversationService.createConversation(title: 'Conv 2');
        await conversationService.addUserMessage(conversationId: conv2.id, content: 'Q2');
        await conversationService.addAIResponse(conversationId: conv2.id, content: 'A2');
        
        final tree = await conversationService.refreshConversationTree();
        
        final rootNode = tree!.nodes['root'];
        expect(rootNode, isNotNull);
        expect(rootNode!.children.length, greaterThanOrEqualTo(2));
      });
    });
  });
}

