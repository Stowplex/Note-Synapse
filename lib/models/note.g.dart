// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'note.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Note _$NoteFromJson(Map<String, dynamic> json) => Note(
  id: json['id'] as String,
  title: json['title'] as String,
  content: json['content'] as String,
  type: $enumDecode(_$NoteTypeEnumMap, json['type']),
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  subNotes:
      (json['subNotes'] as List<dynamic>?)
          ?.map((e) => SubNote.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  tags:
      (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  attachmentPaths:
      (json['attachmentPaths'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const [],
  scheduledAt: json['scheduledAt'] as String?,
  completeBy: json['completeBy'] as String?,
  status: $enumDecodeNullable(_$TaskStatusEnumMap, json['status']),
  completionPercentage: (json['completionPercentage'] as num?)?.toDouble(),
  pinned: json['pinned'] as bool? ?? false,
  isArchived: json['isArchived'] as bool? ?? false,
  recurrenceRule: json['recurrenceRule'] as String?,
);

Map<String, dynamic> _$NoteToJson(Note instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'content': instance.content,
  'type': _$NoteTypeEnumMap[instance.type]!,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
  'subNotes': instance.subNotes,
  'tags': instance.tags,
  'attachmentPaths': instance.attachmentPaths,
  'scheduledAt': instance.scheduledAt,
  'completeBy': instance.completeBy,
  'status': _$TaskStatusEnumMap[instance.status],
  'completionPercentage': instance.completionPercentage,
  'pinned': instance.pinned,
  'isArchived': instance.isArchived,
  'recurrenceRule': instance.recurrenceRule,
};

const _$NoteTypeEnumMap = {NoteType.note: 'note', NoteType.task: 'task'};

const _$TaskStatusEnumMap = {
  TaskStatus.abandoned: 'abandoned',
  TaskStatus.complete: 'complete',
  TaskStatus.inProgress: 'in_progress',
  TaskStatus.todo: 'todo',
};

SubNote _$SubNoteFromJson(Map<String, dynamic> json) => SubNote(
  id: json['id'] as String,
  name: json['name'] as String,
  content: json['content'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
  isCompleted: json['isCompleted'] as bool? ?? false,
);

Map<String, dynamic> _$SubNoteToJson(SubNote instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'content': instance.content,
  'createdAt': instance.createdAt.toIso8601String(),
  'isCompleted': instance.isCompleted,
};
