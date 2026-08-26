// BM25 ranking over FTS4 matchinfo('pcnalx') blobs, plus a Dart-side
// snippet/highlight helper (plan §1.4).
//
// FTS4's snippet() would surface the bigram-mangled normalized text, so
// snippets are computed here from the RAW chunk text using the user's raw
// query terms.

import 'dart:math' as math;
import 'dart:typed_data';

/// Decoded matchinfo('pcnalx') blob for one matched row.
///
/// Layout (32-bit unsigned ints, machine byte order — little-endian on all
/// supported platforms):
///   p                    number of matchable phrases in the query
///   c                    number of columns
///   n                    total rows in the FTS table
///   a[c]                 average tokens per column, across all rows
///   l[c]                 tokens per column, this row
///   x[3 * p * c]         per (phrase, column): [hitsThisRow, hitsAllRows,
///                        docsWithHits], phrase-major order
class MatchinfoStats {
  final int phraseCount;
  final int columnCount;
  final int rowCount;
  final List<int> avgTokens;
  final List<int> rowTokens;
  final List<int> _x;

  MatchinfoStats({
    required this.phraseCount,
    required this.columnCount,
    required this.rowCount,
    required this.avgTokens,
    required this.rowTokens,
    required List<int> x,
  }) : _x = x;

  int _xAt(int phrase, int column, int field) =>
      _x[3 * (phrase * columnCount + column) + field];

  /// Term frequency of [phrase] in [column] of this row.
  int hitsThisRow(int phrase, int column) => _xAt(phrase, column, 0);

  /// Total hits of [phrase] in [column] across all rows.
  int hitsAllRows(int phrase, int column) => _xAt(phrase, column, 1);

  /// Number of rows whose [column] contains [phrase] at least once.
  int docsWithHits(int phrase, int column) => _xAt(phrase, column, 2);
}

/// Decodes a matchinfo('pcnalx') blob.
///
/// The bytes are copied into a freshly allocated buffer before being read as
/// 32-bit ints: sqflite result blobs are not guaranteed to be 4-byte aligned
/// within their underlying buffer, and an unaligned typed-data view throws.
MatchinfoStats decodeMatchinfo(Uint8List blob) {
  if (blob.length < 12 || blob.length % 4 != 0) {
    throw FormatException('matchinfo blob has invalid length ${blob.length}');
  }
  // Copy: guarantees byteOffset 0 in a fresh, aligned buffer.
  final aligned = Uint8List.fromList(blob);
  final data = ByteData.sublistView(aligned);
  final wordCount = aligned.length ~/ 4;
  int word(int i) => data.getUint32(i * 4, Endian.little);

  final p = word(0);
  final c = word(1);
  final n = word(2);
  final expected = 3 + 2 * c + 3 * p * c;
  if (wordCount != expected) {
    throw FormatException(
      'matchinfo blob has $wordCount words, expected $expected '
      '(p=$p, c=$c)',
    );
  }
  final a = List<int>.generate(c, (i) => word(3 + i));
  final l = List<int>.generate(c, (i) => word(3 + c + i));
  final x = List<int>.generate(3 * p * c, (i) => word(3 + 2 * c + i));
  return MatchinfoStats(
    phraseCount: p,
    columnCount: c,
    rowCount: n,
    avgTokens: a,
    rowTokens: l,
    x: x,
  );
}

/// Okapi BM25 score for the row described by [blob], summed over all
/// phrases and columns. Higher is better. k1/b defaults follow plan §1.4.
double bm25FromMatchinfo(Uint8List blob, {double k1 = 1.2, double b = 0.75}) {
  return bm25FromStats(decodeMatchinfo(blob), k1: k1, b: b);
}

/// BM25 over an already-decoded [MatchinfoStats].
double bm25FromStats(MatchinfoStats stats, {double k1 = 1.2, double b = 0.75}) {
  final n = stats.rowCount;
  var score = 0.0;
  for (var phrase = 0; phrase < stats.phraseCount; phrase++) {
    for (var column = 0; column < stats.columnCount; column++) {
      final tf = stats.hitsThisRow(phrase, column);
      if (tf == 0) continue;
      final docs = stats.docsWithHits(phrase, column);
      if (docs == 0 || n == 0) continue;
      // Lucene-style BM25 idf: log(1 + ...) is always positive, so a very
      // common term still ranks the rows that contain it instead of
      // scoring everything 0.0 in small corpora.
      final idf = math.log(1 + (n - docs + 0.5) / (docs + 0.5));
      final docLen = stats.rowTokens[column];
      final avgLen = stats.avgTokens[column];
      final lenNorm = avgLen > 0 ? docLen / avgLen : 1.0;
      score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * lenNorm));
    }
  }
  return score;
}

// ---------------------------------------------------------------------------
// Snippets / highlighting
// ---------------------------------------------------------------------------

/// A half-open [start, end) character range within [Snippet.text].
class SnippetMatch {
  final int start;
  final int end;
  const SnippetMatch(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is SnippetMatch && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SnippetMatch($start, $end)';
}

/// A display snippet extracted from raw chunk text, with highlight ranges.
class Snippet {
  final String text;
  final List<SnippetMatch> matches;

  /// Whether text was cut before/after the window (caller renders "…").
  final bool truncatedStart;
  final bool truncatedEnd;

  const Snippet({
    required this.text,
    required this.matches,
    required this.truncatedStart,
    required this.truncatedEnd,
  });
}

/// Builds a snippet window (~[maxLength] chars) around the densest cluster
/// of [terms] matches in [rawText], with match ranges for UI highlighting.
///
/// [terms] are the user's RAW query terms (from `extractHighlightTerms`),
/// not bigram-normalized tokens — CJK terms are located as direct substrings
/// of the raw text. Matching is case-insensitive. When no term matches, the
/// head of the text is returned with no highlights.
Snippet buildSnippet(
  String rawText,
  List<String> terms, {
  int maxLength = 160,
}) {
  final haystack = rawText.toLowerCase();
  final hits = <SnippetMatch>[];
  for (final term in terms) {
    var needle = term.toLowerCase();
    var searchIn = haystack;
    if (needle.isEmpty) continue;
    if (needle.length != term.length) {
      // Rare: lowercasing changed the length (e.g. İ). Offsets into the
      // lowercased haystack would drift, so match case-sensitively instead.
      needle = term;
      searchIn = rawText;
    }
    var from = 0;
    while (true) {
      final at = searchIn.indexOf(needle, from);
      if (at < 0) break;
      hits.add(SnippetMatch(at, at + needle.length));
      from = at + 1;
    }
  }
  hits.sort((a, b) => a.start.compareTo(b.start));

  if (rawText.length <= maxLength) {
    return Snippet(
      text: rawText,
      matches: _mergeOverlaps(hits),
      truncatedStart: false,
      truncatedEnd: false,
    );
  }

  // Choose the window start that covers the most matches: anchor candidate
  // windows at each hit, slightly padded so the first match isn't flush
  // against the window edge.
  var windowStart = 0;
  if (hits.isNotEmpty) {
    var bestCount = -1;
    for (final anchor in hits) {
      final start = math.max(0, anchor.start - maxLength ~/ 4);
      final end = start + maxLength;
      final count = hits.where((h) => h.start >= start && h.end <= end).length;
      if (count > bestCount) {
        bestCount = count;
        windowStart = start;
      }
    }
  }
  if (windowStart + maxLength > rawText.length) {
    windowStart = math.max(0, rawText.length - maxLength);
  }
  // Never start the window between the halves of a surrogate pair (astral
  // chars are two UTF-16 code units): back off onto the high surrogate.
  if (windowStart > 0 && _isLowSurrogate(rawText.codeUnitAt(windowStart))) {
    windowStart--;
  }
  var windowEnd = math.min(rawText.length, windowStart + maxLength);
  // Same at the end: if the window would cut before a low surrogate, back
  // off so the dangling high surrogate is excluded too.
  if (windowEnd < rawText.length &&
      _isLowSurrogate(rawText.codeUnitAt(windowEnd))) {
    windowEnd--;
  }

  final visible = _mergeOverlaps(
    hits
        .where((h) => h.start >= windowStart && h.end <= windowEnd)
        .map((h) => SnippetMatch(h.start - windowStart, h.end - windowStart))
        .toList(),
  );
  return Snippet(
    text: rawText.substring(windowStart, windowEnd),
    matches: visible,
    truncatedStart: windowStart > 0,
    truncatedEnd: windowEnd < rawText.length,
  );
}

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

List<SnippetMatch> _mergeOverlaps(List<SnippetMatch> sorted) {
  if (sorted.length <= 1) return sorted;
  final merged = <SnippetMatch>[sorted.first];
  for (final match in sorted.skip(1)) {
    final last = merged.last;
    if (match.start <= last.end) {
      if (match.end > last.end) {
        merged[merged.length - 1] = SnippetMatch(last.start, match.end);
      }
    } else {
      merged.add(match);
    }
  }
  return merged;
}
