// Tests for the fusion layer of SearchService (plan §2.3): pinned RRF math,
// semantic retrieval through the vector index with the SAME visibility /
// audience / tag filters as lexical, the session-scoped query-embedding
// cache, and the floor rule — a failing or slow semantic layer never breaks
// searchFused. Real sqlite via sqflite_common_ffi.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
import 'package:note_synapse/services/search/bm25.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider_registry.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search/search_service.dart';
import 'package:note_synapse/services/search/vector_search.dart';

import 'note_index_embed_stage_test.dart' show FakeEmbeddingProvider;
import 'ocr_test_stubs.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

/// Provider whose embedQuery is test-controlled (slow / failing / counted).
class _ScriptedProvider extends FakeEmbeddingProvider {
  _ScriptedProvider({required super.providerKey});

  Duration queryDelay = Duration.zero;
  Object? queryError;

  /// Query vector to return, overriding the deterministic default.
  Float32List? queryVector;

  @override
  Future<Float32List> embedQuery(String query) async {
    queryCalls++;
    if (queryDelay > Duration.zero) await Future<void>.delayed(queryDelay);
    final error = queryError;
    if (error != null) throw error;
    return queryVector ?? Float32List.fromList([1, 0, 0, 0]);
  }
}

SearchResultChunk _chunk(String chunkKey) => SearchResultChunk(
  snippet: const Snippet(
    text: 'snippet',
    matches: [],
    truncatedStart: false,
    truncatedEnd: false,
  ),
  sourceType: 'figure',
  chunkKey: chunkKey,
);

/// A layer result whose reported chunk list is [chunks] (best = first).
NoteSearchResult _resultWithChunks(
  String noteId,
  List<SearchResultChunk> chunks, {
  required SearchLayer layer,
}) => NoteSearchResult(
  noteId: noteId,
  score: 1.0,
  best: chunks.first,
  layers: {layer},
  chunks: chunks,
);

NoteSearchResult _result(String noteId, {double score = 1.0}) =>
    NoteSearchResult(
      noteId: noteId,
      score: score,
      best: const SearchResultChunk(
        snippet: Snippet(
          text: 'snippet',
          matches: [],
          truncatedStart: false,
          truncatedEnd: false,
        ),
        sourceType: 'note_body',
      ),
      layers: const {SearchLayer.lexical},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  group('RRF math (pinned)', () {
    test('score = Σ 1/(60 + rank), rank 1-based per layer', () {
      // a: lexical #1 only. b: semantic #1 only. c: lexical #2 + semantic #2.
      final fused = SearchService.fuseRrf(
        [_result('a'), _result('c')],
        [_result('b'), _result('c')],
      );
      double rrf(List<int> ranks) =>
          ranks.fold(0.0, (sum, rank) => sum + 1 / (60 + rank));

      final byId = {for (final r in fused) r.noteId: r};
      expect(byId['a']!.score, closeTo(rrf([1]), 1e-12));
      expect(byId['b']!.score, closeTo(rrf([1]), 1e-12));
      expect(byId['c']!.score, closeTo(rrf([2, 2]), 1e-12));
      // c wins: it is the only note both layers ranked.
      expect(fused.first.noteId, 'c');
      // a and b tie exactly; the lexical-ranked note sorts first.
      expect([for (final r in fused) r.noteId], ['c', 'a', 'b']);
    });

    test('tags results with the layers that contributed them', () {
      final semantic = NoteSearchResult(
        noteId: 'both',
        score: 0.9,
        best: _result('both').best,
        layers: const {SearchLayer.semantic},
      );
      final fused = SearchService.fuseRrf([_result('both')], [semantic]);
      expect(fused.single.layers, {SearchLayer.lexical, SearchLayer.semantic});
    });

    test('semantic-only notes keep their own snippet; shared notes take the '
        'lexical best chunk (highlight ranges)', () {
      final lexicalHit = NoteSearchResult(
        noteId: 'shared',
        score: 1,
        best: const SearchResultChunk(
          snippet: Snippet(
            text: 'lexical text',
            matches: [SnippetMatch(0, 7)],
            truncatedStart: false,
            truncatedEnd: false,
          ),
          sourceType: 'note_body',
        ),
        layers: const {SearchLayer.lexical},
      );
      final semanticHit = NoteSearchResult(
        noteId: 'shared',
        score: 1,
        best: const SearchResultChunk(
          snippet: Snippet(
            text: 'semantic text',
            matches: [],
            truncatedStart: false,
            truncatedEnd: false,
          ),
          sourceType: 'note_body',
        ),
        layers: const {SearchLayer.semantic},
      );
      final semanticOnly = NoteSearchResult(
        noteId: 'sem-only',
        score: 1,
        best: const SearchResultChunk(
          snippet: Snippet(
            text: 'headline chunk',
            matches: [],
            truncatedStart: false,
            truncatedEnd: false,
          ),
          sourceType: 'note_body',
        ),
        layers: const {SearchLayer.semantic},
      );
      final fused = SearchService.fuseRrf(
        [lexicalHit],
        [semanticHit, semanticOnly],
      );
      final byId = {for (final r in fused) r.noteId: r};
      expect(byId['shared']!.best.snippet.text, 'lexical text');
      expect(byId['shared']!.best.snippet.matches, hasLength(1));
      expect(byId['sem-only']!.best.snippet.text, 'headline chunk');
    });

    test('an empty layer leaves the other layer order intact', () {
      final fused = SearchService.fuseRrf([
        _result('a'),
        _result('b'),
        _result('c'),
      ], const []);
      expect([for (final r in fused) r.noteId], ['a', 'b', 'c']);
    });

    test('a note in BOTH layers keeps the UNION of their chunk lists, '
        'deduped by chunkKey and capped at chunksPerNote', () {
      // The multimodal case: a figure matched only by image embedding lives
      // in the semantic layer's chunk list. Keeping the lexical list alone
      // would drop it the moment any other chunk of the note matched text.
      final lexicalHit = _resultWithChunks('paper', [
        _chunk('paper:figure:att1:1000'),
        _chunk('paper:figure:att1:2000'),
      ], layer: SearchLayer.lexical);
      final semanticHit = _resultWithChunks('paper', [
        _chunk('paper:figure:att1:9000'), // Semantic-only figure.
        _chunk('paper:figure:att1:1000'), // Duplicate of the lexical best.
      ], layer: SearchLayer.semantic);

      final fused = SearchService.fuseRrf(
        [lexicalHit],
        [semanticHit],
        chunksPerNote: 4,
      );

      expect(
        [for (final c in fused.single.chunks) c.chunkKey],
        [
          'paper:figure:att1:1000',
          'paper:figure:att1:9000',
          'paper:figure:att1:2000',
        ],
        reason:
            'lexical best stays first, then the layers interleave; the '
            'duplicate chunkKey appears once',
      );
      expect(
        fused.single.best.chunkKey,
        fused.single.chunks.first.chunkKey,
        reason: 'best == chunks.first is part of the contract',
      );
    });

    test('the merged chunk list never exceeds chunksPerNote', () {
      final fused = SearchService.fuseRrf(
        [
          _resultWithChunks('paper', [
            _chunk('lex-1'),
            _chunk('lex-2'),
          ], layer: SearchLayer.lexical),
        ],
        [
          _resultWithChunks('paper', [
            _chunk('sem-1'),
            _chunk('sem-2'),
          ], layer: SearchLayer.semantic),
        ],
        chunksPerNote: 2,
      );
      expect(
        [for (final c in fused.single.chunks) c.chunkKey],
        ['lex-1', 'sem-1'],
      );
    });

    test('the default budget of 1 keeps exactly the lexical best', () {
      final fused = SearchService.fuseRrf(
        [
          _resultWithChunks('paper', [
            _chunk('lex-1'),
          ], layer: SearchLayer.lexical),
        ],
        [
          _resultWithChunks('paper', [
            _chunk('sem-1'),
          ], layer: SearchLayer.semantic),
        ],
      );
      expect([for (final c in fused.single.chunks) c.chunkKey], ['lex-1']);
    });
  });

  group('searchFused end-to-end', () {
    late DatabaseService db;
    late DataChangeNotifier notifier;
    late NoteIndexService indexer;
    late VectorSearch vectorSearch;
    late EmbeddingProviderRegistry registry;
    late _ScriptedProvider provider;
    late SearchService search;

    const config = EmbeddingProviderConfig(
      type: 'fake',
      modelName: 'm',
      displayName: 'Fake',
      dimensions: 4,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      db = DatabaseService.createNew();
      await db.database;
      notifier = DataChangeNotifier();
      provider = _ScriptedProvider(providerKey: config.providerKey);
      registry = EmbeddingProviderRegistry(providerBuilder: (_) => provider);
      await registry.setActiveConfig(config);
      vectorSearch = VectorSearch(db);
      indexer = NoteIndexService(
        db,
        changeNotifier: notifier,
        debounceDelay: const Duration(milliseconds: 20),
        ocrExtractor: stubOcrExtractor(db),
        figureExtractor: stubFigureExtractor(),
        embeddingRegistry: registry,
        vectorSearch: vectorSearch,
        embedConsentCheck: (_) async => true,
      );
      search = SearchService(
        db,
        indexer,
        notesProvider: () => db.getAllNotes(),
        embeddingRegistry: registry,
        vectorSearch: vectorSearch,
      );
    });

    tearDown(() async {
      indexer.dispose();
      vectorSearch.dispose();
      await db.close();
    });

    Note buildNote(
      String id,
      String content, {
      bool isArchived = false,
      List<String> tags = const [],
    }) => Note(
      id: id,
      title: 'Note $id',
      content: content,
      type: NoteType.note,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      isArchived: isArchived,
      tags: tags,
    );

    /// Points the query embedding at a specific chunk's stored vector so the
    /// semantic layer deterministically retrieves that chunk first.
    Future<void> aimQueryAt(String noteId, {String? sourceType}) async {
      final raw = await db.database;
      final rows = await raw.rawQuery(
        'SELECT e.vector FROM chunk_embeddings e '
        'JOIN search_chunks c ON c.id = e.chunkId '
        'WHERE c.noteId = ? AND c.sourceType = ? LIMIT 1',
        [noteId, sourceType ?? 'note_body'],
      );
      provider.queryVector = decodeVectorFloat32Le(
        rows.first['vector'] as Uint8List,
      );
    }

    test('semantic hits join lexical hits and fusion re-ranks', () async {
      await db.insertNote(buildNote('lex', 'unmistakable lexical keyword'));
      await db.insertNote(buildNote('sem', 'entirely unrelated wording'));
      // flushPending fires the debounced reindexes insertNote scheduled
      // (backfillAll defers notes with a pending timer); backfillAll then
      // sets the global chunks flag the semantic layer gates on.
      await indexer.flushPending();
      await indexer.backfillAll();
      await aimQueryAt('sem');

      final lexicalOnly = await search.searchLexical('unmistakable');
      expect([for (final r in lexicalOnly.results) r.noteId], ['lex']);

      final fused = await search.searchFused('unmistakable');
      final ids = [for (final r in fused.results) r.noteId];
      expect(ids, containsAll(['lex', 'sem']));
      final semResult = fused.results.firstWhere((r) => r.noteId == 'sem');
      expect(semResult.layers, contains(SearchLayer.semantic));
      // Semantic-only results still carry a snippet (best chunk text).
      expect(semResult.best.snippet.text, isNotEmpty);
    });

    test('semantic results respect the archived visibility filter', () async {
      await db.insertNote(
        buildNote('arch', 'archived semantic content', isArchived: true),
      );
      await db.insertNote(buildNote('plain', 'lexical keyword here'));
      // flushPending fires the debounced reindexes insertNote scheduled
      // (backfillAll defers notes with a pending timer); backfillAll then
      // sets the global chunks flag the semantic layer gates on.
      await indexer.flushPending();
      await indexer.backfillAll();
      await aimQueryAt('arch');

      final hidden = await search.searchFused('keyword');
      expect([
        for (final r in hidden.results) r.noteId,
      ], isNot(contains('arch')));

      final shown = await search.searchFused(
        'keyword',
        filter: const NoteFilterContext(includeArchived: true),
      );
      expect([for (final r in shown.results) r.noteId], contains('arch'));
    });

    test('semantic results respect requiredTags (AND semantics)', () async {
      await db.insertNote(
        buildNote('tagged', 'semantic target content', tags: ['alpha']),
      );
      await db.insertNote(buildNote('plain', 'lexical keyword here'));
      // flushPending fires the debounced reindexes insertNote scheduled
      // (backfillAll defers notes with a pending timer); backfillAll then
      // sets the global chunks flag the semantic layer gates on.
      await indexer.flushPending();
      await indexer.backfillAll();
      await aimQueryAt('tagged');

      final filtered = await search.searchFused(
        'keyword',
        filter: const NoteFilterContext(requiredTags: ['beta']),
      );
      expect([
        for (final r in filtered.results) r.noteId,
      ], isNot(contains('tagged')));

      final matching = await search.searchFused(
        'keyword',
        filter: const NoteFilterContext(requiredTags: ['alpha']),
      );
      expect([for (final r in matching.results) r.noteId], contains('tagged'));
    });

    test('ai audience excludes semantic hits from includeInAIContext=false '
        'attachments', () async {
      await db.insertNote(buildNote('n1', 'lexical keyword here'));
      await db.insertNote(buildNote('n2', 'carrier note'));
      final raw = await db.database;
      await raw.insert('attachments', {
        'id': 'a1',
        'noteId': 'n2',
        'filePath': '/tmp/a1.pdf',
        'fileName': 'a1.pdf',
        'fileType': 'pdf',
        'isRelativePath': 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });
      await raw.insert('search_chunks', {
        'chunkKey': 'n2:attachment_text:a1:1',
        'noteId': 'n2',
        'sourceType': 'attachment_text',
        'sourceId': 'a1',
        'page': 3,
        'seq': 1,
        'text': 'attachment derived semantic content',
        'meta': null,
        'contentHash': 'ha1',
        'updatedAt': 0,
      });
      await indexer.flushPending();
      await indexer.backfillAll();
      // Leave the attachment chunk as n2's ONLY chunk, so n2 can enter the
      // semantic layer only through it.
      await raw.rawDelete(
        'DELETE FROM chunk_embeddings WHERE chunkId IN (SELECT id FROM '
        "search_chunks WHERE noteId = 'n2' AND sourceType != 'attachment_text')",
      );
      await raw.delete(
        'search_chunks',
        where: "noteId = 'n2' AND sourceType != 'attachment_text'",
      );
      await aimQueryAt('n2', sourceType: 'attachment_text');

      final userView = await search.searchFused('nonmatching-lexical-term');
      expect([for (final r in userView.results) r.noteId], contains('n2'));
      final n2 = userView.results.firstWhere((r) => r.noteId == 'n2');
      expect(n2.best.sourceType, 'attachment_text');
      expect(n2.attachmentId, 'a1');
      expect(n2.page, 3);

      // Flip the flag: the AI audience must no longer see that chunk — and
      // with no other chunk, n2 leaves the semantic layer entirely.
      await raw.update(
        'attachments',
        {'includeInAIContext': 0},
        where: 'id = ?',
        whereArgs: ['a1'],
      );
      final aiView = await search.searchFused(
        'nonmatching-lexical-term',
        audience: SearchAudience.ai,
      );
      expect([for (final r in aiView.results) r.noteId], isNot(contains('n2')));
    });

    test(
      'query embeddings are cached per folded query (session LRU)',
      () async {
        await db.insertNote(buildNote('n1', 'cache probe content'));
        // flushPending fires the debounced reindexes insertNote scheduled
        // (backfillAll defers notes with a pending timer); backfillAll then
        // sets the global chunks flag the semantic layer gates on.
        await indexer.flushPending();
        await indexer.backfillAll();

        await search.searchFused('Cache Probe');
        expect(provider.queryCalls, 1);
        await search.searchFused('Cache Probe');
        expect(provider.queryCalls, 1, reason: 'identical query is cached');
        await search.searchFused('cache probe');
        expect(provider.queryCalls, 1, reason: 'case folding shares the entry');
        await search.searchFused('different query');
        expect(provider.queryCalls, 2);
      },
    );

    test(
      'the query-embedding cache evicts least-recently-used at the cap',
      () async {
        await db.insertNote(buildNote('n1', 'cache probe content'));
        await indexer.flushPending();
        await indexer.backfillAll();

        // Fill the cache exactly to its cap (the first query is the oldest).
        const cap = 32;
        for (var i = 0; i < cap; i++) {
          await search.searchFused('query number $i');
        }
        expect(provider.queryCalls, cap);

        // Re-using query 0 must both hit the cache AND make it the most
        // recently used, so the next insert evicts query 1 instead.
        await search.searchFused('query number 0');
        expect(provider.queryCalls, cap, reason: 'still cached');

        await search.searchFused('one query too many');
        expect(provider.queryCalls, cap + 1);

        await search.searchFused('query number 1');
        expect(
          provider.queryCalls,
          cap + 2,
          reason: 'the least-recently-used entry was evicted',
        );
        await search.searchFused('query number 0');
        expect(
          provider.queryCalls,
          cap + 2,
          reason: 'the refreshed entry survived the eviction',
        );
      },
    );

    test(
      'embed failure leaves the lexical results standing (floor rule)',
      () async {
        await db.insertNote(buildNote('n1', 'floor keyword content'));
        // flushPending fires the debounced reindexes insertNote scheduled
        // (backfillAll defers notes with a pending timer); backfillAll then
        // sets the global chunks flag the semantic layer gates on.
        await indexer.flushPending();
        await indexer.backfillAll();
        provider.queryError = const EmbeddingProviderException(
          'network down',
          isTransient: true,
        );

        final response = await search.searchFused('floor');
        expect([for (final r in response.results) r.noteId], ['n1']);
        expect(response.results.single.layers, {SearchLayer.lexical});
      },
    );

    test('a slow query embedding times out and lexical order stands', () async {
      await db.insertNote(buildNote('n1', 'timeout keyword content'));
      // flushPending fires the debounced reindexes insertNote scheduled
      // (backfillAll defers notes with a pending timer); backfillAll then
      // sets the global chunks flag the semantic layer gates on.
      await indexer.flushPending();
      await indexer.backfillAll();
      provider.queryDelay = const Duration(milliseconds: 400);

      final fast = SearchService(
        db,
        indexer,
        notesProvider: () => db.getAllNotes(),
        embeddingRegistry: registry,
        vectorSearch: vectorSearch,
        semanticTimeout: const Duration(milliseconds: 20),
      );
      final stopwatch = Stopwatch()..start();
      final response = await fast.searchFused('timeout');
      stopwatch.stop();
      expect([for (final r in response.results) r.noteId], ['n1']);
      expect(response.results.single.layers, {SearchLayer.lexical});
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 350)));
    });

    test(
      'no serving provider (switch in flight / None) → lexical only',
      () async {
        await db.insertNote(buildNote('n1', 'serving keyword content'));
        // flushPending fires the debounced reindexes insertNote scheduled
        // (backfillAll defers notes with a pending timer); backfillAll then
        // sets the global chunks flag the semantic layer gates on.
        await indexer.flushPending();
        await indexer.backfillAll();
        expect(registry.servingProviderKey, config.providerKey);
        await aimQueryAt('n1');

        await registry.revokeServing();
        final callsBefore = provider.queryCalls;
        final response = await search.searchFused('serving');
        expect(provider.queryCalls, callsBefore, reason: 'no query embedded');
        expect(response.results.single.layers, {SearchLayer.lexical});
      },
    );

    test('searchFused keeps the substring fallback flag from the lexical '
        'layer', () async {
      await db.insertNote(buildNote('n1', 'fallback keyword content'));
      // No backfill: the global chunks flag is unset → substring fallback.
      final response = await search.searchFused('fallback');
      expect(response.usedSubstringFallback, isTrue);
      expect([for (final r in response.results) r.noteId], ['n1']);
    });

    test('the ticket of a fused response is the caller ticket', () async {
      await db.insertNote(buildNote('n1', 'ticket keyword content'));
      // flushPending fires the debounced reindexes insertNote scheduled
      // (backfillAll defers notes with a pending timer); backfillAll then
      // sets the global chunks flag the semantic layer gates on.
      await indexer.flushPending();
      await indexer.backfillAll();
      final ticket = search.takeTicket();
      final response = await search.searchFused('ticket', ticket: ticket);
      expect(identical(response.ticket, ticket), isTrue);
      expect(search.isCurrent(response.ticket), isTrue);
    });
  });
}
