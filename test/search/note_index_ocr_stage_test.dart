// Integration tests for NoteIndexService's 'ocr' stage (plan §3, Step 12):
// end-to-end chunk writes with meta persistence, merge against the pdf_text
// stage's output, state hashing/resume, battery deferral, purge-on-toggle,
// stage-named progress, and ensureBackfilled resuming an interrupted pass.
// Real sqlite via sqflite_common_ffi; pdfrx/ML Kit/battery seamed with fakes.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/attachment_ocr_extractor.dart';
import 'package:note_synapse/services/search/attachment_text_extractor.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search/search_service.dart';

import 'ocr_test_stubs.dart';

/// Text-layer fake for the pdf_text stage (mirrors note_index_service_test).
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late DataChangeNotifier notifier;
  late NoteIndexService indexer;
  late Directory fileDir;

  /// Text-layer pages served to the pdf_text stage, by absolute path.
  final textPagesByPath = <String, List<String>>{};

  /// OCR block texts per rendered page, keyed '<path>|<0-based page>'.
  final ocrBlocksByKey = <String, List<String>>{};

  /// OCR blocks for raster images, keyed by the image file's CONTENT.
  final imageBlocksByContent = <String, List<String>>{};

  var ocrOpenCalls = 0;
  late FakeOcrEngine engine;
  var battery = const BatteryStatus(level: 100, charging: true);
  var script = OcrScript.latin;

  /// The GLOBAL OCR switch (SearchSettingsService.getOcrEnabled), read
  /// through the extractor's seam — SharedPreferences has no platform
  /// channel under flutter_tester.
  var globalOcrEnabled = true;

  /// Rendered-page contents whose recognition throws (engine failure).
  final ocrThrowContents = <String>{};

  /// Called on every recognizeFile with the rendered content (battery-drain
  /// mid-pass tests flip [battery] from here).
  void Function(String content)? onRecognize;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  NoteIndexService buildIndexer() {
    engine = FakeOcrEngine(
      blocksFor: (content, s) {
        onRecognize?.call(content);
        if (ocrThrowContents.contains(content)) {
          throw StateError('engine failure on $content');
        }
        final texts =
            ocrBlocksByKey[content] ??
            imageBlocksByContent[content] ??
            const [];
        return [
          for (var i = 0; i < texts.length; i++)
            OcrTextBlock(
              text: texts[i],
              bounds: ui.Rect.fromLTWH(10, 20.0 + i * 40, 200, 30),
            ),
        ];
      },
    );
    return NoteIndexService(
      db,
      changeNotifier: notifier,
      debounceDelay: const Duration(milliseconds: 50),
      extractor: AttachmentTextExtractor(
        db,
        opener: (path) async =>
            _FakeTextSource(textPagesByPath[path] ?? const []),
        pageCapLoader: () async => 100,
      ),
      ocrExtractor: AttachmentOcrExtractor(
        db,
        opener: (path) async {
          ocrOpenCalls++;
          return FakeOcrRenderSource(
            textPagesByPath[path]?.length ?? 0,
            contentFor: (i) => '$path|$i',
          );
        },
        engine: engine,
        batteryLoader: () async => battery,
        scriptLoader: () async => script,
        pageCapLoader: () async => 100,
        ocrEnabledLoader: () async => globalOcrEnabled,
        tempDirLoader: () async => fileDir.path,
      ),
      figureExtractor: stubFigureExtractor(),
    );
  }

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database;
    notifier = DataChangeNotifier();
    fileDir = await Directory.systemTemp.createTemp('ocr_stage');
    textPagesByPath.clear();
    ocrBlocksByKey.clear();
    imageBlocksByContent.clear();
    ocrThrowContents.clear();
    onRecognize = null;
    ocrOpenCalls = 0;
    battery = const BatteryStatus(level: 100, charging: true);
    script = OcrScript.latin;
    globalOcrEnabled = true;
    indexer = buildIndexer();
  });

  tearDown(() async {
    indexer.dispose();
    await db.close();
    await fileDir.delete(recursive: true);
  });

  Note buildNote(String id, {String content = 'note body'}) => Note(
    id: id,
    title: 'Note $id',
    content: content,
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  /// Raw attachments insert (no hook — tests drive reindex explicitly) with
  /// a real backing file. [textPages] feeds the pdf_text fake AND sets the
  /// OCR page count; [ocrPageBlocks] lists block texts per 0-based page.
  Future<String> insertPdfAttachment(
    String id,
    String noteId, {
    required List<String> textPages,
    Map<int, List<String>> ocrPageBlocks = const {},
    Map<String, dynamic>? metadata,
  }) async {
    final file = File('${fileDir.path}/$id.pdf');
    await file.writeAsString('backing bytes for $id');
    textPagesByPath[file.path] = textPages;
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
      'includeInAIContext': 1,
      'metadata': metadata == null ? null : jsonEncode(metadata),
    });
    return file.path;
  }

  Future<void> insertImageAttachment(
    String id,
    String noteId, {
    required List<String> blocks,
  }) async {
    final file = File('${fileDir.path}/$id.png');
    await file.writeAsString('IMG-CONTENT-$id');
    imageBlocksByContent['IMG-CONTENT-$id'] = blocks;
    final raw = await db.database;
    await raw.insert('attachments', {
      'id': id,
      'noteId': noteId,
      'filePath': file.path,
      'fileName': '$id.png',
      'fileType': 'png',
      'isRelativePath': 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': 1,
    });
  }

  Future<List<Map<String, dynamic>>> ocrChunks(String attId) async {
    final raw = await db.database;
    return raw.query(
      'search_chunks',
      where: "sourceType = 'attachment_ocr' AND sourceId = ?",
      whereArgs: [attId],
      orderBy: 'seq',
    );
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

  Future<Map<String, dynamic>?> globalStageState(String stage) async {
    final raw = await db.database;
    final rows = await raw.query(
      'search_index_state',
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [stage],
    );
    return rows.isEmpty ? null : rows.first;
  }

  test('end-to-end: novel OCR text searchable, text-layer text deduped, '
      'meta persisted', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['The quick brown fox jumps over the lazy dog every day.'],
      ocrPageBlocks: {
        0: [
          'quick brown fox jumps over', // covered by the text layer
          'bioluminescent axolotl diagram', // novel (inside a figure)
        ],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();

    final chunks = await ocrChunks('a1');
    expect(chunks, hasLength(1));
    expect(chunks.single['page'], 1);
    expect(chunks.single['text'], 'bioluminescent axolotl diagram');
    expect(chunks.single['chunkKey'], 'n1:attachment_ocr:a1:0');

    final meta =
        jsonDecode(chunks.single['meta'] as String) as Map<String, dynamic>;
    expect(meta['renderScale'], 2.0);
    expect(meta['space'], 'pdf');
    expect(
      meta['blockBounds'],
      hasLength(1),
      reason: 'suppressed blocks leave no bounds',
    );

    expect((await ocrState('a1'))!['status'], 'done');
    expect((await globalStageState('ocr'))!['status'], 'done');

    final search = SearchService(
      db,
      indexer,
      notesProvider: () => db.getAllNotes(),
    );
    final response = await search.searchLexical('axolotl');
    expect(response.usedSubstringFallback, isFalse);
    final result = response.results.single;
    expect(result.noteId, 'n1');
    expect(result.best.sourceType, 'attachment_ocr');
    expect(result.page, 1);

    // The deduped text still matches via its attachment_text chunk only.
    final dupe = await search.searchLexical('quick brown fox');
    expect(dupe.results.single.best.sourceType, 'attachment_text');
  });

  test('raster image attachment produces page-less ocr chunks', () async {
    await db.insertNote(buildNote('n2'));
    await insertImageAttachment(
      'i1',
      'n2',
      blocks: ['street sign says welcome'],
    );
    await indexer.reindexNote('n2');
    await indexer.flushPending();

    final chunks = await ocrChunks('i1');
    expect(chunks, hasLength(1));
    expect(chunks.single['page'], isNull);
    expect(chunks.single['text'], 'street sign says welcome');
    final meta =
        jsonDecode(chunks.single['meta'] as String) as Map<String, dynamic>;
    expect(meta['space'], 'image');
    expect(meta['renderScale'], 1.0);
    expect((await ocrState('i1'))!['status'], 'done');
  });

  test('unchanged file/policy/script skip re-runs on sweeps; script change '
      're-runs', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();
    expect(await ocrChunks('a1'), hasLength(1));
    final opensAfterFirst = ocrOpenCalls;

    await indexer.backfillAll();
    expect(
      ocrOpenCalls,
      opensAfterFirst,
      reason: 'sweep must be stat-only for unchanged attachments',
    );

    // Script switch is part of the state hash: the attachment re-runs.
    script = OcrScript.chinese;
    await indexer.backfillAll();
    expect(
      ocrOpenCalls,
      greaterThan(opensAfterFirst),
      reason: 'a script change must re-run OCR',
    );
    expect(engine.calls.last.$2, OcrScript.chinese);
  });

  test(
    'ocr:false purges chunks and records a skip; re-enabling re-extracts',
    () async {
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment(
        'a1',
        'n1',
        textPages: ['page text'],
        ocrPageBlocks: {
          0: ['novel ocr text'],
        },
      );
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(await ocrChunks('a1'), hasLength(1));

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
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(
        await ocrChunks('a1'),
        isEmpty,
        reason: 'purge-on-toggle (plan §1.3)',
      );
      expect((await ocrState('a1'))!['status'], 'skipped');

      await raw.update(
        'attachments',
        {'metadata': null},
        where: 'id = ?',
        whereArgs: ['a1'],
      );
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(
        await ocrChunks('a1'),
        hasLength(1),
        reason: 'the ocr= component of the state hash forces the re-run',
      );
      expect((await ocrState('a1'))!['status'], 'done');
    },
  );

  test('attachment deletion prunes its ocr chunks and state', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    await indexer.reindexNote('n1');
    await indexer.flushPending();
    expect(await ocrChunks('a1'), hasLength(1));

    final raw = await db.database;
    // Tombstone write: `attachments` is hard-delete-guarded (M1.13), so
    // this is how an attachment actually goes away.
    await raw.update(
      'attachments',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: ['a1'],
    );
    await indexer.reindexNote('n1');
    await indexer.flushPending();
    expect(await ocrChunks('a1'), isEmpty);
    expect(await ocrState('a1'), isNull);
  });

  test('battery deferral writes no state, withholds the global flag, and '
      'retries once charging', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    battery = const BatteryStatus(level: 12, charging: false);
    await indexer.flushPending();
    await indexer.backfillAll();

    expect(
      (await globalStageState('chunks'))!['status'],
      'done',
      reason: 'battery only gates OCR, never lexical completeness',
    );
    expect((await globalStageState('pdf_text'))!['status'], 'done');
    expect(await ocrChunks('a1'), isEmpty);
    expect(
      await ocrState('a1'),
      isNull,
      reason: 'deferrals are transient — no state row',
    );
    expect(
      await globalStageState('ocr'),
      isNull,
      reason: 'the ocr flag must stay unset so the sweep retries',
    );

    battery = const BatteryStatus(level: 12, charging: true);
    await indexer.ensureBackfilled();
    expect(await ocrChunks('a1'), hasLength(1));
    expect((await ocrState('a1'))!['status'], 'done');
    expect((await globalStageState('ocr'))!['status'], 'done');
  });

  test('ensureBackfilled resumes an interrupted ocr pass', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();
    expect((await globalStageState('ocr'))!['status'], 'done');

    // Simulate an app killed mid-ocr-pass: chunks + pdf_text flags stand,
    // the ocr state rows never landed (chunk + state writes share one
    // transaction, so an interrupted attachment has neither).
    final raw = await db.database;
    await raw.delete('search_index_state', where: "stage = 'ocr'");
    expect(await globalStageState('ocr'), isNull);
    final opensBefore = ocrOpenCalls;

    await indexer.ensureBackfilled();
    expect(
      ocrOpenCalls,
      greaterThan(opensBefore),
      reason:
          'ensureBackfilled must drive the ocr pass when its global '
          'flag is absent, even with chunks and pdf_text done',
    );
    expect(await ocrChunks('a1'), hasLength(1));
    expect((await ocrState('a1'))!['status'], 'done');
    expect((await globalStageState('ocr'))!['status'], 'done');
  });

  test('progress reports the ocr stage with page counts', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['p1 text', 'p2 text', 'p3 text'],
      ocrPageBlocks: {
        0: ['novel one'],
        1: ['novel two'],
        2: ['novel three'],
      },
    );
    // Settle every stage, then reset the ocr state so the observed backfill
    // has real page work to report (an all-current sweep publishes nothing).
    await indexer.flushPending();
    await indexer.backfillAll();
    final raw = await db.database;
    await raw.delete('search_index_state', where: "stage = 'ocr'");

    final seen = <IndexProgress>[];
    void listener() => seen.add(indexer.progress.value);
    indexer.progress.addListener(listener);
    addTearDown(() => indexer.progress.removeListener(listener));

    await indexer.backfillAll();

    final ocrUpdates = seen.where((p) => p.stage == 'ocr').toList();
    expect(
      ocrUpdates,
      isNotEmpty,
      reason: 'the ocr pass must publish stage-named progress',
    );
    expect(ocrUpdates.every((p) => p.unit == 'pages'), isTrue);
    expect(ocrUpdates.last.total, 3);
    expect(ocrUpdates.last.done, 3);

    final finalProgress = indexer.progress.value;
    expect(finalProgress.running, isFalse);
    expect(finalProgress.stage, 'ocr');
    expect(finalProgress.unit, 'pages');
    expect(finalProgress.toString(), contains('pages'));
  });

  test('excluded note purges ocr chunks; un-excluding re-extracts', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    await indexer.reindexNote('n1');
    await indexer.flushPending();
    expect(await ocrChunks('a1'), hasLength(1));

    await indexer.setNoteSearchExclusion('n1', true);
    await indexer.flushPending();
    expect(await ocrChunks('a1'), isEmpty);
    expect((await ocrState('a1'))!['status'], 'skipped');

    await indexer.setNoteSearchExclusion('n1', false);
    await indexer.flushPending();
    expect(await ocrChunks('a1'), hasLength(1));
    expect((await ocrState('a1'))!['status'], 'done');
  });

  test('the global OCR switch off purges existing ocr chunks; back on '
      're-extracts them', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    await insertImageAttachment('i1', 'n1', blocks: ['sign text']);
    await indexer.flushPending();
    await indexer.backfillAll();
    expect(await ocrChunks('a1'), hasLength(1));
    expect(await ocrChunks('i1'), hasLength(1));

    // Turning the setting off must reach the index through a plain sweep —
    // the settings screen only flips the pref and kicks ensureBackfilled.
    globalOcrEnabled = false;
    await indexer.ensureBackfilled();

    expect(await ocrChunks('a1'), isEmpty, reason: 'purge-on-toggle (§1.3)');
    expect(await ocrChunks('i1'), isEmpty);
    expect((await ocrState('a1'))!['status'], 'skipped');
    expect((await ocrState('i1'))!['status'], 'skipped');
    // The recognized text is gone from search, not merely hidden.
    final search = SearchService(
      db,
      indexer,
      notesProvider: () => db.getAllNotes(),
    );
    expect((await search.searchLexical('novel ocr text')).results, isEmpty);

    // No further OCR work happens while it stays off.
    final opensAfterPurge = ocrOpenCalls;
    final callsAfterPurge = engine.calls.length;
    await indexer.ensureBackfilled();
    expect(ocrOpenCalls, opensAfterPurge);
    expect(engine.calls, hasLength(callsAfterPurge));

    // Back on: the skipped state must NOT read as current, or those
    // attachments would never be OCRed again short of a forced rebuild.
    globalOcrEnabled = true;
    await indexer.ensureBackfilled();
    expect(await ocrChunks('a1'), hasLength(1));
    expect(await ocrChunks('i1'), hasLength(1));
    expect((await ocrState('a1'))!['status'], 'done');
    expect((await ocrState('i1'))!['status'], 'done');
    expect(
      (await search.searchLexical('novel ocr text')).results,
      hasLength(1),
    );
  });

  test('a script change re-runs the stage through ensureBackfilled', () async {
    // The settings screen kicks ensureBackfilled after changing the script;
    // the completed-stage short-circuit would otherwise swallow it (the
    // per-attachment hashes are never even compared).
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();
    final opensAfterFirst = ocrOpenCalls;
    await indexer.ensureBackfilled();
    expect(ocrOpenCalls, opensAfterFirst, reason: 'nothing changed');

    script = OcrScript.chinese;
    await indexer.ensureBackfilled();
    expect(ocrOpenCalls, greaterThan(opensAfterFirst));
    expect(engine.calls.last.$2, OcrScript.chinese);
  });

  test('the global OCR switch off purges even on a low battery', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();
    expect(await ocrChunks('a1'), hasLength(1));

    // A battery deferral writes no state at all, so an off-switch purge that
    // waited for a charger would leave the chunks searchable indefinitely.
    globalOcrEnabled = false;
    battery = const BatteryStatus(level: 5, charging: false);
    await indexer.ensureBackfilled();

    expect(await ocrChunks('a1'), isEmpty);
    expect((await ocrState('a1'))!['status'], 'skipped');
  });

  test('per-note reindex honors the global OCR switch', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['page text'],
      ocrPageBlocks: {
        0: ['novel ocr text'],
      },
    );
    globalOcrEnabled = false;
    await indexer.reindexNote('n1');
    await indexer.flushPending();

    expect(await ocrChunks('a1'), isEmpty);
    expect((await ocrState('a1'))!['status'], 'skipped');
    expect(ocrOpenCalls, 0, reason: 'no rendering while OCR is off');
    expect(engine.calls, isEmpty);
  });

  test("text:'on' opt-in re-runs OCR for a PDF both stages had skipped as "
      'too large', () async {
    await db.insertNote(buildNote('n1'));
    // 150 pages against the 100-page cap: both stages settle
    // skipped_too_large under text:'auto'.
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: List.generate(150, (i) => 'text of page ${i + 1}'),
      ocrPageBlocks: {
        0: ['scanned figure label'],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();
    expect((await ocrState('a1'))!['status'], 'skipped_too_large');
    expect(await ocrChunks('a1'), isEmpty);

    // Attach-time opt-in: text:'on' bypasses the cap for BOTH stages. The
    // ocr state hash must notice the policy flip — its stored too-large
    // state is no longer current.
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
    await indexer.reindexNote('n1');
    await indexer.flushPending();

    expect(
      (await ocrState('a1'))!['status'],
      'done',
      reason:
          "text:'on' lifts the cap for the ocr stage too — the stored "
          'too-large state must not be deemed current',
    );
    final chunks = await ocrChunks('a1');
    expect(chunks, hasLength(1));
    expect(chunks.single['text'], 'scanned figure label');
  });

  test("text policy flip auto→off re-runs OCR so suppressed text resurfaces; "
      'off→on re-merges without duplicates', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['The quick brown fox jumps over the lazy dog every day.'],
      ocrPageBlocks: {
        0: [
          'quick brown fox jumps over', // covered by the text layer
          'bioluminescent axolotl diagram', // novel
        ],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();
    var chunks = await ocrChunks('a1');
    expect(chunks, hasLength(1));
    expect(chunks.single['text'], 'bioluminescent axolotl diagram');

    // text:'off' purges the attachment_text layer. The OCR chunks were
    // computed WITH suppression against that layer, so without a re-run the
    // suppressed text would be in NEITHER layer.
    final raw = await db.database;
    Future<void> setTextPolicy(String policy) => raw.update(
      'attachments',
      {
        'metadata': jsonEncode({
          'searchIndex': {'text': policy},
        }),
      },
      where: 'id = ?',
      whereArgs: ['a1'],
    );
    Future<List<Map<String, dynamic>>> textChunks() => raw.query(
      'search_chunks',
      where: "sourceType = 'attachment_text' AND sourceId = 'a1'",
    );

    await setTextPolicy('off');
    await indexer.reindexNote('n1');
    await indexer.flushPending();
    expect(await textChunks(), isEmpty, reason: 'purge-on-policy');
    chunks = await ocrChunks('a1');
    final ocrText = [for (final c in chunks) c['text'] as String].join('\n');
    expect(
      ocrText,
      contains('quick brown fox jumps over'),
      reason:
          'the text policy is part of the ocr state hash: the flip '
          're-runs OCR against the (now empty) text layer, so the '
          'previously suppressed text lands in the OCR layer',
    );
    expect(ocrText, contains('bioluminescent axolotl diagram'));

    // Reverse flip: the pdf_text stage re-extracts first (same serialized
    // queue, queued ahead of ocr), then OCR re-merges — the covered block
    // must be re-suppressed, not duplicated across layers.
    await setTextPolicy('on');
    await indexer.reindexNote('n1');
    await indexer.flushPending();
    expect(await textChunks(), isNotEmpty);
    chunks = await ocrChunks('a1');
    expect(
      chunks,
      hasLength(1),
      reason: 'text-layer-covered OCR text must not be duplicated',
    );
    expect(chunks.single['text'], 'bioluminescent axolotl diagram');
  });

  test('mid-pass battery deferral stops the backfill loop and does not '
      'advance progress for unrecognized pages', () async {
    await db.insertNote(buildNote('n1'));
    final a1Path = await insertPdfAttachment(
      'a1',
      'n1',
      textPages: ['p1'],
      ocrPageBlocks: {
        0: ['novel one'],
      },
    );
    await insertPdfAttachment(
      'a2',
      'n1',
      textPages: ['p1', 'p2'],
      ocrPageBlocks: {
        0: ['novel two'],
      },
    );
    await insertPdfAttachment(
      'a3',
      'n1',
      textPages: ['p1'],
      ocrPageBlocks: {
        0: ['novel three'],
      },
    );
    // Settle every stage, then reset the ocr states so the observed
    // backfill has all three attachments pending.
    await indexer.flushPending();
    await indexer.backfillAll();
    final raw = await db.database;
    await raw.delete('search_index_state', where: "stage = 'ocr'");

    // Battery dies right after a1's page is recognized: a2 must defer and
    // the loop must stop — battery state is global, so a3 would defer too.
    onRecognize = (_) {
      battery = const BatteryStatus(level: 10, charging: false);
    };
    final callsBefore = engine.calls.length;
    final seen = <IndexProgress>[];
    void listener() => seen.add(indexer.progress.value);
    indexer.progress.addListener(listener);
    addTearDown(() => indexer.progress.removeListener(listener));

    await indexer.backfillAll();

    expect((await ocrState('a1'))!['status'], 'done');
    expect(
      await ocrState('a2'),
      isNull,
      reason: 'deferrals are transient — no state row',
    );
    expect(
      await ocrState('a3'),
      isNull,
      reason: 'the loop must stop at the first deferral, not try a3',
    );
    expect(
      await globalStageState('ocr'),
      isNull,
      reason: 'a deferred pass must withhold the global ocr flag',
    );

    final newCalls = engine.calls.sublist(callsBefore);
    expect(
      newCalls,
      hasLength(1),
      reason: 'only a1 may be recognized; a2 defers, a3 is never tried',
    );
    expect(newCalls.single.$1, '$a1Path|0');

    final ocrUpdates = seen.where((p) => p.stage == 'ocr').toList();
    expect(ocrUpdates, isNotEmpty);
    expect(ocrUpdates.last.total, 4, reason: '1 + 2 + 1 pages pending');
    expect(
      ocrUpdates.last.done,
      1,
      reason:
          'deferred attachments must not advance page progress — '
          'the bar must never reach N/N when nothing was recognized',
    );
    // The FINAL published progress belongs to the FIGURES stage, which runs
    // after ocr and did work this round: the figures state hash folds in each
    // attachment's stored ocr state (NoteIndexService._ocrStateComponent), and
    // this test deleted every ocr row above, so all three attachments are
    // legitimately stale for figures. The ocr-stage claim under test is the
    // one asserted above — a deferred pass never advances its own page count.
    final finalProgress = indexer.progress.value;
    expect(finalProgress.running, isFalse);
    expect(finalProgress.stage, 'figures');
  });

  test('over-cap PDFs count one settle step, not their page count, in the '
      'ocr progress total', () async {
    await db.insertNote(buildNote('n1'));
    await insertPdfAttachment(
      'big',
      'n1',
      textPages: List.generate(150, (i) => 'page ${i + 1}'),
    );
    await insertPdfAttachment(
      'small',
      'n1',
      textPages: ['p1', 'p2'],
      ocrPageBlocks: {
        0: ['novel text'],
      },
    );
    await indexer.flushPending();
    await indexer.backfillAll();
    final raw = await db.database;
    await raw.delete('search_index_state', where: "stage = 'ocr'");

    final seen = <IndexProgress>[];
    void listener() => seen.add(indexer.progress.value);
    indexer.progress.addListener(listener);
    addTearDown(() => indexer.progress.removeListener(listener));

    await indexer.backfillAll();

    expect((await ocrState('big'))!['status'], 'skipped_too_large');
    expect((await ocrState('small'))!['status'], 'done');
    final ocrUpdates = seen.where((p) => p.stage == 'ocr').toList();
    expect(ocrUpdates, isNotEmpty);
    expect(
      ocrUpdates.last.total,
      3,
      reason:
          'the 150-page over-cap PDF settles skipped_too_large with '
          'one state write — it must count 1 page, not 150',
    );
    expect(ocrUpdates.last.done, 3);
    expect((await globalStageState('ocr'))!['status'], 'done');
  });

  test('engine failure on every page records an error state (retryable), '
      'while genuinely empty pages record done', () async {
    await db.insertNote(buildNote('n1'));
    final boomPath = await insertPdfAttachment(
      'boom',
      'n1',
      textPages: ['p1', 'p2'],
    );
    ocrThrowContents.addAll(['$boomPath|0', '$boomPath|1']);
    await insertPdfAttachment('blank', 'n1', textPages: ['p1']);
    await indexer.flushPending();
    await indexer.backfillAll();

    final boomState = (await ocrState('boom'))!;
    expect(
      boomState['status'],
      'error',
      reason:
          'every page raising an engine exception is a failure, not '
          'an empty document — done would freeze it as success',
    );
    expect(boomState['errorMessage'], contains('engine failure'));
    expect(await ocrChunks('boom'), isEmpty);

    expect(
      (await ocrState('blank'))!['status'],
      'done',
      reason:
          'pages with genuinely no text are a successful empty '
          'extraction',
    );
    expect(await ocrChunks('blank'), isEmpty);
  });
}
