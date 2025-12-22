import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../database_service.dart';
import '../../models/note.dart';
import '../ai_service.dart';
import '../../models/generation_context.dart';

abstract class NativeTool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;
  Future<dynamic> execute(Map<String, dynamic> args);
}

class NoteSearchTool implements NativeTool {
  final DatabaseService _db = DatabaseService();

  @override
  String get name => 'search_notes';

  @override
  String get description =>
      'Search for notes using full-text search. Returns a list of relevant notes with titles and IDs. Supports optional tag filtering.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'The search query string.'},
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional list of tags to filter by.',
      },
    },
    'required': ['query'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final query = args['query'] as String;
    final tags = (args['tags'] as List?)?.cast<String>();

    final notes = await _db.searchNotesFTS(query, tags: tags);

    return notes
        .map(
          (n) => {
            'id': n.id,
            'title': n.title,
            'snippet': n.content.length > 200
                ? n.content.substring(0, 200) + '...'
                : n.content,
            'tags': n.tags,
          },
        )
        .toList();
  }
}

class NoteReadTool implements NativeTool {
  final DatabaseService _db = DatabaseService();

  @override
  String get name => 'read_note';

  @override
  String get description => '''
Read the content of a specific note. Supports granular reading modes:
- 'full' (default):
    - If `extraction_guide` is provided: Uses an AI model to extract specific information from the note AND its attachments based on your guide. Use this for efficient reading.
    - If NO `extraction_guide`: Returns the textual note content and a list of attachment paths.
    - HINT: If you read a note and see it has 'attachments' that you need to analyze, call this tool again WITH an `extraction_guide` describing what you need from them.
- 'summary': Returns the note's summary block or first 500 chars.
- 'toc': Returns the Table of Contents (headers).
''';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'note_id': {
        'type': 'string',
        'description': 'The ID of the note to read.',
      },
      'mode': {
        'type': 'string',
        'enum': ['full', 'summary', 'toc'],
        'description': 'Reading mode. Defaults to "full".',
        'default': 'full',
      },
      'extraction_guide': {
        'type': 'string',
        'description':
            'Optional. If provided, uses AI to extract specific info from note and attachments.',
      },
    },
    'required': ['note_id'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final noteId = args['note_id'] as String;
    final mode = args['mode'] as String? ?? 'full';
    final extractionGuide = args['extraction_guide'] as String?;

    final note = await _db.getNoteById(noteId);

    if (note == null) {
      return {'error': 'Note not found'};
    }

    if (mode == 'summary') {
      // Return custom summary block if exists, else first 500 chars
      final summaryMatch = RegExp(
        r'> \[!SUMMARY\]\n(.*?)(?=\n\n|$)',
      ).firstMatch(note.content);
      if (summaryMatch != null) {
        return {'summary': summaryMatch.group(1)};
      }
      return {'preview': note.content.take(500)};
    } else if (mode == 'toc') {
      // Extract headers
      final headers = RegExp(r'^(#{1,6})\s+(.+)$', multiLine: true)
          .allMatches(note.content)
          .map((m) => {'level': m.group(1)!.length, 'text': m.group(2)})
          .toList();
      return {'toc': headers};
    } else {
      // Mode is 'full'
      if (extractionGuide != null && extractionGuide.isNotEmpty) {
        // AI Extraction Mode
        try {
          final attachments = <PlatformFile>[];
          for (final path in note.attachmentPaths) {
            final file = File(path);
            if (await file.exists()) {
              attachments.add(
                PlatformFile(
                  name: path.split('/').last,
                  path: path,
                  size: await file.length(),
                  bytes: await file.readAsBytes(),
                ),
              );
            }
          }

          final prompt =
              '''
Analyze the following note and its attachments based on the Extraction Guide.

Note Title: ${note.title}
Note Content:
${note.content}

Extraction Guide:
$extractionGuide
''';

          final aiResponse = await AIService.generateWithAttachments(
            prompt,
            attachments,
            generationContext: GenerationContext(
              values: {'type': 'tool_extraction', 'noteId': note.id},
            ),
          );

          return {'id': note.id, 'title': note.title, 'extraction': aiResponse};
        } catch (e) {
          return {
            'error': 'Failed to perform AI extraction: $e',
            'content': note.content, // Fallback
          };
        }
      } else {
        // Standard Full Read
        return {
          'id': note.id,
          'title': note.title,
          'content': note.content,
          'attachments': note.attachmentPaths,
          'hint':
              'To analyze attachments, recall read_note with an extraction_guide.',
          'metadata': {
            'tags': note.tags,
            'updatedAt': note.updatedAt.toIso8601String(),
          },
        };
      }
    }
  }
}

class RunSqlTool implements NativeTool {
  final DatabaseService _db = DatabaseService();

  @override
  String get name => 'run_sql';

  @override
  String get description =>
      'Run a read-only SQL query on the local database. Tables: notes(id, title, content, tags, ...), tags(id, name), conversations(...). Useful for counting, aggregating, or finding patterns not covered by FTS.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'The SQL SELECT query to run.',
      },
    },
    'required': ['query'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final query = args['query'] as String;
    if (!query.trim().toUpperCase().startsWith('SELECT')) {
      return {'error': 'Only SELECT queries are allowed.'};
    }

    try {
      final results = await _db.runRawQuery(query);
      if (results.isEmpty) return 'No results found.';
      if (results.length > 50) {
        return {
          'warning': 'Result truncated to 50 rows',
          'data': _formatTable(results.take(50).toList()),
        };
      }
      return _formatTable(results);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  String _formatTable(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return '';
    final headers = rows.first.keys.toList();
    final buffer = StringBuffer();
    buffer.write('| ${headers.join(' | ')} |\n');
    buffer.write('| ${headers.map((_) => '---').join(' | ')} |\n');
    for (final row in rows) {
      buffer.write(
        '| ${headers.map((h) => row[h]?.toString().replaceAll('\n', ' ') ?? '').join(' | ')} |\n',
      );
    }
    return buffer.toString();
  }
}

extension StringExtension on String {
  String take(int n) => length > n ? substring(0, n) : this;
}
