/// Cursor-motion boundaries for the editor navigation pad.
///
/// This is a hand-written scanner rather than a delegation to `re_editor`'s
/// word motion, which cannot be used: `moveCursorToWordBoundaryForward` raises
/// `RangeError` on ordinary markdown (a trailing space, a hard line break, an
/// all-whitespace line), its `_isAlphanumeric` matches only `[0-9A-Za-z]` so a
/// whole Chinese line counts as one word, and its `extendSelectionToWordBoundary*`
/// pair is named backwards relative to the `moveCursor*` pair.
///
/// Two entry points over one boundary model:
///   * [nextTokenStart] / [previousTokenStart] — within a single line
///   * [nextBlockLine] / [previousBlockLine] / [blockRange] — across line starts
///
/// No markdown AST is built. `MarkdownBlockTracker` is deliberately not used
/// here: it is O(n^2) and measured at 23 ms for 4000 lines, which a 45-120 ms
/// auto-repeat tick cannot absorb.
library;

/// The unit the navigation pad's arrows move by.
enum NavGranularity { char, token, line, block }

/// A half-open `[start, end)` range of UTF-16 offsets within a single line.
class TokenSpan {
  final int start;

  /// Where the token ends as a *navigation stop*, including any closing
  /// punctuation glued on so the cursor never has to stop on a lone full stop.
  final int end;

  /// Where the token ends as a *thing*, before that punctuation was glued on.
  ///
  /// The two differ for `world.` (core `world`) but not for
  /// `[label](url)`, whose closing `)` is part of the link itself. Selection
  /// uses this; blindly stripping trailing punctuation would break the link.
  final int coreEnd;

  const TokenSpan(this.start, this.end, [int? coreEnd])
    : coreEnd = coreEnd ?? end;

  @override
  String toString() => 'TokenSpan($start, $end, core: $coreEnd)';

  @override
  bool operator ==(Object other) =>
      other is TokenSpan &&
      other.start == start &&
      other.end == end &&
      other.coreEnd == coreEnd;

  @override
  int get hashCode => Object.hash(start, end, coreEnd);
}

/// Markdown-aware token and block boundaries.
///
/// A "token" here is not a vim word. Markup that reads as a single thing to a
/// person is a single stop: `**bold**` including its delimiters, a whole
/// `[label](url)`, a bare URL, a `#tag`, a `[[wikilink]]`, and a `- [ ] ` list
/// marker. CJK runs break on script changes and punctuation rather than being
/// swallowed whole.
class MarkdownNavigation {
  MarkdownNavigation._();

  // Composite tokens, in priority order. All are anchored with
  // `matchAsPrefix`, so no `^` is needed and none of them can scan backwards.
  // Declared static so no RegExp is compiled on the auto-repeat path.

  /// `- [ ] `, `* [x] `, `1. [ ] ` — a task marker plus its checkbox.
  static final RegExp _taskMarker = RegExp(
    r'(?:[-*+]|\d+[.)])[ \t]+\[[ xX]\][ \t]*',
  );

  /// `- `, `* `, `+ `, `1. `, `1) ` — a plain list marker.
  static final RegExp _listMarker = RegExp(r'(?:[-*+]|\d+[.)])[ \t]+');

  /// `# ` … `###### ` — a heading marker (needs the trailing space; `#tag`
  /// without one is matched by [_tag] instead).
  static final RegExp _headingMarker = RegExp(r'#{1,6}[ \t]+');

  /// `>`, `>>`, `> ` — blockquote markers, collapsed into one stop.
  static final RegExp _quoteMarker = RegExp(r'>+[ \t]*');

  /// ``` or ~~~ plus any info string.
  static final RegExp _fenceMarker = RegExp(r'(?:`{3,}|~{3,})[^\s]*');

  /// A table row's leading pipe, or a cell separator.
  static final RegExp _tableCell = RegExp(r'\|[ \t]*');

  /// `[label](url)` and `![alt](url)`, including a nested `[]` in the label.
  static final RegExp _link = RegExp(r'!?\[[^\]\n]*\]\([^)\n]*\)');

  /// `[[wikilink]]` and `![[embed]]`.
  static final RegExp _wikiLink = RegExp(r'!?\[\[[^\]\n]*\]\]');

  /// `<https://…>` autolinks.
  static final RegExp _autoLink = RegExp(r'<[a-zA-Z][a-zA-Z0-9+.-]*:[^>\s]*>');

  /// A bare URL. Sentence punctuation after it is glued on as one stop by
  /// [_absorbClosingPunctuation].
  /// Stops on the last character that could genuinely belong to a URL, so the
  /// full stop in `see https://example.com/a.` is not part of the link. The
  /// stop is still glued back on as a navigation stop by
  /// [_absorbClosingPunctuation]; it is the token's *core* that excludes it.
  static final RegExp _bareUrl = RegExp(
    r'(?:https?|ftp|mailto):[^\s<>]*[^\s<>.,;:!?)\]}]',
  );

  /// `**bold**`, `__bold__`, `~~strike~~`, `` `code` ``, `$math$`.
  ///
  /// Both halves carry CommonMark's flanking rule: the opener is not followed
  /// by whitespace and the closer is not preceded by it. Without the second
  /// half, `use *.txt or *.md files` reads as one emphasis span.
  static final RegExp _strongSpan = RegExp(
    r'\*\*(?!\s)[^\n]*?[^\s\n]\*\*|__(?!\s)[^\n]*?[^\s\n]__'
    r'|~~(?!\s)[^\n]*?[^\s\n]~~|`+[^`\n]+`+|\$[^$\n]+\$',
  );

  /// `*italic*`, `_italic_` — single-delimiter emphasis.
  static final RegExp _emphasisSpan = RegExp(
    r'\*(?!\s)[^*\n]*[^*\s\n]\*|_(?!\s)[^_\n]*[^_\s\n]_',
  );

  /// `#tag`, `#tag/sub`, `@mention`.
  ///
  /// The letter ranges are enumerated rather than written as one broad span:
  /// `À-￿` would reach past the letters into CJK *punctuation*, so a
  /// Chinese tag would swallow the rest of the line and undo the whole point of
  /// clause-sized stops.
  static final RegExp _tag = RegExp(r'[#@][\w/À-ÿ぀-ヿ一-鿿가-힯-]+');

  /// Structural markers, tried only at the start of a line's content.
  static final List<RegExp> _lineMarkers = [
    _taskMarker,
    _listMarker,
    _headingMarker,
    _quoteMarker,
    _fenceMarker,
  ];

  /// Inline composites, tried anywhere. Order matters: `_wikiLink` before
  /// `_link` so `[[x]]` is not read as an empty link, and `_strongSpan` before
  /// `_emphasisSpan` so `**x**` is not read as `*` + `*x*`.
  static final List<RegExp> _inlinePatterns = [
    _wikiLink,
    _link,
    _autoLink,
    _bareUrl,
    _strongSpan,
    _emphasisSpan,
    _tag,
    _tableCell,
  ];

  /// Punctuation that *closes* something. It is glued onto the token it
  /// follows, so `Hello, world.` is two stops rather than four and a URL does
  /// not leave a lone full stop behind. Openers (`(`, `[`, `"`, `**`) are
  /// deliberately excluded: landing just after one is where you want to be to
  /// type inside it, and gluing `**` would swallow an emphasis delimiter.
  static const Set<int> _terminalPunctuation = {
    0x2E, // .
    0x2C, // ,
    0x3B, // ;
    0x3A, // :
    0x21, // !
    0x3F, // ?
    0x29, // )
    0x5D, // ]
    0x7D, // }
  };

  /// A run of standalone `-`, `=`, `*` or `_` that forms a horizontal rule.
  static final RegExp _rule = RegExp(r'(?:-{3,}|\*{3,}|_{3,}|={3,})[ \t]*$');

  /// Front-matter delimiter.
  static final RegExp _frontMatter = RegExp(r'---[ \t]*$');

  // ---------------------------------------------------------------------------
  // Token stepping (within one line)
  // ---------------------------------------------------------------------------

  /// The start offset of the first token that begins strictly after [offset],
  /// or `null` when the rest of the line holds no further token.
  ///
  /// Forward motion lands on a token *start* (vim `w`) rather than a token end,
  /// so that pressing forward then backward is symmetric.
  static int? nextTokenStart(String line, int offset) {
    if (offset >= line.length) return null;
    var cursor = 0;
    while (cursor < line.length) {
      final span = _tokenSpanAt(line, cursor);
      if (span == null) return null;
      if (span.start > offset) return span.start;
      // Guard against a zero-width match wedging the scan.
      cursor = span.end > cursor ? span.end : cursor + 1;
    }
    return null;
  }

  /// The start offset of the last token that begins strictly before [offset],
  /// or `null` when [offset] is at or before the first token on the line.
  static int? previousTokenStart(String line, int offset) {
    if (offset <= 0) return null;
    int? best;
    var cursor = 0;
    while (cursor < line.length) {
      final span = _tokenSpanAt(line, cursor);
      if (span == null) break;
      if (span.start >= offset) break;
      best = span.start;
      cursor = span.end > cursor ? span.end : cursor + 1;
    }
    return best;
  }

  /// The span of the token containing [offset], or the one starting at it.
  ///
  /// Used by the expand-selection ladder for its innermost rung. Returns `null`
  /// when [offset] sits in whitespace with no token under it.
  static TokenSpan? tokenSpanAround(String line, int offset) {
    var cursor = 0;
    while (cursor < line.length) {
      final span = _tokenSpanAt(line, cursor);
      if (span == null) return null;
      if (offset >= span.start && offset <= span.end) {
        // A cursor exactly on a boundary belongs to the token it opens, unless
        // it only closes one and another starts right there.
        if (offset == span.end && offset < line.length) {
          final next = _tokenSpanAt(line, offset);
          if (next != null && next.start == offset) return next;
        }
        return span;
      }
      if (span.start > offset) return null;
      cursor = span.end > cursor ? span.end : cursor + 1;
    }
    return null;
  }

  /// Skips whitespace from [from], then matches the longest token that starts
  /// there. Returns `null` at end of line.
  static TokenSpan? _tokenSpanAt(String line, int from) {
    var i = from;
    while (i < line.length && _isWhitespace(line.codeUnitAt(i))) {
      i++;
    }
    if (i >= line.length) return null;

    // Line-leading structural markers only count as one token when nothing but
    // whitespace precedes them; `1. ` mid-sentence is ordinary text.
    if (_isBlankBefore(line, i)) {
      for (final marker in _lineMarkers) {
        final m = marker.matchAsPrefix(line, i);
        if (m != null && m.end > i) return TokenSpan(i, m.end);
      }
      final rule =
          _rule.matchAsPrefix(line, i) ?? _frontMatter.matchAsPrefix(line, i);
      if (rule != null && rule.end > i) return TokenSpan(i, rule.end);
    }

    for (final pattern in _inlinePatterns) {
      final m = pattern.matchAsPrefix(line, i);
      if (m != null && m.end > i) {
        return TokenSpan(i, _absorbClosingPunctuation(line, m.end), m.end);
      }
    }

    final core = _runEnd(line, i);
    return TokenSpan(i, _absorbClosingPunctuation(line, core), core);
  }

  static bool _isClosingPunctuation(int rune) =>
      _terminalPunctuation.contains(rune) || _isCjkPunctuation(rune);

  /// Glues closing punctuation onto the token it terminates.
  ///
  /// Applied to every token kind, so a bare URL keeps the full stop that ends
  /// the sentence rather than leaving it as a stop of its own, and a Chinese
  /// clause keeps its `，`. Without this, punctuation-dense text degenerates to
  /// roughly one stop per character — the exact failure measured in re_editor.
  static int _absorbClosingPunctuation(String line, int end) {
    var i = end;
    while (i < line.length) {
      final rune = _runeAt(line, i);
      if (!_isClosingPunctuation(rune)) break;
      i += _runeWidth(line, i);
    }
    return i;
  }

  static bool _isCjkPunctuation(int r) {
    return (r >= 0x3001 && r <= 0x303F) || // 、。〈〉《》「」
        (r >= 0xFF01 && r <= 0xFF0F) || // ！＂＃＄％＆＇（）＊＋，－．／
        (r >= 0xFF1A && r <= 0xFF20) || // ：；＜＝＞？＠
        (r >= 0xFF3B && r <= 0xFF40) ||
        (r >= 0xFF5B && r <= 0xFF65) ||
        (r >= 0x2018 && r <= 0x201F); // curly quotes
  }

  /// The end of the plain run starting at [start]: a word run, a CJK run, or a
  /// punctuation/symbol run. Runs never mix classes, so `abc,,,def` is three
  /// tokens and `foo_bar` is one.
  ///
  /// A CJK run stops at punctuation, which — once
  /// [_absorbClosingPunctuation] glues that punctuation back on — gives
  /// clause-sized stops, the middle granularity Chinese text otherwise has no
  /// access to since it has no spaces for a word rule to key on.
  static int _runEnd(String line, int start) {
    final first = _runeAt(line, start);
    // An apostrophe is a word character only *between* letters. Leading, it
    // opens a quotation: `'hello there'` must not begin one token `'hello`, or
    // the quote pair becomes unreachable to the selection ladder.
    final cls = _isApostrophe(first) ? _CharClass.symbol : _classOf(first);
    var i = start + _runeWidth(line, start);
    while (i < line.length) {
      final rune = _runeAt(line, i);
      if (_classOf(rune) != cls) break;
      if (cls == _CharClass.word && _isApostrophe(rune)) {
        // `don't` is one token; `there'` ends before the closing quote.
        final width = _runeWidth(line, i);
        if (i + width >= line.length) break;
        final next = _runeAt(line, i + width);
        if (_isApostrophe(next) || _classOf(next) != _CharClass.word) break;
      }
      i += _runeWidth(line, i);
    }
    return i;
  }

  static bool _isApostrophe(int rune) => rune == 0x27 || rune == 0x2019;

  static bool _isBlankBefore(String line, int index) {
    for (var i = 0; i < index; i++) {
      if (!_isWhitespace(line.codeUnitAt(i))) return false;
    }
    return true;
  }

  /// Where a line's own content begins: past its indentation and past any
  /// list, task, heading or quote marker.
  ///
  /// Shared with the expand-selection ladder, which used to carry its own
  /// verbatim copies of these four patterns.
  static int contentStartOf(String line) {
    var i = 0;
    while (i < line.length && _isWhitespace(line.codeUnitAt(i))) {
      i++;
    }
    for (final marker in _lineMarkers) {
      if (identical(marker, _fenceMarker)) continue;
      final m = marker.matchAsPrefix(line, i);
      if (m != null && m.end > i) return m.end;
    }
    return i;
  }

  /// Whether [rune] counts as part of a word. Exposed because the expand
  /// ladder must agree with it: `_` and `'` are word characters here, so they
  /// cannot also be treated as emphasis delimiters inside a word.
  static bool isWordCharacter(int rune) => _isWordRune(rune);

  // ---------------------------------------------------------------------------
  // Block stepping (across lines)
  // ---------------------------------------------------------------------------

  /// The index of the nearest block-start line strictly before [fromLine], or
  /// `null` when [fromLine] is at or before the first block.
  static int? previousBlockLine(List<String> lines, int fromLine) {
    int? best;
    _forEachBlockStart(lines, (index) {
      if (index >= fromLine) return false;
      best = index;
      return true;
    });
    return best;
  }

  /// The index of the nearest block-start line strictly after [fromLine], or
  /// `null` when no block follows.
  static int? nextBlockLine(List<String> lines, int fromLine) {
    int? found;
    _forEachBlockStart(lines, (index) {
      if (index <= fromLine) return true;
      found = index;
      return false;
    });
    return found;
  }

  /// The inclusive line range of the block containing [lineIndex].
  ///
  /// Trailing blank lines belong to no block and are excluded, so selecting a
  /// paragraph does not drag the gap after it along.
  static (int, int) blockRange(List<String> lines, int lineIndex) {
    if (lines.isEmpty) return (0, 0);
    final clamped = lineIndex.clamp(0, lines.length - 1);

    var start = 0;
    int? nextStart;
    // One walk yields both bounds; calling nextBlockLine here would restart the
    // scan from line 0 and double the cost of every auto-repeat tick.
    _forEachBlockStart(lines, (index) {
      if (index <= clamped) {
        start = index;
        return true;
      }
      nextStart = index;
      return false;
    });

    var end = (nextStart ?? lines.length) - 1;
    while (end > start && lines[end].trim().isEmpty) {
      end--;
    }
    return (start, end.clamp(start, lines.length - 1));
  }

  /// Walks block-start line indices in order, stopping when [visit] returns
  /// false. Fence state is tracked so lines inside a code block never register
  /// as block starts.
  static void _forEachBlockStart(List<String> lines, bool Function(int) visit) {
    var inFence = false;
    String? fenceMarker;
    var previousBlank = true;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      final isBlank = trimmed.isEmpty;

      if (inFence) {
        if (fenceMarker != null && trimmed.startsWith(fenceMarker)) {
          inFence = false;
          fenceMarker = null;
          // The fence was a complete block, so the next line opens a new one
          // even with no blank line between them.
          previousBlank = true;
        } else {
          previousBlank = false;
        }
        continue;
      }

      final fenceOpen = _fenceOpener(trimmed);
      if (fenceOpen != null) {
        if (!visit(i)) return;
        inFence = true;
        fenceMarker = fenceOpen;
        previousBlank = false;
        continue;
      }

      if (isBlank) {
        previousBlank = true;
        continue;
      }

      if (previousBlank || _isStructuralStart(trimmed)) {
        if (!visit(i)) return;
      }
      // A heading or a rule is a one-line block, so the text under it is a
      // separate block and should be its own stop.
      previousBlank = _isSingleLineBlock(trimmed);
    }
  }

  /// Blocks that are complete in one line, so the following line starts a new
  /// block whether or not a blank line separates them.
  static bool _isSingleLineBlock(String trimmed) {
    return _headingMarker.matchAsPrefix(trimmed) != null ||
        _rule.matchAsPrefix(trimmed) != null ||
        _frontMatter.matchAsPrefix(trimmed) != null;
  }

  static String? _fenceOpener(String trimmed) {
    if (trimmed.startsWith('```')) return '```';
    if (trimmed.startsWith('~~~')) return '~~~';
    return null;
  }

  /// Whether a non-blank line opens a block on its own, without needing a blank
  /// line before it: headings, list and task items, quotes, tables and rules.
  static bool _isStructuralStart(String trimmed) {
    if (_headingMarker.matchAsPrefix(trimmed) != null) return true;
    if (_taskMarker.matchAsPrefix(trimmed) != null) return true;
    if (_listMarker.matchAsPrefix(trimmed) != null) return true;
    if (trimmed.startsWith('>')) return true;
    if (trimmed.startsWith('|')) return true;
    if (_rule.matchAsPrefix(trimmed) != null) return true;
    return false;
  }

  // ---------------------------------------------------------------------------
  // Character classification
  // ---------------------------------------------------------------------------

  static bool _isWhitespace(int unit) {
    switch (unit) {
      case 0x09:
      case 0x0A:
      case 0x0B:
      case 0x0C:
      case 0x0D:
      case 0x20:
      case 0xA0:
      case 0x1680:
      case 0x2028:
      case 0x2029:
      case 0x202F:
      case 0x205F:
      case 0x3000:
        return true;
      default:
        return unit >= 0x2000 && unit <= 0x200A;
    }
  }

  /// The full code point at [index], combining a surrogate pair so astral
  /// characters (emoji, CJK extension B) are never split.
  static int _runeAt(String s, int index) {
    final unit = s.codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < s.length) {
      final low = s.codeUnitAt(index + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
      }
    }
    return unit;
  }

  static int _runeWidth(String s, int index) {
    final unit = s.codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < s.length) {
      final low = s.codeUnitAt(index + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) return 2;
    }
    return 1;
  }

  static _CharClass _classOf(int rune) {
    if (_isCjk(rune)) return _CharClass.cjk;
    if (_isWordRune(rune)) return _CharClass.word;
    return _CharClass.symbol;
  }

  static bool _isCjk(int r) {
    return (r >= 0x3040 && r <= 0x30FF) || // Hiragana, Katakana
        (r >= 0x3400 && r <= 0x4DBF) || // CJK ext A
        (r >= 0x4E00 && r <= 0x9FFF) || // CJK unified
        (r >= 0xF900 && r <= 0xFAFF) || // CJK compatibility
        (r >= 0xAC00 && r <= 0xD7AF) || // Hangul syllables
        (r >= 0x1100 && r <= 0x11FF) || // Hangul Jamo
        (r >= 0x20000 && r <= 0x2FA1F); // CJK ext B+
  }

  /// Letters, digits, and the connectors that hold an identifier together.
  /// `foo_bar` is deliberately one token; `a.b` is deliberately three.
  static bool _isWordRune(int r) {
    if (r >= 0x30 && r <= 0x39) return true; // 0-9
    if (r >= 0x41 && r <= 0x5A) return true; // A-Z
    if (r >= 0x61 && r <= 0x7A) return true; // a-z
    if (r == 0x5F) return true; // _
    if (r == 0x27 || r == 0x2019) return true; // ' and ’ inside contractions
    if (r < 0x80) return false;
    if (r >= 0xC0 && r <= 0x24F && r != 0xD7 && r != 0xF7) return true; // Latin
    if (r >= 0x370 && r <= 0x3FF) return true; // Greek
    if (r >= 0x400 && r <= 0x52F) return true; // Cyrillic
    if (r >= 0x590 && r <= 0x6FF) return true; // Hebrew, Arabic
    if (r >= 0x900 && r <= 0x0DFF) return true; // Indic
    if (r >= 0x0E00 && r <= 0x0E7F) return true; // Thai
    if (r >= 0xFF10 && r <= 0xFF19) return true; // fullwidth digits
    if (r >= 0xFF21 && r <= 0xFF3A) return true; // fullwidth A-Z
    if (r >= 0xFF41 && r <= 0xFF5A) return true; // fullwidth a-z
    return false;
  }
}

enum _CharClass { word, cjk, symbol }
