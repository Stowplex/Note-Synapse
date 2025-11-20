import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../models/note.dart';
import '../../models/attachment.dart';
import '../../models/relationship.dart';
import '../../utils/file_utils.dart';
import '../../utils/prompt_injection_protection.dart';
import '../../utils/remote_image_storage.dart';
import '../../utils/remote_image_utils.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'ai_prompts.dart';
import 'prompt_models.dart';
import 'prompt_configuration_service.dart';
import 'registrations/note_prompt_configuration.dart';
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
    final relationshipGuidance = contextNotes.isEmpty
        ? null
        : 'Note relationship reminders:\n${AIPrompts.relationshipGuidelines}';

    final guidelines = <String>[
      'Prefer structured, concise explanations.',
      if (relationshipGuidance != null) relationshipGuidance,
      if (useOwnKnowledge)
        'Use relevant general knowledge only after exhausting the provided notes, and flag outside information explicitly.'
      else
        'Do not use knowledge beyond the provided materials.',
      AIPrompts.mathFormulaGuidelines,
    ];

    final systemMessage = SystemPromptBuilder.build(
      taskContext:
          'You answer detailed questions about the user\'s notes. The next message contains note context with optional attachments. '
          '${useOwnKnowledge ? 'You may augment answers with general knowledge when helpful.' : 'Do not use outside knowledge unless the notes lack the answer.'}',
      guidelines: [
        ...guidelines,
        AIPrompts.promptInjectionProtectionGuidelines,
      ],
    );

    final contextMessage = await buildContextMessage(contextNotes);
    final contextMessages = <PromptMessage>[
      if (contextMessage.content.trim().isNotEmpty ||
          contextMessage.attachments.isNotEmpty)
        contextMessage,
    ];

    final buffer = StringBuffer();
    buffer.writeln('Question: "$question"');
    if (contextNotes.isNotEmpty) {
      buffer.writeln('Base your answer on the supplied note context.');
    } else {
      buffer.writeln(
        'No note context is provided. Use the system guidance to determine how to answer.',
      );
    }
    if (useOwnKnowledge) {
      buffer.writeln(
        'Supplement with general knowledge only when it clarifies gaps, and identify assumptions.',
      );
    } else {
      buffer.writeln(
        'Do not rely on information outside the provided materials.',
      );
    }
    buffer.writeln(
      'If the answer cannot be found, state explicitly that the information is unavailable.',
    );

    final userMessage = PromptMessage(
      role: PromptRole.user,
      content: buffer.toString().trim(),
      attachments: additionalAttachments,
    );

    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessages,
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
        AIPrompts.promptInjectionProtectionGuidelines,
      ],
    );

    final noteContextMessage = await buildContextMessage([note]);
    final contextMessages = <PromptMessage>[
      if (noteContextMessage.content.trim().isNotEmpty ||
          noteContextMessage.attachments.isNotEmpty)
        noteContextMessage,
    ];

    final buffer = StringBuffer();
    buffer.writeln('Transformation instruction: "$instruction"');
    buffer.writeln(
      'Apply the changes while preserving the note\'s existing structure (title, sections, sub-notes, tags, metadata) unless explicitly instructed otherwise.',
    );
    buffer.writeln(
      'Incorporate relevant linked note context and attachments when appropriate.',
    );
    buffer.writeln('Return only the transformed note content.');

    final transformationAddOn = PromptConfigurationService.instance.getValue(
      NotePromptConfiguration.transformationAddendumId,
    );
    if (transformationAddOn != null && transformationAddOn.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(transformationAddOn.trim());
    }

    final userMessage = PromptMessage(
      role: PromptRole.user,
      content: buffer.toString().trim(),
      attachments: additionalAttachments,
    );

    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessages,
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
        'Output valid JSON exactly as specified below without extra prose or markdown fences.',
        'Derive relative dates using the current date/time context before responding.',
        'Create related notes that align with observed relationships.',
        AIPrompts.mathFormulaGuidelines,
        AIPrompts.promptInjectionProtectionGuidelines,
      ],
    );

    final contextMessage = await buildContextMessage(contextNotes);
    final contextMessages = <PromptMessage>[
      if (contextMessage.content.trim().isNotEmpty ||
          contextMessage.attachments.isNotEmpty)
        contextMessage,
    ];

    final buffer = StringBuffer();
    buffer.writeln(
      'Use the provided note context (previous message) and the instruction below to create new notes.',
    );
    buffer.writeln();
    buffer.writeln('User Prompt: "$userInstruction"');
    buffer.writeln();
    buffer.writeln('Return a single JSON object with the following structure:');
    buffer.writeln('''{
  "notes": [
    {
      "title": "Note Title",
      "content": "Note content here",
      "type": "note" or "task",
      "tags": ["tag1", "tag2"],
      "subNotes": [
        {
          "name": "Sub-note name",
          "content": "Sub-note content",
          "isCompleted": false
        }
      ],
      "scheduledAt": "YYYY-MM-DD" (only for tasks),
      "completeBy": "YYYY-MM-DD" (only for tasks),
      "status": "todo" (only for tasks)
    }
  ]
}''');
    buffer.writeln();
    buffer.writeln('Critical JSON rules:');
    buffer.writeln(
      '1. The response must be valid JSON with no additional commentary.',
    );
    buffer.writeln(
      '2. Escape all quotes, backslashes, newlines, and control characters.',
    );
    buffer.writeln(
      '3. When using LaTeX (e.g., \\( E = mc^2 \\)), double-escape backslashes (\\\\) to keep JSON valid.',
    );
    buffer.writeln('4. Preserve arrays even when empty (e.g., "tags": []).');
    buffer.writeln();
    buffer.writeln('Additional requirements:');
    buffer.writeln(
      '- Calculate relative dates (e.g., "next Wednesday") using the current date/time provided in the system message.',
    );
    buffer.writeln(
      '- Ensure each generated note relates to the user prompt and the supplied context hierarchy.',
    );
    buffer.writeln(
      '- Reference note relationships (answers, causality, related, etc.) when deciding how new notes connect.',
    );
    buffer.writeln(
      '- Follow the LaTeX formatting guidance from the system message when including formulas.',
    );

    final creationAddOn = PromptConfigurationService.instance.getValue(
      NotePromptConfiguration.creationAddendumId,
    );
    if (creationAddOn != null && creationAddOn.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(creationAddOn.trim());
    }

    final userMessage = PromptMessage(
      role: PromptRole.user,
      content: buffer.toString().trim(),
      attachments: additionalAttachments,
    );

    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessages,
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
    // Quote title to prevent injection
    final safeTitle = PromptInjectionProtection.formatTitleAsData(note.title);
    buffer.writeln('$indent- Title: $safeTitle (${note.type.name})');
    if (note.content.trim().isNotEmpty) {
      // Quote content as data to prevent prompt injection
      buffer.writeln('$indent  Content (data only):');
      buffer.writeln(
        '$indent  ${PromptInjectionProtection.formatNoteContentAsData(note.content.trim())}',
      );
    }

    if (note.tags.isNotEmpty) {
      buffer.writeln('$indent  Tags: ${note.tags.join(', ')}');
    }

    if (note.subNotes.isNotEmpty) {
      buffer.writeln('$indent  Sub-notes:');
      for (final subNote in note.subNotes) {
        // Quote sub-note content as data
        final safeSubNoteContent =
            PromptInjectionProtection.formatNoteContentAsData(subNote.content);
        buffer.writeln(
          '$indent    - ${subNote.name}${subNote.isCompleted ? " (completed)" : ''}:',
        );
        buffer.writeln('$indent      $safeSubNoteContent');
      }
    }

    // Fetch attachments from DB to check includeInAIContext flag
    try {
      final attachments = await _databaseService.getAttachmentsForNote(note.id);
      final validAttachments = attachments
          .where((a) => a.includeInAIContext)
          .toList();

      if (validAttachments.isNotEmpty) {
        buffer.writeln('$indent  Attachments:');
        for (final attachment in validAttachments) {
          buffer.writeln('$indent    - ${attachment.fileName}');
        }
      }
    } catch (e) {
      LoggerService.warning('Failed to load attachments for context: $e');
      // Fallback to note.attachmentPaths if DB fetch fails, but we can't filter
      if (note.attachmentPaths.isNotEmpty) {
        buffer.writeln('$indent  Attachments:');
        for (final attachment in note.attachmentPaths) {
          buffer.writeln('$indent    - ${attachment.split('/').last}');
        }
      }
    }

    final relationships = await _getRelationships(note.id);
    if (relationships.isNotEmpty) {
      buffer.writeln('$indent  Relationships:');
      for (final relationship in relationships) {
        final targetNoteId = relationship.fromNoteId == note.id
            ? relationship.toNoteId
            : relationship.fromNoteId;
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
      LoggerService.warning(
        'Failed to load note relationships for $noteId: $e',
      );
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
        final linkedId = rel.fromNoteId == note.id
            ? rel.toNoteId
            : rel.fromNoteId;
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
    try {
      final attachments = await _databaseService.getAttachmentsForNote(note.id);

      for (final attachment in attachments) {
        if (!attachment.includeInAIContext) continue;

        final fullPath = await FileUtils.getFullFilePath(
          attachment.filePath,
          attachment.isRelativePath,
        );

        if (processed.contains(fullPath)) continue;
        processed.add(fullPath);

        try {
          final file = File(fullPath);
          if (!file.existsSync()) continue;

          final bytes = await file.readAsBytes();
          target.add(
            PlatformFile(
              name: attachment.fileName,
              path: fullPath,
              size: bytes.length,
              bytes: bytes,
            ),
          );
        } catch (e) {
          LoggerService.warning('Failed to read attachment $fullPath: $e');
        }
      }
    } catch (e) {
      LoggerService.warning(
        'Failed to load attachments for note ${note.id}: $e',
      );
    }

    await _addRemoteImageAttachments(target, note, processed);
  }

  Future<void> _addRemoteImageAttachments(
    List<PlatformFile> target,
    Note note,
    Set<String> processed,
  ) async {
    final remoteImages = RemoteImageUtils.extractRemoteImages(note.content);
    if (remoteImages.isEmpty) {
      return;
    }

    for (final image in remoteImages) {
      try {
        final absolutePath = await RemoteImageStorage.resolveAbsolutePath(
          noteId: note.id,
          imageUrl: image.url,
        );
        if (absolutePath == null || processed.contains(absolutePath)) {
          continue;
        }
        final file = File(absolutePath);
        if (!await file.exists()) {
          continue;
        }
        processed.add(absolutePath);
        final bytes = await file.readAsBytes();
        target.add(
          PlatformFile(
            name: absolutePath.split('/').last,
            path: absolutePath,
            size: bytes.length,
            bytes: bytes,
          ),
        );
      } catch (e) {
        LoggerService.warning(
          'Failed to include cached remote image for note ${note.id}: $e',
        );
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
          ? ''
          : 'Note context with linked relationships:\n$context',
      attachments: attachments,
      isContext: true,
    );
  }
}
