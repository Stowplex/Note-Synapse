// Unit tests for the shared substring predicate (plan §1.5/§1.6) and its
// per-note folded-text memoization. The predicate runs over every note's full
// content on the widget build path (saved-filter tabs), so the cache must hit
// for unchanged notes, miss for edited ones, and stay bounded.

import 'package:flutter_test/flutter_test.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/search/search_text_normalizer.dart';
import 'package:note_synapse/utils/note_text_match.dart';

Note buildNote({
  String id = 'n1',
  String title = 'Title',
  String content = 'Content',
  List<String> tags = const [],
  DateTime? updatedAt,
}) {
  final stamp = updatedAt ?? DateTime.utc(2026, 1, 1);
  return Note(
    id: id,
    title: title,
    content: content,
    type: NoteType.note,
    createdAt: stamp,
    updatedAt: stamp,
    tags: tags,
  );
}

void main() {
  setUp(resetNoteFoldCache);

  group('matchesSubstringQuery', () {
    test('matches title, content and tags case-insensitively', () {
      final note = buildNote(
        title: 'Meeting Notes',
        content: 'Discussed the ROADMAP',
        tags: const ['Work'],
      );
      expect(matchesSubstringQuery(note, 'meeting'), isTrue);
      expect(matchesSubstringQuery(note, 'roadmap'), isTrue);
      expect(matchesSubstringQuery(note, 'WORK'), isTrue);
      expect(matchesSubstringQuery(note, 'absent'), isFalse);
    });

    test('folds through NFKC so full-width text compares equal', () {
      final note = buildNote(content: 'ｆｕｌｌｗｉｄｔｈ text');
      expect(matchesSubstringQuery(note, 'fullwidth'), isTrue);
      expect(matchesSubstringQuery(note, 'ｆｕｌｌｗｉｄｔｈ'), isTrue);
    });

    test('an empty query matches everything without folding the note', () {
      final note = buildNote(content: 'anything');
      expect(matchesSubstringQuery(note, ''), isTrue);
      expect(noteFoldCount, 0); // short-circuits before touching note text
      expect(matchesSubstringQuery(note, 'any'), isTrue);
      expect(noteFoldCount, 1);
    });

    test('includeTags: false ignores tag matches', () {
      final note = buildNote(title: 'T', content: 'C', tags: const ['recipes']);
      expect(matchesSubstringQuery(note, 'recipes'), isTrue);
      expect(
        matchesSubstringQuery(note, 'recipes', includeTags: false),
        isFalse,
      );
    });
  });

  group('matchesFoldedQuery', () {
    test('agrees with matchesSubstringQuery for a pre-folded query', () {
      final note = buildNote(content: 'ＭｉＸｅＤ case');
      expect(matchesFoldedQuery(note, foldForMatch('mixed')), isTrue);
      expect(matchesFoldedQuery(note, foldForMatch('nope')), isFalse);
      expect(matchesFoldedQuery(note, foldForMatch('')), isTrue);
    });
  });

  group('folded-text memoization', () {
    test('folds a note once no matter how many times it is matched', () {
      final note = buildNote(content: 'alpha beta gamma');

      expect(matchesSubstringQuery(note, 'beta'), isTrue);
      expect(noteFoldCount, 1);

      for (var i = 0; i < 20; i++) {
        expect(matchesSubstringQuery(note, 'beta'), isTrue);
        expect(matchesSubstringQuery(note, 'delta'), isFalse);
      }
      expect(noteFoldCount, 1);
      expect(noteFoldCacheSize, 1);
    });

    test('an equal copy of the same note reuses the cached fold', () {
      final at = DateTime.utc(2026, 3, 4, 5, 6, 7);
      matchesSubstringQuery(buildNote(content: 'stable', updatedAt: at), 'x');
      matchesSubstringQuery(buildNote(content: 'stable', updatedAt: at), 'x');
      expect(noteFoldCount, 1);
    });

    test('an edit (new updatedAt) invalidates the cached fold', () {
      final before = buildNote(
        content: 'first revision',
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      expect(matchesSubstringQuery(before, 'first'), isTrue);
      expect(matchesSubstringQuery(before, 'second'), isFalse);
      expect(noteFoldCount, 1);

      final after = before.copyWith(
        content: 'second revision',
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      expect(matchesSubstringQuery(after, 'second'), isTrue);
      expect(matchesSubstringQuery(after, 'first'), isFalse);
      expect(noteFoldCount, 2);
      // The stale entry was replaced, not added alongside.
      expect(noteFoldCacheSize, 1);
    });

    test('a same-timestamp text change still invalidates the fold', () {
      final at = DateTime.utc(2026, 1, 1);
      final before = buildNote(content: 'aaaa', updatedAt: at);
      expect(matchesSubstringQuery(before, 'bbbbb'), isFalse);

      final sameStamp = before.copyWith(content: 'bbbbb');
      expect(matchesSubstringQuery(sameStamp, 'bbbbb'), isTrue);
      expect(noteFoldCount, 2);
    });

    test('a tag change invalidates the fold', () {
      final at = DateTime.utc(2026, 1, 1);
      final before = buildNote(tags: const ['work'], updatedAt: at);
      expect(matchesSubstringQuery(before, 'home'), isFalse);

      final retagged = before.copyWith(tags: const ['work', 'home']);
      expect(matchesSubstringQuery(retagged, 'home'), isTrue);
      expect(noteFoldCount, 2);
    });

    test('distinct notes are each folded once per revision', () {
      final notes = [
        for (var i = 0; i < 5; i++) buildNote(id: 'n$i', content: 'body $i'),
      ];
      for (var pass = 0; pass < 3; pass++) {
        for (final note in notes) {
          matchesSubstringQuery(note, 'body');
        }
      }
      expect(noteFoldCount, 5);
      expect(noteFoldCacheSize, 5);
    });

    test('the cache is bounded: a large corpus evicts oldest entries', () {
      // More notes than the entry cap; the cache must not grow without limit.
      const corpus = 700;
      final notes = [
        for (var i = 0; i < corpus; i++) buildNote(id: 'n$i', content: 'b$i'),
      ];
      for (final note in notes) {
        matchesSubstringQuery(note, 'zzz');
      }
      expect(noteFoldCount, corpus);
      expect(noteFoldCacheSize, lessThan(corpus));

      // The most recently folded note is still cached; the first one was
      // evicted and folds again.
      matchesSubstringQuery(notes.last, 'zzz');
      expect(noteFoldCount, corpus);
      matchesSubstringQuery(notes.first, 'zzz');
      expect(noteFoldCount, corpus + 1);
    });
  });
}
