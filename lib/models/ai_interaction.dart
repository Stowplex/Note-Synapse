import 'package:json_annotation/json_annotation.dart';

part 'ai_interaction.g.dart';

enum AIInteractionType {
  @JsonValue('multi_note_qa')
  multiNoteQa,
  @JsonValue('note_transformation')
  noteTransformation,
  @JsonValue('new_note_creation')
  newNoteCreation,
}

@JsonSerializable()
class AIInteraction {
  final String id;
  final AIInteractionType type;
  final String prompt;
  final String response;
  final List<String> contextNoteIds;
  final String? transformedNoteId; // For note transformation
  final List<String>? createdNoteIds; // For new note creation
  final DateTime createdAt;
  final DateTime expiresAt; // 10 days from creation

  AIInteraction({
    required this.id,
    required this.type,
    required this.prompt,
    required this.response,
    required this.contextNoteIds,
    this.transformedNoteId,
    this.createdNoteIds,
    required this.createdAt,
    required this.expiresAt,
  });

  factory AIInteraction.fromJson(Map<String, dynamic> json) => _$AIInteractionFromJson(json);
  Map<String, dynamic> toJson() => _$AIInteractionToJson(this);

  AIInteraction copyWith({
    String? id,
    AIInteractionType? type,
    String? prompt,
    String? response,
    List<String>? contextNoteIds,
    String? transformedNoteId,
    List<String>? createdNoteIds,
    DateTime? createdAt,
    DateTime? expiresAt,
  }) {
    return AIInteraction(
      id: id ?? this.id,
      type: type ?? this.type,
      prompt: prompt ?? this.prompt,
      response: response ?? this.response,
      contextNoteIds: contextNoteIds ?? this.contextNoteIds,
      transformedNoteId: transformedNoteId ?? this.transformedNoteId,
      createdNoteIds: createdNoteIds ?? this.createdNoteIds,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
