import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/screens/tag_management_screen.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';

class _FakeTagWorkflowService extends Fake implements TagWorkflowService {
  @override
  Future<List<WorkflowBindingRow>> getAllBindings() async => const [];
}

class _FakeSkillService extends Fake implements SkillService {
  @override
  Future<Map<String, SkillMetadata>> buildSkillIndex({
    bool allSpaces = false,
  }) async => const {};
}

// Mock AppProvider
class MockAppProvider extends Mock implements AppProvider {
  @override
  void addListener(VoidCallback? listener) {
    super.noSuchMethod(Invocation.method(#addListener, [listener]));
  }

  @override
  void removeListener(VoidCallback? listener) {
    super.noSuchMethod(Invocation.method(#removeListener, [listener]));
  }

  @override
  bool get hasListeners =>
      super.noSuchMethod(Invocation.getter(#hasListeners), returnValue: false);

  @override
  List<Tag> get tags =>
      super.noSuchMethod(Invocation.getter(#tags), returnValue: <Tag>[]);

  @override
  List<Filter> get filters =>
      super.noSuchMethod(Invocation.getter(#filters), returnValue: <Filter>[]);

  @override
  Future<void> deleteTag(String? tagName) => super.noSuchMethod(
    Invocation.method(#deleteTag, [tagName]),
    returnValue: Future.value(),
  );

  // Read right after a tag delete or rename: deleting a Space's last include
  // tag retires the Space, and the screen is where the user is told.
  @override
  List<String> get spacesInvalidatedByLastTagChange => super.noSuchMethod(
    Invocation.getter(#spacesInvalidatedByLastTagChange),
    returnValue: <String>[],
  );
}

void main() {
  final tags = [
    Tag(
      id: '1',
      name: 'Work',
      color: '#FF0000',
      createdAt: DateTime.now(),
      usageCount: 5,
      conversationUsageCount: 2,
    ),
    Tag(
      id: '2',
      name: 'Personal',
      color: '#00FF00',
      createdAt: DateTime.now(),
      usageCount: 3,
      conversationUsageCount: 0,
    ),
    Tag(
      id: '3',
      name: 'Flutter',
      color: '#0000FF',
      createdAt: DateTime.now(),
      usageCount: 10,
      conversationUsageCount: 5,
    ),
  ];

  late MockAppProvider mockAppProvider;

  setUp(() async {
    mockAppProvider = MockAppProvider();

    // Stub methods
    when(mockAppProvider.tags).thenReturn(tags);
    when(mockAppProvider.filters).thenReturn([]);
    // Allow addListener/removeListener to be called silently (do nothing)
    when(mockAppProvider.addListener(any)).thenReturn(null);
    when(mockAppProvider.removeListener(any)).thenReturn(null);
    when(mockAppProvider.deleteTag(any)).thenAnswer((_) async {});

    // The screen's initState fetches workflow bindings + skill index from
    // GetIt; stub them so we never reach the catch-and-snackbar path that
    // pulls ScaffoldMessenger.of(context) before initState completes.
    await getIt.reset();
    getIt.registerSingleton<TagWorkflowService>(_FakeTagWorkflowService());
    getIt.registerSingleton<SkillService>(_FakeSkillService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  Widget createScreen(AppProvider appProvider) {
    return ChangeNotifierProvider<AppProvider>.value(
      value: appProvider,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const TagManagementScreen(),
      ),
    );
  }

  testWidgets('Search bar filters tags', (WidgetTester tester) async {
    await tester.pumpWidget(createScreen(mockAppProvider));
    await tester.pumpAndSettle(); // Wait for _loadTagsWithUsage and UI render

    // Verify all tags are shown initially
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Flutter'), findsOneWidget);

    // Verify search bar is present
    final searchField = find.byType(TextField);
    expect(searchField, findsOneWidget);

    // Enter search text "Work"
    await tester.enterText(searchField, 'Work');
    await tester.pumpAndSettle();

    // Verify only 'Work' is shown
    // Note: 'Work' appears twice: once in the search field, once in the list
    expect(find.text('Work'), findsNWidgets(2));
    expect(find.text('Personal'), findsNothing);
    expect(find.text('Flutter'), findsNothing);

    // Clear search
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();

    // Verify all tags are shown again
    // Expect 1 because search field is cleared
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Flutter'), findsOneWidget);
  });

  testWidgets('Search bar handles case insensitivity', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(createScreen(mockAppProvider));
    await tester.pumpAndSettle();

    // Enter search text "flutter" (lowercase)
    await tester.enterText(find.byType(TextField), 'flutter');
    await tester.pumpAndSettle();

    // Verify 'Flutter' (capitalized) is found
    // 'flutter' in search field, 'Flutter' in list.
    // 'flutter' text finder might not find 'Flutter' if case sensitive default?
    // find.text is case sensitive by default.
    // So find.text('Flutter') should find 1 in the list.
    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('Work'), findsNothing);
  });

  testWidgets('Search bar shows no tags message when no match', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(createScreen(mockAppProvider));
    await tester.pumpAndSettle();

    // Enter nonsense
    await tester.enterText(find.byType(TextField), 'xyz123');
    await tester.pumpAndSettle();

    // Verify no tags list items
    expect(find.byType(ListTile), findsNothing);
    // Note: The actual text might depend on locale, standard english 'No tags available'
    // Ensure we are running with a locale that matches. MaterialApp default is US English usually.
    expect(find.text('No tags available'), findsOneWidget);
  });
}
