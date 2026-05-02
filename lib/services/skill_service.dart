import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';
import 'package:note_synapse/services/service_locator.dart';

class SkillMetadata {
  final String noteId;
  final String skillRef;
  final String name;
  final String description;
  final bool enabled;
  final int? minContext;

  /// Optional prompt-injection instruction telling the AI how to emit
  /// follow-up action chips (a fenced ```chips block) for this skill's
  /// mode. Null if the skill doesn't declare one. Concatenated with
  /// other loaded skills' defaultAction strings into the system prompt.
  final String? defaultAction;

  const SkillMetadata({
    required this.noteId,
    required this.skillRef,
    required this.name,
    required this.description,
    required this.enabled,
    this.minContext,
    this.defaultAction,
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
    final lines = frontmatter.split('\n');
    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) {
        i++;
        continue;
      }
      final key = line.substring(0, colonIdx).trim();
      final rawValue = line.substring(colonIdx + 1).trim();
      if (key.isEmpty) {
        i++;
        continue;
      }
      // Block scalar (`key: |` or `key: >`) — consume indented continuation.
      // Note: `>` is treated as `|` here (no folding-into-spaces). Real YAML
      // folds single newlines into spaces for `>`, but the use case (skill
      // default_action with multi-line prompt text) wants line structure
      // preserved either way. Tabs in continuation lines count as one column;
      // mix tabs and spaces at your own risk.
      if (rawValue == '|' || rawValue == '>') {
        final buffer = StringBuffer();
        i++;
        int? indent;
        bool hasContent = false;
        while (i < lines.length) {
          final next = lines[i];
          if (next.trim().isEmpty) {
            if (hasContent) buffer.writeln();
            i++;
            continue;
          }
          final leadingSpaces = next.length - next.trimLeft().length;
          if (leadingSpaces == 0) break;
          indent ??= leadingSpaces;
          if (leadingSpaces < indent) break;
          if (hasContent) buffer.writeln();
          buffer.write(next.substring(indent));
          hasContent = true;
          i++;
        }
        fields[key] = buffer.toString();
      } else {
        fields[key] = rawValue;
        i++;
      }
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
    final rawDefaultAction = fields['default_action']?.trim();
    // Treat a value that is solely a YAML comment ("# ...") as no value.
    // The hand-rolled parser doesn't strip inline trailing comments, but a
    // value that *starts* with `#` is unambiguously commentary, not content.
    final defaultAction = (rawDefaultAction == null ||
            rawDefaultAction.isEmpty ||
            rawDefaultAction.startsWith('#'))
        ? null
        : rawDefaultAction;
    return SkillMetadata(
      noteId: noteId,
      skillRef: skillRef,
      name: name,
      description: description,
      enabled: enabled,
      minContext: minContext,
      defaultAction: defaultAction,
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
          defaultAction: meta.defaultAction,
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

    final String templatePath;
    final bool includeDescription;
    if (budget < _compactBudgetThreshold) {
      templatePath = 'skills/skill_index_compact';
      includeDescription = alwaysIncludeDescription;
    } else if (budget < _fullBudgetThreshold) {
      templatePath = 'skills/skill_index_medium';
      includeDescription = alwaysIncludeDescription;
    } else {
      templatePath = 'skills/skill_index_full';
      includeDescription = true;
    }

    final skills = index.entries.map((entry) {
      return {
        'entryLine': _formatSkillEntry(
          entry,
          budget: budget,
          includeDescription: includeDescription,
        ),
      };
    }).toList();

    return getIt<PromptTemplateService>().renderSync(
      templatePath,
      {'skills': skills},
    );
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

  /// Returns a system-prompt section containing the concatenated
  /// default_action instruction text from every skill in [index] whose
  /// `defaultAction` is non-null. Skills are sorted by `skillRef`
  /// (alphabetical) so the output is reproducible across runs.
  ///
  /// Returns an empty string if no skill declares a defaultAction —
  /// callers should append the result unconditionally; an empty append
  /// is a no-op.
  String buildDefaultActionPromptSection(Map<String, SkillMetadata> index) {
    final withAction = index.values
        .where((m) =>
            m.enabled &&
            m.defaultAction != null &&
            m.defaultAction!.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => a.skillRef.compareTo(b.skillRef));
    if (withAction.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('## Skill Default Actions');
    buf.writeln(
      'The following skill-driven instructions modify how you should '
      'present follow-up actions to the reader. Apply all that are relevant.',
    );
    for (final m in withAction) {
      buf.writeln();
      buf.writeln('### From skill `${m.skillRef}` (${m.name})');
      buf.writeln(m.defaultAction);
    }
    return buf.toString().trimRight();
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
    return regex.allMatches(content).map((m) => m.group(0)!).toSet().toList();
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
