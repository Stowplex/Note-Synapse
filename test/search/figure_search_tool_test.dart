// Step 15 — the `search_figures` tool (plan §4.2) over a real index.
//
// Figure chunks are seeded the way Step 14 will write them (region identity +
// derivedAssetPath + figureIndex in `meta`, sha-like `contentHash` on the
// row), mirroring test/search/figure_resolver_test.dart, because the figureId
// the tool emits MUST be minted from the chunk row's contentHash — never from
// a rendered PNG. Real sqlite (sqflite_common_ffi) throughout, so the privacy
// (includeInAIContext), archived and deletion behaviour is exercised end to
// end rather than mocked.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search/search_service.dart';
import 'package:note_synapse/services/search/search_text_normalizer.dart';
import 'package:note_synapse/services/tools/figure_tools.dart';

import 'ocr_test_stubs.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late DataChangeNotifier notifier;
  late NoteIndexService indexer;
  late SearchService search;
  late FigureSearchTool tool;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = DatabaseService.createNew();
    await db.database;
    notifier = DataChangeNotifier();
    indexer = NoteIndexService(
      db,
      changeNotifier: notifier,
      debounceDelay: const Duration(milliseconds: 50),
      ocrExtractor: stubOcrExtractor(db),
      figureExtractor: stubFigureExtractor(),
    );
    search = SearchService(db, indexer, notesProvider: () => db.getAllNotes());
    // The indexer is injected so the tool can report REAL index state: during
    // a backfill an empty result says nothing about the corpus.
    tool = FigureSearchTool(
      db: db,
      searchService: search,
      indexService: indexer,
    );
  });

  tearDown(() async {
    indexer.dispose();
    await db.close();
  });

  Future<void> insertNote(
    String id, {
    required String title,
    String content = 'body text',
    bool isArchived = false,
  }) async {
    await db.insertNote(
      Note(
        id: id,
        title: title,
        content: content,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isArchived: isArchived,
      ),
    );
  }

  Future<void> insertAttachment(
    String id,
    String noteId, {
    String fileName = 'paper.pdf',
    String fileType = 'application/pdf',
    bool includeInAIContext = true,
  }) async {
    final raw = await db.database;
    await raw.insert('attachments', {
      'id': id,
      'noteId': noteId,
      'filePath': 'files/$fileName',
      'fileName': fileName,
      'fileType': fileType,
      'isRelativePath': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': includeInAIContext ? 1 : 0,
    });
  }

  /// Flushes debounced reindexes and completes the backfill so the FTS path
  /// is live. Chunks are seeded AFTER this — the indexer would otherwise
  /// treat hand-written chunks as stale and delete them.
  Future<void> indexAll() async {
    await indexer.flushPending();
    await indexer.backfillAll();
    expect(await indexer.isBackfillComplete(), isTrue);
  }

  /// Inserts a chunk plus its `chunks_fts` row (normalized content, docid =
  /// search_chunks.id), the way the indexer writes them.
  Future<int> insertChunk({
    required String chunkKey,
    required String noteId,
    required String sourceType,
    required String? sourceId,
    required int? page,
    required int seq,
    required String text,
    required String contentHash,
    Map<String, dynamic>? meta,
  }) async {
    final raw = await db.database;
    final chunkId = await raw.insert('search_chunks', {
      'chunkKey': chunkKey,
      'noteId': noteId,
      'sourceType': sourceType,
      'sourceId': sourceId,
      'page': page,
      'seq': seq,
      'text': text,
      if (meta != null) 'meta': jsonEncode(meta),
      'contentHash': contentHash,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await raw.rawInsert('INSERT INTO chunks_fts(docid, content) VALUES(?, ?)', [
      chunkId,
      normalizeForIndex(text),
    ]);
    return chunkId;
  }

  /// A `figure` chunk carrying an extracted REGION (derived crop on disk),
  /// exactly the meta shape Step 14 writes. Returns its chunkKey.
  Future<String> insertFigureChunk({
    required String noteId,
    required String attachmentId,
    required int page,
    required int figureIndex,
    required String contentHash,
    required String caption,
    String? text,
    bool withDerivedAsset = true,
  }) async {
    final chunkKey =
        '$noteId:figure:$attachmentId:${page * 1000 + figureIndex}';
    await insertChunk(
      chunkKey: chunkKey,
      noteId: noteId,
      sourceType: 'figure',
      sourceId: attachmentId,
      page: page,
      seq: page * 1000 + figureIndex,
      text: text ?? caption,
      contentHash: contentHash,
      meta: {
        'page': page,
        'rect': {'l': 72.0, 't': 700.0, 'r': 540.0, 'b': 400.0},
        'confidence': 0.9,
        'source': 'captioned',
        'caption': caption,
        if (withDerivedAsset)
          'derivedAssetPath':
              'attachments/derived/${attachmentId}_p${page}_f$figureIndex.png',
        'figureIndex': figureIndex,
      },
    );
    return chunkKey;
  }

  Future<String> run({
    required String query,
    String? noteId,
    int? limit,
  }) async {
    final result = await tool.execute({
      'query': query,
      if (noteId != null) 'noteId': noteId,
      if (limit != null) 'limit': limit,
    });
    expect(result, isA<String>(), reason: 'tool results stay Strings');
    return result as String;
  }

  group('tool contract', () {
    test('name and description carry the always-on guardrail', () {
      expect(tool.name, 'search_figures');
      expect(tool.description, contains('pages are links, never images'));
      expect(
        tool.description,
        contains('prefer retrieving an existing figure over generating one'),
      );
      expect(
        tool.description.trim().split('\n'),
        hasLength(lessThanOrEqualTo(4)),
        reason: 'behavioural guidance belongs in the skill, not here',
      );
      expect(
        (tool.inputSchema['properties'] as Map).keys,
        containsAll(['query', 'noteId', 'limit']),
      );
    });

    test('an empty query asks for one instead of searching', () async {
      final result = await run(query: '   ');
      expect(result, contains('a `query` is required'));
      expect(result, contains('Layers off:'));
    });
  });

  group('output format', () {
    test('a figure hit embeds an image whose figureId is minted from the '
        'chunk ROW contentHash', () async {
      await insertNote('paper', title: 'Attention Is All You Need');
      await insertAttachment('att1', 'paper');
      await indexAll();
      await insertFigureChunk(
        noteId: 'paper',
        attachmentId: 'att1',
        page: 3,
        figureIndex: 0,
        contentHash: 'aaaa1111bbbb2222cccc3333',
        caption: 'Figure 2: The Transformer architecture',
        text: 'Figure 2: The Transformer architecture\npaper.pdf',
      );

      final result = await run(query: 'transformer architecture');

      // The exact URI: <chunkKey>~<first 12 hex chars of the row hash>.
      expect(
        result,
        contains(
          '![Figure 2: The Transformer architecture]'
          '(synapseresource://figure/paper:figure:att1:3000~aaaa1111bbbb)',
        ),
      );
      expect(result, contains('FIGURE'));
      expect(result, contains('from "Attention Is All You Need"'));
      expect(result, contains('p.3'));
      expect(result, contains('1 hit(s)'));
    });

    test('a page-level hit is a plain link and never an image', () async {
      await insertNote('paper', title: 'Attention Is All You Need');
      await insertAttachment('att1', 'paper');
      await indexAll();
      await insertChunk(
        chunkKey: 'paper:attachment_text:att1:7',
        noteId: 'paper',
        sourceType: 'attachment_text',
        sourceId: 'att1',
        page: 7,
        seq: 7,
        text: 'The transformer architecture is described on this page.',
        contentHash: 'page7hash',
      );

      final result = await run(query: 'transformer architecture');

      expect(
        result,
        contains(
          '[Attention Is All You Need, p.7]'
          '(synapseresource://attachment/att1?page=7)',
        ),
      );
      expect(
        result,
        isNot(contains('![')),
        reason: 'a whole PDF page must never be offered as an inline image',
      );
      expect(result, contains('PAGE'));
    });

    test(
      'a raster image attachment embeds through its attachment URI',
      () async {
        await insertNote('design', title: 'Design meeting');
        await insertAttachment(
          'img1',
          'design',
          fileName: 'whiteboard.png',
          fileType: 'image/png',
        );
        await indexAll();
        await insertFigureChunk(
          noteId: 'design',
          attachmentId: 'img1',
          page: 1,
          figureIndex: 0,
          contentHash: 'bbbb2222cccc3333',
          caption: 'whiteboard sketch of the sync architecture',
          withDerivedAsset: false, // The file itself IS the image: no crop.
        );

        final result = await run(query: 'sync architecture');

        expect(
          result,
          contains(
            '![whiteboard sketch of the sync architecture]'
            '(synapseresource://attachment/img1)',
          ),
        );
        expect(result, isNot(contains('synapseresource://figure/')));
        expect(result, contains('IMAGE'));
      },
    );

    test('an SVG attachment is linked with its CAPTION, no page suffix, and '
        'an honest reason', () async {
      await insertNote('design', title: 'Design meeting');
      await insertAttachment(
        'svg1',
        'design',
        fileName: 'topology.svg',
        fileType: 'image/svg+xml',
      );
      await indexAll();
      await insertFigureChunk(
        noteId: 'design',
        attachmentId: 'svg1',
        page: 1,
        figureIndex: 0,
        contentHash: 'cccc3333dddd4444',
        caption: 'cluster topology diagram',
        withDerivedAsset: false,
      );

      final result = await run(query: 'cluster topology');

      expect(result, isNot(contains('![')));
      expect(
        result,
        contains(
          '[cluster topology diagram](synapseresource://attachment/svg1)',
        ),
        reason: 'the caption is what identifies the figure — do not drop it',
      );
      expect(
        result,
        isNot(contains('?page=')),
        reason: 'a single image file has no page 1',
      );
      expect(result, contains('LINK'));
      expect(result, contains('.svg image cannot be rendered inline'));
      expect(
        result,
        isNot(contains('no figure region was extracted')),
        reason: 'that reason is false for an SVG: nothing was ever croppable',
      );
    });

    test('a figure chunk with no crop yet keeps its caption, its page, and '
        'says why it is a link', () async {
      await insertNote('paper', title: 'Field survey');
      await insertAttachment('att1', 'paper');
      await indexAll();
      await insertFigureChunk(
        noteId: 'paper',
        attachmentId: 'att1',
        page: 6,
        figureIndex: 0,
        contentHash: 'aaaa0000bbbb1111',
        caption: 'Figure 6: sediment core profile',
        withDerivedAsset: false, // Region detected, crop not extracted (yet).
      );

      final result = await run(query: 'sediment core profile');

      expect(
        result,
        contains(
          '[Figure 6: sediment core profile, p.6]'
          '(synapseresource://attachment/att1?page=6)',
        ),
      );
      expect(result, contains('no figure region has been extracted'));
      expect(result, isNot(contains('![')));
    });

    test(
      'two crop-less figure chunks on one page offer that page ONCE',
      () async {
        await insertNote('paper', title: 'Survey paper');
        await insertAttachment('att1', 'paper');
        await indexAll();
        for (var i = 0; i < 2; i++) {
          await insertFigureChunk(
            noteId: 'paper',
            attachmentId: 'att1',
            page: 3,
            figureIndex: i,
            contentHash: 'ffff000${i}aaaa1111',
            caption: 'Figure 3$i: bathymetry panel',
            withDerivedAsset: false,
          );
        }

        final result = await run(query: 'bathymetry panel');

        expect(
          result,
          contains('1 hit(s)'),
          reason: 'both chunks point at page 3 — one link, one slot',
        );
        expect('?page=3'.allMatches(result), hasLength(1));
      },
    );

    test('a figure whose attachment row is gone degrades to no hit, not a '
        'crash', () async {
      await insertNote('paper', title: 'Orphaned figures');
      await indexAll();
      await insertFigureChunk(
        noteId: 'paper',
        attachmentId: 'vanished',
        page: 2,
        figureIndex: 0,
        contentHash: 'bbbb1111cccc2222',
        caption: 'Figure 2: orphaned salinity plot',
        withDerivedAsset: false,
      );

      final result = await run(query: 'orphaned salinity plot');

      // The ai audience treats an unresolvable attachment conservatively, so
      // the chunk never surfaces — but the tool still answers cleanly.
      expect(result, contains('no figures or pages found'));
      expect(result, contains('Scope:'));
    });

    test('a markdown-hostile note title still produces a valid link', () async {
      await insertNote('paper', title: '[Draft] Q3 "final"\nreport');
      await insertAttachment('att1', 'paper');
      await indexAll();
      await insertChunk(
        chunkKey: 'paper:attachment_text:att1:7',
        noteId: 'paper',
        sourceType: 'attachment_text',
        sourceId: 'att1',
        page: 7,
        seq: 7,
        text: 'quarterly bookings waterfall on this page',
        contentHash: 'page7hash',
      );

      final result = await run(query: 'quarterly bookings waterfall');

      expect(
        result,
        contains(
          '[(Draft) Q3 "final" report, p.7]'
          '(synapseresource://attachment/att1?page=7)',
        ),
        reason:
            'brackets become parens and the newline is flattened, so the '
            'link the skill tells the model to paste verbatim is valid',
      );
      expect(
        result,
        contains('''from "(Draft) Q3 'final' report"'''),
        reason:
            'the inner double quote is demoted so the headline quoting '
            'stays unambiguous',
      );
    });

    test(
      'figures come first and their page is not repeated as a link',
      () async {
        await insertNote('paper', title: 'Attention Is All You Need');
        await insertAttachment('att1', 'paper');
        await indexAll();
        await insertFigureChunk(
          noteId: 'paper',
          attachmentId: 'att1',
          page: 3,
          figureIndex: 0,
          contentHash: 'dddd4444eeee5555',
          caption: 'Figure 2: encoder decoder architecture',
        );
        // Same page, page-level chunk: the figure already represents it.
        await insertChunk(
          chunkKey: 'paper:attachment_text:att1:3',
          noteId: 'paper',
          sourceType: 'attachment_text',
          sourceId: 'att1',
          page: 3,
          seq: 3,
          text: 'encoder decoder architecture explained',
          contentHash: 'page3hash',
        );
        // A different page with no extracted figure: link-only degradation.
        await insertChunk(
          chunkKey: 'paper:attachment_text:att1:5',
          noteId: 'paper',
          sourceType: 'attachment_text',
          sourceId: 'att1',
          page: 5,
          seq: 5,
          text: 'the encoder decoder architecture ablation table',
          contentHash: 'page5hash',
        );

        final result = await run(query: 'encoder decoder architecture');

        expect(result, contains('FIGURE'));
        expect(result, contains('?page=5'));
        expect(
          result.indexOf('FIGURE'),
          lessThan(result.indexOf('PAGE')),
          reason: 'embeddable figures are offered before page links',
        );
        expect(
          result,
          isNot(contains('?page=3')),
          reason: 'the page a figure came from must not also be offered',
        );
      },
    );
  });

  group('scoping', () {
    test('a figure whose attachment opted out of AI context never '
        'surfaces', () async {
      await insertNote('private', title: 'Private report');
      await insertAttachment(
        'secret',
        'private',
        fileName: 'secret.pdf',
        includeInAIContext: false,
      );
      await insertNote('public', title: 'Public paper');
      await insertAttachment('att1', 'public');
      await indexAll();
      await insertFigureChunk(
        noteId: 'private',
        attachmentId: 'secret',
        page: 2,
        figureIndex: 0,
        contentHash: 'eeee5555ffff6666',
        caption: 'Figure 1: revenue waterfall chart',
      );
      await insertFigureChunk(
        noteId: 'public',
        attachmentId: 'att1',
        page: 4,
        figureIndex: 0,
        contentHash: 'ffff6666aaaa7777',
        caption: 'Figure 4: public waterfall chart',
      );

      final result = await run(query: 'waterfall chart');

      expect(result, contains('Figure 4: public waterfall chart'));
      expect(result, isNot(contains('revenue')));
      expect(result, isNot(contains('synapseresource://figure/private')));

      // Fixture sanity: the user's OWN search still sees the excluded figure,
      // so the exclusion above came from the ai audience, not a bad fixture.
      final userView = await search.searchFused(
        'waterfall chart',
        filter: const NoteFilterContext(sourceTypes: {'figure'}),
      );
      expect([
        for (final r in userView.results) r.noteId,
      ], containsAll(['private', 'public']));
    });

    test('every report says what the scope excluded', () async {
      await insertNote('paper', title: 'Attention Is All You Need');
      await indexAll();

      final open = await run(query: 'anything at all');
      expect(open, contains('Scope:'));
      expect(
        open,
        contains('ARCHIVED'),
        reason:
            'an exclusion the model cannot see becomes an assertion of '
            'absence',
      );

      final scoped = await run(query: 'anything at all', noteId: 'paper');
      expect(scoped, contains('Scope: note paper only'));
      expect(scoped, contains('archived figures included'));
    });

    test('naming a note opts its archived figures back in', () async {
      await insertNote('old', title: 'Archived note', isArchived: true);
      await insertAttachment('att2', 'old', fileName: 'old.pdf');
      await indexAll();
      await insertFigureChunk(
        noteId: 'old',
        attachmentId: 'att2',
        page: 1,
        figureIndex: 0,
        contentHash: 'cccc2222dddd3333',
        caption: 'Figure 1: archived pipeline diagram',
      );

      // An open search still refuses it...
      expect(
        await run(query: 'pipeline diagram'),
        isNot(contains('archived pipeline diagram')),
      );
      // ...but the user naming the note is the user asking for it.
      expect(
        await run(query: 'pipeline diagram', noteId: 'old'),
        contains('archived pipeline diagram'),
      );
    });

    test('figures in archived notes are not offered', () async {
      await insertNote('live', title: 'Live note');
      await insertAttachment('att1', 'live');
      await insertNote('old', title: 'Archived note', isArchived: true);
      await insertAttachment('att2', 'old', fileName: 'old.pdf');
      await indexAll();
      await insertFigureChunk(
        noteId: 'live',
        attachmentId: 'att1',
        page: 1,
        figureIndex: 0,
        contentHash: 'aaaa7777bbbb8888',
        caption: 'Figure 1: live pipeline diagram',
      );
      await insertFigureChunk(
        noteId: 'old',
        attachmentId: 'att2',
        page: 1,
        figureIndex: 0,
        contentHash: 'bbbb8888cccc9999',
        caption: 'Figure 1: archived pipeline diagram',
      );

      final result = await run(query: 'pipeline diagram');

      expect(result, contains('live pipeline diagram'));
      expect(result, isNot(contains('archived pipeline diagram')));
    });

    test('noteId restricts the search to one note', () async {
      await insertNote('a', title: 'Note A');
      await insertAttachment('atta', 'a', fileName: 'a.pdf');
      await insertNote('b', title: 'Note B');
      await insertAttachment('attb', 'b', fileName: 'b.pdf');
      await indexAll();
      await insertFigureChunk(
        noteId: 'a',
        attachmentId: 'atta',
        page: 1,
        figureIndex: 0,
        contentHash: 'cccc9999dddd0000',
        caption: 'Figure 1: alpha topology map',
      );
      await insertFigureChunk(
        noteId: 'b',
        attachmentId: 'attb',
        page: 1,
        figureIndex: 0,
        contentHash: 'dddd0000eeee1111',
        caption: 'Figure 1: beta topology map',
      );

      final both = await run(query: 'topology map');
      expect(both, contains('alpha topology map'));
      expect(both, contains('beta topology map'));

      final scoped = await run(query: 'topology map', noteId: 'b');
      expect(scoped, contains('beta topology map'));
      expect(scoped, isNot(contains('alpha topology map')));
      expect(scoped, contains('1 hit(s)'));
    });

    test('several figures of the SAME note are offered, up to limit', () async {
      await insertNote('paper', title: 'Survey paper');
      await insertAttachment('att1', 'paper');
      await indexAll();
      for (var i = 0; i < 3; i++) {
        await insertFigureChunk(
          noteId: 'paper',
          attachmentId: 'att1',
          page: i + 1,
          figureIndex: 0,
          contentHash: 'hash$i${'0' * 12}',
          caption: 'Figure ${i + 1}: latency benchmark chart',
        );
      }

      final all = await run(query: 'latency benchmark chart');
      expect(all, contains('3 hit(s)'));
      expect(all, contains('Figure 1: latency benchmark chart'));
      expect(all, contains('Figure 3: latency benchmark chart'));

      final capped = await run(query: 'latency benchmark chart', limit: 2);
      expect(capped, contains('2 hit(s)'));
      expect(capped, contains('2. '));
      expect(capped, isNot(contains('3. ')));
    });
  });

  group('live index', () {
    test('a deleted figure stops being offered', () async {
      await insertNote('paper', title: 'Attention Is All You Need');
      await insertAttachment('att1', 'paper');
      await indexAll();
      final chunkKey = await insertFigureChunk(
        noteId: 'paper',
        attachmentId: 'att1',
        page: 3,
        figureIndex: 0,
        contentHash: 'eeee1111ffff2222',
        caption: 'Figure 2: attention heatmap',
      );

      expect(await run(query: 'attention heatmap'), contains('heatmap'));

      final raw = await db.database;
      await raw.delete(
        'search_chunks',
        where: 'chunkKey = ?',
        whereArgs: [chunkKey],
      );

      final after = await run(query: 'attention heatmap');
      expect(after, contains('no figures or pages found'));
      expect(after, isNot(contains('synapseresource://figure/')));
    });

    test('no match states it plainly and still reports layer state', () async {
      await insertNote('paper', title: 'Attention Is All You Need');
      await indexAll();

      final result = await run(query: 'unicorn parade');

      expect(
        result,
        contains('no figures or pages found for "unicorn parade"'),
      );
      expect(result, contains('Layers off:'));
    });
  });

  group('index state (no confident false negatives)', () {
    test('mid-backfill, a miss is reported as an incomplete search, not as '
        'absence', () async {
      // Fresh install / post-recovery / after the Rebuild action: the chunk
      // index is not usable yet, so nothing figure-shaped can be searched.
      await indexer.pause();
      await insertNote('paper', title: 'Attention Is All You Need');
      await indexer.reindexNote('paper');
      expect(await indexer.isBackfillComplete(), isFalse);

      final result = await run(query: 'transformer architecture');

      expect(result, contains('no figures or pages found'));
      expect(
        result,
        contains('NOT proof the figure is absent'),
        reason:
            'the caveat has to be on the HEADLINE — a model that reads '
            'one line must not walk away with "it is not there"',
      );
      expect(result, contains('Index: INCOMPLETE'));
      expect(
        result,
        isNot(contains('Layers off: none.\n')),
        reason: 'the index line must accompany the layer line, not replace it',
      );
      expect(result, contains('Layers off:'));
    });

    test('a completed backfill prints no Index line at all', () async {
      await insertNote('paper', title: 'Attention Is All You Need');
      await indexAll();

      final result = await run(query: 'unicorn parade');

      expect(
        result,
        contains('no figures or pages found for "unicorn parade"'),
      );
      expect(result, isNot(contains('Index:')));
      expect(result, isNot(contains('NOT proof')));
    });
  });

  group('layer state', () {
    test('a missing embedding provider is reported as an off layer', () async {
      await insertNote('paper', title: 'Attention Is All You Need');
      await indexAll();

      final result = await run(query: 'anything');

      expect(result, contains('Layers off:'));
      expect(result, contains('no embedding provider'));
      expect(result, isNot(contains('figure extraction')));
      expect(result, isNot(contains('OCR (')));
    });

    test('OCR and figure indexing report as off when switched off', () async {
      SharedPreferences.setMockInitialValues({
        'search_index_ocr_enabled': false,
        'search_index_figures_enabled': false,
      });
      await insertNote('paper', title: 'Attention Is All You Need');
      await indexAll();

      final result = await run(query: 'anything');

      expect(result, contains('figure extraction'));
      expect(result, contains('OCR ('));
    });
  });
}
