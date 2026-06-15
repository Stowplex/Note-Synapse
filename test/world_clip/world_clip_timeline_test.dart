import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/screens/world_clip/world_clip_timeline.dart';

void main() {
  testWidgets('renders a thumb per timestamp and toggles tags on tap',
      (tester) async {
    final tagged = <int>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorldClipTimeline(
          timestamps: const [0, 200, 400],
          taggedTimestamps: tagged,
          thumbnailBuilder: (ts) async => Uint8List.fromList(const [
            137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,
            0,0,0,144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,
            0,0,3,0,1,169,118,218,141,0,0,0,0,73,69,78,68,174,66,96,130
          ]),
          onToggleTag: (ts) => tagged.contains(ts)
              ? tagged.remove(ts)
              : tagged.add(ts),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wc-thumb-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wc-thumb-200')));
    expect(tagged.contains(200), isTrue);
  });
}
