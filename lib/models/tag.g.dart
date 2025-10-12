// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tag.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Tag _$TagFromJson(Map<String, dynamic> json) => Tag(
  id: json['id'] as String,
  name: json['name'] as String,
  color: json['color'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
  usageCount: (json['usageCount'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$TagToJson(Tag instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'color': instance.color,
  'createdAt': instance.createdAt.toIso8601String(),
  'usageCount': instance.usageCount,
};
