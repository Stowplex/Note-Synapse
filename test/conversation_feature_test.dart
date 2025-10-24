import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  group('Conversation Feature Tests', () {
    late ConversationService conversationService;
    late DatabaseService databaseService;

    setUp(() async {
      conversationService = ConversationService();
      databaseService = DatabaseService();
      await databaseService.clearAllData();
    });

    group('Tree Node Creation Tests', () {
      test('1. Create conversation without messages - no node created', () async {
        // Create a conversation but don't add any messages
        final conversation = await conversationService.createConversation(
          title: 'Empty Conversation',
        );

        expect(conversation.id, isNotEmpty);
        expect(conversation.title, equals('Empty Conversation'));

        // Build the tree
        final tree = await conversationService.refreshConversationTree();
        
        expect(tree, isNotNull);
        // Should only have root node, no conversation nodes
        expect(tree!.nodes.length, equals(1)); // Only root
        expect(tree.nodes.containsKey('root'), isTrue);
        expect(tree.nodes['root']!.children, isEmpty);
      });

      test('2. One AI interaction - 1 node created (Node A)', () async {
        // Create conversation and add one complete interaction
        final conversation = await conversationService.createConversation(
          title: 'Test Conversation',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'What is AI?',
        );
        
        final aiResponse = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'AI stands for Artificial Intelligence',
        );

        // Build the tree
        final tree = await conversationService.refreshConversationTree();
        
        expect(tree, isNotNull);
        // Should have root + 1 interaction node (Node A)
        expect(tree!.nodes.length, equals(2)); // root + Node A
        
        // Find Node A (the interaction node)
        final nodeA = tree.nodes.values.firstWhere(
          (node) => node.id != 'root' && node.conversationId == conversation.id,
        );
        
        expect(nodeA, isNotNull);
        expect(nodeA.messageId, equals(aiResponse.id));
        expect(nodeA.level, equals(1));
        expect(nodeA.parentId, isNull); // First node has no parent (except root)
        expect(nodeA.children, isEmpty); // No children yet
        
        // Root should have Node A as child
        final rootNode = tree.nodes['root']!;
        expect(rootNode.children, contains(nodeA.id));
      });

      test('3. Continue conversation - Node B created as child of A', () async {
        // Create conversation with first interaction
        final conversation = await conversationService.createConversation(
          title: 'Test Conversation',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'What is AI?',
        );
        
        final aiResponse1 = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'AI stands for Artificial Intelligence',
        );

        // Add second interaction
        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Tell me more',
        );
        
        final aiResponse2 = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'AI includes machine learning and deep learning',
        );

        // Build the tree
        final tree = await conversationService.refreshConversationTree();
        
        expect(tree, isNotNull);
        // Should have root + 2 interaction nodes (Node A and Node B)
        expect(tree!.nodes.length, equals(3)); // root + Node A + Node B
        
        // Find Node A (first interaction)
        final nodeA = tree.nodes.values.firstWhere(
          (node) => node.messageId == aiResponse1.id,
        );
        
        // Find Node B (second interaction)
        final nodeB = tree.nodes.values.firstWhere(
          (node) => node.messageId == aiResponse2.id,
        );
        
        expect(nodeA, isNotNull);
        expect(nodeB, isNotNull);
        
        // Node B should be a child of Node A
        expect(nodeB.parentId, equals(nodeA.id));
        expect(nodeB.level, equals(2));
        expect(nodeA.children, contains(nodeB.id));
        
        // Node A should be a child of root
        final rootNode = tree.nodes['root']!;
        expect(rootNode.children, contains(nodeA.id));
      });

      test('4. Fork from A without messages - no new node created', () async {
        // Create conversation with one interaction
        final conversation = await conversationService.createConversation(
          title: 'Original Conversation',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'What is AI?',
        );
        
        final aiResponse = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'AI stands for Artificial Intelligence',
        );

        // Fork from the AI response but don't add any messages
        final forkedConversation = await conversationService.forkConversation(
          originalConversationId: conversation.id,
          forkFromMessageId: aiResponse.id,
          newTitle: 'Forked Conversation',
        );

        expect(forkedConversation, isNotNull);

        // Build the tree
        final tree = await conversationService.refreshConversationTree();
        
        expect(tree, isNotNull);
        // Should still have root + 1 node (Node A only)
        // No new node created because forked conversation has no new interactions
        expect(tree!.nodes.length, equals(2)); // root + Node A
        
        // Find Node A
        final nodeA = tree.nodes.values.firstWhere(
          (node) => node.messageId == aiResponse.id,
        );
        
        expect(nodeA, isNotNull);
        expect(nodeA.children, isEmpty); // No children yet
      });

      test('5. Fork from A with interaction - Node C created as child of A', () async {
        // Create conversation with one interaction (Node A)
        final conversation = await conversationService.createConversation(
          title: 'Original Conversation',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'What is AI?',
        );
        
        final aiResponse1 = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'AI stands for Artificial Intelligence',
        );

        // Add second interaction to original (Node B)
        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Tell me about machine learning',
        );
        
        final aiResponse2 = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'Machine learning is a subset of AI',
        );

        // Fork from Node A
        final forkedConversation = await conversationService.forkConversation(
          originalConversationId: conversation.id,
          forkFromMessageId: aiResponse1.id,
          newTitle: 'Forked Conversation',
        );

        // Add interaction to forked conversation (Node C)
        await conversationService.addUserMessage(
          conversationId: forkedConversation.id,
          content: 'What about deep learning?',
        );
        
        final aiResponse3 = await conversationService.addAIResponse(
          conversationId: forkedConversation.id,
          content: 'Deep learning uses neural networks',
        );

        // Build the tree
        final tree = await conversationService.refreshConversationTree();
        
        expect(tree, isNotNull);
        // Should have root + 3 nodes (A, B, C)
        expect(tree!.nodes.length, equals(4)); // root + Node A + Node B + Node C
        
        // Find Node A (first interaction in original)
        final nodeA = tree.nodes.values.firstWhere(
          (node) => node.messageId == aiResponse1.id,
        );
        
        // Find Node B (second interaction in original)
        final nodeB = tree.nodes.values.firstWhere(
          (node) => node.messageId == aiResponse2.id,
        );
        
        // Find Node C (interaction in forked conversation)
        final nodeC = tree.nodes.values.firstWhere(
          (node) => node.messageId == aiResponse3.id,
        );
        
        expect(nodeA, isNotNull);
        expect(nodeB, isNotNull);
        expect(nodeC, isNotNull);
        
        // Verify tree structure:
        // ROOT -- A -- B
        //          |-- C
        
        // Node A should be child of root
        final rootNode = tree.nodes['root']!;
        expect(rootNode.children, contains(nodeA.id));
        
        // Node B should be child of Node A
        expect(nodeB.parentId, equals(nodeA.id));
        expect(nodeB.level, equals(2));
        
        // Node C should be child of Node A
        expect(nodeC.parentId, equals(nodeA.id));
        expect(nodeC.level, equals(2));
        
        // Node A should have both B and C as children
        expect(nodeA.children.length, equals(2));
        expect(nodeA.children, contains(nodeB.id));
        expect(nodeA.children, contains(nodeC.id));
        
        print('Tree structure verified:');
        print('ROOT -- A -- B');
        print('         |-- C');
        print('Node A: ${nodeA.id}, children: ${nodeA.children}');
        print('Node B: ${nodeB.id}, parent: ${nodeB.parentId}');
        print('Node C: ${nodeC.id}, parent: ${nodeC.parentId}');
      });

      test('6. Complex tree with multiple forks', () async {
        // Create original conversation
        final conv1 = await conversationService.createConversation(
          title: 'Original',
        );

        await conversationService.addUserMessage(
          conversationId: conv1.id,
          content: 'Q1',
        );
        
        final ai1 = await conversationService.addAIResponse(
          conversationId: conv1.id,
          content: 'A1',
        );

        await conversationService.addUserMessage(
          conversationId: conv1.id,
          content: 'Q2',
        );
        
        final ai2 = await conversationService.addAIResponse(
          conversationId: conv1.id,
          content: 'A2',
        );

        // Fork 1 from ai1
        final fork1 = await conversationService.forkConversation(
          originalConversationId: conv1.id,
          forkFromMessageId: ai1.id,
          newTitle: 'Fork 1',
        );

        await conversationService.addUserMessage(
          conversationId: fork1.id,
          content: 'Q3',
        );
        
        final ai3 = await conversationService.addAIResponse(
          conversationId: fork1.id,
          content: 'A3',
        );

        // Fork 2 from ai1
        final fork2 = await conversationService.forkConversation(
          originalConversationId: conv1.id,
          forkFromMessageId: ai1.id,
          newTitle: 'Fork 2',
        );

        await conversationService.addUserMessage(
          conversationId: fork2.id,
          content: 'Q4',
        );
        
        final ai4 = await conversationService.addAIResponse(
          conversationId: fork2.id,
          content: 'A4',
        );

        // Build tree
        final tree = await conversationService.refreshConversationTree();
        
        expect(tree, isNotNull);
        // root + 4 nodes (ai1, ai2, ai3, ai4)
        expect(tree!.nodes.length, equals(5));
        
        final node1 = tree.nodes.values.firstWhere((n) => n.messageId == ai1.id);
        final node2 = tree.nodes.values.firstWhere((n) => n.messageId == ai2.id);
        final node3 = tree.nodes.values.firstWhere((n) => n.messageId == ai3.id);
        final node4 = tree.nodes.values.firstWhere((n) => n.messageId == ai4.id);
        
        // Verify structure:
        // ROOT -- node1 -- node2
        //           |-- node3
        //           |-- node4
        
        expect(node1.children.length, equals(3)); // node2, node3, node4
        expect(node2.parentId, equals(node1.id));
        expect(node3.parentId, equals(node1.id));
        expect(node4.parentId, equals(node1.id));
      });
    });

    group('Basic Conversation Operations', () {
      test('should create a new conversation', () async {
        final conversation = await conversationService.createConversation(
          title: 'Test Conversation',
          noteIds: ['note1', 'note2'],
        );

        expect(conversation.id, isNotEmpty);
        expect(conversation.title, equals('Test Conversation'));
        expect(conversation.noteIds, contains('note1'));
        expect(conversation.noteIds, contains('note2'));
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
        expect(message.type, equals(MessageType.ai));
        expect(message.content, equals('This is an AI response'));
        expect(message.modelUsed, equals('gpt-4'));
      });

      test('should get conversation with messages', () async {
        final conversation = await conversationService.createConversation(
          title: 'Context Test',
        );

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

        final conversationWithMessages = await conversationService.getConversationWithMessages(conversation.id);

        expect(conversationWithMessages, isNotNull);
        expect(conversationWithMessages!.messages.length, equals(3));
        expect(conversationWithMessages.messages[0].content, equals('First message'));
        expect(conversationWithMessages.messages[1].content, equals('First AI response'));
        expect(conversationWithMessages.messages[2].content, equals('Second message'));
      });
    });
  });
}
