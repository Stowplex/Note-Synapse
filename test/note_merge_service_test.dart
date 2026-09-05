import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_merge_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Note _note(
  String id, {
  String content = '',
  List<String> tags = const [],
  List<String> attachmentPaths = const [],
}) => Note(
  id: id,
  title: id,
  content: content,
  type: NoteType.note,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  tags: tags,
  attachmentPaths: attachmentPaths,
);

void main() {
  group('pure helpers', () {
    test('imageTargets finds markdown images in order, deduped', () {
      const content = '''
![a](one.png) text ![b](https://x/y.png)
![c](<one.png>) ![d](synapsetemp:///abc.png "title")
''';
      expect(NoteMergeService.imageTargets(content), [
        'one.png',
        'https://x/y.png',
        'synapsetemp:///abc.png',
      ]);
    });

    test('isBareFileName', () {
      expect(NoteMergeService.isBareFileName('x.png'), isTrue);
      expect(NoteMergeService.isBareFileName('attachments/x.png'), isFalse);
      expect(NoteMergeService.isBareFileName('https://a/b.png'), isFalse);
      expect(NoteMergeService.isBareFileName('synapsetemp:///a'), isFalse);
    });

    test('relativeAttachmentPath normalises every form', () {
      expect(
        NoteMergeService.relativeAttachmentPath('/abs/dir/attachments/x.png'),
        'attachments/x.png',
      );
      expect(
        NoteMergeService.relativeAttachmentPath('attachments/x.png'),
        'attachments/x.png',
      );
      expect(NoteMergeService.relativeAttachmentPath('x.png'), 'attachments/x.png');
      expect(
        NoteMergeService.relativeAttachmentPath(r'C:\d\attachments\x.png'),
        'attachments/x.png',
      );
    });

    test('referencedAttachmentPaths takes only what the content mentions', () {
      final sources = [
        _note(
          'a',
          attachmentPaths: ['/abs/attachments/report.pdf', 'attachments/unused.pdf'],
        ),
        _note('b', attachmentPaths: ['attachments/photo.jpg']),
      ];
      const content = '''
![](photo.jpg)

See [the report](synapseresource://attachment/123) and report.pdf.

![](https://remote/img.png)
''';
      final paths = NoteMergeService.referencedAttachmentPaths(
        content,
        sources,
        extraAttachmentPaths: ['attachments/copied_x.png', 'attachments/photo.jpg'],
      );
      expect(paths, [
        'attachments/photo.jpg',
        'attachments/report.pdf',
        'attachments/copied_x.png',
      ]);
    });

    test('mentionsFileName matches whole file names only', () {
      expect(NoteMergeService.mentionsFileName('![](1.png)', '1.png'), isTrue);
      expect(NoteMergeService.mentionsFileName('![](11.png)', '1.png'), isFalse);
      expect(NoteMergeService.mentionsFileName('![](v1.png)', '1.png'), isFalse);
      expect(NoteMergeService.mentionsFileName('see my-image.png', 'image.png'), isFalse);
      expect(NoteMergeService.mentionsFileName('[image.png](x)', 'image.png'), isTrue);
      expect(NoteMergeService.mentionsFileName('(attachments/a.pdf)', 'a.pdf'), isTrue);
      expect(NoteMergeService.mentionsFileName('a.pdf', 'a.pdf'), isTrue);
      expect(NoteMergeService.mentionsFileName('see a.pdf.', 'a.pdf'), isTrue);
      expect(NoteMergeService.mentionsFileName('a.pdf.bak', 'a.pdf'), isFalse);
    });

    test('referencedAttachmentPaths ignores near-miss file names', () {
      final sources = [_note('a', attachmentPaths: ['attachments/1.png'])];
      expect(NoteMergeService.referencedAttachmentPaths('![](11.png)', sources), ['attachments/11.png']);
      expect(NoteMergeService.referencedAttachmentPaths('![](1.png)', sources), ['attachments/1.png']);
    });

    test('unreferencedAttachmentPaths lists what the content never mentions', () {
      final sources = [
        _note('a', attachmentPaths: ['/abs/attachments/report.pdf', 'attachments/unused.pdf']),
        _note('b', attachmentPaths: ['attachments/photo.jpg', 'attachments/unused.pdf']),
      ];
      expect(
        NoteMergeService.unreferencedAttachmentPaths('![](photo.jpg)', sources),
        ['attachments/report.pdf', 'attachments/unused.pdf'],
      );
      expect(
        NoteMergeService.unreferencedAttachmentPaths(
          '![](photo.jpg)',
          sources,
          alsoReferenced: ['/abs/attachments/report.pdf'],
        ),
        ['attachments/unused.pdf'],
      );
    });

    test('unionTags keeps first-seen order without duplicates', () {
      expect(
        NoteMergeService.unionTags([
          _note('a', tags: ['x', 'y']),
          _note('b', tags: ['y', 'z']),
        ]),
        ['x', 'y', 'z'],
      );
    });

    test('buildNewNote defaults an empty title', () {
      final service = NoteMergeService(DatabaseService.createNew());
      final n = service.buildNewNote(
        title: '  ',
        content: 'c',
        tags: const ['t'],
        attachmentPaths: const ['attachments/a.png'],
      );
      expect(n.title, 'Untitled');
      expect(n.type, NoteType.note);
      expect(n.tags, ['t']);
      expect(n.attachmentPaths, ['attachments/a.png']);
      expect(n.id, isNotEmpty);
    });

    test('buildReplacement keeps identity and unions attachments', () {
      final service = NoteMergeService(DatabaseService.createNew());
      final target = _note(
        'a',
        content: 'old',
        tags: ['keep'],
        attachmentPaths: ['/abs/attachments/one.png'],
      ).copyWith(pinned: true);
      final r = service.buildReplacement(
        target,
        title: '',
        content: 'new',
        tags: const ['t2'],
        attachmentPaths: const ['attachments/one.png', 'attachments/two.png'],
      );
      expect(r.id, 'a');
      expect(r.title, 'a', reason: 'empty title keeps the old one');
      expect(r.content, 'new');
      expect(r.pinned, isTrue);
      expect(r.tags, ['t2']);
      expect(r.attachmentPaths, [
        '/abs/attachments/one.png',
        'attachments/two.png',
      ]);
    });
  });

  group('copyNoteScopedImages', () {
    late Directory dir;
    late NoteMergeService service;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('merge_images');
      service = NoteMergeService(
        DatabaseService.createNew(),
        storageDirectory: () async => dir,
      );
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('duplicates remote and temp images under the target id', () async {
      const remote = 'https://example.com/pic.png';
      const temp = 'synapsetemp:///gen.svg';
      final remoteHash = _sha(remote);
      final tempHash = _sha(temp);
      await File('${dir.path}/src1_$remoteHash.png').writeAsString('R');
      await File('${dir.path}/src2_$tempHash.svg').writeAsString('T');
      await File('${dir.path}/src1_other.png').writeAsString('X');

      final created = await service.copyNoteScopedImages(
        content: '![](one.png)\n![]($remote)\n![]($temp)\n![](https://nope/x.png)',
        sourceNoteIds: ['src1', 'src2'],
        targetNoteId: 'dst',
      );

      expect(created, [
        'attachments/dst_$remoteHash.png',
        'attachments/dst_$tempHash.svg',
      ]);
      expect(await File('${dir.path}/dst_$remoteHash.png').readAsString(), 'R');
      expect(await File('${dir.path}/dst_$tempHash.svg').readAsString(), 'T');
      expect(File('${dir.path}/dst_other.png').existsSync(), isFalse);

      // Second run is a no-op: the target already has both.
      final again = await service.copyNoteScopedImages(
        content: '![]($remote)\n![]($temp)',
        sourceNoteIds: ['src1', 'src2'],
        targetNoteId: 'dst',
      );
      expect(again, isEmpty);
    });

    test('nothing to do without note-scoped images', () async {
      expect(
        await service.copyNoteScopedImages(
          content: '![](bare.png) [link](attachments/x.pdf)',
          sourceNoteIds: ['src1'],
          targetNoteId: 'dst',
        ),
        isEmpty,
      );
    });
  });

  group('fetchMissingRemoteImages', () {
    test('asks the fetcher only for http(s) images and reports its files', () async {
      final calls = <(String, List<String>)>[];
      final service = NoteMergeService(
        DatabaseService.createNew(),
        remoteImageFetcher: ({required noteId, required imageUrls}) async {
          calls.add((noteId, imageUrls.toList()));
          return ['attachments/${noteId}_abc.png'];
        },
      );
      final created = await service.fetchMissingRemoteImages(
        content: '![](bare.png) ![](https://a/b.png) ![](synapsetemp:///x) ![](HTTP://c/d.jpg)',
        targetNoteId: 'dst',
      );
      expect(calls.length, 1);
      expect(calls.single.$1, 'dst');
      expect(calls.single.$2, ['https://a/b.png', 'HTTP://c/d.jpg']);
      expect(created, ['attachments/dst_abc.png']);
    });

    test('no http images means no fetch at all', () async {
      var called = false;
      final service = NoteMergeService(
        DatabaseService.createNew(),
        remoteImageFetcher: ({required noteId, required imageUrls}) async {
          called = true;
          return const [];
        },
      );
      expect(
        await service.fetchMissingRemoteImages(content: '![](x.png)', targetNoteId: 'd'),
        isEmpty,
      );
      expect(called, isFalse);
    });

    test('a failing fetcher is swallowed', () async {
      final service = NoteMergeService(
        DatabaseService.createNew(),
        remoteImageFetcher: ({required noteId, required imageUrls}) async =>
            throw StateError('offline'),
      );
      expect(
        await service.fetchMissingRemoteImages(content: '![](https://a/b.png)', targetNoteId: 'd'),
        isEmpty,
      );
    });
  });

  group('attachment link adoption', () {
    late DatabaseService db;
    late NoteMergeService service;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      db = DatabaseService.createNew();
      await db.database;
      service = NoteMergeService(db);
    });

    tearDown(() => db.close());

    test('links to a source row are re-pointed at the merged row, with metadata', () async {
      await db.insertNote(_note('src', attachmentPaths: ['attachments/report.pdf', 'attachments/other.pdf']));
      final srcRows = await db.getAttachmentsForNote('src');
      final report = srcRows.firstWhere((r) => r.filePath.endsWith('report.pdf'));
      final other = srcRows.firstWhere((r) => r.filePath.endsWith('other.pdf'));
      await db.updateAttachmentMetadata(report.id, {'lastViewedPage': 7});
      await db.updateAttachmentAIContext('src', report.filePath, false);

      final content =
          'See [Chapter 2](synapseresource://attachment/${report.id}?page=5) '
          'and [x](synapseresource://attachment/${other.id}).';

      expect(
        await service.linkedSourceAttachmentPaths(content, ['src']),
        ['attachments/report.pdf', 'attachments/other.pdf'],
      );

      // The merged note only owns the report; "other" was not carried over.
      await db.insertNote(_note('m', attachmentPaths: ['attachments/report.pdf']));
      final rewritten = await service.adoptSourceAttachments(
        mergedNoteId: 'm',
        sourceNoteIds: ['src', 'm'],
        content: content,
      );

      final own = (await db.getAttachmentsForNote('m')).single;
      expect(own.id, isNot(report.id));
      expect(rewritten, contains('synapseresource://attachment/${own.id}?page=5'));
      expect(rewritten, contains('synapseresource://attachment/${other.id})'));
      expect(rewritten, isNot(contains(report.id)));

      final ownAfter = (await db.getAttachmentsForNote('m')).single;
      expect(ownAfter.metadata?['lastViewedPage'], 7);
      expect(ownAfter.includeInAIContext, isFalse);
    });

    test('same-named files from two sources: first source wins metadata', () async {
      await db.insertNote(_note('s1', attachmentPaths: ['attachments/doc.pdf']));
      await db.insertNote(_note('s2', attachmentPaths: ['attachments/doc.pdf']));
      final r1 = (await db.getAttachmentsForNote('s1')).single;
      final r2 = (await db.getAttachmentsForNote('s2')).single;
      await db.updateAttachmentMetadata(r1.id, {'lastViewedPage': 1});
      await db.updateAttachmentMetadata(r2.id, {'lastViewedPage': 2});
      await db.insertNote(_note('m', attachmentPaths: ['attachments/doc.pdf']));

      final rewritten = await service.adoptSourceAttachments(
        mergedNoteId: 'm',
        sourceNoteIds: ['s1', 's2'],
        content: '[a](synapseresource://attachment/${r1.id}) [b](synapseresource://attachment/${r2.id})',
      );
      final own = (await db.getAttachmentsForNote('m')).single;
      expect(rewritten, isNot(contains(r1.id)));
      expect(rewritten, isNot(contains(r2.id)));
      expect(own.metadata?['lastViewedPage'], 1);
    });

    test('content without attachment links is returned untouched', () async {
      await db.insertNote(_note('m'));
      const content = '![](x.png) [n](synapseresource://note/abc)';
      expect(
        await service.adoptSourceAttachments(mergedNoteId: 'm', sourceNoteIds: ['a'], content: content),
        content,
      );
    });
  });

  group('linkToSources', () {
    late DatabaseService db;
    late NoteMergeService service;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      db = DatabaseService.createNew();
      await db.database;
      service = NoteMergeService(db);
      for (final id in ['m', 'a', 'b']) {
        await db.insertNote(_note(id));
      }
    });

    tearDown(() => db.close());

    test('creates one references link per source, idempotently', () async {
      await service.linkToSources('m', ['a', 'b', 'm']);
      await service.linkToSources('m', ['a']);

      final rels = await db.getOutgoingRelationships('m');
      expect(rels.length, 2);
      expect(rels.map((r) => r.toNoteId).toSet(), {'a', 'b'});
      expect(rels.every((r) => r.type == RelationshipType.references), isTrue);
    });
  });
}

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();
