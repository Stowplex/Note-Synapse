import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';

import 'tag_lifecycle_filters_test.mocks.dart';

/// M5 / G8: renaming or deleting a tag rewrites `filters.includeTags` and
/// `excludeTags` too, not just the notes.
///
/// This is the one gap that could destroy a Space without the user asking:
/// a Space *is* its include-tags, so a rename that touched only notes left the
/// Space pointing at a name nothing carries (silently empty), and a delete left
/// it stamping nothing.
@GenerateMocks([
  DatabaseService,
  UserAppService,
  ModelStorageService,
  TagImageService,
  AIService,
])
Note buildNote(String id, {List<String> tags = const []}) {
  final now = DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: 'title',
    content: 'content',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: tags,
  );
}

Filter buildFilter(
  String id, {
  String? name,
  List<String> includeTags = const [],
  List<String> excludeTags = const [],
  bool isSpace = true,
}) {
  final now = DateTime(2026, 1, 1);
  return Filter(
    id: id,
    name: name ?? id,
    includeTags: includeTags,
    excludeTags: excludeTags,
    isSpace: isSpace,
    createdAt: now,
    updatedAt: now,
  );
}

Tag buildTag(String name) =>
    Tag(id: 'tag-$name', name: name, color: '#fff', createdAt: DateTime(2026));

void main() {
  late MockDatabaseService mockDb;
  late MockUserAppService mockUserAppService;
  late MockModelStorageService mockModelStorage;
  late MockTagImageService mockTagImages;
  late SpaceScopeService scope;
  late AppProvider provider;

  /// Filters written back through `updateFilter`, keyed by id, in call order.
  final written = <String, Filter>{};

  Future<void> load({
    List<Note> notes = const [],
    List<Filter> filters = const [],
    List<Tag> tags = const [],
  }) async {
    when(mockDb.getAllNotes()).thenAnswer((_) async => [...notes]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => [...filters]);
    when(mockDb.getAllTags()).thenAnswer((_) async => [...tags]);
    await provider.loadData();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();
    written.clear();
    mockDb = MockDatabaseService();
    mockUserAppService = MockUserAppService();
    mockModelStorage = MockModelStorageService();
    mockTagImages = MockTagImageService();
    scope = SpaceScopeService();
    getIt.registerSingleton<UserAppService>(mockUserAppService);
    getIt.registerSingleton<ModelStorageService>(mockModelStorage);
    getIt.registerSingleton<TagImageService>(mockTagImages);
    getIt.registerSingleton<SpaceScopeService>(scope);

    when(mockDb.getAllNotes()).thenAnswer((_) async => []);
    when(mockDb.getAllTags()).thenAnswer((_) async => []);
    when(mockDb.getAllFilters()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionApps()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionDefaultAppId()).thenAnswer((_) async => null);
    when(mockDb.updateNote(any)).thenAnswer((_) async {});
    when(mockDb.insertNote(any)).thenAnswer((_) async => 'id');
    when(mockDb.deleteTag(any)).thenAnswer((_) async {});
    when(mockDb.replaceTag(any, any)).thenAnswer((_) async {});
    when(mockDb.updateFilter(any)).thenAnswer((invocation) async {
      final filter = invocation.positionalArguments.first as Filter;
      written[filter.id] = filter;
    });
    when(mockTagImages.removeTagImage(any)).thenAnswer((_) async {});
    when(mockTagImages.getImagePathForTag(any)).thenReturn(null);
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);

    provider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
  });

  Filter current(String id) => provider.filters.firstWhere((f) => f.id == id);

  // ------------------------------------------------------------------ rename

  group('replaceTag rewrites filters', () {
    test(
      'renames the tag in includeTags, in the database and in memory',
      () async {
        await load(
          filters: [
            buildFilter('s1', includeTags: ['thesis', 'reading']),
          ],
          tags: [buildTag('thesis'), buildTag('archive')],
        );

        await provider.replaceTag('thesis', 'archive');

        expect(written['s1']!.includeTags, ['archive', 'reading']);
        expect(current('s1').includeTags, ['archive', 'reading']);
      },
    );

    test('renames the tag in excludeTags too', () async {
      await load(
        filters: [
          buildFilter('f1', includeTags: ['keep'], excludeTags: ['thesis']),
        ],
        tags: [buildTag('thesis'), buildTag('archive')],
      );

      await provider.replaceTag('thesis', 'archive');

      expect(written['f1']!.excludeTags, ['archive']);
      expect(current('f1').excludeTags, ['archive']);
    });

    test(
      'matches WHOLE TAGS ONLY: renaming thesis leaves thesis-2026 alone',
      () async {
        // The trap this pins: filters store their tag lists comma-joined, so a
        // rewrite done on the joined string (`'thesis,thesis-2026'.replaceAll`)
        // corrupts every tag the renamed one is a prefix of.
        await load(
          filters: [
            buildFilter('s1', includeTags: ['thesis', 'thesis-2026']),
            buildFilter('f2', includeTags: ['my-thesis'], isSpace: false),
          ],
          tags: [buildTag('thesis'), buildTag('archive')],
        );

        await provider.replaceTag('thesis', 'archive');

        expect(current('s1').includeTags, ['archive', 'thesis-2026']);
        // A filter that never carried the exact tag is not written at all.
        expect(written.containsKey('f2'), isFalse);
        expect(current('f2').includeTags, ['my-thesis']);
      },
    );

    test(
      'dedups when the filter already carries both the old and the new name',
      () async {
        await load(
          filters: [
            buildFilter('s1', includeTags: ['thesis', 'archive']),
          ],
          tags: [buildTag('thesis'), buildTag('archive')],
        );

        await provider.replaceTag('thesis', 'archive');

        expect(current('s1').includeTags, ['archive']);
      },
    );

    test('renaming the ACTIVE space\'s tag keeps it active and re-points the '
        'stamp', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
        tags: [buildTag('thesis'), buildTag('archive')],
      );
      await provider.setActiveSpace('s1');

      await provider.replaceTag('thesis', 'archive');

      expect(provider.activeSpace?.id, 's1');
      expect(provider.spaceTags, ['archive']);
      // The stamp follows: a note created now carries the new name.
      expect(scope.stampTags, ['archive']);
      expect(scope.stamp(buildNote('n2')).tags, ['archive']);
      // ...and the renamed note is still in the Space.
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);
    });

    test(
      'a rename that puts a comma into a space tag retires the space',
      () async {
        await load(
          filters: [
            buildFilter('s1', includeTags: ['thesis']),
          ],
          tags: [buildTag('thesis')],
        );
        await provider.setActiveSpace('s1');

        await provider.replaceTag('thesis', 'a,b');

        expect(provider.activeSpace, isNull);
        expect(provider.spaces, isEmpty);
        expect(provider.spacesInvalidatedByLastTagChange, ['s1']);
      },
    );

    test(
      '...and the retirement is what gets WRITTEN, so it survives a restart',
      () async {
        // The in-memory guard is `spaces`, which filters on usability. The row
        // is what the next launch reads. Un-flagging only on an *empty* include
        // list left `isSpace: 1` on disk for `a,b`, the comma-joined column
        // split it back into two tags on load, and the Space returned —
        // scoping to nothing and stamping two names no note carries.
        await load(
          filters: [
            buildFilter('s1', includeTags: ['thesis']),
          ],
          tags: [buildTag('thesis')],
        );
        await provider.setActiveSpace('s1');

        await provider.replaceTag('thesis', 'a,b');

        // What went to the database, not what the provider is holding.
        expect(written['s1'], isNotNull);
        expect(written['s1']!.isSpace, isFalse);
        expect(written['s1']!.includeTags, ['a,b']);

        // Now boot a second provider over exactly those rows, the way the next
        // launch would — including the split the storage layer performs.
        final reloaded = AppProvider(
          databaseService: mockDb,
          changeNotifier: DataChangeNotifier(),
        );
        final roundTripped = written['s1']!.copyWith(
          includeTags: written['s1']!.includeTags.join(',').split(','),
        );
        expect(roundTripped.includeTags, ['a', 'b']);
        when(mockDb.getAllFilters()).thenAnswer((_) async => [roundTripped]);
        when(mockDb.getAllNotes()).thenAnswer((_) async => []);
        when(mockDb.getAllTags()).thenAnswer((_) async => []);
        await reloaded.loadData();

        expect(reloaded.spaces, isEmpty);
        expect(reloaded.activeSpace, isNull);
        expect(await reloaded.setActiveSpace('s1'), isFalse);
      },
    );

    test('leaves filters that do not carry the tag untouched', () async {
      await load(
        filters: [
          buildFilter('f1', includeTags: ['other'], isSpace: false),
        ],
        tags: [buildTag('thesis'), buildTag('archive')],
      );

      await provider.replaceTag('thesis', 'archive');

      verifyNever(mockDb.updateFilter(any));
      expect(provider.spacesInvalidatedByLastTagChange, isEmpty);
    });
  });

  // ------------------------------------------------------------------ delete

  group('deleteTag rewrites filters', () {
    test('drops the tag from includeTags and excludeTags', () async {
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis', 'reading']),
          buildFilter(
            'f2',
            includeTags: ['keep'],
            excludeTags: ['thesis'],
            isSpace: false,
          ),
        ],
        tags: [buildTag('thesis')],
      );

      await provider.deleteTag('thesis');

      expect(written['s1']!.includeTags, ['reading']);
      expect(current('s1').includeTags, ['reading']);
      expect(written['f2']!.excludeTags, isEmpty);
      expect(current('f2').excludeTags, isEmpty);
    });

    test(
      'deleting ONE of several include tags leaves the space active',
      () async {
        await load(
          notes: [
            buildNote('n1', tags: ['thesis', 'reading']),
          ],
          filters: [
            buildFilter('s1', includeTags: ['thesis', 'reading']),
          ],
          tags: [buildTag('thesis')],
        );
        await provider.setActiveSpace('s1');

        await provider.deleteTag('thesis');

        expect(provider.activeSpace?.id, 's1');
        expect(current('s1').isSpace, isTrue);
        expect(provider.spaceTags, ['reading']);
        expect(scope.stampTags, ['reading']);
        expect(provider.spacesInvalidatedByLastTagChange, isEmpty);
        expect(provider.scopedNotes.map((n) => n.id), ['n1']);
      },
    );

    test('deleting the space\'s ONLY include tag un-flags it, deactivates, and '
        'tells the user', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis']),
          buildNote('n2'),
        ],
        filters: [
          buildFilter('s1', name: 'Thesis', includeTags: ['thesis']),
        ],
        tags: [buildTag('thesis')],
      );
      await provider.setActiveSpace('s1');
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);

      await provider.deleteTag('thesis');

      expect(written['s1']!.isSpace, isFalse);
      expect(written['s1']!.includeTags, isEmpty);
      expect(current('s1').isSpace, isFalse);
      expect(provider.activeSpace, isNull);
      expect(provider.spaces, isEmpty);
      expect(scope.activeSpaceId, isNull);
      expect(scope.stampTags, isEmpty);
      // The one way a Space vanishes without the user asking, so it is said.
      expect(provider.spacesInvalidatedByLastTagChange, ['Thesis']);
      // ...and the persisted id goes with it.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SpaceScopeService.prefsKey), isNull);
    });

    test(
      'a plain filter emptied by the delete keeps its (false) isSpace flag',
      () async {
        await load(
          filters: [
            buildFilter('f1', includeTags: ['thesis'], isSpace: false),
          ],
          tags: [buildTag('thesis')],
        );

        await provider.deleteTag('thesis');

        expect(current('f1').isSpace, isFalse);
        expect(provider.spacesInvalidatedByLastTagChange, isEmpty);
      },
    );
  });

  // ------------------------------------------------------------ comma guard

  group('a tag containing a comma can never be a space tag', () {
    test('it is not listed as a space and cannot be activated', () async {
      // `insertFilter`/`getAllFilters` store includeTags comma-joined, so such
      // a tag comes back as two tags that no note carries.
      await load(
        filters: [
          buildFilter('s1', includeTags: ['a,b']),
        ],
      );

      expect(provider.spaces, isEmpty);
      expect(await provider.setActiveSpace('s1'), isFalse);
      expect(provider.activeSpace, isNull);
    });

    test('one comma tag among several disqualifies the whole space', () async {
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis', 'a,b']),
        ],
      );

      expect(provider.spaces, isEmpty);
      expect(await provider.setActiveSpace('s1'), isFalse);
    });
  });

  // -------------------------------------------------------- cache behaviour

  group('the scopedNotes cache', () {
    test('is invalidated by a rename and by a delete', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis']),
          buildNote('n2'),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
          buildFilter('s2', includeTags: ['reading']),
        ],
        tags: [buildTag('thesis'), buildTag('reading')],
      );
      await provider.setActiveSpace('s2');
      // Prime the cache with the Space that the rename does NOT touch, so a
      // stale cache cannot be excused by the activation changing.
      expect(provider.scopedNotes, isEmpty);

      await provider.replaceTag('thesis', 'reading');

      expect(provider.scopedNotes.map((n) => n.id), ['n1']);

      await provider.deleteTag('reading');

      // 's2' lost its only include tag, so the scope widens to every note.
      expect(provider.activeSpace, isNull);
      expect(provider.scopedNotes.map((n) => n.id), ['n1', 'n2']);
    });
  });
}
