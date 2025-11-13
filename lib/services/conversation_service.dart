import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/conversation_attachment.dart';
import '../models/conversation_context.dart';
import '../models/note.dart';
import '../models/tag.dart';
import 'database_service.dart';
import 'logger_service.dart';

class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal({DatabaseService? databaseService})
      : _databaseService = databaseService ?? DatabaseService();

  final DatabaseService _databaseService;
  final Uuid _uuid = const Uuid();

  // For testing - allow injection of mock database service
  static ConversationService _testInstance = ConversationService._internal();
  static void setTestInstance(ConversationService instance) {
    _testInstance = instance;
  }

  static ConversationService getTestInstance() => _testInstance;

  static ConversationService createForTesting(DatabaseService databaseService) {
    return ConversationService._internal(databaseService: databaseService);
  }

  // Create a new conversation
  Future<Conversation> createConversation({
    required String title,
    List<String> noteIds = const [],
  }) async {
    var conversation = Conversation(
      id: _uuid.v4(),
      title: title,
      noteIds: const [], // Will be managed by mapping table
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _databaseService.insertConversation(conversation);

    // Add note mappings if provided
    if (noteIds.isNotEmpty) {
      await addNotesToConversation(conversation.id, noteIds);
      conversation = conversation.copyWith(noteIds: noteIds.toList());
    }

    LoggerService.info('Created new conversation: ${conversation.id}');
    return conversation;
  }

  // Fork a conversation from a specific message
  Future<Conversation> forkConversation({
    required String originalConversationId,
    required String forkFromMessageId,
    required String newTitle,
  }) async {
    LoggerService.info(
      'Forking conversation $originalConversationId from message $forkFromMessageId',
    );
    // Get the original conversation
    final originalConversation = await _databaseService.getConversation(
      originalConversationId,
    );
    if (originalConversation == null) {
      throw Exception('Original conversation not found');
    }

    // Get messages from the original conversation
    final originalMessages = await _databaseService.getConversationMessages(
      originalConversationId,
    );
    final forkIndex = originalMessages.indexWhere(
      (msg) => msg.id == forkFromMessageId,
    );
    if (forkIndex == -1) {
      throw Exception('Fork message not found');
    }

    // Create new conversation
    final forkedConversation = await createConversation(
      title: newTitle,
      noteIds: const [], // Will be handled by addNotesToConversation
    );

    // Copy note mappings from original conversation
    final originalNoteIds = await _databaseService.getConversationNoteIds(
      originalConversationId,
    );
    final copiedNoteIds = <String>[];
    if (originalNoteIds.isNotEmpty) {
      await addNotesToConversation(forkedConversation.id, originalNoteIds);
      copiedNoteIds.addAll(originalNoteIds);
    }

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

    LoggerService.info(
      'Forked conversation $originalConversationId to ${forkedConversation.id} from message $forkFromMessageId',
    );

    // Refresh the conversation tree to include the new forked conversation
    await refreshConversationTree();

    return forkedConversation.copyWith(noteIds: copiedNoteIds);
  }

  // Prepare fork context selection - checks for conflicts and returns selection info
  Future<ForkContextSelection> prepareForkContextSelection(
    String forkFromMessageId,
  ) async {
    // Find all conversations containing this message
    final conversationIds = await _databaseService
        .getConversationsContainingMessage(forkFromMessageId);

    if (conversationIds.isEmpty) {
      throw Exception('Message not found in any conversation');
    }

    // Get context information for each conversation
    final contexts = <ConversationContext>[];
    for (final conversationId in conversationIds) {
      final conversation = await _databaseService.getConversation(
        conversationId,
      );
      if (conversation == null) continue;

      // Get notes for this conversation
      final noteIds = await _databaseService.getConversationNoteIds(
        conversationId,
      );
      final conversationNotes = await _databaseService.getNotesByIds(noteIds);

      // Get last message for context preview (to distinguish between conversations)
      final messages = await _databaseService.getConversationMessages(
        conversationId,
      );
      ConversationMessage? lastMessage;
      if (messages.isNotEmpty) {
        lastMessage = messages.last;
      }

      final context = ConversationContext(
        conversationId: conversationId,
        title: conversation.title,
        noteIds: noteIds,
        notes: conversationNotes,
        initialContext: lastMessage?.content,
        createdAt: conversation.createdAt,
        messageCount: messages.length,
      );

      contexts.add(context);
    }

    ConversationContext? defaultContext;
    if (contexts.isNotEmpty) {
      final hasConflicts = contexts.any(
        (context) => contexts.any(
          (other) => context != other && context.hasConflictingNotes(other),
        ),
      );
      if (!hasConflicts) {
        defaultContext = contexts.first;
      }
    }

    return ForkContextSelection(
      forkMessageId: forkFromMessageId,
      availableContexts: contexts,
      selectedContext: defaultContext,
    );
  }

  // Fork conversation with context selection
  Future<Conversation> forkConversationWithContext({
    required String forkFromMessageId,
    required ConversationContext selectedContext,
    required String newTitle,
  }) async {
    // Get messages from the selected conversation
    final originalMessages = await _databaseService.getConversationMessages(
      selectedContext.conversationId,
    );
    final forkIndex = originalMessages.indexWhere(
      (msg) => msg.id == forkFromMessageId,
    );
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

    LoggerService.info(
      'Forked conversation ${selectedContext.conversationId} to ${forkedConversation.id} from message $forkFromMessageId with selected context',
    );

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
    final existingMessages = await _databaseService.getConversationMessages(
      conversationId,
    );
    if (existingMessages.length > 1) {
      // More than just this message
      final previousMessage = existingMessages[existingMessages.length - 2];

      // Check if previous message is a fork point (exists in multiple conversations)
      // If so, this is the first new message in a forked conversation
      final conversationsWithPrevious = await _databaseService
          .getConversationsContainingMessage(previousMessage.id);

      if (conversationsWithPrevious.length > 1 &&
          previousMessage.type == MessageType.ai) {
        // This is a fork - new message's parent is the fork point (AI message)
        await _databaseService.insertMessageParent(
          messageId: message.id,
          parentMessageId: previousMessage.id,
        );
        LoggerService.info(
          'Fork detected: ${message.id}.parent = ${previousMessage.id} (fork point)',
        );
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
    final existingMessages = await _databaseService.getConversationMessages(
      conversationId,
    );
    if (existingMessages.length > 1) {
      // More than just this message
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
  Future<List<Conversation>> getAllConversations({
    Duration? maxAge,
    List<String>? tagNames,
    List<String>? conversationIds,
  }) async {
    return await _databaseService.getAllConversations(
      maxAge: maxAge,
      tagNames: tagNames,
      conversationIds: conversationIds,
    );
  }

  // Get a specific conversation with its messages
  Future<ConversationWithMessages?> getConversationWithMessages(
    String conversationId,
  ) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return null;

    final messages = await _databaseService.getConversationMessages(
      conversationId,
    );
    return ConversationWithMessages(
      conversation: conversation,
      messages: messages,
    );
  }

  // Get a conversation with full history (alias for backward compatibility)
  Future<ConversationWithMessages?> getConversationWithFullHistory(
    String conversationId,
  ) async {
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
  Future<ConversationTree?> getConversationTree({
    Duration? maxAge,
    List<String>? conversationIds,
    List<String>? tagNames,
  }) async {
    final conversations = await _databaseService.getAllConversations(
      maxAge: maxAge,
      conversationIds: conversationIds,
      tagNames: tagNames,
    );
    if (conversations.isEmpty) return null;

    return await _buildConversationTree(conversations);
  }

  // Refresh conversation tree
  Future<ConversationTree?> refreshConversationTree({
    Duration? maxAge,
    List<String>? conversationIds,
    List<String>? tagNames,
  }) async {
    final conversations = await _databaseService.getAllConversations(
      maxAge: maxAge,
      conversationIds: conversationIds,
      tagNames: tagNames,
    );
    if (conversations.isEmpty) return null;

    return await _buildConversationTree(conversations);
  }

  // Build conversation tree from conversations using message parent relationships
  Future<ConversationTree> _buildConversationTree(
    List<Conversation> conversations,
  ) async {
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
      parentMap[parent['messageId'] as String] =
          parent['parentMessageId'] as String;
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

    return tree;
  }

  // Find the AI message that should be the tree node parent
  // Walks up the parent chain until it finds an AI message (tree node)
  String? _findAITreeNodeParent(
    String messageId,
    Map<String, String> parentMap,
    Map<String, ConversationTreeNode> nodes,
  ) {
    String? parent = parentMap[messageId];
    while (parent != null) {
      // If this parent is already a tree node (AI message), return it
      if (nodes.containsKey(parent)) {
        return parent;
      }
      // Otherwise, continue walking up the parent chain
      parent = parentMap[parent];
    }
    return null;
  }

  // Build tree nodes for a single conversation
  // Tree nodes represent User-AI interaction pairs for UI display
  // The tree structure comes from message parent relationships
  Future<void> _buildConversationTreeNodes(
    Conversation conversation,
    Map<String, ConversationTreeNode> nodes,
    Map<String, String> parentMap,
  ) async {
    final messages = await _databaseService.getConversationMessages(
      conversation.id,
    );
    if (messages.isEmpty) return;

    // Group messages into User-AI interaction pairs for display
    final interactions = _groupMessagesIntoInteractions(messages);

    for (final interaction in interactions) {
      final userMessage = interaction.first;
      final aiMessage = interaction.last;

      // Node ID is the AI message ID
      final nodeId = aiMessage.id;
      final summary = _generateInteractionSummary(
        userMessage.content,
        aiMessage.content,
      );

      // Find parent node
      final parentNodeId = _findAITreeNodeParent(
        userMessage.id,
        parentMap,
        nodes,
      );

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

        // Add this node to parent's children list
        if (parentNodeId != null && nodes.containsKey(parentNodeId)) {
          final parentNode = nodes[parentNodeId]!;
          if (!parentNode.children.contains(nodeId)) {
            final newChildren = List<String>.from(parentNode.children)
              ..add(nodeId);
            nodes[parentNodeId] = parentNode.copyWith(children: newChildren);
          }
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
  List<List<ConversationMessage>> _groupMessagesIntoInteractions(
    List<ConversationMessage> messages,
  ) {
    final interactions = <List<ConversationMessage>>[];
    List<ConversationMessage> currentInteraction = [];

    for (final message in messages) {
      if (message.type == MessageType.user) {
        // If we have a current interaction, check if it's complete before adding it
        if (currentInteraction.isNotEmpty) {
          // Only add complete interactions (User + AI pairs)
          if (currentInteraction.length == 2) {
            interactions.add(List.from(currentInteraction));
          }
          // If incomplete, we simply discard it and start fresh
        }
        currentInteraction = [message];
      } else if (message.type == MessageType.ai &&
          currentInteraction.isNotEmpty) {
        currentInteraction.add(message);
        // Only add complete interactions (User + AI pairs)
        if (currentInteraction.length == 2) {
          interactions.add(List.from(currentInteraction));
        }
        currentInteraction = [];
      }
    }

    // Handle any remaining incomplete interaction at the end
    // We don't add it since it's incomplete
    if (currentInteraction.isNotEmpty) {
      if (currentInteraction.length == 2) {
        interactions.add(List.from(currentInteraction));
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
  Future<List<String>> getMessageIdsFromTreeNode(
    ConversationTreeNode node,
  ) async {
    final messageIds = <String>{};
    final tree = await getConversationTree();
    if (tree == null) return messageIds.toList();

    // Recursive function to traverse the tree node
    void traverseNode(ConversationTreeNode currentNode) {
      if (currentNode.messageId != null) {
        messageIds.add(currentNode.messageId!);
      }

      // Traverse all children by finding their nodes in the tree
      for (final childId in currentNode.children) {
        final childNode = tree.nodes[childId];
        if (childNode == null) {
          throw Exception('Child node $childId not found in tree');
        }
        traverseNode(childNode);
      }
    }

    traverseNode(node);
    return messageIds.toList();
  }

  Future<List<String>> getAllMessageIdsInSubtree(String messageId) async {
    final db = await _databaseService.database;
    final messagesToDelete = <String>{};

    Future<void> traverseSubtree(String currentMessageId) async {
      if (messagesToDelete.contains(currentMessageId)) {
        return; // Already processed
      }

      messagesToDelete.add(currentMessageId);

      final children = await db.query(
        'message_parents',
        where: 'parentMessageId = ?',
        whereArgs: [currentMessageId],
      );

      for (final child in children) {
        final childId = child['messageId'] as String;
        await traverseSubtree(childId);
      }
    }

    await traverseSubtree(messageId);
    return messagesToDelete.toList();
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

    final snippets = await buildInteractionSnippets(
      existingTree: tree,
      nodeIds: selectedNodeIds,
    );

    if (snippets.isEmpty) {
      throw Exception('No valid conversations selected');
    }

    final allNoteIds = <String>{};
    for (final snippet in snippets) {
      final noteIds = await _databaseService.getConversationNoteIds(
        snippet.conversation.id,
      );
      allNoteIds.addAll(noteIds);
    }

    // Create new conversation with all selected conversations' notes
    final newConversation = await createConversation(
      title: title,
      noteIds: allNoteIds.toList(),
    );

    await _addConversationContextFromSnippets(newConversation.id, snippets);

    LoggerService.info(
      'Created conversation from ${selectedNodeIds.length} selected nodes with ${allNoteIds.length} notes',
    );
    return newConversation;
  }

  Future<void> _addConversationContextFromSnippets(
    String conversationId,
    List<ConversationInteractionSnippet> snippets,
  ) async {
    final contextText = formatInteractionSnippets(snippets);
    if (contextText.isEmpty) {
      return;
    }

    await addUserMessage(
      conversationId: conversationId,
      content: 'Context from selected interactions:\n\n$contextText',
    );
  }

  Future<List<ConversationInteractionSnippet>> buildInteractionSnippets({
    ConversationTree? existingTree,
    required List<String> nodeIds,
  }) async {
    if (nodeIds.isEmpty) {
      return [];
    }

    final tree = existingTree ?? await getConversationTree();
    if (tree == null) {
      return [];
    }

    return await _collectInteractionSnippets(tree, nodeIds);
  }

  Future<List<ConversationInteractionSnippet>> _collectInteractionSnippets(
    ConversationTree tree,
    List<String> nodeIds,
  ) async {
    final uniqueNodeIds = nodeIds.toSet();
    final snippets = <ConversationInteractionSnippet>[];
    final conversationCache = <String, Conversation>{};
    final messageCache = <String, ConversationMessage?>{};
    final initialContextProvided = <String, bool>{};
    final initialContextCache = <String, String?>{};

    for (final nodeId in uniqueNodeIds) {
      final node = tree.nodes[nodeId];
      if (node == null) {
        continue;
      }

      if (node.conversationId.isEmpty) {
        continue;
      }

      final messageId = node.messageId;
      if (messageId == null) {
        continue;
      }

      ConversationMessage? resolvedAiMessage = messageCache[messageId];
      if (resolvedAiMessage == null) {
        resolvedAiMessage = await _databaseService.getConversationMessage(
          messageId,
        );
        messageCache[messageId] = resolvedAiMessage;
      }
      if (resolvedAiMessage == null) {
        continue;
      }

      Conversation? conversation = conversationCache[node.conversationId];
      if (conversation == null) {
        conversation = await _databaseService.getConversation(
          node.conversationId,
        );
        if (conversation == null) {
          continue;
        }
        conversationCache[node.conversationId] = conversation;
      }

      ConversationMessage? userMessage;
      final parentMessageId = await _databaseService.getMessageParent(
        messageId,
      );
      if (parentMessageId != null) {
        userMessage = messageCache[parentMessageId];
        if (userMessage == null) {
          userMessage = await _databaseService.getConversationMessage(
            parentMessageId,
          );
          messageCache[parentMessageId] = userMessage;
        }
        if (userMessage?.type != MessageType.user) {
          userMessage = null;
        }
      }

      String? initialContext;
      final shouldIncludeInitial =
          node.level == 1 &&
          !(initialContextProvided[node.conversationId] ?? false);
      if (shouldIncludeInitial) {
        initialContext = await _getConversationInitialContext(
          node.conversationId,
          initialContextCache,
        );
        initialContextProvided[node.conversationId] = true;
      }

      snippets.add(
        ConversationInteractionSnippet(
          conversation: conversation,
          node: node,
          aiMessage: resolvedAiMessage,
          userMessage: userMessage,
          initialContext: initialContext,
        ),
      );
    }

    snippets.sort(
      (a, b) => a.aiMessage.timestamp.compareTo(b.aiMessage.timestamp),
    );

    return snippets;
  }

  Future<String?> _getConversationInitialContext(
    String conversationId,
    Map<String, String?> cache,
  ) async {
    if (cache.containsKey(conversationId)) {
      return cache[conversationId];
    }

    final messages = await _databaseService.getConversationMessages(
      conversationId,
    );

    for (final message in messages) {
      if (message.type == MessageType.user) {
        final trimmed = message.content.trim();
        if (trimmed.isNotEmpty) {
          cache[conversationId] = trimmed;
          return trimmed;
        }
        break;
      }
    }

    cache[conversationId] = null;
    return null;
  }

  String formatInteractionSnippets(
    List<ConversationInteractionSnippet> snippets,
  ) {
    if (snippets.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();

    for (final snippet in snippets) {
      buffer.writeln(
        '--- Interaction from "${snippet.conversation.title}" ---',
      );
      final initialContext = snippet.initialContext?.trim();
      if (initialContext != null && initialContext.isNotEmpty) {
        buffer.writeln('Initial context: $initialContext');
      }
      buffer.writeln('Node summary: ${snippet.node.summary}');
      final userMessage = snippet.userMessage?.content.trim();
      if (userMessage != null && userMessage.isNotEmpty) {
        buffer.writeln('User: $userMessage');
      }
      buffer.writeln('AI: ${snippet.aiMessage.content.trim()}');
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  // Conversation tags helpers
  Future<List<Tag>> getConversationTags(String conversationId) async {
    return await _databaseService.getConversationTags(conversationId);
  }

  Future<List<String>> getConversationTagNames(String conversationId) async {
    return await _databaseService.getConversationTagNames(conversationId);
  }

  Future<void> addTagsToConversation(
    String conversationId,
    List<String> tagNames,
  ) async {
    if (tagNames.isEmpty) return;
    await _databaseService.addTagsToConversation(conversationId, tagNames);
    LoggerService.info('Added tags $tagNames to conversation: $conversationId');
  }

  Future<void> setConversationTags(
    String conversationId,
    List<String> tagNames,
  ) async {
    await _databaseService.setConversationTags(conversationId, tagNames);
    LoggerService.info(
      'Set tags for conversation $conversationId to $tagNames',
    );
  }

  Future<void> removeTagFromConversation(
    String conversationId,
    String tagName,
  ) async {
    await _databaseService.removeTagFromConversation(conversationId, tagName);
    LoggerService.info(
      'Removed tag $tagName from conversation: $conversationId',
    );
  }

  // Get notes for a conversation
  Future<List<Note>> getConversationNotes(String conversationId) async {
    // Get note IDs from the mapping table
    final noteIds = await _databaseService.getConversationNoteIds(
      conversationId,
    );
    if (noteIds.isEmpty) return [];

    // Efficiently fetch only the notes referenced by this conversation
    return await _databaseService.getNotesByIds(noteIds);
  }

  // Get notes by a list of IDs
  Future<List<Note>> getNotesByIds(List<String> noteIds) async {
    if (noteIds.isEmpty) return [];
    return await _databaseService.getNotesByIds(noteIds);
  }

  // Add notes to a conversation
  Future<void> addNotesToConversation(
    String conversationId,
    List<String> noteIds,
  ) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return;

    for (final noteId in noteIds) {
      // Check if mapping already exists
      final exists = await _databaseService.conversationNoteMappingExists(
        conversationId: conversationId,
        noteId: noteId,
      );

      if (!exists) {
        await _databaseService.insertConversationNoteMapping(
          conversationId: conversationId,
          noteId: noteId,
        );
      }
    }

    // Update conversation timestamp
    final updatedConversation = conversation.copyWith(
      updatedAt: DateTime.now(),
    );
    await _databaseService.updateConversation(updatedConversation);
    LoggerService.info('Added notes to conversation: $conversationId');
  }

  // Remove notes from a conversation
  Future<void> removeNotesFromConversation(
    String conversationId,
    List<String> noteIds,
  ) async {
    final conversation = await _databaseService.getConversation(conversationId);
    if (conversation == null) return;

    for (final noteId in noteIds) {
      await _databaseService.deleteConversationNoteMapping(
        conversationId: conversationId,
        noteId: noteId,
      );
    }

    // Update conversation timestamp
    final updatedConversation = conversation.copyWith(
      updatedAt: DateTime.now(),
    );
    await _databaseService.updateConversation(updatedConversation);
    LoggerService.info('Removed notes from conversation: $conversationId');
  }

  Future<void> deleteEmptyConversations({required Duration olderThan}) async {
    await _databaseService.deleteEmptyConversations(olderThan: olderThan);
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

class ConversationInteractionSnippet {
  final Conversation conversation;
  final ConversationTreeNode node;
  final ConversationMessage aiMessage;
  final ConversationMessage? userMessage;
  final String? initialContext;

  ConversationInteractionSnippet({
    required this.conversation,
    required this.node,
    required this.aiMessage,
    required this.userMessage,
    this.initialContext,
  });
}
