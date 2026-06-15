import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:note_synapse/screens/world_clip/world_clip_timeline.dart';

void main() {
  final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 3)..clear(img.ColorRgb8(10, 20, 30))));

  testWidgets('renders a thumb per timestamp and selects on tap',
      (tester) async {
    int? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorldClipTimeline(
          timestamps: const [0, 200, 400],
          taggedTimestamps: const {200},
          selectedTimestamp: 0,
          thumbnailBuilder: (ts) async => png,
          onSelect: (ts) => selected = ts,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wc-thumb-0')), findsOneWidget);
    // Tagged frame shows the key-frame marker.
    expect(find.byIcon(Icons.key), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wc-thumb-400')));
    expect(selected, 400);
  });
}
