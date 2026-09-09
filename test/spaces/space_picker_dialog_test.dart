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
import 'package:note_synapse/widgets/note_card.dart';
import 'package:note_synapse/widgets/space_picker_dialog.dart';

import 'space_picker_dialog_test.mocks.dart';

/// M4: the join/leave UI.
///
/// [SpacePickerDialog] is the single writer behind *Add to space…* on a note,
/// on a card long-press and in the multi-select AppBar, so a move between
/// Spaces — one join plus one leave — has to survive a single confirm. The
/// leave half is the interesting one: it must drop only the tags no other
/// Space the note still belongs to requires.
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

  /// Notes as the mock database currently holds them, keyed by id.
  late Map<String, Note> rows;

  Note note(
    String id, {
    List<String> tags = const [],
    NoteType type = NoteType.note,
  }) =>
      Note(
        id: id,
        title: id,
        content: 'body',
        type: type,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        tags: tags,
        status: type == NoteType.task ? TaskStatus.todo : null,
      );

  Filter space(
    String id, {
    required String name,
    required List<String> includeTags,
    List<NoteType> noteTypes = const [NoteType.note, NoteType.task],
  }) =>
      Filter(
        id: id,
        name: name,
        includeTags: includeTags,
        noteTypes: noteTypes,
        isSpace: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    await resetForTesting();

    rows = {};
    mockDb = MockDatabaseService();
    mockUserAppService = MockUserAppService();
    mockModelStorage = MockModelStorageService();
    mockTagImages = MockTagImageService();
    getIt.registerSingleton<UserAppService>(mockUserAppService);
    getIt.registerSingleton<ModelStorageService>(mockModelStorage);
    getIt.registerSingleton<TagImageService>(mockTagImages);
    getIt.registerSingleton<SpaceScopeService>(SpaceScopeService());

    when(mockDb.getAllNotes()).thenAnswer((_) async => rows.values.toList());
    when(mockDb.getAllTags()).thenAnswer((_) async => <Tag>[]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionApps()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionDefaultAppId()).thenAnswer((_) async => null);
    when(mockDb.updateNote(any)).thenAnswer((inv) async {
      final updated = inv.positionalArguments.first as Note;
      rows[updated.id] = updated;
    });
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
    rows = {for (final n in notes) n.id: n};
    provider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
    when(mockDb.getAllFilters()).thenAnswer((_) async => [...filters]);
    await provider.loadData();
    if (activeSpaceId != null) {
      expect(await provider.setActiveSpace(activeSpaceId), isTrue);
    }
  }

  /// The note's tags as the provider now holds them.
  List<String> tagsOf(String id) =>
      provider.notes.firstWhere((n) => n.id == id).tags;

  /// A host with a button that runs [onTap] — the picker needs a Navigator and
  /// a ScaffoldMessenger above it, which is what its real call sites provide.
  Future<void> pumpHost(
    WidgetTester tester,
    Future<void> Function(BuildContext) onTap,
  ) async {
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
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => onTap(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester, List<String> noteIds) =>
      pumpHost(tester, (context) => SpacePickerDialog.show(context, noteIds));

  Future<void> toggle(WidgetTester tester, String spaceName) async {
    await tester.tap(find.widgetWithText(CheckboxListTile, spaceName));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();
  }

  /// The checkbox state each Space row is showing.
  Map<String, bool?> checkboxes(WidgetTester tester) => {
        for (final tile in tester.widgetList<CheckboxListTile>(
          find.byType(CheckboxListTile),
        ))
          (tile.title as Text).data!: tile.value,
      };

  final thesis =
      space('thesis', name: 'Thesis', includeTags: ['thesis', '2026']);
  final reading =
      space('reading', name: 'Reading', includeTags: ['reading', '2026']);

  group('checklist state', () {
    testWidgets('pre-checks the Spaces the note already belongs to', (
      tester,
    ) async {
      await load(
        notes: [note('n1', tags: ['thesis', '2026'])],
        filters: [thesis, reading],
      );
      await openPicker(tester, ['n1']);

      expect(checkboxes(tester), {'Reading': false, 'Thesis': true});
    });

    testWidgets('a partial multi-note membership renders as indeterminate', (
      tester,
    ) async {
      await load(
        notes: [
          note('n1', tags: ['thesis', '2026']),
          note('n2', tags: ['recipes']),
        ],
        filters: [thesis],
      );
      await openPicker(tester, ['n1', 'n2']);

      expect(checkboxes(tester)['Thesis'], isNull);
    });

    testWidgets('an unchanged indeterminate row writes nothing', (
      tester,
    ) async {
      await load(
        notes: [
          note('n1', tags: ['thesis', '2026']),
          note('n2', tags: ['recipes']),
        ],
        filters: [thesis],
      );
      await openPicker(tester, ['n1', 'n2']);
      await confirm(tester);

      expect(tagsOf('n1'), unorderedEquals(['thesis', '2026']));
      expect(tagsOf('n2'), ['recipes']);
      verifyNever(mockDb.updateNote(any));
    });
  });

  group('join', () {
    testWidgets('checking a Space stamps its include tags', (tester) async {
      await load(notes: [note('n1', tags: ['recipes'])], filters: [thesis]);
      await openPicker(tester, ['n1']);

      await toggle(tester, 'Thesis');
      await confirm(tester);

      expect(tagsOf('n1'), containsAll(<String>['recipes', 'thesis', '2026']));
    });

    testWidgets('joining reports how many the Space still hides', (
      tester,
    ) async {
      final tasksOnly = space('tasks', name: 'Sprint',
          includeTags: ['sprint'], noteTypes: [NoteType.task]);
      await load(
        notes: [
          note('a-note'),
          note('a-task', type: NoteType.task),
        ],
        filters: [tasksOnly],
      );
      await openPicker(tester, ['a-note', 'a-task']);

      await toggle(tester, 'Sprint');
      await confirm(tester);

      // Both were stamped; only the task passes the Space's noteTypes.
      expect(tagsOf('a-note'), contains('sprint'));
      expect(
        find.text('2 added · 1 not shown because Sprint only shows tasks'),
        findsOneWidget,
      );
    });

    testWidgets('a join with nothing hidden reports only the count', (
      tester,
    ) async {
      await load(notes: [note('n1')], filters: [thesis]);
      await openPicker(tester, ['n1']);

      await toggle(tester, 'Thesis');
      await confirm(tester);

      expect(find.text('1 added'), findsOneWidget);
    });

    testWidgets('a failed write is surfaced, not assumed to have worked', (
      tester,
    ) async {
      await load(notes: [note('n1')], filters: [thesis]);
      when(mockDb.updateNote(any)).thenThrow(Exception('disk full'));
      await openPicker(tester, ['n1']);

      await toggle(tester, 'Thesis');
      await confirm(tester);

      expect(find.text('Could not update space membership'), findsOneWidget);
      // The dialog stays open so the user can retry rather than walking away
      // believing the note was filed.
      expect(find.byType(SpacePickerDialog), findsOneWidget);
    });
  });

  group('leave', () {
    testWidgets('unchecking removes only the tags no other Space needs', (
      tester,
    ) async {
      // The spec's worked example: leaving Thesis {thesis, 2026} from a note
      // that is also in Reading {reading, 2026} drops `thesis`, keeps `2026`.
      await load(
        notes: [note('n1', tags: ['thesis', '2026', 'reading'])],
        filters: [thesis, reading],
      );
      await openPicker(tester, ['n1']);
      expect(checkboxes(tester), {'Reading': true, 'Thesis': true});

      await toggle(tester, 'Thesis');
      await confirm(tester);

      expect(tagsOf('n1'), unorderedEquals(['2026', 'reading']));
    });

    testWidgets('leaving never removes all-spaces', (tester) async {
      await load(
        notes: [
          note('n1', tags: ['thesis', '2026', SpaceScopeService.allSpacesTag]),
        ],
        filters: [thesis],
      );
      await openPicker(tester, ['n1']);

      await toggle(tester, 'Thesis');
      await confirm(tester);

      expect(tagsOf('n1'), [SpaceScopeService.allSpacesTag]);
    });
  });

  group('multi-select move', () {
    testWidgets('a join and a leave are applied under one confirm', (
      tester,
    ) async {
      await load(
        notes: [
          note('n1', tags: ['thesis', '2026']),
          note('n2', tags: ['thesis', '2026']),
        ],
        filters: [thesis, reading],
      );
      await openPicker(tester, ['n1', 'n2']);

      await toggle(tester, 'Thesis'); // leave
      await toggle(tester, 'Reading'); // join
      await confirm(tester);

      for (final id in ['n1', 'n2']) {
        // `2026` is required by Reading, which the notes now belong to, so the
        // leave-set spares it.
        expect(tagsOf(id), unorderedEquals(['reading', '2026']),
            reason: 'move should end in Reading only, for $id');
      }
    });
  });

  group('show in every space', () {
    testWidgets('adds and removes the all-spaces tag', (tester) async {
      await load(notes: [note('n1', tags: ['thesis'])], filters: [thesis]);
      await pumpHost(tester, (context) async {});

      expect(
        await setShowInEverySpace(provider, ['n1'], true),
        isTrue,
      );
      expect(tagsOf('n1'), contains(SpaceScopeService.allSpacesTag));

      expect(
        await setShowInEverySpace(provider, ['n1'], false),
        isTrue,
      );
      expect(tagsOf('n1'), ['thesis']);
    });

    testWidgets('an all-spaces note is in scope inside every Space', (
      tester,
    ) async {
      await load(
        notes: [note('n1', tags: [SpaceScopeService.allSpacesTag])],
        filters: [thesis, reading],
        activeSpaceId: 'thesis',
      );
      await pumpHost(tester, (context) async {});

      expect(provider.scopedNotes.map((n) => n.id), ['n1']);
      expect(await provider.setActiveSpace('reading'), isTrue);
      expect(provider.scopedNotes.map((n) => n.id), ['n1']);
    });
  });

  group('add existing notes', () {
    /// The notes the picker is offering, top to bottom.
    List<String> offered(WidgetTester tester) => tester
        .widgetList<NoteCard>(find.byType(NoteCard))
        .map((c) => c.note.id)
        .toList();

    testWidgets('offers only the complement of the scope, unfiled first', (
      tester,
    ) async {
      await load(
        notes: [
          note('in-scope', tags: ['thesis', '2026']),
          note('other-space', tags: ['reading', '2026']),
          note('unfiled'),
        ],
        filters: [thesis, reading],
        activeSpaceId: 'thesis',
      );
      await pumpHost(tester, showAddExistingNotesDialog);

      expect(find.byType(NoteSelectionDialog), findsOneWidget);
      // `in-scope` is already in the Space, so offering it would be a no-op;
      // the unfiled note leads because that is what a user is normally filing.
      expect(offered(tester), ['unfiled', 'other-space']);
    });

    testWidgets('an all-spaces note is never offered — it is already in', (
      tester,
    ) async {
      await load(
        notes: [
          note('everywhere', tags: [SpaceScopeService.allSpacesTag]),
          note('unfiled'),
        ],
        filters: [thesis],
        activeSpaceId: 'thesis',
      );
      await pumpHost(tester, showAddExistingNotesDialog);

      expect(offered(tester), ['unfiled']);
    });

    testWidgets('picking notes joins them to the active Space', (tester) async {
      await load(
        notes: [note('in-scope', tags: ['thesis', '2026']), note('unfiled')],
        filters: [thesis],
        activeSpaceId: 'thesis',
      );
      await pumpHost(tester, showAddExistingNotesDialog);

      await tester.tap(find.byType(NoteCard));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Proceed'));
      await tester.pumpAndSettle();

      expect(tagsOf('unfiled'), unorderedEquals(['thesis', '2026']));
      expect(find.text('1 added'), findsOneWidget);
    });

    testWidgets('a note that is already stamped is not counted as added', (
      tester,
    ) async {
      // A Space narrows by more than its tags, so the complement — computed
      // from the authoritative predicate — can contain a note that already
      // carries every include tag. Here `a-note` has `sprint` but is not a
      // task, so Sprint hides it on `noteTypes` alone. Joining it writes
      // nothing, and the toast must not claim it moved.
      final tasksOnly = space('tasks', name: 'Sprint',
          includeTags: ['sprint'], noteTypes: [NoteType.task]);
      await load(
        notes: [
          note('a-note', tags: ['sprint']),
          note('a-task', tags: ['sprint'], type: NoteType.task),
        ],
        filters: [tasksOnly],
        activeSpaceId: 'tasks',
      );
      await pumpHost(tester, showAddExistingNotesDialog);

      expect(offered(tester), ['a-note']);
      await tester.tap(find.byType(NoteCard));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Proceed'));
      await tester.pumpAndSettle();

      expect(find.text('1 added'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('with everything already in scope it says so', (tester) async {
      await load(
        notes: [note('in-scope', tags: ['thesis', '2026'])],
        filters: [thesis],
        activeSpaceId: 'thesis',
      );
      await pumpHost(tester, showAddExistingNotesDialog);

      expect(find.byType(NoteSelectionDialog), findsNothing);
      expect(find.text('Every note is already in Thesis'), findsOneWidget);
    });

    testWidgets('with no active Space it refuses instead of listing every '
        'note', (tester) async {
      await load(notes: [note('n1')], filters: [thesis]);
      await pumpHost(tester, showAddExistingNotesDialog);

      expect(find.byType(NoteSelectionDialog), findsNothing);
      expect(find.text('Activate a space first'), findsOneWidget);
    });
  });
}
