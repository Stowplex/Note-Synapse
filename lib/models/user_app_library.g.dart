// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_app_library.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UserAppLibrary _$UserAppLibraryFromJson(Map<String, dynamic> json) =>
    UserAppLibrary(
      id: (json['id'] as num).toInt(),
      appUuid: json['appUuid'] as String,
      revisionId: (json['revisionId'] as num).toInt(),
      name: json['name'] as String,
      usageInstructions: json['usageInstructions'] as String?,
    );

Map<String, dynamic> _$UserAppLibraryToJson(UserAppLibrary instance) =>
    <String, dynamic>{
      'id': instance.id,
      'appUuid': instance.appUuid,
      'revisionId': instance.revisionId,
      'name': instance.name,
      'usageInstructions': instance.usageInstructions,
    };
