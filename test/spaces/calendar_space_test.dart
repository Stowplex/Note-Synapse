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
import 'package:note_synapse/screens/calendar_screen.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';

import 'calendar_space_test.mocks.dart';

/// M5 / decision 3: the calendar honours the active Space.
///
/// It keeps its **own** copy of `_filterNotes`, so it needs its own proof that
/// the scope reaches it — including correction C2's second call site, the
/// saved-filter tab, which without a `base:` would reach straight past the
/// Space.
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

  final today = DateTime.now();

  Note task(String id, {List<String> tags = const []}) => Note(
    id: id,
    title: id,
    content: 'body of $id',
    type: NoteType.task,
    createdAt: today,
    updatedAt: today,
    scheduledAt: today.toIso8601String(),
    status: TaskStatus.todo,
    tags: tags,
  );

  Filter filter(
    String id, {
    required String name,
    required List<String> includeTags,
    bool isSpace = false,
  }) => Filter(
    id: id,
    name: name,
    includeTags: includeTags,
    isSpace: isSpace,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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

    when(mockDb.getAllTags()).thenAnswer((_) async => <Tag>[]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionApps()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionDefaultAppId()).thenAnswer((_) async => null);
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    when(mockTagImages.getImagePathForTag(any)).thenReturn(null);
    when(mockTagImages.getImagePathsForTags(any)).thenReturn([]);
    when(mockTagImages.appDocsPath).thenReturn(null);
  });

  tearDown(() async {
    await resetForTesting();
  });

  /// Builds the provider **in the test body** — never in `setUp` and never
  /// inside `runAsync` (handoff 7a).
  Future<void> load({
    List<Note> notes = const [],
    List<Filter> filters = const [],
    String? activeSpaceId,
  }) async {
    when(mockDb.getAllNotes()).thenAnswer((_) async => [...notes]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => [...filters]);
    provider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
    await provider.loadData();
    if (activeSpaceId != null) {
      expect(await provider.setActiveSpace(activeSpaceId), isTrue);
    }
  }

  Future<void> pumpCalendar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const CalendarScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Task titles the day panel is currently showing.
  List<String> listed(WidgetTester tester) => [
    for (final id in ['inside', 'outside', 'everywhere'])
      if (find.text(id).evaluate().isNotEmpty) id,
  ];

  final thesis = filter(
    's1',
    name: 'Thesis',
    includeTags: ['thesis'],
    isSpace: true,
  );
  final tasks = [
    task('inside', tags: ['thesis']),
    task('outside', tags: ['cooking']),
    task('everywhere', tags: [SpaceScopeService.allSpacesTag]),
  ];

  testWidgets('shows every task with no active Space', (tester) async {
    await load(notes: tasks, filters: [thesis]);

    await pumpCalendar(tester);

    expect(listed(tester), ['inside', 'outside', 'everywhere']);
  });

  testWidgets('inside a Space it shows the Space plus all-spaces', (
    tester,
  ) async {
    await load(notes: tasks, filters: [thesis], activeSpaceId: 's1');

    await pumpCalendar(tester);

    expect(listed(tester), ['inside', 'everywhere']);
  });

  testWidgets('a saved filter tab stays inside the Space (C2)', (tester) async {
    // 'cooking' matches a note the Space excludes. Selecting that tab must not
    // reach past the scope — which is exactly what `getFilteredNotes` does
    // without a `base:`.
    final cooking = filter('f1', name: 'Cooking', includeTags: ['cooking']);
    await load(notes: tasks, filters: [thesis, cooking], activeSpaceId: 's1');
    await pumpCalendar(tester);

    await tester.tap(find.text('Cooking'));
    await tester.pumpAndSettle();

    expect(listed(tester), isEmpty);
  });
}
