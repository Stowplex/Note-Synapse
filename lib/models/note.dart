import 'package:json_annotation/json_annotation.dart';

part 'note.g.dart';

enum NoteType {
  @JsonValue('note')
  note,
  @JsonValue('task')
  task,
}

enum TaskStatus {
  @JsonValue('abandoned')
  abandoned,
  @JsonValue('complete')
  complete,
  @JsonValue('in_progress')
  inProgress,
  @JsonValue('todo')
  todo,
}

@JsonSerializable()
class Note {
  final String id;
  final String title;
  final String content;
  final NoteType type;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<SubNote> subNotes;
  final List<String> tags;
  final List<String> attachmentPaths;
  final String?
  scheduledAt; // For tasks only - when the task is scheduled to start
  final String?
  completeBy; // For tasks only - when the task needs to be completed
  final TaskStatus? status; // For tasks only
  final double? completionPercentage; // For tasks only
  final bool pinned; // Whether the note is pinned to the top
  final bool isArchived; // Whether the note is archived
  final String? recurrenceRule; // JSON string for recurrence rules
  final String? metadata; // JSON string for metadata

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    required this.createdAt,
    required this.updatedAt,
    this.subNotes = const [],
    this.tags = const [],
    this.attachmentPaths = const [],
    this.scheduledAt,
    this.completeBy,
    this.status,
    this.completionPercentage,
    this.pinned = false,
    this.isArchived = false,
    this.recurrenceRule,
    this.metadata,
  });

  factory Note.fromJson(Map<String, dynamic> json) => _$NoteFromJson(json);
  Map<String, dynamic> toJson() => _$NoteToJson(this);

  Note copyWith({
    String? id,
    String? title,
    String? content,
    NoteType? type,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<SubNote>? subNotes,
    List<String>? tags,
    List<String>? attachmentPaths,
    String? scheduledAt,
    String? completeBy,
    TaskStatus? status,
    double? completionPercentage,
    bool? pinned,
    bool? isArchived,
    String? recurrenceRule,
    String? metadata,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      type: type ?? this.type,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      subNotes: subNotes ?? this.subNotes,
      tags: tags ?? this.tags,
      attachmentPaths: attachmentPaths ?? this.attachmentPaths,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      completeBy: completeBy ?? this.completeBy,
      status: status ?? this.status,
      completionPercentage: completionPercentage ?? this.completionPercentage,
      pinned: pinned ?? this.pinned,
      isArchived: isArchived ?? this.isArchived,
      recurrenceRule: recurrenceRule ?? this.recurrenceRule,
      metadata: metadata ?? this.metadata,
    );
  }

  bool get isTask => type == NoteType.task;
  bool get isCompleted => status == TaskStatus.complete;
  bool get isAbandoned => status == TaskStatus.abandoned;
  bool get isInProgress => status == TaskStatus.inProgress;
  bool get isTodo => status == TaskStatus.todo;
}

@JsonSerializable()
class SubNote {
  final String id;
  final String name;
  final String content;
  final DateTime createdAt;
  final bool isCompleted;

  SubNote({
    required this.id,
    required this.name,
    required this.content,
    required this.createdAt,
    this.isCompleted = false,
  });

  factory SubNote.fromJson(Map<String, dynamic> json) =>
      _$SubNoteFromJson(json);
  Map<String, dynamic> toJson() => _$SubNoteToJson(this);

  SubNote copyWith({
    String? id,
    String? name,
    String? content,
    DateTime? createdAt,
    bool? isCompleted,
  }) {
    return SubNote(
      id: id ?? this.id,
      name: name ?? this.name,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }
}
