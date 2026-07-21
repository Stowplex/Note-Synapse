import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/user_app_service.dart';

import 'app_provider_cache_test.mocks.dart';

@GenerateMocks([DatabaseService, UserAppService, ModelStorageService])
Note buildNote(String id, {String title = 'title', List<String> tags = const []}) {
  final now = DateTime.now();
  return Note(
    id: id,
    title: title,
    content: 'content of $id',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: tags,
  );
}

void main() {
  late MockDatabaseService mockDb;
  late MockUserAppService mockUserAppService;
  late MockModelStorageService mockModelStorage;
  late DataChangeNotifier notifier;
  late AppProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockUserAppService = MockUserAppService();
    mockModelStorage = MockModelStorageService();
    getIt.registerSingleton<UserAppService>(mockUserAppService);
    getIt.registerSingleton<ModelStorageService>(mockModelStorage);

    // Defaults for the loadData path.
    when(mockDb.getAllNotes()).thenAnswer((_) async => []);
    when(mockDb.getAllTags()).thenAnswer((_) async => []);
    when(mockDb.getAllFilters()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionApps()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionDefaultAppId()).thenAnswer((_) async => null);
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);

    notifier = DataChangeNotifier();
    provider = AppProvider(databaseService: mockDb, changeNotifier: notifier);
  });

  group('refreshNotesFromDb', () {
    test('upserts changed, appends new, removes deleted', () async {
      final existing = buildNote('a', title: 'old');
      when(mockDb.getNotesByIds(any)).thenAnswer(
        (_) async => [buildNote('a', title: 'new'), buildNote('b')],
      );
      provider.notes.add(existing);
      provider.notes.add(buildNote('gone'));

      await provider.refreshNotesFromDb({'a', 'b', 'gone'});

      expect(provider.notes.map((n) => n.id).toSet(), {'a', 'b'});
      expect(provider.notes.firstWhere((n) => n.id == 'a').title, 'new');
    });

    test('notifies exactly once per batch', () async {
      when(mockDb.getNotesByIds(any))
          .thenAnswer((_) async => [buildNote('a'), buildNote('b')]);
      var notifications = 0;
      provider.addListener(() => notifications++);

      await provider.refreshNotesFromDb({'a', 'b'});

      expect(notifications, 1);
    });

    test('falls back to per-id fetch when the batch fetch fails, and a '
        'failing id is not misread as a deletion', () async {
      final cachedBad = buildNote('bad', title: 'cached');
      provider.notes.add(cachedBad);
      when(mockDb.getNotesByIds(any)).thenThrow(Exception('batch broken'));
      when(mockDb.getNote('good')).thenAnswer((_) async => buildNote('good'));
      when(mockDb.getNote('bad')).thenThrow(Exception('row broken'));
      var notifications = 0;
      provider.addListener(() => notifications++);

      await provider.refreshNotesFromDb({'good', 'bad'});

      expect(provider.notes.map((n) => n.id).toSet(), {'good', 'bad'});
      expect(provider.notes.firstWhere((n) => n.id == 'bad').title, 'cached');
      expect(notifications, 1);
    });
  });

  group('updateNote', () {
    test('upserts when the note is not in the cache', () async {
      final note = buildNote('n1');
      when(mockDb.updateNote(any)).thenAnswer((_) async {});
      when(mockDb.getNote('n1')).thenAnswer((_) async => note);

      await provider.updateNote(note);

      expect(provider.notes.map((n) => n.id), contains('n1'));
    });
  });

  group('cache lock', () {
    test('addNote queued behind an in-flight loadData survives the reload '
        'replace', () async {
      final loadGate = Completer<List<Note>>();
      when(mockDb.getAllNotes()).thenAnswer((_) => loadGate.future);
      final added = buildNote('added');
      when(mockDb.insertNote(any)).thenAnswer((_) async => 'id');
      when(mockDb.getNote('added')).thenAnswer((_) async => added);

      final loadFuture = provider.loadData();
      final addFuture = provider.addNote(added);
      // The load holds the lock; give addNote a chance to (incorrectly) run.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.notes, isEmpty, reason: 'addNote must wait for the lock');

      loadGate.complete([buildNote('preexisting')]);
      await loadFuture;
      await addFuture;

      expect(
        provider.notes.map((n) => n.id).toSet(),
        {'preexisting', 'added'},
        reason: 'the reload replace must not drop the queued addNote',
      );
    });

    test('an action that throws does not poison the lock for later actions',
        () async {
      when(mockDb.insertNote(any)).thenThrow(Exception('insert broken'));
      await expectLater(provider.addNote(buildNote('x')), throwsException);

      when(mockDb.insertNote(any)).thenAnswer((_) async => 'id');
      when(mockDb.getNote('y')).thenAnswer((_) async => buildNote('y'));
      await provider.addNote(buildNote('y'));

      expect(provider.notes.map((n) => n.id), contains('y'));
    });
  });

  group('change events', () {
    test('a merged notes+tags+filters event produces one notification',
        () async {
      when(mockDb.getNotesByIds(any)).thenAnswer((_) async => [buildNote('a')]);
      when(mockDb.getAllTags()).thenAnswer(
        (_) async => [Tag(id: 't1', name: 'tag', color: '#fff', createdAt: DateTime.now())],
      );
      when(mockDb.getAllFilters()).thenAnswer(
        (_) async => [
          Filter(
            id: 'f1',
            name: 'filter',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ],
      );
      var notifications = 0;
      provider.addListener(() => notifications++);

      notifier.publish(const DataChangeEvent(
        noteIds: {'a'},
        tagsChanged: true,
        filtersChanged: true,
        relationshipNoteIds: {'a'},
      ));
      await notifier.waitForIdle();

      expect(notifications, 1);
      expect(provider.notes.map((n) => n.id), contains('a'));
      expect(provider.tags.map((t) => t.name), contains('tag'));
      expect(provider.filters.map((f) => f.name), contains('filter'));
    });

    test('a relationship-only event still notifies', () async {
      var notifications = 0;
      provider.addListener(() => notifications++);

      notifier.publish(const DataChangeEvent(relationshipNoteIds: {'a'}));
      await notifier.waitForIdle();

      expect(notifications, 1);
      verifyNever(mockDb.getNotesByIds(any));
    });

    test('bulk supersedes targeted work and debounces into one loadData',
        () async {
      notifier.publish(const DataChangeEvent(bulk: true, noteIds: {'a'}));
      notifier.publish(const DataChangeEvent(bulk: true));
      await notifier.waitForIdle();

      // Debounce window has not elapsed: no reload, no targeted fetch.
      verifyNever(mockDb.getAllNotes());
      verifyNever(mockDb.getNotesByIds(any));

      await Future<void>.delayed(const Duration(milliseconds: 700));
      verify(mockDb.getAllNotes()).called(1);
      verifyNever(mockDb.getNotesByIds(any));
    });

    test('events after dispose are not delivered', () async {
      provider.dispose();
      notifier.publish(const DataChangeEvent(noteIds: {'a'}));
      await notifier.waitForIdle();
      verifyNever(mockDb.getNotesByIds(any));
    });
  });

  group('clearAllData', () {
    test('clears notes, tags, AND filters under the lock', () async {
      when(mockDb.getAllNotes()).thenAnswer((_) async => [buildNote('a')]);
      when(mockDb.getAllTags()).thenAnswer(
        (_) async => [Tag(id: 't1', name: 'tag', color: '#fff', createdAt: DateTime.now())],
      );
      when(mockDb.getAllFilters()).thenAnswer(
        (_) async => [
          Filter(
            id: 'f1',
            name: 'filter',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ],
      );
      await provider.loadData();
      expect(provider.filters, isNotEmpty);

      when(mockDb.clearAllData()).thenAnswer((_) async {});
      await provider.clearAllData();

      expect(provider.notes, isEmpty);
      expect(provider.tags, isEmpty);
      expect(provider.filters, isEmpty);
    });
  });

  group('scheduleReload', () {
    test('coalesces bursts into a single loadData', () async {
      provider.scheduleReload();
      provider.scheduleReload();
      provider.scheduleReload();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      verify(mockDb.getAllNotes()).called(1);
    });
  });
}
