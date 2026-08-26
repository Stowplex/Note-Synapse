// Text normalization for the lexical search index (FTS4).
//
// The index stores NORMALIZED text (see plan §1.2): NFKC + lowercase +
// markdown stripped + CJK runs expanded into overlapping bigrams. Queries
// must be transformed with the exact same rules (buildFtsQuery) so that
// tokens line up with what was indexed.
//
// Known accepted limitation (documented + tested): bigram tokens never cross
// a script boundary, so a substring that straddles CJK and ASCII (e.g. the
// query "文abc" matching inside "中文abc") does not match as one unit — it is
// split into independent AND terms instead. The same applies to the quoted
// form: the phrase query `"文abc"` becomes the normalized token phrase
// "文 abc", which cannot match inside "中文abc" because the index holds the
// bigram 中文 (not a standalone 文 token) at that position.

import 'package:markdown/markdown.dart' as md;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Case/width folding shared by the index and the substring fallback
/// (`matchesSubstringQuery` in lib/utils/note_text_match.dart): NFKC then
/// lowercase, so both paths agree on case and full/half-width handling
/// (plan §1.2 requires saved-filter matching and index matching to agree).
String foldForMatch(String text) => unorm.nfkc(text).toLowerCase();

/// Normalizes raw note/attachment text into the token stream stored in the
/// FTS index: markdown stripped (alt/link text kept), NFKC, lowercased,
/// CJK runs of length >= 2 expanded into space-separated overlapping bigrams
/// (`中文搜索` -> `中文 文搜 搜索`), lone CJK chars kept as unigrams, and any
/// punctuation (including CJK punctuation such as 、。「」《》，！？；：（）)
/// treated as a run breaker.
String normalizeForIndex(String raw) {
  if (raw.trim().isEmpty) return '';
  final plain = stripMarkdown(raw);
  final folded = unorm.nfkc(plain).toLowerCase();
  final tokens = <String>[];
  for (final run in _splitRuns(folded)) {
    if (run.isCjk) {
      tokens.addAll(_cjkGrams(run.text));
    } else {
      tokens.add(run.text);
    }
  }
  return tokens.join(' ');
}

/// Builds an FTS4 MATCH expression from free-form user input.
///
/// - ASCII terms become prefix terms (`term*`) joined by implicit AND.
/// - `"quoted"` input becomes an FTS phrase over normalized tokens.
/// - A CJK run of length >= 2 becomes a phrase of its overlapping bigrams
///   (`"中文 文搜 搜索"`), preserving substring semantics.
/// - A single CJK char becomes a prefix term (`字*`), matching both its
///   unigram and any bigram starting with it.
/// - Embedded double quotes are stripped and bare FTS operators
///   (AND / OR / NOT / NEAR / - / *) are rejected so user input cannot
///   inject FTS syntax.
///
/// Returns an empty string for effectively-empty queries.
String buildFtsQuery(String userQuery) {
  final units = <String>[];

  for (final part in _splitQuotedSegments(userQuery)) {
    if (part.quoted) {
      final tokens = _normalizedQueryTokens(part.text);
      if (tokens.isNotEmpty) {
        units.add('"${tokens.join(' ')}"');
      }
      continue;
    }
    for (final rawTerm in part.text.split(RegExp(r'\s+'))) {
      final term = rawTerm.replaceAll('"', '');
      if (term.isEmpty || _isBareOperator(term)) continue;
      final folded = unorm.nfkc(term).toLowerCase();
      for (final run in _splitRuns(folded)) {
        if (run.isCjk) {
          if (run.text.runes.length == 1) {
            units.add('${run.text}*');
          } else {
            units.add('"${_cjkGrams(run.text).join(' ')}"');
          }
        } else {
          units.add('${run.text}*');
        }
      }
    }
  }

  return units.join(' ');
}

/// Raw (non-bigram) terms of a user query, for Dart-side snippet
/// highlighting against the raw chunk text. Quoted phrases are kept whole,
/// CJK runs are kept whole (so `中文搜索` highlights as one substring), and
/// bare FTS operators are dropped.
List<String> extractHighlightTerms(String userQuery) {
  final terms = <String>[];
  for (final part in _splitQuotedSegments(userQuery)) {
    if (part.quoted) {
      final text = part.text.trim();
      if (text.isNotEmpty) terms.add(text);
      continue;
    }
    for (final rawTerm in part.text.split(RegExp(r'\s+'))) {
      final term = rawTerm.replaceAll('"', '');
      if (term.isEmpty || _isBareOperator(term)) continue;
      for (final run in _splitRuns(term.toLowerCase())) {
        terms.add(run.text);
      }
    }
  }
  return terms;
}

/// Strips markdown syntax, keeping human-readable text: image alt text,
/// link text, code content, table cell text. Falls back to the raw input if
/// parsing fails.
String stripMarkdown(String markdown) {
  if (markdown.isEmpty) return '';
  try {
    final doc = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final nodes = doc.parse(markdown);
    final buffer = StringBuffer();
    _collectText(nodes, buffer);
    return buffer.toString();
  } catch (_) {
    return markdown;
  }
}

/// Inline (phrasing-level) tags: emitting a separator after these would
/// split a word around emphasis/code/link markup (`im**por**tant` must
/// index as `important`, `中文**搜索**引擎` must bigram across the markers).
const _inlineTags = {
  'em',
  'strong',
  'a',
  'code',
  'del',
  'img',
  'ins',
  'sub',
  'sup',
  'span',
  'mark',
};

void _collectText(List<md.Node> nodes, StringBuffer buffer) {
  for (final node in nodes) {
    if (node is md.Text) {
      buffer.write(node.text);
    } else if (node is md.Element) {
      if (node.tag == 'img') {
        final alt = node.attributes['alt'];
        if (alt != null && alt.isNotEmpty) buffer.write(alt);
      } else if (node.children != null) {
        _collectText(node.children!, buffer);
      }
      // Separate blocks/cells so words never fuse across block elements;
      // inline elements must not split the word they sit inside.
      if (!_inlineTags.contains(node.tag)) buffer.write('\n');
    }
  }
}

// ---------------------------------------------------------------------------
// Script runs
// ---------------------------------------------------------------------------

class _Run {
  final String text;
  final bool isCjk;
  const _Run(this.text, this.isCjk);
}

/// Splits normalized text into script-homogeneous runs of word characters.
/// Anything that is neither a word char nor a CJK char (whitespace, ASCII
/// punctuation, CJK punctuation like 、。「」《》) breaks the run.
List<_Run> _splitRuns(String text) {
  final runs = <_Run>[];
  final current = StringBuffer();
  bool? currentIsCjk;

  void flush() {
    if (current.isNotEmpty) {
      runs.add(_Run(current.toString(), currentIsCjk!));
      current.clear();
    }
    currentIsCjk = null;
  }

  for (final rune in text.runes) {
    final bool? isCjk;
    if (_isCjkRune(rune)) {
      isCjk = true;
    } else if (_isWordRune(rune)) {
      isCjk = false;
    } else {
      isCjk = null; // breaker
    }
    if (isCjk == null) {
      flush();
      continue;
    }
    if (currentIsCjk != null && currentIsCjk != isCjk) flush();
    currentIsCjk = isCjk;
    current.writeCharCode(rune);
  }
  flush();
  return runs;
}

/// Overlapping bigrams for a CJK run; a lone char stays a unigram.
List<String> _cjkGrams(String run) {
  final chars = run.runes.toList();
  if (chars.length == 1) return [run];
  final grams = <String>[];
  for (var i = 0; i + 1 < chars.length; i++) {
    grams.add(String.fromCharCodes([chars[i], chars[i + 1]]));
  }
  return grams;
}

/// Han, Hiragana, Katakana, and Hangul ranges (post-NFKC, so halfwidth
/// Katakana and compatibility forms have already been folded).
bool _isCjkRune(int rune) {
  return (rune >= 0x3040 && rune <= 0x309F) || // Hiragana
      (rune >= 0x30A0 && rune <= 0x30FF) || // Katakana
      (rune >= 0x31F0 && rune <= 0x31FF) || // Katakana phonetic extensions
      (rune >= 0x3400 && rune <= 0x4DBF) || // CJK ext A
      (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK unified
      (rune >= 0xF900 && rune <= 0xFAFF) || // CJK compatibility ideographs
      (rune >= 0xAC00 && rune <= 0xD7AF) || // Hangul syllables
      (rune >= 0x1100 && rune <= 0x11FF) || // Hangul jamo
      (rune >= 0x3130 && rune <= 0x318F) || // Hangul compatibility jamo
      (rune >= 0x20000 && rune <= 0x2FA1F); // CJK ext B..F + compat suppl.
}

/// Letters and digits (any script other than the CJK ranges above),
/// plus underscore. Everything else breaks a run.
bool _isWordRune(int rune) {
  if (rune == 0x5F) return true; // underscore
  if (rune < 0x80) {
    return (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A);
  }
  // Non-ASCII, non-CJK: keep letters/digits (e.g. accented Latin, Cyrillic).
  final s = String.fromCharCode(rune);
  return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(s);
}

// ---------------------------------------------------------------------------
// Query parsing helpers
// ---------------------------------------------------------------------------

class _QuerySegment {
  final String text;
  final bool quoted;
  const _QuerySegment(this.text, this.quoted);
}

final _pairedQuoteRe = RegExp(r'"([^"]*)"');

/// Splits user input into quoted and unquoted segments. Only PAIRED double
/// quotes delimit a phrase; a stray unpaired quote is stripped later when
/// terms are processed (so `he"llo` searches as `hello`, and quotes can
/// never leak into the FTS expression unescaped).
List<_QuerySegment> _splitQuotedSegments(String input) {
  final segments = <_QuerySegment>[];
  var last = 0;
  for (final match in _pairedQuoteRe.allMatches(input)) {
    if (match.start > last) {
      segments.add(_QuerySegment(input.substring(last, match.start), false));
    }
    segments.add(_QuerySegment(match.group(1)!, true));
    last = match.end;
  }
  if (last < input.length) {
    segments.add(_QuerySegment(input.substring(last), false));
  }
  return segments;
}

/// Normalized index tokens for the contents of a quoted phrase — the same
/// token stream normalizeForIndex would produce for that contiguous text.
List<String> _normalizedQueryTokens(String text) {
  final folded = unorm.nfkc(text).toLowerCase();
  final tokens = <String>[];
  for (final run in _splitRuns(folded)) {
    if (run.isCjk) {
      tokens.addAll(_cjkGrams(run.text));
    } else {
      tokens.add(run.text);
    }
  }
  return tokens;
}

const _bareOperators = {'AND', 'OR', 'NOT', 'NEAR'};

bool _isBareOperator(String term) {
  if (_bareOperators.contains(term.toUpperCase())) return true;
  // Tokens made purely of FTS syntax chars carry no searchable content.
  return RegExp(r'^[-*()]+$').hasMatch(term);
}
