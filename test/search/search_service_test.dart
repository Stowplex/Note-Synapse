// Integration tests for SearchService (plan §1.4/§1.5): end-to-end
// index-then-search over real sqlite (sqflite_common_ffi), ranking, grouping,
// tiebreak pinning, archived/audience filtering, fallback rules, sequence
// tickets, and the startup backfill trigger. Follows the
// note_index_service_test.dart harness patterns.

import 'dart:io';
import 'dart:math' as math;

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
import 'package:note_synapse/utils/note_text_match.dart';

import 'ocr_test_stubs.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

class _CountingIndexService extends NoteIndexService {
  _CountingIndexService(super.db, {super.changeNotifier, super.debounceDelay});

  int ensureBackfilledCalls = 0;

  @override
  Future<void> ensureBackfilled() {
    ensureBackfilledCalls++;
    return super.ensureBackfilled();
  }
}

void main() {
  late DatabaseService db;
  late DataChangeNotifier notifier;
  late NoteIndexService indexer;
  late SearchService search;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() async {
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
  });

  tearDown(() async {
    indexer.dispose();
    await db.close();
  });

  Note buildNote(
    String id, {
    String? title,
    String? content,
    List<String> tags = const [],
    bool pinned = false,
    bool isArchived = false,
    DateTime? createdAt,
  }) {
    return Note(
      id: id,
      title: title ?? 'Note $id',
      content: content ?? 'Body of note $id.',
      type: NoteType.note,
      createdAt: createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      tags: tags,
      pinned: pinned,
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

  List<String> noteIds(SearchResponse response) => [
    for (final r in response.results) r.noteId,
  ];

  /// Inserts a chunk plus its `chunks_fts` row (normalized content, docid =
  /// search_chunks.id), the way the indexer writes them. Lets a test seed
  /// chunk kinds the note indexer alone cannot produce (figures, attachment
  /// pages) and control their DOCID ORDER, which is what the unordered
  /// runaway cap in searchChunksLexical keys off.
  Future<int> insertChunk({
    required String chunkKey,
    required String noteId,
    required String sourceType,
    required String text,
    String? sourceId,
    int? page,
    int seq = 0,
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
      'contentHash': 'hash-$chunkKey',
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await raw.rawInsert('INSERT INTO chunks_fts(docid, content) VALUES(?, ?)', [
      chunkId,
      normalizeForIndex(text),
    ]);
    return chunkId;
  }

  group('end-to-end index-then-search', () {
    test(
      'English: FTS path returns ranked results with highlight snippets',
      () async {
        await db.insertNote(
          buildNote(
            'n1',
            title: 'Trip planning',
            content: 'We should visit the alpine lakes next summer.',
          ),
        );
        await db.insertNote(
          buildNote(
            'n2',
            title: 'Recipes',
            content: 'Pasta with garlic and olive oil.',
          ),
        );
        await indexAll();

        final response = await search.searchLexical('alpine');
        expect(response.usedSubstringFallback, isFalse);
        expect(noteIds(response), ['n1']);
        final best = response.results.single.best;
        expect(best.sourceType, 'note_body');
        expect(best.snippet.text.toLowerCase(), contains('alpine'));
        expect(
          best.snippet.matches,
          isNotEmpty,
          reason: 'snippet must carry highlight ranges',
        );
        expect(response.results.single.layers, {SearchLayer.lexical});
        expect(response.results.single.score, greaterThan(0));
      },
    );

    test(
      'Chinese: substring-equivalent recall through the full stack',
      () async {
        final note = buildNote(
          'zh1',
          title: '学习笔记',
          content: '我们正在构建中文搜索引擎的索引。',
        );
        await db.insertNote(note);
        await indexAll();

        // Every query below matches the note as a raw substring; the FTS path
        // (bigram phrases / single-char prefix) must agree — no fallback.
        for (final query in ['搜索', '文搜', '中文搜索', '索']) {
          expect(
            matchesSubstringQuery(note, query),
            isTrue,
            reason: 'fixture sanity: "$query" is a substring match',
          );
          final response = await search.searchLexical(query);
          expect(
            response.usedSubstringFallback,
            isFalse,
            reason: '"$query" must be served by FTS',
          );
          expect(noteIds(response), [
            'zh1',
          ], reason: '"$query" must recall the note through FTS');
        }

        // Chinese snippets highlight the whole CJK run, not bigrams.
        final response = await search.searchLexical('搜索');
        final snippet = response.results.single.best.snippet;
        final match = snippet.matches.first;
        expect(snippet.text.substring(match.start, match.end), '搜索');
      },
    );

    test('searchFused is lexical for now (same results, same shape)', () async {
      await db.insertNote(buildNote('n1', content: 'fusion target text'));
      await indexAll();
      final lexical = await search.searchLexical('fusion');
      final fused = await search.searchFused('fusion');
      expect(noteIds(fused), noteIds(lexical));
      expect(fused.usedSubstringFallback, isFalse);
    });
  });

  group('ranking', () {
    test('title (meta chunk) hit outranks a body hit', () async {
      await db.insertNote(
        buildNote(
          'bodyNote',
          title: 'Field observations',
          content:
              'During the long expedition through the wetlands we counted many '
              'animals and eventually spotted a quokka near the far end of the '
              'trail, alongside dozens of unrelated species we catalogued in '
              'exhaustive detail for the survey report.',
        ),
      );
      await db.insertNote(buildNote('titleNote', title: 'Quokka research'));
      await indexAll();

      final response = await search.searchLexical('quokka');
      expect(noteIds(response), ['titleNote', 'bodyNote']);
      expect(response.results.first.best.sourceType, 'meta');
    });

    test(
      'grouping bonus: extra hits add 0.1*ln(1+extra) exactly once',
      () async {
        const sharedSection = '# One\n\nwalrus paragraph text here.\n\n';
        await db.insertNote(
          buildNote(
            'single',
            title: 'Aaaa',
            content: '$sharedSection# Two\n\nnothing else relevant said.',
          ),
        );
        await db.insertNote(
          buildNote(
            'double',
            title: 'Bbbb',
            content:
                '$sharedSection# Two\n\nthe walrus appears once more in '
                'this considerably longer second section paragraph of text.',
          ),
        );
        await indexAll();

        final response = await search.searchLexical('walrus');
        expect(noteIds(response), ['double', 'single']);
        final doubleScore = response.results[0].score;
        final singleScore = response.results[1].score;
        // Best chunks are textually identical, so their BM25 scores tie; the
        // only difference is the one-time extra-hit bonus.
        expect(doubleScore, closeTo(singleScore + 0.1 * math.log(2), 1e-9));
      },
    );

    test(
      'tiebreak pin: equal BM25 orders higher docid (newer chunk) first',
      () async {
        const sameBody = 'zebra unique body text here.';
        await db.insertNote(
          buildNote('older', title: 'Aaaa', content: sameBody),
        );
        await indexer.flushPending();
        await db.insertNote(
          buildNote('newer', title: 'Bbbb', content: sameBody),
        );
        await indexAll();

        // Identical chunk text => identical BM25; 'newer' was indexed later so
        // its chunk has the higher docid and must sort first. Pinned: score
        // desc, then docid DESC (newer first).
        final response = await search.searchLexical('zebra');
        expect(noteIds(response), ['newer', 'older']);
      },
    );
  });

  group('visibility filters', () {
    test(
      'archived notes are excluded by default and included on request',
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

        final defaultScope = await search.searchLexical('ocelot');
        expect(noteIds(defaultScope), ['live']);

        final withArchived = await search.searchLexical(
          'ocelot',
          filter: const NoteFilterContext(includeArchived: true),
        );
        expect(noteIds(withArchived), containsAll(['live', 'archived']));
        expect(withArchived.results, hasLength(2));
      },
    );

    test(
      'audience=ai excludes attachment chunks with includeInAIContext=false',
      () async {
        await db.insertNote(buildNote('host', content: 'nothing special here'));
        await db.insertNote(
          buildNote(
            'plain',
            content: 'a note body mentioning pangolin directly',
          ),
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

        // The user sees everything, including the deep-link provenance.
        final userResponse = await search.searchLexical('pangolin');
        expect(noteIds(userResponse), containsAll(['host', 'plain']));
        final hostResult = userResponse.results.firstWhere(
          (r) => r.noteId == 'host',
        );
        expect(hostResult.best.sourceType, 'attachment_text');
        expect(hostResult.attachmentId, 'att1');
        expect(hostResult.page, 4);

        // The AI only sees the note-body hit; the opted-out attachment chunk is
        // filtered (note-born chunks are always allowed).
        final aiResponse = await search.searchLexical(
          'pangolin',
          audience: SearchAudience.ai,
        );
        expect(aiResponse.usedSubstringFallback, isFalse);
        expect(noteIds(aiResponse), ['plain']);
      },
    );

    test('archived chunks beyond the top slice do not starve lower-ranked live '
        'notes (paged visibility filtering)', () async {
      // BM25 over all-term chunks grows with repetition count, so:
      // liveTop (12x wombat) > each archived (3x) > liveLow (one hit in a
      // long body). 120 archived chunks would fill a naive top-100 slice.
      await db.insertNote(
        buildNote('liveTop', content: List.filled(12, 'wombat').join(' ')),
      );
      for (var i = 0; i < 120; i++) {
        await db.insertNote(
          buildNote(
            'arch$i',
            content: 'wombat wombat wombat',
            isArchived: true,
          ),
        );
      }
      await db.insertNote(
        buildNote(
          'liveLow',
          content:
              'A very long field report describing the expedition in '
              'exhaustive detail across many unrelated observations until '
              'finally a single wombat appears near the end of the trail '
              'among the other catalogued species of the survey area.',
        ),
      );
      await indexAll();

      // Sanity: with archived included (everything visible) the top-100
      // slice is exhausted by liveTop + 99 archived chunks — liveLow ranks
      // beyond it, which is exactly what a filter-after-truncate
      // implementation would starve in the default scope.
      final withArchived = await search.searchLexical(
        'wombat',
        filter: const NoteFilterContext(includeArchived: true),
      );
      expect(withArchived.results, hasLength(100));
      expect(noteIds(withArchived).first, 'liveTop');
      expect(noteIds(withArchived), isNot(contains('liveLow')));

      // Default (archived-excluded) search: BOTH live notes must survive,
      // served by FTS (no zero-hit substring rerun).
      final response = await search.searchLexical('wombat');
      expect(response.usedSubstringFallback, isFalse);
      expect(noteIds(response), ['liveTop', 'liveLow']);
    });

    test('ai-excluded attachment chunks beyond the top slice do not starve '
        'lower-ranked note-body hits', () async {
      await db.insertNote(
        buildNote('plainTop', content: List.filled(12, 'pangolin').join(' ')),
      );
      await db.insertNote(
        buildNote(
          'plainLow',
          content:
              'A very long journal entry wandering through many topics '
              'and observations before it finally mentions a pangolin '
              'once, buried deep within the closing paragraph of text.',
        ),
      );
      await db.insertNote(buildNote('host', content: 'nothing special here'));
      await indexAll();

      // 120 high-scoring attachment_text chunks whose attachment opted out
      // of AI context (seeded manually — extraction is Step 11).
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
      const chunkText = 'pangolin pangolin pangolin';
      for (var i = 0; i < 120; i++) {
        final chunkId = await raw.insert('search_chunks', {
          'chunkKey': 'host:attachment_text:att1:${3000 + i}',
          'noteId': 'host',
          'sourceType': 'attachment_text',
          'sourceId': 'att1',
          'page': i + 1,
          'seq': 3000 + i,
          'text': chunkText,
          'contentHash': 'manual$i',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        });
        await raw.rawInsert(
          'INSERT INTO chunks_fts(docid, content) VALUES(?, ?)',
          [chunkId, normalizeForIndex(chunkText)],
        );
      }

      // AI audience: the 120 excluded chunks must not consume top-N slots;
      // both note-body hits survive, served by FTS.
      final aiResponse = await search.searchLexical(
        'pangolin',
        audience: SearchAudience.ai,
      );
      expect(aiResponse.usedSubstringFallback, isFalse);
      expect(noteIds(aiResponse), ['plainTop', 'plainLow']);

      // Sanity: for the user audience everything is visible, so the
      // top-100 slice is exhausted by plainTop + the high-scoring hidden
      // chunks — plainLow ranks beyond it (the starvation setup). host's
      // many extra hits earn it the grouping bonus and first place.
      final userResponse = await search.searchLexical('pangolin');
      expect(noteIds(userResponse), ['host', 'plainTop']);
    });

    test(
      'audience=ai with only excluded hits falls back to substring (empty)',
      () async {
        await db.insertNote(buildNote('host', content: 'nothing special here'));
        await indexAll();

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
        const chunkText = 'Only this hidden chunk mentions capybara.';
        final chunkId = await raw.insert('search_chunks', {
          'chunkKey': 'host:attachment_text:att1:0',
          'noteId': 'host',
          'sourceType': 'attachment_text',
          'sourceId': 'att1',
          'page': 1,
          'seq': 0,
          'text': chunkText,
          'contentHash': 'manual',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        });
        await raw.rawInsert(
          'INSERT INTO chunks_fts(docid, content) VALUES(?, ?)',
          [chunkId, normalizeForIndex(chunkText)],
        );

        final aiResponse = await search.searchLexical(
          'capybara',
          audience: SearchAudience.ai,
        );
        // FTS produced zero visible hits -> substring rerun, which scans note
        // text only and finds nothing either.
        expect(aiResponse.usedSubstringFallback, isTrue);
        expect(aiResponse.results, isEmpty);
      },
    );
  });

  group('requiredTags filter', () {
    test('tagged notes ranked below 120 untagged chunks are still found '
        '(filter applies during accumulation, not after truncation)', () async {
      // 120 high-scoring untagged chunks would fill a naive top-100 slice;
      // the two tagged notes carry a single low-ranked hit each.
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

      // Sanity: unfiltered, the top-100 slice is exhausted by the untagged
      // high-scoring chunks — the tagged notes rank beyond it. This is
      // exactly what a filter-after-truncation implementation would lose.
      final unfiltered = await search.searchLexical('heron');
      expect(unfiltered.results, hasLength(100));
      expect(noteIds(unfiltered), isNot(contains('taggedA')));
      expect(noteIds(unfiltered), isNot(contains('taggedB')));

      // With requiredTags the filter runs during accumulation: both tagged
      // notes surface, served by FTS (no substring rerun).
      final filtered = await search.searchLexical(
        'heron',
        filter: const NoteFilterContext(requiredTags: ['wading']),
      );
      expect(filtered.usedSubstringFallback, isFalse);
      expect(noteIds(filtered).toSet(), {'taggedA', 'taggedB'});
    });

    test('AND semantics: a note must carry every required tag', () async {
      await db.insertNote(
        buildNote(
          'both',
          content: 'bittern habitat survey',
          tags: ['wading', 'rare'],
        ),
      );
      await db.insertNote(
        buildNote(
          'onlyWading',
          content: 'bittern habitat survey',
          tags: ['wading'],
        ),
      );
      await db.insertNote(
        buildNote(
          'onlyRare',
          content: 'bittern habitat survey',
          tags: ['rare'],
        ),
      );
      await indexAll();

      final response = await search.searchLexical(
        'bittern',
        filter: const NoteFilterContext(requiredTags: ['wading', 'rare']),
      );
      expect(response.usedSubstringFallback, isFalse);
      expect(noteIds(response), ['both']);
    });

    test('substring fallback applies requiredTags (AND semantics)', () async {
      await indexer.pause(); // Backfill stays incomplete -> substring path.
      await db.insertNote(
        buildNote('both', content: 'egret one', tags: ['wading', 'rare']),
      );
      await db.insertNote(
        buildNote('onlyWading', content: 'egret two', tags: ['wading']),
      );
      await db.insertNote(buildNote('untagged', content: 'egret three'));

      final response = await search.searchLexical(
        'egret',
        filter: const NoteFilterContext(requiredTags: ['wading', 'rare']),
      );
      expect(response.usedSubstringFallback, isTrue);
      expect(noteIds(response), ['both']);
    });
  });

  group('fallback rules', () {
    test(
      'backfill flag unset: substring runs exclusively, FTS untouched',
      () async {
        // Pause the indexer so the search-triggered ensureBackfilled no-ops and
        // the global flag stays unset.
        await indexer.pause();
        final note = buildNote(
          'n1',
          content: 'alpha words in between beta words',
        );
        await db.insertNote(note);
        // Index the note directly so chunks_fts WOULD match if consulted.
        await indexer.reindexNote('n1');
        expect(await indexer.isBackfillComplete(), isFalse);

        // "alpha beta" matches via FTS (implicit AND) but is NOT a raw
        // substring of the note — zero results proves FTS was never consulted.
        final andQuery = await search.searchLexical('alpha beta');
        expect(andQuery.usedSubstringFallback, isTrue);
        expect(andQuery.results, isEmpty);

        // Sanity: FTS really would have matched that query.
        final ftsMatches = await db.searchChunksLexical(
          buildFtsQuery('alpha beta'),
        );
        expect(ftsMatches, isNotEmpty);

        // The substring path still finds plain matches (unranked, score 0).
        final plain = await search.searchLexical('alpha');
        expect(plain.usedSubstringFallback, isTrue);
        expect(noteIds(plain), ['n1']);
        expect(plain.results.single.score, 0.0);
      },
    );

    test('substring fallback keeps pinned-first / newest-first order and '
        'archived scope', () async {
      await indexer.pause();
      final old = DateTime(2024, 1, 1);
      final mid = DateTime(2024, 6, 1);
      final recent = DateTime(2025, 1, 1);
      await db.insertNote(
        buildNote(
          'oldPinned',
          content: 'lemur one',
          pinned: true,
          createdAt: old,
        ),
      );
      await db.insertNote(
        buildNote('newer', content: 'lemur two', createdAt: recent),
      );
      await db.insertNote(
        buildNote('older', content: 'lemur three', createdAt: old),
      );
      await db.insertNote(
        buildNote(
          'gone',
          content: 'lemur four',
          isArchived: true,
          createdAt: mid,
        ),
      );

      final response = await search.searchLexical('lemur');
      expect(response.usedSubstringFallback, isTrue);
      expect(noteIds(response), ['oldPinned', 'newer', 'older']);

      final withArchived = await search.searchLexical(
        'lemur',
        filter: const NoteFilterContext(includeArchived: true),
      );
      expect(noteIds(withArchived), ['oldPinned', 'newer', 'gone', 'older']);
    });

    test(
      'zero-hit FTS query on a complete index re-runs as substring',
      () async {
        // A policy-excluded note is invisible to FTS but reachable by the
        // substring scan (the documented fallback caveat, plan §1.3).
        await db.insertNote(buildNote('ex1', content: 'axolotl care notes'));
        await indexer.flushPending();
        await indexer.setNoteSearchExclusion('ex1', true);
        await indexAll();

        final response = await search.searchLexical('axolotl');
        expect(response.usedSubstringFallback, isTrue);
        expect(noteIds(response), ['ex1']);
      },
    );

    test(
      'FTS4 probe failure degrades to substring despite a complete index',
      () async {
        await db.insertNote(buildNote('n1', content: 'ferret enclosure plans'));
        await indexAll();

        search.debugSetFtsProbeResult(false);
        final degraded = await search.searchLexical('ferret');
        expect(degraded.usedSubstringFallback, isTrue);
        expect(noteIds(degraded), ['n1']);
        expect(degraded.results.single.score, 0.0);

        // Restoring the probe restores the FTS path (ranked, no fallback).
        search.debugSetFtsProbeResult(true);
        final restored = await search.searchLexical('ferret');
        expect(restored.usedSubstringFallback, isFalse);
        expect(restored.results.single.score, greaterThan(0));
      },
    );

    test(
      'concurrent first searches share one FTS probe (no race to fallback)',
      () async {
        await db.insertNote(buildNote('n1', content: 'ibex on the ridge'));
        await indexAll();

        // Both searches hit the (unmemoized) probe at once; a shared probe
        // future means neither can fail on the other's temp table and drop
        // to the substring fallback.
        final responses = await Future.wait([
          search.searchLexical('ibex'),
          search.searchLexical('ibex'),
        ]);
        for (final response in responses) {
          expect(response.usedSubstringFallback, isFalse);
          expect(noteIds(response), ['n1']);
        }
      },
    );

    test('empty query falls back to substring, returns all visible notes, and '
        'skips content-derived snippets', () async {
      await db.insertNote(
        buildNote('n1', content: 'a long body that must not be copied'),
      );
      await db.insertNote(buildNote('n2', isArchived: true));
      await indexAll();

      for (final query in ['', '   ']) {
        final response = await search.searchLexical(query);
        expect(response.usedSubstringFallback, isTrue);
        expect(noteIds(response), ['n1'], reason: 'query "$query"');
        final snippet = response.results.single.best.snippet;
        expect(
          snippet.text,
          isEmpty,
          reason: 'empty-query fast path must not build content snippets',
        );
        expect(snippet.matches, isEmpty);
      }
    });
  });

  group('cold start', () {
    test('first-ever call being a search still uses the FTS path', () async {
      // Build and index a corpus on one connection, then close it.
      final name =
          'search_cold_start_${DateTime.now().microsecondsSinceEpoch}.db';
      final warmDb = DatabaseService.createNew(databaseName: name);
      final warmIndexer = NoteIndexService(
        warmDb,
        debounceDelay: const Duration(milliseconds: 50),
        ocrExtractor: stubOcrExtractor(warmDb),
        figureExtractor: stubFigureExtractor(),
      );
      await warmDb.insertNote(buildNote('n1', content: 'yak herding notes'));
      await warmIndexer.flushPending();
      await warmIndexer.backfillAll();
      warmIndexer.dispose();
      await warmDb.close();

      // Fresh service stack over the same file; the search itself is the
      // first database touch, so chunksFtsAvailable has not been populated
      // yet — the gate must open the DB before reading it.
      final coldDb = DatabaseService.createNew(databaseName: name);
      final coldIndexer = NoteIndexService(
        coldDb,
        debounceDelay: const Duration(milliseconds: 50),
        ocrExtractor: stubOcrExtractor(coldDb),
        figureExtractor: stubFigureExtractor(),
      );
      addTearDown(coldIndexer.dispose);
      addTearDown(() => coldDb.close());
      final coldSearch = SearchService(
        coldDb,
        coldIndexer,
        notesProvider: () => coldDb.getAllNotes(),
      );

      final response = await coldSearch.searchLexical('yak');
      expect(
        response.usedSubstringFallback,
        isFalse,
        reason: 'FTS-capable DB: the first search must use the FTS path',
      );
      expect(noteIds(response), ['n1']);
      expect(response.results.single.score, greaterThan(0));
    });
  });

  group('sequence tickets', () {
    test('a response whose ticket was superseded is stale', () async {
      await db.insertNote(buildNote('n1', content: 'ticket test content'));
      await indexAll();

      final first = search.takeTicket();
      final second = search.takeTicket();
      expect(search.newestTicket, same(second));

      final staleResponse = await search.searchLexical('ticket', ticket: first);
      expect(
        search.isCurrent(staleResponse.ticket),
        isFalse,
        reason: 'a newer ticket was issued before this search finished',
      );

      final freshResponse = await search.searchLexical(
        'ticket',
        ticket: second,
      );
      expect(search.isCurrent(freshResponse.ticket), isTrue);
    });

    test(
      'an un-ticketed search is standalone: always current, never supersedes',
      () async {
        await db.insertNote(buildNote('n1', content: 'ticket test content'));
        await indexAll();

        // The UI takes a ticket; a background AI-audience search (no ticket)
        // runs concurrently with the UI's in-flight search.
        final uiTicket = search.takeTicket();
        final responses = await Future.wait([
          search.searchLexical('ticket', audience: SearchAudience.ai),
          search.searchLexical('ticket', ticket: uiTicket),
        ]);
        final background = responses[0];
        final ui = responses[1];

        // The background search must not have invalidated the UI's ticket...
        expect(search.isCurrent(ui.ticket), isTrue);
        expect(search.newestTicket, same(uiTicket));
        // ...and its own standalone marker is always current.
        expect(background.ticket.standalone, isTrue);
        expect(search.isCurrent(background.ticket), isTrue);
      },
    );
  });

  group('startup backfill trigger', () {
    test('first query fires ensureBackfilled exactly once', () async {
      // A dedicated counting indexer (the setUp indexer keeps running; its
      // hooks being re-pointed here is harmless for this test).
      final counting = _CountingIndexService(
        db,
        changeNotifier: notifier,
        debounceDelay: const Duration(milliseconds: 50),
      );
      addTearDown(counting.dispose);
      final countingSearch = SearchService(
        db,
        counting,
        notesProvider: () => db.getAllNotes(),
      );

      await db.insertNote(buildNote('n1', content: 'trigger test'));
      await counting.flushPending();
      await counting.backfillAll();

      await countingSearch.searchLexical('trigger');
      await countingSearch.searchLexical('trigger');
      await countingSearch.searchLexical('nothing-matches-this');
      expect(counting.ensureBackfilledCalls, 1);

      // Explicit ensureReady after a query is also a no-op.
      await countingSearch.ensureReady();
      expect(counting.ensureBackfilledCalls, 1);
    });
  });

  // The scoped path (`search_figures`) is the one where accumulate-then-
  // filter and filter-then-accumulate diverge, and it only diverges AT SCALE:
  // over a 2-3 chunk corpus every implementation looks identical.
  group('scoped search', () {
    test('an in-scope chunk ranked below 120 out-of-scope ones is still '
        'returned (scope applies during accumulation)', () async {
      // 120 high-scoring note_body chunks would fill a naive top-100 slice.
      for (var i = 0; i < 120; i++) {
        await db.insertNote(
          buildNote('untagged$i', content: 'heron heron heron'),
        );
      }
      await db.insertNote(buildNote('withFigure', content: 'unrelated body'));
      await indexAll();
      // The one in-scope chunk: a single low-scoring mention, seeded after
      // the backfill so the indexer does not treat it as stale.
      await insertChunk(
        chunkKey: 'withFigure:figure:att1:1000',
        noteId: 'withFigure',
        sourceType: 'figure',
        sourceId: 'att1',
        page: 1,
        text:
            'A long descriptive caption wandering through many unrelated '
            'words before it finally names a heron once, near the very end '
            'of the sentence, among other catalogued species.',
      );

      // Sanity: unscoped, the top-100 slice is exhausted before this chunk.
      final unscoped = await search.searchLexical('heron');
      expect(unscoped.results, hasLength(100));
      expect(noteIds(unscoped), isNot(contains('withFigure')));

      final scoped = await search.searchLexical(
        'heron',
        filter: const NoteFilterContext(sourceTypes: {'figure'}),
      );
      expect(scoped.usedSubstringFallback, isFalse);
      expect(noteIds(scoped), ['withFigure']);
      expect(scoped.results.single.best.sourceType, 'figure');
    });

    test('a noteId-scoped hit ranked below 120 other notes is still '
        'returned', () async {
      for (var i = 0; i < 120; i++) {
        await db.insertNote(buildNote('other$i', content: 'egret egret egret'));
      }
      await db.insertNote(
        buildNote(
          'target',
          content:
              'A lengthy entry covering many subjects before it finally '
              'mentions an egret once, buried in the closing paragraph.',
        ),
      );
      await indexAll();

      final unscoped = await search.searchLexical('egret');
      expect(noteIds(unscoped), isNot(contains('target')));

      final scoped = await search.searchLexical(
        'egret',
        filter: const NoteFilterContext(noteId: 'target'),
      );
      expect(scoped.usedSubstringFallback, isFalse);
      expect(noteIds(scoped), ['target']);
    });

    test('chunksPerNote caps the reported list without touching the '
        'score', () async {
      await db.insertNote(buildNote('n1', content: 'unrelated body'));
      await indexAll();
      for (var i = 0; i < 6; i++) {
        await insertChunk(
          chunkKey: 'n1:figure:att1:$i',
          noteId: 'n1',
          sourceType: 'figure',
          sourceId: 'att1',
          page: i + 1,
          seq: i,
          text: 'kestrel plumage plate number $i',
        );
      }
      const scope = NoteFilterContext(sourceTypes: {'figure'});

      final one = await search.searchLexical('kestrel', filter: scope);
      final five = await search.searchLexical(
        'kestrel',
        filter: scope,
        chunksPerNote: 5,
      );
      // Exactly the budget — not budget-1, the classic off-by-one here.
      expect(one.results.single.chunks, hasLength(1));
      expect(five.results.single.chunks, hasLength(5));
      expect(
        five.results.single.chunks.first.chunkKey,
        one.results.single.chunks.first.chunkKey,
      );
      expect(
        five.results.single.chunks.map((c) => c.chunkKey).toSet(),
        hasLength(5),
        reason: 'the reported chunks are distinct',
      );
      // The grouping bonus counts every visible hit, not the reported ones.
      expect(five.results.single.score, one.results.single.score);
      expect(
        five.results.single.best.chunkKey,
        five.results.single.chunks.first.chunkKey,
      );

      // A nonsense budget degrades to 1 rather than emptying the list.
      final zero = await search.searchLexical(
        'kestrel',
        filter: scope,
        chunksPerNote: 0,
      );
      expect(zero.results.single.chunks, hasLength(1));
    });

    test('an unservable scope says so instead of reporting absence', () async {
      // Mid-backfill (fresh install, post-recovery, after Rebuild): the FTS
      // path is gated off, and the substring scan matches NOTE TEXT, so it
      // cannot answer a figure-scoped question at all. Reporting an empty
      // list as "no figures" here is a confident false negative.
      await indexer.pause();
      await db.insertNote(buildNote('n1', content: 'osprey nesting platform'));
      await indexer.reindexNote('n1');
      expect(await indexer.isBackfillComplete(), isFalse);

      final scoped = await search.searchLexical(
        'osprey',
        filter: const NoteFilterContext(sourceTypes: {'figure'}),
      );
      expect(scoped.results, isEmpty);
      expect(scoped.usedSubstringFallback, isFalse);
      expect(scoped.scopeUnservable, isTrue);

      // An unscoped search on the same incomplete index IS servable — the
      // substring scan answers note-body questions.
      final unscoped = await search.searchLexical('osprey');
      expect(unscoped.usedSubstringFallback, isTrue);
      expect(unscoped.scopeUnservable, isFalse);
    });

    test('a failed FTS4 probe also makes a figure scope unservable', () async {
      await db.insertNote(buildNote('n1', content: 'osprey nesting platform'));
      await indexAll();
      search.debugSetFtsProbeResult(false);

      final scoped = await search.searchLexical(
        'osprey',
        filter: const NoteFilterContext(sourceTypes: {'figure'}),
      );
      expect(scoped.results, isEmpty);
      expect(scoped.scopeUnservable, isTrue);
    });

    test(
      'a genuine zero-hit rerun over a COMPLETE index is servable',
      () async {
        await db.insertNote(
          buildNote('n1', content: 'osprey nesting platform'),
        );
        await indexAll();

        final scoped = await search.searchLexical(
          'nothing-matches-this-at-all',
          filter: const NoteFilterContext(sourceTypes: {'figure'}),
        );
        expect(scoped.results, isEmpty);
        expect(
          scoped.scopeUnservable,
          isFalse,
          reason: 'FTS ran over a complete index and genuinely matched nothing',
        );
      },
    );
  });

  group('DatabaseService.searchChunksLexical', () {
    test('the runaway cap applies to IN-SCOPE rows, not the lowest '
        'docids', () async {
      // The cap is an unordered LIMIT, so FTS4 keeps the LOWEST docids. The
      // indexer writes figure chunks LAST, so they carry the highest ids: an
      // unscoped candidate pool on a big corpus contains none of them, and a
      // figure search reports "no figures" while figures match.
      await db.insertNote(buildNote('n1', content: 'unrelated body'));
      await indexAll();
      for (var i = 0; i < 4; i++) {
        await insertChunk(
          chunkKey: 'n1:attachment_text:att1:$i',
          noteId: 'n1',
          sourceType: 'attachment_text',
          sourceId: 'att1',
          page: i + 1,
          text: 'shearwater colony notes page $i',
        );
      }
      // Written last => highest docid => first casualty of the cap.
      final figureId = await insertChunk(
        chunkKey: 'n1:figure:att1:9000',
        noteId: 'n1',
        sourceType: 'figure',
        sourceId: 'att1',
        page: 9,
        text: 'shearwater colony distribution map',
      );

      final unscoped = await db.searchChunksLexical(
        buildFtsQuery('shearwater'),
        limit: 2,
      );
      expect(
        [for (final m in unscoped) m.docid],
        isNot(contains(figureId)),
        reason: 'fixture sanity: the cap keeps the lowest docids',
      );

      final scoped = await db.searchChunksLexical(
        buildFtsQuery('shearwater'),
        limit: 2,
        sourceTypes: const {'figure'},
      );
      expect([for (final m in scoped) m.docid], [figureId]);
      for (final match in scoped) {
        expect(match.matchinfo, isNotEmpty);
      }

      final byNote = await db.searchChunksLexical(
        buildFtsQuery('shearwater'),
        noteId: 'missing-note',
      );
      expect(byNote, isEmpty);
    });

    test('getSearchChunksByIds drops out-of-scope rows in SQL', () async {
      await db.insertNote(buildNote('n1', content: 'unrelated body'));
      await db.insertNote(buildNote('n2', content: 'unrelated body'));
      await indexAll();
      final figure = await insertChunk(
        chunkKey: 'n1:figure:att1:1000',
        noteId: 'n1',
        sourceType: 'figure',
        sourceId: 'att1',
        page: 1,
        text: 'gannet dive sequence',
      );
      final page = await insertChunk(
        chunkKey: 'n2:attachment_text:att2:1',
        noteId: 'n2',
        sourceType: 'attachment_text',
        sourceId: 'att2',
        page: 1,
        text: 'gannet dive sequence',
      );

      final scoped = await db.getSearchChunksByIds(
        [figure, page],
        sourceTypes: const {'figure'},
      );
      expect([for (final r in scoped) r.id], [figure]);

      final byNote = await db.getSearchChunksByIds([
        figure,
        page,
      ], noteId: 'n2');
      expect([for (final r in byNote) r.id], [page]);

      final unscoped = await db.getSearchChunksByIds([figure, page]);
      expect(unscoped, hasLength(2));
    });

    test(
      'returns docid + matchinfo pairs and honors the runaway cap',
      () async {
        await db.insertNote(buildNote('n1', content: 'marmot alpha section'));
        await db.insertNote(buildNote('n2', content: 'marmot beta section'));
        await indexAll();

        final all = await db.searchChunksLexical(buildFtsQuery('marmot'));
        expect(all, hasLength(2));
        for (final match in all) {
          expect(match.matchinfo, isNotEmpty);
        }

        final capped = await db.searchChunksLexical(
          buildFtsQuery('marmot'),
          limit: 1,
        );
        expect(capped, hasLength(1));
      },
    );

    test('getSearchChunksByIds joins archived and AI-context flags', () async {
      await db.insertNote(
        buildNote('n1', content: 'joined row content', isArchived: true),
      );
      await indexAll();

      final matches = await db.searchChunksLexical(buildFtsQuery('joined'));
      final rows = await db.getSearchChunksByIds([
        for (final m in matches) m.docid,
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.noteIsArchived, isTrue);
      expect(
        rows.single.attachmentIncludeInAIContext,
        isNull,
        reason: 'note-body chunks have no source attachment',
      );
      expect(await db.getSearchChunksByIds([]), isEmpty);
    });
  });
}
