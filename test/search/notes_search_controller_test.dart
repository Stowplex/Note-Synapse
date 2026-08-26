// Unit tests for NotesSearchController (plan §1.6): the extracted
// debounce + ticket + state-transition logic behind the notes screen's
// search box. Uses a fake SearchService whose searchFused completion is
// test-controlled; the ticket bookkeeping (takeTicket/isCurrent) is the real
// SearchService implementation, so the stale-drop contract is exercised
// end-to-end.

import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/bm25.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search/notes_search_controller.dart';
import 'package:note_synapse/services/search/search_service.dart';

import 'ocr_test_stubs.dart';

class _FakeSearchService extends SearchService {
  _FakeSearchService()
    : super(
        DatabaseService(),
        NoteIndexService(
          DatabaseService(),
          changeNotifier: DataChangeNotifier(),
          figureExtractor: stubFigureExtractor(),
        ),
        notesProvider: () async => [],
      );

  final List<String> queries = [];
  final List<NoteFilterContext?> filters = [];

  /// Which entry point each recorded query used — the fusion-trigger
  /// contract (keystroke debounce = lexical, submit/idle = fused).
  final List<SearchLayer> layers = [];
  final List<Completer<List<NoteSearchResult>>> pending = [];
  bool throwOnSearch = false;
  bool respondAsFallback = false;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<SearchResponse> searchLexical(
    String query, {
    NoteFilterContext? filter,
    SearchAudience audience = SearchAudience.user,
    SearchTicket? ticket,
    int chunksPerNote = 1,
  }) {
    return _record(query, filter, ticket, SearchLayer.lexical);
  }

  @override
  Future<SearchResponse> searchFused(
    String query, {
    NoteFilterContext? filter,
    SearchAudience audience = SearchAudience.user,
    SearchTicket? ticket,
    int chunksPerNote = 1,
  }) {
    return _record(query, filter, ticket, SearchLayer.semantic);
  }

  Future<SearchResponse> _record(
    String query,
    NoteFilterContext? filter,
    SearchTicket? ticket,
    SearchLayer layer,
  ) async {
    queries.add(query);
    filters.add(filter);
    layers.add(layer);
    if (throwOnSearch) throw StateError('search backend unavailable');
    final completer = Completer<List<NoteSearchResult>>();
    pending.add(completer);
    final results = await completer.future;
    return SearchResponse(
      results: results,
      ticket: ticket ?? SearchService.standaloneTicket,
      usedSubstringFallback: respondAsFallback,
    );
  }
}

NoteSearchResult _hit(String noteId) => NoteSearchResult(
  noteId: noteId,
  score: 1.0,
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
  late _FakeSearchService service;
  late NotesSearchController controller;
  late int notifications;

  setUp(() {
    service = _FakeSearchService();
    controller = NotesSearchController(service);
    notifications = 0;
    controller.addListener(() => notifications++);
  });

  tearDown(() => controller.dispose());

  test('starts in browse mode', () {
    expect(controller.hasActiveQuery, isFalse);
    expect(controller.isSearching, isFalse);
    expect(controller.results, isNull);
  });

  test('debounces keystrokes: one search per pause, latest query wins', () {
    fakeAsync((async) {
      controller.onQueryChanged('a');
      controller.onQueryChanged('ab');
      async.elapse(const Duration(milliseconds: 100));
      controller.onQueryChanged('abc');
      // No search yet: every keystroke restarted the 250 ms window.
      expect(service.queries, isEmpty);
      expect(controller.isSearching, isTrue);

      async.elapse(const Duration(milliseconds: 250));
      expect(service.queries, ['abc']);

      service.pending.single.complete([_hit('n1')]);
      async.flushMicrotasks();
      expect(controller.isSearching, isFalse);
      expect(controller.results, hasLength(1));
      expect(controller.results!.single.noteId, 'n1');
    });
  });

  test('submit bypasses the debounce', () {
    fakeAsync((async) {
      controller.onQueryChanged('quer');
      controller.submit('query');
      // Search ran immediately — no 250 ms wait; the pending debounce from
      // the keystroke was cancelled.
      expect(service.queries, ['query']);
      async.elapse(const Duration(seconds: 1));
      expect(service.queries, ['query']);
    });
  });

  test('passes includeArchived scope (post-filters handle tab scope)', () {
    fakeAsync((async) {
      controller.submit('q');
      expect(service.filters.single?.includeArchived, isTrue);
    });
  });

  test('stale responses are dropped (ticket supersession)', () {
    fakeAsync((async) {
      controller.submit('first');
      controller.submit('second');
      expect(service.pending, hasLength(2));

      // Newer search finishes first.
      service.pending[1].complete([_hit('b')]);
      async.flushMicrotasks();
      expect(controller.results!.single.noteId, 'b');
      expect(controller.isSearching, isFalse);

      // The older search finishing later must not clobber newer results.
      service.pending[0].complete([_hit('a')]);
      async.flushMicrotasks();
      expect(controller.results!.single.noteId, 'b');
      expect(controller.isSearching, isFalse);
    });
  });

  test('clearing the query returns to browse mode and drops in-flight '
      'responses', () {
    fakeAsync((async) {
      controller.submit('query');
      expect(controller.isSearching, isTrue);

      controller.onQueryChanged('');
      expect(controller.hasActiveQuery, isFalse);
      expect(controller.isSearching, isFalse);
      expect(controller.results, isNull);

      // The in-flight search completes late: its ticket was superseded by
      // the clear, so browse mode must not be overwritten.
      service.pending.single.complete([_hit('a')]);
      async.flushMicrotasks();
      expect(controller.results, isNull);
      expect(controller.isSearching, isFalse);
    });
  });

  test('whitespace-only query is browse mode and never searches', () {
    fakeAsync((async) {
      controller.onQueryChanged('   ');
      expect(controller.hasActiveQuery, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(service.queries, isEmpty);
    });
  });

  test('empty result list is exposed only after completion (no empty-state '
      'flash while in flight)', () {
    fakeAsync((async) {
      controller.submit('nothing matches');
      // In flight: results is still null — the screen shows "Searching…",
      // not "No notes found".
      expect(controller.isSearching, isTrue);
      expect(controller.results, isNull);

      service.pending.single.complete(const []);
      async.flushMicrotasks();
      expect(controller.isSearching, isFalse);
      expect(controller.results, isEmpty);
    });
  });

  test('surfaces usedSubstringFallback', () {
    fakeAsync((async) {
      service.respondAsFallback = true;
      controller.submit('q');
      service.pending.single.complete([_hit('a')]);
      async.flushMicrotasks();
      expect(controller.usedSubstringFallback, isTrue);
    });
  });

  test('search errors resolve to empty results instead of hanging the '
      'Searching state', () {
    fakeAsync((async) {
      service.throwOnSearch = true;
      controller.submit('q');
      async.flushMicrotasks();
      expect(controller.isSearching, isFalse);
      expect(controller.results, isEmpty);
    });
  });

  test('notifies listeners on state transitions', () {
    fakeAsync((async) {
      controller.submit('q');
      expect(notifications, 1); // searching started
      service.pending.single.complete([_hit('a')]);
      async.flushMicrotasks();
      expect(notifications, 2); // results landed
      controller.onQueryChanged('');
      expect(notifications, 3); // back to browse mode
    });
  });

  // ── Fusion UX (plan §2.3) ─────────────────────────────────────────────────

  test('keystroke debounce stays lexical-only', () {
    fakeAsync((async) {
      controller.onQueryChanged('abc');
      async.elapse(const Duration(milliseconds: 250));
      expect(service.layers, [SearchLayer.lexical]);
    });
  });

  test('submit is the primary fusion trigger', () {
    fakeAsync((async) {
      controller.submit('abc');
      expect(service.layers, [SearchLayer.semantic]);
    });
  });

  test('~1.5 s idle after a lexical response is the secondary fusion '
      'trigger, landing as a re-rank', () {
    fakeAsync((async) {
      controller.onQueryChanged('abc');
      async.elapse(const Duration(milliseconds: 250));
      service.pending.single.complete([_hit('lex')]);
      async.flushMicrotasks();
      expect(controller.results!.single.noteId, 'lex');
      expect(controller.isRefining, isFalse);

      // Nothing fires before the idle delay elapses.
      async.elapse(const Duration(milliseconds: 1400));
      expect(service.layers, [SearchLayer.lexical]);

      async.elapse(const Duration(milliseconds: 200));
      expect(service.layers, [SearchLayer.lexical, SearchLayer.semantic]);
      expect(controller.isRefining, isTrue);
      // Refining is NOT the "Searching…" state: the list keeps standing.
      expect(controller.isSearching, isFalse);
      expect(controller.results!.single.noteId, 'lex');

      service.pending.last.complete([_hit('sem')]);
      async.flushMicrotasks();
      expect(controller.isRefining, isFalse);
      expect(controller.results!.single.noteId, 'sem');
    });
  });

  test('user interaction drops a pending re-rank', () {
    fakeAsync((async) {
      controller.onQueryChanged('abc');
      async.elapse(const Duration(milliseconds: 250));
      service.pending.single.complete([_hit('lex')]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1600));
      expect(controller.isRefining, isTrue);

      // Scroll/tap while the refinement is in flight.
      controller.notifyUserInteraction();
      expect(controller.isRefining, isFalse);

      service.pending.last.complete([_hit('sem')]);
      async.flushMicrotasks();
      // Order under the user's finger is preserved.
      expect(controller.results!.single.noteId, 'lex');
      expect(controller.isRefining, isFalse);
    });
  });

  test('interaction before the idle delay cancels the refinement entirely', () {
    fakeAsync((async) {
      controller.onQueryChanged('abc');
      async.elapse(const Duration(milliseconds: 250));
      service.pending.single.complete([_hit('lex')]);
      async.flushMicrotasks();

      controller.notifyUserInteraction();
      async.elapse(const Duration(seconds: 5));
      expect(service.layers, [SearchLayer.lexical]);
      expect(controller.isRefining, isFalse);
    });
  });

  test('a keystroke during a refinement supersedes it (stale re-rank '
      'dropped)', () {
    fakeAsync((async) {
      controller.onQueryChanged('abc');
      async.elapse(const Duration(milliseconds: 250));
      service.pending.single.complete([_hit('lex')]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1600));
      expect(controller.isRefining, isTrue);

      controller.onQueryChanged('abcd');
      expect(controller.isRefining, isFalse);
      async.elapse(const Duration(milliseconds: 250));

      // The stale refinement completes late: its ticket was superseded.
      service.pending[1].complete([_hit('stale')]);
      async.flushMicrotasks();
      expect(controller.results!.single.noteId, 'lex');

      service.pending[2].complete([_hit('fresh')]);
      async.flushMicrotasks();
      expect(controller.results!.single.noteId, 'fresh');
    });
  });

  test('a slow older response never publishes for a newer query (ticket '
      'taken at intake)', () {
    fakeAsync((async) {
      controller.onQueryChanged('old');
      async.elapse(const Duration(milliseconds: 250));
      expect(service.pending, hasLength(1));

      // New keystroke while the old search is still in flight.
      controller.onQueryChanged('new');
      expect(controller.isSearching, isTrue);

      // Old response lands first: it must not end the searching state nor
      // publish results for the newer query.
      service.pending[0].complete([_hit('old')]);
      async.flushMicrotasks();
      expect(controller.results, isNull);
      expect(controller.isSearching, isTrue);

      async.elapse(const Duration(milliseconds: 250));
      service.pending[1].complete([_hit('new')]);
      async.flushMicrotasks();
      expect(controller.results!.single.noteId, 'new');
      expect(controller.isSearching, isFalse);
    });
  });
}
