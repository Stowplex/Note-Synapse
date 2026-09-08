import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/l10n/app_localizations_en.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/import_service.dart';
import 'package:note_synapse/services/note_source_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/share_service.dart';
import 'package:note_synapse/utils/file_utils.dart';
import 'package:note_synapse/utils/note_metadata.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

// Reuse existing mocks: AppProvider from the share service tests, the
// database from the source service tests.
import 'note_source_service_test.mocks.dart';
import 'services/share_service_test.mocks.dart';

class _MockPathProviderPlatform extends PathProviderPlatform {
  _MockPathProviderPlatform(this.tempPath);

  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

/// `**Source:**` lines go through the whole import, from the zip to the
/// `metadata` of the created note or the merge into an existing one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const noteId = 'n1';

  late MockAppProvider mockAppProvider;
  late MockDatabaseService mockDb;
  late Directory tempDir;
  late List<Note> added;
  late List<Note> updated;

  setUp(() async {
    await resetForTesting();
    mockAppProvider = MockAppProvider();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<NoteSourceService>(NoteSourceService(mockDb));
    tempDir = await Directory.systemTemp.createTemp('import_source_test_');
    PathProviderPlatform.instance = _MockPathProviderPlatform(tempDir.path);
    FileUtils.resetDocumentsPathCache();
    added = [];
    updated = [];
    when(mockAppProvider.notes).thenReturn([]);
    when(mockAppProvider.addNote(any)).thenAnswer((invocation) async {
      added.add(invocation.positionalArguments.first as Note);
    });
    when(mockAppProvider.updateNote(any)).thenAnswer((invocation) async {
      updated.add(invocation.positionalArguments.first as Note);
    });
    when(mockDb.updateNoteMetadata(any, any)).thenAnswer((_) async {});
  });

  tearDown(() async {
    ShareService.filePickerSaveOverride = null;
    await resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// A zip holding one markdown note built from [headerLines] (placed after
  /// the ID line) and a body.
  Future<File> zipWithNote(
    List<String> headerLines, {
    String id = noteId,
    String updatedAt = '2026-01-02T00:00:00.000',
  }) async {
    final markdown = [
      '# Clipped',
      '',
      '**ID:** $id',
      '**Type:** Note',
      '**Tags:** a, b',
      ...headerLines,
      '**Created:** 2026-01-01T00:00:00.000',
      '**Updated:** $updatedAt',
      '',
      'Body text.',
      '',
    ].join('\n');
    final bytes = utf8.encode(markdown);
    final archive = Archive()
      ..addFile(ArchiveFile('${id}__Clipped.md', bytes.length, bytes));
    final file = File(p.join(tempDir.path, 'import_$id.zip'));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  /// Imports [headerLines] as a new note and returns its parsed sources.
  Future<List<NoteSource>> importSources(List<String> headerLines) async {
    final stats = await ImportService().importFromMarkdownZip(
      await zipWithNote(headerLines),
      mockAppProvider,
    );
    expect(stats.imported, 1);
    expect(stats.errors, 0);
    final note = added.single;
    expect(note.id, noteId);
    expect(note.content, 'Body text.');
    expect(note.tags, ['a', 'b']);
    expect(note.createdAt, DateTime(2026, 1, 1));
    return NoteMetadata.readSources(NoteMetadata.decode(note.metadata));
  }

  group('parsing', () {
    test(
      '[title](url) gives url and title, method import, no clip time',
      () async {
        final sources = await importSources([
          '**Source:** [Post title](https://example.com/post/123)',
        ]);

        final source = sources.single;
        expect(source.url, 'https://example.com/post/123');
        expect(source.title, 'Post title');
        expect(source.method, NoteSourceMethod.import);
        expect(source.kind, NoteSourceKind.web);
        expect(source.clippedAt, isNull);
      },
    );

    test('a bare url has no title', () async {
      final sources = await importSources([
        '**Source:** https://example.com/bare',
      ]);

      expect(sources.single.url, 'https://example.com/bare');
      expect(sources.single.title, isNull);
    });

    test('an angle-bracket url is unwrapped', () async {
      final sources = await importSources([
        '**Source:** <https://example.com/angle>',
      ]);

      expect(sources.single.url, 'https://example.com/angle');
    });

    test(
      'several lines give several sources in order; a repeat collapses',
      () async {
        final sources = await importSources([
          '**Source:** [First](https://example.com/1)',
          '**Source:** https://example.com/2',
          '**Source:** [Again](https://example.com/1)',
        ]);

        expect(sources.map((s) => s.url), [
          'https://example.com/1',
          'https://example.com/2',
        ]);
        expect(sources.first.title, 'First');
      },
    );

    test('malformed lines are ignored and do not break the header', () async {
      final sources = await importSources([
        '**Source:**',
        '**Source:** not a url',
        '**Source:** [t](ftp://example.com/x)',
        '**Source:** javascript:alert(1)',
        '**Source:** [t](https://example.com/x) trailing words',
        '**Source:** [broken](https://example.com/x',
      ]);

      expect(sources, isEmpty);
      expect(added.single.metadata, isNull);
    });

    test('unescapes the link text the export writes', () async {
      final sources = await importSources([
        r'**Source:** [See [ref\] \(2026\) back\\slash](https://example.com/e)',
      ]);

      expect(sources.single.title, r'See [ref] (2026) back\slash');
      expect(sources.single.url, 'https://example.com/e');
    });

    test('keeps a url with parentheses whole', () async {
      final sources = await importSources([
        '**Source:** [Foo](https://en.wikipedia.org/wiki/Foo_(bar))',
      ]);

      expect(sources.single.url, 'https://en.wikipedia.org/wiki/Foo_(bar)');
      expect(sources.single.title, 'Foo');
    });

    test('a title that is just the host is not read back as a title', () async {
      final sources = await importSources([
        '**Source:** [example.com](https://www.example.com/x)',
      ]);

      expect(sources.single.url, 'https://www.example.com/x');
      expect(sources.single.title, isNull);
    });
  });

  group('existing note', () {
    test('merges the parsed sources before updating the note', () async {
      final existing = Note(
        id: noteId,
        title: 'Old',
        content: 'Old body',
        type: NoteType.note,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 1),
      );
      when(mockAppProvider.notes).thenReturn([existing]);
      when(mockDb.getNoteMetadata(noteId)).thenAnswer(
        (_) async => {
          'markers': [
            {'id': 'm1', 'index': 0},
          ],
          'sources': [
            {
              'id': 'a',
              'url': 'https://a.example/',
              'title': 'Kept',
              'method': 'extract',
            },
          ],
        },
      );

      final stats = await ImportService().importFromMarkdownZip(
        await zipWithNote([
          '**Source:** [Replaced?](https://a.example/)',
          '**Source:** [New](https://b.example/)',
        ]),
        mockAppProvider,
      );

      expect(stats.updated, 1);
      expect(updated.single.id, noteId);
      // The merge lands before updateNote notifies, so a listener that
      // re-reads the sources on the note's new updatedAt sees the merged list.
      final written =
          verifyInOrder([
                mockDb.updateNoteMetadata(noteId, captureAny),
                mockAppProvider.updateNote(any),
              ]).first.captured.single
              as Map<String, dynamic>;
      expect(written['markers'], [
        {'id': 'm1', 'index': 0},
      ]);
      final sources = NoteMetadata.readSources(written);
      expect(sources.map((s) => s.url), [
        'https://a.example/',
        'https://b.example/',
      ]);
      expect(sources.first.title, 'Kept', reason: 'existing entry wins');
      expect(sources.first.id, 'a');
      expect(sources.last.title, 'New');
      expect(sources.last.method, NoteSourceMethod.import);
    });

    test('writes no metadata when the file has no sources', () async {
      final existing = Note(
        id: noteId,
        title: 'Old',
        content: 'Old body',
        type: NoteType.note,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 1),
      );
      when(mockAppProvider.notes).thenReturn([existing]);

      await ImportService().importFromMarkdownZip(
        await zipWithNote(const []),
        mockAppProvider,
      );

      expect(updated, hasLength(1));
      verifyNever(mockDb.getNoteMetadata(any));
      verifyNever(mockDb.updateNoteMetadata(any, any));
    });
  });

  test('export then import reproduces url and title', () async {
    final note = Note(
      id: 'rt',
      title: 'Round trip',
      content: 'Body',
      type: NoteType.note,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final titled = NoteSource(
      url: 'https://example.com/post/123',
      title: 'Post [title] (v2)',
      siteName: 'Example',
      method: NoteSourceMethod.ai,
      clippedAt: DateTime.utc(2026, 9, 6),
    );
    final untitled = NoteSource(
      url: 'https://www.example.com/x',
      method: NoteSourceMethod.manual,
    );
    when(
      mockAppProvider.getNoteSources('rt'),
    ).thenAnswer((_) async => [titled, untitled]);
    ShareService.filePickerSaveOverride =
        ({allowedExtensions, dialogTitle, fileName}) async =>
            '${tempDir.path}/$fileName';

    await ShareService.shareAsMarkdownZip(
      notes: [note],
      includeSubNotesAndLinkedNotes: false,
      appProvider: mockAppProvider,
      l10n: AppLocalizationsEn(),
    );
    final zip = tempDir.listSync().whereType<File>().firstWhere(
      (f) => f.path.endsWith('.zip'),
    );
    final stats = await ImportService().importFromMarkdownZip(
      zip,
      mockAppProvider,
    );

    expect(stats.imported, 1);
    final sources = NoteMetadata.readSources(
      NoteMetadata.decode(added.single.metadata),
    );
    expect(sources.map((s) => s.url), [titled.url, untitled.url]);
    expect(sources.map((s) => s.title), [titled.title, null]);
    expect(sources.map((s) => s.method), everyElement(NoteSourceMethod.import));
    expect(sources.map((s) => s.clippedAt), everyElement(isNull));
  });
}
