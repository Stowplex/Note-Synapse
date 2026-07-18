import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:note_synapse/screens/world_clip/world_clip_flow_screen.dart';
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

  Widget host({required int? selected, required List<int> timestamps}) =>
      MaterialApp(
        home: Scaffold(
          body: WorldClipTimeline(
            timestamps: timestamps,
            taggedTimestamps: const {},
            selectedTimestamp: selected,
            thumbnailBuilder: (_) async => png,
            onSelect: (_) {},
          ),
        ),
      );

  testWidgets('selecting a far-off timestamp scrolls it into view',
      (tester) async {
    final timestamps = [for (var i = 0; i < 40; i++) i * 200];
    await tester.pumpWidget(host(selected: 0, timestamps: timestamps));
    await tester.pump();

    // Far-right thumb is beyond the viewport, so the lazy list never built it.
    final farKey = ValueKey('wc-thumb-${35 * 200}');
    expect(find.byKey(farKey), findsNothing);

    // Selecting it (as the prev/next keyframe buttons do) scrolls the strip.
    await tester.pumpWidget(host(selected: 35 * 200, timestamps: timestamps));
    await tester.pumpAndSettle();
    expect(find.byKey(farKey), findsOneWidget);
    // Centered-ish: the thumb sits within the viewport, not clipped at edges.
    final x = tester.getCenter(find.byKey(farKey)).dx;
    expect(x, inInclusiveRange(88, 800 - 88));
  });

  testWidgets('selecting an already-visible thumb does not move the strip',
      (tester) async {
    final timestamps = [for (var i = 0; i < 40; i++) i * 200];
    await tester.pumpWidget(host(selected: 0, timestamps: timestamps));
    await tester.pump();
    final before =
        tester.getCenter(find.byKey(const ValueKey('wc-thumb-200'))).dx;
    // Thumb 200 is on-screen — re-selecting it (a direct tap) must not yank
    // the strip to re-center it under the user's finger.
    await tester.pumpWidget(host(selected: 200, timestamps: timestamps));
    await tester.pumpAndSettle();
    final after =
        tester.getCenter(find.byKey(const ValueKey('wc-thumb-200'))).dx;
    expect(after, before);
  });

  testWidgets('scrolling back to an earlier selection also works',
      (tester) async {
    final timestamps = [for (var i = 0; i < 40; i++) i * 200];
    await tester.pumpWidget(host(selected: 35 * 200, timestamps: timestamps));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(selected: 0, timestamps: timestamps));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wc-thumb-0')), findsOneWidget);
  });

  group('previous/nextKeyframe', () {
    const tagged = {400, 1200, 2800};

    test('steps to the nearest tagged frame in each direction', () {
      expect(previousKeyframe(tagged, 1200), 400);
      expect(nextKeyframe(tagged, 1200), 2800);
      // From an untagged scrub position between keyframes.
      expect(previousKeyframe(tagged, 1000), 400);
      expect(nextKeyframe(tagged, 1000), 1200);
    });

    test('returns null at the ends', () {
      expect(previousKeyframe(tagged, 400), isNull);
      expect(nextKeyframe(tagged, 2800), isNull);
    });

    test('with no selection, jumps to last/first tagged frame', () {
      expect(previousKeyframe(tagged, null), 2800);
      expect(nextKeyframe(tagged, null), 400);
    });

    test('empty tag set navigates nowhere', () {
      expect(previousKeyframe(const {}, 1000), isNull);
      expect(nextKeyframe(const {}, 1000), isNull);
    });
  });
}
