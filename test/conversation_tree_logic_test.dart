import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  group('Conversation Tree Logic Tests', () {
    late ConversationService conversationService;
    late DatabaseService databaseService;

    setUp(() async {
      conversationService = ConversationService();
      databaseService = DatabaseService();
      await databaseService.clearAllData();
    });

    test('Level 1 nodes have isExpanded=true by default', () async {
      final conversation = await conversationService.createConversation(title: 'Test');
      
      await conversationService.addUserMessage(conversationId: conversation.id, content: 'Q');
      await conversationService.addAIResponse(conversationId: conversation.id, content: 'A');

      final tree = await conversationService.refreshConversationTree();
      
      expect(tree, isNotNull);
      final level1Nodes = tree!.nodes.values.where((node) => node.level == 1).toList();
      
      expect(level1Nodes.length, equals(1), reason: 'Should have exactly 1 level 1 node');
      expect(level1Nodes.first.isExpanded, isTrue, reason: 'Level 1 nodes must be expanded by default for visibility');
    });

    test('Level 2 nodes have isExpanded=false by default', () async {
      final conversation = await conversationService.createConversation(title: 'Test');
      
      await conversationService.addUserMessage(conversationId: conversation.id, content: 'Q1');
      await conversationService.addAIResponse(conversationId: conversation.id, content: 'A1');
      
      await conversationService.addUserMessage(conversationId: conversation.id, content: 'Q2');
      await conversationService.addAIResponse(conversationId: conversation.id, content: 'A2');

      final tree = await conversationService.refreshConversationTree();
      
      expect(tree, isNotNull);
      final level2Nodes = tree!.nodes.values.where((node) => node.level == 2).toList();
      
      expect(level2Nodes.length, equals(1), reason: 'Should have exactly 1 level 2 node');
      expect(level2Nodes.first.isExpanded, isFalse, reason: 'Level 2 nodes should not be expanded by default');
    });

    test('Root node always has isExpanded=true', () async {
      final conversation = await conversationService.createConversation(title: 'Test');
      
      await conversationService.addUserMessage(conversationId: conversation.id, content: 'Q');
      await conversationService.addAIResponse(conversationId: conversation.id, content: 'A');

      final tree = await conversationService.refreshConversationTree();
      
      expect(tree, isNotNull);
      final rootNode = tree!.nodes['root'];
      
      expect(rootNode, isNotNull);
      expect(rootNode!.isExpanded, isTrue, reason: 'Root node must always be expanded');
    });

    test('Root node has level 1 nodes as children', () async {
      final conversation = await conversationService.createConversation(title: 'Test');
      
      await conversationService.addUserMessage(conversationId: conversation.id, content: 'Q');
      final aiMsg = await conversationService.addAIResponse(conversationId: conversation.id, content: 'A');

      final tree = await conversationService.refreshConversationTree();
      
      expect(tree, isNotNull);
      final rootNode = tree!.nodes['root'];
      
      expect(rootNode, isNotNull);
      expect(rootNode!.children.length, equals(1), reason: 'Root should have 1 child');
      
      // The child should be the AI message node
      final childNode = tree.nodes[rootNode.children.first];
      expect(childNode, isNotNull);
      expect(childNode!.messageId, equals(aiMsg.id));
      expect(childNode.level, equals(1), reason: 'Root\'s child should be level 1');
    });

    test('Multiple separate conversations create multiple level 1 nodes', () async {
      final conv1 = await conversationService.createConversation(title: 'Conv 1');
      await conversationService.addUserMessage(conversationId: conv1.id, content: 'Q1');
      await conversationService.addAIResponse(conversationId: conv1.id, content: 'A1');

      final conv2 = await conversationService.createConversation(title: 'Conv 2');
      await conversationService.addUserMessage(conversationId: conv2.id, content: 'Q2');
      await conversationService.addAIResponse(conversationId: conv2.id, content: 'A2');

      final tree = await conversationService.refreshConversationTree();
      
      expect(tree, isNotNull);
      final level1Nodes = tree!.nodes.values.where((node) => node.level == 1).toList();
      
      expect(level1Nodes.length, equals(2), reason: 'Should have 2 level 1 nodes for 2 separate conversations');
      expect(level1Nodes[0].isExpanded, isTrue, reason: 'All level 1 nodes must be expanded');
      expect(level1Nodes[1].isExpanded, isTrue, reason: 'All level 1 nodes must be expanded');
      
      // Root should have both as children
      final rootNode = tree.nodes['root']!;
      expect(rootNode.children.length, equals(2), reason: 'Root should have 2 children');
    });

    test('Forked conversations create correct parent-child relationships', () async {
      final conv = await conversationService.createConversation(title: 'Original');
      
      await conversationService.addUserMessage(conversationId: conv.id, content: 'Q1');
      final ai1 = await conversationService.addAIResponse(conversationId: conv.id, content: 'A1');
      
      await conversationService.addUserMessage(conversationId: conv.id, content: 'Q2');
      await conversationService.addAIResponse(conversationId: conv.id, content: 'A2');

      // Fork from ai1
      final fork = await conversationService.forkConversation(
        originalConversationId: conv.id,
        forkFromMessageId: ai1.id,
        newTitle: 'Fork',
      );

      await conversationService.addUserMessage(conversationId: fork.id, content: 'Q3');
      await conversationService.addAIResponse(conversationId: fork.id, content: 'A3');

      final tree = await conversationService.refreshConversationTree();
      
      expect(tree, isNotNull);
      
      // Find the fork point node (ai1)
      final forkPointNode = tree!.nodes.values.firstWhere((node) => node.messageId == ai1.id);
      
      // It should have 2 children (original continuation + fork)
      expect(forkPointNode.children.length, equals(2), reason: 'Fork point should have 2 children');
      
      // Both children should have the fork point as parent
      for (final childId in forkPointNode.children) {
        final child = tree.nodes[childId];
        expect(child, isNotNull);
        expect(child!.parentId, equals(forkPointNode.id), reason: 'Fork children should have fork point as parent');
      }
    });

    test('Tree structure: ROOT -- A -- B with fork C', () async {
      // This test verifies the exact structure the user described
      final conversation = await conversationService.createConversation(title: 'Original');

      await conversationService.addUserMessage(conversationId: conversation.id, content: 'What is AI?');
      final aiA = await conversationService.addAIResponse(conversationId: conversation.id, content: 'AI is...');

      await conversationService.addUserMessage(conversationId: conversation.id, content: 'Tell me more');
      final aiB = await conversationService.addAIResponse(conversationId: conversation.id, content: 'More details...');

      // Fork from A
      final forkedConversation = await conversationService.forkConversation(
        originalConversationId: conversation.id,
        forkFromMessageId: aiA.id,
        newTitle: 'Forked',
      );

      await conversationService.addUserMessage(conversationId: forkedConversation.id, content: 'What about ML?');
      final aiC = await conversationService.addAIResponse(conversationId: forkedConversation.id, content: 'ML is...');

      final tree = await conversationService.refreshConversationTree();
      
      expect(tree, isNotNull);
      
      // Find nodes A, B, C
      final nodeA = tree!.nodes.values.firstWhere((n) => n.messageId == aiA.id);
      final nodeB = tree.nodes.values.firstWhere((n) => n.messageId == aiB.id);
      final nodeC = tree.nodes.values.firstWhere((n) => n.messageId == aiC.id);
      
      // Verify structure: ROOT -- A -- B
      //                            |-- C
      final rootNode = tree.nodes['root']!;
      expect(rootNode.children, contains(nodeA.id), reason: 'Root should have A as child');
      expect(nodeA.children.length, equals(2), reason: 'A should have 2 children (B and C)');
      expect(nodeA.children, contains(nodeB.id), reason: 'A should have B as child');
      expect(nodeA.children, contains(nodeC.id), reason: 'A should have C as child');
      expect(nodeB.parentId, equals(nodeA.id), reason: 'B\'s parent should be A');
      expect(nodeC.parentId, equals(nodeA.id), reason: 'C\'s parent should be A');
      
      // Verify levels
      expect(nodeA.level, equals(1), reason: 'A is level 1');
      expect(nodeB.level, equals(2), reason: 'B is level 2');
      expect(nodeC.level, equals(2), reason: 'C is level 2');
      
      // Verify expansion states
      expect(nodeA.isExpanded, isTrue, reason: 'Level 1 node A must be expanded');
      expect(nodeB.isExpanded, isFalse, reason: 'Level 2 node B should not be expanded');
      expect(nodeC.isExpanded, isFalse, reason: 'Level 2 node C should not be expanded');
      
      print('✓ Tree structure verified: ROOT -- A -- B');
      print('                                    |-- C');
    });

    test('Empty conversation does not create tree nodes', () async {
      // Create conversation but don't add messages
      await conversationService.createConversation(title: 'Empty');

      final tree = await conversationService.refreshConversationTree();
      
      // Tree should be null or only have root
      if (tree != null) {
        expect(tree.nodes.length, equals(1), reason: 'Empty conversation should only have root node');
        expect(tree.nodes.containsKey('root'), isTrue);
        expect(tree.nodes['root']!.children, isEmpty, reason: 'Root should have no children');
      } else {
        // Tree is null, which is also acceptable
        expect(tree, isNull);
      }
    });

    test('Incomplete interaction (user message only) does not create tree node', () async {
      final conversation = await conversationService.createConversation(title: 'Incomplete');
      
      // Add only user message, no AI response
      await conversationService.addUserMessage(conversationId: conversation.id, content: 'Question');

      final tree = await conversationService.refreshConversationTree();
      
      // Should not create a node for incomplete interaction
      if (tree != null) {
        expect(tree.nodes.length, equals(1), reason: 'Incomplete interaction should not create nodes');
        expect(tree.nodes['root']!.children, isEmpty, reason: 'Root should have no children');
      } else {
        expect(tree, isNull);
      }
    });
  });
}

