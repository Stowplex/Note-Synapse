import '../models/dedup_rule.dart';

class DedupSuggestionUtils {
  const DedupSuggestionUtils._();

  static String? resolveTagName(String tagName, List<String> existingTags) {
    final normalized = tagName.trim();
    if (normalized.isEmpty) {
      return null;
    }

    for (final tag in existingTags) {
      if (tag == normalized) {
        return tag;
      }
    }

    final normalizedLower = normalized.toLowerCase();
    for (final tag in existingTags) {
      if (tag.toLowerCase() == normalizedLower) {
        return tag;
      }
    }

    return null;
  }

  static List<DedupRule> normalizeSuggestions(
    List<DedupRule> suggestions,
    List<String> existingTags,
  ) {
    final normalized = <DedupRule>[];

    for (final suggestion in suggestions) {
      final resolvedLeft = resolveTagName(suggestion.leftTag, existingTags);
      final resolvedRight = resolveTagName(suggestion.rightTag, existingTags);

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

