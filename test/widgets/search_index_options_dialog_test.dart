// Step 21 — per-attachment search-index toggles (plan §1.3).
//
// The dialog is pure props + onSave precisely so this file can pump it: the
// two host screens build `DatabaseService()` as a field, so nothing they
// persist can be intercepted. What is pinned here is the policy contract the
// indexer reads back — which toggles a file type may show, that the `text`
// tri-state ('auto' | 'on' | 'off') survives the round trip through a
// two-state switch without silently downgrading an explicit opt-in, and the
// two service-free pieces the HOSTS share: the metadata read-modify-write
// (where a stale snapshot silently deletes bookmarks) and the exclusion
// confirmation (where a mistaken tap purges a note's index).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/search_index_options_dialog.dart';

// ── Harness ──────────────────────────────────────────────────────────────

late List<AttachmentSearchIndexConfig> _saved;

/// pumpAndSettle equivalent used across the search UI tests.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Opens the dialog through a real route so Save/Cancel pop the dialog and
/// not the app's root. [gate], when given, is awaited inside onSave — the
/// seam for asserting that the save is awaited BEFORE the pop.
Future<void> _open(
  WidgetTester tester, {
  required String fileName,
  AttachmentSearchIndexConfig config = const AttachmentSearchIndexConfig(),
  int? pageCount,
  int? pageCap,
  Future<void>? gate,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SearchIndexOptionsDialog(
                fileName: fileName,
                config: config,
                pageCount: pageCount,
                pageCap: pageCap,
                onSave: (saved) async {
                  _saved.add(saved);
                  if (gate != null) await gate;
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  await tester.tap(find.text('open'));
  await _settle(tester);
}

const _textToggle = 'Extract the text layer';
const _capToggle = 'Index despite the page limit';
const _deriveToggle = 'Extract content on this device';
const _embedToggle = 'Use for semantic search';

SwitchListTile _tile(WidgetTester tester, String title) {
  return tester.widget<SwitchListTile>(
    find.ancestor(of: find.text(title), matching: find.byType(SwitchListTile)),
  );
}

Future<void> _tapTile(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await _settle(tester);
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await _settle(tester);
}

Attachment _attachment({Map<String, dynamic>? metadata}) => Attachment(
  id: 'att-1',
  noteId: 'n1',
  filePath: 'attachments/paper.pdf',
  fileName: 'paper.pdf',
  fileType: 'pdf',
  createdAt: DateTime(2024),
  metadata: metadata,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // The dialog itself resolves no services (that is the point), but the
    // locator is reset either way so a stray registration from another suite
    // cannot leak in.
    await getIt.reset();
    _saved = [];
  });

  tearDown(() async {
    await getIt.reset();
  });

  // ── Pure helpers ───────────────────────────────────────────────────────

  group('searchIndexFileKindFor', () {
    test('classifies by extension, case-insensitively', () {
      expect(searchIndexFileKindFor('paper.pdf'), SearchIndexFileKind.pdf);
      expect(searchIndexFileKindFor('PAPER.PDF'), SearchIndexFileKind.pdf);
      for (final name in ['a.png', 'a.jpg', 'a.jpeg', 'a.webp', 'a.JPG']) {
        expect(
          searchIndexFileKindFor(name),
          SearchIndexFileKind.rasterImage,
          reason: name,
        );
      }
      expect(searchIndexFileKindFor('chart.svg'), SearchIndexFileKind.svg);
    });

    test('anything the pipeline cannot read content from is "other"', () {
      // .gif is deliberately NOT a raster kind: it is absent from
      // AttachmentOcrExtractor.kRasterImageExtensions, so the ocr/figures
      // stages skip it and an OCR toggle here would be dead.
      for (final name in ['clip.gif', 'memo.txt', 'talk.m4a', 'sheet.xlsx']) {
        expect(
          searchIndexFileKindFor(name),
          SearchIndexFileKind.other,
          reason: name,
        );
      }
    });
  });

  group('searchIndexConfigIsCustomized', () {
    test('every flag a PDF can show counts', () {
      expect(
        searchIndexConfigIsCustomized(
          'paper.pdf',
          const AttachmentSearchIndexConfig(text: 'off'),
        ),
        isTrue,
      );
    });

    test('the menus only call a config customized when THIS file type can '
        'show it', () {
      const embedOff = AttachmentSearchIndexConfig(embed: false);
      const ocrOff = AttachmentSearchIndexConfig(ocr: false);
      const textOn = AttachmentSearchIndexConfig(text: 'on');

      expect(searchIndexConfigIsCustomized('paper.pdf', textOn), isTrue);
      expect(searchIndexConfigIsCustomized('paper.pdf', ocrOff), isTrue);
      expect(searchIndexConfigIsCustomized('paper.pdf', embedOff), isTrue);

      // A raster never shows the text row (renamed away from .pdf, or an
      // external write): "customized" would point at a dialog that shows
      // nothing of the sort.
      expect(searchIndexConfigIsCustomized('scan.png', textOn), isFalse);
      expect(searchIndexConfigIsCustomized('scan.png', ocrOff), isTrue);
      expect(searchIndexConfigIsCustomized('scan.png', embedOff), isTrue);

      // SVG derives nothing on device, so only the embed switch counts.
      expect(searchIndexConfigIsCustomized('chart.svg', ocrOff), isFalse);
      expect(searchIndexConfigIsCustomized('chart.svg', embedOff), isTrue);

      // Not content-indexed at all: nothing to inspect, nothing to revert.
      for (final config in [textOn, ocrOff, embedOff]) {
        expect(searchIndexConfigIsCustomized('talk.m4a', config), isFalse);
      }
    });

    test('the default policy is never customized', () {
      for (final name in ['a.pdf', 'a.png', 'a.svg', 'a.m4a']) {
        expect(
          searchIndexConfigIsCustomized(
            name,
            const AttachmentSearchIndexConfig(),
          ),
          isFalse,
          reason: name,
        );
      }
    });
  });

  // ── The host-side write (where the data loss lives) ────────────────────

  group('buildSearchIndexMetadata', () {
    test(
      'merges onto the STORED metadata, not the caller\'s snapshot',
      () async {
        // The screens cache attachments and do NOT refresh when a pushed route
        // returns: the immersive viewer's bookmark (and NoteMarkerService's
        // markers, and an aiContextConfig set from that route) exist only in
        // the stored row.
        final cached = _attachment(metadata: {'aiContextConfig': 'stale'});
        final stored = _attachment(
          metadata: {
            'bookmarks': [
              {'page': 3},
            ],
            'markers': ['m1'],
            'aiContextConfig': 'fresh',
          },
        );

        final merged = await buildSearchIndexMetadata(
          attachment: cached,
          config: const AttachmentSearchIndexConfig(embed: false),
          reload: (id) async {
            expect(id, cached.id);
            return stored;
          },
        );

        expect(
          merged['bookmarks'],
          [
            {'page': 3},
          ],
          reason: 'a bookmark written while this screen was covered must live',
        );
        expect(merged['markers'], ['m1']);
        expect(merged['aiContextConfig'], 'fresh');
        expect(merged['searchIndex'], {
          'text': 'auto',
          'ocr': true,
          'embed': false,
        });
      },
    );

    test(
      'falls back to the caller\'s attachment when the row is gone',
      () async {
        final cached = _attachment(metadata: {'bookmarks': []});
        final merged = await buildSearchIndexMetadata(
          attachment: cached,
          config: const AttachmentSearchIndexConfig(),
          reload: (_) async => null,
        );
        expect(merged['bookmarks'], isEmpty);
        expect(merged.containsKey('searchIndex'), isTrue);
      },
    );

    test('an attachment with no metadata gets only the policy', () async {
      final merged = await buildSearchIndexMetadata(
        attachment: _attachment(),
        config: const AttachmentSearchIndexConfig(ocr: false),
        reload: (_) async => _attachment(),
      );
      expect(merged.keys, ['searchIndex']);
    });
  });

  // ── The exclusion confirmation (destructive, previously untested) ──────

  group('showSearchExcludeNoteConfirmation', () {
    Future<List<bool>> pumpConfirmation(WidgetTester tester) async {
      final results = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  results.add(await showSearchExcludeNoteConfirmation(context));
                },
                child: const Text('exclude'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('exclude'));
      await _settle(tester);
      return results;
    }

    testWidgets('states what is purged and returns true only on confirm', (
      tester,
    ) async {
      final results = await pumpConfirmation(tester);
      expect(
        find.textContaining('removed from the search index'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Exclude'));
      await _settle(tester);
      expect(results, [true]);
    });

    testWidgets('a mistaken tap does not purge', (tester) async {
      final results = await pumpConfirmation(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _settle(tester);
      expect(results, [false]);
    });

    testWidgets('dismissing the barrier is a no, not a null', (tester) async {
      final results = await pumpConfirmation(tester);
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      expect(results, [false]);
    });
  });

  // ── Which toggles a file type gets ─────────────────────────────────────

  group('per file type', () {
    testWidgets('a PDF gets text, on-device derivation and embedding', (
      tester,
    ) async {
      await _open(tester, fileName: 'paper.pdf');

      expect(find.text(_textToggle), findsOneWidget);
      expect(find.text(_deriveToggle), findsOneWidget);
      expect(find.text(_embedToggle), findsOneWidget);
      // No cap pressure and no explicit opt-in: nothing to say about size.
      expect(find.text(_capToggle), findsNothing);
      expect(find.text('paper.pdf'), findsNothing); // named inside a sentence
      expect(
        find.textContaining('Choose what may be extracted from paper.pdf'),
        findsOneWidget,
      );
    });

    testWidgets('a raster image has no text-layer toggle', (tester) async {
      await _open(tester, fileName: 'scan.png');

      expect(find.text(_textToggle), findsNothing);
      expect(find.text(_capToggle), findsNothing);
      expect(find.text(_deriveToggle), findsOneWidget);
      expect(find.text(_embedToggle), findsOneWidget);
    });

    testWidgets('the embed row admits that IMAGES are what get uploaded', (
      tester,
    ) async {
      // A figure chunk goes to an image-capable provider as a picture: the
      // crops rendered from a PDF, or the raster file itself. The row above
      // it ends "Nothing is uploaded", so this one has to be explicit.
      await _open(tester, fileName: 'scan.png');
      expect(find.textContaining('the images themselves'), findsOneWidget);
    });

    testWidgets('an SVG keeps the embed switch — the only control over that '
        'upload', (tester) async {
      await _open(tester, fileName: 'chart.svg');

      // Nothing is read from the file, so no text and no derivation row...
      expect(find.text(_textToggle), findsNothing);
      expect(find.text(_deriveToggle), findsNothing);
      // ...but its file-name/alt-text chunk IS sent to the provider.
      expect(find.text(_embedToggle), findsOneWidget);
      expect(
        find.textContaining('indexed by file name and alt text only'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);

      await _tapTile(tester, _embedToggle);
      await _save(tester);
      expect(_saved.single.embed, isFalse);
      expect(_saved.single.ocr, isTrue, reason: 'inapplicable flag preserved');
    });

    testWidgets('an unindexable type says it is not content-indexed', (
      tester,
    ) async {
      await _open(tester, fileName: 'talk.m4a');

      expect(find.byType(SwitchListTile), findsNothing);
      expect(
        find.textContaining('does not extract content from this file type'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    });
  });

  // ── The text tri-state ─────────────────────────────────────────────────

  group('text tri-state', () {
    testWidgets('an over-cap PDF surfaces the size skip and can opt in', (
      tester,
    ) async {
      await _open(tester, fileName: 'thesis.pdf', pageCount: 512, pageCap: 100);

      expect(
        find.textContaining('512 pages'),
        findsOneWidget,
        reason: 'the reason the PDF is skipped has to be stated',
      );
      expect(_tile(tester, _capToggle).value, isFalse);

      await _tapTile(tester, _capToggle);
      await _save(tester);

      expect(_saved.single.text, 'on');
      expect(_saved.single.ocr, isTrue);
      expect(_saved.single.embed, isTrue);
    });

    testWidgets('an unreadable page count still offers the opt-in', (
      tester,
    ) async {
      // The count could not be read (a failed open) but the cap is known:
      // the cap cannot be ruled out, so the way past it must stay reachable.
      await _open(tester, fileName: 'thesis.pdf', pageCap: 100);

      expect(find.text(_capToggle), findsOneWidget);
      expect(
        find.textContaining('even when it is longer than the page limit'),
        findsOneWidget,
      );
      await _tapTile(tester, _capToggle);
      await _save(tester);
      expect(_saved.single.text, 'on');
    });

    testWidgets('an existing "on" is shown and survives an untouched save', (
      tester,
    ) async {
      // No page info at all (the count could not be read): the opt-in must
      // still be visible, or the user could not undo it.
      await _open(
        tester,
        fileName: 'thesis.pdf',
        config: const AttachmentSearchIndexConfig(text: 'on'),
      );

      expect(_tile(tester, _textToggle).value, isTrue);
      expect(_tile(tester, _capToggle).value, isTrue);
      expect(
        find.textContaining('even when it is longer than the page limit'),
        findsOneWidget,
      );

      await _save(tester);
      expect(_saved.single.text, 'on');
    });

    testWidgets('an existing "on" is not downgraded by an off/on round trip', (
      tester,
    ) async {
      await _open(
        tester,
        fileName: 'thesis.pdf',
        config: const AttachmentSearchIndexConfig(text: 'on'),
      );

      await _tapTile(tester, _textToggle);
      expect(_tile(tester, _textToggle).value, isFalse);
      // Still visible so the opt-in is not silently lost, but inert.
      expect(_tile(tester, _capToggle).onChanged, isNull);

      await _tapTile(tester, _textToggle);
      await _save(tester);

      expect(_saved.single.text, 'on');
    });

    testWidgets('an explicit "on" can be returned to auto', (tester) async {
      await _open(
        tester,
        fileName: 'thesis.pdf',
        config: const AttachmentSearchIndexConfig(text: 'on'),
        pageCount: 512,
        pageCap: 100,
      );

      await _tapTile(tester, _capToggle);
      await _save(tester);

      expect(_saved.single.text, 'auto');
    });

    testWidgets('the cap row cannot vanish mid-session and strand the opt-in', (
      tester,
    ) async {
      // Stored 'on' while the file is NOT over the current cap (it shrank, or
      // the cap was raised). Turning the opt-in off must not hide the row:
      // settings' "Index anyway" list only shows over-cap PDFs, so the tap
      // would be unrepeatable.
      await _open(
        tester,
        fileName: 'thesis.pdf',
        config: const AttachmentSearchIndexConfig(text: 'on'),
        pageCount: 12,
        pageCap: 100,
      );

      await _tapTile(tester, _capToggle);
      expect(find.text(_capToggle), findsOneWidget);
      expect(_tile(tester, _capToggle).value, isFalse);

      await _tapTile(tester, _capToggle);
      await _save(tester);
      expect(_saved.single.text, 'on');
    });

    testWidgets('a stored "off" over the cap shows the reason, inert', (
      tester,
    ) async {
      await _open(
        tester,
        fileName: 'thesis.pdf',
        config: const AttachmentSearchIndexConfig(text: 'off'),
        pageCount: 512,
        pageCap: 100,
      );

      expect(_tile(tester, _textToggle).value, isFalse);
      expect(find.textContaining('512 pages'), findsOneWidget);
      expect(
        _tile(tester, _capToggle).onChanged,
        isNull,
        reason: 'meaningless while extraction is off entirely',
      );

      await _save(tester);
      expect(_saved.single.text, 'off');
    });

    testWidgets('turning the text switch off writes "off", not "auto"', (
      tester,
    ) async {
      await _open(tester, fileName: 'paper.pdf');

      await _tapTile(tester, _textToggle);
      await _save(tester);

      expect(_saved.single.text, 'off');
    });
  });

  // ── What Save emits ────────────────────────────────────────────────────

  group('save', () {
    testWidgets('emits exactly the toggled policy, other fields intact', (
      tester,
    ) async {
      await _open(
        tester,
        fileName: 'paper.pdf',
        config: const AttachmentSearchIndexConfig(
          text: 'off',
          ocr: true,
          embed: false,
        ),
      );

      expect(_tile(tester, _textToggle).value, isFalse);
      expect(_tile(tester, _deriveToggle).value, isTrue);
      expect(_tile(tester, _embedToggle).value, isFalse);

      await _tapTile(tester, _deriveToggle);
      await _save(tester);

      expect(_saved, hasLength(1));
      expect(_saved.single.text, 'off', reason: 'untouched field preserved');
      expect(_saved.single.ocr, isFalse);
      expect(_saved.single.embed, isFalse, reason: 'untouched field preserved');
    });

    testWidgets('a hidden toggle preserves its stored value', (tester) async {
      // A raster image never shows the text row; the stored 'off' must not be
      // resurrected as the 'auto' default on save.
      await _open(
        tester,
        fileName: 'scan.png',
        config: const AttachmentSearchIndexConfig(text: 'off'),
      );

      await _tapTile(tester, _embedToggle);
      await _save(tester);

      expect(_saved.single.text, 'off');
      expect(_saved.single.embed, isFalse);
    });

    testWidgets('a raster carrying an explicit "on" keeps it', (tester) async {
      // Renamed away from .pdf, or written externally: the flag is dead for
      // this kind, but the dialog is not the place it gets silently dropped.
      await _open(
        tester,
        fileName: 'scan.png',
        config: const AttachmentSearchIndexConfig(text: 'on'),
      );

      expect(find.text(_capToggle), findsNothing);
      await _tapTile(tester, _deriveToggle);
      await _save(tester);

      expect(_saved.single.text, 'on');
      expect(_saved.single.ocr, isFalse);
    });

    testWidgets('the dialog stays up until the write completes', (
      tester,
    ) async {
      // The hosts re-read the attachment after onSave to relabel their menu
      // entry; popping first lets that read queue ahead of the UPDATE.
      final gate = Completer<void>();
      await _open(tester, fileName: 'paper.pdf', gate: gate.future);

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();

      expect(_saved, hasLength(1));
      expect(find.byType(SearchIndexOptionsDialog), findsOneWidget);
      // Inert while in flight: a second tap must not fire a second write.
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(_saved, hasLength(1));

      gate.complete();
      await _settle(tester);
      expect(find.byType(SearchIndexOptionsDialog), findsNothing);
    });

    testWidgets('Cancel writes nothing', (tester) async {
      await _open(tester, fileName: 'paper.pdf');

      await _tapTile(tester, _deriveToggle);
      await _tapTile(tester, _embedToggle);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _settle(tester);

      expect(_saved, isEmpty);
      expect(find.byType(SearchIndexOptionsDialog), findsNothing);
    });

    testWidgets('the purge consequence is stated before anything is turned '
        'off', (tester) async {
      await _open(tester, fileName: 'paper.pdf');

      expect(
        find.textContaining('deletes what it already produced'),
        findsOneWidget,
      );
      expect(
        find.textContaining('vectors stored for semantic search'),
        findsOneWidget,
        reason: 'the embed toggle deletes too — the copy must not omit it',
      );
    });
  });
}
