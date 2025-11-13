import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/dedup_rule.dart';
import 'model_selector.dart';
import 'prompts/ai_prompts.dart';
import 'logger_service.dart';
import 'database_service.dart';
import 'prompts/prompt_models.dart';
import 'prompts/system_prompt_builder.dart';
import 'prompts/note_prompt_builder.dart';

/// Unified AI service with centralized prompts and simplified architecture
class AIService {
  /// Initialize the AI service
  static Future<void> initialize(AppProvider appProvider) async {
    await ModelSelector.instance.initialize(appProvider);
  }

  static NotePromptBuilder _notePromptBuilder() => NotePromptBuilder(DatabaseService());

  static PromptRequest _singleTurnRequest({
    required String taskContext,
    required String userInstruction,
    List<PlatformFile> attachments = const [],
    List<String> guidelines = const [],
  }) {
    final system = SystemPromptBuilder.build(
      taskContext: taskContext,
      guidelines: guidelines,
    );

    final user = PromptMessage(
      role: PromptRole.user,
      content: userInstruction,
      attachments: attachments,
    );

    return PromptRequest.singleTurn(
      systemMessage: system,
      userMessage: user,
    );
  }

  static Future<String> executePrompt(
    PromptRequest request, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    String? requestId,
  }) async {
    return await _withErrorHandling('prompt execution', () async {
      final actualRequestId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
      return await ModelSelector.instance.generateFromPrompt(
        request,
        temperature: temperature,
        topK: topK,
        topP: topP,
        maxOutputTokens: maxOutputTokens,
        requestId: actualRequestId,
      );
    }, requestId: requestId);
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

      final builder = _notePromptBuilder();
      final request = await builder.buildTransformationPrompt(
        note: note,
        instruction: transformationPrompt,
        additionalAttachments: attachedFiles ?? const [],
      );

      LoggerService.debug('Note transformation prompt built', error: {
        'requestId': requestId,
        'contextMessages': request.contextMessages.length,
      });

      return await ModelSelector.instance.generateFromPrompt(
        request,
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

      final builder = _notePromptBuilder();
      final request = await builder.buildNewNoteCreationPrompt(
        userInstruction: prompt,
        contextNotes: contextNotes,
        additionalAttachments: attachedFiles ?? const [],
      );

      LoggerService.debug('New note creation prompt built', error: {
        'requestId': requestId,
        'contextMessages': request.contextMessages.length,
      });

      final response = await ModelSelector.instance.generateFromPrompt(
        request,
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

      // Convert audio file path to PlatformFile
      final file = File(audioFilePath);
      final bytes = await file.readAsBytes();
      final fileName = audioFilePath.split('/').last;
      
      final audioFile = PlatformFile(
        name: fileName,
        path: audioFilePath,
        size: bytes.length,
        bytes: bytes,
      );

      final request = _singleTurnRequest(
        taskContext: 'Transcribe any attached audio files verbatim. Preserve punctuation and speaker cues if present.',
        userInstruction: AIPrompts.buildAudioTranscriptionPrompt(),
        attachments: [audioFile],
      );

      final response = await ModelSelector.instance.generateFromPrompt(
        request,
        requestId: requestId,
      );
      
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

      // Convert audio file path to PlatformFile
      final file = File(audioFilePath);
      final bytes = await file.readAsBytes();
      final fileName = audioFilePath.split('/').last;
      
      final audioFile = PlatformFile(
        name: fileName,
        path: audioFilePath,
        size: bytes.length,
        bytes: bytes,
      );

      final request = _singleTurnRequest(
        taskContext:
            'Summarize user-provided audio into concise bullet points and highlight actionable items. Use optional context if provided.',
        userInstruction: AIPrompts.buildAudioSummarizationPrompt(context: context),
        attachments: [audioFile],
      );

      final response = await ModelSelector.instance.generateFromPrompt(
        request,
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

      final request = _singleTurnRequest(
        taskContext:
            'Extract key information, structure, and actionable insights from provided ${contentType.toLowerCase()}.',
        userInstruction: AIPrompts.buildContentExtractionPrompt(text, contentType, title),
      );

      final response = await ModelSelector.instance.generateFromPrompt(
        request,
        requestId: requestId,
      );

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

      // Convert image file path to PlatformFile
      final file = File(imagePath);
      final bytes = await file.readAsBytes();
      final fileName = imagePath.split('/').last;
      
      final imageFile = PlatformFile(
        name: fileName,
        path: imagePath,
        size: bytes.length,
        bytes: bytes,
      );

      final request = _singleTurnRequest(
        taskContext: 'Analyze attached images and provide detailed descriptions of text and visual elements.',
        userInstruction: AIPrompts.buildImageContentExtractionPrompt(),
        attachments: [imageFile],
      );

      final response = await ModelSelector.instance.generateFromPrompt(
        request,
        requestId: requestId,
      );

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

      // Convert PDF file path to PlatformFile
      final file = File(pdfPath);
      final bytes = await file.readAsBytes();
      final fileName = pdfPath.split('/').last;
      
      final pdfFile = PlatformFile(
        name: fileName,
        path: pdfPath,
        size: bytes.length,
        bytes: bytes,
      );

      final request = _singleTurnRequest(
        taskContext: 'Summarize and extract structure from the attached PDF document.',
        userInstruction: AIPrompts.buildPdfContentExtractionPrompt(),
        attachments: [pdfFile],
      );

      final response = await ModelSelector.instance.generateFromPrompt(
        request,
        requestId: requestId,
      );

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
  static Future<List<DedupRule>> suggestDedupRules(
    List<String> tagNames, {
    List<String> protectedTags = const [],
  }) async {
    return await _withErrorHandling('AI dedup rules suggestion', () async {
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      LoggerService.debug('Starting AI dedup rules suggestion', error: {
        'tagNames': tagNames,
        'protectedTags': protectedTags,
        'requestId': requestId,
      });

      final request = _singleTurnRequest(
        taskContext: 'Suggest tag deduplication rules given current taxonomy and protected tags.',
        userInstruction: AIPrompts.buildDedupRulesSuggestionPrompt(tagNames, protectedTags: protectedTags),
      );

      final response = await ModelSelector.instance.generateFromPrompt(
        request,
        requestId: requestId,
      );
      
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

      final request = _singleTurnRequest(
        taskContext: 'Create a self-contained HTML/CSS/JS application that satisfies the user specification.',
        userInstruction: prompt,
      );

      return await ModelSelector.instance.generateFromPrompt(
        request,
        requestId: requestId,
      );
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

      final request = _singleTurnRequest(
        taskContext: 'Create a self-contained HTML/CSS/JS application that satisfies the user specification and uses attached assets if provided.',
        userInstruction: prompt,
        attachments: attachedFiles ?? const [],
      );

      return await ModelSelector.instance.generateFromPrompt(
        request,
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

      final request = _singleTurnRequest(
        taskContext: 'General assistant conversation without domain-specific context.',
        userInstruction: prompt,
        attachments: attachedFiles ?? const [],
      );

      return await ModelSelector.instance.generateFromPrompt(
        request,
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

  @visibleForTesting
  static List<DedupRule> parseDedupRulesResponseForTest(String response) {
    return _parseDedupRulesResponse(response);
  }

}
