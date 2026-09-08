/// The expand-selection ladder behind the navigation pad's centre long-press.
///
/// Pure functions over `(text, start, end)` so the whole ladder is testable
/// without a widget. Rides on [MarkdownNavigation] rather than parsing markdown
/// again, so this file is a rung table rather than a second scanner.
///
/// Expanding always yields the *smallest* candidate that strictly contains the
/// current selection, so repeated presses climb one rung at a time without the
/// caller tracking which rung it is on. Shrinking is the caller's job: keep a
/// stack of the selections expand produced and pop it.
library;

import 'markdown_navigation.dart';

/// A half-open `[start, end)` range of UTF-16 offsets in the whole document.
class DocSpan {
  final int start;
  final int end;

  const DocSpan(this.start, this.end);

  int get length => end - start;

  bool get isEmpty => end <= start;

  /// Whether this span covers [other] and is strictly larger than it.
  bool strictlyContains(int otherStart, int otherEnd) {
    if (start > otherStart || end < otherEnd) return false;
    return start < otherStart || end > otherEnd;
  }

  @override
  String toString() => 'DocSpan($start, $end)';

  @override
  bool operator ==(Object other) =>
      other is DocSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

class MarkdownSemanticSelection {
  MarkdownSemanticSelection._();

  /// Symmetric delimiters, longest first so `**` is tried before `*`.
  static const List<String> _symmetric = [
    '```',
    '***',
    '**',
    '__',
    '~~',
    r'$',
    '`',
    '*',
    '_',
    '"',
    "'",
  ];

  /// Bracketing delimiters, matched by depth.
  static const List<(String, String)> _brackets = [
    ('[', ']'),
    ('(', ')'),
    ('{', '}'),
    ('“', '”'), // “ ”
    ('‘', '’'), // ‘ ’
  ];

  static const Set<int> _sentenceEnders = {
    0x2E, // .
    0x21, // !
    0x3F, // ?
    0x3B, // ;
    0x3002, // 。
    0xFF01, // ！
    0xFF1F, // ？
    0xFF1B, // ；
  };

  /// The next span out from `[start, end)`.
  ///
  /// [floor] snaps the ladder to the navigation pad's lit granularity: with
  /// `line` lit the first press selects the line, with `block` lit the block.
  /// Returns `null` once the whole document is already selected.
  static DocSpan? expand(
    String text,
    int start,
    int end, {
    NavGranularity floor = NavGranularity.char,
  }) {
    if (text.isEmpty) return null;
    final s = start.clamp(0, text.length);
    final e = end.clamp(s, text.length);

    final lines = text.split('\n');
    final offsets = _lineOffsets(lines);

    DocSpan? best;
    for (final candidate in _candidates(text, lines, offsets, s, e, floor)) {
      if (candidate == null || candidate.isEmpty) continue;
      if (!candidate.strictlyContains(s, e)) continue;
      if (best == null || candidate.length < best.length) best = candidate;
    }
    return best;
  }

  /// Every rung that could apply, in no particular order — [expand] picks the
  /// smallest that fits, so the rungs do not have to be kept sorted here.
  static Iterable<DocSpan?> _candidates(
    String text,
    List<String> lines,
    List<int> offsets,
    int s,
    int e,
    NavGranularity floor,
  ) sync* {
    final startLine = _lineOf(offsets, s);
    final endLine = _lineOf(offsets, e);

    final wantsInline =
        floor == NavGranularity.char || floor == NavGranularity.token;
    final wantsLine = wantsInline || floor == NavGranularity.line;

    if (wantsInline) {
      yield _tokenSpan(lines, offsets, startLine, s);
      yield* _delimiterSpans(lines, offsets, startLine, s, e);
      yield _sentenceSpan(lines, offsets, startLine, s, e);
    }
    if (wantsLine) {
      yield _lineContentSpan(lines, offsets, startLine, endLine);
      yield _wholeLinesSpan(lines, offsets, startLine, endLine);
    }
    yield _blockSpan(lines, offsets, startLine, endLine);
    yield* _sectionSpans(lines, offsets, startLine, endLine);
    yield DocSpan(0, text.length);
  }

  // ---------------------------------------------------------------------------
  // Rungs
  // ---------------------------------------------------------------------------

  /// Rung 1 — the token under the cursor, at its core extent.
  ///
  /// Navigation deliberately glues a sentence's full stop onto the URL before
  /// it so there is no stop on a lone `.`; selection just as deliberately does
  /// not, so copying the URL does not take the full stop along.
  static DocSpan? _tokenSpan(
    List<String> lines,
    List<int> offsets,
    int lineIndex,
    int s,
  ) {
    final line = lines[lineIndex];
    final base = offsets[lineIndex];
    final span = MarkdownNavigation.tokenSpanAround(line, s - base);
    if (span == null) return null;
    return DocSpan(base + span.start, base + span.coreEnd);
  }

  /// Rung 2 — the innermost delimiter pair around the selection, first its
  /// contents and then the pair including its delimiters, so `**bold**` gives
  /// `bold` before it gives `**bold**`.
  static Iterable<DocSpan> _delimiterSpans(
    List<String> lines,
    List<int> offsets,
    int lineIndex,
    int s,
    int e,
  ) sync* {
    final line = lines[lineIndex];
    final base = offsets[lineIndex];
    final localStart = s - base;
    final localEnd = (e - base).clamp(localStart, line.length);

    for (final marker in _symmetric) {
      final pair = _symmetricPair(line, marker, localStart, localEnd);
      if (pair == null) continue;
      yield DocSpan(base + pair.$1 + marker.length, base + pair.$2);
      yield DocSpan(base + pair.$1, base + pair.$2 + marker.length);
    }
    for (final (open, close) in _brackets) {
      final pair = _bracketPair(line, open, close, localStart, localEnd);
      if (pair == null) continue;
      yield DocSpan(base + pair.$1 + open.length, base + pair.$2);
      yield DocSpan(base + pair.$1, base + pair.$2 + close.length);
    }
  }

  /// Rung 3 — the sentence, bounded by the block so it never runs past a
  /// heading or a list item into unrelated prose.
  static DocSpan? _sentenceSpan(
    List<String> lines,
    List<int> offsets,
    int lineIndex,
    int s,
    int e,
  ) {
    final (blockStart, blockEnd) = MarkdownNavigation.blockRange(
      lines,
      lineIndex,
    );
    final from = offsets[blockStart];
    final to = offsets[blockEnd] + lines[blockEnd].length;
    if (s < from || e > to) return null;

    var start = from;
    for (var i = s - 1; i >= from; i--) {
      if (i >= to) continue;
      if (_endsSentence(lines, offsets, i, to)) {
        start = i + 1;
        break;
      }
    }
    var end = to;
    for (var i = e; i < to; i++) {
      if (_endsSentence(lines, offsets, i, to)) {
        end = i + 1;
        break;
      }
    }
    // Leading whitespace after the previous sentence belongs to neither.
    while (start < end) {
      final unit = _unitAt(lines, offsets, start);
      if (unit == null || !_isSpace(unit)) break;
      start++;
    }
    if (start >= end) return null;
    return DocSpan(start, end);
  }

  /// Whether the offset holds sentence punctuation that actually terminates a
  /// sentence. The full stop in `example.com` does not: requiring whitespace or
  /// end-of-block after it keeps a URL, a decimal and an abbreviation whole.
  static bool _endsSentence(
    List<String> lines,
    List<int> offsets,
    int i,
    int to,
  ) {
    final unit = _unitAt(lines, offsets, i);
    if (unit == null || !_sentenceEnders.contains(unit)) return false;
    // Full-width punctuation is unambiguous — CJK writes no space after 。, so
    // demanding one would leave Chinese with no sentence rung at all.
    if (unit > 0x7F) return true;
    var j = i + 1;
    while (j < to) {
      final next = _unitAt(lines, offsets, j);
      if (next == null) return true; // a line break ends the sentence
      if (_isSpace(next)) return true;
      // `done."` and `Wait?!` still end here.
      if (_isClosingQuote(next) || _sentenceEnders.contains(next)) {
        j++;
        continue;
      }
      return false;
    }
    return true;
  }

  static bool _isClosingQuote(int unit) =>
      unit == 0x22 ||
      unit == 0x27 ||
      unit == 0x29 ||
      unit == 0x5D ||
      unit == 0x201D ||
      unit == 0x2019;

  /// Rung 4 — the line's content without its list, task, quote or heading
  /// marker and without surrounding whitespace. Selecting a bullet's text to
  /// rewrite it should not select the bullet.
  static DocSpan? _lineContentSpan(
    List<String> lines,
    List<int> offsets,
    int startLine,
    int endLine,
  ) {
    if (startLine != endLine) return null;
    final line = lines[startLine];
    final base = offsets[startLine];
    final contentStart = _markerEnd(line);
    var contentEnd = line.length;
    while (contentEnd > contentStart &&
        _isSpace(line.codeUnitAt(contentEnd - 1))) {
      contentEnd--;
    }
    if (contentEnd <= contentStart) return null;
    return DocSpan(base + contentStart, base + contentEnd);
  }

  /// Rung 5 — every line the selection touches, in full.
  static DocSpan _wholeLinesSpan(
    List<String> lines,
    List<int> offsets,
    int startLine,
    int endLine,
  ) {
    return DocSpan(
      offsets[startLine],
      offsets[endLine] + lines[endLine].length,
    );
  }

  /// Rung 6 — the markdown block, from the Phase 1 scanner.
  static DocSpan _blockSpan(
    List<String> lines,
    List<int> offsets,
    int startLine,
    int endLine,
  ) {
    final (firstStart, _) = MarkdownNavigation.blockRange(lines, startLine);
    final (_, lastEnd) = MarkdownNavigation.blockRange(lines, endLine);
    final from = firstStart <= lastEnd ? firstStart : lastEnd;
    final to = lastEnd >= firstStart ? lastEnd : firstStart;
    return DocSpan(offsets[from], offsets[to] + lines[to].length);
  }

  /// Rung 7 — the enclosing sections, innermost first.
  ///
  /// Yields the nearest heading's section, then the section of the nearest
  /// heading above it with a smaller level, and so on out to the document's top
  /// level. Without the outward walk the ladder would jump from a `##` section
  /// straight to the whole document.
  static Iterable<DocSpan> _sectionSpans(
    List<String> lines,
    List<int> offsets,
    int startLine,
    int endLine,
  ) sync* {
    var searchFrom = startLine;
    var maxLevel = 7;
    while (searchFrom >= 0) {
      var headingLine = -1;
      var level = 0;
      for (var i = searchFrom; i >= 0; i--) {
        final depth = _headingLevel(lines[i]);
        if (depth > 0 && depth < maxLevel) {
          headingLine = i;
          level = depth;
          break;
        }
      }
      if (headingLine < 0) return;

      var last = lines.length - 1;
      for (var i = headingLine + 1; i < lines.length; i++) {
        final depth = _headingLevel(lines[i]);
        if (depth > 0 && depth <= level) {
          last = i - 1;
          break;
        }
      }
      while (last > headingLine && lines[last].trim().isEmpty) {
        last--;
      }
      if (last >= endLine) {
        yield DocSpan(offsets[headingLine], offsets[last] + lines[last].length);
      }
      maxLevel = level;
      searchFrom = headingLine - 1;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// The innermost pair of [marker] enclosing `[s, e)`, as `(openIndex,
  /// closeIndex)`. Occurrences are paired left to right, which is how markdown
  /// emphasis reads.
  static (int, int)? _symmetricPair(String line, String marker, int s, int e) {
    final positions = <int>[];
    var i = 0;
    while (i <= line.length - marker.length) {
      if (line.startsWith(marker, i)) {
        // A `*` that is really part of `**` belongs to the longer marker.
        if (marker == '*' || marker == '_') {
          final prev = i > 0 ? line[i - 1] : '';
          final next = i + 1 < line.length ? line[i + 1] : '';
          if (prev == marker || next == marker) {
            i += 1;
            continue;
          }
        }
        // `_` and `'` are word characters to [MarkdownNavigation], so an
        // occurrence with a word on both sides belongs to `snake_case` or
        // `don't` and is not a delimiter. Same flanking rule the repo already
        // uses in `markdown_heading_slug.dart`.
        if ((marker == '_' || marker == "'") && _isIntraWord(line, i)) {
          i += marker.length;
          continue;
        }
        positions.add(i);
        i += marker.length;
      } else {
        i++;
      }
    }
    // CommonMark's flanking rule, for the single-character markers where it
    // matters: an opener is not followed by whitespace, a closer is not
    // preceded by it. Without this, `use *.txt or *.md files` pairs the two
    // globs and expands to `.txt or `.
    if (marker.length == 1 && _flankingMarkers.contains(marker)) {
      var open = -1;
      for (final position in positions) {
        if (open < 0) {
          if (_canOpen(line, position, marker.length)) open = position;
          continue;
        }
        if (!_canClose(line, position)) continue;
        if (open + marker.length <= s && e <= position) return (open, position);
        open = _canOpen(line, position, marker.length) ? position : -1;
      }
      return null;
    }

    for (var p = 0; p + 1 < positions.length; p += 2) {
      final open = positions[p];
      final close = positions[p + 1];
      if (open + marker.length <= s && e <= close) return (open, close);
    }
    return null;
  }

  /// Markers the flanking rule governs. CommonMark's rule is about *emphasis*,
  /// so quotation marks are excluded: applying it to them would drop the pair
  /// in `say " padded quote " ok`, where the spacing is typography rather than
  /// a delimiter run.
  static const Set<String> _flankingMarkers = {'*', '_', '`', r'$'};

  static bool _canOpen(String line, int index, int width) {
    final after = index + width;
    return after < line.length && !_isSpace(line.codeUnitAt(after));
  }

  static bool _canClose(String line, int index) =>
      index > 0 && !_isSpace(line.codeUnitAt(index - 1));

  /// Whether the single-character marker at [index] has word characters on both
  /// sides, which makes it part of a word rather than a delimiter.
  static bool _isIntraWord(String line, int index) {
    if (index == 0 || index + 1 >= line.length) return false;
    return MarkdownNavigation.isWordCharacter(line.codeUnitAt(index - 1)) &&
        MarkdownNavigation.isWordCharacter(line.codeUnitAt(index + 1));
  }

  /// The innermost `open`/`close` pair enclosing `[s, e)`, matched by depth so
  /// nesting works.
  static (int, int)? _bracketPair(
    String line,
    String open,
    String close,
    int s,
    int e,
  ) {
    var depth = 0;
    var openIndex = -1;
    for (var i = s - 1; i >= 0; i--) {
      final ch = line[i];
      if (ch == close) {
        depth++;
      } else if (ch == open) {
        if (depth == 0) {
          openIndex = i;
          break;
        }
        depth--;
      }
    }
    if (openIndex < 0) return null;

    depth = 0;
    for (var i = e; i < line.length; i++) {
      final ch = line[i];
      if (ch == open) {
        depth++;
      } else if (ch == close) {
        if (depth == 0) return (openIndex, i);
        depth--;
      }
    }
    return null;
  }

  /// Where a line's own content begins. Delegates to the scanner so the two
  /// files cannot drift apart on what counts as a marker.
  static int _markerEnd(String line) => MarkdownNavigation.contentStartOf(line);

  static int _headingLevel(String line) {
    var i = 0;
    while (i < line.length &&
        (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09)) {
      i++;
    }
    var hashes = 0;
    while (i + hashes < line.length && line.codeUnitAt(i + hashes) == 0x23) {
      hashes++;
    }
    if (hashes == 0 || hashes > 6) return 0;
    final after = i + hashes;
    if (after >= line.length) return 0;
    final next = line.codeUnitAt(after);
    if (next != 0x20 && next != 0x09) return 0;
    return hashes;
  }

  /// Start offset of every line, so an absolute offset can be turned back into
  /// a line and column.
  static List<int> _lineOffsets(List<String> lines) {
    final offsets = List<int>.filled(lines.length, 0);
    var running = 0;
    for (var i = 0; i < lines.length; i++) {
      offsets[i] = running;
      running += lines[i].length + 1; // + the newline that split() removed
    }
    return offsets;
  }

  static int _lineOf(List<int> offsets, int offset) {
    var low = 0;
    var high = offsets.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (offsets[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// The code unit at an absolute document offset, or null when the offset
  /// lands on the newline that `split` removed.
  static int? _unitAt(List<String> lines, List<int> offsets, int offset) {
    final line = _lineOf(offsets, offset);
    final column = offset - offsets[line];
    if (column < 0 || column >= lines[line].length) return null;
    return lines[line].codeUnitAt(column);
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x3000 || unit == 0xA0;
}

/// The caller-side half of the ladder: what each expand replaced, so a shrink
/// can put it back.
///
/// Lives here rather than inside the pad so it is testable without a widget,
/// which is what the plan asks of the ladder as a whole. Generic over the
/// host's selection type — it only needs `==`.
class SemanticSelectionHistory<T> {
  final List<T> _stack = [];
  T? _expected;
  String? _text;

  bool get isEmpty => _stack.isEmpty;

  int get depth => _stack.length;

  /// Remembers that [previous] was replaced by [result] in [text].
  ///
  /// Callers must record *before* assigning [result] to their controller: a
  /// controller that notifies synchronously would otherwise route straight to
  /// [invalidateIfForeign], see a selection it does not recognise, and discard
  /// the entry that was just pushed.
  void record({required T previous, required T result, required String text}) {
    _stack.add(previous);
    _expected = result;
    _text = text;
  }

  /// The selection one rung in, or null when there is nothing to undo.
  T? shrink({required String text}) {
    if (_stack.isEmpty) return null;
    final previous = _stack.removeLast();
    _expected = previous;
    _text = text;
    return previous;
  }

  /// Drops the history when the document or the selection changed by any route
  /// other than expand or shrink, so a later shrink cannot restore a span from
  /// somewhere the cursor no longer is.
  void invalidateIfForeign({required String text, required T current}) {
    if (_stack.isEmpty) return;
    if (text != _text || current != _expected) clear();
  }

  void clear() {
    _stack.clear();
    _expected = null;
    _text = null;
  }
}
