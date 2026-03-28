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
      'Load a skill note by ID to get detailed workflow instructions for a specific task or workflow type. '
      'Use this when a skill in the Available Agent Skills list is relevant to the current task.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'noteId': {
        'type': 'string',
        'description': 'The note ID of the skill to load (from the Available Agent Skills list)',
      },
    },
    'required': ['noteId'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final noteId = (args['noteId'] as String? ?? '').trim();
    if (noteId.isEmpty) return {'error': 'noteId is required'};

    // Return from cache if already loaded this session
    if (_cache.containsKey(noteId)) return _cache[noteId]!;

    final db = getIt<DatabaseService>();
    final skillService = getIt<SkillService>();

    final note = await db.getNote(noteId);
    if (note == null) return {'error': 'Skill note $noteId not found'};

    final meta = skillService.parseSkillMetadata(noteId, note.content);
    if (meta == null) {
      return {'error': 'Note $noteId is not a valid skill (missing or malformed frontmatter)'};
    }
    if (!meta.enabled) return {'error': "Skill '${meta.name}' is disabled"};

    final body = skillService.stripFrontmatter(note.content);
    final formatted = '# Skill: ${meta.name}\n\n$body';

    _cache[noteId] = formatted;
    skillService.markLoaded(noteId);
    return formatted;
  }

  /// Clear cache for a new session.
  void resetSession() => _cache.clear();
}
