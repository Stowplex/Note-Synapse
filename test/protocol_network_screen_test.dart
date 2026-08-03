import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/protocol_exchange.dart';
import 'package:note_synapse/screens/settings/protocol_network_screen.dart';
import 'package:note_synapse/services/protocol_study/protocol_capture_controller.dart';
import 'package:note_synapse/services/web_session_service.dart';

void main() {
  ProtocolExchange exchange() => ProtocolExchange(
    id: 'exchange-1',
    pageInstanceId: 'page-1',
    sequence: 1,
    source: ProtocolRequestSource.fetch,
    method: 'POST',
    url: 'https://shop.example/checkout',
    startedAt: DateTime.parse('2026-08-02T12:00:00Z'),
    status: 200,
    requestHeaders: const [
      ProtocolField(
        id: 'auth',
        location: ProtocolFieldLocation.requestHeader,
        name: 'Authorization',
        value: 'Bearer locally-visible-token',
      ),
    ],
    queryFields: const [],
    requestBody: const ProtocolBody(
      text: 'card_number=4111111111111111',
      mimeType: 'application/x-www-form-urlencoded',
    ),
    responseHeaders: const [],
    responseBody: const ProtocolBody(
      text: '{"ok":true}',
      mimeType: 'application/json',
      omittedReason: 'response_capture_partial',
    ),
    captureIssues: const ['response_capture_partial'],
    mutatesState: true,
    selected: true,
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProtocolNetworkScreen(
          controller: ProtocolCaptureController.fromExchanges(
            exchanges: [exchange()],
          ),
          webSessions: WebSessionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('raw inspector keeps sensitive local values visible', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(find.textContaining('partial'), findsOneWidget);
    await tester.tap(find.byTooltip('View raw request and response'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Bearer locally-visible-token'), findsOneWidget);
    expect(find.textContaining('4111111111111111'), findsOneWidget);
    expect(find.textContaining('response_capture_partial'), findsOneWidget);
  });

  testWidgets('warns before replaying a mutating request', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Run minimal repro'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This request may mutate website state. Run the minimal repro anyway?',
      ),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Continue'), findsNothing);
  });
}
