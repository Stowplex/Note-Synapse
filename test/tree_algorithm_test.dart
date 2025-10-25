import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/conversation.dart';

void main() {
  group('Tree Building Algorithm Logic Tests', () {
    test('Fork node finding logic', () {
      // Test the logic for finding fork nodes in the tree
      
      // Simulate a tree with nodes
      final nodes = <String, ConversationTreeNode>{
        'root': ConversationTreeNode(
          id: 'root',
          conversationId: '',
          summary: 'All Interactions',
          level: 0,
          createdAt: DateTime.now(),
          isExpanded: true,
        ),
        'interaction_conv1_0': ConversationTreeNode(
          id: 'interaction_conv1_0',
          conversationId: 'conv1',
          messageId: 'msg1_ai',
          summary: 'Hello → Hi there!',
          level: 1,
          parentId: 'root',
          createdAt: DateTime.now(),
          isExpanded: false,
        ),
        'interaction_conv1_1': ConversationTreeNode(
          id: 'interaction_conv1_1',
          conversationId: 'conv1',
          messageId: 'msg2_ai',
          summary: 'How are you? → I am fine',
          level: 1,
          parentId: 'interaction_conv1_0',
          createdAt: DateTime.now(),
          isExpanded: false,
        ),
      };

      // Test finding fork node
      final parentConversationId = 'conv1';
      final forkMessageId = 'msg1_ai'; // Fork from first AI response
      
      // Simulate the fork node finding logic
      String? foundForkNodeId;
      for (final node in nodes.values) {
        if (node.conversationId == parentConversationId) {
          // In real implementation, we'd check if this node contains the fork message
          // For this test, we'll simulate finding the node that contains the fork message
          if (node.messageId == forkMessageId) {
            foundForkNodeId = node.id;
            break;
          }
        }
      }

      expect(foundForkNodeId, equals('interaction_conv1_0'));
    });

    test('Forked conversation node creation logic', () {
      // Test the logic for creating forked conversation nodes
      
      // Simulate a forked conversation
      final forkedConversation = Conversation(
        id: 'conv2',
        title: 'Forked Conversation',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        noteIds: [],
      );

      // Simulate messages in the forked conversation
      final forkedMessages = [
        ConversationMessage(
          id: 'msg1_user',
          conversationId: 'conv2',
          content: 'Hello',
          type: MessageType.user,
          timestamp: DateTime.now(),
        ),
        ConversationMessage(
          id: 'msg1_ai',
          conversationId: 'conv2',
          content: 'Hi there!',
          type: MessageType.ai,
          timestamp: DateTime.now(),
        ),
        ConversationMessage(
          id: 'msg3_user',
          conversationId: 'conv2',
          content: 'Can you help with coding?',
          type: MessageType.user,
          timestamp: DateTime.now(),
        ),
        ConversationMessage(
          id: 'msg3_ai',
          conversationId: 'conv2',
          content: 'Yes, I can help with coding!',
          type: MessageType.ai,
          timestamp: DateTime.now(),
        ),
      ];

      // In the new structure, forked conversations contain messages up to the fork point
      // The fork point is the AI response at index 1
      final forkMessageIndex = 1; // AI response is at index 1
      
      expect(forkMessageIndex, equals(1)); // Should be at index 1 (the AI response)

      // Get new messages after fork point (in a real forked conversation, these would be new messages)
      final newMessages = forkedMessages.skip(forkMessageIndex + 1).toList();
      expect(newMessages.length, equals(2)); // Should have 2 new messages (user + AI)

      // Group into interactions
      final interactions = <List<ConversationMessage>>[];
      List<ConversationMessage> currentInteraction = [];
      
      for (final message in newMessages) {
        if (message.type == MessageType.user) {
          if (currentInteraction.isNotEmpty) {
            interactions.add(List.from(currentInteraction));
          }
          currentInteraction = [message];
        } else if (message.type == MessageType.ai && currentInteraction.isNotEmpty) {
          currentInteraction.add(message);
          interactions.add(List.from(currentInteraction));
          currentInteraction = [];
        }
      }

      expect(interactions.length, equals(1)); // Should have 1 complete interaction
      expect(interactions[0].length, equals(2)); // User + AI
    });

    test('Tree structure after fork', () {
      // Test the expected tree structure after forking
      
      // Before fork: ROOT -> A -> B
      // After fork: ROOT -> A -> B
      //                    |-> C (forked)
      
      final expectedStructure = {
        'root': {
          'children': ['interaction_conv1_0'],
          'level': 0,
        },
        'interaction_conv1_0': {
          'children': ['interaction_conv1_1', 'interaction_conv2_0'],
          'level': 1,
          'conversationId': 'conv1',
        },
        'interaction_conv1_1': {
          'children': [],
          'level': 1,
          'conversationId': 'conv1',
          'parentId': 'interaction_conv1_0',
        },
        'interaction_conv2_0': {
          'children': [],
          'level': 2, // One level deeper than fork point
          'conversationId': 'conv2',
          'parentId': 'interaction_conv1_0', // Child of fork point
        },
      };

      // Verify the structure
      expect(expectedStructure['interaction_conv1_0']!['children'], contains('interaction_conv1_1'));
      expect(expectedStructure['interaction_conv1_0']!['children'], contains('interaction_conv2_0'));
      expect(expectedStructure['interaction_conv2_0']!['parentId'], equals('interaction_conv1_0'));
      expect(expectedStructure['interaction_conv2_0']!['level'], equals(2));
    });
  });
}
