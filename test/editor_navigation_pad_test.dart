import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/utils/markdown_navigation.dart';
import 'package:note_synapse/widgets/editor_navigation_pad.dart';
import 'package:note_synapse/widgets/synapse_code_editor.dart';

/// A fixture with a heading, a wrapped paragraph and a list, so every unit has
/// something meaningful to move over.
const String kDoc =
    '# Title\n'
    'alpha beta gamma\n'
    '\n'
    '- one two\n'
    '- three four';

const int kParagraphLine = 1;

Future<CodeLineEditingController> pumpPad(
  WidgetTester tester, {
  String text = kDoc,
  int line = kParagraphLine,
  int offset = 6,
  FocusNode? focusNode,
}) async {
  focusNode ??= FocusNode();
  addTearDown(focusNode.dispose);
  final controller = CodeLineEditingController.fromText(text);
  controller.selection = CodeLineSelection.collapsed(
    index: line,
    offset: offset,
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Focus(
          focusNode: focusNode,
          child: Stack(
            children: [
              EditorNavigationPad(controller: controller, focusNode: focusNode),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Future<void> selectUnit(WidgetTester tester, NavGranularity unit) async {
  await tester.tap(find.byKey(EditorNavigationPad.unitKeyOf(unit)));
  await tester.pump();
}

Future<void> tapArrow(WidgetTester tester, AxisDirection direction) async {
  await tester.tap(find.byKey(EditorNavigationPad.arrowKeyOf(direction)));
  await tester.pump();
}

/// `(lineIndex, offset)` of the selection's free end.
(int, int) extent(CodeLineEditingController c) =>
    (c.selection.extentIndex, c.selection.extentOffset);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('dispatch matrix — moving', () {
    testWidgets('char steps one grapheme and one line', (tester) async {
      final c = await pumpPad(tester);
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (1, 7));
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 6));
      await tapArrow(tester, AxisDirection.up);
      expect(extent(c), (0, 6));
      await tapArrow(tester, AxisDirection.down);
      expect(extent(c), (1, 6));
    });

    testWidgets('token steps to the next and previous token start', (
      tester,
    ) async {
      // 'alpha beta gamma' — offset 6 is the start of `beta`.
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.token);
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (1, 11), reason: 'start of gamma');
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 6), reason: 'back to the start of beta');
    });

    testWidgets('token vertically collapses onto one visual line', (
      tester,
    ) async {
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.token);
      await tapArrow(tester, AxisDirection.up);
      expect(extent(c), (0, 6), reason: 'one line up, not one token');
      await tapArrow(tester, AxisDirection.down);
      expect(extent(c), (1, 6), reason: 'and back down one line');
    });

    testWidgets('line moves to line start and line end', (tester) async {
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (1, 16), reason: 'end of `alpha beta gamma`');
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 0), reason: 'start of the line');
    });

    testWidgets('line steps vertically by logical line', (tester) async {
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.down);
      expect(extent(c), (
        2,
        0,
      ), reason: 'the blank line is shorter, so the column clamps');
      await tapArrow(tester, AxisDirection.up);
      expect(extent(c), (1, 0));
    });

    testWidgets('block moves to block start and block end', (tester) async {
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.block);
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 0), reason: 'the paragraph is its own block');
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (1, 16));
    });

    testWidgets('block steps to the previous and next block', (tester) async {
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.block);
      await tapArrow(tester, AxisDirection.down);
      expect(extent(c).$1, 3, reason: 'first list item');
      await tapArrow(tester, AxisDirection.down);
      expect(extent(c).$1, 4, reason: 'second list item');
      await tapArrow(tester, AxisDirection.up);
      expect(extent(c).$1, 3);
      await tapArrow(tester, AxisDirection.up);
      expect(extent(c).$1, 1);
      await tapArrow(tester, AxisDirection.up);
      expect(extent(c).$1, 0, reason: 'the heading');
    });

    testWidgets('token carries across lines, including all-space ones', (
      tester,
    ) async {
      // The fourth input that makes re_editor throw: end of a line whose
      // successor holds nothing but spaces.
      final c = await pumpPad(
        tester,
        text: 'one two\n   \nthree four',
        line: 0,
        offset: 4,
      );
      await selectUnit(tester, NavGranularity.token);

      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (0, 7), reason: 'no token left, so the line end');
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (1, 0), reason: 'onto the all-space line');
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (1, 3), reason: 'no token here either, so its end');
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (2, 0), reason: 'first token of the next real line');
      expect(tester.takeException(), isNull);

      await tapArrow(tester, AxisDirection.left);
      expect(extent(c).$1, 1, reason: 'and back across the blank line');
      expect(tester.takeException(), isNull);
    });

    testWidgets('block lands on the first non-space character', (tester) async {
      final c = await pumpPad(
        tester,
        text: 'a\n\n    indented item',
        line: 0,
        offset: 0,
      );
      await selectUnit(tester, NavGranularity.block);
      await tapArrow(tester, AxisDirection.down);
      expect(extent(c), (2, 4), reason: 'past the indentation, not column 0');
    });
  });

  group('line start is the same motion in both modes', () {
    // re_editor's `extendSelectionToLineStart` is a bare `extentOffset: 0`,
    // while `moveCursorToLineStart` toggles first-non-space then column 0. The
    // plan's matrix says one cell, one meaning, so the pad implements it itself.
    const indented = 'alpha\n    indented text';

    testWidgets('moving: first non-space, then column 0', (tester) async {
      final c = await pumpPad(tester, text: indented, line: 1, offset: 10);
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 4), reason: 'past the indent first');
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 0), reason: 'then all the way to column 0');
    });

    testWidgets('selecting: the identical two steps', (tester) async {
      final c = await pumpPad(tester, text: indented, line: 1, offset: 10);
      await tester.tap(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      await selectUnit(tester, NavGranularity.line);

      await tapArrow(tester, AxisDirection.left);
      expect(
        extent(c),
        (1, 4),
        reason: 'selection mode must stop at the indent too, not jump to 0',
      );
      expect(c.selection.baseOffset, 10, reason: 'the anchor stays put');
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 0));
    });

    testWidgets('a tab-indented line gets the same two steps', (tester) async {
      // re_editor's own prefix count only recognises U+0020.
      final c = await pumpPad(tester, text: 'a\n\t\tdeep', line: 1, offset: 5);
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 2), reason: 'tabs count as indentation');
      await tapArrow(tester, AxisDirection.left);
      expect(extent(c), (1, 0));
    });
  });

  group('dispatch matrix — selecting', () {
    Future<CodeLineEditingController> selecting_(WidgetTester tester) async {
      // Tear the old tree down first: pumping the same widget type reuses its
      // State, so the mode toggle below would flip an already-on mode back off.
      await tester.pumpWidget(const SizedBox());
      final c = await pumpPad(tester);
      await tester.tap(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      return c;
    }

    testWidgets('every unit lands the free end exactly where moving would', (
      tester,
    ) async {
      // The anchor-only assertions this replaces were satisfied by any motion
      // that left a non-collapsed selection, which is how the line-start
      // asymmetry above went unnoticed.
      const expected = <(NavGranularity, AxisDirection), (int, int)>{
        (NavGranularity.char, AxisDirection.up): (0, 6),
        (NavGranularity.char, AxisDirection.down): (2, 0),
        (NavGranularity.char, AxisDirection.left): (1, 5),
        (NavGranularity.char, AxisDirection.right): (1, 7),
        (NavGranularity.token, AxisDirection.up): (0, 6),
        (NavGranularity.token, AxisDirection.down): (2, 0),
        (NavGranularity.token, AxisDirection.left): (1, 0),
        (NavGranularity.token, AxisDirection.right): (1, 11),
        (NavGranularity.line, AxisDirection.up): (0, 6),
        (NavGranularity.line, AxisDirection.down): (2, 0),
        (NavGranularity.line, AxisDirection.left): (1, 0),
        (NavGranularity.line, AxisDirection.right): (1, 16),
        (NavGranularity.block, AxisDirection.up): (0, 0),
        (NavGranularity.block, AxisDirection.down): (3, 0),
        (NavGranularity.block, AxisDirection.left): (1, 0),
        (NavGranularity.block, AxisDirection.right): (1, 16),
      };

      for (final entry in expected.entries) {
        final (unit, direction) = entry.key;
        // Moving mode: the cursor lands there.
        await tester.pumpWidget(const SizedBox());
        final moving = await pumpPad(tester);
        await selectUnit(tester, unit);
        await tapArrow(tester, direction);
        expect(extent(moving), entry.value, reason: 'move $unit $direction');
        expect(
          moving.selection.isCollapsed,
          isTrue,
          reason: 'move $unit $direction left a selection',
        );

        // Selecting mode: the free end lands in the identical place.
        final selecting = await selecting_(tester);
        await selectUnit(tester, unit);
        await tapArrow(tester, direction);
        expect(
          extent(selecting),
          entry.value,
          reason: 'select $unit $direction disagreed with move',
        );
        expect(selecting.selection.baseIndex, 1);
        expect(selecting.selection.baseOffset, 6);
      }
    });

    testWidgets('every unit drags the free end and keeps the anchor', (
      tester,
    ) async {
      for (final unit in NavGranularity.values) {
        final c = await selecting_(tester);
        await selectUnit(tester, unit);
        for (final direction in AxisDirection.values) {
          // Re-anchor each time: moving in all four directions in turn would
          // land back on the anchor and collapse the selection legitimately.
          c.selection = const CodeLineSelection.collapsed(index: 1, offset: 6);
          await tester.pump();
          await tapArrow(tester, direction);
          expect(
            c.selection.baseIndex,
            1,
            reason: '$unit $direction moved the anchor',
          );
          expect(
            c.selection.baseOffset,
            6,
            reason: '$unit $direction moved the anchor',
          );
          expect(
            c.selection.isCollapsed,
            isFalse,
            reason: '$unit $direction did not extend the selection',
          );
        }
      }
    });

    testWidgets('moving mode keeps the selection collapsed', (tester) async {
      for (final unit in NavGranularity.values) {
        await tester.pumpWidget(const SizedBox());
        final c = await pumpPad(tester);
        await selectUnit(tester, unit);
        for (final direction in AxisDirection.values) {
          await tapArrow(tester, direction);
          expect(
            c.selection.isCollapsed,
            isTrue,
            reason: '$unit $direction left a selection behind',
          );
        }
      }
    });
  });

  group('the dial itself', () {
    testWidgets('char is lit by default and one tap away', (tester) async {
      await pumpPad(tester);
      expect(
        tester
            .widget<Semantics>(
              find.byKey(EditorNavigationPad.unitKeyOf(NavGranularity.char)),
            )
            .properties
            .selected,
        isTrue,
      );
      await selectUnit(tester, NavGranularity.block);
      expect(
        tester
            .widget<Semantics>(
              find.byKey(EditorNavigationPad.unitKeyOf(NavGranularity.block)),
            )
            .properties
            .selected,
        isTrue,
      );
      await selectUnit(tester, NavGranularity.char);
      expect(
        tester
            .widget<Semantics>(
              find.byKey(EditorNavigationPad.unitKeyOf(NavGranularity.char)),
            )
            .properties
            .selected,
        isTrue,
      );
    });

    testWidgets('reverts to char when the editor loses focus', (tester) async {
      final focusNode = FocusNode();
      final c = await pumpPad(tester, focusNode: focusNode);
      focusNode.requestFocus();
      await tester.pump();

      await selectUnit(tester, NavGranularity.block);
      focusNode.unfocus();
      await tester.pump();

      // With char lit again, one right press is one character.
      final before = extent(c);
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c), (before.$1, before.$2 + 1));
    });

    testWidgets('the status chip names both mode and unit', (tester) async {
      await pumpPad(tester);
      // The transient motion label wins for 700ms after a press, so let it lapse.
      await tester.pumpAndSettle();
      expect(find.text('Move · Char'), findsOneWidget);

      await tester.tap(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Select · Char'), findsOneWidget);

      await selectUnit(tester, NavGranularity.block);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Select · Block'), findsOneWidget);
    });

    testWidgets('a press announces what it did', (tester) async {
      await pumpPad(tester);
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.right);
      expect(find.text('Line end'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Line end'), findsNothing);
    });
  });

  group('auto-repeat', () {
    testWidgets('a held arrow repeats, and the unit does not escalate', (
      tester,
    ) async {
      final c = await pumpPad(
        tester,
        text: 'abcdefghijklmnopqrstuvwxyz',
        line: 0,
        offset: 0,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(EditorNavigationPad.arrowKeyOf(AxisDirection.right)),
        ),
      );
      await tester.pump(); // the press itself moves one
      expect(extent(c).$2, 1);

      await tester.pump(const Duration(milliseconds: 900));
      await gesture.up();
      await tester.pump();

      final moved = extent(c).$2;
      expect(moved, greaterThan(3), reason: 'holding should repeat');
      // 400ms delay then ~120ms decaying to 45ms: ~5-12 steps in 900ms. If the
      // unit had escalated to token this would have run off the end of the word.
      expect(
        moved,
        lessThan(20),
        reason: 'the unit must not escalate with the rate',
      );
    });

    testWidgets('releasing stops the repeat', (tester) async {
      final c = await pumpPad(
        tester,
        text: 'abcdefghijklmnopqrstuvwxyz',
        line: 0,
        offset: 0,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(EditorNavigationPad.arrowKeyOf(AxisDirection.right)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      final atRelease = extent(c).$2;
      await tester.pump(const Duration(seconds: 2));
      expect(extent(c).$2, atRelease);
    });

    testWidgets('a hold that hits a dead end really ends', (tester) async {
      // Cancelling from inside the repeated action cannot work by cancelling
      // the timer — it has already fired — so the re-arm sites consult a flag.
      // Without it the hold silently carried on.
      final c = await pumpPad(tester, text: 'abcdef', line: 0, offset: 6);
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(EditorNavigationPad.arrowKeyOf(AxisDirection.right)),
        ),
      );
      await tester.pump();
      expect(extent(c), (0, 6), reason: 'already at the end, nothing to do');

      // Still holding: put the cursor somewhere it *could* move from.
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pump();

      expect(extent(c), (
        0,
        0,
      ), reason: 'the hold ended at the dead end and must not resume');
    });

    testWidgets('an unchanged label is not re-keyed on every tick', (
      tester,
    ) async {
      // Re-keying restarts the cross-fade, so the label never rises above a
      // third of its opacity during a hold — dim exactly while being read.
      final c = await pumpPad(
        tester,
        text: 'abcdefghijklmnop',
        line: 0,
        offset: 0,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(EditorNavigationPad.arrowKeyOf(AxisDirection.right)),
        ),
      );
      await tester.pump();
      // Scoped to the status bar: 'Char' is also the corner key's own caption.
      final label = find.descendant(
        of: find.byKey(EditorNavigationPad.dragHandleKey),
        matching: find.text('Char'),
      );
      final firstKey = tester.widget<Text>(label).key;

      await tester.pump(const Duration(milliseconds: 800));
      final laterKey = tester.widget<Text>(label).key;
      await gesture.up();
      await tester.pump();

      expect(extent(c).$2, greaterThan(2), reason: 'it really was repeating');
      expect(
        laterKey,
        firstKey,
        reason: 'the same label must keep its key across ticks',
      );
    });

    testWidgets('a corner key does not repeat', (tester) async {
      final c = await pumpPad(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(EditorNavigationPad.unitKeyOf(NavGranularity.token)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await gesture.up();
      await tester.pump();
      expect(extent(c), (
        1,
        6,
      ), reason: 'selecting a unit must not move the cursor');
    });
  });

  group('expand and shrink', () {
    testWidgets('long press expands, and repeats climb', (tester) async {
      final c = await pumpPad(tester);
      await tester.longPress(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      expect(c.selectedText, 'beta');

      await tester.longPress(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      expect(c.selectedText, 'alpha beta gamma');
    });

    testWidgets('expand snaps to the lit unit', (tester) async {
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.line);
      await tester.longPress(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      expect(
        c.selectedText,
        'alpha beta gamma',
        reason: 'with line lit the first expand takes the line, not the token',
      );
    });

    testWidgets('a downward swipe shrinks back', (tester) async {
      final c = await pumpPad(tester);
      await tester.longPress(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      await tester.longPress(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      expect(c.selectedText, 'alpha beta gamma');

      await tester.fling(
        find.byKey(EditorNavigationPad.modeKey),
        const Offset(0, 60),
        800,
      );
      await tester.pump();
      expect(
        c.selectedText,
        'beta',
        reason: 'shrink puts back the previous rung',
      );
    });

    testWidgets('editing the text invalidates the shrink stack', (
      tester,
    ) async {
      final c = await pumpPad(tester);
      await tester.longPress(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      expect(c.selectedText, 'beta');

      c.text = 'something entirely different';
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 3);
      await tester.pump();

      await tester.fling(
        find.byKey(EditorNavigationPad.modeKey),
        const Offset(0, 60),
        800,
      );
      await tester.pump();
      expect(
        c.selection.extentIndex,
        0,
        reason: 'a stale selection from the old text must not be restored',
      );
      expect(c.selection.isCollapsed, isTrue);
    });
  });

  group('the dial reverts on every context change', () {
    testWidgets('hiding and re-showing the pad starts at char', (tester) async {
      final c = await pumpPad(tester);
      await selectUnit(tester, NavGranularity.block);

      // Hiding disposes the pad's State; re-showing must not resurrect `block`.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final c2 = await pumpPad(tester);
      await tapArrow(tester, AxisDirection.right);
      expect(extent(c2), (1, 7), reason: 'one character, so char is lit again');
      expect(
        c.selection.extentOffset,
        6,
        reason: 'the old controller is untouched',
      );
    });

    testWidgets('swapping the controller resets the dial and the ladder', (
      tester,
    ) async {
      // Reproduces the user-app editor, which swaps between an editable and a
      // read-only controller on the same pad.
      final long = CodeLineEditingController.fromText(
        List.generate(40, (i) => 'line $i alpha beta').join('\n'),
      );
      final short = CodeLineEditingController.fromText('tiny');
      long.selection = const CodeLineSelection.collapsed(index: 30, offset: 5);
      short.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);

      var useLong = true;
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setOuter = setState;
                return Stack(
                  children: [
                    EditorNavigationPad(controller: useLong ? long : short),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await selectUnit(tester, NavGranularity.block);
      await tester.longPress(find.byKey(EditorNavigationPad.modeKey));
      await tester.pump();
      expect(long.selection.isCollapsed, isFalse);

      setOuter(() => useLong = false);
      await tester.pump();

      // Shrinking must not restore line 30 into a one-line document, and the
      // next motion must not throw on an out-of-range line index.
      await tester.fling(
        find.byKey(EditorNavigationPad.modeKey),
        const Offset(0, 60),
        800,
      );
      await tester.pump();
      expect(
        short.selection.extentIndex,
        0,
        reason: 'a selection from the previous document must not be restored',
      );

      await tapArrow(tester, AxisDirection.right);
      expect(tester.takeException(), isNull);
      expect(short.selection.extentIndex, 0);
      expect(
        short.selection.extentOffset,
        1,
        reason: 'the dial went back to char, so this is one character',
      );
    });
  });

  group('status readout', () {
    testWidgets('the chip stays visible while a motion label is up', (
      tester,
    ) async {
      await pumpPad(tester);
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.right);
      // Both at once: the readout is the dial's whole justification, so a
      // transient label must not be allowed to hide it.
      expect(find.text('Move · Line'), findsOneWidget);
      expect(find.text('Line end'), findsOneWidget);
    });

    testWidgets('repeating the same label does not throw on duplicate keys', (
      tester,
    ) async {
      await pumpPad(tester);
      // Two identical labels inside one 150ms switch window used to hand
      // AnimatedSwitcher the same key twice.
      await selectUnit(tester, NavGranularity.line);
      await tester.pump(const Duration(milliseconds: 300));
      await selectUnit(tester, NavGranularity.char);
      await tester.pump(const Duration(milliseconds: 20));
      await selectUnit(tester, NavGranularity.line);
      await tester.pump(const Duration(milliseconds: 20));
      await tapArrow(tester, AxisDirection.left);
      await tester.pump(const Duration(milliseconds: 20));
      await selectUnit(tester, NavGranularity.line);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ergonomics', () {
    testWidgets('dragging the status bar moves the pad to the other corner', (
      tester,
    ) async {
      await pumpPad(tester);
      final before = tester.getTopLeft(find.byKey(EditorNavigationPad.modeKey));

      await tester.fling(
        find.byKey(EditorNavigationPad.dragHandleKey),
        const Offset(-120, 0),
        900,
      );
      await tester.pumpAndSettle();

      final after = tester.getTopLeft(find.byKey(EditorNavigationPad.modeKey));
      expect(
        after.dx,
        lessThan(before.dx),
        reason: 'a leftward fling should park the pad on the left',
      );
    });

    testWidgets('a fling across a key moves the cursor and nothing else', (
      tester,
    ) async {
      // The arrows are raw `Listener`s and never join the gesture arena, so a
      // drag surface over the key grid fires *as well as* the key. Confining
      // the drag to the chrome is what keeps these two apart.
      final c = await pumpPad(tester);
      final before = tester.getTopLeft(find.byKey(EditorNavigationPad.modeKey));

      await tester.fling(
        find.byKey(EditorNavigationPad.arrowKeyOf(AxisDirection.right)),
        const Offset(-120, 0),
        900,
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(EditorNavigationPad.modeKey)).dx,
        before.dx,
        reason: 'a fling starting on a key must not relocate the pad',
      );
      expect(extent(c), (1, 7), reason: 'it is a key press, one character');
    });

    testWidgets(
      'a fling across a corner key selects the unit and nothing else',
      (tester) async {
        await pumpPad(tester);
        final before = tester.getTopLeft(
          find.byKey(EditorNavigationPad.modeKey),
        );

        await tester.fling(
          find.byKey(EditorNavigationPad.unitKeyOf(NavGranularity.block)),
          const Offset(-120, 0),
          900,
        );
        await tester.pumpAndSettle();

        expect(
          tester.getTopLeft(find.byKey(EditorNavigationPad.modeKey)).dx,
          before.dx,
        );
      },
    );

    testWidgets('a motion that cannot move stops the hold instead of buzzing', (
      tester,
    ) async {
      // Cursor already at the very start; holding left can never move it.
      final c = await pumpPad(tester, text: 'abc', line: 0, offset: 0);
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(EditorNavigationPad.arrowKeyOf(AxisDirection.left)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await gesture.up();
      await tester.pump();
      expect(extent(c), (0, 0));
      // The empty label slot is the observable proxy for "nothing happened".
      // ('Char' as a bare string would match the corner key's own caption.)
      expect(
        find.byKey(const ValueKey('nav_pad_no_label')),
        findsOneWidget,
        reason: 'a no-op motion should not announce itself',
      );
    });
  });

  group('inside a real editor', () {
    testWidgets('char steps by visual line where line steps by logical line', (
      tester,
    ) async {
      // One logical line long enough to wrap many times in a narrow editor.
      final long = List.filled(40, 'wrap').join(' ');
      final controller = CodeLineEditingController.fromText('$long\ntail');
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 0,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MediaQuery(
              // A raised keyboard: the pad is meant to arrive with it rather
              // than having to be summoned from the toolbar every time.
              data: const MediaQueryData(
                viewInsets: EdgeInsets.only(bottom: 300),
              ),
              child: SizedBox(
                width: 260,
                height: 420,
                child: SynapseCodeEditor(
                  controller: controller,
                  wordWrap: true,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(EditorNavigationPad.modeKey),
        findsOneWidget,
        reason: 'the pad should come up with the keyboard',
      );

      await tapArrow(tester, AxisDirection.down);
      expect(
        controller.selection.extentIndex,
        0,
        reason:
            'a wrapped paragraph is one logical line, so char+down stays on it',
      );
      expect(
        controller.selection.extentOffset,
        greaterThan(0),
        reason: 'but the cursor did move, down one visual row',
      );

      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 0,
      );
      await tester.pump();
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.down);
      expect(
        controller.selection.extentIndex,
        1,
        reason: 'line+down leaves the wrapped paragraph in one press',
      );

      // And the same asymmetry going up, out of the tail line.
      await selectUnit(tester, NavGranularity.char);
      await tapArrow(tester, AxisDirection.up);
      expect(
        controller.selection.extentIndex,
        0,
        reason: 'char+up enters the wrapped paragraph at its last visual row',
      );
      final charUpOffset = controller.selection.extentOffset;
      expect(
        charUpOffset,
        greaterThan(0),
        reason: 'it lands deep in the paragraph, not at its start',
      );

      controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 0,
      );
      await tester.pump();
      await selectUnit(tester, NavGranularity.line);
      await tapArrow(tester, AxisDirection.up);
      expect(controller.selection.extentIndex, 0);
      expect(
        controller.selection.extentOffset,
        lessThan(charUpOffset),
        reason: 'line+up goes to the paragraph itself, not its last row',
      );

      // re_editor schedules uncancellable `Future.delayed` work whenever the
      // selection changes; let it drain while the tree is still alive, or the
      // binding fails the test on pending timers.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });
  });
}
