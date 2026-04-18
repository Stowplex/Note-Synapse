import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'note_tools.dart';

class LoadSkillTool extends NativeTool {
  // Cache: noteId -> formatted content
  final Map<String, String> _cache = {};

  @override
  String get name => 'load_skill';

  @override
  String get description =>
      'Load a skill note by skillRef or noteId to get detailed workflow instructions for a specific task or workflow type. '
      'Use this when a skill in the Available Agent Skills list is relevant to the current task.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'noteId': {
        'type': 'string',
        'description':
            'The note ID of the skill to load (legacy; use skillRef when available)',
      },
      'skillRef': {
        'type': 'string',
        'description':
            'The skillRef of the skill to load (from the Available Agent Skills list)',
      },
    },
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final skillRef = (args['skillRef'] as String? ?? '').trim();
    var noteId = (args['noteId'] as String? ?? '').trim();

    final skillService = getIt<SkillService>();
    // Always resolve skillRef first — it's the canonical identifier.
    // noteId is legacy; when both are present, skillRef takes precedence.
    if (skillRef.isNotEmpty) {
      final index = await skillService.buildSkillIndex();
      final resolved = skillService.resolveNoteIdForSkillRef(index, skillRef);
      if (resolved != null && resolved.isNotEmpty) {
        noteId = resolved;
      } else if (noteId.isEmpty) {
        return {'error': 'Skill ref "$skillRef" not found'};
      }
    }

    if (noteId.isEmpty) {
      return {'error': 'skillRef or noteId is required'};
    }

    // Return from cache if already loaded this session
    if (_cache.containsKey(noteId)) return _cache[noteId]!;

    final db = getIt<DatabaseService>();
    final note = await db.getNote(noteId);
    if (note == null) return {'error': 'Skill note $noteId not found'};

    final meta = skillService.parseSkillMetadata(noteId, note.content);
    if (meta == null) {
      return {
        'error':
            'Note $noteId is not a valid skill (missing or malformed frontmatter)',
      };
    }
    if (!meta.enabled) return {'error': "Skill '${meta.name}' is disabled"};

    final body = skillService.stripFrontmatter(note.content);
    final formatted = '# Skill: ${meta.name}\n\n$body';

    _cache[noteId] = formatted;
    skillService.markLoaded(noteId);
    return formatted;
  }

  /// Clear this tool's content cache for a new agent session.
  ///
  /// IMPORTANT: Must be called alongside [SkillService.resetSession].
  /// Both caches must be cleared together — [LoadSkillTool] caches the
  /// formatted content, while [SkillService] tracks which note IDs have
  /// been marked as loaded. Resetting one without the other leaves state
  /// inconsistent.
  void resetSession() => _cache.clear();
}
