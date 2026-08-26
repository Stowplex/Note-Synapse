// Widget tests for the renderer half of plan §4.3 (Step 16):
// `synapseresource://figure/<figureId>` and `synapseresource://attachment/<id>`
// render as inline images WITHOUT a noteId (so AI chat bubbles work), carry a
// provenance bar, and never render a whole PDF page as an image.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/figure_region_extractor.dart';
import 'package:note_synapse/services/search/figure_resolver.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/utils/file_utils.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

/// 1x1 transparent PNG — real bytes so Image.file actually decodes.
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKwMTQAAAABJRU5ErkJggg==',
);

String _documentsPath = Directory.systemTemp.path;

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => _documentsPath;

  @override
  Future<String?> getTemporaryPath() async => _documentsPath;
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
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    getIt.registerSingleton<DatabaseService>(db);
    docsDir = await Directory.systemTemp.createTemp('figure_widget_test');
    _documentsPath = docsDir.path;
    FileUtils.resetDocumentsPathCache();
    derivedDir = Directory('${docsDir.path}/attachments/derived');
    await derivedDir.create(recursive: true);
  });

  tearDown(() async {
    await resetForTesting();
    await db.close();
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
    FileUtils.resetDocumentsPathCache();
  });

  Future<void> insertNote(String id, String title) async {
    await db.insertNote(
      Note(
        id: id,
        title: title,
        content: 'body',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> insertAttachment(
    String id,
    String noteId, {
    required String fileName,
    bool createFile = true,
  }) async {
    final relative = 'attachments/$fileName';
    if (createFile) {
      final file = File('${docsDir.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(_pngBytes);
    }
    final raw = await db.database;
    await raw.insert('attachments', {
      'id': id,
      'noteId': noteId,
      'filePath': relative,
      'fileName': fileName,
      'fileType': fileName.split('.').last,
      'isRelativePath': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': 1,
    });
  }

  /// Seeds one `figure` chunk the way Step 14 will: `meta` carries the region
  /// identity + derivedAssetPath + figureIndex and NO renderer-dependent value
  /// (the row's own contentHash is computed FROM text+meta by the indexer).
  Future<String> insertFigureChunk({
    required String noteId,
    required String attachmentId,
    required int page,
    required String contentHash,
    String caption = 'Figure 1: pipeline',
    bool writeAsset = true,
  }) async {
    const figureIndex = 0;
    final fileName = FigureRegionExtractor.derivedFigureFileName(
      attachmentId,
      page,
      figureIndex,
    );
    if (writeAsset) {
      await File('${derivedDir.path}/$fileName').writeAsBytes(_pngBytes);
    }
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
      'text': caption,
      'meta': jsonEncode({
        'page': page,
        'rect': {'l': 72.0, 't': 700.0, 'r': 540.0, 'b': 400.0},
        'confidence': 0.9,
        'source': 'captioned',
        'caption': caption,
        'derivedAssetPath': 'attachments/derived/$fileName',
        'figureIndex': figureIndex,
      }),
      'contentHash': contentHash,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    return FigureResolver.buildFigureId(chunkKey, contentHash);
  }

  /// Seeds the index/files and renders the markdown WITHOUT a noteId, exactly
  /// like ChipAwareAiMessageContent does in a chat bubble.
  ///
  /// Everything runs inside [WidgetTester.runAsync] so the real dart:io /
  /// sqlite futures behind seeding and resolution can complete (same pattern
  /// as image_caching_test.dart); a testWidgets body otherwise runs in a fake
  /// async zone where real I/O never resolves.
  Future<void> pumpMarkdown(
    WidgetTester tester,
    String Function() content, {
    Future<void> Function()? seed,
    ValueNotifier<bool>? hasWebViewNotifier,
  }) async {
    await tester.runAsync(() async {
      if (seed != null) await seed();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: InteractiveCheckboxMarkdown(
                originalContent: content(),
                hasWebViewNotifier: hasWebViewNotifier,
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Second round, still inside runAsync: some paths chain a follow-up
      // async lookup (an evicted synapsetemp URI falling back to its promoted
      // copy) whose FutureBuilder is only created by this rebuild — its
      // future must also be born in the real zone to complete.
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('figure URI renders an image + provenance bar without noteId', (
    tester,
  ) async {
    var figureId = '';
    await pumpMarkdown(
      tester,
      () => '![Figure 2](synapseresource://figure/$figureId)',
      seed: () async {
        await insertNote('n1', 'Transformer paper');
        await insertAttachment('att1', 'n1', fileName: 'paper.pdf');
        figureId = await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 7,
          contentHash: 'aaaa1111bbbb2222',
          caption: 'Figure 2: attention',
        );
      },
    );

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images, isNotEmpty);
    expect(
      images.any(
        (image) =>
            image.image is FileImage &&
            (image.image as FileImage).file.path.endsWith('att1_p7_f0.png'),
      ),
      isTrue,
      reason: 'the derived crop must be rendered from disk',
    );
    // Provenance: owning note title + 1-based page.
    expect(find.textContaining('Transformer paper'), findsOneWidget);
    expect(find.textContaining('7'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    // The provenance chip is a control, so it carries its accessible name
    // (`figureOpenSource`).
    expect(find.byTooltip('Open source'), findsOneWidget);
  });

  testWidgets('a figure whose regenerable crop is gone stays navigable', (
    tester,
  ) async {
    // Derived assets are excluded from export/backup, so after a restore the
    // crop is missing while note + chunk + PDF are intact. Claiming "the
    // source note or figure was removed" would be a lie, and refusing the tap
    // would strand the user.
    var figureId = '';
    await pumpMarkdown(
      tester,
      () => '![Figure 2](synapseresource://figure/$figureId)',
      seed: () async {
        await insertNote('n1', 'Transformer paper');
        await insertAttachment(
          'att1',
          'n1',
          fileName: 'paper.pdf',
          createFile: false,
        );
        figureId = await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 7,
          contentHash: 'aaaa1111bbbb2222',
          writeAsset: false,
        );
      },
    );

    expect(find.byType(Image), findsNothing);
    expect(
      find.textContaining('Figure no longer available'),
      findsNothing,
      reason: 'the figure was NOT removed — only its regenerable crop',
    );
    expect(
      find.text('Figure 2'),
      findsOneWidget,
      reason: 'it degrades to the tap-link that opens the source PDF',
    );
  });

  testWidgets('a non-raster attachment in image position is a tap-link', (
    tester,
  ) async {
    await pumpMarkdown(
      tester,
      () => '![The paper](synapseresource://attachment/att-pdf)',
      seed: () async {
        await insertNote('n1', 'Transformer paper');
        await insertAttachment('att-pdf', 'n1', fileName: 'paper.pdf');
      },
    );

    expect(find.byType(Image), findsNothing);
    expect(
      find.textContaining('Figure no longer available'),
      findsNothing,
      reason: 'a live PDF attachment was not removed',
    );
    expect(find.text('The paper'), findsOneWidget);
  });

  testWidgets('an SVG attachment in image position is a tap-link', (
    tester,
  ) async {
    // Image.file cannot decode SVG markup, but the attachment is alive.
    await pumpMarkdown(
      tester,
      () => '![Diagram](synapseresource://attachment/att-svg)',
      seed: () async {
        await insertNote('n1', 'Diagrams');
        await insertAttachment('att-svg', 'n1', fileName: 'chart.svg');
      },
    );

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Figure no longer available'), findsNothing);
    expect(find.text('Diagram'), findsOneWidget);
  });

  testWidgets('image attachment URI renders inline without noteId', (
    tester,
  ) async {
    await pumpMarkdown(
      tester,
      () => '![Diagram](synapseresource://attachment/att-img)',
      seed: () async {
        await insertNote('n1', 'Screenshots');
        await insertAttachment('att-img', 'n1', fileName: 'diagram.png');
      },
    );

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(
      images.any(
        (image) =>
            image.image is FileImage &&
            (image.image as FileImage).file.path.endsWith('diagram.png'),
      ),
      isTrue,
    );
    expect(find.textContaining('Screenshots'), findsOneWidget);
  });

  testWidgets('attachment page URI never renders an inline image', (
    tester,
  ) async {
    await pumpMarkdown(
      tester,
      () => '![report p3](synapseresource://attachment/att1?page=3)',
      seed: () async {
        await insertNote('n1', 'Scanned report');
        await insertAttachment('att1', 'n1', fileName: 'report.pdf');
      },
    );

    expect(
      find.byType(Image),
      findsNothing,
      reason: 'whole PDF pages are links, never inline figures',
    );
    expect(find.text('report p3'), findsOneWidget);
  });

  testWidgets('stale figureId renders the dangling placeholder', (
    tester,
  ) async {
    var chunkKey = '';
    await pumpMarkdown(
      tester,
      () => '![Figure 1](synapseresource://figure/$chunkKey~9999cccc9999)',
      seed: () async {
        await insertNote('n1', 'Transformer paper');
        await insertAttachment('att1', 'n1', fileName: 'paper.pdf');
        final figureId = await insertFigureChunk(
          noteId: 'n1',
          attachmentId: 'att1',
          page: 2,
          contentHash: 'aaaa1111bbbb2222',
        );
        chunkKey = FigureResolver.parseFigureId(figureId)!.chunkKey;
      },
    );

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Figure no longer available'), findsOneWidget);
  });

  testWidgets('unknown figure renders the dangling placeholder', (
    tester,
  ) async {
    await pumpMarkdown(
      tester,
      () => '![Gone](synapseresource://figure/n1:figure:att1:0~abcdef012345)',
    );

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Figure no longer available'), findsOneWidget);
  });

  testWidgets('evicted synapsetemp image falls back to its promoted copy', (
    tester,
  ) async {
    // ConversationService.addAIResponse / the note save path copy these files
    // to attachments/<ownerId>_<sha256(uri)><ext> and keep the URI in the
    // text; the cache entry itself is gone here.
    const uri = 'synapsetemp:///syn_evicted.png';
    await pumpMarkdown(
      tester,
      () => '![diagram]($uri)',
      seed: () async {
        final hash = sha256.convert(utf8.encode(uri)).toString();
        final file = File('${docsDir.path}/attachments/conv-1_$hash.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(_pngBytes);
      },
    );

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(
      images.any(
        (image) =>
            image.image is FileImage &&
            (image.image as FileImage).file.path.contains('conv-1_'),
      ),
      isTrue,
      reason: 'the permanent copy must render once the temp cache is gone',
    );
  });

  testWidgets('a promoted temp SVG goes to the SVG renderer', (tester) async {
    // The promoted copy keeps the original extension; `.svg` is markup, so
    // routing it to Image.file would only ever show a broken image.
    //
    // flutter_inappwebview has no platform implementation under `flutter
    // test`, so the SVG webview asserts the moment it is built (on every
    // pump). Swallow exactly that error — the ROUTING is what this test pins
    // down, and reaching the assert already proves it.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('flutter_inappwebview')) return;
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);

    const uri = 'synapsetemp:///syn_evicted_vector.svg';
    final hasWebView = ValueNotifier<bool>(false);
    await pumpMarkdown(
      tester,
      () => '![chart]($uri)',
      hasWebViewNotifier: hasWebView,
      seed: () async {
        final hash = sha256.convert(utf8.encode(uri)).toString();
        final file = File('${docsDir.path}/attachments/conv-1_$hash.svg');
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>',
        );
      },
    );

    expect(
      hasWebView.value,
      isTrue,
      reason: 'the promoted .svg was handed to the SVG (webview) renderer',
    );
    expect(find.byType(Image), findsNothing);
    expect(
      find.textContaining('Unable to load temporary image'),
      findsNothing,
      reason: 'the promoted copy WAS found — it just is not a bitmap',
    );
  });

  testWidgets('deleted attachment renders the dangling placeholder', (
    tester,
  ) async {
    await pumpMarkdown(
      tester,
      () => '![Gone](synapseresource://attachment/missing-att)',
    );

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Figure no longer available'), findsOneWidget);
  });
}
