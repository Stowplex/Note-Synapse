import 'package:json_annotation/json_annotation.dart';

part 'filter.g.dart';

@JsonSerializable()
class Filter {
  final String id;
  final String name;
  final String? includeText;
  final List<String> includeTags;
  final bool includeArchived;
  final bool isPinned;
  final DateTime createdAt;
  final DateTime updatedAt;

  Filter({
    required this.id,
    required this.name,
    this.includeText,
    this.includeTags = const [],
    this.includeArchived = false,
    this.isPinned = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Filter.fromJson(Map<String, dynamic> json) => _$FilterFromJson(json);
  Map<String, dynamic> toJson() => _$FilterToJson(this);

  Filter copyWith({
    String? id,
    String? name,
    String? includeText,
    List<String>? includeTags,
    bool? includeArchived,
    bool? isPinned,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Filter(
      id: id ?? this.id,
      name: name ?? this.name,
      includeText: includeText ?? this.includeText,
      includeTags: includeTags ?? this.includeTags,
      includeArchived: includeArchived ?? this.includeArchived,
      isPinned: isPinned ?? this.isPinned,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  bool get hasValidCriteria {
    return (includeText?.isNotEmpty == true) || includeTags.isNotEmpty;
  }

  bool isChildOf(Filter other) {
    if (id == other.id) return false;

    // 1. Check text criteria
    // If parent has text, child must have it as substring
    // If parent has NO text, this condition is trivially true
    if (other.includeText != null && other.includeText!.isNotEmpty) {
      if (includeText == null || !includeText!.contains(other.includeText!)) {
        return false;
      }
    }

    // 2. Check tag criteria
    // Parent's tags must be a subset of Child's tags
    // If parent has NO tags, this condition is trivially true
    if (other.includeTags.isNotEmpty) {
      if (!other.includeTags.every((tag) => includeTags.contains(tag))) {
        return false;
      }
    }

    return true;
  }
}
