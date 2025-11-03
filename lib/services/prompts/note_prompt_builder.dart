import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../models/note.dart';
import '../../models/relationship.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'ai_prompts.dart';
import 'prompt_models.dart';
import 'system_prompt_builder.dart';

/// Utilities to build note-centric prompt context and requests.
class NotePromptBuilder {
  NotePromptBuilder(this._databaseService);

  final DatabaseService _databaseService;

  /// Build a single-turn question answering prompt with separated system/user context.
  Future<PromptRequest> buildQuestionPrompt({
    required String question,
    required List<Note> contextNotes,
    bool useOwnKnowledge = false,
    List<PlatformFile> additionalAttachments = const [],
  }) async {
    final systemMessage = SystemPromptBuilder.build(
      taskContext:
          'You answer detailed questions about the user\'s notes. The next message contains note context with optional attachments. '
          '${useOwnKnowledge ? 'You may augment answers with general knowledge when helpful.' : 'Do not use outside knowledge unless the notes lack the answer.'}',
      guidelines: [
        'Prefer structured, concise explanations.',
        'Cite note relationships when relevant.',
        AIPrompts.mathFormulaGuidelines,
      ],
    );

    final contextMessage = await buildContextMessage(contextNotes);

    final buffer = StringBuffer();
    buffer.writeln('Question: $question');
    if (useOwnKnowledge) {
      buffer.writeln('You may incorporate relevant general knowledge.');
    } else {
      buffer.writeln('Answer strictly from the provided note context.');
    }

    final userMessage = PromptMessage(
      role: PromptRole.user,
      content: buffer.toString().trim(),
      attachments: additionalAttachments,
    );

    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: [contextMessage],
      conversationMessages: [userMessage],
    );
  }

  /// Build a prompt for transforming an existing note.
  Future<PromptRequest> buildTransformationPrompt({
    required Note note,
    required String instruction,
    List<PlatformFile> additionalAttachments = const [],
  }) async {
    final systemMessage = SystemPromptBuilder.build(
      taskContext:
          'Transform the provided note content based on the user instruction while respecting structure and metadata. '
          'The upcoming context message includes the original note, sub-notes, tags, and linked references.',
      guidelines: [
        'Preserve critical information unless explicitly told to remove it.',
        'Indicate any assumptions made during transformation.',
        AIPrompts.mathFormulaGuidelines,
      ],
    );

    final noteContextMessage = await buildContextMessage([note]);

    final buffer = StringBuffer();
    buffer.writeln('Transformation instruction: $instruction');
    buffer.writeln('Return only the transformed note content.');

    final userMessage = PromptMessage(
      role: PromptRole.user,
      content: buffer.toString().trim(),
      attachments: additionalAttachments,
    );

    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: [noteContextMessage],
      conversationMessages: [userMessage],
    );
  }

  /// Build a prompt for creating new notes from context and instruction.
  Future<PromptRequest> buildNewNoteCreationPrompt({
    required String userInstruction,
    required List<Note> contextNotes,
    List<PlatformFile> additionalAttachments = const [],
  }) async {
    final systemMessage = SystemPromptBuilder.build(
      taskContext:
          'Generate new notes based on user goals. The next message contains the existing note graph for context, including relationships.',
      guidelines: [
        'Output valid JSON as specified by the user.',
        'Create related notes that align with observed relationships.',
        AIPrompts.mathFormulaGuidelines,
      ],
    );

    final contextMessage = await buildContextMessage(contextNotes);

    final buffer = StringBuffer();
    buffer.writeln('User prompt: $userInstruction');
    buffer.writeln('Produce new notes in JSON following the specification.');

    final userMessage = PromptMessage(
      role: PromptRole.user,
      content: buffer.toString().trim(),
      attachments: additionalAttachments,
    );

    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: [contextMessage],
      conversationMessages: [userMessage],
    );
  }

  /// Build the textual context for the provided notes, including linked notes
  /// up to a limited depth.
  Future<String> buildNoteContext(List<Note> notes) async {
    if (notes.isEmpty) return '';

    final buffer = StringBuffer();
    final processedNoteIds = <String>{};

    for (final note in notes) {
      await _addNoteToContext(buffer, note, processedNoteIds, 0);
    }

    return buffer.toString();
  }

  Future<void> _addNoteToContext(
    StringBuffer buffer,
    Note note,
    Set<String> processed,
    int depth,
  ) async {
    if (processed.contains(note.id) || depth > 3) return;
    processed.add(note.id);

    final indent = '  ' * depth;
    buffer.writeln('$indent- ${note.title} (${note.type.name})');
    if (note.content.trim().isNotEmpty) {
      buffer.writeln('$indent  Content: ${note.content.trim()}');
    }

    if (note.tags.isNotEmpty) {
      buffer.writeln('$indent  Tags: ${note.tags.join(', ')}');
    }

    if (note.subNotes.isNotEmpty) {
      buffer.writeln('$indent  Sub-notes:');
      for (final subNote in note.subNotes) {
        buffer.writeln(
          '$indent    - ${subNote.name}${subNote.isCompleted ? " (completed)" : ''}: ${subNote.content}',
        );
      }
    }

    if (note.attachmentPaths.isNotEmpty) {
      buffer.writeln('$indent  Attachments:');
      for (final attachment in note.attachmentPaths) {
        buffer.writeln('$indent    - ${attachment.split('/').last}');
      }
    }

    final relationships = await _getRelationships(note.id);
    if (relationships.isNotEmpty) {
      buffer.writeln('$indent  Relationships:');
      for (final relationship in relationships) {
        final targetNoteId =
            relationship.fromNoteId == note.id ? relationship.toNoteId : relationship.fromNoteId;
        final targetNote = await _databaseService.getNote(targetNoteId);
        if (targetNote == null) continue;

        final direction = relationship.fromNoteId == note.id ? '→' : '←';
        buffer.writeln(
          '$indent    - ${relationship.type} $direction ${targetNote.title}',
        );

        await _addNoteToContext(buffer, targetNote, processed, depth + 1);
      }
    }
  }

  Future<List<Relationship>> _getRelationships(String noteId) async {
    try {
      return await _databaseService.getRelationships(noteId);
    } catch (e) {
      LoggerService.warning('Failed to load note relationships for $noteId: $e');
      return [];
    }
  }

  /// Load note attachments into [PlatformFile]s, avoiding duplicates.
  Future<List<PlatformFile>> loadNoteAttachments(List<Note> notes) async {
    final platformFiles = <PlatformFile>[];
    final processed = <String>{};

    for (final note in notes) {
      await _addNoteAttachments(platformFiles, note, processed);

      final relationships = await _getRelationships(note.id);
      for (final rel in relationships) {
        final linkedId = rel.fromNoteId == note.id ? rel.toNoteId : rel.fromNoteId;
        final linkedNote = await _databaseService.getNote(linkedId);
        if (linkedNote == null) {
          continue;
        }
        await _addNoteAttachments(platformFiles, linkedNote, processed);
      }
    }

    return platformFiles;
  }

  Future<void> _addNoteAttachments(
    List<PlatformFile> target,
    Note note,
    Set<String> processed,
  ) async {
    for (final path in note.attachmentPaths) {
      if (processed.contains(path)) continue;
      processed.add(path);

      try {
        final file = File(path);
        if (!file.existsSync()) continue;

        final bytes = await file.readAsBytes();
        target.add(
          PlatformFile(
            name: path.split('/').last,
            path: path,
            size: bytes.length,
            bytes: bytes,
          ),
        );
      } catch (e) {
        LoggerService.warning('Failed to read attachment $path: $e');
      }
    }
  }

  /// Build a context message that contains the aggregated notes and optional
  /// attachments.
  Future<PromptMessage> buildContextMessage(List<Note> notes) async {
    final context = await buildNoteContext(notes);
    final attachments = await loadNoteAttachments(notes);

    return PromptMessage(
      role: PromptRole.user,
      content: context.isEmpty
          ? 'No note context provided.'
          : 'Note context with linked relationships:\n$context',
      attachments: attachments,
      isContext: true,
    );
  }
}

