// Shared fakes for the ocr stage (Step 12). ML Kit, battery_plus, pdfrx
// rendering, and SharedPreferences all need real platform channels, so every
// AttachmentOcrExtractor constructed in tests must inject these seams — the
// default seams would throw (or, for pdfrx, potentially hang pdfium init)
// under flutter_tester.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/attachment_ocr_extractor.dart';
import 'package:note_synapse/services/search/figure_region_extractor.dart';

/// Recording OCR engine; [blocksFor] maps (image file content, script) to
/// blocks. PDF pages arrive as temp PNG files whose bytes are whatever the
/// fake render source produced (see [FakeOcrRenderSource]: `page:N`), so
/// fakes can key blocks off the page marker.
class FakeOcrEngine implements OcrEngine {
  FakeOcrEngine({this.blocksFor});

  final List<OcrTextBlock> Function(String content, OcrScript script)?
  blocksFor;

  /// (file content, script) per recognizeFile call, in order.
  final List<(String, OcrScript)> calls = [];
  bool disposed = false;

  @override
  Future<List<OcrTextBlock>> recognizeFile(
    String imagePath,
    OcrScript script,
  ) async {
    String content;
    try {
      content = await File(imagePath).readAsString();
    } catch (_) {
      content = imagePath; // Raster images: identify by path.
    }
    calls.add((content, script));
    return blocksFor?.call(content, script) ?? const [];
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// Render source whose page [i] renders to the bytes `page:i` (readable by
/// [FakeOcrEngine]) on a fixed-size page.
class FakeOcrRenderSource implements PdfOcrRenderSource {
  FakeOcrRenderSource(
    this.pageCount, {
    this.pageWidthPts = 612,
    this.pageHeightPts = 792,
    this.onRender,
    this.contentFor,
  });

  @override
  final int pageCount;
  final double pageWidthPts;
  final double pageHeightPts;

  /// Optional per-page hook (gating/abort tests).
  final Future<void> Function(int pageIndex)? onRender;

  /// Content of the rendered "PNG" for a page; defaults to `page:N` (0-based)
  /// — override to disambiguate documents in multi-attachment tests.
  final String Function(int pageIndex)? contentFor;

  int renderCalls = 0;
  bool disposed = false;

  @override
  Future<OcrPageRender?> renderPage(
    int pageIndex, {
    required double scale,
  }) async {
    renderCalls++;
    await onRender?.call(pageIndex);
    return OcrPageRender(
      pngBytes: utf8.encode(contentFor?.call(pageIndex) ?? 'page:$pageIndex'),
      pageWidthPts: pageWidthPts,
      pageHeightPts: pageHeightPts,
      renderScale: scale,
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// A benign extractor for tests that are NOT about OCR: every PDF opens as a
/// zero-page document (ocr state settles as 'done' with no chunks), the
/// engine finds nothing in raster images, battery is full/charging, and the
/// global OCR switch is on (its default).
AttachmentOcrExtractor stubOcrExtractor(DatabaseService db) {
  return AttachmentOcrExtractor(
    db,
    opener: (path) async => FakeOcrRenderSource(0),
    engine: FakeOcrEngine(),
    batteryLoader: () async => const BatteryStatus(level: 100, charging: true),
    scriptLoader: () async => OcrScript.latin,
    pageCapLoader: () async => 100,
    ocrEnabledLoader: () async => true,
    tempDirLoader: () async => Directory.systemTemp.path,
  );
}

/// A figure source that opens nothing: zero pages, no regions, no renders.
class FakeEmptyFigureSource implements PdfFigureSource {
  @override
  int get pageCount => 0;

  @override
  Future<PdfFigurePage> loadPage(int pageIndex) async =>
      throw StateError('no pages');

  @override
  Future<Uint8List?> renderRegionPng(
    int pageIndex, {
    required int x,
    required int y,
    required int width,
    required int height,
    required double fullWidth,
    required double fullHeight,
  }) async => null;

  @override
  Future<void> dispose() async {}
}

/// A benign figure extractor for tests that are NOT about the figures stage:
/// every PDF opens as a zero-page document, so the stage settles 'done' with
/// no chunks and no derived crops.
///
/// EVERY test that constructs a NoteIndexService needs this (or
/// `figuresEnabledLoader: () async => false`). The default seams are the REAL
/// ones: `figureExtractor ?? FigureRegionExtractor()` binds
/// `openPdfrxFigureSource`, and `loadFigureIndexingEnabled` fails OPEN
/// (SharedPreferences has no platform channel under `flutter_tester`, so it
/// logs and returns its `true` default) — so the figures stage runs, and the
/// only thing standing between a unit test and pdfium initializing is whether
/// path_provider happens to be mocked AND an attachment file happens to exist
/// on disk. Both of those are one line away in any future test.
FigureRegionExtractor stubFigureExtractor({Directory? derivedDir}) {
  return FigureRegionExtractor(
    opener: (path) async => FakeEmptyFigureSource(),
    // Never created and never touched: a zero-page document yields no
    // regions, so nothing is rendered, saved or reaped.
    derivedDirLoader: () async =>
        derivedDir ?? Directory('${Directory.systemTemp.path}/no_derived'),
  );
}
