import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';

class SkillMetadata {
  final String noteId;
  final String skillRef;
  final String name;
  final String description;
  final bool enabled;
  final int? minContext;

  const SkillMetadata({
    required this.noteId,
    required this.skillRef,
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
    final skillRef =
        fields['skill_ref'] ??
        fields['skillRef'] ??
        fields['ref'] ??
        _slugifySkillRef(name);
    final minContextStr = fields['min_context'];
    final minContext = minContextStr != null
        ? int.tryParse(minContextStr)
        : null;
    return SkillMetadata(
      noteId: noteId,
      skillRef: skillRef,
      name: name,
      description: description,
      enabled: enabled,
      minContext: minContext,
    );
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
    final usedRefs = <String>{};
    for (final Note note in notes) {
      final meta = parseSkillMetadata(note.id, note.content);
      if (meta != null && meta.enabled) {
        final stableRef = _dedupeSkillRef(meta.skillRef, usedRefs);
        usedRefs.add(stableRef);
        index[note.id] = SkillMetadata(
          noteId: meta.noteId,
          skillRef: stableRef,
          name: meta.name,
          description: meta.description,
          enabled: meta.enabled,
          minContext: meta.minContext,
        );
      }
    }
    return index;
  }

  String buildSkillIndexPrompt(
    Map<String, SkillMetadata> index, {
    int? maxBudgetTokens,
    bool forLocalModel = false,
  }) {
    if (index.isEmpty) return '';
    final budget = maxBudgetTokens ?? 100000;
    // Local models need descriptions at all budget levels to make informed
    // skill selections — they lack the text tool catalog that cloud models get.
    final alwaysIncludeDescription = forLocalModel;
    final sb = StringBuffer();

    if (budget < _compactBudgetThreshold) {
      sb.writeln('\n## Available Agent Skills');
      sb.writeln(
        'If a skill matches the request, call load_skill using the listed skillRef.',
      );
      for (final entry in index.entries) {
        sb.writeln(
          _formatSkillEntry(
            entry,
            budget: budget,
            includeDescription: alwaysIncludeDescription,
          ),
        );
      }
    } else if (budget < _fullBudgetThreshold) {
      sb.writeln('\n## Available Agent Skills');
      sb.writeln(
        'If a skill matches the request, call load_skill using the listed skillRef.\n',
      );
      for (final entry in index.entries) {
        sb.writeln(
          _formatSkillEntry(
            entry,
            budget: budget,
            includeDescription: alwaysIncludeDescription,
          ),
        );
      }
    } else {
      sb.writeln('\n## Available Agent Skills');
      sb.writeln(
        'If a skill matches the request, call load_skill using the listed skillRef to retrieve its workflow instructions.\n',
      );
      for (final entry in index.entries) {
        sb.writeln(
          _formatSkillEntry(entry, budget: budget, includeDescription: true),
        );
      }
    }
    return sb.toString();
  }

  String _formatSkillEntry(
    MapEntry<String, SkillMetadata> entry, {
    required int budget,
    required bool includeDescription,
  }) {
    final limited =
        entry.value.minContext != null && entry.value.minContext! > budget;
    final parts = <String>[
      'skillRef=${entry.value.skillRef}',
      'name=${entry.value.name}',
      if (includeDescription) 'when=${entry.value.description}',
      if (limited) 'mode=limited',
    ];
    return '- ${parts.join(' | ')}';
  }

  String? resolveNoteIdForSkillRef(
    Map<String, SkillMetadata> index,
    String skillRef,
  ) {
    final normalized = skillRef.trim();
    if (normalized.isEmpty) return null;
    for (final entry in index.entries) {
      if (entry.value.skillRef == normalized) {
        return entry.key;
      }
    }
    return null;
  }

  String _dedupeSkillRef(String baseRef, Set<String> usedRefs) {
    final normalized = baseRef.trim().isEmpty
        ? 'skill'
        : _slugifySkillRef(baseRef);
    if (!usedRefs.contains(normalized)) {
      return normalized;
    }
    var counter = 2;
    while (usedRefs.contains('$normalized-$counter')) {
      counter++;
    }
    return '$normalized-$counter';
  }

  String _slugifySkillRef(String value) {
    final lower = value.toLowerCase();
    final slug = lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return slug.isEmpty ? 'skill' : slug;
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
