class MarkdownCleaner {
  /// Unescapes characters that are aggressively escaped by html2md.
  ///
  /// This systematically cleans up spurious backslashes resulting from the conversion,
  /// restoring a more readable Markdown format while risking some semantic changes
  /// (e.g., "1. item" text might be interpreted as a list item).
  static String clean(String markdown) {
    if (markdown.isEmpty) return markdown;

    var cleaned = markdown;

    // Unescape number + dot (e.g. "1\. " -> "1. ")
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'^(\d+)\\\. ', multiLine: true),
      (match) => '${match[1]}. ',
    );

    // Unescape specific characters
    // We iterate through patterns to be explicit about what we assume is safe to unescape.
    final simpleEscapes = [
      r'\[', r'\]', // Brackets
      r'\(', r'\)', // Parentheses (less common but possible)
      r'\_', // Underscores
      r'\*', // Asterisks
      r'\!', // Exclamation marks
      r'\>', // Blockquotes
      r'\-', // Hyphens (list markers)
      r'\+', // Plus signs (list markers)
      r'\#', // Hashes (headings)
      r'\`', // Backticks
    ];

    for (final escaped in simpleEscapes) {
      // Create a pattern that matches the escaped character
      // e.g. \\\[ matches "\[" literal in the string
      final char = escaped.replaceAll(r'\', '');
      cleaned = cleaned.replaceAll('\\$char', char);
    }

    // Unescape pipe `|` for tables if not properly handled,
    // but html2md usually handles tables well.
    // We'll leave `\|` alone for now as it might be inside a table cell.

    return cleaned;
  }
}
