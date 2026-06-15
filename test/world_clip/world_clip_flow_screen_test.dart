import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_flow_screen.dart';

void main() {
  testWidgets('shows the import action on first stage', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipFlowScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(WorldClipFlowScreen), findsOneWidget);
    expect(find.byIcon(Icons.video_library), findsOneWidget);
  });
}
