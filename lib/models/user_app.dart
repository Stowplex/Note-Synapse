import 'package:json_annotation/json_annotation.dart';

part 'user_app.g.dart';

enum UserAppType {
  normal,
  noteAction,
}

class UserAppLibraryInfo {
  final String name;
  final String? usage;
  final List<String> links;

  const UserAppLibraryInfo({
    required this.name,
    this.usage,
    required this.links,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'usage': usage,
    'links': links,
  };

  factory UserAppLibraryInfo.fromJson(Map<String, dynamic> json) => UserAppLibraryInfo(
    name: json['name'] as String,
    usage: json['usage'] as String?,
    links: (json['links'] as List<dynamic>).cast<String>(),
  );
}

@JsonSerializable()
class UserApp {
  final String id;
  final String uuid;
  final String name;
  final String description;
  final List<String> steps;
  final String htmlContent;
  final Map<String, dynamic>? appState;
  final UserAppType type;
  final String? selectedRevisionId;
  final String author;
  final String license;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<UserAppLibraryInfo>? libraries;

  const UserApp({
    required this.id,
    required this.uuid,
    required this.name,
    required this.description,
    required this.steps,
    required this.htmlContent,
    this.appState,
    this.type = UserAppType.normal,
    this.selectedRevisionId,
    this.author = '',
    this.license = '',
    required this.createdAt,
    required this.updatedAt,
    this.libraries,
  });

  factory UserApp.fromJson(Map<String, dynamic> json) => _$UserAppFromJson(json);
  Map<String, dynamic> toJson() => _$UserAppToJson(this);

  UserApp copyWith({
    String? id,
    String? uuid,
    String? name,
    String? description,
    List<String>? steps,
    String? htmlContent,
    Map<String, dynamic>? appState,
    UserAppType? type,
    String? selectedRevisionId,
    String? author,
    String? license,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<UserAppLibraryInfo>? libraries,
  }) {
    return UserApp(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      description: description ?? this.description,
      steps: steps ?? this.steps,
      htmlContent: htmlContent ?? this.htmlContent,
      appState: appState ?? this.appState,
      type: type ?? this.type,
      selectedRevisionId: selectedRevisionId ?? this.selectedRevisionId,
      author: author ?? this.author,
      license: license ?? this.license,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      libraries: libraries ?? this.libraries,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserApp && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
