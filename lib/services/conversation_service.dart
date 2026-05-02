import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/conversation_attachment.dart';
import '../models/conversation_branch_summary.dart';
import '../models/conversation_context.dart';
import '../models/mcp_endpoint.dart';
import '../models/note.dart';
import '../models/tag.dart';
import 'agent_service.dart';
import 'ai_tool_service.dart';
import 'conversation_attachment_service.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'mcp_service.dart';
import 'service_locator.dart';
import 'skill_service.dart';
import 'tools/load_skill_tool.dart';
import 'tools/note_tools.dart';
import 'user_app_service.dart';

class ConversationService {
  final DatabaseService _databaseService;
  final Uuid _uuid = const Uuid();

  // Skill state (chat mode)
  // NOTE: must be activated via enableSkills() before skillsEnabled returns true.
  // The per-conversation skills toggle (Task 10) will call enableSkills() at session start.
  bool _skillsEnabled = false;
  Map<String, SkillMetadata> _skillIndex = {};
  final List<McpTool> _skillDiscoveredTools = [];
  LoadSkillTool? _loadSkillTool;

  /// Maps skill-discovered MCP tool names to their MCP endpoint names.
  final Map<String, String> _skillToolEndpointNames = {};

  /// Maps skill-discovered MCP tool names to their MCP endpoint IDs.
  final Map<String, String> _skillToolEndpointIds = {};

  /// Maps skill-discovered user_defined tool names to their [AiToolAppBundle].
  final Map<String, AiToolAppBundle> _skillDiscoveredBundles = {};

  /// Names of skill-discovered native (builtin) tools.
  final Set<String> _skillDiscoveredNativeToolNames = {};

  /// Whether skills are currently enabled for chat mode.
  bool get skillsEnabled => _skillsEnabled;

  /// Current skill index (noteId → SkillMetadata).
  Map<String, SkillMetadata> get skillIndex => Map.unmodifiable(_skillIndex);

  /// Tools discovered via skill tool URIs during this chat session.
  List<McpTool> get skillDiscoveredTools =>
      List.unmodifiable(_skillDiscoveredTools);

  /// Maps skill-discovered MCP tool names to their MCP endpoint names.
  Map<String, String> get skillToolEndpointNames =>
      Map.unmodifiable(_skillToolEndpointNames);

  /// Maps skill-discovered MCP tool names to their MCP endpoint IDs.
  Map<String, String> get skillToolEndpointIds =>
      Map.unmodifiable(_skillToolEndpointIds);

  /// Bundles for skill-discovered user_defined tools (keyed by serviceName).
  Map<String, AiToolAppBundle> get skillDiscoveredBundles =>
      Map.unmodifiable(_skillDiscoveredBundles);

  /// Names of skill-discovered native (builtin) tools.
  Set<String> get skillDiscoveredNativeToolNames =>
      Set.unmodifiable(_skillDiscoveredNativeToolNames);

  /// The LoadSkillTool instance (lazily created when skills are enabled).
  LoadSkillTool get loadSkillTool => _loadSkillTool ??= LoadSkillTool();

  /// Creates a ConversationService.
  ///
  /// [databaseService] - The database service for conversation persistence.
  ConversationService(this._databaseService);

  /// Creates a ConversationService for testing with injected dependencies.
  @visibleForTesting
  static ConversationService createForTesting(DatabaseService databaseService) {
    return ConversationService(databaseService);
  }

  // --- Skill support (chat mode) ---

  /// Enables skills for the current chat session.
  ///
  /// Builds the skill index from notes tagged `agent-skill`, resets session
  /// state on both [SkillService] and [LoadSkillTool] so a fresh session begins.
  Future<void> enableSkills() async {
    _skillsEnabled = true;
    _skillDiscoveredTools.clear();
    _skillToolEndpointNames.clear();
    _skillToolEndpointIds.clear();
    _skillDiscoveredBundles.clear();
    _skillDiscoveredNativeToolNames.clear();
    getIt<SkillService>().resetSession();
    _loadSkillTool?.resetSession();
    _skillIndex = await getIt<SkillService>().buildSkillIndex();
  }

  /// Disables skills and clears all skill-related session state.
  void disableSkills() {
    _skillsEnabled = false;
    _skillIndex = {};
    _skillDiscoveredTools.clear();
    _skillToolEndpointNames.clear();
    _skillToolEndpointIds.clear();
    _skillDiscoveredBundles.clear();
    _skillDiscoveredNativeToolNames.clear();
  }

  /// The standard set of native tools available for `builtin` URI resolution.
  /// Derived from [AgentService] to avoid duplication.
  List<NativeTool> get _standardNativeTools => getIt<AgentService>().nativeTools;

  /// Handles the result from a `load_skill` tool call during chat mode.
  ///
  /// Parses tool URIs from the skill content, resolves them to [McpTool]
  /// instances (supporting `mcp`, `builtin`, and `user_defined` namespaces),
  /// and appends any newly-discovered tools to [skillDiscoveredTools].
  Future<void> handleLoadSkillResult(
    String noteId,
    String result,
  ) async {
    if (!_skillsEnabled) return;
    if (noteId.isEmpty) return;
    final skillService = getIt<SkillService>();
    final uris = skillService.extractToolUris(result);
    for (final uri in uris) {
      final parsed = skillService.parseToolUri(uri);
      if (parsed == null) continue;
      switch (parsed.namespace) {
        case 'builtin':
          // Find in standard native tools list, convert to McpTool and add.
          final nativeTool =
              _standardNativeTools.where((t) => t.name == parsed.id).firstOrNull;
          if (nativeTool != null &&
              !_skillDiscoveredTools.any((s) => s.name == nativeTool.name)) {
            _skillDiscoveredTools.add(McpTool(
              name: nativeTool.name,
              description: nativeTool.description,
              inputSchema: nativeTool.inputSchema,
            ));
            _skillDiscoveredNativeToolNames.add(nativeTool.name);
          }

        case 'user_defined':
          // Load UserApp bundle and add its tools.
          final allApps = await _databaseService.getAllUserApps();
          final app = allApps.where((a) => a.uuid == parsed.id).firstOrNull;
          if (app == null || app.selectedRevisionId == null) continue;
          final revision = await getIt<UserAppService>().getAppRevision(
            app.selectedRevisionId!,
          );
          if (revision == null) continue;
          final bundle = await AiToolService.loadAppBundle(
            app: app,
            revision: revision,
          );
          if (bundle == null) continue;
          final allTools = bundle.toMcpTools();
          final filtered = parsed.function != null
              ? allTools.where((t) => t.name == parsed.function).toList()
              : allTools;
          for (final t in filtered) {
            if (!_skillDiscoveredTools.any((s) => s.name == t.name)) {
              _skillDiscoveredTools.add(t);
              _skillDiscoveredBundles[bundle.serviceName] = bundle;
            }
          }

        case 'mcp':
          final mcpService = getIt<McpService>();
          final endpoints = await mcpService.getEndpoints();
          final endpoint =
              endpoints.where((e) => e.name == parsed.id).firstOrNull;
          if (endpoint != null) {
            final cache = await mcpService.getCachedTools(endpoint.id);
            final allTools =
                cache?.tools ??
                (await mcpService.refreshTools(endpoint.id)).tools;
            final filtered = parsed.function != null
                ? allTools.where((t) => t.name == parsed.function).toList()
                : allTools;
            for (final t in filtered) {
              if (!_skillDiscoveredTools.any((s) => s.name == t.name)) {
                _skillDiscoveredTools.add(t);
                _skillToolEndpointNames[t.name] = endpoint.name;
                _skillToolEndpointIds[t.name] = endpoint.id;
              }
            }
          }
      }
    }
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
    await _databaseService.insertConversationMessageMappingsBatch(
      forkedConversation.id,
      messagesToCopy.map((m) => m.id).toList(),
    );

    // Parent relationships for copied messages already exist from the original conversation
    // They are inherited since we're copying message IDs, not creating new messages

    LoggerService.info(
      'Forked conversation $originalConversationId to ${forkedConversation.id} from message $forkFromMessageId',
    );

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
    await _databaseService.insertConversationMessageMappingsBatch(
      forkedConversation.id,
      messagesToCopy.map((m) => m.id).toList(),
    );

    // Parent relationships for copied messages already exist from the original conversation
    // They are inherited since we're copying message IDs, not creating new messages

    // When the first new message is added, it will detect the fork point automatically
    // by checking if the last message exists in multiple conversations

    LoggerService.info(
      'Forked conversation ${selectedContext.conversationId} to ${forkedConversation.id} from message $forkFromMessageId with selected context',
    );

    return forkedConversation;
  }

  // Add a user message to a conversation
  Future<ConversationMessage> addUserMessage({
    required String conversationId,
    required String content,
    List<String> attachmentPaths = const [],
  }) async {
    // Process local absolute file paths
    final finalAttachmentPaths = <String>[];
    final pathsToProcess = <String>[];

    for (final path in attachmentPaths) {
      if (path.startsWith('http://') ||
          path.startsWith('https://') ||
          path.startsWith('gs://') ||
          path.startsWith('attachments/')) {
        finalAttachmentPaths.add(path);
      } else {
        pathsToProcess.add(path);
      }
    }

    if (pathsToProcess.isNotEmpty) {
      final processed =
          await ConversationAttachmentService.processFilesForAttachments(
            filePaths: pathsToProcess,
            noteId: conversationId,
          );
      finalAttachmentPaths.addAll(processed);
    }

    final message = ConversationMessage(
      id: _uuid.v4(),
      conversationId: conversationId,
      type: MessageType.user,
      content: content,
      timestamp: DateTime.now(),
      attachmentPaths: finalAttachmentPaths,
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
    for (final attachmentPath in finalAttachmentPaths) {
      final fileName = attachmentPath.split('/').last;
      final fileType = fileName.split('.').last;

      // Check if it's an absolute URI
      final isUri =
          attachmentPath.startsWith('http://') ||
          attachmentPath.startsWith('https://') ||
          attachmentPath.startsWith('gs://');

      final attachment = ConversationAttachment(
        id: _uuid.v4(),
        messageId: message.id,
        filePath: attachmentPath,
        fileName: fileName,
        fileType: fileType,
        createdAt: DateTime.now(),
        isRelativePath:
            !isUri, // Both local absolute and attachments/ are considered relative to the device
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

    return message;
  }

  // Update an existing conversation message
  Future<void> updateConversationMessage(ConversationMessage message) async {
    await _databaseService.updateConversationMessage(message);
    LoggerService.info('Updated conversation message: ${message.id}');
  }

  // Get all conversations
  Future<List<Conversation>> getAllConversations({
    Duration? maxAge,
    List<String>? tagNames,
    List<String>? conversationIds,
    bool includeEmpty = true,
  }) async {
    return await _databaseService.getAllConversations(
      maxAge: maxAge,
      tagNames: tagNames,
      conversationIds: conversationIds,
      includeEmpty: includeEmpty,
    );
  }

  // Get preview messages (first and last) for a conversation efficiently
  Future<List<ConversationMessage>> getConversationPreviewMessages(
    String conversationId,
  ) async {
    return await _databaseService.getConversationPreviewMessages(
      conversationId,
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

    // Batch fetch all messages for these conversations
    final allMessages = await _databaseService.getMessagesForConversations(
      conversations.map((c) => c.id).toList(),
    );

    // Group messages by conversation ID
    final messagesByConversation = <String, List<ConversationMessage>>{};
    for (final msg in allMessages) {
      if (!messagesByConversation.containsKey(msg.conversationId)) {
        messagesByConversation[msg.conversationId] = [];
      }
      messagesByConversation[msg.conversationId]!.add(msg);
    }

    // Build tree nodes for each conversation
    // The parent-child relationships are automatically established
    // based on message parent relationships
    for (final conversation in conversations) {
      await _buildConversationTreeNodes(
        conversation,
        nodes,
        parentMap,
        messagesByConversation[conversation.id] ?? [],
      );
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
    List<ConversationMessage> messages,
  ) async {
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
  }

  // Delete messages using tree node traversal (for UI efficiency)
  Future<void> deleteMessagesFromTreeNodes(List<String> messageIds) async {
    await _databaseService.deleteMessagesFromTreeNodes(messageIds);
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

  /// Returns child branches forking off [parentMessageId]. One entry per
  /// child conversation that diverges at this message. Empty list if the
  /// message has no children in other conversations yet.
  ///
  /// Uses the [message_parents] adjacency table: a child conversation appears
  /// in the result only when a post-fork message in that conversation has
  /// [parentMessageId] as its parent in [message_parents]. This guarantees the
  /// strip renders only when 2+ real children of the fork point exist.
  ///
  /// Note: this method does NOT exclude any particular conversation from the
  /// result. Callers that need to suppress the active conversation (typically
  /// ChatPanel) should either use [getAllForkPointBranches] (which excludes
  /// the queried conversation) or filter by `conversationId` themselves.
  Future<List<ConversationBranchSummary>> getChildBranches(
    String parentMessageId,
  ) async {
    final branches =
        await _getForkPointBranchesForParents([parentMessageId]);
    return branches[parentMessageId] ?? const [];
  }

  /// Batched fork-point query: one DB round-trip returning all child
  /// branches for every fork-point in [conversationId]. Used by
  /// ChatPanel to render inline branch strips without N+1 queries.
  /// Cached by ChatPanel for the lifetime of the panel; invalidated by
  /// ForkService.forkCreatedStream.
  ///
  /// Uses [message_parents]: for every message in [conversationId] that is a
  /// parent in [message_parents], find child messages living in OTHER
  /// conversations. The strip renders only once post-fork messages exist.
  Future<Map<String, List<ConversationBranchSummary>>> getAllForkPointBranches(
    String conversationId,
  ) async {
    final db = await _databaseService.database;
    // For every message in [conversationId] that is a parent in message_parents,
    // find its child messages that ONLY live in OTHER conversations (i.e., the
    // child message is post-divergence content of a sibling branch, not a copy
    // of an active-conversation message).
    //
    // The "child not in active" filter is what guarantees the strip renders
    // at the *actual* fork point, not at every ancestor of it. Without it,
    // a copied shared message (e.g. Q2 forked into both branches) would make
    // the sibling appear at every preceding parent in message_parents.
    //
    // Group by (parentMessageId, childConversationId) — at most one entry
    // per (fork-point, child) pair.
    final rows = await db.rawQuery('''
      SELECT mp.parentMessageId AS parent_id,
             cmm.conversationId AS child_conv_id,
             c.title           AS child_title,
             (SELECT m2.id
                FROM conversation_messages m2
                JOIN message_parents mp2 ON mp2.messageId = m2.id
                JOIN conversation_message_mapping cmm2
                  ON cmm2.messageId = m2.id
               WHERE mp2.parentMessageId = mp.parentMessageId
                 AND cmm2.conversationId = cmm.conversationId
               ORDER BY m2.timestamp ASC
               LIMIT 1) AS first_child_message_id
        FROM message_parents mp
        JOIN conversation_message_mapping cmm
          ON cmm.messageId = mp.messageId
        JOIN conversations c
          ON c.id = cmm.conversationId
       WHERE mp.parentMessageId IN (
              SELECT m.id FROM conversation_messages m
               JOIN conversation_message_mapping mm
                 ON mm.messageId = m.id
              WHERE mm.conversationId = ?
            )
         AND cmm.conversationId != ?
         AND NOT EXISTS (
              SELECT 1 FROM conversation_message_mapping active_cmm
               WHERE active_cmm.messageId = mp.messageId
                 AND active_cmm.conversationId = ?
            )
       GROUP BY mp.parentMessageId, cmm.conversationId
    ''', [conversationId, conversationId, conversationId]);

    return _materializeBranchSummaries(rows);
  }

  /// IN-list variant of the fork-point query: accepts an explicit list of
  /// [parentMessageIds] (one or more). Returns all child conversations,
  /// **including the calling conversation** if it has a qualifying row.
  /// Used by [getChildBranches]; consumers that need self-exclusion should
  /// use [getAllForkPointBranches] (which adds `cmm.conversationId != ?`).
  Future<Map<String, List<ConversationBranchSummary>>>
      _getForkPointBranchesForParents(List<String> parentMessageIds) async {
    if (parentMessageIds.isEmpty) return const {};
    final db = await _databaseService.database;
    final placeholders =
        List.filled(parentMessageIds.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT mp.parentMessageId AS parent_id,
             cmm.conversationId AS child_conv_id,
             c.title           AS child_title,
             (SELECT m2.id
                FROM conversation_messages m2
                JOIN message_parents mp2 ON mp2.messageId = m2.id
                JOIN conversation_message_mapping cmm2
                  ON cmm2.messageId = m2.id
               WHERE mp2.parentMessageId = mp.parentMessageId
                 AND cmm2.conversationId = cmm.conversationId
               ORDER BY m2.timestamp ASC
               LIMIT 1) AS first_child_message_id
        FROM message_parents mp
        JOIN conversation_message_mapping cmm
          ON cmm.messageId = mp.messageId
        JOIN conversations c
          ON c.id = cmm.conversationId
       WHERE mp.parentMessageId IN ($placeholders)
       GROUP BY mp.parentMessageId, cmm.conversationId
    ''', parentMessageIds);
    return _materializeBranchSummaries(rows);
  }

  /// Internal: turn raw rows from the branch query into the public
  /// ConversationBranchSummary map. Fetches noteIds per distinct child
  /// conversation appearing in the result (one DB call per unique child;
  /// bounded by typical fan-out per spec, < 5).
  Future<Map<String, List<ConversationBranchSummary>>>
      _materializeBranchSummaries(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return const {};
    final childConvIds = rows.map((r) => r['child_conv_id'] as String).toSet();
    final notesByConv = <String, List<String>>{};
    for (final cid in childConvIds) {
      notesByConv[cid] = await _databaseService.getConversationNoteIds(cid);
    }
    final result = <String, List<ConversationBranchSummary>>{};
    for (final row in rows) {
      final parentId = row['parent_id'] as String;
      final childConvId = row['child_conv_id'] as String;
      final summary = ConversationBranchSummary(
        conversationId: childConvId,
        title: row['child_title'] as String,
        forkPointMessageId: parentId,
        // Subquery is guaranteed non-null: the outer mp.messageId itself
        // satisfies the subquery's WHERE clause (same parentMessageId, same
        // conversationId), so it always returns at least one row.
        firstChildMessageId: row['first_child_message_id'] as String,
        noteIds: notesByConv[childConvId] ?? const [],
      );
      result.putIfAbsent(parentId, () => []).add(summary);
    }
    return result;
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
