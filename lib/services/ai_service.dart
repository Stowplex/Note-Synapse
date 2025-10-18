import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/dedup_rule.dart';
import 'model_service.dart';
import 'logger_service.dart';
import 'database_service.dart';

/// Unified AI service that uses the model service
class AIService {
  /// Note Q&A
  static Future<String> answerNoteQuestion(
    String question,
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
    bool useOwnKnowledge = false,
  }) async {
    return await _withErrorHandling('note Q&A', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting note Q&A request', error: {
        'question': question,
        'contextNotesCount': contextNotes.length,
        'attachedFilesCount': attachedFiles?.length ?? 0,
        'requestId': requestId,
      });

      final contextText = await _buildContextFromNotes(contextNotes);
      final prompt = _buildMultiNoteQAPrompt(question, contextText, useOwnKnowledge: useOwnKnowledge);
      final allAttachedFiles = await _prepareAttachedFiles(contextNotes, attachedFiles);

      LoggerService.debug('Note Q&A context built', error: {
        'contextLength': contextText.length,
        'totalAttachedFiles': allAttachedFiles.length,
        'requestId': requestId,
      });

      // Check if current model can handle the request with attachments
      if (!ModelService.instance.canHandleRequest(attachedFiles: allAttachedFiles)) {
        throw Exception(ModelService.instance.getCapabilityErrorMessage(attachedFiles: allAttachedFiles));
      }

      return await ModelService.instance.generateWithAttachments(
        prompt,
        allAttachedFiles,
        requestId: requestId,
      );
    });
  }

  /// Note transformation
  static Future<String> transformNote(
    Note note,
    String transformationPrompt, {
    List<PlatformFile>? attachedFiles,
  }) async {
    return await _withErrorHandling('note transformation', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting note transformation request', error: {
        'noteId': note.id,
        'noteTitle': note.title,
        'transformationPrompt': transformationPrompt,
        'attachedFilesCount': attachedFiles?.length ?? 0,
        'requestId': requestId,
      });

      final prompt = await _buildNoteTransformationPrompt(note, transformationPrompt);
      final allAttachedFiles = await _prepareAttachedFiles([note], attachedFiles);
      
      LoggerService.debug('Note transformation prompt built', error: {
        'promptLength': prompt.length,
        'totalAttachedFiles': allAttachedFiles.length,
        'requestId': requestId,
      });

      // Check if current model can handle the request with attachments
      if (!ModelService.instance.canHandleRequest(attachedFiles: allAttachedFiles)) {
        throw Exception(ModelService.instance.getCapabilityErrorMessage(attachedFiles: allAttachedFiles));
      }
      
      return await ModelService.instance.generateWithAttachments(
        prompt,
        allAttachedFiles,
        requestId: requestId,
      );
    });
  }

  /// New note creation
  static Future<List<Note>> createNewNotes(
    String prompt,
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
  }) async {
    return await _withErrorHandling('new note creation', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting new note creation request', error: {
        'prompt': prompt,
        'contextNotesCount': contextNotes.length,
        'attachedFilesCount': attachedFiles?.length ?? 0,
        'requestId': requestId,
      });

      final contextText = await _buildContextFromNotes(contextNotes);
      final aiPrompt = _buildNewNoteCreationPrompt(prompt, contextText);
      final allAttachedFiles = await _prepareAttachedFiles(contextNotes, attachedFiles);

      LoggerService.debug('New note creation prompt built', error: {
        'promptLength': aiPrompt.length,
        'contextLength': contextText.length,
        'totalAttachedFiles': allAttachedFiles.length,
        'requestId': requestId,
      });

      // Check if current model can handle the request with attachments
      if (!ModelService.instance.canHandleRequest(attachedFiles: allAttachedFiles)) {
        throw Exception(ModelService.instance.getCapabilityErrorMessage(attachedFiles: allAttachedFiles));
      }

      final response = await ModelService.instance.generateWithAttachments(
        aiPrompt,
        allAttachedFiles,
        requestId: requestId,
      );
      return _parseNewNotesResponse(response);
    });
  }

  /// Audio transcription
  static Future<String> transcribeAudio(String audioFilePath) async {
    return await _withErrorHandling('audio transcription', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting audio transcription request', error: {
        'audioFilePath': audioFilePath,
        'requestId': requestId,
      });

      // Check if current model supports audio transcription
      if (!ModelService.instance.canHandleRequest(requiresAudioSupport: true)) {
        throw Exception(ModelService.instance.getCapabilityErrorMessage(requiresAudioSupport: true));
      }

      final response = await ModelService.instance.transcribeAudio(audioFilePath, requestId: requestId);
      
      LoggerService.debug('Audio transcription completed', error: {
        'transcriptionLength': response.length,
        'requestId': requestId,
      });
      
      return response.trim();
    });
  }

  /// Audio summarization
  static Future<String> summarizeAudio(String audioFilePath, {String? context}) async {
    return await _withErrorHandling('audio summarization', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting audio summarization request', error: {
        'audioFilePath': audioFilePath,
        'context': context,
        'requestId': requestId,
      });

      // Check if current model supports audio processing
      if (!ModelService.instance.canHandleRequest(requiresAudioSupport: true)) {
        throw Exception(ModelService.instance.getCapabilityErrorMessage(requiresAudioSupport: true));
      }

      final response = await ModelService.instance.summarizeAudio(
        audioFilePath,
        context: context,
        requestId: requestId,
      );
      
      LoggerService.debug('Audio summarization completed', error: {
        'summaryLength': response.length,
        'requestId': requestId,
      });
      
      return response.trim();
    });
  }

  /// Content extraction methods
  static Future<Map<String, dynamic>> extractContentFromText(
    String text,
    String contentType,
    String title,
  ) async {
    return await _withErrorHandling('text content extraction', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting text content extraction', error: {
        'contentType': contentType,
        'title': title,
        'textLength': text.length,
        'requestId': requestId,
      });

      final response = await ModelService.instance.extractContentFromText(
        text,
        contentType,
        title,
        requestId: requestId,
      );

      LoggerService.debug('Content extraction completed', error: {
        'requestId': requestId,
        'responseLength': response['content']?.length ?? 0,
      });

      return response;
    }).catchError((e) => {
      'success': false,
      'error': e.toString(),
    });
  }

  static Future<Map<String, dynamic>> extractContentFromImage(String imagePath) async {
    return await _withErrorHandling('image content extraction', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting image content extraction', error: {
        'imagePath': imagePath,
        'requestId': requestId,
      });

      // Check if current model supports image processing
      if (!ModelService.instance.canHandleRequest(requiresImageSupport: true)) {
        throw Exception(ModelService.instance.getCapabilityErrorMessage(requiresImageSupport: true));
      }

      final response = await ModelService.instance.extractContentFromImage(imagePath, requestId: requestId);

      LoggerService.debug('Image content extraction completed', error: {
        'requestId': requestId,
        'responseLength': response['content']?.length ?? 0,
      });

      return response;
    }).catchError((e) => {
      'success': false,
      'error': e.toString(),
    });
  }

  static Future<Map<String, dynamic>> extractContentFromPdf(String pdfPath) async {
    return await _withErrorHandling('PDF content extraction', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting PDF content extraction', error: {
        'pdfPath': pdfPath,
        'requestId': requestId,
      });

      // Check if current model supports document processing
      if (!ModelService.instance.canHandleRequest(requiresDocumentSupport: true)) {
        throw Exception(ModelService.instance.getCapabilityErrorMessage(requiresDocumentSupport: true));
      }

      final response = await ModelService.instance.extractContentFromPdf(pdfPath, requestId: requestId);

      LoggerService.debug('PDF content extraction completed', error: {
        'requestId': requestId,
        'responseLength': response['content']?.length ?? 0,
      });

      return response;
    }).catchError((e) => {
      'success': false,
      'error': e.toString(),
    });
  }

  /// AI suggestion for dedup rules
  static Future<List<DedupRule>> suggestDedupRules(List<String> tagNames) async {
    return await _withErrorHandling('AI dedup rules suggestion', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting AI dedup rules suggestion', error: {
        'tagNames': tagNames,
        'requestId': requestId,
      });

      final prompt = _buildDedupRulesSuggestionPrompt(tagNames);
      final response = await ModelService.instance.generateText(prompt, requestId: requestId);
      
      LoggerService.debug('AI dedup rules suggestion completed', error: {
        'requestId': requestId,
        'responseLength': response.length,
      });

      return _parseDedupRulesResponse(response);
    });
  }

  /// Generate user app HTML
  static Future<String> generateApp(String prompt) async {
    return await _withErrorHandling('app generation', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting app generation request', error: {
        'prompt': prompt,
        'requestId': requestId,
      });

      return await ModelService.instance.generateApp(prompt, requestId: requestId);
    });
  }

  /// Generate user app HTML with attachments
  static Future<String> generateAppWithAttachments(String prompt, List<PlatformFile>? attachedFiles) async {
    return await _withErrorHandling('app generation with attachments', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting app generation request with attachments', error: {
        'prompt': prompt,
        'attachedFilesCount': attachedFiles?.length ?? 0,
        'requestId': requestId,
      });

      // Check if current model can handle the request with attachments
      if (attachedFiles != null && attachedFiles.isNotEmpty) {
        if (!ModelService.instance.canHandleRequest(attachedFiles: attachedFiles)) {
          throw Exception(ModelService.instance.getCapabilityErrorMessage(attachedFiles: attachedFiles));
        }
      }

      return await ModelService.instance.generateAppWithAttachments(
        prompt,
        attachedFiles,
        requestId: requestId,
      );
    });
  }

  /// Chat AI with configurable parameters
  static Future<String> chatAI(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    List<PlatformFile>? attachedFiles,
  }) async {
    return await _withErrorHandling('chat AI', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting chat AI request', error: {
        'prompt': prompt,
        'temperature': temperature,
        'topK': topK,
        'topP': topP,
        'attachedFilesCount': attachedFiles?.length ?? 0,
        'requestId': requestId,
      });

      // Check if current model can handle the request with attachments
      if (attachedFiles != null && attachedFiles.isNotEmpty) {
        if (!ModelService.instance.canHandleRequest(attachedFiles: attachedFiles)) {
          throw Exception(ModelService.instance.getCapabilityErrorMessage(attachedFiles: attachedFiles));
        }
      }

      return await ModelService.instance.chatAI(
        prompt,
        temperature: temperature,
        topK: topK,
        topP: topP,
        attachedFiles: attachedFiles,
        requestId: requestId,
      );
    });
  }

  // Helper methods (copied from original GeminiApiService)
  static Future<T> _withErrorHandling<T>(
    String operation,
    Future<T> Function() operationFunction, {
    String? requestId,
  }) async {
    final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    try {
      return await operationFunction();
    } catch (e) {
      LoggerService.error('Error in $operation', error: {
        'error': e.toString(),
        'requestId': actualRequestId,
      });
      rethrow;
    }
  }

  static Future<List<PlatformFile>> _prepareAttachedFiles(
    List<Note> notes,
    List<PlatformFile>? additionalFiles,
  ) async {
    final allAttachedFiles = <PlatformFile>[];
    if (additionalFiles != null) allAttachedFiles.addAll(additionalFiles);
    
    final noteAttachments = await _convertNoteAttachmentsToPlatformFiles(notes);
    allAttachedFiles.addAll(noteAttachments);
    
    return allAttachedFiles;
  }

  static Future<List<PlatformFile>> _convertNoteAttachmentsToPlatformFiles(List<Note> notes) async {
    final platformFiles = <PlatformFile>[];
    final processedFiles = <String>{}; // To avoid duplicate files
    
    for (final note in notes) {
      // Add attachments from the main note
      await _addNoteAttachments(platformFiles, note, processedFiles);
      
      // Add attachments from linked notes
      try {
        final databaseService = DatabaseService();
        final relationships = await databaseService.getRelationships(note.id);
        
        for (final relationship in relationships) {
          final linkedNoteId = relationship.fromNoteId == note.id ? relationship.toNoteId : relationship.fromNoteId;
          final linkedNote = await databaseService.getNote(linkedNoteId);
          
          if (linkedNote != null) {
            await _addNoteAttachments(platformFiles, linkedNote, processedFiles);
          }
        }
      } catch (e) {
        LoggerService.warning('Error loading linked note attachments for ${note.title}: $e');
        // Continue with other files even if one fails
      }
    }
    
    return platformFiles;
  }

  static Future<void> _addNoteAttachments(List<PlatformFile> platformFiles, Note note, Set<String> processedFiles) async {
    for (final attachmentPath in note.attachmentPaths) {
      // Skip if we've already processed this file
      if (processedFiles.contains(attachmentPath)) continue;
      processedFiles.add(attachmentPath);
      
      try {
        final file = File(attachmentPath);
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          final fileName = attachmentPath.split('/').last;
          
          final platformFile = PlatformFile(
            name: fileName,
            path: attachmentPath,
            size: bytes.length,
            bytes: bytes,
          );
          
          platformFiles.add(platformFile);
        }
      } catch (e) {
        LoggerService.warning('Error reading attachment file $attachmentPath: $e');
        // Continue with other files even if one fails
      }
    }
  }

  static Future<String> _buildContextFromNotes(List<Note> notes) async {
    if (notes.isEmpty) return '';

    final buffer = StringBuffer();
    final processedNoteIds = <String>{};
    
    for (final note in notes) {
      await _addNoteToContext(buffer, note, processedNoteIds, 0);
    }
    
    return buffer.toString();
  }

  static Future<void> _addNoteToContext(StringBuffer buffer, Note note, Set<String> processedNoteIds, int depth) async {
    // Avoid infinite loops and duplicate processing
    if (processedNoteIds.contains(note.id) || depth > 3) return;
    processedNoteIds.add(note.id);
    
    // Add indentation based on depth
    final indent = '  ' * depth;
    
    buffer.writeln('${indent}--- Note: ${note.title} ---');
    buffer.writeln('${indent}${note.content}');
    
    // Add file attachment info if any (files will be sent as binary data separately)
    if (note.attachmentPaths.isNotEmpty) {
      buffer.writeln('${indent}File Attachments:');
      for (final attachmentPath in note.attachmentPaths) {
        final fileName = attachmentPath.split('/').last;
        final file = File(attachmentPath);
        if (file.existsSync()) {
          final fileSize = file.lengthSync();
          buffer.writeln('${indent}- $fileName (${_formatFileSize(fileSize)})');
        } else {
          buffer.writeln('${indent}- $fileName (file not found)');
        }
      }
    }
    
    if (note.subNotes.isNotEmpty) {
      buffer.writeln('${indent}Sub-notes:');
      for (final subNote in note.subNotes) {
        buffer.writeln('${indent}- ${subNote.name}: ${subNote.content}');
      }
    }
    
    if (note.tags.isNotEmpty) {
      buffer.writeln('${indent}Tags: ${note.tags.join(', ')}');
    }
    
    // Add linked notes with relationships
    try {
      final databaseService = DatabaseService();
      final relationships = await databaseService.getRelationships(note.id);
      
      if (relationships.isNotEmpty) {
        buffer.writeln('${indent}Linked Notes:');
        for (final relationship in relationships) {
          final linkedNoteId = relationship.fromNoteId == note.id ? relationship.toNoteId : relationship.fromNoteId;
          final linkedNote = await databaseService.getNote(linkedNoteId);
          
          if (linkedNote != null) {
            final isOutgoing = relationship.fromNoteId == note.id;
            final direction = isOutgoing ? '→' : '←';
            final relationshipDisplay = RelationshipType.getDisplayName(relationship.type);
            
            buffer.writeln('${indent}  ${direction} $relationshipDisplay: ${linkedNote.title}');
            
            // Recursively add linked note content (with depth limit)
            if (depth < 2) {
              buffer.writeln('${indent}  Linked Note Content:');
              await _addNoteToContext(buffer, linkedNote, processedNoteIds, depth + 2);
            }
          }
        }
      }
    } catch (e) {
      // If there's an error loading relationships, continue without them
      LoggerService.warning('Error loading linked notes for ${note.title}: $e');
    }
    
    buffer.writeln();
  }

  static String _buildMultiNoteQAPrompt(String question, String context, {bool useOwnKnowledge = false}) {
    if (useOwnKnowledge) {
      return '''
Based on the following notes and their linked relationships, please answer the question: "$question"

Context Notes (including linked notes and their relationships):
$context

Please provide a comprehensive answer using both the information in the notes and your own knowledge. Consider:
- The hierarchical structure shown (indented linked notes)
- The relationship types between notes (answers, causality, related, subnote, parent, references, expands, contradicts, supports)
- How linked notes might provide additional context or clarification
- The direction of relationships (→ for outgoing, ← for incoming)
- Your own knowledge to provide additional insights, explanations, or expanded context

IMPORTANT - Math Formula Guidelines:
- When including mathematical formulas, equations, or expressions in your response, use LaTeX format
- Use the format: \\( formula \\) for inline math (without leading and ending \$ symbols)
- Use the format: \\[ formula \\] for display math (without leading and ending \$ symbols)
- Examples:
  - Inline: \\( E = mc^2 \\) or \\( \\frac{a}{b} \\)
  - Display: \\[ \\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi} \\]
- Preserve all mathematical notation, symbols, and formatting accurately
- If explaining complex equations, break them down into logical components

You may supplement the information from the notes with your own knowledge to provide a more complete and helpful answer.
''';
    } else {
      return '''
Based on the following notes and their linked relationships, please answer the question: "$question"

Context Notes (including linked notes and their relationships):
$context

Please provide a comprehensive answer based ONLY on the information in the notes and their relationships. Consider:
- The hierarchical structure shown (indented linked notes)
- The relationship types between notes (answers, causality, related, subnote, parent, references, expands, contradicts, supports)
- How linked notes might provide additional context or clarification
- The direction of relationships (→ for outgoing, ← for incoming)

IMPORTANT - Math Formula Guidelines:
- When including mathematical formulas, equations, or expressions in your response, use LaTeX format
- Use the format: \\( formula \\) for inline math (without leading and ending \$ symbols)
- Use the format: \\[ formula \\] for display math (without leading and ending \$ symbols)
- Examples:
  - Inline: \\( E = mc^2 \\) or \\( \\frac{a}{b} \\)
  - Display: \\[ \\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi} \\]
- Preserve all mathematical notation, symbols, and formatting accurately
- If explaining complex equations, break them down into logical components

If the answer cannot be found in the provided context, please state that clearly and do not use your own knowledge to supplement the answer.
''';
    }
  }

  static Future<String> _buildNoteTransformationPrompt(Note note, String transformationPrompt) async {
    final buffer = StringBuffer();
    buffer.writeln('Please transform the following note according to the instruction: "$transformationPrompt"');
    buffer.writeln();
    buffer.writeln('Original Note:');
    buffer.writeln('Title: ${note.title}');
    buffer.writeln('Content: ${note.content}');
    
    // Add file attachment info if any (files will be sent as binary data separately)
    if (note.attachmentPaths.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('File Attachments:');
      for (final attachmentPath in note.attachmentPaths) {
        final fileName = attachmentPath.split('/').last;
        final file = File(attachmentPath);
        if (file.existsSync()) {
          final fileSize = file.lengthSync();
          buffer.writeln('- $fileName (${_formatFileSize(fileSize)})');
        } else {
          buffer.writeln('- $fileName (file not found)');
        }
      }
    }
    
    if (note.subNotes.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Sub-notes:');
      buffer.writeln(note.subNotes.map((sn) => '- ${sn.name}: ${sn.content}').join('\n'));
    }
    
    if (note.tags.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Tags: ${note.tags.join(', ')}');
    }
    
    // Add linked notes context
    try {
      final databaseService = DatabaseService();
      final relationships = await databaseService.getRelationships(note.id);
      
      if (relationships.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('Linked Notes Context:');
        for (final relationship in relationships) {
          final linkedNoteId = relationship.fromNoteId == note.id ? relationship.toNoteId : relationship.fromNoteId;
          final linkedNote = await databaseService.getNote(linkedNoteId);
          
          if (linkedNote != null) {
            final isOutgoing = relationship.fromNoteId == note.id;
            final direction = isOutgoing ? '→' : '←';
            final relationshipDisplay = RelationshipType.getDisplayName(relationship.type);
            
            buffer.writeln('  ${direction} $relationshipDisplay: ${linkedNote.title}');
            buffer.writeln('  Content: ${linkedNote.content}');
            
            if (linkedNote.tags.isNotEmpty) {
              buffer.writeln('  Tags: ${linkedNote.tags.join(', ')}');
            }
            buffer.writeln();
          }
        }
      }
    } catch (e) {
      // If there's an error loading relationships, continue without them
      LoggerService.warning('Error loading linked notes for transformation: $e');
    }
    
    buffer.writeln();
    buffer.writeln('IMPORTANT - Math Formula Guidelines:');
    buffer.writeln('- When including mathematical formulas, equations, or expressions in the transformed content, use LaTeX format');
    buffer.writeln(r'- Use the format: \( formula \) for inline math (without leading and ending $ symbols)');
    buffer.writeln(r'- Use the format: \[ formula \] for display math (without leading and ending $ symbols)');
    buffer.writeln('- Examples:');
    buffer.writeln(r'  - Inline: \( E = mc^2 \) or \( \frac{a}{b} \)');
    buffer.writeln(r'  - Display: \[ \int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi} \]');
    buffer.writeln('- Preserve all mathematical notation, symbols, and formatting accurately');
    buffer.writeln('- If transforming complex equations, break them down into logical components');
    buffer.writeln();
    buffer.writeln('Please provide the transformed version of this note, maintaining the same structure but with the requested changes applied. Consider the linked notes context when making transformations.');
    
    return buffer.toString();
  }

  static String _buildNewNoteCreationPrompt(String prompt, String context) {
    return '''
Based on the following context and prompt, please create one or more new notes.

Context Notes (including linked notes and their relationships):
$context

User Prompt: "$prompt"

IMPORTANT: 
- When creating tasks with dates, use the format YYYY-MM-DD and consider the current date context provided. For relative dates like "next Wednesday" or "tomorrow", calculate the actual date based on today's date.
- Consider the relationships between notes in the context when creating new notes. If the context shows linked notes with specific relationship types (answers, causality, related, subnote, parent, references, expands, contradicts, supports), consider how your new notes might relate to existing ones.
- Pay attention to the hierarchical structure shown in the context (indented linked notes) to understand the note relationships.

IMPORTANT - Math Formula Guidelines:
- When including mathematical formulas, equations, or expressions in note content, use LaTeX format
- Use the format: \\( formula \\) for inline math (without leading and ending \$ symbols)
- Use the format: \\[ formula \\] for display math (without leading and ending \$ symbols)
- Examples:
  - Inline: \\( E = mc^2 \\) or \\( \\frac{a}{b} \\)
  - Display: \\[ \\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi} \\]
- Preserve all mathematical notation, symbols, and formatting accurately
- If creating notes with complex equations, break them down into logical components

Please create the new note(s) in the following JSON format:
{
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
          "isCompleted": either false (default value) or true (if the sub-note is deemed completed, derived from the context)
        }
      ],
      "scheduledAt": "YYYY-MM-DD" (only for tasks - when the task should start),
      "completeBy": "YYYY-MM-DD" (only for tasks - when the task should be completed),
      "status": "todo" (only for tasks)
    }
  ]
}

If creating multiple notes, ensure they are related and useful based on the context and prompt. Consider how the new notes might fit into the existing network of relationships shown in the context. For tasks, make sure to set appropriate scheduledAt and completeBy dates based on the user's request and current date context.
''';
  }

  static List<Note> _parseNewNotesResponse(String response) {
    try {
      // Extract JSON from the response
      final jsonStart = response.indexOf('{');
      final jsonEnd = response.lastIndexOf('}') + 1;
      
      if (jsonStart == -1 || jsonEnd == 0) {
        throw Exception('No JSON found in response');
      }
      
      final jsonString = response.substring(jsonStart, jsonEnd);
      final Map<String, dynamic> json = jsonDecode(jsonString);
      
      final List<dynamic> notesJson = json['notes'] as List<dynamic>;
      final List<Note> notes = [];
      
      for (final noteJson in notesJson) {
        final note = Note(
          id: DateTime.now().millisecondsSinceEpoch.toString() + '_${notes.length}',
          title: noteJson['title'] as String,
          content: noteJson['content'] as String,
          type: noteJson['type'] == 'task' ? NoteType.task : NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          tags: List<String>.from(noteJson['tags'] ?? []),
          subNotes: (noteJson['subNotes'] as List<dynamic>?)?.map((sn) => SubNote(
            id: DateTime.now().millisecondsSinceEpoch.toString() + '_sub_${sn.hashCode}',
            name: sn['name'] as String,
            content: sn['content'] as String,
            createdAt: DateTime.now(),
            isCompleted: sn['isCompleted'] as bool? ?? false,
          )).toList() ?? [],
          scheduledAt: noteJson['scheduledAt'] as String?,
          completeBy: noteJson['completeBy'] as String?,
          status: noteJson['status'] != null 
              ? TaskStatus.values.firstWhere(
                  (e) => e.toString().split('.').last == noteJson['status'],
                  orElse: () => TaskStatus.todo,
                )
              : null,
        );
        notes.add(note);
      }
      
      return notes;
    } catch (e) {
      throw Exception('Failed to parse AI response: $e');
    }
  }

  static String _buildDedupRulesSuggestionPrompt(List<String> tagNames) {
    return '''
Analyze the following list of tags and suggest deduplication rules to consolidate similar or redundant tags. 

Tags: ${tagNames.join(', ')}

Please suggest rules in the format "leftTag -> rightTag" where:
- leftTag is the tag that should be replaced
- rightTag is the tag that should replace it

Rules to follow:
1. No tag should appear as leftTag in multiple rules (each tag can only be replaced once)
2. No tag should appear as both leftTag in one rule and rightTag in another rule (no cross-references)
3. Do not suggest self-replacement (A -> A)
4. It IS allowed for a tag to appear as rightTag in multiple rules (consolidating multiple tags into one)
5. Focus on consolidating similar tags, typos, or variations
6. Prefer shorter, more standard tag names
7. Consider semantic similarity (e.g., "work" and "job" could be consolidated)

Please respond with a JSON array of objects in this format:
[
  {"leftTag": "old_tag_name", "rightTag": "new_tag_name"},
  {"leftTag": "another_old_tag", "rightTag": "another_new_tag"}
]

Only suggest rules that would genuinely improve tag organization. If no meaningful consolidations are possible, return an empty array.
''';
  }

  static List<DedupRule> _parseDedupRulesResponse(String response) {
    try {
      // Extract JSON from the response
      final jsonStart = response.indexOf('[');
      final jsonEnd = response.lastIndexOf(']') + 1;
      
      if (jsonStart == -1 || jsonEnd == 0) {
        return [];
      }
      
      final jsonString = response.substring(jsonStart, jsonEnd);
      final List<dynamic> rulesJson = jsonDecode(jsonString);
      
      final List<DedupRule> rules = [];
      
      for (final ruleJson in rulesJson) {
        final rule = DedupRule(
          id: DateTime.now().millisecondsSinceEpoch.toString() + '_${rules.length}',
          leftTag: ruleJson['leftTag'] as String,
          rightTag: ruleJson['rightTag'] as String,
        );
        rules.add(rule);
      }
      
      return rules;
    } catch (e) {
      LoggerService.warning('Failed to parse AI dedup rules response: $e');
      return [];
    }
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
