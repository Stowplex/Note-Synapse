import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/markdown_navigation.dart';
import 'package:note_synapse/utils/markdown_semantic_selection.dart';

/// Climbs the ladder from a collapsed cursor at [cursor], returning the text of
/// each successive selection. Reads far better in a failure than offsets do.
List<String> climb(String text, int cursor, {int limit = 12}) {
  final out = <String>[];
  var start = cursor;
  var end = cursor;
  for (var i = 0; i < limit; i++) {
    final next = MarkdownSemanticSelection.expand(text, start, end);
    if (next == null) break;
    out.add(text.substring(next.start, next.end));
    start = next.start;
    end = next.end;
  }
  return out;
}

void main() {
  group('expand ladder', () {
    test('climbs token then span then sentence then line then block', () {
      const text = 'First one. A **bold** word here. Last one.';
      final cursor = text.indexOf('bold');
      final rungs = climb(text, cursor);

      expect(rungs.first, 'bold', reason: 'innermost rung is the token');
      expect(rungs, contains('**bold**'));
      expect(rungs, contains('A **bold** word here.'));
      expect(rungs.last, text, reason: 'the ladder ends at the whole document');
      // Each rung must be strictly larger than the one before it.
      for (var i = 1; i < rungs.length; i++) {
        expect(
          rungs[i].length,
          greaterThan(rungs[i - 1].length),
          reason: 'rung $i (${rungs[i]}) did not grow',
        );
      }
    });

    test('a token expands without the punctuation that closes it', () {
      const text = 'See https://example.com/a. Done.';
      final rungs = climb(text, text.indexOf('example'));
      expect(
        rungs.first,
        'https://example.com/a',
        reason:
            'the sentence full stop is a navigation stop, not part of the URL',
      );
    });

    test('a link expands to its label, then the whole link', () {
      const text = 'go [the docs](https://x.dev) now';
      final rungs = climb(text, text.indexOf('docs'));
      expect(rungs, contains('the docs'));
      expect(rungs, contains('[the docs](https://x.dev)'));
    });

    test('a quoted string expands to its contents before its quotes', () {
      const text = 'set name to "Ada Lovelace" today';
      final rungs = climb(text, text.indexOf('Ada'));
      expect(
        rungs.indexOf('Ada Lovelace'),
        lessThan(rungs.indexOf('"Ada Lovelace"')),
      );
    });

    test('nested brackets expand innermost first', () {
      const text = 'call f(g(x), y) here';
      final rungs = climb(text, text.indexOf('x'));
      // `g(x)` is not a rung: pairing an identifier with the bracket group that
      // follows it is a code-editor notion, and this ladder is markdown's.
      expect(rungs.indexOf('x'), lessThan(rungs.indexOf('(x)')));
      expect(rungs.indexOf('(x)'), lessThan(rungs.indexOf('g(x), y')));
      expect(rungs.indexOf('g(x), y'), lessThan(rungs.indexOf('(g(x), y)')));
    });

    test('a list item expands to its text before its bullet', () {
      const text = '- [ ] buy milk\n- [ ] walk dog';
      final rungs = climb(text, text.indexOf('milk'));
      expect(rungs, contains('buy milk'));
      expect(
        rungs.indexOf('buy milk'),
        lessThan(rungs.indexOf('- [ ] buy milk')),
      );
    });

    test('a heading expands to its text before the whole heading line', () {
      const text = '# The Title\n\nbody text';
      final rungs = climb(text, text.indexOf('Title'));
      expect(rungs, contains('The Title'));
      expect(rungs, contains('# The Title'));
    });

    test('expands to the section, then the document', () {
      const text = '# One\n\nalpha\n\n## Two\n\nbeta\n\n# Three\n\ngamma';
      final rungs = climb(text, text.indexOf('beta'));
      expect(
        rungs,
        contains('## Two\n\nbeta'),
        reason: 'a level-2 section stops at the next level-1 heading',
      );
      expect(
        rungs,
        contains('# One\n\nalpha\n\n## Two\n\nbeta'),
        reason: 'the enclosing level-1 section comes next',
      );
      expect(rungs.last, text);
    });

    test('a fenced code block expands as one block', () {
      const text = 'intro\n\n```dart\nvar x = 1;\nvar y = 2;\n```\n\nafter';
      final rungs = climb(text, text.indexOf('x = 1'));
      expect(rungs, contains('```dart\nvar x = 1;\nvar y = 2;\n```'));
    });

    test('CJK text expands by clause then sentence', () {
      const text = '这是第一句。这是第二句，还有更多。';
      final rungs = climb(text, 1);
      expect(
        rungs.first,
        '这是第一句',
        reason: 'the token rung drops the closing 。',
      );
      expect(rungs, contains('这是第一句。'));
    });

    test('an apostrophe inside a contraction is not a delimiter', () {
      // `'` is a word character to the scanner, so pairing it here made the two
      // modules contradict each other: two contractions in a line is enough.
      const text = "I don't think it's right at all.";
      final rungs = climb(text, text.indexOf('think'));
      expect(rungs.first, 'think');
      expect(
        rungs.any((r) => r.startsWith("'") && r.endsWith("'")),
        isFalse,
        reason: 'no rung should be bounded by contraction apostrophes',
      );
    });

    test('an underscore inside an identifier is not a delimiter', () {
      const text = 'call snake_case then other_thing here';
      final rungs = climb(text, text.indexOf('then'));
      expect(rungs.first, 'then');
      expect(
        rungs.any((r) => r.startsWith('_') || r.endsWith('_')),
        isFalse,
        reason: 'snake_case must not be read as emphasis delimiters',
      );
    });

    test('real emphasis underscores still pair', () {
      const text = 'an _emphasised_ word';
      final rungs = climb(text, text.indexOf('emphasised'));
      expect(rungs, contains('emphasised'));
      expect(rungs, contains('_emphasised_'));
    });

    test('comparison operators are not treated as brackets', () {
      const text = 'if a < b and c > d then stop';
      final rungs = climb(text, text.indexOf('and'));
      expect(rungs.first, 'and');
      expect(
        rungs.contains(' b and c '),
        isFalse,
        reason: '< and > in prose are not a delimiter pair',
      );
    });

    test('glob asterisks are not an emphasis pair', () {
      const text = 'use *.txt or *.md files';
      final rungs = climb(text, text.indexOf('or'));
      expect(rungs.first, 'or');
      expect(
        rungs.contains('.txt or '),
        isFalse,
        reason: 'an opener may not be followed by whitespace-flanked text',
      );
      expect(rungs.contains('*.txt or *'), isFalse);
    });

    test('intraword asterisks do pair, as CommonMark says they should', () {
      // Not a defect: CommonMark permits intraword emphasis for `*` (though not
      // for `_`), so `a*b plus c*d` really is `a<em>b plus c</em>d`. Both
      // delimiters are flanking — neither touches whitespace on its inner side.
      const text = 'compute a*b plus c*d now';
      final rungs = climb(text, text.indexOf('plus'));
      expect(rungs, contains('b plus c'));
    });

    test('a padded quotation still pairs', () {
      // The flanking rule is about emphasis, not quotation, so it must not
      // reach the quote markers.
      const text = 'say " padded quote " ok';
      final rungs = climb(text, text.indexOf('padded'));
      expect(rungs, contains(' padded quote '));
      expect(rungs, contains('" padded quote "'));
    });

    test('a quoted phrase is reachable past its closing quote', () {
      const text = "he said 'hello there' loudly";
      final rungs = climb(text, text.indexOf('there'));
      expect(
        rungs.first,
        'there',
        reason: 'the closing quote is not part of the word',
      );
      expect(rungs, contains('hello there'));
      expect(rungs, contains("'hello there'"));
    });

    test('every step is a strict superset of the previous one', () {
      const text = '# H\n\n- [ ] a **b** c. d.\n\npara\n';
      for (var cursor = 0; cursor < text.length; cursor++) {
        var start = cursor;
        var end = cursor;
        for (var i = 0; i < 12; i++) {
          final next = MarkdownSemanticSelection.expand(text, start, end);
          if (next == null) break;
          expect(
            next.strictlyContains(start, end),
            isTrue,
            reason:
                'at cursor $cursor, step $i: $next did not grow ($start,$end)',
          );
          start = next.start;
          end = next.end;
        }
      }
    });

    test('terminates at the whole document', () {
      const text = 'alpha beta';
      expect(MarkdownSemanticSelection.expand(text, 0, text.length), isNull);
    });

    test('an empty document expands to nothing', () {
      expect(MarkdownSemanticSelection.expand('', 0, 0), isNull);
    });

    test('offsets past the end are clamped rather than throwing', () {
      const text = 'abc';
      expect(
        () => MarkdownSemanticSelection.expand(text, 99, 120),
        returnsNormally,
      );
    });
  });

  group('shrink history', () {
    test('shrink returns exactly the span the previous expand replaced', () {
      final history = SemanticSelectionHistory<String>();
      history.record(previous: 'cursor', result: 'token', text: 'doc');
      history.record(previous: 'token', result: 'line', text: 'doc');

      expect(history.depth, 2);
      expect(history.shrink(text: 'doc'), 'token');
      expect(history.shrink(text: 'doc'), 'cursor');
      expect(history.shrink(text: 'doc'), isNull);
      expect(history.isEmpty, isTrue);
    });

    test('editing the text invalidates the stack', () {
      final history = SemanticSelectionHistory<String>();
      history.record(previous: 'cursor', result: 'token', text: 'doc');
      history.invalidateIfForeign(text: 'edited', current: 'token');
      expect(history.isEmpty, isTrue);
      expect(history.shrink(text: 'edited'), isNull);
    });

    test('a selection change from elsewhere invalidates the stack', () {
      final history = SemanticSelectionHistory<String>();
      history.record(previous: 'cursor', result: 'token', text: 'doc');
      history.invalidateIfForeign(text: 'doc', current: 'somewhere else');
      expect(history.isEmpty, isTrue);
    });

    test('the expand it just recorded does not invalidate it', () {
      final history = SemanticSelectionHistory<String>();
      history.record(previous: 'cursor', result: 'token', text: 'doc');
      history.invalidateIfForeign(text: 'doc', current: 'token');
      expect(history.depth, 1);
    });

    test('a shrink leaves the stack valid for the next one', () {
      final history = SemanticSelectionHistory<String>();
      history.record(previous: 'cursor', result: 'token', text: 'doc');
      history.record(previous: 'token', result: 'line', text: 'doc');
      expect(history.shrink(text: 'doc'), 'token');
      history.invalidateIfForeign(text: 'doc', current: 'token');
      expect(
        history.shrink(text: 'doc'),
        'cursor',
        reason: 'shrinking must not look like a foreign selection change',
      );
    });
  });

  group('granularity floor', () {
    const text = 'alpha beta gamma\n\nsecond para here';

    test('line floor skips the token and span rungs', () {
      final first = MarkdownSemanticSelection.expand(
        text,
        7,
        7,
        floor: NavGranularity.line,
      )!;
      expect(text.substring(first.start, first.end), 'alpha beta gamma');
    });

    test('block floor skips straight to the block', () {
      final first = MarkdownSemanticSelection.expand(
        text,
        20,
        20,
        floor: NavGranularity.block,
      )!;
      expect(text.substring(first.start, first.end), 'second para here');
    });

    test('token floor still starts at the token', () {
      final first = MarkdownSemanticSelection.expand(
        text,
        7,
        7,
        floor: NavGranularity.token,
      )!;
      expect(text.substring(first.start, first.end), 'beta');
    });
  });
}
