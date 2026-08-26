// Tests for FigureResolver (plan §4.3, Step 16) — the `synapseresource://
// figure/<figureId>` contract that Steps 14/15 conform to.
//
// The figureId's hash half is the CHUNK ROW's `search_chunks.contentHash`
// (sha256 of text+meta, written by the indexer), never the derived PNG's hash;
// the fixtures below therefore mirror what Step 14 will write into `meta`:
// region identity + derivedAssetPath + figureIndex, and NO renderer-dependent
// value (a pixel hash in meta would make every URI dangle on a pdfium bump).
//
// Real sqlite (sqflite_common_ffi) + real files under a faked app-documents
// dir, mirroring test/search/note_index_service_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/figure_region_extractor.dart';
import 'package:note_synapse/services/search/figure_resolver.dart';
import 'package:note_synapse/utils/file_utils.dart';

String _documentsPath = Directory.systemTemp.path;

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => _documentsPath;
}

/// Minimal pdfrx seam fake: one 612x792pt page that renders deterministic
/// PNG-ish bytes, enough to exercise the regenerate-on-demand path.
class _FakeFigureSource implements PdfFigureSource {
  _FakeFigureSource({this.renderReturnsNull = false, this.renderDelay});

  final bool renderReturnsNull;

  /// Keeps a render in flight long enough for a concurrent resolve to observe
  /// it (the in-flight dedup is what that test is about).
  final Duration? renderDelay;

  int renderCalls = 0;

  @override
  int get pageCount => 5;

  @override
  Future<PdfFigurePage> loadPage(int pageIndex) async =>
      const PdfFigurePage(pageWidthPts: 612, pageHeightPts: 792, items: []);

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
    if (renderDelay != null) await Future<void>.delayed(renderDelay!);
    if (renderReturnsNull) return null;
    return Uint8List.fromList(utf8.encode('PNG:$pageIndex:$x:$y:$width'));
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late Directory docsDir;
  late Directory derivedDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database;
    docsDir = await Directory.systemTemp.createTemp('figure_resolver_test');
    _documentsPath = docsDir.path;
    FileUtils.resetDocumentsPathCache();
    derivedDir = Directory('${docsDir.path}/attachments/derived');
    await derivedDir.create(recursive: true);
    FigureResolver.resetInFlightRegenerations();
  });

  tearDown(() async {
    await db.close();
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
    FileUtils.resetDocumentsPathCache();
    FigureResolver.resetInFlightRegenerations();
  });

  /// An extractor whose PDF seam is [source] and whose derived assets land in
  /// the test's `attachments/derived` dir.
  FigureRegionExtractor extractorFor(
    _FakeFigureSource source, {
    void Function()? onOpen,
  }) => FigureRegionExtractor(
    opener: (path) async {
      onOpen?.call();
      return source;
    },
    derivedDirLoader: () async => derivedDir,
  );

  Future<void> insertNote(String id, {String? title}) async {
    await db.insertNote(
      Note(
        id: id,
        title: title ?? 'Note $id',
        content: 'body',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> insertPdfAttachment(
    String id,
    String noteId, {
    bool createFile = true,
  }) async {
    final relative = 'attachments/$id.pdf';
    if (createFile) {
      final file = File('${docsDir.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsString('%PDF-1.4 backing bytes');
    }
    final raw = await db.database;
    await raw.insert('attachments', {
      'id': id,
      'noteId': noteId,
      'filePath': relative,
      'fileName': '$id.pdf',
      'fileType': 'pdf',
      'isRelativePath': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': 1,
    });
  }

  /// Seeds one `figure` chunk exactly the way Step 14 will, and returns its
  /// figureId. [metaPage] defaults to [page]; passing a different value
  /// reproduces an index inconsistency between the row and its meta.
  Future<String> insertFigureChunk({
    required String noteId,
    required String attachmentId,
    required int page,
    required int figureIndex,
    required String contentHash,
    String caption = 'Figure 1: pipeline',
    String? derivedAssetPath,
    int? metaPage,
    bool includeDerivedAssetPath = true,
    bool includeFigureIndex = true,
    Map<String, dynamic>? metaOverride,
    bool includeRegion = true,
  }) async {
    final effectiveMetaPage = metaPage ?? page;
    final fileName = FigureRegionExtractor.derivedFigureFileName(
      attachmentId,
      effectiveMetaPage,
      figureIndex,
    );
    final meta =
        metaOverride ??
        {
          if (includeRegion) ...{
            'page': effectiveMetaPage,
            'rect': {'l': 72.0, 't': 700.0, 'r': 540.0, 'b': 400.0},
            'confidence': 0.9,
            'source': 'captioned',
          },
          'caption': caption,
          if (includeDerivedAssetPath)
            'derivedAssetPath':
                derivedAssetPath ?? 'attachments/derived/$fileName',
          if (includeFigureIndex) 'figureIndex': figureIndex,
        };
    final seq = (page - 1) * 1000 + figureIndex;
    final chunkKey = '$noteId:figure:$attachmentId:$seq';
    final raw = await db.database;
    await raw.insert('search_chunks', {
      'chunkKey': chunkKey,
      'noteId': noteId,
      'sourceType': 'figure',
      'sourceId': attachmentId,
      'page': page,
      'seq': seq,
      'text': '$caption\n$attachmentId.pdf',
      'meta': jsonEncode(meta),
      'contentHash': contentHash,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    return FigureResolver.buildFigureId(chunkKey, contentHash);
  }

  Future<File> writeDerivedAsset(
    String attachmentId,
    int page,
    int figureIndex, [
    String content = 'derived-png',
  ]) async {
    final file = File(
      '${derivedDir.path}/'
      '${FigureRegionExtractor.derivedFigureFileName(attachmentId, page, figureIndex)}',
    );
    await file.writeAsString(content);
    return file;
  }

  group('figureId', () {
    test('buildFigureId takes the first 12 hex chars of the contentHash', () {
      final id = FigureResolver.buildFigureId(
        'n1:figure:att1:2000',
        'abcdef0123456789abcdef',
      );
      expect(id, 'n1:figure:att1:2000~abcdef012345');
    });

    test('parseFigureId splits on the LAST tilde', () {
      final parsed = FigureResolver.parseFigureId('n1:figure:a~b:2000~abc123');
      expect(parsed!.chunkKey, 'n1:figure:a~b:2000');
      expect(parsed.hashPrefix, 'abc123');
    });

    test('parseFigureId rejects malformed ids', () {
      expect(FigureResolver.parseFigureId('no-tilde'), isNull);
      expect(FigureResolver.parseFigureId('~onlyhash'), isNull);
      expect(FigureResolver.parseFigureId('onlykey~'), isNull);
    });
  });

  group('resolve', () {
    test('happy path returns the asset + provenance', () async {
      await insertNote('n1', title: 'Transformer paper');
      await insertPdfAttachment('att1', 'n1');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 3,
        figureIndex: 0,
        contentHash: 'aaaa1111bbbb2222cccc3333',
        caption: 'Figure 2: attention',
      );
      final asset = await writeDerivedAsset('att1', 3, 0);

      final resolution = await FigureResolver(db).resolve(figureId);

      expect(resolution.isResolved, isTrue);
      final figure = resolution.figure!;
      expect(figure.assetPath, asset.path);
      expect(figure.caption, 'Figure 2: attention');
      expect(figure.noteId, 'n1');
      expect(figure.noteTitle, 'Transformer paper');
      expect(figure.attachmentId, 'att1');
      expect(figure.page, 3);
      expect(figure.regenerated, isFalse);
      // The navigation target travels with every verified resolution.
      expect(resolution.target!.attachmentId, 'att1');
      expect(resolution.target!.page, 3);
    });

    test('resolves through an absolute derivedAssetPath', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      final asset = await writeDerivedAsset('att1', 1, 0, 'abs');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 1,
        figureIndex: 0,
        contentHash: 'ffff0000ffff0000',
        derivedAssetPath: asset.path,
      );

      final resolution = await FigureResolver(db).resolve(figureId);

      expect(resolution.figure!.assetPath, asset.path);
    });

    test('a stale ABSOLUTE derivedAssetPath falls back to the current '
        'container, without re-rendering', () async {
      // iOS rewrites the app-container UUID on every reinstall/restore, so an
      // absolute path stored by an older install names a directory that no
      // longer exists — the file itself is right where it always was.
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      final asset = await writeDerivedAsset('att1', 2, 0, 'still-here');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 2,
        figureIndex: 0,
        contentHash: 'abcd0000abcd0000',
        derivedAssetPath:
            '/var/mobile/Containers/Data/Application/OLD-UUID/Documents/'
            'attachments/derived/att1_p2_f0.png',
      );
      final source = _FakeFigureSource();

      final resolution = await FigureResolver(
        db,
        extractor: extractorFor(source),
      ).resolve(figureId);

      expect(resolution.isResolved, isTrue);
      expect(resolution.figure!.assetPath, asset.path);
      expect(
        source.renderCalls,
        0,
        reason: 'a findable asset must never be re-rasterized',
      );
    });

    test('recovers an absent figureIndex from the derived path', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      // Asset missing on disk: the index is only recoverable from the stored
      // `_f1` suffix, and it decides which sibling gets overwritten.
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 2,
        figureIndex: 1,
        contentHash: 'deadbeefdeadbeef',
        includeFigureIndex: false,
      );
      final source = _FakeFigureSource();

      final resolution = await FigureResolver(
        db,
        extractor: extractorFor(source),
      ).resolve(figureId);

      expect(resolution.isResolved, isTrue);
      expect(resolution.figure!.assetPath, endsWith('att1_p2_f1.png'));
      expect(source.renderCalls, 1);
    });

    test('an unknown figureIndex is never guessed', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      // Neither meta.figureIndex nor a derived path to recover it from.
      // Guessing (e.g. seq % 1000) would make renderRegion overwrite whatever
      // sibling region happens to own that index — it writes unconditionally —
      // and the sibling would then resolve fine while showing the wrong image.
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 2,
        figureIndex: 1,
        contentHash: 'c0ffeec0ffeec0ff',
        includeFigureIndex: false,
        includeDerivedAssetPath: false,
      );
      final sibling = await writeDerivedAsset('att1', 2, 1, 'SIBLING');
      final source = _FakeFigureSource();

      final resolution = await FigureResolver(
        db,
        extractor: extractorFor(source),
      ).resolve(figureId);

      expect(resolution.status, FigureResolutionStatus.assetUnavailable);
      expect(source.renderCalls, 0);
      expect(
        await sibling.readAsString(),
        'SIBLING',
        reason: "a guessed index would have overwritten the sibling's crop",
      );
      expect(
        resolution.target!.attachmentId,
        'att1',
        reason: 'the figure itself is fine — navigation must still work',
      );
    });

    test(
      're-extraction that renumbers regions dangles the OLD figureId',
      () async {
        // The literal §4.2 scenario: chunk A's row is later rewritten to carry
        // what used to be chunk B (new contentHash, new derived asset). Holding
        // A's ORIGINAL figureId must dangle — a resolver that ignored the hash
        // would happily render B's crop under A's caption.
        await insertNote('n1');
        await insertPdfAttachment('att1', 'n1');
        final figureA = await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 4,
          figureIndex: 0,
          contentHash: '1111aaaa1111aaaa',
          caption: 'Figure A',
        );
        await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 4,
          figureIndex: 1,
          contentHash: '2222bbbb2222bbbb',
          caption: 'Figure B',
        );
        final assetA = await writeDerivedAsset('att1', 4, 0, 'A');
        final assetB = await writeDerivedAsset('att1', 4, 1, 'B');
        expect((await FigureResolver(db).resolve(figureA)).isResolved, isTrue);

        // Re-extraction renumbers: row A now IS the region B used to be.
        final chunkKeyA = FigureResolver.parseFigureId(figureA)!.chunkKey;
        final raw = await db.database;
        await raw.update(
          'search_chunks',
          {
            'contentHash': '2222bbbb2222bbbb',
            'meta': jsonEncode({
              'page': 4,
              'rect': {'l': 72.0, 't': 700.0, 'r': 540.0, 'b': 400.0},
              'confidence': 0.9,
              'source': 'captioned',
              'caption': 'Figure B',
              'derivedAssetPath': 'attachments/derived/att1_p4_f1.png',
              'figureIndex': 1,
            }),
          },
          where: 'chunkKey = ?',
          whereArgs: [chunkKeyA],
        );

        final resolution = await FigureResolver(db).resolve(figureA);

        expect(resolution.status, FigureResolutionStatus.staleFigure);
        expect(resolution.isDangling, isTrue);
        expect(resolution.isMissingFigure, isTrue);
        expect(
          resolution.figure,
          isNull,
          reason: 'a stale figureId must never resolve to another figure',
        );
        expect(
          resolution.target,
          isNull,
          reason: 'a stale id must not offer navigation either',
        );
        expect(File(assetA.path).existsSync(), isTrue);
        expect(File(assetB.path).existsSync(), isTrue);
      },
    );

    test('hash mismatch dangles and never returns the other figure', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      final figureA = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 4,
        figureIndex: 0,
        contentHash: '1111aaaa1111aaaa',
        caption: 'Figure A',
      );
      await writeDerivedAsset('att1', 4, 0, 'A');

      final staleId =
          '${FigureResolver.parseFigureId(figureA)!.chunkKey}~9999cccc9999';
      final resolution = await FigureResolver(db).resolve(staleId);

      expect(resolution.status, FigureResolutionStatus.staleFigure);
      expect(resolution.figure, isNull);
    });

    test('hash verification is case-insensitive hex', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 1,
        figureIndex: 0,
        contentHash: 'abcdef0123456789',
        caption: 'Figure 1',
      );
      await writeDerivedAsset('att1', 1, 0);

      final upperCased = FigureResolver.buildFigureId(
        'n1:figure:att1:0',
        'ABCDEF012345',
      );
      final resolution = await FigureResolver(db).resolve(upperCased);

      expect(resolution.isResolved, isTrue);
    });

    test('missing chunk dangles as unknownFigure', () async {
      await insertNote('n1');
      final resolution = await FigureResolver(
        db,
      ).resolve('n1:figure:att1:0~abcdef012345');

      expect(resolution.status, FigureResolutionStatus.unknownFigure);
      expect(resolution.figure, isNull);
      expect(resolution.target, isNull);
    });

    test('malformed figureId dangles as unknownFigure', () async {
      final resolution = await FigureResolver(db).resolve('not-a-figure-id');
      expect(resolution.status, FigureResolutionStatus.unknownFigure);
    });

    test('a non-figure chunk with the same key is not resolved', () async {
      await insertNote('n1');
      final raw = await db.database;
      await raw.insert('search_chunks', {
        'chunkKey': 'n1:attachment_text:att1:0',
        'noteId': 'n1',
        'sourceType': 'attachment_text',
        'sourceId': 'att1',
        'page': 1,
        'seq': 0,
        'text': 'page text',
        'contentHash': 'cafebabecafebabe',
        'updatedAt': 0,
      });

      final resolution = await FigureResolver(
        db,
      ).resolve('n1:attachment_text:att1:0~cafebabecafe');

      expect(resolution.status, FigureResolutionStatus.unknownFigure);
    });

    test('deleted owning note dangles as unknownFigure', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 1,
        figureIndex: 0,
        contentHash: 'abc123abc123abc1',
      );
      await writeDerivedAsset('att1', 1, 0);
      final raw = await db.database;
      // Tombstone write: `notes` is hard-delete-guarded (M1.13), so a
      // deleted owning note is a tombstoned row, not a missing one.
      await raw.update(
        'notes',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: ['n1'],
      );

      final resolution = await FigureResolver(db).resolve(figureId);

      expect(resolution.status, FigureResolutionStatus.unknownFigure);
    });

    test('missing asset with no attachment row is unregenerable', () async {
      await insertNote('n1');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'gone',
        page: 1,
        figureIndex: 0,
        contentHash: '0101010101010101',
      );

      final resolution = await FigureResolver(db).resolve(figureId);

      expect(resolution.status, FigureResolutionStatus.assetUnavailable);
      expect(resolution.isDangling, isTrue);
      expect(
        resolution.isMissingFigure,
        isFalse,
        reason: 'the figure still exists; only its regenerable asset is gone',
      );
    });

    test('missing asset with a deleted source PDF is unregenerable, but keeps '
        'its navigation target', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1', createFile: false);
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 6,
        figureIndex: 0,
        contentHash: '0202020202020202',
      );

      final resolution = await FigureResolver(db).resolve(figureId);

      expect(resolution.status, FigureResolutionStatus.assetUnavailable);
      expect(resolution.target!.attachmentId, 'att1');
      expect(resolution.target!.page, 6);
    });

    test('missing asset without region meta is unregenerable', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 1,
        figureIndex: 0,
        contentHash: '0303030303030303',
        includeRegion: false,
      );

      final resolution = await FigureResolver(
        db,
        extractor: extractorFor(_FakeFigureSource()),
      ).resolve(figureId);

      expect(resolution.status, FigureResolutionStatus.assetUnavailable);
    });

    test(
      'missing asset is regenerated on demand from the stored region',
      () async {
        await insertNote('n1', title: 'Scanned report');
        await insertPdfAttachment('att1', 'n1');
        final figureId = await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 3,
          figureIndex: 0,
          contentHash: '0404040404040404',
          caption: 'Figure 7: layout',
        );
        final source = _FakeFigureSource();

        final resolution = await FigureResolver(
          db,
          extractor: extractorFor(source),
        ).resolve(figureId);

        expect(resolution.isResolved, isTrue);
        expect(source.renderCalls, 1);
        final figure = resolution.figure!;
        expect(figure.regenerated, isTrue);
        expect(figure.assetPath, '${derivedDir.path}/att1_p3_f0.png');
        expect(File(figure.assetPath).existsSync(), isTrue);
        expect(figure.caption, 'Figure 7: layout');
        expect(figure.page, 3);
        // Regeneration is a read-only side effect: the chunk row is untouched.
        final raw = await db.database;
        final rows = await raw.query('search_chunks');
        expect(rows.single['contentHash'], '0404040404040404');
        // Nothing is left behind in the in-flight table.
        expect(FigureResolver.inFlightRegenerationCount, 0);
      },
    );

    test('a failed re-render is unregenerable, not a wrong figure', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 1,
        figureIndex: 0,
        contentHash: '0505050505050505',
      );

      final resolution = await FigureResolver(
        db,
        extractor: extractorFor(_FakeFigureSource(renderReturnsNull: true)),
      ).resolve(figureId);

      expect(resolution.status, FigureResolutionStatus.assetUnavailable);
      expect(resolution.figure, isNull);
    });

    test(
      'concurrent resolutions of the same figure share ONE regeneration',
      () async {
        // Two widget states (note preview + open note, or two chat bubbles) can
        // resolve the same figure at once. Without process-global dedup both
        // open pdfium and truncate-write the same path, so a reader can decode a
        // half-written PNG.
        await insertNote('n1');
        await insertPdfAttachment('att1', 'n1');
        final figureId = await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 3,
          figureIndex: 0,
          contentHash: '0606060606060606',
        );
        final source = _FakeFigureSource(
          renderDelay: const Duration(milliseconds: 60),
        );
        var opens = 0;
        // Separate resolver instances on purpose: the dedup must NOT live on the
        // instance (one is constructed per call).
        final a = FigureResolver(
          db,
          extractor: extractorFor(source, onOpen: () => opens++),
        );
        final b = FigureResolver(
          db,
          extractor: extractorFor(source, onOpen: () => opens++),
        );

        final results = await Future.wait([
          a.resolve(figureId),
          b.resolve(figureId),
        ]);

        expect(results.every((r) => r.isResolved), isTrue);
        expect(source.renderCalls, 1, reason: 'one render, shared by both');
        expect(opens, 1, reason: 'pdfium must be opened once');
        expect(
          results.map((r) => r.figure!.assetPath).toSet().single,
          '${derivedDir.path}/att1_p3_f0.png',
        );
        expect(FigureResolver.inFlightRegenerationCount, 0);
      },
    );

    test(
      'a row/meta page divergence probes the page renderRegion would write',
      () async {
        // The old probe used `row.page ?? meta.page` while renderRegion names its
        // output from meta's page: whenever they disagreed the probe missed
        // forever and every single resolve re-rasterized the PDF.
        await insertNote('n1');
        await insertPdfAttachment('att1', 'n1');
        final figureId = await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 3,
          metaPage: 4,
          figureIndex: 0,
          contentHash: '0707070707070707',
          includeDerivedAssetPath: false,
        );
        final asset = await writeDerivedAsset('att1', 4, 0, 'page-4 crop');
        final source = _FakeFigureSource();

        final resolution = await FigureResolver(
          db,
          extractor: extractorFor(source),
        ).resolve(figureId);

        expect(resolution.isResolved, isTrue);
        expect(resolution.figure!.assetPath, asset.path);
        expect(
          source.renderCalls,
          0,
          reason: 'the existence check must target what a render would write',
        );
        expect(resolution.figure!.page, 4, reason: 'meta owns the region');
      },
    );
  });

  group('resolveTarget', () {
    test('returns the navigation target without touching the asset', () async {
      await insertNote('n1', title: 'Transformer paper');
      await insertPdfAttachment('att1', 'n1');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 7,
        figureIndex: 0,
        contentHash: '0808080808080808',
        caption: 'Figure 9: results',
      );
      final source = _FakeFigureSource();

      final resolution = await FigureResolver(
        db,
        extractor: extractorFor(source),
      ).resolveTarget(figureId);

      expect(resolution.isResolved, isTrue);
      final target = resolution.target!;
      expect(target.attachmentId, 'att1');
      expect(target.page, 7);
      expect(target.noteId, 'n1');
      expect(target.noteTitle, 'Transformer paper');
      expect(target.caption, 'Figure 9: results');
      expect(
        source.renderCalls,
        0,
        reason: 'navigating must never rasterize a PDF page',
      );
      expect(
        File('${derivedDir.path}/att1_p7_f0.png').existsSync(),
        isFalse,
        reason: 'no asset is written by a metadata-only lookup',
      );
    });

    test('still resolves when the asset is unavailable — the normal state '
        'after a restore', () async {
      // Derived assets are excluded from export/backup, so after a restore the
      // crop is gone while note + chunk + PDF are all intact. Tapping the
      // figure must still open the source.
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1', createFile: false);
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 5,
        figureIndex: 2,
        contentHash: '0909090909090909',
      );

      final resolution = await FigureResolver(db).resolveTarget(figureId);

      expect(resolution.isResolved, isTrue);
      expect(resolution.target!.attachmentId, 'att1');
      expect(resolution.target!.page, 5);
    });

    test('stale and unknown ids have no target', () async {
      await insertNote('n1');
      await insertPdfAttachment('att1', 'n1');
      final figureId = await insertFigureChunk(
        noteId: 'n1',
        attachmentId: 'att1',
        page: 1,
        figureIndex: 0,
        contentHash: '1010101010101010',
      );
      final chunkKey = FigureResolver.parseFigureId(figureId)!.chunkKey;

      final stale = await FigureResolver(
        db,
      ).resolveTarget('$chunkKey~ffffffff');
      expect(stale.status, FigureResolutionStatus.staleFigure);
      expect(stale.target, isNull);

      final unknown = await FigureResolver(
        db,
      ).resolveTarget('n1:figure:att1:999~abcdef012345');
      expect(unknown.status, FigureResolutionStatus.unknownFigure);
      expect(unknown.target, isNull);

      final malformed = await FigureResolver(db).resolveTarget('nope');
      expect(malformed.status, FigureResolutionStatus.unknownFigure);
    });
  });
}
