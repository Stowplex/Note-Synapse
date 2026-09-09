import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/screens/note_merge_screen.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_merge_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/merge_arrange_list.dart';
import 'package:note_synapse/widgets/synapse_note_editor.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Note _note(String id, String title, String content) => Note(
  id: id,
  title: title,
  content: content,
  type: NoteType.note,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

const _a = '''# Alpha heading

First paragraph of A.

Second paragraph of A.
''';

const _b = '''Only paragraph of B.
''';

/// Position badges (small numbers) of ticked blocks, in screen order.
List<String> badgesTopToBottom(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (w) => w is Text && RegExp(r'^\d+$').hasMatch(w.data ?? ''),
  );
  final entries = [
    for (final e in finder.evaluate())
      (tester.getTopLeft(find.byWidget(e.widget)).dy, (e.widget as Text).data!),
  ]..sort((x, y) => x.$1.compareTo(y.$1));
  return entries.map((e) => e.$2).toList();
}

/// The title field is prefilled with the first note's title, so plain
/// `find.text` would also match it: scope tab taps to the TabBar.
Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

Widget _host(List<Note> notes) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: NoteMergeScreen(notes: notes),
);

void main() {
  testWidgets('tabs: Merged plus one per source, and an add button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Merged (0)'), findsOneWidget);
    expect(_tab('Note A'), findsOneWidget);
    expect(_tab('Note B'), findsOneWidget);
    expect(find.byTooltip('Add notes'), findsOneWidget);
    expect(find.byType(MergeArrangeList), findsOneWidget);
    expect(
      find.textContaining('Tap blocks in a note tab'),
      findsOneWidget,
    );
  });

  testWidgets('tapping a block ticks it in and out of the merged note', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note A'));
    await tester.pumpAndSettle();
    expect(find.text('0 of 3 blocks added'), findsOneWidget);

    final block = find.textContaining(
      'First paragraph of A',
      findRichText: true,
    );
    expect(block, findsOneWidget);
    await tester.tap(block);
    await tester.pumpAndSettle();

    expect(find.text('Merged (1)'), findsOneWidget);
    expect(find.text('1 of 3 blocks added'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: 'position badge');

    // Ticking the heading above it afterwards makes it block 2: the badges
    // show tick order, not document order. Read them top to bottom.
    final heading = find.textContaining('Alpha heading', findRichText: true);
    await tester.tap(heading);
    await tester.pumpAndSettle();
    expect(find.text('Merged (2)'), findsOneWidget);
    expect(badgesTopToBottom(tester), ['2', '1']);

    await tester.tap(block);
    await tester.pumpAndSettle();
    expect(badgesTopToBottom(tester), ['1'], reason: 'renumbered');
    await tester.tap(heading);
    await tester.pumpAndSettle();
    expect(find.text('Merged (0)'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('Add all / Remove all, then the Arrange view shows the blocks', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();
    expect(find.text('Merged (3)'), findsOneWidget);
    expect(find.text('3 of 3 blocks added'), findsOneWidget);

    await tester.tap(_tab('Merged (3)'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
    expect(
      find.textContaining('Second paragraph of A', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(_tab('Note A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove all'));
    await tester.pumpAndSettle();
    expect(find.text('Merged (0)'), findsOneWidget);
  });

  testWidgets('Edit view shows the merged markdown and round-trips', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();
    await tester.tap(_tab('Merged (1)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final editor = tester.widget<SynapseNoteEditor>(
      find.byType(SynapseNoteEditor),
    );
    expect(editor.controller.text, 'Only paragraph of B.');

    editor.controller.text = 'Only paragraph of B.\n\nTyped by hand.';
    await tester.tap(find.text('Arrange'));
    await tester.pumpAndSettle();
    expect(find.text('Merged (2)'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
  });

  testWidgets('back with unsaved blocks asks before discarding', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();

    final NavigatorState navigator = tester.state(find.byType(Navigator));
    navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Discard merged note?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteMergeScreen), findsOneWidget);
  });

  testWidgets('text typed in Edit view arms the discard guard and Save', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save')).onPressed,
      isNull,
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final editor = tester.widget<SynapseNoteEditor>(
      find.byType(SynapseNoteEditor),
    );
    editor.controller.text = 'Pasted by hand.';
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save')).onPressed,
      isNotNull,
    );

    final NavigatorState navigator = tester.state(find.byType(Navigator));
    navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Discard merged note?'), findsOneWidget);
  });

  testWidgets('long press on a source tab removes it and rebuilds the tabs', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _note('a', 'Note A', _a),
        _note('b', 'Note B', _b),
        _note('c', 'Note C', 'Paragraph of C.'),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();
    expect(find.text('Merged (1)'), findsOneWidget);

    await tester.longPress(_tab('Note B'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from merge'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(FilledButton, 'Remove from merge'));
    await tester.pumpAndSettle();

    expect(_tab('Note B'), findsNothing);
    expect(_tab('Note A'), findsOneWidget);
    expect(_tab('Note C'), findsOneWidget);
    // The block taken from B survives as plain text.
    expect(find.text('Merged (1)'), findsOneWidget);
    expect(
      find.textContaining('Only paragraph of B', findRichText: true),
      findsOneWidget,
    );

    // The rebuilt controller still drives the remaining tabs.
    await tester.tap(_tab('Note C'));
    await tester.pumpAndSettle();
    expect(find.text('0 of 1 blocks added'), findsOneWidget);
  });

  testWidgets('a block edited in the merged note shows the edited dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();

    await tester.tap(_tab('Merged (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    tester
        .widget<SynapseNoteEditor>(find.byType(SynapseNoteEditor))
        .controller
        .text = 'Only paragraph of B, shortened.';
    await tester.tap(find.text('Arrange'));
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note B'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_note), findsOneWidget);
    expect(find.text('0 of 1 blocks added'), findsOneWidget);

    await tester.tap(
      find.textContaining('Only paragraph of B', findRichText: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('Changed in the merged note'), findsOneWidget);
    await tester.tap(find.text('Add another copy'));
    await tester.pumpAndSettle();
    expect(find.text('Merged (2)'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'the new copy is block 2');
  });

  testWidgets('tapping a gap sets the insertion point and blocks land there', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_note('a', 'Note A', _a), _note('b', 'Note B', _b)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(_tab('Note A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();
    await tester.tap(_tab('Merged (3)'));
    await tester.pumpAndSettle();

    // Tap the gap above the first card (the topmost InkWell in the list).
    final gaps = find.descendant(
      of: find.byType(MergeArrangeList),
      matching: find.byType(InkWell),
    );
    await tester.tap(gaps.first);
    await tester.pumpAndSettle();
    expect(find.text('Next block goes here'), findsOneWidget);

    await tester.tap(_tab('Note B'));
    await tester.pumpAndSettle();
    expect(find.text('Inserting at position 1'), findsOneWidget);
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();
    expect(find.text('Inserting at position 2'), findsOneWidget);

    await tester.tap(_tab('Merged (4)'));
    await tester.pumpAndSettle();
    final firstCardText = find.descendant(
      of: find.byType(Card).first,
      matching: find.textContaining('Only paragraph of B', findRichText: true),
    );
    expect(firstCardText, findsOneWidget);
  });

  testWidgets('removing a source while in Edit view keeps typed text and new blocks', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _note('a', 'Note A', _a),
        _note('b', 'Note B', _b),
        _note('c', 'Note C', 'Paragraph of C.'),
      ]),
    );
    await tester.pumpAndSettle();

    // Type in Edit view, then go tick a block on another tab (commits text).
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    tester
        .widget<SynapseNoteEditor>(find.byType(SynapseNoteEditor))
        .controller
        .text = 'Typed by hand.';
    await tester.pumpAndSettle();
    await tester.tap(_tab('Note B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all'));
    await tester.pumpAndSettle();

    // Removing C rebuilds the tab controller and lands on Merged: the editor
    // must show the committed text plus the block ticked meanwhile.
    await tester.longPress(_tab('Note C'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove from merge'));
    await tester.pumpAndSettle();

    final text = tester
        .widget<SynapseNoteEditor>(find.byType(SynapseNoteEditor))
        .controller
        .text;
    expect(text, 'Typed by hand.\n\nOnly paragraph of B.');
    expect(find.text('Merged (2)'), findsOneWidget);
  });

  group('save (real database)', () {
    late DatabaseService db;
    late AppProvider appProvider;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      await resetForTesting();
      db = DatabaseService.createNew();
      await db.database;
      getIt.registerSingleton<DatabaseService>(db);
      getIt.registerSingleton<NoteMergeService>(NoteMergeService(db));
      appProvider = AppProvider(databaseService: db);
    });

    tearDown(() async {
      appProvider.dispose();
      await db.close();
    });

    /// Widget tests run under fake async, where real sqlite I/O never
    /// completes; anything that touches the database runs in [runAsync]
    /// and is pumped with real delays until it settles.
    Future<void> settleAsync(WidgetTester tester) => tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    Future<void> launch(WidgetTester tester, List<Note> notes) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: appProvider,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<Note>(
                    MaterialPageRoute(
                      builder: (_) => NoteMergeScreen(notes: notes),
                    ),
                  ),
                  child: const Text('launch'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('launch'));
      await tester.pumpAndSettle();
    }

    testWidgets('save as new note: content, tags, back-links, archive', (
      tester,
    ) async {
      final a = _note('a', 'Note A', _a).copyWith(tags: ['x']);
      final b = _note('b', 'Note B', _b).copyWith(tags: ['y'], pinned: true);
      await tester.runAsync(() async {
        await db.insertNote(a);
        await db.insertNote(b);
        await appProvider.loadData();
      });

      await launch(tester, [a, b]);
      await tester.tap(_tab('Note B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add all'));
      await tester.pumpAndSettle();
      await tester.tap(_tab('Note A'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.textContaining('First paragraph of A', findRichText: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Save as new note'), findsNWidgets(2));
      expect(find.text('Pinned notes are left as they are.'), findsOneWidget);
      await tester.tap(find.text('Archive the other source notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save as new note'));
      await settleAsync(tester);
      await tester.pumpAndSettle();

      // Back on the launcher: the screen popped with the merged note.
      expect(find.byType(NoteMergeScreen), findsNothing);
      await tester.runAsync(() async {
        final all = await db.getAllNotes();
        final merged = all.firstWhere((n) => n.id != 'a' && n.id != 'b');
        expect(merged.title, 'Note A');
        expect(
          merged.content,
          'Only paragraph of B.\n\nFirst paragraph of A.',
        );
        expect(merged.tags.toSet(), {'x', 'y'});

        final rels = await db.getOutgoingRelationships(merged.id);
        expect(rels.map((r) => r.toNoteId).toSet(), {'a', 'b'});
        expect(
          rels.every((r) => r.type == RelationshipType.references),
          isTrue,
        );

        // Both sources are "others" for a new note: A is archived, B is
        // pinned and therefore left alone.
        final aAfter = (await db.getNote('a'))!;
        final bAfter = (await db.getNote('b'))!;
        expect(aAfter.isArchived, isTrue);
        expect(bAfter.isArchived, isFalse);
        expect(bAfter.pinned, isTrue);
      });
    });

    testWidgets('replace Note A keeps its id and shows the diff first', (
      tester,
    ) async {
      final a = _note('a', 'Note A', _a);
      final b = _note('b', 'Note B', _b);
      await tester.runAsync(() async {
        await db.insertNote(a);
        await db.insertNote(b);
        await appProvider.loadData();
      });

      await launch(tester, [a, b]);
      await tester.tap(_tab('Note B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add all'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((w) => w is RadioListTile).last,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The other note is not changed.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Replace "Note A"'));
      await tester.pumpAndSettle();

      // Diff preview: accept.
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      await settleAsync(tester);
      await tester.pumpAndSettle();

      expect(find.byType(NoteMergeScreen), findsNothing);
      await tester.runAsync(() async {
        final aAfter = (await db.getNote('a'))!;
        expect(aAfter.content, 'Only paragraph of B.');
        expect((await db.getAllNotes()).length, 2);
      });
    });
  });
}
