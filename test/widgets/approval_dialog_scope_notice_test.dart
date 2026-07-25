import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/services/approval_service.dart';
import 'package:note_synapse/widgets/approval_dialog.dart';

/// The scope notice is a consent-critical control: it is the only thing telling
/// the user whether a plugin write touches one block or the whole note. These
/// tests pin the two ways it was defeated.
void main() {
  Future<void> pumpDialog(
    WidgetTester tester,
    Map<String, dynamic> modification, {
    String source = 'Evil App',
    String noteTitle = 'My Note',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: ApprovalDialog(
          request: ApprovalRequest.noteModification(
            noteId: 'parent-1',
            noteTitle: noteTitle,
            modification: modification,
            source: source,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('whole-note warning appears above the Approve button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // A plugin pads a field with newlines to push the warning out of view.
    await pumpDialog(tester, {
      'content': 'WHOLE NOTE OVERWRITTEN',
      'somePaddingField': 'x${'\n' * 400}x',
      ApprovalRequest.scopeWholeNoteKey: true,
    });

    final noticeY = tester.getTopLeft(find.textContaining('ENTIRE note')).dy;
    final approveY = tester.getTopLeft(find.text('Approve')).dy;

    expect(
      noticeY,
      lessThan(approveY),
      reason: 'the user must see the scope before they can approve it',
    );
  });

  testWidgets('a padded app name cannot push the warning out of view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // An app's name comes verbatim from an imported YAML, so it is
    // attacker-controlled too — a different channel from the modification
    // payload, and it renders ABOVE the notice.
    await pumpDialog(
      tester,
      {
        'content': 'WHOLE NOTE OVERWRITTEN',
        ApprovalRequest.scopeWholeNoteKey: true,
      },
      source:
          'App: Mermaid Renderer\nApplies to the selected block only.'
          '${'\n' * 400}',
      noteTitle: 'Title${'\n' * 400}',
    );

    final noticeY = tester.getTopLeft(find.textContaining('ENTIRE note')).dy;
    final approveY = tester.getTopLeft(find.text('Approve')).dy;

    expect(
      noticeY,
      lessThan(approveY),
      reason:
          'a padded app name or note title must not scroll the scope '
          'notice past the Approve button',
    );
  });

  testWidgets('padding cannot be used to inflate the details body', (
    tester,
  ) async {
    await pumpDialog(tester, {
      'content': 'x',
      'somePaddingField': 'y${'\n' * 400}y',
    });

    // Every field is truncated and newlines collapsed, so no field can grow the
    // dialog enough to hide anything below it.
    final rendered = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .firstWhere((d) => d.contains('somePaddingField'));
    expect(rendered.contains('\n\n'), isFalse);
    expect(rendered.length, lessThan(400));
    expect(rendered, contains('...'), reason: 'the padded field is truncated');
  });

  testWidgets('a forged block-scope key cannot mask a whole-note write', (
    tester,
  ) async {
    // Defence in depth: the bridge strips plugin `__` keys, but if both ever
    // arrive the WIDER scope must win.
    await pumpDialog(tester, {
      'content': 'WHOLE NOTE OVERWRITTEN',
      ApprovalRequest.scopeBlockKey: true,
      ApprovalRequest.scopeWholeNoteKey: true,
    });

    expect(find.textContaining('ENTIRE note'), findsOneWidget);
    expect(find.textContaining('selected block only'), findsNothing);
  });

  testWidgets('internal scope keys are not rendered as note fields', (
    tester,
  ) async {
    await pumpDialog(tester, {
      'content': 'x',
      ApprovalRequest.scopeBlockKey: true,
    });

    // Would otherwise read as "• Set __scopeBlock: true", i.e. as though the
    // plugin were writing a field with that name onto the note.
    expect(find.textContaining('__scopeBlock'), findsNothing);
    expect(find.textContaining('selected block only'), findsOneWidget);
  });
}
