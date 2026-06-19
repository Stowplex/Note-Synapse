import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:note_synapse/screens/world_clip/correction_editor.dart';
import 'package:note_synapse/services/world_clip/frame_correction.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';

Uint8List _png(int w, int h) => Uint8List.fromList(
    img.encodePng(img.Image(width: w, height: h)..clear(img.ColorRgb8(20, 90, 140))));

void main() {
  testWidgets('emits a mesh-dewarp correction via onDone', (tester) async {
    List<Correction>? result;
    final png = _png(48, 32);

    // Real image-codec decode needs the real event loop.
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CorrectionEditor(
            framePng: png,
            initial: const [],
            correction: OpenCvFrameCorrection(),
            onDone: (c) => result = c,
          ),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // Four corner handles are present (1x1 grid).
    expect(find.byKey(const ValueKey('wc-handle-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('wc-handle-3')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('wc-mesh-done')));
    await tester.pump();

    expect(result, isNotNull);
    expect(result!.whereType<MeshDewarpCorrection>(), isNotEmpty);
  });
}
