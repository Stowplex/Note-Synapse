import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/protocol_study.dart';
import 'package:note_synapse/screens/settings/protocol_studies_screen.dart';
import 'package:note_synapse/services/protocol_study/protocol_study_workspace.dart';
import 'package:note_synapse/services/web_session_service.dart';

class _FakeWorkspace extends ProtocolStudyWorkspace {
  _FakeWorkspace(this.studies);

  final List<ProtocolStudy> studies;

  @override
  Future<List<ProtocolStudy>> listStudies() async => List.of(studies);

  @override
  Future<void> delete(String id) async {
    studies.removeWhere((study) => study.id == id);
  }
}

void main() {
  testWidgets('refresh after a workspace change is synchronous', (
    tester,
  ) async {
    final study = ProtocolStudy(
      id: 'new-study',
      title: 'New study',
      startUrl: 'https://example.test',
      createdAt: DateTime.parse('2026-08-02T12:00:00Z'),
      updatedAt: DateTime.parse('2026-08-02T12:00:00Z'),
      sessionProvenance: ProtocolSessionProvenance.noSavedLogin,
      limits: const ProtocolCaptureLimits(),
      exchanges: const [],
    );
    final workspace = _FakeWorkspace([study]);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProtocolStudiesScreen(
          webSessions: WebSessionService(),
          workspace: workspace,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New study'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('New study'), findsNothing);
  });
}
