// Unit tests + Step-13 SPIKE for FigureRegionExtractor (plan §4.1).
//
// pdfrx/pdfium cannot initialize headless under flutter_tester (see
// attachment_text_extractor.dart header), so the spike validates the
// region-inference MATH through a fake source built from the fixtures'
// KNOWN ground-truth geometry (test/search/figure_fixtures.dart — the same
// geometry the `pdf` package draws into real PDFs at exact coordinates).
// The live-pdfrx pass is a skipped-by-default integration test at the
// bottom, mirroring the pdf_text extractor's.

// ignore_for_file: avoid_print -- the spike group prints its metrics report.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/services/search/attachment_ocr_extractor.dart'
    show PdfRect;
import 'package:note_synapse/services/search/figure_region_extractor.dart';

import 'figure_fixtures.dart';

/// Recording fake of the pdfrx seam. Renders deterministic pseudo-PNG bytes
/// derived from the render arguments, so asset-hash determinism is testable.
class FakeFigureSource implements PdfFigureSource {
  FakeFigureSource(
    this.pages, {
    this.onLoadPage,
    this.renderReturnsNull = false,
    this.failRenderAt,
  });

  final List<PdfFigurePage> pages;
  final void Function(int pageIndex)? onLoadPage;
  final bool renderReturnsNull;

  /// 0-based index (over all render calls) of a single render to fail.
  final int? failRenderAt;

  final List<Map<String, num>> renderCalls = [];
  bool disposed = false;

  @override
  int get pageCount => pages.length;

  @override
  Future<PdfFigurePage> loadPage(int pageIndex) async {
    onLoadPage?.call(pageIndex);
    return pages[pageIndex];
  }

  @override
  Future<Uint8List?> renderRegionPng(
    int pageIndex, {
    required int x,
    required int y,
    required int width,
    required int height,
    required double fullWidth,
    required double fullHeight,
  }) async {
    final callIndex = renderCalls.length;
    renderCalls.add({
      'page': pageIndex,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'fullWidth': fullWidth,
      'fullHeight': fullHeight,
    });
    if (renderReturnsNull || callIndex == failRenderAt) return null;
    return Uint8List.fromList(
      utf8.encode(
        'png:$pageIndex:$x:$y:$width:$height:'
        '${fullWidth.round()}:${fullHeight.round()}',
      ),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// Fake whose [loadPage] throws for the given 0-based page indexes.
class ThrowingPageSource extends FakeFigureSource {
  ThrowingPageSource(super.pages, {required this.throwOnPages});

  final Set<int> throwOnPages;

  @override
  Future<PdfFigurePage> loadPage(int pageIndex) async {
    if (throwOnPages.contains(pageIndex)) {
      throw StateError('page $pageIndex is broken');
    }
    return super.loadPage(pageIndex);
  }
}

/// Line classification for a whole fixture (the same inputs
/// [inferFigureRegions] uses).
List<PageLineClass> classifyFixture(FigureFixture fixture) => classifyPageLines(
  fixture.allItems,
  pageWidthPts: fixture.pageWidth,
  pageHeightPts: fixture.pageHeight,
  captionIndexes: {
    for (final a in detectCaptionAnchors(fixture.allItems)) a.itemIndex,
  },
);

PdfFigurePage pageOf(FigureFixture fixture, {bool textOnly = false}) =>
    PdfFigurePage(
      pageWidthPts: fixture.pageWidth,
      pageHeightPts: fixture.pageHeight,
      items: textOnly ? fixture.textItems : fixture.allItems,
    );

void main() {
  late Directory tempDir;
  late Directory derivedDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('figure_extractor_test');
    derivedDir = Directory('${tempDir.path}/derived');
    await derivedDir.create(recursive: true);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<Attachment> buildAttachment({
    String id = 'att1',
    String fileName = 'doc.pdf',
    bool createFile = true,
  }) async {
    final path = '${tempDir.path}/$fileName';
    if (createFile) await File(path).writeAsString('dummy pdf bytes');
    return Attachment(
      id: id,
      noteId: 'n1',
      filePath: path,
      fileName: fileName,
      fileType: fileName.split('.').last,
      createdAt: DateTime.now(),
      isRelativePath: false,
    );
  }

  FigureRegionExtractor buildExtractor(
    FakeFigureSource source, {
    double minConfidence = kDefaultMinConfidence,
    void Function()? onOpen,
  }) => FigureRegionExtractor(
    opener: (path) async {
      onOpen?.call();
      return source;
    },
    derivedDirLoader: () async => derivedDir,
    minConfidence: minConfidence,
  );

  // ─── SPIKE: caption detection + region inference vs ground truth ─────────

  group(
    'SPIKE: synthetic fixtures (fake source from ground-truth geometry)',
    () {
      test('caption detection + region IoU metrics', () {
        final fixtures = allSpikeFixtures();
        var regexMatches = 0;
        var regexTrueCaptions = 0;
        var emittedCaptioned = 0;
        var emittedCorrect = 0;
        final lines = <String>[];
        final failures = <String>[];

        for (final fixture in fixtures) {
          final anchors = detectCaptionAnchors(fixture.allItems);
          if (anchors.length != fixture.expectedRegexAnchors) {
            failures.add(
              '${fixture.name}: ${anchors.length} regex anchors, expected '
              '${fixture.expectedRegexAnchors}',
            );
          }
          regexMatches += anchors.length;
          regexTrueCaptions += fixture.expectedTrueCaptions;

          final regions = inferFigureRegions(
            page: 1,
            pageWidthPts: fixture.pageWidth,
            pageHeightPts: fixture.pageHeight,
            items: fixture.allItems,
          );
          final captioned = regions
              .where((r) => r.source == FigureRegionSource.captioned)
              .toList();
          emittedCaptioned += captioned.length;
          if (captioned.length != fixture.expectedRegions) {
            failures.add(
              '${fixture.name}: ${captioned.length} captioned regions, '
              'expected ${fixture.expectedRegions} — '
              '${captioned.map((r) => r.rectPdf).toList()}',
            );
            lines.add(
              'SPIKE ${fixture.name}: anchors=${anchors.length} '
              'regions=${captioned.length} (EXPECTED '
              '${fixture.expectedRegions}) ${captioned.map((r) => r.rectPdf)}',
            );
            continue;
          }

          if (fixture.expectedRegions == 0) {
            lines.add(
              'SPIKE ${fixture.name}: anchors=${anchors.length} '
              'regions=0 (as expected)',
            );
            continue;
          }
          final region = captioned.single;
          expect(region.caption, contains(fixture.expectedCaptionContains!));
          expect(region.confidence, kCaptionedConfidence);
          final score = iou(region.rectPdf, fixture.truthRect);
          if (score <= fixture.minIou) {
            failures.add(
              '${fixture.name}: IoU ${score.toStringAsFixed(3)} '
              '<= ${fixture.minIou} for ${region.rectPdf}',
            );
          } else {
            emittedCorrect += 1;
          }
          lines.add(
            'SPIKE ${fixture.name}: anchors=${anchors.length} regions=1 '
            'IoU=${score.toStringAsFixed(3)} caption="${region.caption}"',
          );
        }

        final expectedRegions = fixtures.fold<int>(
          0,
          (sum, f) => sum + f.expectedRegions,
        );
        final regexPrecision = regexTrueCaptions / regexMatches;
        final pipelinePrecision = emittedCorrect / emittedCaptioned;
        lines.add(
          'SPIKE totals: regex caption precision '
          '$regexTrueCaptions/$regexMatches='
          '${regexPrecision.toStringAsFixed(2)} '
          '(the "Figure 4 shows…" body line matches the regex), '
          'pipeline precision $emittedCorrect/$emittedCaptioned='
          '${pipelinePrecision.toStringAsFixed(2)} '
          '(geometry rejects it: no text-free gap above a body line), '
          'recall $emittedCorrect/$expectedRegions',
        );
        lines.forEach(print);
        expect(failures, isEmpty, reason: failures.join('\n'));

        expect(pipelinePrecision, 1.0);
        expect(emittedCorrect, expectedRegions);
        // One true caption per fixture except E (none by design) and Y (a
        // parent caption plus its two sub-figure captions), plus the one
        // known "Figure 4 shows…" body-line false positive.
        expect(
          regexTrueCaptions,
          fixtures.fold<int>(0, (sum, f) => sum + f.expectedTrueCaptions),
        );
        expect(regexMatches, regexTrueCaptions + 1);
      });

      test('caption-less whitespace candidate: gated by default, emitted at a '
          'lowered threshold', () {
        final fixture = fixtureWhitespaceOnly();

        final gated = inferFigureRegions(
          page: 1,
          pageWidthPts: fixture.pageWidth,
          pageHeightPts: fixture.pageHeight,
          items: fixture.allItems,
        );
        expect(
          gated,
          isEmpty,
          reason: 'default threshold admits captioned only',
        );

        final admitted = inferFigureRegions(
          page: 1,
          pageWidthPts: fixture.pageWidth,
          pageHeightPts: fixture.pageHeight,
          items: fixture.allItems,
          minConfidence: 0.3,
        );
        final candidate = admitted.single;
        expect(candidate.source, FigureRegionSource.whitespace);
        expect(candidate.confidence, kWhitespaceConfidence);
        expect(candidate.caption, isNull);
        final score = iou(candidate.rectPdf, fixture.truthRect);
        print(
          'SPIKE ${fixture.name}: whitespace candidate '
          'IoU=${score.toStringAsFixed(3)} conf=${candidate.confidence} '
          '(emitted only below threshold ${kWhitespaceConfidence + 0.1})',
        );
        expect(score, greaterThan(0.5));
      });

      test('whitespace band already claimed by a captioned region is not '
          'duplicated', () {
        final fixture = fixtureSingleColumn();
        final regions = inferFigureRegions(
          page: 1,
          pageWidthPts: fixture.pageWidth,
          pageHeightPts: fixture.pageHeight,
          items: fixture.allItems,
          minConfidence: 0.3,
        );
        final captioned = regions
            .where((r) => r.source == FigureRegionSource.captioned)
            .single;
        for (final r in regions) {
          if (r.source != FigureRegionSource.whitespace) continue;
          expect(
            iou(r.rectPdf, captioned.rectPdf),
            lessThan(0.5),
            reason: 'whitespace candidates must not re-report the figure band',
          );
        }
      });

      test(
        'spike PDFs are generated by the pdf package (exact coordinates)',
        () async {
          for (final fixture in allSpikeFixtures().take(4)) {
            final bytes = await buildFixturePdf(fixture);
            expect(
              bytes.length,
              greaterThan(800),
              reason: '${fixture.name}: PDF bytes',
            );
            final file = File(
              '${tempDir.path}/${fixture.name.split(' ').first}.pdf',
            );
            await file.writeAsBytes(bytes);
            expect(await file.exists(), isTrue);
          }
        },
      );
    },
  );

  // ─── Caption regex / anchors ──────────────────────────────────────────────

  group('caption anchor detection', () {
    PageTextItem item(String text) => PageTextItem(
      text: text,
      rect: (left: 72, top: 114, right: 300, bottom: 100),
    );

    test('accepted caption forms (en/zh, line-start)', () {
      const accepted = [
        'Figure 1: Overview',
        'Fig. 12 latency by payload',
        'fig 3',
        'FIGURE 2. Uppercase caption',
        'Table 4 results across seeds',
        'table 10',
        '图1：网络结构',
        '表 2 参数设置',
        '圖3 系統架構',
        '  Figure 5 leading whitespace',
        '\t图１全角数字',
        '表三 中文数字',
        'Figure 7: pipeline\nsecond detail line',
        'Figure 1a: sub-figure label',
        // IEEE mandates Roman table numbering; two-column IEEE papers are
        // the archetypal input for this whole feature. The numeral must
        // END the caption number: at end of line, at a separator, or at the
        // wide gap IEEE puts before a same-line title.
        'TABLE I',
        'TABLE II',
        'TABLE I  COMPARISON OF SCHEDULERS',
        'TABLE III: Ablation study',
        'Table II. Results across seeds',
        'Table VIII',
        'Figure IX) Layout of the system',
        'Figure XII—Overview',
        // Unicode separators real typesetting emits between keyword and
        // number (a non-breaking or thin space keeps them on one line).
        'Figure\u00a01: NBSP separator',
        'Figure\u20091 thin space',
        'Figure\u20031 em space',
        'Figure\u202f1 narrow NBSP',
        'Figure\u205f1 medium mathematical space',
        '图\u30001：表意空格', // U+3000 ideographic space
        '表\u00a02 参数设置',
      ];
      for (final text in accepted) {
        expect(
          detectCaptionAnchors([item(text)]),
          hasLength(1),
          reason: 'should accept: "$text"',
        );
      }
    });

    test(
      'rejected non-captions (mid-sentence, prefixes, plural, no number)',
      () {
        const rejected = [
          'The figure 3 shows the trend.',
          'Configure 5 settings first',
          'figures 2 and 3 are omitted',
          'Fig leaf 3',
          'tablet 5 specs',
          '表面上看 3 个方案都可行',
          '图书馆 3 层',
          'Figure',
          'Figure captions need numbers',
          '',
          'preamble line first\nFigure 2 only on the second line',
          // The Roman branch must not swallow ordinary words that happen to
          // start with a Roman letter (the pattern is case-insensitive, so
          // I/V/X/L/C/D/M all appear at the head of common words).
          'Fig. Ideal case for the method',
          'Figure Extraction pipeline',
          'Table ivory tower metrics',
          'Table Michael built',
          'Figure Overview of the system',
          // Round 2: acronyms and part numbers that ARE spellable in Roman
          // letters. DVD/ID are not canonical numerals; CLI (151), MIX
          // (1009), L (50) and M (1000) are, and are rejected because a
          // single space is not a caption separator.
          'Table DVD formats compared',
          'Table ID mapping for each run',
          'Figure CLI output of the tool',
          'Figure MIX of both approaches',
          'Table L2 cache miss rates',
          'Fig. M1 board temperatures',
          // …and the CJK numerals that head ordinary words.
          '表十分感谢各位的支持',
          '图一致性协议的实现',
          // Accepted trade-off: a Roman numeral followed by ONE space is no
          // longer a caption. Two-column IEEE PDFs put the title on its own
          // line (or after a wide gap), which both still match.
          'Table IV Results',
          'Fig. IX shows the layout',
        ];
        for (final text in rejected) {
          expect(
            detectCaptionAnchors([item(text)]),
            isEmpty,
            reason: 'should reject: "$text"',
          );
        }
      },
    );

    test('caption kind: table for Table/表, figure otherwise', () {
      expect(
        detectCaptionAnchors([item('Table 4 results')]).single.kind,
        CaptionKind.table,
      );
      expect(
        detectCaptionAnchors([item('表 2 参数')]).single.kind,
        CaptionKind.table,
      );
      expect(
        detectCaptionAnchors([item('Figure 1: x')]).single.kind,
        CaptionKind.figure,
      );
      expect(
        detectCaptionAnchors([item('Fig. 9')]).single.kind,
        CaptionKind.figure,
      );
      expect(
        detectCaptionAnchors([item('图1 结构')]).single.kind,
        CaptionKind.figure,
      );
      expect(
        detectCaptionAnchors([item('圖3 架構')]).single.kind,
        CaptionKind.figure,
      );
    });
  });

  // ─── Region inference specifics ───────────────────────────────────────────

  group('region inference', () {
    test('table prefers the text-free side (caption above → grows down)', () {
      final fixture = fixtureTable();
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: fixture.allItems,
      ).single;
      // The region must lie BELOW the caption (top of table area < caption
      // bottom of 640 + padding) and absorb the cell texts.
      expect(region.rectPdf.top, lessThan(640));
      expect(region.rectPdf.bottom, lessThan(420 - 12)); // Below last row.
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('two-column: region stays inside the caption column', () {
      final fixture = fixtureTwoColumn();
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: fixture.allItems,
      ).single;
      expect(
        region.rectPdf.left,
        greaterThanOrEqualTo(300),
        reason: 'must not bleed into the left column (x < 300)',
      );
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('OCR-only page (scanned): caption + region from OCR bounds alone', () {
      final fixture = fixtureChineseScanned();
      expect(fixture.textItems, isEmpty);
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: fixture.ocrItems,
      ).single;
      expect(region.caption, contains('图1'));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('caption-shaped body line yields no region (degenerate gap)', () {
      // "Figure 4 shows…" inside running text: lines directly above/below.
      final items = [
        PageTextItem(
          text: 'Body line directly above the false caption.',
          rect: (left: 72, top: 346, right: 540, bottom: 334),
        ),
        PageTextItem(
          text: 'Figure 4 shows the aggregate results in detail.',
          rect: (left: 72, top: 332, right: 540, bottom: 320),
        ),
        PageTextItem(
          text: 'Body line directly below the false caption.',
          rect: (left: 72, top: 318, right: 540, bottom: 306),
        ),
      ];
      expect(detectCaptionAnchors(items), hasLength(1));
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: items,
        ),
        isEmpty,
      );
    });

    test('wide in-figure text (chart title, axis title) is absorbed, not '
        'treated as a body line', () {
      final fixture = fixtureInFigureWideText();
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: fixture.allItems,
      ).single;
      // The 200pt chart title sits at y680–694 INSIDE the figure: if it
      // blocked, the region would be cut at ~676 and lose the top 50pt.
      expect(
        region.rectPdf.top,
        greaterThan(700),
        reason: 'the chart title must not clip the top off the figure',
      );
      // The 150pt x-axis title at y424–436 must be inside the region too;
      // when it blocked, the band collapsed to 22pt and nothing was emitted.
      expect(region.rectPdf.bottom, lessThan(424));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('a lone wide line is absorbed but a PAIR of stacked, aligned wide '
        'lines blocks (the run rule, at the same width)', () {
      PageTextItem line(
        String t,
        double bottom,
        double top, [
        double l = 200,
      ]) => PageTextItem(
        text: t,
        rect: (left: l, top: top, right: l + 200, bottom: bottom),
      );
      final base = [
        PageTextItem(
          text: 'Body text well above the figure.',
          rect: (left: 72, top: 758, right: 540, bottom: 746),
        ),
        PageTextItem(
          text: 'A second body line, so this is a paragraph.',
          rect: (left: 72, top: 744, right: 540, bottom: 732),
        ),
        PageTextItem(
          text: 'Figure 1: A plot',
          rect: (left: 90, top: 394, right: 300, bottom: 380),
        ),
      ];

      // One lone wide line inside the figure → absorbed; the band runs all
      // the way up to the real paragraph at 732.
      final lone = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: [...base, line('Chart title', 680, 694)],
      ).single;
      expect(lone.rectPdf.top, 728);

      // Two of them, stacked at leading distance and left-aligned → a
      // paragraph → the band stops under it.
      final paragraph = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: [
          ...base,
          line('A paragraph of prose here', 680, 694),
          line('continuing onto a second line', 666, 680),
        ],
      ).single;
      expect(paragraph.rectPdf.top, 662);
    });

    test('BLANK STRIP REGRESSION: the 42pt text-free gap above a wrapped '
        'table caption must never win over the table below it', () {
      final fixture = fixtureWrappedTableCaption();
      final regions = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: fixture.allItems,
      );
      final region = regions.single;
      // The exact reproduced failure: l=72 b=658 r=540 t=700 — a 468x42pt
      // strip of pure page whitespace between two body lines, rendered as a
      // blank PNG and shown in chat as "Table 2".
      expect(
        region.rectPdf,
        isNot((left: 72.0, top: 700.0, right: 540.0, bottom: 658.0)),
      );
      expect(
        region.rectPdf.top,
        lessThan(640),
        reason: 'the region must be BELOW the caption, where the table is',
      );
      // …and it must actually contain the table rows (y 524–606).
      expect(region.rectPdf.top, greaterThan(606));
      expect(region.rectPdf.bottom, lessThan(524));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('wrapped caption lines are folded into the caption, not treated as '
        'blockers', () {
      final fixture = fixtureWrappedTableCaption();
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: fixture.allItems,
      ).single;
      expect(region.caption, contains('Table 2: Results summary'));
      expect(
        region.caption,
        contains('dataset, averaged over five seeds'),
        reason: 'the wrap line is caption text',
      );

      final figureFixture = fixtureWrappedFigureCaption();
      final figureRegion = inferFigureRegions(
        page: 1,
        pageWidthPts: figureFixture.pageWidth,
        pageHeightPts: figureFixture.pageHeight,
        items: figureFixture.allItems,
      ).single;
      expect(
        figureRegion.caption,
        contains('scheduler under increasing offered load'),
      );
      expect(
        iou(figureRegion.rectPdf, figureFixture.truthRect),
        greaterThan(0.7),
      );
    });

    test('table rows that merged into wide lines are still table rows '
        '(gutters survive the merge)', () {
      final fixture = fixtureWrappedTableCaption();
      final classes = classifyFixture(fixture);
      for (var i = 0; i < fixture.allItems.length; i++) {
        final item = fixture.allItems[i];
        final isRow = item.text.startsWith('cell0');
        expect(classes[i].isTabular, isRow, reason: '"${item.text}" tabular?');
        if (isRow) {
          // 468pt wide (76% of the page) — the old width test called this
          // body text; it must not block.
          expect(item.rect.right - item.rect.left, 468);
          expect(classes[i].blocksGrowth, isFalse);
          // …and the row really did arrive as ONE merged line carrying its
          // per-word fragments (the production shape).
          expect(item.fragmentRects.length, 3);
        }
      }

      // A REAL two-column body page (52 lines a column, per-word fragments,
      // a 46pt corridor): not one line of it is a table row, and every one
      // of them blocks. Round 1 classified 104 of 105 as tabular.
      final twoColumn = fixtureTwoColumnBodyOnly();
      final columnClasses = classifyFixture(twoColumn);
      final bodyLines = [
        for (var i = 0; i < twoColumn.allItems.length; i++)
          if (!twoColumn.allItems[i].text.startsWith('Figure')) i,
      ];
      expect(bodyLines, hasLength(104));
      expect(
        bodyLines.where((i) => columnClasses[i].isTabular),
        isEmpty,
        reason: 'the inter-column corridor is not a table gutter',
      );
      expect(
        bodyLines.where((i) => !columnClasses[i].blocksGrowth),
        isEmpty,
        reason: 'every body line of a two-column page blocks growth',
      );
    });

    test('a page of narrow lines does not become a whole-page figure', () {
      final fixture = fixtureAllNarrowLines();
      expect(
        detectCaptionAnchors(fixture.allItems),
        hasLength(1),
        reason: 'the caption line is there; only the geometry says no',
      );
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: fixture.pageWidth,
          pageHeightPts: fixture.pageHeight,
          items: fixture.allItems,
        ),
        isEmpty,
      );
    });

    test('whole-page guard: many scattered narrow lines in a page-tall band '
        'are the page, not a figure', () {
      // Irregular spacing and shifting margins, so nothing forms a run and
      // nothing bounds the band — the guard is the only thing left.
      final items = <PageTextItem>[
        for (var i = 0; i < 10; i++)
          PageTextItem(
            text: 'scattered label $i',
            rect: (
              left: 72.0 + (i % 2) * 140,
              top: 780.0 - i * 74,
              right: 172.0 + (i % 2) * 140,
              bottom: 768.0 - i * 74,
            ),
          ),
        PageTextItem(
          text: 'Figure 4: Page bottom caption',
          rect: (left: 72, top: 34, right: 300, bottom: 20),
        ),
      ];
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: items,
        ),
        isEmpty,
      );

      // The same page-tall band with only a FEW labels is a real full-page
      // figure and still comes through.
      final fewLabels = [items[0], items[1], items[2], items.last];
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: fewLabels,
      ).single;
      expect(region.rectPdf.top, greaterThan(700));
    });

    test('small text-free area does not become a whitespace candidate', () {
      // Dense page: gaps well under 15% of page area.
      final items = <PageTextItem>[
        for (var top = 760.0; top >= 80; top -= 20)
          PageTextItem(
            text: 'body line',
            rect: (left: 72, top: top, right: 540, bottom: top - 12),
          ),
      ];
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: items,
          minConfidence: 0.0,
        ),
        isEmpty,
      );
    });
  });

  // ─── Round 2: the reproduced regressions ─────────────────────────────────
  //
  // Every case here was measured failing on the REALISTIC per-word input
  // path (see figure_fixtures.dart), which round 1's fixtures could not
  // express. The comment on each test carries the number it used to produce.

  group('round-2 regressions', () {
    List<FigureRegion> regionsOf(FigureFixture fixture) => inferFigureRegions(
      page: 1,
      pageWidthPts: fixture.pageWidth,
      pageHeightPts: fixture.pageHeight,
      items: fixture.allItems,
    );

    test('a real two-column body page yields NO region (was: the whole '
        'right column at l=324 b=98 r=548 t=788, confidence 0.9)', () {
      final fixture = fixtureTwoColumnBodyOnly();
      expect(
        detectCaptionAnchors(fixture.allItems),
        hasLength(1),
        reason: 'the caption is there; only the geometry says no',
      );
      expect(regionsOf(fixture), isEmpty);
    });

    test('the same page WITH a figure returns the hole, not the column '
        '(was: t=788 instead of t≈596, IoU 0.46)', () {
      final fixture = fixtureTwoColumnFigure();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf.top, closeTo(596, 1));
      expect(region.rectPdf.bottom, closeTo(404, 1));
      expect(region.rectPdf.left, greaterThanOrEqualTo(300));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('three narrow columns yield NO region — no fragments needed, so '
        'this is the OCR-page case too (was: the whole page)', () {
      final fixture = fixtureThreeColumn();
      final classes = classifyFixture(fixture);
      expect(
        classes.where((c) => c.isTabular),
        isEmpty,
        reason: '18pt column gutters are not table gutters',
      );
      expect(regionsOf(fixture), isEmpty);

      // …and the same page stripped of its fragments (what OCR delivers)
      // behaves identically.
      final ocrStyle = [
        for (final item in fixture.allItems)
          PageTextItem(text: item.text, rect: item.rect),
      ];
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: fixture.pageWidth,
          pageHeightPts: fixture.pageHeight,
          items: ocrStyle,
        ),
        isEmpty,
      );
    });

    test('a two-line in-figure legend does not truncate the plot '
        '(was: top 582, 146pt of plot lost)', () {
      final fixture = fixtureInFigureLegend();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf.top, 714);
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // The legend IS a geometric run — same margin, one line apart. What
      // saves the figure is that it does not FILL the strip.
      final classes = classifyFixture(fixture);
      final legend = [
        for (var i = 0; i < fixture.allItems.length; i++)
          if (fixture.allItems[i].text.startsWith('—')) i,
      ];
      expect(legend, hasLength(2));
      expect(classes[legend.first].inBodyRun, isTrue);
      expect(classes[legend.first].runGroup, classes[legend.last].runGroup);
    });

    test('a stack of ten tick labels does not truncate the plot '
        '(was: top 560, 168pt of plot lost)', () {
      final fixture = fixtureTickLabelStack();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf.top, 714);
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('a paragraph under a full-measure caption is not folded into it '
        '(was: four body lines became caption text and stopped blocking)', () {
      final fixture = fixtureCaptionThenParagraph();
      final region = regionsOf(fixture).single;
      expect(
        region.caption,
        'Figure 7: End-to-end latency of the proposed scheduler',
      );
      expect(region.caption, isNot(contains('Queueing dominates')));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('an INDENTED line under a caption starts a paragraph, it is not a '
        'wrap (round 1 only rejected lines starting further LEFT)', () {
      final items = [
        ...fixtureSingleColumn().textItems.take(3),
        PageTextItem(
          text: 'Figure 7: Overview of the pipeline',
          rect: (left: 72, top: 406, right: 372, bottom: 394),
        ),
        PageTextItem(
          text: 'We now turn to the evaluation.',
          rect: (left: 90, top: 392, right: 250, bottom: 380),
        ),
      ];
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: items,
      ).single;
      expect(region.caption, 'Figure 7: Overview of the pipeline');
    });

    test('a page of seven wide LONE lines yields NO region (was: '
        'l=72 b=58 r=372 t=788 — nothing forms a run, so nothing blocked)', () {
      final fixture = fixtureLoneLinesPage();
      expect(
        classifyFixture(fixture).where((c) => c.inBodyRun),
        isEmpty,
        reason: 'lines 100pt apart form no paragraph — density is the guard',
      );
      expect(regionsOf(fixture), isEmpty);
    });

    test('a two-column table with 37% cells is still a table '
        '(was: 0 regions, the table silently missing)', () {
      final fixture = fixtureWideCellTable();
      final region = regionsOf(fixture).single;
      expect(region.caption, contains('Table 5'));
      // The band must hold the rows (y 528–640), below the caption.
      expect(region.rectPdf.top, lessThan(660));
      expect(region.rectPdf.top, greaterThan(640));
      expect(region.rectPdf.bottom, lessThan(528));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // Same table with per-cell items and NO fragments (an OCR'd table):
      // the cell-width cap is what used to lose this, and it is applied to
      // the flanking cells now, at 45%.
      final classes = classifyFixture(fixture);
      final rows = [
        for (var i = 0; i < fixture.allItems.length; i++)
          if (fixture.allItems[i].text.contains('p99')) i,
      ];
      expect(rows, hasLength(6));
      for (final i in rows) {
        expect(classes[i].isTabular, isTrue);
        expect(classes[i].blocksGrowth, isFalse);
      }
    });

    test('a FULL-WIDTH figure on a two-column page: the column corridor is '
        'broken by the caption, so the gutter EXTENT rule has to catch it', () {
      // The caption spans both columns, so the page has no text-free
      // corridor at all and the corridor rule cannot fire. The 42 body rows
      // still share one gutter x down 63% of the page — a column layout,
      // not a 42-row table.
      final items = <PageTextItem>[];
      final page = <PageTextItem>[];
      for (final left in [54.0, 324.0]) {
        for (var top = 780.0; top >= 620; top -= 12) {
          page.addAll(
            wordFragments(
              'the quick brown fox jumps over the lazy dog',
              left,
              top - 10,
              left + 224,
              top,
            ),
          );
        }
        for (var top = 370.0; top >= 110; top -= 12) {
          page.addAll(
            wordFragments(
              'the quick brown fox jumps over the lazy dog',
              left,
              top - 10,
              left + 224,
              top,
            ),
          );
        }
      }
      page.addAll(
        wordFragments(
          'Figure 4: A figure spanning both columns of the page',
          54,
          386,
          548,
          400,
        ),
      );
      items.addAll(mergeFragmentsIntoLines(page));

      final classes = classifyPageLines(
        items,
        pageWidthPts: 612,
        pageHeightPts: 792,
        captionIndexes: {
          for (final a in detectCaptionAnchors(items)) a.itemIndex,
        },
      );
      expect(
        classes.where((c) => c.isTabular),
        isEmpty,
        reason: 'a gutter carried down 63% of the page is a column layout',
      );
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: items,
      ).single;
      expect(region.rectPdf.bottom, 404);
      expect(region.rectPdf.top, 610, reason: 'stops under the body above');
      expect(region.rectPdf.left, lessThan(60));
      expect(region.rectPdf.right, greaterThan(540));
    });

    test('justified prose never turns tabular, whatever its word spacing '
        '(was: 6pt gaps → 24 of 26 lines tabular)', () {
      final report = <String>[];
      for (final gap in [4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0]) {
        final items = justifiedProsePage(wordGap: gap);
        final classes = classifyPageLines(
          items,
          pageWidthPts: 612,
          pageHeightPts: 792,
          captionIndexes: {
            for (final a in detectCaptionAnchors(items)) a.itemIndex,
          },
        );
        final tabular = classes.where((c) => c.isTabular).length;
        final regions = inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: items,
        );
        report.add(
          'SPIKE justified prose wordGap=$gap: tabular=$tabular/'
          '${items.length - 1} regions=${regions.length}',
        );
        expect(
          regions,
          isEmpty,
          reason: 'wordGap $gap must not produce a figure region',
        );
        if (gap <= 8) {
          expect(
            tabular,
            0,
            reason: 'wordGap $gap is under the cell-gutter floor',
          );
        }
      }
      report.forEach(print);
    });
  });

  // ─── Round 3: the red team's reproduced defects ──────────────────────────
  //
  // Every geometry here was measured failing on the per-word path with the
  // exact coordinates in the comments. For the two false positives the bad
  // rect is pinned with `isNot`, the way the blank-strip regression is: the
  // failure mode is not "a slightly wrong crop", it is a screenshot of prose
  // shown in chat captioned as someone's table.

  group('round-3 regressions', () {
    List<FigureRegion> regionsOf(FigureFixture fixture) => inferFigureRegions(
      page: 1,
      pageWidthPts: fixture.pageWidth,
      pageHeightPts: fixture.pageHeight,
      items: fixture.allItems,
    );

    test('FP-1 two columns of PROSE under a table caption are not a table '
        '(was: l=60 b=500 r=540 t=788 — 18 prose lines, 43.8% ink, IoU 0.000 '
        'against the table it captioned)', () {
      final fixture = fixtureProseColumnsOverTable();
      final regions = regionsOf(fixture);
      final region = regions.single;
      expect(region.rectPdf, isNot(kProseColumnsBadRect));
      // The prose is ABOVE the caption; nothing above it may be claimed.
      expect(
        region.rectPdf.top,
        lessThan(480),
        reason: 'the region must be the table below the caption',
      );
      expect(region.rectPdf.right, greaterThan(430), reason: 'all 3 columns');
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // The prose rows are no longer "table rows": their cells hold running
      // text, so they block like the body text they are.
      final classes = classifyFixture(fixture);
      final prose = [
        for (var i = 0; i < fixture.allItems.length; i++)
          if (fixture.allItems[i].text.startsWith('the quick')) i,
      ];
      expect(prose, isNotEmpty);
      for (final i in prose) {
        expect(classes[i].isTabular, isFalse, reason: 'prose row $i');
        expect(classes[i].blocksGrowth, isTrue);
      }
    });

    test('FP-1 sweep: no lineHeight × gutter combination emits the prose band '
        '(was: 15 of 16)', () {
      for (final lineHeight in [8.0, 10.0, 12.0, 14.0]) {
        for (final gutter in [10.0, 16.0, 24.0, 40.0]) {
          final items = mergeFragmentsIntoLines([
            for (var i = 0; i < 9; i++) ...[
              ...wordFragments(
                'the quick brown fox jumps over lazy dog',
                60,
                700 - 20.0 * i - lineHeight,
                300 - gutter / 2,
                700 - 20.0 * i,
              ),
              ...wordFragments(
                'another line of ordinary running prose',
                300 + gutter / 2,
                700 - 20.0 * i - lineHeight,
                540,
                700 - 20.0 * i,
              ),
            ],
            ...wordFragments('Table 2: Accuracy summary', 60, 480, 220, 496),
            for (var i = 0; i < 5; i++) ...[
              ...wordFragments('12.4', 60, 438.0 - 20 * i, 160, 450.0 - 20 * i),
              ...wordFragments(
                '18.1',
                240,
                438.0 - 20 * i,
                300,
                450.0 - 20 * i,
              ),
              ...wordFragments(
                '23.7',
                380,
                438.0 - 20 * i,
                440,
                450.0 - 20 * i,
              ),
            ],
          ], pageHeightPts: 792);
          final regions = inferFigureRegions(
            page: 1,
            pageWidthPts: 612,
            pageHeightPts: 792,
            items: items,
          );
          final reason = 'lineHeight $lineHeight gutter $gutter';
          expect(regions, hasLength(1), reason: reason);
          expect(regions.single.rectPdf.top, lessThan(480), reason: reason);
        }
      }
    });

    test('FP-2 two columns above a full-width figure caption yield the band '
        'BETWEEN them, not the page (was: l=54 b=98 r=548 t=788 at density '
        '0.1183, or nothing at all past 9 lines)', () {
      final fixture = fixtureFullWidthCaptionUnderColumns();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf, isNot(kFullWidthCaptionBadRect));
      expect(
        region.rectPdf.top,
        lessThan(624),
        reason: 'the band stops under the prose, at its lowest line',
      );
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // The complement: the SAME layout at every line count, where 10..36
      // lines used to produce nothing at all.
      for (final n in [5, 10, 18, 36]) {
        final page = <PageTextItem>[];
        for (var i = 0; i < n; i++) {
          final top = 730.0 - 12 * i;
          page.addAll(
            wordFragments(
              'body text of the left column',
              54,
              top - 10,
              278,
              top,
            ),
          );
          page.addAll(
            wordFragments(
              'body text of the right column',
              324,
              top - 10,
              548,
              top,
            ),
          );
        }
        page.addAll(
          wordFragments(
            'Figure 2: End-to-end system architecture',
            54,
            80,
            548,
            94,
          ),
        );
        final regions = inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: mergeFragmentsIntoLines(page, pageHeightPts: 792),
        );
        expect(regions, hasLength(1), reason: 'n=$n');
        expect(
          regions.single.rectPdf.top,
          lessThan(730.0 - 12 * (n - 1)),
          reason: 'n=$n: the band starts under the lowest body line',
        );
        expect(regions.single.rectPdf.bottom, closeTo(98, 1), reason: 'n=$n');
      }
    });

    test('C-2 a table alone on a page is trimmed to the table and keeps every '
        'column (was: l=72 b=4 r=360 t=696 — 692pt for a 126pt table, third '
        'column outside, IoU 0.165)', () {
      final fixture = fixtureTableToPageEdge();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf, isNot(kTableToPageEdgeBadRect));
      expect(
        region.rectPdf.bottom,
        greaterThan(560),
        reason: 'trimmed to the last row (bottom 582), not the page edge',
      );
      expect(
        region.rectPdf.right,
        greaterThanOrEqualTo(520),
        reason: 'the third column at x 460–520 is inside the region',
      );
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // …at every column gap, including gaps far past any absorb reach.
      for (final gap in [12.0, 20.0, 40.0, 60.0]) {
        final page = <PageTextItem>[
          ...wordFragments('Table 1: Quarterly revenue', 72, 700, 340, 714),
        ];
        for (var i = 0; i < 5; i++) {
          final top = 674.0 - 20 * i;
          page.addAll(wordFragments('north', 72, top - 12, 200, top));
          page.addAll(
            wordFragments('12.4', 200 + gap, top - 12, 260 + gap, top),
          );
          page.addAll(
            wordFragments('23.7', 260 + 2 * gap, top - 12, 320 + 2 * gap, top),
          );
        }
        final region = inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: mergeFragmentsIntoLines(page, pageHeightPts: 792),
        ).single;
        expect(
          region.rectPdf.right,
          greaterThanOrEqualTo(320 + 2 * gap),
          reason: 'gap $gap: the last column is inside',
        );
        expect(region.rectPdf.bottom, greaterThan(560), reason: 'gap $gap');
      }
    });

    test('C-2 IEEE variant: a table inside ONE column of a two-column page '
        'claims that column only (was IoU 0.131)', () {
      final page = <PageTextItem>[];
      for (var top = 740.0; top >= 120; top -= 12) {
        page.addAll(
          wordFragments(
            'the quick brown fox jumps over the lazy dog',
            54,
            top - 10,
            278,
            top,
          ),
        );
      }
      for (var top = 740.0; top >= 620; top -= 12) {
        page.addAll(
          wordFragments(
            'the quick brown fox jumps over the lazy dog',
            324,
            top - 10,
            548,
            top,
          ),
        );
      }
      page.addAll(
        wordFragments('Table 1: Quarterly revenue', 324, 590, 500, 604),
      );
      for (var i = 0; i < 5; i++) {
        final top = 564.0 - 20 * i;
        page.addAll(wordFragments('north', 324, top - 12, 400, top));
        page.addAll(wordFragments('12.4', 420, top - 12, 470, top));
        page.addAll(wordFragments('23.7', 490, top - 12, 548, top));
      }
      for (var top = 440.0; top >= 120; top -= 12) {
        page.addAll(
          wordFragments(
            'the quick brown fox jumps over the lazy dog',
            324,
            top - 10,
            548,
            top,
          ),
        );
      }
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: mergeFragmentsIntoLines(page, pageHeightPts: 792),
      ).single;
      expect(
        region.rectPdf.left,
        greaterThanOrEqualTo(320),
        reason: 'the left column\'s body text is not part of the table',
      );
      expect(
        iou(region.rectPdf, (left: 322, top: 570, right: 550, bottom: 466)),
        greaterThan(0.7),
      );
    });

    test('a table in one column does not make the OTHER column\'s body lines '
        'table rows (they share a visual row, not a table)', () {
      // Left column: body, a figure caption, more body. Right column: body
      // throughout. If the right column ever held a table, the left column's
      // lines must keep blocking — tabularity is per CELL, not per row.
      final page = <PageTextItem>[];
      for (var top = 740.0; top >= 620; top -= 12) {
        page.addAll(
          wordFragments(
            'the quick brown fox jumps over the lazy dog',
            54,
            top - 10,
            278,
            top,
          ),
        );
      }
      for (var top = 740.0; top >= 120; top -= 12) {
        page.addAll(
          wordFragments(
            'the quick brown fox jumps over the lazy dog',
            324,
            top - 10,
            548,
            top,
          ),
        );
      }
      page.addAll(
        wordFragments('Figure 5: Left column plot', 54, 380, 240, 394),
      );
      for (var top = 360.0; top >= 120; top -= 12) {
        page.addAll(
          wordFragments(
            'the quick brown fox jumps over the lazy dog',
            54,
            top - 10,
            278,
            top,
          ),
        );
      }
      final items = mergeFragmentsIntoLines(page, pageHeightPts: 792);
      final classes = classifyPageLines(
        items,
        pageWidthPts: 612,
        pageHeightPts: 792,
        captionIndexes: {
          for (final a in detectCaptionAnchors(items)) a.itemIndex,
        },
      );
      expect(classes.where((c) => c.isTabular), isEmpty);
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: items,
      ).single;
      expect(region.rectPdf.right, lessThan(300), reason: 'left column only');
      expect(
        iou(region.rectPdf, (left: 54, top: 604, right: 278, bottom: 400)),
        greaterThan(0.7),
      );
    });

    test('C-1 a full-page plate takes its width from the whitespace, not from '
        'its caption (was: the caption\'s own 258pt, IoU 0.510; 0.272 for a '
        'short caption)', () {
      final fixture = fixtureFullPagePlate();
      final region = regionsOf(fixture).single;
      expect(
        region.rectPdf.right,
        greaterThan(500),
        reason: 'a 258pt caption must not define a full-page figure',
      );
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // A SHORT caption on the same plate lands in the same place.
      final short = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: mergeFragmentsIntoLines(
          wordFragments('Figure 4: Schematic', 72, 74, 210, 88),
          pageHeightPts: 792,
        ),
      ).single;
      expect(iou(short.rectPdf, fixture.truthRect), greaterThan(0.7));

      // Landscape: the same rule on a 792x612 page.
      final landscape = inferFigureRegions(
        page: 1,
        pageWidthPts: 792,
        pageHeightPts: 612,
        items: mergeFragmentsIntoLines(
          wordFragments('Figure 4: Landscape chart', 60, 40, 730, 54),
          pageHeightPts: 612,
        ),
      ).single;
      expect(landscape.rectPdf.right, greaterThan(700));
      expect(landscape.rectPdf.top, greaterThan(560));
    });

    test('FN-1 a standalone appendix table page is found (was: 0 regions '
        'unless the caption happened to be wider than column 1)', () {
      final fixture = fixtureAppendixTablePage();
      final region = regionsOf(fixture).single;
      expect(region.caption, contains('Table 1'));
      expect(region.rectPdf.top, lessThan(760));
      expect(region.rectPdf.top, greaterThan(728), reason: 'holds row 1');
      expect(region.rectPdf.bottom, lessThan(268), reason: 'holds row 24');
      expect(region.rectPdf.right, greaterThanOrEqualTo(540));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // The same table WITH a full-width lead-in line (which used to be the
      // only way it was found) still lands in the same place.
      final withLeadIn = [
        ...fixture.textItems,
        ...mergeFragmentsIntoLines(
          wordFragments(
            'The following table lists every result we obtained.',
            72,
            776,
            540,
            788,
          ),
          pageHeightPts: 792,
        ),
      ];
      final second = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: withLeadIn,
      ).single;
      expect(iou(second.rectPdf, region.rectPdf), greaterThan(0.9));

      // Three columns and a tighter pitch are the same shape.
      for (final columns in [2, 3]) {
        for (final pitch in [20.0, 32.0]) {
          final page = <PageTextItem>[
            ...wordFragments('Table 1: Full results', 72, 760, 250, 774),
          ];
          final rows = pitch == 20.0 ? 20 : 15;
          for (var i = 0; i < rows; i++) {
            final top = 740.0 - pitch * i;
            for (var c = 0; c < columns; c++) {
              final l = 72.0 + c * 160;
              page.addAll(wordFragments('12.4', l, top - 12, l + 120, top));
            }
          }
          final regions = inferFigureRegions(
            page: 1,
            pageWidthPts: 612,
            pageHeightPts: 792,
            items: mergeFragmentsIntoLines(page, pageHeightPts: 792),
          );
          expect(
            regions,
            hasLength(1),
            reason: '$columns columns at pitch $pitch',
          );
        }
      }
    });

    test('FN-2 an architecture diagram with six or more labelled boxes is '
        'still a figure (was: a hard cliff — 4 and 5 worked, 6, 7 and 8 gave '
        'nothing)', () {
      for (final n in [4, 5, 6, 7, 8]) {
        final page = <PageTextItem>[];
        for (var i = 0; i < n; i++) {
          final top = 720.0 - 90 * i;
          page.addAll(wordFragments('module $i', 200, top - 14, 360, top));
        }
        page.addAll(
          wordFragments(
            'Figure 1: Architecture of the proposed model',
            72,
            120,
            400,
            134,
          ),
        );
        final regions = inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: mergeFragmentsIntoLines(page, pageHeightPts: 792),
        );
        expect(regions, hasLength(1), reason: '$n labels');
        final rect = regions.single.rectPdf;
        // Every label ABOVE the caption is inside the region (labels 7 and 8
        // of the sweep sit level with or below the caption itself).
        for (var i = 0; i < n; i++) {
          final top = 720.0 - 90 * i;
          if (top - 14 < 134) break;
          expect(rect.top, greaterThanOrEqualTo(top), reason: '$n labels');
          expect(rect.bottom, lessThanOrEqualTo(top - 14), reason: '$n labels');
          expect(rect.left, lessThanOrEqualTo(200), reason: '$n labels');
          expect(rect.right, greaterThanOrEqualTo(360), reason: '$n labels');
        }
      }

      // The guard it used to trip is still there: a page of WIDE lone lines
      // (a slide, a chat log) is the page, not a figure.
      expect(regionsOf(fixtureLoneLinesPage()), isEmpty);
    });

    test('FN-3 a table with a 50% description column is found (the cap gates '
        'on cell CONTENT now, not width alone)', () {
      final fixture = fixtureDescriptionColumnTable();
      final region = regionsOf(fixture).single;
      expect(region.caption, contains('Table 3'));
      expect(region.rectPdf.top, lessThan(700));
      expect(
        region.rectPdf.bottom,
        lessThan(562),
        reason: 'holds the last row',
      );
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('FN-4 RESIDUAL: sub-word-space column gaps stay unrecognised, but '
        'nothing wrong is emitted for them', () {
      // 5 numeric columns of 70pt cells with gaps under the word-space floor
      // (max(6, 0.75x12) = 9pt). Telling a 4pt column gap from a justified
      // word space needs cross-row fragment alignment, which fires on
      // synthetic prose too — precision-first says leave the table missed.
      for (final gap in [4.0, 6.0, 7.0, 8.0]) {
        final page = <PageTextItem>[
          ...wordFragments(
            'Body text above the table here.',
            72,
            740,
            540,
            752,
          ),
          ...wordFragments(
            'A second line of that paragraph.',
            72,
            726,
            540,
            738,
          ),
          ...wordFragments('Table 4: Financials', 72, 700, 250, 714),
        ];
        for (var i = 0; i < 6; i++) {
          final top = 674.0 - 20 * i;
          for (var c = 0; c < 5; c++) {
            final l = 72.0 + c * (70 + gap);
            page.addAll(wordFragments('12.4', l, top - 12, l + 70, top));
          }
        }
        expect(
          inferFigureRegions(
            page: 1,
            pageWidthPts: 612,
            pageHeightPts: 792,
            items: mergeFragmentsIntoLines(page, pageHeightPts: 792),
          ),
          isEmpty,
          reason: 'gap $gap: missed, but never a blank or wrong rect',
        );
      }
      // At 10pt — a normal gutter — the same table is found.
      final page = <PageTextItem>[
        ...wordFragments('Table 4: Financials', 72, 700, 250, 714),
      ];
      for (var i = 0; i < 6; i++) {
        final top = 674.0 - 20 * i;
        for (var c = 0; c < 5; c++) {
          final l = 72.0 + c * 80;
          page.addAll(wordFragments('12.4', l, top - 12, l + 70, top));
        }
      }
      final region = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: mergeFragmentsIntoLines(page, pageHeightPts: 792),
      ).single;
      expect(region.rectPdf.bottom, greaterThan(540));
      expect(region.rectPdf.right, greaterThanOrEqualTo(462));
    });

    test('FN-6 a superscript merged AHEAD of a caption does not destroy the '
        'anchor (was: "a Figure 3: …" matched nothing)', () {
      // The superscript is raised (its top is above the caption's), so
      // mergeFragmentsIntoLines' top-desc/left-asc order puts it FIRST.
      final merged = mergeFragmentsIntoLines([
        PageTextItem(
          text: 'a',
          rect: (left: 66, top: 376, right: 72, bottom: 366),
        ),
        ...wordFragments('Figure 3: Latency by payload', 72, 360, 260, 374),
      ], pageHeightPts: 792);
      expect(merged, hasLength(1));
      expect(merged.single.text, startsWith('a Figure 3'));
      final anchors = detectCaptionAnchors(merged);
      expect(anchors, hasLength(1));
      expect(anchors.single.kind, CaptionKind.figure);

      // The orphan retry needs a physically tiny first fragment, so running
      // text can never reach it: "In figure 3 we…" is not a caption, and
      // neither is a line whose leading word is simply short.
      expect(
        detectCaptionAnchors(
          mergeFragmentsIntoLines(
            wordFragments('In figure 3 we show the latency', 72, 360, 300, 374),
            pageHeightPts: 792,
          ),
        ),
        isEmpty,
      );
      expect(
        detectCaptionAnchors(
          mergeFragmentsIntoLines(
            wordFragments('as figure 3 shows the latency', 72, 360, 300, 374),
            pageHeightPts: 792,
          ),
        ),
        isEmpty,
      );
      // An OCR block (no fragment breakdown) never gets the retry either —
      // "如图1所示" is running text, not a caption.
      expect(
        detectCaptionAnchors([
          PageTextItem(
            text: '如图1所示，延迟随负载增加',
            rect: (left: 72, top: 374, right: 300, bottom: 360),
          ),
        ]),
        isEmpty,
      );
    });

    test('FN-6 a caption does not merge across a page column corridor '
        '(was: at a 12pt gutter the right-column caption joined the left '
        'column\'s body line and the region was lost)', () {
      for (final gutter in [12.0, 14.0, 20.0, 46.0]) {
        final page = <PageTextItem>[];
        final rightLeft = 278 + gutter;
        for (var top = 740.0; top >= 200; top -= 12) {
          page.addAll(
            wordFragments('left column body text here', 54, top - 10, 278, top),
          );
          page.addAll(
            wordFragments(
              'right column body text here',
              rightLeft,
              top - 10,
              rightLeft + 224,
              top,
            ),
          );
        }
        page.addAll(
          wordFragments(
            'Figure 3: Latency',
            rightLeft,
            176,
            rightLeft + 160,
            188,
          ),
        );
        final merged = mergeFragmentsIntoLines(page, pageHeightPts: 792);
        final caption = merged.where((m) => m.text.startsWith('Figure 3'));
        expect(
          caption,
          hasLength(1),
          reason: 'gutter $gutter: the caption stayed its own line',
        );
        expect(
          detectCaptionAnchors(merged),
          hasLength(1),
          reason: 'gutter $gutter',
        );
      }
    });

    test('FP-3 sub-figure captions do not duplicate the region or block their '
        'parent (was: two byte-identical regions and the parent\'s band '
        'collapsed to 8pt)', () {
      final fixture = fixtureSubCaptions();
      final regions = regionsOf(fixture);
      expect(detectCaptionAnchors(fixture.allItems), hasLength(3));
      expect(regions, hasLength(1));
      final region = regions.single;
      expect(region.caption, startsWith('Figure 2:'));
      expect(
        region.rectPdf.bottom,
        lessThan(430),
        reason: 'the sub-captions are content of the parent figure',
      );
      expect(region.rectPdf.top, closeTo(728, 1));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));

      // Two sub-captions with NO parent on the page are two ordinary
      // captions again — subordination needs a parent to be subordinate to.
      final orphans = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: mergeFragmentsIntoLines([
          ...wordFragments('Body text above the figures.', 72, 746, 540, 758),
          ...wordFragments('A second body line here now.', 72, 732, 540, 744),
          ...wordFragments('Fig. 2a baseline', 72, 430, 260, 442),
        ], pageHeightPts: 792),
      );
      expect(orphans, hasLength(1));
      expect(orphans.single.caption, contains('2a'));
    });
  });

  // ─── Round-4: the structural defect and the geometries that found it ──────
  //
  // The defect these all share: [_detectTableBlock] was the ONE path that
  // could exempt items from the ink and weighted-line backstops, and it
  // applied NONE of the page-column defences the classifier applies. The
  // classifier could be completely right — on the Chinese page below it
  // returned tabular=0 and blocksGrowth for all 65 lines — and be overruled.
  // The fix is structural: the defences are computed once per page and every
  // consumer applies them, cell evidence is read from the cell's TEXT rather
  // than guessed from its geometry, and the block's exemption is RE-DERIVED
  // at the emit gate from each row's own evidence.

  group('round-4 regressions', () {
    List<FigureRegion> regionsOf(FigureFixture fixture) => inferFigureRegions(
      page: 1,
      pageWidthPts: fixture.pageWidth,
      pageHeightPts: fixture.pageHeight,
      items: fixture.allItems,
    );

    /// Fraction of [rect] covered by [items]' ink — what the reader would see
    /// as text in the rendered crop.
    double inkFraction(List<PageTextItem> items, PdfRect rect) {
      final area = (rect.top - rect.bottom) * (rect.right - rect.left);
      if (area <= 0) return 0;
      var ink = 0.0;
      for (final item in items) {
        final r = item.rect;
        final w =
            (r.right < rect.right ? r.right : rect.right) -
            (r.left > rect.left ? r.left : rect.left);
        final h =
            (r.top < rect.top ? r.top : rect.top) -
            (r.bottom > rect.bottom ? r.bottom : rect.bottom);
        if (w > 0 && h > 0) ink += w * h;
      }
      return ink / area;
    }

    test('FP-1 three columns of PROSE above a table caption are not a table '
        'block (was: l=54 b=502 r=472 t=744 — twelve rows of prose, 69.4% '
        'ink, at 0.9 confidence, because 130pt cells cleared the 22% '
        '"narrow cell" cap)', () {
      final fixture = fixtureProseThreeColumnsOverTable();
      final regions = regionsOf(fixture);
      expect(regions, isEmpty);
      for (final region in regions) {
        expect(region.rectPdf, isNot(kProseThreeColumnsBadRect));
      }

      // The cells hold six words each; nothing about them is a table cell,
      // so the rows never become tabular and they block like body text.
      final classes = classifyFixture(fixture);
      for (var i = 0; i < fixture.allItems.length; i++) {
        if (!fixture.allItems[i].text.startsWith('the quick')) continue;
        expect(classes[i].isTabular, isFalse, reason: 'prose row $i');
        expect(classes[i].blocksGrowth, isTrue, reason: 'prose row $i');
      }
    });

    test('FP-1a a two-column CHINESE page emits nothing (was: l=60 b=108 '
        'r=540 t=744 — 63% of the page, 64 lines of prose at 67.2% ink, '
        'while the classifier called every one of them a blocking body '
        'line and the corridor was detected)', () {
      for (final fixture in [
        fixtureCjkTwoColumnPage(),
        fixtureJapaneseTwoColumnPage(),
      ]) {
        final items = fixture.allItems;
        // The classifier is RIGHT about this page…
        final classes = classifyFixture(fixture);
        expect(
          classes.where((c) => c.isTabular),
          isEmpty,
          reason: '${fixture.name}: no line is tabular',
        );
        expect(
          classes.where((c) => c.blocksGrowth).length,
          items.length,
          reason: '${fixture.name}: every line blocks',
        );
        expect(
          detectLayoutCorridors(items, pageHeightPts: fixture.pageHeight),
          isNotEmpty,
          reason: '${fixture.name}: the column corridor is detected',
        );
        // …and can no longer be overruled.
        final regions = regionsOf(fixture);
        expect(regions, isEmpty, reason: fixture.name);
        for (final region in regions) {
          expect(region.rectPdf, isNot(kCjkTwoColumnBadRect));
        }
      }

      // The English control at the same measure: unchanged, still nothing.
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: cjkControlEnglishPage(),
        ),
        isEmpty,
      );
    });

    test('FP-1a the CJK fix is not "give up on CJK": a real Chinese table '
        'under a Chinese caption is still found', () {
      final items = mergeFragmentsIntoLines([
        ...wordFragments('表2：准确率汇总', 60, 700, 220, 714),
        for (var i = 0; i < 6; i++) ...[
          ...wordFragments('模型甲', 60, 660.0 - 20 * i, 130, 674.0 - 20 * i),
          ...wordFragments('12.4', 240, 660.0 - 20 * i, 310, 674.0 - 20 * i),
          ...wordFragments('98.6', 420, 660.0 - 20 * i, 490, 674.0 - 20 * i),
        ],
      ], pageHeightPts: 792);
      final regions = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: items,
      );
      final region = regions.single;
      expect(region.caption, contains('表2'));
      expect(
        iou(region.rectPdf, (left: 58, top: 678, right: 492, bottom: 554)),
        greaterThan(0.7),
      );
    });

    test('FP-1b/c three 130pt columns are not a table, on the text-layer '
        'path OR the OCR path (was: l=54 b=142 r=472 t=744 at 67.4% and '
        '65.1% ink — the word test and the width test, one hole each)', () {
      for (final fixture in [
        fixtureThreeNarrowColumnsTable(),
        fixtureThreeNarrowColumnsOcr(),
      ]) {
        final regions = regionsOf(fixture);
        expect(regions, isEmpty, reason: fixture.name);
        for (final region in regions) {
          expect(region.rectPdf, isNot(kThreeNarrowColumnsBadRect));
        }
      }
    });

    test('FP-2 a marginal gloss does not turn the body line beside it into a '
        'table row (was: l=72 b=398 r=400 t=788 — all three prose lines '
        'inside the figure; deleting the glosses gave the right answer)', () {
      final fixture = fixtureMarginalGlosses();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf, isNot(kMarginalGlossesBadRect));
      expect(
        region.rectPdf.top,
        lessThan(712),
        reason: 'the prose above the figure bounds it',
      );
      expect(inkFraction(fixture.allItems, region.rectPdf), lessThan(0.01));

      // Only the gloss is a table cell; the body line beside it is not.
      final classes = classifyFixture(fixture);
      for (var i = 0; i < fixture.allItems.length; i++) {
        if (!fixture.allItems[i].text.startsWith('the quick')) continue;
        expect(classes[i].isTabular, isFalse, reason: 'body line $i');
      }

      // Same shape with numbered display equations instead of glosses.
      final equations = mergeFragmentsIntoLines([
        for (var i = 0; i < 4; i++) ...[
          ...wordFragments(
            'x equals alpha plus beta times gamma',
            150,
            738.0 - 30 * i,
            400,
            750.0 - 30 * i,
          ),
          ...wordFragments(
            '(${i + 1})',
            500,
            738.0 - 30 * i,
            520,
            750.0 - 30 * i,
          ),
        ],
        ...wordFragments(
          'Figure 3: Latency by payload size',
          72,
          380,
          320,
          394,
        ),
        ...wordFragments('Discussion continues after it.', 72, 348, 400, 360),
        ...wordFragments(
          'A second line of that discussion.',
          72,
          334,
          400,
          346,
        ),
      ], pageHeightPts: 792);
      final equationRegion = inferFigureRegions(
        page: 1,
        pageWidthPts: 612,
        pageHeightPts: 792,
        items: equations,
      ).single;
      expect(equationRegion.rectPdf.top, lessThan(660));
      expect(inkFraction(equations, equationRegion.rectPdf), lessThan(0.01));
    });

    test('FP-3 sweep: double-spaced body lines never render as a page-sized '
        'figure (was: n = 4, 6, 7, 8 narrow lines and n = 3, 4 full-measure '
        'ones returned the whole page; only the flat line-count cliff at '
        'n = 9 stopped it)', () {
      for (final fullMeasure in [false, true]) {
        for (var lines = 2; lines <= 9; lines++) {
          final items = doubleSpacedProsePage(
            lines: lines,
            fullMeasure: fullMeasure,
          );
          final regions = inferFigureRegions(
            page: 1,
            pageWidthPts: 612,
            pageHeightPts: 792,
            items: items,
          );
          final reason = 'lines=$lines fullMeasure=$fullMeasure';
          for (final region in regions) {
            expect(
              region.rectPdf,
              isNot(kDoubleSpacedProseBadRect),
              reason: reason,
            );
            // Whatever is emitted, no line of prose may be inside it.
            expect(
              inkFraction(items, region.rectPdf),
              lessThan(0.01),
              reason: reason,
            );
          }
        }
      }
    });

    test('FP-4 a LIST OF FIGURES page emits nothing (was: the heading above '
        'the first entry came back as l=72 b=704 r=540 t=788 at 0.9 '
        'confidence — every thesis has this page)', () {
      final fixture = fixtureListOfFigures();
      expect(detectCaptionAnchors(fixture.allItems), hasLength(8));
      final regions = regionsOf(fixture);
      expect(regions, isEmpty);
      for (final region in regions) {
        expect(region.rectPdf, isNot(kListOfFiguresBadRect));
      }

      // Two stacked captions are not a list: a page CAN hold two figures.
      final two = mergeFragmentsIntoLines([
        ...wordFragments('Body text above the figure area.', 72, 746, 540, 758),
        ...wordFragments('A second body line for it here.', 72, 732, 540, 744),
        ...wordFragments('Figure 1: The first plot', 72, 500, 300, 514),
        ...wordFragments('Figure 2: The second plot', 72, 300, 300, 314),
      ], pageHeightPts: 792);
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: two,
        ),
        hasLength(2),
      );
    });

    test('FP-5 the 66pt strip between a poem and its caption is not a figure '
        '(was: a blank 432×66pt PNG at l=90 b=438 r=522 t=504 — 0 items, 0% '
        'ink, its width MIRRORED from the caption margin)', () {
      final fixture = fixtureVerseBlankBand();
      final regions = regionsOf(fixture);
      expect(regions, isEmpty);
      for (final region in regions) {
        expect(region.rectPdf, isNot(kVerseBlankBandBadRect));
      }

      // A real full-page plate still takes its extent from the whitespace:
      // an EMPTY band is only evidence when it is the size of a plate.
      final plate = fixtureFullPagePlate();
      final plateRegion = regionsOf(plate).single;
      expect(iou(plateRegion.rectPdf, plate.truthRect), greaterThan(0.7));
    });

    test('FP-6 a sentence whose first word is one narrow character is not a '
        'caption ("A figure 3 in the appendix shows…"), while a superscript '
        'footnote mark ahead of a real caption still is', () {
      for (final text in [
        'A figure 3 in the appendix shows the trend of the measured latency',
        'I figure 3 is enough for the reader to see the pattern we describe',
        'a figure 3 in the appendix shows the trend of the measured latency',
        '3 figure 3 in the appendix shows the trend of the measured latency',
        'e figure 3 in the appendix shows the trend of the measured latency',
      ]) {
        for (final width in [300.0, 400.0, 540.0]) {
          expect(
            detectCaptionAnchors(
              mergeFragmentsIntoLines(
                wordFragments(text, 72, 700, 72 + width, 714),
                pageHeightPts: 792,
              ),
            ),
            isEmpty,
            reason: '"$text" at width $width',
          );
        }
      }
      // The mechanism still works for what it exists for.
      expect(
        detectCaptionAnchors(
          mergeFragmentsIntoLines([
            PageTextItem(
              text: 'a',
              rect: (left: 66, top: 376, right: 72, bottom: 366),
            ),
            ...wordFragments('Figure 3: Latency by payload', 72, 360, 260, 374),
          ], pageHeightPts: 792),
        ),
        hasLength(1),
      );
    });

    test('FN-1 right-aligned money columns are a table block (was: l=72 b=4 '
        'r=380 t=696 — a 692pt band for a 122pt table, IoU 0.163, third '
        'column outside the crop; with prose below, no region at all)', () {
      for (final proseBelow in [false, true]) {
        final fixture = fixtureRightAlignedNumericTable(proseBelow: proseBelow);
        final region = regionsOf(fixture).single;
        expect(region.rectPdf, isNot(kRightAlignedTableBadRect));
        expect(
          region.rectPdf.right,
          greaterThan(519),
          reason: 'the third money column is inside the crop',
        );
        expect(
          region.rectPdf.bottom,
          greaterThan(560),
          reason: 'the band stops at the table, not at the page edge',
        );
        expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
      }
    });

    test('FN-2 a merged header row does not kill the block (was: l=72 b=4 '
        'r=440 t=696, IoU 0.199 — the blockless path has no trimming, so any '
        'shape that defeats block detection runs to the page edge)', () {
      final fixture = fixtureMergedHeaderTable();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf, isNot(kMergedHeaderTableBadRect));
      expect(
        region.rectPdf.top,
        greaterThan(673),
        reason: 'the merged header row is part of the table',
      );
      expect(region.rectPdf.bottom, greaterThan(540));
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('FN-3 a blank separator row does not truncate the table (was: IoU '
        '0.424, three of six rows, and the crop LOOKED complete)', () {
      final fixture = fixtureSeparatorRowTable();
      final region = regionsOf(fixture).single;
      expect(region.rectPdf, isNot(kSeparatorRowTableBadRect));
      expect(
        region.rectPdf.bottom,
        lessThan(546),
        reason: 'the rows below the separator belong to the same table',
      );
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('FN-4 sweep: a double-spaced page keeps its figure at every pitch '
        '(was: 14/16/18/20 → a region, 21/22/24/28 → nothing at all)', () {
      for (final pitch in [14.0, 16.0, 18.0, 20.0, 21.0, 22.0, 24.0, 28.0]) {
        final items = doubleSpacedFigurePage(pitch: pitch);
        final regions = inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: items,
        );
        expect(regions, hasLength(1), reason: 'pitch $pitch');
        final region = regions.single;
        expect(
          inkFraction(items, region.rectPdf),
          lessThan(0.01),
          reason: 'pitch $pitch: no body line inside the figure',
        );
        expect(
          region.rectPdf.bottom,
          closeTo(398, 1),
          reason: 'pitch $pitch: the band sits on the caption',
        );
      }
    });

    test('FN-5 a figure in the LEFT column does not cross the corridor to '
        'claim a blank right column (was: l=54 b=398 r=548 t=606, both '
        'columns, IoU 0.445 — the extent logic never consulted the corridor '
        'detectLayoutCorridors had already found)', () {
      final fixture = fixtureLeftColumnFigureClearRight();
      expect(
        detectLayoutCorridors(fixture.allItems, pageHeightPts: 792),
        isNotEmpty,
      );
      final region = regionsOf(fixture).single;
      expect(region.rectPdf, isNot(kLeftColumnFigureBadRect));
      expect(
        region.rectPdf.right,
        lessThanOrEqualTo(324),
        reason: 'the corridor bounds the region',
      );
      expect(iou(region.rectPdf, fixture.truthRect), greaterThan(0.7));
    });

    test('STRUCTURAL: the backstops are not exemptible — a table caption '
        'whose rows carry no table evidence of their own gets no exemption, '
        'however the block was found', () {
      // The prose page of FP-1 with the real table removed: a table caption
      // with nothing but prose above it. The only way this could ever be
      // emitted is an exemption, and there is none to be had.
      final items = mergeFragmentsIntoLines([
        for (var i = 0; i <= 11; i++) ...[
          ...wordFragments(
            'the quick brown fox jumps over',
            54,
            726.0 - 20 * i,
            184,
            740.0 - 20 * i,
          ),
          ...wordFragments(
            'another line of running prose',
            198,
            726.0 - 20 * i,
            328,
            740.0 - 20 * i,
          ),
          ...wordFragments(
            'a third column of body text',
            342,
            726.0 - 20 * i,
            472,
            740.0 - 20 * i,
          ),
        ],
        ...wordFragments('Table 2: Accuracy summary', 54, 460, 214, 474),
      ], pageHeightPts: 792);
      expect(
        inferFigureRegions(
          page: 1,
          pageWidthPts: 612,
          pageHeightPts: 792,
          items: items,
        ),
        isEmpty,
      );
    });
  });

  // ─── Fragment line merging (real-pdfrx robustness) ────────────────────────

  group('mergeFragmentsIntoLines', () {
    test('word-level fragments on one baseline merge into a caption line', () {
      final merged = mergeFragmentsIntoLines([
        PageTextItem(
          text: 'Figure',
          rect: (left: 100, top: 394, right: 135, bottom: 380),
        ),
        PageTextItem(
          text: '1:',
          rect: (left: 139, top: 394, right: 150, bottom: 380),
        ),
        PageTextItem(
          text: 'Overview',
          rect: (left: 154, top: 394, right: 210, bottom: 380),
        ),
      ]);
      expect(merged, hasLength(1));
      expect(merged.single.text, 'Figure 1: Overview');
      expect(merged.single.rect.left, 100);
      expect(merged.single.rect.right, 210);
      expect(detectCaptionAnchors(merged), hasLength(1));
    });

    test('same-baseline lines across a column gap do NOT merge', () {
      final merged = mergeFragmentsIntoLines([
        PageTextItem(
          text: 'left column line',
          rect: (left: 40, top: 394, right: 290, bottom: 382),
        ),
        PageTextItem(
          text: 'right column line',
          rect: (left: 322, top: 394, right: 572, bottom: 382),
        ),
      ]);
      expect(merged, hasLength(2));
    });
  });

  // ─── Rotated pages (/Rotate 90|180|270) ──────────────────────────────────

  group('rotateRectToDisplaySpace', () {
    // pdfium's FPDF_GetPageWidthF/HeightF ARE rotation-adjusted; its
    // FPDFText_GetCharBox is NOT. Pairing them measures line widths along
    // the wrong axis and crops a differently-rotated part of the raster.
    // (Verified against pdfrx_engine 0.3.9: PdfRect.toRect(page:) applies
    // exactly this rotation before dividing by page.height.)
    const rect = (left: 50.0, top: 830.0, right: 200.0, bottom: 800.0);

    test('rotation 0 is the identity', () {
      expect(
        rotateRectToDisplaySpace(
          rect,
          rotation: 0,
          displayWidthPts: 595,
          displayHeightPts: 842,
        ),
        rect,
      );
    });

    test('clockwise 90 maps the portrait top edge onto the landscape right '
        'edge', () {
      // /Rotate 90 on A4: display is 842x595, the unrotated page 595x842.
      final display = rotateRectToDisplaySpace(
        rect,
        rotation: 1,
        displayWidthPts: 842,
        displayHeightPts: 595,
      );
      expect(display, (left: 800.0, top: 545.0, right: 830.0, bottom: 395.0));
      expect(display.right, lessThanOrEqualTo(842));
      expect(display.top, lessThanOrEqualTo(595));
      // A 150x30 line becomes 30x150 — the width heuristic would have been
      // reading the wrong axis entirely.
      expect(display.right - display.left, 30);
      expect(display.top - display.bottom, 150);
    });

    test('180 and 270 land inside the page too', () {
      expect(
        rotateRectToDisplaySpace(
          rect,
          rotation: 2,
          displayWidthPts: 595,
          displayHeightPts: 842,
        ),
        (left: 395.0, top: 42.0, right: 545.0, bottom: 12.0),
      );
      final ccw = rotateRectToDisplaySpace(
        rect,
        rotation: 3,
        displayWidthPts: 842,
        displayHeightPts: 595,
      );
      expect(ccw, (left: 12.0, top: 200.0, right: 42.0, bottom: 50.0));
    });

    test('a /Rotate 90 page yields the SAME region as the upright page it '
        'displays as', () {
      // Fixture A is the page as the READER sees it (612x792 display). On a
      // /Rotate 90 page pdfium stores those glyph boxes sideways, in a
      // 792x612 frame. Inverse-rotate the fixture to get what
      // FPDFText_GetCharBox would return, then run the seam's normalization
      // and check we land back on the upright geometry.
      final fixture = fixtureSingleColumn();
      PdfRect toStored(PdfRect display) => rotateRectToDisplaySpace(
        display,
        rotation: 3,
        displayWidthPts: fixture.pageHeight, // unrotated width  = 792
        displayHeightPts: fixture.pageWidth, // unrotated height = 612
      );
      final normalized = [
        for (final item in fixture.allItems)
          PageTextItem(
            text: item.text,
            rect: rotateRectToDisplaySpace(
              toStored(item.rect),
              rotation: 1,
              displayWidthPts: fixture.pageWidth,
              displayHeightPts: fixture.pageHeight,
            ),
          ),
      ];
      for (var i = 0; i < normalized.length; i++) {
        expect(
          normalized[i].rect,
          fixture.allItems[i].rect,
          reason: 'round trip through the stored frame',
        );
      }

      final upright = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: fixture.allItems,
      ).single;
      final rotated = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: normalized,
      ).single;
      expect(rotated.rectPdf, upright.rectPdf);

      // Without normalization the raw stored bounds produce something else
      // entirely (here: nothing at all) — which is what shipped.
      final unnormalized = inferFigureRegions(
        page: 1,
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: [
          for (final item in fixture.allItems)
            PageTextItem(text: item.text, rect: toStored(item.rect)),
        ],
      );
      expect(
        unnormalized.map((r) => r.rectPdf),
        isNot(contains(upright.rectPdf)),
      );
    });
  });

  // ─── OCR meta parsing ─────────────────────────────────────────────────────

  group('ocrItemsFromChunkMeta', () {
    test('parses pdf-space block bounds', () {
      final meta = jsonEncode({
        'renderScale': 2.0,
        'space': 'pdf',
        'blockBounds': [
          {
            'rect': {'l': 10.0, 't': 100.0, 'r': 200.0, 'b': 80.0},
            'text': '图1：结构',
          },
          {
            'rect': {'l': 10, 't': 60, 'r': 90, 'b': 40},
            'text': 'axis label',
          },
        ],
      });
      final items = ocrItemsFromChunkMeta(meta);
      expect(items, hasLength(2));
      expect(items.first.text, '图1：结构');
      expect(items.first.rect, (
        left: 10.0,
        top: 100.0,
        right: 200.0,
        bottom: 80.0,
      ));
    });

    test('image-space and malformed meta yield no items', () {
      expect(
        ocrItemsFromChunkMeta(
          jsonEncode({
            'space': 'image',
            'blockBounds': [
              {
                'rect': {'l': 0, 't': 10, 'r': 10, 'b': 0},
                'text': 'x',
              },
            ],
          }),
        ),
        isEmpty,
      );
      expect(ocrItemsFromChunkMeta('not json'), isEmpty);
      expect(ocrItemsFromChunkMeta('42'), isEmpty);
      expect(
        ocrItemsFromChunkMeta(jsonEncode({'space': 'pdf', 'blockBounds': 3})),
        isEmpty,
      );
      // Blocks with missing keys are skipped, valid siblings survive.
      final items = ocrItemsFromChunkMeta(
        jsonEncode({
          'space': 'pdf',
          'blockBounds': [
            {'text': 'no rect'},
            {
              'rect': {'l': 1, 't': 2, 'r': 3, 'b': 0},
              'text': 'ok',
            },
          ],
        }),
      );
      expect(items, hasLength(1));
      expect(items.single.text, 'ok');
    });
  });

  // ─── Rendering: transform reuse, derived assets, statuses ────────────────

  group('extractFigures rendering', () {
    test('render arguments follow the §4.1 transform at 3x', () async {
      final fixture = fixtureSingleColumn();
      final source = FakeFigureSource([pageOf(fixture)]);
      final extractor = buildExtractor(source);
      final attachment = await buildAttachment();

      final result = await extractor.extractFigures(attachment);
      expect(result.status, FigureExtractionStatus.extracted);
      expect(result.figures, hasLength(1));
      expect(result.pageCount, 1);

      // Region pinned by the fixture geometry: (l=72, b=398, r=540, t=714)
      // on a 612x792 page at scale 3 → fullWidth 1836, fullHeight 2376,
      // x = 72*3, y = (792-714)*3, w = 468*3, h = 316*3.
      final call = source.renderCalls.single;
      expect(call['fullWidth'], 612.0 * 3);
      expect(call['fullHeight'], 792.0 * 3);
      expect(call['x'], 216);
      expect(call['y'], 234);
      expect(call['width'], 1404);
      expect(call['height'], 948);
      expect(source.disposed, isTrue);
    });

    test('derived asset naming, relative path, and hash determinism', () async {
      final fixture = fixtureSingleColumn();
      final attachment = await buildAttachment(id: 'attX');

      Future<DerivedFigure> runOnce() async {
        final source = FakeFigureSource([pageOf(fixture)]);
        final extractor = buildExtractor(source);
        final result = await extractor.extractFigures(attachment);
        return result.figures.single;
      }

      final first = await runOnce();
      final second = await runOnce();

      expect(first.fileName, 'attX_p1_f0.png');
      expect(first.assetRelativePath, 'attachments/derived/attX_p1_f0.png');
      expect(second.fileName, first.fileName);
      expect(second.contentHash, first.contentHash);

      final file = File('${derivedDir.path}/${first.fileName}');
      expect(await file.exists(), isTrue);
      final bytes = await file.readAsBytes();
      expect(sha256.convert(bytes).toString(), first.contentHash);
      expect(first.region.caption, contains('Figure 1'));
    });

    test('non-PDF attachment is skipped before opening', () async {
      var opened = false;
      final extractor = buildExtractor(
        FakeFigureSource([]),
        onOpen: () => opened = true,
      );
      final attachment = await buildAttachment(fileName: 'image.png');
      final result = await extractor.extractFigures(attachment);
      expect(result.status, FigureExtractionStatus.skippedNotPdf);
      expect(opened, isFalse);
    });

    test('missing file fails without opening', () async {
      var opened = false;
      final extractor = buildExtractor(
        FakeFigureSource([]),
        onOpen: () => opened = true,
      );
      final attachment = await buildAttachment(createFile: false);
      final result = await extractor.extractFigures(attachment);
      expect(result.status, FigureExtractionStatus.failed);
      expect(result.errorMessage, contains('File not found'));
      expect(opened, isFalse);
    });

    test('opener failure yields failed', () async {
      final extractor = FigureRegionExtractor(
        opener: (path) async => throw Exception('corrupt'),
        derivedDirLoader: () async => derivedDir,
      );
      final result = await extractor.extractFigures(await buildAttachment());
      expect(result.status, FigureExtractionStatus.failed);
      expect(result.errorMessage, contains('Failed to open PDF'));
    });

    test('abort between pages discards partial output', () async {
      final fixture = fixtureSingleColumn();
      final source = FakeFigureSource([pageOf(fixture), pageOf(fixture)]);
      final extractor = buildExtractor(source);
      var pagesSeen = 0;
      final result = await extractor.extractFigures(
        await buildAttachment(),
        shouldAbort: () => pagesSeen++ >= 1,
      );
      expect(result.status, FigureExtractionStatus.aborted);
      expect(result.figures, isEmpty);
      expect(source.disposed, isTrue);
    });

    test('render failure on ONE region does not lose the document', () async {
      // Two pages, one region each; the first render fails.
      final fixture = fixtureSingleColumn();
      final source = FakeFigureSource([
        pageOf(fixture),
        pageOf(fixture),
      ], failRenderAt: 0);
      final extractor = buildExtractor(source);
      final result = await extractor.extractFigures(await buildAttachment());
      expect(result.status, FigureExtractionStatus.extracted);
      expect(result.figures, hasLength(1));
      expect(result.attemptedRenders, 2);
      expect(result.failedRenders, 1);
    });

    test('EVERY render failing is failed, not an empty extracted (a full or '
        'read-only disk must stay retryable)', () async {
      final fixture = fixtureSingleColumn();
      final source = FakeFigureSource([
        pageOf(fixture),
        pageOf(fixture),
      ], renderReturnsNull: true);
      final extractor = buildExtractor(source);
      final result = await extractor.extractFigures(await buildAttachment());
      expect(result.status, FigureExtractionStatus.failed);
      expect(result.figures, isEmpty);
      expect(result.attemptedRenders, 2);
      expect(result.failedRenders, 2);
      expect(result.errorMessage, contains('All 2 figure renders failed'));
    });

    test(
      'EVERY page failing to load is failed, not an empty extracted',
      () async {
        final fixture = fixtureSingleColumn();
        final source = ThrowingPageSource(
          [pageOf(fixture), pageOf(fixture)],
          throwOnPages: {0, 1},
        );
        final result = await buildExtractor(
          source,
        ).extractFigures(await buildAttachment());
        expect(result.status, FigureExtractionStatus.failed);
        expect(result.failedPages, 2);
        expect(result.errorMessage, contains('All 2 pages failed to load'));
      },
    );

    test('one broken page among good ones is still extracted', () async {
      final fixture = fixtureSingleColumn();
      final source = ThrowingPageSource(
        [pageOf(fixture), pageOf(fixture)],
        throwOnPages: {0},
      );
      final result = await buildExtractor(
        source,
      ).extractFigures(await buildAttachment());
      expect(result.status, FigureExtractionStatus.extracted);
      expect(result.failedPages, 1);
      expect(result.figures, hasLength(1));
    });

    test('a page whose region count shrank has its stale derived assets '
        'reaped', () async {
      final fixture = fixtureSingleColumn();
      final attachment = await buildAttachment(id: 'attReap');
      // Assets left behind by an earlier run that found three regions.
      for (final k in [1, 2]) {
        await File(
          '${derivedDir.path}/'
          '${FigureRegionExtractor.derivedFigureFileName('attReap', 1, k)}',
        ).writeAsString('stale');
      }
      // …and one for a DIFFERENT page, which must survive.
      final otherPage = File(
        '${derivedDir.path}/'
        '${FigureRegionExtractor.derivedFigureFileName('attReap', 2, 0)}',
      );
      await otherPage.writeAsString('other page');

      final source = FakeFigureSource([pageOf(fixture)]);
      final result = await buildExtractor(source).extractFigures(attachment);
      expect(result.figures, hasLength(1));
      expect(
        await File('${derivedDir.path}/attReap_p1_f1.png').exists(),
        isFalse,
      );
      expect(
        await File('${derivedDir.path}/attReap_p1_f2.png').exists(),
        isFalse,
      );
      expect(
        await File('${derivedDir.path}/attReap_p1_f0.png').exists(),
        isTrue,
      );
      expect(await otherPage.exists(), isTrue);
    });

    test('render scale is capped: an A0 page region stays inside the raster '
        'budget while US Letter keeps the full 3x', () async {
      // A0 (2384x3370 pt): a full-page region at the nominal 3x would ask
      // pdfium for 7152x10110 px = 289 MB of RGBA, up front, in a worker.
      const a0Page = PdfFigurePage(
        pageWidthPts: 2384,
        pageHeightPts: 3370,
        items: [],
      );
      final region = FigureRegion(
        page: 1,
        rectPdf: (left: 0, top: 3370, right: 2384, bottom: 0),
        confidence: 0.9,
        source: FigureRegionSource.captioned,
      );
      final source = FakeFigureSource([a0Page]);
      final saved = await buildExtractor(source).renderRegion(
        'a0.pdf',
        attachmentId: 'a0',
        region: region,
        figureIndex: 0,
      );
      expect(saved, isNotNull);
      final call = source.renderCalls.single;
      final width = call['width']!.toInt();
      final height = call['height']!.toInt();
      expect(width, lessThanOrEqualTo(FigureRegionExtractor.kMaxRenderSidePx));
      expect(height, lessThanOrEqualTo(FigureRegionExtractor.kMaxRenderSidePx));
      expect(
        width * height,
        lessThanOrEqualTo(
          (FigureRegionExtractor.kMaxRenderPixels * 1.01).round(),
        ),
        reason: 'requested raster must fit the documented pixel budget',
      );
      // Degraded, not failed: still a usable ~1x render of the whole sheet.
      expect(width, greaterThan(2000));
      expect(
        FigureRegionExtractor.effectiveRenderScale(region.rectPdf),
        lessThan(FigureRegionExtractor.kFigureRenderScale),
      );

      // A normal page is untouched by the cap.
      expect(
        FigureRegionExtractor.effectiveRenderScale((
          left: 72,
          top: 714,
          right: 540,
          bottom: 398,
        )),
        FigureRegionExtractor.kFigureRenderScale,
      );
    });

    test(
      'detectRegions unions provided OCR items with the text layer',
      () async {
        final fixture = fixtureChineseScanned();
        // The fake text layer is EMPTY — everything arrives via ocrItemsByPage,
        // exactly how Step 14 feeds stored attachment_ocr meta.
        final source = FakeFigureSource([pageOf(fixture, textOnly: true)]);
        final extractor = buildExtractor(source);
        final regions = await extractor.detectRegions(
          'unused.pdf',
          ocrItemsByPage: {1: fixture.ocrItems},
        );
        expect(regions, hasLength(1));
        expect(regions.single.page, 1);
        expect(regions.single.caption, contains('图1'));
        expect(source.disposed, isTrue);
      },
    );
  });

  group('renderRegion (Step 16 on-demand regeneration)', () {
    test(
      're-renders a region from its stored JSON with an identical hash',
      () async {
        final fixture = fixtureSingleColumn();
        final attachment = await buildAttachment(id: 'attY');

        final extractSource = FakeFigureSource([pageOf(fixture)]);
        final extracted = (await buildExtractor(
          extractSource,
        ).extractFigures(attachment)).figures.single;

        // Round-trip the region through JSON — the chunk-meta path.
        final restored = FigureRegion.fromJson(
          jsonDecode(jsonEncode(extracted.region.toJson()))
              as Map<String, dynamic>,
        );
        expect(restored.rectPdf, extracted.region.rectPdf);
        expect(restored.source, FigureRegionSource.captioned);

        // Delete the asset, regenerate on demand.
        final assetFile = File('${derivedDir.path}/${extracted.fileName}');
        await assetFile.delete();
        final renderSource = FakeFigureSource([pageOf(fixture)]);
        final regenerated = await buildExtractor(renderSource).renderRegion(
          attachment.filePath,
          attachmentId: 'attY',
          region: restored,
          figureIndex: 0,
        );
        expect(regenerated, isNotNull);
        expect(regenerated!.fileName, extracted.fileName);
        expect(regenerated.contentHash, extracted.contentHash);
        expect(await assetFile.exists(), isTrue);
      },
    );

    test('out-of-range page or degenerate rect returns null', () async {
      final fixture = fixtureSingleColumn();
      final source = FakeFigureSource([pageOf(fixture)]);
      final extractor = buildExtractor(source);

      expect(
        await extractor.renderRegion(
          'x.pdf',
          attachmentId: 'a',
          region: FigureRegion(
            page: 9,
            rectPdf: (left: 0, top: 100, right: 100, bottom: 0),
            confidence: 0.9,
            source: FigureRegionSource.captioned,
          ),
          figureIndex: 0,
        ),
        isNull,
      );

      final source2 = FakeFigureSource([pageOf(fixture)]);
      expect(
        await buildExtractor(source2).renderRegion(
          'x.pdf',
          attachmentId: 'a',
          region: FigureRegion(
            page: 1,
            // Zero-height rect → degenerate after rounding.
            rectPdf: (left: 10, top: 20, right: 200, bottom: 20),
            confidence: 0.9,
            source: FigureRegionSource.captioned,
          ),
          figureIndex: 0,
        ),
        isNull,
      );
      expect(source2.renderCalls, isEmpty);
    });

    test('a rect that no longer fits the page is refused, not cropped from '
        'the wrong place', () async {
      // The PDF was replaced by a smaller document: the stored rect would
      // still "render fine" and hand back a plausible crop of the wrong
      // area.
      const smallPage = PdfFigurePage(
        pageWidthPts: 300,
        pageHeightPts: 400,
        items: [],
      );
      final source = FakeFigureSource([smallPage]);
      final result = await buildExtractor(source).renderRegion(
        'x.pdf',
        attachmentId: 'a',
        region: FigureRegion(
          page: 1,
          rectPdf: (left: 72, top: 714, right: 540, bottom: 398),
          confidence: 0.9,
          source: FigureRegionSource.captioned,
        ),
        figureIndex: 0,
      );
      expect(result, isNull);
      expect(source.renderCalls, isEmpty);
      expect(source.disposed, isTrue);
    });

    test('opener failure returns null instead of throwing (the documented '
        'contract)', () async {
      final extractor = FigureRegionExtractor(
        opener: (path) async => throw Exception('corrupt'),
        derivedDirLoader: () async => derivedDir,
      );
      expect(
        await extractor.renderRegion(
          'gone.pdf',
          attachmentId: 'a',
          region: FigureRegion(
            page: 1,
            rectPdf: (left: 0, top: 100, right: 100, bottom: 0),
            confidence: 0.9,
            source: FigureRegionSource.captioned,
          ),
          figureIndex: 0,
        ),
        isNull,
      );
    });
  });

  group('confidence threshold plumbing', () {
    test(
      'extractor-level minConfidence admits whitespace candidates',
      () async {
        final fixture = fixtureWhitespaceOnly();
        final gatedSource = FakeFigureSource([pageOf(fixture)]);
        final gated = await buildExtractor(gatedSource).detectRegions('x.pdf');
        expect(gated, isEmpty);

        final openSource = FakeFigureSource([pageOf(fixture)]);
        final admitted = await buildExtractor(
          openSource,
          minConfidence: 0.3,
        ).detectRegions('x.pdf');
        expect(admitted.single.source, FigureRegionSource.whitespace);
      },
    );
  });

  // ─── Live pdfrx integration (skipped by default) ──────────────────────────

  group('pdfrx integration', () {
    test(
      'extracts figure regions from the generated spike PDFs via the real '
      'opener',
      () async {
        final fixtureDir = await Directory.systemTemp.createTemp(
          'figure_pdfrx_integration',
        );
        addTearDown(() => fixtureDir.delete(recursive: true));

        for (final fixture in allSpikeFixtures().take(4)) {
          if (fixture.zhText &&
              !File(
                '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
              ).existsSync()) {
            continue; // No CJK-capable font on this machine.
          }
          final pdfFile = File(
            '${fixtureDir.path}/${fixture.name.split(' ').first}.pdf',
          );
          await pdfFile.writeAsBytes(await buildFixturePdf(fixture));

          final extractor = FigureRegionExtractor(
            derivedDirLoader: () async => fixtureDir,
          );
          final regions = await extractor.detectRegions(pdfFile.path);
          expect(
            regions,
            isNotEmpty,
            reason: '${fixture.name}: live pdfrx should find the region',
          );
          final best = regions
              .map((r) => iou(r.rectPdf, fixture.truthRect))
              .reduce((a, b) => a > b ? a : b);
          // Looser than the geometry spike: live glyph bounds differ from
          // the declared line rects.
          expect(best, greaterThan(0.5), reason: '${fixture.name}: live IoU');
        }
      },
      skip:
          'pdfium cannot initialize headless under flutter_tester '
          '(worker isolate falls back to DynamicLibrary.process()); '
          'remove this skip to run manually.',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
