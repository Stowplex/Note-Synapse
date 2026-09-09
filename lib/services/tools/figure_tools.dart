// `search_figures` (plan §4.2) — retrieval of visuals that ALREADY exist in
// the user's notes, so a reply can embed one instead of generating an image.
//
// This tool is deliberately MECHANICAL: input, ranked hits, and the exact
// markdown to paste. The reply-quality guidance (when to search, how to pick
// among hits, caption/provenance phrasing, what to say when nothing matches)
// lives in the user-installable "Figure Answers" agent skill
// (assets/starter/skills/Figure_Answers.md), which the user can read, edit and
// disable. Only ONE behavioural sentence stays in [description] — the minimum
// that must hold in sessions where the skill is not installed.
//
// Output rules (load-bearing, see the plan and figure_resolver.dart's header):
//   * An extracted figure/table REGION embeds as an image through its
//     content-addressed figure URI: `synapseresource://figure/<figureId>`,
//     where figureId is minted ONLY by [FigureResolver.buildFigureId] from the
//     chunk ROW's contentHash — never from the derived PNG's bytes.
//   * A raster IMAGE attachment embeds through
//     `synapseresource://attachment/<id>` (the file itself is the image; there
//     is no derived crop).
//   * Anything else that cannot be rendered inline — an SVG, a figure chunk
//     whose crop has not been extracted (yet) — is a LINK that keeps its
//     caption and says WHY it is a link. The `?page=` suffix is added only
//     when the source paginates: a single image file has no page 1.
//   * A whole PDF PAGE is offered as a plain LINK
//     `[title, p.N](synapseresource://attachment/<id>?page=N)` and NEVER as an
//     image. A page rendered inline is a low-resolution thumbnail with no
//     value over a tappable deep link — this is a product decision, not an
//     implementation detail.
//
// All markdown is produced by [AttachmentLinkService] (the shared generator
// that also feeds the editor's link/figure insertion), so the tool's output
// and the app's own links can never drift apart.
//
// Retrieval runs through [SearchService.searchFused] scoped to figure chunks
// (`NoteFilterContext.sourceTypes`), so it is semantic whenever a multimodal
// embedding provider is serving and lexical otherwise, and it inherits the
// audience/tag filtering of every other search — an attachment with
// `includeInAIContext = false` can never surface here. Because it reads the
// live index, a deleted figure simply stops being offered.
//
// HONESTY CONTRACT: an empty result is only ever reported as "not found" when
// the index could actually answer the question. The report carries a `Scope:`
// line (what was excluded) and, whenever the index is still being built or
// could not be queried at all, an `Index:` line saying so — because during a
// backfill, "no figures found" is a confident false negative.

import 'dart:convert';

import '../../models/attachment.dart';
import '../../utils/file_type_utils.dart';
import '../attachment_link_service.dart';
import '../database_service.dart';
import '../logger_service.dart';
import '../search/attachment_ocr_extractor.dart';
import '../search/embedding/embedding_provider_registry.dart';
import '../search/figure_resolver.dart';
import '../search/note_index_service.dart';
import '../search/search_service.dart';
import '../search_settings_service.dart';
import '../service_locator.dart';
import 'note_tools.dart';

/// Ranked retrieval of figures, images and PDF pages from the note index.
class FigureSearchTool implements NativeTool {
  /// All dependencies are injectable so the tool can be exercised without a
  /// service locator; production instances resolve through `getIt`.
  FigureSearchTool({
    DatabaseService? db,
    SearchService? searchService,
    EmbeddingProviderRegistry? embeddingRegistry,
    SearchSettingsService? settings,
    NoteIndexService? indexService,
  }) : _db = db,
       _searchService = searchService,
       _embeddingRegistry = embeddingRegistry,
       _settings = settings,
       _indexService = indexService;

  final DatabaseService? _db;
  final SearchService? _searchService;
  final EmbeddingProviderRegistry? _embeddingRegistry;
  final SearchSettingsService? _settings;
  final NoteIndexService? _indexService;

  /// Default number of hits.
  static const int defaultLimit = 5;

  /// Hard cap: every hit costs the model a markdown line it may embed.
  static const int maxLimit = 20;

  /// Chunk sourceTypes that describe a whole PDF page — the link-only
  /// degradation used when no figure region was extracted (plan §4.1).
  static const Set<String> pageSourceTypes = {
    'attachment_text',
    'attachment_ocr',
  };

  DatabaseService get _database => _db ?? getIt<DatabaseService>();

  SearchService get _search => _searchService ?? getIt<SearchService>();

  SearchSettingsService get _searchSettings =>
      _settings ?? SearchSettingsService();

  /// Null when no registry is available (tests, or before the locator is
  /// initialized) — read as "no embedding provider", which is exactly what
  /// the layer-state report should then say.
  EmbeddingProviderRegistry? get _registry =>
      _embeddingRegistry ??
      (getIt.isRegistered<EmbeddingProviderRegistry>()
          ? getIt<EmbeddingProviderRegistry>()
          : null);

  /// Null when the indexer is not reachable — read as "index state unknown",
  /// which reports nothing rather than guessing either way.
  NoteIndexService? get _index =>
      _indexService ??
      (getIt.isRegistered<NoteIndexService>()
          ? getIt<NoteIndexService>()
          : null);

  @override
  String get name => 'search_figures';

  /// Read-only: this ranks material already in the index and never writes.
  @override
  bool get isMutating => false;

  @override
  String get description => '''
Search the user's notes for visuals that already exist: figure/table regions extracted from PDFs, image attachments, and — when no figure region was extracted — the PDF pages that match. Ranked over the note index (semantic when a multimodal embedding provider is active, lexical otherwise).
Returns a numbered list; each hit carries its caption, source note and page, plus a ready-to-use markdown line, above a Scope/Index report saying what was excluded and whether the index could answer at all.
Figures embed as images; pages are links, never images; prefer retrieving an existing figure over generating one.
''';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'What the figure shows — caption wording, subject, or a '
            'description of the visual.',
      },
      'noteId': {
        'type': 'string',
        'description':
            'Optional: restrict the search to a single note. Naming a note '
            'also opts its archived figures back in.',
      },
      'limit': {
        'type': 'integer',
        'description':
            'Maximum hits to return (default $defaultLimit, max $maxLimit).',
      },
    },
    'required': ['query'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final query = (args['query'] as String? ?? '').trim();
    final rawNoteId = (args['noteId'] as String? ?? '').trim();
    final noteId = rawNoteId.isEmpty ? null : rawNoteId;
    final limit = _resolveLimit(args['limit']);
    final layerState = await _layerStateLine();
    final backfillComplete = await _backfillComplete();

    if (query.isEmpty) {
      return 'search_figures: a `query` is required — describe what the '
          'figure shows.\n$layerState';
    }

    final session = _LookupSession(_database);
    final List<_FigureHit> hits;
    final bool scopeUnservable;
    try {
      final figures = await _figureHits(session, query, noteId, limit);
      var collected = figures.hits;
      var unservable = figures.scopeUnservable;
      if (collected.length < limit) {
        final pages = await _pageHits(
          session,
          query,
          noteId,
          limit - collected.length,
          collected,
        );
        collected = [...collected, ...pages.hits];
        unservable = unservable || pages.scopeUnservable;
      }
      hits = collected;
      scopeUnservable = unservable;
    } catch (e) {
      LoggerService.error('[search_figures] Search failed: $e', error: e);
      return 'search_figures: the search failed ($e).\n$layerState';
    }
    return _render(
      query: query,
      hits: hits,
      layers: layerState,
      scope: _scopeLine(noteId),
      index: _indexLine(
        backfillComplete: backfillComplete,
        scopeUnservable: scopeUnservable,
      ),
      links: session.links,
    );
  }

  static int _resolveLimit(Object? raw) {
    final value = raw is int ? raw : int.tryParse('${raw ?? ''}');
    if (value == null) return defaultLimit;
    return value.clamp(1, maxLimit);
  }

  // ── Retrieval ────────────────────────────────────────────────────────────

  /// Figure-chunk hits, best first. The search is scoped to `figure` chunks
  /// so out-of-scope chunks can never consume the top slice, and the rows are
  /// re-read afterwards: the figureId's hash half must come from the CURRENT
  /// row, and a figure deleted since the query simply drops out.
  Future<_HitBatch> _figureHits(
    _LookupSession session,
    String query,
    String? noteId,
    int limit,
  ) async {
    final response = await _search.searchFused(
      query,
      // The ai audience drops chunks of attachments with
      // includeInAIContext = false — including figure chunks.
      audience: SearchAudience.ai,
      filter: NoteFilterContext(
        sourceTypes: const {FigureResolver.figureSourceType},
        noteId: noteId,
        // Archived notes stay out of an open search (unlike search_notes,
        // which opts INTO archived material): a hit here gets rendered into
        // the reply as a picture, and archived is the user saying "keep this
        // out of the way". A noteId-scoped call is the opposite situation —
        // the user named that note — so it opts archived back in. Either way
        // the `Scope:` line says which rule applied, because an exclusion the
        // model cannot see becomes an assertion of absence.
        includeArchived: noteId != null,
      ),
      chunksPerNote: limit,
    );

    final chunkKeys = <String>[];
    for (final result in response.results) {
      for (final chunk in result.chunks) {
        if (chunk.sourceType != FigureResolver.figureSourceType) continue;
        final key = chunk.chunkKey;
        if (key == null || chunkKeys.contains(key)) continue;
        chunkKeys.add(key);
        if (chunkKeys.length >= limit) break;
      }
      if (chunkKeys.length >= limit) break;
    }
    if (chunkKeys.isEmpty) {
      return _HitBatch(const [], response.scopeUnservable);
    }

    final rows = await session.figureRows(chunkKeys);
    final hits = <_FigureHit>[];
    // Two crop-less figure chunks on the same page point at the SAME page;
    // offering both would burn two of the user's `limit` slots on one
    // destination. Distinct figures keep distinct figure ids, so real figures
    // never collide here.
    final targets = <String>{};
    for (final key in chunkKeys) {
      final row = rows[key];
      if (row == null) continue; // Deleted between the query and this read.
      final hit = await _figureHitFor(session, row);
      if (hit == null) continue;
      if (!targets.add(hit.target)) continue;
      hits.add(hit);
    }
    return _HitBatch(hits, response.scopeUnservable);
  }

  /// One hit from a `figure` chunk row, or null when the row carries nothing
  /// that can be embedded or linked.
  Future<_FigureHit?> _figureHitFor(
    _LookupSession session,
    Map<String, Object?> row,
  ) async {
    final chunkKey = row['chunkKey'] as String;
    final contentHash = (row['contentHash'] as String?) ?? '';
    final noteId = row['noteId'] as String;
    final meta = _decodeMeta(row['meta'] as String?);
    final attachmentId =
        (row['sourceId'] as String?) ?? meta['attachmentId'] as String?;
    // meta owns the region (the page its rect is expressed in); the column is
    // the fallback. Same precedence as FigureResolver.
    final page = (meta['page'] as num?)?.toInt() ?? row['page'] as int?;
    final derivedAssetPath = (meta['derivedAssetPath'] as String?)?.trim();
    final noteTitle = _label(await session.noteTitle(noteId));
    final attachment = attachmentId == null
        ? null
        : await session.attachment(attachmentId);
    final caption =
        _label(meta['caption'] as String?) ??
        _label(_firstLine(row['text'] as String?)) ??
        _label(attachment?.fileName) ??
        'Figure';

    // An extracted REGION: content-addressed figure URI, embedded as an image.
    if (derivedAssetPath != null &&
        derivedAssetPath.isNotEmpty &&
        contentHash.isNotEmpty) {
      return _FigureHit.figure(
        caption: caption,
        noteTitle: noteTitle,
        page: page,
        attachmentId: attachmentId,
        figureId: FigureResolver.buildFigureId(chunkKey, contentHash),
      );
    }

    if (attachmentId == null) return null;

    // A raster image ATTACHMENT: the file itself is the image.
    if (attachment != null && _isEmbeddableImage(attachment)) {
      return _FigureHit.image(
        caption: caption,
        noteTitle: noteTitle,
        attachmentId: attachmentId,
      );
    }

    // Neither a crop nor an inline-renderable file — an SVG, a figure whose
    // region has not been extracted, a vanished attachment row. Offer the
    // SOURCE as a link that keeps the caption and states the real reason.
    return _FigureHit.link(
      caption: caption,
      noteTitle: noteTitle,
      attachmentId: attachmentId,
      page: _paginates(attachment) ? page : null,
      reason: _linkReason(attachment),
    );
  }

  /// Page-level hits filling the remainder of the budget — the degradation
  /// path when a matching page has no extracted figure (plan §4.1). Pages
  /// already represented by a figure hit are skipped.
  Future<_HitBatch> _pageHits(
    _LookupSession session,
    String query,
    String? noteId,
    int remaining,
    List<_FigureHit> alreadyOffered,
  ) async {
    if (remaining <= 0) return const _HitBatch([], false);
    final response = await _search.searchFused(
      query,
      audience: SearchAudience.ai,
      filter: NoteFilterContext(
        sourceTypes: pageSourceTypes,
        noteId: noteId,
        includeArchived: noteId != null,
      ),
      chunksPerNote: remaining,
    );

    final seen = {
      for (final hit in alreadyOffered)
        if (hit.dedupeKey != null) hit.dedupeKey!,
    };
    final hits = <_FigureHit>[];
    for (final result in response.results) {
      for (final chunk in result.chunks) {
        if (!pageSourceTypes.contains(chunk.sourceType)) continue;
        final attachmentId = chunk.sourceId;
        final page = chunk.page;
        if (attachmentId == null || page == null) continue;
        if (!seen.add('$attachmentId#$page')) continue;
        final attachment = await session.attachment(attachmentId);
        hits.add(
          _FigureHit.page(
            noteTitle: _label(await session.noteTitle(result.noteId)),
            attachmentId: attachmentId,
            page: page,
            fileName: _label(attachment?.fileName),
          ),
        );
        if (hits.length >= remaining) {
          return _HitBatch(hits, response.scopeUnservable);
        }
      }
    }
    return _HitBatch(hits, response.scopeUnservable);
  }

  // ── Layer / scope / index state ──────────────────────────────────────────

  /// Which retrieval layers are currently OFF — data for the skill's
  /// no-match phrasing ("nothing matched, and figure indexing is off" reads
  /// very differently from "nothing matched"). Never throws: an unreadable
  /// setting reports nothing rather than claiming a layer is off.
  Future<String> _layerStateLine() async {
    final off = <String>[];
    try {
      final registry = _registry;
      await registry?.ensureInitialized();
      final provider = registry?.servingProvider;
      if (provider == null) {
        off.add(
          'semantic + image embeddings (no embedding provider is '
          'configured — figures are matched on caption and OCR text only)',
        );
      } else if (!provider.supportsImages) {
        off.add(
          'image embeddings (the "${provider.displayName}" embedding '
          'provider is text-only — figures are matched on caption and OCR '
          'text only)',
        );
      }
    } catch (e) {
      LoggerService.warning('[search_figures] Provider state unreadable: $e');
    }
    try {
      final settings = _searchSettings;
      if (!await settings.getFigureIndexingEnabled()) {
        off.add('figure extraction (PDF figure regions are not being indexed)');
      }
      if (!await settings.getOcrEnabled()) {
        off.add('OCR (text inside images and scanned pages is not indexed)');
      }
    } catch (e) {
      LoggerService.warning('[search_figures] Settings unreadable: $e');
    }
    if (off.isEmpty) return 'Layers off: none.';
    return 'Layers off: ${off.join('; ')}.';
  }

  /// Whether the chunk backfill has finished, or null when the indexer is
  /// unreachable / unreadable (state unknown — claim nothing).
  Future<bool?> _backfillComplete() async {
    try {
      return await _index?.isBackfillComplete();
    } catch (e) {
      LoggerService.warning('[search_figures] Index state unreadable: $e');
      return null;
    }
  }

  /// What this call did NOT look at. An invisible exclusion is how a tool
  /// talks a model into asserting absence.
  static String _scopeLine(String? noteId) => noteId == null
      ? 'Scope: every note except ARCHIVED ones — archived figures are never '
            'returned by an open search. Pass `noteId` to search one note '
            'including its archived figures.'
      : 'Scope: note $noteId only, archived figures included (you named the '
            'note).';

  /// The `Index:` line, or null when the index could answer normally. Present
  /// means every empty or short result is UNRELIABLE.
  static String? _indexLine({
    required bool? backfillComplete,
    required bool scopeUnservable,
  }) {
    if (backfillComplete == false) {
      return 'Index: INCOMPLETE — the note index is still being built. '
          'Figures that are not indexed yet cannot be found, so a miss here '
          'is NOT evidence the figure is absent: say the results are '
          'incomplete and offer to look again once indexing finishes.';
    }
    if (scopeUnservable) {
      return 'Index: UNAVAILABLE — the figure index could not be queried on '
          'this device, so no figure search ran at all. A miss here is NOT '
          'evidence the figure is absent.';
    }
    return null;
  }

  // ── Rendering ────────────────────────────────────────────────────────────

  static String _render({
    required String query,
    required List<_FigureHit> hits,
    required String layers,
    required String scope,
    required String? index,
    required AttachmentLinkService links,
  }) {
    final buffer = StringBuffer();
    final subject = _label(query) ?? query;
    if (hits.isEmpty) {
      // The headline itself has to carry the caveat: a model that reads only
      // the first line must not walk away with "the figure is not there".
      const caveat =
          ' — but the index could not answer this search, so this is NOT '
          'proof the figure is absent';
      buffer.writeln(
        'search_figures: no figures or pages found for "$subject"'
        '${index == null ? '' : caveat}.',
      );
      buffer.writeln(scope);
      if (index != null) buffer.writeln(index);
      buffer.write(layers);
      return buffer.toString();
    }
    buffer.writeln('search_figures: ${hits.length} hit(s) for "$subject".');
    buffer.writeln(scope);
    if (index != null) buffer.writeln(index);
    buffer.writeln(layers);
    buffer.writeln();
    for (var i = 0; i < hits.length; i++) {
      buffer.writeln('${i + 1}. ${hits[i].headline}');
      buffer.writeln('   ${hits[i].markdown(links)}');
    }
    return buffer.toString().trimRight();
  }

  /// Whether this attachment file can BE the image of its own figure hit.
  ///
  /// Delegates to [AttachmentOcrExtractor.isRasterImageFileName] — the ONE
  /// raster-extension list the search pipeline keeps (see its doc comment).
  /// That list is what decides which attachments get a `figure` chunk in the
  /// first place, so answering from it is what keeps the tool's "this is an
  /// image" and the indexer's "this is an image" the same sentence; deriving
  /// it separately from [FileTypeUtils.isImage] minus SVG produced the same
  /// answers today only by coincidence, and would diverge the moment either
  /// list learned about `.heic`.
  static bool _isEmbeddableImage(Attachment attachment) =>
      AttachmentOcrExtractor.isRasterImageFileName(attachment.fileName);

  /// Whether `?page=N` means anything for [attachment]. A single image file
  /// has no pages, so `?page=1` on it is noise; a null attachment row is
  /// treated as paginated, since figure chunks carrying a page overwhelmingly
  /// come from PDFs.
  static bool _paginates(Attachment? attachment) =>
      attachment == null ||
      !FileTypeUtils.isImage(
        FileTypeUtils.getFileExtension(attachment.fileName),
      );

  /// Why this hit is a link and not an image — the honest reason, per case.
  static String _linkReason(Attachment? attachment) {
    if (attachment == null) {
      return 'the source file record is missing — link only';
    }
    final extension = FileTypeUtils.getFileExtension(attachment.fileName);
    if (FileTypeUtils.isImage(extension)) {
      return 'a .$extension image cannot be rendered inline — link only';
    }
    return 'no figure region has been extracted from this page — link only';
  }

  static Map<String, dynamic> _decodeMeta(String? metaJson) {
    if (metaJson == null || metaJson.isEmpty) return const {};
    try {
      final decoded = jsonDecode(metaJson);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  static String? _firstLine(String? text) {
    if (text == null) return null;
    for (final line in text.split('\n')) {
      if (line.trim().isNotEmpty) return line;
    }
    return null;
  }

  /// One-line, bracket-free, length-capped text safe to drop into a markdown
  /// label. Null for empty input. Applied to note TITLES as well as captions:
  /// a note called `[Draft] Q3` would otherwise emit `[[Draft] Q3, p.7](…)`,
  /// which is not a link, and the skill tells the model to paste verbatim.
  static String? _label(String? raw) {
    if (raw == null) return null;
    final flattened = raw
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll('[', '(')
        .replaceAll(']', ')')
        .trim();
    if (flattened.isEmpty) return null;
    return flattened.length <= _maxLabelChars
        ? flattened
        : '${flattened.substring(0, _maxLabelChars).trimRight()}…';
  }

  /// [value] wrapped in double quotes for a headline segment, with any inner
  /// double quote demoted so the quoting stays unambiguous.
  static String _quoted(String value) => '"${value.replaceAll('"', "'")}"';

  static const int _maxLabelChars = 120;
}

/// One retrieval pass: its hits plus whether the index could serve the scope
/// at all (see [SearchResponse.scopeUnservable]).
class _HitBatch {
  const _HitBatch(this.hits, this.scopeUnservable);
  final List<_FigureHit> hits;
  final bool scopeUnservable;
}

/// What a hit is, which decides how it may be rendered.
enum _HitKind {
  /// An extracted figure/table region — embeds as an image.
  figure,

  /// A raster image attachment — embeds as an image.
  image,

  /// A visual that exists but cannot be rendered inline (SVG, or a figure
  /// whose crop is not extracted) — a captioned LINK plus the reason.
  link,

  /// A whole PDF page — a LINK, never an image.
  page,
}

/// One renderable hit.
class _FigureHit {
  const _FigureHit._({
    required this.kind,
    required this.caption,
    required this.noteTitle,
    this.page,
    this.attachmentId,
    this.figureId,
    this.reason,
  });

  factory _FigureHit.figure({
    required String caption,
    required String? noteTitle,
    required int? page,
    required String? attachmentId,
    required String figureId,
  }) => _FigureHit._(
    kind: _HitKind.figure,
    caption: caption,
    noteTitle: noteTitle,
    page: page,
    attachmentId: attachmentId,
    figureId: figureId,
  );

  factory _FigureHit.image({
    required String caption,
    required String? noteTitle,
    required String attachmentId,
  }) => _FigureHit._(
    kind: _HitKind.image,
    caption: caption,
    noteTitle: noteTitle,
    attachmentId: attachmentId,
  );

  factory _FigureHit.link({
    required String caption,
    required String? noteTitle,
    required String attachmentId,
    required int? page,
    required String reason,
  }) => _FigureHit._(
    kind: _HitKind.link,
    caption: caption,
    noteTitle: noteTitle,
    page: page,
    attachmentId: attachmentId,
    reason: reason,
  );

  factory _FigureHit.page({
    required String? noteTitle,
    required String attachmentId,
    required int? page,
    String? fileName,
  }) => _FigureHit._(
    kind: _HitKind.page,
    caption: noteTitle ?? fileName ?? 'Page',
    noteTitle: noteTitle,
    page: page,
    attachmentId: attachmentId,
  );

  final _HitKind kind;
  final String caption;
  final String? noteTitle;
  final int? page;
  final String? attachmentId;
  final String? figureId;

  /// Why a [_HitKind.link] hit is not an image.
  final String? reason;

  /// `<attachmentId>#<page>` — used to keep a page link out of the results
  /// when a figure from that same page is already offered.
  String? get dedupeKey =>
      attachmentId == null || page == null ? null : '$attachmentId#$page';

  /// What this hit POINTS AT. Two hits sharing a target are the same offer:
  /// rendering both spends two of the caller's slots on one destination.
  String get target {
    switch (kind) {
      case _HitKind.figure:
        return 'figure/$figureId';
      case _HitKind.image:
        return 'attachment/$attachmentId';
      case _HitKind.link:
      case _HitKind.page:
        return 'attachment/$attachmentId${page == null ? '' : '?page=$page'}';
    }
  }

  String get headline {
    final source = noteTitle == null
        ? null
        : 'from ${FigureSearchTool._quoted(noteTitle!)}';
    final pageLabel = page == null ? null : 'p.$page';
    final quotedCaption = FigureSearchTool._quoted(caption);
    switch (kind) {
      case _HitKind.figure:
        return [
          'FIGURE — $quotedCaption',
          if (source != null) source,
          if (pageLabel != null) pageLabel,
        ].join(' — ');
      case _HitKind.image:
        return [
          'IMAGE — $quotedCaption',
          if (source != null) source,
        ].join(' — ');
      case _HitKind.link:
        return [
          'LINK — $quotedCaption',
          if (source != null) source,
          if (pageLabel != null) pageLabel,
          reason ?? 'link only',
        ].join(' — ');
      case _HitKind.page:
        return [
          'PAGE',
          if (source != null) source,
          if (pageLabel != null) pageLabel,
          'no figure region was extracted from this page — link only',
        ].join(' — ');
    }
  }

  /// The markdown to paste, built by the shared [AttachmentLinkService] so it
  /// matches what the app itself inserts. Figures and images are `![...]`
  /// embeds; links and pages are plain links and must never become images.
  String markdown(AttachmentLinkService links) {
    switch (kind) {
      case _HitKind.figure:
        return links.generateFigureMarkdownImage(
          figureId: figureId!,
          caption: caption,
        );
      case _HitKind.image:
        return links.generateAttachmentMarkdownImage(
          attachmentId: attachmentId!,
          caption: caption,
        );
      case _HitKind.link:
      case _HitKind.page:
        final label = page == null ? caption : '$caption, p.$page';
        return links.generateMarkdownLink(
          attachmentId: attachmentId!,
          linkText: label,
          page: page,
        );
    }
  }
}

/// Per-call lookup caches: note titles and attachments are read once each,
/// however many hits share them.
class _LookupSession {
  _LookupSession(this._db) : links = AttachmentLinkService(_db);

  final DatabaseService _db;

  /// The shared markdown generator every hit renders through.
  final AttachmentLinkService links;

  final Map<String, String?> _titles = {};
  final Map<String, Attachment?> _attachments = {};

  /// SQLite variable-limit-safe IN() size — the same guard [noteTitle]'s
  /// sibling batch queries use. `chunkKeys` is bounded by `limit` today, but
  /// an unguarded IN() is a landmine for whoever raises that cap.
  static const int _inClauseChunkSize = 500;

  /// The CURRENT `figure` rows for [chunkKeys], keyed by chunkKey. Rows that
  /// no longer exist are simply absent — a deleted figure stops being offered.
  Future<Map<String, Map<String, Object?>>> figureRows(
    List<String> chunkKeys,
  ) async {
    if (chunkKeys.isEmpty) return const {};
    final db = await _db.database;
    final byKey = <String, Map<String, Object?>>{};
    for (var i = 0; i < chunkKeys.length; i += _inClauseChunkSize) {
      final slice = chunkKeys.sublist(
        i,
        i + _inClauseChunkSize > chunkKeys.length
            ? chunkKeys.length
            : i + _inClauseChunkSize,
      );
      final placeholders = List.filled(slice.length, '?').join(',');
      final rows = await db.query(
        'search_chunks',
        columns: [
          'chunkKey',
          'noteId',
          'sourceId',
          'page',
          'text',
          'meta',
          'contentHash',
        ],
        where: 'sourceType = ? AND chunkKey IN ($placeholders)',
        whereArgs: [FigureResolver.figureSourceType, ...slice],
      );
      for (final row in rows) {
        byKey[row['chunkKey'] as String] = row;
      }
    }
    return byKey;
  }

  /// Title only — never loads `notes.content`, which can be very large.
  ///
  /// `__deleted__ = 0` for the same reason [FigureResolver] filters it:
  /// deletion is a tombstone write, so the row survives and an unfiltered
  /// lookup would hand a deleted note's title back to the model. The chunkKeys
  /// reaching here come from an already-filtered search, so this is a second
  /// guard rather than the only one — but it is the one that keeps the two
  /// lookups saying the same thing.
  Future<String?> noteTitle(String noteId) async {
    if (_titles.containsKey(noteId)) return _titles[noteId];
    final db = await _db.database;
    final rows = await db.query(
      'notes',
      columns: ['title'],
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [noteId],
      limit: 1,
    );
    final title = rows.isEmpty ? null : rows.first['title'] as String?;
    _titles[noteId] = title;
    return title;
  }

  Future<Attachment?> attachment(String attachmentId) async {
    if (_attachments.containsKey(attachmentId)) {
      return _attachments[attachmentId];
    }
    Attachment? attachment;
    try {
      attachment = await _db.getAttachmentById(attachmentId);
    } catch (e) {
      LoggerService.warning(
        '[search_figures] Attachment $attachmentId unreadable: $e',
      );
    }
    _attachments[attachmentId] = attachment;
    return attachment;
  }
}
