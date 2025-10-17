import 'package:json_annotation/json_annotation.dart';

part 'user_app_library.g.dart';

@JsonSerializable()
class UserAppLibrary {
  final int id;
  final String appUuid;
  final int revisionId;
  final String name;
  final String? usageInstructions;

  const UserAppLibrary({
    required this.id,
    required this.appUuid,
    required this.revisionId,
    required this.name,
    this.usageInstructions,
  });

  factory UserAppLibrary.fromJson(Map<String, dynamic> json) => _$UserAppLibraryFromJson(json);
  Map<String, dynamic> toJson() => _$UserAppLibraryToJson(this);

  UserAppLibrary copyWith({
    int? id,
    String? appUuid,
    int? revisionId,
    String? name,
    String? usageInstructions,
  }) {
    return UserAppLibrary(
      id: id ?? this.id,
      appUuid: appUuid ?? this.appUuid,
      revisionId: revisionId ?? this.revisionId,
      name: name ?? this.name,
      usageInstructions: usageInstructions ?? this.usageInstructions,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserAppLibrary && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
