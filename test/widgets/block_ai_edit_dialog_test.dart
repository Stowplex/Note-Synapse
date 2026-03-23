import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/widgets/block_ai_edit_dialog.dart';

void main() {
  Widget buildTestApp({
    required Function(String?) onResult,
    AIEditCallback? onTransform,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              final result = await BlockAIEditDialog.show(
                context,
                onTransform: onTransform ?? (instruction) async => 'transformed: $instruction',
              );
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

    expect(find.text('AI Edit Block'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('submit calls onTransform and returns result', (tester) async {
    String? result;
    await tester.pumpWidget(buildTestApp(
      onResult: (r) => result = r,
      onTransform: (instruction) async => 'AI result for: $instruction',
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Make it shorter');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(result, equals('AI result for: Make it shorter'));
  });

  testWidgets('submit with empty text does nothing', (tester) async {
    String? result = 'not-null';
    await tester.pumpWidget(buildTestApp(onResult: (r) => result = r));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('AI Edit Block'), findsOneWidget);
    expect(result, equals('not-null'));
  });

  testWidgets('shows loading state during transform', (tester) async {
    final completer = Completer<String>();
    await tester.pumpWidget(buildTestApp(
      onResult: (_) {},
      onTransform: (_) => completer.future,
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'test');
    await tester.tap(find.text('Send'));
    await tester.pump();

    // Should show spinner, text field should be disabled
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.enabled, isFalse);

    // Complete the future
    completer.complete('done');
    await tester.pumpAndSettle();
  });

  testWidgets('shows error on transform failure', (tester) async {
    await tester.pumpWidget(buildTestApp(
      onResult: (_) {},
      onTransform: (_) async => throw Exception('API error'),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'test');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Should show error text, dialog still open
    expect(find.textContaining('API error'), findsOneWidget);
    expect(find.text('AI Edit Block'), findsOneWidget);
  });
}
