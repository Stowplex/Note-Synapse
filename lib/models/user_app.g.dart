// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_app.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UserApp _$UserAppFromJson(Map<String, dynamic> json) => UserApp(
  id: json['id'] as String,
  name: json['name'] as String,
  description: json['description'] as String,
  steps: (json['steps'] as List<dynamic>).map((e) => e as String).toList(),
  htmlContent: json['htmlContent'] as String,
  appState: json['appState'] as Map<String, dynamic>?,
  type:
      $enumDecodeNullable(_$UserAppTypeEnumMap, json['type']) ??
      UserAppType.normal,
  selectedRevisionId: json['selectedRevisionId'] as String?,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
);

Map<String, dynamic> _$UserAppToJson(UserApp instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'description': instance.description,
  'steps': instance.steps,
  'htmlContent': instance.htmlContent,
  'appState': instance.appState,
  'type': _$UserAppTypeEnumMap[instance.type]!,
  'selectedRevisionId': instance.selectedRevisionId,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
};

const _$UserAppTypeEnumMap = {
  UserAppType.normal: 'normal',
  UserAppType.noteAction: 'noteAction',
};
