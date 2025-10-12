// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'relationship.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Relationship _$RelationshipFromJson(Map<String, dynamic> json) => Relationship(
  id: json['id'] as String,
  fromNoteId: json['fromNoteId'] as String,
  toNoteId: json['toNoteId'] as String,
  type: json['type'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
);

Map<String, dynamic> _$RelationshipToJson(Relationship instance) =>
    <String, dynamic>{
      'id': instance.id,
      'fromNoteId': instance.fromNoteId,
      'toNoteId': instance.toNoteId,
      'type': instance.type,
      'createdAt': instance.createdAt.toIso8601String(),
    };
