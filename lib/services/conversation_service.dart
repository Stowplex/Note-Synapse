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

    // Get messages up to the fork point
    final allMessages = await _databaseService.getConversationMessages(originalConversationId);
    final forkMessageIndex = allMessages.indexWhere((msg) => msg.id == forkFromMessageId);
    if (forkMessageIndex == -1) {
      throw Exception('Fork message not found');
    }

    // Create new conversation
    final forkedConversation = await createConversation(
      title: newTitle,
      noteIds: originalConversation.noteIds,
      parentConversationId: originalConversationId,
      forkFromMessageId: forkFromMessageId,
    );

    // Copy messages up to the fork point
    final messagesToCopy = allMessages.take(forkMessageIndex + 1).toList();
    for (final message in messagesToCopy) {
      final newMessage = ConversationMessage(
        id: _uuid.v4(),
        conversationId: forkedConversation.id,
        type: message.type,
        content: message.content,
        timestamp: message.timestamp,
        modelUsed: message.modelUsed,
        metadata: message.metadata,
      );
      await _databaseService.insertConversationMessage(newMessage);

      // Copy attachments
      final attachments = await _databaseService.getConversationAttachments(message.id);
      for (final attachment in attachments) {
        final newAttachment = ConversationAttachment(
          id: _uuid.v4(),
          messageId: newMessage.id,
          filePath: attachment.filePath,
          fileName: attachment.fileName,
          fileType: attachment.fileType,
          createdAt: attachment.createdAt,
          isRelativePath: attachment.isRelativePath,
        );
        await _databaseService.insertConversationAttachment(newAttachment);
      }
    }

    LoggerService.info('Forked conversation ${originalConversationId} to ${forkedConversation.id}');
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

  // Build conversation tree from conversations
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

    // Process each conversation to build interaction nodes
    for (final conversation in conversations) {
      await _buildInteractionNodes(conversation, nodes);
    }

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

    // Handle forked conversations
    if (conversation.parentConversationId != null && conversation.forkFromMessageId != null) {
      await _handleForkedConversation(conversation, nodes);
    }
  }

  // Handle forked conversations by finding the fork point and creating a branch
  Future<void> _handleForkedConversation(
    Conversation forkedConversation, 
    Map<String, ConversationTreeNode> nodes
  ) async {
    // Find the parent conversation's interaction node that contains the fork message
    final parentConversation = await _databaseService.getConversation(forkedConversation.parentConversationId!);
    if (parentConversation == null) return;

    final parentMessages = await _databaseService.getConversationMessages(parentConversation.id);
    final forkMessage = parentMessages.firstWhere(
      (m) => m.id == forkedConversation.forkFromMessageId,
      orElse: () => parentMessages.first,
    );

    // Find the interaction node that contains this message
    String? forkNodeId;
    for (final node in nodes.values) {
      if (node.conversationId == parentConversation.id) {
        final nodeMessages = await _databaseService.getConversationMessages(node.conversationId);
        final interactions = _groupMessagesIntoInteractions(nodeMessages);
        for (final interaction in interactions) {
          if (interaction.any((m) => m.id == forkMessage.id)) {
            forkNodeId = node.id;
            break;
          }
        }
        if (forkNodeId != null) break;
      }
    }

    if (forkNodeId != null) {
      // Build interaction nodes for the forked conversation
      await _buildInteractionNodes(forkedConversation, nodes);
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

    // Collect all conversation IDs from selected nodes
    final conversationIds = <String>{};
    for (final nodeId in selectedNodeIds) {
      final node = tree.nodes[nodeId];
      if (node != null && node.conversationId.isNotEmpty) {
        conversationIds.add(node.conversationId);
      }
    }

    if (conversationIds.isEmpty) {
      throw Exception('No valid conversations selected');
    }

    // Create new conversation with all selected conversations' notes
    final allNoteIds = <String>{};
    for (final convId in conversationIds) {
      final conversation = await _databaseService.getConversation(convId);
      if (conversation != null) {
        allNoteIds.addAll(conversation.noteIds);
      }
    }

    return await createConversation(
      title: title,
      noteIds: allNoteIds.toList(),
    );
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
