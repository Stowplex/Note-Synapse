import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/add_note_result.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/models/tag.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/screens/note_detail_screen.dart';
import 'package:note_synapse/screens/share_screen.dart';
import 'package:note_synapse/services/content_ingestion_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:note_synapse/widgets/add_note_dialog.dart';
import 'package:note_synapse/widgets/note_card.dart';

import 'space_prefill_test.mocks.dart';

/// M4: the creation prefill and its opt-out.
///
/// The promise under test is invariant 5 / design R5: inside a Space the
/// creator *shows* the Space's tags rather than stamping them behind the user's
/// back, and taking one off before the first save has to stick. It did not:
/// a new note has no row until the 2 s auto-save fires, so `_removeTag` asked
/// `AppProvider` to edit a note it had never heard of and returned quietly,
/// after which `addNote`'s stamp put the tag back anyway. Both halves are
/// exercised here through the real screen.
///
/// The other two interactive creators are driven here too, for the same
/// promise from their own side: [AddNoteDialog], which prefills without ever
/// showing the tags, and [ShareScreen], the one creator that pairs a removable
/// chip UI with `applySpaceTags: false`.
@GenerateMocks([
  DatabaseService,
  UserAppService,
  ModelStorageService,
  TagImageService,
  ContentIngestionService,
])
void main() {
  late MockDatabaseService mockDb;
  late MockUserAppService mockUserAppService;
  late MockModelStorageService mockModelStorage;
  late MockTagImageService mockTagImages;
  late MockContentIngestionService mockIngestion;
  late AppProvider provider;

  final space = Filter(
    id: 'space',
    name: 'Thesis',
    includeTags: const ['thesis', '2026'],
    isSpace: true,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  /// The notes actually written through `insertNote`, in call order.
  final inserted = <Note>[];

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
    mockIngestion = MockContentIngestionService();
    getIt.registerSingleton<UserAppService>(mockUserAppService);
    getIt.registerSingleton<ModelStorageService>(mockModelStorage);
    getIt.registerSingleton<TagImageService>(mockTagImages);
    getIt.registerSingleton<ContentIngestionService>(mockIngestion);
    getIt.registerSingleton<SpaceScopeService>(SpaceScopeService());

    when(mockDb.getAllNotes()).thenAnswer((_) async => []);
    when(mockDb.getAllTags()).thenAnswer((_) async => <Tag>[]);
    when(mockDb.getAllFilters()).thenAnswer((_) async => [space]);
    when(mockDb.getMultiFunctionApps()).thenAnswer((_) async => []);
    when(mockDb.getMultiFunctionDefaultAppId()).thenAnswer((_) async => null);
    inserted.clear();
    when(mockDb.insertNote(any)).thenAnswer((inv) async {
      final note = inv.positionalArguments.first as Note;
      inserted.add(note);
      return note.id;
    });
    when(mockDb.updateNote(any)).thenAnswer((_) async {});
    // `addNote` re-reads the row it just wrote (for converted attachment
    // paths), so the note that comes back is what lands in the provider.
    when(mockDb.getNote(any)).thenAnswer((inv) async {
      final id = inv.positionalArguments.first as String;
      for (final note in inserted.reversed) {
        if (note.id == id) return note;
      }
      return null;
    });
    when(mockDb.getRelationships(any))
        .thenAnswer((_) async => <Relationship>[]);
    when(mockDb.getNoteMetadata(any)).thenAnswer((_) async => null);
    // Read from `build` on a saved note: an unstubbed call would throw, and
    // AppProvider's catch notifies mid-build.
    when(mockDb.getNoteConversationCount(any)).thenAnswer((_) async => 0);
    when(mockDb.getAttachmentsForNote(any)).thenAnswer((_) async => []);
    when(mockUserAppService.getAllUserApps()).thenAnswer((_) async => []);
    when(mockModelStorage.getActiveModel()).thenAnswer((_) async => null);
    when(mockTagImages.getImagePathForTag(any)).thenReturn(null);
    when(mockTagImages.getImagePathsForTags(any)).thenReturn([]);
    when(mockTagImages.appDocsPath).thenReturn(null);
    // The first save fires ingestion; it must not reach a real model.
    when(mockIngestion.processNote(any, any,
            onMessage: anyNamed('onMessage'),
            onError: anyNamed('onError'),
            onSuccess: anyNamed('onSuccess')))
        .thenAnswer((_) async {});
  });

  tearDown(() async {
    await resetForTesting();
  });

  /// Builds the provider **in the test body** and optionally activates the
  /// Space.
  ///
  /// `AppProvider._withCacheLock` chains every locked call onto a future seeded
  /// at construction; a chain seeded outside the widget binding's fake clock
  /// (in `setUp`, or inside `tester.runAsync`) schedules on the real microtask
  /// queue that `pump` never drains, and the auto-save then hangs forever. See
  /// handoff note 7a.
  Future<void> load({bool activate = true}) async {
    provider = AppProvider(
      databaseService: mockDb,
      changeNotifier: DataChangeNotifier(),
    );
    await provider.loadData();
    if (activate) {
      expect(await provider.setActiveSpace('space'), isTrue);
    }
  }

  /// The note a Space-aware creator hands to [NoteDetailScreen]: prefilled with
  /// the Space's tags, exactly as `MainScreen._createNewNote` and
  /// `CalendarScreen._createNewTask` build it.
  Note prefilledNote() => Note(
        id: 'new-1',
        title: '',
        content: '',
        type: NoteType.note,
        createdAt: DateTime(2026, 6, 1),
        updatedAt: DateTime(2026, 6, 1),
        tags: List<String>.of(provider.spaceTags),
      );

  Future<void> pumpDetail(
    WidgetTester tester,
    Note note, {
    bool isNewNote = true,
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
          home: NoteDetailScreen(note: note, isNewNote: isNewNote),
        ),
      ),
    );
    await tester.pump();
  }

  /// The tag chips rendered in the note's Tags section.
  List<String> chips(WidgetTester tester) => tester
      .widgetList<Chip>(find.byType(Chip))
      .map((c) => (c.label as Text).data!)
      .where((t) => t != 'Unsaved' && t != 'Saved')
      .toList();

  /// Deletes the chip labelled [tag] and confirms the dialog.
  Future<void> removeChip(WidgetTester tester, String tag) async {
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text(tag),
          matching: find.byType(Chip),
        ),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
  }

  /// A `testWidgets` that tears the tree down before the binding checks for
  /// pending timers.
  ///
  /// The markdown editor re-arms a cursor-blink timer for as long as it is
  /// focused, and a new note opens focused. The binding asserts "a Timer is
  /// still pending" at the end of the **test body**, before any `addTearDown`
  /// runs, so the disposal has to happen here.
  void detailTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      await body(tester);
      // re_editor's cursor blink arms an uncancellable `Future.delayed(100ms)`
      // on the Android platform the test binding defaults to. Let it land
      // while its controller is still alive, then dispose the tree, which
      // cancels the periodic half of the blink.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
    });
  }

  /// Types a title and lets the 2 s auto-save timer run to completion.
  Future<void> typeAndSave(WidgetTester tester, String title) async {
    await tester.enterText(find.byType(TextField).first, title);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  group('prefill', () {
    detailTest('a new note opens with the Space\'s tags as removable chips', (
      tester,
    ) async {
      await load();
      expect(provider.spaceTags, ['thesis', '2026']);
      await pumpDetail(tester, prefilledNote());

      expect(chips(tester), containsAll(<String>['thesis', '2026']));
    });

    detailTest('the prefill never carries all-spaces (A2)', (tester) async {
      await load();
      await pumpDetail(tester, prefilledNote());

      expect(chips(tester), isNot(contains(SpaceScopeService.allSpacesTag)));
      await typeAndSave(tester, 'Chapter 1');
      expect(
        inserted.single.tags,
        isNot(contains(SpaceScopeService.allSpacesTag)),
      );
    });

    detailTest('with no active Space nothing is prefilled', (tester) async {
      await load(activate: false);
      await pumpDetail(tester, prefilledNote());

      expect(chips(tester), isEmpty);
      await typeAndSave(tester, 'Loose note');
      expect(inserted.single.tags, isEmpty);
    });

    detailTest('an untouched prefill is saved as it stands', (tester) async {
      await load();
      await pumpDetail(tester, prefilledNote());
      await typeAndSave(tester, 'Chapter 1');

      expect(inserted.single.tags, containsAll(<String>['thesis', '2026']));
    });
  });

  group('opt-out (R5) — the one that must not be skipped', () {
    detailTest('removing a prefilled chip before the first save persists', (
      tester,
    ) async {
      await load();
      await pumpDetail(tester, prefilledNote());
      expect(chips(tester), containsAll(<String>['thesis', '2026']));

      await removeChip(tester, 'thesis');
      // The chip has to be gone on screen *and* out of the row that is written
      // next: the original bug passed the first half and failed the second,
      // because the provider silently no-opped and `addNote` re-stamped.
      expect(chips(tester), isNot(contains('thesis')));

      await typeAndSave(tester, 'Chapter 1');

      final saved = inserted.single;
      expect(saved.tags, isNot(contains('thesis')));
      expect(saved.tags, contains('2026'));
    });

    detailTest('removing every prefilled chip saves a fully unstamped note', (
      tester,
    ) async {
      await load();
      await pumpDetail(tester, prefilledNote());

      await removeChip(tester, 'thesis');
      await removeChip(tester, '2026');
      await typeAndSave(tester, 'Chapter 1');

      expect(inserted.single.tags, isEmpty);
    });

    detailTest('removing a chip does not delete the tag globally', (
      tester,
    ) async {
      await load();
      await pumpDetail(tester, prefilledNote());
      await removeChip(tester, 'thesis');
      await tester.pumpAndSettle();

      // Nothing about an unsaved note may reach the tag tables: the chip is a
      // local decision, not a library edit.
      verifyNever(mockDb.deleteTag(any));
      verifyNever(mockDb.updateNote(any));
    });

    detailTest('the Saved outside snackbar fires when only part of the stamp '
        'is kept', (tester) async {
      await load();
      await pumpDetail(tester, prefilledNote());

      // Include tags are ANDed, so a note left carrying only `2026` is
      // **outside** Thesis {thesis, 2026} and disappears from the list the
      // user is looking at. A guard written with `any` sees the surviving
      // `2026`, concludes the note is still in scope and says nothing — the
      // exact surprise this snackbar exists to prevent. Only a single-tag
      // Space makes `any` and `every` agree, which is why this fixture has
      // two.
      await removeChip(tester, 'thesis');
      await typeAndSave(tester, 'Chapter 1');
      expect(find.text('Saved outside Thesis'), findsOneWidget);
    });

    detailTest('an intact stamp says nothing', (tester) async {
      await load();
      await pumpDetail(tester, prefilledNote());

      // The complement of the case above: the guard must fire on a partial
      // stamp without firing on every save.
      await typeAndSave(tester, 'Chapter 1');
      expect(find.textContaining('Saved outside'), findsNothing);
    });

    detailTest('the Saved outside snackbar offers Show all notes', (
      tester,
    ) async {
      await load();
      await pumpDetail(tester, prefilledNote());

      await removeChip(tester, 'thesis');
      await removeChip(tester, '2026');
      await typeAndSave(tester, 'Chapter 1');

      expect(find.text('Saved outside Thesis'), findsOneWidget);
      await tester.tap(find.text('Show all notes'));
      await tester.pumpAndSettle();
      expect(provider.activeSpace, isNull);
    });
  });

  group('adding tags before the first save', () {
    /// Drives the real [TagSelectionDialog] the way a user does: type a name,
    /// submit to create it, then confirm.
    Future<void> addTag(WidgetTester tester, String tag) async {
      await tester.tap(find.widgetWithText(TextButton, 'Add tag'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Add new tag or search'),
        tag,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 Tag'));
      await tester.pumpAndSettle();
    }

    detailTest('a tag added on an unsaved note survives the first save', (
      tester,
    ) async {
      await load();
      await pumpDetail(tester, prefilledNote());

      await addTag(tester, 'draft');
      expect(chips(tester), contains('draft'));

      await typeAndSave(tester, 'Chapter 1');
      expect(inserted.single.tags, contains('draft'));
      expect(inserted.single.tags, containsAll(<String>['thesis', '2026']));
    });

    detailTest('an addition and a removal compose before the first save', (
      tester,
    ) async {
      await load();
      await pumpDetail(tester, prefilledNote());

      await addTag(tester, 'draft');
      await removeChip(tester, 'thesis');
      await typeAndSave(tester, 'Chapter 1');

      expect(inserted.single.tags, isNot(contains('thesis')));
      expect(inserted.single.tags, containsAll(<String>['2026', 'draft']));
    });
  });

  group('note detail menu', () {
    /// A note that already exists, so the screen opens in viewing mode where
    /// the overflow menu lives.
    Note saved() => Note(
          id: 'saved-1',
          title: 'Chapter 1',
          content: 'body',
          type: NoteType.note,
          createdAt: DateTime(2026, 6, 1),
          updatedAt: DateTime(2026, 6, 1),
          tags: const ['thesis', '2026'],
        );

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
    }

    /// Taps the menu entry whose label is [label].
    ///
    /// The enclosing item, not the `Text`: tapping the label's own centre
    /// makes Flutter warn that the derived offset "would not hit test on the
    /// specified widget" — it dispatches anyway, so the test passes only
    /// because the offset happens to land on the right row, and a layout shift
    /// would silently re-point it at a neighbouring one. The cross-space
    /// toggle is a [CheckedPopupMenuItem], so the finder has to accept a
    /// subtype of [PopupMenuItem].
    Future<void> tapMenuItem(WidgetTester tester, String label) async {
      await tester.tap(
        find
            .ancestor(
              of: find.text(label),
              matching: find.bySubtype<PopupMenuItem<String>>(),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }

    detailTest('offers Add to space… and Show in every space', (tester) async {
      when(mockDb.getAllNotes()).thenAnswer((_) async => [saved()]);
      await load();
      await pumpDetail(tester, saved(), isNewNote: false);
      await openMenu(tester);

      expect(find.text('Add to space…'), findsOneWidget);
      expect(find.text('Show in every space'), findsOneWidget);
    });

    detailTest('Show in every space adds the tag and reports it', (
      tester,
    ) async {
      when(mockDb.getAllNotes()).thenAnswer((_) async => [saved()]);
      await load();
      await pumpDetail(tester, saved(), isNewNote: false);
      await openMenu(tester);
      await tapMenuItem(tester, 'Show in every space');

      expect(
        provider.notes.single.tags,
        contains(SpaceScopeService.allSpacesTag),
      );
      expect(find.text('This note now shows in every space'), findsOneWidget);
    });

    detailTest('toggling it off removes the tag again', (tester) async {
      final note = saved().copyWith(
        tags: const ['thesis', '2026', SpaceScopeService.allSpacesTag],
      );
      when(mockDb.getAllNotes()).thenAnswer((_) async => [note]);
      await load();
      await pumpDetail(tester, note, isNewNote: false);
      await openMenu(tester);
      await tapMenuItem(tester, 'Show in every space');

      expect(
        provider.notes.single.tags,
        isNot(contains(SpaceScopeService.allSpacesTag)),
      );
      expect(
        find.text('This note no longer shows in every space'),
        findsOneWidget,
      );
    });
  });

  /// Pumps [child] under the provider, a Navigator and a ScaffoldMessenger —
  /// what every real creator call site sits inside.
  ///
  /// `/main` is registered because [ShareScreen] leaves its flow with
  /// `pushNamedAndRemoveUntil('/main', …)` once the note is written.
  Future<void> pumpApp(WidgetTester tester, Widget child) async {
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
          routes: {'/main': (_) => const Scaffold(body: Text('home'))},
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// §4's named M4 acceptance case: "`AddNoteDialog` prefills and the created
  /// note carries the tags".
  ///
  /// This is the conversation-to-note creator, and it was the one prefill call
  /// site that applied the stamp with no way to decline it: it rendered no
  /// chips, and *Add as-is* asks for a title and writes immediately, so the
  /// tags were never shown and never refusable — invariant 5 named this dialog
  /// and it was the only one of the four creators failing it. It now shows the
  /// tags as removable chips and saves with `applySpaceTags: false`, so a chip
  /// the user takes off cannot be put back by the stamp on the way to the row.
  group('AddNoteDialog', () {
    /// Opens the dialog from a host button and reports its result.
    Future<void> openDialog(
      WidgetTester tester,
      void Function(AddNoteResult?) onDone,
    ) async {
      await pumpApp(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onDone(
                await AddNoteDialog.show(
                  context: context,
                  content: 'Notes from the supervision meeting.',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// Drives *Add as-is* through its title prompt.
    Future<void> addAsIs(WidgetTester tester, String title) async {
      await tester.tap(
        find.ancestor(of: find.text('Add as-is'), matching: find.byType(InkWell))
            .first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), title);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create Note'));
      await tester.pumpAndSettle();
    }

    testWidgets('the created note carries the Space\'s tags, never all-spaces '
        '(A2)', (tester) async {
      await load();
      AddNoteResult? result;
      await openDialog(tester, (r) => result = r);
      await addAsIs(tester, 'Supervision');

      expect(inserted.single.tags, containsAll(<String>['thesis', '2026']));
      expect(
        inserted.single.tags,
        isNot(contains(SpaceScopeService.allSpacesTag)),
      );
      // The prefill also has to be real on the object handed back to the
      // caller, which is what the conversation screens go on to display.
      expect(
        result!.createdNotes.single.tags,
        containsAll(<String>['thesis', '2026']),
      );
    });

    testWidgets('with no active Space it creates an untagged note', (
      tester,
    ) async {
      await load(activate: false);
      AddNoteResult? result;
      await openDialog(tester, (r) => result = r);
      await addAsIs(tester, 'Loose capture');

      expect(inserted.single.tags, isEmpty);
      expect(result!.createdNotes.single.tags, isEmpty);
    });

    /// The chips are the whole of the opt-out here: this dialog has no second
    /// screen and no editor to remove a tag on afterwards.
    testWidgets('shows the prefilled tags as removable chips', (tester) async {
      await load();
      await openDialog(tester, (_) {});

      expect(find.widgetWithText(Chip, 'thesis'), findsOneWidget);
      expect(find.widgetWithText(Chip, '2026'), findsOneWidget);
    });

    testWidgets('renders no chip row outside a Space', (tester) async {
      await load(activate: false);
      await openDialog(tester, (_) {});

      expect(find.byType(Chip), findsNothing);
    });

    /// The R5 promise, on the creator that did not keep it: a removed chip has
    /// to still be gone in the row that gets written. Re-stamping on save is
    /// what made the removal a no-op everywhere else.
    testWidgets('a chip removed before saving stays removed', (tester) async {
      await load();
      AddNoteResult? result;
      await openDialog(tester, (r) => result = r);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(Chip, 'thesis'),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Chip, 'thesis'), findsNothing);

      await addAsIs(tester, 'Partly filed');

      expect(
        inserted.single.tags,
        ['2026'],
        reason: 'the stamp must not put back the tag the user just removed',
      );
      expect(result!.createdNotes.single.tags, ['2026']);
    });

    testWidgets('removing every chip writes an untagged note inside a Space',
        (tester) async {
      await load();
      await openDialog(tester, (_) {});

      for (final tag in ['thesis', '2026']) {
        await tester.tap(
          find.descendant(
            of: find.widgetWithText(Chip, tag),
            matching: find.byIcon(Icons.close),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(find.byType(Chip), findsNothing);

      await addAsIs(tester, 'Deliberately loose');

      expect(inserted.single.tags, isEmpty);
    });
  });

  /// [ShareScreen] is the only creator that pairs a **removable** tag UI with
  /// `applySpaceTags: false`, which is the invariant-5 combination: the stamp
  /// is offered, the user may take it off, and the save must not put it back.
  /// Both halves have to be exercised together — a prefill test alone passes
  /// even when the save re-stamps.
  group('ShareScreen', () {
    /// A plain-text share, the one intent shape that reaches the editable
    /// create form without touching the filesystem, a webview or the AI.
    const shared = {
      'action': 'SEND',
      'type': 'text/plain',
      'text': 'A paragraph worth keeping.',
    };

    /// The labels of the *selected* tag chips.
    List<String> selectedChips(WidgetTester tester) => tester
        .widgetList<Chip>(find.byType(Chip))
        .map((c) => (c.label as Text).data!)
        .toList();

    Future<void> deleteChip(WidgetTester tester, String tag) async {
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text(tag), matching: find.byType(Chip)),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create Note'));
      await tester.pumpAndSettle();
    }

    testWidgets('prefills the Space\'s tags as removable chips', (tester) async {
      await load();
      await pumpApp(tester, const ShareScreen(sharedData: shared));

      expect(selectedChips(tester), containsAll(<String>['thesis', '2026']));
      expect(
        selectedChips(tester),
        isNot(contains(SpaceScopeService.allSpacesTag)),
      );
      // Removable is the whole point of invariant 5: every chip carries its
      // own delete affordance.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('thesis'),
            matching: find.byType(Chip),
          ),
          matching: find.byIcon(Icons.close),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a removed chip stays removed through the save', (
      tester,
    ) async {
      await load();
      await pumpApp(tester, const ShareScreen(sharedData: shared));

      await deleteChip(tester, 'thesis');
      expect(selectedChips(tester), isNot(contains('thesis')));

      await save(tester);

      // `applySpaceTags: false` on the save is what makes this hold; stamping
      // there would put `thesis` straight back and turn the default into a
      // lock.
      final saved = inserted.single;
      expect(saved.tags, isNot(contains('thesis')));
      expect(saved.tags, contains('2026'));
    });

    testWidgets('an untouched prefill is saved as it stands', (tester) async {
      await load();
      await pumpApp(tester, const ShareScreen(sharedData: shared));
      await save(tester);

      expect(inserted.single.tags, containsAll(<String>['thesis', '2026']));
      expect(
        inserted.single.tags,
        isNot(contains(SpaceScopeService.allSpacesTag)),
      );
    });

    testWidgets('with no active Space nothing is prefilled', (tester) async {
      await load(activate: false);
      await pumpApp(tester, const ShareScreen(sharedData: shared));

      expect(selectedChips(tester), isNot(contains('thesis')));
      await save(tester);
      expect(inserted.single.tags, isNot(contains('thesis')));
    });
  });

  group('NoteCard', () {
    test('the active Space\'s own tags are dropped from the chips', () {
      getIt<SpaceScopeService>().setActive('space', ['thesis', '2026']);
      expect(
        NoteCard.visibleTags(['thesis', '2026', 'urgent']),
        ['urgent'],
      );
    });

    test('the globe survives the three-chip truncation', () {
      getIt<SpaceScopeService>().setActive(null, const []);
      // `all-spaces` is the fifth tag, so a plain take(3) would drop it.
      expect(
        NoteCard.visibleTags([
          'a',
          'b',
          'c',
          'd',
          SpaceScopeService.allSpacesTag,
        ]),
        [SpaceScopeService.allSpacesTag, 'a', 'b'],
      );
    });

    test('at most three chips, and no duplicate globe', () {
      getIt<SpaceScopeService>().setActive(null, const []);
      final shown = NoteCard.visibleTags([
        SpaceScopeService.allSpacesTag,
        'a',
        'b',
        'c',
      ]);
      expect(shown.length, 3);
      expect(
        shown.where((t) => t == SpaceScopeService.allSpacesTag).length,
        1,
      );
    });
  });

  group('l10n', () {
    test('every M4 key exists in both app_en.arb and app_zh.arb', () {
      Map<String, dynamic> arb(String path) =>
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final en = arb('lib/l10n/app_en.arb');
      final zh = arb('lib/l10n/app_zh.arb');

      const m4Keys = [
        'addToSpaceMenu',
        'addToSpaceTitle',
        'addToSpaceHint',
        'addToSpaceHintPlural',
        'spaceMembershipPartial',
        'spaceMembershipFailed',
        'showInEverySpace',
        'showInEverySpaceOn',
        'showInEverySpaceOff',
        'addExistingNotesMenu',
        'addExistingNotesTitle',
        'addExistingNotesNoSpace',
        'addExistingNotesNothingLeft',
        'spaceJoinAdded',
        'spaceJoinHiddenTasks',
        'spaceJoinHiddenNotes',
        'spaceJoinHiddenFilter',
        'savedOutsideSpace',
        'showAllNotes',
      ];
      for (final key in m4Keys) {
        expect(en.containsKey(key), isTrue, reason: 'missing in en: $key');
        expect(zh.containsKey(key), isTrue, reason: 'missing in zh: $key');
      }

      // Parity across the whole file, so a later key cannot be added to one
      // side only.
      Set<String> keys(Map<String, dynamic> m) =>
          m.keys.where((k) => !k.startsWith('@')).toSet();
      expect(keys(en).difference(keys(zh)), isEmpty);
      expect(keys(zh).difference(keys(en)), isEmpty);
    });
  });
}
