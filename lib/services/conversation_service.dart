import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/conversation_attachment.dart';
import '../models/conversation_context.dart';
import '../models/note.dart';
import 'database_service.dart';
import 'logger_service.dart';

class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  final DatabaseService _databaseService = DatabaseService();
  final Uuid _uuid = const Uuid();

  // For testing - allow injection of mock database service
  static ConversationService _testInstance = ConversationService._internal();
  static void setTestInstance(ConversationService instance) {
    _testInstance = instance;
  }
  static ConversationService getTestInstance() => _testInstance;

  // Create a new conversation
  Future<Conversation> createConversation({
    required String title,
    List<String> noteIds = const [],
  }) async {
    final conversation = Conversation(
      id: _uuid.v4(),
      title: title,
      noteIds: noteIds,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _databaseService.insertConversation(conversation);
    LoggerService.info('Created new conversation: ${conversation.id}');
    return conversation;
  }

  // Fork a conversation from a specific message
  Future<Conversation> forkConversation({
    required String originalConversationId,
    required String forkFromMessageId,
    required String newTitle,
  }) async {
    LoggerService.info('Forking conversation ${originalConversationId} from message ${forkFromMessageId}');
    // Get the original conversation
    final originalConversation = await _databaseService.getConversation(originalConversationId);
    if (originalConversation == null) {
      throw Exception('Original conversation not found');
    }

    // Get messages from the original conversation
    final originalMessages = await _databaseService.getConversationMessages(originalConversationId);
    final forkIndex = originalMessages.indexWhere((msg) => msg.id == forkFromMessageId);
    if (forkIndex == -1) {
      throw Exception('Fork message not found');
    }

    // Create new conversation
    final forkedConversation = await createConversation(
      title: newTitle,
      noteIds: originalConversation.noteIds,
    );

    // Copy message IDs from root to fork point (inclusive)
    final messagesToCopy = originalMessages.take(forkIndex + 1);
    for (final message in messagesToCopy) {
      await _databaseService.insertConversationMessageMapping(
        conversationId: forkedConversation.id,
        messageId: message.id,
      );
    }

    // Parent relationships for copied messages already exist from the original conversation
    // They are inherited since we're copying message IDs, not creating new messages

    LoggerService.info('Forked conversation ${originalConversationId} to ${forkedConversation.id} from message ${forkFromMessageId}');
    
    // Refresh the conversation tree to include the new forked conversation
    await refreshConversationTree();
    
    return forkedConversation;
  }

  // Prepare fork context selection - checks for conflicts and returns selection info
  Future<ForkContextSelection> prepareForkContextSelection(String forkFromMessageId) async {
    // Find all conversations containing this message
    final conversationIds = await _databaseService.getConversationsContainingMessage(forkFromMessageId);
    
    if (conversationIds.isEmpty) {
      throw Exception('Message not found in any conversation');
    }

    // Get context information for each conversation
    final contexts = <ConversationContext>[];
    for (final conversationId in conversationIds) {
      final conversation = await _databaseService.getConversation(conversationId);
      if (conversation == null) continue;

      // Get notes for this conversation
      final allNotes = await _databaseService.getAllNotes();
      final conversationNotes = allNotes.where((note) => conversation.noteIds.contains(note.id)).toList();

      // Get initial context (first user message)
      final messages = await _databaseService.getConversationMessages(conversationId);
      ConversationMessage? firstUserMessage;
      try {
        firstUserMessage = messages.firstWhere((msg) => msg.type == MessageType.user);
      } catch (e) {
        firstUserMessage = messages.isNotEmpty ? messages.first : null;
      }
      
      final context = ConversationContext(
        conversationId: conversationId,
        title: conversation.title,
        noteIds: conversation.noteIds,
        notes: conversationNotes,
        initialContext: firstUserMessage?.content,
        createdAt: conversation.createdAt,
        messageCount: messages.length,
      );
      
      contexts.add(context);
    }

    return ForkContextSelection(
      forkMessageId: forkFromMessageId,
      availableContexts: contexts,
    );
  }

  // Fork conversation with context selection
  Future<Conversation> forkConversationWithContext({
    required String forkFromMessageId,
    required ConversationContext selectedContext,
    required String newTitle,
  }) async {
    // Get messages from the selected conversation
    final originalMessages = await _databaseService.getConversationMessages(selectedContext.conversationId);
    final forkIndex = originalMessages.indexWhere((msg) => msg.id == forkFromMessageId);
    if (forkIndex == -1) {
      throw Exception('Fork message not found in selected conversation');
    }

    // Create new conversation with selected context's notes
    final forkedConversation = await createConversation(
      title: newTitle,
      noteIds: selectedContext.noteIds,
    );

    // Copy message IDs from root to fork point (inclusive)
    final messagesToCopy = originalMessages.take(forkIndex + 1);
    for (final message in messagesToCopy) {
      await _databaseService.insertConversationMessageMapping(
        conversationId: forkedConversation.id,
        messageId: message.id,
      );
    }

    // Parent relationships for copied messages already exist from the original conversation
    // They are inherited since we're copying message IDs, not creating new messages
    
    // When the first new message is added, it will detect the fork point automatically
    // by checking if the last message exists in multiple conversations

    LoggerService.info('Forked conversation ${selectedContext.conversationId} to ${forkedConversation.id} from message ${forkFromMessageId} with selected context');
    
    // Refresh the conversation tree to include the new forked conversation
    await refreshConversationTree();
    
    return forkedConversation;
  }

  // Add a user message to a conversation
  Future<ConversationMessage> addUserMessage({
    required String conversationId,
    required String content,
    List<String> attachmentPaths = const [],
  }) async {
    final message = ConversationMessage(
      id: _uuid.v4(),
      conversationId: conversationId,
      type: MessageType.user,
      content: content,
      timestamp: DateTime.now(),
      attachmentPaths: attachmentPaths,
    );

    // Insert message
    await _databaseService.insertConversationMessage(message);
    
    // Create conversation-message mapping
    await _databaseService.insertConversationMessageMapping(
      conversationId: conversationId,
      messageId: message.id,
    );

    // Create parent relationship with previous message (if exists)
    final existingMessages = await _databaseService.getConversationMessages(conversationId);
    if (existingMessages.length > 1) { // More than just this message
      final previousMessage = existingMessages[existingMessages.length - 2];
      
      // Check if previous message is a fork point (exists in multiple conversations)
      // If so, this is the first new message in a forked conversation
      final conversationsWithPrevious = await _databaseService.getConversationsContainingMessage(previousMessage.id);
      
      if (conversationsWithPrevious.length > 1 && previousMessage.type == MessageType.ai) {
        // This is a fork - new message's parent is the fork point (AI message)
        await _databaseService.insertMessageParent(
          messageId: message.id,
          parentMessageId: previousMessage.id,
        );
        LoggerService.info('Fork detected: ${message.id}.parent = ${previousMessage.id} (fork point)');
      } else {
        // Normal case - parent is previous message
        await _databaseService.insertMessageParent(
          messageId: message.id,
          parentMessageId: previousMessage.id,
        );
      }
    }

    // Add attachments
    for (final attachmentPath in attachmentPaths) {
      final fileName = attachmentPath.split('/').last;
      final fileType = fileName.split('.').last;
      
      final attachment = ConversationAttachment(
        id: _uuid.v4(),
        messageId: message.id,
        filePath: attachmentPath,
        fileName: fileName,
        fileType: fileType,
        createdAt: DateTime.now(),
      );
      await _databaseService.insertConversationAttachment(attachment);
    }

    // Update conversation timestamp
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation != null) {
      await _databaseService.updateConversation(
        conversation.copyWith(updatedAt: DateTime.now()),
      );
    }

    LoggerService.info('Added user message to conversation: $conversationId');
    return message;
  }

  // Add an AI response to a conversation
  Future<ConversationMessage> addAIResponse({
    required String conversationId,
    required String content,
    String? modelUsed,
    Map<String, dynamic>? metadata,
  }) async {
    final message = ConversationMessage(
      id: _uuid.v4(),
      conversationId: conversationId,
      type: MessageType.ai,
      content: content,
      timestamp: DateTime.now(),
      modelUsed: modelUsed,
      metadata: metadata,
    );

    // Insert message
    await _databaseService.insertConversationMessage(message);
    
    // Create conversation-message mapping
    await _databaseService.insertConversationMessageMapping(
      conversationId: conversationId,
      messageId: message.id,
    );

    // Create parent relationship with previous message
    final existingMessages = await _databaseService.getConversationMessages(conversationId);
    if (existingMessages.length > 1) { // More than just this message
      final previousMessage = existingMessages[existingMessages.length - 2];
      await _databaseService.insertMessageParent(
        messageId: message.id,
        parentMessageId: previousMessage.id,
      );
    }

    // Update conversation timestamp
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation != null) {
      await _databaseService.updateConversation(
        conversation.copyWith(updatedAt: DateTime.now()),
      );
    }

    LoggerService.info('Added AI response to conversation: $conversationId');
    
    // Refresh the conversation tree to include the new interaction
    await refreshConversationTree();
    
    return message;
  }

  // Get all conversations
  Future<List<Conversation>> getAllConversations() async {
    return await _databaseService.getAllConversations();
  }

  // Get a specific conversation with its messages
  Future<ConversationWithMessages?> getConversationWithMessages(String conversationId) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return null;

    final messages = await _databaseService.getConversationMessages(conversationId);
    return ConversationWithMessages(
      conversation: conversation,
      messages: messages,
    );
  }

  // Get a conversation with full history (alias for backward compatibility)
  Future<ConversationWithMessages?> getConversationWithFullHistory(String conversationId) async {
    return await getConversationWithMessages(conversationId);
  }

  // Validate conversation notes and return missing note IDs
  Future<List<String>> validateConversationNotes(String conversationId) async {
    return await _databaseService.validateConversationNotes(conversationId);
  }

  // Clean up invalid note references across all conversations
  Future<void> cleanupInvalidNoteReferences() async {
    await _databaseService.cleanupInvalidNoteReferences();
  }



  // Get conversation tree
  Future<ConversationTree?> getConversationTree() async {
    // Check if we have a cached tree first
    final existingTree = await _databaseService.getConversationTree('main_tree');
    if (existingTree != null) {
      return existingTree;
    }

    // Build new tree if none exists
    final conversations = await _databaseService.getAllConversations();
    if (conversations.isEmpty) return null;

    return await _buildConversationTree(conversations);
  }

  // Refresh conversation tree
  Future<ConversationTree?> refreshConversationTree() async {
    final conversations = await _databaseService.getAllConversations();
    if (conversations.isEmpty) return null;

    return await _buildConversationTree(conversations);
  }

  // Build conversation tree from conversations using message parent relationships
  Future<ConversationTree> _buildConversationTree(List<Conversation> conversations) async {
    final nodes = <String, ConversationTreeNode>{};
    String? rootNodeId;

    // Create root node
    var rootNode = ConversationTreeNode(
      id: 'root',
      conversationId: '',
      summary: 'All Interactions',
      level: 0,
      createdAt: DateTime.now(),
      isExpanded: true, // Root should be expanded to show first level
    );
    nodes['root'] = rootNode;
    rootNodeId = 'root';

    // Get all message parent relationships
    final allMessageParents = await _databaseService.getAllMessageParents();
    final parentMap = <String, String>{};
    for (final parent in allMessageParents) {
      parentMap[parent['messageId'] as String] = parent['parentMessageId'] as String;
    }

    // Sort conversations by creation time
    conversations.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Build tree nodes for each conversation
    // The parent-child relationships are automatically established
    // based on message parent relationships
    for (final conversation in conversations) {
      await _buildConversationTreeNodes(conversation, nodes, parentMap);
    }

    // Connect root-level messages to root node
    final rootLevelMessages = nodes.values
        .where((node) => node.parentId == null && node.id != 'root')
        .toList();
    
    if (rootLevelMessages.isNotEmpty) {
      final rootChildren = List<String>.from(rootNode.children);
      for (final message in rootLevelMessages) {
        if (!rootChildren.contains(message.id)) {
          rootChildren.add(message.id);
        }
        // Set root as parent for level 1 nodes so graph edges work correctly
        nodes[message.id] = message.copyWith(parentId: 'root');
      }
      nodes['root'] = rootNode.copyWith(children: rootChildren);
    }

    final tree = ConversationTree(
      id: 'main_tree',
      nodes: nodes,
      rootNodeId: rootNodeId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // Save tree to database using upsert (insert or update)
    await _databaseService.upsertConversationTree(tree);
    return tree;
  }

  // Build tree nodes for a single conversation
  // Tree nodes represent User-AI interaction pairs for UI display
  // The tree structure comes from message parent relationships
  Future<void> _buildConversationTreeNodes(
    Conversation conversation, 
    Map<String, ConversationTreeNode> nodes,
    Map<String, String> parentMap,
  ) async {
    final messages = await _databaseService.getConversationMessages(conversation.id);
    if (messages.isEmpty) return;

    // Group messages into User-AI interaction pairs for display
    final interactions = _groupMessagesIntoInteractions(messages);
    
    // Create tree nodes for completed interactions (User + AI pairs)
    for (final interaction in interactions) {
      if (interaction.length != 2) continue; // Skip incomplete interactions

      final userMessage = interaction.first;
      final aiMessage = interaction.last;
      
      // Node ID is the AI message ID
      final nodeId = aiMessage.id;
      final summary = _generateInteractionSummary(userMessage.content, aiMessage.content);
      
      // Find parent node: look at the user message's parent (which could be a fork point)
      String? parentNodeId;
      final userParentId = parentMap[userMessage.id];
      
      if (userParentId != null) {
        // User's parent is either:
        // 1. Previous AI message in same conversation (normal case)
        // 2. Fork point AI message from another conversation (fork case)
        // In both cases, that AI message IS a tree node
        parentNodeId = userParentId;
      }
      
      // Check if node already exists (for fork points that exist in multiple conversations)
      if (!nodes.containsKey(nodeId)) {
        // Calculate level based on parent
        int level = 1;
        if (parentNodeId != null && nodes.containsKey(parentNodeId)) {
          level = nodes[parentNodeId]!.level + 1;
        }
        
        // Level 1 nodes (immediate children of root) should always be visible/expanded
        final shouldBeExpanded = (level == 1);
        
        // Create the tree node
        final node = ConversationTreeNode(
          id: nodeId,
          conversationId: conversation.id,
          messageId: aiMessage.id,
          summary: summary,
          level: level,
          parentId: parentNodeId,
          createdAt: aiMessage.timestamp,
          isExpanded: shouldBeExpanded,
        );

        nodes[nodeId] = node;
      }
      
      // Always add this node to parent's children list (even if node already existed)
      if (parentNodeId != null && nodes.containsKey(parentNodeId)) {
        final parentNode = nodes[parentNodeId]!;
        // Only add if not already in children list
        if (!parentNode.children.contains(nodeId)) {
          final newChildren = List<String>.from(parentNode.children)..add(nodeId);
          nodes[parentNodeId] = parentNode.copyWith(children: newChildren);
        }
      }
    }
  }

  // Generate a brief summary from content
  String _generateSummary(String content) {
    // Simple summary generation - take first 10 words
    final words = content.split(' ').take(10).join(' ');
    return words.length > 50 ? '${words.substring(0, 50)}...' : words;
  }







  // Group messages into User-AI interaction pairs
  List<List<ConversationMessage>> _groupMessagesIntoInteractions(List<ConversationMessage> messages) {
    final interactions = <List<ConversationMessage>>[];
    List<ConversationMessage> currentInteraction = [];
    
    for (final message in messages) {
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
    
    return interactions;
  }

  // Generate summary for a User-AI interaction pair
  String _generateInteractionSummary(String userContent, String aiContent) {
    final userSummary = _generateSummary(userContent);
    final aiSummary = _generateSummary(aiContent);
    return '$userSummary → $aiSummary';
  }

  // Delete a conversation (explicit deletion)
  Future<void> deleteConversation(String conversationId) async {
    await _databaseService.deleteConversationExplicitly(conversationId);
    LoggerService.info('Deleted conversation: $conversationId');
  }

  // Delete a message and its entire subtree
  Future<void> deleteMessageWithSubtree(String messageId) async {
    await _databaseService.deleteMessageWithSubtree(messageId);
    
    // Refresh the conversation tree after deletion
    await refreshConversationTree();
  }

  // Delete messages using tree node traversal (for UI efficiency)
  Future<void> deleteMessagesFromTreeNodes(List<String> messageIds) async {
    await _databaseService.deleteMessagesFromTreeNodes(messageIds);
    
    // Refresh the conversation tree after deletion
    await refreshConversationTree();
  }

  // Get all message IDs in a tree node's subtree using proper tree traversal
  Future<List<String>> getMessageIdsFromTreeNode(ConversationTreeNode node) async {
    final messageIds = <String>{};
    final tree = await getConversationTree();
    if (tree == null) return messageIds.toList();
    
    // Recursive function to traverse the tree node
    void _traverseNode(ConversationTreeNode currentNode) {
      if (currentNode.messageId != null) {
        messageIds.add(currentNode.messageId!);
      }
      
      // Traverse all children by finding their nodes in the tree
      for (final childId in currentNode.children) {
        final childNode = tree.nodes[childId];
        if (childNode == null) {
          throw Exception('Child node $childId not found in tree');
        }
        _traverseNode(childNode);
      }
    }
    
    _traverseNode(node);
    return messageIds.toList();
  }

  // Update conversation tree node
  Future<void> updateTreeNode({
    required String nodeId,
    bool? isExpanded,
    bool? isSelected,
  }) async {
    final tree = await getConversationTree();
    if (tree == null) return;

    final node = tree.nodes[nodeId];
    if (node == null) return;

    final updatedNode = node.copyWith(
      isExpanded: isExpanded,
      isSelected: isSelected,
    );

    final updatedNodes = Map<String, ConversationTreeNode>.from(tree.nodes);
    updatedNodes[nodeId] = updatedNode;

    final updatedTree = tree.copyWith(
      nodes: updatedNodes,
      updatedAt: DateTime.now(),
    );

    await _databaseService.updateConversationTree(updatedTree);
  }

  // Create new conversation from selected tree nodes
  Future<Conversation> createConversationFromSelectedNodes({
    required List<String> selectedNodeIds,
    required String title,
  }) async {
    // Get the tree
    final tree = await getConversationTree();
    if (tree == null) {
      throw Exception('No conversation tree found');
    }

    // Collect all conversation IDs and note IDs from selected nodes
    final conversationIds = <String>{};
    final allNoteIds = <String>{};
    
    for (final nodeId in selectedNodeIds) {
      final node = tree.nodes[nodeId];
      if (node != null && node.conversationId.isNotEmpty) {
        conversationIds.add(node.conversationId);
        
        // Get notes from this conversation
        final conversation = await _databaseService.getConversation(node.conversationId);
        if (conversation != null) {
          allNoteIds.addAll(conversation.noteIds);
        }
      }
    }

    if (conversationIds.isEmpty) {
      throw Exception('No valid conversations selected');
    }

    // Create new conversation with all selected conversations' notes
    final newConversation = await createConversation(
      title: title,
      noteIds: allNoteIds.toList(),
    );

    // Add context from selected conversations as initial messages
    await _addConversationContext(newConversation.id, conversationIds.toList());

    LoggerService.info('Created conversation from ${selectedNodeIds.length} selected nodes with ${allNoteIds.length} notes');
    return newConversation;
  }

  // Add conversation context as initial messages
  Future<void> _addConversationContext(String conversationId, List<String> sourceConversationIds) async {
    final contextMessages = <String>[];
    
    for (final sourceConvId in sourceConversationIds) {
      final messages = await _databaseService.getConversationMessages(sourceConvId);
      if (messages.isNotEmpty) {
        // Add a header for this conversation's context
        contextMessages.add('--- Context from previous conversation ---');
        
        // Add key messages (first few and last few)
        final keyMessages = <ConversationMessage>[];
        if (messages.length <= 4) {
          keyMessages.addAll(messages);
        } else {
          // First 2 and last 2 messages
          keyMessages.addAll(messages.take(2));
          keyMessages.addAll(messages.skip(messages.length - 2));
        }
        
        for (final message in keyMessages) {
          final prefix = message.type == MessageType.user ? 'User: ' : 'AI: ';
          contextMessages.add('$prefix${message.content}');
        }
        contextMessages.add(''); // Empty line between conversations
      }
    }
    
    if (contextMessages.isNotEmpty) {
      // Add context as a single user message
      final contextText = contextMessages.join('\n');
      await addUserMessage(
        conversationId: conversationId,
        content: 'Context from selected conversations:\n\n$contextText',
      );
    }
  }

  // Get notes for a conversation
  Future<List<Note>> getConversationNotes(String conversationId) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return [];

    final allNotes = await _databaseService.getAllNotes();
    return allNotes.where((note) => conversation.noteIds.contains(note.id)).toList();
  }

  // Add notes to a conversation
  Future<void> addNotesToConversation(String conversationId, List<String> noteIds) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return;

    final updatedNoteIds = List<String>.from(conversation.noteIds);
    for (final noteId in noteIds) {
      if (!updatedNoteIds.contains(noteId)) {
        updatedNoteIds.add(noteId);
      }
    }

    final updatedConversation = conversation.copyWith(
      noteIds: updatedNoteIds,
      updatedAt: DateTime.now(),
    );

    await _databaseService.updateConversation(updatedConversation);
    LoggerService.info('Added notes to conversation: $conversationId');
  }

  // Remove notes from a conversation
  Future<void> removeNotesFromConversation(String conversationId, List<String> noteIds) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return;

    final updatedNoteIds = List<String>.from(conversation.noteIds);
    updatedNoteIds.removeWhere((id) => noteIds.contains(id));

    final updatedConversation = conversation.copyWith(
      noteIds: updatedNoteIds,
      updatedAt: DateTime.now(),
    );

    await _databaseService.updateConversation(updatedConversation);
    LoggerService.info('Removed notes from conversation: $conversationId');
  }

  // Get a specific conversation message
  Future<ConversationMessage?> getConversationMessage(String messageId) async {
    return await _databaseService.getConversationMessage(messageId);
  }
}

// Helper class to combine conversation with its messages
class ConversationWithMessages {
  final Conversation conversation;
  final List<ConversationMessage> messages;

  ConversationWithMessages({
    required this.conversation,
    required this.messages,
  });
}
