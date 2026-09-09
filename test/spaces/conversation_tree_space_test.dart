import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/screens/conversation_tree_screen.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/widgets/linear_history_dialog.dart';

import 'conversation_tree_space_test.mocks.dart';

/// M5 / C3: inside a Space the conversation tree opens on the Space's
/// conversations **and** the cross-Space ones.
///
/// `getAllConversations(tagNames:)` ANDs its tags, so seeding the tag filter
/// with the Space's tags alone could never surface an `all-spaces`
/// conversation. The screen therefore passes `includeAllSpacesTag`, derived
/// from the live scope.
///
/// The Space's tags go in **`scopeTags`**, never in `tagNames`: the chips are
/// user-editable, and the cross-Space escape may only be ORed around the
/// Space's group. Merging the two lists is the M5 blocker shape — inside Space
/// `{thesis}`, adding a chip `urgent` would return every cross-Space
/// conversation, none of them urgent.
///
/// This drives the screen rather than reading its source: the flag is a single
/// getter, and hard-coding it to `false` left the whole suite green.
@GenerateMocks([ConversationService])
void main() {
  late MockConversationService mockConversationService;
  late SpaceScopeService scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();
    mockConversationService = MockConversationService();
    scope = SpaceScopeService();
    getIt.registerSingleton<ConversationService>(mockConversationService);
    getIt.registerSingleton<SpaceScopeService>(scope);

    // An empty tree: the screen renders its "nothing found" scaffold, which
    // needs no graph layout and no database.
    when(
      mockConversationService.refreshConversationTree(
        maxAge: anyNamed('maxAge'),
        conversationIds: anyNamed('conversationIds'),
        tagNames: anyNamed('tagNames'),
        scopeTags: anyNamed('scopeTags'),
        includeAllSpacesTag: anyNamed('includeAllSpacesTag'),
      ),
    ).thenAnswer((_) async => null);
  });

  tearDown(() async {
    await resetForTesting();
  });

  Future<void> pumpTree(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: [Locale('en', ''), Locale('zh', '')],
        home: ConversationTreeScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every (tagNames, scopeTags, includeAllSpacesTag) triple the screen asked
  /// for. The screen loads once on init and refreshes once on first
  /// appearance, so both calls are inspected — an argument that is only right
  /// on one of them is still wrong.
  List<({List<String>? tags, List<String>? scopeTags, bool orAllSpaces})>
  loads() {
    final captured = verify(
      mockConversationService.refreshConversationTree(
        maxAge: anyNamed('maxAge'),
        conversationIds: anyNamed('conversationIds'),
        tagNames: captureAnyNamed('tagNames'),
        scopeTags: captureAnyNamed('scopeTags'),
        includeAllSpacesTag: captureAnyNamed('includeAllSpacesTag'),
      ),
    ).captured;
    return [
      for (var i = 0; i < captured.length; i += 3)
        (
          tags: captured[i] as List<String>?,
          scopeTags: captured[i + 1] as List<String>?,
          orAllSpaces: captured[i + 2] as bool,
        ),
    ];
  }

  testWidgets('inside a Space it seeds the Space tags and ORs all-spaces',
      (tester) async {
    scope.setActive('s1', const ['thesis', '2026'], name: 'Thesis');

    await pumpTree(tester);

    final calls = loads();
    expect(calls, isNotEmpty);
    for (final call in calls) {
      expect(
        call.scopeTags,
        ['thesis', '2026'],
        reason: 'the Space tags are the scope group, not the caller\'s own',
      );
      expect(
        call.tags,
        isNull,
        reason: 'merging them lets all-spaces escape the user\'s own chips',
      );
      expect(
        call.orAllSpaces,
        isTrue,
        reason: 'an all-spaces conversation must be visible in every Space',
      );
    }
  });

  testWidgets('with no Space active nothing is seeded and nothing is ORed',
      (tester) async {
    await pumpTree(tester);

    final calls = loads();
    expect(calls, isNotEmpty);
    for (final call in calls) {
      expect(call.tags, isNull);
      expect(call.scopeTags, isNull);
      expect(call.orAllSpaces, isFalse);
    }
  });

  testWidgets('the OR is off while the tag filter is empty', (tester) async {
    // `getAllConversations` only applies the OR alongside a tag conjunction;
    // asking for it with no tags at all would be a no-op at best and is not
    // what the screen means. A Space with no resolved tags is not active.
    scope.setActive('s1', const []);

    await pumpTree(tester);

    for (final call in loads()) {
      expect(call.tags, isNull);
      expect(call.scopeTags, isNull);
      expect(call.orAllSpaces, isFalse);
    }
  });

  group('the filters dialog the tree opens', () {
    // The dialog is handed the tree's chip list and lists the same
    // conversations the graph draws. Loading them without the scope arguments
    // made the two disagree: the tree ORed the cross-Space escape around the
    // Space's tags while the dialog ANDed, so a conversation marked "show
    // everywhere" was a node in the graph and missing from the list beside it.
    Future<void> pumpDialog(
      WidgetTester tester, {
      required List<String> chips,
    }) async {
      when(
        mockConversationService.deleteEmptyConversations(
          olderThan: anyNamed('olderThan'),
        ),
      ).thenAnswer((_) async {});
      when(
        mockConversationService.getAllConversations(
          maxAge: anyNamed('maxAge'),
          tagNames: anyNamed('tagNames'),
          scopeTags: anyNamed('scopeTags'),
          conversationIds: anyNamed('conversationIds'),
          includeEmpty: anyNamed('includeEmpty'),
          includeAllSpacesTag: anyNamed('includeAllSpacesTag'),
        ),
      ).thenAnswer((_) async => <Conversation>[]);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en', ''), Locale('zh', '')],
          home: LinearHistoryDialog(
            initialTimeRange: const Duration(days: 3),
            onTimeRangeChanged: (_) {},
            initialSelectedTags: chips,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    ({List<String>? tags, List<String>? scopeTags, bool orAllSpaces}) load() {
      final captured = verify(
        mockConversationService.getAllConversations(
          maxAge: anyNamed('maxAge'),
          tagNames: captureAnyNamed('tagNames'),
          scopeTags: captureAnyNamed('scopeTags'),
          conversationIds: anyNamed('conversationIds'),
          includeEmpty: anyNamed('includeEmpty'),
          includeAllSpacesTag: captureAnyNamed('includeAllSpacesTag'),
        ),
      ).captured;
      return (
        tags: captured[0] as List<String>?,
        scopeTags: captured[1] as List<String>?,
        orAllSpaces: captured[2] as bool,
      );
    }

    testWidgets('splits the chips exactly as the tree does', (tester) async {
      scope.setActive('s1', const ['thesis'], name: 'Thesis');

      await pumpDialog(tester, chips: const ['thesis', 'urgent']);

      final call = load();
      expect(call.scopeTags, ['thesis']);
      expect(call.tags, ['urgent']);
      expect(
        call.orAllSpaces,
        isTrue,
        reason: 'the dialog ANDing while the tree ORs hides a cross-Space '
            'conversation that is drawn in the graph behind it',
      );
    });

    testWidgets('outside a Space it is the plain conjunction it always was',
        (tester) async {
      await pumpDialog(tester, chips: const ['urgent']);

      final call = load();
      expect(call.tags, ['urgent']);
      expect(call.scopeTags, isNull);
      expect(call.orAllSpaces, isFalse);
    });
  });

  group('the chip split the screen delegates to', () {
    // The screen holds one editable chip list and hands it to
    // `partitionChips`, so what happens when the user adds a chip inside a
    // Space is decided there. Driving it directly is what makes the blocker
    // shape testable at all: reaching the chips through the UI means opening
    // the filters dialog and then the tag picker over a graph.
    test('a chip the user added stays out of the scope group', () {
      scope.setActive('s1', const ['thesis'], name: 'Thesis');

      final split = scope.partitionChips(const ['thesis', 'urgent']);

      expect(split.scopeTags, ['thesis']);
      expect(
        split.tagNames,
        ['urgent'],
        reason: 'merged, the query becomes (urgent AND thesis) OR all-spaces '
            'and returns every cross-Space conversation',
      );
      expect(split.orAllSpaces, isTrue);
    });

    test('removing the Space chip widens: no scope group, no OR', () {
      scope.setActive('s1', const ['thesis'], name: 'Thesis');

      final split = scope.partitionChips(const ['urgent']);

      expect(split.scopeTags, isNull);
      expect(split.tagNames, ['urgent']);
      expect(split.orAllSpaces, isFalse);
    });

    test('with no Space every chip is the caller\'s own', () {
      final split = scope.partitionChips(const ['thesis', 'urgent']);

      expect(split.scopeTags, isNull);
      expect(split.tagNames, ['thesis', 'urgent']);
      expect(split.orAllSpaces, isFalse);
    });
  });
}
