// Search indexer (plan §1.3): keeps `search_chunks` / `chunks_fts` derived
// from note content, incrementally and resumably.
//
// Write-path wiring (critical — DataChangeNotifier alone is NOT sufficient):
// - Primary: DatabaseService post-write hooks (`onNoteContentChanged` /
//   `onNoteDeleted`) registered in the constructor. Every note/subnote/
//   annotation/attachment mutation method calls them, which covers
//   AppProvider, tools, and services that write through DatabaseService.
// - Secondary: a DataChangeNotifier subscription catches raw-SQL writes
//   journaled by the change-capture triggers (SqlQueryService), including
//   `bulk` events whose scope is unknown — those trigger a debounced
//   backfill-style completeness sweep.
//
// The indexer NEVER touches AppProvider (and must never trigger loadData).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite/sqflite.dart';

import 'dart:math' as math;

import '../../models/attachment.dart';
import '../../models/note.dart';
import '../../models/note_annotation.dart';
import '../../utils/file_utils.dart';
import '../data_change_notifier.dart';
import '../database_service.dart';
import '../logger_service.dart';
import '../search_settings_service.dart';
import '../sync/large_row_reader.dart';
import 'attachment_ocr_extractor.dart';
import 'attachment_text_extractor.dart';
import 'embedding/embedding_provider.dart';
import 'embedding/embedding_provider_registry.dart';
import 'figure_region_extractor.dart';
import 'note_chunker.dart';
import 'search_text_normalizer.dart';
import 'vector_search.dart';

/// The GLOBAL figure-indexing switch, GUARDED (mirrors
/// `attachment_ocr_extractor.dart`'s `loadOcrEnabled`).
///
/// This seam is consulted on EVERY indexing sweep — it takes part in the
/// figures stage's completeness check — so an unavailable settings store
/// (no platform channel, e.g. a `flutter test` file that never initializes
/// the binding) must degrade to the documented default rather than abort the
/// whole sweep with an exception.
Future<bool> loadFigureIndexingEnabled() async {
  try {
    return await SearchSettingsService().getFigureIndexingEnabled();
  } catch (e) {
    LoggerService.info('[NoteIndex] Figure indexing setting unknown: $e');
    return true;
  }
}

/// Progress of a running (or the last finished) backfill, for UI surfaces
/// like the first-run "Building search index…" banner.
class IndexProgress {
  const IndexProgress({
    required this.done,
    required this.total,
    required this.stage,
    required this.running,
    this.unit = 'notes',
  });

  static const IndexProgress idle = IndexProgress(
    done: 0,
    total: 0,
    stage: NoteIndexService.stageChunks,
    running: false,
  );

  final int done;
  final int total;

  /// Pipeline stage label ('chunks' for the lexical stage, 'pdf_text' for
  /// the PDF text-layer pass, 'ocr' for text recognition, 'figures' for
  /// figure-region extraction). Internal identifier, not user-facing text —
  /// the UI maps it to an l10n'd label ("Recognizing text in PDFs —
  /// 120/900 pages").
  final String stage;
  final bool running;

  /// What [done]/[total] count: 'notes' (chunks stage), 'attachments'
  /// (pdf_text and figures stages), or 'pages' (ocr stage).
  final String unit;

  @override
  String toString() =>
      'IndexProgress($done/$total $unit, stage: $stage, running: $running)';
}

/// Maintains the lexical chunk index for notes.
///
/// All chunk/FTS/state writes for one note happen in a single transaction, so
/// readers never observe a half-indexed note. Index writes are serialized on
/// an internal queue so a debounced reindex can never interleave with a
/// backfill write for the same note.
class NoteIndexService {
  /// [embeddingRegistry] + [vectorSearch] enable the embed pipeline stage
  /// (both null → stage off entirely).
  ///
  /// Seams for Step 10's settings wiring (and for tests):
  /// - [embedConsentCheck]: whether the user granted the one-time consent
  ///   for a providerKey. Default reads [SearchSettingsService
  ///   .getEmbeddingConsent] — no consent recorded → the stage no-ops.
  /// - [embedNetworkAllowed]: wifi-only gating. Default: always allowed;
  ///   Step 10 wires connectivity + the wifi-only-backfill setting. A false
  ///   result DEFERS the pass (like a battery deferral), leaving the global
  ///   flag unset so the next sweep retries.
  /// - [embedConsentRevoke]: withdraws a providerKey's consent. Called by
  ///   [deleteStoredEmbeddings] so the escape hatch cannot be undone by a
  ///   background sweep re-uploading the corpus.
  /// - [figuresEnabledLoader]: the GLOBAL figure-indexing switch. Default
  ///   reads [SearchSettingsService.getFigureIndexingEnabled] (SharedPrefs
  ///   has no platform channel under `flutter test`, hence the seam).
  /// - [derivedFigureDirLoader]: where derived figure crops live. Used by the
  ///   PURGE paths only (the extractor owns writing them); tests point it at
  ///   a temp dir.
  NoteIndexService(
    this._db, {
    DataChangeNotifier? changeNotifier,
    AttachmentTextExtractor? extractor,
    AttachmentOcrExtractor? ocrExtractor,
    FigureRegionExtractor? figureExtractor,
    EmbeddingProviderRegistry? embeddingRegistry,
    VectorSearch? vectorSearch,
    Future<bool> Function(String providerKey)? embedConsentCheck,
    Future<void> Function(String providerKey)? embedConsentRevoke,
    Future<bool> Function()? embedNetworkAllowed,
    Future<bool> Function()? figuresEnabledLoader,
    Future<Directory> Function()? derivedFigureDirLoader,
    @visibleForTesting this.embedScanPageSize = _embedScanPageSize,
    this.embedRetryBaseDelay = const Duration(seconds: 1),
    this.embedMaxRetries = 3,
    this.debounceDelay = const Duration(seconds: 2),
  }) : _changeNotifier = changeNotifier ?? DataChangeNotifier.shared(),
       _extractor = extractor ?? AttachmentTextExtractor(_db),
       _ocrExtractor = ocrExtractor ?? AttachmentOcrExtractor(_db),
       _figureExtractor = figureExtractor ?? FigureRegionExtractor(),
       _figuresEnabledLoader =
           figuresEnabledLoader ?? loadFigureIndexingEnabled,
       _derivedFigureDirLoader =
           derivedFigureDirLoader ?? defaultDerivedFigureDirectory,
       _embeddingRegistry = embeddingRegistry,
       _vectorSearch = vectorSearch,
       _embedConsentCheck =
           embedConsentCheck ??
           ((providerKey) =>
               SearchSettingsService().getEmbeddingConsent(providerKey)),
       _embedConsentRevoke =
           embedConsentRevoke ??
           ((providerKey) =>
               SearchSettingsService().setEmbeddingConsent(providerKey, false)),
       _embedNetworkAllowed = embedNetworkAllowed ?? (() async => true) {
    // Inversion of control: DatabaseService exposes the hooks but never
    // imports the indexer.
    _db.onNoteContentChanged = scheduleReindex;
    _db.onNoteDeleted = _handleNoteDeleted;
    _subscription = _changeNotifier.addListener(_onDataChange);
  }

  static const String stageChunks = 'chunks';
  static const String stagePdfText = 'pdf_text';
  static const String stageOcr = 'ocr';
  static const String stageFigures = 'figures';

  /// Embedding stage label for one providerKey ("embed:{type}:{model}:
  /// {dims}"); its global row ('global','all',stage) tracks backfill
  /// completeness per provider, and 'chunk'-scoped rows record per-chunk
  /// permanent errors.
  static String stageEmbed(String providerKey) => 'embed:$providerKey';

  static const String statusDone = 'done';
  static const String statusSkipped = 'skipped';

  /// PDF over the page cap without an explicit opt-in — distinct from
  /// [statusSkipped] so settings can list "N large PDFs not indexed".
  static const String statusSkippedTooLarge = 'skipped_too_large';
  static const String statusError = 'error';

  /// sourceTypes owned by the note-content chunk stage. The per-note diff in
  /// [_writeChunks] is scoped to these, so attachment-derived chunks
  /// (attachment_text now; attachment_ocr / figure later) survive a note
  /// reindex — they are maintained by their own stages.
  static const String _noteSourceTypesSql =
      "('meta','note_body','subnote','annotation')";

  /// Sentinel contentHash for policy-excluded notes: stable while excluded
  /// (content edits don't force re-chunking) and guaranteed to mismatch a
  /// real fingerprint once the exclusion is lifted.
  static const String _excludedFingerprint = 'excluded';

  /// Maximum notes chunked per compute() batch during backfill.
  static const int _backfillBatchSize = 50;

  /// Text-size budget (note, subnote, and annotation content) per compute()
  /// batch, so large child records cannot hide behind a small note body. A single
  /// note always forms a batch even when it exceeds the budget alone.
  static const int _backfillBatchByteBudget = 2 * 1024 * 1024;

  /// SQLite variable-limit-safe IN() chunk size.
  static const int _sqlVarChunk = 500;

  /// Rows per page of the embed gap scan (ids only — the text of a batch is
  /// fetched right before it is embedded).
  static const int _embedScanPageSize = 1000;

  final DatabaseService _db;
  final DataChangeNotifier _changeNotifier;

  /// PDF text-layer extractor feeding the pdf_text stage (constructed here
  /// rather than via the service locator so locator wiring stays untouched).
  final AttachmentTextExtractor _extractor;

  /// On-device OCR extractor feeding the ocr stage (same wiring rationale).
  final AttachmentOcrExtractor _ocrExtractor;

  /// Figure/table region extractor feeding the figures stage.
  final FigureRegionExtractor _figureExtractor;

  /// GLOBAL figure-indexing switch (plan §4.1) and the derived-asset
  /// directory used by the purge paths.
  final Future<bool> Function() _figuresEnabledLoader;
  final Future<Directory> Function() _derivedFigureDirLoader;

  /// Embedding provider source for the embed stage; null → stage off.
  final EmbeddingProviderRegistry? _embeddingRegistry;

  /// In-memory vector index kept fresh with incremental patches (upsert on
  /// embed write, remove on chunk delete).
  final VectorSearch? _vectorSearch;

  final Future<bool> Function(String providerKey) _embedConsentCheck;
  final Future<void> Function(String providerKey) _embedConsentRevoke;
  final Future<bool> Function() _embedNetworkAllowed;

  /// Base delay of the exponential backoff on transient embed failures
  /// (attempt n waits base·2ⁿ); after [embedMaxRetries] retries the pass
  /// defers to the next sweep instead.
  final Duration embedRetryBaseDelay;
  final int embedMaxRetries;

  /// Per-note debounce delay for [scheduleReindex].
  final Duration debounceDelay;

  /// Rows per page of the embed gap scan (see [_embedScanPageSize]).
  final int embedScanPageSize;

  late final DataChangeSubscription _subscription;
  final Map<String, Timer> _debounceTimers = {};
  Timer? _bulkCheckTimer;
  bool _paused = false;
  Future<void>? _backfill;

  /// Latched forced pass: resolves after the forced backfill that follows the
  /// currently running one (see [backfillAll]).
  Future<void>? _forcedFollowUp;

  /// A bulk mutation can land after the active sweep took its source
  /// snapshot. Coalescing into that run would lose new or changed sources;
  /// keep one follow-up pass for all such events.
  Future<void>? _bulkFollowUp;

  /// Note ids whose change events arrived while paused. Flushed (as normal
  /// debounced reindexes) on [resume] so pausing never loses events.
  final Set<String> _pendingWhilePaused = {};

  /// Tail of the serialized index-write queue.
  Future<void> _queueTail = Future.value();

  /// Tail of the serialized embed-pass queue. SEPARATE from [_queueTail]:
  /// embed passes make network calls that must never block index writes, so
  /// only their database writes ride the write queue (via [_serialized])
  /// while the passes themselves serialize here (one provider pass at a
  /// time — no request stampede from concurrent per-note passes).
  Future<void> _embedTail = Future.value();

  // Deleting stored vectors cancels work already waiting on a provider. A
  // response from an earlier generation must never recreate deleted data.
  int _embedGeneration = 0;
  bool _deletingEmbeddings = false;

  /// Chunk ids whose vectors became stale in a COMMITTED write of the
  /// current queued action (chunk deleted, or content changed invalidating
  /// its embeddings). Filled only by [_transactionWithRemovals] after a
  /// successful commit, and flushed to [_vectorSearch] once the action ends.
  final List<int> _pendingVectorRemovals = [];

  final ValueNotifier<IndexProgress> _progress = ValueNotifier(
    IndexProgress.idle,
  );

  /// Backfill progress (done/total notes, stage label, running flag).
  ValueListenable<IndexProgress> get progress => _progress;

  /// Number of completed reindex passes; test observability for debounce
  /// coalescing.
  @visibleForTesting
  int debugReindexRuns = 0;

  /// Notes actually chunked (sent through compute()) by backfill runs; test
  /// observability for the fingerprint-before-chunking skip.
  @visibleForTesting
  int debugBackfillNotesChunked = 0;

  /// Largest estimated source-text batch loaded by the last sweep. A
  /// single over-budget note must still be processed on its own.
  @visibleForTesting
  int debugBackfillLargestBatchBytes = 0;

  /// Queues a snapshot-guarded chunk write, exactly like a backfill batch
  /// write does. Test hook for the stale-snapshot guard.
  @visibleForTesting
  Future<void> debugWriteChunksGuarded(
    String noteId,
    List<ChunkDraft> drafts,
    List<String> normalized,
    String fingerprint, {
    required String? snapshotStateHash,
  }) {
    return _serialized(
      () => _writeChunks(
        noteId,
        drafts,
        normalized,
        fingerprint,
        guardSnapshot: true,
        snapshotStateHash: snapshotStateHash,
      ),
    );
  }

  // ── Metadata policy ──────────────────────────────────────────────────────

  /// Whether `notes.metadata.searchIndex.exclude == true`.
  static bool isNoteSearchExcluded(Map<String, dynamic>? metadata) {
    final searchIndex = metadata?['searchIndex'];
    if (searchIndex is Map) return searchIndex['exclude'] == true;
    return false;
  }

  /// Writes the per-note exclusion flag and immediately purges (or rebuilds)
  /// the note's chunks, so excluded content stops appearing in results right
  /// away (purge-on-toggle, plan §1.3).
  Future<void> setNoteSearchExclusion(String noteId, bool exclude) async {
    final metadata = Map<String, dynamic>.from(
      await _db.getNoteMetadata(noteId) ?? <String, dynamic>{},
    );
    final searchIndex = Map<String, dynamic>.from(
      metadata['searchIndex'] as Map? ?? <String, dynamic>{},
    );
    if (exclude) {
      searchIndex['exclude'] = true;
    } else {
      searchIndex.remove('exclude');
    }
    if (searchIndex.isEmpty) {
      metadata.remove('searchIndex');
    } else {
      metadata['searchIndex'] = searchIndex;
    }
    await _db.updateNoteMetadata(noteId, metadata.isEmpty ? null : metadata);
    await reindexNote(noteId);
  }

  // ── Event intake ─────────────────────────────────────────────────────────

  /// Debounced (2 s per note, coalescing) reindex trigger — the entry point
  /// used by the DatabaseService write hooks.
  void scheduleReindex(String noteId) {
    if (_paused) {
      _pendingWhilePaused.add(noteId);
      return;
    }
    _debounceTimers[noteId]?.cancel();
    _debounceTimers[noteId] = Timer(debounceDelay, () {
      _debounceTimers.remove(noteId);
      reindexNote(noteId).catchError((Object e) {
        LoggerService.error(
          '[NoteIndex] Scheduled reindex failed for $noteId: $e',
          error: e,
        );
      });
    });
  }

  void _handleNoteDeleted(String noteId) {
    if (_paused) {
      // A reindex of a deleted note purges its rows, so the resume flush
      // (which schedules reindexes) heals deletions too.
      _pendingWhilePaused.add(noteId);
      return;
    }
    _debounceTimers.remove(noteId)?.cancel();
    unawaited(
      removeNote(noteId).catchError((Object e) {
        LoggerService.error(
          '[NoteIndex] Remove failed for deleted note $noteId: $e',
          error: e,
        );
      }),
    );
  }

  Future<void> _onDataChange(DataChangeEvent event) async {
    if (_paused) {
      // Bulk events need no queuing: resume() always runs a completeness
      // sweep, which covers whatever the bulk write touched.
      _pendingWhilePaused.addAll(event.noteIds);
      return;
    }
    if (event.bulk) {
      // Unknown scope (DDL / degraded capture): schedule a completeness
      // sweep — backfillAll skips up-to-date notes via fingerprints, so this
      // stays cheap when nothing relevant changed.
      _bulkCheckTimer?.cancel();
      _bulkCheckTimer = Timer(debounceDelay, () {
        _bulkCheckTimer = null;
        final running = _backfill;
        final sweep = running == null
            ? backfillAll()
            : (_bulkFollowUp ??= running
                  .then<void>((_) {}, onError: (_) {})
                  .then((_) {
                    _bulkFollowUp = null;
                    return backfillAll();
                  }));
        unawaited(
          sweep.catchError((Object e) {
            LoggerService.error(
              '[NoteIndex] Bulk completeness sweep failed: $e',
              error: e,
            );
          }),
        );
      });
      return;
    }
    for (final noteId in event.noteIds) {
      scheduleReindex(noteId);
    }
    // relationshipNoteIds / tagsChanged / filtersChanged carry no chunk
    // content by themselves; tag renames already surface as per-note ids via
    // the notesWithTag capture trigger.
  }

  // ── Pause / resume (recovery swap) ───────────────────────────────────────

  /// Stop taking indexing events and drain every queued index write. Used
  /// while recovery swaps the database file under the live connection — an
  /// in-flight index write would race the copy or target the pre-swap file,
  /// so this only resolves once the queue is empty and stays empty.
  Future<void> pause() async {
    _paused = true;
    for (final entry in _debounceTimers.entries) {
      entry.value.cancel();
      // Not dropped: the resume flush reindexes these notes.
      _pendingWhilePaused.add(entry.key);
    }
    _debounceTimers.clear();
    _bulkCheckTimer?.cancel();
    _bulkCheckTimer = null;
    // Drain until stable: a running backfill may enqueue one more per-note
    // write before it observes _paused between notes, and a running embed
    // pass (which aborts between batches once paused) may enqueue one more
    // batch write.
    Future<void> tail;
    Future<void> embedTail;
    do {
      tail = _queueTail;
      embedTail = _embedTail;
      await tail;
      await embedTail;
    } while (!identical(tail, _queueTail) || !identical(embedTail, _embedTail));
  }

  /// Re-enable indexing, flush the events that arrived while paused, and run
  /// an unconditional completeness sweep (raw-SQL/bulk writes that happened
  /// while paused leave no per-note trace, and recovery may have swapped in
  /// a database whose index is arbitrarily stale — the sweep is cheap because
  /// up-to-date notes are skipped by fingerprint before chunking).
  void resume() {
    _paused = false;
    final pending = _pendingWhilePaused.toList();
    _pendingWhilePaused.clear();
    for (final noteId in pending) {
      scheduleReindex(noteId);
    }
    unawaited(
      backfillAll().catchError((Object e) {
        LoggerService.error(
          '[NoteIndex] Post-resume backfill check failed: $e',
          error: e,
        );
      }),
    );
  }

  /// Runs a backfill unless EVERY stage's global completion flag is set —
  /// 'chunks', 'pdf_text', and 'ocr'. The per-stage checks are what resume
  /// an interrupted pass across app restarts: the chunks flag is written
  /// BEFORE the attachment passes run (see [_runBackfill]), so an app killed
  /// mid-pdf-or-ocr-pass restarts with chunks done but no pdf_text/ocr
  /// global row. A battery-deferred ocr pass also leaves the ocr flag unset,
  /// so the next sweep (e.g. once charging) picks the work back up.
  ///
  /// The pdf_text/ocr/figures checks are POLICY-AWARE (each stage's global
  /// row carries the settings its last completed pass ran under), so a
  /// settings change alone makes this false and the next sweep re-evaluates
  /// the per-attachment hashes.
  Future<void> ensureBackfilled() async {
    if (_paused) return;
    if (await isBackfillComplete() &&
        await _pdfTextStageComplete() &&
        await _ocrStageComplete() &&
        await _figuresStageComplete() &&
        await _embedStageSatisfied()) {
      return;
    }
    await backfillAll();
  }

  /// Whether the pdf_text stage's global row is done FOR THE CURRENT PDF
  /// SETTINGS, exactly like [_ocrStageComplete] / [_figuresStageComplete]: its
  /// contentHash records [_pdfTextPolicyHash] as of the completed pass, so a
  /// page-cap change makes this false and the next sweep re-runs the stage —
  /// which is what re-admits a `skipped_too_large` PDF when the cap is raised
  /// (and re-skips one when it is lowered).
  ///
  /// Without the policy component a stale `done` row short-circuits
  /// [ensureBackfilled] and the per-attachment hashes never even get compared
  /// — the same bug Step 14 fixed for figures and Step 18 for ocr. The
  /// settings screen kicks a sweep right after writing the cap, so that
  /// short-circuit was the whole reason raising the cap from 100 to 1000 left
  /// a 512-page PDF sitting in the "large PDFs not indexed" list until a
  /// forced rebuild.
  ///
  /// A pre-existing done row written before this hash existed (contentHash
  /// NULL) mismatches too: one extra sweep re-evaluates every attachment
  /// (a stat + one state-row read each) and stamps the hash.
  Future<bool> _pdfTextStageComplete() async {
    final db = await _db.database;
    final rows = await db.query(
      'search_index_state',
      columns: ['status', 'contentHash'],
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stagePdfText],
    );
    if (rows.isEmpty || rows.first['status'] != statusDone) return false;
    return rows.first['contentHash'] == await _pdfTextPolicyHash();
  }

  /// contentHash recorded on the ('global','all','pdf_text') row: every
  /// SETTINGS input that applies to EVERY attachment and can change the
  /// stage's outcome. The page cap is the only one — the stage's other inputs
  /// are per-attachment (`text` policy, file fingerprint) or per-note (search
  /// exclusion), and the per-attachment hashes already carry those, so they
  /// need no global invalidation. Should the stage ever gain a global switch
  /// of its own (as ocr and figures have), it belongs here too.
  ///
  /// A cap change re-runs the PASS, not the extraction: the per-attachment
  /// hashes decide what actually re-extracts, and [_pdfStateIsCurrent] keeps
  /// that to the documents the cap could flip (see its rules) — a done 2-page
  /// PDF costs one state-row read.
  Future<String> _pdfTextPolicyHash() async =>
      'cap=${await _effectivePageCap()}';

  /// Whether the ocr stage's global row is done FOR THE CURRENT OCR SETTINGS.
  /// Its contentHash records [_ocrPolicyHash] as of the completed pass, so
  /// changing one of those settings makes this false and the next sweep
  /// re-runs the stage — which is what purges every `attachment_ocr` chunk
  /// when OCR goes off (and re-extracts them when it comes back on).
  ///
  /// Without the policy component this predicate short-circuits
  /// [ensureBackfilled] on the stale done row, so a settings change has no
  /// effect until an unrelated forced rebuild — the per-attachment state
  /// hashes never even get compared.
  Future<bool> _ocrStageComplete() async {
    final db = await _db.database;
    final rows = await db.query(
      'search_index_state',
      columns: ['status', 'contentHash'],
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stageOcr],
    );
    if (rows.isEmpty || rows.first['status'] != statusDone) return false;
    return rows.first['contentHash'] == await _ocrPolicyHash();
  }

  /// contentHash recorded on the ('global','all','ocr') row: the OCR settings
  /// that apply to EVERY attachment — the global switch and the recognizer
  /// script. Both invalidate the stage as a whole; the per-attachment hashes
  /// (which carry the same values plus the file/policy ones) then decide
  /// which attachments actually re-run.
  ///
  /// The page cap is deliberately NOT here: it binds only for over-cap PDFs,
  /// and their per-attachment `cap=` component already re-runs them.
  Future<String> _ocrPolicyHash() async {
    final enabled = await _ocrExtractor.ocrEnabled();
    final script = (await _ocrExtractor.effectiveScript()).name;
    return 'gocr=$enabled|script=$script';
  }

  /// Whether the figures stage's global row is done FOR THE CURRENT SETTINGS,
  /// exactly like [_ocrStageComplete]: its contentHash records
  /// [_figuresPolicyHash] as of the completed pass, so flipping a setting
  /// makes this false and the next sweep re-runs the stage (which is what
  /// purges every `figure` chunk + derived crop when figure indexing goes
  /// off, and re-extracts them when it comes back on).
  ///
  /// Without the policy component a stale `done` row short-circuits
  /// [ensureBackfilled] and the per-attachment hashes never even get
  /// compared — the bug Step 18 fixed for the ocr stage.
  Future<bool> _figuresStageComplete() async {
    final db = await _db.database;
    final rows = await db.query(
      'search_index_state',
      columns: ['status', 'contentHash'],
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stageFigures],
    );
    if (rows.isEmpty || rows.first['status'] != statusDone) return false;
    return rows.first['contentHash'] == await _figuresPolicyHash();
  }

  /// contentHash recorded on the ('global','all','figures') row: every input
  /// that applies to EVERY attachment and can change the stage's outcome —
  /// the global figures switch, the global OCR switch and recognizer script
  /// (OCR block bounds are a first-class caption-anchor source, so both
  /// change which regions are found), and the shared page cap.
  ///
  /// The cap participates here (as it does in [_pdfTextPolicyHash]), unlike
  /// [_ocrPolicyHash] where it is deliberately absent: a cap change can flip a
  /// PDF between "extract" and `skipped_too_large`, and re-running the pass
  /// costs one state-row read per unchanged attachment (the per-attachment
  /// hashes decide what actually re-extracts, see [_pdfStateIsCurrent]).
  Future<String> _figuresPolicyHash() async {
    final figures = await _figuresEnabled();
    final globalOcr = await _ocrExtractor.ocrEnabled();
    final script = (await _ocrExtractor.effectiveScript()).name;
    final cap = await _effectivePageCap();
    return 'gfig=$figures|gocr=$globalOcr|script=$script|cap=$cap';
  }

  /// The GLOBAL figure-indexing switch (plan §4.1). Guarded by default (see
  /// [loadFigureIndexingEnabled]).
  Future<bool> _figuresEnabled() => _figuresEnabledLoader();

  /// The shared PDF page cap (`searchIndexPdfPageCap`), GUARDED for the same
  /// reason [loadFigureIndexingEnabled] is: the pdf_text and figures policy
  /// hashes both fold it in, so it is read on EVERY sweep — before either
  /// stage holds an eligible attachment, and in databases with no attachments
  /// at all. An unreachable settings store (no platform channel, e.g. a
  /// `flutter test` file that never initializes the binding) must degrade to
  /// the documented default rather than abort the whole sweep.
  ///
  /// Deliberately ONE seam for both stages, reading the same
  /// `AttachmentTextExtractor.pageCapLoader` the extraction path uses: two
  /// independent readers of the same setting could disagree, and a policy
  /// hash saying `cap=1000` while extraction still gates at 100 would freeze
  /// the stage in a permanent re-run.
  Future<int> _effectivePageCap() async {
    try {
      return await _extractor.effectivePageCap();
    } catch (e) {
      LoggerService.info('[NoteIndex] Page cap unknown: $e');
      return SearchSettingsService.defaultPdfPageCap;
    }
  }

  /// Whether the embed stage needs no work right now. True when the stage is
  /// off (no registry, no active provider, or no consent — plan §2.3: the
  /// stage's global row is consulted ONLY when a provider is active AND
  /// consented), when the active key's backfill is done AND it is already
  /// serving (or was explicitly revoked from serving), or when the stage is
  /// halted on a recorded auth/permanent error — halts are sticky until
  /// [retryEmbedIndexing] or a forced rebuild, so sweeps never burn quota
  /// re-hitting a misconfigured provider.
  ///
  /// Deliberately side-effect free: promotion happens only where a pass
  /// actually runs ([_runEmbedPass]). A "done but not serving" key — e.g.
  /// re-enabling a provider whose vectors were kept when switching to None —
  /// reports NOT satisfied, so the sweep runs a pass that finds zero gaps
  /// and promotes it (no re-embedding, no provider calls). Promoting from
  /// inside this predicate instead would silently undo [revokeServing] on
  /// the next sweep or app start.
  Future<bool> _embedStageSatisfied() async {
    final registry = _embeddingRegistry;
    if (registry == null) return true;
    await registry.ensureInitialized();
    final config = registry.activeConfig;
    if (config == null) return true;
    if (!await _embedConsentCheck(config.providerKey)) return true;
    final db = await _db.database;
    final rows = await db.query(
      'search_index_state',
      columns: ['status'],
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stageEmbed(config.providerKey)],
    );
    if (rows.isEmpty) return false;
    final status = rows.first['status'];
    if (status == statusDone) {
      return registry.servingProviderKey == config.providerKey ||
          registry.isServingRevoked(config.providerKey);
    }
    return status == statusError;
  }

  /// Whether search_index_state('global','all','chunks') is done — the flag
  /// that gates the substring fallback (plan §1.5). Deliberately chunks-only:
  /// PDF extraction must never pin search to the substring fallback.
  Future<bool> isBackfillComplete() => _isStageBackfillComplete(stageChunks);

  Future<bool> _isStageBackfillComplete(String stage) async {
    final db = await _db.database;
    final rows = await db.query(
      'search_index_state',
      columns: ['status'],
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stage],
    );
    return rows.isNotEmpty && rows.first['status'] == statusDone;
  }

  // ── Reindex / remove ─────────────────────────────────────────────────────

  /// Rechunks [noteId] and diffs against the stored chunks: unchanged chunks
  /// (same chunkKey + contentHash) are left untouched, changed ones are
  /// updated in place (keeping their rowid), stale ones are deleted together
  /// with their FTS rows and embeddings. A missing note purges its chunks; a
  /// policy-excluded note purges and marks state 'skipped'.
  Future<void> reindexNote(String noteId) {
    _debounceTimers.remove(noteId)?.cancel();
    final run = _serialized(() => _reindexNoteNow(noteId));
    // pdf_text stage rides the same serialized queue right behind the chunk
    // txn but is NOT awaited by the caller: PDF extraction is slow and must
    // never block a note reindex. Attachment insert/delete flows here too
    // (their DatabaseService hooks call scheduleReindex with the noteId).
    unawaited(
      _serialized(() => _pdfTextForNote(noteId)).catchError((Object e) {
        LoggerService.error(
          '[NoteIndex] pdf_text pass failed for $noteId: $e',
          error: e,
        );
      }),
    );
    // ocr stage queues AFTER pdf_text (same queue, so ordering is
    // guaranteed): the merge policy dedupes OCR blocks against the page's
    // freshly written attachment_text chunks.
    unawaited(
      _serialized(() => _ocrForNote(noteId)).catchError((Object e) {
        LoggerService.error(
          '[NoteIndex] ocr pass failed for $noteId: $e',
          error: e,
        );
      }),
    );
    // figures stage queues AFTER ocr (same queue): region inference reads the
    // attachment's freshly written `attachment_ocr` chunk meta for caption
    // anchors and text obstacles.
    final figuresRun = _serialized(() => _figuresForNote(noteId)).catchError((
      Object e,
    ) {
      LoggerService.error(
        '[NoteIndex] figures pass failed for $noteId: $e',
        error: e,
      );
    });
    // embed stage runs after the derived stages complete (so freshly written
    // attachment/figure chunks embed in the same round) but OFF the write
    // queue — provider network calls must never block index writes. Scoped to
    // this note; the gap scan makes it a no-op when nothing changed.
    unawaited(
      figuresRun.then((_) async {
        try {
          await _embedSerialized(
            () => _runEmbedPass(scopeNoteId: noteId, force: false),
          );
        } catch (e) {
          LoggerService.error(
            '[NoteIndex] embed pass failed for $noteId: $e',
            error: e,
          );
        }
      }),
    );
    return run;
  }

  /// Deletes all chunks, FTS rows, embeddings, and state rows for [noteId].
  Future<void> removeNote(String noteId) {
    _debounceTimers.remove(noteId)?.cancel();
    return _serialized(() => _removeNoteNow(noteId));
  }

  /// Fires all pending debounced reindexes now and waits for every queued
  /// index write (including removals) to finish. Test helper.
  @visibleForTesting
  Future<void> flushPending() async {
    final ids = _debounceTimers.keys.toList();
    for (final id in ids) {
      _debounceTimers.remove(id)?.cancel();
    }
    await Future.wait(ids.map(reindexNote));
    // Stabilization loop: per-note embed passes are chained onto the ocr
    // action's completion via a microtask, so a single tail await can miss
    // work that has not been enqueued yet.
    Future<void> tail;
    Future<void> embedTail;
    do {
      tail = _queueTail;
      embedTail = _embedTail;
      await tail;
      await embedTail;
      await Future<void>.delayed(Duration.zero);
    } while (!identical(tail, _queueTail) || !identical(embedTail, _embedTail));
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _queueTail.then((_) => action());
    // Errors are surfaced to the caller of the queued operation; the queue
    // itself must keep draining. Vector-index removals COMMITTED by the
    // action are flushed once it completes (queue actions never interleave,
    // so the pending list always belongs to exactly one action) — including
    // when a later step of the same action threw, since those earlier
    // commits really did remove the rows.
    _queueTail = run
        .then<void>((_) {}, onError: (_) {})
        .whenComplete(_flushVectorRemovals);
    return run;
  }

  Future<T> _embedSerialized<T>(Future<T> Function() action) {
    final run = _embedTail.then((_) => action());
    _embedTail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  void _flushVectorRemovals() {
    if (_pendingVectorRemovals.isEmpty) return;
    final ids = List<int>.of(_pendingVectorRemovals);
    _pendingVectorRemovals.clear();
    _vectorSearch?.removeChunks(ids);
  }

  /// Runs [action] in a transaction, collecting the chunk ids whose vectors
  /// it evicts into a LOCAL list and merging them into
  /// [_pendingVectorRemovals] only once the transaction COMMITS.
  ///
  /// Queueing them inside the transaction body instead would evict rows that
  /// a rollback then restores: the vector index would silently disagree with
  /// `chunk_embeddings` until the app restarts (the matrix is refreshed by
  /// patches, never re-read).
  Future<T> _transactionWithRemovals<T>(
    Database db,
    Future<T> Function(Transaction txn, List<int> removals) action,
  ) async {
    final removals = <int>[];
    final result = await db.transaction((txn) => action(txn, removals));
    _pendingVectorRemovals.addAll(removals);
    return result;
  }

  Future<void> _reindexNoteNow(String noteId) async {
    final note = (await _db.getNotesByIds([noteId])).firstOrNull;
    if (note == null) {
      await _removeNoteNow(noteId);
      return;
    }
    final metadata = await _db.getNoteMetadata(noteId);
    if (isNoteSearchExcluded(metadata)) {
      await _purgeToSkipped(noteId);
      debugReindexRuns++;
      return;
    }
    final annotations = await _loadAnnotations(noteId);
    // Editing/importing a large note can cost many frames of synchronous
    // hashing, chunking, and normalization. Use the same worker as startup
    // backfill so the debounced path also keeps that CPU off the UI isolate.
    final output = (await compute(_chunkNotesBatch, [
      _BackfillInput(note: note, annotations: annotations),
    ])).single;
    await _writeChunks(
      noteId,
      output.drafts,
      output.normalized,
      output.fingerprint,
    );
    debugReindexRuns++;
  }

  /// Annotations feeding a note's chunks: note-scoped rows plus rows scoped
  /// to the note's attachments (deduplicated by id).
  Future<List<NoteAnnotation>> _loadAnnotations(String noteId) async =>
      (await _loadAnnotationsForNotes([noteId]))[noteId] ?? [];

  /// One owner join per note batch replaces the former per-note query plus
  /// one additional query for every attachment. Attachment-only annotations
  /// are included, and a row with both owner fields is deduplicated per note.
  Future<Map<String, List<NoteAnnotation>>> _loadAnnotationsForNotes(
    List<String> noteIds,
  ) async => loadIndexAnnotations(await _db.database, noteIds);

  /// Source-only annotation reader, exposed for a CursorWindow-constrained
  /// executor regression. Paths and timestamps never feed chunks and are
  /// deliberately omitted, even when old annotations store large payloads.
  @visibleForTesting
  static Future<Map<String, List<NoteAnnotation>>> loadIndexAnnotations(
    DatabaseExecutor db,
    List<String> noteIds,
  ) async {
    if (noteIds.isEmpty) return {};
    final placeholders = List.filled(noteIds.length, '?').join(',');
    final rows = await db.rawQuery(
      // Separate indexed branches: an OR spanning a joined owner would
      // force SQLite to scan every annotation again for each note batch.
      'SELECT ann.id, ann.note_id AS _ownerNoteId FROM note_annotations ann '
      'WHERE ann.note_id IN ($placeholders) '
      'UNION ALL '
      'SELECT ann.id, a.noteId AS _ownerNoteId FROM attachments a '
      'JOIN note_annotations ann ON ann.attachment_id = a.id '
      'WHERE a.noteId IN ($placeholders) AND a.__deleted__ = 0 '
      'AND (ann.note_id IS NULL OR ann.note_id <> a.noteId)',
      [...noteIds, ...noteIds],
    );
    final ids = {for (final row in rows) row['id'] as String}.toList();
    final annotations = <String, NoteAnnotation>{};
    for (var i = 0; i < ids.length; i += _sqlVarChunk) {
      final page = ids.sublist(i, math.min(i + _sqlVarChunk, ids.length));
      final contents = await readSyncRowsWhere(
        db,
        table: 'note_annotations',
        columns: ['id', 'content'],
        keyColumns: ['id'],
        where: 'id IN (${List.filled(page.length, '?').join(',')})',
        whereArgs: page,
      );
      for (final row in contents) {
        final id = row['id'] as String;
        annotations[id] = NoteAnnotation(
          id: id,
          content: row['content'] as String? ?? '',
          attachmentPaths: const [],
          createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        );
      }
    }
    final byNote = <String, List<NoteAnnotation>>{};
    for (final row in rows) {
      final annotation = annotations[row['id']];
      if (annotation != null) {
        (byNote[row['_ownerNoteId'] as String] ??= []).add(annotation);
      }
    }
    return byNote;
  }

  /// Loads first-upgrade attachment policy without asking Android for a
  /// multi-megabyte joined row. Keep only the search policy once parsed:
  /// unrelated PDF marker data must not accumulate across the full library.
  @visibleForTesting
  static Future<List<(Attachment, bool)>> loadIndexAttachments(
    DatabaseExecutor db, {
    String? eligibleFileNameSql,
  }) async {
    final owners = await db.rawQuery(
      'SELECT a.id, '
      'COALESCE(length(CAST(a.metadata AS BLOB)), 0) + '
      'COALESCE(length(CAST(n.metadata AS BLOB)), 0) AS metadataBytes '
      'FROM attachments a JOIN notes n ON n.id = a.noteId '
      '$_liveRowsPredicate '
      '${eligibleFileNameSql == null ? '' : 'AND ($eligibleFileNameSql)'}',
    );
    final lengths = {
      for (final row in owners)
        row['id'] as String: row['metadataBytes'] as int,
    };
    final work = <(Attachment, bool)>[];
    for (final ids in planBackfillBatches(lengths.keys.toList(), lengths)) {
      final rows = await readSyncRowsWhere(
        db,
        table: 'attachments',
        columns: [
          'id',
          'noteId',
          'filePath',
          'fileName',
          'fileType',
          'createdAt',
          'isRelativePath',
          'includeInAIContext',
          'metadata',
        ],
        keyColumns: ['id'],
        where:
            'id IN (${List.filled(ids.length, '?').join(',')}) AND __deleted__ = 0',
        whereArgs: ids,
      );
      final noteIds = {
        for (final row in rows) row['noteId'] as String,
      }.toList();
      if (noteIds.isEmpty) continue;
      final noteRows = await readSyncRowsWhere(
        db,
        table: 'notes',
        columns: ['id', 'metadata'],
        keyColumns: ['id'],
        where:
            'id IN (${List.filled(noteIds.length, '?').join(',')}) AND __deleted__ = 0',
        whereArgs: noteIds,
      );
      final excluded = {
        for (final row in noteRows)
          row['id'] as String: isNoteSearchExcluded(
            _decodeMetadata(row['metadata'] as String?),
          ),
      };
      for (final row in rows) {
        final attachment = Attachment.fromDatabase(row);
        final noteExcluded = excluded[attachment.noteId];
        if (noteExcluded == null) continue;
        work.add((
          Attachment(
            id: attachment.id,
            noteId: attachment.noteId,
            filePath: attachment.filePath,
            fileName: attachment.fileName,
            fileType: attachment.fileType,
            createdAt: attachment.createdAt,
            isRelativePath: attachment.isRelativePath,
            includeInAIContext: attachment.includeInAIContext,
            metadata: {
              'searchIndex': attachment.getSearchIndexConfig().toJson(),
            },
          ),
          noteExcluded,
        ));
      }
    }
    return work;
  }

  Future<void> _removeNoteNow(String noteId) async {
    final db = await _db.database;
    final ftsAvailable = _db.chunksFtsAvailable;
    // Derived crops die with their figure chunks (plan §1.3 purge-on-toggle:
    // excluded/removed content stops existing as derived data too). Collected
    // BEFORE the transaction, deleted after it commits.
    final derivedOwners = await _figureAttachmentIdsForNote(db, noteId);
    await _transactionWithRemovals(db, (txn, removals) async {
      final chunkRows = await txn.query(
        'search_chunks',
        columns: ['id'],
        where: 'noteId = ?',
        whereArgs: [noteId],
      );
      await _deleteChunkRowsById(
        txn,
        [for (final row in chunkRows) row['id'] as int],
        ftsAvailable: ftsAvailable,
        removals: removals,
      );
      await txn.delete(
        'search_index_state',
        where: "scopeType = 'note' AND scopeId = ?",
        whereArgs: [noteId],
      );
      // Attachment-stage states (pdf_text, ocr) of the note's attachments.
      // When the attachments table rows are already gone (cascade), the
      // orphan sweep in _purgeOrphanRows covers them instead.
      await txn.rawDelete(
        "DELETE FROM search_index_state WHERE scopeType = 'attachment' "
        'AND scopeId IN (SELECT id FROM attachments WHERE noteId = ?)',
        [noteId],
      );
    });
    await _deleteDerivedFigures(derivedOwners);
  }

  /// Attachment ids owning `figure` chunks of [noteId] — the derived crops a
  /// purge of the note must delete.
  Future<Set<String>> _figureAttachmentIdsForNote(
    DatabaseExecutor db,
    String noteId,
  ) async {
    final rows = await db.rawQuery(
      "SELECT DISTINCT sourceId FROM search_chunks WHERE noteId = ? "
      "AND sourceType = 'figure' AND sourceId IS NOT NULL",
      [noteId],
    );
    return {for (final row in rows) row['sourceId'] as String};
  }

  /// Purges a policy-excluded note's chunks and marks its chunk stage
  /// 'skipped' — which counts as done for global completeness (a permanent
  /// exclusion must not pin search to the substring fallback forever).
  Future<void> _purgeToSkipped(String noteId) async {
    final db = await _db.database;
    final ftsAvailable = _db.chunksFtsAvailable;
    final derivedOwners = await _figureAttachmentIdsForNote(db, noteId);
    await _transactionWithRemovals(db, (txn, removals) async {
      final chunkRows = await txn.query(
        'search_chunks',
        columns: ['id'],
        where: 'noteId = ?',
        whereArgs: [noteId],
      );
      await _deleteChunkRowsById(
        txn,
        [for (final row in chunkRows) row['id'] as int],
        ftsAvailable: ftsAvailable,
        removals: removals,
      );
      await _writeNoteState(
        txn,
        noteId,
        contentHash: _excludedFingerprint,
        status: statusSkipped,
      );
    });
    await _deleteDerivedFigures(derivedOwners);
  }

  /// Diff-writes [drafts] for one note. All writes in a single transaction.
  ///
  /// With [guardSnapshot], the write is a no-op if the note's stored state
  /// contentHash no longer equals [snapshotStateHash] — i.e. a fresher write
  /// (a debounced reindex whose timer beat the backfill's timer check)
  /// already landed after this batch's snapshot was taken; letting the stale
  /// batch land on the serialized queue would overwrite it.
  Future<void> _writeChunks(
    String noteId,
    List<ChunkDraft> drafts,
    List<String> normalized,
    String fingerprint, {
    bool guardSnapshot = false,
    String? snapshotStateHash,
  }) async {
    assert(drafts.length == normalized.length);
    final db = await _db.database;
    // FTS writes are guarded: on platforms where the FTS4 CREATE failed the
    // chunk rows are still maintained (search degrades to substring).
    final ftsAvailable = _db.chunksFtsAvailable;
    await _transactionWithRemovals(db, (txn, removals) async {
      final liveNotes = await readSyncRowsWhere(
        txn,
        table: 'notes',
        columns: ['metadata'],
        keyColumns: ['id'],
        where: 'id = ? AND __deleted__ = 0',
        whereArgs: [noteId],
      );
      if (liveNotes.isEmpty ||
          isNoteSearchExcluded(
            _decodeMetadata(liveNotes.first['metadata'] as String?),
          )) {
        return;
      }
      if (guardSnapshot) {
        final stateRows = await txn.query(
          'search_index_state',
          columns: ['contentHash'],
          where: "scopeType = 'note' AND scopeId = ? AND stage = ?",
          whereArgs: [noteId, stageChunks],
        );
        final currentHash = stateRows.isEmpty
            ? null
            : stateRows.first['contentHash'] as String?;
        if (currentHash != snapshotStateHash) {
          return; // Stale batch: a fresher write already landed.
        }
      }
      // Scoped to note-derived sourceTypes: attachment_text (and later ocr/
      // figure) chunks share the noteId but belong to their own stages and
      // must not be treated as stale here.
      final existing = await txn.query(
        'search_chunks',
        columns: ['id', 'chunkKey', 'contentHash'],
        where: 'noteId = ? AND sourceType IN $_noteSourceTypesSql',
        whereArgs: [noteId],
      );
      await _diffWriteChunkSet(
        txn,
        existing,
        drafts,
        normalized,
        ftsAvailable: ftsAvailable,
        removals: removals,
      );

      await _writeNoteState(
        txn,
        noteId,
        contentHash: fingerprint,
        status: statusDone,
      );
    });
  }

  /// Diffs [drafts] against [existing] `search_chunks` rows (id / chunkKey /
  /// contentHash) inside [txn]: unchanged chunks stay untouched (row, FTS
  /// entry, and embeddings), changed ones are updated in place with their
  /// embeddings and FTS content invalidated, and leftover [existing] rows
  /// are deleted with their FTS rows and embeddings. Shared by the note
  /// chunk stage and the per-attachment pdf_text stage.
  /// [removals] collects the chunk ids whose vectors this write evicts; the
  /// caller merges them into [_pendingVectorRemovals] after the commit (see
  /// [_transactionWithRemovals]).
  Future<void> _diffWriteChunkSet(
    DatabaseExecutor txn,
    List<Map<String, Object?>> existing,
    List<ChunkDraft> drafts,
    List<String> normalized, {
    required bool ftsAvailable,
    required List<int> removals,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final staleByKey = {
      for (final row in existing) row['chunkKey'] as String: row,
    };
    // A pre-existing library can contain tens of thousands of chunks. Batch
    // writes keep each one from paying several platform-channel round trips,
    // while retaining the surrounding per-note/attachment transaction.
    var batch = txn.batch();
    var pendingChunks = 0;

    for (var i = 0; i < drafts.length; i++) {
      final draft = drafts[i];
      final old = staleByKey.remove(draft.chunkKey);
      if (old != null && old['contentHash'] == draft.contentHash) {
        continue; // Unchanged: row, FTS entry, and embeddings all stay.
      }
      final values = <String, Object?>{
        'chunkKey': draft.chunkKey,
        'noteId': draft.noteId,
        'sourceType': draft.sourceType,
        'sourceId': draft.sourceId,
        'page': draft.page,
        'seq': draft.seq,
        'text': draft.text,
        'meta': draft.meta,
        'contentHash': draft.contentHash,
        'updatedAt': now,
      };
      if (old != null) {
        final chunkId = old['id'] as int;
        batch.update(
          'search_chunks',
          values,
          where: 'id = ?',
          whereArgs: [chunkId],
        );
        // Content changed: stored vectors and FTS content are stale. The
        // vector index drops the row too (a fresh embed pass re-adds it).
        batch.delete(
          'chunk_embeddings',
          where: 'chunkId = ?',
          whereArgs: [chunkId],
        );
        removals.add(chunkId);
        if (ftsAvailable) {
          batch.rawDelete('DELETE FROM chunks_fts WHERE docid = ?', [chunkId]);
          batch.rawInsert(
            'INSERT INTO chunks_fts(docid, content) VALUES(?, ?)',
            [chunkId, normalized[i]],
          );
        }
      } else {
        batch.insert('search_chunks', values);
        if (ftsAvailable) {
          // Resolve the inserted id inside SQLite rather than transferring
          // it to Dart and back. The unique chunkKey makes the mapping
          // explicit, including when other virtual-table inserts run.
          batch.rawInsert(
            'INSERT INTO chunks_fts(docid, content) '
            'SELECT id, ? FROM search_chunks WHERE chunkKey = ?',
            [normalized[i], draft.chunkKey],
          );
        }
      }
      pendingChunks++;
      if (pendingChunks >= 200) {
        await batch.commit(noResult: true);
        batch = txn.batch();
        pendingChunks = 0;
      }
    }
    if (pendingChunks > 0) await batch.commit(noResult: true);

    // Whatever is left in staleByKey no longer exists in the source.
    final staleIds = [for (final row in staleByKey.values) row['id'] as int];
    await _deleteChunkRowsById(
      txn,
      staleIds,
      ftsAvailable: ftsAvailable,
      removals: removals,
    );
  }

  /// Deletes chunk rows (and their FTS rows and embeddings) by id, in
  /// SQLite-variable-limit-safe batches. [removals] collects the ids for the
  /// post-commit vector-index patch (see [_transactionWithRemovals]).
  Future<void> _deleteChunkRowsById(
    DatabaseExecutor txn,
    List<int> chunkIds, {
    required bool ftsAvailable,
    required List<int> removals,
  }) async {
    for (var i = 0; i < chunkIds.length; i += _sqlVarChunk) {
      final chunk = chunkIds.sublist(
        i,
        i + _sqlVarChunk > chunkIds.length ? chunkIds.length : i + _sqlVarChunk,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      if (ftsAvailable) {
        await txn.rawDelete(
          'DELETE FROM chunks_fts WHERE docid IN ($placeholders)',
          chunk,
        );
      }
      await txn.rawDelete(
        'DELETE FROM chunk_embeddings WHERE chunkId IN ($placeholders)',
        chunk,
      );
      // Per-chunk embed error states die with the chunk.
      await txn.rawDelete(
        "DELETE FROM search_index_state WHERE scopeType = 'chunk' "
        'AND scopeId IN ($placeholders)',
        [for (final id in chunk) '$id'],
      );
      await txn.rawDelete(
        'DELETE FROM search_chunks WHERE id IN ($placeholders)',
        chunk,
      );
      removals.addAll(chunk);
    }
  }

  Future<void> _writeNoteState(
    DatabaseExecutor txn,
    String noteId, {
    required String contentHash,
    required String status,
    String? errorMessage,
  }) {
    return txn
        .insert('search_index_state', {
          'scopeType': 'note',
          'scopeId': noteId,
          'stage': stageChunks,
          'contentHash': contentHash,
          'status': status,
          'errorMessage': errorMessage,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace)
        .then((_) {});
  }

  // ── pdf_text stage ───────────────────────────────────────────────────────
  //
  // Stage accounting (deliberate, plan §1.3 / §3): the pdf_text stage is
  // tracked per ATTACHMENT ('attachment', attachmentId, 'pdf_text') with its
  // own global row ('global','all','pdf_text') that CARRIES the stage's policy
  // hash (see _pdfTextPolicyHash / _pdfTextStageComplete — without it a cap
  // change never reaches the per-attachment hashes below). The phase-1
  // 'chunks' global flag — the one that gates the substring fallback — is
  // written before the pdf_text pass runs and never waits on PDF extraction:
  // search layers are independent, and a slow (or failing) PDF must not pin
  // the whole app to substring search.
  //
  // Per-attachment state contentHash is a composite change fingerprint —
  // base "{fileFingerprint}|text={policy}|ex={noteExcluded}" (file size+mtime
  // — see AttachmentTextExtractor.fileFingerprint for why not a partial
  // sha256) plus outcome-dependent components: extracted documents record
  // their page count ("|pages=N"), skipped_too_large ones record the cap
  // they were skipped under ("|cap=C|pages=N"). Any file/policy change
  // re-runs the attachment, while sweeps over unchanged ones cost a stat +
  // one state-row read — and a page-cap change re-runs ONLY the attachments
  // it could affect (see _pdfStateIsCurrent), not every already-done PDF.
  // Skipped and error states are equally stable: an unreadable PDF is not
  // reopened on every sweep, only when the file/policy changes or a forced
  // rebuild runs.

  /// pdf_text pass for one note: prunes chunks of attachments that no longer
  /// exist, then (re)extracts each current PDF attachment as policy permits.
  /// Runs as ONE serialized-queue action; pause() drains it — extraction
  /// aborts between pages via the shouldAbort callback.
  Future<void> _pdfTextForNote(String noteId) async {
    if (_paused) return; // Queued before a pause/dispose: no-op.
    if (await _db.getNote(noteId) == null) {
      // Note removal already purged every chunk (incl. attachment chunks).
      return;
    }
    final attachments = await _db.getAttachmentsForNote(noteId);
    await _pruneStaleAttachmentRows(noteId, attachments);
    final noteExcluded = isNoteSearchExcluded(
      await _db.getNoteMetadata(noteId),
    );
    for (final attachment in attachments) {
      if (_paused) return;
      if (!AttachmentTextExtractor.isPdfAttachment(attachment)) continue;
      await _indexAttachmentPdfText(
        attachment,
        noteExcluded: noteExcluded,
        force: false,
      );
    }
  }

  /// Deletes attachment_text chunks (and pdf_text state rows) whose source
  /// attachment no longer exists on [noteId] — or is no longer a PDF (a
  /// raw-SQL fileName rename away from .pdf leaves derived rows that the
  /// extraction loop, which skips non-PDFs, would never purge).
  Future<void> _pruneStaleAttachmentRows(
    String noteId,
    List<Attachment> attachments,
  ) async {
    final db = await _db.database;
    final currentIds = {
      for (final a in attachments)
        if (AttachmentTextExtractor.isPdfAttachment(a)) a.id,
    };
    final rows = await db.query(
      'search_chunks',
      columns: ['id', 'sourceId'],
      where: "noteId = ? AND sourceType = 'attachment_text'",
      whereArgs: [noteId],
    );
    final staleIds = <int>[];
    final staleSourceIds = <String>{};
    for (final row in rows) {
      final sourceId = row['sourceId'] as String?;
      if (sourceId == null || !currentIds.contains(sourceId)) {
        staleIds.add(row['id'] as int);
        if (sourceId != null) staleSourceIds.add(sourceId);
      }
    }
    if (staleIds.isEmpty && staleSourceIds.isEmpty) return;
    final ftsAvailable = _db.chunksFtsAvailable;
    await _transactionWithRemovals(db, (txn, removals) async {
      await _deleteChunkRowsById(
        txn,
        staleIds,
        ftsAvailable: ftsAvailable,
        removals: removals,
      );
      for (final sourceId in staleSourceIds) {
        await txn.delete(
          'search_index_state',
          where: "scopeType = 'attachment' AND scopeId = ?",
          whereArgs: [sourceId],
        );
      }
    });
  }

  /// Runs the pdf_text stage for one PDF attachment: cheap change detection
  /// (state hash), then extraction and a diff-write, or a purge+skip state.
  /// MUST run on the serialized queue (called from queued actions only).
  Future<void> _indexAttachmentPdfText(
    Attachment attachment, {
    required bool noteExcluded,
    required bool force,
  }) async {
    final db = await _db.database;
    final config = attachment.getSearchIndexConfig();
    final fileHash = await _extractor.fileFingerprint(attachment);
    final cap = await _extractor.effectivePageCap();
    final baseHash = '$fileHash|text=${config.text}|ex=$noteExcluded';

    if (!force) {
      final stateRows = await db.query(
        'search_index_state',
        columns: ['contentHash'],
        where: "scopeType = 'attachment' AND scopeId = ? AND stage = ?",
        whereArgs: [attachment.id, stagePdfText],
      );
      if (stateRows.isNotEmpty &&
          _pdfStateIsCurrent(
            stateRows.first['contentHash'] as String? ?? '',
            baseHash,
            cap,
            capBypassed: config.textExplicitlyOn,
          )) {
        return; // File, policy, and effective cap unchanged — nothing to do.
      }
    }

    final result = await _extractor.extractPdfText(
      attachment,
      noteExcluded: noteExcluded,
      shouldAbort: () => _paused,
    );
    switch (result.status) {
      case ExtractionStatus.aborted:
        // Paused mid-file: write nothing; the resume sweep re-runs.
        return;
      case ExtractionStatus.extracted:
        final normalized = [
          for (final d in result.drafts) normalizeForIndex(d.text),
        ];
        await _writeAttachmentChunks(
          attachment,
          result.drafts,
          normalized,
          _pdfStateHash(baseHash, pageCount: result.pageCount),
          sourceType: 'attachment_text',
          stage: stagePdfText,
        );
      case ExtractionStatus.skippedNotPdf:
      case ExtractionStatus.skippedPolicyOff:
      case ExtractionStatus.skippedNoteExcluded:
        // Cap-independent skips: base hash only.
        await _purgeAttachmentToState(
          attachment,
          status: statusSkipped,
          stateHash: baseHash,
          sourceType: 'attachment_text',
          stage: stagePdfText,
        );
      case ExtractionStatus.skippedTooLarge:
        await _purgeAttachmentToState(
          attachment,
          status: statusSkippedTooLarge,
          stateHash: _pdfStateHash(
            baseHash,
            cap: cap,
            pageCount: result.pageCount,
          ),
          sourceType: 'attachment_text',
          stage: stagePdfText,
        );
      case ExtractionStatus.failed:
        // Keep any existing (stale) chunks — better than nothing — but
        // record the failure. The matching stateHash keeps sweeps from
        // retrying a broken file until it (or policy) changes.
        LoggerService.error(
          '[NoteIndex] pdf_text extraction failed for '
          '${attachment.fileName}: ${result.errorMessage}',
        );
        await db.insert('search_index_state', {
          'scopeType': 'attachment',
          'scopeId': attachment.id,
          'stage': stagePdfText,
          'contentHash': baseHash,
          'status': statusError,
          'errorMessage': result.errorMessage,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Builds a stored pdf_text state hash: `{base}[|cap=C][|pages=N]`, where
  /// base is `{fileFingerprint}|text={policy}|ex={noteExcluded}`. `pages=` is
  /// recorded whenever the document was opened; `cap=` ONLY for
  /// skipped_too_large states — see [_pdfStateIsCurrent] for the matching
  /// rules this encodes.
  static String _pdfStateHash(String base, {int? cap, int? pageCount}) {
    final buffer = StringBuffer(base);
    if (cap != null) buffer.write('|cap=$cap');
    if (pageCount != null) buffer.write('|pages=$pageCount');
    return buffer.toString();
  }

  /// Whether a [stored] pdf_text state hash is still current for [base]
  /// (file fingerprint + text policy + note exclusion) under page cap [cap].
  ///
  /// The cap participates only where a cap change could change the outcome,
  /// so raising (or lowering) the cap does not re-extract every already-done
  /// PDF:
  /// - skipped_too_large states carry `cap=C`: ANY cap change re-runs them
  ///   (a raised cap may now admit the document; a lowered one re-skips
  ///   cheaply, refreshing the recorded cap) — and so does [capBypassed]: a
  ///   stored too-large skip can never be current once `text: 'on'` lifts
  ///   the cap for this attachment.
  /// - extracted states carry `pages=N` and no `cap=`: they re-run only when
  ///   N exceeds the new cap and the attachment is not explicitly opted in
  ///   ([capBypassed] — `text: 'on'` bypasses the cap entirely). A 2-page
  ///   PDF is thus never re-extracted by a cap change.
  /// - other skip/error states equal [base]: cap-independent.
  /// - anything unrecognized (legacy format) mismatches and re-runs once.
  static bool _pdfStateIsCurrent(
    String stored,
    String base,
    int cap, {
    required bool capBypassed,
  }) {
    if (stored == base) return true;
    if (!stored.startsWith('$base|')) return false;
    int? storedCap;
    int? pages;
    for (final part in stored.substring(base.length + 1).split('|')) {
      if (part.startsWith('cap=')) {
        storedCap = int.tryParse(part.substring(4));
      } else if (part.startsWith('pages=')) {
        pages = int.tryParse(part.substring(6));
      } else {
        return false; // Unknown component (format change): re-run.
      }
    }
    if (storedCap != null) return !capBypassed && storedCap == cap;
    if (pages != null) return capBypassed || pages <= cap;
    return false;
  }

  /// Diff-writes one attachment's derived chunks ([sourceType] =
  /// 'attachment_text' or 'attachment_ocr') and its [stage] state row in a
  /// single transaction. Shared by the pdf_text and ocr stages.
  Future<void> _writeAttachmentChunks(
    Attachment attachment,
    List<ChunkDraft> drafts,
    List<String> normalized,
    String stateHash, {
    required String sourceType,
    required String stage,
  }) async {
    final db = await _db.database;
    final ftsAvailable = _db.chunksFtsAvailable;
    await _transactionWithRemovals(db, (txn, removals) async {
      final existing = await txn.query(
        'search_chunks',
        columns: ['id', 'chunkKey', 'contentHash'],
        where: 'noteId = ? AND sourceType = ? AND sourceId = ?',
        whereArgs: [attachment.noteId, sourceType, attachment.id],
      );
      await _diffWriteChunkSet(
        txn,
        existing,
        drafts,
        normalized,
        ftsAvailable: ftsAvailable,
        removals: removals,
      );
      await _writeAttachmentState(
        txn,
        attachment.id,
        stage: stage,
        contentHash: stateHash,
        status: statusDone,
      );
    });
  }

  /// Deletes an attachment's [sourceType] chunks and records a skip state
  /// for [stage] (purge-on-policy, plan §1.3) in a single transaction.
  ///
  /// [deleteDerivedAssets] additionally removes the attachment's derived
  /// figure crops from `attachments/derived/` once the transaction commits —
  /// the figures stage's purge must also stop the OFF-DEVICE-DERIVED data
  /// from existing, not just its chunks (plan §1.3).
  Future<void> _purgeAttachmentToState(
    Attachment attachment, {
    required String status,
    required String stateHash,
    required String sourceType,
    required String stage,
    bool deleteDerivedAssets = false,
  }) async {
    final db = await _db.database;
    final ftsAvailable = _db.chunksFtsAvailable;
    await _transactionWithRemovals(db, (txn, removals) async {
      final rows = await txn.query(
        'search_chunks',
        columns: ['id'],
        where: 'noteId = ? AND sourceType = ? AND sourceId = ?',
        whereArgs: [attachment.noteId, sourceType, attachment.id],
      );
      await _deleteChunkRowsById(
        txn,
        [for (final row in rows) row['id'] as int],
        ftsAvailable: ftsAvailable,
        removals: removals,
      );
      await _writeAttachmentState(
        txn,
        attachment.id,
        stage: stage,
        contentHash: stateHash,
        status: status,
      );
    });
    if (deleteDerivedAssets) {
      await _deleteDerivedFigures({attachment.id});
    }
  }

  /// Owner id of a derived crop name (`<attachmentId>_p<page>_f<index>.png`,
  /// minted by [FigureRegionExtractor.derivedFigureFileName]). Greedy on the
  /// id because the `_p…_f….png` suffix is always appended last, so the LAST
  /// match is the real boundary even for an id that itself contains `_p1_f0`.
  static final RegExp _derivedFigureOwnerRe = RegExp(r'^(.+)_p\d+_f\d+\.png$');

  /// Deletes every `attachments/derived/<attachmentId>_p*_f*.png` belonging to
  /// [attachmentIds]. Best effort: derived crops are regenerable, so a failure
  /// here must never fail an index write.
  Future<void> _deleteDerivedFigures(Set<String> attachmentIds) async {
    if (attachmentIds.isEmpty) return;
    try {
      final dir = await _derivedFigureDirLoader();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        // Match the FULL derived-asset name and take the owner id from it,
        // rather than testing an `<id>_p` prefix: a prefix test deletes
        // attachment `abc`'s crops when purging attachment `ab`, whose id is
        // a prefix of it and whose own crops are named `ab_p1_f0.png`
        // (`FigureRegionExtractor.derivedFigureFileName`). Ids are opaque
        // strings, so nothing rules that out.
        final owner = _derivedFigureOwnerRe.firstMatch(name)?.group(1);
        if (owner == null || !attachmentIds.contains(owner)) continue;
        try {
          await entity.delete();
        } catch (e) {
          LoggerService.warning(
            '[NoteIndex] Could not delete derived figure ${entity.path}: $e',
          );
        }
      }
    } catch (e) {
      LoggerService.warning('[NoteIndex] Derived figure purge failed: $e');
    }
  }

  Future<void> _writeAttachmentState(
    DatabaseExecutor txn,
    String attachmentId, {
    required String stage,
    required String contentHash,
    required String status,
    String? errorMessage,
  }) {
    return txn
        .insert('search_index_state', {
          'scopeType': 'attachment',
          'scopeId': attachmentId,
          'stage': stage,
          'contentHash': contentHash,
          'status': status,
          'errorMessage': errorMessage,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace)
        .then((_) {});
  }

  // ── ocr stage ────────────────────────────────────────────────────────────
  //
  // OCR is a PRIMARY layer (plan §3): default on, over all pages of
  // policy-permitted PDFs and raster images. Accounting mirrors pdf_text —
  // per-attachment ('attachment', attachmentId, 'ocr') rows plus a
  // ('global','all','ocr') row, none of which ever gate the 'chunks' flag.
  //
  // Per-attachment state contentHash: base "{fileFingerprint}|gocr={bool}
  // |ocr={bool}|text={policy}|ex={noteExcluded}|script={latin|chinese}" —
  // `gocr` is the GLOBAL ocr switch and `ocr` the per-attachment flag (either
  // one off purges the attachment's chunks and records a skip, and either
  // flip re-runs the stage), the script is
  // part of the hash so switching the recognizer re-runs OCR, and the TEXT
  // policy is too: the merge policy suppresses OCR blocks against the
  // attachment_text layer, so flipping text on/off changes what OCR should
  // have produced (text:'off' purges the text layer — without a re-run the
  // suppressed text would be in NEITHER layer), and text:'on' also lifts the
  // shared page cap for OCR. Plus the same outcome components as pdf_text
  // via _pdfStateHash:
  // extracted → "|pages=N", skipped_too_large → "|cap=C|pages=N". The page
  // cap is shared with pdf_text (OCRing an over-cap PDF costs even more than
  // text-extracting it); text:'on' bypasses it for OCR too, and raster
  // images (pages=1) can never hit it.
  //
  // Battery deferrals (low battery, unplugged) write NO state row at all —
  // unlike skips they are transient, and the absent row makes the next
  // sweep (e.g. once charging) retry without any special-casing.

  /// Outcome of one queued [_indexAttachmentOcr] run.
  static const int _ocrOutcomeDone = 0;
  static const int _ocrOutcomeAborted = 1;
  static const int _ocrOutcomeDeferred = 2;

  /// ocr pass for one note: prunes chunks of attachments that no longer
  /// exist (or are no longer OCR-eligible), then (re)runs each current
  /// PDF/raster attachment as policy permits. Runs as ONE serialized-queue
  /// action, queued AFTER the note's pdf_text action so the merge policy
  /// sees fresh attachment_text chunks.
  Future<void> _ocrForNote(String noteId) async {
    if (_paused) return;
    if (await _db.getNote(noteId) == null) return;
    final attachments = await _db.getAttachmentsForNote(noteId);
    await _pruneStaleOcrRows(noteId, attachments);
    final noteExcluded = isNoteSearchExcluded(
      await _db.getNoteMetadata(noteId),
    );
    for (final attachment in attachments) {
      if (_paused) return;
      if (!AttachmentOcrExtractor.isOcrEligible(attachment)) continue;
      final outcome = await _indexAttachmentOcr(
        attachment,
        noteExcluded: noteExcluded,
        force: false,
      );
      if (outcome == _ocrOutcomeAborted) return;
      if (outcome == _ocrOutcomeDeferred) {
        // Battery state is global: the remaining attachments would defer
        // too. Stop; the next sweep retries them all.
        return;
      }
    }
  }

  /// Deletes attachment_ocr chunks (and ocr state rows) whose source
  /// attachment no longer exists on [noteId] or is no longer OCR-eligible
  /// (raw-SQL rename to e.g. .svg leaves derived rows the extraction loop
  /// would never purge).
  Future<void> _pruneStaleOcrRows(
    String noteId,
    List<Attachment> attachments,
  ) async {
    final db = await _db.database;
    final currentIds = {
      for (final a in attachments)
        if (AttachmentOcrExtractor.isOcrEligible(a)) a.id,
    };
    final rows = await db.query(
      'search_chunks',
      columns: ['id', 'sourceId'],
      where: "noteId = ? AND sourceType = 'attachment_ocr'",
      whereArgs: [noteId],
    );
    final staleIds = <int>[];
    final staleSourceIds = <String>{};
    for (final row in rows) {
      final sourceId = row['sourceId'] as String?;
      if (sourceId == null || !currentIds.contains(sourceId)) {
        staleIds.add(row['id'] as int);
        if (sourceId != null) staleSourceIds.add(sourceId);
      }
    }
    if (staleIds.isEmpty && staleSourceIds.isEmpty) return;
    final ftsAvailable = _db.chunksFtsAvailable;
    await _transactionWithRemovals(db, (txn, removals) async {
      await _deleteChunkRowsById(
        txn,
        staleIds,
        ftsAvailable: ftsAvailable,
        removals: removals,
      );
      for (final sourceId in staleSourceIds) {
        await txn.delete(
          'search_index_state',
          where: "scopeType = 'attachment' AND scopeId = ? AND stage = ?",
          whereArgs: [sourceId, stageOcr],
        );
      }
    });
  }

  /// Base component of the ocr state hash (see the stage comment).
  Future<String> _ocrBaseHash(Attachment attachment, bool noteExcluded) async {
    final config = attachment.getSearchIndexConfig();
    final fileHash = await _ocrExtractor.fileFingerprint(attachment);
    final script = (await _ocrExtractor.effectiveScript()).name;
    // The GLOBAL ocr switch is part of the hash exactly like the
    // per-attachment flag: without it a `skipped` row written while OCR was
    // off would still match after the user turns it back on, so
    // _ocrStateIsCurrent would report "current" and those attachments would
    // never be re-OCRed short of a forced rebuild.
    final globalOcr = await _ocrExtractor.ocrEnabled();
    return '$fileHash|gocr=$globalOcr|ocr=${config.ocr}|text=${config.text}'
        '|ex=$noteExcluded|script=$script';
  }

  /// Whether the stored ocr state for [attachment] is still current (file,
  /// policy, script, and — where it could bind — the page cap unchanged).
  Future<bool> _ocrStateIsCurrent(
    Attachment attachment, {
    required bool noteExcluded,
  }) async {
    final db = await _db.database;
    final stateRows = await db.query(
      'search_index_state',
      columns: ['contentHash'],
      where: "scopeType = 'attachment' AND scopeId = ? AND stage = ?",
      whereArgs: [attachment.id, stageOcr],
    );
    if (stateRows.isEmpty) return false;
    final base = await _ocrBaseHash(attachment, noteExcluded);
    final cap = await _ocrExtractor.effectivePageCap();
    return _pdfStateIsCurrent(
      stateRows.first['contentHash'] as String? ?? '',
      base,
      cap,
      capBypassed:
          attachment.getSearchIndexConfig().textExplicitlyOn ||
          !AttachmentTextExtractor.isPdfAttachment(attachment),
    );
  }

  /// Runs the ocr stage for one eligible attachment: cheap change detection
  /// (state hash), then OCR and a diff-write, or a purge+skip state.
  /// MUST run on the serialized queue (called from queued actions only).
  /// Returns one of the _ocrOutcome* constants.
  Future<int> _indexAttachmentOcr(
    Attachment attachment, {
    required bool noteExcluded,
    required bool force,
    void Function(int done, int total)? onPageProgress,
  }) async {
    final db = await _db.database;
    final baseHash = await _ocrBaseHash(attachment, noteExcluded);
    final cap = await _ocrExtractor.effectivePageCap();

    if (!force &&
        await _ocrStateIsCurrent(attachment, noteExcluded: noteExcluded)) {
      return _ocrOutcomeDone; // Nothing to do.
    }

    final result = await _ocrExtractor.extractOcr(
      attachment,
      noteExcluded: noteExcluded,
      shouldAbort: () => _paused,
      onPageProgress: onPageProgress,
    );
    switch (result.status) {
      case OcrExtractionStatus.aborted:
        // Paused mid-file: write nothing; the resume sweep re-runs.
        return _ocrOutcomeAborted;
      case OcrExtractionStatus.deferredBattery:
        // Transient: no state row, so the next sweep retries (see the stage
        // comment). Must also keep the global ocr flag unset this round.
        return _ocrOutcomeDeferred;
      case OcrExtractionStatus.extracted:
        final normalized = [
          for (final d in result.drafts) normalizeForIndex(d.text),
        ];
        await _writeAttachmentChunks(
          attachment,
          result.drafts,
          normalized,
          _pdfStateHash(baseHash, pageCount: result.pageCount),
          sourceType: 'attachment_ocr',
          stage: stageOcr,
        );
        return _ocrOutcomeDone;
      case OcrExtractionStatus.skippedNotEligible:
      case OcrExtractionStatus.skippedPolicyOff:
      case OcrExtractionStatus.skippedNoteExcluded:
        await _purgeAttachmentToState(
          attachment,
          status: statusSkipped,
          stateHash: baseHash,
          sourceType: 'attachment_ocr',
          stage: stageOcr,
        );
        return _ocrOutcomeDone;
      case OcrExtractionStatus.skippedTooLarge:
        await _purgeAttachmentToState(
          attachment,
          status: statusSkippedTooLarge,
          stateHash: _pdfStateHash(
            baseHash,
            cap: cap,
            pageCount: result.pageCount,
          ),
          sourceType: 'attachment_ocr',
          stage: stageOcr,
        );
        return _ocrOutcomeDone;
      case OcrExtractionStatus.failed:
        // Keep any existing (stale) chunks — better than nothing — but
        // record the failure; the matching stateHash keeps sweeps from
        // retrying a broken file until it (or policy) changes.
        LoggerService.error(
          '[NoteIndex] ocr extraction failed for '
          '${attachment.fileName}: ${result.errorMessage}',
        );
        await db.insert('search_index_state', {
          'scopeType': 'attachment',
          'scopeId': attachment.id,
          'stage': stageOcr,
          'contentHash': baseHash,
          'status': statusError,
          'errorMessage': result.errorMessage,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return _ocrOutcomeDone;
    }
  }

  /// Resumable ocr pass over every OCR-eligible attachment. Progress is
  /// page-based ("Recognizing text in PDFs — X/Y pages"): totals are the
  /// summed page counts of the attachments that actually need work (cheap
  /// doc-info opens, cached; skip-bound attachments count 1). Sets
  /// ('global','all','ocr') = done when every attachment reached a terminal
  /// state — skipped and recorded-error states count as done (mirroring
  /// pdf_text), battery deferrals do NOT (the flag stays unset so
  /// ensureBackfilled retries once conditions improve). A deferral also ends
  /// the pass immediately — battery state is global, so every remaining
  /// attachment would defer too. Returns (done,total) page counts, or null
  /// when it bailed out early (paused).
  Future<({int done, int total})?> _runOcrBackfill(
    Database db, {
    required bool force,
  }) async {
    // Up-front battery gate: on low battery the whole pass defers before any
    // doc-info opens (the per-attachment extractor gate still re-checks, in
    // case battery drains mid-pass). The global flag stays unset, so
    // ensureBackfilled retries once conditions improve.
    //
    // Skipped entirely when the global OCR switch is OFF: this pass then only
    // purges chunks and records skip states (no rendering, no recognition),
    // which must not wait for a charger — the user turned OCR off and expects
    // the recognized text to leave the index now.
    final globalOcr = await _ocrExtractor.ocrEnabled();
    if (globalOcr && !await _ocrExtractor.batteryAllowsOcr()) {
      return (done: 0, total: 0);
    }
    // Captured BEFORE the pass, written after it: a settings change landing
    // mid-pass must leave a hash that no longer matches, so the next sweep
    // re-evaluates the attachments this one processed under the old policy.
    final policyHash = await _ocrPolicyHash();
    final work = await loadIndexAttachments(
      db,
      eligibleFileNameSql: _ocrEligibleFileNameSql,
    );
    final pending = <(Attachment, bool)>[];
    final pageTotals = <String, int>{};
    var totalPages = 0;
    for (final (attachment, noteExcluded) in work) {
      if (_paused) return null;
      if (!force &&
          await _ocrStateIsCurrent(attachment, noteExcluded: noteExcluded)) {
        continue;
      }
      pending.add((attachment, noteExcluded));
      // Page total: only attachments that will actually OCR pages need a
      // real count; skip-bound ones settle with one state write (1 "page").
      // That includes over-cap PDFs without the text:'on' opt-in — they
      // settle skipped_too_large, so a 500-page clipped PDF must count 1,
      // not inflate the total by pages that will never be recognized.
      final config = attachment.getSearchIndexConfig();
      var pages = 1;
      if (globalOcr && config.ocr && !noteExcluded) {
        pages = await _ocrExtractor.getOcrPageCount(attachment) ?? 1;
        if (AttachmentTextExtractor.isPdfAttachment(attachment) &&
            !config.textExplicitlyOn &&
            pages > await _ocrExtractor.effectivePageCap()) {
          pages = 1;
        }
      }
      pageTotals[attachment.id] = pages;
      totalPages += pages;
    }

    var donePages = 0;
    var failed = 0;
    var deferred = false;
    if (pending.isNotEmpty) {
      _progress.value = IndexProgress(
        done: 0,
        total: totalPages,
        stage: stageOcr,
        unit: 'pages',
        running: true,
      );
    }

    for (final (attachment, noteExcluded) in pending) {
      if (_paused) return null;
      final basePages = donePages;
      final attachmentPages = pageTotals[attachment.id] ?? 1;
      try {
        final outcome = await _serialized(
          () => _indexAttachmentOcr(
            attachment,
            noteExcluded: noteExcluded,
            force: force,
            onPageProgress: (done, total) {
              donePages = basePages + done;
              _progress.value = IndexProgress(
                done: donePages,
                total: totalPages,
                stage: stageOcr,
                unit: 'pages',
                running: true,
              );
            },
          ),
        );
        if (outcome == _ocrOutcomeAborted) return null;
        if (outcome == _ocrOutcomeDeferred) {
          // Battery state is global: the remaining attachments would defer
          // too (mirror _ocrForNote). Roll this attachment's partial page
          // progress back — its output was discarded, so the bar must not
          // report pages nobody recognized — and stop; the global flag
          // stays unset below, so the next sweep retries them all.
          deferred = true;
          donePages = basePages;
          break;
        }
        donePages = basePages + attachmentPages;
      } catch (e) {
        failed++;
        donePages = basePages + attachmentPages;
        LoggerService.error(
          '[NoteIndex] ocr backfill failed for ${attachment.id}: $e',
          error: e,
        );
      }
      _progress.value = IndexProgress(
        done: donePages,
        total: totalPages,
        stage: stageOcr,
        unit: 'pages',
        running: true,
      );
    }

    if (!_paused && failed == 0 && !deferred) {
      await db.insert('search_index_state', {
        'scopeType': 'global',
        'scopeId': 'all',
        'stage': stageOcr,
        // Unlike the other global rows this one CARRIES a hash: the OCR
        // settings as of this completed pass (see [_ocrStageComplete]).
        'contentHash': policyHash,
        'status': statusDone,
        'errorMessage': null,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return (done: donePages, total: totalPages);
  }

  // ── figures stage ────────────────────────────────────────────────────────
  //
  // Plan §4.1: precise figure/table CROPS, never page thumbnails. For every
  // policy-permitted PDF attachment FigureRegionExtractor infers regions and
  // renders them to `attachments/derived/`; each region becomes one `figure`
  // chunk. Raster image attachments (png/jpg/jpeg/webp) get one figure chunk
  // each with no extraction (the file itself is the image), and SVG is
  // LEXICAL-ONLY (filename + alt text): Image.file cannot render it, ML Kit
  // cannot OCR it, and Gemini image input rejects image/svg+xml.
  //
  // THE CHUNK IS THE FIGURE'S IDENTITY. ChunkDraft hashes `text` + `meta`, so
  // the row's contentHash — the half of `figureId = <chunkKey>~<hash12>` that
  // FigureResolver verifies — is a REGION-IDENTITY hash exactly because
  // `meta` holds the region and nothing volatile:
  //     page, rect{l,t,r,b}, caption?, confidence, source  (FigureRegion.toJson)
  //     derivedAssetPath   'attachments/derived/<attId>_p<N>_f<i>.png'
  //     figureIndex        MANDATORY — the resolver refuses to GUESS it
  //                        (a wrong index makes renderRegion overwrite a
  //                        sibling region's asset), so an absent one costs
  //                        the figure its image.
  // The rendered PNG's sha256 (DerivedFigure.contentHash) is deliberately NOT
  // written: PNG bytes are renderer-dependent, so a pdfium bump would change
  // every figureId and dangle every figure URI already embedded in a note or
  // a chat message. The `page` COLUMN equals `meta.page` for the same class of
  // reason — a divergence makes the resolver probe one asset path while
  // renderRegion writes another, re-rasterizing the PDF on every render.
  //
  // Accounting mirrors pdf_text/ocr: per-attachment ('attachment', id,
  // 'figures') rows plus a ('global','all','figures') row that CARRIES the
  // policy hash (see [_figuresPolicyHash]). Neither ever gates the phase-1
  // 'chunks' flag — layers are independent.
  //
  // Per-attachment state contentHash base:
  //   "{fileFingerprint}|gfig={bool}|gocr={bool}|ocr={bool}|text={policy}
  //    |ex={noteExcluded}|script={latin|chinese}|alt={digest}|ocrst={state}"
  // plus the same outcome components as pdf_text via _pdfStateHash
  // (extracted → "|pages=N", skipped_too_large → "|cap=C|pages=N").
  //  * `gfig` is the global switch and `ocr` the PER-ATTACHMENT gate: the
  //    figures stage rides the attachment's on-device-derivation flag
  //    (`metadata.searchIndex.ocr`), the only per-item knob for "derive
  //    content from this file locally". Either flip purges/re-extracts.
  //  * `gocr` + `script` because OCR block bounds are a first-class
  //    caption-anchor source — changing them changes which regions exist.
  //  * `text` because `text:'on'` lifts the shared page cap for this
  //    attachment (same bypass rule as the ocr stage).
  //  * `alt` is a digest of the note's markdown alt text FOR THIS ATTACHMENT,
  //    which is part of every figure chunk's text. Editing unrelated note
  //    prose leaves it identical, so ordinary edits never re-render.
  //  * `ocrst` is the ocr stage's OUTCOME for this attachment (see
  //    [_ocrStateComponent]) — not just its settings. The settings say what
  //    OCR was ASKED to do; only the state row says whether OCR data actually
  //    EXISTS. Without it a figures pass that ran while OCR had DEFERRED (low
  //    battery, unplugged: extractOcr bails writing no state row, but nothing
  //    stops the figures pass) sees an empty _loadOcrItemsByPage, finds ZERO
  //    caption anchors in a scanned image-only PDF, and freezes that as
  //    "figures = done, none" — every other component is unchanged once
  //    charging, so the document is never reopened and a scanned document has
  //    no figures permanently. The same hole swallowed OCR text for raster
  //    figure chunks (_loadAttachmentOcrText) and re-runs after an ocr `error`
  //    state is later cleared.

  static const int _figuresOutcomeDone = 0;
  static const int _figuresOutcomeAborted = 1;

  /// State hash matched: nothing was opened, rendered or written. Tracked
  /// separately from [_figuresOutcomeDone] so an all-current sweep publishes
  /// NO figures progress (and does not claim the final progress stage from
  /// the pass that actually did work).
  static const int _figuresOutcomeUpToDate = 2;

  /// Whether the figures stage applies to [attachment] at all: PDFs (region
  /// extraction), raster images, and SVG (lexical-only chunk).
  static bool isFigureEligible(Attachment attachment) =>
      AttachmentTextExtractor.isPdfAttachment(attachment) ||
      AttachmentOcrExtractor.isRasterImageAttachment(attachment) ||
      isSvgAttachment(attachment);

  /// Shared by [isSvgAttachment] and [_figureEligibleFileNameSql] so the Dart
  /// predicate and its SQL twin cannot disagree.
  static const String _svgExtension = '.svg';

  /// SVG attachments: a `figure` chunk is written for lexical findability
  /// (filename + alt text) but nothing is rendered, OCRed, or embedded as an
  /// image (plan §4.1).
  static bool isSvgAttachment(Attachment attachment) =>
      attachment.fileName.toLowerCase().endsWith(_svgExtension);

  /// figures pass for one note: prunes chunks of attachments that no longer
  /// exist (or are no longer figure-eligible), then (re)runs each current
  /// attachment as policy permits. Runs as ONE serialized-queue action,
  /// queued AFTER the note's ocr action so region inference sees fresh
  /// `attachment_ocr` bounds.
  Future<void> _figuresForNote(String noteId) async {
    if (_paused) return;
    final noteContent = await _loadNoteContent(noteId);
    if (noteContent == null) return; // Note gone: removal purged everything.
    final attachments = await _db.getAttachmentsForNote(noteId);
    await _pruneStaleFigureRows(noteId, attachments);
    final noteExcluded = isNoteSearchExcluded(
      await _db.getNoteMetadata(noteId),
    );
    for (final attachment in attachments) {
      if (_paused) return;
      if (!isFigureEligible(attachment)) continue;
      final outcome = await _indexAttachmentFigures(
        attachment,
        noteExcluded: noteExcluded,
        noteContent: noteContent,
        force: false,
      );
      if (outcome == _figuresOutcomeAborted) return;
    }
  }

  /// Raw note content (the markdown the alt-text digest is derived from).
  /// Null when the note no longer exists. Read directly instead of via
  /// [DatabaseService.getNote] so a sweep does not also materialize subnotes,
  /// tags and annotations it has no use for.
  Future<String?> _loadNoteContent(String noteId) async {
    final db = await _db.database;
    final rows = await readSyncRowsWhere(
      db,
      table: 'notes',
      columns: ['content'],
      keyColumns: ['id'],
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [noteId],
    );
    if (rows.isEmpty) return null;
    return (rows.first['content'] as String?) ?? '';
  }

  /// Deletes `figure` chunks (and figures state rows + derived crops) whose
  /// source attachment no longer exists on [noteId] or is no longer
  /// figure-eligible.
  Future<void> _pruneStaleFigureRows(
    String noteId,
    List<Attachment> attachments,
  ) async {
    final db = await _db.database;
    final currentIds = {
      for (final a in attachments)
        if (isFigureEligible(a)) a.id,
    };
    final rows = await db.query(
      'search_chunks',
      columns: ['id', 'sourceId'],
      where: "noteId = ? AND sourceType = 'figure'",
      whereArgs: [noteId],
    );
    final staleIds = <int>[];
    final staleSourceIds = <String>{};
    for (final row in rows) {
      final sourceId = row['sourceId'] as String?;
      if (sourceId == null || !currentIds.contains(sourceId)) {
        staleIds.add(row['id'] as int);
        if (sourceId != null) staleSourceIds.add(sourceId);
      }
    }
    if (staleIds.isEmpty && staleSourceIds.isEmpty) return;
    final ftsAvailable = _db.chunksFtsAvailable;
    await _transactionWithRemovals(db, (txn, removals) async {
      await _deleteChunkRowsById(
        txn,
        staleIds,
        ftsAvailable: ftsAvailable,
        removals: removals,
      );
      for (final sourceId in staleSourceIds) {
        await txn.delete(
          'search_index_state',
          where: "scopeType = 'attachment' AND scopeId = ? AND stage = ?",
          whereArgs: [sourceId, stageFigures],
        );
      }
    });
    await _deleteDerivedFigures(staleSourceIds);
  }

  /// Base component of the figures state hash (see the stage comment).
  Future<String> _figuresBaseHash(
    Attachment attachment,
    bool noteExcluded,
    String altText,
  ) async {
    final config = attachment.getSearchIndexConfig();
    final fileHash = await _extractor.fileFingerprint(attachment);
    final figures = await _figuresEnabled();
    final globalOcr = await _ocrExtractor.ocrEnabled();
    final script = (await _ocrExtractor.effectiveScript()).name;
    final altDigest = sha256
        .convert(utf8.encode(altText))
        .toString()
        .substring(0, 12);
    final ocrState = await _ocrStateComponent(attachment);
    return '$fileHash|gfig=$figures|gocr=$globalOcr|ocr=${config.ocr}'
        '|text=${config.text}|ex=$noteExcluded|script=$script|alt=$altDigest'
        '|ocrst=$ocrState';
  }

  /// The ocr stage's recorded OUTCOME for [attachment], as a hash component:
  /// `none` while no ('attachment', id, 'ocr') row exists — which is exactly
  /// the battery-deferred state, since [AttachmentOcrExtractor.extractOcr]
  /// deliberately writes nothing when it defers — and `{status}:{digest}`
  /// once one does.
  ///
  /// The digest covers the whole stored ocr contentHash, so it also moves
  /// when OCR re-runs for a reason the figures hash does not carry itself
  /// (a raised page cap re-admitting a `skipped_too_large` PDF, an `error`
  /// state replaced by a successful extraction). The figures stage never
  /// races it: the figures action is queued AFTER the note's ocr action on
  /// the same serialized queue, and [_runFiguresBackfill] runs after
  /// [_runOcrBackfill].
  Future<String> _ocrStateComponent(Attachment attachment) async {
    final db = await _db.database;
    final rows = await db.query(
      'search_index_state',
      columns: ['status', 'contentHash'],
      where: "scopeType = 'attachment' AND scopeId = ? AND stage = ?",
      whereArgs: [attachment.id, stageOcr],
      limit: 1,
    );
    if (rows.isEmpty) return 'none';
    final status = rows.first['status'] as String? ?? '';
    final stored = rows.first['contentHash'] as String? ?? '';
    final digest = sha256
        .convert(utf8.encode(stored))
        .toString()
        .substring(0, 12);
    return '$status:$digest';
  }

  /// Runs the figures stage for one eligible attachment: cheap change
  /// detection (state hash), then extraction and a diff-write, or a
  /// purge+skip state. MUST run on the serialized queue.
  Future<int> _indexAttachmentFigures(
    Attachment attachment, {
    required bool noteExcluded,
    required String noteContent,
    required bool force,
  }) async {
    final db = await _db.database;
    final config = attachment.getSearchIndexConfig();
    final altText = markdownAltTextFor(attachment, noteContent);
    final baseHash = await _figuresBaseHash(attachment, noteExcluded, altText);
    final cap = await _effectivePageCap();
    final isPdf = AttachmentTextExtractor.isPdfAttachment(attachment);
    // Only PDFs can hit the page cap; `text:'on'` lifts it for this
    // attachment exactly as it does for pdf_text/ocr.
    final capBypassed = config.textExplicitlyOn || !isPdf;

    if (!force) {
      final stateRows = await db.query(
        'search_index_state',
        columns: ['contentHash'],
        where: "scopeType = 'attachment' AND scopeId = ? AND stage = ?",
        whereArgs: [attachment.id, stageFigures],
      );
      if (stateRows.isNotEmpty &&
          _pdfStateIsCurrent(
            stateRows.first['contentHash'] as String? ?? '',
            baseHash,
            cap,
            capBypassed: capBypassed,
          )) {
        return _figuresOutcomeUpToDate;
      }
    }

    // Policy gates (plan §1.3): global switch, per-attachment flag, note
    // exclusion. Purge-on-toggle — chunks AND derived crops go now.
    //
    // NOTE the deliberate asymmetry between the two OCR knobs, because they
    // are NOT the same question:
    //  * The GLOBAL ocr switch (`gocr`, folded into baseHash above) only
    //    removes OCR block bounds as a caption-anchor source. Figures still
    //    extract from the PDF's own text layer — turning text recognition off
    //    is not a statement about figures.
    //  * The PER-ATTACHMENT `ocr` flag (`metadata.searchIndex.ocr`) is this
    //    file's on-device-derivation consent — the only per-item knob for
    //    "derive content from this file locally", and rendering a crop of it
    //    to `attachments/derived/` is exactly that. So `ocr:false` PURGES the
    //    attachment's figure chunks and its crops, and this is intended: an
    //    opt-out that left derived images of the file on disk would not be an
    //    opt-out. The Step-21 dialog therefore labels the flag "extract
    //    content on this device", not "OCR this file", or the crop purge
    //    would read as a bug.
    //
    // SVG is exempt from the per-attachment flag (only from that one — the
    // global switch and the note exclusion still purge it): its chunk is the
    // FILE NAME plus the note's own alt text, and the file itself is never
    // opened, rendered or recognized, so there is nothing derived for a
    // derivation opt-out to withdraw. Honouring it there would silently
    // strand the attachment with no lexical row and no way back, since the
    // dialog hides the toggle for SVG exactly because it does not apply
    // (a stored `ocr:false` is reachable by renaming a raster to `.svg`).
    final derivationAllowed = config.ocr || isSvgAttachment(attachment);
    if (!await _figuresEnabled() || !derivationAllowed || noteExcluded) {
      await _purgeAttachmentToState(
        attachment,
        status: statusSkipped,
        stateHash: baseHash,
        sourceType: 'figure',
        stage: stageFigures,
        deleteDerivedAssets: true,
      );
      return _figuresOutcomeDone;
    }

    // Raster images and SVG: one chunk, no extraction, no derived asset.
    if (!isPdf) {
      final drafts = _buildImageFigureDrafts(
        attachment,
        altText,
        await _loadAttachmentOcrText(attachment),
      );
      await _writeAttachmentChunks(
        attachment,
        drafts,
        [for (final d in drafts) normalizeForIndex(d.text)],
        _pdfStateHash(baseHash, pageCount: 1),
        sourceType: 'figure',
        stage: stageFigures,
      );
      return _figuresOutcomeDone;
    }

    // Size-gated default, shared with pdf_text/ocr: extraction renders every
    // region of every page, so a 500-page clipped PDF stays opt-in. The count
    // comes from the TEXT extractor's cached doc-info open, not the OCR one:
    // the figures stage must not make the OCR renderer touch a document OCR
    // itself was told (globally or per attachment) not to open.
    final pageCount = await _extractor.getPdfPageCount(attachment);
    if (!capBypassed && pageCount != null && pageCount > cap) {
      await _purgeAttachmentToState(
        attachment,
        status: statusSkippedTooLarge,
        stateHash: _pdfStateHash(baseHash, cap: cap, pageCount: pageCount),
        sourceType: 'figure',
        stage: stageFigures,
        deleteDerivedAssets: true,
      );
      return _figuresOutcomeDone;
    }

    final ocrItemsByPage = await _loadOcrItemsByPage(attachment);
    final result = await _figureExtractor.extractFigures(
      attachment,
      ocrItemsByPage: ocrItemsByPage,
      shouldAbort: () => _paused,
    );
    switch (result.status) {
      case FigureExtractionStatus.aborted:
        // Paused mid-file: write nothing; the resume sweep re-runs.
        return _figuresOutcomeAborted;
      case FigureExtractionStatus.extracted:
        final drafts = _buildRegionFigureDrafts(
          attachment,
          result.figures,
          ocrItemsByPage,
          altText,
        );
        await _writeAttachmentChunks(
          attachment,
          drafts,
          [for (final d in drafts) normalizeForIndex(d.text)],
          _pdfStateHash(baseHash, pageCount: result.pageCount),
          sourceType: 'figure',
          stage: stageFigures,
        );
        return _figuresOutcomeDone;
      case FigureExtractionStatus.skippedNotPdf:
        // Unreachable (isPdf gated above) but handled for completeness.
        await _purgeAttachmentToState(
          attachment,
          status: statusSkipped,
          stateHash: baseHash,
          sourceType: 'figure',
          stage: stageFigures,
          deleteDerivedAssets: true,
        );
        return _figuresOutcomeDone;
      case FigureExtractionStatus.failed:
        // Retry semantics come from the extractor's failure COUNTERS: it
        // reports `failed` (not an empty `extracted`) when every page failed
        // to load or every region failed to render/save, so an unreadable
        // document and a full disk are recorded as errors instead of frozen
        // as "done, no figures". Existing chunks are kept — better than
        // nothing — and the matching stateHash keeps sweeps from reopening a
        // broken file until it (or policy) changes; a forced rebuild retries.
        LoggerService.error(
          '[NoteIndex] figure extraction failed for '
          '${attachment.fileName}: ${result.errorMessage} '
          '(failedPages=${result.failedPages}, '
          'failedRenders=${result.failedRenders}/${result.attemptedRenders})',
        );
        await db.insert('search_index_state', {
          'scopeType': 'attachment',
          'scopeId': attachment.id,
          'stage': stageFigures,
          'contentHash': baseHash,
          'status': statusError,
          'errorMessage': result.errorMessage,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return _figuresOutcomeDone;
    }
  }

  /// Test hook for the one-chunk-per-page rule of [_loadOcrItemsByPage].
  @visibleForTesting
  Future<Map<int, List<PageTextItem>>> debugLoadOcrItemsByPage(
    Attachment attachment,
  ) => _loadOcrItemsByPage(attachment);

  /// Stored OCR block bounds for one attachment, keyed by 1-based page.
  ///
  /// Exactly ONE chunk per page contributes: Step 12 writes the page's FULL
  /// block list onto EVERY chunk of that page, so concatenating a page's
  /// chunks would duplicate every caption anchor and produce duplicate
  /// regions (and duplicate derived assets).
  Future<Map<int, List<PageTextItem>>> _loadOcrItemsByPage(
    Attachment attachment,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'search_chunks',
      columns: ['page', 'meta'],
      where: "sourceType = 'attachment_ocr' AND sourceId = ?",
      whereArgs: [attachment.id],
      orderBy: 'seq',
    );
    final byPage = <int, List<PageTextItem>>{};
    final seen = <int>{};
    for (final row in rows) {
      final page = (row['page'] as int?) ?? 1;
      if (!seen.add(page)) continue; // One chunk per page — see above.
      final meta = row['meta'] as String?;
      if (meta == null || meta.isEmpty) continue;
      final items = ocrItemsFromChunkMeta(meta);
      if (items.isNotEmpty) byPage[page] = items;
    }
    return byPage;
  }

  /// The attachment's recognized text (its `attachment_ocr` chunks), used as
  /// the searchable body of a raster image's figure chunk.
  Future<String> _loadAttachmentOcrText(Attachment attachment) async {
    final db = await _db.database;
    final rows = await db.query(
      'search_chunks',
      columns: ['text'],
      where: "sourceType = 'attachment_ocr' AND sourceId = ?",
      whereArgs: [attachment.id],
      orderBy: 'seq',
    );
    return [
      for (final row in rows) ((row['text'] as String?) ?? '').trim(),
    ].where((t) => t.isNotEmpty).join('\n');
  }

  /// One `figure` chunk per extracted region.
  List<ChunkDraft> _buildRegionFigureDrafts(
    Attachment attachment,
    List<DerivedFigure> figures,
    Map<int, List<PageTextItem>> ocrItemsByPage,
    String altText,
  ) {
    final drafts = <ChunkDraft>[];
    final nextIndexByPage = <int, int>{};
    for (final figure in figures) {
      final region = figure.region;
      final page = region.page;
      final fallbackIndex = nextIndexByPage.update(
        page,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      // The file name renderRegion wrote is authoritative for the index (the
      // `<i>` the resolver re-derives when meta is incomplete); the
      // per-page counter is only a fallback for an unexpected name.
      final figureIndex =
          _figureIndexFromFileName(figure.fileName) ?? fallbackIndex;
      final meta = <String, dynamic>{
        ...region.toJson(),
        'derivedAssetPath': figure.assetRelativePath,
        'figureIndex': figureIndex,
      };
      drafts.add(
        ChunkDraft(
          noteId: attachment.noteId,
          sourceType: 'figure',
          sourceId: attachment.id,
          // MUST equal meta.page (== region.page): the resolver probes the
          // asset path from meta and navigates from the column.
          page: page,
          seq: (page - 1) * 1000 + figureIndex,
          text: _figureChunkText([
            region.caption,
            attachment.fileName,
            altText,
            _regionOcrText(region, ocrItemsByPage[page]),
          ]),
          meta: jsonEncode(meta),
        ),
      );
    }
    return drafts;
  }

  /// The single `figure` chunk of a raster image or SVG attachment: no
  /// region, no derived asset, no `figureIndex` — the consumers address these
  /// as `synapseresource://attachment/<id>` (rasters) or render them as a
  /// link (SVG), never through a figure URI.
  List<ChunkDraft> _buildImageFigureDrafts(
    Attachment attachment,
    String altText,
    String ocrText,
  ) {
    final text = _figureChunkText([
      attachment.fileName,
      altText,
      // SVG is LEXICAL-ONLY: ML Kit cannot OCR it, so this is empty there.
      if (!isSvgAttachment(attachment)) ocrText,
    ]);
    if (text.isEmpty) return const [];
    return [
      ChunkDraft(
        noteId: attachment.noteId,
        sourceType: 'figure',
        sourceId: attachment.id,
        seq: 0,
        text: text,
      ),
    ];
  }

  /// Largest chunk of recognized text a figure chunk absorbs, so a dense
  /// scanned figure cannot bloat the row (and the embedding input).
  static const int _figureOcrTextLimit = 1500;

  /// `text` of a figure chunk: caption + fileName + note alt text + OCR text,
  /// so figures are lexically findable with NO provider configured.
  static String _figureChunkText(List<String?> parts) {
    final seen = <String>{};
    final lines = <String>[];
    for (final part in parts) {
      final value = part?.trim();
      if (value == null || value.isEmpty) continue;
      if (!seen.add(value)) continue;
      lines.add(value);
    }
    return lines.join('\n');
  }

  /// Recognized text lying INSIDE [region] (block centers, PDF y-up coords).
  static String? _regionOcrText(
    FigureRegion region,
    List<PageTextItem>? items,
  ) {
    if (items == null || items.isEmpty) return null;
    final rect = region.rectPdf;
    final buffer = StringBuffer();
    for (final item in items) {
      final r = item.rect;
      final cx = (r.left + r.right) / 2;
      final cy = (r.top + r.bottom) / 2;
      if (cx < rect.left || cx > rect.right) continue;
      if (cy > rect.top || cy < rect.bottom) continue;
      final text = item.text.trim();
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(text);
      if (buffer.length >= _figureOcrTextLimit) break;
    }
    if (buffer.isEmpty) return null;
    final text = buffer.toString();
    return text.length <= _figureOcrTextLimit
        ? text
        : text.substring(0, _figureOcrTextLimit);
  }

  static final RegExp _derivedIndexRe = RegExp(r'_f(\d+)\.png$');

  static int? _figureIndexFromFileName(String fileName) {
    final match = _derivedIndexRe.firstMatch(fileName);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Markdown image references pointing at [attachment], as alt text.
  ///
  /// Notes embed attachments as `![alt](fileName)` (the markdown toolbar),
  /// `![alt](relative/path)`, or `![alt](synapseresource://attachment/<id>)`.
  /// Whatever the form, the ALT text is the human label the user typed for
  /// this image — the best lexical handle a figure has when the PDF caption
  /// is missing.
  @visibleForTesting
  static String markdownAltTextFor(Attachment attachment, String noteContent) {
    if (noteContent.isEmpty) return '';
    final alts = <String>[];
    final seen = <String>{};
    for (final match in _markdownImageRe.allMatches(noteContent)) {
      final alt = (match.group(1) ?? '').trim();
      if (alt.isEmpty) continue;
      if (!_targetRefersTo(match.group(2) ?? '', attachment)) continue;
      if (seen.add(alt)) alts.add(alt);
    }
    return alts.join('\n');
  }

  static final RegExp _markdownImageRe = RegExp(
    r'!\[([^\]\n]*)\]\(\s*(<[^>\n]*>|[^)\s]*)[^)\n]*\)',
  );

  static bool _targetRefersTo(String rawTarget, Attachment attachment) {
    var target = rawTarget.trim();
    if (target.startsWith('<') && target.endsWith('>')) {
      target = target.substring(1, target.length - 1);
    }
    for (final separator in ['?', '#']) {
      final index = target.indexOf(separator);
      if (index >= 0) target = target.substring(0, index);
    }
    if (target.isEmpty) return false;
    try {
      target = Uri.decodeFull(target);
    } catch (_) {
      // Malformed percent-escapes: compare the raw form.
    }
    final lower = target.toLowerCase();
    // synapseresource://attachment/<id> (and any other id-terminated form).
    final lastSlash = target.lastIndexOf('/');
    if (lastSlash >= 0 &&
        target.substring(lastSlash + 1) == attachment.id &&
        lower.contains('attachment')) {
      return true;
    }
    final fileName = attachment.fileName.toLowerCase();
    if (fileName.isNotEmpty &&
        (lower == fileName || lower.endsWith('/$fileName'))) {
      return true;
    }
    // Path suffix match, anchored on a SEPARATOR exactly like the fileName
    // case above. An unanchored `filePath.endsWith(lower)` would make
    // `![Org chart](photo.png)` claim `attachments/team-photo.png` — the
    // wrong alt text would enter that attachment's figure chunks AND its
    // `alt=` digest, so editing an unrelated image would re-render these
    // figures, breaking the "ordinary edits never re-render" contract above.
    // `![x](.png)` would match every PNG on the note.
    final filePath = attachment.filePath.toLowerCase();
    if (filePath.isNotEmpty &&
        (lower == filePath || filePath.endsWith('/$lower'))) {
      return true;
    }
    return false;
  }

  /// Resumable figures pass over every figure-eligible attachment.
  ///
  /// Attachments are processed GROUPED BY NOTE so the note's markdown (which
  /// supplies the alt text every figure chunk carries) is read once and
  /// released before the next note — the backfill join deliberately does not
  /// select `notes.content`, a large column.
  ///
  /// Sets ('global','all','figures') = done when every attachment reached a
  /// terminal state — skipped and recorded-error states count as done
  /// (mirroring pdf_text/ocr) — with [_figuresPolicyHash] as its contentHash.
  /// Returns (done,total) attachment counts, or null when it bailed out early
  /// (paused).
  Future<({int done, int total})?> _runFiguresBackfill(
    Database db, {
    required bool force,
  }) async {
    // Captured BEFORE the pass, written after it: a settings change landing
    // mid-pass must leave a hash that no longer matches, so the next sweep
    // re-evaluates the attachments this one processed under the old policy.
    final policyHash = await _figuresPolicyHash();
    final work = await loadIndexAttachments(
      db,
      eligibleFileNameSql: _figureEligibleFileNameSql,
    );
    final byNote = <String, List<(Attachment, bool)>>{};
    var total = 0;
    for (final (attachment, noteExcluded) in work) {
      byNote.putIfAbsent(attachment.noteId, () => []).add((
        attachment,
        noteExcluded,
      ));
      total++;
    }

    var done = 0;
    var failed = 0;
    // Attachments this pass actually opened/wrote. Progress is published only
    // once one of them appears: an all-current sweep must publish nothing
    // (mirroring the ocr pass, whose totals cover pending work only) — a
    // figures 1/1 flash would otherwise overwrite the progress of whichever
    // earlier stage did the real work this round.
    var worked = 0;

    void publish() {
      _progress.value = IndexProgress(
        done: done,
        total: total,
        stage: stageFigures,
        unit: 'attachments',
        running: true,
      );
    }

    for (final entry in byNote.entries) {
      if (_paused) return null;
      final noteContent = await _loadNoteContent(entry.key);
      if (noteContent == null) {
        // Note deleted since the join; the orphan sweep clears leftovers.
        done += entry.value.length;
        continue;
      }
      for (final (attachment, noteExcluded) in entry.value) {
        if (_paused) return null;
        try {
          final outcome = await _serialized(
            () => _indexAttachmentFigures(
              attachment,
              noteExcluded: noteExcluded,
              noteContent: noteContent,
              force: force,
            ),
          );
          if (outcome == _figuresOutcomeAborted) return null;
          if (outcome != _figuresOutcomeUpToDate) worked++;
        } catch (e) {
          failed++;
          worked++;
          LoggerService.error(
            '[NoteIndex] figures backfill failed for ${attachment.id}: $e',
            error: e,
          );
        }
        done++;
        if (worked > 0) publish();
      }
    }

    if (!_paused && failed == 0) {
      await db.insert('search_index_state', {
        'scopeType': 'global',
        'scopeId': 'all',
        'stage': stageFigures,
        // Like the ocr row this one CARRIES a hash: the figure settings as of
        // this completed pass (see [_figuresStageComplete]).
        'contentHash': policyHash,
        'status': statusDone,
        'errorMessage': null,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // Zero counts when nothing needed doing: the caller then leaves the final
    // progress with the stage that did the work (see [worked]).
    return worked > 0 ? (done: done, total: total) : (done: 0, total: 0);
  }

  // ── embed stage ──────────────────────────────────────────────────────────
  //
  // Plan §2.3: gaps by (chunkId, providerKey) + contentHash, batch-embed,
  // store L2-normalized float32-LE vectors. The stage targets the ACTIVE
  // provider (the transition target); queries keep using the SERVING
  // provider until this stage's global row turns done, at which point the
  // registry promotes the active key to serving and the old key's rows are
  // lazily GC'd.
  //
  // Policy: chunks whose source attachment has includeInAIContext = false
  // are never embedded (the existing privacy contract extends to embedding
  // uploads), nor those whose attachment turned the embed stage off
  // (metadata.searchIndex.embed). Note-born chunks embed when a provider is
  // active AND the global consent flag is set (the consent-check seam);
  // without consent the whole stage no-ops. Both exclusions are enforced
  // TWICE: as a filter on the gap scans (nothing new is uploaded) and as a
  // purge of already-stored vectors at the head of every pass (what was
  // uploaded before the opt-out stops serving results) — see
  // [_purgeEmbedPolicyViolations].
  //
  // MULTIMODAL (plan §4.1): when the active provider's supportsImages is
  // true, a `figure` chunk is embedded as an IMAGE — its derived crop, or the
  // raster attachment itself — downscaled to [_embedImageMaxSide] px on the
  // longest side, and the stored row records modality 'image'. Everything
  // else (and every figure whose image is unavailable: SVG, a crop lost to a
  // restore, an undecodable file) embeds its TEXT, so the layer degrades
  // instead of dropping the chunk. The exclusions above apply identically to
  // both paths — they are enforced in the gap scan, before any file is read.
  //
  // A text fallback is RECOVERABLE, and `chunk_embeddings.modality` is what
  // makes it so: a figure stored as 'text' whose image input later becomes
  // available (the normal post-restore case — the crop is re-rendered by the
  // figures stage, which does NOT change the chunk's contentHash, so the
  // plain hash-difference gap scan would never notice) is re-embedded as an
  // image. See [_scanFigureModalityUpgradeIds]. A figure whose image file is
  // present but UNUSABLE (over the decode budget, corrupt) records a
  // 'skipped' chunk-scoped state row so it settles instead of paying for a
  // fresh text embedding on every single sweep.
  //
  // Error handling per batch:
  // - auth (401/403), model-not-installed, dims mismatch → HALT the pass and
  //   record a visible error on the global row ('global','all','embed:<key>'),
  //   its errorMessage prefixed with the machine-readable halt kind (see
  //   [encodeEmbedHalt]) — settings surfaces errorMessage in Step 10; the
  //   halt is sticky (no retry burn on sweeps) until
  //   retryEmbedIndexing()/rebuild.
  // - transient (429/5xx/network) → exponential backoff (embedRetryBaseDelay
  //   · 2ⁿ, embedMaxRetries), then DEFER like a battery deferral: no state
  //   written, global flag stays unset, next sweep retries.
  // - other permanent failures → per-chunk error rows ('chunk', chunkId,
  //   'embed:<key>') keyed to the chunk's contentHash (skipped by future gap
  //   scans until the content changes) and the pass continues. Recorded
  //   per-chunk errors count as terminal for the global flag, mirroring
  //   pdf_text's accounting.

  /// sourceTypes whose chunks derive from an attachment (embed policy +
  /// includeInAIContext apply to these).
  static const Set<String> _attachmentSourceTypes = {
    'attachment_text',
    'attachment_ocr',
    'figure',
  };

  static const int _embedOutcomeDone = 0;
  static const int _embedOutcomeDeferred = 1;
  static const int _embedOutcomeHalted = 2;
  static const int _embedOutcomeUnavailable = 3;

  /// One full embed pass for the active provider ([scopeNoteId] limits the
  /// gap scan to one note — the per-edit path). Runs OFF the write queue
  /// (network); only its batch writes are serialized. Returns its outcome
  /// plus (done,total) chunk counts for progress bookkeeping.
  Future<({int outcome, int done, int total, String? stage})> _runEmbedPass({
    required String? scopeNoteId,
    required bool force,
  }) async {
    const unavailable = (
      outcome: _embedOutcomeUnavailable,
      done: 0,
      total: 0,
      stage: null,
    );
    if (_paused || _deletingEmbeddings) return unavailable;
    final generation = _embedGeneration;
    bool cancelled() =>
        _paused || _deletingEmbeddings || generation != _embedGeneration;
    final db = await _db.database;
    // Policy purge FIRST, ahead of every gate below: it only DELETES local
    // rows, so it needs no provider, no consent, no network and no unhalted
    // stage — and an opt-out that took effect only while a provider happened
    // to be configured would not be an opt-out (plan §1.3).
    await _serialized(
      () => _purgeEmbedPolicyViolations(db, scopeNoteId: scopeNoteId),
    );

    final registry = _embeddingRegistry;
    if (registry == null) return unavailable;
    await registry.ensureInitialized();
    final config = registry.activeConfig;
    final provider = registry.active;
    if (config == null || provider == null) return unavailable;
    final providerKey = config.providerKey;
    final stage = stageEmbed(providerKey);
    if (!await _embedConsentCheck(providerKey) || cancelled()) {
      return unavailable;
    }

    Future<void> writeGlobal(String status, {String? errorMessage}) =>
        _serialized(() async {
          if (cancelled()) return;
          await _writeEmbedGlobalRow(
            db,
            stage,
            status,
            errorMessage: errorMessage,
          );
        });

    if (!force && await _embedStageHalted(db, stage)) {
      return (outcome: _embedOutcomeHalted, done: 0, total: 0, stage: stage);
    }
    if (!await _embedNetworkAllowed()) {
      // A note may have changed since the previous completed pass. Keep
      // ensureBackfilled eligible to resume once the network gate reopens.
      await _clearEmbedGlobalDone(db, stage);
      return (outcome: _embedOutcomeDeferred, done: 0, total: 0, stage: stage);
    }

    final gapIds = await _scanEmbedGapIds(
      db,
      providerKey,
      stage,
      scopeNoteId: scopeNoteId,
    );
    if (provider.supportsImages) {
      // Figures already embedded from TEXT whose image input has since become
      // available. Their contentHash still matches, so the scan above cannot
      // see them (plan §4.1 fallback recovery).
      gapIds.addAll(
        await _scanFigureModalityUpgradeIds(
          db,
          providerKey,
          stage,
          scopeNoteId: scopeNoteId,
        ),
      );
      gapIds.sort((a, b) => a.id.compareTo(b.id));
    }
    if (cancelled()) return unavailable;
    final total = gapIds.length;
    var done = 0;
    var staleBatch = false;
    if (gapIds.isEmpty) {
      if (scopeNoteId == null && !_paused) {
        await writeGlobal(statusDone);
        if (!cancelled()) await _maybePromoteServing(registry, providerKey);
      }
      return (outcome: _embedOutcomeDone, done: 0, total: 0, stage: stage);
    }

    final batches = _buildEmbedBatches(gapIds, provider);
    if (scopeNoteId == null) {
      _progress.value = IndexProgress(
        done: 0,
        total: total,
        stage: stage,
        unit: 'chunks',
        running: true,
      );
    }

    void reportProgress() {
      if (scopeNoteId != null) return;
      _progress.value = IndexProgress(
        done: done,
        total: total,
        stage: stage,
        unit: 'chunks',
        running: true,
      );
    }

    /// Deferral bookkeeping: a pass that stops with gaps left must not
    /// leave a stale ('global','all',stage) = done row behind — that flag is
    /// what [ensureBackfilled] consults, so a per-note pass deferred by the
    /// wifi gate would otherwise never be picked back up.
    Future<({int outcome, int done, int total, String? stage})> defer() async {
      if (cancelled()) return unavailable;
      await _clearEmbedGlobalDone(db, stage);
      return (
        outcome: _embedOutcomeDeferred,
        done: done,
        total: total,
        stage: stage,
      );
    }

    for (final batchIds in batches) {
      if (cancelled() || !await _embedConsentCheck(providerKey)) {
        return unavailable;
      }
      if (!await _embedNetworkAllowed()) {
        return defer();
      }
      // Text is fetched per batch (never for the whole pass at once) and is
      // re-read here, so a chunk edited since the scan embeds its CURRENT
      // content under its current hash.
      final batch = await _loadEmbedGapBatch(db, batchIds);
      if (batch.isEmpty) {
        done += batchIds.length; // Every chunk vanished since the scan.
        reportProgress();
        continue;
      }
      List<Float32List> vectors;
      List<_PreparedEmbedInput> prepared;
      try {
        final embedded = await _embedBatchWithRetry(
          provider,
          batch,
          shouldAbort: cancelled,
        );
        vectors = embedded.vectors;
        prepared = embedded.prepared;
        if (vectors.length != batch.length) {
          throw EmbeddingProviderException(
            'Provider returned ${vectors.length} vectors for '
            '${batch.length} inputs',
          );
        }
      } on EmbeddingProviderException catch (e) {
        if (cancelled()) return unavailable;
        if (e.isAuthError || e.isNotInstalled || e.detectedDimensions != null) {
          // Halt the whole pass; visible error state for settings (§2.2).
          LoggerService.error(
            '[NoteIndex] embed pass halted for $providerKey: ${e.message}',
          );
          await writeGlobal(statusError, errorMessage: encodeEmbedHalt(e));
          return (
            outcome: _embedOutcomeHalted,
            done: done,
            total: total,
            stage: stage,
          );
        }
        if (e.isTransient) {
          // Bounded retries already exhausted inside _embedBatchWithRetry:
          // defer (no state) so the next sweep retries.
          LoggerService.warning(
            '[NoteIndex] embed pass deferred (transient): ${e.message}',
          );
          return defer();
        }
        // Permanent, batch-scoped: record per-chunk errors and continue.
        LoggerService.error(
          '[NoteIndex] embed batch failed permanently: ${e.message}',
        );
        final recorded = await _serialized(() async {
          if (cancelled()) return 0;
          return _writeChunkEmbedErrors(batch, stage, e.message);
        });
        if (recorded < batch.length) staleBatch = true;
        done += batchIds.length;
        reportProgress();
        continue;
      } catch (e) {
        if (cancelled()) return unavailable;
        // Unexpected (e.g. ArgumentError): treat as permanent for the batch.
        LoggerService.error('[NoteIndex] embed batch failed: $e', error: e);
        final recorded = await _serialized(() async {
          if (cancelled()) return 0;
          return _writeChunkEmbedErrors(batch, stage, '$e');
        });
        if (recorded < batch.length) staleBatch = true;
        done += batchIds.length;
        reportProgress();
        continue;
      }

      if (cancelled() || !await _embedConsentCheck(providerKey)) {
        return unavailable;
      }
      final written = await _serialized(
        () => _writeEmbeddingBatch(
          providerKey,
          batch,
          vectors,
          prepared,
          stage,
          generation: generation,
        ),
      );
      if (written == null) return unavailable;
      if (written < batch.length) staleBatch = true;
      done += batchIds.length;
      reportProgress();
    }

    if (cancelled()) return unavailable;
    if (staleBatch) return defer();
    if (scopeNoteId == null) {
      // Recorded per-chunk errors are stable, inspectable rows — terminal
      // for completeness (a permanently failing chunk must not pin the
      // stage incomplete forever).
      await writeGlobal(statusDone);
      if (!cancelled()) await _maybePromoteServing(registry, providerKey);
    }
    return (outcome: _embedOutcomeDone, done: done, total: total, stage: stage);
  }

  /// Drops a ('global','all',[stage]) = done row so the next sweep resumes
  /// an interrupted pass. Error rows are left alone (halts are sticky).
  Future<void> _clearEmbedGlobalDone(Database db, String stage) async {
    await db.delete(
      'search_index_state',
      where:
          "scopeType = 'global' AND scopeId = 'all' AND stage = ? "
          'AND status = ?',
      whereArgs: [stage, statusDone],
    );
  }

  /// Whether the stage's global row records a halt (auth/permanent error).
  Future<bool> _embedStageHalted(Database db, String stage) async {
    final rows = await db.query(
      'search_index_state',
      columns: ['status'],
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stage],
    );
    return rows.isNotEmpty && rows.first['status'] == statusError;
  }

  /// Gap scan (plan §2.3): ids of the chunks with no `chunk_embeddings` row
  /// for [providerKey] — or a stale one (contentHash differs) — that pass
  /// embed policy. Chunks with a recorded permanent error for their CURRENT
  /// contentHash are skipped (they retry only when content changes or a
  /// forced rebuild clears the error rows).
  ///
  /// Returns IDS ONLY, read in keyset-paged pages: the chunk TEXT is fetched
  /// one batch at a time by [_loadEmbedGapBatch]. Materializing every gap's
  /// text up front would hold the whole corpus in memory (~12 MB at 10k
  /// chunks) across every network round-trip of the pass, on top of the
  /// vector matrix.
  Future<List<_EmbedGapId>> _scanEmbedGapIds(
    Database db,
    String providerKey,
    String stage, {
    String? scopeNoteId,
  }) async {
    final ids = <_EmbedGapId>[];
    var afterId = 0; // search_chunks.id is a rowid: always > 0.
    while (true) {
      final rows = await db.rawQuery(
        '''
        SELECT c.id, c.sourceType,
               n.id AS liveNoteId, $_embedNoteMetadataSql,
               a.id AS attachmentId,
               a.includeInAIContext AS aiInclude,
               $_embedAttachmentMetadataSql
        FROM search_chunks c
        LEFT JOIN notes n ON n.id = c.noteId AND n.__deleted__ = 0
        LEFT JOIN chunk_embeddings e
          ON e.chunkId = c.id AND e.providerKey = ?
        LEFT JOIN attachments a
          ON a.id = c.sourceId
          AND c.sourceType IN ('attachment_text','attachment_ocr','figure')
          $_liveAttachmentJoinFilter
        LEFT JOIN search_index_state s
          ON s.scopeType = 'chunk' AND s.scopeId = CAST(c.id AS TEXT)
          AND s.stage = ?
        WHERE (e.chunkId IS NULL OR e.contentHash != c.contentHash)
          AND NOT (COALESCE(s.status, '') = ?
                   AND COALESCE(s.contentHash, '') = c.contentHash)
          AND trim(c.text) != ''
          AND c.id > ?
          ${scopeNoteId != null ? 'AND c.noteId = ?' : ''}
        ORDER BY c.id
        LIMIT ?
        ''',
        [
          providerKey,
          stage,
          statusError,
          afterId,
          if (scopeNoteId != null) scopeNoteId,
          embedScanPageSize,
        ],
      );
      if (rows.isEmpty) return ids;
      for (final row in await hydrateIndexEmbedPolicies(db, rows)) {
        afterId = row['id'] as int;
        if (!_passesEmbedPolicy(row)) continue;
        ids.add((id: afterId, figure: row['sourceType'] == 'figure'));
      }
      if (rows.length < embedScanPageSize) return ids;
    }
  }

  /// The per-attachment embed exclusions of plan §2.3, shared by both gap
  /// scans so they can never diverge: an orphaned attachment chunk, an
  /// attachment with `includeInAIContext = false` (the privacy contract
  /// extends to embedding uploads), and one whose
  /// `metadata.searchIndex.embed` is false are never embedded. Rows must
  /// carry `sourceType`, `attachmentId`, `aiInclude` and `attachmentMetadata`.
  ///
  /// Every caller's `attachments` join carries [_liveAttachmentJoinFilter], so
  /// a null `attachmentId` means "no LIVE attachment" — absent OR tombstoned.
  /// Without that filter this null check is dead for a deleted attachment (the
  /// tombstoned row still joins) and the `aiInclude`/`attachmentMetadata`
  /// decisions below are read off a row that no longer exists.
  bool _passesEmbedPolicy(Map<String, Object?> row) {
    if (row['liveNoteId'] == null ||
        isNoteSearchExcluded(_decodeMetadata(row['noteMetadata'] as String?))) {
      return false;
    }
    final sourceType = row['sourceType'] as String? ?? '';
    if (!_attachmentSourceTypes.contains(sourceType)) return true;
    if (row['attachmentId'] == null) {
      // Orphaned or deleted attachment chunk: the orphan sweep purges it.
      return false;
    }
    if ((row['aiInclude'] as int? ?? 1) == 0) {
      return false; // includeInAIContext = false: never uploaded (§2.3).
    }
    final metadata = _decodeMetadata(row['attachmentMetadata'] as String?);
    final searchIndex = metadata?['searchIndex'];
    if (searchIndex is Map && searchIndex['embed'] == false) {
      return false; // Per-attachment embed stage turned off (plan §1.3).
    }
    return true;
  }

  // A chunk scan may join a note and attachment whose marker metadata is
  // megabytes. Keep the ordinary row small; load oversized policies through
  // the byte-safe reader before making any upload or stored-vector decision.
  static const int _inlinePolicyBytes = 64 * 1024;
  static const String _embedNoteMetadataSql =
      'CASE WHEN length(CAST(n.metadata AS BLOB)) <= $_inlinePolicyBytes '
      'THEN n.metadata END AS noteMetadata, '
      'length(CAST(n.metadata AS BLOB)) AS noteMetadataBytes';
  static const String _embedAttachmentMetadataSql =
      'CASE WHEN length(CAST(a.metadata AS BLOB)) <= $_inlinePolicyBytes '
      'THEN a.metadata END AS attachmentMetadata, '
      'length(CAST(a.metadata AS BLOB)) AS attachmentMetadataBytes';

  @visibleForTesting
  static Future<List<Map<String, Object?>>> hydrateIndexEmbedPolicies(
    DatabaseExecutor db,
    List<Map<String, Object?>> rows,
  ) async {
    final policies = <String, Map<String, String?>>{};
    for (final (table, ownerColumn, metadataColumn) in [
      ('notes', 'liveNoteId', 'noteMetadata'),
      ('attachments', 'attachmentId', 'attachmentMetadata'),
    ]) {
      final lengths = <String, int>{};
      for (final row in rows) {
        final length = row['${metadataColumn}Bytes'] as int? ?? 0;
        final owner = row[ownerColumn] as String?;
        if (owner != null && length > _inlinePolicyBytes) {
          lengths[owner] = length;
        }
      }
      final byOwner = <String, String?>{};
      for (final ids in planBackfillBatches(lengths.keys.toList(), lengths)) {
        final metadataRows = await readSyncRowsWhere(
          db,
          table: table,
          columns: ['id', 'metadata'],
          keyColumns: ['id'],
          where: 'id IN (${List.filled(ids.length, '?').join(',')})',
          whereArgs: ids,
        );
        for (final row in metadataRows) {
          final metadata = _decodeMetadata(row['metadata'] as String?);
          final policy = metadata?['searchIndex'];
          byOwner[row['id'] as String] = policy is Map
              ? jsonEncode({'searchIndex': policy})
              : null;
        }
      }
      policies[metadataColumn] = byOwner;
    }
    return [
      for (final row in rows)
        {
          ...row,
          if ((row['noteMetadataBytes'] as int? ?? 0) > _inlinePolicyBytes)
            'noteMetadata': policies['noteMetadata']![row['liveNoteId']],
          if ((row['attachmentMetadataBytes'] as int? ?? 0) >
              _inlinePolicyBytes)
            'attachmentMetadata':
                policies['attachmentMetadata']![row['attachmentId']],
        },
    ];
  }

  /// Deletes the STORED vectors of every chunk that no longer passes
  /// [_passesEmbedPolicy] — the purge half of plan §1.3 ("flipping a flag off
  /// promptly deletes the affected chunks, embeddings and derived figure
  /// assets, and incrementally patches the in-memory vector matrix").
  ///
  /// The two gap scans are FILTERS: they stop new vectors being created, but
  /// a chunk embedded BEFORE its attachment's `includeInAIContext` or
  /// `metadata.searchIndex.embed` was turned off keeps its `chunk_embeddings`
  /// row AND its column in the loaded matrix, and nothing re-checks the
  /// policy at query time — so without this pass the attachment keeps
  /// surfacing in semantic results after the user opted out, which is exactly
  /// what the toggle promises it will not do.
  ///
  /// Deliberately a self-healing SWEEP rather than a side effect of the write
  /// that flips the flag: it also collects vectors stranded by an external
  /// metadata write, a restore, or a build that predates this pass. It runs
  /// through [_transactionWithRemovals] like every other delete, so the
  /// in-memory matrix is patched incrementally after the commit instead of
  /// waiting for a reload that never happens.
  ///
  /// Only the vectors go: the chunk stays lexically searchable, because these
  /// flags say "do not send this to the provider", not "do not index it".
  /// The flags that delete CHUNKS (`text:'off'`, `ocr:false`, note exclusion)
  /// purge through their own stages, taking the embeddings with them.
  Future<void> _purgeEmbedPolicyViolations(
    Database db, {
    String? scopeNoteId,
  }) async {
    final doomed = <int>[];
    var afterId = 0; // search_chunks.id is a rowid: always > 0.
    while (true) {
      // Driven FROM chunk_embeddings so a database with no vectors at all
      // (no provider ever configured) pays for an empty index scan. DISTINCT
      // because a chunk can hold one row per providerKey — the policy is
      // provider-independent, so every one of them goes.
      final rows = await db.rawQuery(
        '''
        SELECT DISTINCT c.id, c.sourceType,
               n.id AS liveNoteId, $_embedNoteMetadataSql,
               a.id AS attachmentId,
               a.includeInAIContext AS aiInclude,
               $_embedAttachmentMetadataSql
        FROM chunk_embeddings e
        JOIN search_chunks c ON c.id = e.chunkId
        LEFT JOIN notes n ON n.id = c.noteId AND n.__deleted__ = 0
        LEFT JOIN attachments a
          ON a.id = c.sourceId $_liveAttachmentJoinFilter
        WHERE c.id > ?
          ${scopeNoteId != null ? 'AND c.noteId = ?' : ''}
        ORDER BY c.id
        LIMIT ?
        ''',
        [afterId, if (scopeNoteId != null) scopeNoteId, embedScanPageSize],
      );
      if (rows.isEmpty) break;
      for (final row in await hydrateIndexEmbedPolicies(db, rows)) {
        afterId = row['id'] as int;
        if (!_passesEmbedPolicy(row)) doomed.add(afterId);
      }
      if (rows.length < embedScanPageSize) break;
    }
    if (doomed.isEmpty) return;
    LoggerService.info(
      '[NoteIndex] embed policy purge: dropping ${doomed.length} vector(s)',
    );
    await _transactionWithRemovals(db, (txn, removals) async {
      for (var i = 0; i < doomed.length; i += _sqlVarChunk) {
        final batch = doomed.sublist(
          i,
          i + _sqlVarChunk > doomed.length ? doomed.length : i + _sqlVarChunk,
        );
        final placeholders = List.filled(batch.length, '?').join(',');
        await txn.rawDelete(
          'DELETE FROM chunk_embeddings WHERE chunkId IN ($placeholders)',
          batch,
        );
        removals.addAll(batch);
      }
    });
  }

  /// Second gap scan, run ONLY for an image-capable provider: `figure` chunks
  /// whose stored vector is otherwise CURRENT (contentHash matches, so
  /// [_scanEmbedGapIds] cannot see them) but was produced from TEXT, and
  /// whose image input exists on disk now.
  ///
  /// Without this, `modality` is a write-only column and a text fallback is
  /// permanent: a figure chunk's text does not change when its crop is
  /// re-rendered (the region-identity contentHash is deliberately stable
  /// across re-renders), so the ordinary hash-difference scan never fires
  /// again and `backfillAll(force: true)` explicitly keeps matching-hash
  /// vectors. The normal way in is a restore: derived crops are excluded from
  /// export/backup by design, so every figure embeds as text on first index
  /// after a restore and only becomes an image once the figures stage has
  /// re-rendered the crops.
  ///
  /// TERMINATION — the reason the on-disk check is here and not only inside
  /// [_figureImageInput]: a candidate that came back is re-embedded, and if
  /// its image still cannot be used the result is another TEXT vector with
  /// the same hash, i.e. the same candidate next sweep, i.e. a provider call
  /// per sweep forever. So the two "cannot use it" cases are separated:
  ///  * image FILE ABSENT (missing crop, SVG with no path at all) — cheap to
  ///    re-test, so it is tested HERE and costs nothing until the file lands;
  ///  * image file PRESENT but unusable (over the decode budget, corrupt) —
  ///    only discoverable by opening it, so [_writeEmbeddingBatch] records a
  ///    'skipped' chunk-scoped state row for it and this scan skips it until
  ///    the chunk's content changes or a forced rebuild clears the row.
  Future<List<_EmbedGapId>> _scanFigureModalityUpgradeIds(
    Database db,
    String providerKey,
    String stage, {
    String? scopeNoteId,
  }) async {
    final ids = <_EmbedGapId>[];
    var afterId = 0;
    while (true) {
      final rows = await db.rawQuery(
        '''
        SELECT c.id, c.sourceType, c.meta,
               n.id AS liveNoteId, $_embedNoteMetadataSql,
               a.id AS attachmentId,
               a.includeInAIContext AS aiInclude,
               $_embedAttachmentMetadataSql,
               a.fileName AS attFileName,
               a.filePath AS attFilePath,
               a.isRelativePath AS attIsRelative
        FROM search_chunks c
        LEFT JOIN notes n ON n.id = c.noteId AND n.__deleted__ = 0
        JOIN chunk_embeddings e
          ON e.chunkId = c.id AND e.providerKey = ?
          AND e.contentHash = c.contentHash AND e.modality = 'text'
        LEFT JOIN attachments a
          ON a.id = c.sourceId $_liveAttachmentJoinFilter
        LEFT JOIN search_index_state s
          ON s.scopeType = 'chunk' AND s.scopeId = CAST(c.id AS TEXT)
          AND s.stage = ?
        WHERE c.sourceType = 'figure'
          AND NOT (COALESCE(s.status, '') IN (?, ?)
                   AND COALESCE(s.contentHash, '') = c.contentHash)
          AND trim(c.text) != ''
          AND c.id > ?
          ${scopeNoteId != null ? 'AND c.noteId = ?' : ''}
        ORDER BY c.id
        LIMIT ?
        ''',
        [
          providerKey,
          stage,
          statusError,
          statusSkipped,
          afterId,
          if (scopeNoteId != null) scopeNoteId,
          embedScanPageSize,
        ],
      );
      if (rows.isEmpty) return ids;
      for (final row in await hydrateIndexEmbedPolicies(db, rows)) {
        afterId = row['id'] as int;
        if (!_passesEmbedPolicy(row)) continue;
        final path = await _figureImagePath(
          _EmbedGap(
            chunkId: afterId,
            text: '',
            contentHash: '',
            sourceType: 'figure',
            meta: row['meta'] as String?,
            attachmentFileName: row['attFileName'] as String?,
            attachmentFilePath: row['attFilePath'] as String?,
            attachmentIsRelativePath: (row['attIsRelative'] as int?) != 0,
          ),
        );
        if (path == null || !await File(path).exists()) continue;
        ids.add((id: afterId, figure: true));
      }
      if (rows.length < embedScanPageSize) return ids;
    }
  }

  /// Splits [gapIds] into provider batches, capped BOTH by the provider's
  /// `maxBatchSize` and — for an image-capable provider — by
  /// [_maxImageInputsPerBatch].
  ///
  /// [_buildEmbedInputs] materializes every input of a batch at once, so a
  /// batch of N figure chunks holds N downscaled images (plus the provider's
  /// base64 request body) in memory simultaneously. Today the only
  /// image-capable preset ships `supports_batch: false` → `maxBatchSize = 1`,
  /// which is the ONLY thing keeping that bounded; a future preset with both
  /// flags set would otherwise accumulate a whole batch of images. Text
  /// chunks are unaffected: only the figure count in a batch is rationed.
  List<List<int>> _buildEmbedBatches(
    List<_EmbedGapId> gapIds,
    EmbeddingProvider provider,
  ) {
    final maxBatch = math.max(1, provider.maxBatchSize);
    final maxImages = provider.supportsImages
        ? _maxImageInputsPerBatch
        : maxBatch;
    final batches = <List<int>>[];
    var current = <int>[];
    var images = 0;
    for (final gap in gapIds) {
      if (current.isNotEmpty &&
          (current.length >= maxBatch || (gap.figure && images >= maxImages))) {
        batches.add(current);
        current = <int>[];
        images = 0;
      }
      current.add(gap.id);
      if (gap.figure) images++;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Most image inputs one batch may carry (see [_buildEmbedBatches]). At the
  /// [_embedImageMaxSide] budget a downscaled crop is well under 1 MB, so 4
  /// bounds the batch's image working set at a few MB including the base64
  /// expansion — small next to the decode budget a single image may cost.
  static const int _maxImageInputsPerBatch = 4;

  /// Loads the text + current contentHash of one batch of gap ids, in the
  /// order given. Chunks deleted since the scan (or emptied) simply drop out
  /// — the pass counts them as done and the next sweep re-checks.
  Future<List<_EmbedGap>> _loadEmbedGapBatch(
    DatabaseExecutor db,
    List<int> chunkIds,
  ) async {
    if (chunkIds.isEmpty) return const [];
    final byId = <int, Map<String, Object?>>{};
    for (var i = 0; i < chunkIds.length; i += _sqlVarChunk) {
      final slice = chunkIds.sublist(
        i,
        math.min(i + _sqlVarChunk, chunkIds.length),
      );
      final placeholders = List.filled(slice.length, '?').join(',');
      // The attachment join carries what the multimodal path needs to locate
      // a figure's image without a second query per chunk.
      final rows = await db.rawQuery(
        'SELECT c.id, c.chunkKey, c.text, c.contentHash, c.sourceType, c.meta, '
        'n.id AS liveNoteId, $_embedNoteMetadataSql, '
        'a.id AS attachmentId, a.includeInAIContext AS aiInclude, '
        '$_embedAttachmentMetadataSql, '
        'a.fileName AS attFileName, a.filePath AS attFilePath, '
        'a.isRelativePath AS attIsRelative '
        'FROM search_chunks c '
        'LEFT JOIN notes n ON n.id = c.noteId AND n.__deleted__ = 0 '
        'LEFT JOIN attachments a ON a.id = c.sourceId '
        "AND c.sourceType IN ('attachment_text','attachment_ocr','figure') "
        '$_liveAttachmentJoinFilter '
        'WHERE c.id IN ($placeholders)',
        slice,
      );
      for (final row in await hydrateIndexEmbedPolicies(db, rows)) {
        byId[row['id'] as int] = row;
      }
    }
    final gaps = <_EmbedGap>[];
    for (final chunkId in chunkIds) {
      final row = byId[chunkId];
      if (row == null || !_passesEmbedPolicy(row)) continue;
      final text = row['text'] as String;
      if (text.trim().isEmpty) continue;
      gaps.add(
        _EmbedGap(
          chunkId: chunkId,
          chunkKey: row['chunkKey'] as String,
          text: text,
          contentHash: row['contentHash'] as String,
          sourceType: row['sourceType'] as String? ?? '',
          meta: row['meta'] as String?,
          attachmentFileName: row['attFileName'] as String?,
          attachmentFilePath: row['attFilePath'] as String?,
          attachmentIsRelativePath: (row['attIsRelative'] as int?) != 0,
        ),
      );
    }
    return gaps;
  }

  /// Embed one batch with bounded exponential backoff on transient failures.
  /// Rethrows the last transient error once retries are exhausted (the
  /// caller then defers the pass); non-transient errors rethrow immediately.
  ///
  /// Returns the vectors plus the modality actually used per input, which the
  /// stored `chunk_embeddings.modality` records.
  Future<({List<Float32List> vectors, List<_PreparedEmbedInput> prepared})>
  _embedBatchWithRetry(
    EmbeddingProvider provider,
    List<_EmbedGap> batch, {
    required bool Function() shouldAbort,
  }) async {
    final prepared = await _buildEmbedInputs(provider, batch);
    final inputs = [for (final item in prepared) item.input];
    var attempt = 0;
    while (true) {
      if (shouldAbort()) {
        throw const EmbeddingProviderException(
          'Embedding pass cancelled',
          isTransient: true,
        );
      }
      try {
        return (
          vectors: await provider.embedDocuments(inputs),
          prepared: prepared,
        );
      } on EmbeddingProviderException catch (e) {
        if (!e.isTransient || attempt >= embedMaxRetries) rethrow;
        await Future<void>.delayed(embedRetryBaseDelay * (1 << attempt));
        attempt++;
        if (_paused) rethrow; // Pause landed during the backoff wait.
      }
    }
  }

  /// Longest side (px) of an image handed to the provider (plan §4.1
  /// "downscaled to ~768 px longest side" — cheaper and sharper than whole
  /// pages, and well inside every provider's per-image budget).
  static const int _embedImageMaxSide = 768;

  /// Builds this batch's provider inputs: images for `figure` chunks when the
  /// provider supports them, text otherwise (and text as the fallback for
  /// every figure whose image cannot be produced).
  Future<List<_PreparedEmbedInput>> _buildEmbedInputs(
    EmbeddingProvider provider,
    List<_EmbedGap> batch,
  ) async {
    final prepared = <_PreparedEmbedInput>[];
    for (final gap in batch) {
      if (provider.supportsImages && gap.sourceType == 'figure') {
        final image = await _figureImageInput(gap);
        if (image.input != null) {
          prepared.add(
            _PreparedEmbedInput(image.input!, 'image', imageUnusable: false),
          );
          continue;
        }
        prepared.add(
          _PreparedEmbedInput(
            EmbeddingInput.text(gap.text),
            'text',
            imageUnusable: image.unusable,
          ),
        );
        continue;
      }
      prepared.add(_PreparedEmbedInput(EmbeddingInput.text(gap.text), 'text'));
    }
    return prepared;
  }

  /// The image input for a `figure` chunk: its derived crop, or — for a
  /// raster image attachment, which has no crop — the attachment file itself.
  ///
  /// A null `input` means "embed the text instead", and `unusable` says which
  /// KIND of null it is, because the two retry differently (see
  /// [_scanFigureModalityUpgradeIds]):
  ///  * `unusable: false` — nothing to open: an SVG (no image path at all), a
  ///    crop lost to a restore, a file that is not there yet, or an I/O error
  ///    that may well not repeat. Cheap to re-test, so it stays retryable.
  ///  * `unusable: true` — the file IS there and still cannot become an
  ///    image input: over the decode budget, or bytes no decoder accepts.
  ///    Re-testing costs a full read + header parse and would end in the same
  ///    text vector, so the caller records it and stops asking.
  Future<({EmbeddingInput? input, bool unusable})> _figureImageInput(
    _EmbedGap gap,
  ) async {
    try {
      final path = await _figureImagePath(gap);
      if (path == null) return (input: null, unusable: false);
      final file = File(path);
      if (!await file.exists()) return (input: null, unusable: false);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return (input: null, unusable: true);
      final prepared = await compute(
        _downscaleForEmbedding,
        _ImageEmbedRequest(
          bytes: bytes,
          extension: _extensionOf(path),
          maxSide: _embedImageMaxSide,
          maxDecodePixels: kMaxEmbedDecodePixels,
        ),
      );
      if (prepared == null) {
        LoggerService.warning(
          '[NoteIndex] Figure image at $path could not be prepared for '
          'chunk ${gap.chunkId} (undecodable or over the '
          '$kMaxEmbedDecodePixels px decode budget) — embedding its text',
        );
        return (input: null, unusable: true);
      }
      return (
        input: EmbeddingInput.image(prepared.bytes, prepared.mimeType),
        unusable: false,
      );
    } catch (e) {
      LoggerService.warning(
        '[NoteIndex] Figure image unavailable for chunk ${gap.chunkId} '
        '($e) — embedding its text instead',
      );
      return (input: null, unusable: false);
    }
  }

  /// Pixel budget for ONE image decoded on the embed path — the raster
  /// sibling of [FigureRegionExtractor.kMaxRenderPixels], and needed for the
  /// same reason: a decode is a single up-front allocation the process either
  /// gets or dies for, so it must be bounded BEFORE it is attempted, not
  /// wrapped in a try/catch.
  ///
  /// Unlike a PDF crop (which the extractor already caps at 8 MP), the input
  /// here can be the user's ORIGINAL camera file. `package:image` decodes to
  /// 32-bit RGBA regardless of source depth, and `copyResize` bakes EXIF
  /// orientation into a SECOND full-size copy first, so peak ≈ pixels × 8
  /// bytes: a 48 MP phone photo would ask for ~390 MB inside the compute
  /// isolate and a 108 MP one ~870 MB. Neither is catchable — it is a kill.
  ///
  /// 16 MP admits every mainstream phone camera default (a 12 MP sensor
  /// writes 4032×3024 = 12.2 MP), scans, and screenshots at a bounded ~128 MB
  /// peak; larger files fall back to embedding the figure's TEXT, which is
  /// still lexically and semantically findable. The gap scan records that
  /// fallback so it is paid for once, not once per sweep.
  @visibleForTesting
  static const int kMaxEmbedDecodePixels = 16000000;

  /// Test hook for the budget measurement: the pixel count the embed path
  /// would have to materialize for [bytes], read from the image HEADER (null
  /// when no decoder recognizes them).
  @visibleForTesting
  static int? debugDecodedPixelCount(Uint8List bytes) =>
      _decodedPixelCount(bytes);

  Future<String?> _figureImagePath(_EmbedGap gap) async {
    final meta = _decodeMetadata(gap.meta);
    final derived = (meta?['derivedAssetPath'] as String?)?.trim();
    if (derived != null && derived.isNotEmpty) {
      // Stored relative to the app documents dir; absolute paths are used
      // as-is (same rule as FigureResolver).
      return derived.startsWith('/')
          ? derived
          : FileUtils.getFullFilePath(derived, true);
    }
    // A raster image attachment's figure chunk carries no crop: the file IS
    // the image. SVG deliberately falls through to the text path.
    final fileName = gap.attachmentFileName;
    final filePath = gap.attachmentFilePath;
    if (fileName == null || filePath == null) return null;
    if (!_isEmbeddableRasterName(fileName)) return null;
    return FileUtils.getFullFilePath(filePath, gap.attachmentIsRelativePath);
  }

  /// Which raster attachment file can BE the image input of its own figure
  /// chunk. Same list as everything else in the pipeline — see
  /// [AttachmentOcrExtractor.kRasterImageExtensions].
  static bool _isEmbeddableRasterName(String fileName) =>
      AttachmentOcrExtractor.isRasterImageFileName(fileName);

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  /// Stores one batch of vectors (float32 LE, already L2-normalized by the
  /// provider) in a single transaction, clearing any per-chunk error states
  /// they supersede. Returns the committed count, or null when cancelled.
  /// Rows edited, deleted, moved or excluded during the provider call are
  /// discarded after checking their current identity, hash and policy.
  ///
  /// A figure that fell back to text because its image file is present but
  /// UNUSABLE gets a 'skipped' chunk-scoped state row instead of the usual
  /// clear, so [_scanFigureModalityUpgradeIds] stops re-offering it (it would
  /// otherwise re-embed the same text, for a provider call per sweep,
  /// forever). Same transaction as the vector, so the two can never disagree;
  /// the row dies with the chunk, and `backfillAll(force: true)` clears it.
  Future<int?> _writeEmbeddingBatch(
    String providerKey,
    List<_EmbedGap> batch,
    List<Float32List> vectors,
    List<_PreparedEmbedInput> prepared,
    String stage, {
    required int generation,
  }) async {
    if (_paused || _deletingEmbeddings || generation != _embedGeneration) {
      return null;
    }
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final committed = <int>[];
    await db.transaction((txn) async {
      final current = {
        for (final gap in await _loadEmbedGapBatch(txn, [
          for (final gap in batch) gap.chunkId,
        ]))
          gap.chunkId: gap,
      };
      for (var i = 0; i < batch.length; i++) {
        final gap = batch[i];
        final live = current[gap.chunkId];
        if (live == null ||
            live.chunkKey != gap.chunkKey ||
            live.contentHash != gap.contentHash) {
          continue;
        }
        final vector = vectors[i];
        final input = i < prepared.length ? prepared[i] : null;
        await txn.insert('chunk_embeddings', {
          'chunkId': gap.chunkId,
          'providerKey': providerKey,
          'modality': input?.modality ?? 'text',
          'dims': vector.length,
          'vector': encodeVectorFloat32Le(vector),
          'contentHash': gap.contentHash,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        committed.add(i);
        if (input?.imageUnusable ?? false) {
          await txn.insert('search_index_state', {
            'scopeType': 'chunk',
            'scopeId': '${gap.chunkId}',
            'stage': stage,
            'contentHash': gap.contentHash,
            'status': statusSkipped,
            'errorMessage': 'Figure image unusable; embedded as text',
            'updatedAt': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          continue;
        }
        await txn.delete(
          'search_index_state',
          where: "scopeType = 'chunk' AND scopeId = ? AND stage = ?",
          whereArgs: ['${gap.chunkId}', stage],
        );
      }
    });
    // Apply only committed rows while still on the write queue, before a
    // following chunk mutation can remove or replace their vectors.
    for (final i in committed) {
      _vectorSearch?.upsert(providerKey, batch[i].chunkId, vectors[i]);
    }
    return committed.length;
  }

  /// Records per-chunk permanent-error states for [batch] (keyed to each
  /// chunk's current contentHash so gap scans skip them until it changes).
  Future<int> _writeChunkEmbedErrors(
    List<_EmbedGap> batch,
    String stage,
    String errorMessage,
  ) async {
    if (_paused) return 0;
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    var recorded = 0;
    await db.transaction((txn) async {
      final current = {
        for (final gap in await _loadEmbedGapBatch(txn, [
          for (final gap in batch) gap.chunkId,
        ]))
          gap.chunkId: gap,
      };
      for (final gap in batch) {
        final live = current[gap.chunkId];
        if (live == null ||
            live.chunkKey != gap.chunkKey ||
            live.contentHash != gap.contentHash) {
          continue;
        }
        await txn.insert('search_index_state', {
          'scopeType': 'chunk',
          'scopeId': '${gap.chunkId}',
          'stage': stage,
          'contentHash': gap.contentHash,
          'status': statusError,
          'errorMessage': errorMessage,
          'updatedAt': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        recorded++;
      }
    });
    return recorded;
  }

  Future<void> _writeEmbedGlobalRow(
    Database db,
    String stage,
    String status, {
    String? errorMessage,
  }) {
    return db
        .insert('search_index_state', {
          'scopeType': 'global',
          'scopeId': 'all',
          'stage': stage,
          'contentHash': null,
          'status': status,
          'errorMessage': errorMessage,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace)
        .then((_) {});
  }

  /// Promote [providerKey] — the key whose pass just finished — to serving
  /// (plan §2.3 atomic switch), then lazily GC the superseded keys' rows.
  ///
  /// The registry refuses the promotion when [providerKey] is no longer the
  /// active one (the user switched again while this pass ran) or when it was
  /// revoked. NOTHING is GCd then: the rows of whatever is still serving —
  /// and of the key now backfilling — must survive.
  Future<void> _maybePromoteServing(
    EmbeddingProviderRegistry registry,
    String providerKey,
  ) async {
    if (registry.servingProviderKey == providerKey) return;
    final result = await registry.promoteActiveToServing(providerKey);
    if (!result.promoted) return;
    await _serialized(() => _gcEmbeddingsExcept({providerKey}));
    final previousKey = result.previousKey;
    if (previousKey != null) {
      _vectorSearch?.invalidate(previousKey);
    }
  }

  /// Deletes stored vectors (and embed state rows) of every providerKey NOT
  /// in [keepKeys] — the lazy GC after a completed provider switch.
  Future<void> _gcEmbeddingsExcept(Set<String> keepKeys) async {
    final db = await _db.database;
    final keyPlaceholders = List.filled(keepKeys.length, '?').join(',');
    await db.rawDelete(
      'DELETE FROM chunk_embeddings WHERE providerKey NOT IN '
      '($keyPlaceholders)',
      [...keepKeys],
    );
    await db.rawDelete(
      "DELETE FROM search_index_state WHERE stage LIKE 'embed:%' "
      'AND stage NOT IN ($keyPlaceholders)',
      [for (final key in keepKeys) stageEmbed(key)],
    );
  }

  /// Explicit "Delete stored embeddings" (plan §2.3, Step 10's button):
  /// removes ALL stored vectors and embed state for every providerKey and
  /// clears the in-memory vector index.
  ///
  /// It then turns the embedding provider OFF: consent is withdrawn for
  /// every providerKey that had vectors (and for the active one), and the
  /// registry is reset to "None (lexical only)". This is the plan's
  /// privacy/storage escape hatch — leaving the provider active would make
  /// the very next completeness sweep re-upload the entire corpus, unpaid
  /// for by any fresh consent, and every search in between would bill a
  /// query embedding against an empty matrix. Semantic search comes back
  /// only when the user picks a provider again (and re-consents).
  ///
  /// Self-contained on purpose: the guarantee holds whether or not the
  /// caller also invokes [EmbeddingProviderRegistry.clearActiveConfig].
  Future<void> deleteStoredEmbeddings() async {
    _embedGeneration++;
    _deletingEmbeddings = true;
    try {
      await _deleteStoredEmbeddingsNow();
    } finally {
      _deletingEmbeddings = false;
    }
  }

  Future<void> _deleteStoredEmbeddingsNow() async {
    final registry = _embeddingRegistry;
    final revokeKeys = <String>{};
    await _serialized(() async {
      final db = await _db.database;
      final keyRows = await db.rawQuery(
        'SELECT DISTINCT providerKey FROM chunk_embeddings',
      );
      revokeKeys.addAll([
        for (final row in keyRows) row['providerKey'] as String,
      ]);
      await db.delete('chunk_embeddings');
      await db.delete('search_index_state', where: "stage LIKE 'embed:%'");
      _vectorSearch?.reset();
    });
    if (registry == null) return;
    await registry.ensureInitialized();
    final activeKey = registry.activeConfig?.providerKey;
    if (activeKey != null) revokeKeys.add(activeKey);
    final servingKey = registry.servingProviderKey;
    if (servingKey != null) revokeKeys.add(servingKey);
    for (final key in revokeKeys) {
      try {
        await _embedConsentRevoke(key);
      } catch (e) {
        LoggerService.error(
          '[NoteIndex] Could not withdraw embedding consent for $key: $e',
          error: e,
        );
      }
    }
    await registry.clearActiveConfig();
  }

  /// Clears sticky embed halts (recorded auth/permanent errors on the
  /// global embed rows) AND the per-chunk permanent-error rows, then re-runs
  /// the backfill check. Step 10's Retry button — and its post-key-fix hook —
  /// call this.
  ///
  /// Both scopes are required for Retry to do anything visible. The gap scan
  /// skips a chunk that has a 'chunk'-scoped error row whose contentHash
  /// still matches, so clearing only the global row re-runs a pass that finds
  /// no gaps: the chunks never re-embed and settings keeps showing "N chunks
  /// could not be embedded" forever (only a forced rebuild cleared them).
  /// Retry is an explicit user gesture, so — like the forced rebuild — it
  /// clears the error rows of EVERY embed stage, not just the active key's:
  /// the method takes no providerKey, the global delete already spans all
  /// keys, and a key mid-transition must not keep stale failures.
  Future<void> retryEmbedIndexing() async {
    final db = await _db.database;
    await db.delete(
      'search_index_state',
      where:
          "scopeType = 'global' AND scopeId = 'all' AND stage LIKE 'embed:%' "
          'AND status = ?',
      whereArgs: [statusError],
    );
    await db.delete(
      'search_index_state',
      where: "scopeType = 'chunk' AND stage LIKE 'embed:%' AND status = ?",
      whereArgs: [statusError],
    );
    // backfillAll, not ensureBackfilled: after per-chunk failures the pass
    // itself COMPLETED (global row done, key promoted to serving), so the
    // completeness predicate is satisfied and would short-circuit the sweep
    // — leaving the just-cleared chunks unembedded. The pass is a no-op for
    // chunks that already have a current vector.
    await backfillAll();
  }

  // ── Halt-kind encoding ───────────────────────────────────────────────────
  //
  // EmbeddingProviderException carries TYPED halt reasons (isAuthError /
  // isNotInstalled / detectedDimensions) that only exist at the throw site;
  // search_index_state stores prose. Persisting the prose alone forced the
  // settings screen to string-match English error text, which mislabelled
  // both directions: a local provider missing its download URLs ("… is
  // missing its model/tokenizer download URLs") matched no pattern and
  // offered an inert Retry instead of "Download model", while a 5xx whose
  // response BODY echoed "unauthorized" read as an auth halt.
  //
  // The fix is migration-free: the stored errorMessage of a HALT is prefixed
  // with a stable code and a single '|' — "auth|…", "not_installed|…",
  // "dims|…" — and anything else is stored unprefixed. [parseEmbedHalt]
  // splits it back apart; [embedStageState] hands the raw (prefixed) string
  // to the UI, which parses it instead of matching prose. Per-chunk error
  // rows are never prefixed: they are not halts and carry no typed kind.

  /// Halt kind: 401/403 — the key must be fixed; retrying only burns quota.
  static const String embedHaltAuth = 'auth';

  /// Halt kind: a local provider's on-device model files are not installed
  /// (offer a download, not a retry).
  static const String embedHaltNotInstalled = 'not_installed';

  /// Halt kind: the endpoint's vector length differs from the configured
  /// `dimensions`.
  static const String embedHaltDims = 'dims';

  static const Set<String> _embedHaltKinds = {
    embedHaltAuth,
    embedHaltNotInstalled,
    embedHaltDims,
  };

  /// Encodes a halting [EmbeddingProviderException] for storage: its typed
  /// reason as a `kind|` prefix on the message (no prefix for a kind-less
  /// halt). Visible for the tests that pin the persisted format.
  @visibleForTesting
  static String encodeEmbedHalt(EmbeddingProviderException e) {
    final kind = e.isAuthError
        ? embedHaltAuth
        : e.isNotInstalled
        ? embedHaltNotInstalled
        : e.detectedDimensions != null
        ? embedHaltDims
        : null;
    return kind == null ? e.message : '$kind|${e.message}';
  }

  /// Splits a stored halt [errorMessage] into its machine-readable [kind]
  /// ([embedHaltAuth] / [embedHaltNotInstalled] / [embedHaltDims], or null
  /// when the halt had no typed reason) and the human-readable [message]
  /// with the prefix removed — what the UI should display.
  ///
  /// Only the three known codes count as a prefix, so a prose message that
  /// merely contains a '|' is returned untouched, as is a message persisted
  /// before this encoding existed.
  static ({String? kind, String message}) parseEmbedHalt(String? errorMessage) {
    final stored = errorMessage ?? '';
    final separator = stored.indexOf('|');
    if (separator <= 0) return (kind: null, message: stored);
    final kind = stored.substring(0, separator);
    if (!_embedHaltKinds.contains(kind)) return (kind: null, message: stored);
    return (kind: kind, message: stored.substring(separator + 1));
  }

  /// Embed-stage state for the settings surface (plan §2.2 error surfacing):
  /// the global row's status/errorMessage plus the number of chunks with a
  /// recorded permanent error. `status` is null when the stage never ran.
  /// A status of [statusError] means the pass HALTED (bad key / model not
  /// installed / dims mismatch) — settings shows the message with a Retry
  /// that calls [retryEmbedIndexing].
  ///
  /// `errorMessage` of a halt is the RAW stored value, i.e. it carries the
  /// `kind|` prefix described above. Callers must run it through
  /// [parseEmbedHalt] to branch on the kind and to get displayable prose.
  Future<({String? status, String? errorMessage, int failedChunks})>
  embedStageState(String providerKey) async {
    final db = await _db.database;
    final stage = stageEmbed(providerKey);
    final globalRows = await db.query(
      'search_index_state',
      columns: ['status', 'errorMessage'],
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stage],
    );
    final failedRows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM search_index_state WHERE scopeType = 'chunk' "
      'AND stage = ? AND status = ?',
      [stage, statusError],
    );
    return (
      status: globalRows.isEmpty ? null : globalRows.first['status'] as String?,
      errorMessage: globalRows.isEmpty
          ? null
          : globalRows.first['errorMessage'] as String?,
      failedChunks: (failedRows.first['c'] as int?) ?? 0,
    );
  }

  /// Coverage counts for the settings subtitle ("Switching to B — 40%
  /// re-indexed"): chunks with a current embedding for [providerKey] out of
  /// all chunks. Approximate on purpose (policy-excluded chunks count in the
  /// denominator).
  Future<({int embedded, int total})> embedCoverage(String providerKey) async {
    final db = await _db.database;
    final totalRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM search_chunks',
    );
    final embeddedRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM search_chunks c '
      'JOIN chunk_embeddings e ON e.chunkId = c.id '
      'AND e.providerKey = ? AND e.contentHash = c.contentHash',
      [providerKey],
    );
    return (
      embedded: (embeddedRows.first['c'] as int?) ?? 0,
      total: (totalRows.first['c'] as int?) ?? 0,
    );
  }

  // ── Backfill ─────────────────────────────────────────────────────────────

  /// Indexes every note, resumably: notes whose stored state fingerprint
  /// matches are skipped (their rows and state timestamps stay untouched).
  /// Chunking + normalization run in compute() batches off the main isolate;
  /// database writes happen on the main isolate, one transaction per note.
  ///
  /// On full completion the global flag search_index_state('global','all',
  /// 'chunks') is set to done; policy-excluded notes count as done. [force]
  /// clears the global flag first and re-diffs every note regardless of
  /// stored fingerprints (a rebuild that still no-ops unchanged chunks).
  Future<void> backfillAll({bool force = false}) {
    final running = _backfill;
    if (running != null) {
      if (!force) return running;
      // A forced request must not degrade to the in-flight (non-forced) run:
      // latch a forced pass to start after it completes. Concurrent force
      // requests share the same follow-up; the caller's future resolves after
      // the FORCED pass finishes.
      return _forcedFollowUp ??= running
          .then<void>((_) {}, onError: (_) {})
          .then((_) {
            _forcedFollowUp = null;
            return backfillAll(force: true);
          });
    }
    final run = _runBackfill(force: force).whenComplete(() {
      _backfill = null;
    });
    _backfill = run;
    return run;
  }

  Future<void> _runBackfill({required bool force}) async {
    if (_paused) return;
    final db = await _db.database;

    if (force) {
      await db.delete(
        'search_index_state',
        where:
            "scopeType = 'global' AND scopeId = 'all' AND stage IN (?, ?, ?, ?)",
        whereArgs: [stageChunks, stagePdfText, stageOcr, stageFigures],
      );
      // Embed stage: clear global flags (incl. sticky auth-halt rows) and
      // per-chunk permanent-error states so a rebuild retries them. Stored
      // vectors with matching contentHash are NOT re-embedded (the gap scan
      // skips them — a rebuild that still no-ops unchanged chunks).
      await db.delete(
        'search_index_state',
        where:
            "scopeType = 'global' AND scopeId = 'all' AND stage LIKE 'embed:%'",
      );
      await db.delete(
        'search_index_state',
        where: "scopeType = 'chunk' AND stage LIKE 'embed:%'",
      );
    }

    // Raw-SQL deletes can orphan chunks without ever firing a hook.
    await _purgeOrphanRows(db);

    // Budget the complete text that getNotesByIds + the annotation loader
    // will materialize, not only notes.content. Imported notes often keep
    // most of their text in subnotes or PDF annotations. Pre-aggregated
    // joins avoid a correlated child-table scan for every note.
    final idRows = await db.rawQuery('''
      SELECT n.id,
        COALESCE(length(CAST(n.content AS BLOB)), 0) +
        COALESCE(length(CAST(n.title AS BLOB)), 0) +
        COALESCE(length(CAST(n.metadata AS BLOB)), 0) +
        COALESCE(s.sourceLength, 0) + COALESCE(ann.sourceLength, 0)
          AS contentLength
      FROM notes n
      LEFT JOIN (
        SELECT noteId,
          SUM(length(CAST(content AS BLOB)) + length(CAST(name AS BLOB)))
            AS sourceLength
        FROM subnotes WHERE __deleted__ = 0 GROUP BY noteId
      ) s ON s.noteId = n.id
      LEFT JOIN (
        SELECT noteId, SUM(sourceLength) AS sourceLength FROM (
          SELECT note_id AS noteId, length(CAST(content AS BLOB)) AS sourceLength
          FROM note_annotations WHERE note_id IS NOT NULL
          UNION ALL
          SELECT a.noteId, length(CAST(ann.content AS BLOB)) AS sourceLength
          FROM note_annotations ann
          JOIN attachments a ON a.id = ann.attachment_id
          WHERE a.__deleted__ = 0
            AND (ann.note_id IS NULL OR ann.note_id <> a.noteId)
        ) GROUP BY noteId
      ) ann ON ann.noteId = n.id
      WHERE n.__deleted__ = 0
    ''');
    final noteIds = [for (final row in idRows) row['id'] as String];
    final contentLengths = {
      for (final row in idRows)
        row['id'] as String: (row['contentLength'] as int?) ?? 0,
    };

    debugBackfillLargestBatchBytes = 0;
    var done = 0;
    var failed = 0;
    // Notes left to a fresher pending debounced reindex: their state stays
    // untouched and they must NOT count towards the global flag this round.
    var deferred = 0;
    var total = noteIds.length;
    // Stage/unit shown by the finally-block progress update: the pdf_text
    // and ocr passes (which run after the chunk pass) advance them.
    var stage = stageChunks;
    var unit = 'notes';
    _progress.value = IndexProgress(
      done: 0,
      total: total,
      stage: stageChunks,
      running: true,
    );

    try {
      for (final batchIds in planBackfillBatches(noteIds, contentLengths)) {
        if (_paused) return;
        debugBackfillLargestBatchBytes = math.max(
          debugBackfillLargestBatchBytes,
          batchIds.fold<int>(0, (sum, id) => sum + contentLengths[id]!),
        );

        final stateByNoteId = await _loadNoteStates(db, batchIds);
        final metadataRows = await readSyncRowsWhere(
          db,
          table: 'notes',
          columns: ['id', 'metadata'],
          keyColumns: ['id'],
          where: 'id IN (${List.filled(batchIds.length, '?').join(',')})',
          whereArgs: batchIds,
        );
        final metadataById = {
          for (final row in metadataRows)
            row['id'] as String: _decodeMetadata(row['metadata'] as String?),
        };
        final notes = await _db.getNotesByIds(batchIds);
        final notesById = {for (final note in notes) note.id: note};
        final annotationsByNoteId = await _loadAnnotationsForNotes(batchIds);

        final inputs = <_BackfillInput>[];
        final snapshotHashByNoteId = <String, String?>{};
        for (final noteId in batchIds) {
          if (_paused) return;
          final note = notesById[noteId];
          if (note == null) {
            // Deleted between listing and load; the orphan purge on the next
            // sweep clears any leftovers.
            done++;
            continue;
          }
          if (isNoteSearchExcluded(metadataById[noteId])) {
            final state = stateByNoteId[noteId];
            final alreadySkipped =
                !force &&
                state != null &&
                state.status == statusSkipped &&
                state.contentHash == _excludedFingerprint;
            if (alreadySkipped) {
              done++;
            } else {
              try {
                await _serialized(() => _purgeToSkipped(noteId));
                done++;
              } catch (e) {
                failed++;
                await _markNoteError(db, noteId, e);
              }
            }
            continue;
          }
          if (_debounceTimers.containsKey(noteId)) {
            // An edit is pending; the debounced reindex owns this note.
            deferred++;
            continue;
          }
          final state = stateByNoteId[noteId];
          snapshotHashByNoteId[noteId] = state?.contentHash;
          inputs.add(
            _BackfillInput(
              note: note,
              annotations: annotationsByNoteId[noteId] ?? [],
              indexedFingerprint: !force && state?.status == statusDone
                  ? state?.contentHash
                  : null,
            ),
          );
        }
        _progress.value = IndexProgress(
          done: done,
          total: total,
          stage: stageChunks,
          running: true,
        );

        if (inputs.isEmpty) continue;
        final outputs = await compute(_chunkNotesBatch, inputs);
        debugBackfillNotesChunked += outputs.where((o) => !o.unchanged).length;

        for (final output in outputs) {
          if (_paused) return;
          if (_debounceTimers.containsKey(output.noteId)) {
            // An edit landed after this batch's snapshot; the pending
            // debounced reindex will write the fresher content instead.
            deferred++;
          } else if (output.unchanged) {
            done++;
          } else {
            try {
              await _serialized(
                () => _writeChunks(
                  output.noteId,
                  output.drafts,
                  output.normalized,
                  output.fingerprint,
                  // The debounce timer can also have already FIRED: its
                  // reindex then races this batch write on the serialized
                  // queue. The guard aborts this write if a fresher one
                  // landed after the snapshot.
                  guardSnapshot: true,
                  snapshotStateHash: snapshotHashByNoteId[output.noteId],
                ),
              );
              done++;
            } catch (e) {
              failed++;
              await _markNoteError(db, output.noteId, e);
            }
          }
          _progress.value = IndexProgress(
            done: done,
            total: total,
            stage: stageChunks,
            running: true,
          );
        }
      }

      if (!_paused && failed == 0 && deferred == 0) {
        await db.insert('search_index_state', {
          'scopeType': 'global',
          'scopeId': 'all',
          'stage': stageChunks,
          'contentHash': null,
          'status': statusDone,
          'errorMessage': null,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else if (!_paused && failed == 0 && deferred > 0) {
        // Completeness must still converge: re-check after the pending
        // debounced writes have had time to land.
        Timer(debounceDelay * 2, () {
          unawaited(
            ensureBackfilled().catchError((Object e) {
              LoggerService.error(
                '[NoteIndex] Deferred completeness re-check failed: $e',
                error: e,
              );
            }),
          );
        });
      }

      // pdf_text pass — AFTER the 'chunks' global flag is written, so
      // phase-1 completeness (which gates the substring fallback) is never
      // blocked by PDF extraction. Runs regardless of chunk-stage failures:
      // the layers are independent (see the pdf_text stage comment).
      if (!_paused) {
        final pdf = await _runPdfTextBackfill(db, force: force);
        if (pdf != null && pdf.total > 0) {
          // With zero PDF attachments the chunk-stage stats remain the
          // final progress (no 0/0 pdf_text flash).
          stage = stagePdfText;
          unit = 'attachments';
          done = pdf.done;
          total = pdf.total;
        }
      }

      // ocr pass — after pdf_text so the merge policy dedupes against fresh
      // attachment_text chunks. Same independence: neither the chunks nor
      // the pdf_text flag ever waits on OCR.
      if (!_paused) {
        final ocr = await _runOcrBackfill(db, force: force);
        if (ocr != null && ocr.total > 0) {
          stage = stageOcr;
          unit = 'pages';
          done = ocr.done;
          total = ocr.total;
        }
      }

      // figures pass — after ocr so region inference reads fresh
      // `attachment_ocr` bounds. Same independence: neither the chunks, the
      // pdf_text nor the ocr flag ever waits on figures.
      if (!_paused) {
        final figures = await _runFiguresBackfill(db, force: force);
        if (figures != null && figures.total > 0) {
          stage = stageFigures;
          unit = 'attachments';
          done = figures.done;
          total = figures.total;
        }
      }

      // embed pass — last, so it sees every chunk the earlier stages wrote
      // this round. Serialized on the embed queue (never concurrent with a
      // per-note embed pass); its writes ride the write queue internally.
      if (!_paused) {
        final embed = await _embedSerialized(
          () => _runEmbedPass(scopeNoteId: null, force: force),
        );
        if (embed.total > 0 && embed.stage != null) {
          stage = embed.stage!;
          unit = 'chunks';
          done = embed.done;
          total = embed.total;
        }
      }
    } finally {
      _progress.value = IndexProgress(
        done: done,
        total: total,
        stage: stage,
        unit: unit,
        running: false,
      );
    }
  }

  /// Resumable pdf_text pass over every PDF attachment (state-hash skip for
  /// unchanged ones). Sets ('global','all','pdf_text') = done — with
  /// [_pdfTextPolicyHash] as its contentHash — when the pass visited every
  /// attachment: skipped states — policy off, note excluded, over the cap —
  /// count as done (mirroring the chunk stage's policy-exclusion accounting),
  /// and recorded extraction-error states count too (they are stable,
  /// inspectable rows; only an unexpected exception blocks the flag). Returns
  /// its (done,total) counts, or null when it bailed out early (paused).
  Future<({int done, int total})?> _runPdfTextBackfill(
    Database db, {
    required bool force,
  }) async {
    // Captured BEFORE the pass, written after it (as ocr/figures do): a cap
    // change landing mid-pass must leave a hash that no longer matches, so the
    // next sweep re-evaluates the attachments this one processed under the old
    // cap.
    final policyHash = await _pdfTextPolicyHash();
    final work = await loadIndexAttachments(
      db,
      eligibleFileNameSql: "a.fileName LIKE '%.pdf'",
    );

    var done = 0;
    var failed = 0;
    final total = work.length;
    if (total > 0) {
      _progress.value = IndexProgress(
        done: 0,
        total: total,
        stage: stagePdfText,
        unit: 'attachments',
        running: true,
      );
    }

    for (final (attachment, noteExcluded) in work) {
      if (_paused) return null;
      try {
        await _serialized(
          () => _indexAttachmentPdfText(
            attachment,
            noteExcluded: noteExcluded,
            force: force,
          ),
        );
        done++;
      } catch (e) {
        failed++;
        LoggerService.error(
          '[NoteIndex] pdf_text backfill failed for ${attachment.id}: $e',
          error: e,
        );
      }
      _progress.value = IndexProgress(
        done: done,
        total: total,
        stage: stagePdfText,
        unit: 'attachments',
        running: true,
      );
    }

    if (!_paused && failed == 0) {
      // Aborted extractions only occur when paused, which returned above —
      // every attachment reached a terminal state this round.
      await db.insert('search_index_state', {
        'scopeType': 'global',
        'scopeId': 'all',
        'stage': stagePdfText,
        // Like the ocr/figures rows this one CARRIES a hash: the PDF settings
        // as of this completed pass (see [_pdfTextStageComplete]).
        'contentHash': policyHash,
        'status': statusDone,
        'errorMessage': null,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return (done: done, total: total);
  }

  /// Splits [noteIds] into compute() batches capped by BOTH a note count and
  /// a byte budget over content lengths, so batches of large notes stay
  /// small. A note larger than the whole budget still gets a batch of one.
  @visibleForTesting
  static List<List<String>> planBackfillBatches(
    List<String> noteIds,
    Map<String, int> contentLengths, {
    int maxNotes = _backfillBatchSize,
    int byteBudget = _backfillBatchByteBudget,
  }) {
    final batches = <List<String>>[];
    var current = <String>[];
    var currentBytes = 0;
    for (final noteId in noteIds) {
      final length = contentLengths[noteId] ?? 0;
      if (current.isNotEmpty &&
          (current.length >= maxNotes || currentBytes + length > byteBudget)) {
        batches.add(current);
        current = <String>[];
        currentBytes = 0;
      }
      current.add(noteId);
      currentBytes += length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  Future<void> _purgeOrphanRows(Database db) async {
    final orphanRows = await db.rawQuery(
      'SELECT DISTINCT noteId FROM search_chunks '
      'WHERE noteId NOT IN ($_liveNoteIdsSql)',
    );
    for (final row in orphanRows) {
      await _serialized(() => _removeNoteNow(row['noteId'] as String));
    }
    await db.rawDelete(
      "DELETE FROM search_index_state WHERE scopeType = 'note' "
      'AND scopeId NOT IN ($_liveNoteIdsSql)',
    );
    // Per-chunk embed error states whose chunk vanished via raw SQL, plus
    // orphaned embedding rows themselves.
    await db.rawDelete(
      "DELETE FROM search_index_state WHERE scopeType = 'chunk' "
      'AND scopeId NOT IN (SELECT CAST(id AS TEXT) FROM search_chunks)',
    );
    await db.rawDelete(
      'DELETE FROM chunk_embeddings '
      'WHERE chunkId NOT IN (SELECT id FROM search_chunks)',
    );
    // attachment_text chunks whose attachment vanished via raw SQL (or with
    // a cascaded note delete) or is no longer a PDF (raw-SQL rename), plus
    // their pdf_text state rows. LIKE '%.pdf' is ASCII-case-insensitive in
    // SQLite, mirroring AttachmentTextExtractor.isPdfAttachment.
    final orphanAttachmentChunks = await db.rawQuery(
      "SELECT id FROM search_chunks WHERE sourceType = 'attachment_text' "
      'AND sourceId NOT IN '
      "(SELECT id FROM attachments WHERE __deleted__ = 0 "
      "AND fileName LIKE '%.pdf')",
    );
    if (orphanAttachmentChunks.isNotEmpty) {
      final ids = [for (final row in orphanAttachmentChunks) row['id'] as int];
      final ftsAvailable = _db.chunksFtsAvailable;
      await _serialized(
        () => _transactionWithRemovals(
          db,
          (txn, removals) => _deleteChunkRowsById(
            txn,
            ids,
            ftsAvailable: ftsAvailable,
            removals: removals,
          ),
        ),
      );
    }
    // attachment_ocr chunks whose attachment vanished via raw SQL or is no
    // longer OCR-eligible (LIKE is ASCII-case-insensitive, mirroring
    // AttachmentOcrExtractor.isOcrEligible).
    final orphanOcrChunks = await db.rawQuery(
      "SELECT id FROM search_chunks WHERE sourceType = 'attachment_ocr' "
      'AND sourceId NOT IN '
      '(SELECT id FROM attachments WHERE __deleted__ = 0 '
      'AND ($_ocrEligibleFileNameSql))',
    );
    if (orphanOcrChunks.isNotEmpty) {
      final ids = [for (final row in orphanOcrChunks) row['id'] as int];
      final ftsAvailable = _db.chunksFtsAvailable;
      await _serialized(
        () => _transactionWithRemovals(
          db,
          (txn, removals) => _deleteChunkRowsById(
            txn,
            ids,
            ftsAvailable: ftsAvailable,
            removals: removals,
          ),
        ),
      );
    }
    // figure chunks whose attachment vanished via raw SQL or is no longer
    // figure-eligible; their derived crops go with them.
    final orphanFigureChunks = await db.rawQuery(
      "SELECT id, sourceId FROM search_chunks WHERE sourceType = 'figure' "
      'AND (sourceId IS NULL OR sourceId NOT IN '
      '(SELECT id FROM attachments WHERE __deleted__ = 0 '
      'AND ($_figureEligibleFileNameSql)))',
    );
    if (orphanFigureChunks.isNotEmpty) {
      final ids = [for (final row in orphanFigureChunks) row['id'] as int];
      final owners = {
        for (final row in orphanFigureChunks)
          if (row['sourceId'] != null) row['sourceId'] as String,
      };
      final ftsAvailable = _db.chunksFtsAvailable;
      await _serialized(
        () => _transactionWithRemovals(
          db,
          (txn, removals) => _deleteChunkRowsById(
            txn,
            ids,
            ftsAvailable: ftsAvailable,
            removals: removals,
          ),
        ),
      );
      await _deleteDerivedFigures(owners);
    }
    await db.rawDelete(
      "DELETE FROM search_index_state WHERE scopeType = 'attachment' "
      'AND scopeId NOT IN '
      '(SELECT id FROM attachments WHERE __deleted__ = 0)',
    );
    // pdf_text state of attachments renamed away from .pdf: the stage no
    // longer applies to them (their chunks were purged above).
    await db.rawDelete(
      "DELETE FROM search_index_state WHERE scopeType = 'attachment' "
      'AND stage = ? AND scopeId IN '
      "(SELECT id FROM attachments WHERE fileName NOT LIKE '%.pdf')",
      [stagePdfText],
    );
    // Same for ocr state of attachments no longer OCR-eligible.
    await db.rawDelete(
      "DELETE FROM search_index_state WHERE scopeType = 'attachment' "
      'AND stage = ? AND scopeId IN '
      '(SELECT id FROM attachments WHERE NOT ($_ocrEligibleFileNameSql))',
      [stageOcr],
    );
    // Same for figures state of attachments no longer figure-eligible.
    await db.rawDelete(
      "DELETE FROM search_index_state WHERE scopeType = 'attachment' "
      'AND stage = ? AND scopeId IN '
      '(SELECT id FROM attachments WHERE NOT ($_figureEligibleFileNameSql))',
      [stageFigures],
    );
  }

  /// Liveness predicates for the cloud-sync soft-delete model: `notes`,
  /// `subnotes` and `attachments` are tombstoned (`__deleted__ = 1`), never
  /// physically deleted, so "the row is still in the table" no longer means
  /// "the note/attachment still exists". Everywhere this file used to lean
  /// on row presence, it must lean on liveness instead — otherwise a deleted
  /// note keeps its chunks forever and stays searchable.
  ///
  /// [_liveRowsPredicate] closes the `attachments a JOIN notes n` enumerations
  /// the pdf_text/ocr/figures stages run; [_liveNoteIdsSql] is the id set the
  /// orphan sweep compares `search_chunks.noteId` against.
  ///
  /// [_liveAttachmentJoinFilter] closes the embed stage's four
  /// `LEFT JOIN attachments a ON a.id = c.sourceId` joins
  /// ([_scanEmbedGapIds], [_purgeEmbedPolicyViolations],
  /// [_scanFigureModalityUpgradeIds], [_loadEmbedGapBatch]). It belongs on the
  /// JOIN and not in the WHERE: these are OUTER joins whose non-attachment
  /// chunks must survive with a null `a` — a WHERE clause would drop every
  /// note chunk instead. Filtering here is what makes
  /// [_passesEmbedPolicy]'s null-`attachmentId` branch mean "no live
  /// attachment"; without it a deleted attachment's chunk text reaches the
  /// embedding provider, and the policy purge stops reclaiming its vectors.
  static const String _liveRowsPredicate =
      'WHERE a.__deleted__ = 0 AND n.__deleted__ = 0';
  static const String _liveNoteIdsSql =
      'SELECT id FROM notes WHERE __deleted__ = 0';
  static const String _liveAttachmentJoinFilter =
      'AND a.__deleted__ = 0 AND a.noteId = c.noteId';

  /// SQL predicate matching OCR-eligible fileNames (PDF + raster images).
  ///
  /// GENERATED from [AttachmentOcrExtractor.kRasterImageExtensions] rather
  /// than spelled out a second time: this predicate drives the orphan sweep,
  /// so a list that drifted from [AttachmentOcrExtractor.isOcrEligible] would
  /// have the sweep delete chunks the ocr stage immediately re-writes (or
  /// leave chunks no stage owns). The extensions are compile-time constants,
  /// never user input — nothing here is interpolated from data.
  static final String _ocrEligibleFileNameSql = [
    "fileName LIKE '%.pdf'",
    for (final ext in AttachmentOcrExtractor.kRasterImageExtensions)
      "fileName LIKE '%$ext'",
  ].join(' OR ');

  /// SQL predicate matching figure-eligible fileNames (OCR-eligible plus SVG,
  /// which gets a lexical-only figure chunk), kept in lockstep with
  /// [isFigureEligible].
  static final String _figureEligibleFileNameSql =
      "$_ocrEligibleFileNameSql OR fileName LIKE '%$_svgExtension'";

  Future<Map<String, _NoteChunkState>> _loadNoteStates(
    Database db,
    List<String> noteIds,
  ) async {
    if (noteIds.isEmpty) return {};
    final placeholders = List.filled(noteIds.length, '?').join(',');
    final rows = await db.query(
      'search_index_state',
      columns: ['scopeId', 'contentHash', 'status'],
      where: "scopeType = 'note' AND stage = ? AND scopeId IN ($placeholders)",
      whereArgs: [stageChunks, ...noteIds],
    );
    return {
      for (final row in rows)
        row['scopeId'] as String: _NoteChunkState(
          contentHash: row['contentHash'] as String?,
          status: row['status'] as String,
        ),
    };
  }

  Future<void> _markNoteError(Database db, String noteId, Object error) async {
    LoggerService.error(
      '[NoteIndex] Backfill failed for note $noteId: $error',
      error: error,
    );
    try {
      await db.insert('search_index_state', {
        'scopeType': 'note',
        'scopeId': noteId,
        'stage': stageChunks,
        'contentHash': null,
        'status': statusError,
        'errorMessage': '$error',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      LoggerService.error(
        '[NoteIndex] Failed to record error state for $noteId: $e',
        error: e,
      );
    }
  }

  static Map<String, dynamic>? _decodeMetadata(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Detach hooks, subscription, and timers. Tests only — the app-lifetime
  /// singleton is never disposed.
  @visibleForTesting
  void dispose() {
    _subscription.cancel();
    // pause() sets _paused and cancels timers synchronously; the drain await
    // is irrelevant here.
    unawaited(pause());
    _db.onNoteContentChanged = null;
    _db.onNoteDeleted = null;
    unawaited(_ocrExtractor.dispose());
    _progress.dispose();
  }
}

class _NoteChunkState {
  const _NoteChunkState({required this.contentHash, required this.status});
  final String? contentHash;
  final String status;
}

/// One hit of an embed gap scan: the chunk id plus whether it is a `figure`
/// chunk — the only kind that can become an IMAGE input, and therefore the
/// only kind whose count per batch has to be rationed (see
/// `NoteIndexService._buildEmbedBatches`).
typedef _EmbedGapId = ({int id, bool figure});

/// One chunk the embed gap scan found missing/stale for the active provider.
class _EmbedGap {
  const _EmbedGap({
    required this.chunkId,
    this.chunkKey = '',
    required this.text,
    required this.contentHash,
    this.sourceType = '',
    this.meta,
    this.attachmentFileName,
    this.attachmentFilePath,
    this.attachmentIsRelativePath = true,
  });
  final int chunkId;
  final String chunkKey;
  final String text;
  final String contentHash;

  /// Multimodal routing (only `figure` takes the image path).
  final String sourceType;
  final String? meta;

  /// Source attachment of a `figure` chunk, joined in by the batch load so a
  /// raster image can be embedded without a second query.
  final String? attachmentFileName;
  final String? attachmentFilePath;
  final bool attachmentIsRelativePath;
}

/// One provider input plus the modality it represents ('text' | 'image').
class _PreparedEmbedInput {
  const _PreparedEmbedInput(
    this.input,
    this.modality, {
    this.imageUnusable = false,
  });
  final EmbeddingInput input;
  final String modality;

  /// This is a TEXT input for a `figure` chunk whose image file exists but
  /// cannot be turned into an image input (over the decode budget, corrupt).
  /// Recorded by `NoteIndexService._writeEmbeddingBatch` so the modality
  /// upgrade scan stops re-offering it — see
  /// `NoteIndexService._scanFigureModalityUpgradeIds`.
  final bool imageUnusable;
}

class _ImageEmbedRequest {
  const _ImageEmbedRequest({
    required this.bytes,
    required this.extension,
    required this.maxSide,
    required this.maxDecodePixels,
  });
  final Uint8List bytes;
  final String extension;
  final int maxSide;

  /// Hard ceiling on width × height (see
  /// [NoteIndexService.kMaxEmbedDecodePixels]).
  final int maxDecodePixels;
}

class _ImageEmbedResult {
  const _ImageEmbedResult(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

/// Top-level for compute(): decode, downscale to [_ImageEmbedRequest.maxSide]
/// on the longest side, re-encode. Runs off the main isolate because pure-Dart
/// decode+resize of a 3x figure crop is tens of milliseconds of solid CPU and
/// the indexer must never stutter the UI.
///
/// Images already within the budget are passed through UNTOUCHED (no
/// re-encode): the crop is already a PNG the provider accepts, and a
/// needless round-trip would only cost bytes and fidelity.
///
/// Returns null when the bytes are not a decodable image OR when decoding
/// them would exceed [_ImageEmbedRequest.maxDecodePixels]. The size test runs
/// on the HEADER — `startDecode` parses dimensions without materializing
/// pixels — because the whole point is to not perform the allocation that
/// would kill the process; a try/catch around `decodeImage` cannot help with
/// an OOM.
_ImageEmbedResult? _downscaleForEmbedding(_ImageEmbedRequest request) {
  final pixels = _decodedPixelCount(request.bytes);
  if (pixels == null || pixels > request.maxDecodePixels) return null;
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null) return null;
  final longest = math.max(decoded.width, decoded.height);
  if (longest <= 0) return null;
  final mimeType = _imageMimeForExtension(request.extension);
  if (longest <= request.maxSide) {
    return _ImageEmbedResult(request.bytes, mimeType);
  }
  final scale = request.maxSide / longest;
  final resized = img.copyResize(
    decoded,
    width: math.max(1, (decoded.width * scale).round()),
    height: math.max(1, (decoded.height * scale).round()),
    interpolation: img.Interpolation.average,
  );
  switch (request.extension) {
    case 'jpg':
    case 'jpeg':
      return _ImageEmbedResult(
        img.encodeJpg(resized, quality: 85),
        'image/jpeg',
      );
    default:
      // PNG for crops (lossless, and what renderRegion already wrote) and for
      // webp, which package:image decodes but cannot encode.
      return _ImageEmbedResult(img.encodePng(resized), 'image/png');
  }
}

/// Pixels [bytes] would decode to, read from the image HEADER: `startDecode`
/// parses dimensions without materializing a single pixel. Null when no
/// decoder recognizes the bytes or the header is degenerate.
int? _decodedPixelCount(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null) return null;
  final info = decoder.startDecode(bytes);
  if (info == null || info.width <= 0 || info.height <= 0) return null;
  return info.width * info.height;
}

String _imageMimeForExtension(String extension) {
  switch (extension) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    default:
      return 'image/png';
  }
}

class _BackfillInput {
  const _BackfillInput({
    required this.note,
    required this.annotations,
    this.indexedFingerprint,
  });
  final Note note;
  final List<NoteAnnotation> annotations;
  final String? indexedFingerprint;
}

class _BackfillOutput {
  const _BackfillOutput({
    required this.noteId,
    required this.fingerprint,
    required this.drafts,
    required this.normalized,
    this.unchanged = false,
  });
  final String noteId;
  final String fingerprint;
  final List<ChunkDraft> drafts;
  final List<String> normalized;
  final bool unchanged;
}

/// Top-level for compute(): fingerprint, skip unchanged sources, then chunk
/// and normalize off the UI isolate. Large notes are hashed only once even
/// on their first upgrade pass; repeat sweeps do not rechunk them.
List<_BackfillOutput> _chunkNotesBatch(List<_BackfillInput> inputs) {
  return [
    for (final input in inputs)
      () {
        final fingerprint = noteContentFingerprint(
          input.note,
          input.annotations,
        );
        if (fingerprint == input.indexedFingerprint) {
          return _BackfillOutput(
            noteId: input.note.id,
            fingerprint: fingerprint,
            drafts: const [],
            normalized: const [],
            unchanged: true,
          );
        }
        final drafts = chunkNote(input.note, annotations: input.annotations);
        return _BackfillOutput(
          noteId: input.note.id,
          fingerprint: fingerprint,
          drafts: drafts,
          normalized: [for (final d in drafts) normalizeForIndex(d.text)],
        );
      }(),
  ];
}

/// Fingerprint of everything that feeds a note's chunks (title, content,
/// tags, subnotes, annotations). Stored in search_index_state.contentHash so
/// reindex/backfill can skip notes whose indexed content is already current.
String noteContentFingerprint(Note note, List<NoteAnnotation> annotations) {
  // U+0000 separates records, U+0001 separates fields within a record, so
  // adjacent fields can never collide by concatenation.
  final buffer = StringBuffer()
    ..write(note.title)
    ..write('\u0000')
    ..write(note.content)
    ..write('\u0000');
  final tags = [...note.tags]..sort();
  buffer
    ..write(tags.join('\u0001'))
    ..write('\u0000');
  for (final subNote in note.subNotes) {
    buffer
      ..write(subNote.id)
      ..write('\u0001')
      ..write(subNote.name)
      ..write('\u0001')
      ..write(subNote.content)
      ..write('\u0000');
  }
  final sortedAnnotations = [...annotations]
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final annotation in sortedAnnotations) {
    buffer
      ..write(annotation.id)
      ..write('\u0001')
      ..write(annotation.content)
      ..write('\u0000');
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}
