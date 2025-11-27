/// Utilities for protecting against prompt injection attacks
///
/// This module provides functions to properly quote and format user-provided
/// content (notes, attachments, etc.) to prevent prompt injection when sending
/// data to LLMs.
class PromptInjectionProtection {
  /// Quotes content for safe inclusion in prompts using XML-style markers
  /// This clearly marks content as data, not instructions
  /// Uses <DATA_ONLY_DOCUMENT> tags instead of triple backticks to avoid
  /// conflicts with markdown code blocks in note content
  static String quoteAsData(String content) {
    if (content.trim().isEmpty) {
      return '<DATA_ONLY_DOCUMENT></DATA_ONLY_DOCUMENT>';
    }
    // Use XML-style tags to clearly delimit data content
    // This helps LLMs distinguish between instructions and data
    // and avoids conflicts with markdown code blocks (```) in notes
    return '<DATA_ONLY_DOCUMENT>\n$content\n</DATA_ONLY_DOCUMENT>';
  }

  /// Escapes content for safe inclusion in prompts
  /// Replaces potentially dangerous patterns with safe alternatives
  static String escapeForPrompt(String content) {
    // For now, we rely on proper quoting rather than escaping
    // as escaping can corrupt legitimate content
    return content;
  }

  /// Formats note content with clear data markers using XML-style tags
  /// This is used in conversation contexts where notes may contain markdown
  static String formatNoteContentAsData(String content) {
    return quoteAsData(content);
  }

  /// Formats title with proper quoting
  static String formatTitleAsData(String title) {
    // Titles are shorter, so we can use simpler quoting
    // Escape quotes if present
    final escaped = title.replaceAll('"', '\\"');
    return '"$escaped"';
  }
}
