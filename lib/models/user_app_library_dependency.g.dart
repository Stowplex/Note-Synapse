// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_app_library_dependency.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UserAppLibraryDependency _$UserAppLibraryDependencyFromJson(
  Map<String, dynamic> json,
) => UserAppLibraryDependency(
  id: (json['id'] as num).toInt(),
  originalUrl: json['originalUrl'] as String?,
  localPath: json['localPath'] as String,
  bytes: (json['bytes'] as List<dynamic>)
      .map((e) => (e as num).toInt())
      .toList(),
  libraryId: (json['libraryId'] as num).toInt(),
);

Map<String, dynamic> _$UserAppLibraryDependencyToJson(
  UserAppLibraryDependency instance,
) => <String, dynamic>{
  'id': instance.id,
  'originalUrl': instance.originalUrl,
  'localPath': instance.localPath,
  'bytes': instance.bytes,
  'libraryId': instance.libraryId,
};
