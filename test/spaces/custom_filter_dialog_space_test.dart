import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:note_synapse/widgets/custom_filter_dialog.dart';
import 'package:note_synapse/widgets/tag_selection_dialog.dart';

import 'notes_screen_space_test.mocks.dart';

/// M3: the *Use as space* switch in the filter editor — the gate that decides
/// whether a filter may become a Space (A8), and the offer to bring a Space's
/// existing members along when its include tags grow.
void main() {
  late MockDatabaseService mockDb;
  late MockUserAppService mockUserAppService;
  late MockModelStorageService mockModelStorage;
  late MockTagImageService mockTagImages;
  late AppProvider provider;

  Note note(String id, {List<String> tags = const [], bool archived = false}) =>
      Note(
        id: id,
        title: id,
        content: 'body',
        type: NoteType.note,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        tags: tags,
        isArchived: archived,
      );

  Filter filter(
    String id, {
    String? name,
    List<String> includeTags = const [],
    List<String> excludeTags = const [],
    String? includeText,
    bool isSpace = false,
    bool includeArchived = false,
  }) => Filter(
    id: id,
    name: name ?? id,
    includeTags: includeTags,
    excludeTags: excludeTags,
    includeText: includeText,
    isSpace: isSpace,
    includeArchived: includeArchived,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    await resetForTesting();

    // TagSelectionDialog resolves the documents directory in initState; the
    // channel mock keeps that off the real filesystem.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp/note-synapse-space-test',
        );

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
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    when(mockTagImages.getImagePathForTag(any)).thenReturn(null);
    when(mockTagImages.getImagePathsForTags(any)).thenReturn([]);
    when(mockTagImages.appDocsPath).thenReturn(null);
  });

  tearDown(() async {
    await resetForTesting();
  });

  /// Loads the provider with [notes] and [filters].
  ///
  /// The provider is built here rather than in `setUp`:
  /// `AppProvider._withCacheLock` seeds its queue at construction, and a future
  /// created outside the widget binding's fake clock schedules its listeners on
  /// the real microtask queue, which that clock never drains — `batchUpdateTags`
  /// would then never complete.
  Future<void> load({
    List<Note> notes = const [],
    List<Filter> filters = const [],
  }) async {
    provider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
    when(mockDb.getAllNotes()).thenAnswer((_) async => [...notes]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => [...filters]);
    await provider.loadData();
  }

  /// Opens the dialog and hands back a getter for whatever it pops.
  Future<Filter? Function()> open(
    WidgetTester tester, {
    Filter? existing,
  }) async {
    Filter? result;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  final popped = await showDialog<dynamic>(
                    context: context,
                    builder: (_) => CustomFilterDialog(
                      availableTags: const ['thesis', 'draft'],
                      existingFilter: existing,
                    ),
                  );
                  if (popped is Filter) result = popped;
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
    return () => result;
  }

  /// Whether the dialog's confirm button is enabled.
  bool canSave(WidgetTester tester, String label) =>
      tester
          .widget<ElevatedButton>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(ElevatedButton),
            ),
          )
          .onPressed !=
      null;

  Future<void> toggleUseAsSpace(WidgetTester tester) async {
    await tester.tap(find.text('Use as space'));
    await tester.pumpAndSettle();
  }

  group('Use as space gating (A8)', () {
    testWidgets('refuses a filter with no include tags', (tester) async {
      await load();
      await open(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Filter Name'),
        'Thesis',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Include Text'),
        'chapter',
      );
      await tester.pumpAndSettle();

      // A text-only filter is a valid *filter*: hasValidCriteria accepts it.
      expect(canSave(tester, 'Create'), isTrue);

      await toggleUseAsSpace(tester);

      // ...but not a valid Space: the stamp would be empty.
      expect(canSave(tester, 'Create'), isFalse);
      expect(
        find.textContaining('Add at least one include tag'),
        findsOneWidget,
      );
    });

    testWidgets('refuses an exclude-tags-only filter', (tester) async {
      await load();
      await open(tester, existing: filter('f', excludeTags: ['draft']));

      await tester.enterText(
        find.widgetWithText(TextField, 'Include Text'),
        'chapter',
      );
      await tester.pumpAndSettle();
      await toggleUseAsSpace(tester);

      expect(canSave(tester, 'Update'), isFalse);
    });

    testWidgets('refuses an include tag containing a comma', (tester) async {
      // `filters.includeTags` is stored comma-joined, so `a,b` comes back as
      // two tags no note carries: the Space would scope to nothing and stamp
      // names that do not exist. The save gate has to use the same predicate
      // AppProvider.spaces uses, not merely "the list is non-empty" — that is
      // the hole that let a broken Space be written and survive a restart.
      await load();
      await open(tester, existing: filter('f', name: 'X', includeTags: ['a,b']));

      // A perfectly ordinary filter.
      expect(canSave(tester, 'Update'), isTrue);

      await toggleUseAsSpace(tester);

      expect(canSave(tester, 'Update'), isFalse);
      expect(
        find.text('A tag containing a comma cannot be used as a space.'),
        findsOneWidget,
      );
      // The stamp preview must not claim it would work.
      expect(find.textContaining('New notes will be tagged'), findsNothing);
    });

    testWidgets('refuses one comma tag among several good ones',
        (tester) async {
      await load();
      await open(
        tester,
        existing: filter('f', name: 'X', includeTags: ['thesis', 'a,b']),
      );

      await toggleUseAsSpace(tester);

      expect(canSave(tester, 'Update'), isFalse);
    });

    testWidgets('refuses the reserved cross-Space tag as an include tag',
        (tester) async {
      // Migration v47 creates `all-spaces` as a real tag row and puts it on
      // every skill note, so the include-tag picker offers it like any other.
      // As a Space's include-tag it would stamp the cross-Space escape onto
      // every note created inside (A2), make leaving the Space a permanent
      // no-op, and hide it from the scoped chip list (A9).
      await load();
      await open(
        tester,
        existing: filter(
          'f',
          name: 'X',
          includeTags: [SpaceScopeService.allSpacesTag],
        ),
      );

      // A perfectly ordinary filter.
      expect(canSave(tester, 'Update'), isTrue);

      await toggleUseAsSpace(tester);

      expect(canSave(tester, 'Update'), isFalse);
      expect(
        find.text(
          'This tag is reserved by the app and cannot be used as a space.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('New notes will be tagged'), findsNothing);
    });

    testWidgets('refuses one reserved tag among several good ones',
        (tester) async {
      await load();
      await open(
        tester,
        existing: filter(
          'f',
          name: 'X',
          includeTags: ['thesis', SpaceScopeService.allSpacesTag],
        ),
      );

      await toggleUseAsSpace(tester);

      expect(canSave(tester, 'Update'), isFalse);
    });

    testWidgets('accepts include tags, previews the stamp and pops isSpace', (
      tester,
    ) async {
      await load();
      final result = await open(
        tester,
        existing: filter('f', name: 'Thesis', includeTags: ['thesis', '2026']),
      );

      await toggleUseAsSpace(tester);

      expect(
        find.text('New notes will be tagged: thesis, 2026'),
        findsOneWidget,
      );
      expect(canSave(tester, 'Update'), isTrue);

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(result()?.isSpace, isTrue);
      expect(result()?.includeTags, ['thesis', '2026']);
    });

    testWidgets('warns softly about text and note-type criteria', (
      tester,
    ) async {
      await load();
      await open(
        tester,
        existing: filter(
          'f',
          includeTags: ['thesis'],
          includeText: 'chapter',
        ),
      );
      await toggleUseAsSpace(tester);

      expect(
        find.textContaining("may not match this filter's text criteria"),
        findsOneWidget,
      );
      expect(
        find.textContaining("may not match this filter's note types"),
        findsNothing,
      );

      // Restricting the note types adds the second warning. The checkbox sits
      // below the fold of the dialog's scroll view.
      await tester.ensureVisible(find.text('Note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Note'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("may not match this filter's note types"),
        findsOneWidget,
      );
    });

    testWidgets('an existing Space opens with the switch already on', (
      tester,
    ) async {
      await load();
      await open(
        tester,
        existing: filter('f', includeTags: ['thesis'], isSpace: true),
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      expect(find.text('New notes will be tagged: thesis'), findsOneWidget);
    });
  });

  group('re-tag offer', () {
    /// Adds [tag] through the include-tags selector.
    Future<void> addIncludeTag(WidgetTester tester, String tag) async {
      await tester.tap(find.widgetWithText(TextField, 'Include Tags'));
      await tester.pumpAndSettle();
      expect(find.byType(TagSelectionDialog), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Add new tag or search'),
        tag,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(TagSelectionDialog),
          matching: find.widgetWithIcon(IconButton, Icons.add),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply Filters'));
      await tester.pumpAndSettle();
    }

    testWidgets('counts pre-edit membership and tags exactly those ids', (
      tester,
    ) async {
      final space = filter('s', name: 'Thesis', includeTags: ['thesis'],
          isSpace: true);
      await load(
        notes: [
          note('in-1', tags: ['thesis']),
          note('in-2-archived', tags: ['thesis'], archived: true),
          note('everywhere', tags: [SpaceScopeService.allSpacesTag]),
          note('outside', tags: ['other']),
        ],
        filters: [space],
      );

      final result = await open(tester, existing: space);
      await addIncludeTag(tester, 'draft');

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      // Archived members count: inside a Space archived-ness is the tab's
      // decision, so an archived note is still a member. 'everywhere' does
      // not: it is in scope only via `all-spaces`, and stamping it would file
      // a deliberately global note into this one Space (A11).
      expect(
        find.text('Also tag the 2 notes currently in "Thesis" with: draft'),
        findsOneWidget,
      );

      await tester.tap(find.text('Tag notes'));
      await tester.pumpAndSettle();

      final written = verify(mockDb.updateNote(captureAny)).captured
          .cast<Note>();
      expect(written.map((n) => n.id).toSet(), {'in-1', 'in-2-archived'});
      expect(written.every((n) => n.tags.contains('draft')), isTrue);
      expect(result()?.includeTags, containsAll(['thesis', 'draft']));
    });

    testWidgets('"Not now" saves the filter without touching any note', (
      tester,
    ) async {
      final space = filter('s', name: 'Thesis', includeTags: ['thesis'],
          isSpace: true);
      await load(notes: [note('in-1', tags: ['thesis'])], filters: [space]);

      final result = await open(tester, existing: space);
      await addIncludeTag(tester, 'draft');
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      verifyNever(mockDb.updateNote(any));
      expect(result()?.includeTags, containsAll(['thesis', 'draft']));
    });

    testWidgets('no offer when the filter is not a Space', (tester) async {
      final plain = filter('f', name: 'Drafts', includeTags: ['thesis']);
      await load(notes: [note('in-1', tags: ['thesis'])], filters: [plain]);

      await open(tester, existing: plain);
      await addIncludeTag(tester, 'draft');
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(find.text('Tag existing notes?'), findsNothing);
      verifyNever(mockDb.updateNote(any));
    });
  });
}
