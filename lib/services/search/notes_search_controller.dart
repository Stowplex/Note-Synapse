// UI-side search state machine for the notes screen (plan §1.6 + §2.3
// fusion UX), extracted from the widget State so debounce / ticket / state
// transitions are unit testable.
//
// Responsibilities:
// - 250 ms debounce on keystrokes; submit (keyboard search action) bypasses
//   the debounce.
// - The SearchService ticket contract: a ticket is taken at INTAKE time
//   (keystroke / submit / blank reset), so a slow response for an older
//   query can never be judged current and published for a newer one; the
//   debounced run reuses the ticket its keystroke took.
// - State the screen renders from: browse mode (empty query, results ==
//   null), "Searching…" (isSearching), and completed results — the
//   no-results empty state is correct ONLY when a search for the current
//   query has completed (results != null && !isSearching).
//
// ## Fusion UX (plan §2.3)
//
// Keystroke-debounced searches stay LEXICAL-ONLY: semantic refinement costs
// a (possibly paid) query embedding, so it must not fire per typing pause.
// Fusion triggers are:
//   1. [submit] — the primary trigger (keyboard search action).
//   2. ~1.5 s of idle after the lexical response lands — the secondary
//      trigger (NOT 600 ms; see the plan).
// A landed refinement is published as a re-rank only when its ticket is
// still current AND the user has not scrolled/tapped since it started — the
// screen reports interaction through [notifyUserInteraction]. While a
// refinement is in flight, [isRefining] drives a subtle "refining…"
// affordance; it never re-enters the "Searching…" state, so the visible
// list keeps standing (the lexical floor).
//
// The controller always queries with includeArchived: true — the screen's
// tab/tag scopes are POST-filters it applies to the ranked results (plan
// §1.6: non-text filters stay outside the text search), so the archived tab
// can surface archived hits from the same response.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../logger_service.dart';
import 'search_service.dart';

class NotesSearchController extends ChangeNotifier {
  NotesSearchController(
    this._searchService, {
    this.debounceDelay = const Duration(milliseconds: 250),
    this.semanticIdleDelay = const Duration(milliseconds: 1500),
  });

  final SearchService _searchService;

  /// Keystroke debounce (plan §1.6: 250 ms).
  final Duration debounceDelay;

  /// Idle delay after a lexical response before the secondary fusion
  /// trigger fires (plan §2.3: ~1.5 s).
  final Duration semanticIdleDelay;

  Timer? _debounce;
  Timer? _idleFusion;
  String _query = '';
  bool _searching = false;
  bool _refining = false;
  List<NoteSearchResult>? _results;
  bool _usedSubstringFallback = false;
  bool _disposed = false;

  /// Ticket of the newest INTAKE (keystroke/submit). The debounced run
  /// reuses it, so responses are matched to the intake that requested them.
  SearchTicket? _ticket;

  /// Bumped by [notifyUserInteraction]; a refinement started before the
  /// current value is dropped on arrival (the user is engaging with the
  /// list — moving rows under them is worse than a slightly stale order).
  int _interactionSeq = 0;

  /// The query text as last typed/submitted.
  String get query => _query;

  /// Whether the screen is in search mode (non-blank query). A blank query
  /// is browse mode: the existing pinned-first/newest pipeline, untouched.
  bool get hasActiveQuery => _query.trim().isNotEmpty;

  /// True from keystroke/submit until the (non-stale) response lands.
  bool get isSearching => _searching;

  /// True while a semantic refinement runs over already-displayed results
  /// (subtle "refining…" affordance; NOT the "Searching…" state).
  bool get isRefining => _refining;

  /// Ranked results of the last completed search, or null when none has
  /// completed for the current query (browse mode, or first search still in
  /// flight).
  List<NoteSearchResult>? get results => _results;

  /// Whether [results] came from the substring fallback (their snippets may
  /// be empty — degrade to plain rows).
  bool get usedSubstringFallback => _usedSubstringFallback;

  /// Keystroke entry point: debounced LEXICAL search, or an immediate reset
  /// to browse mode when the query went blank.
  void onQueryChanged(String text) {
    _query = text;
    _debounce?.cancel();
    _idleFusion?.cancel();
    _refining = false;
    // Ticket at INTAKE, not inside the debounced run: an in-flight response
    // for the previous query is superseded the moment a new keystroke
    // arrives, so it can never be published as this query's final result.
    _ticket = _searchService.takeTicket();
    if (!hasActiveQuery) {
      // Browse mode needs no SearchService call; the ticket taken above
      // supersedes any in-flight search so its late response is dropped
      // instead of resurrecting stale results.
      _searching = false;
      _results = null;
      _usedSubstringFallback = false;
      notifyListeners();
      return;
    }
    _searching = true;
    notifyListeners();
    final ticket = _ticket!;
    _debounce = Timer(debounceDelay, () => _run(_query, ticket, fused: false));
  }

  /// Keyboard search action: runs immediately, bypassing the debounce, and
  /// is the PRIMARY fusion trigger (semantic layer included).
  void submit(String text) {
    _query = text;
    _debounce?.cancel();
    _idleFusion?.cancel();
    _refining = false;
    if (!hasActiveQuery) {
      onQueryChanged(text);
      return;
    }
    _ticket = _searchService.takeTicket();
    _searching = true;
    notifyListeners();
    _run(_query, _ticket!, fused: true);
  }

  /// The screen calls this on scroll/tap. A semantic refinement in flight
  /// when it fires is dropped on arrival (plan §2.3).
  void notifyUserInteraction() {
    _interactionSeq++;
    _idleFusion?.cancel();
    if (_refining) {
      _refining = false;
      notifyListeners();
    }
  }

  Future<void> _run(
    String query,
    SearchTicket ticket, {
    required bool fused,
  }) async {
    // Re-assert: a debounced run starts long after its keystroke, and the
    // screen may have rendered a completed older response meanwhile.
    if (!_searching) {
      _searching = true;
      notifyListeners();
    }
    SearchResponse response;
    try {
      response = await _search(query, ticket, fused: fused);
    } catch (e) {
      LoggerService.error(
        '[NotesSearchController] Search failed: $e',
        error: e,
      );
      if (_disposed || !_searchService.isCurrent(ticket)) return;
      _results = const [];
      _usedSubstringFallback = false;
      _searching = false;
      _refining = false;
      notifyListeners();
      return;
    }
    if (_disposed || !_searchService.isCurrent(response.ticket)) return;
    _results = response.results;
    _usedSubstringFallback = response.usedSubstringFallback;
    _searching = false;
    _refining = false;
    notifyListeners();
    if (!fused) _scheduleIdleFusion(query, ticket);
  }

  /// Secondary fusion trigger: ~1.5 s of idle after a lexical response.
  void _scheduleIdleFusion(String query, SearchTicket ticket) {
    _idleFusion?.cancel();
    _idleFusion = Timer(semanticIdleDelay, () {
      if (_disposed || !_searchService.isCurrent(ticket)) return;
      if (_query != query) return;
      unawaited(_refine(query, ticket));
    });
  }

  /// Runs the fused search over an already-rendered lexical result set and
  /// publishes it as a re-rank when it is still wanted.
  Future<void> _refine(String query, SearchTicket ticket) async {
    final interactionAtStart = _interactionSeq;
    _refining = true;
    notifyListeners();
    SearchResponse response;
    try {
      response = await _search(query, ticket, fused: true);
    } catch (e) {
      // Refinement failures are silent: the lexical results stand.
      LoggerService.warning('[NotesSearchController] Refinement failed: $e');
      if (_disposed) return;
      if (_refining) {
        _refining = false;
        notifyListeners();
      }
      return;
    }
    if (_disposed) return;
    final stillWanted =
        _searchService.isCurrent(response.ticket) &&
        _interactionSeq == interactionAtStart &&
        _query == query;
    if (!stillWanted) {
      // Dropped re-rank: keep the displayed order, just clear the flag.
      if (_refining) {
        _refining = false;
        notifyListeners();
      }
      return;
    }
    _results = response.results;
    _usedSubstringFallback = response.usedSubstringFallback;
    _refining = false;
    notifyListeners();
  }

  /// Layer selection: keystroke-debounced runs stay lexical-only; submit and
  /// the idle refinement use the fused entry point.
  Future<SearchResponse> _search(
    String query,
    SearchTicket ticket, {
    required bool fused,
  }) {
    // Archived scope handled by the screen's post-filters; see header.
    const filter = NoteFilterContext(includeArchived: true);
    return fused
        ? _searchService.searchFused(query, filter: filter, ticket: ticket)
        : _searchService.searchLexical(query, filter: filter, ticket: ticket);
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _idleFusion?.cancel();
    super.dispose();
  }
}
