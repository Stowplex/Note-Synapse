import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../models/note.dart';
import 'secure_storage_service.dart';

class GeminiApiService {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';

  // Multi-note Q&A
  static Future<String> answerMultiNoteQuestion(
    String question,
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
  }) async {
    final apiKey = await SecureStorageService.getApiKey();
    if (apiKey == null) {
      throw Exception('API key not found');
    }

    final contextText = _buildContextFromNotes(contextNotes);
    final prompt = _buildMultiNoteQAPrompt(question, contextText);

    final response = await _makeGeminiRequest(apiKey, prompt, attachedFiles: attachedFiles);
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

    final prompt = _buildNoteTransformationPrompt(note, transformationPrompt);
    final response = await _makeGeminiRequest(apiKey, prompt, attachedFiles: attachedFiles);
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

    final contextText = _buildContextFromNotes(contextNotes);
    final aiPrompt = _buildNewNoteCreationPrompt(prompt, contextText);

    final response = await _makeGeminiRequest(apiKey, aiPrompt, attachedFiles: attachedFiles);
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
          final mimeType = _getMimeType(file.extension);
          
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

  static String _buildContextFromNotes(List<Note> notes) {
    if (notes.isEmpty) return '';

    final buffer = StringBuffer();
    for (final note in notes) {
      buffer.writeln('--- Note: ${note.title} ---');
      buffer.writeln(note.content);
      if (note.subNotes.isNotEmpty) {
        buffer.writeln('Sub-notes:');
        for (final subNote in note.subNotes) {
          buffer.writeln('- ${subNote.name}: ${subNote.content}');
        }
      }
      if (note.tags.isNotEmpty) {
        buffer.writeln('Tags: ${note.tags.join(', ')}');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String _buildMultiNoteQAPrompt(String question, String context) {
    return '''
Based on the following notes, please answer the question: "$question"

Context Notes:
$context

Please provide a comprehensive answer based on the information in the notes. If the answer cannot be found in the provided context, please state that clearly.
''';
  }

  static String _buildNoteTransformationPrompt(Note note, String transformationPrompt) {
    return '''
Please transform the following note according to the instruction: "$transformationPrompt"

Original Note:
Title: ${note.title}
Content: ${note.content}

Sub-notes:
${note.subNotes.map((sn) => '- ${sn.name}: ${sn.content}').join('\n')}

Please provide the transformed version of this note, maintaining the same structure but with the requested changes applied.
''';
  }

  static String _buildNewNoteCreationPrompt(String prompt, String context) {
    return '''
Based on the following context and prompt, please create one or more new notes.

Context Notes:
$context

User Prompt: "$prompt"

IMPORTANT: When creating tasks with dates, use the format YYYY-MM-DD and consider the current date context provided. For relative dates like "next Wednesday" or "tomorrow", calculate the actual date based on today's date.

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

If creating multiple notes, ensure they are related and useful based on the context and prompt. For tasks, make sure to set appropriate scheduledAt and completeBy dates based on the user's request and current date context.
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
