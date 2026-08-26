import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/search/search_text_normalizer.dart';

void main() {
  group('normalizeForIndex', () {
    test('CJK run of >=2 chars expands into overlapping bigrams', () {
      expect(normalizeForIndex('中文搜索'), '中文 文搜 搜索');
    });

    test('two-char CJK run yields a single bigram', () {
      expect(normalizeForIndex('中文'), '中文');
    });

    test('lone CJK chars between ASCII are indexed as unigrams', () {
      // "A中B": the 中 run has length 1 -> unigram, ASCII kept as words.
      expect(normalizeForIndex('A中B'), 'a 中 b');
    });

    test('CJK punctuation breaks runs (、 。 「 」)', () {
      // 你好、世界。 -> two separate 2-char runs, one bigram each.
      expect(normalizeForIndex('你好、世界。'), '你好 世界');
      // Corner brackets break the run too.
      expect(normalizeForIndex('他说「你好」了'), '他说 你好 了');
      // More CJK punctuation: ，！？；：（）《》
      expect(normalizeForIndex('《标题》，正文！'), '标题 正文');
    });

    test('NFKC folds full-width forms to half-width', () {
      // Full-width Latin + digits (ＡＢＣ１２３) normalize to ascii and
      // lowercase.
      expect(normalizeForIndex('ＡＢＣ１２３'), 'abc123');
      // Full-width comma is punctuation after NFKC -> run breaker.
      expect(normalizeForIndex('ｆｏｏ，ｂａｒ'), 'foo bar');
    });

    test('lowercases ASCII', () {
      expect(normalizeForIndex('Hello WORLD'), 'hello world');
    });

    test('markdown stripping keeps image alt text and link text', () {
      expect(
        normalizeForIndex('See ![diagram of pipeline](img.png) here'),
        'see diagram of pipeline here',
      );
      expect(
        normalizeForIndex('Read [the manual](https://example.com/manual)'),
        'read the manual',
      );
      // URL should not leak into the index tokens.
      expect(
        normalizeForIndex('[click](https://secret.example)'),
        isNot(contains('secret')),
      );
    });

    test('markdown headings, emphasis and code markers are stripped', () {
      expect(
        normalizeForIndex('# Heading\n\n**bold** and `code`'),
        'heading bold and code',
      );
    });

    test('inline emphasis inside a word does not split it', () {
      // Regression: _collectText used to emit a separator after EVERY
      // element, so the text after an inline element was cut off from it
      // (im**por**tant indexed as "impor tant").
      expect(normalizeForIndex('im**por**tant'), 'important');
    });

    test('inline emphasis inside a CJK run keeps bigrams fused across it', () {
      // Full fusion must include the 索引 bigram that straddles the closing
      // ** marker (pre-fix the stream was '中文 文搜 搜索 引擎').
      expect(normalizeForIndex('中文**搜索**引擎'), '中文 文搜 搜索 索引 引擎');
    });

    test('mixed CJK and ASCII splits at the script boundary', () {
      expect(normalizeForIndex('中文abc测试'), '中文 abc 测试');
    });

    test('ACCEPTED LIMITATION: bigrams never cross a script boundary — '
        'indexing 中文abc yields no token joining 文 and a', () {
      // The substring "文abc" inside "中文abc" cannot match as one contiguous
      // unit: the index holds the bigram 中文 and the ASCII word abc, but no
      // 文a-style cross-script token. A query for 文abc degrades to
      // (文* AND abc*) — which happens to match here, but position-adjacency
      // is lost by design. We assert the exact token stream to pin this.
      expect(normalizeForIndex('中文abc'), '中文 abc');
    });

    test('Japanese kana and Korean hangul runs are bigrammed', () {
      expect(normalizeForIndex('テスト'), 'テス スト');
      expect(normalizeForIndex('한국어'), '한국 국어');
    });

    test('empty and whitespace-only input yields empty string', () {
      expect(normalizeForIndex(''), '');
      expect(normalizeForIndex('   \n\t '), '');
    });
  });

  group('buildFtsQuery', () {
    test('ASCII terms become prefix terms joined by implicit AND', () {
      expect(buildFtsQuery('hello world'), 'hello* world*');
    });

    test('lowercases and NFKC-folds terms', () {
      expect(buildFtsQuery('Ｈｅｌｌｏ'), 'hello*');
    });

    test('quoted input becomes an FTS phrase of normalized tokens', () {
      expect(buildFtsQuery('"hello world"'), '"hello world"');
    });

    test('quoted phrase mixing ASCII and CJK normalizes like the index', () {
      expect(buildFtsQuery('"foo 中文搜索"'), '"foo 中文 文搜 搜索"');
    });

    test('CJK run becomes a phrase of overlapping bigrams', () {
      expect(buildFtsQuery('中文搜索'), '"中文 文搜 搜索"');
    });

    test('two-char CJK run becomes a single-bigram phrase', () {
      expect(buildFtsQuery('中文'), '"中文"');
    });

    test('single CJK char becomes a prefix term', () {
      expect(buildFtsQuery('中'), '中*');
    });

    test('embedded double quotes in a term are stripped', () {
      expect(buildFtsQuery('he"llo'), 'hello*');
    });

    test('bare FTS operators are stripped, not passed through', () {
      expect(buildFtsQuery('AND'), '');
      expect(buildFtsQuery('foo AND bar'), 'foo* bar*');
      expect(buildFtsQuery('foo OR NOT NEAR bar'), 'foo* bar*');
      expect(buildFtsQuery('or'), '');
      expect(buildFtsQuery('- *'), '');
      expect(buildFtsQuery('foo - bar'), 'foo* bar*');
    });

    test('leading hyphen (FTS NOT syntax) cannot be injected', () {
      // '-' is a run breaker, so "-secret" searches for secret rather than
      // excluding it.
      expect(buildFtsQuery('-secret'), 'secret*');
    });

    test('star cannot be injected as a lone operator', () {
      expect(buildFtsQuery('foo *'), 'foo*');
    });

    test('mixed CJK + ASCII term splits into independent units', () {
      expect(buildFtsQuery('中文abc'), '"中文" abc*');
    });

    test('effectively-empty queries return the empty string', () {
      expect(buildFtsQuery(''), '');
      expect(buildFtsQuery('   '), '');
      expect(buildFtsQuery('""'), '');
      expect(buildFtsQuery('...!!!'), '');
    });
  });

  group('extractHighlightTerms', () {
    test('keeps CJK runs whole for raw-substring highlighting', () {
      expect(extractHighlightTerms('中文搜索 hello'), ['中文搜索', 'hello']);
    });

    test('keeps quoted phrases whole and drops operators', () {
      expect(extractHighlightTerms('"exact phrase" foo AND'), [
        'exact phrase',
        'foo',
      ]);
    });
  });
}
