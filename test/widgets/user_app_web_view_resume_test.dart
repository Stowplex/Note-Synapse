import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/app_revision.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/user_app_runtime_bridge.dart';
import 'package:note_synapse/utils/global_keys.dart';
import 'package:note_synapse/widgets/user_app_web_view.dart';
import 'package:provider/provider.dart';

import '../services/user_app_runtime_bridge_test.mocks.dart';

/// End-to-end wiring: popping a page above a UserAppWebView dispatches
/// `synapse:resumed` into its bridge's WebView. The platform WebView itself is
/// never built: the selected note's sources never finish loading, so the view
/// stays on its placeholder while the bridge and the route listener are live.
void main() {
  setUp(() async {
    await resetForTesting();
    appRouteObserver.resetForTesting();
  });

  testWidgets('popping a page above the app dispatches synapse:resumed', (
    tester,
  ) async {
    final provider = MockAppProvider();
    final controller = MockInAppWebViewController();
    when(provider.locale).thenReturn(const Locale('en', 'US'));
    when(provider.isDarkMode).thenReturn(false);
    final pendingSources = Completer<List<NoteSource>>();
    when(provider.getNoteSources(any)).thenAnswer((_) => pendingSources.future);

    final now = DateTime(2026, 9, 26);
    UserAppRuntimeBridge? bridge;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [appRouteObserver],
          home: Scaffold(
            body: UserAppWebView(
              app: UserApp(
                id: 'app-1',
                uuid: 'uuid-1',
                name: 'App',
                description: '',
                steps: const [],
                htmlContent: '',
                createdAt: now,
                updatedAt: now,
              ),
              revision: AppRevision(
                id: 'rev-1',
                appId: 'app-1',
                revisionNumber: 1,
                revisionTimestamp: now,
                userPrompt: '',
                aiResponse: '',
                appCode: '<html></html>',
              ),
              selectedNotes: [
                Note(
                  id: 'n1',
                  title: 'N',
                  content: '',
                  type: NoteType.note,
                  createdAt: now,
                  updatedAt: now,
                ),
              ],
              sourceLabel: 'App: App',
              onBridgeReady: (b) => bridge = b,
            ),
          ),
        ),
      ),
    );
    expect(bridge, isNotNull);

    // Stand in for the WebView: attach the controller and finish a load.
    bridge!.registerJavaScriptHandlers(controller);
    bridge!.buildBootstrapScript();
    bridge!.pageDidStartLoading();
    await bridge!.pageDidFinishLoading();
    clearInteractions(controller);

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('note')),
    );
    await tester.pumpAndSettle();
    verifyNever(controller.evaluateJavascript(source: anyNamed('source')));

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    final scripts = verify(
      controller.evaluateJavascript(source: captureAnyNamed('source')),
    ).captured.cast<String>();
    expect(scripts, hasLength(1));
    expect(scripts.single, contains("new CustomEvent('synapse:resumed')"));
  });
}
