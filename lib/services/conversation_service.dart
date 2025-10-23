import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/conversation_attachment.dart';
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
    String? parentConversationId,
    String? forkFromMessageId,
  }) async {
    final conversation = Conversation(
      id: _uuid.v4(),
      title: title,
      parentConversationId: parentConversationId,
      forkFromMessageId: forkFromMessageId,
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
    // Get the original conversation
    final originalConversation = await _databaseService.getConversation(originalConversationId);
    if (originalConversation == null) {
      throw Exception('Original conversation not found');
    }

    // Verify the fork message exists in the conversation we're forking from
    // This includes the full history (shared history + own messages) for forked conversations
    final allMessages = await _getFullConversationHistory(originalConversation);
    final forkMessageExists = allMessages.any((msg) => msg.id == forkFromMessageId);
    if (!forkMessageExists) {
      throw Exception('Fork message not found');
    }

    // Create new conversation with reference to the fork point
    final forkedConversation = await createConversation(
      title: newTitle,
      noteIds: originalConversation.noteIds,
      parentConversationId: originalConversationId,
      forkFromMessageId: forkFromMessageId, // Keep reference to original message
    );

    LoggerService.info('Forked conversation ${originalConversationId} to ${forkedConversation.id} at message ${forkFromMessageId}');
    
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

    await _databaseService.insertConversationMessage(message);

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

    await _databaseService.insertConversationMessage(message);

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

  // Get a conversation with full history including shared history from parent conversations
  Future<ConversationWithMessages?> getConversationWithFullHistory(String conversationId) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return null;

    // Get all messages including shared history
    final allMessages = await _getFullConversationHistory(conversation);
    
    return ConversationWithMessages(
      conversation: conversation,
      messages: allMessages,
    );
  }

  // Get full conversation history including shared history from parent conversations
  Future<List<ConversationMessage>> _getFullConversationHistory(Conversation conversation) async {
    final allMessages = <ConversationMessage>[];
    
    // If this is a forked conversation, get shared history first
    if (conversation.parentConversationId != null && conversation.forkFromMessageId != null) {
      final parentConversation = await _databaseService.getConversation(conversation.parentConversationId!);
      if (parentConversation != null) {
        // Get parent's full history recursively
        final parentHistory = await _getFullConversationHistory(parentConversation);
        
        // Find the fork point in parent history
        final forkIndex = parentHistory.indexWhere((msg) => msg.id == conversation.forkFromMessageId);
        if (forkIndex != -1) {
          // Include messages up to and including the fork point
          allMessages.addAll(parentHistory.take(forkIndex + 1));
        }
      }
    }
    
    // Add this conversation's own messages
    final ownMessages = await _databaseService.getConversationMessages(conversation.id);
    allMessages.addAll(ownMessages);
    
    return allMessages;
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

  // Build conversation tree from conversations using shared ancestor approach
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

    // Sort conversations by creation time
    conversations.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Build shared tree structure - this will handle both regular and forked conversations
    await _buildSharedTreeStructure(conversations, nodes);

    // Update root node children list - get the latest root node from nodes map
    final finalRootNode = nodes['root']!;
    nodes['root'] = finalRootNode;

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

  // Generate a brief summary from content
  String _generateSummary(String content) {
    // Simple summary generation - take first 10 words
    final words = content.split(' ').take(10).join(' ');
    return words.length > 50 ? '${words.substring(0, 50)}...' : words;
  }

  // Build shared tree structure that handles both regular and forked conversations
  Future<void> _buildSharedTreeStructure(List<Conversation> conversations, Map<String, ConversationTreeNode> nodes) async {
    LoggerService.info('Building shared tree structure for ${conversations.length} conversations');
    
    // First, build all regular conversations (non-forked)
    final regularConversations = conversations.where((c) => c.parentConversationId == null).toList();
    LoggerService.info('Found ${regularConversations.length} regular conversations');
    for (final conversation in regularConversations) {
      LoggerService.info('Building regular conversation: ${conversation.id}');
      await _buildInteractionNodes(conversation, nodes);
    }

    // Then, build forked conversations by finding their shared ancestors
    final forkedConversations = conversations.where((c) => c.parentConversationId != null).toList();
    LoggerService.info('Found ${forkedConversations.length} forked conversations');
    for (final forkedConversation in forkedConversations) {
      LoggerService.info('Building forked conversation: ${forkedConversation.id}');
      await _buildForkedConversationNodes(forkedConversation, nodes);
    }
    
    LoggerService.info('Tree building complete. Total nodes: ${nodes.length}');
  }

  // Build nodes for a forked conversation by finding shared ancestors
  Future<void> _buildForkedConversationNodes(Conversation forkedConversation, Map<String, ConversationTreeNode> nodes) async {
    LoggerService.info('Building forked conversation nodes for: ${forkedConversation.id}');
    LoggerService.info('Parent conversation ID: ${forkedConversation.parentConversationId}');
    LoggerService.info('Fork from message ID: ${forkedConversation.forkFromMessageId}');
    
    final messages = await _databaseService.getConversationMessages(forkedConversation.id);
    LoggerService.info('Forked conversation has ${messages.length} messages');
    
    if (messages.isEmpty) {
      LoggerService.info('Forked conversation has no messages yet, skipping node creation');
      return;
    }

    // Get the fork message ID (this is the original message ID, not a copy)
    final forkMessageId = forkedConversation.forkFromMessageId;
    if (forkMessageId == null) {
      LoggerService.warning('Fork message ID not found for forked conversation: ${forkedConversation.id}');
      return;
    }

    // Find the shared ancestor node (the fork point in the existing tree)
    final forkNodeId = await _findForkNodeInTree(forkedConversation.parentConversationId!, forkMessageId, nodes);
    if (forkNodeId == null) {
      LoggerService.warning('Could not find fork node in existing tree for forked conversation: ${forkedConversation.id}');
      return;
    }

    LoggerService.info('Found fork node: $forkNodeId for forked conversation: ${forkedConversation.id}');

    // Build new interaction nodes and attach them as children of the fork point
    await _buildNewInteractionNodes(forkedConversation, messages, forkNodeId, nodes);
  }

  // Find the fork node in the existing tree
  Future<String?> _findForkNodeInTree(String parentConversationId, String forkMessageId, Map<String, ConversationTreeNode> nodes) async {
    LoggerService.info('Looking for fork node in ${nodes.length} nodes for parent conversation: $parentConversationId, fork message: $forkMessageId');
    
    // Get the parent conversation to check if it's a forked conversation
    final parentConversation = await _databaseService.getConversation(parentConversationId);
    if (parentConversation == null) {
      LoggerService.warning('Parent conversation not found: $parentConversationId');
      return null;
    }
    
    // If the parent is a forked conversation, we need to look in the original conversation
    // that contains the shared history, not just the immediate parent
    String searchConversationId = parentConversationId;
    if (parentConversation.parentConversationId != null) {
      LoggerService.info('Parent is a forked conversation, looking in original conversation: ${parentConversation.parentConversationId}');
      searchConversationId = parentConversation.parentConversationId!;
    }
    
    // Get the full conversation history (including shared history for forked conversations)
    final searchConversation = await _databaseService.getConversation(searchConversationId);
    if (searchConversation == null) {
      LoggerService.warning('Search conversation not found: $searchConversationId');
      return null;
    }
    
    final allMessages = await _getFullConversationHistory(searchConversation);
    LoggerService.info('Search conversation has ${allMessages.length} messages in full history');
    
    // Check if the fork message exists in the full history
    final forkMessageExists = allMessages.any((msg) => msg.id == forkMessageId);
    if (!forkMessageExists) {
      LoggerService.warning('Fork message $forkMessageId not found in search conversation $searchConversationId');
      LoggerService.info('Available message IDs in search conversation: ${allMessages.map((m) => m.id).toList()}');
      return null;
    }
    
    final forkMessage = allMessages.firstWhere((msg) => msg.id == forkMessageId);
    LoggerService.info('Found fork message: ${forkMessage.id} at index ${allMessages.indexOf(forkMessage)}');
    
    // Group messages into interactions to find which interaction contains the fork message
    final interactions = _groupMessagesIntoInteractions(allMessages);
    LoggerService.info('Search conversation has ${interactions.length} interactions');
    
    // Find which interaction contains the fork message
    for (int i = 0; i < interactions.length; i++) {
      final interaction = interactions[i];
      if (interaction.any((m) => m.id == forkMessageId)) {
        LoggerService.info('Fork message found in interaction $i');
        
        // Find the corresponding node in the tree
        final nodeId = 'interaction_${searchConversationId}_$i';
        if (nodes.containsKey(nodeId)) {
          LoggerService.info('Found fork node: $nodeId for fork message: $forkMessageId');
          return nodeId;
        } else {
          LoggerService.warning('Node $nodeId not found in tree nodes');
        }
      }
    }
    
    LoggerService.warning('Could not find fork node for search conversation: $searchConversationId, fork message: $forkMessageId');
    return null;
  }

  // Build new interaction nodes for a forked conversation
  Future<void> _buildNewInteractionNodes(
    Conversation forkedConversation,
    List<ConversationMessage> newMessages,
    String forkNodeId,
    Map<String, ConversationTreeNode> nodes
  ) async {
    final forkNode = nodes[forkNodeId];
    if (forkNode == null) {
      LoggerService.warning('Fork node not found: $forkNodeId');
      return;
    }

    // Group new messages into User-AI interaction pairs
    final newInteractions = _groupMessagesIntoInteractions(newMessages);
    
    LoggerService.info('Creating ${newInteractions.length} new interaction nodes for forked conversation, attaching as children of fork node: $forkNodeId');
    
    // Only create nodes for completed new interactions (User + AI)
    String? previousForkedNodeId;
    for (int i = 0; i < newInteractions.length; i++) {
      final interaction = newInteractions[i];
      if (interaction.length != 2) continue; // Skip incomplete interactions

      final userMessage = interaction.first;
      final aiMessage = interaction.last;
      
      // Create node for this interaction
      final nodeId = 'interaction_${forkedConversation.id}_${i}';
      final summary = _generateInteractionSummary(userMessage.content, aiMessage.content);
      
      // First forked interaction should be a child of the fork point
      // Subsequent forked interactions should be children of each other
      final nodeParentId = i == 0 ? forkNodeId : previousForkedNodeId!;
      
      final node = ConversationTreeNode(
        id: nodeId,
        conversationId: forkedConversation.id,
        messageId: aiMessage.id, // Reference the AI message as the "completion" point
        summary: summary,
        level: forkNode.level + 1, // One level deeper than the fork point (child)
        parentId: nodeParentId,
        createdAt: aiMessage.timestamp, // Use AI message timestamp as completion time
        isExpanded: false, // All forked nodes collapsed by default
      );

      nodes[nodeId] = node;

      // Add to parent's children
      final parentNode = nodes[nodeParentId];
      if (parentNode != null) {
        final newChildren = List<String>.from(parentNode.children)..add(nodeId);
        final updatedParentNode = parentNode.copyWith(children: newChildren);
        nodes[nodeParentId] = updatedParentNode;
      }

      previousForkedNodeId = nodeId;
    }
  }

  // Build interaction nodes for a conversation
  Future<void> _buildInteractionNodes(
    Conversation conversation, 
    Map<String, ConversationTreeNode> nodes
  ) async {
    final messages = await _databaseService.getConversationMessages(conversation.id);
    if (messages.isEmpty) return;

    // Group messages into User-AI interaction pairs
    final interactions = _groupMessagesIntoInteractions(messages);
    
    // Only create nodes for completed interactions (User + AI)
    String? previousNodeId;
    for (int i = 0; i < interactions.length; i++) {
      final interaction = interactions[i];
      if (interaction.length != 2) continue; // Skip incomplete interactions

      final userMessage = interaction.first;
      final aiMessage = interaction.last;
      
      // Create node for this interaction
      final nodeId = 'interaction_${conversation.id}_${i}';
      final summary = _generateInteractionSummary(userMessage.content, aiMessage.content);
      
      final node = ConversationTreeNode(
        id: nodeId,
        conversationId: conversation.id,
        messageId: aiMessage.id, // Reference the AI message as the "completion" point
        summary: summary,
        level: 1,
        parentId: previousNodeId ?? 'root',
        createdAt: aiMessage.timestamp, // Use AI message timestamp as completion time
        isExpanded: false, // All first level nodes collapsed by default for cleaner look
      );

      nodes[nodeId] = node;

      // Add to parent's children
      if (previousNodeId == null) {
        // First interaction in conversation - add to root
        final rootNode = nodes['root']!;
        final newChildren = List<String>.from(rootNode.children)..add(nodeId);
        nodes['root'] = rootNode.copyWith(children: newChildren);
      } else {
        // Add to previous interaction node
        final parentNode = nodes[previousNodeId];
        if (parentNode != null) {
          final newChildren = List<String>.from(parentNode.children)..add(nodeId);
          final updatedParentNode = parentNode.copyWith(children: newChildren);
          nodes[previousNodeId] = updatedParentNode;
        }
      }

      previousNodeId = nodeId;
    }
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

  // Delete a conversation and its descendants
  Future<void> deleteConversation(String conversationId) async {
    // Get all child conversations
    final allConversations = await _databaseService.getAllConversations();
    final childConversations = allConversations
        .where((c) => c.parentConversationId == conversationId)
        .toList();

    // Recursively delete child conversations
    for (final child in childConversations) {
      await deleteConversation(child.id);
    }

    // Delete the conversation itself
    await _databaseService.deleteConversation(conversationId);
    LoggerService.info('Deleted conversation: $conversationId');
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
