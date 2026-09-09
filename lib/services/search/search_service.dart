// SearchService (plan §1.5): the query-side entry point for layered search.
//
// Lexical (FTS4 + BM25) is the always-on floor; `searchFused` is an alias of
// `searchLexical` until the semantic layer lands (Step 9 / plan phase 2) —
// callers should target `searchFused` so they pick up fusion for free.
//
// Fallback rules (plan §1.5 — probe + completeness, never row counts): the
// substring predicate scan runs EXCLUSIVELY when
//   (a) chunks_fts is missing on this database (chunksFtsAvailable), or
//   (b) the runtime FTS4 capability probe fails, or
//   (c) the global backfill-complete flag is unset (partially-indexed
//       corpora must never silently miss notes), or
//   (d) the query normalizes to an empty FTS expression;
// additionally a complete-index FTS query that yields ZERO results re-runs
// as substring (status-quo cost, deliberate).
//
// ## Stale-response dropping (sequence tokens) — Step 5 contract
//
// Searches are async; a fast query issued later can finish before a slow
// earlier one. Callers that render results should:
//
// ```dart
// final ticket = searchService.takeTicket();   // supersedes older tickets
// final response = await searchService.searchFused(query, ticket: ticket);
// if (!searchService.isCurrent(response.ticket)) return; // stale — drop
// render(response.results);
// ```
//
// `takeTicket()` advances `newestTicket`; a response is stale iff its ticket
// is no longer the newest. ONLY an explicit `takeTicket()` advances the
// sequence: a search called without a ticket runs ticket-less — its response
// carries a standalone marker that never enters the sequence (`isCurrent` is
// always true for it) and never invalidates tickets other callers hold. This
// keeps background searches (e.g. an AI-audience lookup) from staling out
// the UI's in-flight ticketed search.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/note.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'bm25.dart';
import 'embedding/embedding_provider.dart';
import 'embedding/embedding_provider_registry.dart';
import 'note_index_service.dart';
import 'search_text_normalizer.dart';
import 'vector_search.dart';

/// Retrieval layers that can contribute to a result (plan architecture).
enum SearchLayer { lexical, semantic, figure }

/// Who the results are for. [ai] excludes chunks whose source attachment has
/// includeInAIContext = false (the existing privacy contract — about the AI,
/// not the user); [user] sees everything.
enum SearchAudience { user, ai }

/// The reserved "visible from every Space" tag, mirroring
/// `SpaceScopeService.allSpacesTag`. Spelled out rather than imported to keep
/// this retrieval layer free of `shared_preferences` for one string — the same
/// reason `DatabaseService` keeps its own copy. The scoped-search tests tag
/// their fixtures with `SpaceScopeService.allSpacesTag` and expect them found,
/// so the two cannot drift apart silently.
const String allSpacesTag = 'all-spaces';

/// Query-time visibility scope (plan §1.5). Mirrors saved-filter semantics:
/// archived notes are hidden unless [includeArchived]. Room for type
/// scopes later.
class NoteFilterContext {
  const NoteFilterContext({
    this.includeArchived = false,
    this.requiredTags,
    this.scopeTags,
    this.includeAllSpacesTag = false,
    this.sourceTypes,
    this.noteId,
  });

  final bool includeArchived;

  /// Tags the owning note must ALL carry (AND semantics, exact tag-name
  /// match — the pre-layered SQL applied one EXISTS per tag). Null or empty
  /// means no tag constraint. Applied DURING result accumulation, so tagged
  /// notes ranked below untagged ones are still found rather than being
  /// truncated away with the top slice.
  ///
  /// This is the **caller's own** requirement. It is never escaped by
  /// [includeAllSpacesTag] — see [scopeTags].
  final List<String>? requiredTags;

  /// The active Space's tags. ANDed among themselves as their own group, and
  /// [includeAllSpacesTag] ORs the reserved `all-spaces` tag around **that
  /// group only**:
  ///
  ///     t1 AND t2 AND ((s1 AND s2) OR all-spaces)
  ///
  /// so a note marked visible everywhere is found inside a Space even though
  /// it carries none of the Space's tags, while [requiredTags] still has to
  /// match. Kept as a separate list from [requiredTags] for exactly the
  /// reason `DatabaseService.searchNotesFTS` does: merging them and ORing
  /// around the whole conjunction turns "tag `invoice` in this Space" into
  /// "tag `invoice`, OR anything tagged `all-spaces`", which since migration
  /// v47 means every agent-skill note.
  final List<String>? scopeTags;

  /// Whether the reserved `all-spaces` tag escapes [scopeTags]. Does nothing
  /// without [scopeTags] — with no Space there is no scope to escape, so it
  /// fails closed.
  final bool includeAllSpacesTag;

  /// Chunk `sourceType`s results may come from — `meta`, `note_body`,
  /// `subnote`, `annotation`, `attachment_text`, `attachment_ocr`, `figure`.
  /// Null or empty means every type (the default for note search).
  ///
  /// `search_figures` scopes to `{figure}` (and to the page-level types for
  /// its link fallback). Applied in the SAME accumulation pass as the
  /// archived / audience / tag filters, so a scoped search can never
  /// bypass the privacy or archived rules, and out-of-scope chunks never
  /// consume top-N slots ahead of in-scope ones ranked below them.
  final Set<String>? sourceTypes;

  /// Restricts results to a single note. Applied during accumulation for the
  /// same reason as [sourceTypes]: filtering after truncation would let a
  /// popular note's chunks starve the requested note out of the top slice.
  final String? noteId;
}

/// Monotonic sequence token; see the class comment for the Step 5 contract.
class SearchTicket {
  const SearchTicket._(this.seq, {this.standalone = false});

  final int seq;

  /// True for the marker attached to un-ticketed searches: it never enters
  /// the supersession sequence, is always "current", and issuing it did not
  /// invalidate any ticket other callers hold.
  final bool standalone;

  @override
  String toString() =>
      standalone ? 'SearchTicket(standalone)' : 'SearchTicket($seq)';
}

/// The best-scoring chunk of a result note: display snippet (with highlight
/// ranges) plus provenance (sourceType / sourceId / 1-based page) for the
/// source badge and deep link.
class SearchResultChunk {
  const SearchResultChunk({
    required this.snippet,
    required this.sourceType,
    this.sourceId,
    this.page,
    this.chunkKey,
  });

  final Snippet snippet;

  /// meta | note_body | subnote | annotation | attachment_text |
  /// attachment_ocr | figure
  final String sourceType;
  final String? sourceId;

  /// 1-based page for attachment-derived chunks.
  final int? page;

  /// `search_chunks.chunkKey` this hit came from — the logical chunk
  /// identity callers need to look the row back up (e.g. `search_figures`
  /// minting `<chunkKey>~<contentHash prefix>` figure ids). Null for
  /// substring-fallback results: that scan matches note text, not chunks.
  final String? chunkKey;
}

/// One note in a ranked result list.
class NoteSearchResult {
  const NoteSearchResult({
    required this.noteId,
    required this.score,
    required this.best,
    this.attachmentId,
    this.page,
    required this.layers,
    this.chunks = const [],
  });

  final String noteId;

  /// Note-level score within the producing layer: max chunk BM25 +
  /// 0.1·ln(1 + extraHits), where extraHits counts only VISIBLE chunks
  /// within the accumulated top slice (visibility-filtered chunks never
  /// contribute). Substring-fallback results carry 0.0 (the fallback is
  /// unranked; its order is pinned-first / newest-first).
  final double score;

  /// Best chunk (snippet + provenance).
  final SearchResultChunk best;

  /// Deep-link target when [best] is attachment-derived, else null.
  final String? attachmentId;

  /// 1-based page of [attachmentId], when known.
  final int? page;

  /// Layers that contributed this result (only [SearchLayer.lexical] until
  /// fusion lands).
  final Set<SearchLayer> layers;

  /// The reported matched chunks of this note, best first — [best] is
  /// `chunks.first`. At most `chunksPerNote` entries (default 1, so the note
  /// search pays nothing for this); chunk-level callers such as
  /// `search_figures` ask for more so several figures of the SAME note can
  /// be offered instead of only its best one.
  ///
  /// Empty only for hand-constructed results; every result this service
  /// produces carries at least [best].
  final List<SearchResultChunk> chunks;
}

/// A completed search: ranked results + the ticket to check for staleness,
/// plus whether the substring fallback produced them.
class SearchResponse {
  const SearchResponse({
    required this.results,
    required this.ticket,
    required this.usedSubstringFallback,
    this.scopeUnservable = false,
  });

  final List<NoteSearchResult> results;
  final SearchTicket ticket;

  /// True when the substring predicate scan produced [results] (probe
  /// failure, incomplete backfill, empty FTS query, or zero-hit rerun).
  final bool usedSubstringFallback;

  /// True when the requested scope could NOT be searched at all: the chunk
  /// index was unusable (missing chunks_fts, failed FTS4 probe, incomplete
  /// backfill) AND the substring fallback cannot produce results of the
  /// requested kind — it scans note text, so it can only answer scopes that
  /// accept `note_body`.
  ///
  /// [results] is then empty for a reason that has nothing to do with the
  /// corpus, and a caller that reports absence ("no figures found") would be
  /// asserting a confident false negative. Deliberately NOT set by the
  /// zero-hit rerun: there, FTS ran over a complete index and genuinely
  /// matched nothing.
  final bool scopeUnservable;
}

/// Layered note search (lexical now; fusion later).
class SearchService {
  /// [notesProvider] supplies the note list the substring fallback scans —
  /// injected rather than importing AppProvider (Step 5 wires AppProvider's
  /// in-memory cache; the service-locator default reads the database; tests
  /// inject fixtures).
  /// [embeddingRegistry] + [vectorSearch] enable the semantic layer in
  /// [searchFused] (either null → lexical-only, exactly the Step-5
  /// behavior). [semanticTimeout] caps the semantic wait (plan §2.3: ~2 s,
  /// then the lexical order stands — searchFused NEVER breaks).
  SearchService(
    this._db,
    this._indexService, {
    required Future<List<Note>> Function() notesProvider,
    EmbeddingProviderRegistry? embeddingRegistry,
    VectorSearch? vectorSearch,
    this.semanticTimeout = const Duration(seconds: 2),
    this.semanticTopK = 200,
  }) : _notesProvider = notesProvider,
       _embeddingRegistry = embeddingRegistry,
       _vectorSearch = vectorSearch;

  /// VISIBLE ranked chunks accumulated for result building (plan §1.4:
  /// matchinfo for all matches, full text for the top visible slice).
  /// Visibility-filtered chunks (archived notes, ai-excluded attachments)
  /// do not count against this budget.
  static const int _fetchTopChunks = 100;

  /// Page size for fetching candidate rows while filling the visible top
  /// slice ([_fetchTopChunks]).
  static const int _visibilityPageSize = 200;

  /// Weight of the extra-hits grouping bonus (plan §1.5).
  static const double _extraHitBonus = 0.1;

  /// sourceTypes derived from attachments — the ones the ai-audience
  /// includeInAIContext exclusion applies to. Chunks born from the note
  /// itself (meta/note_body/subnote/annotation) are always allowed.
  static const Set<String> _attachmentSourceTypes = {
    'attachment_text',
    'attachment_ocr',
    'figure',
  };

  /// RRF constant (plan §2.3: score = Σ 1/(60 + rank)).
  static const int _rrfK = 60;

  /// Multiplier applied to [semanticTopK] when [NoteFilterContext.sourceTypes]
  /// narrows the accepted chunk kinds — see [_semanticCandidateK].
  static const int _scopedSemanticCandidateFactor = 5;

  /// sourceTypes that make up the BULK of a real corpus. A scope naming any
  /// of them is not a narrow scope — see [_semanticCandidateK].
  static const Set<String> _bulkSourceTypes = {
    'note_body',
    'attachment_text',
    'attachment_ocr',
  };

  /// Session-scoped query-embedding LRU capacity.
  static const int _queryEmbeddingCacheCap = 32;

  final DatabaseService _db;
  final NoteIndexService _indexService;
  final Future<List<Note>> Function() _notesProvider;
  final EmbeddingProviderRegistry? _embeddingRegistry;
  final VectorSearch? _vectorSearch;

  /// Cap on the semantic layer's total wall time inside [searchFused].
  final Duration semanticTimeout;

  /// How many chunk-level vector hits feed the semantic note grouping.
  final int semanticTopK;

  /// Session-scoped LRU of query embeddings, keyed by providerKey + folded
  /// query (a re-submitted or idle-refined query never re-bills the API).
  final Map<String, Float32List> _queryEmbeddingCache = {};

  /// Memoized probe FUTURE (not result): concurrent first searches share a
  /// single in-flight probe instead of racing two CREATE TABLEs.
  Future<bool>? _ftsProbe;
  bool _backfillTriggered = false;
  int _ticketSeq = 0;
  SearchTicket? _newestTicket;

  /// The marker carried by responses of un-ticketed searches; see
  /// [SearchTicket.standalone]. Public so fakes/tests can construct
  /// responses for ticket-less searches.
  static const SearchTicket standaloneTicket = SearchTicket._(
    0,
    standalone: true,
  );

  /// The most recently issued ticket; responses carrying an older ticket are
  /// stale and should be dropped.
  SearchTicket? get newestTicket => _newestTicket;

  /// Issues a new ticket, superseding all previously issued ones.
  SearchTicket takeTicket() {
    final ticket = SearchTicket._(++_ticketSeq);
    _newestTicket = ticket;
    return ticket;
  }

  /// Whether [ticket] is still the newest (i.e. its response is not stale).
  /// Standalone markers (un-ticketed searches) are always current.
  bool isCurrent(SearchTicket ticket) =>
      ticket.standalone || _newestTicket?.seq == ticket.seq;

  /// Kicks off the index backfill if it never completed. Fire-and-forget and
  /// idempotent per service instance; called implicitly by the first query,
  /// or explicitly at startup.
  Future<void> ensureReady() async {
    if (_backfillTriggered) return;
    _backfillTriggered = true;
    unawaited(
      _indexService.ensureBackfilled().catchError((Object e) {
        LoggerService.error(
          '[SearchService] Startup backfill trigger failed: $e',
          error: e,
        );
      }),
    );
  }

  /// Lexical (FTS4 + BM25) note search. See the class comment for fallback
  /// rules and the ticket contract.
  ///
  /// [chunksPerNote] caps how many matched chunks each result reports in
  /// [NoteSearchResult.chunks] (default 1 = the best chunk only, today's
  /// behavior and cost). It never changes ranking or the grouping bonus,
  /// which always count every visible hit.
  Future<SearchResponse> searchLexical(
    String query, {
    NoteFilterContext? filter,
    SearchAudience audience = SearchAudience.user,
    SearchTicket? ticket,
    int chunksPerNote = 1,
  }) async {
    // No caller ticket: run ticket-less with a standalone marker. Deliberately
    // NOT takeTicket() — that would supersede tickets held by other callers
    // (a background AI search must not stale-out the UI's in-flight search).
    ticket ??= standaloneTicket;
    unawaited(ensureReady());
    final scope = filter ?? const NoteFilterContext();

    // Cold start: chunksFtsAvailable is populated by the DB's onOpen hook, so
    // open the database before consulting the flag (the first call into this
    // service may well precede any other DB use).
    await _db.database;

    final ftsQuery = buildFtsQuery(query);
    final ftsUsable =
        ftsQuery.isNotEmpty &&
        _db.chunksFtsAvailable &&
        await _probeFts4() &&
        await _indexService.isBackfillComplete();

    if (!ftsUsable) {
      return _fallbackResponse(query, scope, ticket, indexUsable: false);
    }

    final results = await _lexicalChunkSearch(
      query,
      ftsQuery,
      scope,
      audience,
      chunksPerNote,
    );
    if (results.isEmpty) {
      // Complete-index zero-hit rerun (plan §1.5): the substring scan is the
      // status-quo cost and catches content the index deliberately lacks
      // (e.g. policy-excluded notes).
      return _fallbackResponse(query, scope, ticket, indexUsable: true);
    }
    return SearchResponse(
      results: results,
      ticket: ticket,
      usedSubstringFallback: false,
    );
  }

  /// The substring fallback, or an empty response when it cannot serve the
  /// scope. The scan matches in-memory NOTE TEXT, so every result it can
  /// produce is a `note_body` one: answering a search scoped to other chunk
  /// sources (figures, attachment pages) with a list of notes would hand the
  /// caller hits of a kind it explicitly did not ask for.
  ///
  /// [indexUsable] distinguishes the two ways the caller gets here. False —
  /// the chunk index could not be queried — makes an empty scoped response
  /// [SearchResponse.scopeUnservable], so the caller can say "not searchable
  /// right now" instead of "not there".
  Future<SearchResponse> _fallbackResponse(
    String query,
    NoteFilterContext scope,
    SearchTicket ticket, {
    required bool indexUsable,
  }) async {
    final sourceTypes = scope.sourceTypes;
    if (sourceTypes != null &&
        sourceTypes.isNotEmpty &&
        !sourceTypes.contains('note_body')) {
      return SearchResponse(
        results: const [],
        ticket: ticket,
        usedSubstringFallback: false,
        scopeUnservable: !indexUsable,
      );
    }
    return SearchResponse(
      results: await _substringSearch(query, scope),
      ticket: ticket,
      usedSubstringFallback: true,
    );
  }

  /// Fused multi-layer search: lexical ∥ semantic, grouped to note level
  /// per layer, fused with Reciprocal Rank Fusion (plan §2.3).
  ///
  /// The semantic layer contributes only when a SERVING provider exists,
  /// the chunk backfill is complete, and its query embedding + topK finish
  /// within [semanticTimeout]. On any failure/timeout the lexical results
  /// stand unchanged — the lexical floor is never broken.
  Future<SearchResponse> searchFused(
    String query, {
    NoteFilterContext? filter,
    SearchAudience audience = SearchAudience.user,
    SearchTicket? ticket,
    int chunksPerNote = 1,
  }) async {
    final scope = filter ?? const NoteFilterContext();
    // Kick off the semantic layer BEFORE awaiting lexical so the two run
    // concurrently. Guarded end-to-end: null means "no semantic this time".
    final semanticFuture = _semanticLayerGuarded(
      query,
      scope,
      audience,
      chunksPerNote,
    );
    final lexical = await searchLexical(
      query,
      filter: filter,
      audience: audience,
      ticket: ticket,
      chunksPerNote: chunksPerNote,
    );
    final semantic = await semanticFuture;
    if (semantic == null || semantic.isEmpty) return lexical;
    return SearchResponse(
      results: fuseRrf(lexical.results, semantic, chunksPerNote: chunksPerNote),
      ticket: lexical.ticket,
      usedSubstringFallback: lexical.usedSubstringFallback,
      // The semantic layer produced in-scope results (it applies the same
      // scope filters), so the scope WAS servable even if the lexical layer
      // could not serve it — e.g. a platform whose sqlite lacks FTS4.
      scopeUnservable: false,
    );
  }

  /// [_semanticLayer] wrapped so it can never throw past this point and
  /// never outlive [semanticTimeout].
  Future<List<NoteSearchResult>?> _semanticLayerGuarded(
    String query,
    NoteFilterContext scope,
    SearchAudience audience,
    int chunksPerNote,
  ) async {
    if (_embeddingRegistry == null || _vectorSearch == null) return null;
    try {
      return await _semanticLayer(
        query,
        scope,
        audience,
        chunksPerNote,
      ).timeout(semanticTimeout, onTimeout: () => null);
    } catch (e) {
      // Semantic failures (provider errors, network, anything) leave the
      // lexical results standing; the pipeline surfaces indexing-side
      // errors, not the query path.
      LoggerService.warning('[SearchService] Semantic layer failed: $e');
      return null;
    }
  }

  /// Semantic retrieval: embed the query with the SERVING provider (the one
  /// whose vectors are stored — plan §2.3), topK over the vector index, map
  /// chunk ids through the SAME visibility/audience/tag filters as the
  /// lexical layer, and group to note level. Null when the layer is
  /// unavailable (no serving provider, or backfill incomplete — embeddings
  /// are equally incomplete then).
  Future<List<NoteSearchResult>?> _semanticLayer(
    String query,
    NoteFilterContext scope,
    SearchAudience audience,
    int chunksPerNote,
  ) async {
    if (query.trim().isEmpty) return null;
    final registry = _embeddingRegistry!;
    await registry.ensureInitialized();
    final provider = registry.servingProvider;
    if (provider == null) return null;
    if (!await _indexService.isBackfillComplete()) return null;

    final queryVector = await _embedQueryCached(provider, query);
    final hits = await _vectorSearch!.topK(
      provider.providerKey,
      queryVector,
      k: _semanticCandidateK(scope),
    );
    if (hits.isEmpty) return const [];
    final grouped = await _accumulateVisibleGroups(
      [for (final hit in hits) _ScoredDocid(hit.chunkId, hit.score)],
      scope,
      audience,
      chunksPerNote,
    );
    // Semantic-only results still get snippets: headline the best chunk's
    // text with no highlight terms (plan handoff).
    return _buildGroupResults(grouped.groups, grouped.order, const [], const {
      SearchLayer.semantic,
    });
  }

  /// How many vector candidates to pull for [scope].
  ///
  /// A NARROW source scope accepts a small minority of the matrix (figure
  /// chunks are far outnumbered by text chunks), so the default k would
  /// arrive already spent on chunks the scope rejects and the semantic layer
  /// would contribute nothing. The vector scan scores every row regardless of
  /// k — only the returned list grows — so widening the candidate pool for
  /// such a query is close to free.
  ///
  /// A scope that names a BULK source type is not narrow: on a PDF library
  /// `{attachment_text, attachment_ocr}` is the majority of the matrix, and
  /// widening there is pure waste — 1000 candidates to accept roughly the
  /// same ones the default 200 already held.
  int _semanticCandidateK(NoteFilterContext scope) {
    final sourceTypes = scope.sourceTypes;
    if (sourceTypes == null || sourceTypes.isEmpty) return semanticTopK;
    if (sourceTypes.any(_bulkSourceTypes.contains)) return semanticTopK;
    return semanticTopK * _scopedSemanticCandidateFactor;
  }

  /// Session-scoped LRU over query embeddings, keyed by providerKey +
  /// case/width-folded query.
  Future<Float32List> _embedQueryCached(
    EmbeddingProvider provider,
    String query,
  ) async {
    final cacheKey = '${provider.providerKey} ${foldForMatch(query).trim()}';
    final cached = _queryEmbeddingCache.remove(cacheKey);
    if (cached != null) {
      _queryEmbeddingCache[cacheKey] = cached; // Re-insert: most recent.
      return cached;
    }
    final vector = await provider.embedQuery(query);
    _queryEmbeddingCache[cacheKey] = vector;
    while (_queryEmbeddingCache.length > _queryEmbeddingCacheCap) {
      _queryEmbeddingCache.remove(_queryEmbeddingCache.keys.first);
    }
    return vector;
  }

  /// Reciprocal Rank Fusion over note-level layer lists (plan §2.3):
  /// fusedScore(note) = Σ_layers 1/(60 + rank), rank 1-based within each
  /// layer. Notes in both layers carry the lexical best chunk (it has
  /// highlight ranges); semantic-only notes keep their headline snippet.
  /// Ties: lexical-ranked notes before semantic-only ones, then by the
  /// contributing layer rank, then noteId (fully deterministic — pinned by
  /// test).
  ///
  /// A note found by BOTH layers keeps the UNION of their chunk lists, up to
  /// [chunksPerNote] — see [_mergeChunks]. Keeping only the lexical list
  /// would silently drop every chunk the semantic layer alone found, which is
  /// exactly the multimodal case chunk-level callers like `search_figures`
  /// exist for: a figure matched by image embedding but not by caption text
  /// would never be offered as soon as any other chunk of its note matched
  /// lexically.
  @visibleForTesting
  static List<NoteSearchResult> fuseRrf(
    List<NoteSearchResult> lexical,
    List<NoteSearchResult> semantic, {
    int chunksPerNote = 1,
  }) {
    final scores = <String, double>{};
    final lexicalRank = <String, int>{};
    final semanticRank = <String, int>{};
    final byNote = <String, NoteSearchResult>{};
    final semanticByNote = <String, NoteSearchResult>{};
    final layersByNote = <String, Set<SearchLayer>>{};
    for (var i = 0; i < lexical.length; i++) {
      final result = lexical[i];
      scores[result.noteId] =
          (scores[result.noteId] ?? 0) + 1 / (_rrfK + i + 1);
      lexicalRank[result.noteId] = i;
      byNote[result.noteId] = result; // Lexical best wins (has highlights).
      (layersByNote[result.noteId] ??= {}).addAll(result.layers);
    }
    for (var i = 0; i < semantic.length; i++) {
      final result = semantic[i];
      scores[result.noteId] =
          (scores[result.noteId] ?? 0) + 1 / (_rrfK + i + 1);
      semanticRank[result.noteId] = i;
      semanticByNote[result.noteId] = result;
      byNote.putIfAbsent(result.noteId, () => result);
      (layersByNote[result.noteId] ??= {}).addAll(result.layers);
    }
    final noteIds = scores.keys.toList()
      ..sort((a, b) {
        final byScore = scores[b]!.compareTo(scores[a]!);
        if (byScore != 0) return byScore;
        final aLex = lexicalRank[a];
        final bLex = lexicalRank[b];
        if (aLex != null && bLex != null) return aLex.compareTo(bLex);
        if (aLex != null) return -1;
        if (bLex != null) return 1;
        final bySemantic = semanticRank[a]!.compareTo(semanticRank[b]!);
        if (bySemantic != 0) return bySemantic;
        return a.compareTo(b);
      });
    return [
      for (final noteId in noteIds)
        () {
          final base = byNote[noteId]!;
          final other = identical(base, semanticByNote[noteId])
              ? null
              : semanticByNote[noteId];
          return NoteSearchResult(
            noteId: noteId,
            score: scores[noteId]!,
            best: base.best,
            attachmentId: base.attachmentId,
            page: base.page,
            layers: Set.unmodifiable(layersByNote[noteId]!),
            chunks: _mergeChunks(base, other, chunksPerNote),
          );
        }(),
    ];
  }

  /// Both layers' chunk lists for one note, deduped by `chunkKey` and capped
  /// at [chunksPerNote]. [base]'s best chunk stays first (so `best ==
  /// chunks.first` still holds); the rest interleave base/other so a chunk
  /// only the second layer found still reaches the caller when the first
  /// layer alone would have filled the budget. [other] may be null (the note
  /// came from one layer).
  static List<SearchResultChunk> _mergeChunks(
    NoteSearchResult base,
    NoteSearchResult? other,
    int chunksPerNote,
  ) {
    final budget = chunksPerNote < 1 ? 1 : chunksPerNote;
    if (other == null || other.chunks.isEmpty) {
      return base.chunks.length <= budget
          ? base.chunks
          : base.chunks.sublist(0, budget);
    }
    final merged = <SearchResultChunk>[];
    final seen = <String>{};
    void take(SearchResultChunk chunk) {
      final key = chunk.chunkKey;
      if (key != null && !seen.add(key)) return;
      if (merged.length < budget) merged.add(chunk);
    }

    for (
      var i = 0;
      i < math.max(base.chunks.length, other.chunks.length) &&
          merged.length < budget;
      i++
    ) {
      if (i < base.chunks.length) take(base.chunks[i]);
      if (i < other.chunks.length) take(other.chunks[i]);
    }
    return merged;
  }

  // ── Lexical pipeline ─────────────────────────────────────────────────────

  Future<List<NoteSearchResult>> _lexicalChunkSearch(
    String rawQuery,
    String ftsQuery,
    NoteFilterContext scope,
    SearchAudience audience,
    int chunksPerNote,
  ) async {
    final List<ChunkFtsMatch> matches;
    try {
      // The scope goes into the SQL: searchChunksLexical's runaway cap is an
      // unordered LIMIT, so an unscoped candidate pool on a large corpus is
      // the LOWEST 5000 docids — which on a PDF-heavy library contains no
      // figure chunks at all (they are written last, so they carry the
      // highest ids). See searchChunksLexical's doc comment.
      matches = await _db.searchChunksLexical(
        ftsQuery,
        sourceTypes: scope.sourceTypes,
        noteId: scope.noteId,
      );
    } catch (e) {
      // A MATCH failure must degrade, never break search.
      LoggerService.error('[SearchService] FTS query failed: $e', error: e);
      return [];
    }
    if (matches.isEmpty) return [];

    // Rank ALL matches in Dart (avoids rank truncation), then fetch text for
    // only the top slice. Deterministic tiebreak (pinned by test): equal
    // BM25 -> higher docid first (a higher rowid is the newer chunk).
    final scored = <_ScoredDocid>[];
    for (final match in matches) {
      try {
        scored.add(
          _ScoredDocid(match.docid, bm25FromMatchinfo(match.matchinfo)),
        );
      } on FormatException catch (e) {
        LoggerService.warning(
          '[SearchService] Skipping undecodable matchinfo for docid '
          '${match.docid}: $e',
        );
      }
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.docid.compareTo(a.docid);
    });

    final grouped = await _accumulateVisibleGroups(
      scored,
      scope,
      audience,
      chunksPerNote,
    );
    return _buildGroupResults(
      grouped.groups,
      grouped.order,
      extractHighlightTerms(rawQuery),
      const {SearchLayer.lexical},
    );
  }

  /// Pages through a ranked (chunkId, score) list, applying visibility
  /// filters per page, until [_fetchTopChunks] VISIBLE chunks are
  /// accumulated or the list is exhausted. Filtering before counting keeps
  /// invisible chunks (archived notes, ai-excluded attachments, notes
  /// missing required tags) from consuming top-N slots and starving visible
  /// notes ranked below them.
  ///
  /// Grouping — and the extra-hit bonus — runs over the accumulated VISIBLE
  /// set only: the first visible chunk seen for a note is its best chunk;
  /// every further visible chunk within the top slice is an extra hit.
  ///
  /// Shared by the lexical and semantic layers so both apply the SAME
  /// pagination/visibility/audience/tag rules (plan §2.3).
  Future<({Map<String, _NoteGroup> groups, List<String> order})>
  _accumulateVisibleGroups(
    List<_ScoredDocid> scored,
    NoteFilterContext scope,
    SearchAudience audience,
    int chunksPerNote,
  ) async {
    final requiredTags = scope.requiredTags;
    final scopeTags = scope.scopeTags;
    final hasScopeFilter = scopeTags != null && scopeTags.isNotEmpty;
    final hasTagFilter =
        (requiredTags != null && requiredTags.isNotEmpty) || hasScopeFilter;
    final sourceTypes = scope.sourceTypes;
    final hasSourceFilter = sourceTypes != null && sourceTypes.isNotEmpty;
    final onlyNoteId = scope.noteId;
    final chunkBudget = chunksPerNote < 1 ? 1 : chunksPerNote;
    // Tag names per noteId, loaded one batch query per page and cached for
    // the duration of this search call.
    final tagsByNote = <String, Set<String>>{};
    final groups = <String, _NoteGroup>{};
    final order = <String>[];
    var visibleCount = 0;
    for (
      var offset = 0;
      offset < scored.length && visibleCount < _fetchTopChunks;
      offset += _visibilityPageSize
    ) {
      final page = scored.sublist(
        offset,
        math.min(offset + _visibilityPageSize, scored.length),
      );
      // Scope predicates travel into the fetch so out-of-scope rows never
      // have their (potentially kilobyte-sized) `text` read just to be
      // dropped below. The Dart-side checks stay: they are the contract.
      final rows = await _db.getSearchChunksByIds(
        [for (final s in page) s.docid],
        sourceTypes: sourceTypes,
        noteId: onlyNoteId,
      );
      final rowsById = {for (final row in rows) row.id: row};
      if (hasTagFilter) {
        await _loadTagsForNotes({
          for (final row in rows) row.noteId,
        }, tagsByNote);
      }
      for (final entry in page) {
        if (visibleCount >= _fetchTopChunks) break;
        final row = rowsById[entry.docid];
        if (row == null) continue; // Note deleted between match and fetch.
        if (onlyNoteId != null && row.noteId != onlyNoteId) continue;
        if (hasSourceFilter && !sourceTypes.contains(row.sourceType)) continue;
        if (!scope.includeArchived && row.noteIsArchived) continue;
        if (audience == SearchAudience.ai &&
            _attachmentSourceTypes.contains(row.sourceType) &&
            row.attachmentIncludeInAIContext != true) {
          // Attachment-derived chunk whose attachment opted out of AI context
          // (or whose attachment no longer exists — treated conservatively).
          continue;
        }
        if (hasTagFilter &&
            !_satisfiesTagScope(scope, tagsByNote[row.noteId])) {
          // Note lacks a required tag, or falls outside the active Space.
          continue;
        }
        visibleCount++;
        final group = groups[row.noteId];
        if (group == null) {
          groups[row.noteId] = _NoteGroup(
            best: row,
            bestScore: entry.score,
            chunkBudget: chunkBudget,
          );
          order.add(row.noteId);
        } else {
          group.addHit(row);
        }
      }
    }
    return (groups: groups, order: order);
  }

  /// Builds ranked note-level results from accumulated visible groups.
  /// [highlightTerms] may be empty (semantic-only results headline the best
  /// chunk with no highlights). Shared by both layers.
  List<NoteSearchResult> _buildGroupResults(
    Map<String, _NoteGroup> groups,
    List<String> order,
    List<String> highlightTerms,
    Set<SearchLayer> layers,
  ) {
    final results = <NoteSearchResult>[];
    for (final noteId in order) {
      final group = groups[noteId]!;
      final best = group.best;
      // Grouping bonus applied exactly once, at note level (plan §1.5).
      final score =
          group.bestScore + _extraHitBonus * math.log(1 + group.extraHits);
      final isAttachment = _attachmentSourceTypes.contains(best.sourceType);
      final bestChunk = _chunkOf(best, highlightTerms);
      results.add(
        NoteSearchResult(
          noteId: noteId,
          score: score,
          best: bestChunk,
          attachmentId: isAttachment ? best.sourceId : null,
          page: isAttachment ? best.page : null,
          layers: layers,
          chunks: [
            bestChunk,
            for (final row in group.retained) _chunkOf(row, highlightTerms),
          ],
        ),
      );
    }
    // Note-level order: score desc; ties broken by best-chunk docid desc
    // (newer note content first), mirroring the chunk-level tiebreak.
    results.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return groups[b.noteId]!.best.id.compareTo(groups[a.noteId]!.best.id);
    });
    return results;
  }

  /// Presentation form of one matched chunk row (snippet + provenance +
  /// chunk identity).
  static SearchResultChunk _chunkOf(
    SearchChunkRow row,
    List<String> highlightTerms,
  ) => SearchResultChunk(
    snippet: buildSnippet(row.text, highlightTerms),
    sourceType: row.sourceType,
    sourceId: row.sourceId,
    page: row.page,
    chunkKey: row.chunkKey,
  );

  /// Whether a note carrying [noteTags] passes [scope]'s tag rules.
  ///
  /// Two independent gates, matching `DatabaseService.searchNotesFTS`:
  /// `requiredTags` are ANDed unconditionally (the caller's own filter, never
  /// escapable), while `scopeTags` are ANDed as a group that the reserved
  /// `all-spaces` tag can OR its way past when `includeAllSpacesTag` is set.
  ///
  /// A null [noteTags] means the note has no tags loaded — treated as no tags
  /// at all, so it fails any non-empty requirement.
  static bool _satisfiesTagScope(
    NoteFilterContext scope,
    Set<String>? noteTags,
  ) {
    final tags = noteTags ?? const <String>{};

    final required = scope.requiredTags;
    if (required != null && !required.every(tags.contains)) return false;

    final scopeTags = scope.scopeTags;
    if (scopeTags == null || scopeTags.isEmpty) return true;
    if (scopeTags.every(tags.contains)) return true;
    return scope.includeAllSpacesTag && tags.contains(allSpacesTag);
  }

  /// Batch-loads tag names for [noteIds] into [cache] — one IN() query per
  /// call covering only the ids not already cached (a visibility page holds
  /// at most [_visibilityPageSize] distinct notes, well under SQLite's
  /// variable limit). Notes without tags cache as an empty set so repeat
  /// pages never re-query them.
  Future<void> _loadTagsForNotes(
    Set<String> noteIds,
    Map<String, Set<String>> cache,
  ) async {
    final missing = [
      for (final id in noteIds)
        if (!cache.containsKey(id)) id,
    ];
    if (missing.isEmpty) return;
    for (final id in missing) {
      cache[id] = <String>{};
    }
    final db = await _db.database;
    final placeholders = List.filled(missing.length, '?').join(',');
    // `t.__deleted__ = 0`, matching DatabaseService.searchNotesFTS' tag
    // EXISTS: a deleted tag is a tombstone, and `note_tags` is an OR-Set
    // membership table that `deleteTag` hard-deletes alongside it — so the
    // in-app path never produces a live membership row for a dead tag. One
    // written out of band (sync, raw SQL) would, and the names loaded here
    // decide a `requiredTags` scope, so a deleted tag must not satisfy it.
    final rows = await db.rawQuery('''
      SELECT nt.noteId, t.name
      FROM note_tags nt
      JOIN tags t ON t.id = nt.tagId AND t.__deleted__ = 0
      WHERE nt.noteId IN ($placeholders)
    ''', missing);
    for (final row in rows) {
      cache[row['noteId'] as String]!.add(row['name'] as String);
    }
  }

  // ── Substring fallback ───────────────────────────────────────────────────

  /// Case-insensitive contains scan over title/content/tags (the extracted
  /// notes_screen predicate), ordered pinned-first / newest-first like the
  /// screens it substitutes for. Scans in-memory note text only, so the
  /// ai-audience attachment exclusion is vacuous here.
  Future<List<NoteSearchResult>> _substringSearch(
    String query,
    NoteFilterContext scope,
  ) async {
    final notes = await _notesProvider();
    // Fold the query ONCE (matchesSubstringQuery would re-fold it per note);
    // an empty/whitespace-only query means "match everything", per the
    // screen semantics of an empty search box.
    final folded = foldForMatch(query);
    final matchAll = folded.trim().isEmpty;
    // requiredTags / scopeTags apply here too (over the in-memory note.tags),
    // keeping the fallback consistent with the FTS path.
    final requiredTags = scope.requiredTags;
    final scopeTags = scope.scopeTags;
    final hasTagFilter =
        (requiredTags != null && requiredTags.isNotEmpty) ||
        (scopeTags != null && scopeTags.isNotEmpty);
    final onlyNoteId = scope.noteId;
    final matched = [
      for (final note in notes)
        if ((onlyNoteId == null || note.id == onlyNoteId) &&
            (scope.includeArchived || !note.isArchived) &&
            (!hasTagFilter || _satisfiesTagScope(scope, note.tags.toSet())) &&
            (matchAll || _matchesFoldedQuery(note, folded)))
          note,
    ];
    matched.sort((a, b) {
      if (a.pinned && !b.pinned) return -1;
      if (!a.pinned && b.pinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    if (matchAll) {
      // Empty/whitespace query == "show all notes": there is nothing to
      // highlight, so skip snippet construction entirely instead of copying
      // every note's full content into a head snippet.
      return [
        for (final note in matched)
          NoteSearchResult(
            noteId: note.id,
            score: 0.0,
            best: _emptyBodyChunk,
            layers: const {SearchLayer.lexical},
            chunks: _emptyBodyChunks,
          ),
      ];
    }
    final highlightTerms = extractHighlightTerms(query);
    return [
      for (final note in matched)
        () {
          final chunk = SearchResultChunk(
            snippet: buildSnippet(note.content, highlightTerms),
            sourceType: 'note_body',
          );
          return NoteSearchResult(
            noteId: note.id,
            score: 0.0,
            best: chunk,
            layers: const {SearchLayer.lexical},
            chunks: [chunk],
          );
        }(),
    ];
  }

  /// The headline chunk of an "empty query == show everything" fallback
  /// result: no text to snippet, nothing to highlight.
  static const SearchResultChunk _emptyBodyChunk = SearchResultChunk(
    snippet: Snippet(
      text: '',
      matches: [],
      truncatedStart: false,
      truncatedEnd: false,
    ),
    sourceType: 'note_body',
  );
  static const List<SearchResultChunk> _emptyBodyChunks = [_emptyBodyChunk];

  /// `matchesSubstringQuery` (utils/note_text_match.dart) with the query
  /// pre-folded, so the fold happens once per search instead of once per
  /// note. Keep the predicates in sync.
  static bool _matchesFoldedQuery(Note note, String foldedQuery) =>
      foldForMatch(note.title).contains(foldedQuery) ||
      foldForMatch(note.content).contains(foldedQuery) ||
      note.tags.any((tag) => foldForMatch(tag).contains(foldedQuery));

  // ── FTS4 capability probe ────────────────────────────────────────────────

  /// Runtime FTS4 capability probe (plan §1.5 / platform-risk mitigation):
  /// tries to CREATE a throwaway FTS4 table in the temp schema. Memoized as
  /// a Future so concurrent first searches share one in-flight probe. This —
  /// combined with [DatabaseService.chunksFtsAvailable]
  /// — is the real gate for the lexical path: chunksFtsAvailable proves the
  /// table exists, the probe proves the loaded sqlite still speaks FTS4.
  Future<bool> _probeFts4() => _ftsProbe ??= _runFtsProbe();

  Future<bool> _runFtsProbe() async {
    try {
      final db = await _db.database;
      try {
        await db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS temp.fts_probe USING fts4(x)',
        );
        return true;
      } finally {
        await db.execute('DROP TABLE IF EXISTS temp.fts_probe');
      }
    } catch (e) {
      LoggerService.warning(
        '[SearchService] FTS4 probe failed, using substring fallback: $e',
      );
      return false;
    }
  }

  /// Overrides (or with null, clears) the cached FTS4 probe result — for
  /// simulating platforms without FTS4.
  @visibleForTesting
  void debugSetFtsProbeResult(bool? value) =>
      _ftsProbe = value == null ? null : Future.value(value);
}

class _ScoredDocid {
  const _ScoredDocid(this.docid, this.score);
  final int docid;
  final double score;
}

class _NoteGroup {
  _NoteGroup({
    required this.best,
    required this.bestScore,
    required this.chunkBudget,
  });
  final SearchChunkRow best;
  final double bestScore;

  /// Total chunks reported for this note, [best] included (`chunksPerNote`).
  final int chunkBudget;

  /// Every visible hit beyond [best] — the grouping bonus counts all of
  /// them, whether or not they fit in [chunkBudget].
  int extraHits = 0;

  /// The hits (beyond [best]) actually reported to the caller.
  final List<SearchChunkRow> retained = [];

  void addHit(SearchChunkRow row) {
    extraHits++;
    if (retained.length + 1 < chunkBudget) retained.add(row);
  }
}
