import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/markdown_heading_slug.dart';

void main() {
  group('slugifyHeading', () {
    test('lowercases and joins words with hyphens', () {
      expect(slugifyHeading('Hello World'), 'hello-world');
    });

    test('strips leading hash markers and surrounding whitespace', () {
      expect(slugifyHeading('## Hello World'), 'hello-world');
      expect(slugifyHeading('#   Spaced  '), 'spaced');
      expect(slugifyHeading('###Nospace'), 'nospace');
    });

    test('removes punctuation', () {
      expect(slugifyHeading('Hello, World!'), 'hello-world');
      expect(slugifyHeading('What?! Really?'), 'what-really');
      expect(slugifyHeading('a/b/c'), 'a-b-c');
    });

    test('strips inline emphasis delimiters', () {
      expect(slugifyHeading('**Bold** Heading'), 'bold-heading');
      expect(slugifyHeading('*emph* and _under_'), 'emph-and-under');
      expect(slugifyHeading('~~strike~~ through'), 'strike-through');
      expect(slugifyHeading('Some `code` here'), 'some-code-here');
    });

    test('reduces inline links to their visible text', () {
      expect(
        slugifyHeading('See [the docs](https://example.com)'),
        'see-the-docs',
      );
      expect(
        slugifyHeading('![alt text](image.png) caption'),
        'alt-text-caption',
      );
    });

    test('preserves digits, underscores, and hyphens', () {
      expect(slugifyHeading('Section 3.2'), 'section-3-2');
      expect(slugifyHeading('snake_case_id'), 'snake_case_id');
      expect(slugifyHeading('already-slugged'), 'already-slugged');
    });

    test('preserves Unicode letters and digits', () {
      expect(slugifyHeading('Café Résumé'), 'café-résumé');
      expect(slugifyHeading('日本語の見出し'), '日本語の見出し');
    });

    test('trims leading and trailing hyphens', () {
      expect(slugifyHeading('-- leading'), 'leading');
      expect(slugifyHeading('trailing --'), 'trailing');
      expect(slugifyHeading('!! both !!'), 'both');
    });

    test('returns empty string for input with no slug-able content', () {
      expect(slugifyHeading(''), '');
      expect(slugifyHeading('!!!'), '');
      expect(slugifyHeading('   '), '');
    });
  });

  group('HeadingSlugCounter', () {
    test('first occurrence returns base slug unchanged', () {
      final counter = HeadingSlugCounter();
      expect(counter.next('foo'), 'foo');
    });

    test('subsequent occurrences receive incrementing suffixes', () {
      final counter = HeadingSlugCounter();
      expect(counter.next('foo'), 'foo');
      expect(counter.next('foo'), 'foo-1');
      expect(counter.next('foo'), 'foo-2');
      expect(counter.next('foo'), 'foo-3');
    });

    test('different bases are tracked independently', () {
      final counter = HeadingSlugCounter();
      expect(counter.next('foo'), 'foo');
      expect(counter.next('bar'), 'bar');
      expect(counter.next('foo'), 'foo-1');
      expect(counter.next('bar'), 'bar-1');
    });

    test('reset clears all counters', () {
      final counter = HeadingSlugCounter();
      counter.next('foo');
      counter.next('foo');
      counter.reset();
      expect(counter.next('foo'), 'foo');
    });
  });
}
