// Synthetic figure-extraction fixtures for the Step-13 spike and unit tests.
//
// Each fixture carries EXACT ground-truth geometry (page size, text items
// with bounds, the drawn figure/table rect) and can also be emitted as a
// real PDF via the low-level `pdf` package API — which draws rects and text
// at exact PDF coordinates, so the ground truth is not approximated. The
// spike validates the region-inference MATH through fakes built from this
// geometry (pdfrx/pdfium cannot initialize headless under flutter_tester);
// the same PDFs feed the skipped-by-default live-pdfrx integration test.
//
// EVERY text-layer fixture is built from PER-WORD fragments and assembled by
// the production [mergeFragmentsIntoLines], because that is what pdfrx hands
// the extractor (pdfrx_engine `pdf_text_formatter.dart`, `addWords`). Round
// 1's fixtures declared whole lines with an empty `fragmentRects`, a shape
// that never occurs in production, and consequently could not see that the
// table-row classifier fired on every body row of a two-column page. OCR
// fixtures keep whole-block rects with no fragments — that IS what Step 12
// stores.

import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart' as pdflib;

import 'package:note_synapse/services/search/attachment_ocr_extractor.dart'
    show PdfRect;
import 'package:note_synapse/services/search/figure_region_extractor.dart';

/// One spike fixture: ground-truth geometry + expected outcomes.
class FigureFixture {
  const FigureFixture({
    required this.name,
    required this.pageWidth,
    required this.pageHeight,
    required this.textItems,
    this.ocrItems = const [],
    required this.truthRect,
    this.truthIsTable = false,
    required this.expectedRegexAnchors,
    required this.expectedRegions,
    int? expectedTrueCaptions,
    this.expectedCaptionContains,
    this.zhText = false,
    this.minIou = 0.7,
  }) : expectedTrueCaptions = expectedTrueCaptions ?? expectedRegions;

  final String name;
  final double pageWidth;
  final double pageHeight;

  /// Text-layer items (LINES, assembled from per-word fragments by
  /// [mergeFragmentsIntoLines] — each keeps its `fragmentRects`).
  final List<PageTextItem> textItems;

  /// OCR block items (the Step-12 meta input, PDF coords y-up, no fragments).
  final List<PageTextItem> ocrItems;

  /// The drawn figure/table rect — what a perfect extraction would return.
  /// All-zero when the fixture's ground truth is "there is no figure here".
  final PdfRect truthRect;
  final bool truthIsTable;

  /// Regex-level caption matches expected among all items (may exceed the
  /// true captions — e.g. the "Figure 4 shows…" body-line false positive).
  final int expectedRegexAnchors;

  /// Captioned regions expected AFTER geometry (degenerate anchors die).
  final int expectedRegions;

  /// How many of [expectedRegexAnchors] are REAL captions — the denominator
  /// side of regex precision. Defaults to [expectedRegions]; differs
  /// wherever a genuine caption has no figure behind it (fixtures I, J, L,
  /// P).
  final int expectedTrueCaptions;

  /// Substring the winning region's caption must contain.
  final String? expectedCaptionContains;

  /// Whether the fixture's caption needs a CJK-capable font when emitted as
  /// a real PDF.
  final bool zhText;

  /// IoU the emitted region must beat. 0.7 everywhere except where the page
  /// itself does not carry enough evidence to place an edge (see fixture W,
  /// whose caption is wider than the drawing it labels).
  final double minIou;

  List<PageTextItem> get allItems => [...textItems, ...ocrItems];
}

/// Intersection-over-union of two PDF rects.
double iou(PdfRect a, PdfRect b) {
  final ix =
      (a.right < b.right ? a.right : b.right) -
      (a.left > b.left ? a.left : b.left);
  final iy =
      (a.top < b.top ? a.top : b.top) -
      (a.bottom > b.bottom ? a.bottom : b.bottom);
  if (ix <= 0 || iy <= 0) return 0;
  final inter = ix * iy;
  final areaA = (a.right - a.left) * (a.top - a.bottom);
  final areaB = (b.right - b.left) * (b.top - b.bottom);
  return inter / (areaA + areaB - inter);
}

/// A text item with NO fragment breakdown — what an OCR block looks like
/// (Step 12 stores one rect per block, never per word).
PageTextItem _line(
  String text,
  double left,
  double bottom,
  double right,
  double top,
) => PageTextItem(
  text: text,
  rect: (left: left, top: top, right: right, bottom: bottom),
);

/// Splits a line into the PER-WORD fragments a real PDF text layer emits.
///
/// Words are laid out left to right with [wordGap] between them and widths
/// proportional to their character counts, so the line's outer rect is
/// exactly the declared one while its internal structure is what pdfium
/// actually reports.
List<PageTextItem> wordFragments(
  String text,
  double left,
  double bottom,
  double right,
  double top, {
  double wordGap = 4,
}) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final width = right - left;
  if (words.length < 2 || width <= 0) {
    return [_line(text, left, bottom, right, top)];
  }
  final usable = width - wordGap * (words.length - 1);
  if (usable <= 0) return [_line(text, left, bottom, right, top)];
  final totalChars = words.fold<int>(0, (sum, w) => sum + w.length);
  final fragments = <PageTextItem>[];
  var x = left;
  for (var i = 0; i < words.length; i++) {
    final w = i == words.length - 1
        ? right - x
        : usable * words[i].length / totalChars;
    fragments.add(_line(words[i], x, bottom, x + w, top));
    x += w + wordGap;
  }
  return fragments;
}

/// Collects per-word fragments for a whole page and runs them through the
/// REAL [mergeFragmentsIntoLines] — including the same-baseline column-gap
/// check that keeps two page columns from merging into one page-wide line,
/// and (given the page height, exactly as the pdfrx seam supplies it) the
/// column-corridor check that keeps a right-column caption from merging into
/// the body line beside it.
class _Page {
  _Page({this.pageHeight = 792});

  final double pageHeight;
  final List<PageTextItem> _fragments = [];

  void line(
    String text,
    double left,
    double bottom,
    double right,
    double top, {
    double wordGap = 4,
  }) {
    _fragments.addAll(
      wordFragments(text, left, bottom, right, top, wordGap: wordGap),
    );
  }

  /// [count] lines of one column measure, top-down from [firstTop].
  void column(
    String text,
    double left,
    double right,
    double firstTop, {
    required int count,
    required double lineHeight,
    required double pitch,
    double wordGap = 4,
  }) {
    for (var i = 0; i < count; i++) {
      final top = firstTop - i * pitch;
      line(text, left, top - lineHeight, right, top, wordGap: wordGap);
    }
  }

  List<PageTextItem> build() =>
      mergeFragmentsIntoLines(_fragments, pageHeightPts: pageHeight);
}

List<PageTextItem> _pageLines(
  void Function(_Page page) build, {
  double pageHeight = 792,
}) {
  final page = _Page(pageHeight: pageHeight);
  build(page);
  return page.build();
}

const PdfRect _noFigure = (left: 0, top: 0, right: 0, bottom: 0);

/// Fixture A — single-column page: body text above the figure, a colored
/// figure rect, "Figure 1:" caption below it, body text below the caption.
/// The lower body includes a "Figure 4 shows…" line — a regex-level caption
/// false positive that geometry must reject (no text-free gap above it) —
/// and a mid-sentence "The figure 3…" line that the line-start anchor must
/// never match.
FigureFixture fixtureSingleColumn() => FigureFixture(
  name: 'A single-column figure',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Signals were sampled at 48 kHz as usual.', 72, 746, 540, 758);
    page.line('Each window was Hann-tapered before FFT.', 72, 732, 540, 744);
    page.line('Spectra were averaged over twelve trials.', 72, 718, 540, 730);
    page.line(
      'Figure 1: Synthetic spectrum of the test signal',
      90,
      380,
      430,
      394,
    );
    page.line('The figure 3 shows the trend clearly here.', 72, 348, 540, 360);
    page.line('Peaks align with the harmonic grid closely.', 72, 334, 540, 346);
    page.line(
      'Figure 4 shows the aggregate results of all runs in detail.',
      72,
      320,
      540,
      332,
    );
    page.line('Residual noise stays below minus sixty dB.', 72, 306, 540, 318);
  }),
  truthRect: (left: 80, top: 700, right: 530, bottom: 410),
  expectedRegexAnchors: 2, // "Figure 1:" + the "Figure 4 shows…" body line.
  expectedRegions: 1, // Geometry kills the body-line anchor.
  expectedCaptionContains: 'Figure 1',
);

/// Fixture B — table with the caption ABOVE it: the region must grow toward
/// the text-free side (down, through the narrow cell texts, which are
/// absorbed rather than blocking). The cells sit far enough apart that they
/// stay separate ITEMS after the merge — the inter-item gutter path.
FigureFixture fixtureTable() => FigureFixture(
  name: 'B table with caption above',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('We compare four models on both datasets.', 72, 704, 540, 716);
    page.line('All scores are averaged over five seeds.', 72, 690, 540, 702);
    page.line('Table 2: Results summary', 72, 640, 250, 654);
    const columnsX = [(76.0, 176.0), (240.0, 340.0), (420.0, 530.0)];
    const rowTops = [620.0, 580.0, 540.0, 500.0, 460.0, 420.0];
    for (var r = 0; r < rowTops.length; r++) {
      for (var c = 0; c < columnsX.length; c++) {
        page.line(
          'cell r${r}c$c',
          columnsX[c].$1,
          rowTops[r] - 12,
          columnsX[c].$2,
          rowTops[r],
        );
      }
    }
    page.line('Bold entries mark the best score per row.', 72, 336, 540, 348);
    page.line('Differences are significant at p < 0.05.', 72, 322, 540, 334);
  }),
  truthRect: (left: 72, top: 630, right: 540, bottom: 380),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 2',
);

/// Fixture C — "scanned" Chinese page: NO text layer at all; the caption and
/// the in-figure labels arrive exclusively as OCR block bounds (Step 12's
/// stored meta), proving OCR is a first-class caption source. Distractor
/// lines start with 表面/图书馆 (表/图 followed by a non-digit — must not
/// match).
FigureFixture fixtureChineseScanned() => FigureFixture(
  name: 'C Chinese scanned figure',
  pageWidth: 595,
  pageHeight: 842,
  textItems: const [],
  ocrItems: [
    _line('输入层', 100, 700, 160, 716),
    _line('隐藏层', 250, 620, 310, 636),
    _line('输出层', 400, 540, 460, 556),
    _line('图1：神经网络结构示意图', 200, 450, 395, 466),
    _line('表面上看这个结构十分简单。', 60, 420, 535, 434),
    _line('图书馆的记录显示 3 个版本。', 60, 406, 535, 418),
  ],
  truthRect: (left: 60, top: 780, right: 535, bottom: 480),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: '图1',
  zhText: true,
);

/// Fixture D — two-column layout: the figure lives in the right column while
/// the left column is full of body text at the same heights; the region must
/// stay inside the right column. A left-column line reading "figures 2 and
/// 3…" is a plural distractor the regex must reject.
FigureFixture fixtureTwoColumn() => FigureFixture(
  name: 'D two-column figure',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var top = 740.0; top >= 132; top -= 14) {
      page.line(
        top == 460
            ? 'figures 2 and 3 are omitted here'
            : 'left column body text line',
        40,
        top - 12,
        290,
        top,
      );
    }
    page.line('Latency was measured end to end.', 322, 674, 572, 686);
    page.line('Batching was disabled throughout.', 322, 660, 572, 672);
    page.line('Fig. 3 End-to-end latency comparison', 322, 402, 520, 414);
    page.line('The gap widens with payload size.', 322, 376, 572, 388);
    page.line('Results replicate across regions.', 322, 362, 572, 374);
  }),
  truthRect: (left: 322, top: 640, right: 572, bottom: 430),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Fig. 3',
);

/// Fixture E — caption-less page: a big drawn area with no caption anywhere;
/// becomes a low-confidence whitespace candidate (behind the threshold by
/// default).
FigureFixture fixtureWhitespaceOnly() => FigureFixture(
  name: 'E caption-less whitespace',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('An untitled diagram follows below.', 72, 748, 540, 760);
    page.line('It ships without any caption at all.', 72, 734, 540, 746);
    page.line('Discussion resumes after the diagram.', 72, 148, 540, 160);
    page.line('The layout above is self-explanatory.', 72, 134, 540, 146);
    page.line('We therefore omit a formal caption.', 72, 100, 540, 112);
  }),
  truthRect: (left: 80, top: 660, right: 530, bottom: 200),
  expectedRegexAnchors: 0,
  expectedRegions: 0, // At the DEFAULT confidence threshold.
);

/// Fixture F — a figure containing WIDE in-figure text: a 200pt chart title
/// just inside the figure's top edge and a 150pt x-axis title just inside its
/// bottom edge, both well over a fifth of the page width. Neither is body
/// text (each is a lone line surrounded by whitespace), so both must be
/// absorbed: the chart title must not clip the top of the figure off and the
/// axis title must not collapse the region to nothing.
FigureFixture fixtureInFigureWideText() => FigureFixture(
  name: 'F in-figure wide text',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Throughput was measured end to end.', 72, 746, 540, 758);
    page.line('Each run used a freshly booted cluster.', 72, 732, 540, 744);
    page.line('We report the median of eleven runs.', 72, 718, 540, 730);
    // Chart title INSIDE the figure (200pt = 32.7% of the page width).
    page.line('Latency versus offered load', 206, 680, 406, 694);
    // Y-axis tick labels: narrow, scattered, absorbed either way.
    page.line('100', 86, 636, 116, 646);
    page.line('50', 86, 556, 116, 566);
    page.line('0', 86, 476, 116, 486);
    // X-axis title INSIDE the figure (150pt = 24.5%).
    page.line('Offered load (requests/s)', 230, 424, 380, 436);
    page.line('Figure 2: Throughput versus offered load', 90, 380, 430, 394);
    page.line('Saturation begins near four hundred.', 72, 348, 540, 360);
    page.line('Tail latency grows super-linearly then.', 72, 334, 540, 346);
  }),
  truthRect: (left: 80, top: 700, right: 530, bottom: 410),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 2',
);

/// Fixture G — the reproduced table failure, in full: a WRAPPED two-line
/// caption ("Table 2: … for every model and / dataset, averaged over five
/// seeds") sitting above rows whose per-cell fragments merge into ONE wide
/// 468pt line each through the real [mergeFragmentsIntoLines] path, at 125pt
/// cells separated by 10pt gutters.
///
/// The geometry of the blank strip is preserved exactly: the body line above
/// the caption ends at y=704 and the caption top is 654, leaving a 42pt
/// text-free band that used to win the above/below comparison and be
/// rendered as a blank PNG labelled "Table 2".
FigureFixture fixtureWrappedTableCaption() => FigureFixture(
  name: 'G wrapped table caption',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('We evaluate four models on two datasets.', 72, 718, 540, 730);
    page.line('Every score is the mean of five runs.', 72, 704, 540, 716);
    page.line(
      'Table 2: Results summary for every model and',
      72,
      640,
      450,
      654,
    );
    page.line('dataset, averaged over five seeds', 72, 626, 330, 640);
    const columns = [(72.0, 197.0), (207.0, 332.0), (342.0, 540.0)];
    for (var top = 606.0; top >= 536.0; top -= 14) {
      for (var c = 0; c < columns.length; c++) {
        page.line('cell$c', columns[c].$1, top - 12, columns[c].$2, top);
      }
    }
    page.line('Bold entries mark the best score per row.', 72, 480, 540, 492);
    page.line('Differences are significant at p < 0.05.', 72, 466, 540, 478);
  }),
  truthRect: (left: 72, top: 620, right: 540, bottom: 516),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 2',
);

/// Fixture H — a figure with a WRAPPED two-line caption below it. The wrap
/// line must be folded into the caption (it is caption text, and it must not
/// act as a body-line blocker).
FigureFixture fixtureWrappedFigureCaption() => FigureFixture(
  name: 'H wrapped figure caption',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Scheduling decisions are made per batch.', 72, 718, 540, 730);
    page.line('The admission window is fixed at 8 ms.', 72, 704, 540, 716);
    page.line(
      'Figure 3: End-to-end latency of the proposed',
      72,
      394,
      500,
      408,
    );
    page.line('scheduler under increasing offered load', 72, 380, 430, 394);
    page.line('Queueing dominates beyond the knee point.', 72, 348, 540, 360);
    page.line('The effect persists across all regions.', 72, 334, 540, 346);
  }),
  truthRect: (left: 80, top: 690, right: 530, bottom: 424),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 3',
);

/// Fixture I — a page of nothing but NARROW lines (verse; 118pt = 19.3% of
/// the page, just under the old body-line width threshold) with a caption at
/// the bottom. Every line used to be invisible to the blocker test, so the
/// caption's band grew over the whole page and the entire page of text was
/// emitted as a 0.9-confidence "figure". Correct behaviour: no region.
FigureFixture fixtureAllNarrowLines() => FigureFixture(
  name: 'I all-narrow page',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var top = 788.0; top >= 410.0; top -= 18) {
      page.line('a narrow line of verse', 72, top - 12, 190, top);
    }
    page.line('Figure 9: Sonnet layout', 72, 380, 260, 394);
  }),
  // Nothing is drawn: the "truth" is that no figure exists here.
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  // The caption line IS a real caption; it is the geometry (a page of
  // verse, no drawn area) that has no figure to hand back.
  expectedTrueCaptions: 1,
);

// ─── Round-2 fixtures: the reproduced regressions ───────────────────────────

/// Fixture J — a REAL two-column body page, no figure at all: 52 lines per
/// column at 10pt on a 12pt pitch, a 46pt inter-column corridor, and a
/// figure caption at the bottom of the right column.
///
/// The reproduced failure: with per-word fragments every visual row's
/// pooled "cells" were words, so `every cell is narrow` held trivially and
/// the 46pt corridor read as a table gutter that repeated at the same x on
/// every row — 104 of 105 lines classified tabular, nothing blocked, and the
/// caption's band swallowed the entire right column
/// (l=324 b=98 r=548 t=788 at 0.9 confidence). Correct behaviour: no region.
FigureFixture fixtureTwoColumnBodyOnly() => FigureFixture(
  name: 'J real two-column body page',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (final left in [54.0, 324.0]) {
      page.column(
        'the quick brown fox jumps over the lazy dog',
        left,
        left + 224,
        730,
        count: 52,
        lineHeight: 10,
        pitch: 12,
      );
    }
    page.line('Figure 3: Latency', 324, 80, 430, 94);
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
);

/// Fixture K — the same two-column page WITH a figure: the right column has
/// a 200pt hole (y 400–600) and the caption sits directly under it. The
/// region must be the hole; the reproduced failure returned t=788 (the whole
/// column, IoU 0.51) because the body rows above the hole were "table rows".
FigureFixture fixtureTwoColumnFigure() => FigureFixture(
  name: 'K two-column figure with body rows',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    const line = 'the quick brown fox jumps over the lazy dog';
    page.column(line, 54, 278, 730, count: 52, lineHeight: 10, pitch: 12);
    // Right column: 11 lines above the hole, 23 below the caption.
    page.column(line, 324, 548, 730, count: 11, lineHeight: 10, pitch: 12);
    page.line('Figure 3: Latency by payload size', 324, 386, 430, 400);
    page.column(line, 324, 548, 374, count: 23, lineHeight: 10, pitch: 12);
  }),
  truthRect: (left: 330, top: 594, right: 542, bottom: 406),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 3',
);

/// Fixture L — three narrow columns (158pt = 25.8% of the page) with 18pt
/// gutters. Needs no fragments at all to fail: the cells were narrow by
/// their own line rects, so 153 of 154 lines classified tabular and the
/// caption's band covered the page (l=54 b=108 r=388 t=788). Also the case
/// that reaches OCR pages, which have no fragments to begin with.
FigureFixture fixtureThreeColumn() => FigureFixture(
  name: 'L three narrow columns',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (final left in [54.0, 230.0, 406.0]) {
      page.column(
        'narrow column of body text here',
        left,
        left + 158,
        730,
        count: 51,
        lineHeight: 10,
        pitch: 12,
      );
    }
    page.line('Figure 3: Caption', 54, 90, 200, 104);
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
);

/// Fixture M — a two-line LEGEND inside the plot ("— baseline" / "—
/// proposed", 120pt and 100pt at leading distance). Geometrically it is a
/// paragraph — same left margin, one line apart — so the run rule blocked on
/// it and cut 146pt of plot area off the top of the figure (region top 582
/// instead of 728). It is figure content: two short lines in an otherwise
/// empty band fill ~30% of the strip they share with the caption, where a
/// paragraph fills ~90%.
FigureFixture fixtureInFigureLegend() => FigureFixture(
  name: 'M in-figure two-line legend',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Scheduling decisions are made per batch.', 72, 746, 540, 758);
    page.line('The admission window is fixed at 8 ms.', 72, 732, 540, 744);
    page.line('We report the median of eleven runs.', 72, 718, 540, 730);
    page.line('— baseline', 200, 600, 320, 612);
    page.line('— proposed', 200, 586, 300, 598);
    page.line('Figure 5: Latency versus offered load', 90, 380, 430, 394);
    page.line('Queueing dominates beyond the knee point.', 72, 348, 540, 360);
    page.line('The effect persists across all regions.', 72, 334, 540, 346);
  }),
  truthRect: (left: 80, top: 714, right: 530, bottom: 410),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 5',
);

/// Fixture N — ten right-aligned y-axis TICK LABELS stacked on a 14pt pitch.
/// A ten-member "paragraph" by geometry; 20pt wide, so it fills ~4% of the
/// strip. Blocking on it lost 168pt of the plot (region top 560 instead of
/// 728).
FigureFixture fixtureTickLabelStack() => FigureFixture(
  name: 'N dense tick-label stack',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Throughput was measured end to end.', 72, 746, 540, 758);
    page.line('Each run used a freshly booted cluster.', 72, 732, 540, 744);
    page.line('We report the median of eleven runs.', 72, 718, 540, 730);
    for (var i = 0; i < 10; i++) {
      final top = 700.0 - i * 14;
      page.line('${100 - i * 10}', 96, top - 10, 116, top);
    }
    page.line('Figure 6: Throughput versus offered load', 90, 380, 430, 394);
    page.line('Saturation begins near four hundred.', 72, 348, 540, 360);
    page.line('Tail latency grows super-linearly then.', 72, 334, 540, 346);
  }),
  truthRect: (left: 80, top: 714, right: 530, bottom: 410),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 6',
);

/// Fixture O — a FULL-MEASURE caption followed by an ordinary paragraph at
/// leading distance. Every continuation guard round 1 had (starts at/right
/// of the caption's left, not past its right edge, overlaps its column) is
/// satisfied by an ordinary body line under a full-width caption, so four
/// body lines were folded into the caption text — and folded lines stop
/// blocking and stop counting.
FigureFixture fixtureCaptionThenParagraph() => FigureFixture(
  name: 'O caption followed by a paragraph',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Scheduling decisions are made per batch.', 72, 746, 540, 758);
    page.line('The admission window is fixed at 8 ms.', 72, 732, 540, 744);
    page.line('We report the median of eleven runs.', 72, 718, 540, 730);
    page.line(
      'Figure 7: End-to-end latency of the proposed scheduler',
      72,
      394,
      540,
      406,
    );
    page.line('Queueing dominates beyond the knee point of', 72, 380, 540, 392);
    page.line(
      'the arrival curve, and the effect persists in',
      72,
      366,
      540,
      378,
    );
    page.line('every region we measured, including the two', 72, 352, 540, 364);
    page.line('smallest ones, where the queue is shortest.', 72, 338, 540, 350);
    page.line('Batching was disabled throughout.', 72, 324, 300, 336);
  }),
  truthRect: (left: 80, top: 700, right: 530, bottom: 412),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 7',
);

/// Fixture P — seven WIDE LONE lines 100pt apart (a slide, a chat log, a
/// page of one-line paragraphs) plus a caption at the page foot. Nothing
/// forms a run, so nothing blocks, and seven lines cleared the old 8-line
/// whole-page cliff: the whole page came back as a 0.9-confidence figure
/// (l=72 b=58 r=372 t=788). Correct behaviour: no region.
FigureFixture fixtureLoneLinesPage() => FigureFixture(
  name: 'P seven lone lines',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i < 7; i++) {
      final top = 746.0 - i * 100;
      page.line('a single line of slide text here', 72, top - 14, 372, top);
    }
    page.line('Figure 8: Summary of the results', 72, 40, 300, 54);
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
);

/// Fixture Q — a two-column TABLE whose cells are 228pt (37.3% of the page),
/// over the old 35% cell cap: every row failed the cell test, became a body
/// run instead, and blocked in both directions, so the table was silently
/// missing (0 regions). The cap now applies to the two cells flanking a
/// gutter and sits at 45%, which is safe because a page COLUMN layout is
/// recognised as such by its corridor and by the page-height extent of its
/// gutter, not by cell width.
FigureFixture fixtureWideCellTable() => FigureFixture(
  name: 'Q two-column table with wide cells',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('We compare four scheduling policies here.', 72, 704, 540, 716);
    page.line('All scores are averaged over five seeds.', 72, 690, 540, 702);
    page.line('Table 5: Scheduling policies compared', 72, 660, 300, 674);
    const rows = [
      ('earliest deadline first', 'p99 latency 12.4 ms'),
      ('shortest job next', 'p99 latency 18.1 ms'),
      ('round robin quantum', 'p99 latency 23.7 ms'),
      ('fair queueing weights', 'p99 latency 19.5 ms'),
      ('lottery scheduling draw', 'p99 latency 27.2 ms'),
      ('first come first served', 'p99 latency 31.8 ms'),
    ];
    for (var r = 0; r < rows.length; r++) {
      final top = 640.0 - r * 20;
      page.line(rows[r].$1, 72, top - 12, 300, top);
      page.line(rows[r].$2, 312, top - 12, 540, top);
    }
    page.line('Bold entries mark the best score per row.', 72, 480, 540, 492);
    page.line('Differences are significant at p < 0.05.', 72, 466, 540, 478);
  }),
  truthRect: (left: 72, top: 652, right: 540, bottom: 522),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 5',
);

// ─── Round-3 fixtures: the red team's reproduced geometries ─────────────────
//
// Every one of these was measured on the per-word path with exact
// coordinates. The two FALSE POSITIVES (R, S) carry the bad rect in their
// doc comment and pin it with `isNot` in the tests, the way the blank-strip
// regression does — an emitted region there is a screenshot of prose shown
// in chat under someone else's caption.

/// Fixture R — nine rows of TWO-COLUMN PROSE above a table caption, with the
/// real table below it. The prose rows are geometrically identical to a
/// two-column table (230pt cells, 20pt pitch, one aligned gutter) and every
/// page-level defence needs ~60% of page height to fire, so a bounded prose
/// block was "tabular", never blocked, and the caption claimed all 18 prose
/// lines: l=60 b=500 r=540 t=788, 43.8% prose ink, IoU 0.000 against the
/// table it was captioning. Reproduced in 15 of 16 lineHeight × gutter
/// combinations.
///
/// What tells the two apart is what is INSIDE the cells (8 and 6 words of
/// running text vs "12.4"), and — independently — that a "Table N" caption
/// has an actual table block on its other side.
FigureFixture fixtureProseColumnsOverTable() => FigureFixture(
  name: 'R prose columns above a table caption',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i < 9; i++) {
      final top = 700.0 - 20 * i;
      page.line(
        'the quick brown fox jumps over lazy dog',
        60,
        top - 14,
        290,
        top,
      );
      page.line(
        'another line of ordinary running prose',
        310,
        top - 14,
        540,
        top,
      );
    }
    page.line('Table 2: Accuracy summary', 60, 480, 220, 496);
    for (var i = 0; i < 5; i++) {
      final top = 450.0 - 20 * i;
      page.line('12.4', 60, top - 12, 160, top);
      page.line('18.1', 240, top - 12, 300, top);
      page.line('23.7', 380, top - 12, 440, top);
    }
  }),
  truthRect: (left: 58, top: 456, right: 442, bottom: 350),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 2',
);

/// The exact rect fixture R used to emit — 18 lines of prose at 0.9
/// confidence, captioned "Table 2: Accuracy summary".
const PdfRect kProseColumnsBadRect = (
  left: 60,
  top: 788,
  right: 540,
  bottom: 500,
);

/// Fixture S — the archetypal IEEE shape: two columns of body text at the
/// top of the page, a full-width figure caption at the foot, and the figure
/// between them. The caption bridges the column corridor so
/// [detectLayoutCorridors] returns nothing, the body rows read as table rows,
/// nothing blocks, and the band ran the whole page: l=54 b=98 r=548 t=788,
/// density 0.1183 — just under the 0.12 backstop, which the tabular
/// exemption would have skipped anyway. At 10+ lines the same page produced
/// NOTHING (the complement failure): the correct answer is the band between
/// the prose and the caption, at every line count.
FigureFixture fixtureFullWidthCaptionUnderColumns() => FigureFixture(
  name: 'S two columns above a full-width figure caption',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i < 9; i++) {
      final top = 730.0 - 12 * i;
      page.line(
        'the quick brown fox jumps over lazy dog',
        54,
        top - 10,
        278,
        top,
      );
      page.line(
        'another line of ordinary running prose',
        324,
        top - 10,
        548,
        top,
      );
    }
    page.line('Figure 2: End-to-end system architecture', 54, 80, 548, 94);
  }),
  truthRect: (left: 54, top: 604, right: 548, bottom: 110),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 2',
);

/// The exact rect fixture S used to emit: the entire page, prose included.
const PdfRect kFullWidthCaptionBadRect = (
  left: 54,
  top: 788,
  right: 548,
  bottom: 98,
);

/// Fixture T — a table caption, five rows of three columns, and nothing else
/// on the page. With the rows tabular and no trailing body run to stop at,
/// the band ran from the caption to the PAGE EDGE and the third column
/// (100pt past the second, far beyond the old 8pt absorb reach) fell
/// outside it: l=72 b=4 r=360 t=696 — 692pt of band for a 126pt table,
/// IoU 0.165.
FigureFixture fixtureTableToPageEdge() => FigureFixture(
  name: 'T table alone on the page',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Table 1: Quarterly revenue by region', 72, 700, 340, 714);
    for (var i = 0; i < 5; i++) {
      final top = 674.0 - 20 * i;
      page.line('north', 72, top - 12, 200, top);
      page.line('12.4', 300, top - 12, 360, top);
      page.line('23.7', 460, top - 12, 520, top);
    }
  }),
  truthRect: (left: 70, top: 680, right: 524, bottom: 576),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 1',
);

/// The exact rect fixture T used to emit.
const PdfRect kTableToPageEdgeBadRect = (
  left: 72,
  top: 696,
  right: 360,
  bottom: 4,
);

/// Fixture U — a full-page plate with its caption at the foot and NO other
/// text anywhere: a thesis figure, a scanned photograph, a slide. Horizontal
/// extent used to be inferred only from adjacent TEXT, so the region
/// collapsed to the caption's own width (IoU 0.510; 0.272 for a short
/// caption). A figure is by definition where text ISN'T — the band's clear
/// sides carry the extent instead.
FigureFixture fixtureFullPagePlate() => FigureFixture(
  name: 'U full-page plate, caption-width only',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Figure 4: The full page schematic', 72, 74, 330, 88);
  }),
  truthRect: (left: 72, top: 760, right: 540, bottom: 100),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 4',
);

/// Fixture V — a standalone appendix table page: caption, then 24 rows of
/// two columns to the page foot. The 40pt inter-cell gap is a text-free
/// corridor spanning the page, so the corridor rule suppressed the gutters,
/// the rows became blocking body runs, and the page returned NOTHING —
/// unless the caption happened to be wider than column 1, which is what
/// "table found" depended on.
FigureFixture fixtureAppendixTablePage() => FigureFixture(
  name: 'V standalone appendix table page',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Table 1: Full results', 72, 760, 250, 774);
    for (var i = 0; i < 24; i++) {
      final top = 740.0 - 20 * i;
      page.line('alpha beta', 72, top - 12, 280, top);
      page.line('12.4 18.1', 320, top - 12, 540, top);
    }
  }),
  truthRect: (left: 70, top: 746, right: 542, bottom: 262),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 1',
);

/// Fixture W — an architecture diagram: six labelled boxes stacked 90pt
/// apart, 26% of the page wide, and a caption at the foot. Six labels was a
/// hard cliff — 4 and 5 produced a region, 6, 7 and 8 produced nothing,
/// because a page-tall band with six countable lines was "the page". Exactly
/// the figure most worth showing.
///
/// [minIou] is 0.5 here and nowhere else. The truth rect is the DRAWING a
/// human would crop; the page carries no evidence for its edges (the caption
/// is wider than the labels, and the boxes and arrows around them leave no
/// text at all), so the region is the caption-implied plate above the
/// caption. It contains the whole drawing — the assertion that matters is
/// containment, in the FN-2 test — while including page margin around it.
FigureFixture fixtureLabelledDiagram() => FigureFixture(
  name: 'W six-label architecture diagram',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i < 6; i++) {
      final top = 720.0 - 90 * i;
      page.line('module $i', 200, top - 14, 360, top);
    }
    page.line(
      'Figure 1: Architecture of the proposed model',
      72,
      120,
      400,
      134,
    );
  }),
  truthRect: (left: 180, top: 750, right: 380, bottom: 180),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 1',
  minIou: 0.5,
);

/// Fixture X — a two-column table whose DESCRIPTION column is 50.3% of the
/// page, just over the 45% cell cap that fixture Q sits under at 37%. Every
/// row failed the cell test, became a body run, blocked in both directions,
/// and the table was silently missing. The cap now gates on cell CONTENT
/// (a one-word "12.4" beside the description is a table cell, whatever its
/// neighbour's width).
FigureFixture fixtureDescriptionColumnTable() => FigureFixture(
  name: 'X table with a 50% description column',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Table 3: Parameters and their meanings', 72, 700, 260, 714);
    for (var i = 0; i < 6; i++) {
      final top = 674.0 - 20 * i;
      page.line('a long description of the parameter', 72, top - 12, 380, top);
      page.line('12.4', 400, top - 12, 540, top);
    }
  }),
  truthRect: (left: 70, top: 680, right: 542, bottom: 552),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 3',
);

/// Fixture Y — sub-figure captions: "Fig. 2a baseline" and "Fig. 2b
/// proposed" side by side under the panels they label, with the parent
/// "Figure 2:" caption below them. Each sub-caption re-derived the parent's
/// band, so the page returned two byte-identical regions
/// (l=72 b=446 r=540 t=714) — and, being captions, the two of them collapsed
/// the PARENT's band to 8pt, which was then dropped. One region, owned by
/// the parent.
FigureFixture fixtureSubCaptions() => FigureFixture(
  name: 'Y sub-figure captions',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Body text above the figure area here.', 72, 746, 540, 758);
    page.line('A second body line for the paragraph.', 72, 732, 540, 744);
    page.line('Fig. 2a baseline', 130, 430, 230, 442);
    page.line('Fig. 2b proposed', 380, 430, 480, 442);
    page.line('Figure 2: Comparison of the two systems', 72, 400, 540, 414);
  }),
  truthRect: (left: 72, top: 726, right: 540, bottom: 420),
  expectedRegexAnchors: 3,
  expectedRegions: 1,
  expectedTrueCaptions: 3,
  expectedCaptionContains: 'Figure 2',
);

// ─── Round-4 fixtures: the second red team's reproduced geometries ─────────
//
// Every geometry below was measured with the red team's exact coordinates and
// reproduced the reported rect before the round-4 fix. The FALSE POSITIVES
// carry the bad rect as a `k…BadRect` constant, pinned with `isNot` in the
// tests: an emitted region there is a screenshot of prose (or a blank
// rectangle) shown in chat under someone else's caption.

/// Fixture Z — THREE columns of body prose above a table caption, with the
/// real table below it. The prose cells are 130pt (21% of the page), just
/// inside the 22% "narrow cell" cap that round 3 accepted as evidence of a
/// table cell, so the block detector claimed all twelve rows of prose, and
/// the claim exempted them from both backstops:
/// l=54 b=502 r=472 t=744, 69.4% prose ink, IoU 0.000, confidence 0.9.
///
/// What a table cell holds is now read from its TEXT, not guessed from its
/// width: "the quick brown fox jumps over" is six words wherever it is drawn.
///
/// The table below (5 columns on 4pt gaps, under the word-space floor) is NOT
/// found — a declared false negative, and the reason this page emits nothing
/// at all rather than a table.
FigureFixture fixtureProseThreeColumnsOverTable() => FigureFixture(
  name: 'Z prose in three columns above a table caption',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i <= 11; i++) {
      final top = 740.0 - 20 * i;
      page.line('the quick brown fox jumps over', 54, top - 14, 184, top);
      page.line('another line of running prose', 198, top - 14, 328, top);
      page.line('a third column of body text', 342, top - 14, 472, top);
    }
    page.line('Table 2: Accuracy summary', 54, 460, 214, 474);
    for (var i = 0; i <= 5; i++) {
      final top = 430.0 - 20 * i;
      for (var c = 0; c <= 4; c++) {
        final l = 54.0 + 74 * c;
        page.line('12.4', l, top - 12, l + 70, top);
      }
    }
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
);

/// The exact rect fixture Z used to emit: twelve rows of prose in three
/// columns, captioned "Table 2: Accuracy summary".
const PdfRect kProseThreeColumnsBadRect = (
  left: 54,
  top: 744,
  right: 472,
  bottom: 502,
);

/// Fixture AA — a standard two-column CHINESE page, 32 rows, with a table
/// caption at the foot. THE SHIPPING BLOCKER: pdfrx splits fragments on
/// whitespace only, so a Chinese line is ONE fragment ⇒ "one word" ⇒ "a table
/// cell", at any width under the cell cap. The classifier got this page
/// completely right (tabular=0, blocksGrowth for all 65 lines, corridor
/// detected at 290–310) and was overruled by a block detector that applied
/// none of its defences: l=60 b=108 r=540 t=744 — a 480×636pt crop, 63% of
/// the page, 64 lines of prose at 67.2% ink. The English control at the same
/// measure correctly emitted nothing.
FigureFixture fixtureCjkTwoColumnPage() => FigureFixture(
  name: 'AA Chinese two-column body page',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i < 32; i++) {
      final top = 740.0 - 20 * i;
      page.line('这是一行普通的中文正文内容用于测试排版', 60, top - 14, 290, top);
      page.line('这是一行普通的中文正文内容用于测试排版', 310, top - 14, 540, top);
    }
    page.line('表2：准确率汇总', 60, 90, 220, 104);
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
  zhText: true,
);

/// The same page in Japanese (kana + kanji): identical failure, identical fix.
FigureFixture fixtureJapaneseTwoColumnPage() => FigureFixture(
  name: 'AB Japanese two-column body page',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i < 32; i++) {
      final top = 740.0 - 20 * i;
      page.line('これは組版のテストに使う普通の日本語の本文です', 60, top - 14, 290, top);
      page.line('これは組版のテストに使う普通の日本語の本文です', 310, top - 14, 540, top);
    }
    page.line('表2：精度のまとめ', 60, 90, 220, 104);
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
  zhText: true,
);

/// The exact rect fixtures AA and AB used to emit.
const PdfRect kCjkTwoColumnBadRect = (
  left: 60,
  top: 744,
  right: 540,
  bottom: 108,
);

/// The English control for AA/AB at the same measure: a two-column English
/// page whose cells hold nine words each. It emitted nothing before the fix
/// and must keep emitting nothing — the point being that the CJK page differs
/// from it only in how many FRAGMENTS one line is made of.
List<PageTextItem> cjkControlEnglishPage() => _pageLines((page) {
  for (var i = 0; i < 32; i++) {
    final top = 740.0 - 20 * i;
    page.line(
      'the quick brown fox jumps over the lazy dog again',
      60,
      top - 14,
      290,
      top,
    );
    page.line(
      'another line of ordinary running prose for tests',
      310,
      top - 14,
      540,
      top,
    );
  }
  page.line('Table 2: Accuracy summary', 60, 90, 220, 104);
});

/// Fixture AC — three 130pt columns with a table caption at the foot, and its
/// OCR twin ([fixtureThreeNarrowColumnsOcr]), which carries the same page as
/// Step-12 block bounds. The text-layer page emitted l=54 b=142 r=472 t=744 at
/// 67.4% ink; the OCR page emitted the same rect at 65.1%, through a
/// different door — an OCR block has no word breakdown at all, so round 3 fell
/// back to width alone. Both now read the block's TEXT.
FigureFixture fixtureThreeNarrowColumnsTable() => FigureFixture(
  name: 'AC three 130pt columns under a table caption',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _threeNarrowColumnLines(),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
);

/// The OCR twin of [fixtureThreeNarrowColumnsTable]: whole-block rects with
/// no fragment breakdown, exactly as Step 12 stores them.
FigureFixture fixtureThreeNarrowColumnsOcr() => FigureFixture(
  name: 'AD three 130pt columns, OCR blocks',
  pageWidth: 612,
  pageHeight: 792,
  textItems: const [],
  ocrItems: [
    for (var i = 0; i < 30; i++) ...[
      _line(
        'the quick brown fox jumps over',
        54,
        726.0 - 20 * i,
        184,
        740.0 - 20 * i,
      ),
      _line(
        'another line of running prose',
        198,
        726.0 - 20 * i,
        328,
        740.0 - 20 * i,
      ),
      _line(
        'a third column of body text',
        342,
        726.0 - 20 * i,
        472,
        740.0 - 20 * i,
      ),
    ],
    _line('Table 2: Accuracy summary', 54, 120, 214, 134),
  ],
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
);

List<PageTextItem> _threeNarrowColumnLines() => _pageLines((page) {
  for (var i = 0; i < 30; i++) {
    final top = 740.0 - 20 * i;
    page.line('the quick brown fox jumps over', 54, top - 14, 184, top);
    page.line('another line of running prose', 198, top - 14, 328, top);
    page.line('a third column of body text', 342, top - 14, 472, top);
  }
  page.line('Table 2: Accuracy summary', 54, 120, 214, 134);
});

/// The exact rect fixtures AC and AD used to emit.
const PdfRect kThreeNarrowColumnsBadRect = (
  left: 54,
  top: 744,
  right: 472,
  bottom: 142,
);

/// Fixture AE — three body lines with a MARGINAL GLOSS beside each ("see note
/// 1"), a figure caption below them and discussion under that. A gutter was
/// accepted when only ONE flank was table-shaped and then marked BOTH flanks
/// tabular, so a short marginal item — a margin gloss, an equation number, a
/// verse number — turned the body line beside it into a "table row", which
/// stops blocking: the figure grew straight over the paragraph to the page
/// top (l=72 b=398 r=400 t=788). Deleting the glosses gave the right answer,
/// which is what identified the cause.
FigureFixture fixtureMarginalGlosses() => FigureFixture(
  name: 'AE body lines with marginal glosses',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i <= 2; i++) {
      final top = 750.0 - 14 * i;
      page.line(
        'the quick brown fox jumps over the lazy',
        72,
        top - 12,
        400,
        top,
      );
      page.line('see note ${i + 1}', 440, top - 12, 510, top);
    }
    page.line('Figure 3: Latency by payload size', 72, 380, 320, 394);
    page.line('Discussion continues after the plot.', 72, 348, 400, 360);
    page.line('A second line of that discussion.', 72, 334, 400, 346);
  }),
  truthRect: (left: 72, top: 706, right: 460, bottom: 398),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 3',
);

/// The exact rect fixture AE used to emit — the three prose lines inside it.
const PdfRect kMarginalGlossesBadRect = (
  left: 72,
  top: 788,
  right: 400,
  bottom: 398,
);

/// A page of DOUBLE-SPACED body lines (28pt pitch on an 11pt box) with a
/// caption at the foot, for the FP-3 sweep. No two lines were run partners
/// past 0.9× the glyph box, so nothing blocked and the whole page came back
/// as a figure at n = 4, 6, 7 and 8 narrow lines (and n = 3, 4 full-measure
/// ones); only the flat weighted-line cliff at n = 9 stopped it. A line-count
/// cliff cannot be the last defence — the page's own leading is now measured.
List<PageTextItem> doubleSpacedProsePage({
  required int lines,
  bool fullMeasure = false,
}) => _pageLines((page) {
  for (var i = 0; i < lines; i++) {
    final top = 740.0 - 28 * i;
    page.line(
      fullMeasure
          ? 'the quick brown fox jumps over the lazy dog and then some more'
          : 'the quick brown fox jumps',
      72,
      top - 11,
      fullMeasure ? 540 : 272,
      top,
    );
  }
  page.line('Figure 2: Caption at the foot', 72, 320, 300, 334);
});

/// The exact rect the FP-3 pages used to emit: the whole page.
const PdfRect kDoubleSpacedProseBadRect = (
  left: 72,
  top: 788,
  right: 540,
  bottom: 338,
);

/// Fixture AF — a LIST OF FIGURES page: a heading and eight entries at a 24pt
/// pitch, each a perfectly good caption string announcing a figure on another
/// page. The first entry claimed the band above it — the heading — as a
/// 0.9-confidence figure: l=72 b=704 r=540 t=788. Every thesis has this page.
FigureFixture fixtureListOfFigures() => FigureFixture(
  name: 'AF list of figures page',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('List of Figures', 72, 740, 200, 756);
    for (var i = 0; i < 8; i++) {
      final top = 700.0 - 24 * i;
      page.line(
        'Figure ${i + 1}: A descriptive title of the figure    ${10 + i}',
        72,
        top - 12,
        540,
        top,
      );
    }
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 8,
  expectedRegions: 0,
  // All eight ARE caption strings; none of them captions anything here.
  expectedTrueCaptions: 8,
);

/// The exact rect fixture AF used to emit.
const PdfRect kListOfFiguresBadRect = (
  left: 72,
  top: 788,
  right: 540,
  bottom: 704,
);

/// Fixture AG — twelve verse lines with verse NUMBERS in the margin and a
/// caption below them. The 66pt strip between the poem and its caption is
/// empty; it cleared the flat 60pt content-free floor, and its width came
/// from MIRRORING the caption's own left margin (612 − 90), not from any
/// evidence: a blank 432×66pt PNG containing 0 items and 0% ink, captioned
/// "Figure 9: Sonnet layout".
FigureFixture fixtureVerseBlankBand() => FigureFixture(
  name: 'AG verse page with a blank strip above its caption',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    for (var i = 0; i < 12; i++) {
      final top = 740.0 - 20 * i;
      page.line('a narrow line of verse here', 90, top - 12, 300, top);
      page.line('${i + 1}', 320, top - 12, 340, top);
    }
    page.line('Figure 9: Sonnet layout', 90, 420, 260, 434);
  }),
  truthRect: _noFigure,
  expectedRegexAnchors: 1,
  expectedRegions: 0,
  expectedTrueCaptions: 1,
);

/// The exact blank rect fixture AG used to emit.
const PdfRect kVerseBlankBandBadRect = (
  left: 90,
  top: 504,
  right: 522,
  bottom: 438,
);

/// Fixture AH — a five-row income statement: text labels on the left, two
/// RIGHT-ALIGNED money columns whose digit counts differ from row to row.
/// Column alignment was measured on cell LEFT edges only, so "1,234" over
/// "12,345" broke the block at row 2 and the page fell back to the blockless
/// path — which has no trimming at all: l=72 b=4 r=380 t=696, a 692pt band
/// for a 122pt table, IoU 0.163, with the third money column outside the crop
/// entirely. Adding prose below the table produced NO region at all.
FigureFixture fixtureRightAlignedNumericTable({bool proseBelow = false}) =>
    FigureFixture(
      name: proseBelow
          ? 'AI income statement with prose below'
          : 'AH income statement, right-aligned columns',
      pageWidth: 612,
      pageHeight: 792,
      textItems: _pageLines((page) {
        page.line('Table 4: Consolidated income statement', 72, 700, 380, 714);
        const labels = [
          'Revenue',
          'Cost of sales',
          'Gross profit',
          'Operating expenses',
          'Net income',
        ];
        const col2 = ['1,234', '12,345', '123,456', '9,876', '54,321'];
        const col3 = ['999', '8,888', '77,777', '666', '5,555'];
        for (var i = 0; i < 5; i++) {
          final top = 674.0 - 20 * i;
          page.line(labels[i], 72, top - 12, 72 + 7.0 * labels[i].length, top);
          page.line(col2[i], 380 - 7.0 * col2[i].length, top - 12, 380, top);
          page.line(col3[i], 520 - 7.0 * col3[i].length, top - 12, 520, top);
        }
        if (proseBelow) {
          for (var i = 0; i < 4; i++) {
            final top = 540.0 - 14 * i;
            page.line(
              'discussion of the results continues below the table',
              72,
              top - 12,
              540,
              top,
            );
          }
        }
      }),
      truthRect: (left: 70, top: 680, right: 522, bottom: 576),
      truthIsTable: true,
      expectedRegexAnchors: 1,
      expectedRegions: 1,
      expectedCaptionContains: 'Table 4',
    );

/// The exact rect fixture AH used to emit.
const PdfRect kRightAlignedTableBadRect = (
  left: 72,
  top: 696,
  right: 380,
  bottom: 4,
);

/// Fixture AJ — a table with a MERGED HEADER row (one spanning cell over the
/// columns). A spanning header has no gutter, so block detection broke on the
/// FIRST row, never reached [kTableBlockMinRows], and the page reverted to the
/// untrimmed blockless path: l=72 b=4 r=440 t=696, IoU 0.199 — the round-2
/// fixture-T regression, re-achieved by a different route.
FigureFixture fixtureMergedHeaderTable() => FigureFixture(
  name: 'AJ table with a merged header row',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Table 6: Ablation over model sizes', 72, 700, 340, 714);
    page.line('Model configuration and accuracy', 72, 662, 440, 674);
    for (var i = 0; i < 5; i++) {
      final top = 642.0 - 20 * i;
      page.line('small', 72, top - 12, 140, top);
      page.line('12.4', 240, top - 12, 300, top);
      page.line('23.7', 380, top - 12, 440, top);
    }
  }),
  truthRect: (left: 70, top: 676, right: 442, bottom: 548),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 6',
);

/// The exact rect fixture AJ used to emit.
const PdfRect kMergedHeaderTableBadRect = (
  left: 72,
  top: 696,
  right: 440,
  bottom: 4,
);

/// Fixture AK — a table with a BLANK SEPARATOR ROW in the middle (rows at
/// 674, 654, 634, then 594, 574, 554). A skipped row is a missing point on
/// the table's lattice at exactly 2× the pitch, which round 3's flat 1.6×
/// tolerance could not span: the block stopped at the separator, the region
/// covered only the first three rows (IoU 0.424) — and the crop LOOKED
/// complete, which is the dangerous part.
FigureFixture fixtureSeparatorRowTable() => FigureFixture(
  name: 'AK table with a blank separator row',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    page.line('Table 7: Results with a separator', 72, 700, 340, 714);
    for (final top in [674.0, 654.0, 634.0, 594.0, 574.0, 554.0]) {
      page.line('north', 72, top - 12, 140, top);
      page.line('12.4', 240, top - 12, 300, top);
      page.line('23.7', 380, top - 12, 440, top);
    }
  }),
  truthRect: (left: 70, top: 676, right: 442, bottom: 540),
  truthIsTable: true,
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Table 7',
);

/// The exact truncated rect fixture AK used to emit (three of six rows).
const PdfRect kSeparatorRowTableBadRect = (
  left: 72,
  top: 678,
  right: 440,
  bottom: 618,
);

/// A single-column page at a given line PITCH with a figure between two
/// paragraphs, for the FN-4 sweep. At 11pt glyph boxes, pitches of 21, 22, 24
/// and 28pt produced NO region at all — nothing was a run partner past 0.9×
/// the box, so nothing blocked and the band overgrew into a rejection.
/// Theses, court filings, review drafts and line-numbered pleadings are all
/// double-spaced.
List<PageTextItem> doubleSpacedFigurePage({required double pitch}) =>
    _pageLines((page) {
      for (var i = 0; i < 6; i++) {
        final top = 758.0 - pitch * i;
        page.line(
          'the quick brown fox jumps over the lazy dog again',
          72,
          top - 11,
          540,
          top,
        );
      }
      page.line('Figure 2: Throughput versus offered load', 90, 380, 430, 394);
      for (var i = 0; i < 4; i++) {
        final top = 360.0 - pitch * i;
        page.line(
          'the quick brown fox jumps over the lazy dog again',
          72,
          top - 11,
          540,
          top,
        );
      }
    });

/// Fixture AL — a two-column page whose LEFT column holds the figure, and
/// whose right column happens to be clear beside it. The "clear side" extent
/// rule reached for the page's text margin without consulting the corridor
/// [detectLayoutCorridors] had already found at 278–324, and the region
/// spanned BOTH columns: l=54 b=398 r=548 t=606, IoU 0.445.
FigureFixture fixtureLeftColumnFigureClearRight() => FigureFixture(
  name: 'AL two-column page, figure in the left column',
  pageWidth: 612,
  pageHeight: 792,
  textItems: _pageLines((page) {
    const line = 'the quick brown fox jumps over the lazy dog';
    for (var i = 0; i < 11; i++) {
      final top = 730.0 - 12 * i;
      page.line(line, 54, top - 10, 278, top);
    }
    page.line('Figure 3: Latency by payload size', 54, 386, 200, 400);
    for (var i = 0; i < 23; i++) {
      final top = 374.0 - 12 * i;
      page.line(line, 54, top - 10, 278, top);
    }
    for (var i = 0; i < 52; i++) {
      final top = 730.0 - 12 * i;
      if (top < 620 && top > 380) continue; // The right column's own figure.
      page.line(line, 324, top - 10, 548, top);
    }
  }),
  truthRect: (left: 54, top: 596, right: 290, bottom: 404),
  expectedRegexAnchors: 1,
  expectedRegions: 1,
  expectedCaptionContains: 'Figure 3',
);

/// The exact column-crossing rect fixture AL used to emit.
const PdfRect kLeftColumnFigureBadRect = (
  left: 54,
  top: 606,
  right: 548,
  bottom: 398,
);

/// A page of JUSTIFIED prose with a given inter-word gap, plus a caption at
/// the foot. Justified text stretches its word spaces; once those spaces
/// reach the cell-gutter floor, every line looks like a table row whose
/// gutters happen to align with the next line's. Used by the gutter sweep
/// test (the reproduced failure: 6pt gaps → 24 of 26 lines tabular).
List<PageTextItem> justifiedProsePage({
  required double wordGap,
  int lines = 26,
  double pageWidth = 612,
}) {
  const words = [
    'the',
    'quick',
    'brown',
    'fox',
    'jumped',
    'over',
    'lazy',
    'dogs',
    'again',
    'and',
    'then',
    'some',
    'more',
    'words',
  ];
  final page = _Page();
  for (var i = 0; i < lines; i++) {
    final top = 740.0 - i * 14;
    final text = [
      for (var w = 0; w < 9; w++) words[(i * 7 + w * 3) % words.length],
    ].join(' ');
    page.line(text, 72, top - 12, 540, top, wordGap: wordGap);
  }
  page.line('Figure 2: Caption at the foot', 72, 320, 300, 334);
  return page.build();
}

/// All spike fixtures in report order.
List<FigureFixture> allSpikeFixtures() => [
  fixtureSingleColumn(),
  fixtureTable(),
  fixtureChineseScanned(),
  fixtureTwoColumn(),
  fixtureWhitespaceOnly(),
  fixtureInFigureWideText(),
  fixtureWrappedTableCaption(),
  fixtureWrappedFigureCaption(),
  fixtureAllNarrowLines(),
  fixtureTwoColumnBodyOnly(),
  fixtureTwoColumnFigure(),
  fixtureThreeColumn(),
  fixtureInFigureLegend(),
  fixtureTickLabelStack(),
  fixtureCaptionThenParagraph(),
  fixtureLoneLinesPage(),
  fixtureWideCellTable(),
  fixtureProseColumnsOverTable(),
  fixtureFullWidthCaptionUnderColumns(),
  fixtureTableToPageEdge(),
  fixtureFullPagePlate(),
  fixtureAppendixTablePage(),
  fixtureLabelledDiagram(),
  fixtureDescriptionColumnTable(),
  fixtureSubCaptions(),
  fixtureProseThreeColumnsOverTable(),
  fixtureCjkTwoColumnPage(),
  fixtureJapaneseTwoColumnPage(),
  fixtureThreeNarrowColumnsTable(),
  fixtureThreeNarrowColumnsOcr(),
  fixtureMarginalGlosses(),
  fixtureListOfFigures(),
  fixtureVerseBlankBand(),
  fixtureRightAlignedNumericTable(),
  fixtureRightAlignedNumericTable(proseBelow: true),
  fixtureMergedHeaderTable(),
  fixtureSeparatorRowTable(),
  fixtureLeftColumnFigureClearRight(),
];

/// Emits [fixture] as a real PDF: the truth rect is drawn as a filled
/// colored rectangle and every text item is drawn at its declared bounds
/// (font size = rect height − 2, baseline ~2pt above rect bottom). Used by
/// the skipped-by-default live-pdfrx integration test.
///
/// CJK text needs a unicode TTF ([cjkFontPath], checked for existence);
/// when unavailable, CJK-flagged items are silently skipped (the built-in
/// Helvetica cannot encode them) — live zh assertions must gate on the font.
Future<Uint8List> buildFixturePdf(
  FigureFixture fixture, {
  String cjkFontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
}) async {
  final doc = pdflib.PdfDocument();
  final page = pdflib.PdfPage(
    doc,
    pageFormat: pdflib.PdfPageFormat(fixture.pageWidth, fixture.pageHeight),
  );
  final g = page.getGraphics();

  // The ground-truth figure/table area.
  g.setFillColor(pdflib.PdfColors.lightBlue);
  g.drawRect(
    fixture.truthRect.left,
    fixture.truthRect.bottom,
    fixture.truthRect.right - fixture.truthRect.left,
    fixture.truthRect.top - fixture.truthRect.bottom,
  );
  g.fillPath();

  final helvetica = pdflib.PdfFont.helvetica(doc);
  pdflib.PdfFont? cjkFont;
  final cjkFile = File(cjkFontPath);
  if (await cjkFile.exists()) {
    cjkFont = pdflib.PdfTtfFont(
      doc,
      (await cjkFile.readAsBytes()).buffer.asByteData(),
    );
  }

  g.setFillColor(pdflib.PdfColors.black);
  for (final item in fixture.allItems) {
    final needsCjk = item.text.runes.any((r) => r > 0x2E7F);
    final font = needsCjk ? cjkFont : helvetica;
    if (font == null) continue; // No CJK font available on this machine.
    final size = (item.rect.top - item.rect.bottom) - 2;
    g.drawString(font, size, item.text, item.rect.left, item.rect.bottom + 2);
  }

  return doc.save();
}
