import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_flow_screen.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/world_clip/screen_capture_service.dart';

void main() {
  testWidgets('shows both import actions on the first stage', (tester) async {
    // The source stage reads ScreenCaptureService.isSupported during build;
    // a false backend keeps this focused on the two gallery-import actions.
    await resetForTesting();
    getIt.registerSingleton<ScreenCaptureService>(
        FakeScreenCaptureService(supported: false));

    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipFlowScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(WorldClipFlowScreen), findsOneWidget);
    expect(find.byIcon(Icons.video_library), findsOneWidget); // Import video
    expect(find.byIcon(Icons.photo_library), findsOneWidget); // Import pictures
  });
}
