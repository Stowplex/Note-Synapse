import 'package:flutter/material.dart';
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
  static const String subnote = 'subnote';
  static const String parent = 'parent';
  static const String references = 'references';
  static const String expands = 'expands';
  static const String contradicts = 'contradicts';
  static const String supports = 'supports';
  
  static const List<String> predefined = [
    answers, 
    causality, 
    related, 
    subnote, 
    parent, 
    references, 
    expands, 
    contradicts, 
    supports
  ];
  
  static bool isValidType(String type) {
    return predefined.contains(type.toLowerCase());
  }
  
  static String getDisplayName(String type) {
    switch (type.toLowerCase()) {
      case 'answers':
        return 'Answers';
      case 'causality':
        return 'Causality';
      case 'related':
        return 'Related';
      case 'subnote':
        return 'Sub-note';
      case 'parent':
        return 'Parent';
      case 'references':
        return 'References';
      case 'expands':
        return 'Expands';
      case 'contradicts':
        return 'Contradicts';
      case 'supports':
        return 'Supports';
      default:
        return type;
    }
  }
  
  static IconData getIcon(String type) {
    switch (type.toLowerCase()) {
      case 'answers':
        return Icons.question_answer;
      case 'causality':
        return Icons.trending_up;
      case 'related':
        return Icons.link;
      case 'subnote':
        return Icons.subdirectory_arrow_right;
      case 'parent':
        return Icons.subdirectory_arrow_left;
      case 'references':
        return Icons.bookmark;
      case 'expands':
        return Icons.expand_more;
      case 'contradicts':
        return Icons.cancel;
      case 'supports':
        return Icons.thumb_up;
      default:
        return Icons.link;
    }
  }
}
