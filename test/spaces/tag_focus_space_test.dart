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
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:note_synapse/widgets/multi_select_tag_filter.dart';
import 'package:note_synapse/widgets/tag_focus_action.dart';
import 'package:note_synapse/widgets/tag_selection_dialog.dart';

import 'notes_screen_space_test.mocks.dart';

/// M7: *Focus on this tag* — the one-action path from a tag chip to a Space
/// scoped to that tag, and the reuse rule that stops a second invocation from
/// minting a duplicate.
void main() {
  late MockDatabaseService mockDb;
  late MockUserAppService mockUserAppService;
  late MockModelStorageService mockModelStorage;
  late MockTagImageService mockTagImages;
  late AppProvider provider;

  Note note(String id, {List<String> tags = const []}) => Note(
    id: id,
    title: id,
    content: 'body',
    type: NoteType.note,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    tags: tags,
  );

  Filter filter(
    String id, {
    String? name,
    List<String> includeTags = const [],
    bool isSpace = true,
  }) => Filter(
    id: id,
    name: name ?? id,
    includeTags: includeTags,
    isSpace: isSpace,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    await resetForTesting();

    // TagSelectionDialog resolves the documents directory in initState.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp/note-synapse-tag-focus-test',
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
    when(mockDb.insertFilter(any)).thenAnswer((_) async => 'inserted');
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    when(mockTagImages.getImagePathForTag(any)).thenReturn(null);
    when(mockTagImages.getImagePathsForTags(any)).thenReturn([]);
    when(mockTagImages.appDocsPath).thenReturn(null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await resetForTesting();
  });

  /// Builds and loads the provider *inside the test body*.
  ///
  /// `AppProvider._withCacheLock` seeds its queue at construction; a future
  /// created outside the widget binding's fake clock never has its listeners
  /// drained by `pump`, so `setActiveSpace` would hang forever.
  Future<void> load({
    List<Note> notes = const [],
    List<Filter> filters = const [],
    List<Tag> tags = const [],
  }) async {
    provider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
    when(mockDb.getAllNotes()).thenAnswer((_) async => [...notes]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => [...filters]);
    when(mockDb.getAllTags()).thenAnswer((_) async => [...tags]);
    await provider.loadData();
  }

  group('focusOnTag', () {
    test('creates a one-tag Space named after the tag and activates it',
        () async {
      await load(notes: [note('n1', tags: ['thesis'])]);

      final result = await focusOnTag(provider, 'thesis');

      expect(result.outcome, FocusTagOutcome.created);
      expect(provider.filters, hasLength(1));
      final created = provider.filters.single;
      expect(created.name, 'thesis');
      expect(created.includeTags, ['thesis']);
      expect(created.isSpace, isTrue);
      expect(provider.activeSpace?.id, created.id);
      expect(provider.spaceTags, ['thesis']);
      verify(mockDb.insertFilter(any)).called(1);
    });

    test('a second focus on the same tag reuses the Space', () async {
      await load(notes: [note('n1', tags: ['thesis'])]);

      final first = await focusOnTag(provider, 'thesis');
      await provider.setActiveSpace(null);
      final second = await focusOnTag(provider, 'thesis');

      expect(first.outcome, FocusTagOutcome.created);
      expect(second.outcome, FocusTagOutcome.reused);
      expect(second.space?.id, first.space?.id);
      expect(
        provider.filters,
        hasLength(1),
        reason: 'a second focus must not mint a duplicate Space',
      );
      verify(mockDb.insertFilter(any)).called(1);
      expect(provider.activeSpace?.id, first.space?.id);
    });

    test('focusing the Space that is already active is still a reuse',
        () async {
      await load();
      final first = await focusOnTag(provider, 'thesis');
      final second = await focusOnTag(provider, 'thesis');

      expect(second.outcome, FocusTagOutcome.reused);
      expect(second.space?.id, first.space?.id);
      expect(provider.filters, hasLength(1));
    });

    test('reuses a Space that already existed before any focus', () async {
      await load(
        filters: [filter('s1', name: 'Thesis', includeTags: ['thesis'])],
      );

      final result = await focusOnTag(provider, 'thesis');

      expect(result.outcome, FocusTagOutcome.reused);
      expect(result.space?.id, 's1');
      expect(provider.filters, hasLength(1));
      verifyNever(mockDb.insertFilter(any));
    });

    test('does not reuse a Space that scopes to more than this tag', () async {
      await load(
        filters: [filter('s1', includeTags: ['thesis', '2026'])],
      );

      final result = await focusOnTag(provider, 'thesis');

      expect(result.outcome, FocusTagOutcome.created);
      expect(provider.activeSpace?.includeTags, ['thesis']);
      expect(provider.filters, hasLength(2));
    });

    test('does not adopt a plain filter carrying the same tag', () async {
      // Promoting someone's saved filter to a Space behind a long-press is a
      // bigger change than this affordance asks for; the tab's own *Activate
      // as space* exists for when they do want it.
      await load(
        filters: [filter('f1', includeTags: ['thesis'], isSpace: false)],
      );

      final result = await focusOnTag(provider, 'thesis');

      expect(result.outcome, FocusTagOutcome.created);
      expect(provider.filters.firstWhere((f) => f.id == 'f1').isSpace, isFalse);
    });

    test('refuses a tag containing a comma and writes nothing', () async {
      // `filters.includeTags` is stored comma-joined, so such a Space could
      // never resolve.
      await load();

      final result = await focusOnTag(provider, 'a,b');

      expect(result.outcome, FocusTagOutcome.unusableTag);
      expect(provider.filters, isEmpty);
      expect(provider.activeSpace, isNull);
      verifyNever(mockDb.insertFilter(any));
    });

    test('reports failure and activates nothing when the write fails',
        () async {
      await load();
      when(mockDb.insertFilter(any)).thenThrow(Exception('disk full'));

      final result = await focusOnTag(provider, 'thesis');

      expect(result.outcome, FocusTagOutcome.failed);
      expect(result.space, isNull);
      expect(provider.activeSpace, isNull);
    });

    test('findTagSpace ignores filters that are not usable Spaces', () async {
      await load(
        filters: [
          filter('plain', includeTags: ['thesis'], isSpace: false),
          filter('comma', includeTags: ['thesis,other']),
          filter('empty', includeTags: const []),
        ],
      );

      expect(findTagSpace(provider, 'thesis'), isNull);
    });

    test('canFocusOnTag rejects commas, blanks and reserved tags', () {
      expect(canFocusOnTag('thesis'), isTrue);
      expect(canFocusOnTag('thesis-2026'), isTrue);
      expect(canFocusOnTag('a,b'), isFalse);
      expect(canFocusOnTag('   '), isFalse);
      expect(canFocusOnTag(SpaceScopeService.allSpacesTag), isFalse);
      expect(canFocusOnTag(SkillService.agentSkillTag), isFalse);
    });

    // A Space whose include-tag is `all-spaces` would stamp the cross-Space
    // escape onto every note created inside it (A2), make leaving it a
    // permanent no-op, and hide it from the chip list (A9). Migration v47
    // creates that tag as a real row and puts it on every skill note, so the
    // tag picker this affordance lives in offers it like any other.
    for (final reserved in [
      SpaceScopeService.allSpacesTag,
      SkillService.agentSkillTag,
    ]) {
      test('refuses the reserved tag "$reserved" and writes nothing', () async {
        await load(notes: [note('n1', tags: [reserved])]);

        final result = await focusOnTag(provider, reserved);

        expect(result.outcome, FocusTagOutcome.reservedTag);
        expect(result.space, isNull);
        expect(provider.filters, isEmpty);
        expect(provider.activeSpace, isNull);
        expect(provider.spaceTags, isEmpty);
        verifyNever(mockDb.insertFilter(any));
      });
    }

    test('a reserved tag is refused even when a Space already carries it',
        () async {
      // A filter row restored from a backup can carry anything; it must not
      // become reusable just because it exists.
      await load(
        filters: [
          filter('restored', includeTags: [SpaceScopeService.allSpacesTag]),
        ],
      );

      final result = await focusOnTag(
        provider,
        SpaceScopeService.allSpacesTag,
      );

      expect(result.outcome, FocusTagOutcome.reservedTag);
      expect(provider.activeSpace, isNull);
      expect(findTagSpace(provider, SpaceScopeService.allSpacesTag), isNull);
    });
  });

  group('the tag chip affordance', () {
    /// Pumps the tag filter dialog the notes screen opens, already showing
    /// [tags] as available chips.
    Future<void> pumpFilter(WidgetTester tester, {bool viaFilter = true}) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: provider,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: viaFilter
                    ? MultiSelectTagFilter(
                        availableTags: const [],
                        selectedTags: const {},
                        onSelectionChanged: (_) {},
                      )
                    : Builder(
                        builder: (context) => ElevatedButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => const TagSelectionDialog(
                              allowCreateNew: false,
                              allowEmptySelection: true,
                              returnAsSet: true,
                            ),
                          ),
                          child: const Text('open'),
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        viaFilter ? find.byIcon(Icons.filter_list) : find.text('open'),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('long-pressing a tag chip offers Focus on this tag', (
      tester,
    ) async {
      await load(
        notes: [note('n1', tags: ['thesis'])],
        tags: [
          Tag(
            id: 't1',
            name: 'thesis',
            color: '#fff',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await pumpFilter(tester);

      await tester.longPress(find.widgetWithText(FilterChip, 'thesis'));
      await tester.pumpAndSettle();

      expect(find.text('Focus on this tag'), findsOneWidget);
    });

    testWidgets('choosing it creates the Space, activates it and closes the '
        'picker', (tester) async {
      await load(
        notes: [note('n1', tags: ['thesis'])],
        tags: [
          Tag(
            id: 't1',
            name: 'thesis',
            color: '#fff',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await pumpFilter(tester);

      await tester.longPress(find.widgetWithText(FilterChip, 'thesis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Focus on this tag'));
      await tester.pumpAndSettle();

      expect(provider.activeSpace?.name, 'thesis');
      expect(provider.activeSpace?.includeTags, ['thesis']);
      expect(
        find.byType(TagSelectionDialog),
        findsNothing,
        reason: 'the picker must not sit over the list it just rescoped',
      );
    });

    testWidgets('a second long-press reuses the Space rather than duplicating '
        'it', (tester) async {
      await load(
        notes: [note('n1', tags: ['thesis'])],
        tags: [
          Tag(
            id: 't1',
            name: 'thesis',
            color: '#fff',
            createdAt: DateTime(2026),
          ),
        ],
      );

      for (var i = 0; i < 2; i++) {
        await pumpFilter(tester);
        await tester.longPress(find.widgetWithText(FilterChip, 'thesis'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Focus on this tag'));
        await tester.pumpAndSettle();
      }

      expect(provider.filters, hasLength(1));
      verify(mockDb.insertFilter(any)).called(1);
    });

    testWidgets('a tag containing a comma explains why it cannot be a Space', (
      tester,
    ) async {
      await load(
        notes: [note('n1', tags: ['a,b'])],
        tags: [
          Tag(id: 't1', name: 'a,b', color: '#fff', createdAt: DateTime(2026)),
        ],
      );
      await pumpFilter(tester);

      await tester.longPress(find.widgetWithText(FilterChip, 'a,b'));
      await tester.pumpAndSettle();

      expect(
        find.text('A tag containing a comma cannot be used as a space.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Focus on this tag'));
      await tester.pumpAndSettle();
      expect(provider.filters, isEmpty);
      expect(provider.activeSpace, isNull);
    });

    testWidgets('the reserved cross-Space tag explains why it cannot be a '
        'Space', (tester) async {
      // The picker lists every tag row, and migration v47 guarantees this one
      // exists on every skill note — so this chip is really on screen.
      await load(
        notes: [note('n1', tags: [SpaceScopeService.allSpacesTag])],
        tags: [
          Tag(
            id: 't1',
            name: SpaceScopeService.allSpacesTag,
            color: '#fff',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await pumpFilter(tester);

      await tester.longPress(
        find.widgetWithText(FilterChip, SpaceScopeService.allSpacesTag),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This tag is reserved by the app and cannot be used as a space.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Focus on this tag'));
      await tester.pumpAndSettle();
      expect(
        provider.filters,
        isEmpty,
        reason: 'a Space stamping all-spaces onto every new note violates A2',
      );
      expect(provider.activeSpace, isNull);
    });

    testWidgets('the affordance is off unless the host opts in', (
      tester,
    ) async {
      await load(
        notes: [note('n1', tags: ['thesis'])],
        tags: [
          Tag(
            id: 't1',
            name: 'thesis',
            color: '#fff',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await pumpFilter(tester, viaFilter: false);

      await tester.longPress(find.widgetWithText(FilterChip, 'thesis'));
      await tester.pumpAndSettle();

      expect(find.text('Focus on this tag'), findsNothing);
      expect(provider.filters, isEmpty);
    });
  });
}
