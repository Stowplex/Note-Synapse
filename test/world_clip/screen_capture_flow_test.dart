import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_flow_screen.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/world_clip/video_source.dart';
import 'package:note_synapse/services/world_clip/screen_capture_service.dart';
import 'package:note_synapse/services/world_clip/frame_correction.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempPath);
  final String tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

// Non-const home so a re-mount in the same test actually rebuilds (a const
// WorldClipFlowScreen would be canonicalized and its build() skipped).
Widget _app() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipFlowScreen(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Screen Capture button is shown only when supported',
      (tester) async {
    await resetForTesting();
    getIt.registerSingleton<VideoSource>(FakeVideoSource(null));
    getIt.registerSingleton<ScreenCaptureService>(
        FakeScreenCaptureService(supported: false));

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wc-screen-capture')), findsNothing);

    // Re-mount with a supported backend.
    await resetForTesting();
    getIt.registerSingleton<VideoSource>(FakeVideoSource(null));
    getIt.registerSingleton<ScreenCaptureService>(
        FakeScreenCaptureService(supported: true));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wc-screen-capture')), findsOneWidget);
  });

  testWidgets('Tapping Screen Capture shows the recording overlay; a cancelled '
      'capture returns to the source picker', (tester) async {
    await resetForTesting();
    getIt.registerSingleton<VideoSource>(FakeVideoSource(null));
    // resultPath null → stop yields no file (cancelled / empty recording).
    getIt.registerSingleton<ScreenCaptureService>(
        FakeScreenCaptureService(resultPath: null, supported: true));

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('wc-screen-capture')));
    await tester.pump(); // build the recording overlay
    expect(find.byKey(const ValueKey('wc-capture-stop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('wc-capture-stop')));
    await tester.pumpAndSettle();
    // Overlay gone, back on the source picker (no video pipeline ran).
    expect(find.byKey(const ValueKey('wc-capture-stop')), findsNothing);
    expect(find.byKey(const ValueKey('wc-screen-capture')), findsOneWidget);
  });

  testWidgets('A finished recording flows into the video timeline stage',
      (tester) async {
    late Directory tmp;
    late String videoPath;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('wc_capflow');
      // A real (if tiny) file so ClipProjectStore.create can copy it.
      videoPath = (File('${tmp.path}/capture.mp4')..writeAsBytesSync([0, 1, 2]))
          .path;
    });

    // Mock the native video-frames channel: a duration + decodable frames so
    // sampleTimestamps and the timeline thumbnails work without a real decoder.
    const framesChannel = MethodChannel('note_synapse/video_frames');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final framePng = Uint8List.fromList(img.encodePng(
        img.Image(width: 16, height: 12)..clear(img.ColorRgb8(40, 80, 120))));
    messenger.setMockMethodCallHandler(framesChannel, (call) async {
      switch (call.method) {
        case 'getDuration':
          return 1000; // 5 fps → timestamps 0,200,400,600,800
        case 'extractFrame':
          return framePng;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(framesChannel, null));

    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    await resetForTesting();
    getIt.registerSingleton<VideoSource>(FakeVideoSource(null));
    getIt.registerSingleton<FrameCorrection>(OpenCvFrameCorrection());
    // autoComplete models the notification's Stop action: record() resolves
    // with the file on its own, so the whole capture→pipeline chain runs in
    // one real-async window (the in-app Stop button path is covered above).
    getIt.registerSingleton<ScreenCaptureService>(FakeScreenCaptureService(
        resultPath: videoPath, supported: true, autoComplete: true));

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Tap capture → record() resolves with the file → copy + sample + enter
    // timeline, all on the real event loop (file I/O + native channel).
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('wc-screen-capture')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();

    // We left the source picker and landed on the timeline stage (the
    // key-frame controls + review button are unique to it).
    expect(find.byKey(const ValueKey('wc-screen-capture')), findsNothing);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.textContaining('Review clips'), findsOneWidget);

    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}
