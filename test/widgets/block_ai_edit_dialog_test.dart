import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/widgets/block_ai_edit_dialog.dart';

void main() {
  Widget buildTestApp({required Function(String?) onResult}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              final result = await BlockAIEditDialog.show(context);
              onResult(result);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
  }

  testWidgets('cancel returns null', (tester) async {
    String? result = 'not-null';
    await tester.pumpWidget(buildTestApp(onResult: (r) => result = r));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Dialog should be visible
    expect(find.text('AI Edit Block'), findsOneWidget);

    // Tap Cancel
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('submit returns instruction text', (tester) async {
    String? result;
    await tester.pumpWidget(buildTestApp(onResult: (r) => result = r));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Enter text and submit
    await tester.enterText(find.byType(TextField), 'Make it shorter');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(result, equals('Make it shorter'));
  });

  testWidgets('submit with empty text does nothing', (tester) async {
    String? result = 'not-null';
    await tester.pumpWidget(buildTestApp(onResult: (r) => result = r));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Submit with empty text
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Dialog should still be open
    expect(find.text('AI Edit Block'), findsOneWidget);
    expect(result, equals('not-null'));
  });
}
