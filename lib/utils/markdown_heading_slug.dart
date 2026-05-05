/// GitHub-style markdown heading slug generation.
///
/// Mirrors the slug shape produced by GitHub's anchor links so that
/// `[text](#section)` resolves to the heading with the matching slug.
library;

/// Convert a raw heading text (the part after `#` markers) into a slug.
///
/// Behavior:
/// - Strips inline markdown delimiters (`**`, `__`, `*`, `_`, `~~`, `` ` ``).
/// - Reduces `[text](url)` to `text` and `![alt](url)` to `alt`.
/// - Lowercases.
/// - Replaces runs of characters that are not letters, digits, `-`, or `_`
///   with a single `-`. Unicode letters/digits are preserved.
/// - Trims leading and trailing `-`.
String slugifyHeading(String raw) {
  var text = raw.trim();

  // Strip leading `#` markers if a full heading line was passed in.
  text = text.replaceFirst(RegExp(r'^#{1,6}\s*'), '');

  // Reduce image links: ![alt](url) -> alt
  text = text.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\([^\)]*\)'),
    (m) => m.group(1) ?? '',
  );

  // Reduce inline links: [text](url) -> text
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^\)]*\)'),
    (m) => m.group(1) ?? '',
  );

  // Strip emphasis / code / strikethrough delimiters (order matters — longer first).
  for (final pattern in const ['**', '__', '~~', '*', '_', '`']) {
    text = text.replaceAll(pattern, '');
  }

  text = text.toLowerCase();

  // Replace any run of characters that aren't a Unicode letter/digit, `-`, or `_`
  // with a single `-`.
  text = text.replaceAll(
    RegExp(r'[^\p{L}\p{N}_-]+', unicode: true),
    '-',
  );

  // Trim leading/trailing hyphens.
  text = text.replaceAll(RegExp(r'^-+|-+$'), '');

  return text;
}

/// Tracks duplicate slugs within a single document, GitHub-style.
///
/// First occurrence of a base slug returns it unchanged; subsequent
/// occurrences receive `-1`, `-2`, ... suffixes in document order.
class HeadingSlugCounter {
  final Map<String, int> _seen = {};

  /// Record the next slug for [base] and return the disambiguated slug.
  String next(String base) {
    final count = _seen[base] ?? 0;
    _seen[base] = count + 1;
    if (count == 0) return base;
    return '$base-$count';
  }

  void reset() => _seen.clear();
}
