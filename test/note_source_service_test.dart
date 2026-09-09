import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_source_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'note_source_service_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  const noteId = 'note-1';

  /// Owned by NoteMarkerService: opaque here, and must survive every write.
  final markers = [
    {'id': 'marker-1', 'index': 0, 'charStart': 4, 'charEnd': 9},
  ];

  NoteSource source(String url, {String? id, String? title}) => NoteSource(
    id: id,
    url: url,
    title: title,
    method: NoteSourceMethod.extract,
    clippedAt: DateTime.utc(2026, 9, 6, 17, 4, 11),
  );

  final a = source('https://a.example/post', id: 'a', title: 'A');
  final b = source('https://b.example/post', id: 'b', title: 'B');

  late MockDatabaseService mockDb;
  late NoteSourceService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteSourceService(mockDb);
    when(mockDb.updateNoteMetadata(any, any)).thenAnswer((_) async {});
  });

  void stored(Map<String, dynamic>? metadata) =>
      when(mockDb.getNoteMetadata(noteId)).thenAnswer((_) async => metadata);

  /// The map written to [noteId]; fails unless exactly one write happened.
  Map<String, dynamic> written() =>
      verify(mockDb.updateNoteMetadata(noteId, captureAny)).captured.single
          as Map<String, dynamic>;

  List<Map<String, dynamic>> sourcesOf(Map<String, dynamic> metadata) =>
      (metadata['sources'] as List).cast<Map<String, dynamic>>();

  List<String?> idsOf(Iterable<Map<String, dynamic>> entries) =>
      entries.map((e) => e['id'] as String?).toList();

  group('getSources', () {
    test('returns empty for a note without metadata', () async {
      stored(null);
      expect(await service.getSources(noteId), isEmpty);
    });

    test('returns empty when metadata has no sources key', () async {
      stored({'markers': markers});
      expect(await service.getSources(noteId), isEmpty);
    });

    test('skips malformed entries and keeps the rest in order', () async {
      stored({
        'sources': [
          {'id': 'no-url', 'title': 'missing url'},
          'not an object',
          42,
          b.toJson(),
          a.toJson(),
        ],
      });

      final result = await service.getSources(noteId);

      expect(result.map((s) => s.id).toList(), ['b', 'a']);
      expect(result.first.title, 'B');
    });

    test('returns empty when the stored metadata is not usable JSON', () async {
      when(
        mockDb.getNoteMetadata(noteId),
      ).thenThrow(const FormatException('bad json'));
      expect(await service.getSources(noteId), isEmpty);
    });

    test('returns empty instead of throwing on a database error', () async {
      when(mockDb.getNoteMetadata(noteId)).thenThrow(StateError('closed'));
      expect(await service.getSources(noteId), isEmpty);
    });
  });

  group('addSources', () {
    test('writes the sources into a note without metadata', () async {
      stored(null);

      await service.addSources(noteId, [a]);

      expect(written(), {
        'sources': [a.toJson()],
      });
    });

    test('merges into existing metadata and preserves markers', () async {
      stored({
        'markers': markers,
        'sources': [a.toJson()],
      });

      await service.addSources(noteId, [b]);

      final map = written();
      expect(map['markers'], markers);
      expect(idsOf(sourcesOf(map)), ['a', 'b']);
    });

    test('de-duplicates on url, keeping the existing entry', () async {
      stored({
        'sources': [a.toJson()],
      });
      final reclipped = source(a.url, id: 'a2', title: 'Re-clipped');

      await service.addSources(noteId, [reclipped, b]);

      final entries = sourcesOf(written());
      expect(idsOf(entries), ['a', 'b']);
      expect(entries.first['title'], 'A');
    });

    test('a url with surrounding whitespace is the same url', () async {
      stored({
        'sources': [a.toJson()],
      });

      await service.addSources(noteId, [source('  ${a.url}  ', id: 'a2')]);

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('neither reads nor writes for an empty list', () async {
      await service.addSources(noteId, []);

      verifyNever(mockDb.getNoteMetadata(any));
      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('does not write when every source is already recorded', () async {
      stored({
        'markers': markers,
        'sources': [a.toJson(), b.toJson()],
      });

      await service.addSources(noteId, [
        source(b.url, id: 'b2'),
        source(a.url, id: 'a2'),
      ]);

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('does not write when the only new source has a blank url', () async {
      stored({
        'sources': [a.toJson()],
      });

      await service.addSources(noteId, [
        source('   ', id: 'blank'),
        source(a.url, id: 'a2'),
      ]);

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('replaces stored metadata that is not usable JSON', () async {
      when(
        mockDb.getNoteMetadata(noteId),
      ).thenThrow(const FormatException('bad json'));

      await service.addSources(noteId, [a]);

      expect(written(), {
        'sources': [a.toJson()],
      });
    });

    test('replaces stored metadata whose JSON has the wrong shape', () async {
      when(mockDb.getNoteMetadata(noteId)).thenThrow(TypeError());

      await service.addSources(noteId, [a]);

      expect(written(), {
        'sources': [a.toJson()],
      });
    });

    test('does not write after a database read error', () async {
      when(mockDb.getNoteMetadata(noteId)).thenThrow(StateError('closed'));

      await service.addSources(noteId, [a]);

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('does not throw when the write fails', () async {
      stored(null);
      when(mockDb.updateNoteMetadata(any, any)).thenThrow(StateError('closed'));

      await expectLater(service.addSources(noteId, [a]), completes);
    });
  });

  group('updateSource', () {
    test('never writes a blank url, even when editing by id', () async {
      stored({
        'sources': [a.toJson(), b.toJson()],
      });

      await service.updateSource(noteId, a.copyWith(url: '   '));

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('does not write after a database read error', () async {
      when(mockDb.getNoteMetadata(noteId)).thenThrow(StateError('closed'));

      await service.updateSource(noteId, a.copyWith(title: 'edited'));

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test(
      'replaces the entry with the same id in place, keeping markers',
      () async {
        stored({
          'markers': markers,
          'sources': [a.toJson(), b.toJson()],
        });
        final edited = a.copyWith(title: 'A, renamed', siteName: 'Example');

        await service.updateSource(noteId, edited);

        final map = written();
        expect(map['markers'], markers);
        expect(sourcesOf(map), [edited.toJson(), b.toJson()]);
      },
    );

    test('appends when no entry has the id', () async {
      stored({
        'sources': [a.toJson()],
      });
      final c = source('https://c.example/', id: 'c');

      await service.updateSource(noteId, c);

      expect(sourcesOf(written()), [a.toJson(), c.toJson()]);
    });

    test('appends to a note without metadata', () async {
      stored(null);

      await service.updateSource(noteId, a);

      expect(written(), {
        'sources': [a.toJson()],
      });
    });

    test('the edited entry wins over another entry with its new url', () async {
      stored({
        'sources': [a.toJson(), b.toJson()],
      });
      final moved = b.copyWith(url: a.url);

      await service.updateSource(noteId, moved);

      expect(sourcesOf(written()), [moved.toJson()]);
    });

    test(
      'appending an unknown id whose url is already recorded does not write',
      () async {
        stored({
          'sources': [a.toJson()],
        });
        final reclipped = source(a.url, id: 'a2', title: 'Re-clipped');

        await service.updateSource(noteId, reclipped);

        verifyNever(mockDb.updateNoteMetadata(any, any));
      },
    );

    test('does not write when appending a blank url', () async {
      stored({
        'sources': [a.toJson()],
      });

      await service.updateSource(noteId, source('   ', id: 'blank'));

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('does not write when the stored entry already equals it', () async {
      stored({
        'markers': markers,
        'sources': [a.toJson(), b.toJson()],
      });

      await service.updateSource(noteId, a);

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });
  });

  group('removeSource', () {
    test('does not write after a database read error', () async {
      when(mockDb.getNoteMetadata(noteId)).thenThrow(StateError('closed'));

      await service.removeSource(noteId, a.id);

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('removes only that id and keeps other keys', () async {
      stored({
        'markers': markers,
        'sources': [a.toJson(), b.toJson()],
      });

      await service.removeSource(noteId, 'a');

      final map = written();
      expect(map['markers'], markers);
      expect(sourcesOf(map), [b.toJson()]);
    });

    test('removing the last source drops the key but keeps markers', () async {
      stored({
        'markers': markers,
        'sources': [a.toJson()],
      });

      await service.removeSource(noteId, 'a');

      expect(written(), {'markers': markers});
    });

    test('does not write when no entry has the id', () async {
      stored({
        'markers': markers,
        'sources': [a.toJson()],
      });

      await service.removeSource(noteId, 'missing');

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });

    test('does not write for a note without metadata', () async {
      stored(null);

      await service.removeSource(noteId, 'a');

      verifyNever(mockDb.updateNoteMetadata(any, any));
    });
  });

  group('AppProvider.getNoteSources', () {
    late AppProvider provider;

    setUp(() {
      provider = AppProvider(
        databaseService: mockDb,
        changeNotifier: DataChangeNotifier(),
      );
      addTearDown(provider.dispose);
    });

    test("reads sources through the provider's own database", () async {
      stored({
        'markers': markers,
        'sources': [b.toJson(), a.toJson()],
      });

      final result = await provider.getNoteSources(noteId);

      expect(result.map((s) => s.id).toList(), ['b', 'a']);
      expect(result.first.url, b.url);
    });

    test('returns empty for a note without metadata', () async {
      stored(null);
      expect(await provider.getNoteSources(noteId), isEmpty);
    });
  });
}
