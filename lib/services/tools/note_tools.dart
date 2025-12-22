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
        'enum': ['full', 'summary', 'toc'],
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
