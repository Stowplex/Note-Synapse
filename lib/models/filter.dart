import 'package:json_annotation/json_annotation.dart';
import 'note.dart';

part 'filter.g.dart';

@JsonSerializable()
class Filter {
  final String id;
  final String name;
  final String? includeText;
  final List<String> includeTags;
  final List<String> excludeTags;
  final List<NoteType> noteTypes;
  final bool includeArchived;
  final bool isPinned;
  final DateTime createdAt;
  final DateTime updatedAt;

  Filter({
    required this.id,
    required this.name,
    this.includeText,
    this.includeTags = const [],
    this.excludeTags = const [],
    this.noteTypes = const [NoteType.note, NoteType.task],
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
    List<String>? excludeTags,
    List<NoteType>? noteTypes,
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
      excludeTags: excludeTags ?? this.excludeTags,
      noteTypes: noteTypes ?? this.noteTypes,
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

    // Check if fully equal to avoid hierarchy of equals
    if (_isContentEqual(other)) return false;

    // 1. Check text criteria
    // Include Text in A is a substring of B
    if (other.includeText != null && other.includeText!.isNotEmpty) {
      if (includeText == null || !includeText!.contains(other.includeText!)) {
        return false;
      }
    }

    // 2. Check tag criteria
    // Included tags in A is a subset of B
    if (other.includeTags.isNotEmpty) {
      if (!other.includeTags.every((tag) => includeTags.contains(tag))) {
        return false;
      }
    }

    // 3. Not included tags in B is a subset of A
    // (B is 'this', A is 'other')
    if (excludeTags.isNotEmpty) {
      if (!excludeTags.every((tag) => other.excludeTags.contains(tag))) {
        return false;
      }
    }

    // 4. Note type in A is a superset of B
    // A (other) superset of B (this)
    if (!noteTypes.every((type) => other.noteTypes.contains(type))) {
      return false;
    }

    // 5. Include archived in B is either not checked or both A and B are checked
    if (includeArchived && !other.includeArchived) {
      return false;
    }

    return true;
  }

  bool _isContentEqual(Filter other) {
    if (includeText != other.includeText) return false;
    if (!_areStringListsEqual(includeTags, other.includeTags)) return false;
    if (!_areStringListsEqual(excludeTags, other.excludeTags)) return false;
    if (!_areNoteTypeListsEqual(noteTypes, other.noteTypes)) return false;
    if (includeArchived != other.includeArchived) return false;
    return true;
  }

  bool _areStringListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final setA = Set.from(a);
    final setB = Set.from(b);
    return setA.containsAll(setB) && setB.containsAll(setA);
  }

  bool _areNoteTypeListsEqual(List<NoteType> a, List<NoteType> b) {
    if (a.length != b.length) return false;
    final setA = Set.from(a);
    final setB = Set.from(b);
    return setA.containsAll(setB) && setB.containsAll(setA);
  }
}
