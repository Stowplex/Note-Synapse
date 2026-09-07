import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/l10n/app_localizations_en.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/widgets/note_source_card.dart';

final AppLocalizations _l10n = AppLocalizationsEn();

NoteSource _source({
  required String id,
  required String url,
  String? title,
  String? siteName,
  DateTime? clippedAt,
  String kind = NoteSourceKind.web,
}) => NoteSource(
  id: id,
  url: url,
  title: title,
  siteName: siteName,
  clippedAt: clippedAt,
  kind: kind,
  method: NoteSourceMethod.extract,
);

/// Exactly 300 characters, with a deep path.
final String _longUrl =
    'https://example.com/blog/${'very-long-segment/' * 15}slugs';

final DateTime _threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));

final NoteSource _first = _source(
  id: 'a',
  url: 'https://www.example.com/post/123',
  title: 'Post title',
  siteName: 'Example',
  clippedAt: _threeDaysAgo,
);
final NoteSource _second = _source(
  id: 'b',
  url: 'https://news.site/article',
  title: 'Second article',
  clippedAt: _threeDaysAgo,
);
final NoteSource _third = _source(
  id: 'c',
  url: _longUrl,
  title: 'Third with a long link',
);

/// Renders [card] at phone width, top-aligned, inside a localized app;
/// [textScaler] applies to the whole app, menus included.
Future<void> _pump(
  WidgetTester tester,
  Widget card, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: Padding(padding: const EdgeInsets.all(16), child: card),
          ),
        ),
      ),
    ),
  );
}

/// The data of every [Text] currently in the tree.
Iterable<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty);

void main() {
  setUpAll(() {
    expect(_longUrl.length, 300);
  });

  testWidgets('one source: title and meta lines only, no expand control', (
    tester,
  ) async {
    await _pump(
      tester,
      NoteSourceCard(sources: [_first], onOpen: (_) {}, onCopy: (_) {}),
    );

    expect(find.text('Post title'), findsOneWidget);
    expect(find.text('Example · clipped 3d ago'), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(2));
    expect(find.byIcon(Icons.public), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(find.textContaining('more'), findsNothing);
  });

  testWidgets('three sources collapsed: first source plus "+2 more" only', (
    tester,
  ) async {
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second, _third],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );

    expect(find.text('Post title'), findsOneWidget);
    expect(find.text('Example · clipped 3d ago'), findsOneWidget);
    expect(find.text(_l10n.moreSources(2)), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(3));
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.text('Second article'), findsNothing);
    expect(find.text('Third with a long link'), findsNothing);
    expect(find.text(_l10n.showLess), findsNothing);
    // No raw or compact URL while collapsed.
    expect(_texts(tester).where((s) => s.contains('/')), isEmpty);
  });

  testWidgets('"+N more" expands to every source and "Show less" collapses', (
    tester,
  ) async {
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second, _third],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );

    await tester.tap(find.text(_l10n.moreSources(2)));
    await tester.pumpAndSettle();

    expect(find.text('Post title'), findsOneWidget);
    expect(find.text('Second article'), findsOneWidget);
    expect(find.text('Third with a long link'), findsOneWidget);
    expect(find.text(_first.compactUrl), findsOneWidget);
    expect(find.text(_second.compactUrl), findsOneWidget);
    expect(find.text(_third.compactUrl), findsOneWidget);
    expect(find.text(_l10n.showLess), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsNWidgets(3));
    expect(find.text(_l10n.moreSources(2)), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing);

    await tester.tap(find.text(_l10n.showLess));
    await tester.pumpAndSettle();

    expect(find.text(_l10n.moreSources(2)), findsOneWidget);
    expect(find.text('Second article'), findsNothing);
    expect(find.text(_l10n.showLess), findsNothing);
  });

  testWidgets('the chevron expands too', (tester) async {
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    expect(find.text('Second article'), findsOneWidget);
    expect(find.text(_l10n.showLess), findsOneWidget);
  });

  testWidgets(
    'a 300-character URL is absent collapsed and a single line expanded',
    (tester) async {
      await _pump(
        tester,
        NoteSourceCard(
          sources: [_third, _first],
          onOpen: (_) {},
          onCopy: (_) {},
        ),
      );

      expect(find.text(_longUrl), findsNothing);
      expect(_texts(tester).where((s) => s.contains('very-long')), isEmpty);

      await tester.tap(find.text(_l10n.moreSources(1)));
      await tester.pumpAndSettle();

      // Still never the raw URL, only the compact form on one line.
      expect(find.text(_longUrl), findsNothing);
      final urlFinder = find.text(_third.compactUrl);
      expect(urlFinder, findsOneWidget);
      final urlText = tester.widget<Text>(urlFinder);
      expect(urlText.maxLines, 1);
      expect(urlText.overflow, TextOverflow.ellipsis);
      expect(urlText.softWrap, isFalse);
      final lineHeight =
          (urlText.style!.fontSize ?? 12) * (urlText.style!.height ?? 1.5);
      expect(
        tester.getSize(urlFinder).height,
        lessThanOrEqualTo(lineHeight + 1),
        reason: 'the URL line must not wrap',
      );
    },
  );

  testWidgets('tapping the title or the meta line opens the full url', (
    tester,
  ) async {
    final opened = <String>[];
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second],
        onOpen: (s) => opened.add(s.url),
        onCopy: (_) {},
      ),
    );

    await tester.tap(find.text('Post title'));
    await tester.tap(find.text('Example · clipped 3d ago'));
    await tester.pump();

    expect(opened, List.filled(2, 'https://www.example.com/post/123'));
  });

  testWidgets('the "⋯" menu copies the full url and offers edit / remove', (
    tester,
  ) async {
    final copied = <String>[];
    final edited = <String>[];
    final removed = <String>[];
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second, _third],
        onOpen: (_) {},
        onCopy: (s) => copied.add(s.url),
        onEdit: (s) => edited.add(s.id),
        onRemove: (s) => removed.add(s.id),
      ),
    );
    await tester.tap(find.text(_l10n.moreSources(2)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).at(2));
    await tester.pumpAndSettle();
    expect(find.text(_l10n.copyLink), findsOneWidget);
    expect(find.text(_l10n.editSource), findsOneWidget);
    expect(find.text(_l10n.removeSource), findsOneWidget);
    await tester.tap(find.text(_l10n.copyLink));
    await tester.pumpAndSettle();
    expect(copied, [_longUrl]);

    await tester.tap(find.byIcon(Icons.more_horiz).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_l10n.editSource));
    await tester.pumpAndSettle();
    expect(edited, ['b']);

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(_l10n.removeSource));
    await tester.pumpAndSettle();
    expect(removed, ['a']);
  });

  testWidgets('long-press opens the same menu while collapsed', (tester) async {
    final copied = <String>[];
    final opened = <String>[];
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first],
        onOpen: (s) => opened.add(s.url),
        onCopy: (s) => copied.add(s.url),
        onEdit: (_) {},
        onRemove: (_) {},
      ),
    );

    await tester.longPress(find.text('Post title'));
    await tester.pumpAndSettle();

    expect(find.text(_l10n.copyLink), findsOneWidget);
    expect(find.text(_l10n.editSource), findsOneWidget);
    expect(find.text(_l10n.removeSource), findsOneWidget);
    await tester.tap(find.text(_l10n.copyLink));
    await tester.pumpAndSettle();
    expect(copied, ['https://www.example.com/post/123']);
    expect(opened, isEmpty, reason: 'a long-press must not also open');
  });

  testWidgets('compact: no "⋯", and the menu offers only what is wired', (
    tester,
  ) async {
    final copied = <String>[];
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second],
        compact: true,
        onOpen: (_) {},
        onCopy: (s) => copied.add(s.url),
      ),
    );
    await tester.tap(find.text(_l10n.moreSources(1)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(find.text(_second.compactUrl), findsOneWidget);

    await tester.longPress(find.text('Second article'));
    await tester.pumpAndSettle();
    expect(find.text(_l10n.copyLink), findsOneWidget);
    expect(find.text(_l10n.editSource), findsNothing);
    expect(find.text(_l10n.removeSource), findsNothing);
    await tester.tap(find.text(_l10n.copyLink));
    await tester.pumpAndSettle();
    expect(copied, ['https://news.site/article']);
  });

  testWidgets('menu labels ellipsize at a large text scale', (tester) async {
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second],
        onOpen: (_) {},
        onCopy: (_) {},
        onEdit: (_) {},
        onRemove: (_) {},
      ),
      textScaler: const TextScaler.linear(2.0),
    );
    await tester.tap(find.text(_l10n.moreSources(1)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();

    // The popup menu caps its content width; the labels must fit on one
    // ellipsized line instead of overflowing.
    expect(tester.takeException(), isNull);
    for (final label in [
      _l10n.copyLink,
      _l10n.editSource,
      _l10n.removeSource,
    ]) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    }
  });

  testWidgets('shrinking to one source forgets the expansion', (tester) async {
    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );
    await tester.tap(find.text(_l10n.moreSources(1)));
    await tester.pumpAndSettle();
    expect(find.text(_l10n.showLess), findsOneWidget);

    // Same element throughout, so the widget state survives the rebuilds.
    await _pump(
      tester,
      NoteSourceCard(sources: [_first], onOpen: (_) {}, onCopy: (_) {}),
    );
    await tester.pumpAndSettle();
    expect(find.text(_l10n.showLess), findsNothing);

    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_l10n.showLess), findsNothing);
    expect(find.text(_l10n.moreSources(1)), findsOneWidget);
    expect(find.text('Second article'), findsNothing);
  });

  testWidgets('the collapsed card stays within the height budget', (
    tester,
  ) async {
    await _pump(
      tester,
      NoteSourceCard(sources: [_first], onOpen: (_) {}, onCopy: (_) {}),
    );
    final one = tester.getSize(find.byType(NoteSourceCard)).height;
    expect(one, lessThan(60), reason: 'one source is two lines (~56 px)');

    await _pump(
      tester,
      NoteSourceCard(
        sources: [_first, _second, _third],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );
    // Same element as before, so AnimatedSize animates to the new height.
    await tester.pumpAndSettle();
    // Two lines for the first source plus the `+N more` strip, which is a
    // 40 px tap target: about 86 px in all.
    final three = tester.getSize(find.byType(NoteSourceCard)).height;
    expect(three, lessThan(90), reason: 'three lines must stay under 90 px');
    expect(three, greaterThan(one));
  });

  testWidgets('file sources get the file icon; no clip time, no "clipped"', (
    tester,
  ) async {
    await _pump(
      tester,
      NoteSourceCard(
        sources: [
          _source(
            id: 'f',
            url: 'https://cdn.example.com/files/report.pdf',
            title: 'report.pdf',
            kind: NoteSourceKind.file,
          ),
        ],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );

    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
    expect(find.byIcon(Icons.public), findsNothing);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('cdn.example.com'), findsOneWidget);
    expect(find.textContaining('clipped'), findsNothing);
  });

  testWidgets('without a title the host is the title and not repeated', (
    tester,
  ) async {
    await _pump(
      tester,
      NoteSourceCard(
        sources: [
          _source(
            id: 'h',
            url: 'https://blog.example.org/x',
            clippedAt: _threeDaysAgo,
          ),
        ],
        onOpen: (_) {},
        onCopy: (_) {},
      ),
    );

    expect(find.text('blog.example.org'), findsOneWidget);
    expect(find.text(_l10n.clippedRelative('3d ago')), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(2));
  });
}
