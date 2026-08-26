// Search & indexing settings (plan §2.2 "Presets + settings UX", §2.3
// provider-switch disclosure, §3 OCR toggle, §1.3 size-gated large PDFs,
// §4.2 Figure Answers cross-link).
//
// Everything the user can decide about the search index lives here:
// which embedding provider (if any) runs, what it is allowed to upload,
// how big a PDF may be before it needs an explicit opt-in, whether the
// on-device OCR layer runs, and the rebuild / delete escape hatches.
//
// The lexical (keyword) layer is never configurable — it is the always-on,
// offline floor. Nothing on this screen can break search; the worst case is
// falling back to keywords.

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/attachment.dart';
import '../models/model_type.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../services/model_storage_service.dart';
import '../services/search/embedding/embedding_preset_service.dart';
import '../services/search/embedding/embedding_provider.dart';
import '../services/search/embedding/embedding_provider_registry.dart';
import '../services/search/embedding/local_embedding_model_manager.dart';
import '../services/search/note_index_service.dart';
import '../services/search_settings_service.dart';
import '../services/service_locator.dart';
import '../services/skill_service.dart';
import '../services/starter_service.dart';
import 'install_starter_skills_screen.dart';

// ─────────────────────────────────────────────────────────────────────────
// Pure helpers (unit-tested directly — no widgets involved)
// ─────────────────────────────────────────────────────────────────────────

/// Which live state the Settings entry tile's subtitle reports.
enum SearchSubtitleKind {
  /// No embedding provider configured — keyword search only.
  lexicalOnly,

  /// Provider configured, its backfill complete, no errors.
  ready,

  /// Provider configured, backfill still filling gaps.
  indexing,

  /// A → B switch in flight: B is backfilling while A still serves queries.
  switching,

  /// The configured provider was explicitly stopped ("Stop using X now").
  /// The revocation is persisted, so it outlives sweeps and restarts until
  /// the user re-enables that provider.
  revoked,

  /// The embed stage halted, or chunks failed permanently.
  errors,
}

/// Derived subtitle state: the [kind] plus the numbers its label needs.
class SearchSettingsSubtitle {
  const SearchSettingsSubtitle(
    this.kind, {
    this.provider,
    this.percent = 0,
    this.errorCount = 0,
  });

  final SearchSubtitleKind kind;

  /// Display name of the provider the label names: the CONFIGURED provider
  /// (the backfill target) for every kind but [SearchSubtitleKind.lexicalOnly].
  final String? provider;

  /// Whole-number index coverage for the configured provider (0–100).
  final int percent;

  /// Failed chunks (or 1 for a stage-level halt with no per-chunk failures,
  /// so "0 errors" is never shown next to an error state).
  final int errorCount;

  @override
  bool operator ==(Object other) =>
      other is SearchSettingsSubtitle &&
      other.kind == kind &&
      other.provider == provider &&
      other.percent == percent &&
      other.errorCount == errorCount;

  @override
  int get hashCode => Object.hash(kind, provider, percent, errorCount);

  @override
  String toString() =>
      'SearchSettingsSubtitle($kind, provider: $provider, '
      'percent: $percent, errors: $errorCount)';
}

/// Maps the registry's transition snapshot + the indexer's embed counters to
/// the tile subtitle state.
///
/// Priority is deliberate: an error is the most actionable thing the tile can
/// say, so it outranks a transition; a transition outranks plain progress
/// (during A → B the percentage alone would read as a regression).
SearchSettingsSubtitle deriveSearchSettingsSubtitle({
  required EmbeddingTransitionState transition,
  required int embeddedChunks,
  required int totalChunks,
  String? embedStatus,
  int failedChunks = 0,
}) {
  final activeName = transition.activeDisplayName;
  if (transition.activeKey == null) {
    return const SearchSettingsSubtitle(SearchSubtitleKind.lexicalOnly);
  }
  final percent = totalChunks <= 0
      ? 100
      : (embeddedChunks * 100 ~/ totalChunks).clamp(0, 100);

  // A revoked ACTIVE provider outranks everything below it. The revocation
  // is persisted and suppresses promotion, so `inTransition` stays true
  // forever and the switching branch would read "Switching to A — 62%" for
  // good; an embed error under it is not actionable either, because nothing
  // will serve until the user re-enables the provider.
  if (transition.activeRevoked) {
    return SearchSettingsSubtitle(
      SearchSubtitleKind.revoked,
      provider: activeName,
      percent: percent,
    );
  }

  final halted = embedStatus == NoteIndexService.statusError;
  if (halted || failedChunks > 0) {
    return SearchSettingsSubtitle(
      SearchSubtitleKind.errors,
      provider: activeName,
      percent: percent,
      errorCount: failedChunks > 0 ? failedChunks : 1,
    );
  }
  if (transition.inTransition) {
    return SearchSettingsSubtitle(
      SearchSubtitleKind.switching,
      provider: activeName,
      percent: percent,
    );
  }
  // Ready is keyed off the STAGE, not the percentage. embedCoverage's
  // denominator is every chunk, while the embed pass skips chunks it may
  // never upload (includeInAIContext = false, searchIndex.embed = false,
  // empty text), so a completed backfill routinely lands at 97% — requiring
  // 100% here left the tile reading "indexing 97%" forever. The percent is
  // clamped to 100 for display so nothing reports a fraction of "done".
  if (embedStatus == NoteIndexService.statusDone) {
    return SearchSettingsSubtitle(
      SearchSubtitleKind.ready,
      provider: activeName,
      percent: 100,
    );
  }
  return SearchSettingsSubtitle(
    SearchSubtitleKind.indexing,
    provider: activeName,
    percent: percent,
  );
}

/// Cause of a recorded embed-stage HALT.
///
/// Only auth / not-installed / dims-mismatch failures halt the stage and
/// write `search_index_state.errorMessage` (transient failures defer without
/// writing state), so this classifies exactly those. The indexer persists the
/// typed reason as a machine-readable `kind|` prefix on that message — see
/// [NoteIndexService.parseEmbedHalt].
enum EmbedHaltKind {
  /// 401/403 — a key fix is needed; retrying only burns quota.
  auth,

  /// A local model's files are missing — offer a download, not an error.
  notInstalled,

  /// The endpoint's vector length differs from the configured dimensions.
  dimensionMismatch,

  /// Anything else that halted the pass.
  other,
}

/// Maps a stored halt [message] — the RAW value from
/// [NoteIndexService.embedStageState], i.e. still carrying its `kind|` prefix
/// — to the remedy the error tile should offer.
///
/// The prefix is authoritative. Matching the prose instead mislabelled both
/// directions: a message that merely QUOTED an endpoint's "unauthorized"
/// response body read as an auth halt (offering "Fix key" for a working
/// key), while a local provider that "is missing its model/tokenizer
/// download URLs" matched nothing and offered an inert Retry instead of
/// "Download model". Only a row written before the prefix existed still
/// falls back to prose ([_classifyEmbedHaltProse]).
EmbedHaltKind classifyEmbedHalt(String? message) {
  switch (NoteIndexService.parseEmbedHalt(message).kind) {
    case NoteIndexService.embedHaltAuth:
      return EmbedHaltKind.auth;
    case NoteIndexService.embedHaltNotInstalled:
      return EmbedHaltKind.notInstalled;
    case NoteIndexService.embedHaltDims:
      return EmbedHaltKind.dimensionMismatch;
  }
  return _classifyEmbedHaltProse(message);
}

/// Prose fallback for an UNPREFIXED halt, i.e. a row persisted before the
/// indexer encoded the kind (an upgrade reads it back once). It is the old,
/// loose English matching and it keeps the old failure modes — including
/// reading a body that merely quotes "unauthorized" as an auth halt. That is
/// tolerable only because it cannot see a fresh row: the pass halts solely on
/// a TYPED reason (auth / not-installed / dims), so everything it writes
/// today carries a prefix and never reaches this function.
EmbedHaltKind _classifyEmbedHaltProse(String? message) {
  if (message == null || message.isEmpty) return EmbedHaltKind.other;
  final lower = message.toLowerCase();
  if (lower.contains('is not installed') ||
      lower.contains('not installed on this device')) {
    return EmbedHaltKind.notInstalled;
  }
  if (lower.contains('dimensional vectors') ||
      lower.contains('expects') && lower.contains('dimensions')) {
    return EmbedHaltKind.dimensionMismatch;
  }
  if (lower.contains('failed: 401') ||
      lower.contains('failed: 403') ||
      lower.contains(' 401 ') ||
      lower.contains(' 403 ') ||
      lower.contains('unauthorized') ||
      lower.contains('forbidden') ||
      lower.contains('api key') ||
      lower.contains('permission denied')) {
    return EmbedHaltKind.auth;
  }
  return EmbedHaltKind.other;
}

/// Rounds a count down to an order-of-magnitude figure for the consent
/// dialog: exact counts imply a precision the estimate does not have (chunks
/// change between the dialog and the upload), and "~3,000" communicates the
/// scale the user is consenting to.
int approximateCount(int value) {
  if (value <= 0) return 0;
  if (value < 100) return value;
  var magnitude = 1;
  var scaled = value;
  while (scaled >= 100) {
    scaled ~/= 10;
    magnitude *= 10;
  }
  return scaled * magnitude;
}

/// What the user chose in the privacy/cost consent dialog.
enum EmbeddingConsentDecision {
  /// Do not enable the provider; no consent recorded.
  cancel,

  /// Enable; the previous provider keeps serving queries until the new
  /// provider's backfill completes.
  accept,

  /// Enable AND stop serving from the previous provider right now (search
  /// degrades to lexical until the new backfill completes).
  acceptStopServing,
}

/// Index-wide counts behind the consent dialog's "what leaves the device"
/// numbers and the rebuild dialog's scope.
class SearchIndexScope {
  const SearchIndexScope({
    this.notes = 0,
    this.chunks = 0,
    this.uploadableChunks = 0,
    this.imageChunks = 0,
    this.largePdfs = 0,
  });

  final int notes;

  /// EVERY chunk in the index — what a rebuild re-checks and what the status
  /// card reports. Deliberately not the consent number: plenty of these are
  /// never uploaded.
  final int chunks;

  /// Chunks the embed pass would ACTUALLY send, mirroring its gap scan:
  /// excludes attachments with includeInAIContext = false, attachments with
  /// `searchIndex.embed = false`, and empty-text chunks (plan §1.3 — the
  /// estimate names what leaves the device, not what is indexed).
  final int uploadableChunks;

  /// Chunks whose content is an image (figure crops / raster attachments) —
  /// only these are uploaded as images, and only to providers that accept
  /// image inputs. A SUBSET of [uploadableChunks].
  final int imageChunks;

  /// PDFs currently skipped for exceeding the page cap: not uploaded, and
  /// called out so the estimate is not mistaken for "everything".
  final int largePdfs;

  /// Uploadable chunks that are TEXT. [imageChunks] are counted separately in
  /// the consent copy, so leaving them in would double-count every figure.
  int get uploadableTextChunks =>
      (uploadableChunks - imageChunks).clamp(0, uploadableChunks);
}

/// One PDF skipped for exceeding the page cap (plan §1.3 review list).
class LargePdfEntry {
  const LargePdfEntry({
    required this.attachmentId,
    required this.fileName,
    required this.noteId,
    this.noteTitle,
    this.pages,
  });

  final String attachmentId;
  final String fileName;
  final String noteId;
  final String? noteTitle;
  final int? pages;
}

/// How many skipped PDFs the review list renders. The card builds its rows
/// eagerly inside a Column, so the list has to be bounded — a corpus with
/// hundreds of oversized PDFs would otherwise build hundreds of ListTiles on
/// every rebuild of the screen. The remainder is reported as a count (the
/// scope query still counts them all).
const int maxLargePdfRows = 20;

/// Pulls the `|pages=N` component out of a stored pdf_text/ocr state hash
/// (see NoteIndexService's `_pdfStateHash`). Null when absent.
int? pageCountFromStateHash(String? stateHash) {
  if (stateHash == null) return null;
  final match = RegExp(r'\|pages=(\d+)').firstMatch(stateHash);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Loads the tile/screen subtitle state. Services default to the locator so
/// callers (the Settings tile, the screen header) stay one-liners.
Future<SearchSettingsSubtitle> loadSearchSettingsSubtitle({
  EmbeddingProviderRegistry? registry,
  NoteIndexService? indexService,
}) async {
  final embeddingRegistry = registry ?? getIt<EmbeddingProviderRegistry>();
  final indexer = indexService ?? getIt<NoteIndexService>();
  await embeddingRegistry.ensureInitialized();
  final transition = embeddingRegistry.transitionState;
  final activeKey = transition.activeKey;
  if (activeKey == null) {
    return const SearchSettingsSubtitle(SearchSubtitleKind.lexicalOnly);
  }
  final coverage = await indexer.embedCoverage(activeKey);
  final stage = await indexer.embedStageState(activeKey);
  return deriveSearchSettingsSubtitle(
    transition: transition,
    embeddedChunks: coverage.embedded,
    totalChunks: coverage.total,
    embedStatus: stage.status,
    failedChunks: stage.failedChunks,
  );
}

/// Renders a [SearchSettingsSubtitle] as localized text.
String searchSettingsSubtitleText(
  AppLocalizations l10n,
  SearchSettingsSubtitle state,
) {
  final provider = state.provider ?? '';
  switch (state.kind) {
    case SearchSubtitleKind.lexicalOnly:
      return l10n.searchSubtitleLexicalOnly;
    case SearchSubtitleKind.ready:
      return l10n.searchSubtitleReady(provider);
    case SearchSubtitleKind.indexing:
      return l10n.searchSubtitleIndexing(provider, state.percent);
    case SearchSubtitleKind.switching:
      return l10n.searchSubtitleSwitching(provider, state.percent);
    case SearchSubtitleKind.revoked:
      return l10n.searchSubtitleRevoked(provider);
    case SearchSubtitleKind.errors:
      return l10n.searchSubtitleErrors(provider, state.errorCount);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Settings entry tile
// ─────────────────────────────────────────────────────────────────────────

/// Top-level Settings tile whose subtitle reports live index state
/// ("Lexical only" / "Gemini · indexing 62%" / "Gemini · 2 errors" /
/// "Switching to X — 40% re-indexed").
class SearchSettingsTile extends StatefulWidget {
  const SearchSettingsTile({super.key});

  @override
  State<SearchSettingsTile> createState() => _SearchSettingsTileState();
}

class _SearchSettingsTileState extends State<SearchSettingsTile> {
  SearchSettingsSubtitle _state = const SearchSettingsSubtitle(
    SearchSubtitleKind.lexicalOnly,
  );
  bool _loading = true;

  /// Guards against overlapping refreshes: index progress ticks far more
  /// often than the two aggregate queries behind the subtitle.
  bool _refreshing = false;

  /// Throttle for progress-driven refreshes. A running backfill emits a tick
  /// per batch; the subtitle only needs a coarse percentage, and each refresh
  /// costs two COUNT queries over the whole chunk table.
  DateTime? _lastProgressRefresh;
  static const Duration _progressRefreshInterval = Duration(seconds: 2);

  /// Trailing-edge timer for ticks that arrive inside the throttle window.
  /// Dropping them outright loses the most important tick of all — the one
  /// that says the backfill finished — and the subtitle then keeps reporting
  /// a percentage that will never move again.
  Timer? _trailingRefresh;

  ValueListenable<IndexProgress>? _progress;

  @override
  void initState() {
    super.initState();
    try {
      _progress = getIt<NoteIndexService>().progress;
      _progress!.addListener(_onProgress);
    } catch (e) {
      LoggerService.warning('[SearchSettingsTile] indexer unavailable: $e');
    }
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _trailingRefresh?.cancel();
    _progress?.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    final last = _lastProgressRefresh;
    final elapsed = last == null ? null : DateTime.now().difference(last);
    if (elapsed != null && elapsed < _progressRefreshInterval) {
      if (_trailingRefresh?.isActive ?? false) return;
      _trailingRefresh = Timer(_progressRefreshInterval - elapsed, () {
        if (!mounted) return;
        unawaited(_refresh());
      });
      return;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    // Stamped here rather than in [_onProgress] so the initial load counts
    // as a refresh too — otherwise the very first progress tick always ran
    // a second pair of COUNT queries a few milliseconds after the first.
    _lastProgressRefresh = DateTime.now();
    try {
      final state = await loadSearchSettingsSubtitle();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } catch (e) {
      LoggerService.warning('[SearchSettingsTile] subtitle refresh failed: $e');
      if (mounted) setState(() => _loading = false);
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isError = _state.kind == SearchSubtitleKind.errors;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.manage_search),
        title: Text(l10n.searchSettings),
        subtitle: Text(
          // Until the two aggregate queries land, describe the screen rather
          // than guessing a state that might be wrong for a blink.
          _loading
              ? l10n.searchSettingsSubtitle
              : searchSettingsSubtitleText(l10n, _state),
          style: isError
              ? TextStyle(color: Theme.of(context).colorScheme.error)
              : null,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const SearchSettingsScreen(),
            ),
          );
          await _refresh();
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────

LocalEmbeddingModelManager? _sharedModelManager;

/// Process-wide [LocalEmbeddingModelManager], created on first use (the same
/// shape as [EmbeddingPresetService.instance]).
///
/// It MUST outlive the screen: the manager de-duplicates concurrent installs
/// through an `_inFlight` map keyed by config, and a per-screen instance
/// starts life with that map empty. Backing out of settings mid-download and
/// re-entering would then kick a SECOND ~180 MB download of the same gated
/// files instead of re-attaching to the running one. Tests still inject their
/// own via `SearchSettingsScreen.modelManager`.
LocalEmbeddingModelManager get sharedLocalEmbeddingModelManager =>
    _sharedModelManager ??= LocalEmbeddingModelManager();

/// Search & indexing settings screen.
///
/// Service seams are constructor parameters so widget tests can drive the
/// flows without SharedPreferences/asset/platform-channel dependencies; in
/// production every one of them defaults to the real implementation.
class SearchSettingsScreen extends StatefulWidget {
  const SearchSettingsScreen({
    super.key,
    this.settingsService,
    this.presetService,
    this.modelManager,
    this.largePdfLoader,
    this.scopeLoader,
    this.figureSkillLoader,
  });

  final SearchSettingsService? settingsService;
  final EmbeddingPresetService? presetService;
  final LocalEmbeddingModelManager? modelManager;

  /// PDFs currently skipped for exceeding the page cap.
  final Future<List<LargePdfEntry>> Function()? largePdfLoader;

  /// Index-wide counts for the consent + rebuild dialogs.
  final Future<SearchIndexScope> Function()? scopeLoader;

  /// Figure Answers starter-skill state: null when the skill asset is not in
  /// this build (Step 15 ships it) — the cross-link then stays hidden.
  final Future<bool?> Function()? figureSkillLoader;

  @override
  State<SearchSettingsScreen> createState() => _SearchSettingsScreenState();
}

class _SearchSettingsScreenState extends State<SearchSettingsScreen> {
  late final SearchSettingsService _settings =
      widget.settingsService ?? SearchSettingsService();
  late final EmbeddingPresetService _presets =
      widget.presetService ?? EmbeddingPresetService.instance;
  late final LocalEmbeddingModelManager _modelManager =
      widget.modelManager ?? sharedLocalEmbeddingModelManager;

  EmbeddingProviderRegistry get _registry => getIt<EmbeddingProviderRegistry>();
  NoteIndexService get _indexer => getIt<NoteIndexService>();

  bool _loading = true;

  // Provider state
  EmbeddingProviderConfig? _activeConfig;
  EmbeddingTransitionState _transition = const EmbeddingTransitionState();
  ({int embedded, int total}) _coverage = (embedded: 0, total: 0);
  ({String? status, String? errorMessage, int failedChunks}) _embedStage = (
    status: null,
    errorMessage: null,
    failedChunks: 0,
  );

  // Toggles
  bool _ocrEnabled = true;
  String _ocrScript = 'auto';
  bool _figuresEnabled = true;
  bool _wifiOnly = true;
  int _pageCap = SearchSettingsService.defaultPdfPageCap;

  // Derived data
  List<LargePdfEntry> _largePdfs = const [];
  SearchIndexScope _scope = const SearchIndexScope();

  /// null → the Figure Answers skill asset is not in this build; true/false →
  /// installed / available-but-not-installed.
  bool? _figureSkillInstalled;

  bool _rebuilding = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _registry.ensureInitialized();
      final transition = _registry.transitionState;
      final activeConfig = _registry.activeConfig;
      final activeKey = transition.activeKey;
      final coverage = activeKey == null
          ? (embedded: 0, total: 0)
          : await _indexer.embedCoverage(activeKey);
      final stage = activeKey == null
          ? (status: null, errorMessage: null, failedChunks: 0)
          : await _indexer.embedStageState(activeKey);
      final ocrEnabled = await _settings.getOcrEnabled();
      final ocrScript = await _settings.getOcrScript();
      final figures = await _settings.getFigureIndexingEnabled();
      final wifiOnly = await _settings.getEmbedWifiOnly();
      final pageCap = await _settings.getPdfPageCap();
      final largePdfs = await (widget.largePdfLoader ?? _defaultLargePdfs)();
      final scope = await (widget.scopeLoader ?? _defaultScope)();
      final skill = await (widget.figureSkillLoader ?? _defaultFigureSkill)();
      if (!mounted) return;
      setState(() {
        _activeConfig = activeConfig;
        _transition = transition;
        _coverage = coverage;
        _embedStage = stage;
        _ocrEnabled = ocrEnabled;
        _ocrScript = ocrScript;
        _figuresEnabled = figures;
        _wifiOnly = wifiOnly;
        _pageCap = pageCap;
        _largePdfs = largePdfs;
        _scope = scope;
        _figureSkillInstalled = skill;
        _loading = false;
      });
    } catch (e, stack) {
      LoggerService.error(
        '[SearchSettings] load failed: $e',
        error: e,
        stackTrace: stack,
      );
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Default (production) data loaders ──────────────────────────────────

  Future<List<LargePdfEntry>> _defaultLargePdfs() async {
    final db = await getIt<DatabaseService>().database;
    final rows = await db.rawQuery(
      'SELECT s.scopeId AS attachmentId, s.contentHash AS stateHash, '
      'a.fileName AS fileName, a.noteId AS noteId, n.title AS noteTitle '
      'FROM search_index_state s '
      'JOIN attachments a ON a.id = s.scopeId '
      'LEFT JOIN notes n ON n.id = a.noteId '
      "WHERE s.scopeType = 'attachment' AND s.status = ? "
      'GROUP BY s.scopeId '
      'ORDER BY a.fileName '
      'LIMIT ?',
      [NoteIndexService.statusSkippedTooLarge, maxLargePdfRows],
    );
    return [
      for (final row in rows)
        LargePdfEntry(
          attachmentId: row['attachmentId'] as String,
          fileName: (row['fileName'] as String?) ?? '',
          noteId: (row['noteId'] as String?) ?? '',
          noteTitle: row['noteTitle'] as String?,
          pages: pageCountFromStateHash(row['stateHash'] as String?),
        ),
    ];
  }

  Future<SearchIndexScope> _defaultScope() async {
    final db = await getIt<DatabaseService>().database;
    Future<int> count(String sql, [List<Object?>? args]) async {
      final rows = await db.rawQuery(sql, args);
      return (rows.first.values.first as int?) ?? 0;
    }

    // What the embed pass would actually upload, mirroring
    // NoteIndexService._scanEmbedGapIds' exclusions: empty-text chunks,
    // orphaned attachment chunks, includeInAIContext = false, and
    // `searchIndex.embed = false`. The last one is matched as a substring
    // rather than json_extract: SQLite's JSON1 functions are not guaranteed
    // on every Android system library this ships to, and the writer
    // (AttachmentSearchIndexConfig.toJson through jsonEncode) always emits
    // the compact `"embed":false` form. Figures come back from the same
    // scan so the two numbers cannot disagree.
    final uploadRows = await db.rawQuery('''
      SELECT COUNT(*) AS chunks,
             COALESCE(
               SUM(CASE WHEN c.sourceType = 'figure' THEN 1 ELSE 0 END), 0
             ) AS figures
      FROM search_chunks c
      LEFT JOIN attachments a
        ON a.id = c.sourceId
        AND c.sourceType IN ('attachment_text', 'attachment_ocr', 'figure')
      WHERE trim(c.text) != ''
        AND (a.id IS NOT NULL
             OR c.sourceType NOT IN
                ('attachment_text', 'attachment_ocr', 'figure'))
        AND COALESCE(a.includeInAIContext, 1) != 0
        AND COALESCE(a.metadata, '') NOT LIKE '%"embed":false%'
      ''');

    return SearchIndexScope(
      notes: await count('SELECT COUNT(*) FROM notes'),
      chunks: await count('SELECT COUNT(*) FROM search_chunks'),
      uploadableChunks: (uploadRows.first['chunks'] as int?) ?? 0,
      imageChunks: (uploadRows.first['figures'] as int?) ?? 0,
      largePdfs: await count(
        'SELECT COUNT(DISTINCT scopeId) FROM search_index_state '
        "WHERE scopeType = 'attachment' AND status = ?",
        [NoteIndexService.statusSkippedTooLarge],
      ),
    );
  }

  /// Figure Answers starter skill: null when the asset isn't bundled yet
  /// (Step 15), so the cross-link is a no-op in builds without it.
  Future<bool?> _defaultFigureSkill() async {
    try {
      final skills = await StarterService.getStarterSkills();
      for (final skill in skills) {
        if (skill['skillRef'] == figureAnswersSkillRef) {
          return skill['isInstalled'] == true;
        }
      }
      // The asset is absent; the user may still have authored the skill.
      final index = await getIt<SkillService>().buildSkillIndex();
      final installed = index.values.any(
        (meta) => meta.skillRef == figureAnswersSkillRef,
      );
      return installed ? true : null;
    } catch (e) {
      LoggerService.warning('[SearchSettings] figure skill lookup failed: $e');
      return null;
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────

  /// One provider row in the picker. A plain ListTile with a radio GLYPH
  /// rather than RadioListTile: the picker pops on tap (there is no
  /// persistent group state to manage), and RadioListTile's groupValue/
  /// onChanged are deprecated in favour of a RadioGroup ancestor.
  ///
  /// The glyph carries no semantics of its own, so the row is wrapped in a
  /// [Semantics] node that restores what a real radio would announce — that
  /// this is one of a mutually exclusive set, and whether it is the current
  /// choice. Without it a screen reader reads five identical tappable rows.
  Widget _providerOption({
    required bool selected,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: ListTile(
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: onTap,
      ),
    );
  }

  Future<void> _openProviderPicker() async {
    final l10n = AppLocalizations.of(context)!;
    final presets = await _presets.loadPresets();
    if (!mounted) return;
    final choice = await showModalBottomSheet<_ProviderChoice>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final activeKey = _activeConfig?.providerKey;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(
                  l10n.searchEmbeddingProvider,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              _providerOption(
                selected: activeKey == null,
                title: l10n.searchProviderNone,
                subtitle: l10n.searchProviderNoneSubtitle,
                onTap: () =>
                    Navigator.pop(sheetContext, const _ProviderChoice.none()),
              ),
              for (final preset in presets)
                _providerOption(
                  selected:
                      activeKey == preset.providerKey &&
                      !(_activeConfig?.isCustom ?? false),
                  title: preset.displayName,
                  subtitle:
                      '${preset.type == 'local' ? l10n.searchProviderOnDevice : l10n.searchProviderCloud}'
                      ' · ${l10n.searchProviderDimensions(preset.dimensions)}',
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _ProviderChoice.preset(preset),
                  ),
                ),
              _providerOption(
                selected: _activeConfig?.isCustom ?? false,
                title: l10n.searchProviderCustom,
                subtitle: l10n.searchProviderCustomSubtitle,
                onTap: () =>
                    Navigator.pop(sheetContext, const _ProviderChoice.custom()),
              ),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    if (choice.isNone) {
      await _turnProviderOff();
      return;
    }
    final base =
        choice.preset ??
        (_activeConfig?.isCustom ?? false
            ? _activeConfig!
            : const EmbeddingProviderConfig(
                type: 'openai',
                endpoint: '',
                modelName: '',
                displayName: '',
                dimensions: 768,
                isCustom: true,
              ));
    // Editing the provider currently configured? Prefill its stored values
    // (its endpoint/dims may have been corrected since the preset shipped).
    final active = _activeConfig;
    final prefill =
        (active != null &&
            active.type == base.type &&
            active.modelName == base.modelName &&
            active.isCustom == base.isCustom)
        ? active
        : base;
    if (!mounted) return;
    final applied = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => _ProviderConfigPage(
          config: prefill,
          isCustom: choice.isCustom || prefill.isCustom,
          settings: _settings,
          modelManager: _modelManager,
          scopeLoader: widget.scopeLoader ?? _defaultScope,
        ),
      ),
    );
    if (applied == true && mounted) {
      setState(() => _loading = true);
      await _load();
    }
  }

  Future<void> _turnProviderOff() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    await _registry.clearActiveConfig();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.searchProviderTurnedOff)),
    );
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _retryEmbedding() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    await _indexer.retryEmbedIndexing();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(l10n.searchRetryStarted)));
    await _load();
  }

  Future<void> _rebuildIndex() async {
    final l10n = AppLocalizations.of(context)!;
    // Cost line only for CLOUD providers — an on-device model re-embedding
    // costs nothing but time, and implying a bill would be wrong.
    final config = _activeConfig;
    final providerName = (config != null && config.type != 'local')
        ? config.displayName
        : null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.searchRebuildConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.searchRebuildConfirmBody(_scope.notes, _scope.chunks)),
            if (providerName != null) ...[
              const SizedBox(height: 12),
              Text(l10n.searchRebuildConfirmCost(providerName)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.searchRebuildIndex),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _rebuilding = true);
    messenger.showSnackBar(SnackBar(content: Text(l10n.searchRebuildStarted)));
    try {
      await _indexer.backfillAll(force: true);
    } catch (e) {
      LoggerService.error('[SearchSettings] rebuild failed: $e');
    }
    if (!mounted) return;
    setState(() => _rebuilding = false);
    await _load();
  }

  Future<void> _deleteStoredEmbeddings() async {
    final l10n = AppLocalizations.of(context)!;
    // The confirmation states the full effect: deleteStoredEmbeddings also
    // withdraws consent for every providerKey that had vectors and clears
    // the active config, precisely so the next sweep cannot re-upload the
    // corpus. That makes this the privacy escape hatch AND a provider-off
    // switch, and the copy has to say both.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.searchDeleteEmbeddings),
        content: Text(l10n.searchDeleteEmbeddingsConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await _indexer.deleteStoredEmbeddings();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.searchEmbeddingsDeleted)),
    );
    await _load();
  }

  Future<void> _indexLargePdfAnyway(LargePdfEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final db = getIt<DatabaseService>();
    final attachment = await db.getAttachmentById(entry.attachmentId);
    if (attachment == null) {
      if (!mounted) return;
      await _load();
      return;
    }
    final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
    final config = attachment.getSearchIndexConfig();
    metadata['searchIndex'] = AttachmentSearchIndexConfig(
      text: 'on',
      ocr: config.ocr,
      embed: config.embed,
    ).toJson();
    await db.updateAttachmentMetadata(entry.attachmentId, metadata);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.searchLargePdfQueued(entry.fileName))),
    );
    await _load();
  }

  Future<void> _editPageCap() async {
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _PageCapDialog(initialValue: _pageCap),
    );
    if (value == null || !mounted) return;
    final previous = _pageCap;
    await _settings.setPdfPageCap(value);
    final stored = await _settings.getPdfPageCap();
    if (!mounted) return;
    setState(() => _pageCap = stored);
    if (stored != previous) unawaited(_kickIndexSweep());
  }

  /// Re-runs the pipeline after a setting that feeds an indexing state hash
  /// changed, then refreshes the derived lists.
  ///
  /// Writing the pref alone was not enough: the PDF cap and the OCR script
  /// are both part of the attachment state hashes the sweep diffs against,
  /// so nothing re-evaluated them until an unrelated reindex — raising the
  /// cap from 100 to 1000 left the 512-page PDF sitting in the "not indexed"
  /// list until the next app launch. Not awaited by callers: a sweep can run
  /// for minutes, and the list refresh rides its completion.
  Future<void> _kickIndexSweep() async {
    try {
      await _indexer.ensureBackfilled();
    } catch (e) {
      LoggerService.warning('[SearchSettings] index sweep kick failed: $e');
      return;
    }
    if (!mounted) return;
    final largePdfs = await (widget.largePdfLoader ?? _defaultLargePdfs)();
    final scope = await (widget.scopeLoader ?? _defaultScope)();
    if (!mounted) return;
    setState(() {
      _largePdfs = largePdfs;
      _scope = scope;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.searchSettings)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildStatusCard(l10n),
                const SizedBox(height: 8),
                _buildProviderCard(l10n),
                const SizedBox(height: 8),
                _buildMaintenanceCard(l10n),
                const SizedBox(height: 8),
                _buildOcrCard(l10n),
                const SizedBox(height: 8),
                _buildFiguresCard(l10n),
                const SizedBox(height: 8),
                _buildLargePdfCard(l10n),
              ],
            ),
    );
  }

  Widget _buildStatusCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.searchIndexStatus,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<IndexProgress>(
              valueListenable: _indexer.progress,
              builder: (context, progress, _) {
                if (!progress.running) {
                  return Text(l10n.searchIndexIdle(_scope.chunks));
                }
                final percent = progress.total <= 0
                    ? 0
                    : (progress.done * 100 ~/ progress.total).clamp(0, 100);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_stageLabel(l10n, progress)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: percent / 100),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _stageLabel(AppLocalizations l10n, IndexProgress progress) {
    final stage = progress.stage;
    if (stage == NoteIndexService.stageChunks) {
      return l10n.searchStageChunks(progress.done, progress.total);
    }
    if (stage == NoteIndexService.stagePdfText) {
      return l10n.searchStagePdfText(progress.done, progress.total);
    }
    if (stage == NoteIndexService.stageOcr) {
      return l10n.searchStageOcr(progress.done, progress.total);
    }
    if (stage.startsWith('embed:')) {
      return l10n.searchStageEmbed(progress.done, progress.total);
    }
    return l10n.searchStageChunks(progress.done, progress.total);
  }

  Widget _buildProviderCard(AppLocalizations l10n) {
    final config = _activeConfig;
    final isCloud = config != null && config.type != 'local';
    final children = <Widget>[
      ListTile(
        title: Text(l10n.searchEmbeddingProvider),
        subtitle: Text(config?.displayName ?? l10n.searchProviderNone),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openProviderPicker,
      ),
    ];

    if (_transition.activeRevoked) {
      // Persisted revocation: nothing promotes and nothing serves until the
      // same provider is picked again, so the row says so and offers the one
      // action that lifts it.
      children.add(
        ListTile(
          leading: const Icon(Icons.pause_circle_outline),
          title: Text(
            l10n.searchSubtitleRevoked(_transition.activeDisplayName ?? ''),
          ),
          trailing: TextButton(
            onPressed: _openProviderPicker,
            child: Text(l10n.searchProviderReEnable),
          ),
        ),
      );
    } else if (_transition.inTransition &&
        _transition.servingDisplayName != null) {
      children.add(
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: Text(
            l10n.searchProviderServedBy(_transition.servingDisplayName!),
          ),
          subtitle: Text(
            l10n.searchSubtitleSwitching(
              _transition.activeDisplayName ?? '',
              _coveragePercent,
            ),
          ),
          trailing: TextButton(
            onPressed: _stopServingNow,
            child: Text(
              l10n.searchConsentStopServing(_transition.servingDisplayName!),
            ),
          ),
        ),
      );
    }

    final errorTile = _buildErrorTile(l10n);
    if (errorTile != null) children.add(errorTile);

    if (isCloud) {
      children.add(
        SwitchListTile(
          value: _wifiOnly,
          title: Text(l10n.searchWifiOnly),
          subtitle: Text(l10n.searchWifiOnlySubtitle),
          onChanged: (value) async {
            await _settings.setEmbedWifiOnly(value);
            if (!mounted) return;
            setState(() => _wifiOnly = value);
            // Turning the gate OFF is the direction that matters: an embed
            // pass that deferred on the wifi check cleared its global done
            // flag and waits for the next sweep, so without this kick the
            // stalled work only resumed on an app restart or an unrelated
            // bulk change. Kicking in the ON direction too costs one sweep
            // that skips everything up to date and defers the embed pass
            // again — cheap enough not to warrant a direction test.
            unawaited(_kickIndexSweep());
          },
        ),
      );
    }

    return Card(child: Column(children: children));
  }

  int get _coveragePercent => _coverage.total <= 0
      ? 100
      : (_coverage.embedded * 100 ~/ _coverage.total).clamp(0, 100);

  Future<void> _stopServingNow() async {
    final l10n = AppLocalizations.of(context)!;
    final serving = _transition.servingDisplayName ?? '';
    final messenger = ScaffoldMessenger.of(context);
    await _registry.revokeServing();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.searchConsentStoppedServing(serving))),
    );
    await _load();
  }

  /// Failed-chunk count + last error + the action the failure calls for
  /// (plan §2.2 error surfacing): auth halts read as "fix the key", a local
  /// model that was never downloaded reads as "Download model" rather than
  /// an error, everything else offers Retry.
  Widget? _buildErrorTile(AppLocalizations l10n) {
    final halted = _embedStage.status == NoteIndexService.statusError;
    final failed = _embedStage.failedChunks;
    if (!halted && failed == 0) return null;
    final theme = Theme.of(context);
    final providerName = _activeConfig?.displayName ?? '';
    final kind = halted
        ? classifyEmbedHalt(_embedStage.errorMessage)
        : EmbedHaltKind.other;

    String title;
    // The stored halt message carries the machine-readable `kind|` prefix the
    // classification above reads; the user sees the prose half only.
    String? detail = NoteIndexService.parseEmbedHalt(
      _embedStage.errorMessage,
    ).message;
    String? hint;
    Widget action;
    IconData icon = Icons.error_outline;
    // Whether the TITLE already states the failed-chunk count, so the
    // subtitle does not repeat the same sentence back verbatim.
    var titleStatesFailures = false;
    switch (kind) {
      case EmbedHaltKind.auth:
        title = l10n.searchErrorAuth(providerName);
        icon = Icons.key_off;
        action = TextButton(
          onPressed: _openProviderPicker,
          child: Text(l10n.searchFixKey),
        );
      case EmbedHaltKind.notInstalled:
        title = l10n.searchErrorNotInstalled(providerName);
        detail = null;
        icon = Icons.download_for_offline_outlined;
        action = TextButton(
          onPressed: _openProviderPicker,
          child: Text(l10n.searchDownloadModel),
        );
      case EmbedHaltKind.dimensionMismatch:
        title = l10n.searchErrorDimensions;
        icon = Icons.straighten;
        action = TextButton(
          onPressed: _openProviderPicker,
          child: Text(l10n.searchTestConnection),
        );
      case EmbedHaltKind.other:
        if (halted) {
          // A stage-level halt IS what retryEmbedIndexing clears (it deletes
          // the global embed error rows and re-runs the backfill).
          title = l10n.searchErrorHalted;
          action = TextButton(
            onPressed: _retryEmbedding,
            child: Text(l10n.retry),
          );
        } else {
          // Per-chunk permanent failures only. retryEmbedIndexing would be a
          // no-op here: it deletes scopeType='global' rows, while these are
          // scopeType='chunk' rows that the embed gap scan explicitly skips
          // — the button looked like it worked and changed nothing. The
          // forced rebuild is the one path that does clear them
          // (NoteIndexService._runBackfill deletes chunk-scoped embed rows
          // under `force`), so that is what the control offers, with copy
          // that says so. Point this back at a cheap retry once the indexer
          // grows one (deleting just the chunk-scoped embed error rows for
          // the active providerKey and re-running the embed pass).
          title = l10n.searchErrorFailedChunks(failed);
          titleStatesFailures = true;
          hint = l10n.searchErrorFailedChunksHint;
          action = TextButton(
            onPressed: _rebuildIndex,
            child: Text(l10n.searchRebuildIndex),
          );
        }
    }

    final subtitleLines = <Widget>[
      if (failed > 0 && !titleStatesFailures)
        Text(l10n.searchErrorFailedChunks(failed)),
      if (hint != null) Text(hint),
      if (detail != null && detail.isNotEmpty)
        Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis),
    ];

    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.error),
      title: Text(title, style: TextStyle(color: theme.colorScheme.error)),
      subtitle: subtitleLines.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: subtitleLines,
            ),
      trailing: action,
      isThreeLine: subtitleLines.length > 1,
    );
  }

  Widget _buildMaintenanceCard(AppLocalizations l10n) {
    return Card(
      child: Column(
        children: [
          ValueListenableBuilder<IndexProgress>(
            valueListenable: _indexer.progress,
            builder: (context, progress, _) {
              final running = _rebuilding || progress.running;
              final percent = progress.total <= 0
                  ? 0
                  : (progress.done * 100 ~/ progress.total).clamp(0, 100);
              return ListTile(
                leading: const Icon(Icons.refresh),
                title: Text(l10n.searchRebuildIndex),
                subtitle: Text(
                  running
                      ? l10n.searchRebuildRunning(percent)
                      : l10n.searchRebuildSubtitle,
                ),
                trailing: running
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                enabled: !running,
                onTap: running ? null : _rebuildIndex,
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(l10n.searchDeleteEmbeddings),
            subtitle: Text(l10n.searchDeleteEmbeddingsSubtitle),
            onTap: _deleteStoredEmbeddings,
          ),
        ],
      ),
    );
  }

  Widget _buildOcrCard(AppLocalizations l10n) {
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            value: _ocrEnabled,
            title: Text(l10n.searchOcrEnabled),
            // "on-device" is stated up front: the fear this preempts is that
            // an OCR toggle means uploading pages to a service (plan §2.2).
            subtitle: Text(l10n.searchOcrOnDevice),
            onChanged: (value) async {
              await _settings.setOcrEnabled(value);
              if (!mounted) return;
              setState(() => _ocrEnabled = value);
              // Whether OCR runs at all is part of the OCR stage's policy
              // hash, so switching it off has to PURGE the text it added (and
              // switching it on has to produce it). Without the kick that
              // waited for the next app start or an unrelated bulk change.
              unawaited(_kickIndexSweep());
            },
          ),
          ListTile(
            title: Text(l10n.searchOcrScript),
            subtitle: Text(_ocrScriptLabel(l10n, _ocrScript)),
            enabled: _ocrEnabled,
            trailing: DropdownButton<String>(
              value: _ocrScript,
              onChanged: _ocrEnabled
                  ? (value) async {
                      if (value == null || value == _ocrScript) return;
                      await _settings.setOcrScript(value);
                      if (!mounted) return;
                      setState(() => _ocrScript = value);
                      // The script is part of the OCR state hash, so the
                      // affected pages re-run — but only once a sweep runs.
                      unawaited(_kickIndexSweep());
                    }
                  : null,
              items: [
                for (final script in SearchSettingsService.ocrScriptValues)
                  DropdownMenuItem(
                    value: script,
                    child: Text(_ocrScriptLabel(l10n, script)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _ocrScriptLabel(AppLocalizations l10n, String script) {
    switch (script) {
      case 'latin':
        return l10n.searchOcrScriptLatin;
      case 'chinese':
        return l10n.searchOcrScriptChinese;
      default:
        return l10n.searchOcrScriptAuto;
    }
  }

  Widget _buildFiguresCard(AppLocalizations l10n) {
    final showSkillHint = _figuresEnabled && _figureSkillInstalled == false;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            value: _figuresEnabled,
            title: Text(l10n.searchFigureIndexing),
            subtitle: Text(l10n.searchFigureIndexingSubtitle),
            onChanged: (value) async {
              await _settings.setFigureIndexingEnabled(value);
              if (!mounted) return;
              setState(() => _figuresEnabled = value);
              // The global switch is part of the figures stage's policy hash,
              // so switching it off has to PURGE every figure chunk and the
              // crop it derived (and switching it on has to extract them).
              // Same kick as the OCR toggle: without it nothing re-evaluated
              // the stage until an app restart or an unrelated bulk change.
              unawaited(_kickIndexSweep());
            },
          ),
          if (showSkillHint)
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: Text(l10n.searchFigureSkillHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const InstallStarterSkillsScreen(),
                  ),
                );
                if (!mounted) return;
                final installed =
                    await (widget.figureSkillLoader ?? _defaultFigureSkill)();
                if (!mounted) return;
                setState(() => _figureSkillInstalled = installed);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildLargePdfCard(AppLocalizations l10n) {
    // The list is capped at [maxLargePdfRows]; the scope query counts every
    // skipped PDF, so the header can still report the real total and the
    // remainder is named rather than silently missing.
    final total = _scope.largePdfs > _largePdfs.length
        ? _scope.largePdfs
        : _largePdfs.length;
    final hidden = total - _largePdfs.length;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(l10n.searchPdfPageCap),
            subtitle: Text(l10n.searchPdfPageCapSubtitle(_pageCap)),
            trailing: Text('$_pageCap'),
            onTap: _editPageCap,
          ),
          if (_largePdfs.isEmpty)
            ListTile(subtitle: Text(l10n.searchNoLargePdfs))
          else ...[
            ListTile(
              title: Text(
                l10n.searchLargePdfsSkipped(total),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            for (final entry in _largePdfs)
              ListTile(
                title: Text(entry.fileName),
                subtitle: Text(
                  entry.pages != null
                      ? l10n.searchLargePdfPages(
                          entry.noteTitle ?? '',
                          entry.pages!,
                        )
                      : (entry.noteTitle ?? ''),
                ),
                trailing: TextButton(
                  onPressed: () => _indexLargePdfAnyway(entry),
                  child: Text(l10n.searchIndexAnyway),
                ),
              ),
            if (hidden > 0)
              ListTile(
                dense: true,
                title: Text(l10n.searchLargePdfsMore(hidden)),
              ),
          ],
        ],
      ),
    );
  }
}

/// Page-cap editor. A widget rather than an inline `AlertDialog` + a local
/// controller so the [TextEditingController] is disposed by the ROUTE's
/// lifecycle: disposing it right after `showDialog` returns kills it while
/// the dialog's exit animation is still rendering the field.
class _PageCapDialog extends StatefulWidget {
  const _PageCapDialog({required this.initialValue});

  final int initialValue;

  @override
  State<_PageCapDialog> createState() => _PageCapDialogState();
}

class _PageCapDialogState extends State<_PageCapDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.initialValue}',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.searchPdfPageCap),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.searchPdfPageCapField),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, int.tryParse(_controller.text.trim())),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// Skill ref of the bundled "Figure Answers" agent skill (plan §4.2).
const String figureAnswersSkillRef = 'figure-answers';

/// What the provider picker returned.
class _ProviderChoice {
  const _ProviderChoice.none() : preset = null, isNone = true, isCustom = false;
  const _ProviderChoice.custom()
    : preset = null,
      isNone = false,
      isCustom = true;
  const _ProviderChoice.preset(this.preset) : isNone = false, isCustom = false;

  final EmbeddingProviderConfig? preset;
  final bool isNone;
  final bool isCustom;
}

// ─────────────────────────────────────────────────────────────────────────
// Provider configuration route
// ─────────────────────────────────────────────────────────────────────────

/// Endpoint / model / dimensions / key form with the Test-connection probe
/// that gates enabling, the privacy+cost consent dialog, and (for local
/// providers) the gated-HuggingFace download.
class _ProviderConfigPage extends StatefulWidget {
  const _ProviderConfigPage({
    required this.config,
    required this.isCustom,
    required this.settings,
    required this.modelManager,
    required this.scopeLoader,
  });

  final EmbeddingProviderConfig config;
  final bool isCustom;
  final SearchSettingsService settings;
  final LocalEmbeddingModelManager modelManager;
  final Future<SearchIndexScope> Function() scopeLoader;

  @override
  State<_ProviderConfigPage> createState() => _ProviderConfigPageState();
}

class _ProviderConfigPageState extends State<_ProviderConfigPage> {
  late final TextEditingController _endpoint = TextEditingController(
    text: widget.config.endpoint ?? '',
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.config.modelName,
  );
  late final TextEditingController _dimensions = TextEditingController(
    text: '${widget.config.dimensions}',
  );
  final TextEditingController _apiKey = TextEditingController();

  EmbeddingProviderRegistry get _registry => getIt<EmbeddingProviderRegistry>();
  NoteIndexService get _indexer => getIt<NoteIndexService>();

  bool get _isLocal => widget.config.type == 'local';

  /// Signature of the field values that produced the last successful probe.
  /// Any edit invalidates it — a wrong dims/endpoint must never reach the
  /// indexer just because an earlier variant probed clean (plan §2.1).
  String? _probedSignature;
  bool _probing = false;
  String? _probeMessage;
  bool _probeFailed = false;
  bool _probeNotInstalled = false;
  bool _applying = false;

  // Local model install state
  bool _installed = false;
  bool _installing = false;
  int _installPercent = 0;
  String? _installError;
  StreamSubscription<LocalEmbeddingDownloadProgress>? _installProgress;

  /// Display name of the chat model whose key was borrowed to prefill the
  /// field, so the user can see where an unexpected key came from.
  String? _keyFromChatModel;

  @override
  void initState() {
    super.initState();
    unawaited(_loadKeyAndInstallState());
  }

  @override
  void dispose() {
    unawaited(_installProgress?.cancel());
    _endpoint.dispose();
    _model.dispose();
    _dimensions.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _loadKeyAndInstallState() async {
    final storedKey = await _registry.getApiKey(widget.config);
    // §2.2 key reuse: no embedding key stored yet → offer the one the user
    // already gave a CHAT model that talks to the same provider, instead of
    // sending them back to a dashboard for a key they have on file. Same
    // secure store, same options, only a different handle.
    final borrowed = (storedKey == null || storedKey.isEmpty)
        ? await _chatModelApiKey(widget.config)
        : null;
    var installed = false;
    if (_isLocal) {
      installed = await widget.modelManager.isInstalled(widget.config);
    }
    if (!mounted) return;
    setState(() {
      if (storedKey != null && storedKey.isNotEmpty) {
        _apiKey.text = storedKey;
      } else if (borrowed != null) {
        _apiKey.text = borrowed.key;
        _keyFromChatModel = borrowed.modelName;
      }
      _installed = installed;
    });
  }

  /// The API key of a configured CHAT model that talks to the same provider
  /// as [config]: same type, and for OpenAI-compatible endpoints the same
  /// base-URL host (a key is scoped to a host — a key for api.openai.com must
  /// never be prefilled for a self-hosted endpoint).
  Future<({String key, String modelName})?> _chatModelApiKey(
    EmbeddingProviderConfig config,
  ) async {
    if (config.type == 'local') return null;
    try {
      if (!getIt.isRegistered<ModelStorageService>()) return null;
      final storage = getIt<ModelStorageService>();
      final host = _hostOf(config.endpoint);
      for (final model in await storage.getConfiguredModels()) {
        final matches = switch (config.type) {
          'gemini' => model.type == ModelType.gemini,
          'openai' =>
            model.type == ModelType.openaiCompatible &&
                host != null &&
                _hostOf(model.endpoint) == host,
          _ => false,
        };
        if (!matches) continue;
        final key =
            await storage.getModelApiKey(model.id) ?? model.apiKey ?? '';
        if (key.isEmpty) continue;
        return (
          key: key,
          modelName: model.displayName ?? model.modelName ?? '',
        );
      }
    } catch (e) {
      LoggerService.warning('[SearchSettings] chat-key lookup failed: $e');
    }
    return null;
  }

  static String? _hostOf(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final host = Uri.tryParse(url.trim())?.host;
    return (host == null || host.isEmpty) ? null : host.toLowerCase();
  }

  EmbeddingProviderConfig _currentConfig() {
    final dims =
        int.tryParse(_dimensions.text.trim()) ?? widget.config.dimensions;
    final modelName = _model.text.trim().isEmpty
        ? widget.config.modelName
        : _model.text.trim();
    return widget.config.copyWith(
      endpoint: _endpoint.text.trim(),
      modelName: modelName,
      displayName: widget.isCustom ? modelName : widget.config.displayName,
      dimensions: dims,
      isCustom: widget.isCustom,
    );
  }

  String _signature() {
    final config = _currentConfig();
    return '${config.type}|${config.endpoint}|${config.modelName}|'
        '${config.dimensions}|${_apiKey.text.trim()}';
  }

  bool get _canEnable =>
      !_applying &&
      _probedSignature != null &&
      _probedSignature == _signature();

  /// Whether the form holds enough to probe. A cloud config with no endpoint
  /// cannot be reached, and a custom config with no model name would be
  /// stored under providerKey "openai::768" with an EMPTY display name — the
  /// probe alone only rejected the empty endpoint, so the model name is
  /// checked here rather than discovered later as a nameless provider.
  bool get _formComplete {
    if (_isLocal) return true;
    if (_endpoint.text.trim().isEmpty) return false;
    if (widget.isCustom && _model.text.trim().isEmpty) return false;
    return true;
  }

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _probing = true;
      _probeMessage = null;
      _probeFailed = false;
      _probeNotInstalled = false;
    });
    final config = _currentConfig();
    final key = _apiKey.text.trim();
    final result = await _registry.testConnection(
      config,
      apiKey: key.isEmpty ? null : key,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _probing = false;
        _probeFailed = true;
        _probeNotInstalled = result.isNotInstalled;
        _probedSignature = null;
        _probeMessage = result.isNotInstalled
            ? l10n.searchErrorNotInstalled(config.displayName)
            : (result.isAuthError
                  ? l10n.searchErrorAuth(config.displayName)
                  : l10n.searchTestFailed(result.errorMessage ?? ''));
      });
      return;
    }
    // Dims mismatch: adopt the corrected config rather than reporting a
    // failure — the probe's job is to make the stored dimensions true.
    final corrected = result.correctedConfig;
    if (!result.dimensionsMatched && corrected != null) {
      _dimensions.text = '${corrected.dimensions}';
    }
    setState(() {
      _probing = false;
      _probeFailed = false;
      _probedSignature = _signature();
      _probeMessage = result.dimensionsMatched
          ? l10n.searchTestOk(result.detectedDimensions ?? config.dimensions)
          : l10n.searchTestDimensionsCorrected(
              result.detectedDimensions ?? config.dimensions,
            );
    });
  }

  Future<void> _install() async {
    final l10n = AppLocalizations.of(context)!;
    final token = _apiKey.text.trim();
    await _installProgress?.cancel();
    _installProgress = null;
    setState(() {
      _installing = true;
      _installPercent = 0;
      _installError = null;
    });
    // The token rides the config's secure-storage slot (same mechanism and
    // same handle as a cloud API key) so a later re-install / repair does not
    // ask again — the gated HuggingFace repo needs it every time. It cannot
    // ride setActiveConfig(apiKey:), which would enable a provider whose
    // model is not on the device yet; saveApiKey persists without activating.
    if (token.isNotEmpty) {
      await _registry.saveApiKey(widget.config, token);
    }
    final stream = widget.modelManager.install(
      widget.config,
      authToken: token.isEmpty ? null : token,
      onComplete: () {
        if (!mounted) return;
        setState(() {
          _installing = false;
          _installed = true;
          _installPercent = 100;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.searchModelInstalled)));
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _installing = false;
          _installError = error.isAuthError
              ? l10n.searchInstallAuthFailed(error.message)
              : (error.isTransient
                    ? l10n.searchInstallTransientFailed(error.message)
                    : l10n.searchInstallFailed(error.message));
        });
      },
    );
    // Held so it can be cancelled: the stream outlives a pop mid-download
    // (the manager keeps the install running so a re-entry re-attaches), and
    // an uncancelled listener would keep calling setState on a dead State.
    _installProgress = stream.listen((progress) {
      if (!mounted) return;
      setState(() => _installPercent = progress.progressPercent);
    });
  }

  Future<void> _uninstall() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    await widget.modelManager.uninstall(widget.config);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(l10n.searchModelRemoved)));
    setState(() {
      _installed = false;
      _installPercent = 0;
    });
  }

  Future<void> _apply() async {
    final l10n = AppLocalizations.of(context)!;
    final config = _currentConfig();
    final key = _apiKey.text.trim();
    final isCloud = config.type != 'local';
    setState(() => _applying = true);
    try {
      var decision = EmbeddingConsentDecision.accept;
      if (isCloud &&
          !await widget.settings.getEmbeddingConsent(config.providerKey)) {
        if (!mounted) return;
        final scope = await widget.scopeLoader();
        if (!mounted) return;
        final serving = _registry.transitionState.servingDisplayName;
        final servingKey = _registry.transitionState.servingKey;
        final result = await _showConsentDialog(
          config: config,
          scope: scope,
          // Only disclose a switch when a DIFFERENT provider is serving.
          servingName: servingKey != null && servingKey != config.providerKey
              ? serving
              : null,
        );
        if (result == null || result == EmbeddingConsentDecision.cancel) {
          if (mounted) setState(() => _applying = false);
          return;
        }
        decision = result;
        await widget.settings.setEmbeddingConsent(config.providerKey, true);
      }

      if (decision == EmbeddingConsentDecision.acceptStopServing) {
        await _registry.revokeServing();
      }
      await _registry.setActiveConfig(config, apiKey: key.isEmpty ? null : key);
      // retryEmbedIndexing, NOT ensureBackfilled: this form is also the
      // post-key-fix hook. A rejected key halts the embed stage, and a halted
      // stage counts as SATISFIED — so a plain ensureBackfilled() no-ops and
      // the halt survives fixing the key (the key is not part of
      // providerKey, so the stage identity never changes). retryEmbedIndexing
      // clears the sticky halt rows first and then calls ensureBackfilled
      // itself. Never awaited — the backfill can take minutes.
      unawaited(
        _indexer.retryEmbedIndexing().catchError((Object e) {
          LoggerService.error('[SearchSettings] backfill kick failed: $e');
        }),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.searchProviderEnabled(config.displayName))),
      );
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// One-time privacy + cost confirmation (plan §2.2). States what leaves the
  /// device with order-of-magnitude counts, discloses the switch behavior
  /// when another provider is still serving, and offers "Stop using A now".
  Future<EmbeddingConsentDecision?> _showConsentDialog({
    required EmbeddingProviderConfig config,
    required SearchIndexScope scope,
    String? servingName,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // Text chunks only: imageChunks is a SUBSET of the uploadable total, so
    // adding the two would count every figure twice.
    final chunks = approximateCount(scope.uploadableTextChunks);
    final images = approximateCount(scope.imageChunks);
    // Nothing chunked yet (a fresh install whose first backfill has not run)
    // is NOT "about 0 chunks" — the whole corpus uploads as chunking
    // proceeds. Say that instead of quoting a number that is only true for
    // the next few seconds.
    final unknownScope = scope.uploadableChunks <= 0;
    return showDialog<EmbeddingConsentDecision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.searchConsentTitle(config.displayName)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                unknownScope
                    ? l10n.searchConsentBodyUnknown(config.displayName)
                    : (config.supportsImages && images > 0
                          ? l10n.searchConsentBodyWithImages(
                              chunks,
                              images,
                              config.displayName,
                            )
                          : l10n.searchConsentBody(chunks, config.displayName)),
              ),
              if (scope.largePdfs > 0) ...[
                const SizedBox(height: 8),
                Text(l10n.searchConsentLargePdfsExcluded(scope.largePdfs)),
              ],
              const SizedBox(height: 8),
              Text(l10n.searchConsentWifiOnly),
              if (servingName != null) ...[
                const SizedBox(height: 8),
                Text(l10n.searchConsentSwitchDisclosure(servingName)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, EmbeddingConsentDecision.cancel),
            child: Text(l10n.cancel),
          ),
          if (servingName != null)
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                EmbeddingConsentDecision.acceptStopServing,
              ),
              child: Text(l10n.searchConsentStopServing(servingName)),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, EmbeddingConsentDecision.accept),
            child: Text(l10n.searchConsentAccept),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final apiKeyUrl = widget.config.apiKeyUrl;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isCustom
              ? l10n.searchProviderCustom
              : widget.config.displayName,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_isLocal) ...[
            TextField(
              controller: _endpoint,
              enabled: widget.isCustom || widget.config.type == 'openai',
              decoration: InputDecoration(
                labelText: l10n.searchProviderEndpoint,
                helperText: l10n.searchProviderEndpointHelp,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              enabled: widget.isCustom,
              decoration: InputDecoration(
                labelText: l10n.searchProviderModelName,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dimensions,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l10n.searchProviderDimensionsField,
                helperText: l10n.searchProviderDimensionsHelp,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _isLocal
                  ? l10n.searchHuggingFaceToken
                  : l10n.searchProviderApiKey,
              helperText: _isLocal
                  ? l10n.searchHuggingFaceTokenHelp
                  : l10n.searchProviderApiKeyHelp,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_keyFromChatModel != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.searchProviderApiKeyFromChat(_keyFromChatModel!),
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (apiKeyUrl != null && apiKeyUrl.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _openUrl(apiKeyUrl),
                child: Text(
                  _isLocal ? l10n.searchGetHfToken : l10n.searchGetApiKey,
                ),
              ),
            ),
          if (_isLocal) ...[
            const Divider(height: 32),
            Text(
              l10n.searchLocalModelSection,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _installed
                  ? l10n.searchLocalModelInstalled
                  : l10n.searchLocalModelNotInstalled,
            ),
            if (_installing) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _installPercent / 100),
              const SizedBox(height: 4),
              Text(l10n.searchInstallProgress(_installPercent)),
            ],
            if (_installError != null) ...[
              const SizedBox(height: 8),
              Text(
                _installError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _installing ? null : _install,
                  icon: const Icon(Icons.download),
                  label: Text(l10n.searchInstallModel),
                ),
                const SizedBox(width: 12),
                if (_installed)
                  TextButton(
                    onPressed: _installing ? null : _uninstall,
                    child: Text(l10n.searchUninstallModel),
                  ),
              ],
            ),
          ],
          const Divider(height: 32),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: (_probing || !_formComplete)
                    ? null
                    : _testConnection,
                icon: _probing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check),
                label: Text(l10n.searchTestConnection),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _canEnable ? _apply : null,
                child: Text(l10n.searchProviderEnable),
              ),
            ],
          ),
          if (_probeMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _probeMessage!,
              style: TextStyle(
                color: _probeFailed
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
            if (_probeNotInstalled && _isLocal)
              Text(l10n.searchDownloadModelHint),
          ],
          if (!_canEnable && !_probing) ...[
            const SizedBox(height: 8),
            Text(
              _formComplete
                  ? l10n.searchTestRequired
                  : l10n.searchProviderFieldsRequired,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      LoggerService.error('[SearchSettings] could not open $url: $e');
    }
  }
}
