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
