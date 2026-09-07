import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/l10n/app_localizations_en.dart';
import 'package:note_synapse/l10n/app_localizations_zh.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/share_service.dart';
import 'package:note_synapse/utils/file_utils.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

// Reuse the DatabaseService mock generated for the source service tests.
import 'note_source_service_test.mocks.dart';

class _MockPathProviderPlatform extends PathProviderPlatform {
  _MockPathProviderPlatform(this.tempPath);

  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

/// Export and copy read a note's sources through a real [AppProvider] over a
/// mocked database, since cached [Note] objects never carry metadata.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const noteId = 'n1';
  final note = Note(
    id: noteId,
    title: 'Clipped',
    content: 'Body text.',
    type: NoteType.note,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 2),
    tags: const ['a', 'b'],
  );

  final titled = NoteSource(
    id: 's1',
    url: 'https://example.com/post/123',
    title: 'Post title',
    siteName: 'Example',
    method: NoteSourceMethod.extract,
    clippedAt: DateTime.utc(2026, 9, 6, 17, 4, 11),
  );
  final untitled = NoteSource(
    id: 's2',
    url: 'https://www.example.com/x',
    method: NoteSourceMethod.manual,
  );

  late MockDatabaseService mockDb;
  late AppProvider appProvider;
  late Directory tempDir;

  void stored(List<NoteSource> sources) =>
      when(mockDb.getNoteMetadata(noteId)).thenAnswer(
        (_) async => {'sources': sources.map((s) => s.toJson()).toList()},
      );

  setUp(() async {
    mockDb = MockDatabaseService();
    appProvider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
    tempDir = await Directory.systemTemp.createTemp('share_source_test_');
    PathProviderPlatform.instance = _MockPathProviderPlatform(tempDir.path);
    FileUtils.resetDocumentsPathCache();
    ShareService.filePickerSaveOverride =
        ({allowedExtensions, dialogTitle, fileName}) async =>
            '${tempDir.path}/$fileName';
  });

  tearDown(() async {
    ShareService.filePickerSaveOverride = null;
    appProvider.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> copyText({required dynamic l10n}) =>
      ShareService.generateMarkdownText(
        notes: [note],
        includeSubNotesAndLinkedNotes: false,
        appProvider: appProvider,
        l10n: l10n,
      );

  /// Runs the zip export and returns the note's markdown file from it.
  Future<String> exportText() async {
    await ShareService.shareAsMarkdownZip(
      notes: [note],
      includeSubNotesAndLinkedNotes: false,
      appProvider: appProvider,
      l10n: AppLocalizationsEn(),
    );
    final zip = tempDir.listSync().whereType<File>().firstWhere(
      (f) => f.path.endsWith('.zip'),
    );
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    final file = archive.findFile('${noteId}__Clipped.md');
    expect(file, isNotNull, reason: 'note file missing from the zip');
    return String.fromCharCodes(file!.content as List<int>);
  }

  List<String> linesOf(String markdown) => markdown.split('\n');

  group('copy (generateMarkdownText)', () {
    test('writes a localized Source line per source after Tags', () async {
      stored([titled, untitled]);
      final l10n = AppLocalizationsEn();

      final lines = linesOf(await copyText(l10n: l10n));

      final tags = lines.indexOf('**Tags:** a, b');
      final first = lines.indexOf(
        '**${l10n.source}:** [Post title](https://example.com/post/123)',
      );
      final second = lines.indexOf(
        '**${l10n.source}:** [example.com](https://www.example.com/x)',
      );
      final created = lines.indexWhere((l) => l.startsWith('**Created:**'));
      expect(tags, greaterThanOrEqualTo(0));
      expect(first, tags + 1);
      expect(second, tags + 2);
      expect(created, tags + 3);
    });

    test('uses the current locale for the label', () async {
      stored([titled]);
      final l10n = AppLocalizationsZh();
      expect(l10n.source, isNot('Source'));

      final markdown = await copyText(l10n: l10n);

      expect(
        markdown,
        contains(
          '**${l10n.source}:** [Post title](https://example.com/post/123)',
        ),
      );
      expect(markdown, isNot(contains('**Source:**')));
    });

    test('writes nothing for a note without sources', () async {
      stored([]);

      final markdown = await copyText(l10n: AppLocalizationsEn());

      expect(markdown, isNot(contains('Source')));
      expect(markdown, contains('**Tags:** a, b'));
    });

    test('a failing metadata read drops the line, not the export', () async {
      when(mockDb.getNoteMetadata(noteId)).thenThrow(StateError('closed'));

      final markdown = await copyText(l10n: AppLocalizationsEn());

      expect(markdown, contains('# Clipped'));
      expect(markdown, isNot(contains('Source')));
    });

    test('sourceNoteIdFor resolves a transient id to the note read', () async {
      stored([titled]);
      // A block-scoped note as the plugin bridge synthesizes it: a transient
      // id, no row of its own.
      final block = Note(
        id: 'block-1',
        title: note.title,
        content: 'Body',
        type: NoteType.note,
        createdAt: note.createdAt,
        updatedAt: note.updatedAt,
      );
      final l10n = AppLocalizationsEn();

      final markdown = await ShareService.generateMarkdownText(
        notes: [block],
        includeSubNotesAndLinkedNotes: false,
        appProvider: appProvider,
        l10n: l10n,
        sourceNoteIdFor: (id) => id == 'block-1' ? noteId : id,
      );

      expect(
        markdown,
        contains(
          '**${l10n.source}:** [Post title](https://example.com/post/123)',
        ),
      );
      verifyNever(mockDb.getNoteMetadata('block-1'));
    });
  });

  group('PDF label (sourceLabel)', () {
    test('a titled source is "title — url"', () {
      expect(
        ShareService.sourceLabel(titled),
        'Post title — https://example.com/post/123',
      );
    });

    test('an untitled source is the url alone, not host — url', () {
      expect(ShareService.sourceLabel(untitled), 'https://www.example.com/x');
    });
  });

  group('export (shareAsMarkdownZip)', () {
    test('writes an English **Source:** link line per source', () async {
      stored([titled, untitled]);

      final lines = linesOf(await exportText());

      final tags = lines.indexOf('**Tags:** a, b');
      expect(
        lines[tags + 1],
        '**Source:** [Post title](https://example.com/post/123)',
      );
      expect(
        lines[tags + 2],
        '**Source:** [example.com](https://www.example.com/x)',
      );
      expect(lines[tags + 3], startsWith('**Created:**'));
    });

    test('escapes the link text and keeps it on one line', () async {
      stored([
        NoteSource(
          id: 's3',
          url: 'https://example.com/e',
          title: 'See [ref] (2026)\nback\\slash',
          method: NoteSourceMethod.manual,
        ),
      ]);

      final markdown = await exportText();

      expect(
        markdown,
        contains(
          r'**Source:** [See [ref\] (2026\) back\\slash](https://example.com/e)',
        ),
      );
    });

    test('writes the url as is, even with parentheses', () async {
      stored([
        NoteSource(
          id: 's4',
          url: 'https://en.wikipedia.org/wiki/Foo_(bar)',
          method: NoteSourceMethod.manual,
        ),
      ]);

      final markdown = await exportText();

      expect(
        markdown,
        contains(
          '**Source:** [en.wikipedia.org](https://en.wikipedia.org/wiki/Foo_(bar))',
        ),
      );
    });
  });
}
