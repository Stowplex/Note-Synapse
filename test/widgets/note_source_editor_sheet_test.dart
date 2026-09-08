import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/l10n/app_localizations_en.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/widgets/note_source_editor_sheet.dart';

final AppLocalizations _l10n = AppLocalizationsEn();

/// Opens the sheet from a button and returns its (still pending) result.
Future<Future<NoteSourceEditorResult?>> _open(
  WidgetTester tester, {
  NoteSource? existing,
  NoteSourceDuplicateCheck? isDuplicate,
}) async {
  Future<NoteSourceEditorResult?>? pending;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                pending = NoteSourceEditorSheet.show(
                  context,
                  existing: existing,
                  isDuplicate: isDuplicate,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return pending!;
}

Finder _field(String label) => find.widgetWithText(TextField, label);

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, _l10n.save));
  await tester.pumpAndSettle();
}

void main() {
  group('normalizeUrl', () {
    test('accepts http(s) with a host, prefixing https when no scheme', () {
      expect(
        NoteSourceEditorSheet.normalizeUrl('  https://example.com/a?b=1 '),
        'https://example.com/a?b=1',
      );
      expect(
        NoteSourceEditorSheet.normalizeUrl('http://example.com'),
        'http://example.com',
      );
      expect(
        NoteSourceEditorSheet.normalizeUrl('example.com/post'),
        'https://example.com/post',
      );
    });

    test('rejects blanks, whitespace, other schemes and a missing host', () {
      expect(NoteSourceEditorSheet.normalizeUrl(''), isNull);
      expect(NoteSourceEditorSheet.normalizeUrl('   '), isNull);
      expect(NoteSourceEditorSheet.normalizeUrl('not a url'), isNull);
      expect(NoteSourceEditorSheet.normalizeUrl('ftp://files.example'), isNull);
      expect(NoteSourceEditorSheet.normalizeUrl('javascript:alert(1)'), isNull);
      expect(NoteSourceEditorSheet.normalizeUrl('mailto:a@b.c'), isNull);
      expect(NoteSourceEditorSheet.normalizeUrl('https://'), isNull);
    });

    test('lowercases the scheme and host, not the path or query', () {
      expect(
        NoteSourceEditorSheet.normalizeUrl('HTTP://Example.com/X'),
        'http://example.com/X',
      );
      expect(
        NoteSourceEditorSheet.normalizeUrl('Example.COM/Path?Q=A#Frag'),
        'https://example.com/Path?Q=A#Frag',
      );
      expect(
        NoteSourceEditorSheet.normalizeUrl('https://User@Example.com:8443/X'),
        'https://User@example.com:8443/X',
      );
    });

    test('a bare host with a port is not taken for a scheme', () {
      expect(
        NoteSourceEditorSheet.normalizeUrl('example.com:8080/x'),
        'https://example.com:8080/x',
      );
      expect(
        NoteSourceEditorSheet.normalizeUrl('foo.bar://x'),
        isNull,
        reason: 'a dotted scheme with :// is a scheme, not a bare host',
      );
      expect(
        NoteSourceEditorSheet.normalizeUrl('Example.com:8080'),
        'https://example.com:8080',
      );
    });
  });

  testWidgets('an invalid URL blocks saving and shows the message', (
    tester,
  ) async {
    final pending = await _open(tester);
    var completed = false;
    pending.whenComplete(() => completed = true);

    await tester.enterText(_field(_l10n.url), 'not a url');
    await _save(tester);

    expect(find.text(_l10n.invalidUrl), findsOneWidget);
    expect(find.byType(NoteSourceEditorSheet), findsOneWidget);
    expect(completed, isFalse);

    // The message clears as soon as the field changes.
    await tester.enterText(_field(_l10n.url), 'ftp://files.example.com/a');
    await tester.pump();
    expect(find.text(_l10n.invalidUrl), findsNothing);
    await _save(tester);
    expect(find.text(_l10n.invalidUrl), findsOneWidget);
    expect(completed, isFalse);
  });

  testWidgets('valid input returns a manual source clipped now', (
    tester,
  ) async {
    final pending = await _open(tester);
    expect(find.text(_l10n.addSource), findsOneWidget);
    expect(find.text(_l10n.remove), findsNothing);

    final before = DateTime.now();
    await tester.enterText(_field(_l10n.url), 'https://example.com/post');
    await tester.enterText(_field(_l10n.title), 'Post');
    await tester.enterText(_field(_l10n.sourceSiteName), 'Example');
    await _save(tester);

    final result = await pending;
    expect(find.byType(NoteSourceEditorSheet), findsNothing);
    expect(result, isNotNull);
    expect(result!.removed, isFalse);
    final source = result.source!;
    expect(source.url, 'https://example.com/post');
    expect(source.title, 'Post');
    expect(source.siteName, 'Example');
    expect(source.method, NoteSourceMethod.manual);
    expect(source.kind, NoteSourceKind.web);
    expect(source.clippedAt, isNotNull);
    expect(source.clippedAt!.isBefore(before), isFalse);
  });

  testWidgets('a scheme-less URL is stored as https', (tester) async {
    final pending = await _open(tester);
    await tester.enterText(_field(_l10n.url), 'example.com/x');
    await _save(tester);
    expect((await pending)!.source!.url, 'https://example.com/x');
  });

  testWidgets(
    'editing keeps id and untouched fields; a cleared title is gone',
    (tester) async {
      final clippedAt = DateTime.utc(2026, 9, 1, 12);
      final existing = NoteSource(
        id: 'src-1',
        url: 'https://example.com/old',
        title: 'Old title',
        siteName: 'Example',
        byline: 'Jane Doe',
        clippedAt: clippedAt,
        method: NoteSourceMethod.extract,
      );
      final pending = await _open(tester, existing: existing);
      expect(find.text(_l10n.editSource), findsOneWidget);
      expect(find.text('Old title'), findsOneWidget);

      await tester.enterText(_field(_l10n.title), '');
      await _save(tester);

      final source = (await pending)!.source!;
      expect(source.id, 'src-1');
      expect(source.url, 'https://example.com/old');
      expect(source.title, isNull);
      expect(source.siteName, 'Example');
      expect(source.byline, 'Jane Doe');
      expect(source.clippedAt, clippedAt);
      expect(source.method, NoteSourceMethod.extract);
    },
  );

  testWidgets('the duplicate check keeps the sheet open with a message', (
    tester,
  ) async {
    final asked = <String>[];
    final pending = await _open(
      tester,
      isDuplicate: (candidate) async {
        asked.add(candidate.url);
        return candidate.url == 'https://example.com/dup';
      },
    );
    var completed = false;
    pending.whenComplete(() => completed = true);

    await tester.enterText(_field(_l10n.url), 'https://example.com/dup');
    await _save(tester);
    expect(find.text(_l10n.duplicateSourceUrl), findsOneWidget);
    expect(find.byType(NoteSourceEditorSheet), findsOneWidget);
    expect(completed, isFalse);

    await tester.enterText(_field(_l10n.url), 'https://example.com/new');
    await _save(tester);
    expect(asked, ['https://example.com/dup', 'https://example.com/new']);
    expect((await pending)!.source!.url, 'https://example.com/new');
  });

  testWidgets(
    'a second submit while the duplicate check is pending is ignored',
    (tester) async {
      final gate = Completer<bool>();
      var asked = 0;
      final pending = await _open(
        tester,
        isDuplicate: (_) {
          asked++;
          return gate.future;
        },
      );
      var completions = 0;
      pending.whenComplete(() => completions++);

      await tester.enterText(_field(_l10n.url), 'https://example.com/x');
      await tester.tap(find.text(_l10n.save));
      await tester.pump();
      expect(asked, 1);

      // Submitting the Site-name field while the check is pending must not
      // start a second save.
      await tester.tap(_field(_l10n.sourceSiteName));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(asked, 1);

      gate.complete(false);
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(completions, 1);
      expect((await pending)!.source!.url, 'https://example.com/x');
    },
  );

  testWidgets('Remove while editing returns the remove signal', (tester) async {
    final existing = NoteSource(
      id: 'src-2',
      url: 'https://example.com/old',
      method: NoteSourceMethod.manual,
    );
    final pending = await _open(tester, existing: existing);

    await tester.tap(find.widgetWithText(TextButton, _l10n.remove));
    await tester.pumpAndSettle();

    final result = await pending;
    expect(result!.removed, isTrue);
    expect(result.source, isNull);
  });

  testWidgets('Cancel returns nothing', (tester) async {
    final pending = await _open(tester);
    await tester.tap(find.widgetWithText(TextButton, _l10n.cancel));
    await tester.pumpAndSettle();
    expect(await pending, isNull);
  });
}
