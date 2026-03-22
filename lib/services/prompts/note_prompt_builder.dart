import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';

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

  /// Shared transformation guidelines for both note-level and block-level transforms.
  static List<String> get _transformationGuidelines => [
    'Preserve critical information unless explicitly told to remove it.',
    'Indicate any assumptions made during transformation.',
    AIPrompts.mathFormulaGuidelines,
    AIPrompts.promptInjectionProtectionGuidelines,
  ];

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
      guidelines: _transformationGuidelines,
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

  /// Build a prompt for transforming a markdown block (not a full note).
  /// Synchronous because block-level transforms don't need DB lookups for context.
  PromptRequest buildBlockTransformationPrompt({
    required String blockContent,
    required String instruction,
  }) {
    final systemMessage = SystemPromptBuilder.build(
      taskContext:
          'Transform the provided markdown block based on the user instruction. '
          'Return only the transformed block content.',
      guidelines: _transformationGuidelines,
    );

    final buffer = StringBuffer();
    buffer.writeln('Transformation instruction: "$instruction"');
    buffer.writeln();
    buffer.writeln('Block content to transform:');
    buffer.writeln(blockContent);

    final userMessage = PromptMessage(
      role: PromptRole.user,
      content: buffer.toString().trim(),
    );

    return PromptRequest(
      systemMessage: systemMessage,
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
    buffer.writeln('$indent- Title: $safeTitle');

    // Metadata section
    buffer.writeln('$indent  Metadata:');
    buffer.writeln('$indent    ID: ${note.id}');
    buffer.writeln('$indent    Type: ${note.type.name}');

    if (note.tags.isNotEmpty) {
      buffer.writeln('$indent    Tags: ${note.tags.join(', ')}');
    }

    if (note.isTask) {
      buffer.writeln('$indent    Status: ${note.status?.name ?? 'unknown'}');
      if (note.scheduledAt != null) {
        buffer.writeln('$indent    Scheduled: ${note.scheduledAt}');
      }
      if (note.completeBy != null) {
        buffer.writeln('$indent    Complete By: ${note.completeBy}');
      }
    }

    if (note.content.trim().isNotEmpty) {
      // Quote content as data to prevent prompt injection
      buffer.writeln('$indent  Content:');
      buffer.writeln(
        '$indent  ${PromptInjectionProtection.formatNoteContentAsData(note.content.trim())}',
      );
    }

    if (note.subNotes.isNotEmpty) {
      buffer.writeln('$indent  Sub-notes:');
      for (final subNote in note.subNotes) {
        // Quote sub-note content as data
        final safeSubNoteContent =
            PromptInjectionProtection.formatNoteContentAsData(subNote.content);
        buffer.writeln(
          '$indent    - ${subNote.name} (ID: ${subNote.id}${subNote.isCompleted ? ", completed" : ''}):',
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
          buffer.writeln('$indent    - ${attachment.fileName} (ID: ${attachment.id})');
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
  /// [currentPdfPage] is used for "window" mode AI context to focus on nearby pages.
  Future<List<PlatformFile>> loadNoteAttachments(
    List<Note> notes, {
    int? currentPdfPage,
  }) async {
    final platformFiles = <PlatformFile>[];
    final processed = <String>{};

    for (final note in notes) {
      await _addNoteAttachments(
        platformFiles,
        note,
        processed,
        currentPdfPage: currentPdfPage,
      );

      final relationships = await _getRelationships(note.id);
      for (final rel in relationships) {
        final linkedId = rel.fromNoteId == note.id
            ? rel.toNoteId
            : rel.fromNoteId;
        final linkedNote = await _databaseService.getNote(linkedId);
        if (linkedNote == null) {
          continue;
        }
        await _addNoteAttachments(
          platformFiles,
          linkedNote,
          processed,
          currentPdfPage: currentPdfPage,
        );
      }
    }
    return platformFiles;
  }

  Future<void> _addNoteAttachments(
    List<PlatformFile> target,
    Note note,
    Set<String> processed, {
    int? currentPdfPage, // For window mode: current page being viewed
  }) async {
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

          // Check for PDF-specific AI context config
          final isPdf = attachment.fileName.toLowerCase().endsWith('.pdf');
          final aiConfig = isPdf ? attachment.getAiContextConfig() : null;

          // Determine page range for window mode
          int? startPage;
          int? endPage;
          bool extractPages = false;

          if (aiConfig != null && isPdf) {
            if (aiConfig.mode == 'window' && currentPdfPage != null) {
              final windowSize = aiConfig.windowSize ?? 10;
              final half = windowSize ~/ 2;
              startPage = (currentPdfPage - half + 1).clamp(1, 9999);
              endPage = currentPdfPage + half + 1;
              extractPages = true;
            } else if (aiConfig.mode == 'chapters' &&
                aiConfig.selectedChapters != null &&
                aiConfig.selectedChapters!.isNotEmpty) {
              // For chapters mode, extract pages from selected chapters
              try {
                final pdfDoc = await PdfDocument.openFile(fullPath);
                final outline = await pdfDoc.loadOutline();

                if (outline != null && outline.isNotEmpty) {
                  // Find page ranges for selected chapters
                  final pageRanges = _getChapterPageRanges(
                    outline,
                    aiConfig.selectedChapters!,
                    pdfDoc.pages.length,
                  );

                  if (pageRanges.isNotEmpty) {
                    LoggerService.debug(
                      'Extracting chapter pages: $pageRanges from ${attachment.fileName}',
                    );

                    // Extract pages from each range
                    for (final range in pageRanges) {
                      for (
                        int pageNum = range.start;
                        pageNum <= range.end;
                        pageNum++
                      ) {
                        await _extractAndAddPage(
                          pdfDoc,
                          pageNum,
                          attachment.fileName,
                          target,
                        );
                      }
                    }
                    pdfDoc.dispose();
                    continue; // Done with this attachment
                  }
                }
                pdfDoc.dispose();

                // Fallback if outline not found or chapters not matched
                LoggerService.warning(
                  'Could not find chapters in PDF outline, sending full PDF',
                );
              } catch (e) {
                LoggerService.warning('Failed to extract chapter pages: $e');
              }

              // Fallback: send full PDF with hint
              final chapters = aiConfig.selectedChapters!.join(', ');
              target.add(
                PlatformFile(
                  name: '${attachment.fileName}_context.txt',
                  path: null,
                  size: 0,
                  bytes: Uint8List.fromList(
                    '[Focus on chapters: $chapters]'.codeUnits,
                  ),
                ),
              );
              final bytes = await file.readAsBytes();
              target.add(
                PlatformFile(
                  name: attachment.fileName,
                  path: fullPath,
                  size: bytes.length,
                  bytes: bytes,
                ),
              );
              continue; // Skip to next attachment
            } else if (aiConfig.mode == 'bookmarks' &&
                aiConfig.selectedBookmarks != null &&
                aiConfig.selectedBookmarks!.isNotEmpty) {
              // Bookmarks mode
              try {
                final pdfDoc = await PdfDocument.openFile(fullPath);
                final totalPages = pdfDoc.pages.length;
                final bookmarkWindow = aiConfig.bookmarkWindowSize ?? 1;

                // Calculate ranges from bookmarks
                final ranges = <_PageRange>[];
                for (final bookmark in aiConfig.selectedBookmarks!) {
                  // Bookmarks are 0-indexed, pdfrx pages are 1-indexed (in this logic)
                  // Wait, earlier code converted 1-indexed to 0-indexed?
                  // No, pdfrx pages getter is 0-indexed access, but logic seems to use 1-based startPage/endPage vars.
                  // Let's verify: `_extractAndAddPage` takes `pageNum`.
                  // `_extractAndAddPage`: `if (pageNum < 1 || pageNum > pdfDoc.pages.length) return;`
                  // So `_extractAndAddPage` expects 1-based index.

                  // `PdfBookmark.pageNumber` is 0-indexed (as per ImmersiveNoteScreen usage).
                  final centerPage = bookmark.pageNumber + 1;
                  final start = (centerPage - bookmarkWindow).clamp(
                    1,
                    totalPages,
                  );
                  final end = (centerPage + bookmarkWindow).clamp(
                    1,
                    totalPages,
                  );

                  ranges.add(_PageRange(start, end));
                }

                final mergedRanges = _mergeRanges(ranges);

                if (mergedRanges.isNotEmpty) {
                  LoggerService.debug(
                    'Extracting bookmark pages: $mergedRanges from ${attachment.fileName}',
                  );

                  for (final range in mergedRanges) {
                    for (
                      int pageNum = range.start;
                      pageNum <= range.end;
                      pageNum++
                    ) {
                      await _extractAndAddPage(
                        pdfDoc,
                        pageNum,
                        attachment.fileName,
                        target,
                      );
                    }
                  }
                  pdfDoc.dispose();
                  continue; // Done
                }
                pdfDoc.dispose();
              } catch (e) {
                LoggerService.warning('Failed to extract bookmark pages: $e');
              }
            }
            // mode == 'all' means send full PDF
          }

          if (extractPages && startPage != null && endPage != null) {
            // Extract pages as images
            try {
              final pdfDoc = await PdfDocument.openFile(fullPath);
              final totalPages = pdfDoc.pages.length;
              final actualEndPage = endPage.clamp(1, totalPages);
              final actualStartPage = startPage.clamp(1, totalPages);

              LoggerService.debug(
                'Extracting PDF pages $actualStartPage-$actualEndPage from ${attachment.fileName}',
              );

              for (
                int pageNum = actualStartPage;
                pageNum <= actualEndPage;
                pageNum++
              ) {
                final page = pdfDoc.pages[pageNum - 1]; // 0-indexed

                // Render at reasonable resolution (2x for clarity)
                final renderWidth = (page.width * 2).toInt();
                final renderHeight = (page.height * 2).toInt();

                final pdfImage = await page.render(
                  width: renderWidth,
                  height: renderHeight,
                );

                if (pdfImage != null) {
                  // Convert to PNG bytes
                  final uiImage = await pdfImage.createImage();
                  final byteData = await uiImage.toByteData(
                    format: ui.ImageByteFormat.png,
                  );

                  if (byteData != null) {
                    final pngBytes = byteData.buffer.asUint8List();
                    target.add(
                      PlatformFile(
                        name: '${attachment.fileName}_page$pageNum.png',
                        path: null,
                        size: pngBytes.length,
                        bytes: pngBytes,
                      ),
                    );
                  }
                  uiImage.dispose();
                }
              }
              pdfDoc.dispose();
            } catch (e) {
              LoggerService.warning('Failed to extract PDF pages: $e');
              // Fallback: send full PDF
              final bytes = await file.readAsBytes();
              target.add(
                PlatformFile(
                  name: attachment.fileName,
                  path: fullPath,
                  size: bytes.length,
                  bytes: bytes,
                ),
              );
            }
          } else {
            // Send full PDF (mode == 'all' or no config)
            final bytes = await file.readAsBytes();
            target.add(
              PlatformFile(
                name: attachment.fileName,
                path: fullPath,
                size: bytes.length,
                bytes: bytes,
              ),
            );
          }
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

    // Load attachments for this note to check includeInAIContext flag
    List<Attachment> noteAttachments = [];
    try {
      noteAttachments = await _databaseService.getAttachmentsForNote(note.id);
    } catch (e) {
      LoggerService.warning(
        'Failed to load attachments for remote image filtering: $e',
      );
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

        // Check if this remote image has a corresponding attachment in the DB
        // and if so, respect its includeInAIContext flag
        final fileName = absolutePath.split('/').last;
        final matchingAttachment = noteAttachments
            .cast<Attachment?>()
            .firstWhere(
              (a) =>
                  a?.fileName == fileName ||
                  a?.filePath.endsWith(fileName) == true,
              orElse: () => null,
            );

        if (matchingAttachment != null &&
            !matchingAttachment.includeInAIContext) {
          // Skip this image as user has explicitly excluded it from AI context
          LoggerService.debug(
            'Skipping remote image $fileName from AI context (includeInAIContext=false)',
          );
          continue;
        }

        processed.add(absolutePath);
        final bytes = await file.readAsBytes();
        target.add(
          PlatformFile(
            name: fileName,
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
  /// [currentPdfPage] is used for "window" mode AI context to focus on nearby pages.
  Future<PromptMessage> buildContextMessage(
    List<Note> notes, {
    int? currentPdfPage,
  }) async {
    final context = await buildNoteContext(notes);
    final attachments = await loadNoteAttachments(
      notes,
      currentPdfPage: currentPdfPage,
    );

    return PromptMessage(
      role: PromptRole.user,
      content: context.isEmpty
          ? ''
          : 'Note context with linked relationships:\n$context',
      attachments: attachments,
      isContext: true,
    );
  }

  /// Find page ranges for selected chapters by matching titles against PDF outline
  List<_PageRange> _getChapterPageRanges(
    List<PdfOutlineNode> outline,
    List<String> selectedChapters,
    int totalPages,
  ) {
    final ranges = <_PageRange>[];
    final flatNodes = _flattenOutline(outline);

    for (int i = 0; i < flatNodes.length; i++) {
      final node = flatNodes[i];
      // Check if this node's title matches any selected chapter
      if (selectedChapters.any(
        (title) =>
            node.title.toLowerCase().contains(title.toLowerCase()) ||
            title.toLowerCase().contains(node.title.toLowerCase()),
      )) {
        // Start page from this node's destination
        final startPage = node.dest?.pageNumber ?? 1;

        // End page is either the next node's start or end of document
        int endPage;
        if (i + 1 < flatNodes.length) {
          endPage = (flatNodes[i + 1].dest?.pageNumber ?? totalPages) - 1;
        } else {
          endPage = totalPages;
        }

        if (startPage <= endPage) {
          ranges.add(_PageRange(startPage, endPage));
        }
      }
    }

    // Merge overlapping ranges
    return _mergeRanges(ranges);
  }

  /// Flatten a nested outline into a linear list
  List<PdfOutlineNode> _flattenOutline(List<PdfOutlineNode> nodes) {
    final result = <PdfOutlineNode>[];
    for (final node in nodes) {
      result.add(node);
      if (node.children.isNotEmpty) {
        result.addAll(_flattenOutline(node.children));
      }
    }
    return result;
  }

  /// Merge overlapping page ranges
  List<_PageRange> _mergeRanges(List<_PageRange> ranges) {
    if (ranges.isEmpty) return [];

    ranges.sort((a, b) => a.start.compareTo(b.start));
    final merged = <_PageRange>[ranges.first];

    for (int i = 1; i < ranges.length; i++) {
      final current = ranges[i];
      final last = merged.last;

      if (current.start <= last.end + 1) {
        // Overlapping or adjacent, extend
        merged[merged.length - 1] = _PageRange(
          last.start,
          current.end > last.end ? current.end : last.end,
        );
      } else {
        merged.add(current);
      }
    }

    return merged;
  }

  /// Extract a single page from PDF and add as PNG image
  Future<void> _extractAndAddPage(
    PdfDocument pdfDoc,
    int pageNum,
    String fileName,
    List<PlatformFile> target,
  ) async {
    if (pageNum < 1 || pageNum > pdfDoc.pages.length) return;

    final page = pdfDoc.pages[pageNum - 1]; // 0-indexed

    // Render at reasonable resolution (2x for clarity)
    final renderWidth = (page.width * 2).toInt();
    final renderHeight = (page.height * 2).toInt();

    final pdfImage = await page.render(
      width: renderWidth,
      height: renderHeight,
    );

    if (pdfImage != null) {
      final uiImage = await pdfImage.createImage();
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);

      if (byteData != null) {
        final pngBytes = byteData.buffer.asUint8List();
        target.add(
          PlatformFile(
            name: '${fileName}_page$pageNum.png',
            path: null,
            size: pngBytes.length,
            bytes: pngBytes,
          ),
        );
      }
      uiImage.dispose();
    }
  }
}

/// Simple page range helper
class _PageRange {
  final int start;
  final int end;

  _PageRange(this.start, this.end);

  @override
  String toString() => '$start-$end';
}
