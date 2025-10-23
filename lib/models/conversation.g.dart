// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'conversation.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Conversation _$ConversationFromJson(Map<String, dynamic> json) => Conversation(
  id: json['id'] as String,
  title: json['title'] as String,
  parentConversationId: json['parentConversationId'] as String?,
  forkFromMessageId: json['forkFromMessageId'] as String?,
  noteIds:
      (json['noteIds'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  isArchived: json['isArchived'] as bool? ?? false,
);

Map<String, dynamic> _$ConversationToJson(Conversation instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'parentConversationId': instance.parentConversationId,
      'forkFromMessageId': instance.forkFromMessageId,
      'noteIds': instance.noteIds,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
      'isArchived': instance.isArchived,
    };

ConversationMessage _$ConversationMessageFromJson(Map<String, dynamic> json) =>
    ConversationMessage(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      type: $enumDecode(_$MessageTypeEnumMap, json['type']),
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      attachmentPaths:
          (json['attachmentPaths'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      modelUsed: json['modelUsed'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$ConversationMessageToJson(
  ConversationMessage instance,
) => <String, dynamic>{
  'id': instance.id,
  'conversationId': instance.conversationId,
  'type': _$MessageTypeEnumMap[instance.type]!,
  'content': instance.content,
  'timestamp': instance.timestamp.toIso8601String(),
  'attachmentPaths': instance.attachmentPaths,
  'modelUsed': instance.modelUsed,
  'metadata': instance.metadata,
};

const _$MessageTypeEnumMap = {
  MessageType.user: 'user',
  MessageType.ai: 'ai',
  MessageType.system: 'system',
};

ConversationTreeNode _$ConversationTreeNodeFromJson(
  Map<String, dynamic> json,
) => ConversationTreeNode(
  id: json['id'] as String,
  conversationId: json['conversationId'] as String,
  messageId: json['messageId'] as String?,
  summary: json['summary'] as String,
  children:
      (json['children'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  parentId: json['parentId'] as String?,
  level: (json['level'] as num).toInt(),
  createdAt: DateTime.parse(json['createdAt'] as String),
  isExpanded: json['isExpanded'] as bool? ?? false,
  isSelected: json['isSelected'] as bool? ?? false,
);

Map<String, dynamic> _$ConversationTreeNodeToJson(
  ConversationTreeNode instance,
) => <String, dynamic>{
  'id': instance.id,
  'conversationId': instance.conversationId,
  'messageId': instance.messageId,
  'summary': instance.summary,
  'children': instance.children,
  'parentId': instance.parentId,
  'level': instance.level,
  'createdAt': instance.createdAt.toIso8601String(),
  'isExpanded': instance.isExpanded,
  'isSelected': instance.isSelected,
};

ConversationTree _$ConversationTreeFromJson(Map<String, dynamic> json) =>
    ConversationTree(
      id: json['id'] as String,
      nodes: (json['nodes'] as Map<String, dynamic>).map(
        (k, e) => MapEntry(
          k,
          ConversationTreeNode.fromJson(e as Map<String, dynamic>),
        ),
      ),
      rootNodeId: json['rootNodeId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );

Map<String, dynamic> _$ConversationTreeToJson(ConversationTree instance) =>
    <String, dynamic>{
      'id': instance.id,
      'nodes': instance.nodes,
      'rootNodeId': instance.rootNodeId,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
    };
