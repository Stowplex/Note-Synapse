import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/main.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/screens/onboarding/welcome_screen.dart';
import 'package:note_synapse/screens/onboarding/license_screen.dart';
import 'package:note_synapse/screens/onboarding/privacy_screen.dart';
import 'package:note_synapse/screens/model_selection_screen.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:note_synapse/l10n/app_localizations.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    setupServiceLocator();
  });

  testWidgets('Onboarding flow navigation', (WidgetTester tester) async {
    // Build the WelcomeScreen directly since we can't easily mock the entire AppWrapper/Providers complexity here
    // without extensive setup. Testing the individual flow is sufficient.

    // We need a provider for localization switching
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider(create: (_) => AppProvider())],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: [Locale('en', ''), Locale('zh', '')],
          home: WelcomeScreen(),
        ),
      ),
    );

    // Verify Welcome Screen
    expect(find.text('Welcome to Note Synapse'), findsOneWidget);
    expect(find.text('Get Started'), findsOneWidget);

    // Tap Start
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();

    // Verify License Screen
    expect(find.text('License Agreement'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    // Tap Next
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // Verify Privacy Screen
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Accept & Continue'), findsOneWidget);

    // Tap Accept
    await tester.tap(find.text('Accept & Continue'));
    await tester.pumpAndSettle();

    // Verify Model Selection Screen (triggered by navigation)
    // Note: ModelSelectionScreen depends on getIt and services which might crash if not fully mocked.
    // Ideally we stop here or mock ModelSelectionScreen.
    // But since we pushed it, we check if we are on it.
    // The previous test logic might fail if ModelSelectionScreen crashes on init.
    // Let's rely on finding the widget type.
    expect(find.byType(ModelSelectionScreen), findsOneWidget);
  });
}
