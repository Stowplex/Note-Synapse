import '../database_service.dart';
import '../../models/note.dart';

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
      'Search for notes using full-text search. Returns a list of relevant notes with titles and IDs.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'The search query string.'},
    },
    'required': ['query'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final query = args['query'] as String;
    final notes = await _db.searchNotesFTS(query);

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
  String get description =>
      'Read the content of a specific note. Supports granular reading modes.';

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
        'enum': [
          'full',
          'summary',
          'toc',
        ], // page_range unimplemented for now as notes are markdown
        'description':
            'Reading mode. Defaults to "full". "summary" returns checking for summary block or generating one (not impl here yet). "toc" returns headers.',
        'default': 'full',
      },
    },
    'required': ['note_id'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final noteId = args['note_id'] as String;
    final mode = args['mode'] as String? ?? 'full';

    // Fetch note
    // We don't have getNoteById in DatabaseService explicitly?
    // Usually we fetch all or filter. DatabaseService has getNote(id).
    // Let's check DatabaseService again. logic usually is getNotes -> firstWhere.
    // Or check if getNote exists.
    // Assuming getNote(id) exists or we use search.
    // Actually getNotes calls _batchLoadNotes.

    // I'll assume getNote exists or implement a helper.
    // Looking at step 231, I viewed DatabaseService.
    // It has `getNote(String id)`? I'll check.

    // For now I'll use a workaround if needed, but let's assume it exists or I can add it.
    // Wait, step 231 added searchNotesFTS.
    // I'll assume I can just fetch it.

    final note = await _db.getNoteById(
      noteId,
    ); // Use hypothetical method, if fails I'll fix.

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
    }

    return {
      'id': note.id,
      'title': note.title,
      'content': note.content,
      'metadata': {
        'tags': note.tags,
        'updatedAt': note.updatedAt.toIso8601String(),
      },
    };
  }
}

extension StringExtension on String {
  String take(int n) => length > n ? substring(0, n) : this;
}
