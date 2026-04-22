import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/widgets/app_embed_picker_sheet.dart';

class _StubAppProvider extends AppProvider {
  _StubAppProvider(this._apps);
  final List<UserApp> _apps;
  @override
  List<UserApp> get userApps => _apps;
}

UserApp _app({
  required String id,
  required String uuid,
  required String name,
  UserAppType type = UserAppType.normal,
  String description = '',
}) {
  final now = DateTime.utc(2024, 1, 1);
  return UserApp(
    id: id,
    uuid: uuid,
    name: name,
    description: description,
    steps: const [],
    htmlContent: '',
    type: type,
    createdAt: now,
    updatedAt: now,
  );
}

Future<Future<AppEmbedInsertion?>> _launch(
  WidgetTester tester, {
  required AppProvider provider,
}) async {
  Future<AppEmbedInsertion?>? pending;
  await tester.pumpWidget(
    ChangeNotifierProvider<AppProvider>.value(
      value: provider,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = AppEmbedPickerSheet.show(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return pending ?? Future.value(null);
}

void main() {
  final normalApp = _app(
    id: 'id-1',
    uuid: 'uuid-normal',
    name: 'Knowledge Graph',
    description: 'Visualise notes',
  );
  final actionApp = _app(
    id: 'id-2',
    uuid: 'uuid-action',
    name: 'Action App',
    type: UserAppType.noteAction,
  );
  final aiToolApp = _app(
    id: 'id-3',
    uuid: 'uuid-ai',
    name: 'AI Tool',
    type: UserAppType.aiTool,
  );

  testWidgets('default filter shows only normal apps', (tester) async {
    final provider = _StubAppProvider([normalApp, actionApp, aiToolApp]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => AppEmbedPickerSheet.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Knowledge Graph'), findsOneWidget);
    expect(find.text('Action App'), findsNothing);
    expect(find.text('AI Tool'), findsNothing);

    // Toggle "include all types"
    await tester.tap(find.text('Include note-action & AI-tool apps'));
    await tester.pumpAndSettle();
    expect(find.text('Action App'), findsOneWidget);
    expect(find.text('AI Tool'), findsOneWidget);
  });

  testWidgets(
      'default insert returns inline embed with current-note param',
      (tester) async {
    final provider = _StubAppProvider([normalApp]);
    final result = await _launch(tester, provider: provider);
    // Dialog is now open; tap the app tile.
    await tester.tap(find.text('Knowledge Graph'));
    await tester.pumpAndSettle();
    // Configure step: default medium, pass current note on, advanced off.
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    final insertion = await result;
    expect(insertion, isNotNull);
    expect(
      insertion!.markdown,
      '\n@[480x300](synapseresource://app/uuid-normal?note=current)\n\n',
    );
    expect(insertion.selectionOffset, 0);
  });

  testWidgets('toggling pass-current-note strips the query string',
      (tester) async {
    final provider = _StubAppProvider([normalApp]);
    final result = await _launch(tester, provider: provider);
    await tester.tap(find.text('Knowledge Graph'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pass current note to app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    final insertion = await result;
    expect(
      insertion!.markdown,
      '\n@[480x300](synapseresource://app/uuid-normal)\n\n',
    );
  });

  testWidgets('small size preset produces 320x200', (tester) async {
    final provider = _StubAppProvider([normalApp]);
    final result = await _launch(tester, provider: provider);
    await tester.tap(find.text('Knowledge Graph'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Small (320×200)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    final insertion = await result;
    expect(insertion!.markdown.startsWith('\n@[320x200]('), isTrue);
  });

  testWidgets('custom size uses user-supplied dimensions', (tester) async {
    final provider = _StubAppProvider([normalApp]);
    final result = await _launch(tester, provider: provider);
    await tester.tap(find.text('Knowledge Graph'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Width'), '700');
    await tester.enterText(find.widgetWithText(TextField, 'Height'), '450');
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    final insertion = await result;
    expect(insertion!.markdown.startsWith('\n@[700x450]('), isTrue);
  });

  testWidgets('advanced toggle produces fenced synapse-app block',
      (tester) async {
    final provider = _StubAppProvider([normalApp]);
    final result = await _launch(tester, provider: provider);
    await tester.tap(find.text('Knowledge Graph'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced: generate fenced block'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    final insertion = await result;
    expect(
      insertion!.markdown,
      contains('```synapse-app'),
    );
    expect(insertion.markdown, contains('app: uuid-normal'));
    expect(insertion.markdown, contains('width: 480'));
    expect(insertion.markdown, contains('notes: [current]'));
    expect(insertion.markdown, contains('params:'));
    // Caret should land on the params-comment line.
    expect(insertion.selectionOffset, greaterThan(0));
    final caretArea = insertion.markdown.substring(
      insertion.selectionOffset,
      insertion.selectionOffset + 2,
    );
    expect(caretArea, '  ');
  });
}
