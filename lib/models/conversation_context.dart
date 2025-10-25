import 'package:json_annotation/json_annotation.dart';
import 'conversation.dart';
import 'note.dart';

part 'conversation_context.g.dart';

@JsonSerializable()
class ConversationContext {
  final String conversationId;
  final String title;
  final List<String> noteIds;
  final List<Note> notes;
  final String? initialContext; // First user message or context summary
  final DateTime createdAt;
  final int messageCount;

  ConversationContext({
    required this.conversationId,
    required this.title,
    required this.noteIds,
    required this.notes,
    this.initialContext,
    required this.createdAt,
    required this.messageCount,
  });

  factory ConversationContext.fromJson(Map<String, dynamic> json) => _$ConversationContextFromJson(json);
  Map<String, dynamic> toJson() => _$ConversationContextToJson(this);

  // Generate a summary for display in selection dialog
  String get displaySummary {
    final noteNames = notes.map((n) => n.title).join(', ');
    final contextPreview = initialContext != null 
        ? 'Context: ${initialContext!.length > 100 ? '${initialContext!.substring(0, 100)}...' : initialContext!}'
        : 'No initial context';
    
    return 'Notes: $noteNames\n$contextPreview\nMessages: $messageCount';
  }

  // Check if this context conflicts with another
  bool hasConflictingNotes(ConversationContext other) {
    final thisNoteIds = noteIds.toSet();
    final otherNoteIds = other.noteIds.toSet();
    
    // Check if they have different note sets
    if (!thisNoteIds.containsAll(otherNoteIds) || !otherNoteIds.containsAll(thisNoteIds)) {
      return true;
    }
    
    // Check if initial contexts are different
    if (initialContext != other.initialContext) {
      return true;
    }
    
    return false;
  }
}

@JsonSerializable()
class ForkContextSelection {
  final String forkMessageId;
  final List<ConversationContext> availableContexts;
  final ConversationContext? selectedContext;
  final String? customTitle;

  ForkContextSelection({
    required this.forkMessageId,
    required this.availableContexts,
    this.selectedContext,
    this.customTitle,
  });

  factory ForkContextSelection.fromJson(Map<String, dynamic> json) => _$ForkContextSelectionFromJson(json);
  Map<String, dynamic> toJson() => _$ForkContextSelectionToJson(this);

  bool get hasConflictingContexts => availableContexts.length > 1 && 
      availableContexts.any((context) => 
          availableContexts.any((other) => 
              context != other && context.hasConflictingNotes(other)));

  bool get requiresUserSelection => hasConflictingContexts || selectedContext == null;

  ForkContextSelection copyWith({
    String? forkMessageId,
    List<ConversationContext>? availableContexts,
    ConversationContext? selectedContext,
    String? customTitle,
  }) {
    return ForkContextSelection(
      forkMessageId: forkMessageId ?? this.forkMessageId,
      availableContexts: availableContexts ?? this.availableContexts,
      selectedContext: selectedContext ?? this.selectedContext,
      customTitle: customTitle ?? this.customTitle,
    );
  }
}
