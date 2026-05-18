import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/marker_orphan_state.dart';

void main() {
  testWidgets('shows anchor-deleted message + delete button', (tester) async {
    bool deleted = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkerOrphanState(
          reason: OrphanReason.anchorDeleted,
          onDeleteMarker: () => deleted = true,
        ),
      ),
    ));
    expect(find.textContaining('exploration was deleted'), findsOneWidget);
    expect(find.textContaining('anchor message'), findsOneWidget);
    await tester.tap(find.text('Delete marker'));
    expect(deleted, isTrue);
  });

  testWidgets('shows conversation-deleted message variant', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkerOrphanState(
          reason: OrphanReason.conversationDeleted,
          onDeleteMarker: () {},
        ),
      ),
    ));
    expect(find.textContaining('conversation no longer exists'), findsOneWidget);
  });
}
