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
import 'package:note_synapse/screens/note_selection_dialog.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';

import 'note_selection_dialog_space_test.mocks.dart';

/// M5: [NoteSelectionDialog] is the one picker behind AI context picking,
/// merge and the plugin `pickNotes`, so scoping it here scopes all three.
///
/// Two things have to hold at once: the default is the Space (with a switch to
/// widen it), and an explicit `candidateNotes` still wins — *Add existing
/// notes…* passes the **complement** of the Space, which a scoped default would
/// reduce to nothing.
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

  Note note(String id, {List<String> tags = const []}) => Note(
        id: id,
        title: id,
        content: 'body of $id',
        type: NoteType.note,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        tags: tags,
      );

  Filter space(String id, {required String name, required List<String> tags}) =>
      Filter(
        id: id,
        name: name,
        includeTags: tags,
        isSpace: true,
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
  /// inside `runAsync` — so every `_withCacheLock` call lands on the widget
  /// binding's fake clock instead of the real microtask queue (handoff 7a).
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

  Future<void> openDialog(
    WidgetTester tester, {
    List<Note>? candidateNotes,
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: NoteSelectionDialog(
              onNotesSelected: (_) {},
              candidateNotes: candidateNotes,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Note titles the picker is currently offering.
  List<String> listed(WidgetTester tester) => [
        for (final id in ['inside', 'outside', 'everywhere'])
          if (find.text(id).evaluate().isNotEmpty) id,
      ];

  final thesis = space('s1', name: 'Thesis', tags: ['thesis']);
  final notes = [
    note('inside', tags: ['thesis']),
    note('outside', tags: ['cooking']),
    note('everywhere', tags: [SpaceScopeService.allSpacesTag]),
  ];

  testWidgets('defaults to the Space, and all-spaces notes come with it',
      (tester) async {
    await load(notes: notes, filters: [thesis], activeSpaceId: 's1');

    await openDialog(tester);

    expect(listed(tester), ['inside', 'everywhere']);
  });

  testWidgets('the switch widens the picker to every note', (tester) async {
    await load(notes: notes, filters: [thesis], activeSpaceId: 's1');
    await openDialog(tester);

    expect(find.text('Include notes outside Thesis'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('include-outside-space')));
    await tester.pumpAndSettle();

    expect(listed(tester), ['inside', 'outside', 'everywhere']);
  });

  testWidgets('with no active Space every note is offered and no switch shows',
      (tester) async {
    await load(notes: notes, filters: [thesis]);

    await openDialog(tester);

    expect(listed(tester), ['inside', 'outside', 'everywhere']);
    expect(find.byKey(const ValueKey('include-outside-space')), findsNothing);
  });

  testWidgets('an explicit candidateNotes wins over the Space default',
      (tester) async {
    // *Add existing notes…* passes the complement of the Space. Scoping that
    // again would leave the dialog with nothing to offer.
    await load(notes: notes, filters: [thesis], activeSpaceId: 's1');

    await openDialog(tester, candidateNotes: [notes[1]]);

    expect(listed(tester), ['outside']);
    // No switch either: the caller already answered the scope question.
    expect(find.byKey(const ValueKey('include-outside-space')), findsNothing);
  });
}
