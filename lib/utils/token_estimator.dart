/// Token estimation utility for accurate token counting.
///
/// This provides a heuristic-based token estimation that is more accurate
/// than word count, especially for CJK (Chinese, Japanese, Korean) text
/// where individual characters are full semantic units.
class TokenEstimator {
  TokenEstimator._();

  /// Estimates the token count for the given text.
  ///
  /// Uses character-based heuristics:
  /// - Latin text: ~1 token per 4 characters (standard tokenizer behavior)
  /// - CJK text: ~1 token per character (characters are semantic units)
  /// - Mixed content: weighted calculation based on character type
  ///
  /// This is more accurate than word count for CJK text, where splitting by
  /// whitespace would count an entire sentence as one "word".
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;

    int cjkChars = 0;
    int nonCjkChars = 0;

    for (final rune in text.runes) {
      if (_isCjkCharacter(rune)) {
        cjkChars++;
      } else {
        nonCjkChars++;
      }
    }

    // CJK: ~1 token per character
    // Non-CJK (Latin, punctuation, etc.): ~1 token per 4 characters
    final cjkTokens = cjkChars;
    final nonCjkTokens = (nonCjkChars / 4).ceil();

    return cjkTokens + nonCjkTokens;
  }

  /// Checks if a Unicode code point is a CJK character.
  ///
  /// Covers the main CJK Unicode ranges:
  /// - CJK Unified Ideographs (4E00-9FFF)
  /// - CJK Unified Ideographs Extension A (3400-4DBF)
  /// - CJK Unified Ideographs Extension B+ (20000-2A6DF, etc.)
  /// - Hiragana (3040-309F)
  /// - Katakana (30A0-30FF)
  /// - Hangul Syllables (AC00-D7AF)
  /// - Hangul Jamo (1100-11FF)
  /// - CJK Symbols and Punctuation (3000-303F)
  /// - Fullwidth ASCII variants (FF00-FFEF)
  static bool _isCjkCharacter(int codePoint) {
    return
    // CJK Unified Ideographs
    (codePoint >= 0x4E00 && codePoint <= 0x9FFF) ||
        // CJK Extension A
        (codePoint >= 0x3400 && codePoint <= 0x4DBF) ||
        // CJK Extension B
        (codePoint >= 0x20000 && codePoint <= 0x2A6DF) ||
        // CJK Extension C
        (codePoint >= 0x2A700 && codePoint <= 0x2B73F) ||
        // CJK Extension D
        (codePoint >= 0x2B740 && codePoint <= 0x2B81F) ||
        // CJK Extension E
        (codePoint >= 0x2B820 && codePoint <= 0x2CEAF) ||
        // CJK Extension F
        (codePoint >= 0x2CEB0 && codePoint <= 0x2EBEF) ||
        // Hiragana
        (codePoint >= 0x3040 && codePoint <= 0x309F) ||
        // Katakana
        (codePoint >= 0x30A0 && codePoint <= 0x30FF) ||
        // Katakana Phonetic Extensions
        (codePoint >= 0x31F0 && codePoint <= 0x31FF) ||
        // Hangul Syllables
        (codePoint >= 0xAC00 && codePoint <= 0xD7AF) ||
        // Hangul Jamo
        (codePoint >= 0x1100 && codePoint <= 0x11FF) ||
        // Hangul Jamo Extended-A
        (codePoint >= 0xA960 && codePoint <= 0xA97F) ||
        // Hangul Jamo Extended-B
        (codePoint >= 0xD7B0 && codePoint <= 0xD7FF) ||
        // CJK Symbols and Punctuation
        (codePoint >= 0x3000 && codePoint <= 0x303F) ||
        // CJK Compatibility
        (codePoint >= 0x3300 && codePoint <= 0x33FF) ||
        // CJK Compatibility Ideographs
        (codePoint >= 0xF900 && codePoint <= 0xFAFF) ||
        // Fullwidth Forms
        (codePoint >= 0xFF00 && codePoint <= 0xFFEF);
  }
}
