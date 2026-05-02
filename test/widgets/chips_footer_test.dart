import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/chip_action.dart';
import 'package:note_synapse/widgets/chips_footer.dart';

Widget _wrap(Widget c) => MaterialApp(home: Scaffold(body: c));

void main() {
  testWidgets('shows 4 skeleton pills when isStreaming AND isExpected', (tester) async {
    await tester.pumpWidget(_wrap(const ChipsFooter(
      chips: null,
      isStreaming: true,
      isExpected: true,
    )));
    await tester.pump();
    expect(find.byKey(const ValueKey('chip-skeleton-pill')), findsNWidgets(4));
  });

  testWidgets('shows nothing when isExpected = false (no default_action skill loaded)', (tester) async {
    await tester.pumpWidget(_wrap(const ChipsFooter(
      chips: null,
      isStreaming: true,
      isExpected: false,
    )));
    await tester.pump();
    expect(find.byKey(const ValueKey('chip-skeleton-pill')), findsNothing);
  });

  testWidgets('shows nothing when isStreaming = false and chips list is empty', (tester) async {
    await tester.pumpWidget(_wrap(const ChipsFooter(
      chips: [],
      isStreaming: false,
      isExpected: true,
    )));
    await tester.pump();
    expect(find.byKey(const ValueKey('chip-skeleton-pill')), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('renders one InkWell per chip with the label visible', (tester) async {
    const chips = [
      ChipAction(label: 'explain transformer', prompt: 'You are a tutor...'),
      ChipAction(label: 'explain attention', prompt: 'Explain attention...'),
    ];
    await tester.pumpWidget(_wrap(ChipsFooter(
      chips: chips,
      isStreaming: false,
      isExpected: true,
      onChipTap: (_) {},
    )));
    await tester.pump();
    expect(find.text('explain transformer'), findsOneWidget);
    expect(find.text('explain attention'), findsOneWidget);
  });

  testWidgets('chip tap fires onChipTap with the tapped chip', (tester) async {
    ChipAction? tapped;
    const chips = [ChipAction(label: 'go', prompt: 'Go forth.')];
    await tester.pumpWidget(_wrap(ChipsFooter(
      chips: chips,
      isStreaming: false,
      isExpected: true,
      onChipTap: (c) => tapped = c,
    )));
    await tester.pump();
    await tester.tap(find.text('go'));
    expect(tapped, isNotNull);
    expect(tapped!.label, 'go');
    expect(tapped!.prompt, 'Go forth.');
  });

  testWidgets('label longer than 5 words is ellipsized at render', (tester) async {
    const chips = [
      ChipAction(
        label: 'this label has way too many words for a chip',
        prompt: 'p'),
    ];
    await tester.pumpWidget(_wrap(ChipsFooter(
      chips: chips,
      isStreaming: false,
      isExpected: true,
      onChipTap: (_) {},
    )));
    await tester.pump();
    // Find the rendered label text — it should contain "this label has way too" then ellipsis.
    final found = find.byWidgetPredicate((w) =>
        w is Text &&
        w.data != null &&
        w.data!.startsWith('this label has way too') &&
        w.data!.endsWith('…'));
    expect(found, findsOneWidget);
  });

  testWidgets('long-press fires onChipLongPress with chip and anchor key', (tester) async {
    ChipAction? lpChip;
    GlobalKey? lpKey;
    const chips = [ChipAction(label: 'go', prompt: 'Long prompt here')];
    await tester.pumpWidget(_wrap(ChipsFooter(
      chips: chips,
      isStreaming: false,
      isExpected: true,
      onChipTap: (_) {},
      onChipLongPress: (c, k) {
        lpChip = c;
        lpKey = k;
      },
    )));
    await tester.pump();
    await tester.longPress(find.text('go'));
    expect(lpChip, isNotNull);
    expect(lpChip!.label, 'go');
    expect(lpKey, isNotNull);
  });
}
