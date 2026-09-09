import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The store platform is what `SharedPreferences.getInstance()` reads through;
// swapping in a throwing one is the only way to exercise the prefs try/catch
// in SpaceScopeService.load(). It is a transitive dependency of
// shared_preferences and only ever imported from tests.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';

import 'app_provider_space_test.mocks.dart';

/// M2: AppProvider's Space scope, the three creation sinks that stamp, and the
/// leave-set rule. Mockito pattern follows test/app_provider_cache_test.dart.
@GenerateMocks([
  DatabaseService,
  UserAppService,
  ModelStorageService,
  TagImageService,
  AIService,
])
Note buildNote(
  String id, {
  String title = 'title',
  String content = 'content',
  List<String> tags = const [],
  NoteType type = NoteType.note,
  bool isArchived = false,
  bool pinned = false,
  String? scheduledAt,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: title,
    content: content,
    type: type,
    createdAt: now,
    updatedAt: now,
    tags: tags,
    isArchived: isArchived,
    pinned: pinned,
    scheduledAt: scheduledAt,
    status: type == NoteType.task ? TaskStatus.todo : null,
  );
}

Filter buildFilter(
  String id, {
  String? name,
  List<String> includeTags = const [],
  List<String> excludeTags = const [],
  List<NoteType> noteTypes = const [NoteType.note, NoteType.task],
  String? includeText,
  bool includeArchived = false,
  bool isSpace = true,
}) {
  final now = DateTime(2026, 1, 1);
  return Filter(
    id: id,
    name: name ?? id,
    includeTags: includeTags,
    excludeTags: excludeTags,
    noteTypes: noteTypes,
    includeText: includeText,
    includeArchived: includeArchived,
    isSpace: isSpace,
    createdAt: now,
    updatedAt: now,
  );
}

/// A `SharedPreferences` backend where every read and write fails, standing in
/// for a device whose preference store is unavailable (A15).
class _ThrowingPrefsStore extends SharedPreferencesStorePlatform {
  static Never _fail() => throw Exception('preferences unavailable');

  @override
  Future<bool> clear() async => _fail();

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async => _fail();

  @override
  Future<Map<String, Object>> getAll() async => _fail();

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async => _fail();

  @override
  Future<bool> remove(String key) async => _fail();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _fail();
}

Tag buildTag(String name) =>
    Tag(id: 'tag-$name', name: name, color: '#fff', createdAt: DateTime(2026));

void main() {
  late MockDatabaseService mockDb;
  late MockUserAppService mockUserAppService;
  late MockModelStorageService mockModelStorage;
  late MockTagImageService mockTagImages;
  late DataChangeNotifier notifier;
  late SpaceScopeService scope;
  late AppProvider provider;

  /// Stubs a full [AppProvider.loadData] pass over the given data and runs it.
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
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);

    notifier = DataChangeNotifier();
    provider = AppProvider(databaseService: mockDb, changeNotifier: notifier);
  });

  // -------------------------------------------------------------- activation

  group('setActiveSpace', () {
    test('persists under exactly active_space_id, notifies, and pushes the '
        'stamp tags and snapshots into the scope service', () async {
      final space = buildFilter('s1', includeTags: ['thesis', '2026']);
      await load(filters: [space, buildFilter('f1', isSpace: false)]);
      var notifications = 0;
      provider.addListener(() => notifications++);

      expect(await provider.setActiveSpace('s1'), isTrue);

      expect(provider.activeSpace?.id, 's1');
      expect(provider.spaceTags, ['thesis', '2026']);
      expect(notifications, 1);
      expect(scope.activeSpaceId, 's1');
      expect(scope.stampTags, ['thesis', '2026']);
      expect(scope.spaceSnapshots.map((s) => s.id), ['s1']);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_space_id'), 's1');
      expect(prefs.getString(SpaceScopeService.prefsKey), 's1');
    });

    test('null deactivates and clears the persisted id', () async {
      final space = buildFilter('s1', includeTags: ['thesis']);
      await load(filters: [space]);
      await provider.setActiveSpace('s1');

      expect(await provider.setActiveSpace(null), isTrue);

      expect(provider.activeSpace, isNull);
      expect(provider.spaceTags, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_space_id'), isNull);
    });

    test('rejects a filter that is not flagged isSpace', () async {
      await load(
        filters: [
          buildFilter('f1', includeTags: ['x'], isSpace: false),
        ],
      );

      expect(await provider.setActiveSpace('f1'), isFalse);
      expect(provider.activeSpace, isNull);
      expect(scope.activeSpaceId, isNull);
    });

    test('rejects a space with empty include tags', () async {
      await load(filters: [buildFilter('s1', includeTags: const [])]);

      expect(await provider.setActiveSpace('s1'), isFalse);
      expect(provider.activeSpace, isNull);
    });

    // A reserved tag can reach `filters.includeTags` from any of the three
    // activation paths and from a restored backup row; `_isUsableSpace` is the
    // single definition of "is this filter a Space", so refusing it there is
    // what covers all four.
    for (final reserved in [
      SpaceScopeService.allSpacesTag,
      SkillService.agentSkillTag,
    ]) {
      test('rejects a space whose include tags contain "$reserved"', () async {
        await load(
          filters: [
            buildFilter('s1', includeTags: ['thesis', reserved]),
          ],
        );

        expect(await provider.setActiveSpace('s1'), isFalse);
        expect(provider.activeSpace, isNull);
        expect(provider.spaces, isEmpty);
        expect(provider.spaceTags, isEmpty);
        expect(scope.activeSpaceId, isNull);
        expect(
          scope.stampTags,
          isEmpty,
          reason:
              'stamping all-spaces onto every note created in the Space '
              'is exactly what A2 forbids',
        );
      });
    }

    test(
      'a restored backup row flagged isSpace with a reserved tag is inert',
      () async {
        // Recovery writes filter rows straight back, so the flag and the tags
        // arrive together with no dialog in between. The row loads, and stays
        // unusable: unlisted, unactivatable, and stamping nothing.
        await load(
          filters: [
            buildFilter(
              'restored',
              includeTags: [SpaceScopeService.allSpacesTag],
            ),
          ],
        );

        expect(provider.filters, hasLength(1));
        expect(provider.spaces, isEmpty);
        expect(await provider.setActiveSpace('restored'), isFalse);
        expect(provider.activeSpace, isNull);
        expect(provider.spaceTags, isEmpty);
      },
    );

    test('a persisted active id pointing at a reserved-tag Space is dropped '
        'on load', () async {
      SharedPreferences.setMockInitialValues({
        SpaceScopeService.prefsKey: 'restored',
      });
      await load(
        notes: [
          buildNote('n1', tags: ['other']),
        ],
        filters: [
          buildFilter(
            'restored',
            includeTags: [SpaceScopeService.allSpacesTag],
          ),
        ],
      );

      expect(provider.activeSpace, isNull);
      expect(provider.spaceTags, isEmpty);
      // A dangling id means "unscoped", never "empty list" (A3).
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);
    });

    test('rejects an unknown id and leaves the current space alone', () async {
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');

      expect(await provider.setActiveSpace('nope'), isFalse);
      expect(provider.activeSpace?.id, 's1');
    });

    test('spaces lists only flagged filters with include tags', () async {
      await load(
        filters: [
          buildFilter('s1', includeTags: ['a']),
          buildFilter('s2', includeTags: const []),
          buildFilter('f1', includeTags: ['b'], isSpace: false),
        ],
      );

      expect(provider.spaces.map((f) => f.id), ['s1']);
    });
  });

  group('activation lifecycle', () {
    test('a dangling persisted id is dropped on load and leaves notes '
        'unscoped rather than empty', () async {
      SharedPreferences.setMockInitialValues({'active_space_id': 'gone'});

      await load(notes: [buildNote('n1'), buildNote('n2')]);

      expect(provider.activeSpace, isNull);
      expect(provider.scopedNotes, equals(provider.notes));
      expect(provider.scopedNotes.map((n) => n.id), ['n1', 'n2']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_space_id'), isNull);
    });

    test('a persisted space survives a restart', () async {
      SharedPreferences.setMockInitialValues({'active_space_id': 's1'});
      final space = buildFilter('s1', includeTags: ['thesis']);

      // A brand-new provider, as if the app had just launched.
      final restarted = AppProvider(
        databaseService: mockDb,
        changeNotifier: notifier,
      );
      when(mockDb.getAllNotes()).thenAnswer(
        (_) async => [
          buildNote('in', tags: ['thesis']),
          buildNote('out'),
        ],
      );
      when(mockDb.getAllFilters()).thenAnswer((_) async => [space]);
      await restarted.loadData();

      expect(restarted.activeSpace?.id, 's1');
      expect(restarted.spaceTags, ['thesis']);
      expect(restarted.scopedNotes.map((n) => n.id), ['in']);
      restarted.dispose();
    });

    test('deleting the active space deactivates it and clears prefs', () async {
      final space = buildFilter('s1', includeTags: ['thesis']);
      await load(filters: [space]);
      await provider.setActiveSpace('s1');
      when(mockDb.deleteFilter('s1')).thenAnswer((_) async {});

      await provider.deleteFilter('s1');

      expect(provider.activeSpace, isNull);
      expect(scope.activeSpaceId, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_space_id'), isNull);
    });

    test('un-flagging isSpace deactivates', () async {
      final space = buildFilter('s1', includeTags: ['thesis']);
      await load(filters: [space]);
      await provider.setActiveSpace('s1');
      when(mockDb.updateFilter(any)).thenAnswer((_) async {});

      await provider.updateFilter(space.copyWith(isSpace: false));

      expect(provider.activeSpace, isNull);
      expect(provider.spaceTags, isEmpty);
      // `activeSpace`/`spaceTags` re-derive from `_filters` on every read, so
      // they go null on their own even if updateFilter never resynced. Only
      // the scope service pins that the *stamp* actually stopped.
      expect(scope.activeSpaceId, isNull);
      expect(scope.stampTags, isEmpty);
    });

    test('emptying the include tags deactivates', () async {
      final space = buildFilter('s1', includeTags: ['thesis']);
      await load(filters: [space]);
      await provider.setActiveSpace('s1');
      when(mockDb.updateFilter(any)).thenAnswer((_) async {});

      await provider.updateFilter(space.copyWith(includeTags: const []));

      expect(provider.activeSpace, isNull);
      // As above: without these two the test passes with `_syncSpaceState()`
      // deleted from updateFilter, and new notes keep being stamped `thesis`.
      expect(scope.activeSpaceId, isNull);
      expect(scope.stampTags, isEmpty);
    });

    test('editing the include tags re-points the stamp', () async {
      final space = buildFilter('s1', includeTags: ['thesis']);
      await load(filters: [space]);
      await provider.setActiveSpace('s1');
      when(mockDb.updateFilter(any)).thenAnswer((_) async {});

      await provider.updateFilter(
        space.copyWith(includeTags: ['thesis', '2026']),
      );

      expect(provider.spaceTags, ['thesis', '2026']);
      expect(scope.stampTags, ['thesis', '2026']);
    });

    test('an external filtersChanged event that removes the space '
        'deactivates it', () async {
      final space = buildFilter('s1', includeTags: ['thesis']);
      await load(filters: [space]);
      await provider.setActiveSpace('s1');
      when(mockDb.getAllFilters()).thenAnswer((_) async => []);

      notifier.publish(const DataChangeEvent(filtersChanged: true));
      await notifier.waitForIdle();

      expect(provider.activeSpace, isNull);
      expect(scope.activeSpaceId, isNull);
    });

    test('a preferences failure does not break loadData (A15)', () async {
      // SpaceScopeService.load() guards its prefs read the way
      // _loadHierarchyPreference does. A throwing store must degrade to "no
      // active space", never propagate out of loadData and blank the app.
      SharedPreferencesStorePlatform.instance = _ThrowingPrefsStore();

      await load(
        notes: [
          buildNote('n1', tags: ['thesis']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );

      expect(provider.error, isNull);
      expect(provider.notes.map((n) => n.id), ['n1']);
      expect(provider.activeSpace, isNull);
      expect(scope.activeSpaceId, isNull);
      expect(scope.stampTags, isEmpty);
      // Unscoped, not empty: an unreadable preference means "no Space".
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);
    });

    test('a save failure does not break setActiveSpace (A15)', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      SharedPreferencesStorePlatform.instance = _ThrowingPrefsStore();

      expect(await provider.setActiveSpace('s1'), isTrue);

      // The activation holds for this session even though it will not survive
      // a restart.
      expect(provider.activeSpace?.id, 's1');
      expect(scope.stampTags, ['thesis']);
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);
    });

    test('addFilter publishes the new space to the scope service', () async {
      await load();
      when(mockDb.insertFilter(any)).thenAnswer((_) async => 's1');

      await provider.addFilter(buildFilter('s1', includeTags: ['thesis']));

      expect(scope.spaceSnapshots.map((s) => s.id), ['s1']);
      expect(provider.spaces.map((f) => f.id), ['s1']);
    });

    test('clearAllData clears the active space', () async {
      final space = buildFilter('s1', includeTags: ['thesis']);
      await load(filters: [space]);
      await provider.setActiveSpace('s1');
      when(mockDb.clearAllData()).thenAnswer((_) async {});

      await provider.clearAllData();

      expect(provider.activeSpace, isNull);
      expect(scope.activeSpaceId, isNull);
      expect(provider.scopedNotes, equals(provider.notes));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_space_id'), isNull);
    });
  });

  // ------------------------------------------------------------- scopedNotes

  group('scopedNotes', () {
    test(
      'with no active space it holds every note, in the same order (A3)',
      () async {
        await load(notes: [buildNote('a'), buildNote('b'), buildNote('c')]);

        // A3 is equal *content*, not the identical object: the getter hands back
        // an unmodifiable view in both branches (see the next test).
        expect(provider.scopedNotes, equals(provider.notes));
        expect(provider.scopedNotes.map((n) => n.id), ['a', 'b', 'c']);
      },
    );

    test('is unmodifiable in both branches, so a mutating caller fails at the '
        'default state too', () async {
      // Two contracts — a live mutable `_notes` with no space and a copy with
      // one — would let a caller that mutates the result pass every no-space
      // test and crash the first time a user activates a Space.
      await load(
        notes: [
          buildNote('in', tags: ['thesis']),
          buildNote('out'),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );

      expect(
        () => provider.scopedNotes.add(buildNote('x')),
        throwsUnsupportedError,
      );
      expect(() => provider.scopedNotes.removeAt(0), throwsUnsupportedError);

      await provider.setActiveSpace('s1');

      expect(
        () => provider.scopedNotes.add(buildNote('x')),
        throwsUnsupportedError,
      );
      expect(() => provider.scopedNotes.removeAt(0), throwsUnsupportedError);
    });

    test('the no-space branch is a live view, not a snapshot', () async {
      // UnmodifiableListView wraps `_notes` rather than copying it, so it is
      // O(1) and never goes stale between the read and the next mutation.
      await load(notes: [buildNote('a')]);
      final view = provider.scopedNotes;

      await provider.addTagToNote('a', 'reading');

      expect(view.single.tags, ['reading']);
    });

    test(
      'keeps only notes carrying every include tag, in notes order',
      () async {
        await load(
          notes: [
            buildNote('both', tags: ['thesis', '2026']),
            buildNote('one', tags: ['thesis']),
            buildNote('none'),
          ],
          filters: [
            buildFilter('s1', includeTags: ['thesis', '2026']),
          ],
        );
        await provider.setActiveSpace('s1');

        expect(provider.scopedNotes.map((n) => n.id), ['both']);
      },
    );

    test('ignores the space filter\'s includeArchived: archived in-space '
        'notes stay in scope', () async {
      await load(
        notes: [
          buildNote('live', tags: ['thesis']),
          buildNote('filed', tags: ['thesis'], isArchived: true),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis'], includeArchived: false),
        ],
      );
      await provider.setActiveSpace('s1');

      expect(provider.scopedNotes.map((n) => n.id), ['live', 'filed']);
    });

    test('honours the space filter\'s excludeTags and noteTypes', () async {
      await load(
        notes: [
          buildNote('keep', tags: ['thesis']),
          buildNote('excluded', tags: ['thesis', 'draft']),
          buildNote('wrongType', tags: ['thesis'], type: NoteType.task),
        ],
        filters: [
          buildFilter(
            's1',
            includeTags: ['thesis'],
            excludeTags: ['draft'],
            noteTypes: const [NoteType.note],
          ),
        ],
      );
      await provider.setActiveSpace('s1');

      expect(provider.scopedNotes.map((n) => n.id), ['keep']);
    });

    test('all-spaces is an unconditional override of excludeTags, '
        'includeText and noteTypes', () async {
      await load(
        notes: [
          buildNote('member', tags: ['thesis'], content: 'physics'),
          buildNote(
            'everywhere',
            tags: [SpaceScopeService.allSpacesTag, 'draft'],
            title: 'unrelated',
            content: 'nothing to do with it',
            type: NoteType.task,
          ),
        ],
        filters: [
          buildFilter(
            's1',
            includeTags: ['thesis'],
            excludeTags: ['draft'],
            includeText: 'physics',
            noteTypes: const [NoteType.note],
          ),
        ],
      );
      await provider.setActiveSpace('s1');

      expect(provider.scopedNotes.map((n) => n.id), ['member', 'everywhere']);
    });

    test('switching spaces re-scopes immediately', () async {
      await load(
        notes: [
          buildNote('a', tags: ['alpha']),
          buildNote('b', tags: ['beta']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['alpha']),
          buildFilter('s2', includeTags: ['beta']),
        ],
      );

      await provider.setActiveSpace('s1');
      expect(provider.scopedNotes.map((n) => n.id), ['a']);
      await provider.setActiveSpace('s2');
      expect(provider.scopedNotes.map((n) => n.id), ['b']);
      await provider.setActiveSpace(null);
      expect(provider.scopedNotes.map((n) => n.id), ['a', 'b']);
    });
  });

  // Invariant 4 (§3): a Space narrows *lists*, never access. M3 and M5 exist
  // to swap `notes` -> `scopedNotes` at call sites; the same swap on a by-id
  // or by-filter path would quietly make out-of-space notes unreachable, and
  // nothing else in this file would fail.
  group('scope narrows lists, never access (invariant 4)', () {
    test(
      'an out-of-space note stays reachable by id and by saved filter',
      () async {
        final byId = buildFilter(
          'ideas',
          includeTags: ['idea'],
          isSpace: false,
        );
        await load(
          notes: [
            buildNote('inSpace', tags: ['thesis', 'idea']),
            buildNote('outside', tags: ['idea']),
          ],
          filters: [
            buildFilter('s1', includeTags: ['thesis']),
            byId,
          ],
        );
        await provider.setActiveSpace('s1');

        // The list narrows...
        expect(provider.scopedNotes.map((n) => n.id), ['inSpace']);
        expect(provider.scopedNotes.where((n) => n.id == 'outside'), isEmpty);

        // ...and nothing else does. `notes` still resolves it by id,
        expect(provider.notes.where((n) => n.id == 'outside').single.tags, [
          'idea',
        ]);
        // and an unscoped getFilteredNotes still finds it.
        expect(provider.getFilteredNotes(byId).map((n) => n.id).toSet(), {
          'inSpace',
          'outside',
        });
      },
    );
  });

  // K4: two membership predicates that deliberately disagree.
  group('membership predicates', () {
    test(
      'noteInScope is the wider tags-only approximation of _isInSpace',
      () async {
        await load(
          notes: [
            buildNote('n1', tags: ['thesis', 'draft']),
          ],
          filters: [
            buildFilter('s1', includeTags: ['thesis'], excludeTags: ['draft']),
          ],
        );
        await provider.setActiveSpace('s1');

        // Authoritative: the whole Space filter is evaluated, so excludeTags
        // takes the note out of scope.
        expect(provider.scopedNotes, isEmpty);
        // Approximate: SpaceScopeService holds an id and a tag list and cannot
        // see excludeTags/includeText/noteTypes, so it says yes. Deliberate,
        // documented on noteInScope, and pinned here so M5/M6 pick knowingly.
        expect(scope.noteInScope(['thesis', 'draft']), isTrue);
      },
    );
  });

  // C1: the cache must not be keyed on _dataVersion. Each of these mutators
  // rewrites `_notes` and notifies WITHOUT bumping it.
  group('scopedNotes cache invalidation (C1)', () {
    Future<void> loadThesisSpace() async {
      await load(
        notes: [
          buildNote('n1'),
          buildNote('n2', tags: ['thesis']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
        tags: [buildTag('thesis')],
      );
      await provider.setActiveSpace('s1');
      // Prime the cache before mutating.
      expect(provider.scopedNotes.map((n) => n.id), ['n2']);
    }

    test('batchUpdateTags refreshes the scope', () async {
      await loadThesisSpace();

      await provider.batchUpdateTags(['n1'], ['thesis'], const []);

      expect(provider.scopedNotes.map((n) => n.id), ['n1', 'n2']);
    });

    test('addTagToNote refreshes the scope', () async {
      await loadThesisSpace();

      await provider.addTagToNote('n1', 'thesis');

      expect(provider.scopedNotes.map((n) => n.id), ['n1', 'n2']);
    });

    test('removeTagFromNote refreshes the scope', () async {
      await loadThesisSpace();

      await provider.removeTagFromNote('n2', 'thesis');

      expect(provider.scopedNotes, isEmpty);
    });

    test('replaceTag refreshes the scope', () async {
      await loadThesisSpace();
      when(mockDb.replaceTag(any, any)).thenAnswer((_) async {});
      when(mockDb.updateFilter(any)).thenAnswer((_) async {});
      when(mockTagImages.getImagePathForTag(any)).thenReturn(null);

      // Every 'thesis' note becomes 'archive' — and so does the space's own
      // include-tag (G8), so the space follows the rename instead of emptying.
      await provider.replaceTag('thesis', 'archive');

      expect(provider.spaceTags, ['archive']);
      expect(provider.scopedNotes.map((n) => n.id), ['n2']);
      // The cached list is rebuilt, so it carries the renamed tag rather than
      // the note objects captured before the rename.
      expect(provider.scopedNotes.single.tags, ['archive']);
    });

    test('deleteTag refreshes the scope', () async {
      // Deliberately a *two-tag* Space: deleting one of them leaves the Space
      // alive, so `scopedNotes` stays on its cached branch and a stale cache
      // is actually observable. A one-tag Space would be retired by G8 and
      // `scopedNotes` would take the no-Space branch, which never reads the
      // cache — the test would then pass with the invalidation deleted.
      when(mockDb.deleteTag(any)).thenAnswer((_) async {});
      when(mockDb.updateFilter(any)).thenAnswer((_) async {});
      when(mockTagImages.removeTagImage(any)).thenAnswer((_) async {});
      await load(
        notes: [
          buildNote('n1', tags: ['thesis', 'reading']),
          buildNote('n2', tags: ['reading']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis', 'reading']),
        ],
        tags: [buildTag('thesis'), buildTag('reading')],
      );
      await provider.setActiveSpace('s1');
      // Prime the cache: only n1 carries both include tags.
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);

      await provider.deleteTag('thesis');

      // The Space is still a Space — it kept 'reading' — so this reads the
      // cached branch, and the widened membership must be visible in it.
      expect(provider.activeSpace?.id, 's1');
      expect(provider.spaceTags, ['reading']);
      expect(provider.scopedNotes.map((n) => n.id), ['n1', 'n2']);
    });

    test('deleteTag that retires the space widens the scope too', () async {
      // The other half of G8, kept as its own case: deleting the Space's only
      // include-tag un-flags it and the scope widens back to every note (A3).
      await loadThesisSpace();
      when(mockDb.deleteTag(any)).thenAnswer((_) async {});
      when(mockDb.updateFilter(any)).thenAnswer((_) async {});
      when(mockTagImages.removeTagImage(any)).thenAnswer((_) async {});

      await provider.deleteTag('thesis');

      expect(provider.activeSpace, isNull);
      expect(provider.scopedNotes.map((n) => n.id), ['n1', 'n2']);
    });

    test('getAllAvailableTags is invalidated alongside it', () async {
      await loadThesisSpace();
      expect(provider.getAllAvailableTags(), isEmpty);

      await provider.batchUpdateTags(['n2'], ['reading'], const []);

      expect(provider.getAllAvailableTags(), ['reading']);
    });
  });

  // ------------------------------------------------------------- tag listing

  group('getAllAvailableTags', () {
    test('is scoped by default, drops the space\'s own tags, and does not '
        'poison the unscoped cache in the same cycle', () async {
      await load(
        notes: [
          buildNote('in', tags: ['thesis', 'reading']),
          buildNote('out', tags: ['cooking']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');

      // Both modes answered inside one notify cycle, with a Space active so
      // the two answers differ. A single-slot memo would hand the second
      // caller the first caller's answer and pass a one-mode-per-test suite.
      expect(provider.getAllAvailableTags(), ['reading']);
      expect(provider.getAllAvailableTags(scoped: false), [
        'cooking',
        'reading',
        'thesis',
      ]);
      // ...and again with both slots warm, in the other order.
      expect(provider.getAllAvailableTags(scoped: false), [
        'cooking',
        'reading',
        'thesis',
      ]);
      expect(provider.getAllAvailableTags(), ['reading']);
    });

    test('keeps all-spaces in the scoped list (S25)', () async {
      // Ruled deliberate, not an oversight: a Space's own include-tags sit on
      // every note in scope and so carry no information, which is why they are
      // subtracted. `all-spaces` is carried by only a subset, so it is a
      // genuinely useful chip — "show me the cross-space notes". A later
      // milestone must not tidy it away as scope plumbing.
      await load(
        notes: [
          buildNote('member', tags: ['thesis', 'reading']),
          buildNote('everywhere', tags: [SpaceScopeService.allSpacesTag]),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');

      expect(provider.getAllAvailableTags(), [
        SpaceScopeService.allSpacesTag,
        'reading',
      ]);
    });

    test('scoped: false lists every tag including the space\'s own', () async {
      await load(
        notes: [
          buildNote('in', tags: ['thesis', 'reading']),
          buildNote('out', tags: ['cooking']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');

      expect(provider.getAllAvailableTags(scoped: false), [
        'cooking',
        'reading',
        'thesis',
      ]);
    });

    test('with no active space the two modes agree', () async {
      await load(
        notes: [
          buildNote('a', tags: ['b', 'a']),
        ],
      );

      expect(provider.getAllAvailableTags(), ['a', 'b']);
      expect(provider.getAllAvailableTags(scoped: false), ['a', 'b']);
    });
  });

  // ---------------------------------------------------------------- stamping

  group('addNote stamping', () {
    Future<void> activateThesis() async {
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis', '2026']),
        ],
      );
      await provider.setActiveSpace('s1');
    }

    test(
      'stamps by default, before the insert, as an order-preserving union',
      () async {
        await activateThesis();
        final note = buildNote('n1', tags: ['reading', 'thesis']);
        when(mockDb.getNote('n1')).thenAnswer((_) async => note);

        await provider.addNote(note);

        final inserted =
            verify(mockDb.insertNote(captureAny)).captured.single as Note;
        expect(inserted.tags, ['reading', 'thesis', '2026']);
      },
    );

    test('does not stamp with applySpaceTags: false', () async {
      await activateThesis();
      final note = buildNote('n1', tags: ['reading']);
      when(mockDb.getNote('n1')).thenAnswer((_) async => note);

      await provider.addNote(note, applySpaceTags: false);

      final inserted =
          verify(mockDb.insertNote(captureAny)).captured.single as Note;
      expect(inserted.tags, ['reading']);
    });

    test('fromShare and applySpaceTags are orthogonal', () async {
      await activateThesis();
      final shared = buildNote('n1');
      when(mockDb.getNote('n1')).thenAnswer((_) async => shared);

      await provider.addNote(shared, fromShare: true);
      expect(provider.newNoteFromShare, isTrue);
      var inserted =
          verify(mockDb.insertNote(captureAny)).captured.single as Note;
      expect(inserted.tags, ['thesis', '2026']);

      final opted = buildNote('n2');
      when(mockDb.getNote('n2')).thenAnswer((_) async => opted);
      await provider.addNote(opted, fromShare: true, applySpaceTags: false);
      inserted = verify(mockDb.insertNote(captureAny)).captured.single as Note;
      expect(inserted.tags, isEmpty);
    });

    test('is a no-op with no active space', () async {
      await load();
      final note = buildNote('n1', tags: ['reading']);
      when(mockDb.getNote('n1')).thenAnswer((_) async => note);

      await provider.addNote(note);

      final inserted =
          verify(mockDb.insertNote(captureAny)).captured.single as Note;
      expect(inserted.tags, ['reading']);
    });

    test('never adds all-spaces', () async {
      await activateThesis();
      final note = buildNote('n1');
      when(mockDb.getNote('n1')).thenAnswer((_) async => note);

      await provider.addNote(note);

      final inserted =
          verify(mockDb.insertNote(captureAny)).captured.single as Note;
      expect(inserted.tags, isNot(contains(SpaceScopeService.allSpacesTag)));
    });
  });

  group('updateNote never stamps', () {
    test('an existing note keeps exactly the tags it was given', () async {
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');
      final note = buildNote('n1', tags: ['reading']);
      when(mockDb.getNote('n1')).thenAnswer((_) async => note);

      await provider.updateNote(note);

      final updated =
          verify(mockDb.updateNote(captureAny)).captured.single as Note;
      expect(updated.tags, ['reading']);
    });
  });

  group('createNewNotes stamping', () {
    test('stamps every generated note before persisting it', () async {
      final mockAi = MockAIService();
      getIt.registerSingleton<AIService>(mockAi);
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');

      final generated = [
        buildNote('g1', tags: ['idea']),
        buildNote('g2'),
      ];
      when(
        mockAi.createNewNotes(
          any,
          any,
          attachedFiles: anyNamed('attachedFiles'),
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => generated);
      when(mockDb.getNote(any)).thenAnswer(
        (inv) async => buildNote(inv.positionalArguments.first as String),
      );

      await provider.createNewNotes('prompt', const []);

      final inserted = verify(
        mockDb.insertNote(captureAny),
      ).captured.cast<Note>();
      expect(inserted.map((n) => n.tags), [
        ['idea', 'thesis'],
        ['thesis'],
      ]);
    });

    test('does not stamp when persist is false', () async {
      final mockAi = MockAIService();
      getIt.registerSingleton<AIService>(mockAi);
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');
      when(
        mockAi.createNewNotes(
          any,
          any,
          attachedFiles: anyNamed('attachedFiles'),
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => [buildNote('g1')]);

      final result = await provider.createNewNotes(
        'prompt',
        const [],
        persist: false,
      );

      expect(result.single.tags, isEmpty);
      verifyNever(mockDb.insertNote(any));
    });
  });

  // ------------------------------------------------------------- join /leave

  group('joinSpace / leaveSpace', () {
    test('joinSpace adds the space tags and reports success', () async {
      await load(
        notes: [buildNote('n1')],
        filters: [
          buildFilter('s1', includeTags: ['thesis', '2026']),
        ],
      );

      expect(await provider.joinSpace(['n1'], 's1'), isTrue);

      final updated =
          verify(mockDb.updateNote(captureAny)).captured.single as Note;
      expect(updated.tags.toSet(), {'thesis', '2026'});
    });

    test('joinSpace reports failure when the write fails', () async {
      await load(
        notes: [buildNote('n1')],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      when(mockDb.updateNote(any)).thenThrow(Exception('disk full'));

      expect(await provider.joinSpace(['n1'], 's1'), isFalse);
    });

    test('both reject an unknown space and leave every note alone', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis']),
        ],
        filters: [
          buildFilter('f1', includeTags: ['thesis'], isSpace: false),
        ],
      );

      expect(await provider.joinSpace(['n1'], 'nope'), isFalse);
      expect(await provider.leaveSpace(['n1'], 'nope'), isFalse);
      // A plain filter is not a Space, however well-formed.
      expect(await provider.joinSpace(['n1'], 'f1'), isFalse);
      expect(await provider.leaveSpace(['n1'], 'f1'), isFalse);
      verifyNever(mockDb.updateNote(any));
    });

    test('an empty note list is a vacuous success for both', () async {
      await load(
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );

      expect(await provider.joinSpace(const [], 's1'), isTrue);
      expect(await provider.leaveSpace(const [], 's1'), isTrue);
      verifyNever(mockDb.updateNote(any));
    });

    test('leaveSpace keeps a tag another space the note still matches also '
        'requires', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis', '2026', 'reading']),
        ],
        filters: [
          buildFilter('thesis', includeTags: ['thesis', '2026']),
          buildFilter('reading', includeTags: ['reading', '2026']),
        ],
      );

      expect(await provider.leaveSpace(['n1'], 'thesis'), isTrue);

      final updated =
          verify(mockDb.updateNote(captureAny)).captured.single as Note;
      expect(updated.tags.toSet(), {'2026', 'reading'});
    });

    test(
      'leaveSpace removes everything when no other space claims the tags',
      () async {
        await load(
          notes: [
            buildNote('n1', tags: ['thesis', '2026', 'idea']),
          ],
          filters: [
            buildFilter('thesis', includeTags: ['thesis', '2026']),
          ],
        );

        await provider.leaveSpace(['n1'], 'thesis');

        final updated =
            verify(mockDb.updateNote(captureAny)).captured.single as Note;
        expect(updated.tags.toSet(), {'idea'});
      },
    );

    test(
      'a plain filter with an overlapping tag does not protect it (J6)',
      () async {
        // The leave-set is computed from `spaces`, not from `_filters`: only an
        // isSpace filter is membership. A saved filter that happens to include
        // the same tag must not hold it back — sourcing `others` from `_filters`
        // instead would keep `2026` here and break nothing else in this file.
        await load(
          notes: [
            buildNote('n1', tags: ['thesis', '2026']),
          ],
          filters: [
            buildFilter('thesis', includeTags: ['thesis', '2026']),
            buildFilter('plain', includeTags: ['2026'], isSpace: false),
          ],
        );

        expect(await provider.leaveSpace(['n1'], 'thesis'), isTrue);

        final updated =
            verify(mockDb.updateNote(captureAny)).captured.single as Note;
        expect(updated.tags, isEmpty);
      },
    );

    test('leaveSpace reports failure when a write fails', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      when(mockDb.updateNote(any)).thenThrow(Exception('disk full'));

      expect(await provider.leaveSpace(['n1'], 's1'), isFalse);
    });

    test(
      'success is read from the write, not from the shared error field',
      () async {
        // `_error` is shared mutable state: clearing it to use as a success flag
        // wipes an error the UI is showing, and a pre-existing error must not be
        // mistaken for this join failing.
        await load(
          notes: [buildNote('n1')],
          filters: [
            buildFilter('s1', includeTags: ['thesis']),
          ],
        );
        // An unrelated write fails first and leaves its message in `error`.
        when(mockDb.updateNote(any)).thenThrow(Exception('unrelated failure'));
        await provider.addTagToNote('n1', 'unrelated');
        expect(provider.error, contains('unrelated failure'));
        when(mockDb.updateNote(any)).thenAnswer((_) async {});

        expect(await provider.joinSpace(['n1'], 's1'), isTrue);

        // The join reported its own outcome — reading `_error` back would have
        // called this success a failure — and left the standing error on screen
        // instead of silently clearing it.
        final updated =
            verify(mockDb.updateNote(captureAny)).captured.last as Note;
        expect(updated.tags, ['thesis']);
        expect(provider.error, contains('unrelated failure'));
      },
    );

    test(
      'leaveSpace ignores a space the note does not actually belong to',
      () async {
        // Reading requires {reading, 2026}; the note has reading but not 2026,
        // so it is not a member and cannot protect 2026.
        await load(
          notes: [
            buildNote('n1', tags: ['thesis', '2026', 'reading']),
          ],
          filters: [
            buildFilter('thesis', includeTags: ['thesis', '2026']),
            buildFilter('reading', includeTags: ['reading', '2026', 'lit']),
          ],
        );

        await provider.leaveSpace(['n1'], 'thesis');

        final updated =
            verify(mockDb.updateNote(captureAny)).captured.single as Note;
        expect(updated.tags.toSet(), {'reading'});
      },
    );

    test('leaveSpace never removes all-spaces', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['thesis', SpaceScopeService.allSpacesTag]),
        ],
        filters: [
          buildFilter('thesis', includeTags: ['thesis']),
        ],
      );

      await provider.leaveSpace(['n1'], 'thesis');

      final updated =
          verify(mockDb.updateNote(captureAny)).captured.single as Note;
      expect(updated.tags, [SpaceScopeService.allSpacesTag]);
    });

    test(
      'a filter that includes a reserved tag is not a Space to leave',
      () async {
        // Belt and braces for the same guarantee from the other side: such a
        // filter can no longer be a Space at all, so `leaveSpace` has no Space
        // to act on and writes nothing.
        await load(
          notes: [
            buildNote('n1', tags: ['thesis', SpaceScopeService.allSpacesTag]),
          ],
          filters: [
            buildFilter(
              'weird',
              includeTags: ['thesis', SpaceScopeService.allSpacesTag],
            ),
          ],
        );

        expect(await provider.leaveSpace(['n1'], 'weird'), isFalse);
        verifyNever(mockDb.updateNote(any));
      },
    );

    test('leaveSpace computes the removal set per note', () async {
      await load(
        notes: [
          buildNote('shared', tags: ['thesis', '2026', 'reading']),
          buildNote('lonely', tags: ['thesis', '2026']),
        ],
        filters: [
          buildFilter('thesis', includeTags: ['thesis', '2026']),
          buildFilter('reading', includeTags: ['reading', '2026']),
        ],
      );

      await provider.leaveSpace(['shared', 'lonely'], 'thesis');

      final updated = verify(
        mockDb.updateNote(captureAny),
      ).captured.cast<Note>();
      expect(
        {for (final n in updated) n.id: n.tags.toSet()},
        {
          'shared': {'2026', 'reading'},
          'lonely': <String>{},
        },
      );
    });

    test('leaveSpace is a no-op for a note that is not in the space', () async {
      await load(
        notes: [
          buildNote('n1', tags: ['cooking']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );

      expect(await provider.leaveSpace(['n1'], 's1'), isTrue);
      verifyNever(mockDb.updateNote(any));
    });

    test('joining then leaving round-trips through scopedNotes', () async {
      await load(
        notes: [buildNote('n1')],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );
      await provider.setActiveSpace('s1');
      expect(provider.scopedNotes, isEmpty);

      await provider.joinSpace(['n1'], 's1');
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);

      await provider.leaveSpace(['n1'], 's1');
      expect(provider.scopedNotes, isEmpty);
    });
  });

  // ------------------------------------------------------------ derived list

  group('date lists are scoped', () {
    test('getTasksForDate and getNotesForDate honour the space', () async {
      await load(
        notes: [
          buildNote(
            'inTask',
            tags: ['thesis'],
            type: NoteType.task,
            scheduledAt: '2026-03-04',
            createdAt: DateTime(2026, 3, 4),
          ),
          buildNote(
            'outTask',
            type: NoteType.task,
            scheduledAt: '2026-03-04',
            createdAt: DateTime(2026, 3, 4),
          ),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
        ],
      );

      expect(provider.getTasksForDate(DateTime(2026, 3, 4)).map((n) => n.id), [
        'inTask',
        'outTask',
      ]);
      expect(provider.getNotesForDate(DateTime(2026, 3, 4)).map((n) => n.id), [
        'inTask',
        'outTask',
      ]);

      await provider.setActiveSpace('s1');

      expect(provider.getTasksForDate(DateTime(2026, 3, 4)).map((n) => n.id), [
        'inTask',
      ]);
      expect(provider.getNotesForDate(DateTime(2026, 3, 4)).map((n) => n.id), [
        'inTask',
      ]);
    });
  });

  // C2: getFilteredNotes starts from `_notes` unless given a base, and the
  // notes screen calls it for every saved-filter tab.
  group('getFilteredNotes base (C2)', () {
    late Filter customFilter;

    Future<void> loadWithCustomFilter() async {
      customFilter = buildFilter(
        'custom',
        includeTags: ['idea'],
        isSpace: false,
      );
      await load(
        notes: [
          buildNote('inSpace', tags: ['thesis', 'idea']),
          buildNote('outsideSpace', tags: ['idea']),
        ],
        filters: [
          buildFilter('s1', includeTags: ['thesis']),
          customFilter,
        ],
      );
      await provider.setActiveSpace('s1');
    }

    test('a custom filter given scopedNotes stays inside the space', () async {
      await loadWithCustomFilter();

      final result = provider.getFilteredNotes(
        customFilter,
        base: provider.scopedNotes,
      );

      expect(result.map((n) => n.id), ['inSpace']);
    });

    test(
      'without a base it still sees every note (the default is _notes)',
      () async {
        await loadWithCustomFilter();

        final result = provider.getFilteredNotes(customFilter);

        expect(result.map((n) => n.id).toSet(), {'inSpace', 'outsideSpace'});
      },
    );

    test('an empty base yields nothing', () async {
      await loadWithCustomFilter();

      expect(provider.getFilteredNotes(customFilter, base: const []), isEmpty);
    });

    test('still applies archived, text, exclude and type criteria, pinned '
        'first', () async {
      final now = DateTime(2026, 5, 1);
      await load(
        notes: [
          buildNote('old', content: 'physics', createdAt: now),
          buildNote(
            'new',
            content: 'physics',
            createdAt: now.add(const Duration(days: 1)),
          ),
          buildNote(
            'pinnedOld',
            content: 'physics',
            pinned: true,
            createdAt: now.subtract(const Duration(days: 5)),
          ),
          buildNote('archived', content: 'physics', isArchived: true),
          buildNote('noMatch', content: 'chemistry'),
          buildNote('excluded', content: 'physics', tags: ['draft']),
          buildNote('task', content: 'physics', type: NoteType.task),
        ],
      );

      final result = provider.getFilteredNotes(
        buildFilter(
          'f',
          includeText: 'physics',
          excludeTags: ['draft'],
          noteTypes: const [NoteType.note],
          isSpace: false,
        ),
      );

      expect(result.map((n) => n.id), ['pinnedOld', 'new', 'old']);
    });

    test('does not reorder the provider\'s own notes list', () async {
      await load(
        notes: [
          buildNote('a', createdAt: DateTime(2026, 1, 1)),
          buildNote('b', createdAt: DateTime(2026, 2, 1)),
        ],
      );

      // A filter with no criteria at all: the one shape that used to hand the
      // caller `_notes` itself and then sort it in place.
      final result = provider.getFilteredNotes(
        buildFilter(
          'f',
          noteTypes: const [],
          includeArchived: true,
          isSpace: false,
        ),
      );

      expect(result.map((n) => n.id), ['b', 'a']);
      expect(provider.notes.map((n) => n.id), ['a', 'b']);
      expect(provider.scopedNotes.map((n) => n.id), ['a', 'b']);
    });
  });
}
