import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_flow_screen.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/world_clip/video_source.dart';
import 'package:note_synapse/services/world_clip/frame_correction.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempPath);
  final String tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  testWidgets('Import pictures goes straight to the review stage with pages',
      (tester) async {
    late Directory tmp;
    late List<String> imagePaths;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('wc_picflow');
      Uint8List jpg(int v) => Uint8List.fromList(img.encodeJpg(
          img.Image(width: 40, height: 30)..clear(img.ColorRgb8(v, v, v))));
      imagePaths = [
        (File('${tmp.path}/p0.jpg')..writeAsBytesSync(jpg(60))).path,
        (File('${tmp.path}/p1.jpg')..writeAsBytesSync(jpg(180))).path,
      ];
    });

    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    await resetForTesting();
    getIt.registerSingleton<VideoSource>(
        FakeVideoSource(null, imagePaths: imagePaths));
    getIt.registerSingleton<FrameCorrection>(OpenCvFrameCorrection());

    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipFlowScreen(),
    ));
    await tester.pumpAndSettle();

    // Tap "Import pictures" and let the copy + render pipeline run on the
    // real event loop (file I/O + OpenCV decode/encode + first-time init).
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.photo_library));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();

    // We skipped the timeline (no Import buttons / scrub) and landed on the
    // review list showing one tile per picture, with the compile bar.
    expect(find.byIcon(Icons.photo_library), findsNothing);
    expect(find.byKey(const ValueKey('wc-page-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('wc-page-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('wc-compile')), findsOneWidget);

    // Deleting every page of a picture project returns to the source picker
    // (it has no video timeline to fall back to).
    for (var n = 0; n < 2; n++) {
      await tester.tap(find.byKey(const ValueKey('wc-menu-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
    }
    expect(find.byIcon(Icons.photo_library), findsOneWidget); // back on source
    expect(find.byIcon(Icons.video_library), findsOneWidget);

    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}
