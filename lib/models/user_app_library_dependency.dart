import 'package:json_annotation/json_annotation.dart';

part 'user_app_library_dependency.g.dart';

@JsonSerializable()
class UserAppLibraryDependency {
  final int id;
  final String? originalUrl;
  final String localPath;
  final List<int> bytes;
  final int libraryId;

  const UserAppLibraryDependency({
    required this.id,
    this.originalUrl,
    required this.localPath,
    required this.bytes,
    required this.libraryId,
  });

  factory UserAppLibraryDependency.fromJson(Map<String, dynamic> json) => _$UserAppLibraryDependencyFromJson(json);
  Map<String, dynamic> toJson() => _$UserAppLibraryDependencyToJson(this);

  UserAppLibraryDependency copyWith({
    int? id,
    String? originalUrl,
    String? localPath,
    List<int>? bytes,
    int? libraryId,
  }) {
    return UserAppLibraryDependency(
      id: id ?? this.id,
      originalUrl: originalUrl ?? this.originalUrl,
      localPath: localPath ?? this.localPath,
      bytes: bytes ?? this.bytes,
      libraryId: libraryId ?? this.libraryId,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserAppLibraryDependency && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
