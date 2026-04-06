import 'package:note_synapse/services/database_service.dart';

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
  TagWorkflowService(this._db);

  Future<List<ResolvedBinding>> resolveBindings(List<String> tags) async {
    final results = <ResolvedBinding>[];
    final prefixBindings = await _db.getPrefixWorkflowBindings();
    final prefixMatches = <String, List<String>>{};

    for (final tag in tags) {
      final exact = await _db.getExactWorkflowBinding(tag);
      if (exact != null) {
        results.add(ResolvedBinding(
          skillNoteId: exact.skillNoteId,
          matchedTag: tag,
          pattern: exact.pattern,
          prompt: exact.prompt,
          contentImmutable: exact.contentImmutable,
        ));
        continue;
      }
      for (final binding in prefixBindings) {
        if (tag.startsWith(binding.pattern) && tag.length > binding.pattern.length) {
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
      results.add(ResolvedBinding(
        skillNoteId: binding.skillNoteId,
        matchedTag: entry.value.first,
        pattern: entry.key,
        prompt: binding.prompt,
        contentImmutable: binding.contentImmutable,
      ));
    }

    return results;
  }

  Future<bool> hasImmutableBinding(List<String> tags) async {
    final bindings = await resolveBindings(tags);
    return bindings.any((b) => b.contentImmutable);
  }

  Future<void> registerBinding({
    required String pattern,
    required bool isPrefix,
    required String skillNoteId,
    required String prompt,
    required bool contentImmutable,
  }) async {
    await _db.insertWorkflowBinding(WorkflowBindingRow(
      pattern: pattern,
      isPrefix: isPrefix,
      skillNoteId: skillNoteId,
      prompt: prompt,
      contentImmutable: contentImmutable,
    ));
  }

  Future<void> removeBinding(String pattern) async {
    await _db.deleteWorkflowBinding(pattern);
  }
}
