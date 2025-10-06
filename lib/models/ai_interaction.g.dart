// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_interaction.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AIInteraction _$AIInteractionFromJson(Map<String, dynamic> json) =>
    AIInteraction(
      id: json['id'] as String,
      type: $enumDecode(_$AIInteractionTypeEnumMap, json['type']),
      prompt: json['prompt'] as String,
      response: json['response'] as String,
      contextNoteIds: (json['contextNoteIds'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      transformedNoteId: json['transformedNoteId'] as String?,
      createdNoteIds: (json['createdNoteIds'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );

Map<String, dynamic> _$AIInteractionToJson(AIInteraction instance) =>
    <String, dynamic>{
      'id': instance.id,
      'type': _$AIInteractionTypeEnumMap[instance.type]!,
      'prompt': instance.prompt,
      'response': instance.response,
      'contextNoteIds': instance.contextNoteIds,
      'transformedNoteId': instance.transformedNoteId,
      'createdNoteIds': instance.createdNoteIds,
      'createdAt': instance.createdAt.toIso8601String(),
      'expiresAt': instance.expiresAt.toIso8601String(),
    };

const _$AIInteractionTypeEnumMap = {
  AIInteractionType.noteQa: 'note_qa',
  AIInteractionType.noteTransformation: 'note_transformation',
  AIInteractionType.newNoteCreation: 'new_note_creation',
};
