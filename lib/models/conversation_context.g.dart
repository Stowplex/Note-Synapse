// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'conversation_context.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ConversationContext _$ConversationContextFromJson(Map<String, dynamic> json) =>
    ConversationContext(
      conversationId: json['conversationId'] as String,
      title: json['title'] as String,
      noteIds: (json['noteIds'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      notes: (json['notes'] as List<dynamic>)
          .map((e) => Note.fromJson(e as Map<String, dynamic>))
          .toList(),
      initialContext: json['initialContext'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      messageCount: (json['messageCount'] as num).toInt(),
    );

Map<String, dynamic> _$ConversationContextToJson(
  ConversationContext instance,
) => <String, dynamic>{
  'conversationId': instance.conversationId,
  'title': instance.title,
  'noteIds': instance.noteIds,
  'notes': instance.notes,
  'initialContext': instance.initialContext,
  'createdAt': instance.createdAt.toIso8601String(),
  'messageCount': instance.messageCount,
};

ForkContextSelection _$ForkContextSelectionFromJson(
  Map<String, dynamic> json,
) => ForkContextSelection(
  forkMessageId: json['forkMessageId'] as String,
  availableContexts: (json['availableContexts'] as List<dynamic>)
      .map((e) => ConversationContext.fromJson(e as Map<String, dynamic>))
      .toList(),
  selectedContext: json['selectedContext'] == null
      ? null
      : ConversationContext.fromJson(
          json['selectedContext'] as Map<String, dynamic>,
        ),
  customTitle: json['customTitle'] as String?,
);

Map<String, dynamic> _$ForkContextSelectionToJson(
  ForkContextSelection instance,
) => <String, dynamic>{
  'forkMessageId': instance.forkMessageId,
  'availableContexts': instance.availableContexts,
  'selectedContext': instance.selectedContext,
  'customTitle': instance.customTitle,
};
