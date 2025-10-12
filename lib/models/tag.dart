import 'package:json_annotation/json_annotation.dart';

part 'tag.g.dart';

@JsonSerializable()
class Tag {
  final String id;
  final String name;
  final String color; // Hex color code
  final DateTime createdAt;
  final int usageCount;

  Tag({
    required this.id,
    required this.name,
    required this.color,
    required this.createdAt,
    this.usageCount = 0,
  });

  factory Tag.fromJson(Map<String, dynamic> json) => _$TagFromJson(json);
  Map<String, dynamic> toJson() => _$TagToJson(this);

  Tag copyWith({
    String? id,
    String? name,
    String? color,
    DateTime? createdAt,
    int? usageCount,
  }) {
    return Tag(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      createdAt: createdAt ?? this.createdAt,
      usageCount: usageCount ?? this.usageCount,
    );
  }
}
