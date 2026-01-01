import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:note_synapse/widgets/synapse_note_editor.dart';
import 'package:note_synapse/l10n/app_localizations.dart';

void main() {
  testWidgets('SynapseNoteEditor multi-line list formatting', (
    WidgetTester tester,
  ) async {
    final controller = CodeLineEditingController.fromText(
      'item 1\nitem 2\nitem 3',
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SynapseNoteEditor(
            controller:
                controller, // No language, to avoid lexer issues in test if possible
          ),
        ),
      ),
    );

    // Select all text
    controller.selection = const CodeLineSelection(
      baseIndex: 0,
      baseOffset: 0,
      extentIndex: 2,
      extentOffset: 6, // "item 3".length = 6
    );
    await tester.pump();

    // Find the Bullet List button and tap it
    final bulletButton = find.byIcon(Icons.list);
    expect(bulletButton, findsOneWidget);
    await tester.tap(bulletButton);
    await tester.pump();

    // Verify text has bullets
    expect(controller.text, '- item 1\n- item 2\n- item 3');

    // Tap it again to toggle off
    await tester.tap(bulletButton);
    await tester.pump();
    expect(controller.text, 'item 1\nitem 2\nitem 3');

    // Apply Numbered List
    final numberButton = find.byIcon(Icons.format_list_numbered);
    expect(numberButton, findsOneWidget);
    await tester.tap(numberButton);
    await tester.pump();
    expect(controller.text, '1. item 1\n2. item 2\n3. item 3');

    // Apply Checkbox (Popup menu interaction)
    final checkboxButton = find.byIcon(Icons.check_box_outlined);
    expect(checkboxButton, findsOneWidget);
    await tester.tap(checkboxButton);
    await tester.pumpAndSettle(); // Wait for menu

    // Find "Checked" option
    // PopupMenu items are standard Text widgets usually.
    // The code uses: const PopupMenuItem(value: '- [x] ', child: Text('☑ Checked')),
    final checkedOption = find.text('☑ Checked');
    expect(checkedOption, findsOneWidget);
    await tester.tap(checkedOption);
    await tester.pump();

    // Verify replacement (Numbers should be gone, checkboxes added)
    expect(controller.text, '- [x] item 1\n- [x] item 2\n- [x] item 3');

    // Verify selection restoration
    expect(controller.selection.start.index, 0);
    expect(controller.selection.end.index, 2);

    await tester.pumpWidget(const SizedBox());
  });
}
