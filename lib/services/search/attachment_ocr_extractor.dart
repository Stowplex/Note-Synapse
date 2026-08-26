// On-device OCR extraction for the search index (plan §3, Step 12).
//
// OCR is a PRIMARY layer, not a "text layer too short" fallback: it runs over
// ALL pages of policy-permitted PDFs and over raster image attachments
// (png/jpg/webp — not SVG: ML Kit cannot OCR vector data), default ON
// (AttachmentSearchIndexConfig.ocr defaults true), toggleable per attachment.
// It is used BY NoteIndexService's 'ocr' stage; it never writes the database.
//
// Mirrors AttachmentTextExtractor's design: cheap policy gates first, every
// platform dependency behind an injectable seam (pdfrx render, ML Kit,
// battery, temp dir), abort between pages, results as ChunkDrafts.
//
// ML Kit input route (investigated, deliberate): rendered pages are PNG
// bytes. `InputImage.fromBytes` only accepts RAW camera-frame formats
// (nv21/bgra8888 + InputImageMetadata) and `InputImage.fromBitmap` wants raw
// RGBA bitmaps — both would force a full uncompressed copy across the
// platform channel (~4 bytes/px, tens of MB at 2x). `InputImage.fromFilePath`
// lets the OS decode the PNG natively and is the route the plugin documents
// for encoded images, so each rendered page is written to a temp file and
// recognized via fromFilePath (deleted immediately after). Raster image
// attachments already live on disk and are passed by path directly.
//
// Script selection policy (documented, pragmatic — never both recognizers
// unconditionally, that would double the battery cost of the whole backfill):
// one PRIMARY script per run, from SearchSettingsService.getOcrScript():
// 'latin' / 'chinese' explicit, or 'auto' (default) which picks Chinese when
// the device locale is zh, Latin otherwise. When the primary is Latin and a
// page yields NO text at all, the Chinese recognizer is tried once for that
// page (covers zh scans on non-zh devices at the cost of one extra pass only
// on Latin-empty pages). Known gap: Latin models can return mojibake instead
// of nothing on Chinese scans — the settings override is the escape hatch.
// The effective script is part of the ocr stage's state hash, so changing it
// re-runs OCR.
//
// Merge policy (text layer is authoritative): each OCR block's normalized
// tokens (normalizeForIndex — CJK bigrams included, so zh dedupe works) are
// checked against the page's `attachment_text` chunk text; a block whose
// token multiset is >= 70% contained in the page's text-layer tokens is
// suppressed. Only novel blocks become `attachment_ocr` chunks; their block
// bounds + render scales (renderScale horizontal, renderScaleY vertical —
// the raster axes round independently) are persisted in the chunk meta JSON
// for §4.1's figure-region inference.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:battery_plus/battery_plus.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../models/attachment.dart';
import '../database_service.dart';
import '../logger_service.dart';
import '../search_settings_service.dart';
import 'attachment_text_extractor.dart';
import 'note_chunker.dart';
import 'note_index_service.dart';
import 'search_text_normalizer.dart';

// ─── Script selection ───────────────────────────────────────────────────────

/// OCR script model. Only Latin and Chinese are wired (the app ships en/zh);
/// ML Kit also has devanagari/japanese/korean if ever needed.
enum OcrScript { latin, chinese }

/// Loads the effective primary script for an OCR run.
typedef OcrScriptLoader = Future<OcrScript> Function();

/// Default script policy: explicit setting wins; 'auto' follows the device
/// locale (zh → Chinese recognizer).
///
/// An unreadable settings store degrades to 'auto' rather than throwing
/// (same rationale as [loadOcrEnabled]: the effective script takes part in
/// the ocr stage's completeness check, so it is consulted on every sweep).
Future<OcrScript> loadDefaultOcrScript() async {
  String setting;
  try {
    setting = await SearchSettingsService().getOcrScript();
  } catch (e) {
    LoggerService.info('[AttachmentOcrExtractor] OCR script unknown: $e');
    setting = 'auto';
  }
  switch (setting) {
    case 'latin':
      return OcrScript.latin;
    case 'chinese':
      return OcrScript.chinese;
    default:
      final locale = ui.PlatformDispatcher.instance.locale;
      return locale.languageCode.toLowerCase() == 'zh'
          ? OcrScript.chinese
          : OcrScript.latin;
  }
}

// ─── ML Kit seam ────────────────────────────────────────────────────────────

/// One recognized text block: raw text + bounding rect in RASTER pixels
/// (y-down, origin top-left — ML Kit's coordinate space for the input image).
class OcrTextBlock {
  const OcrTextBlock({required this.text, required this.bounds});

  final String text;
  final ui.Rect bounds;
}

/// Text recognition seam. The default implementation is ML Kit
/// ([MlKitOcrEngine]); tests inject fakes (ML Kit needs real platform
/// channels and on-device models — impossible under `flutter test`).
abstract class OcrEngine {
  /// Recognizes text in the image file at [imagePath] (an encoded image —
  /// PNG/JPEG/WebP) using the given script model.
  Future<List<OcrTextBlock>> recognizeFile(String imagePath, OcrScript script);

  Future<void> dispose();
}

/// Default engine: `google_mlkit_text_recognition` via
/// `InputImage.fromFilePath` (see the header comment for why the file route).
/// Recognizers are created lazily per script and reused across pages.
class MlKitOcrEngine implements OcrEngine {
  final Map<OcrScript, TextRecognizer> _recognizers = {};

  @override
  Future<List<OcrTextBlock>> recognizeFile(
    String imagePath,
    OcrScript script,
  ) async {
    final recognizer = _recognizers[script] ??= TextRecognizer(
      script: script == OcrScript.chinese
          ? TextRecognitionScript.chinese
          : TextRecognitionScript.latin,
    );
    final recognized = await recognizer.processImage(
      InputImage.fromFilePath(imagePath),
    );
    return [
      for (final block in recognized.blocks)
        OcrTextBlock(text: block.text, bounds: block.boundingBox),
    ];
  }

  @override
  Future<void> dispose() async {
    for (final recognizer in _recognizers.values) {
      await recognizer.close();
    }
    _recognizers.clear();
  }
}

// ─── PDF render seam (bypasses PdfThumbnailService's LRU deliberately) ──────

/// One page rendered for OCR.
class OcrPageRender {
  const OcrPageRender({
    required this.pngBytes,
    required this.pageWidthPts,
    required this.pageHeightPts,
    required this.renderScale,
    double? renderScaleY,
  }) : _renderScaleY = renderScaleY;

  final Uint8List pngBytes;

  /// Page size in PDF points (y-up coordinate space).
  final double pageWidthPts;
  final double pageHeightPts;

  /// Actual HORIZONTAL raster-pixels-per-PDF-point scale of [pngBytes]
  /// (widthPx / page width; nominally
  /// [AttachmentOcrExtractor.kOcrRenderScale], but the raster width is
  /// rounded to whole pixels, so it can deviate slightly). Persisted in the
  /// chunk meta.
  final double renderScale;

  /// Actual VERTICAL scale (heightPx / page height). The raster height is
  /// rounded to whole pixels independently of the width, so this can differ
  /// from [renderScale] by a sub-pixel amount; defaults to [renderScale]
  /// when the producer has no separate value. Persisted in the chunk meta.
  double get renderScaleY => _renderScaleY ?? renderScale;
  final double? _renderScaleY;
}

/// Minimal page-render view of an open PDF document (the pdfrx seam for the
/// ocr stage, mirroring [PdfTextSource] of the pdf_text stage).
abstract class PdfOcrRenderSource {
  int get pageCount;

  /// Renders page [pageIndex] (0-based) at [scale]× the page's point size,
  /// as PNG bytes. Null when the page fails to render.
  Future<OcrPageRender?> renderPage(int pageIndex, {required double scale});

  Future<void> dispose();
}

/// Opens the PDF at an absolute [path] for OCR rendering.
typedef PdfOcrRenderSourceOpener =
    Future<PdfOcrRenderSource> Function(String path);

class _PdfrxOcrRenderSource implements PdfOcrRenderSource {
  _PdfrxOcrRenderSource(this._document);

  final PdfDocument _document;

  @override
  int get pageCount => _document.pages.length;

  @override
  Future<OcrPageRender?> renderPage(
    int pageIndex, {
    required double scale,
  }) async {
    final page = _document.pages[pageIndex];
    final width = (page.width * scale).round();
    final height = (page.height * scale).round();
    if (width <= 0 || height <= 0) return null;
    final pdfImage = await page.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (pdfImage == null) return null;
    try {
      final uiImage = await pdfImage.createImage();
      try {
        final byteData = await uiImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (byteData == null) return null;
        return OcrPageRender(
          // Copy: the ui.Image's backing buffer is disposed below.
          pngBytes: Uint8List.fromList(byteData.buffer.asUint8List()),
          pageWidthPts: page.width,
          pageHeightPts: page.height,
          renderScale: width / page.width,
          renderScaleY: height / page.height,
        );
      } finally {
        uiImage.dispose();
      }
    } finally {
      pdfImage.dispose();
    }
  }

  @override
  Future<void> dispose() => _document.dispose();
}

/// Default opener: DIRECT pdfrx render — deliberately not
/// `PdfThumbnailService.renderPage` (plan §3 render spec): its LRU cache
/// would hold full-resolution pages (~2× page size, MBs each) and evict the
/// UI's small thumbnails; OCR renders are one-shot and must not be cached.
Future<PdfOcrRenderSource> openPdfrxOcrRenderSource(String path) async {
  Pdfrx.getCacheDirectory ??= () async {
    final tempDir = await getTemporaryDirectory();
    return tempDir.path;
  };
  final document = await PdfDocument.openFile(path);
  return _PdfrxOcrRenderSource(document);
}

/// Default loader for the GLOBAL on-device-OCR switch
/// (SearchSettingsService.getOcrEnabled, default true).
///
/// Guarded like [loadBatteryStatus]: this seam is consulted on EVERY indexing
/// sweep (it takes part in the ocr stage's completeness check), not only for
/// OCR-eligible attachments, so an unavailable settings store must degrade to
/// the documented default rather than abort the sweep.
Future<bool> loadOcrEnabled() async {
  try {
    return await SearchSettingsService().getOcrEnabled();
  } catch (e) {
    LoggerService.info('[AttachmentOcrExtractor] OCR setting unknown: $e');
    return true;
  }
}

// ─── Battery seam ───────────────────────────────────────────────────────────

/// Battery snapshot for the OCR guard.
class BatteryStatus {
  const BatteryStatus({required this.level, required this.charging});

  /// 0–100.
  final int level;

  /// Plugged in (charging / full / connected-not-charging).
  final bool charging;
}

typedef BatteryStatusLoader = Future<BatteryStatus> Function();

/// Default loader via battery_plus. Errors (platforms without battery info,
/// desktops without a battery) resolve to "fine to run" — the guard must
/// never disable OCR where battery state simply is not a concern.
Future<BatteryStatus> loadBatteryStatus() async {
  try {
    final battery = Battery();
    final state = await battery.batteryState;
    final level = await battery.batteryLevel;
    return BatteryStatus(
      level: level,
      charging:
          state == BatteryState.charging ||
          state == BatteryState.full ||
          state == BatteryState.connectedNotCharging,
    );
  } catch (e) {
    LoggerService.info('[AttachmentOcrExtractor] Battery status unknown: $e');
    return const BatteryStatus(level: 100, charging: true);
  }
}

// ─── Coordinate transform (plan §3/§4.1, specced not discovered) ────────────

/// A rectangle in PDF PAGE coordinates: y-up, origin bottom-left, so
/// `top > bottom` numerically. Units are PDF points.
typedef PdfRect = ({double left, double bottom, double right, double top});

/// Which "PDF page coordinates" these transforms mean (checked against
/// pdfrx 2.2.24 / pdfrx_engine 0.3.9, and relied on by §4.1's figure stage):
/// the page's DISPLAY space — y-up points with the page's `/Rotate` already
/// applied, i.e. the frame `PdfPage.width`/`.height` report and the frame
/// `PdfPage.render()` rasterizes into. On a `/Rotate 90` A4 page that is
/// 842×595, not 595×842.
///
/// This stage is self-consistent in that frame by construction: it renders
/// with no `rotationOverride` (so the raster IS the display frame), sizes
/// the raster from `page.width`/`page.height`, and maps ML Kit's raster
/// bounds straight back with [rasterRectToPdfRect] — so the `space:'pdf'`
/// bounds it persists in the chunk meta are display-space and need no
/// rotation fix-up. (pdfium's TEXT-layer character boxes are a different
/// story: `FPDFText_GetCharBox` is NOT rotation-adjusted, which is why
/// figure_region_extractor.dart normalizes text fragments with
/// `rotateRectToDisplaySpace` before unioning them with these bounds.)
///
/// Forward transform (the §4.1 spec): PDF page rect (y-up, points) → raster
/// pixel rect (y-down, origin top-left) at [renderScale] px/pt horizontally
/// on a page [pageHeightPts] tall: `x_px = left·sx`,
/// `y_px = (pageHeight − top)·sy`. The raster's width and height are rounded
/// to whole pixels independently, so the vertical scale can differ from the
/// horizontal one — pass it as [renderScaleY] (`heightPx / pageHeightPts`);
/// it defaults to [renderScale].
ui.Rect pdfRectToRasterRect(
  PdfRect rect, {
  required double renderScale,
  double? renderScaleY,
  required double pageHeightPts,
}) {
  final scaleY = renderScaleY ?? renderScale;
  return ui.Rect.fromLTWH(
    rect.left * renderScale,
    (pageHeightPts - rect.top) * scaleY,
    (rect.right - rect.left) * renderScale,
    (rect.top - rect.bottom) * scaleY,
  );
}

/// Inverse transform: ML Kit block bounds (raster pixels, y-down) at
/// [renderScale] px/pt (horizontal; [renderScaleY] vertical, defaulting to
/// [renderScale]) → PDF page coordinates (y-up), for §4.1's union with
/// text-layer charRects. Exact inverse of [pdfRectToRasterRect]: note
/// `pageHeightPts − y_px/sy == (heightPx − y_px)/sy` when
/// `sy = heightPx / pageHeightPts`, i.e. the y-flip is anchored on the
/// ACTUAL rendered height, not the nominal one.
PdfRect rasterRectToPdfRect(
  ui.Rect rect, {
  required double renderScale,
  double? renderScaleY,
  required double pageHeightPts,
}) {
  final scaleY = renderScaleY ?? renderScale;
  return (
    left: rect.left / renderScale,
    top: pageHeightPts - rect.top / scaleY,
    right: rect.right / renderScale,
    bottom: pageHeightPts - rect.bottom / scaleY,
  );
}

// ─── Merge policy (text layer is authoritative) ─────────────────────────────

/// Token multiset of [normalizedText] (the output of normalizeForIndex).
Map<String, int> ocrTokenCounts(String normalizedText) {
  final counts = <String, int>{};
  for (final token in normalizedText.split(' ')) {
    if (token.isEmpty) continue;
    counts[token] = (counts[token] ?? 0) + 1;
  }
  return counts;
}

/// Fraction of [blockTokens] present (with multiplicity) in
/// [pageTokenCounts]. 0 for an empty block (nothing to suppress on).
double ocrTokenContainment(
  List<String> blockTokens,
  Map<String, int> pageTokenCounts,
) {
  if (blockTokens.isEmpty) return 0;
  final remaining = Map<String, int>.from(pageTokenCounts);
  var contained = 0;
  for (final token in blockTokens) {
    final available = remaining[token] ?? 0;
    if (available > 0) {
      remaining[token] = available - 1;
      contained++;
    }
  }
  return contained / blockTokens.length;
}

/// Whether an OCR block is redundant against the page's text layer: its
/// normalized tokens (CJK bigrams included, so zh dedupe works) are >=
/// [threshold] contained in the page's text-layer token multiset. Multiset
/// (not strict subsequence) containment is deliberate: OCR reorders text
/// relative to the extraction order of the text layer (columns, rotated
/// labels), and near-duplicate content should still be suppressed.
bool isOcrBlockSuppressed(
  String blockText,
  Map<String, int> pageTokenCounts, {
  double threshold = AttachmentOcrExtractor.kSuppressionThreshold,
}) {
  final tokens = normalizeForIndex(
    blockText,
  ).split(' ').where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty) return true; // No indexable content at all.
  if (pageTokenCounts.isEmpty) return false;
  return ocrTokenContainment(tokens, pageTokenCounts) >= threshold;
}

// ─── Result types ───────────────────────────────────────────────────────────

/// Outcome of one OCR extraction attempt (mirrors [ExtractionStatus]).
enum OcrExtractionStatus {
  /// OCR ran; [OcrExtractionResult.drafts] holds the novel-text chunks
  /// (possibly empty when everything was suppressed by the text layer).
  extracted,

  /// Not a PDF or raster image (e.g. SVG, audio) — the ocr stage does not
  /// apply.
  skippedNotEligible,

  /// OCR is turned off for this attachment: either the GLOBAL switch
  /// (SearchSettingsService.getOcrEnabled) or the per-attachment
  /// AttachmentSearchIndexConfig.ocr is false. One status for both because
  /// the indexer reacts identically — purge the attachment_ocr chunks and
  /// record a skip (the two policies differ only in the state hash, which
  /// carries both so either flip re-runs the stage).
  skippedPolicyOff,

  /// The owning note has notes.metadata.searchIndex.exclude == true.
  skippedNoteExcluded,

  /// PDF over the page cap without the explicit text:'on' opt-in — OCRing a
  /// 500-page clipped PDF is even costlier than text-extracting it, so the
  /// ocr stage honors the same size-gated default (plan §1.3).
  skippedTooLarge,

  /// Battery guard fired (low battery, not charging). Unlike skips this is
  /// TRANSIENT: no state row is written, so the next sweep retries.
  deferredBattery,

  /// The pause/cancel callback fired between pages; partial output is
  /// discarded and no state should be written (the resume sweep re-runs).
  aborted,

  /// The file is missing or unreadable.
  failed,
}

class OcrExtractionResult {
  const OcrExtractionResult._(
    this.status, {
    this.drafts = const [],
    this.pageCount,
    this.errorMessage,
  });

  final OcrExtractionStatus status;

  /// `attachment_ocr` chunk drafts (only for [OcrExtractionStatus.extracted]).
  final List<ChunkDraft> drafts;

  /// Page count of the document when it was opened (1 for raster images).
  final int? pageCount;

  final String? errorMessage;
}

// ─── Extractor ──────────────────────────────────────────────────────────────

/// Runs on-device OCR over PDF pages and raster image attachments, deduping
/// against the PDF text layer, producing `attachment_ocr` [ChunkDraft]s with
/// block bounds + renderScale in their meta JSON.
class AttachmentOcrExtractor {
  AttachmentOcrExtractor(
    this._db, {
    PdfOcrRenderSourceOpener? opener,
    OcrEngine? engine,
    BatteryStatusLoader? batteryLoader,
    OcrScriptLoader? scriptLoader,
    Future<int> Function()? pageCapLoader,
    Future<bool> Function()? ocrEnabledLoader,
    Future<String> Function()? tempDirLoader,
  }) : _opener = opener ?? openPdfrxOcrRenderSource,
       _engine = engine ?? MlKitOcrEngine(),
       _batteryLoader = batteryLoader ?? loadBatteryStatus,
       _scriptLoader = scriptLoader ?? loadDefaultOcrScript,
       _pageCapLoader =
           pageCapLoader ?? (SearchSettingsService().getPdfPageCap),
       _ocrEnabledLoader = ocrEnabledLoader ?? loadOcrEnabled,
       _tempDirLoader =
           tempDirLoader ?? (() async => (await getTemporaryDirectory()).path);

  /// Nominal render scale: ~2× the page's PDF point size (plan §3 render
  /// spec — a US-Letter page becomes ~1224×1584 px, plenty for ML Kit and
  /// far above the 200 px thumbnails the LRU serves the UI).
  static const double kOcrRenderScale = 2.0;

  /// OCR blocks whose normalized tokens are at least this contained in the
  /// page's text layer are suppressed (plan §3 merge policy, "≥~70%").
  static const double kSuppressionThreshold = 0.7;

  /// At most this many pages in flight at once (render + recognize).
  static const int kMaxConcurrentPages = 2;

  /// Below this battery percentage, un-plugged OCR is deferred.
  static const int kLowBatteryLevel = 20;

  /// Battery is re-checked every this many pages during a long document.
  static const int kBatteryRecheckPages = 10;

  final DatabaseService _db;
  final PdfOcrRenderSourceOpener _opener;
  final OcrEngine _engine;
  final BatteryStatusLoader _batteryLoader;
  final OcrScriptLoader _scriptLoader;
  final Future<int> Function() _pageCapLoader;
  final Future<bool> Function() _ocrEnabledLoader;
  final Future<String> Function() _tempDirLoader;

  /// Page counts by attachment id (same fingerprint-validated cache pattern
  /// as [AttachmentTextExtractor]); used for page-based progress totals.
  final Map<String, ({String fingerprint, int count})> _pageCountCache = {};

  /// THE list of raster image extensions the whole search pipeline
  /// understands, lower-case and dot-prefixed. Single source of truth for
  /// every place that has to agree on it, because they must agree file by
  /// file or the stages contradict each other:
  ///   * [isRasterImageAttachment] / [isOcrEligible] — what the ocr stage
  ///     recognizes and what `NoteIndexService.isFigureEligible` admits;
  ///   * `NoteIndexService._ocrEligibleFileNameSql` (and the figure-eligible
  ///     predicate built on it) — the SQL form used by the orphan sweep, so
  ///     a sweep can never purge chunks a stage would legitimately re-write;
  ///   * `NoteIndexService._isEmbeddableRasterName` — which raster
  ///     attachment file can BE the image input of its figure chunk.
  /// Adding `.heic` here (and teaching the OCR/decode paths about it) is the
  /// whole change; there is deliberately no second list to remember.
  static const List<String> kRasterImageExtensions = [
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
  ];

  /// Raster images ML Kit can decode. SVG is deliberately excluded (vector —
  /// nothing to OCR without rasterizing first, plan §4.1 keeps SVG
  /// lexical-only).
  static bool isRasterImageAttachment(Attachment attachment) =>
      isRasterImageFileName(attachment.fileName);

  /// [isRasterImageAttachment] for a bare file name (callers that hold a name
  /// but no [Attachment] row).
  static bool isRasterImageFileName(String fileName) {
    final name = fileName.toLowerCase();
    return kRasterImageExtensions.any(name.endsWith);
  }

  /// Whether the ocr stage applies to [attachment] at all.
  static bool isOcrEligible(Attachment attachment) =>
      AttachmentTextExtractor.isPdfAttachment(attachment) ||
      isRasterImageAttachment(attachment);

  /// The current `searchIndexPdfPageCap` value (shared with the pdf_text
  /// stage — one size-gated default governs both).
  Future<int> effectivePageCap() => _pageCapLoader();

  /// The primary script for the next run (part of the ocr state hash).
  Future<OcrScript> effectiveScript() => _scriptLoader();

  /// The GLOBAL on-device-OCR switch (`searchIndexOcrEnabled`, default true).
  /// Off means no attachment is OCRed regardless of its per-attachment
  /// `ocr` policy — [extractOcr] short-circuits to
  /// [OcrExtractionStatus.skippedPolicyOff]. It is part of the ocr stage's
  /// state hash (see NoteIndexService), so flipping it purges the existing
  /// `attachment_ocr` chunks and flipping it back re-extracts them.
  Future<bool> ocrEnabled() => _ocrEnabledLoader();

  /// Whether OCR may run right now: plugged in, or battery above
  /// [kLowBatteryLevel]. "Prefer charging/idle" (plan §3) is realized as:
  /// charging always runs; on battery it runs only above the low-water mark,
  /// and the deferral is transient so the charging session's sweep picks the
  /// work back up.
  Future<bool> batteryAllowsOcr() async {
    final status = await _batteryLoader();
    return status.charging || status.level > kLowBatteryLevel;
  }

  /// Stat-only file fingerprint (shared with the pdf_text stage).
  Future<String> fileFingerprint(Attachment attachment) =>
      attachmentFileFingerprint(attachment);

  /// Page count for progress totals: PDFs via a cheap doc-info open (cached
  /// per attachment id + fingerprint), raster images count as 1. Null when
  /// the file is missing/unreadable or the attachment is not OCR-eligible.
  Future<int?> getOcrPageCount(Attachment attachment) async {
    if (isRasterImageAttachment(attachment)) return 1;
    if (!AttachmentTextExtractor.isPdfAttachment(attachment)) return null;
    final fingerprint = await fileFingerprint(attachment);
    if (fingerprint == 'missing') return null;
    final cached = _pageCountCache[attachment.id];
    if (cached != null && cached.fingerprint == fingerprint) {
      return cached.count;
    }
    try {
      final source = await _opener(await attachment.getAbsolutePath());
      try {
        final count = source.pageCount;
        _pageCountCache[attachment.id] = (
          fingerprint: fingerprint,
          count: count,
        );
        return count;
      } finally {
        await source.dispose();
      }
    } catch (e) {
      LoggerService.warning(
        '[AttachmentOcrExtractor] Page count failed for '
        '${attachment.fileName}: $e',
      );
      return null;
    }
  }

  /// Releases the OCR engine's native recognizers. Safe to call between
  /// runs; recognizers are re-created lazily.
  Future<void> dispose() => _engine.dispose();

  /// Runs OCR over [attachment] into `attachment_ocr` drafts.
  ///
  /// PDF pages carry 1-based [ChunkDraft.page] and per-page seq bands (like
  /// chunkPdfPage); raster images produce page-less drafts. Each draft's
  /// meta JSON holds the page's novel block bounds — PDF bounds mapped back
  /// to PDF page coordinates (y-up) via [rasterRectToPdfRect] — plus the
  /// renderScale they were recognized at.
  ///
  /// [shouldAbort] is consulted before each page (indexer pause semantics);
  /// the battery guard is checked up front and every [kBatteryRecheckPages]
  /// pages. Both discard partial output ([OcrExtractionStatus.aborted] /
  /// [OcrExtractionStatus.deferredBattery]) so the resume/next sweep re-runs
  /// the whole attachment.
  ///
  /// [onPageProgress] reports (done, total) pages for the stage's
  /// "Recognizing text in PDFs — X/Y pages" progress.
  Future<OcrExtractionResult> extractOcr(
    Attachment attachment, {
    bool Function()? shouldAbort,
    bool? noteExcluded,
    void Function(int done, int total)? onPageProgress,
  }) async {
    if (!isOcrEligible(attachment)) {
      return const OcrExtractionResult._(
        OcrExtractionStatus.skippedNotEligible,
      );
    }
    // Global switch first (cheap, and BEFORE the battery gate): with OCR
    // turned off the caller must reach the same purge path the per-attachment
    // flag takes, even on a low battery — a battery deferral writes no state
    // and would leave the now-unwanted chunks in the index.
    if (!await ocrEnabled()) {
      return const OcrExtractionResult._(OcrExtractionStatus.skippedPolicyOff);
    }
    final config = attachment.getSearchIndexConfig();
    if (!config.ocr) {
      return const OcrExtractionResult._(OcrExtractionStatus.skippedPolicyOff);
    }
    final excluded =
        noteExcluded ??
        NoteIndexService.isNoteSearchExcluded(
          await _db.getNoteMetadata(attachment.noteId),
        );
    if (excluded) {
      return const OcrExtractionResult._(
        OcrExtractionStatus.skippedNoteExcluded,
      );
    }
    if (!await batteryAllowsOcr()) {
      return const OcrExtractionResult._(OcrExtractionStatus.deferredBattery);
    }

    final fingerprint = await fileFingerprint(attachment);
    if (fingerprint == 'missing') {
      return OcrExtractionResult._(
        OcrExtractionStatus.failed,
        errorMessage: 'File not found: ${attachment.filePath}',
      );
    }

    if (isRasterImageAttachment(attachment)) {
      return _extractImage(attachment, shouldAbort, onPageProgress);
    }
    return _extractPdf(
      attachment,
      config,
      fingerprint,
      shouldAbort,
      onPageProgress,
    );
  }

  // ── Raster images ────────────────────────────────────────────────────────

  Future<OcrExtractionResult> _extractImage(
    Attachment attachment,
    bool Function()? shouldAbort,
    void Function(int done, int total)? onPageProgress,
  ) async {
    if (shouldAbort?.call() ?? false) {
      return const OcrExtractionResult._(OcrExtractionStatus.aborted);
    }
    final script = await effectiveScript();
    final List<OcrTextBlock> blocks;
    try {
      blocks = await _recognizeWithFallback(
        await attachment.getAbsolutePath(),
        script,
      );
    } catch (e) {
      return OcrExtractionResult._(
        OcrExtractionStatus.failed,
        errorMessage: 'OCR failed: $e',
      );
    }

    // No text layer exists for images: every block with indexable content is
    // novel by definition.
    final novel = [
      for (final block in blocks)
        if (!isOcrBlockSuppressed(block.text, const {})) block,
    ];
    final drafts = _buildDrafts(
      attachment,
      page: null,
      novelBlocks: novel,
      // Image bounds stay in image pixel space (y-down): there is no PDF
      // coordinate system to map into. Marked space:'image' in the meta.
      boundsMapper: (rect) => (
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
      ),
      space: 'image',
      renderScale: 1.0,
    );
    onPageProgress?.call(1, 1);
    return OcrExtractionResult._(
      OcrExtractionStatus.extracted,
      drafts: drafts,
      pageCount: 1,
    );
  }

  // ── PDFs ─────────────────────────────────────────────────────────────────

  Future<OcrExtractionResult> _extractPdf(
    Attachment attachment,
    AttachmentSearchIndexConfig config,
    String fingerprint,
    bool Function()? shouldAbort,
    void Function(int done, int total)? onPageProgress,
  ) async {
    final PdfOcrRenderSource source;
    try {
      source = await _opener(await attachment.getAbsolutePath());
    } catch (e) {
      return OcrExtractionResult._(
        OcrExtractionStatus.failed,
        errorMessage: 'Failed to open PDF: $e',
      );
    }
    try {
      final pageCount = source.pageCount;
      _pageCountCache[attachment.id] = (
        fingerprint: fingerprint,
        count: pageCount,
      );
      if (pageCount > await effectivePageCap() && !config.textExplicitlyOn) {
        return OcrExtractionResult._(
          OcrExtractionStatus.skippedTooLarge,
          pageCount: pageCount,
        );
      }

      final script = await effectiveScript();
      final textLayerByPage = await _loadTextLayerTokens(attachment);
      final tempDir = await _tempDirLoader();

      // Per-page results, ordered; workers pull the next un-taken page.
      final pageDrafts = List<List<ChunkDraft>?>.filled(pageCount, null);
      var nextPage = 0;
      var donePages = 0;
      var errorPages = 0;
      String? firstPageError;
      var aborted = false;
      var batteryDeferred = false;

      Future<void> worker() async {
        while (true) {
          if (aborted || batteryDeferred) return;
          if (shouldAbort?.call() ?? false) {
            aborted = true;
            return;
          }
          final pageIndex = nextPage++;
          if (pageIndex >= pageCount) return;
          if (pageIndex > 0 && pageIndex % kBatteryRecheckPages == 0) {
            if (!await batteryAllowsOcr()) {
              batteryDeferred = true;
              return;
            }
          }
          try {
            pageDrafts[pageIndex] = await _ocrPdfPage(
              attachment,
              source,
              pageIndex,
              script,
              textLayerByPage[pageIndex + 1] ?? const {},
              tempDir,
            );
          } catch (e) {
            // One broken page must not lose the document — mirror pdf_text.
            // But COUNT it: a document where every page raised is an engine/
            // document failure, not an empty scan (checked after the loop).
            errorPages++;
            firstPageError ??= '$e';
            LoggerService.warning(
              '[AttachmentOcrExtractor] Page ${pageIndex + 1} of '
              '${attachment.fileName} failed: $e',
            );
            pageDrafts[pageIndex] = const [];
          }
          donePages++;
          onPageProgress?.call(donePages, pageCount);
        }
      }

      await Future.wait([
        for (var i = 0; i < math.min(kMaxConcurrentPages, pageCount); i++)
          worker(),
      ]);

      if (aborted) {
        return OcrExtractionResult._(
          OcrExtractionStatus.aborted,
          pageCount: pageCount,
        );
      }
      if (batteryDeferred) {
        return OcrExtractionResult._(
          OcrExtractionStatus.deferredBattery,
          pageCount: pageCount,
        );
      }
      if (pageCount > 0 && errorPages == pageCount) {
        // EVERY page raised an engine exception — that is a failure of the
        // engine or document, not "pages genuinely empty". Reporting it as
        // extracted would record a done state and freeze the failure as
        // success; failing lets the ocr stage record an error state with
        // the usual retry semantics (file/policy change re-runs).
        return OcrExtractionResult._(
          OcrExtractionStatus.failed,
          pageCount: pageCount,
          errorMessage:
              'OCR failed on all $pageCount pages; first: $firstPageError',
        );
      }

      final drafts = [for (final page in pageDrafts) ...?page];
      return OcrExtractionResult._(
        OcrExtractionStatus.extracted,
        drafts: drafts,
        pageCount: pageCount,
      );
    } catch (e) {
      return OcrExtractionResult._(
        OcrExtractionStatus.failed,
        errorMessage: 'OCR extraction failed: $e',
      );
    } finally {
      await source.dispose();
    }
  }

  /// OCRs one PDF page: render at ~2×, recognize via a temp PNG file,
  /// suppress text-layer-covered blocks, map bounds back to PDF coordinates.
  Future<List<ChunkDraft>> _ocrPdfPage(
    Attachment attachment,
    PdfOcrRenderSource source,
    int pageIndex,
    OcrScript script,
    Map<String, int> textLayerTokens,
    String tempDir,
  ) async {
    final render = await source.renderPage(pageIndex, scale: kOcrRenderScale);
    if (render == null) return const [];

    // fromFilePath route: write the PNG, recognize, delete (header comment).
    final tempFile = File(
      '$tempDir/ocr_${attachment.id}_p${pageIndex}_'
      '${DateTime.now().microsecondsSinceEpoch}.png',
    );
    List<OcrTextBlock> blocks;
    try {
      await tempFile.writeAsBytes(render.pngBytes, flush: false);
      blocks = await _recognizeWithFallback(tempFile.path, script);
    } finally {
      try {
        await tempFile.delete();
      } catch (_) {
        // Best-effort: the OS temp dir is periodically purged anyway.
      }
    }

    final novel = [
      for (final block in blocks)
        if (!isOcrBlockSuppressed(block.text, textLayerTokens)) block,
    ];
    return _buildDrafts(
      attachment,
      page: pageIndex + 1,
      novelBlocks: novel,
      boundsMapper: (rect) => rasterRectToPdfRect(
        rect,
        renderScale: render.renderScale,
        renderScaleY: render.renderScaleY,
        pageHeightPts: render.pageHeightPts,
      ),
      space: 'pdf',
      renderScale: render.renderScale,
      renderScaleY: render.renderScaleY,
    );
  }

  /// Primary-script recognition with the Latin→Chinese empty-page fallback
  /// (see the script policy in the header comment).
  Future<List<OcrTextBlock>> _recognizeWithFallback(
    String imagePath,
    OcrScript script,
  ) async {
    final blocks = await _engine.recognizeFile(imagePath, script);
    if (script == OcrScript.latin &&
        blocks.every((b) => b.text.trim().isEmpty)) {
      try {
        final retry = await _engine.recognizeFile(imagePath, OcrScript.chinese);
        if (retry.any((b) => b.text.trim().isNotEmpty)) return retry;
      } catch (e) {
        // Chinese model unavailable (e.g. iOS pod not installed): the Latin
        // result stands.
        LoggerService.info(
          '[AttachmentOcrExtractor] Chinese fallback unavailable: $e',
        );
      }
    }
    return blocks;
  }

  /// Builds the `attachment_ocr` drafts for one page (or one raster image):
  /// novel block text joined in reading order, chunked, each chunk carrying
  /// the page's meta JSON ({blockBounds:[{rect,text}], renderScale,
  /// renderScaleY, space}). PDF pages carry both scales ([renderScaleY] is
  /// the vertical one; §4.1 consumers should fall back to renderScale when
  /// the key is absent — raster images omit it).
  ///
  /// The full block list rides on EVERY chunk of the page (pages almost
  /// always produce a single chunk of novel text) so §4.1 can read a page's
  /// bounds from any of its chunks.
  List<ChunkDraft> _buildDrafts(
    Attachment attachment, {
    required int? page,
    required List<OcrTextBlock> novelBlocks,
    required PdfRect Function(ui.Rect) boundsMapper,
    required String space,
    required double renderScale,
    double? renderScaleY,
  }) {
    if (novelBlocks.isEmpty) return const [];
    final text = novelBlocks
        .map((b) => b.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    if (text.isEmpty) return const [];

    double round2(double v) => (v * 100).roundToDouble() / 100;
    final meta = jsonEncode({
      'renderScale': round2(renderScale),
      if (renderScaleY != null) 'renderScaleY': round2(renderScaleY),
      'space': space,
      'blockBounds': [
        for (final block in novelBlocks)
          () {
            final rect = boundsMapper(block.bounds);
            return {
              'rect': {
                'l': round2(rect.left),
                't': round2(rect.top),
                'r': round2(rect.right),
                'b': round2(rect.bottom),
              },
              'text': block.text,
            };
          }(),
      ],
    });

    final drafts = <ChunkDraft>[];
    var i = 0;
    for (final chunkText in chunkPlainText(text)) {
      assert(
        i < 1000,
        'page $page produced $i+ OCR chunks, overflowing its seq band',
      );
      drafts.add(
        ChunkDraft(
          noteId: attachment.noteId,
          sourceType: 'attachment_ocr',
          sourceId: attachment.id,
          page: page,
          // Same page-banded seq scheme as chunkPdfPage; images (page ==
          // null) use the first band.
          seq: ((page ?? 1) - 1) * 1000 + i++,
          text: chunkText,
          meta: meta,
        ),
      );
    }
    return drafts;
  }

  /// Loads the page's text-layer token multisets for the merge policy:
  /// {1-based page: token counts} over the attachment's `attachment_text`
  /// chunks (raw text, normalized here with the same normalizeForIndex the
  /// index uses).
  Future<Map<int, Map<String, int>>> _loadTextLayerTokens(
    Attachment attachment,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'search_chunks',
      columns: ['page', 'text'],
      where: "sourceType = 'attachment_text' AND sourceId = ?",
      whereArgs: [attachment.id],
    );
    final textByPage = <int, StringBuffer>{};
    for (final row in rows) {
      final page = row['page'] as int?;
      if (page == null) continue;
      (textByPage[page] ??= StringBuffer())
        ..write(row['text'] as String? ?? '')
        ..write('\n');
    }
    return {
      for (final entry in textByPage.entries)
        entry.key: ocrTokenCounts(normalizeForIndex(entry.value.toString())),
    };
  }
}
