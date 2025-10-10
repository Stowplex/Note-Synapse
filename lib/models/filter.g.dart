// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'filter.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Filter _$FilterFromJson(Map<String, dynamic> json) => Filter(
  id: json['id'] as String,
  name: json['name'] as String,
  includeText: json['includeText'] as String?,
  includeTags:
      (json['includeTags'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const [],
  includeArchived: json['includeArchived'] as bool? ?? false,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

Map<String, dynamic> _$FilterToJson(Filter instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'includeText': instance.includeText,
  'includeTags': instance.includeTags,
  'includeArchived': instance.includeArchived,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
};
