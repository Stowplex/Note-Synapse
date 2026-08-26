// PDF text-layer extraction for the search index (plan §3, Step 11).
//
// The extractor turns a PDF attachment into `attachment_text` ChunkDrafts
// (one stream per attachment, 1-based pages) using pdfrx's per-page
// `loadStructuredText().fullText`. It is used BY NoteIndexService's
// 'pdf_text' stage; it never writes to the database itself.
//
// pdfrx access is seamed behind [PdfTextSource] / [PdfTextSourceOpener]:
// pdfium cannot initialize headless under `flutter test` (the engine's
// worker isolate falls back to DynamicLibrary.process() and the symbol
// lookup fails even with Pdfrx.pdfiumModulePath set), so tests inject a fake
// source; one skipped-by-default integration test exercises the real opener.
//
// OCR is deliberately NOT here — it is Step 12 (a separate primary layer).

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../models/attachment.dart';
import '../database_service.dart';
import '../logger_service.dart';
import '../search_settings_service.dart';
import 'note_chunker.dart';
import 'note_index_service.dart';

/// Minimal page-text view of an open PDF document (the pdfrx seam).
abstract class PdfTextSource {
  int get pageCount;

  /// Text of page [pageIndex] (0-based). The chunker's page numbers are
  /// 1-based; the conversion happens in [AttachmentTextExtractor].
  Future<String> loadPageText(int pageIndex);

  Future<void> dispose();
}

/// Opens the PDF at an absolute [path]. Defaults to pdfrx
/// ([openPdfrxTextSource]); tests inject fakes.
typedef PdfTextSourceOpener = Future<PdfTextSource> Function(String path);

class _PdfrxTextSource implements PdfTextSource {
  _PdfrxTextSource(this._document);

  final PdfDocument _document;

  @override
  int get pageCount => _document.pages.length;

  @override
  Future<String> loadPageText(int pageIndex) async {
    final text = await _document.pages[pageIndex].loadStructuredText();
    return text.fullText;
  }

  @override
  Future<void> dispose() => _document.dispose();
}

/// Default opener: pdfrx `PdfDocument.openFile`, following the open/dispose
/// pattern of `pdf_thumbnail_service.dart` / `note_prompt_builder.dart`.
Future<PdfTextSource> openPdfrxTextSource(String path) async {
  // Ensure pdfrx cache directory is set (same guard as PdfThumbnailService).
  Pdfrx.getCacheDirectory ??= () async {
    final tempDir = await getTemporaryDirectory();
    return tempDir.path;
  };
  final document = await PdfDocument.openFile(path);
  return _PdfrxTextSource(document);
}

/// Stat-only change fingerprint of an attachment's backing file:
/// `"{size}:{mtimeMs}"`, or `"missing"` when the file does not exist. Shared
/// by the pdf_text and ocr stages so their state hashes agree on what "the
/// file changed" means (see [AttachmentTextExtractor.fileFingerprint] for the
/// rationale and the known mtime-granularity gap).
Future<String> attachmentFileFingerprint(Attachment attachment) async {
  final path = await attachment.getAbsolutePath();
  final file = File(path);
  if (!await file.exists()) return 'missing';
  final stat = await file.stat();
  return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
}

/// Outcome of one extraction attempt.
enum ExtractionStatus {
  /// Text extracted; [ExtractionResult.drafts] holds the page chunks.
  extracted,

  /// Attachment is not a PDF — the pdf_text stage does not apply.
  skippedNotPdf,

  /// AttachmentSearchIndexConfig.text == 'off'.
  skippedPolicyOff,

  /// The owning note has notes.metadata.searchIndex.exclude == true.
  skippedNoteExcluded,

  /// Page count exceeds the size cap and the attachment is not explicitly
  /// opted in (text != 'on'). Kept distinct from the other skips so the UI
  /// can list "N large PDFs not indexed" (plan §1.3).
  skippedTooLarge,

  /// The pause/cancel callback fired between pages; partial output is
  /// discarded and no state should be written (the resume sweep re-runs).
  aborted,

  /// The file is missing or unreadable.
  failed,
}

class ExtractionResult {
  const ExtractionResult._(
    this.status, {
    this.drafts = const [],
    this.pageCount,
    this.errorMessage,
  });

  final ExtractionStatus status;

  /// `attachment_text` chunk drafts (only for [ExtractionStatus.extracted]).
  final List<ChunkDraft> drafts;

  /// Page count of the document, when it was opened.
  final int? pageCount;

  final String? errorMessage;
}

/// Extracts the embedded text layer of PDF attachments.
///
/// Policy gates (cheapest first) run before the document is opened:
/// non-PDF, per-attachment `text: off`, note-level exclusion. The size cap
/// (`searchIndexPdfPageCap`, default 100) is checked right after open from
/// the page count, before any page text is loaded.
class AttachmentTextExtractor {
  AttachmentTextExtractor(
    this._db, {
    PdfTextSourceOpener? opener,
    Future<int> Function()? pageCapLoader,
  }) : _opener = opener ?? openPdfrxTextSource,
       _pageCapLoader =
           pageCapLoader ?? (SearchSettingsService().getPdfPageCap);

  final DatabaseService _db;
  final PdfTextSourceOpener _opener;
  final Future<int> Function() _pageCapLoader;

  /// Page counts by attachment id, stamped with the [fileFingerprint] they
  /// were read under, so the attach-time [exceedsPageCap] prompt and a
  /// subsequent extraction don't open the document twice — while a replaced
  /// file (fingerprint change) still gets a fresh open and count.
  final Map<String, ({String fingerprint, int count})> _pageCountCache = {};

  /// Repo-wide PDF detection convention (see note_prompt_builder.dart:466).
  static bool isPdfAttachment(Attachment attachment) =>
      attachment.fileName.toLowerCase().endsWith('.pdf');

  /// The current `searchIndexPdfPageCap` value.
  Future<int> effectivePageCap() => _pageCapLoader();

  /// Change fingerprint of the attachment's file: `"{size}:{mtimeMs}"`, or
  /// `"missing"` when the file does not exist.
  ///
  /// Chosen over sha256-of-first-N-bytes deliberately: (a) it is stat-only —
  /// the backfill completeness sweep re-fingerprints every attachment, and a
  /// read-based hash would touch every PDF on every sweep; (b) PDF
  /// incremental saves append at the end of the file and leave the header
  /// bytes untouched, so a first-N-bytes hash would miss most real PDF
  /// edits, while size+mtime catches any rewrite.
  ///
  /// Known granularity gap: a rewrite that keeps the byte size identical AND
  /// lands within the filesystem's mtime resolution window (up to seconds on
  /// coarse-mtime filesystems) yields the same fingerprint and is missed.
  /// Accepted tradeoff for a stat-only check; the Settings force rebuild
  /// (`backfillAll(force: true)`) is the escape hatch.
  Future<String> fileFingerprint(Attachment attachment) =>
      attachmentFileFingerprint(attachment);

  /// Page count of a PDF attachment via a cheap doc-info open (cached per
  /// attachment id, validated against the current [fileFingerprint] so a
  /// replaced file is re-counted). Null for non-PDFs, missing, or unreadable
  /// files.
  Future<int?> getPdfPageCount(Attachment attachment) async {
    if (!isPdfAttachment(attachment)) return null;
    final fingerprint = await fileFingerprint(attachment);
    if (fingerprint == 'missing') return null;
    final cached = _pageCountCache[attachment.id];
    if (cached != null && cached.fingerprint == fingerprint) {
      return cached.count;
    }
    final path = await attachment.getAbsolutePath();
    try {
      final source = await _opener(path);
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
        '[AttachmentTextExtractor] Page count failed for '
        '${attachment.fileName}: $e',
      );
      return null;
    }
  }

  /// Whether [attachment] has more pages than `searchIndexPdfPageCap` — the
  /// check behind Step 10's attach-time "Index this PDF for search?" prompt.
  Future<bool> exceedsPageCap(Attachment attachment) async {
    final count = await getPdfPageCount(attachment);
    if (count == null) return false;
    return count > await effectivePageCap();
  }

  /// Extracts the PDF text layer of [attachment] into per-page
  /// `attachment_text` drafts (1-based pages, chunkPdfPage seq bands).
  ///
  /// Pages are processed sequentially; [shouldAbort] is consulted before
  /// each page so the indexer's pause() semantics extend into a running
  /// extraction (an aborted run returns [ExtractionStatus.aborted] and its
  /// partial drafts are discarded).
  ///
  /// [noteExcluded] short-circuits the note-metadata read when the caller
  /// (NoteIndexService) already knows the note-level exclusion flag.
  Future<ExtractionResult> extractPdfText(
    Attachment attachment, {
    bool Function()? shouldAbort,
    bool? noteExcluded,
  }) async {
    if (!isPdfAttachment(attachment)) {
      return const ExtractionResult._(ExtractionStatus.skippedNotPdf);
    }
    final config = attachment.getSearchIndexConfig();
    if (!config.textEnabled) {
      return const ExtractionResult._(ExtractionStatus.skippedPolicyOff);
    }
    final excluded =
        noteExcluded ??
        NoteIndexService.isNoteSearchExcluded(
          await _db.getNoteMetadata(attachment.noteId),
        );
    if (excluded) {
      return const ExtractionResult._(ExtractionStatus.skippedNoteExcluded);
    }

    final path = await attachment.getAbsolutePath();
    final fingerprint = await fileFingerprint(attachment);
    if (fingerprint == 'missing') {
      return ExtractionResult._(
        ExtractionStatus.failed,
        errorMessage: 'File not found: ${attachment.filePath}',
      );
    }

    final PdfTextSource source;
    try {
      source = await _opener(path);
    } catch (e) {
      return ExtractionResult._(
        ExtractionStatus.failed,
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
        return ExtractionResult._(
          ExtractionStatus.skippedTooLarge,
          pageCount: pageCount,
        );
      }

      final drafts = <ChunkDraft>[];
      for (var i = 0; i < pageCount; i++) {
        if (shouldAbort?.call() ?? false) {
          return ExtractionResult._(
            ExtractionStatus.aborted,
            pageCount: pageCount,
          );
        }
        String pageText;
        try {
          pageText = await source.loadPageText(i);
        } catch (e) {
          // One broken page must not lose the rest of the document.
          LoggerService.warning(
            '[AttachmentTextExtractor] Page ${i + 1} of '
            '${attachment.fileName} failed: $e',
          );
          continue;
        }
        drafts.addAll(
          chunkPdfPage(attachment.noteId, attachment.id, i + 1, pageText),
        );
      }
      return ExtractionResult._(
        ExtractionStatus.extracted,
        drafts: drafts,
        pageCount: pageCount,
      );
    } catch (e) {
      return ExtractionResult._(
        ExtractionStatus.failed,
        errorMessage: 'Extraction failed: $e',
      );
    } finally {
      await source.dispose();
    }
  }
}
