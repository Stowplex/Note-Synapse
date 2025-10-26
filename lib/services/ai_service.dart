import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/dedup_rule.dart';
import 'model_selector.dart';
import 'prompts/ai_prompts.dart';
import 'logger_service.dart';
import 'database_service.dart';

/// Unified AI service with centralized prompts and simplified architecture
class AIService {
  /// Initialize the AI service
  static Future<void> initialize(AppProvider appProvider) async {
    await ModelSelector.instance.initialize(appProvider);
  }

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
      final prompt = AIPrompts.buildNoteQAPrompt(question, contextText, useOwnKnowledge: useOwnKnowledge);
      final allAttachedFiles = await _prepareAttachedFiles(contextNotes, attachedFiles);

      LoggerService.debug('Note Q&A context built', error: {
        'contextLength': contextText.length,
        'totalAttachedFiles': allAttachedFiles.length,
        'requestId': requestId,
      });

      // Model will handle capability limitations gracefully

      return await ModelSelector.instance.generateWithAttachments(
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

      final linkedNotesContext = await _buildLinkedNotesContext(note);
      final prompt = AIPrompts.buildNoteTransformationPrompt(
        note.title,
        note.content,
        transformationPrompt,
        attachmentPaths: note.attachmentPaths,
        subNotes: note.subNotes.map((sn) => '${sn.name}: ${sn.content}').toList(),
        tags: note.tags,
        linkedNotesContext: linkedNotesContext,
      );
      final allAttachedFiles = await _prepareAttachedFiles([note], attachedFiles);
      
      LoggerService.debug('Note transformation prompt built', error: {
        'promptLength': prompt.length,
        'totalAttachedFiles': allAttachedFiles.length,
        'requestId': requestId,
      });
      
      // Model will handle capability limitations gracefully
      
      return await ModelSelector.instance.generateWithAttachments(
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
      final aiPrompt = AIPrompts.buildNewNoteCreationPrompt(prompt, contextText);
      final allAttachedFiles = await _prepareAttachedFiles(contextNotes, attachedFiles);

      LoggerService.debug('New note creation prompt built', error: {
        'promptLength': aiPrompt.length,
        'contextLength': contextText.length,
        'totalAttachedFiles': allAttachedFiles.length,
        'requestId': requestId,
      });

      // Model will handle capability limitations gracefully

      final response = await ModelSelector.instance.generateWithAttachments(
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

      // Model will handle capability limitations gracefully

      final prompt = AIPrompts.buildAudioTranscriptionPrompt();
      final response = await ModelSelector.instance.generateWithAttachments(prompt, [], requestId: requestId);
      
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

      // Model will handle capability limitations gracefully

      final prompt = AIPrompts.buildAudioSummarizationPrompt(context: context);
      final response = await ModelSelector.instance.generateWithAttachments(prompt, [], requestId: requestId);
      
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

      final prompt = AIPrompts.buildContentExtractionPrompt(text, contentType, title);
      final response = await ModelSelector.instance.generateWithAttachments(prompt, [], requestId: requestId);

      LoggerService.debug('Content extraction completed', error: {
        'requestId': requestId,
        'responseLength': response.length,
      });

      return {
        'success': true,
        'content': response,
      };
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

      // Model will handle capability limitations gracefully

      final prompt = AIPrompts.buildImageContentExtractionPrompt();
      final response = await ModelSelector.instance.generateWithAttachments(prompt, [], requestId: requestId);

      LoggerService.debug('Image content extraction completed', error: {
        'requestId': requestId,
        'responseLength': response.length,
      });

      return {
        'success': true,
        'content': response,
      };
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

      // Model will handle capability limitations gracefully

      final prompt = AIPrompts.buildPdfContentExtractionPrompt();
      final response = await ModelSelector.instance.generateWithAttachments(prompt, [], requestId: requestId);

      LoggerService.debug('PDF content extraction completed', error: {
        'requestId': requestId,
        'responseLength': response.length,
      });

      return {
        'success': true,
        'content': response,
      };
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

      final prompt = AIPrompts.buildDedupRulesSuggestionPrompt(tagNames);
      final response = await ModelSelector.instance.generateWithAttachments(prompt, [], requestId: requestId);
      
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

      return await ModelSelector.instance.generateWithAttachments(prompt, [], requestId: requestId);
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

      // Model will handle capability limitations gracefully

      return await ModelSelector.instance.generateWithAttachments(
        prompt,
        attachedFiles ?? [],
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

      // Model will handle capability limitations gracefully

      return await ModelSelector.instance.generateWithAttachments(
        prompt,
        attachedFiles ?? [],
        temperature: temperature,
        topK: topK,
        topP: topP,
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

  static Future<String> _buildLinkedNotesContext(Note note) async {
    try {
      final databaseService = DatabaseService();
      final relationships = await databaseService.getRelationships(note.id);
      
      if (relationships.isEmpty) return '';
      
      final buffer = StringBuffer();
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
      
      return buffer.toString();
    } catch (e) {
      LoggerService.warning('Error loading linked notes for transformation: $e');
      return '';
    }
  }




  static List<Note> _parseNewNotesResponse(String response) {
    try {
      // Extract JSON from the response
      final jsonStart = response.indexOf('{');
      final jsonEnd = response.lastIndexOf('}') + 1;
      
      if (jsonStart == -1 || jsonEnd == 0) {
        throw Exception('No JSON found in response');
      }
      
      String jsonString = response.substring(jsonStart, jsonEnd);
      
      // Try to parse the JSON
      Map<String, dynamic> json;
      try {
        json = jsonDecode(jsonString);
      } catch (jsonError) {
        // Check if the error is due to invalid escape sequences (common with LaTeX notation)
        if (jsonError.toString().contains('escape') || 
            jsonError.toString().contains('Unexpected character')) {
          LoggerService.warning('JSON parsing failed, possibly due to invalid escape sequences. Attempting to fix LaTeX notation...');
          
          // Log a sample of the problematic JSON for debugging
          final sampleLength = jsonString.length > 500 ? 500 : jsonString.length;
          LoggerService.debug('JSON sample (first $sampleLength chars): ${jsonString.substring(0, sampleLength)}');
          
          // Attempt to fix common LaTeX escape sequence issues
          // Replace single backslashes in LaTeX notation with double backslashes
          // This regex looks for \( \) \[ \] that aren't already escaped
          jsonString = jsonString.replaceAllMapped(
            RegExp(r'(?<!\\)\\([()[\]])'),
            (match) => '\\\\${match.group(1)}',
          );
          
          // Try parsing again with the fixed JSON
          try {
            json = jsonDecode(jsonString);
            LoggerService.info('Successfully parsed JSON after fixing escape sequences');
          } catch (e2) {
            // If it still fails, provide a detailed error message
            throw Exception(
              'Failed to parse JSON response even after attempting to fix escape sequences. '
              'The AI may have generated invalid JSON with improperly escaped special characters (e.g., LaTeX notation like \\( or \\)). '
              'Original error: $jsonError. Error after fix attempt: $e2'
            );
          }
        } else {
          // Different JSON parsing error, rethrow with original error
          rethrow;
        }
      }
      
      final List<dynamic> notesJson = json['notes'] as List<dynamic>;
      final List<Note> notes = [];
      
      for (final noteJson in notesJson) {
        final note = Note(
          id: const Uuid().v4(),
          title: noteJson['title'] as String,
          content: noteJson['content'] as String,
          type: noteJson['type'] == 'task' ? NoteType.task : NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          tags: List<String>.from(noteJson['tags'] ?? []),
          subNotes: (noteJson['subNotes'] as List<dynamic>?)?.map((sn) => SubNote(
            id: const Uuid().v4(),
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
          id: const Uuid().v4(),
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
