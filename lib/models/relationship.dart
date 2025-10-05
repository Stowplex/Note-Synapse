import 'package:json_annotation/json_annotation.dart';

part 'relationship.g.dart';

@JsonSerializable()
class Relationship {
  final String id;
  final String fromNoteId;
  final String toNoteId;
  final String type;
  final DateTime createdAt;

  Relationship({
    required this.id,
    required this.fromNoteId,
    required this.toNoteId,
    required this.type,
    required this.createdAt,
  });

  factory Relationship.fromJson(Map<String, dynamic> json) => _$RelationshipFromJson(json);
  Map<String, dynamic> toJson() => _$RelationshipToJson(this);

  Relationship copyWith({
    String? id,
    String? fromNoteId,
    String? toNoteId,
    String? type,
    DateTime? createdAt,
  }) {
    return Relationship(
      id: id ?? this.id,
      fromNoteId: fromNoteId ?? this.fromNoteId,
      toNoteId: toNoteId ?? this.toNoteId,
      type: type ?? this.type,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

// Predefined relationship types
class RelationshipType {
  static const String answers = 'answers';
  static const String causality = 'causality';
  static const String related = 'related';
  
  static const List<String> predefined = [answers, causality, related];
  
  static bool isValidType(String type) {
    return predefined.contains(type.toLowerCase());
  }
}
