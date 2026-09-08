import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/markdown_navigation.dart';

/// Every token start on [line], in order.
List<int> starts(String line) {
  final out = <int>[];
  var probe = -1;
  while (true) {
    final next = MarkdownNavigation.nextTokenStart(line, probe);
    if (next == null) break;
    out.add(next);
    probe = next;
  }
  return out;
}

/// The text of each token stop — far easier to read in a failure than offsets.
List<String> stops(String line) {
  final s = starts(line);
  return [
    for (var i = 0; i < s.length; i++)
      line
          .substring(s[i], i + 1 < s.length ? s[i + 1] : line.length)
          .trimRight(),
  ];
}

void main() {
  group('token stepping — the cases re_editor gets wrong', () {
    test('an identifier with an underscore is one stop', () {
      // re_editor stops at 0,3,4,7,11,12,15,19 — three stops for `foo_bar`.
      expect(stops('foo_bar baz_qux end'), ['foo_bar', 'baz_qux', 'end']);
    });

    test('markdown markers and spans are single stops', () {
      // re_editor lands between `**` and `bold`, and between `code` and the
      // closing backtick — 3 of its 8 stops are inside markup.
      expect(stops('- [ ] **bold** and `code` here'), [
        '- [ ]',
        '**bold**',
        'and',
        '`code`',
        'here',
      ]);
    });

    test('a Chinese line steps by clause, not as one word', () {
      // re_editor returns exactly [0, 17]: the whole line is one "word".
      const line = '这是一个中文句子，用来测试词移动。';
      expect(stops(line), ['这是一个中文句子，', '用来测试词移动。']);
      expect(starts(line).length, greaterThan(1));
    });

    test('punctuation-dense text does not degenerate to one stop per char', () {
      // re_editor returns 11 stops for these 12 characters.
      expect(starts('a.b,c;d e--f').length, lessThan(8));
    });

    test('prose punctuation attaches to the word it ends', () {
      expect(stops('Hello, world. Bye!'), ['Hello,', 'world.', 'Bye!']);
    });

    test('a ZWJ emoji sequence is a single stop', () {
      const line = 'a 👨‍👩‍👧 b';
      final s = starts(line);
      expect(s.length, 3, reason: 'a | family | b');
      expect(line.substring(s[1], s[2]).trimRight(), '👨‍👩‍👧');
    });

    test('links, URLs, tags and wikilinks are single stops', () {
      expect(stops('see [the docs](https://example.com/a/b) now'), [
        'see',
        '[the docs](https://example.com/a/b)',
        'now',
      ]);
      expect(stops('read https://example.com/a. done'), [
        'read',
        'https://example.com/a.',
        'done',
      ]);
      expect(stops('tagged #project/alpha here'), [
        'tagged',
        '#project/alpha',
        'here',
      ]);
      expect(stops('a [[wiki link]] b'), ['a', '[[wiki link]]', 'b']);
    });

    test('a CJK tag stops at the clause mark, not the end of the line', () {
      // The tag pattern once spanned U+00C0-U+FFFF, which reaches past the
      // letters into CJK punctuation, so `#标签` swallowed everything after it.
      expect(stops('#标签，然后是更多文字。结束'), ['#标签，', '然后是更多文字。', '结束']);
      expect(stops('联系@张三，请尽快回复。谢谢'), ['联系', '@张三，', '请尽快回复。', '谢谢']);
    });

    test('an ascii tag still absorbs its whole path', () {
      expect(stops('see #a/b-c done'), ['see', '#a/b-c', 'done']);
    });

    test('plain ascii prose steps word by word', () {
      expect(stops('the quick brown fox'), ['the', 'quick', 'brown', 'fox']);
    });
  });

  group('token stepping — the inputs that make re_editor throw', () {
    test('cursor before a trailing space', () {
      expect(
        () => MarkdownNavigation.nextTokenStart('abc ', 3),
        returnsNormally,
      );
      expect(MarkdownNavigation.nextTokenStart('abc ', 3), isNull);
    });

    test('markdown hard line break (trailing double space)', () {
      expect(MarkdownNavigation.nextTokenStart('abc  ', 3), isNull);
      expect(MarkdownNavigation.previousTokenStart('abc  ', 5), 0);
    });

    test('an all-whitespace line', () {
      expect(MarkdownNavigation.nextTokenStart('   ', 0), isNull);
      expect(MarkdownNavigation.previousTokenStart('   ', 3), isNull);
      expect(MarkdownNavigation.tokenSpanAround('   ', 1), isNull);
    });

    test('an empty line', () {
      expect(MarkdownNavigation.nextTokenStart('', 0), isNull);
      expect(MarkdownNavigation.previousTokenStart('', 0), isNull);
    });

    test('a tab is treated as whitespace', () {
      expect(stops('abc\tdef'), ['abc', 'def']);
    });

    test('an ideographic space is treated as whitespace', () {
      expect(stops('中文　英文'), ['中文', '英文']);
    });
  });

  group('token stepping — direction symmetry', () {
    test('forward then backward returns to the token start', () {
      const line = 'alpha beta gamma delta';
      final forward = MarkdownNavigation.nextTokenStart(line, 6)!; // -> gamma
      expect(forward, 11);
      expect(MarkdownNavigation.previousTokenStart(line, forward), 6);
    });

    test('backward from column 0 yields null', () {
      expect(MarkdownNavigation.previousTokenStart('alpha beta', 0), isNull);
    });

    test('forward past the last token yields null', () {
      const line = 'alpha beta';
      expect(MarkdownNavigation.nextTokenStart(line, 6), isNull);
      expect(MarkdownNavigation.nextTokenStart(line, line.length), isNull);
    });

    test('leading indentation is skipped, not treated as a stop', () {
      expect(MarkdownNavigation.nextTokenStart('    hello', -1), 4);
    });
  });

  group('tokenSpanAround', () {
    test('finds the token the cursor sits inside', () {
      const line = 'alpha beta gamma';
      expect(
        MarkdownNavigation.tokenSpanAround(line, 8),
        const TokenSpan(6, 10),
      );
    });

    test('a cursor on a boundary prefers the token it opens', () {
      const line = 'alpha beta';
      expect(
        MarkdownNavigation.tokenSpanAround(line, 6),
        const TokenSpan(6, 10),
      );
    });

    test('a cursor at the end of the last token stays in it', () {
      const line = 'alpha beta';
      expect(
        MarkdownNavigation.tokenSpanAround(line, 10),
        const TokenSpan(6, 10),
      );
    });

    test('returns the whole markup span, not the text inside it', () {
      const line = 'a **bold** b';
      expect(
        MarkdownNavigation.tokenSpanAround(line, 5),
        const TokenSpan(2, 10),
      );
    });
  });

  group('block boundaries', () {
    List<String> doc(String s) => s.split('\n');

    test('a blank line starts a new paragraph block', () {
      final lines = doc('one\ntwo\n\nthree\nfour');
      expect(MarkdownNavigation.nextBlockLine(lines, 0), 3);
      expect(MarkdownNavigation.previousBlockLine(lines, 3), 0);
      expect(MarkdownNavigation.previousBlockLine(lines, 0), isNull);
      expect(MarkdownNavigation.nextBlockLine(lines, 3), isNull);
    });

    test('headings and list items start blocks without a blank line', () {
      final lines = doc('# Title\npara\n## Sub\n- one\n- two\n1. three');
      expect(starts0(lines), [0, 1, 2, 3, 4, 5]);
    });

    test('lines inside a fence are never block starts', () {
      final lines = doc(
        'para\n\n```dart\n# not a heading\n- not a list\n\nstill inside\n```\nafter',
      );
      expect(starts0(lines), [0, 2, 8]);
    });

    test('a tilde fence is closed only by a tilde fence', () {
      final lines = doc('~~~\n```\n# inside\n~~~\nafter');
      expect(starts0(lines), [0, 4]);
    });

    test('front matter and rules register as blocks', () {
      final lines = doc('---\ntitle: x\n---\n\nbody\n\n***\n\ntail');
      expect(starts0(lines), containsAll([0, 4, 6, 8]));
    });

    test('table rows start a block', () {
      final lines = doc('text\n| a | b |\n| - | - |\n| 1 | 2 |');
      expect(starts0(lines), [0, 1, 2, 3]);
    });

    test('nested list items each start a block', () {
      final lines = doc('- one\n  - nested\n    - deeper\n- two');
      expect(starts0(lines), [0, 1, 2, 3]);
    });

    test('CRLF line endings do not break structural detection', () {
      final lines = 'para\r\n\r\n# Heading\r\n- item\r\n'.split('\n');
      expect(starts0(lines), containsAll([0, 2, 3]));
    });

    test('blockRange excludes the blank lines after a block', () {
      final lines = doc('one\ntwo\n\n\nthree');
      expect(MarkdownNavigation.blockRange(lines, 1), (0, 1));
      expect(MarkdownNavigation.blockRange(lines, 4), (4, 4));
    });

    test('blockRange spans a whole fenced block', () {
      final lines = doc('intro\n\n```\ncode\nmore\n```\n\nafter');
      expect(MarkdownNavigation.blockRange(lines, 3), (2, 5));
    });

    test('blockRange on an empty document is safe', () {
      expect(MarkdownNavigation.blockRange(const [], 0), (0, 0));
      expect(MarkdownNavigation.blockRange(const [''], 5), (0, 0));
    });

    test('a document of only blank lines has no block starts', () {
      expect(starts0(doc('\n\n\n')), isEmpty);
    });
  });
}

/// Every block-start line index in [lines].
List<int> starts0(List<String> lines) {
  final out = <int>[];
  var probe = -1;
  while (true) {
    final next = MarkdownNavigation.nextBlockLine(lines, probe);
    if (next == null) break;
    out.add(next);
    probe = next;
  }
  return out;
}
