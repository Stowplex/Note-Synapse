import 'package:json_annotation/json_annotation.dart';

part 'user_app.g.dart';

enum UserAppType {
  normal,
  noteAction,
}

@JsonSerializable()
class UserApp {
  final String id;
  final String name;
  final String description;
  final List<String> steps;
  final String htmlContent;
  final Map<String, dynamic>? appState;
  final UserAppType type;
  final DateTime createdAt;
  final DateTime updatedAt;

  const UserApp({
    required this.id,
    required this.name,
    required this.description,
    required this.steps,
    required this.htmlContent,
    this.appState,
    this.type = UserAppType.normal,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserApp.fromJson(Map<String, dynamic> json) => _$UserAppFromJson(json);
  Map<String, dynamic> toJson() => _$UserAppToJson(this);

  UserApp copyWith({
    String? id,
    String? name,
    String? description,
    List<String>? steps,
    String? htmlContent,
    Map<String, dynamic>? appState,
    UserAppType? type,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return UserApp(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      steps: steps ?? this.steps,
      htmlContent: htmlContent ?? this.htmlContent,
      appState: appState ?? this.appState,
      type: type ?? this.type,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
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
