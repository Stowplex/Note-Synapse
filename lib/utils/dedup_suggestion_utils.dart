import '../models/dedup_rule.dart';

class DedupSuggestionUtils {
  const DedupSuggestionUtils._();

  static String? resolveTagName(String tagName, List<String> existingTags) {
    final normalized = tagName.trim();
    if (normalized.isEmpty) {
      return null;
    }

    return existingTags.contains(normalized) ? normalized : null;
  }

  static String? _normalizeReplacementTag(String tagName) {
    final normalized = tagName.trim();
    if (normalized.isEmpty) {
      return null;
    }

    return normalized;
  }

  static List<DedupRule> normalizeSuggestions(
    List<DedupRule> suggestions,
    List<String> existingTags,
  ) {
    final normalized = <DedupRule>[];

    for (final suggestion in suggestions) {
      final resolvedLeft = resolveTagName(suggestion.leftTag, existingTags);
      final resolvedRight = _normalizeReplacementTag(suggestion.rightTag);

      if (resolvedLeft != null && resolvedRight != null) {
        normalized.add(
          suggestion.copyWith(
            leftTag: resolvedLeft,
            rightTag: resolvedRight,
          ),
        );
      }
    }

    return normalized;
  }
}

