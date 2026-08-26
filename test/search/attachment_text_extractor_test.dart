// Unit tests for AttachmentTextExtractor (plan §3, Step 11).
//
// pdfrx/pdfium CANNOT initialize headless under `flutter test`: the engine's
// background worker isolate falls back to DynamicLibrary.process() for the
// pdfium symbols and fails even with Pdfrx.pdfiumModulePath set (verified —
// the worker never receives the propagated module path before FPDF init
// runs). Extraction logic is therefore tested through the PdfTextSource
// seam with fakes; one skipped-by-default integration test exercises the
// real pdfrx opener against fixture PDFs generated with the `pdf` package
// (run manually on a machine where pdfium can load).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/attachment_text_extractor.dart';
import 'package:note_synapse/services/search_settings_service.dart';

class _FakeSource implements PdfTextSource {
  _FakeSource(this.pages);

  final List<String> pages;
  bool disposed = false;
  int pageLoads = 0;

  @override
  int get pageCount => pages.length;

  @override
  Future<String> loadPageText(int pageIndex) async {
    pageLoads++;
    return pages[pageIndex];
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

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
    tempDir = await Directory.systemTemp.createTemp('extractor_test');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  /// A real (dummy-content) file so fileFingerprint has something to stat.
  Future<String> createBackingFile(String name) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString('dummy pdf bytes');
    return file.path;
  }

  Future<Attachment> buildPdfAttachment({
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

  group('extractPdfText', () {
    test(
      'produces per-page chunks: 1-based pages, banded keys, text',
      () async {
        await insertNote('n1');
        final source = _FakeSource([
          'Alpha page about quantum entanglement.',
          '第二页 中文搜索 content on page two.',
        ]);
        final extractor = AttachmentTextExtractor(
          db,
          opener: (path) async => source,
          pageCapLoader: () async => 100,
        );
        final attachment = await buildPdfAttachment();

        final result = await extractor.extractPdfText(attachment);

        expect(result.status, ExtractionStatus.extracted);
        expect(result.pageCount, 2);
        expect(result.drafts, hasLength(2));

        final first = result.drafts[0];
        expect(first.page, 1);
        expect(first.sourceType, 'attachment_text');
        expect(first.sourceId, 'att1');
        expect(first.chunkKey, 'n1:attachment_text:att1:0');
        expect(first.text, contains('quantum entanglement'));

        final second = result.drafts[1];
        expect(second.page, 2);
        expect(second.chunkKey, 'n1:attachment_text:att1:1000');
        expect(second.text, contains('中文搜索'));

        expect(source.disposed, isTrue);
      },
    );

    test('missing file fails without opening', () async {
      await insertNote('n1');
      var openCalls = 0;
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async {
          openCalls++;
          return _FakeSource(['x']);
        },
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment(createFile: false);

      final result = await extractor.extractPdfText(attachment);
      expect(result.status, ExtractionStatus.failed);
      expect(openCalls, 0);
    });

    test('non-PDF attachment is skipped before opening', () async {
      await insertNote('n1');
      var openCalls = 0;
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async {
          openCalls++;
          return _FakeSource(['x']);
        },
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment(fileName: 'photo.png');

      final result = await extractor.extractPdfText(attachment);
      expect(result.status, ExtractionStatus.skippedNotPdf);
      expect(openCalls, 0);
    });

    test('text policy off is skipped before opening', () async {
      await insertNote('n1');
      var openCalls = 0;
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async {
          openCalls++;
          return _FakeSource(['x']);
        },
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment(
        metadata: {
          'searchIndex': {'text': 'off'},
        },
      );

      final result = await extractor.extractPdfText(attachment);
      expect(result.status, ExtractionStatus.skippedPolicyOff);
      expect(openCalls, 0);
    });

    test(
      'excluded note is skipped before opening (metadata read from db)',
      () async {
        await insertNote('n1');
        await db.updateNoteMetadata('n1', {
          'searchIndex': {'exclude': true},
        });
        var openCalls = 0;
        final extractor = AttachmentTextExtractor(
          db,
          opener: (path) async {
            openCalls++;
            return _FakeSource(['x']);
          },
          pageCapLoader: () async => 100,
        );
        final attachment = await buildPdfAttachment();

        final result = await extractor.extractPdfText(attachment);
        expect(result.status, ExtractionStatus.skippedNoteExcluded);
        expect(openCalls, 0);
      },
    );

    test(
      'over the page cap with default auto policy: skipped, no page reads',
      () async {
        await insertNote('n1');
        final source = _FakeSource(List.filled(120, 'tiny page'));
        final extractor = AttachmentTextExtractor(
          db,
          opener: (path) async => source,
          pageCapLoader: () async => 100,
        );
        final attachment = await buildPdfAttachment();

        final result = await extractor.extractPdfText(attachment);
        expect(result.status, ExtractionStatus.skippedTooLarge);
        expect(result.pageCount, 120);
        expect(source.pageLoads, 0, reason: 'no page text may be loaded');
        expect(source.disposed, isTrue);
      },
    );

    test('over the page cap with explicit on policy: extracted', () async {
      await insertNote('n1');
      final source = _FakeSource(
        List.generate(120, (i) => 'tiny page ${i + 1}'),
      );
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async => source,
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment(
        metadata: {
          'searchIndex': {'text': 'on'},
        },
      );

      final result = await extractor.extractPdfText(attachment);
      expect(result.status, ExtractionStatus.extracted);
      expect(result.drafts, hasLength(120));
      expect(result.drafts.last.page, 120);
      expect(result.drafts.last.chunkKey, 'n1:attachment_text:att1:119000');
    });

    test('shouldAbort between pages discards partial output', () async {
      await insertNote('n1');
      final source = _FakeSource(['page one', 'page two', 'page three']);
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async => source,
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment();

      final result = await extractor.extractPdfText(
        attachment,
        // Aborts before page 2 (checked between pages, after page 1 loaded).
        shouldAbort: () => source.pageLoads >= 1,
      );
      expect(result.status, ExtractionStatus.aborted);
      expect(result.drafts, isEmpty);
      expect(source.pageLoads, 1);
      expect(source.disposed, isTrue);
    });
  });

  group('exceedsPageCap', () {
    test('cheap doc-info open, cached per attachment id', () async {
      await insertNote('n1');
      var openCalls = 0;
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async {
          openCalls++;
          return _FakeSource(List.filled(120, 'p'));
        },
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment();

      expect(await extractor.exceedsPageCap(attachment), isTrue);
      expect(await extractor.exceedsPageCap(attachment), isTrue);
      expect(openCalls, 1, reason: 'page count cached per attachment id');
    });

    test('replaced file invalidates the cached page count', () async {
      await insertNote('n1');
      var openCalls = 0;
      var pages = 120;
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async {
          openCalls++;
          return _FakeSource(List.filled(pages, 'p'));
        },
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment();
      expect(await extractor.getPdfPageCount(attachment), 120);
      expect(await extractor.exceedsPageCap(attachment), isTrue);
      expect(openCalls, 1);

      // Replace the backing file (different byte length -> new size ->
      // new fingerprint) with a shorter document.
      pages = 30;
      await File(
        await attachment.getAbsolutePath(),
      ).writeAsString('replaced backing bytes, different length');

      expect(
        await extractor.getPdfPageCount(attachment),
        30,
        reason: 'a replaced file must get a fresh open and count',
      );
      expect(openCalls, 2);
      expect(await extractor.exceedsPageCap(attachment), isFalse);
      expect(openCalls, 2, reason: 'the refreshed count is cached again');
    });

    test('false for non-PDFs and under-cap documents', () async {
      await insertNote('n1');
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async => _FakeSource(List.filled(30, 'p')),
        pageCapLoader: () async => 100,
      );
      expect(
        await extractor.exceedsPageCap(await buildPdfAttachment()),
        isFalse,
      );
      expect(
        await extractor.exceedsPageCap(
          await buildPdfAttachment(id: 'att2', fileName: 'img.png'),
        ),
        isFalse,
      );
    });
  });

  group('fileFingerprint', () {
    test('is size:mtime for existing files, missing otherwise', () async {
      final extractor = AttachmentTextExtractor(
        db,
        opener: (path) async => _FakeSource(const []),
        pageCapLoader: () async => 100,
      );
      final attachment = await buildPdfAttachment();
      final stat = await File(await attachment.getAbsolutePath()).stat();
      expect(
        await extractor.fileFingerprint(attachment),
        '${stat.size}:${stat.modified.millisecondsSinceEpoch}',
      );

      final gone = await buildPdfAttachment(
        id: 'att2',
        fileName: 'gone.pdf',
        createFile: false,
      );
      expect(await extractor.fileFingerprint(gone), 'missing');
    });
  });

  group('SearchSettingsService page cap', () {
    test('defaults to 100 and round-trips valid values', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SearchSettingsService();
      expect(await settings.getPdfPageCap(), 100);

      await settings.setPdfPageCap(250);
      expect(await settings.getPdfPageCap(), 250);
    });

    test('rejects out-of-range stored values', () async {
      SharedPreferences.setMockInitialValues({'search_index_pdf_page_cap': 0});
      expect(await SearchSettingsService().getPdfPageCap(), 100);
    });
  });

  // Real pdfrx extraction against PDFs generated on the fly with the `pdf`
  // package (into a systemTemp dir — nothing is written under test/).
  // Skipped by default: pdfium cannot initialize under flutter_tester (see
  // header comment). Run manually with the skip flag removed on a machine
  // where pdfrx can load pdfium.
  group('pdfrx integration', () {
    test(
      'extracts generated PDFs via the real opener',
      () async {
        final fixtureDir = await Directory.systemTemp.createTemp(
          'pdfrx_integration',
        );
        addTearDown(() => fixtureDir.delete(recursive: true));

        // 2-page text PDF with known strings (Chinese included when a
        // unicode-capable system font is available; the built-in Helvetica
        // cannot encode CJK).
        final doc = pw.Document();
        doc.addPage(
          pw.Page(
            build: (ctx) => pw.Text('Alpha page about quantum entanglement.'),
          ),
        );
        pw.Font? cjkFont;
        final cjkFontFile = File(
          '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        );
        if (await cjkFontFile.exists()) {
          cjkFont = pw.Font.ttf(
            (await cjkFontFile.readAsBytes()).buffer.asByteData(),
          );
        }
        doc.addPage(
          pw.Page(
            build: (ctx) => pw.Text(
              cjkFont == null
                  ? 'Second page mitochondria text.'
                  : '中文搜索 second page mitochondria text.',
              style: cjkFont == null ? null : pw.TextStyle(font: cjkFont),
            ),
          ),
        );
        final twoPage = File('${fixtureDir.path}/two_page_text.pdf');
        await twoPage.writeAsBytes(await doc.save());

        // 120-page tiny PDF for the cap test.
        final bigDoc = pw.Document();
        for (var i = 1; i <= 120; i++) {
          bigDoc.addPage(pw.Page(build: (ctx) => pw.Text('Tiny page $i')));
        }
        final bigPdf = File('${fixtureDir.path}/many_pages.pdf');
        await bigPdf.writeAsBytes(await bigDoc.save());

        await pdfrxInitialize();
        final source = await openPdfrxTextSource(twoPage.path);
        expect(source.pageCount, 2);
        final page1 = await source.loadPageText(0);
        final page2 = await source.loadPageText(1);
        await source.dispose();
        expect(page1, contains('quantum entanglement'));
        expect(page2, contains('mitochondria'));
        if (cjkFont != null) {
          expect(page2, contains('中文搜索'));
        }

        final big = await openPdfrxTextSource(bigPdf.path);
        expect(big.pageCount, 120);
        await big.dispose();
      },
      skip:
          'pdfium cannot initialize headless under flutter_tester '
          '(worker isolate falls back to DynamicLibrary.process()); '
          'remove this skip to run manually.',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
