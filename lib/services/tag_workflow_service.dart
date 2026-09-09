import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';

class ResolvedBinding {
  final String skillNoteId;
  final String matchedTag;
  final String pattern;
  final String prompt;
  final bool contentImmutable;

  const ResolvedBinding({
    required this.skillNoteId,
    required this.matchedTag,
    required this.pattern,
    required this.prompt,
    required this.contentImmutable,
  });
}

class TagWorkflowService {
  final DatabaseService _db;
  final SpaceScopeService _spaceScope;

  /// [spaceScope] supplies the known Spaces used by the reach rule in
  /// [resolveBindings]. Optional and named for the same reason as everywhere
  /// else in this build: the service is constructed positionally in several
  /// tests and in `service_locator.dart`.
  TagWorkflowService(this._db, {SpaceScopeService? spaceScope})
    : _spaceScope = spaceScope ?? SpaceScopeService.shared();

  /// Bindings that fire for a note carrying [tags].
  ///
  /// A binding fires when the note being ingested is within the bound skill's
  /// **reach**:
  ///
  /// | Skill carries    | Fires for a note that…            |
  /// |------------------|-----------------------------------|
  /// | `all-spaces`     | always                            |
  /// | Space S's tags   | carries S's include-tags          |
  /// | neither          | matches no Space                  |
  ///
  /// Deliberately note-based rather than active-Space-based: ingestion is
  /// asynchronous and routinely finishes after the user has switched Spaces,
  /// so keying on what is active at completion time would apply a different
  /// workflow to the same note depending on timing.
  ///
  /// See [hasImmutableBinding] for the one thing this filtering must never
  /// weaken.
  Future<List<ResolvedBinding>> resolveBindings(List<String> tags) async {
    final all = await _resolveAllBindings(tags);
    if (_spaceScope.spaceSnapshots.isEmpty) return all;
    final reachable = <ResolvedBinding>[];
    for (final binding in all) {
      if (await _skillReaches(binding.skillNoteId, tags)) {
        reachable.add(binding);
      }
    }
    return reachable;
  }

  /// Every binding matching [tags], before the Space reach rule is applied.
  Future<List<ResolvedBinding>> _resolveAllBindings(List<String> tags) async {
    final results = <ResolvedBinding>[];
    final prefixBindings = await _db.getPrefixWorkflowBindings();
    final prefixMatches = <String, List<String>>{};

    for (final tag in tags) {
      final exact = await _db.getExactWorkflowBinding(tag);
      if (exact != null) {
        results.add(
          ResolvedBinding(
            skillNoteId: exact.skillNoteId,
            matchedTag: tag,
            pattern: exact.pattern,
            prompt: exact.prompt,
            contentImmutable: exact.contentImmutable,
          ),
        );
        continue;
      }
      for (final binding in prefixBindings) {
        if (tag.startsWith(binding.pattern) &&
            tag.length > binding.pattern.length) {
          prefixMatches.putIfAbsent(binding.pattern, () => []).add(tag);
        }
      }
    }

    for (final entry in prefixMatches.entries) {
      if (entry.value.length > 1) {
        throw Exception(
          'ambiguous workflow binding: tags ${entry.value.join(", ")} '
          'both match prefix pattern "${entry.key}". Remove all but one.',
        );
      }
      final binding = prefixBindings.firstWhere((b) => b.pattern == entry.key);
      results.add(
        ResolvedBinding(
          skillNoteId: binding.skillNoteId,
          matchedTag: entry.value.first,
          pattern: entry.key,
          prompt: binding.prompt,
          contentImmutable: binding.contentImmutable,
        ),
      );
    }

    return results;
  }

  /// Whether any binding for [tags] marks the note's content immutable.
  ///
  /// **Correction C6: reach must never weaken immutability.** This deliberately
  /// reads the *unfiltered* binding set. A note protected in one Space would
  /// otherwise become editable simply by activating another Space, or by having
  /// none active — turning a protection into a mode. Reach decides which
  /// workflow *runs*; it never decides whether content is writable.
  Future<bool> hasImmutableBinding(List<String> tags) async {
    final bindings = await _resolveAllBindings(tags);
    return bindings.any((b) => b.contentImmutable);
  }

  /// Whether a note carrying [noteTags] is within reach of the skill note
  /// [skillNoteId] — the table documented on [resolveBindings].
  ///
  /// A skill note that cannot be read (deleted, or a bundled asset path that is
  /// not a note at all) counts as `all-spaces`: dropping its binding would
  /// silently disable a workflow, which is a worse failure than running one.
  Future<bool> _skillReaches(String skillNoteId, List<String> noteTags) async {
    final skill = await _db.getNote(skillNoteId);
    if (skill == null) return true;
    final skillTags = skill.tags;
    if (skillTags.contains(SpaceScopeService.allSpacesTag)) return true;
    final spaces = _spaceScope.spaceSnapshots
        .where((s) => s.includeTags.isNotEmpty)
        .toList();
    final skillSpaces = spaces
        .where((s) => s.includeTags.every(skillTags.contains))
        .toList();
    if (skillSpaces.isEmpty) {
      // Unfiled skill: reaches only notes that are themselves unfiled.
      return !spaces.any((s) => s.includeTags.every(noteTags.contains));
    }
    return skillSpaces.any((s) => s.includeTags.every(noteTags.contains));
  }

  Future<WorkflowBindingRow?> getBindingByPattern(String pattern) async {
    return _db.getWorkflowBindingByPattern(pattern);
  }

  Future<List<WorkflowBindingRow>> getAllBindings() async {
    return _db.getAllWorkflowBindings();
  }

  Future<void> registerBinding({
    required String pattern,
    required bool isPrefix,
    required String skillNoteId,
    required String prompt,
    required bool contentImmutable,
  }) async {
    await _db.insertWorkflowBinding(
      WorkflowBindingRow(
        pattern: pattern,
        isPrefix: isPrefix,
        skillNoteId: skillNoteId,
        prompt: prompt,
        contentImmutable: contentImmutable,
      ),
    );
  }

  Future<void> removeBinding(String pattern) async {
    await _db.deleteWorkflowBinding(pattern);
  }
}
