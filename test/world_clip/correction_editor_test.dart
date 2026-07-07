import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/correction_editor.dart';
import 'package:note_synapse/services/world_clip/frame_correction.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';

Uint8List _png(int w, int h) => Uint8List.fromList(
    img.encodePng(img.Image(width: w, height: h)..clear(img.ColorRgb8(20, 90, 140))));

Future<void> _pumpEditor(
  WidgetTester tester,
  Uint8List png, {
  List<Correction> initial = const [],
  required void Function(List<Correction>) onDone,
}) async {
  // Real image-codec decode needs the real event loop.
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: CorrectionEditor(
          framePng: png,
          initial: initial,
          correction: OpenCvFrameCorrection(),
          onDone: onDone,
        ),
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump();
}

void main() {
  testWidgets('emits a mesh-dewarp correction via onDone', (tester) async {
    List<Correction>? result;
    await _pumpEditor(tester, _png(48, 32), onDone: (c) => result = c);

    // Four corner handles are present (1x1 grid).
    expect(find.byKey(const ValueKey('wc-handle-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('wc-handle-3')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('wc-mesh-done')));
    await tester.pump();

    expect(result, isNotNull);
    expect(result!.whereType<MeshDewarpCorrection>(), isNotEmpty);
    // Untouched color sliders → no colorAdjust correction emitted.
    expect(result!.whereType<ColorAdjustCorrection>(), isEmpty);
  });

  testWidgets('color panel emits a colorAdjust correction via onDone',
      (tester) async {
    List<Correction>? result;
    await _pumpEditor(tester, _png(48, 32), onDone: (c) => result = c);

    await tester.tap(find.byKey(const ValueKey('wc-color-toggle')));
    await tester.pump();

    // Drag the saturation slider fully left (saturation 0).
    final slider = find.byKey(const ValueKey('wc-saturation'));
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(-400, 0));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('wc-color-done')));
    await tester.pump();

    expect(result, isNotNull);
    final color = result!.whereType<ColorAdjustCorrection>();
    expect(color, hasLength(1));
    expect(color.first.saturation, 0);
    expect(result!.whereType<MeshDewarpCorrection>(), isNotEmpty);
  });

  testWidgets('tool strip scrolls on a narrow screen with Done pinned',
      (tester) async {
    // Narrow phone: the shape tool row is wider than the screen. It must
    // scroll (no RenderFlex overflow, which would fail this test) and the
    // pinned Done button must stay tappable without scrolling.
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    List<Correction>? result;
    await _pumpEditor(tester, _png(48, 32), onDone: (c) => result = c);

    // The color toggle sits at the far end of the strip — off-screen until
    // the strip is scrolled.
    await tester.ensureVisible(find.byKey(const ValueKey('wc-color-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('wc-color-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('wc-saturation')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('wc-color-done')));
    await tester.pump();
    expect(result, isNotNull);
  });

  testWidgets('re-opens with stored color values and can reset them',
      (tester) async {
    List<Correction>? result;
    await _pumpEditor(
      tester,
      _png(48, 32),
      initial: [
        ColorAdjustCorrection(contrast: 1.3, saturation: 0.5, temperature: 0.4)
      ],
      onDone: (c) => result = c,
    );

    await tester.tap(find.byKey(const ValueKey('wc-color-toggle')));
    await tester.pump();
    // Stored contrast value is reflected in the slider.
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('wc-contrast')))
            .value,
        closeTo(1.3, 0.001));

    // Reset colors → Done emits no colorAdjust (back to neutral).
    await tester.tap(find.byIcon(Icons.format_color_reset));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('wc-color-done')));
    await tester.pump();
    expect(result!.whereType<ColorAdjustCorrection>(), isEmpty);
  });
}
