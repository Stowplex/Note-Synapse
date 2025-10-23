import 'package:json_annotation/json_annotation.dart';

part 'conversation.g.dart';

@JsonSerializable()
class Conversation {
  final String id;
  final String title;
  final String? parentConversationId; // For forked conversations
  final String? forkFromMessageId; // The message ID where this conversation was forked from
  final List<String> noteIds; // Notes included in this conversation
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isArchived;

  Conversation({
    required this.id,
    required this.title,
    this.parentConversationId,
    this.forkFromMessageId,
    this.noteIds = const [],
    required this.createdAt,
    required this.updatedAt,
    this.isArchived = false,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => _$ConversationFromJson(json);
  Map<String, dynamic> toJson() => _$ConversationToJson(this);

  Conversation copyWith({
    String? id,
    String? title,
    String? parentConversationId,
    String? forkFromMessageId,
    List<String>? noteIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isArchived,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      parentConversationId: parentConversationId ?? this.parentConversationId,
      forkFromMessageId: forkFromMessageId ?? this.forkFromMessageId,
      noteIds: noteIds ?? this.noteIds,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isArchived: isArchived ?? this.isArchived,
    );
  }

  bool get isForked => parentConversationId != null;
}

@JsonSerializable()
class ConversationMessage {
  final String id;
  final String conversationId;
  final MessageType type;
  final String content;
  final DateTime timestamp;
  final List<String> attachmentPaths;
  final String? modelUsed; // AI model used for this message
  final Map<String, dynamic>? metadata; // Additional metadata

  ConversationMessage({
    required this.id,
    required this.conversationId,
    required this.type,
    required this.content,
    required this.timestamp,
    this.attachmentPaths = const [],
    this.modelUsed,
    this.metadata,
  });

  factory ConversationMessage.fromJson(Map<String, dynamic> json) => _$ConversationMessageFromJson(json);
  Map<String, dynamic> toJson() => _$ConversationMessageToJson(this);

  ConversationMessage copyWith({
    String? id,
    String? conversationId,
    MessageType? type,
    String? content,
    DateTime? timestamp,
    List<String>? attachmentPaths,
    String? modelUsed,
    Map<String, dynamic>? metadata,
  }) {
    return ConversationMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      type: type ?? this.type,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      attachmentPaths: attachmentPaths ?? this.attachmentPaths,
      modelUsed: modelUsed ?? this.modelUsed,
      metadata: metadata ?? this.metadata,
    );
  }
}

enum MessageType {
  @JsonValue('user')
  user,
  @JsonValue('ai')
  ai,
  @JsonValue('system')
  system,
}

@JsonSerializable()
class ConversationTreeNode {
  final String id;
  final String conversationId;
  final String? messageId; // The specific message this node represents
  final String summary; // Brief summary (less than 10 words)
  final List<String> children; // Child node IDs
  final String? parentId; // Parent node ID
  final int level; // Depth level in the tree
  final DateTime createdAt;
  final bool isExpanded; // UI state for tree view
  final bool isSelected; // UI state for multi-selection

  ConversationTreeNode({
    required this.id,
    required this.conversationId,
    this.messageId,
    required this.summary,
    this.children = const [],
    this.parentId,
    required this.level,
    required this.createdAt,
    this.isExpanded = false,
    this.isSelected = false,
  });

  factory ConversationTreeNode.fromJson(Map<String, dynamic> json) => _$ConversationTreeNodeFromJson(json);
  Map<String, dynamic> toJson() => _$ConversationTreeNodeToJson(this);

  ConversationTreeNode copyWith({
    String? id,
    String? conversationId,
    String? messageId,
    String? summary,
    List<String>? children,
    String? parentId,
    int? level,
    DateTime? createdAt,
    bool? isExpanded,
    bool? isSelected,
  }) {
    return ConversationTreeNode(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      summary: summary ?? this.summary,
      children: children ?? this.children,
      parentId: parentId ?? this.parentId,
      level: level ?? this.level,
      createdAt: createdAt ?? this.createdAt,
      isExpanded: isExpanded ?? this.isExpanded,
      isSelected: isSelected ?? this.isSelected,
    );
  }
}

@JsonSerializable()
class ConversationTree {
  final String id;
  final Map<String, ConversationTreeNode> nodes; // nodeId -> TreeNode
  final String rootNodeId; // The root node of the tree
  final DateTime createdAt;
  final DateTime updatedAt;

  ConversationTree({
    required this.id,
    required this.nodes,
    required this.rootNodeId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ConversationTree.fromJson(Map<String, dynamic> json) => _$ConversationTreeFromJson(json);
  Map<String, dynamic> toJson() => _$ConversationTreeToJson(this);

  ConversationTree copyWith({
    String? id,
    Map<String, ConversationTreeNode>? nodes,
    String? rootNodeId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ConversationTree(
      id: id ?? this.id,
      nodes: nodes ?? this.nodes,
      rootNodeId: rootNodeId ?? this.rootNodeId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // Helper methods for tree operations
  ConversationTreeNode? getNode(String nodeId) => nodes[nodeId];
  
  List<ConversationTreeNode> getChildren(String nodeId) {
    final node = nodes[nodeId];
    if (node == null) return [];
    return node.children.map((childId) => nodes[childId]!).toList();
  }
  
  ConversationTreeNode? getParent(String nodeId) {
    final node = nodes[nodeId];
    if (node?.parentId == null) return null;
    return nodes[node!.parentId!];
  }
  
  List<ConversationTreeNode> getRootNodes() {
    return nodes.values.where((node) => node.parentId == null).toList();
  }
  
  List<ConversationTreeNode> getNodesAtLevel(int level) {
    return nodes.values.where((node) => node.level == level).toList();
  }
}
