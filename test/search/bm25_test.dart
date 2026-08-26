import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/search/bm25.dart';

/// Builds a matchinfo('pcnalx') blob from 32-bit words (little-endian),
/// exactly as sqlite lays it out.
Uint8List matchinfoBlob(List<int> words) {
  final data = ByteData(words.length * 4);
  for (var i = 0; i < words.length; i++) {
    data.setUint32(i * 4, words[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('decodeMatchinfo', () {
    test('decodes a single-phrase single-column blob', () {
      // p=1, c=1, n=10, a=[10], l=[8], x=[tf=2, allHits=5, docs=2]
      final stats = decodeMatchinfo(matchinfoBlob([1, 1, 10, 10, 8, 2, 5, 2]));
      expect(stats.phraseCount, 1);
      expect(stats.columnCount, 1);
      expect(stats.rowCount, 10);
      expect(stats.avgTokens, [10]);
      expect(stats.rowTokens, [8]);
      expect(stats.hitsThisRow(0, 0), 2);
      expect(stats.hitsAllRows(0, 0), 5);
      expect(stats.docsWithHits(0, 0), 2);
    });

    test('decodes multi-phrase multi-column x in phrase-major order', () {
      // p=2, c=2, n=4, a=[5,20], l=[6,18],
      // x: p0c0=[1,3,2] p0c1=[0,4,3] p1c0=[2,2,1] p1c1=[1,1,1]
      final stats = decodeMatchinfo(
        matchinfoBlob([
          2,
          2,
          4,
          5,
          20,
          6,
          18,
          1,
          3,
          2,
          0,
          4,
          3,
          2,
          2,
          1,
          1,
          1,
          1,
        ]),
      );
      expect(stats.hitsThisRow(0, 0), 1);
      expect(stats.hitsThisRow(0, 1), 0);
      expect(stats.hitsThisRow(1, 0), 2);
      expect(stats.hitsThisRow(1, 1), 1);
      expect(stats.docsWithHits(0, 1), 3);
      expect(stats.docsWithHits(1, 0), 1);
    });

    test('rejects malformed blobs', () {
      expect(
        () => decodeMatchinfo(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      // Word count inconsistent with p/c header.
      expect(
        () => decodeMatchinfo(matchinfoBlob([1, 1, 10, 10, 8, 2, 5])),
        throwsFormatException,
      );
    });
  });

  group('bm25FromMatchinfo', () {
    test('matches hand-computed BM25 for one phrase, one column', () {
      // Corpus: N=10 docs, avg column length 10 tokens. This row: 8 tokens,
      // phrase occurs tf=2 times, and 2 docs contain the phrase.
      final blob = matchinfoBlob([1, 1, 10, 10, 8, 2, 5, 2]);

      // Manual arithmetic (k1=1.2, b=0.75, Lucene-style idf):
      //   idf    = ln(1 + (10 - 2 + 0.5) / (2 + 0.5)) = ln(1 + 3.4) = ln(4.4)
      //          = 1.481605
      //   denom  = 2 + 1.2 * (1 - 0.75 + 0.75 * 8/10) = 3.02
      //   score  = 1.481605 * (2 * 2.2) / 3.02 = 1.481605 * 1.456954
      //          = 2.158629
      final expected = math.log(4.4) * 4.4 / 3.02;
      expect(expected, closeTo(2.158629, 1e-4)); // pinned literal
      expect(bm25FromMatchinfo(blob), closeTo(expected, 1e-9));
    });

    test('sums across phrases and columns, hand-computed', () {
      final blob = matchinfoBlob([
        2,
        2,
        4,
        5,
        20,
        6,
        18,
        1,
        3,
        2,
        0,
        4,
        3,
        2,
        2,
        1,
        1,
        1,
        1,
      ]);
      // Lucene-style idf = ln(1 + (n - docs + 0.5)/(docs + 0.5)), N=4:
      // p0c0: docs=2 -> idf = ln(1 + 2.5/2.5) = ln 2 = 0.693147;
      //       tf=1, l=6, a=5: denom = 1 + 1.2*(0.25 + 0.75*1.2) = 2.38;
      //       num = 2.2 -> 0.693147 * 2.2/2.38 = 0.640724
      // p0c1: tf=0 -> skipped.
      // p1c0: docs=1 -> idf = ln(1 + 3.5/1.5) = ln(10/3) = 1.203973;
      //       tf=2, l=6, a=5: denom = 2 + 1.2*(0.25 + 0.75*1.2) = 3.38;
      //       num = 4.4 -> 1.203973 * 4.4/3.38 = 1.567302
      // p1c1: docs=1 -> idf = ln(10/3); tf=1, l=18, a=20:
      //       denom = 1 + 1.2*(0.25 + 0.75*0.9) = 2.11;
      //       num = 2.2 -> 1.203973 * 2.2/2.11 = 1.255327
      // total = 0.640724 + 1.567302 + 1.255327 = 3.463353
      final expected =
          math.log(2) * 2.2 / 2.38 +
          math.log(10 / 3) * 4.4 / 3.38 +
          math.log(10 / 3) * 2.2 / 2.11;
      expect(expected, closeTo(3.463353, 1e-4)); // pinned literal
      expect(bm25FromMatchinfo(blob), closeTo(expected, 1e-9));
    });

    test('very common phrase still scores positive (Lucene-style idf)', () {
      // With the classic idf this row scored 0.0 (docs=9 of N=10 gives
      // ln(1.5/9.5) < 0, clamped); the Lucene form stays positive so common
      // terms still rank in small corpora. Manual arithmetic:
      //   idf   = ln(1 + 1.5/9.5) = ln(1.157895) = 0.146603
      //   tf=3, l=10, a=10 -> denom = 3 + 1.2*(0.25 + 0.75) = 4.2
      //   num   = 3 * 2.2 = 6.6
      //   score = 0.146603 * 6.6/4.2 = 0.230377
      final blob = matchinfoBlob([1, 1, 10, 10, 10, 3, 30, 9]);
      final score = bm25FromMatchinfo(blob);
      expect(score, greaterThan(0.0));
      expect(score, closeTo(math.log(1 + 1.5 / 9.5) * 6.6 / 4.2, 1e-9));
      expect(score, closeTo(0.230377, 1e-4)); // pinned literal
    });

    test(
      'zero-guards: empty table and zero-length rows do not divide by 0',
      () {
        expect(bm25FromMatchinfo(matchinfoBlob([1, 1, 0, 0, 0, 0, 0, 0])), 0.0);
        // avg length 0 with a hit: falls back to lenNorm 1.0, stays finite.
        final blob = matchinfoBlob([1, 1, 10, 0, 0, 1, 1, 1]);
        expect(bm25FromMatchinfo(blob).isFinite, isTrue);
      },
    );

    test('decodes correctly from an unaligned buffer view', () {
      final words = [1, 1, 10, 10, 8, 2, 5, 2];
      final aligned = matchinfoBlob(words);

      // Place the blob at byte offset 1 inside a larger buffer: a direct
      // Uint32List view over it would throw, which is exactly why the
      // decoder copies first.
      final backing = Uint8List(aligned.length + 1);
      backing.setRange(1, backing.length, aligned);
      final unaligned = Uint8List.view(backing.buffer, 1, aligned.length);
      expect(unaligned.offsetInBytes % 4, isNot(0));
      expect(
        () => Uint32List.view(
          unaligned.buffer,
          unaligned.offsetInBytes,
          words.length,
        ),
        throwsA(anything),
      );

      expect(
        bm25FromMatchinfo(unaligned),
        closeTo(bm25FromMatchinfo(aligned), 1e-12),
      );
    });
  });

  group('buildSnippet', () {
    test('short text is returned whole with highlight ranges', () {
      final snippet = buildSnippet('The quick brown fox', ['quick', 'fox']);
      expect(snippet.text, 'The quick brown fox');
      expect(snippet.truncatedStart, isFalse);
      expect(snippet.truncatedEnd, isFalse);
      expect(snippet.matches, [
        const SnippetMatch(4, 9),
        const SnippetMatch(16, 19),
      ]);
    });

    test('matching is case-insensitive', () {
      final snippet = buildSnippet('Flutter Rocks', ['flutter']);
      expect(snippet.matches, [const SnippetMatch(0, 7)]);
    });

    test('window centers on the match in long ASCII text', () {
      final filler = 'lorem ipsum dolor sit amet ' * 30; // 810 chars
      final text = '${filler}NEEDLE found here $filler';
      final snippet = buildSnippet(text, ['needle'], maxLength: 100);
      expect(snippet.text.length, 100);
      expect(snippet.text, contains('NEEDLE'));
      expect(snippet.truncatedStart, isTrue);
      expect(snippet.truncatedEnd, isTrue);
      expect(snippet.matches, hasLength(1));
      final m = snippet.matches.single;
      expect(snippet.text.substring(m.start, m.end), 'NEEDLE');
    });

    test('window prefers the densest cluster of matches', () {
      final gap = 'x' * 500;
      final text = 'alpha $gap alpha beta alpha $gap tail';
      final snippet = buildSnippet(text, ['alpha', 'beta'], maxLength: 80);
      // The middle cluster holds 3 hits; the lone leading alpha only 1.
      expect(snippet.text, contains('alpha beta alpha'));
      expect(snippet.matches.length, 3);
    });

    test('locates Chinese terms as raw substrings', () {
      const text = '这是一段很长的中文内容，用于测试中文搜索的片段提取功能。';
      final snippet = buildSnippet(text, ['中文搜索']);
      expect(snippet.matches, hasLength(1));
      final m = snippet.matches.single;
      expect(snippet.text.substring(m.start, m.end), '中文搜索');
    });

    test('Chinese window in long text keeps ranges aligned', () {
      final filler = '前面的无关内容。' * 50; // 400 chars
      final text = '$filler这里出现了中文搜索关键词。$filler';
      final snippet = buildSnippet(text, ['中文搜索'], maxLength: 60);
      expect(snippet.truncatedStart, isTrue);
      expect(snippet.truncatedEnd, isTrue);
      final m = snippet.matches.single;
      expect(snippet.text.substring(m.start, m.end), '中文搜索');
    });

    test('no match falls back to the head of the text, no highlights', () {
      final text = 'plain text without the term ' * 20;
      final snippet = buildSnippet(text, ['missing'], maxLength: 50);
      expect(snippet.text, text.substring(0, 50));
      expect(snippet.matches, isEmpty);
      expect(snippet.truncatedStart, isFalse);
      expect(snippet.truncatedEnd, isTrue);
    });

    test('overlapping term hits are merged into one range', () {
      final snippet = buildSnippet('interoperate', ['inter', 'operate']);
      expect(snippet.matches, [const SnippetMatch(0, 12)]);
    });

    test('window never splits an astral char at its edges', () {
      bool isHigh(int cu) => cu >= 0xD800 && cu <= 0xDBFF;
      bool isLow(int cu) => cu >= 0xDC00 && cu <= 0xDFFF;

      // Han ext-B chars are surrogate pairs; the match sits between two
      // astral runs and maxLength 101 forces both window edges onto odd
      // (mid-pair) offsets without the back-off.
      final astral = '\u{20000}' * 200; // 400 UTF-16 code units
      final text = '$astral中文搜索$astral';
      final snippet = buildSnippet(text, ['中文搜索'], maxLength: 101);

      expect(snippet.truncatedStart, isTrue);
      expect(snippet.truncatedEnd, isTrue);
      expect(isLow(snippet.text.codeUnitAt(0)), isFalse);
      expect(isHigh(snippet.text.codeUnitAt(snippet.text.length - 1)), isFalse);
      // Well-formed UTF-16 round-trips through UTF-8 losslessly.
      expect(utf8.decode(utf8.encode(snippet.text)), snippet.text);
      // Highlight offsets still align after the boundary adjustment.
      final m = snippet.matches.single;
      expect(snippet.text.substring(m.start, m.end), '中文搜索');
    });
  });
}
