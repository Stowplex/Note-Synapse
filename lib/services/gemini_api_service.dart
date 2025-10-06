import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import 'secure_storage_service.dart';
import 'database_service.dart';

class GeminiApiService {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';

  // Note Q&A
  static Future<String> answerNoteQuestion(
    String question,
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
  }) async {
    final apiKey = await SecureStorageService.getApiKey();
    if (apiKey == null) {
      throw Exception('API key not found');
    }

    final contextText = await _buildContextFromNotes(contextNotes);
    final prompt = _buildMultiNoteQAPrompt(question, contextText);

    // Convert note attachments to PlatformFile objects
    final noteAttachments = await _convertNoteAttachmentsToPlatformFiles(contextNotes);
    
    // Combine with any additional attached files
    final allAttachedFiles = <PlatformFile>[];
    if (attachedFiles != null) allAttachedFiles.addAll(attachedFiles);
    allAttachedFiles.addAll(noteAttachments);

    final response = await _makeGeminiRequest(apiKey, prompt, attachedFiles: allAttachedFiles);
    return response;
  }

  // Note transformation
  static Future<String> transformNote(
    Note note,
    String transformationPrompt, {
    List<PlatformFile>? attachedFiles,
  }) async {
    final apiKey = await SecureStorageService.getApiKey();
    if (apiKey == null) {
      throw Exception('API key not found');
    }

    final prompt = await _buildNoteTransformationPrompt(note, transformationPrompt);
    
    // Convert note attachments to PlatformFile objects
    final noteAttachments = await _convertNoteAttachmentsToPlatformFiles([note]);
    
    // Combine with any additional attached files
    final allAttachedFiles = <PlatformFile>[];
    if (attachedFiles != null) allAttachedFiles.addAll(attachedFiles);
    allAttachedFiles.addAll(noteAttachments);
    
    final response = await _makeGeminiRequest(apiKey, prompt, attachedFiles: allAttachedFiles);
    return response;
  }

  // New note creation
  static Future<List<Note>> createNewNotes(
    String prompt,
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
  }) async {
    final apiKey = await SecureStorageService.getApiKey();
    if (apiKey == null) {
      throw Exception('API key not found');
    }

    final contextText = await _buildContextFromNotes(contextNotes);
    final aiPrompt = _buildNewNoteCreationPrompt(prompt, contextText);

    // Convert note attachments to PlatformFile objects
    final noteAttachments = await _convertNoteAttachmentsToPlatformFiles(contextNotes);
    
    // Combine with any additional attached files
    final allAttachedFiles = <PlatformFile>[];
    if (attachedFiles != null) allAttachedFiles.addAll(attachedFiles);
    allAttachedFiles.addAll(noteAttachments);

    final response = await _makeGeminiRequest(apiKey, aiPrompt, attachedFiles: allAttachedFiles);
    return _parseNewNotesResponse(response);
  }

  static Future<String> _makeGeminiRequest(
    String apiKey, 
    String prompt, {
    List<PlatformFile>? attachedFiles,
  }) async {
    // Add today's date context to the prompt
    final today = DateTime.now();
    final todayContext = '\n\nToday\'s date: ${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')} (${_getDayOfWeek(today)})';
    final enhancedPrompt = prompt + todayContext;

    final parts = <Map<String, dynamic>>[
      {'text': enhancedPrompt}
    ];

    // Add file attachments if any
    if (attachedFiles != null && attachedFiles.isNotEmpty) {
      for (final file in attachedFiles) {
        if (file.bytes != null) {
          // Convert file to base64 for Gemini API
          final base64Data = base64Encode(file.bytes!);
          final extension = file.name.split('.').last;
          final mimeType = _getMimeType(extension);
          
          parts.add({
            'inline_data': {
              'mime_type': mimeType,
              'data': base64Data,
            }
          });
        }
      }
    }

    final requestBody = {
      'contents': [
        {
          'parts': parts
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'topK': 32,
        'topP': 1,
        'maxOutputTokens': 8192,
      }
    };

    final response = await http.post(
      Uri.parse('$_baseUrl/models/gemini-2.5-flash:generateContent?key=$apiKey'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['candidates'] != null && data['candidates'].isNotEmpty) {
        final candidate = data['candidates'][0];
        final content = candidate['content'];
        
        if (content != null && content['parts'] != null && content['parts'].isNotEmpty) {
          return content['parts'][0]['text'];
        }
      }
      throw Exception('No content in Gemini API response');
    } else {
      throw Exception('Failed to process request: ${response.statusCode} - ${response.body}');
    }
  }

  static String _getDayOfWeek(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
  }

  static String _getMimeType(String? extension) {
    if (extension == null) return 'application/octet-stream';
    
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'mp4':
        return 'video/mp4';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      default:
        return 'application/octet-stream';
    }
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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
        print('Error loading linked note attachments for ${note.title}: $e');
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
        print('Error reading attachment file $attachmentPath: $e');
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
      print('Error loading linked notes for ${note.title}: $e');
    }
    
    buffer.writeln();
  }

  static String _buildMultiNoteQAPrompt(String question, String context) {
    return '''
Based on the following notes and their linked relationships, please answer the question: "$question"

Context Notes (including linked notes and their relationships):
$context

Please provide a comprehensive answer based on the information in the notes and their relationships. Consider:
- The hierarchical structure shown (indented linked notes)
- The relationship types between notes (answers, causality, related, subnote, parent, references, expands, contradicts, supports)
- How linked notes might provide additional context or clarification
- The direction of relationships (→ for outgoing, ← for incoming)

If the answer cannot be found in the provided context, please state that clearly.
''';
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
      print('Error loading linked notes for transformation: $e');
    }
    
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
          "content": "Sub-note content"
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
}
