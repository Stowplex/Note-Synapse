// Integration tests for NoteIndexService's 'figures' stage (plan §4.1,
// Step 14): figure chunks carrying the resolver's mandatory meta payload, the
// region-identity contentHash (stable across re-renders), row.page ==
// meta.page, the ONE-OCR-chunk-per-page input rule, raster/SVG handling,
// policy gates + purge-on-toggle (chunks AND derived crops), state hashing,
// extraction-failure accounting, and the multimodal embed path.
// Real sqlite via sqflite_common_ffi; pdfrx/ML Kit/providers seamed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

// ignore: depend_on_referenced_packages
import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/attachment_ocr_extractor.dart';
import 'package:note_synapse/services/search/attachment_text_extractor.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider_registry.dart';
import 'package:note_synapse/services/search/figure_region_extractor.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/utils/file_utils.dart';

import 'figure_fixtures.dart';
import 'ocr_test_stubs.dart';

/// A real, tiny PNG whose IHDR DECLARES [width]x[height].
///
/// The embed path must reject it on the header alone — the whole point of the
/// pixel budget is that the rejection happens before the allocation, so a test
/// that had to materialize 20 MP to prove it would be testing the wrong thing
/// (and would cost ~160 MB and seconds of zlib to build).
Uint8List pngWithDeclaredSize(int width, int height) {
  final bytes = Uint8List.fromList(
    img.encodePng(img.Image(width: 1, height: 1)),
  );
  // 8-byte signature, 4-byte length, 'IHDR', then width, height; the chunk
  // CRC covers the type plus the 13 header bytes.
  final view = ByteData.sublistView(bytes);
  view.setUint32(16, width);
  view.setUint32(20, height);
  view.setUint32(
    29,
    getCrc32(bytes.sublist(16, 29), getCrc32('IHDR'.codeUnits)),
  );
  return bytes;
}

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProviderPlatform(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

/// Text-layer fake for the pdf_text stage.
class _FakeTextSource implements PdfTextSource {
  _FakeTextSource(this.pages);
  final List<String> pages;

  @override
  int get pageCount => pages.length;

  @override
  Future<String> loadPageText(int pageIndex) async => pages[pageIndex];

  @override
  Future<void> dispose() async {}
}

/// Figure-geometry fake: serves pre-built pages and renders every region as a
/// real (decodable) PNG, so the derived-asset and multimodal paths run end to
/// end. Every call produces DIFFERENT bytes — the pdfium-upgrade condition
/// the region-identity hash must survive.
class _FakeFigureSource implements PdfFigureSource {
  _FakeFigureSource(
    this.pages, {
    this.failLoadPages = const {},
    this.renderReturnsNull = false,
    this.renderPixelSide = 1000,
  });

  final List<PdfFigurePage> pages;

  /// 0-based page indexes whose load throws.
  final Set<int> failLoadPages;
  final bool renderReturnsNull;
  final int renderPixelSide;

  /// Total renders across all instances (state-hash "did it re-extract?").
  static int renderCalls = 0;

  @override
  int get pageCount => pages.length;

  @override
  Future<PdfFigurePage> loadPage(int pageIndex) async {
    if (failLoadPages.contains(pageIndex)) {
      throw StateError('page $pageIndex is broken');
    }
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
    renderCalls++;
    if (renderReturnsNull) return null;
    final image = img.Image(width: renderPixelSide, height: renderPixelSide);
    img.fill(image, color: img.ColorRgb8(renderCalls % 251, 40, 90));
    return Uint8List.fromList(img.encodePng(image));
  }

  @override
  Future<void> dispose() async {}
}

/// Provider recording the exact inputs it received.
class _FakeProvider implements EmbeddingProvider {
  _FakeProvider({
    required this.providerKey,
    this.supportsImages = false,
    this.maxBatchSize = 2,
  });

  @override
  final String providerKey;
  @override
  final bool supportsImages;

  @override
  final int dimensions = 4;

  /// Small on purpose: the pass must never hand a provider more inputs than
  /// this, images included.
  @override
  final int maxBatchSize;

  @override
  String get displayName => providerKey;
  @override
  Future<bool> isReady() async => true;

  final List<List<EmbeddingInput>> batches = [];

  List<EmbeddingInput> get allInputs => [for (final b in batches) ...b];

  @override
  Future<List<Float32List>> embedDocuments(List<EmbeddingInput> inputs) async {
    batches.add(List.of(inputs));
    return [
      for (var i = 0; i < inputs.length; i++)
        Float32List(dimensions)..[0] = 1.0,
    ];
  }

  @override
  Future<Float32List> embedQuery(String query) async =>
      Float32List(dimensions)..[0] = 1.0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late DataChangeNotifier notifier;
  late NoteIndexService indexer;
  late Directory docsDir;
  late Directory derivedDir;

  /// Figure-geometry pages served per PDF path.
  final figurePagesByPath = <String, List<PdfFigurePage>>{};

  /// Text-layer pages per PDF path (also the OCR/figure page count).
  final textPagesByPath = <String, List<String>>{};

  /// OCR blocks per rendered page, keyed '<path>|<0-based page>'.
  final ocrBlocksByKey = <String, List<OcrTextBlock>>{};

  var failLoadPages = <int>{};
  var renderReturnsNull = false;
  var renderPixelSide = 1000;
  var globalFiguresEnabled = true;
  var globalOcrEnabled = true;
  var pageCap = 100;
  var ocrScript = OcrScript.latin;

  /// The OCR stage's battery gate. Pinned to charging for every test that is
  /// not ABOUT deferral — but it must be a seam, because a figures pass that
  /// runs while OCR has deferred is exactly the state that used to freeze a
  /// scanned document as "no figures, forever".
  var battery = const BatteryStatus(level: 100, charging: true);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  NoteIndexService buildIndexer({EmbeddingProviderRegistry? registry}) {
    return NoteIndexService(
      db,
      changeNotifier: notifier,
      debounceDelay: const Duration(milliseconds: 20),
      extractor: AttachmentTextExtractor(
        db,
        opener: (path) async =>
            _FakeTextSource(textPagesByPath[path] ?? const []),
        pageCapLoader: () async => pageCap,
      ),
      ocrExtractor: AttachmentOcrExtractor(
        db,
        opener: (path) async => FakeOcrRenderSource(
          textPagesByPath[path]?.length ?? 0,
          contentFor: (i) => '$path|$i',
        ),
        engine: FakeOcrEngine(
          blocksFor: (content, script) => ocrBlocksByKey[content] ?? const [],
        ),
        batteryLoader: () async => battery,
        scriptLoader: () async => ocrScript,
        pageCapLoader: () async => pageCap,
        ocrEnabledLoader: () async => globalOcrEnabled,
        tempDirLoader: () async => docsDir.path,
      ),
      figureExtractor: FigureRegionExtractor(
        opener: (path) async => _FakeFigureSource(
          figurePagesByPath[path] ?? const [],
          failLoadPages: failLoadPages,
          renderReturnsNull: renderReturnsNull,
          renderPixelSide: renderPixelSide,
        ),
        derivedDirLoader: () async => derivedDir,
      ),
      embeddingRegistry: registry,
      embedConsentCheck: (_) async => true,
      figuresEnabledLoader: () async => globalFiguresEnabled,
      derivedFigureDirLoader: () async => derivedDir,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    docsDir = await Directory.systemTemp.createTemp('figures_stage');
    // Derived crops live exactly where FileUtils resolves
    // 'attachments/derived/…', so the embed path's relative-path resolution
    // is exercised for real.
    derivedDir = Directory('${docsDir.path}/attachments/derived');
    await derivedDir.create(recursive: true);
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
    FileUtils.resetDocumentsPathCache();
    db = DatabaseService.createNew();
    await db.database;
    notifier = DataChangeNotifier();
    figurePagesByPath.clear();
    textPagesByPath.clear();
    ocrBlocksByKey.clear();
    failLoadPages = <int>{};
    renderReturnsNull = false;
    renderPixelSide = 1000;
    globalFiguresEnabled = true;
    globalOcrEnabled = true;
    pageCap = 100;
    ocrScript = OcrScript.latin;
    battery = const BatteryStatus(level: 100, charging: true);
    _FakeFigureSource.renderCalls = 0;
    indexer = buildIndexer();
  });

  tearDown(() async {
    indexer.dispose();
    await db.close();
    FileUtils.resetDocumentsPathCache();
    await docsDir.delete(recursive: true);
  });

  Note buildNote(String id, {String content = 'note body'}) => Note(
    id: id,
    title: 'Note $id',
    content: content,
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  /// Fires pending debounced reindexes (note inserts scheduled them through
  /// the write hook) and then sweeps.
  Future<void> runIndex({bool force = false}) async {
    await indexer.flushPending();
    await indexer.backfillAll(force: force);
  }

  /// ML Kit-style raster bounds for a PDF-space rect at the OCR stage's
  /// nominal 2x render scale on a 792pt-tall page (inverse of
  /// rasterRectToPdfRect, which the extractor applies before storing meta).
  ui.Rect rasterBoundsFor({
    required double left,
    required double top,
    required double right,
    required double bottom,
    double pageHeightPts = 792,
    double scale = AttachmentOcrExtractor.kOcrRenderScale,
  }) => ui.Rect.fromLTRB(
    left * scale,
    (pageHeightPts - top) * scale,
    right * scale,
    (pageHeightPts - bottom) * scale,
  );

  /// The recognized blocks of a SCANNED page carrying one captioned figure:
  /// body text at the top, a text-free band where the figure is drawn, the
  /// "Figure 1:" caption under it, and body text below. Mirrors
  /// [fixtureSingleColumn]'s geometry, but as OCR output — which is the whole
  /// point, since a scan has no text layer to infer from.
  List<OcrTextBlock> scannedPageBlocks() => [
    for (final line in const [
      ('Signals were sampled at 48 kHz as usual.', 72.0, 758.0, 540.0, 746.0),
      ('Each window was Hann-tapered before FFT.', 72.0, 744.0, 540.0, 732.0),
      ('Spectra were averaged over twelve trials.', 72.0, 730.0, 540.0, 718.0),
      ('Figure 1: Synthetic spectrum of the signal', 90.0, 394.0, 430.0, 380.0),
      (
        'Peaks align with the harmonic grid closely.',
        72.0,
        360.0,
        540.0,
        348.0,
      ),
      ('Residual noise stays below minus sixty dB.', 72.0, 346.0, 540.0, 334.0),
    ])
      OcrTextBlock(
        text: line.$1,
        bounds: rasterBoundsFor(
          left: line.$2,
          top: line.$3,
          right: line.$4,
          bottom: line.$5,
        ),
      ),
  ];

  /// A PDF attachment whose figure geometry comes from the shared spike
  /// fixture (one captioned region, "Figure 1: …").
  Future<Attachment> insertPdfAttachment(
    String id,
    String noteId, {
    int pages = 1,
    Map<int, List<OcrTextBlock>> ocrPageBlocks = const {},
    Map<String, dynamic>? metadata,
    bool includeInAIContext = true,
    bool scanned = false,
  }) async {
    final file = File('${docsDir.path}/$id.pdf');
    await file.writeAsString('backing bytes for $id');
    final fixture = fixtureSingleColumn();
    figurePagesByPath[file.path] = [
      for (var i = 0; i < pages; i++)
        PdfFigurePage(
          pageWidthPts: fixture.pageWidth,
          pageHeightPts: fixture.pageHeight,
          // A SCANNED document has no text layer at all: every caption anchor
          // has to come from OCR.
          items: scanned ? const [] : fixture.textItems,
        ),
    ];
    // The text layer is deliberately unrelated to the OCR blocks so the merge
    // policy never suppresses them.
    textPagesByPath[file.path] = [
      for (var i = 0; i < pages; i++) scanned ? '' : 'text layer page ${i + 1}',
    ];
    for (final entry in ocrPageBlocks.entries) {
      ocrBlocksByKey['${file.path}|${entry.key}'] = entry.value;
    }
    final raw = await db.database;
    await raw.insert('attachments', {
      'id': id,
      'noteId': noteId,
      'filePath': file.path,
      'fileName': '$id.pdf',
      'fileType': 'pdf',
      'isRelativePath': 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': includeInAIContext ? 1 : 0,
      'metadata': metadata == null ? null : jsonEncode(metadata),
    });
    return Attachment(
      id: id,
      noteId: noteId,
      filePath: file.path,
      fileName: '$id.pdf',
      fileType: 'pdf',
      createdAt: DateTime.now(),
      isRelativePath: false,
      includeInAIContext: includeInAIContext,
      metadata: metadata,
    );
  }

  Future<void> insertImageAttachment(
    String id,
    String noteId, {
    String extension = 'png',
    bool includeInAIContext = true,
    Map<String, dynamic>? metadata,
    int pixelSide = 900,
    Uint8List? rawBytes,
  }) async {
    final file = File('${docsDir.path}/$id.$extension');
    if (rawBytes != null) {
      await file.writeAsBytes(rawBytes);
    } else if (extension == 'svg') {
      await file.writeAsString('<svg xmlns="http://www.w3.org/2000/svg"/>');
    } else {
      final image = img.Image(width: pixelSide, height: pixelSide);
      img.fill(image, color: img.ColorRgb8(10, 200, 30));
      await file.writeAsBytes(
        extension == 'jpg' ? img.encodeJpg(image) : img.encodePng(image),
      );
    }
    final raw = await db.database;
    await raw.insert('attachments', {
      'id': id,
      'noteId': noteId,
      'filePath': file.path,
      'fileName': '$id.$extension',
      'fileType': extension,
      'isRelativePath': 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': includeInAIContext ? 1 : 0,
      'metadata': metadata == null ? null : jsonEncode(metadata),
    });
  }

  Future<List<Map<String, dynamic>>> figureChunks(String attId) async {
    final raw = await db.database;
    return raw.query(
      'search_chunks',
      where: "sourceType = 'figure' AND sourceId = ?",
      whereArgs: [attId],
      orderBy: 'seq',
    );
  }

  Future<Map<String, dynamic>?> figuresState(String attId) async {
    final raw = await db.database;
    final rows = await raw.query(
      'search_index_state',
      where: "scopeType = 'attachment' AND scopeId = ? AND stage = 'figures'",
      whereArgs: [attId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> globalStageState(String stage) async {
    final raw = await db.database;
    final rows = await raw.query(
      'search_index_state',
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stage],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> ocrState(String attId) async {
    final raw = await db.database;
    final rows = await raw.query(
      'search_index_state',
      where: "scopeType = 'attachment' AND scopeId = ? AND stage = 'ocr'",
      whereArgs: [attId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Stored embedding modality of [attId]'s figure chunk, or null when it has
  /// no vector yet.
  Future<String?> figureModality(String attId) async {
    final raw = await db.database;
    final rows = await raw.rawQuery(
      'SELECT e.modality FROM chunk_embeddings e '
      'JOIN search_chunks c ON c.id = e.chunkId '
      "WHERE c.sourceType = 'figure' AND c.sourceId = ?",
      [attId],
    );
    return rows.isEmpty ? null : rows.first['modality'] as String?;
  }

  Future<List<String>> derivedFiles() async {
    if (!await derivedDir.exists()) return const [];
    final names = <String>[];
    await for (final entity in derivedDir.list()) {
      if (entity is File) names.add(entity.uri.pathSegments.last);
    }
    names.sort();
    return names;
  }

  // ── chunk shape + identity ────────────────────────────────────────────

  test('writes one figure chunk per region with the resolver contract meta, '
      'and row.page == meta.page', () async {
    await db.insertNote(
      buildNote('n1', content: '![Spectrum overview](a1.pdf)'),
    );
    await insertPdfAttachment('a1', 'n1');
    await runIndex();

    final chunks = await figureChunks('a1');
    expect(chunks, hasLength(1), reason: 'the fixture has ONE real caption');
    final row = chunks.single;
    final meta = jsonDecode(row['meta'] as String) as Map<String, dynamic>;

    // The resolver's NORMATIVE payload.
    expect(meta['page'], isA<int>());
    expect((meta['rect'] as Map).keys, containsAll(['l', 't', 'r', 'b']));
    expect(meta['confidence'], isA<num>());
    expect(meta['source'], isA<String>());
    expect(meta['caption'], contains('Figure 1'));
    expect(meta['figureIndex'], 0, reason: 'mandatory — never guessed');
    expect(
      meta['derivedAssetPath'],
      'attachments/derived/'
      '${FigureRegionExtractor.derivedFigureFileName('a1', meta['page'] as int, 0)}',
    );

    // row.page and meta.page MUST agree: a divergence makes the resolver
    // probe one asset path and regenerate another, re-rasterizing forever.
    expect(row['page'], meta['page']);
    expect(row['sourceId'], 'a1');
    expect(row['chunkKey'], 'n1:figure:a1:${row['seq']}');

    // Nothing renderer-version-dependent may ride in meta.
    expect(meta.keys, isNot(contains('contentHash')));
    expect(meta.keys, isNot(contains('assetHash')));

    // The crop really landed on disk under the name meta points at.
    expect(await derivedFiles(), ['a1_p${meta['page']}_f0.png']);
  });

  test('chunk text carries caption + fileName + markdown alt text + region '
      'OCR text (lexically findable with no provider)', () async {
    await db.insertNote(
      buildNote('n1', content: 'intro\n\n![Bioluminescent axolotl](a1.pdf)\n'),
    );
    await insertPdfAttachment(
      'a1',
      'n1',
      // A block INSIDE the fixture's figure band (y 394..718).
      ocrPageBlocks: {
        0: [
          OcrTextBlock(
            text: 'axis label kilohertz',
            bounds: rasterBoundsFor(
              left: 200,
              top: 600,
              right: 320,
              bottom: 580,
            ),
          ),
        ],
      },
    );
    await runIndex();

    final text = (await figureChunks('a1')).single['text'] as String;
    expect(text, contains('Figure 1'));
    expect(text, contains('a1.pdf'));
    expect(text, contains('Bioluminescent axolotl'));
    expect(text, contains('axis label kilohertz'));
  });

  test('the row contentHash is a REGION-IDENTITY hash: unchanged by a '
      're-render, changed by a moved region', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a1', 'n1');
    await runIndex();
    final firstHash = (await figureChunks('a1')).single['contentHash'];
    final firstPng = await File(
      '${derivedDir.path}/${(await derivedFiles()).single}',
    ).readAsBytes();

    // Force a full re-extraction; the fake re-encodes to different bytes,
    // exactly like a pdfium upgrade.
    await runIndex(force: true);
    final secondPng = await File(
      '${derivedDir.path}/${(await derivedFiles()).single}',
    ).readAsBytes();
    expect(secondPng, isNot(equals(firstPng)));
    expect(
      (await figureChunks('a1')).single['contentHash'],
      firstHash,
      reason: 'a pdfium bump must not dangle every embedded figure URI',
    );

    // Move the region: a different rect IS a different figure.
    final fixture = fixtureSingleColumn();
    figurePagesByPath['${docsDir.path}/a1.pdf'] = [
      PdfFigurePage(
        pageWidthPts: fixture.pageWidth,
        pageHeightPts: fixture.pageHeight,
        items: [
          for (final item in fixture.textItems)
            PageTextItem(
              text: item.text,
              rect: (
                left: item.rect.left,
                top: item.rect.top - 30,
                right: item.rect.right,
                bottom: item.rect.bottom - 30,
              ),
              fragmentRects: [
                for (final r in item.fragmentRects)
                  (
                    left: r.left,
                    top: r.top - 30,
                    right: r.right,
                    bottom: r.bottom - 30,
                  ),
              ],
            ),
        ],
      ),
    ];
    await runIndex(force: true);
    expect((await figureChunks('a1')).single['contentHash'], isNot(firstHash));
  });

  // ── OCR input rule ────────────────────────────────────────────────────

  test('exactly ONE OCR chunk per page feeds region inference (Step 12 puts '
      "the page's full block list on EVERY chunk of that page)", () async {
    await db.insertNote(buildNote('n1'));
    // Enough novel text that the page produces MULTIPLE ocr chunks, each
    // carrying the same full block list.
    final blocks = [
      for (var i = 0; i < 4; i++)
        OcrTextBlock(
          text: List.filled(60, 'lorem$i').join(' '),
          bounds: rasterBoundsFor(
            left: 100,
            top: 600.0 - i * 30,
            right: 400,
            bottom: 580.0 - i * 30,
          ),
        ),
    ];
    final attachment = await insertPdfAttachment(
      'a1',
      'n1',
      ocrPageBlocks: {0: blocks},
    );
    await runIndex();

    final raw = await db.database;
    final ocrChunks = await raw.query(
      'search_chunks',
      where: "sourceType = 'attachment_ocr' AND sourceId = 'a1'",
    );
    expect(
      ocrChunks.length,
      greaterThan(1),
      reason: 'the fixture must actually produce several chunks for page 1',
    );

    final items = await indexer.debugLoadOcrItemsByPage(attachment);
    expect(items.keys, [1]);
    expect(
      items[1],
      hasLength(blocks.length),
      reason:
          "concatenating the page's chunks would multiply every caption "
          'anchor and produce duplicate regions and derived assets',
    );
  });

  // ── raster + SVG ──────────────────────────────────────────────────────

  test('raster image attachments get one figure chunk, no region meta and no '
      'derived asset', () async {
    await db.insertNote(buildNote('n1', content: '![Whiteboard](i1.png)'));
    await insertImageAttachment('i1', 'n1');
    await runIndex();

    final chunks = await figureChunks('i1');
    expect(chunks, hasLength(1));
    expect(chunks.single['meta'], isNull);
    expect(chunks.single['page'], isNull);
    expect(chunks.single['text'], contains('i1.png'));
    expect(chunks.single['text'], contains('Whiteboard'));
    expect(await derivedFiles(), isEmpty);
    expect((await figuresState('i1'))!['status'], 'done');
  });

  test(
    'SVG is LEXICAL-ONLY: filename + alt text, never a rendered asset',
    () async {
      await db.insertNote(buildNote('n1', content: '![Architecture](v1.svg)'));
      await insertImageAttachment('v1', 'n1', extension: 'svg');
      await runIndex();

      final chunks = await figureChunks('v1');
      expect(chunks, hasLength(1));
      expect(chunks.single['meta'], isNull);
      expect(chunks.single['text'], 'v1.svg\nArchitecture');
      expect(await derivedFiles(), isEmpty);
    },
  );

  test(
    'an SVG keeps its lexical chunk under searchIndex.ocr = false',
    () async {
      // Nothing is derived FROM the file (never opened, rendered or OCRed) —
      // its chunk is the file name plus the note's own alt text — so the
      // on-device-derivation flag has nothing to withdraw here. The Step-21
      // dialog hides the toggle for SVG for exactly that reason, so honouring
      // a stored `ocr:false` (inherited by renaming a raster to .svg) would
      // strand the attachment with no lexical row and no way back.
      await db.insertNote(buildNote('n1', content: '![Architecture](v1.svg)'));
      await insertImageAttachment('v1', 'n1', extension: 'svg');
      final raw = await db.database;
      await raw.update(
        'attachments',
        {
          'metadata': jsonEncode({
            'searchIndex': {'ocr': false},
          }),
        },
        where: 'id = ?',
        whereArgs: ['v1'],
      );
      await runIndex();

      expect(await figureChunks('v1'), hasLength(1));
      expect(await derivedFiles(), isEmpty);

      // The gates that DO apply to it still purge.
      await indexer.setNoteSearchExclusion('n1', true);
      await runIndex();
      expect(await figureChunks('v1'), isEmpty);
    },
  );

  // ── policy gates + purge-on-toggle ────────────────────────────────────

  test('global figures toggle off purges chunks AND derived crops; toggling '
      'back on re-extracts', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a1', 'n1');
    await runIndex();
    expect(await figureChunks('a1'), hasLength(1));
    expect(await derivedFiles(), hasLength(1));

    globalFiguresEnabled = false;
    await indexer.ensureBackfilled();
    expect(await figureChunks('a1'), isEmpty);
    expect(
      await derivedFiles(),
      isEmpty,
      reason: 'purge-on-toggle removes the DERIVED data, not just the rows',
    );
    expect((await figuresState('a1'))!['status'], 'skipped');

    globalFiguresEnabled = true;
    await indexer.ensureBackfilled();
    expect(await figureChunks('a1'), hasLength(1));
    expect(await derivedFiles(), hasLength(1));
  });

  test('per-attachment policy off and note exclusion both purge', () async {
    await db.insertNote(buildNote('n1'));
    await db.insertNote(buildNote('n2'));
    await insertPdfAttachment('a1', 'n1');
    await insertPdfAttachment('a2', 'n2');
    await runIndex();
    expect(await figureChunks('a1'), hasLength(1));
    expect(await figureChunks('a2'), hasLength(1));
    expect(await derivedFiles(), hasLength(2));

    final raw = await db.database;
    await raw.update(
      'attachments',
      {
        'metadata': jsonEncode({
          'searchIndex': {'ocr': false},
        }),
      },
      where: 'id = ?',
      whereArgs: ['a1'],
    );
    await indexer.setNoteSearchExclusion('n2', true);
    await runIndex();

    expect(await figureChunks('a1'), isEmpty);
    expect(await figureChunks('a2'), isEmpty);
    expect(await derivedFiles(), isEmpty);
    expect((await figuresState('a1'))!['status'], 'skipped');
    expect((await figuresState('a2'))!['status'], 'skipped');
  });

  // ── state hashing ─────────────────────────────────────────────────────

  test('an unchanged attachment is not re-extracted, but flipping the global '
      'OCR switch or the recognizer script re-runs it', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a1', 'n1');
    await runIndex();
    final baseline = _FakeFigureSource.renderCalls;
    expect(baseline, greaterThan(0));

    await indexer.ensureBackfilled();
    expect(
      _FakeFigureSource.renderCalls,
      baseline,
      reason: 'a state-hash match must short-circuit before opening the PDF',
    );

    globalOcrEnabled = false; // OCR bounds are a caption-anchor source.
    await indexer.ensureBackfilled();
    expect(_FakeFigureSource.renderCalls, greaterThan(baseline));

    final afterOcr = _FakeFigureSource.renderCalls;
    ocrScript = OcrScript.chinese;
    await indexer.ensureBackfilled();
    expect(_FakeFigureSource.renderCalls, greaterThan(afterOcr));
  });

  test(
    'lowering the page cap under an already-indexed PDF re-runs the stage '
    'and purges it to skipped_too_large; raising it back re-extracts',
    () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1', pages: 3);
      await runIndex();
      expect(await figureChunks('a1'), hasLength(3));
      expect(await derivedFiles(), hasLength(3));

      pageCap = 2;
      await indexer.ensureBackfilled();
      expect(await figureChunks('a1'), isEmpty);
      expect(await derivedFiles(), isEmpty);
      expect((await figuresState('a1'))!['status'], 'skipped_too_large');

      pageCap = 100;
      await indexer.ensureBackfilled();
      expect(await figureChunks('a1'), hasLength(3));
      expect((await figuresState('a1'))!['status'], 'done');
    },
  );

  test('an over-cap PDF is opted back in by text:"on"', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a1', 'n1', pages: 3);
    pageCap = 2;
    await runIndex();
    expect((await figuresState('a1'))!['status'], 'skipped_too_large');

    final raw = await db.database;
    await raw.update(
      'attachments',
      {
        'metadata': jsonEncode({
          'searchIndex': {'text': 'on'},
        }),
      },
      where: 'id = ?',
      whereArgs: ['a1'],
    );
    // A per-attachment metadata change reaches the stage through the note's
    // reindex hook (or a sweep) — no GLOBAL policy input moved, so
    // ensureBackfilled would correctly short-circuit here.
    await runIndex();
    expect(await figureChunks('a1'), hasLength(3));
    expect((await figuresState('a1'))!['status'], 'done');
  });

  test('the global figures row carries the policy hash, so a toggle is not '
      'short-circuited by a stale done row', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a1', 'n1');
    await runIndex();
    final done = await globalStageState('figures');
    expect(done!['status'], 'done');
    expect(done['contentHash'], contains('gfig=true'));
    expect(done['contentHash'], contains('cap=100'));

    globalFiguresEnabled = false;
    await indexer.ensureBackfilled();
    expect(
      (await globalStageState('figures'))!['contentHash'],
      contains('gfig=false'),
    );
    expect(await figureChunks('a1'), isEmpty);
  });

  test('editing unrelated note prose does not re-extract, but editing the '
      "attachment's alt text does", () async {
    await db.insertNote(buildNote('n1', content: '![Old label](a1.pdf)'));
    await insertPdfAttachment('a1', 'n1');
    await runIndex();
    final baseline = _FakeFigureSource.renderCalls;

    final raw = await db.database;
    await raw.update(
      'notes',
      {'content': '![Old label](a1.pdf)\n\nsome unrelated prose'},
      where: 'id = ?',
      whereArgs: ['n1'],
    );
    await indexer.reindexNote('n1');
    await indexer.flushPending();
    expect(_FakeFigureSource.renderCalls, baseline);

    await raw.update(
      'notes',
      {'content': '![Brand new label](a1.pdf)'},
      where: 'id = ?',
      whereArgs: ['n1'],
    );
    await indexer.reindexNote('n1');
    await indexer.flushPending();
    expect(_FakeFigureSource.renderCalls, greaterThan(baseline));
    expect(
      (await figureChunks('a1')).single['text'],
      contains('Brand new label'),
    );
  });

  test('a figures pass that ran while the ocr stage DEFERRED is not frozen: '
      'charging re-extracts the scanned document', () async {
    await db.insertNote(buildNote('n1', content: '![Scan](a1.pdf)'));
    // A scanned page: NO text layer, so every caption anchor must come from
    // OCR. This is the document class the bug erased entirely.
    await insertPdfAttachment(
      'a1',
      'n1',
      scanned: true,
      ocrPageBlocks: {0: scannedPageBlocks()},
    );

    // Unplugged at 15%: extractOcr bails at the battery gate and writes NO
    // state row — but only `_paused` gates the figures pass, so it runs.
    battery = const BatteryStatus(level: 15, charging: false);
    await runIndex();

    expect(
      await ocrState('a1'),
      isNull,
      reason: 'a battery deferral is transient — it writes no state row',
    );
    final raw = await db.database;
    expect(
      await raw.query(
        'search_chunks',
        where: "sourceType = 'attachment_ocr' AND sourceId = 'a1'",
      ),
      isEmpty,
    );
    expect(
      await figureChunks('a1'),
      isEmpty,
      reason: 'no text layer and no OCR bounds means no caption anchors',
    );
    expect(
      (await figuresState('a1'))!['status'],
      'done',
      reason:
          'the stage really did record a terminal state — that is the '
          'trap: every OTHER hash component is identical once charging',
    );

    // Plugged back in. The ocr pass now writes real block bounds, and the
    // figures state hash carries that outcome, so the PDF is reopened.
    battery = const BatteryStatus(level: 100, charging: true);
    await indexer.ensureBackfilled();

    expect((await ocrState('a1'))!['status'], 'done');
    final chunks = await figureChunks('a1');
    expect(
      chunks,
      hasLength(1),
      reason:
          'the OCR caption anchor is the only thing that finds this '
          "region — without it the scan has no figures, permanently",
    );
    expect(chunks.single['text'], contains('Figure 1'));
    expect(await derivedFiles(), hasLength(1));
  });

  test('an ocr ERROR state that is later cleared also re-runs the figures '
      'stage', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      scanned: true,
      ocrPageBlocks: {0: scannedPageBlocks()},
    );
    await runIndex();
    expect(await figureChunks('a1'), hasLength(1));
    final baseline = _FakeFigureSource.renderCalls;

    // Rewrite the ocr row as a recorded error, exactly as a failed
    // recognition would: same base hash, different status. The figures hash
    // must move with it.
    final raw = await db.database;
    await raw.update(
      'search_index_state',
      {'status': 'error', 'errorMessage': 'engine blew up'},
      where: "scopeType = 'attachment' AND scopeId = 'a1' AND stage = 'ocr'",
    );
    await indexer.backfillAll();
    expect(
      _FakeFigureSource.renderCalls,
      greaterThan(baseline),
      reason:
          'the ocr outcome changed, so the figures state cannot be '
          'current any more',
    );
  });

  test('purging one attachment leaves a crop whose owner id merely STARTS '
      'with the same characters alone', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a', 'n1');
    // An id that a naive `<id>_p` prefix test cannot tell apart from `a`'s
    // own crops: this one's are named `a_p9_p1_f0.png`.
    await insertPdfAttachment('a_p9', 'n1');
    await runIndex();
    expect(await derivedFiles(), hasLength(2));

    // Purge only `a` (per-attachment derivation opt-out).
    final raw = await db.database;
    await raw.update(
      'attachments',
      {
        'metadata': jsonEncode({
          'searchIndex': {'ocr': false},
        }),
      },
      where: 'id = ?',
      whereArgs: ['a'],
    );
    await runIndex();

    expect(await figureChunks('a'), isEmpty);
    expect(await figureChunks('a_p9'), hasLength(1));
    expect(
      await derivedFiles(),
      hasLength(1),
      reason: "a_p9's crop must survive a purge of a",
    );
    expect((await derivedFiles()).single, startsWith('a_p9_p'));
  });

  group('markdown target matching', () {
    Attachment attachmentAt(String filePath, String fileName) => Attachment(
      id: 'att-1',
      noteId: 'n1',
      filePath: filePath,
      fileName: fileName,
      fileType: fileName.split('.').last,
      createdAt: DateTime.now(),
      isRelativePath: true,
    );

    test('a path suffix only matches on a SEPARATOR boundary', () {
      final attachment = attachmentAt(
        'attachments/team-photo.png',
        'team-photo.png',
      );
      expect(
        NoteIndexService.markdownAltTextFor(
          attachment,
          '![Org chart](photo.png)',
        ),
        isEmpty,
        reason:
            'photo.png is a different file from team-photo.png — the '
            "wrong alt text would enter this attachment's figure chunks AND "
            'its alt digest, re-rendering it on every unrelated image edit',
      );
      expect(
        NoteIndexService.markdownAltTextFor(attachment, '![Any](.png)'),
        isEmpty,
        reason: 'a degenerate target must not claim every png on the note',
      );
    });

    test('the forms a note really uses still match', () {
      final attachment = attachmentAt(
        'attachments/team-photo.png',
        'team-photo.png',
      );
      for (final target in [
        'team-photo.png', // markdown toolbar
        'attachments/team-photo.png', // full stored path
        'notes/n1/attachments/team-photo.png', // deeper relative path
        'synapseresource://attachment/att-1', // resource URI
        'team-photo.png?v=2', // query stripped
      ]) {
        expect(
          NoteIndexService.markdownAltTextFor(attachment, '![Team]($target)'),
          'Team',
          reason: 'target: $target',
        );
      }
    });
  });

  // ── failure accounting ────────────────────────────────────────────────

  test('a document whose every page fails to load is an ERROR, not a silent '
      '"done, no figures"', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a1', 'n1');
    failLoadPages = {0};
    await runIndex();

    final state = await figuresState('a1');
    expect(state!['status'], 'error');
    expect(state['errorMessage'], contains('pages failed to load'));
    expect(await figureChunks('a1'), isEmpty);
  });

  test(
    'a document whose every render fails is an ERROR too (full disk)',
    () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1');
      renderReturnsNull = true;
      await runIndex();

      final state = await figuresState('a1');
      expect(state!['status'], 'error');
      expect(state['errorMessage'], contains('figure renders failed'));
      // Recorded errors are terminal for completeness (a broken file must not
      // pin the sweep) while staying inspectable in settings.
      expect((await globalStageState('figures'))!['status'], 'done');
    },
  );

  // ── stage independence + lifecycle ────────────────────────────────────

  test('the phase-1 chunks flag never waits on figures', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment('a1', 'n1');
    failLoadPages = {0}; // figures stage errors out
    await runIndex();

    expect(await indexer.isBackfillComplete(), isTrue);
    expect((await globalStageState('chunks'))!['status'], 'done');
  });

  test(
    'deleting the note removes its figure chunks and derived crops',
    () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1');
      await runIndex();
      expect(await derivedFiles(), hasLength(1));

      await indexer.removeNote('n1');
      expect(await figureChunks('a1'), isEmpty);
      expect(await derivedFiles(), isEmpty);
    },
  );

  // ── multimodal embedding ──────────────────────────────────────────────

  group('multimodal embed', () {
    Future<_FakeProvider> embedWith({
      required bool supportsImages,
      int maxBatchSize = 2,
    }) async {
      final config = EmbeddingProviderConfig(
        type: supportsImages ? 'fakeimg' : 'faketxt',
        modelName: 'm',
        displayName: 'Fake',
        dimensions: 4,
        supportsImages: supportsImages,
      );
      final provider = _FakeProvider(
        providerKey: config.providerKey,
        supportsImages: supportsImages,
        maxBatchSize: maxBatchSize,
      );
      final registry = EmbeddingProviderRegistry(
        providerBuilder: (_) => provider,
      );
      await registry.setActiveConfig(config);
      // Rebuild the indexer with the embed stage wired (the constructor owns
      // the DatabaseService write hooks, so the old one must go first).
      indexer.dispose();
      indexer = buildIndexer(registry: registry);
      await runIndex();
      return provider;
    }

    test('figure chunks embed as IMAGES when the provider supports them, '
        'downscaled to 768px and within the batch cap', () async {
      await db.insertNote(buildNote('n1', content: '![Diagram](a1.pdf)'));
      await insertPdfAttachment('a1', 'n1');
      await insertImageAttachment('i1', 'n1', pixelSide: 900);

      final provider = await embedWith(supportsImages: true);
      final images = provider.allInputs.where((i) => i.isImage).toList();
      expect(
        images,
        hasLength(2),
        reason: 'the PDF crop and the raster attachment both embed as images',
      );
      for (final input in images) {
        expect(input.mimeType, anyOf('image/png', 'image/jpeg'));
        final decoded = img.decodeImage(input.bytes!)!;
        expect(
          decoded.width <= 768 && decoded.height <= 768,
          isTrue,
          reason: '${decoded.width}x${decoded.height} exceeds the 768 budget',
        );
      }
      for (final batch in provider.batches) {
        expect(batch.length, lessThanOrEqualTo(provider.maxBatchSize));
      }
    });

    test('a provider without image support embeds the figure TEXT', () async {
      await db.insertNote(buildNote('n1', content: '![Diagram](a1.pdf)'));
      await insertPdfAttachment('a1', 'n1');

      final provider = await embedWith(supportsImages: false);
      expect(provider.allInputs.where((i) => i.isImage), isEmpty);
      expect(
        provider.allInputs.map((i) => i.text ?? '').join('\n'),
        contains('a1.pdf'),
      );
    });

    test('stored modality records how each chunk was embedded', () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1');

      await embedWith(supportsImages: true);
      final raw = await db.database;
      final rows = await raw.rawQuery(
        'SELECT c.sourceType, e.modality FROM chunk_embeddings e '
        'JOIN search_chunks c ON c.id = e.chunkId',
      );
      final byType = {
        for (final row in rows) row['sourceType'] as String: row['modality'],
      };
      expect(byType['figure'], 'image');
      expect(byType['meta'], 'text');
    });

    test('includeInAIContext = false and searchIndex.embed = false keep a '
        'figure out of the upload entirely', () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1', includeInAIContext: false);
      await insertPdfAttachment(
        'a2',
        'n1',
        metadata: {
          'searchIndex': {'embed': false},
        },
      );

      final provider = await embedWith(supportsImages: true);
      expect(await figureChunks('a1'), hasLength(1));
      expect(await figureChunks('a2'), hasLength(1));
      expect(
        provider.allInputs.where((i) => i.isImage),
        isEmpty,
        reason: 'neither figure may be uploaded, as image OR as text',
      );
      final texts = provider.allInputs.map((i) => i.text ?? '').join('\n');
      expect(texts, isNot(contains('a1.pdf')));
      expect(texts, isNot(contains('a2.pdf')));
    });

    test('a missing derived crop (the NORMAL state after a restore) falls '
        'back to embedding the figure text', () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1');
      await runIndex();
      for (final name in await derivedFiles()) {
        await File('${derivedDir.path}/$name').delete();
      }

      final provider = await embedWith(supportsImages: true);
      expect(provider.allInputs.where((i) => i.isImage), isEmpty);
      expect(
        provider.allInputs.map((i) => i.text ?? '').join('\n'),
        contains('a1.pdf'),
      );
    });

    test('a figure stored as TEXT is re-embedded as an image once its crop is '
        'back — the fallback is recoverable, not permanent', () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1');
      await runIndex();
      final names = await derivedFiles();
      expect(names, hasLength(1));
      final crop = File('${derivedDir.path}/${names.single}');
      final cropBytes = await crop.readAsBytes();
      await crop.delete();

      final provider = await embedWith(supportsImages: true);
      expect(provider.allInputs.where((i) => i.isImage), isEmpty);
      expect(await figureModality('a1'), 'text');

      // Restoring the crop does NOT change the chunk: the region-identity
      // contentHash is deliberately stable across re-renders, so the ordinary
      // hash-difference gap scan can never see this. Only modality can.
      await crop.writeAsBytes(cropBytes);
      final batchesBefore = provider.batches.length;
      await indexer.backfillAll();

      expect(
        provider.batches.length,
        greaterThan(batchesBefore),
        reason: 'the pass must actually re-embed the figure',
      );
      expect(provider.allInputs.where((i) => i.isImage), hasLength(1));
      expect(await figureModality('a1'), 'image');
    });

    test('an image over the decode budget is embedded as TEXT and settles: '
        'it is not re-attempted on every sweep', () async {
      await db.insertNote(buildNote('n1'));
      // 5000x4000 = 20 MP, over NoteIndexService.kMaxEmbedDecodePixels. The
      // header alone says so — which is the point: the budget has to bite
      // BEFORE the ~160 MB RGBA allocation that would kill the process.
      await insertImageAttachment(
        'big',
        'n1',
        rawBytes: pngWithDeclaredSize(5000, 4000),
      );
      await insertImageAttachment('ok', 'n1', pixelSide: 900);

      final provider = await embedWith(supportsImages: true);
      expect(
        await figureModality('ok'),
        'image',
        reason: 'an in-budget image is unaffected',
      );
      expect(await figureModality('big'), 'text');
      expect(
        provider.allInputs.map((i) => i.text ?? '').join('\n'),
        contains('big.png'),
        reason: 'the figure still has to be findable, just not by pixels',
      );

      final batchesBefore = provider.batches.length;
      await indexer.backfillAll();
      expect(
        provider.batches.length,
        batchesBefore,
        reason:
            're-offering it would cost a provider call per sweep, '
            'forever, and end in exactly the same text vector',
      );
    });

    test('the decode budget is measured from the HEADER, not by decoding', () {
      // Only 1 pixel of actual data, yet the header says 20 MP: if the budget
      // were enforced after `decodeImage` it could not possibly report this,
      // and on a REAL 20 MP photo the allocation it is guarding against would
      // already have happened (and is a process kill, not an exception).
      expect(
        NoteIndexService.debugDecodedPixelCount(
          pngWithDeclaredSize(5000, 4000),
        ),
        20000000,
      );
      expect(20000000, greaterThan(NoteIndexService.kMaxEmbedDecodePixels));
      // A 12 MP phone photo (4032x3024) stays inside the budget — the whole
      // point of choosing 16 MP rather than the PDF path's 8 MP.
      expect(4032 * 3024, lessThan(NoteIndexService.kMaxEmbedDecodePixels));
      expect(
        NoteIndexService.debugDecodedPixelCount(
          Uint8List.fromList(img.encodePng(img.Image(width: 90, height: 70))),
        ),
        6300,
      );
      expect(
        NoteIndexService.debugDecodedPixelCount(
          Uint8List.fromList('not an image at all'.codeUnits),
        ),
        isNull,
      );
    });

    test('an image-capable provider never gets more than four images in one '
        'batch, however large its maxBatchSize', () async {
      await db.insertNote(buildNote('n1'));
      for (var i = 0; i < 6; i++) {
        await insertImageAttachment('i$i', 'n1', pixelSide: 900);
      }

      // Today's only multimodal preset ships supports_batch: false, so
      // maxBatchSize = 1 is the ONLY thing bounding this. A future preset
      // with both flags set must not accumulate a batch of decoded images.
      final provider = await embedWith(supportsImages: true, maxBatchSize: 50);
      expect(
        provider.allInputs.where((i) => i.isImage),
        hasLength(6),
        reason: 'all six really did embed as images',
      );
      for (final batch in provider.batches) {
        expect(batch.where((i) => i.isImage).length, lessThanOrEqualTo(4));
      }
    });
  });
}
