import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/widgets/block_selection_menu.dart';

void main() {
  Future<void> pumpMenu(
    WidgetTester tester, {
    VoidCallback? onExpandAbove,
    VoidCallback? onContractAbove,
    VoidCallback? onContractBelow,
    VoidCallback? onExpandBelow,
    VoidCallback? onLongPressExpandAbove,
    VoidCallback? onLongPressContractAbove,
    VoidCallback? onLongPressContractBelow,
    VoidCallback? onLongPressExpandBelow,
    VoidCallback? onNoteActionApp,
    bool canExpandAbove = true,
    bool canContractAbove = true,
    bool canContractBelow = true,
    bool canExpandBelow = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Center(
            child: BlockSelectionMenu(
              onExpandAbove: onExpandAbove ?? () {},
              onContractAbove: onContractAbove ?? () {},
              onContractBelow: onContractBelow ?? () {},
              onExpandBelow: onExpandBelow ?? () {},
              onEdit: () {},
              onAIEdit: () {},
              onNoteActionApp: onNoteActionApp ?? () {},
              onDelete: () {},
              onExit: () {},
              canExpandAbove: canExpandAbove,
              canContractAbove: canContractAbove,
              canContractBelow: canContractBelow,
              canExpandBelow: canExpandBelow,
              onLongPressExpandAbove: onLongPressExpandAbove,
              onLongPressContractAbove: onLongPressContractAbove,
              onLongPressContractBelow: onLongPressContractBelow,
              onLongPressExpandBelow: onLongPressExpandBelow,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('boundary buttons keep single tap behavior', (tester) async {
    var expandAbove = 0;
    var contractAbove = 0;
    var contractBelow = 0;
    var expandBelow = 0;

    await pumpMenu(
      tester,
      onExpandAbove: () => expandAbove++,
      onContractAbove: () => contractAbove++,
      onContractBelow: () => contractBelow++,
      onExpandBelow: () => expandBelow++,
    );

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.tap(find.byIcon(Icons.vertical_align_bottom));
    await tester.tap(find.byIcon(Icons.vertical_align_top));
    await tester.tap(find.byIcon(Icons.expand_more));

    expect(expandAbove, 1);
    expect(contractAbove, 1);
    expect(contractBelow, 1);
    expect(expandBelow, 1);
  });

  testWidgets('boundary button long press uses popup callback, not tooltip', (
    tester,
  ) async {
    var tapCount = 0;
    var expandAbove = 0;
    var contractAbove = 0;
    var contractBelow = 0;
    var expandBelow = 0;

    await pumpMenu(
      tester,
      onExpandAbove: () => tapCount++,
      onContractAbove: () => tapCount++,
      onContractBelow: () => tapCount++,
      onExpandBelow: () => tapCount++,
      onLongPressExpandAbove: () => expandAbove++,
      onLongPressContractAbove: () => contractAbove++,
      onLongPressContractBelow: () => contractBelow++,
      onLongPressExpandBelow: () => expandBelow++,
    );

    await tester.longPress(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(expandAbove, 1);
    expect(find.text('Expand Above'), findsNothing);

    await tester.longPress(find.byIcon(Icons.vertical_align_bottom));
    await tester.pump();
    expect(contractAbove, 1);
    expect(find.text('Contract Above'), findsNothing);

    await tester.longPress(find.byIcon(Icons.vertical_align_top));
    await tester.pump();
    expect(contractBelow, 1);
    expect(find.text('Contract Below'), findsNothing);

    await tester.longPress(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(expandBelow, 1);
    expect(find.text('Expand Below'), findsNothing);
    expect(tapCount, 0);
  });

  testWidgets('note action app button fires its callback', (tester) async {
    var noteActionApp = 0;

    await pumpMenu(tester, onNoteActionApp: () => noteActionApp++);

    expect(find.byIcon(Icons.apps), findsOneWidget);
    await tester.tap(find.byIcon(Icons.apps));
    await tester.pump();

    expect(noteActionApp, 1);
  });

  testWidgets('all nine buttons fit within a 360dp phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpMenu(tester);
    await tester.pumpAndSettle();

    // No RenderFlex overflow, and every action is reachable.
    expect(tester.takeException(), isNull);
    for (final icon in const [
      Icons.expand_less,
      Icons.vertical_align_bottom,
      Icons.vertical_align_top,
      Icons.expand_more,
      Icons.edit,
      Icons.auto_awesome,
      Icons.apps,
      Icons.delete,
      Icons.close,
    ]) {
      expect(find.byIcon(icon), findsOneWidget, reason: 'missing $icon');
    }

    final card = tester.getSize(find.byType(Card));
    expect(card.width, lessThanOrEqualTo(360.0));
    expect(
      BlockSelectionMenu.estimatedWidth,
      greaterThanOrEqualTo(card.width),
      reason:
          'estimatedWidth must not under-report the rendered width, '
          'or the position clamp will let the card run off screen',
    );
  });

  testWidgets('disabled boundary button ignores long press', (tester) async {
    var tapCount = 0;
    var longPressCount = 0;

    await pumpMenu(
      tester,
      canExpandAbove: false,
      onExpandAbove: () => tapCount++,
      onLongPressExpandAbove: () => longPressCount++,
    );

    await tester.longPress(find.byIcon(Icons.expand_less));
    await tester.pump();

    expect(tapCount, 0);
    expect(longPressCount, 0);
  });
}
