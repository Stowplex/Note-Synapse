// Integration tests for NoteSearchTool's layered-search path (plan §1.6):
// tool → SearchService.searchFused(audience: ai) → real sqlite
// (sqflite_common_ffi), following the search_service_test.dart harness.
//
// Pinned behaviors:
// - ranked results with real best-chunk snippets, output schema unchanged
//   (id / title / snippet / tags);
// - tag filtering (AND semantics, like the old EXISTS-per-tag SQL) applied
//   inside the search via NoteFilterContext.requiredTags, so tagged notes
//   ranked below the top slice are still found;
// - candidate list capped before note loading; getNotesByIds chunks its
//   IN() list;
// - archived notes remain searchable (the pre-layered FTS path never
//   filtered archived notes — includeArchived: true preserves that);
// - attachment chunks with includeInAIContext = false never reach the
//   AI-facing output.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search/search_service.dart';
import 'package:note_synapse/services/search/search_text_normalizer.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import '../search/ocr_test_stubs.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

/// Records the size of every getNotesByIds id-list, so tests can pin the
/// tool's candidate cap (applied BEFORE loading full note rows).
class _SpyDatabaseService extends DatabaseService {
  _SpyDatabaseService() : super.createNew();

  final List<int> getNotesByIdsCallSizes = [];

  @override
  Future<List<Note>> getNotesByIds(List<String> noteIds) {
    getNotesByIdsCallSizes.add(noteIds.length);
    return super.getNotesByIds(noteIds);
  }
}

void main() {
  late _SpyDatabaseService db;
  late DataChangeNotifier notifier;
  late NoteIndexService indexer;
  late SearchService search;
  late NoteSearchTool tool;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() async {
    await resetForTesting();
    db = _SpyDatabaseService();
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
    getIt.registerSingleton<DatabaseService>(db);
    getIt.registerSingleton<SearchService>(search);
    tool = NoteSearchTool();
  });

  tearDown(() async {
    indexer.dispose();
    await db.close();
    await resetForTesting();
  });

  Note buildNote(
    String id, {
    String? title,
    String? content,
    List<String> tags = const [],
    bool isArchived = false,
  }) {
    return Note(
      id: id,
      title: title ?? 'Note $id',
      content: content ?? 'Body of note $id.',
      type: NoteType.note,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      tags: tags,
      isArchived: isArchived,
    );
  }

  /// Flushes pending debounced reindexes and completes the backfill, so the
  /// global backfill-complete flag is set and the FTS path is live.
  Future<void> indexAll() async {
    await indexer.flushPending();
    await indexer.backfillAll();
    expect(
      await indexer.isBackfillComplete(),
      isTrue,
      reason: 'test setup expects a completed backfill',
    );
  }

  test(
    'returns ranked results with real snippets in the legacy schema',
    () async {
      await db.insertNote(
        buildNote(
          'bodyNote',
          title: 'Field observations',
          content:
              'During the long expedition through the wetlands we counted many '
              'animals and eventually spotted a quokka near the far end of the '
              'trail, alongside dozens of unrelated species we catalogued in '
              'exhaustive detail for the survey report.',
          tags: ['fieldwork'],
        ),
      );
      await db.insertNote(buildNote('titleNote', title: 'Quokka research'));
      await indexAll();

      final result = await tool.execute({'query': 'quokka'}) as List;

      // Ranked: title (meta chunk) hit outranks the body hit.
      expect(result.map((e) => e['id']), ['titleNote', 'bodyNote']);

      // Output schema unchanged: exactly id / title / snippet / tags.
      for (final entry in result) {
        expect((entry as Map).keys.toSet(), {'id', 'title', 'snippet', 'tags'});
      }
      expect(result.first['title'], 'Quokka research');
      expect(result.last['tags'], ['fieldwork']);

      // Real ranked snippet from the best chunk, not a content-head slice: the
      // body note's match sits ~200 chars in, past the old head-snippet window.
      final bodySnippet = (result.last['snippet'] as String).toLowerCase();
      expect(bodySnippet, contains('quokka'));
    },
  );

  test('tag filter (AND semantics) applies over search results', () async {
    await db.insertNote(
      buildNote(
        'both',
        content: 'wiki source overview for machine learning',
        tags: ['wiki-source-ai', 'reference'],
      ),
    );
    await db.insertNote(
      buildNote(
        'untagged',
        content: 'wiki source overview for neural networks',
        tags: ['reference'],
      ),
    );
    await db.insertNote(
      buildNote(
        'tagOnly',
        content: 'meeting notes and project planning',
        tags: ['wiki-source-ai'],
      ),
    );
    await indexAll();

    final result =
        await tool.execute({
              'query': 'wiki source',
              'tags': ['wiki-source-ai', 'reference'],
            })
            as List;

    expect(result.map((e) => e['id']), ['both']);
  });

  test(
    'archived notes stay searchable (pre-layered behavior preserved)',
    () async {
      await db.insertNote(buildNote('live', content: 'ocelot sighting live'));
      await db.insertNote(
        buildNote(
          'archived',
          content: 'ocelot sighting archived',
          isArchived: true,
        ),
      );
      await indexAll();

      final result = await tool.execute({'query': 'ocelot'}) as List;
      expect(result.map((e) => e['id']).toSet(), {'live', 'archived'});
    },
  );

  test(
    'attachment chunks with includeInAIContext=false never reach the output',
    () async {
      await db.insertNote(buildNote('host', content: 'nothing special here'));
      await db.insertNote(
        buildNote('plain', content: 'a note body mentioning pangolin directly'),
      );
      await indexAll();

      // Seed an attachment_text chunk manually (extraction is Step 11): a raw
      // attachments row with includeInAIContext = 0, a search_chunks row, and
      // its chunks_fts row — bypassing hooks so no reindex rewrites it.
      final raw = await db.database;
      await raw.insert('attachments', {
        'id': 'att1',
        'noteId': 'host',
        'filePath': 'files/report.pdf',
        'fileName': 'report.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 0,
      });
      const chunkText = 'Extracted PDF text about pangolin habitats.';
      final chunkId = await raw.insert('search_chunks', {
        'chunkKey': 'host:attachment_text:att1:3000',
        'noteId': 'host',
        'sourceType': 'attachment_text',
        'sourceId': 'att1',
        'page': 4,
        'seq': 3000,
        'text': chunkText,
        'contentHash': 'manual',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await raw.rawInsert(
        'INSERT INTO chunks_fts(docid, content) VALUES(?, ?)',
        [chunkId, normalizeForIndex(chunkText)],
      );

      // Sanity: the user-audience search DOES see the seeded chunk.
      final userResponse = await search.searchFused('pangolin');
      expect(
        userResponse.results.map((r) => r.noteId).toSet(),
        containsAll({'host', 'plain'}),
      );

      // The AI-facing tool must not: the opted-out attachment's note never
      // appears, and no snippet leaks the extracted text.
      final result = await tool.execute({'query': 'pangolin'}) as List;
      expect(result.map((e) => e['id']), ['plain']);
      for (final entry in result) {
        expect(entry['snippet'], isNot(contains('habitats')));
      }
    },
  );

  test(
    'tag filter still finds tagged notes ranked below 120 untagged chunks',
    () async {
      // 120 high-scoring untagged chunks would fill a naive top-100 slice;
      // the two tagged notes carry a single low-ranked hit each. A
      // filter-after-truncation implementation would lose them.
      for (var i = 0; i < 120; i++) {
        await db.insertNote(
          buildNote('untagged$i', content: 'heron heron heron'),
        );
      }
      await db.insertNote(
        buildNote(
          'taggedA',
          content:
              'A very long field report describing the expedition in '
              'exhaustive detail across many unrelated observations until '
              'finally a single heron appears near the end of the trail '
              'among the other catalogued species of the survey area.',
          tags: ['wading'],
        ),
      );
      await db.insertNote(
        buildNote(
          'taggedB',
          content:
              'Another lengthy journal entry wandering through many topics '
              'and observations before it finally mentions a heron once, '
              'buried deep within the closing paragraph of the text.',
          tags: ['wading'],
        ),
      );
      await indexAll();

      // Sanity: without the tag filter the tagged notes rank beyond the top
      // slice (the untagged notes exhaust it).
      final unfiltered = await tool.execute({'query': 'heron'}) as List;
      expect(unfiltered.map((e) => e['id']), isNot(contains('taggedA')));
      expect(unfiltered.map((e) => e['id']), isNot(contains('taggedB')));

      final result =
          await tool.execute({
                'query': 'heron',
                'tags': ['wading'],
              })
              as List;
      expect(result.map((e) => e['id']).toSet(), {'taggedA', 'taggedB'});
    },
  );

  test('substring fallback with a huge match set is capped before note loading '
      'and still outputs at most 50 entries', () async {
    await indexer.pause(); // Backfill stays incomplete -> substring path.
    final raw = await db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = raw.batch();
    for (var i = 0; i < 650; i++) {
      batch.insert('notes', {
        'id': 'match$i',
        'title': 'Capybara sighting $i',
        'content': 'capybara field note $i',
        'type': 'note',
        'createdAt': now + i,
        'updatedAt': now + i,
        'pinned': 0,
        'isArchived': 0,
      });
    }
    await batch.commit(noResult: true);

    final result = await tool.execute({'query': 'capybara'}) as List;
    expect(result, hasLength(50));
    // The candidate list was capped BEFORE fetching notes: exactly one
    // getNotesByIds call, with the 200-id no-tags cap — not all 650.
    expect(db.getNotesByIdsCallSizes, [200]);
  });

  test(
    'DatabaseService.getNotesByIds chunks the IN() list (1200 ids)',
    () async {
      final raw = await db.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final batch = raw.batch();
      final ids = <String>[];
      for (var i = 0; i < 1200; i++) {
        final id = 'bulk$i';
        ids.add(id);
        batch.insert('notes', {
          'id': id,
          'title': 'Bulk note $i',
          'content': 'bulk body $i',
          'type': 'note',
          'createdAt': now,
          'updatedAt': now,
          'pinned': 0,
          'isArchived': 0,
        });
      }
      await batch.commit(noResult: true);

      // 1200 ids exceed SQLite's default 999-variable limit: only a chunked
      // IN() can return every note.
      final notes = await db.getNotesByIds(ids);
      expect(notes, hasLength(1200));
      expect({for (final n in notes) n.id}, ids.toSet());
    },
  );
}
