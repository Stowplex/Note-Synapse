import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/in_note_marker_badge.dart';

void main() {
  testWidgets('InNoteMarkerBadge shows correct index number', (tester) async {
    bool tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InNoteMarkerBadge(
            index: 3,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byType(InNoteMarkerBadge));
    expect(tapped, isTrue);
    // Drain the pending 800ms timer from the opacity reset.
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('InNoteMarkerBadge starts at 60% opacity', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InNoteMarkerBadge(index: 1, onTap: () {}),
        ),
      ),
    );
    final animatedOpacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(animatedOpacity.opacity, closeTo(0.6, 0.01));
  });
}
