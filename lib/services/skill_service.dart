import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';

class SkillMetadata {
  final String noteId;
  final String name;
  final String description;
  final bool enabled;
  final int? minContext;

  const SkillMetadata({
    required this.noteId,
    required this.name,
    required this.description,
    required this.enabled,
    this.minContext,
  });
}

class SkillService {
  static const String agentSkillTag = 'agent-skill';
  static const int _compactBudgetThreshold = 15000;
  static const int _fullBudgetThreshold = 50000;

  final DatabaseService _db;
  final Set<String> _loadedSkillNoteIds = {};

  SkillService(this._db);

  // --- Parsing ---

  SkillMetadata? parseSkillMetadata(String noteId, String content) {
    if (!content.startsWith('---\n')) return null;
    final endIdx = content.indexOf('\n---\n', 4);
    if (endIdx == -1) return null;
    final frontmatter = content.substring(4, endIdx);
    final fields = <String, String>{};
    for (final line in frontmatter.split('\n')) {
      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) continue;
      final key = line.substring(0, colonIdx).trim();
      final value = line.substring(colonIdx + 1).trim();
      if (key.isNotEmpty) fields[key] = value;
    }
    final name = fields['name'];
    final description = fields['description'];
    if (name == null || name.isEmpty) return null;
    if (description == null || description.isEmpty) return null;
    final enabled = fields['enabled']?.toLowerCase() != 'false';
    final minContextStr = fields['min_context'];
    final minContext = minContextStr != null ? int.tryParse(minContextStr) : null;
    return SkillMetadata(
        noteId: noteId, name: name, description: description, enabled: enabled,
        minContext: minContext);
  }

  String stripFrontmatter(String content) {
    if (!content.startsWith('---\n')) return content;
    final endIdx = content.indexOf('\n---\n', 4);
    if (endIdx == -1) return content;
    return content.substring(endIdx + 5).trim();
  }

  // --- Index ---

  Future<Map<String, SkillMetadata>> buildSkillIndex() async {
    final notes = await _db.getNotesByTag(agentSkillTag);
    final index = <String, SkillMetadata>{};
    for (final Note note in notes) {
      final meta = parseSkillMetadata(note.id, note.content);
      if (meta != null && meta.enabled) {
        index[note.id] = meta;
      }
    }
    return index;
  }

  String buildSkillIndexPrompt(Map<String, SkillMetadata> index, {int? maxBudgetTokens}) {
    if (index.isEmpty) return '';
    final budget = maxBudgetTokens ?? 100000;
    final sb = StringBuffer();

    if (budget < _compactBudgetThreshold) {
      // No per-skill annotations in minimal format — space too constrained
      sb.writeln('\n## Available Agent Skills');
      sb.writeln('Use load_skill with the noteId to get instructions.');
      sb.writeln(index.entries.map((e) => '${e.key}: ${e.value.name}').join(', '));
    } else if (budget < _fullBudgetThreshold) {
      sb.writeln('\n## Available Agent Skills');
      sb.writeln('Use load_skill with the noteId to get instructions.\n');
      for (final entry in index.entries) {
        final limited = entry.value.minContext != null && entry.value.minContext! > budget;
        final suffix = limited ? ' (limited mode)' : '';
        sb.writeln('${entry.key}: ${entry.value.name}$suffix');
      }
    } else {
      sb.writeln('\n## Available Agent Skills');
      sb.writeln('When a skill is relevant, call load_skill with the noteId to get workflow instructions.\n');
      for (final entry in index.entries) {
        final limited = entry.value.minContext != null && entry.value.minContext! > budget;
        final suffix = limited ? ' (limited mode)' : '';
        sb.writeln('${entry.key}: ${entry.value.name} — ${entry.value.description}$suffix');
      }
    }
    return sb.toString();
  }

  // --- Tool URI extraction ---

  List<String> extractToolUris(String content) {
    final regex = RegExp(r'notesynapse://tool/[^\s\)\"\x27.,;>]+');
    return regex.allMatches(content).map((m) => m.group(0)!).toList();
  }

  /// Parse a notesynapse://tool/ URI into its components.
  /// Returns null if the URI is not a valid tool URI.
  ({String namespace, String id, String? function})? parseToolUri(String uri) {
    const prefix = 'notesynapse://tool/';
    if (!uri.startsWith(prefix)) return null;
    final path = uri.substring(prefix.length);
    final parts = path.split('/');
    if (parts.length < 2) return null;
    final namespace = parts[0]; // builtin | user_defined | mcp
    final id = parts[1];
    final function = parts.length > 2 ? parts[2] : null;
    return (namespace: namespace, id: id, function: function);
  }

  // --- Deduplication ---

  bool isAlreadyLoaded(String noteId) => _loadedSkillNoteIds.contains(noteId);

  void markLoaded(String noteId) => _loadedSkillNoteIds.add(noteId);

  void resetSession() => _loadedSkillNoteIds.clear();
}
