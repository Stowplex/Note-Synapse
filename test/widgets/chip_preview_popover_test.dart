import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/chip_action.dart';
import 'package:note_synapse/widgets/chip_preview_popover.dart';

void main() {
  testWidgets('show() inserts an overlay containing the full chip prompt text', (tester) async {
    const chip = ChipAction(label: 'go', prompt: 'You are a tutor. Explain X.');
    BuildContext? capturedCtx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        capturedCtx = ctx;
        return const Scaffold(body: SizedBox.shrink());
      }),
    ));
    final entry = ChipPreviewPopover.show(
      context: capturedCtx!,
      anchorRect: const Rect.fromLTWH(100, 100, 80, 26),
      chip: chip,
    );
    await tester.pump();
    expect(find.text('You are a tutor. Explain X.'), findsOneWidget);
    entry.remove();
    await tester.pump();
    expect(find.text('You are a tutor. Explain X.'), findsNothing);
  });

  testWidgets('popover is constrained — long prompt scrolls inside', (tester) async {
    final longPrompt = List.generate(60, (i) => 'Line $i').join('\n');
    final chip = ChipAction(label: 'big', prompt: longPrompt);
    BuildContext? capturedCtx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        capturedCtx = ctx;
        return const Scaffold(body: SizedBox.shrink());
      }),
    ));
    final entry = ChipPreviewPopover.show(
      context: capturedCtx!,
      anchorRect: const Rect.fromLTWH(100, 400, 80, 26),
      chip: chip,
    );
    await tester.pump();
    // The popover wraps content in a SingleChildScrollView for very long prompts.
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    entry.remove();
  });

  testWidgets('popover horizontal placement is clamped to screen bounds', (tester) async {
    // Anchor near the right edge of the screen — the popover should
    // shift left so it doesn't run off-screen.
    const chip = ChipAction(label: 'edge', prompt: 'short');
    BuildContext? capturedCtx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        capturedCtx = ctx;
        return const Scaffold(body: SizedBox.shrink());
      }),
    ));
    final mediaSize = MediaQuery.of(capturedCtx!).size;
    final anchorAtRightEdge = Rect.fromLTWH(mediaSize.width - 30, 100, 30, 26);
    final entry = ChipPreviewPopover.show(
      context: capturedCtx!,
      anchorRect: anchorAtRightEdge,
      chip: chip,
    );
    await tester.pump();
    // Find the Positioned widget — its `left` value should keep popover
    // within the screen.
    final positioned = tester.widget<Positioned>(find.byType(Positioned));
    expect(positioned.left, isNotNull);
    // Popover right edge = positioned.left + maxWidth (360). Must stay
    // within the screen with the 8px gap, i.e. <= mediaSize.width - 8.
    expect(positioned.left! + 360.0, lessThanOrEqualTo(mediaSize.width - 8.0),
        reason: 'Popover (max 360px wide) must not run past right edge of screen with 8px margin');
    entry.remove();
  });
}
