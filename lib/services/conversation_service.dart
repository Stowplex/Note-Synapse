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
      summary: 'All Conversations',
      level: 0,
      createdAt: DateTime.now(),
    );
    nodes['root'] = rootNode;
    rootNodeId = 'root';

    // Sort conversations by creation time
    conversations.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Group conversations by parent
    final rootConversations = conversations.where((c) => c.parentConversationId == null).toList();
    final forkedConversations = conversations.where((c) => c.parentConversationId != null).toList();

    // Add root conversations as first level
    for (final conversation in rootConversations) {
      final nodeId = 'conv_${conversation.id}';
      
      // Get first message for summary
      final messages = await _databaseService.getConversationMessages(conversation.id);
      final summary = messages.isNotEmpty 
          ? _generateSummary(messages.first.content)
          : conversation.title;

      final node = ConversationTreeNode(
        id: nodeId,
        conversationId: conversation.id,
        messageId: messages.isNotEmpty ? messages.first.id : null,
        summary: summary,
        level: 1,
        parentId: 'root',
        createdAt: conversation.createdAt,
      );
      
      nodes[nodeId] = node;
      // Create a new list to avoid unmodifiable list issues
      final newChildren = List<String>.from(rootNode.children)..add(nodeId);
      rootNode = rootNode.copyWith(children: newChildren);
      nodes['root'] = rootNode;
    }

    // Add forked conversations as children in proper hierarchy
    final processedForks = <String>{};
    for (final conversation in forkedConversations) {
      if (processedForks.contains(conversation.id)) continue;
      
      final parentNodeId = 'conv_${conversation.parentConversationId}';
      if (nodes.containsKey(parentNodeId)) {
        final nodeId = 'conv_${conversation.id}';
        
        // Get first message for summary
        final messages = await _databaseService.getConversationMessages(conversation.id);
        final summary = messages.isNotEmpty 
            ? _generateSummary(messages.first.content)
            : conversation.title;

        final node = ConversationTreeNode(
          id: nodeId,
          conversationId: conversation.id,
          messageId: messages.isNotEmpty ? messages.first.id : null,
          summary: summary,
          level: nodes[parentNodeId]!.level + 1,
          parentId: parentNodeId,
          createdAt: conversation.createdAt,
        );
        
        nodes[nodeId] = node;
        final parentNode = nodes[parentNodeId];
        if (parentNode != null) {
          // Create a new list to avoid unmodifiable list issues
          final newChildren = List<String>.from(parentNode.children)..add(nodeId);
          final updatedParentNode = parentNode.copyWith(children: newChildren);
          nodes[parentNodeId] = updatedParentNode;
        }
        processedForks.add(conversation.id);
      }
    }

    // Update root node children list
    final updatedRootNode = rootNode.copyWith(children: List<String>.from(rootNode.children));
    nodes['root'] = updatedRootNode;

    final tree = ConversationTree(
      id: 'main_tree',
      nodes: nodes,
      rootNodeId: rootNodeId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // Save tree to database
    await _databaseService.insertConversationTree(tree);
    return tree;
  }

  // Generate a brief summary from content
  String _generateSummary(String content) {
    // Simple summary generation - take first 10 words
    final words = content.split(' ').take(10).join(' ');
    return words.length > 50 ? '${words.substring(0, 50)}...' : words;
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
