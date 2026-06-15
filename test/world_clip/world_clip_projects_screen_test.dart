import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_projects_screen.dart';
import 'package:note_synapse/services/world_clip/clip_project_store.dart';

void main() {
  testWidgets('shows empty state when no projects', (tester) async {
    // The screen + store use real dart:io, which only resolves on the real
    // event loop — wrap all I/O (and the load triggered by initState) in
    // tester.runAsync, otherwise it hangs under fake-async test time.
    late Directory tmp;
    late ClipProjectStore store;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('wc_projects');
      store = ClipProjectStore(Directory('${tmp.path}/world_clip'));
    });

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipProjectsScreen(store: store),
    ));
    // Let initState's listAll() complete on the real loop, then render it.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('No saved World Clip projects'), findsOneWidget);

    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}
