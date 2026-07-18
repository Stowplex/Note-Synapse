import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_flow_screen.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/world_clip/screen_capture_service.dart';

Widget _app() => const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipFlowScreen(),
    );

void main() {
  setUp(() async {
    // The source stage reads ScreenCaptureService.isSupported during build;
    // a false backend keeps these focused on the import/capture actions.
    await resetForTesting();
    getIt.registerSingleton<ScreenCaptureService>(
        FakeScreenCaptureService(supported: false));
  });

  testWidgets('shows the import and picture-sequence actions on the first stage',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byType(WorldClipFlowScreen), findsOneWidget);
    expect(find.byIcon(Icons.video_library), findsOneWidget); // Import video
    expect(find.byIcon(Icons.photo_library), findsOneWidget); // Import pictures
    // Picture Sequence: repeated in-app still captures (optionally
    // anti-glare-fused) alongside the gallery import modes.
    expect(find.byKey(const ValueKey('wc-picture-sequence')), findsOneWidget);
  });

  testWidgets(
      'Picture Sequence opens its own screen and returns to the source stage on cancel',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // PictureSequenceScreen's camera never finishes initializing in a host
    // widget test (no platform channel mocked) — pump a bounded number of
    // frames for the route transitions instead of pumpAndSettle, which would
    // hang on the indeterminate loading spinner.
    await tester.tap(find.byKey(const ValueKey('wc-picture-sequence')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The capture screen is up (its cancel button exists; the source stage's
    // buttons are gone beneath the opaque route).
    expect(find.byKey(const ValueKey('ps-cancel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ps-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    // Cancelling with no captured pages pops null — back to the source
    // stage, no project created.
    expect(find.byKey(const ValueKey('wc-picture-sequence')), findsOneWidget);
  });
}
