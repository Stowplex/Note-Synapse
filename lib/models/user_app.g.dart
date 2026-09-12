// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_app.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UserApp _$UserAppFromJson(Map<String, dynamic> json) => UserApp(
  id: json['id'] as String,
  uuid: json['uuid'] as String,
  name: json['name'] as String,
  description: json['description'] as String,
  steps: (json['steps'] as List<dynamic>).map((e) => e as String).toList(),
  htmlContent: json['htmlContent'] as String,
  appState: json['appState'] as Map<String, dynamic>?,
  type:
      $enumDecodeNullable(_$UserAppTypeEnumMap, json['type']) ??
      UserAppType.normal,
  selectedRevisionId: json['selectedRevisionId'] as String?,
  author: json['author'] as String? ?? '',
  license: json['license'] as String? ?? '',
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  libraries: (json['libraries'] as List<dynamic>?)
      ?.map((e) => UserAppLibraryInfo.fromJson(e as Map<String, dynamic>))
      .toList(),
  i18n: json['i18n'] == null
      ? const {}
      : userAppI18nFromJson(json['i18n']),
);

Map<String, dynamic> _$UserAppToJson(UserApp instance) => <String, dynamic>{
  'id': instance.id,
  'uuid': instance.uuid,
  'name': instance.name,
  'description': instance.description,
  'steps': instance.steps,
  'htmlContent': instance.htmlContent,
  'appState': instance.appState,
  'type': _$UserAppTypeEnumMap[instance.type]!,
  'selectedRevisionId': instance.selectedRevisionId,
  'author': instance.author,
  'license': instance.license,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt.toIso8601String(),
  'libraries': instance.libraries,
  'i18n': userAppI18nToJson(instance.i18n),
};

const _$UserAppTypeEnumMap = {
  UserAppType.normal: 'normal',
  UserAppType.noteAction: 'noteAction',
  UserAppType.aiTool: 'aiTool',
};
