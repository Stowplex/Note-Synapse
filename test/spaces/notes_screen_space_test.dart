import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/screens/notes_screen.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:note_synapse/widgets/filter_tab_strip.dart';
import 'package:note_synapse/widgets/hierarchy_dialog.dart';
import 'package:note_synapse/widgets/multi_select_tag_filter.dart';
import 'package:note_synapse/widgets/note_card.dart';
import 'package:note_synapse/widgets/space_switcher.dart';

import 'notes_screen_space_test.mocks.dart';

/// M3: the notes screen inside a Space — scoped list, scoped chips, the space
/// switcher, the *Activate as space* affordance and the filters dialog's
/// Space row. Real [AppProvider] over a mocked database, so the scope
/// predicate and `getFilteredNotes` under test are the production ones.
@GenerateMocks([
  DatabaseService,
  UserAppService,
  ModelStorageService,
  TagImageService,
])
void main() {
  late MockDatabaseService mockDb;
  late MockUserAppService mockUserAppService;
  late MockModelStorageService mockModelStorage;
  late MockTagImageService mockTagImages;
  late AppProvider provider;

  Note note(
    String id, {
    List<String> tags = const [],
    bool archived = false,
    bool pinned = false,
    NoteType type = NoteType.note,
  }) => Note(
    id: id,
    title: id,
    content: 'body',
    type: type,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    tags: tags,
    isArchived: archived,
    pinned: pinned,
    status: type == NoteType.task ? TaskStatus.todo : null,
  );

  Filter filter(
    String id, {
    String? name,
    List<String> includeTags = const [],
    bool isSpace = false,
    bool includeArchived = false,
  }) => Filter(
    id: id,
    name: name ?? id,
    includeTags: includeTags,
    isSpace: isSpace,
    includeArchived: includeArchived,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Warm the singleton outside the widget binding's fake async, so a
    // `setActiveSpace` driven from a tap resolves without waiting on a channel.
    await SharedPreferences.getInstance();
    await resetForTesting();

    mockDb = MockDatabaseService();
    mockUserAppService = MockUserAppService();
    mockModelStorage = MockModelStorageService();
    mockTagImages = MockTagImageService();
    getIt.registerSingleton<UserAppService>(mockUserAppService);
    getIt.registerSingleton<ModelStorageService>(mockModelStorage);
    getIt.registerSingleton<TagImageService>(mockTagImages);
    getIt.registerSingleton<SpaceScopeService>(SpaceScopeService());

    when(mockDb.getAllNotes()).thenAnswer((_) async => []);
    when(mockDb.getAllTags()).thenAnswer((_) async => <Tag>[]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionApps()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionDefaultAppId()).thenAnswer((_) async => null);
    when(mockDb.updateNote(any)).thenAnswer((_) async {});
    when(mockDb.updateFilter(any)).thenAnswer((_) async {});
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    when(mockTagImages.getImagePathForTag(any)).thenReturn(null);
    when(mockTagImages.getImagePathsForTags(any)).thenReturn([]);
    when(mockTagImages.appDocsPath).thenReturn(null);
  });

  tearDown(() async {
    await resetForTesting();
  });

  /// Builds the provider and loads [notes] and [filters] into it, optionally
  /// activating a Space.
  ///
  /// The provider is constructed **here, in the test body**, and the load is
  /// deliberately not wrapped in `tester.runAsync`. `AppProvider._withCacheLock`
  /// serializes every locked call on a future chain seeded at construction, and
  /// a future created outside the widget binding's fake clock (in `setUp`, or
  /// inside `runAsync`) schedules its listeners on the real microtask queue,
  /// which the fake clock never drains — every locked call would then hang, or
  /// a later `setActiveSpace` driven from a tap would never complete.
  Future<void> load({
    List<Note> notes = const [],
    List<Filter> filters = const [],
    String? activeSpaceId,
  }) async {
    provider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
    when(mockDb.getAllNotes()).thenAnswer((_) async => [...notes]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => [...filters]);
    await provider.loadData();
    if (activeSpaceId != null) {
      expect(await provider.setActiveSpace(activeSpaceId), isTrue);
    }
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    // The AppBar carries a title, four actions, a search field and the filter
    // strip; a phone-sized surface overflows before any Space logic runs.
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const NotesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The notes actually rendered, by title.
  List<String> visible(WidgetTester tester) => tester
      .widgetList<NoteCard>(find.byType(NoteCard))
      .map((card) => card.note.title)
      .toList();

  /// Taps one of the built-in tabs (Active / Pinned / Archived / All). The
  /// action group precedes the custom tabs in the strip, so `.first` is it.
  Future<void> tapBuiltInTab(WidgetTester tester, IconData icon) async {
    await tester.tap(
      find
          .descendant(
            of: find.byType(FilterTabStrip),
            matching: find.byIcon(icon),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSwitcher(WidgetTester tester) async {
    await tester.tap(find.byType(SpaceSwitcher));
    await tester.pumpAndSettle();
  }

  Future<void> tapMenuItem(WidgetTester tester, String label) async {
    // Tap the menu *item*, not its label: the label's centre is not
    // hit-testable, so tapping it dispatches an offset the framework warns
    // about and which only lands on the right row by luck of layout.
    // `find.byType` matches the exact runtime type and the Space entries are
    // CheckedPopupMenuItems, so match the supertype by predicate instead.
    await tester.tap(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem<String>),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  /// Applies tag chips the way [MultiSelectTagFilter] does when the user picks
  /// tags, without driving its tag-picker dialog.
  Future<void> applyChips(WidgetTester tester, Set<String> tags) async {
    tester
        .widget<MultiSelectTagFilter>(find.byType(MultiSelectTagFilter))
        .onSelectionChanged(tags);
    await tester.pumpAndSettle();
  }

  /// The tab selection the strip is currently rendering.
  Set<String> selection(WidgetTester tester) => tester
      .widget<FilterTabStrip>(find.byType(FilterTabStrip))
      .selectedFilterIds;

  /// Taps the custom filter tab labelled [name].
  Future<void> tapTab(WidgetTester tester, String name) async {
    await tester.tap(
      find.descendant(
        of: find.byType(FilterTabStrip),
        matching: find.text(name),
      ),
    );
    await tester.pumpAndSettle();
  }

  final space = filter('space', name: 'Thesis', includeTags: ['thesis'],
      isSpace: true);

  group('scoped list', () {
    testWidgets('shows the Space\'s notes plus all-spaces notes', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('outside', tags: ['recipes']),
          note('everywhere', tags: [SpaceScopeService.allSpacesTag]),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      expect(visible(tester), unorderedEquals(['inside', 'everywhere']));
    });

    testWidgets('a custom filter tab stays inside the Space (C2)', (
      tester,
    ) async {
      final urgent = filter('urgent', name: 'Urgent',
          includeTags: ['urgent']);
      await load(
        notes: [
          note('inside-urgent', tags: ['thesis', 'urgent']),
          note('inside-calm', tags: ['thesis']),
          note('outside-urgent', tags: ['urgent']),
        ],
        filters: [space, urgent],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      await tester.tap(find.text('Urgent'));
      await tester.pumpAndSettle();

      // Without `base:` the saved filter would reach past the Space and show
      // `outside-urgent` as well.
      expect(visible(tester), ['inside-urgent']);
    });

    testWidgets('Archived shows the Space\'s archived notes, Active hides '
        'them (A5)', (tester) async {
      await load(
        notes: [
          note('active', tags: ['thesis']),
          note('archived', tags: ['thesis'], archived: true),
          note('outside-archived', tags: ['recipes'], archived: true),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      expect(visible(tester), ['active']);

      await tapBuiltInTab(tester, Icons.archive);
      // The Space's own filter says includeArchived: false; the scope forces
      // it true so the tab can decide.
      expect(visible(tester), ['archived']);
    });

    testWidgets('Pinned means pinned within the Space', (tester) async {
      await load(
        notes: [
          note('inside-pinned', tags: ['thesis'], pinned: true),
          note('inside-plain', tags: ['thesis']),
          note('outside-pinned', tags: ['recipes'], pinned: true),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      await tapBuiltInTab(tester, Icons.push_pin);
      expect(visible(tester), ['inside-pinned']);
    });

    testWidgets('composition order is scope → tab → chips → search', (
      tester,
    ) async {
      await load(
        notes: [
          note('Keep', tags: ['thesis', 'urgent']),
          note('DropByScope', tags: ['urgent']),
          note('DropByTab', tags: ['thesis', 'urgent'], archived: true),
          note('DropByChip', tags: ['thesis']),
          note('DropBySearch', tags: ['thesis', 'urgent']),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      await tapBuiltInTab(tester, Icons.list); // All
      expect(
        visible(tester),
        unorderedEquals(['Keep', 'DropByTab', 'DropByChip', 'DropBySearch']),
      );

      await tapBuiltInTab(tester, Icons.note); // Active
      expect(
        visible(tester),
        unorderedEquals(['Keep', 'DropByChip', 'DropBySearch']),
      );

      await applyChips(tester, {'urgent'});
      expect(visible(tester), unorderedEquals(['Keep', 'DropBySearch']));

      await tester.enterText(find.byType(TextField).first, 'Keep');
      await tester.pumpAndSettle();
      expect(visible(tester), ['Keep']);
    });

    testWidgets('with no active Space nothing is filtered out', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('outside', tags: ['recipes']),
        ],
        filters: [space],
      );
      await pumpScreen(tester);

      expect(visible(tester), unorderedEquals(['inside', 'outside']));
    });
  });

  group('space chrome', () {
    testWidgets('the switcher shows the Space name and the Space\'s own tab '
        'is absent', (tester) async {
      final other = filter('other', name: 'Recipes',
          includeTags: ['recipes']);
      await load(
        notes: [note('inside', tags: ['thesis'])],
        filters: [space, other],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      expect(
        find.descendant(
          of: find.byType(SpaceSwitcher),
          matching: find.text('Thesis'),
        ),
        findsOneWidget,
      );
      // The Space's criteria already apply to every list, so its tab would be
      // a no-op; other filters keep their tabs.
      expect(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.text('Thesis'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.text('Recipes'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('leaving through the switcher restores the full list', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('outside', tags: ['recipes']),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);
      expect(visible(tester), ['inside']);

      await openSwitcher(tester);
      await tapMenuItem(tester, 'All Notes');

      expect(provider.activeSpace, isNull);
      expect(visible(tester), unorderedEquals(['inside', 'outside']));
      expect(
        find.descendant(
          of: find.byType(SpaceSwitcher),
          matching: find.text('Notes'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the switcher activates a Space from the unscoped list', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('outside', tags: ['recipes']),
        ],
        filters: [space],
      );
      await pumpScreen(tester);

      await openSwitcher(tester);
      await tapMenuItem(tester, 'Thesis');

      expect(provider.activeSpace?.id, 'space');
      expect(visible(tester), ['inside']);
    });

    testWidgets('the switcher clears a tab selection the new Space hides', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('everywhere', tags: [SpaceScopeService.allSpacesTag]),
          note('outside', tags: ['recipes']),
        ],
        filters: [space],
      );
      await pumpScreen(tester);

      // Same stale-selection trap as the long-press route, reached from the
      // switcher: the tab is selected while the Space is not yet active.
      await tapTab(tester, 'Thesis');
      expect(visible(tester), ['inside']);

      await openSwitcher(tester);
      await tapMenuItem(tester, 'Thesis');

      expect(provider.activeSpace?.id, 'space');
      expect(selection(tester), {'default'});
      expect(visible(tester), unorderedEquals(['inside', 'everywhere']));
    });

    testWidgets('the switcher renders the Space\'s tag image', (tester) async {
      when(
        mockTagImages.getImagePathForTag('thesis'),
      ).thenReturn('builtin:landscape-sunset');
      await load(
        notes: [note('inside', tags: ['thesis'])],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      final avatar = find.descendant(
        of: find.byType(SpaceSwitcher),
        matching: find.byType(CircleAvatar),
      );
      expect(avatar, findsOneWidget);
      // A tag image whose file has since gone must degrade the way every other
      // tag-image renderer in the app does, not throw out of the image stream.
      expect(
        tester.widget<CircleAvatar>(avatar).onBackgroundImageError,
        isNotNull,
      );
    });

    testWidgets('a user tag image with no docs path shows no avatar', (
      tester,
    ) async {
      when(
        mockTagImages.getImagePathForTag('thesis'),
      ).thenReturn('tag_images/thesis.png');
      when(mockTagImages.appDocsPath).thenReturn(null);
      await load(
        notes: [note('inside', tags: ['thesis'])],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      // A relative user-image path is unresolvable without the documents
      // directory, so the switcher falls back to the bare name rather than
      // building a FileImage over a path that cannot exist.
      expect(
        find.descendant(
          of: find.byType(SpaceSwitcher),
          matching: find.byType(CircleAvatar),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SpaceSwitcher),
          matching: find.text('Thesis'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Manage spaces lists the Spaces and can drop the role', (
      tester,
    ) async {
      final other = filter('other', name: 'Recipes',
          includeTags: ['recipes'], isSpace: true);
      await load(
        notes: [note('inside', tags: ['thesis'])],
        filters: [space, other],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      await openSwitcher(tester);
      await tapMenuItem(tester, 'Manage spaces…');

      expect(find.byType(ManageSpacesDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ManageSpacesDialog),
          matching: find.text('Recipes'),
        ),
        findsOneWidget,
      );

      // Dropping the role on the *active* Space deactivates it: `updateFilter`
      // re-resolves the activation against the new flag.
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Thesis'),
            matching: find.byType(ListTile),
          ),
          matching: find.byTooltip('Stop using as space'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        provider.filters.firstWhere((f) => f.id == 'space').isSpace,
        isFalse,
      );
      expect(provider.activeSpace, isNull);
    });

    testWidgets('tag chips are scoped and drop the Space\'s own tags', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis', 'urgent']),
          note('outside', tags: ['recipes']),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      final chips = tester.widget<MultiSelectTagFilter>(
        find.byType(MultiSelectTagFilter),
      );
      // 'recipes' is out of scope; 'thesis' is carried by every note in scope
      // and would be a useless chip.
      expect(chips.availableTags, ['all', 'urgent']);
      expect(
        tester
            .widget<FilterTabStrip>(find.byType(FilterTabStrip))
            .availableTags,
        ['all', 'urgent'],
      );
    });

    testWidgets('the Space survives a MainScreen tab switch', (tester) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('outside', tags: ['recipes']),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);
      expect(visible(tester), ['inside']);

      // MainScreen builds `_screens[_currentIndex]`, so the notes screen is
      // disposed on every tab switch. The Space lives in AppProvider, not in
      // screen state.
      await tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: Text('other tab'))),
        ),
      );
      await tester.pumpAndSettle();
      await pumpScreen(tester);

      expect(visible(tester), ['inside']);
      expect(
        find.descendant(
          of: find.byType(SpaceSwitcher),
          matching: find.text('Thesis'),
        ),
        findsOneWidget,
      );
    });
  });

  group('activate as space (C4)', () {
    testWidgets('long-pressing a tab sets isSpace and activates it', (
      tester,
    ) async {
      final recipes = filter('recipes', name: 'Recipes',
          includeTags: ['recipes']);
      await load(
        notes: [
          note('inside', tags: ['recipes']),
          note('outside', tags: ['thesis']),
        ],
        filters: [recipes],
      );
      await pumpScreen(tester);

      await tester.longPress(find.text('Recipes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activate as space'));
      await tester.pumpAndSettle();

      expect(
        provider.filters.firstWhere((f) => f.id == 'recipes').isSpace,
        isTrue,
      );
      expect(provider.activeSpace?.id, 'recipes');
      expect(visible(tester), ['inside']);
      // Its own tab disappears once it is the active Space.
      expect(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.text('Recipes'),
        ),
        findsNothing,
      );
    });

    testWidgets('activating the *selected* tab clears the selection', (
      tester,
    ) async {
      final recipes = filter('recipes', name: 'Recipes',
          includeTags: ['recipes']);
      await load(
        notes: [
          note('inside', tags: ['recipes']),
          note('everywhere', tags: [SpaceScopeService.allSpacesTag]),
          note('inside-archived', tags: ['recipes'], archived: true),
          note('outside', tags: ['thesis']),
        ],
        filters: [recipes],
      );
      await pumpScreen(tester);

      // Selecting the tab *first* is what makes this bite: the activated
      // filter loses its tab, so a selection left pointing at it selects
      // nothing visible and keeps re-applying the Space's own criteria over
      // the already-scoped list — dropping every `all-spaces` note (A1) and
      // every archived one (A5).
      await tapTab(tester, 'Recipes');
      expect(visible(tester), ['inside']);

      await tester.longPress(find.text('Recipes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activate as space'));
      await tester.pumpAndSettle();

      expect(provider.activeSpace?.id, 'recipes');
      expect(visible(tester), unorderedEquals(['inside', 'everywhere']));
      expect(selection(tester), {'default'});
    });

    testWidgets('a filter carrying a reserved include tag cannot become a '
        'Space, and says why', (tester) async {
      // The tab writes `isSpace: true` *before* activating, so refusing this
      // only at activation would persist a flagged filter that can never be a
      // Space. `all-spaces` as an include-tag would stamp the cross-Space
      // escape onto every note created inside it (A2).
      final reserved = filter(
        'reserved',
        name: 'Everywhere',
        includeTags: [SpaceScopeService.allSpacesTag],
        isSpace: false,
      );
      await load(notes: [note('n1')], filters: [reserved]);
      await pumpScreen(tester);

      await tester.longPress(find.text('Everywhere'));
      await tester.pumpAndSettle();

      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Activate as space'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.enabled, isFalse);
      expect(
        find.text(
          'This tag is reserved by the app and cannot be used as a space.',
        ),
        findsOneWidget,
      );
      expect(provider.activeSpace, isNull);
      expect(
        provider.filters.single.isSpace,
        isFalse,
        reason: 'a filter that can never be a Space must not be flagged as '
            'one on the way to being rejected',
      );
    });

    testWidgets('a filter with no include tags cannot become a Space', (
      tester,
    ) async {
      final textOnly = Filter(
        id: 'text',
        name: 'TextOnly',
        includeText: 'chapter',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      await load(notes: [note('n1')], filters: [textOnly]);
      await pumpScreen(tester);

      await tester.longPress(find.text('TextOnly'));
      await tester.pumpAndSettle();

      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Activate as space'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.enabled, isFalse);
      expect(provider.activeSpace, isNull);
    });
  });

  group('hierarchy', () {
    final child = filter('child', name: 'Chapter 3',
        includeTags: ['thesis', 'ch3']);
    final unrelated = filter('unrelated', name: 'Recipes',
        includeTags: ['recipes']);

    Future<void> enableHierarchy(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.byIcon(Icons.account_tree),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows only the active Space\'s children', (tester) async {
      await load(
        notes: [note('inside', tags: ['thesis'])],
        filters: [space, child, unrelated],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);
      await enableHierarchy(tester);

      expect(find.text('Chapter 3'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.text('Recipes'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.text('Thesis'),
        ),
        findsNothing,
      );
    });

    testWidgets('enabling hierarchy clears a selection outside the subtree', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('everywhere', tags: [SpaceScopeService.allSpacesTag]),
        ],
        filters: [space, child, unrelated],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      // 'Recipes' is a tab while the strip is flat...
      await tapTab(tester, 'Recipes');
      expect(visible(tester), isEmpty);

      // ...and is gone once the tree is rooted at the Space, so the selection
      // cannot stay pointing at it.
      await enableHierarchy(tester);

      expect(selection(tester), {'default'});
      expect(visible(tester), unorderedEquals(['inside', 'everywhere']));
    });

    testWidgets('the hierarchy dialog opens rooted at the active Space', (
      tester,
    ) async {
      await load(
        notes: [note('inside', tags: ['thesis'])],
        filters: [space, child, unrelated],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      await tester.longPress(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.byIcon(Icons.account_tree),
        ),
      );
      await tester.pumpAndSettle();

      final dialog = tester.widget<HierarchyDialog>(
        find.byType(HierarchyDialog),
      );
      expect(dialog.rootFilter?.id, 'space');
    });

    testWidgets('with no active Space the dialog shows the whole tree', (
      tester,
    ) async {
      await load(filters: [space, child, unrelated]);
      await pumpScreen(tester);

      await tester.longPress(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.byIcon(Icons.account_tree),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<HierarchyDialog>(find.byType(HierarchyDialog))
            .rootFilter,
        isNull,
      );
    });
  });

  group('active filters dialog', () {
    testWidgets('shows the Space row and Leave restores the full list', (
      tester,
    ) async {
      await load(
        notes: [
          note('inside', tags: ['thesis']),
          note('outside', tags: ['recipes']),
        ],
        filters: [space],
        activeSpaceId: 'space',
      );
      await pumpScreen(tester);

      // The Space alone makes the filters affordance appear — without it the
      // Leave action would be unreachable on a default tab.
      await tester.tap(
        find.descendant(
          of: find.byType(FilterTabStrip),
          matching: find.byIcon(Icons.filter_list),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Space: Thesis'), findsOneWidget);

      await tester.tap(find.text('Leave space'));
      await tester.pumpAndSettle();

      expect(provider.activeSpace, isNull);
      expect(visible(tester), unorderedEquals(['inside', 'outside']));
    });
  });
}
