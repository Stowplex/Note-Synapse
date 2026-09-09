import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
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

    // Return from cache if already loaded this session.
    //
    // Not a hole in the Space check below: a cache hit means this session
    // already loaded that skill, so its content is in the model's context
    // regardless, and the cache is cleared per session by [resetSession].
    if (_cache.containsKey(noteId)) return _cache[noteId]!;

    final db = getIt<DatabaseService>();
    final note = await db.getNote(noteId);
    final content = note?.content;
    if (content == null) return {'error': 'Skill note $noteId not found'};

    // A skill hidden by the active Space must be unreachable, not merely
    // unlisted (design decision 7). `buildSkillIndex` already filters what the
    // model is *told* about, but a note id survives in conversation history
    // across a Space switch, and the legacy `noteId` argument bypasses the
    // index entirely — so a model quoting an id from earlier in the session
    // could load a skill the current Space cannot see. Deliberately the same
    // "not found" answer as a missing note: which Spaces a skill is filed
    // under is not something a hidden skill should disclose.
    if (!SpaceScopeService.shared().skillVisible(note!.tags)) {
      return {'error': 'Skill note $noteId not found'};
    }

    final meta = skillService.parseSkillMetadata(noteId, content);
    if (meta == null) {
      return {
        'error':
            'Note $noteId is not a valid skill (missing or malformed frontmatter)',
      };
    }
    if (!meta.enabled) return {'error': "Skill '${meta.name}' is disabled"};

    final body = skillService.stripFrontmatter(content);
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
