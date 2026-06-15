import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/clip_review_screen.dart';

void main() {
  final png = Uint8List.fromList(const [
    137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,
    144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,0,0,3,0,1,169,
    118,218,141,0,0,0,0,73,69,78,68,174,66,96,130
  ]);

  testWidgets('shows a tile per page and a compile button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ClipReviewScreen(
          pages: [png, png],
          onReorder: (a, b) {},
          onRemove: (i) {},
          onCompilePdf: () {},
          onCompileImages: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byKey(const ValueKey('wc-compile')), findsOneWidget);
  });
}
