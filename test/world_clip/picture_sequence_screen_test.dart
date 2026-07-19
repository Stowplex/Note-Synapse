import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/picture_sequence_screen.dart';

Widget _localized(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  // The `camera` plugin's platform channel isn't mocked in host widget tests —
  // `initialize()` never resolves here, so these tests only pump a bounded
  // number of frames rather than pumpAndSettle (which would hang forever on
  // both the pending future and the indeterminate spinner).
  testWidgets(
      'renders the loading state without crashing while the camera initializes',
      (tester) async {
    await tester.pumpWidget(_localized(PictureSequenceScreen()));
    await tester.pump();

    expect(find.text('Picture sequence'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('ps-shutter')), findsNothing);

    // The flash toggle is in the (always-built) AppBar, but disabled until
    // the camera exists to apply it to — nothing to flash on yet.
    final flashButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('ps-flash-toggle')),
    );
    expect(flashButton.onPressed, isNull);
    expect(find.byIcon(Icons.flash_off), findsOneWidget);
  });

  testWidgets(
      'cancel with no captured pages pops immediately (no confirmation)',
      (tester) async {
    await tester.pumpWidget(
      _localized(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  final result = await Navigator.of(context).push<Object?>(
                    MaterialPageRoute(builder: (_) => PictureSequenceScreen()),
                  );
                  expect(result, isNull);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // push transition

    await tester.tap(find.byKey(const ValueKey('ps-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000)); // pop transition

    expect(find.text('Picture sequence'), findsNothing);
    expect(find.text('open'), findsOneWidget); // back on the launcher screen
  });
}
