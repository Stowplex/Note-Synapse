// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_revision.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AppRevision _$AppRevisionFromJson(Map<String, dynamic> json) => AppRevision(
  id: json['id'] as String,
  appId: json['appId'] as String,
  revisionNumber: (json['revisionNumber'] as num).toInt(),
  revisionTimestamp: DateTime.parse(json['revisionTimestamp'] as String),
  userPrompt: json['userPrompt'] as String,
  aiResponse: json['aiResponse'] as String,
  appCode: json['appCode'] as String,
);

Map<String, dynamic> _$AppRevisionToJson(AppRevision instance) =>
    <String, dynamic>{
      'id': instance.id,
      'appId': instance.appId,
      'revisionNumber': instance.revisionNumber,
      'revisionTimestamp': instance.revisionTimestamp.toIso8601String(),
      'userPrompt': instance.userPrompt,
      'aiResponse': instance.aiResponse,
      'appCode': instance.appCode,
    };
