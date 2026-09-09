// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'filter.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Filter _$FilterFromJson(Map<String, dynamic> json) => Filter(
  id: json['id'] as String?,
  name: json['name'] as String,
  includeText: json['includeText'] as String?,
  includeTags:
      (json['includeTags'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const [],
  excludeTags:
      (json['excludeTags'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const [],
  noteTypes:
      (json['noteTypes'] as List<dynamic>?)
          ?.map((e) => $enumDecode(_$NoteTypeEnumMap, e))
          .toList() ??
      const [NoteType.note, NoteType.task],
  includeArchived: json['includeArchived'] as bool? ?? false,
  isPinned: json['isPinned'] as bool? ?? false,
  isSpace: json['isSpace'] as bool? ?? false,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

Map<String, dynamic> _$FilterToJson(Filter instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'includeText': instance.includeText,
  'includeTags': instance.includeTags,
  'excludeTags': instance.excludeTags,
  'noteTypes': instance.noteTypes.map((e) => _$NoteTypeEnumMap[e]!).toList(),
  'includeArchived': instance.includeArchived,
  'isPinned': instance.isPinned,
  'isSpace': instance.isSpace,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
};

const _$NoteTypeEnumMap = {NoteType.note: 'note', NoteType.task: 'task'};
