import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/note_annotation.dart';
import 'package:note_synapse/services/search/note_chunker.dart';

Note _note({
  String id = 'note-1',
  String title = 'My Note',
  String content = '',
  List<SubNote> subNotes = const [],
  List<String> tags = const [],
}) {
  return Note(
    id: id,
    title: title,
    content: content,
    type: NoteType.note,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 2),
    subNotes: subNotes,
    tags: tags,
  );
}

void main() {
  group('chunkNote', () {
    test('emits a meta chunk with title and tag names', () {
      final drafts = chunkNote(
        _note(title: 'Trip Plan', tags: ['travel', 'japan']),
      );
      final meta = drafts.singleWhere((d) => d.sourceType == 'meta');
      expect(meta.text, 'Trip Plan\ntravel\njapan');
      expect(meta.seq, 0);
      expect(meta.chunkKey, 'note-1:meta:-:0');
      expect(meta.page, isNull);
    });

    test('splits body at headings and prepends breadcrumbs', () {
      final drafts = chunkNote(
        _note(content: '# Setup\n\nInstall deps.\n\n## Android\n\nRun gradle.'),
      );
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body, hasLength(2));
      expect(body[0].text, 'Setup\nInstall deps.');
      expect(body[1].text, 'Setup > Android\nRun gradle.');
    });

    test('packs paragraphs to roughly the 1200-char target', () {
      // 10 paragraphs of ~300 chars: expect ~4 per chunk, none far over
      // target and (except possibly the merged tail) none under the min.
      final para = List.filled(30, 'lorem ipsu').join(' '); // 329 chars
      final content = List.filled(10, para).join('\n\n');
      final drafts = chunkNote(_note(content: content));
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body.length, greaterThan(1));
      for (final d in body) {
        expect(d.text.length, lessThanOrEqualTo(kChunkTargetChars + 400));
        expect(d.text.length, greaterThanOrEqualTo(kChunkMinChars));
      }
      // No text lost.
      final joined = body.map((d) => d.text).join('\n\n');
      expect(joined, content);
    });

    test('hard-splits a single paragraph far above the target', () {
      final huge = List.filled(300, 'wordword').join(' '); // 2699 chars
      final drafts = chunkNote(_note(content: huge));
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body.length, greaterThanOrEqualTo(2));
      for (final d in body) {
        expect(d.text.length, lessThanOrEqualTo(kChunkTargetChars + 200));
      }
    });

    test('merges a small trailing chunk into the previous one', () {
      final big = List.filled(109, 'alpha beta').join(' '); // 1198 chars
      final content = '$big\n\ntiny tail';
      final drafts = chunkNote(_note(content: content));
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body, hasLength(1));
      expect(body.single.text, contains('tiny tail'));
    });

    test('sequential seq and stable chunkKeys per source stream', () {
      final drafts = chunkNote(
        _note(
          content: '# A\n\none\n\n# B\n\ntwo',
          subNotes: [
            SubNote(
              id: 'sub-1',
              name: 'Checklist',
              content: 'pack bags',
              createdAt: DateTime(2026, 1, 1),
            ),
          ],
        ),
        annotations: [
          NoteAnnotation(
            id: 'ann-1',
            noteId: 'note-1',
            content: 'margin comment',
            attachmentPaths: const [],
            createdAt: DateTime(2026, 1, 1),
          ),
        ],
      );
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body.map((d) => d.seq), [0, 1]);
      expect(body.map((d) => d.chunkKey), [
        'note-1:note_body:-:0',
        'note-1:note_body:-:1',
      ]);

      final sub = drafts.singleWhere((d) => d.sourceType == 'subnote');
      expect(sub.sourceId, 'sub-1');
      expect(sub.chunkKey, 'note-1:subnote:sub-1:0');
      expect(sub.text, 'Checklist\npack bags');

      final ann = drafts.singleWhere((d) => d.sourceType == 'annotation');
      expect(ann.sourceId, 'ann-1');
      expect(ann.chunkKey, 'note-1:annotation:ann-1:0');
      expect(ann.text, 'margin comment');
    });

    test('chunking identical input twice yields identical keys and hashes', () {
      final note = _note(content: '# A\n\nsome body text', tags: ['t']);
      final a = chunkNote(note);
      final b = chunkNote(note);
      expect(a.map((d) => d.chunkKey), b.map((d) => d.chunkKey));
      expect(a.map((d) => d.contentHash), b.map((d) => d.contentHash));
    });

    test('contentHash is the sha256 of the chunk text', () {
      final drafts = chunkNote(_note(content: 'hello'));
      final body = drafts.singleWhere((d) => d.sourceType == 'note_body');
      expect(
        body.contentHash,
        sha256.convert(utf8.encode(body.text)).toString(),
      );
    });

    test('empty note yields only the meta chunk', () {
      final drafts = chunkNote(_note(title: 'Just a title'));
      expect(drafts, hasLength(1));
      expect(drafts.single.sourceType, 'meta');
    });

    test('parent heading with only subsections is not duplicated', () {
      final drafts = chunkNote(_note(content: '# A\n\n## B\n\nbody'));
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body, hasLength(1));
      expect(body.single.text, 'A > B\nbody');
    });

    test('code fences do not trigger heading detection', () {
      final drafts = chunkNote(
        _note(content: 'intro\n\n```\n# not a heading\n```\n\noutro'),
      );
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body.map((d) => d.text).join(), isNot(contains(' > ')));
      expect(body.map((d) => d.text).join('\n'), contains('# not a heading'));
    });

    test('a ~~~ line does not close a ``` fence', () {
      final drafts = chunkNote(
        _note(
          content:
              'intro\n\n```\ncode line\n~~~\n# not-a-heading\n```\n\noutro',
        ),
      );
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      final joined = body.map((d) => d.text).join('\n');
      // The fenced pseudo-heading never becomes a breadcrumb...
      expect(body.any((d) => d.text.startsWith('not-a-heading')), isFalse);
      expect(joined, isNot(contains(' > ')));
      // ...and the fence content survives unmutated.
      expect(joined, contains('code line\n~~~\n# not-a-heading'));
      expect(joined, contains('outro'));
    });

    test('sibling heading with a shared name prefix does not suppress a '
        'body-less heading chunk', () {
      // "# AB" is a SIBLING of "# A", not a descendant: A's words appear
      // nowhere else, so A must still get its heading-only chunk.
      final drafts = chunkNote(_note(content: '# A\n\n# AB\n\nbody'));
      final body = drafts.where((d) => d.sourceType == 'note_body').toList();
      expect(body.map((d) => d.text), contains('A'));
      expect(body.map((d) => d.text), contains('AB\nbody'));
    });

    test('hard split never severs a surrogate pair (astral CJK)', () {
      // Han ext-B chars are surrogate pairs (2 UTF-16 code units); the
      // leading BMP char forces every pair onto an odd offset, and the lack
      // of whitespace forces raw-offset hard splits.
      final text = '中${'\u{20000}' * 2000}'; // 4001 UTF-16 code units
      final chunks = chunkMarkdown(text);
      expect(chunks.length, greaterThan(1));

      bool isHigh(int cu) => cu >= 0xD800 && cu <= 0xDBFF;
      bool isLow(int cu) => cu >= 0xDC00 && cu <= 0xDFFF;
      for (final chunk in chunks) {
        expect(isLow(chunk.codeUnitAt(0)), isFalse);
        expect(isHigh(chunk.codeUnitAt(chunk.length - 1)), isFalse);
      }
      // Well-formed UTF-16 round-trips through UTF-8 losslessly; a lone
      // surrogate would come back as U+FFFD instead.
      final joined = chunks.join();
      expect(utf8.decode(utf8.encode(joined)), joined);
    });
  });

  group('chunkPdfPage', () {
    test('produces attachment_text chunks with 1-based page', () {
      final drafts = chunkPdfPage('note-1', 'att-9', 3, 'Some page text.');
      expect(drafts, hasLength(1));
      final d = drafts.single;
      expect(d.sourceType, 'attachment_text');
      expect(d.sourceId, 'att-9');
      expect(d.page, 3);
      expect(d.noteId, 'note-1');
      expect(d.text, 'Some page text.');
    });

    test('seq is banded per page so chunkKeys never collide across pages', () {
      final p1 = chunkPdfPage('n', 'att', 1, 'page one');
      final p2 = chunkPdfPage('n', 'att', 2, 'page two');
      expect(p1.single.seq, 0);
      expect(p2.single.seq, 1000);
      expect(p1.single.chunkKey, isNot(p2.single.chunkKey));
    });

    test('empty page text yields no chunks', () {
      expect(chunkPdfPage('n', 'att', 1, '  \n '), isEmpty);
    });

    test('asserts if a page overflows its 1000-chunk seq band', () {
      // 1,201,000 chars with no whitespace hard-split into 1200-char pieces,
      // one chunk each -> 1001 chunks, one past the per-page band.
      final huge = 'x' * (kChunkTargetChars * 1000 + 1000);
      expect(
        () => chunkPdfPage('n', 'att', 1, huge),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
