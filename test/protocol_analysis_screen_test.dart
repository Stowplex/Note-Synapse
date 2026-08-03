import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/models/protocol_exchange.dart';
import 'package:note_synapse/models/protocol_study.dart';
import 'package:note_synapse/screens/settings/protocol_analysis_screen.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/protocol_study/protocol_capture_controller.dart';
import 'package:note_synapse/services/protocol_study/protocol_study_workspace.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    await resetForTesting();
    final model = ModelConfig(
      id: 'local-model',
      type: ModelType.localMnn,
      displayName: 'Small local model',
      isConfigured: true,
      maxInputTokens: 16384,
    );
    SharedPreferences.setMockInitialValues({
      'configured_models': jsonEncode([model.toJson()]),
    });
    getIt.registerSingleton<ModelStorageService>(ModelStorageService());
  });

  tearDown(() => resetForTesting());

  testWidgets('local user can exclude a field from the model preview', (
    tester,
  ) async {
    final exchange = ProtocolExchange(
      id: 'exchange-1',
      pageInstanceId: 'page-1',
      sequence: 1,
      source: ProtocolRequestSource.fetch,
      method: 'GET',
      url: 'https://example.test/data',
      startedAt: DateTime.parse('2026-08-02T12:00:00Z'),
      requestHeaders: const [
        ProtocolField(
          id: 'analytics-header',
          location: ProtocolFieldLocation.requestHeader,
          name: 'X-Analytics-Debug',
          value: 'unneeded-analytics-value',
        ),
      ],
      queryFields: const [],
      responseHeaders: const [],
      selected: true,
    );
    final controller = ProtocolCaptureController.fromExchanges(
      exchanges: [exchange],
    );
    addTearDown(controller.dispose);
    final timestamp = DateTime.parse('2026-08-02T12:00:00Z');
    final study = ProtocolStudy(
      id: 'study-1',
      title: 'Study',
      startUrl: 'https://example.test',
      createdAt: timestamp,
      updatedAt: timestamp,
      sessionProvenance: ProtocolSessionProvenance.noSavedLogin,
      limits: const ProtocolCaptureLimits(),
      exchanges: [exchange],
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProtocolAnalysisScreen(
          study: study,
          controller: controller,
          workspace: ProtocolStudyWorkspace(
            rootProvider: () async => Directory.systemTemp,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(
      CheckboxListTile,
      'requestHeader: X-Analytics-Debug',
    );
    expect(tile, findsOneWidget);
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(Checkbox)),
    );
    await tester.pump();
    await tester.tap(find.text('Analyze with this model'));
    await tester.pumpAndSettle();

    final payload = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data ?? '')
        .join('\n');
    expect(payload, isNot(contains('unneeded-analytics-value')));
    expect(find.text('1 excluded fields'), findsOneWidget);
  });
}
