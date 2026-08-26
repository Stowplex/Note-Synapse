// Unit tests for AttachmentOcrExtractor (plan §3, Step 12).
//
// Everything platform-bound is seamed and faked (see ocr_test_stubs.dart):
// ML Kit cannot run under flutter_tester at all, and pdfrx/pdfium cannot
// initialize headless (see attachment_text_extractor_test.dart). These tests
// cover the pure logic: policy gates, the merge (suppression) policy, the
// raster↔PDF coordinate transform, battery guards, script fallback, bounds
// persistence, and abort semantics.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/attachment_ocr_extractor.dart';
import 'package:note_synapse/services/search/note_chunker.dart';
import 'package:note_synapse/services/search/search_text_normalizer.dart';

import 'ocr_test_stubs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database;
    tempDir = await Directory.systemTemp.createTemp('ocr_extractor_test');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<String> createBackingFile(String name, [String? content]) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(content ?? 'dummy bytes for $name');
    return file.path;
  }

  Future<Attachment> buildAttachment({
    String id = 'att1',
    String noteId = 'n1',
    String fileName = 'doc.pdf',
    Map<String, dynamic>? metadata,
    bool createFile = true,
  }) async {
    final path = createFile
        ? await createBackingFile(fileName)
        : '${tempDir.path}/$fileName';
    return Attachment(
      id: id,
      noteId: noteId,
      filePath: path,
      fileName: fileName,
      fileType: fileName.split('.').last,
      createdAt: DateTime.now(),
      isRelativePath: false,
      metadata: metadata,
    );
  }

  Future<void> insertNote(String id) async {
    await db.insertNote(
      Note(
        id: id,
        title: 'Note $id',
        content: 'body',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  AttachmentOcrExtractor buildExtractor({
    FakeOcrEngine? engine,
    FakeOcrRenderSource Function(String path)? sourceFor,
    BatteryStatus battery = const BatteryStatus(level: 100, charging: false),
    Future<BatteryStatus> Function()? batteryLoader,
    OcrScript script = OcrScript.latin,
    int pageCap = 100,
    bool ocrEnabled = true,
    void Function()? onOpen,
  }) {
    return AttachmentOcrExtractor(
      db,
      opener: (path) async {
        onOpen?.call();
        return sourceFor?.call(path) ?? FakeOcrRenderSource(1);
      },
      engine: engine ?? FakeOcrEngine(),
      batteryLoader: batteryLoader ?? (() async => battery),
      scriptLoader: () async => script,
      pageCapLoader: () async => pageCap,
      ocrEnabledLoader: () async => ocrEnabled,
      tempDirLoader: () async => tempDir.path,
    );
  }

  group('coordinate transform', () {
    test('forward transform matches the §4.1 spec (y-flip)', () {
      // 612x792pt page at 2x: a rect whose TOP is at y=750 (y-up) starts
      // (792-750)*2 = 84 px from the raster top (y-down).
      final raster = pdfRectToRasterRect(
        (left: 72, bottom: 700, right: 200, top: 750),
        renderScale: 2,
        pageHeightPts: 792,
      );
      expect(raster.left, 144);
      expect(raster.top, 84);
      expect(raster.width, 256);
      expect(raster.height, 100);
    });

    test('inverse transform round-trips PDF → raster(2x) → PDF', () {
      const original = (left: 72.0, bottom: 700.0, right: 200.0, top: 750.0);
      final raster = pdfRectToRasterRect(
        original,
        renderScale: 2,
        pageHeightPts: 792,
      );
      final back = rasterRectToPdfRect(
        raster,
        renderScale: 2,
        pageHeightPts: 792,
      );
      expect(back.left, closeTo(original.left, 1e-9));
      expect(back.bottom, closeTo(original.bottom, 1e-9));
      expect(back.right, closeTo(original.right, 1e-9));
      expect(back.top, closeTo(original.top, 1e-9));
    });

    test('renderScaleY (independent height rounding) drives the y axis', () {
      // x at 2 px/pt, y at 3 px/pt: the y-flip and the vertical extent must
      // use the VERTICAL scale, x stays on the horizontal one.
      final raster = pdfRectToRasterRect(
        (left: 10, bottom: 20, right: 30, top: 40),
        renderScale: 2,
        renderScaleY: 3,
        pageHeightPts: 100,
      );
      expect(raster.left, 20);
      expect(raster.top, (100 - 40) * 3);
      expect(raster.width, 40);
      expect(raster.height, (40 - 20) * 3);

      final back = rasterRectToPdfRect(
        raster,
        renderScale: 2,
        renderScaleY: 3,
        pageHeightPts: 100,
      );
      expect(back.left, closeTo(10, 1e-9));
      expect(back.bottom, closeTo(20, 1e-9));
      expect(back.right, closeTo(30, 1e-9));
      expect(back.top, closeTo(40, 1e-9));
    });

    test('y-flip anchored on the actual rendered height round-trips', () {
      // 612.3x791.7pt page at nominal 2x renders 1225x1583 px: the axes
      // round independently, so sx != sy. The inverse must still round-trip.
      const pageHeightPts = 791.7;
      const sx = 1225 / 612.3;
      const sy = 1583 / pageHeightPts;
      const original = (left: 72.0, bottom: 700.0, right: 200.0, top: 750.0);
      final raster = pdfRectToRasterRect(
        original,
        renderScale: sx,
        renderScaleY: sy,
        pageHeightPts: pageHeightPts,
      );
      final back = rasterRectToPdfRect(
        raster,
        renderScale: sx,
        renderScaleY: sy,
        pageHeightPts: pageHeightPts,
      );
      expect(back.left, closeTo(original.left, 1e-9));
      expect(back.bottom, closeTo(original.bottom, 1e-9));
      expect(back.right, closeTo(original.right, 1e-9));
      expect(back.top, closeTo(original.top, 1e-9));
    });

    test('inverse keeps y-up ordering: top > bottom in PDF space', () {
      final pdf = rasterRectToPdfRect(
        const ui.Rect.fromLTWH(0, 100, 50, 60),
        renderScale: 2,
        pageHeightPts: 792,
      );
      expect(pdf.top, greaterThan(pdf.bottom));
      expect(pdf.top, 792 - 50); // 100px / 2 from the top edge.
      expect(pdf.bottom, 792 - 80); // (100+60)px / 2.
    });
  });

  group('merge policy (normalized-overlap suppression)', () {
    Map<String, int> pageTokens(String rawText) =>
        ocrTokenCounts(normalizeForIndex(rawText));

    test('block fully contained in the text layer is suppressed', () {
      final tokens = pageTokens(
        'The quick brown fox jumps over the lazy dog near the river bank.',
      );
      expect(isOcrBlockSuppressed('quick brown fox', tokens), isTrue);
    });

    test('containment >= 70% is suppressed, < 70% is kept', () {
      final tokens = pageTokens('alpha beta gamma delta epsilon zeta eta');
      // 10 tokens, 7 contained: exactly 70% → suppressed (boundary is >=).
      expect(
        isOcrBlockSuppressed(
          'alpha beta gamma delta epsilon zeta eta theta iota kappa',
          tokens,
        ),
        isTrue,
      );
      // 7 tokens, 4 contained (57%) → kept.
      expect(
        isOcrBlockSuppressed('alpha beta gamma delta theta iota kappa', tokens),
        isFalse,
      );
      // 7 tokens, 5 contained (71%) → suppressed.
      expect(
        isOcrBlockSuppressed(
          'alpha beta gamma delta epsilon theta iota',
          tokens,
        ),
        isTrue,
      );
    });

    test('multiset counting: repeats beyond the page count are novel', () {
      final tokens = pageTokens('total total subtotal');
      // 'total' x4: only 2 available in the page multiset → 2/4 = 50% kept.
      expect(isOcrBlockSuppressed('total total total total', tokens), isFalse);
    });

    test('novel text is kept even when the page has text', () {
      final tokens = pageTokens('An essay about economics and markets.');
      expect(
        isOcrBlockSuppressed('bioluminescent axolotl diagram', tokens),
        isFalse,
      );
    });

    test('Chinese text dedupes via CJK bigrams', () {
      final tokens = pageTokens('中文搜索引擎的设计与实现');
      // Substring of the page text: its bigrams are all contained.
      expect(isOcrBlockSuppressed('中文搜索', tokens), isTrue);
      // Novel zh text: different bigrams.
      expect(isOcrBlockSuppressed('量子计算机', tokens), isFalse);
    });

    test('empty / punctuation-only blocks are suppressed', () {
      expect(isOcrBlockSuppressed('', const {}), isTrue);
      expect(isOcrBlockSuppressed('***', const {}), isTrue);
    });

    test('empty text layer suppresses nothing', () {
      expect(isOcrBlockSuppressed('any text at all', const {}), isFalse);
    });
  });

  group('policy gates (checked before any open/recognize)', () {
    test('ocr:false is skipped', () async {
      await insertNote('n1');
      var opens = 0;
      final engine = FakeOcrEngine();
      final extractor = buildExtractor(engine: engine, onOpen: () => opens++);
      final attachment = await buildAttachment(
        metadata: {
          'searchIndex': {'ocr': false},
        },
      );
      final result = await extractor.extractOcr(attachment);
      expect(result.status, OcrExtractionStatus.skippedPolicyOff);
      expect(opens, 0);
      expect(engine.calls, isEmpty);
    });

    test('the GLOBAL ocr switch off skips every attachment, whatever its '
        'per-attachment flag says', () async {
      await insertNote('n1');
      var opens = 0;
      final engine = FakeOcrEngine();
      final extractor = buildExtractor(
        engine: engine,
        ocrEnabled: false,
        onOpen: () => opens++,
      );
      // PDF with the per-attachment flag explicitly ON, and a raster image.
      final pdf = await buildAttachment(
        metadata: {
          'searchIndex': {'ocr': true},
        },
      );
      final image = await buildAttachment(id: 'att2', fileName: 'photo.png');
      expect(
        (await extractor.extractOcr(pdf)).status,
        OcrExtractionStatus.skippedPolicyOff,
      );
      expect(
        (await extractor.extractOcr(image)).status,
        OcrExtractionStatus.skippedPolicyOff,
      );
      expect(opens, 0, reason: 'no CPU work: nothing is even opened');
      expect(engine.calls, isEmpty);
    });

    test('the global switch off skips even on a low battery, so the purge '
        'is never deferred', () async {
      await insertNote('n1');
      final extractor = buildExtractor(
        ocrEnabled: false,
        battery: const BatteryStatus(level: 3, charging: false),
      );
      // A battery deferral writes no state row, which would leave the
      // attachment's stale ocr chunks in the index until it charges.
      expect(
        (await extractor.extractOcr(await buildAttachment())).status,
        OcrExtractionStatus.skippedPolicyOff,
      );
    });

    test('excluded note is skipped (metadata read from db)', () async {
      await insertNote('n1');
      await db.updateNoteMetadata('n1', {
        'searchIndex': {'exclude': true},
      });
      var opens = 0;
      final extractor = buildExtractor(onOpen: () => opens++);
      final result = await extractor.extractOcr(await buildAttachment());
      expect(result.status, OcrExtractionStatus.skippedNoteExcluded);
      expect(opens, 0);
    });

    test(
      'SVG (and other non-raster, non-PDF types) are not eligible',
      () async {
        await insertNote('n1');
        final engine = FakeOcrEngine();
        final extractor = buildExtractor(engine: engine);
        for (final name in ['diagram.svg', 'voice.m4a', 'notes.txt']) {
          final result = await extractor.extractOcr(
            await buildAttachment(id: 'att_$name', fileName: name),
          );
          expect(
            result.status,
            OcrExtractionStatus.skippedNotEligible,
            reason: '$name must not be OCRed',
          );
        }
        expect(engine.calls, isEmpty);
      },
    );

    test('raster image attachments ARE processed (png/jpg/webp)', () async {
      await insertNote('n1');
      for (final name in ['photo.png', 'scan.JPG', 'pic.webp']) {
        final engine = FakeOcrEngine(
          blocksFor: (content, script) => [
            OcrTextBlock(
              text: 'text inside $name',
              bounds: const ui.Rect.fromLTWH(10, 20, 100, 30),
            ),
          ],
        );
        final extractor = buildExtractor(engine: engine);
        final attachment = await buildAttachment(
          id: 'att_$name',
          fileName: name,
        );
        final result = await extractor.extractOcr(attachment);
        expect(
          result.status,
          OcrExtractionStatus.extracted,
          reason: '$name must be OCRed',
        );
        expect(result.pageCount, 1);
        expect(result.drafts, hasLength(1));
        expect(result.drafts.single.sourceType, 'attachment_ocr');
        expect(
          result.drafts.single.page,
          isNull,
          reason: 'raster images are page-less',
        );
        expect(result.drafts.single.text, contains('text inside'));
        // The engine received the ORIGINAL image path (no temp copy).
        expect(engine.calls.single.$1, contains('dummy bytes for'));
      }
    });

    test(
      'over the page cap without text:on is skipped; text:on bypasses',
      () async {
        await insertNote('n1');
        final engine = FakeOcrEngine(
          blocksFor: (content, script) => [
            OcrTextBlock(
              text: 'novel text on $content',
              bounds: const ui.Rect.fromLTWH(0, 0, 10, 10),
            ),
          ],
        );
        final extractor = buildExtractor(
          engine: engine,
          pageCap: 3,
          sourceFor: (path) => FakeOcrRenderSource(5),
        );
        final capped = await extractor.extractOcr(await buildAttachment());
        expect(capped.status, OcrExtractionStatus.skippedTooLarge);
        expect(capped.pageCount, 5);
        expect(engine.calls, isEmpty, reason: 'no page may be recognized');

        final optedIn = await extractor.extractOcr(
          await buildAttachment(
            id: 'att2',
            fileName: 'doc2.pdf',
            metadata: {
              'searchIndex': {'text': 'on'},
            },
          ),
        );
        expect(optedIn.status, OcrExtractionStatus.extracted);
        expect(optedIn.drafts.map((d) => d.page).toSet(), {1, 2, 3, 4, 5});
      },
    );

    test('missing file fails without opening', () async {
      await insertNote('n1');
      var opens = 0;
      final extractor = buildExtractor(onOpen: () => opens++);
      final result = await extractor.extractOcr(
        await buildAttachment(createFile: false),
      );
      expect(result.status, OcrExtractionStatus.failed);
      expect(opens, 0);
    });
  });

  group('battery guard', () {
    test('low battery + not charging defers before any work', () async {
      await insertNote('n1');
      var opens = 0;
      final engine = FakeOcrEngine();
      final extractor = buildExtractor(
        engine: engine,
        battery: const BatteryStatus(level: 15, charging: false),
        onOpen: () => opens++,
      );
      final result = await extractor.extractOcr(await buildAttachment());
      expect(result.status, OcrExtractionStatus.deferredBattery);
      expect(opens, 0);
      expect(engine.calls, isEmpty);
    });

    test('low battery while CHARGING still runs', () async {
      await insertNote('n1');
      final extractor = buildExtractor(
        battery: const BatteryStatus(level: 5, charging: true),
      );
      final result = await extractor.extractOcr(await buildAttachment());
      expect(result.status, OcrExtractionStatus.extracted);
    });

    test(
      'battery drop mid-document defers and discards partial output',
      () async {
        await insertNote('n1');
        var level = 50;
        final engine = FakeOcrEngine(
          blocksFor: (content, script) => [
            OcrTextBlock(
              text: 'novel $content',
              bounds: const ui.Rect.fromLTWH(0, 0, 5, 5),
            ),
          ],
        );
        final extractor = buildExtractor(
          engine: engine,
          batteryLoader: () async =>
              BatteryStatus(level: level, charging: false),
          sourceFor: (path) => FakeOcrRenderSource(
            25,
            onRender: (i) async {
              // Battery dies while early pages process; the recheck (every 10
              // pages) must stop the run.
              if (i >= 5) level = 10;
            },
          ),
        );
        final result = await extractor.extractOcr(await buildAttachment());
        expect(result.status, OcrExtractionStatus.deferredBattery);
        expect(result.drafts, isEmpty, reason: 'partial output is discarded');
        expect(engine.calls.length, lessThan(25));
      },
    );
  });

  group('script selection', () {
    test('primary script from the loader is used', () async {
      await insertNote('n1');
      final engine = FakeOcrEngine(
        blocksFor: (content, script) => [
          OcrTextBlock(
            text: '中文内容',
            bounds: const ui.Rect.fromLTWH(0, 0, 10, 10),
          ),
        ],
      );
      final extractor = buildExtractor(
        engine: engine,
        script: OcrScript.chinese,
      );
      await extractor.extractOcr(await buildAttachment());
      expect(engine.calls.single.$2, OcrScript.chinese);
    });

    test(
      'Latin-empty page falls back to the Chinese recognizer once',
      () async {
        await insertNote('n1');
        final engine = FakeOcrEngine(
          blocksFor: (content, script) => script == OcrScript.chinese
              ? [
                  OcrTextBlock(
                    text: '扫描的中文页面',
                    bounds: const ui.Rect.fromLTWH(0, 0, 10, 10),
                  ),
                ]
              : const [],
        );
        final extractor = buildExtractor(
          engine: engine,
          script: OcrScript.latin,
        );
        final result = await extractor.extractOcr(await buildAttachment());
        expect(engine.calls.map((c) => c.$2).toList(), [
          OcrScript.latin,
          OcrScript.chinese,
        ]);
        expect(result.drafts.single.text, contains('扫描的中文页面'));
      },
    );

    test('Chinese primary never falls back (no double pass)', () async {
      await insertNote('n1');
      final engine = FakeOcrEngine();
      final extractor = buildExtractor(
        engine: engine,
        script: OcrScript.chinese,
      );
      await extractor.extractOcr(await buildAttachment());
      expect(engine.calls, hasLength(1));
    });
  });

  group('bounds + renderScale persistence', () {
    test(
      'PDF block bounds are mapped to PDF coordinates in the meta JSON',
      () async {
        await insertNote('n1');
        final engine = FakeOcrEngine(
          blocksFor: (content, script) => [
            const OcrTextBlock(
              text: 'figure label text',
              // Raster px at 2x on a 612x792pt page.
              bounds: ui.Rect.fromLTRB(100, 200, 300, 250),
            ),
          ],
        );
        final extractor = buildExtractor(
          engine: engine,
          sourceFor: (path) =>
              FakeOcrRenderSource(1, pageWidthPts: 612, pageHeightPts: 792),
        );
        final result = await extractor.extractOcr(await buildAttachment());
        final draft = result.drafts.single;
        expect(draft.page, 1);

        final meta = jsonDecode(draft.meta!) as Map<String, dynamic>;
        expect(meta['renderScale'], 2.0);
        expect(
          meta['renderScaleY'],
          2.0,
          reason:
              'PDF pages persist the vertical scale alongside the '
              'horizontal one (equal here — the fake rounds nothing)',
        );
        expect(meta['space'], 'pdf');
        final bounds = meta['blockBounds'] as List;
        final rect = (bounds.single as Map)['rect'] as Map<String, dynamic>;
        // Inverse transform: l=100/2, t=792-200/2, r=300/2, b=792-250/2.
        expect(rect['l'], 50);
        expect(rect['t'], 692);
        expect(rect['r'], 150);
        expect(rect['b'], 667);
        expect((bounds.single as Map)['text'], 'figure label text');
        // meta participates in the contentHash (a bounds change re-writes).
        expect(draft.contentHash, isNot(ChunkDraftHashProbe.textOnly(draft)));
      },
    );

    test('image bounds stay in pixel space with renderScale 1', () async {
      await insertNote('n1');
      final engine = FakeOcrEngine(
        blocksFor: (content, script) => [
          const OcrTextBlock(
            text: 'sticker text',
            bounds: ui.Rect.fromLTRB(5, 10, 55, 40),
          ),
        ],
      );
      final extractor = buildExtractor(engine: engine);
      final result = await extractor.extractOcr(
        await buildAttachment(id: 'img1', fileName: 'photo.png'),
      );
      final meta =
          jsonDecode(result.drafts.single.meta!) as Map<String, dynamic>;
      expect(meta['renderScale'], 1.0);
      expect(meta['space'], 'image');
      final rect =
          ((meta['blockBounds'] as List).single as Map)['rect']
              as Map<String, dynamic>;
      expect(rect['l'], 5);
      expect(rect['t'], 10);
      expect(rect['r'], 55);
      expect(rect['b'], 40);
    });
  });

  group('merge against the stored text layer', () {
    test(
      'text-layer-covered blocks are dropped; only novel text chunks',
      () async {
        await insertNote('n1');
        final attachment = await buildAttachment();
        // Simulate the pdf_text stage having indexed page 1's text layer.
        final raw = await db.database;
        await raw.insert('search_chunks', {
          'chunkKey': 'n1:attachment_text:att1:0',
          'noteId': 'n1',
          'sourceType': 'attachment_text',
          'sourceId': 'att1',
          'page': 1,
          'seq': 0,
          'text': 'The quick brown fox jumps over the lazy dog every day.',
          'contentHash': 'x',
          'updatedAt': 0,
        });

        final engine = FakeOcrEngine(
          blocksFor: (content, script) => [
            const OcrTextBlock(
              text: 'quick brown fox jumps over',
              bounds: ui.Rect.fromLTWH(0, 0, 10, 10),
            ),
            const OcrTextBlock(
              text: 'bioluminescent axolotl diagram',
              bounds: ui.Rect.fromLTWH(0, 20, 10, 10),
            ),
          ],
        );
        final extractor = buildExtractor(engine: engine);
        final result = await extractor.extractOcr(attachment);
        expect(result.drafts, hasLength(1));
        expect(result.drafts.single.text, 'bioluminescent axolotl diagram');
        final meta =
            jsonDecode(result.drafts.single.meta!) as Map<String, dynamic>;
        expect(
          (meta['blockBounds'] as List),
          hasLength(1),
          reason: 'suppressed blocks must not leave bounds behind',
        );
      },
    );

    test('fully suppressed page yields no drafts', () async {
      await insertNote('n1');
      final attachment = await buildAttachment();
      final raw = await db.database;
      await raw.insert('search_chunks', {
        'chunkKey': 'n1:attachment_text:att1:0',
        'noteId': 'n1',
        'sourceType': 'attachment_text',
        'sourceId': 'att1',
        'page': 1,
        'seq': 0,
        'text': 'alpha beta gamma delta',
        'contentHash': 'x',
        'updatedAt': 0,
      });
      final engine = FakeOcrEngine(
        blocksFor: (content, script) => [
          const OcrTextBlock(
            text: 'alpha beta gamma',
            bounds: ui.Rect.fromLTWH(0, 0, 10, 10),
          ),
        ],
      );
      final extractor = buildExtractor(engine: engine);
      final result = await extractor.extractOcr(attachment);
      expect(result.status, OcrExtractionStatus.extracted);
      expect(result.drafts, isEmpty);
    });
  });

  group('all-pages-failed vs genuinely empty', () {
    test('engine throwing on every page fails the document (retryable), '
        'not done', () async {
      await insertNote('n1');
      final engine = FakeOcrEngine(
        blocksFor: (content, script) => throw StateError('engine boom'),
      );
      final extractor = buildExtractor(
        engine: engine,
        sourceFor: (path) => FakeOcrRenderSource(3),
      );
      final result = await extractor.extractOcr(await buildAttachment());
      expect(
        result.status,
        OcrExtractionStatus.failed,
        reason:
            'all pages raising is an engine/document failure — '
            'recording it as extracted would freeze it as done',
      );
      expect(result.drafts, isEmpty);
      expect(result.errorMessage, contains('boom'));
    });

    test('a single broken page does not lose the document', () async {
      await insertNote('n1');
      final engine = FakeOcrEngine(
        blocksFor: (content, script) {
          if (content == 'page:0') throw StateError('one bad page');
          return [
            OcrTextBlock(
              text: 'novel $content',
              bounds: const ui.Rect.fromLTWH(0, 0, 5, 5),
            ),
          ];
        },
      );
      final extractor = buildExtractor(
        engine: engine,
        sourceFor: (path) => FakeOcrRenderSource(3),
      );
      final result = await extractor.extractOcr(await buildAttachment());
      expect(result.status, OcrExtractionStatus.extracted);
      expect(result.drafts.map((d) => d.page).toSet(), {2, 3});
    });

    test('pages genuinely empty extract successfully with no drafts', () async {
      await insertNote('n1');
      final extractor = buildExtractor(
        engine: FakeOcrEngine(), // Finds nothing anywhere.
        sourceFor: (path) => FakeOcrRenderSource(3),
      );
      final result = await extractor.extractOcr(await buildAttachment());
      expect(result.status, OcrExtractionStatus.extracted);
      expect(result.drafts, isEmpty);
      expect(result.pageCount, 3);
    });
  });

  group('abort + chunk identity', () {
    test('shouldAbort between pages discards partial output', () async {
      await insertNote('n1');
      final engine = FakeOcrEngine(
        blocksFor: (content, script) => [
          OcrTextBlock(
            text: 'novel $content',
            bounds: const ui.Rect.fromLTWH(0, 0, 5, 5),
          ),
        ],
      );
      var abort = false;
      final extractor = buildExtractor(
        engine: engine,
        sourceFor: (path) => FakeOcrRenderSource(
          10,
          onRender: (i) async {
            if (i >= 2) abort = true;
          },
        ),
      );
      final result = await extractor.extractOcr(
        await buildAttachment(),
        shouldAbort: () => abort,
      );
      expect(result.status, OcrExtractionStatus.aborted);
      expect(result.drafts, isEmpty);
    });

    test('page-banded seq keys mirror chunkPdfPage', () async {
      await insertNote('n1');
      final engine = FakeOcrEngine(
        blocksFor: (content, script) => [
          OcrTextBlock(
            text: 'unique novel text for $content',
            bounds: const ui.Rect.fromLTWH(0, 0, 5, 5),
          ),
        ],
      );
      final extractor = buildExtractor(
        engine: engine,
        sourceFor: (path) => FakeOcrRenderSource(2),
      );
      final result = await extractor.extractOcr(await buildAttachment());
      expect(result.drafts, hasLength(2));
      expect(result.drafts[0].chunkKey, 'n1:attachment_ocr:att1:0');
      expect(result.drafts[0].page, 1);
      expect(result.drafts[1].chunkKey, 'n1:attachment_ocr:att1:1000');
      expect(result.drafts[1].page, 2);
    });

    test('temp render files are cleaned up', () async {
      await insertNote('n1');
      final extractor = buildExtractor(
        sourceFor: (path) => FakeOcrRenderSource(3),
      );
      await extractor.extractOcr(await buildAttachment());
      final leftovers = tempDir
          .listSync()
          .where((e) => e.path.contains('ocr_att1'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}

/// Probe asserting ChunkDraft's hash covers meta: recomputes the text-only
/// hash for comparison.
class ChunkDraftHashProbe {
  static String textOnly(dynamic draft) {
    final clone = ChunkDraft(
      noteId: draft.noteId,
      sourceType: draft.sourceType,
      sourceId: draft.sourceId,
      page: draft.page,
      seq: draft.seq,
      text: draft.text,
    );
    return clone.contentHash;
  }
}
