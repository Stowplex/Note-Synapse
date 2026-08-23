// Widget tests for M2.9's Cloud Sync settings screen.
//
// Focused on the state machine the screen renders and on one specific
// regression found in review: **a sync error must not outlive the successful
// run that follows it.** The earlier implementation only ever *set* the
// banner (on failure) and never cleared it, so once anything failed the
// screen accused the user of a problem forever — including after they had
// fixed it and synced successfully. The fix is `_beginAction`, which clears
// the banner at the start of every action; these tests pin that down.
//
// The screen reads `getIt<CloudSyncService>()`, and `CloudSyncService` takes
// both its auth service and its backend by injection, so the whole thing can
// be driven without Drive, HTTP or OAuth. `GoogleDriveAuthService` is
// subclassed to report a connected account — otherwise every button is
// correctly disabled (this test build carries the placeholder client ID, so
// the real service reports `notConfigured`).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/settings/cloud_sync_screen.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/sync/cloud_sync_service.dart';
import 'package:note_synapse/services/sync/drive_folder_identity.dart';
import 'package:note_synapse/services/sync/google_drive_auth_service.dart';
import 'package:note_synapse/services/sync/google_drive_backend.dart';

import '../sync_backend/fake_drive_http_transport.dart';
import '../sync_backend/mock_sync_backend.dart';

/// Reports a healthy connection so the screen's buttons are enabled. Nothing
/// else about the real service is stubbed — `connectionState()` is the only
/// thing standing between this test and a fully disabled screen.
class _ConnectedAuthService extends GoogleDriveAuthService {
  /// When true, [connect] fails — modelling the user re-tapping Connect and
  /// cancelling the Google consent screen, which is the ordinary way a
  /// *transient* (non-persisted) error banner appears on this screen.
  bool failConnect = false;

  @override
  Future<GoogleDriveConnectionState> connectionState() async =>
      GoogleDriveConnectionState.connected;

  @override
  Future<void> connect() async {
    if (failConnect) throw Exception('consent cancelled by user');
  }
}

/// Fails `listDeviceLogIds` (the first backend call a sync round makes) until
/// [failNextSync] is cleared, so one test can drive failure-then-success.
class _FlakyBackend extends MockSyncBackend {
  bool failNextSync = false;

  @override
  Future<List<String>> listDeviceLogIds() {
    if (failNextSync) {
      return Future.error(StateError('drive unreachable'));
    }
    return super.listDeviceLogIds();
  }
}

OAuthConfig _testOAuthConfig() => OAuthConfig(
  authorizationEndpoint: 'https://accounts.google.test/o/oauth2/auth',
  tokenEndpoint: 'https://oauth2.google.test/token',
  clientId: 'test-client-id',
  scope: 'https://www.googleapis.com/auth/drive.file',
  usePkce: true,
  redirectUri: 'notesynapse://oauth/callback',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService db;
  late _FlakyBackend backend;
  late _ConnectedAuthService auth;

  Future<void> setUpService() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    backend = _FlakyBackend();
    auth = _ConnectedAuthService();
    getIt.registerSingleton<CloudSyncService>(
      CloudSyncService(db, authService: auth, backendFactory: () => backend),
    );
  }

  /// The same screen, over a REAL `GoogleDriveBackend` and the production
  /// `sync_state`-backed folder store, with only Drive's HTTP surface faked.
  ///
  /// **Added in review round 2, because `MockSyncBackend` cannot record a
  /// folder id at all.** Every M2.11 screen test ran against it, so
  /// `folder.folderId` was permanently null and the entire "Folder ID:"
  /// affordance — the one thing a user has to copy in order to set up a
  /// second device — was rendered by no widget test in the repo. It also
  /// meant the screen-level ambiguity test drove a *hand-thrown* exception,
  /// so it passed unchanged with the backend's ambiguity check reverted to
  /// the pre-M2.11 `.first`: it pinned rendering while claiming to pin
  /// behaviour.
  Future<void> setUpDriveService(FakeDriveHttpTransport transport) async {
    SharedPreferences.setMockInitialValues({
      'gdrive_oauth_test_token_drive-test': 'test-access-token',
    });
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    auth = _ConnectedAuthService();
    getIt.registerSingleton<CloudSyncService>(
      CloudSyncService(
        db,
        authService: auth,
        backendFactory: () => GoogleDriveBackend(
          tokenManager: OAuthTokenManager(
            endpointId: 'drive-test',
            config: _testOAuthConfig(),
            storagePrefix: 'gdrive_oauth_test_',
          ),
          httpClient: transport,
          folderIdentityStore: SyncStateDriveFolderIdentityStore(db),
        ),
      ),
    );
  }

  tearDown(() async {
    await db.close();
    await resetForTesting();
  });

  /// Lets pending real-event-loop work (the ffi database, and the async
  /// service calls layered on it) finish, then rebuilds.
  ///
  /// Deliberately NOT `pumpAndSettle`: while `_loading` is true the screen
  /// shows a `CircularProgressIndicator`, whose animation never settles, so
  /// `pumpAndSettle` times out rather than waiting for the thing we actually
  /// care about. A bounded runAsync-then-pump loop is the reliable shape for
  /// a screen that mixes real I/O with an indeterminate progress indicator.
  ///
  /// **The two durations below are deliberately different, and only one of
  /// them may be raised.** The `runAsync` delay is a REAL-time budget for
  /// the database/service work behind a tap; the `pump` duration advances
  /// the test binding's FAKE clock, which is what drives widget animations
  /// and `SnackBar` auto-dismissal. M2.10 added a fourth phase to a sync
  /// round (the initial seed scan, plus a second push for the `seed:`
  /// namespace), whose extra awaited round trips no longer fit in the
  /// original 15x40ms real-time budget — the sync was still in flight when
  /// the assertions ran, so the "Sync complete" outcome had not been
  /// re-read into the card yet. Raising the REAL delay fixes that; raising
  /// the iteration count (or the pump duration) would ALSO push the fake
  /// clock far enough to change which snackbars are still on screen, which
  /// these tests' findsNothing assertions genuinely depend on. So: real
  /// time up, fake time unchanged.
  Future<void> settle(
    WidgetTester tester, {
    /// Pass false to leave any raised `SnackBar` on screen — the only way to
    /// assert on what a snackbar says (or, more usefully, does NOT say)
    /// rather than on what the card underneath it says.
    bool dismissSnackBars = true,
  }) async {
    // Phase 1: a fixed number of fake-clock advances, which is what drives
    // animations and SnackBar auto-dismissal.
    //
    // Kept constant out of caution rather than proven necessity: an earlier
    // version of this comment asserted that raising it would change which
    // snackbars are still on screen and so break the `findsNothing`
    // regression guards below. That is not actually what holds those
    // guards — `_beginAction` clearing the transient message slot is
    // (`cloud_sync_screen.dart`), and it does so regardless of timing. The
    // fake clock is left alone because nothing needs it moved, not because
    // moving it is known to be unsafe.
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }

    // Phase 2 — the part that actually matters. Keep giving the real event
    // loop time for as long as the screen is still showing a progress
    // indicator, WITHOUT advancing the fake clock (`Duration.zero`). A sync
    // round is genuinely slower than it was — drain, seed scan, pull, two
    // pushes, and a health recompute — and pinning it to a fixed real-time
    // budget meant every future addition silently turned into "the
    // assertions ran before the work finished." Waiting on the app's own
    // busy signal decouples the two: real time is unbounded (up to a cap),
    // fake time is untouched.
    bool busy() =>
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    for (var i = 0; i < 100 && busy(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(Duration.zero);
    }
    // A few more real-time slices for the post-action `_refreshStatus()`,
    // which runs after the busy flag clears.
    //
    // **Raised from 10 to 30 in review round 2**, and only the REAL budget
    // was raised, per this method's own rule. The trigger was M2.11's
    // "Change folder" flow, whose busy state renders no progress indicator
    // at all (the Set-up button it used to live on is hidden once the device
    // is Ready), so phase 2 exits immediately and this loop is the *entire*
    // budget for a reset plus a create-or-join plus a health recompute plus
    // the `_refreshStatus()` that repaints the result. At 10 the folder card
    // was still showing the pre-change ID when the assertions ran.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(Duration.zero);
    }

    // Phase 3 — retire any `SnackBar` this action raised, by advancing the
    // fake clock past its four-second auto-dismiss.
    //
    // **Necessary, and it makes the assertions stronger rather than weaker.**
    // A `SnackBar` is an overlay: it silently absorbs a tap aimed at the card
    // underneath it, which is how a later `tester.tap(find.text('Sync now'))`
    // came to hit the snackbar instead and do nothing at all. Phase 1's fake
    // ticks all happen *before* the action's real work finishes, so the
    // snackbar was raised into a stretch of time that never advanced. Every
    // `findsWidgets`/`findsNothing` assertion in this file is about text the
    // screen renders into the sync card (via `_transientMessage`, the
    // persisted `LastSyncOutcome`, or the health section), never about a
    // snackbar — so dismissing them removes a way for an assertion to pass
    // on the wrong widget.
    // Several advances rather than one: the first fires the auto-dismiss
    // timer, the rest run the 250ms hide animation to completion. A single
    // large `pump` leaves the snackbar mid-fade — still laid out, still
    // hit-testable, still swallowing the next tap.
    if (!dismissSnackBars) return;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
  }

  /// Drives the dataset step end to end, including M2.11's folder dialog.
  ///
  /// The dialog is now unavoidable on a device with no recorded folder id —
  /// which is every device in these tests — so every pre-M2.11 test that
  /// simply tapped "Set up dataset" and expected "Ready" was, correctly,
  /// left sitting in front of an open dialog. Accepting the pre-filled
  /// default name is the ordinary path.
  Future<void> setUpDatasetViaUi(WidgetTester tester) async {
    await tester.tap(find.text('Set up dataset'));
    await settle(tester);
    await tester.tap(find.text('Continue'));
    await settle(tester);
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const CloudSyncScreen(),
      ),
    );
    await settle(tester);
  }

  testWidgets('renders connected + not-yet-bootstrapped, with Sync now '
      'disabled until the dataset exists', (tester) async {
    await tester.runAsync(setUpService);
    await pumpScreen(tester);

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Not set up yet'), findsOneWidget);
    expect(find.text('Not synced on this device yet'), findsOneWidget);

    final syncTile = tester.widget<ListTile>(
      find.ancestor(of: find.text('Sync now'), matching: find.byType(ListTile)),
    );
    expect(
      syncTile.onTap,
      isNull,
      reason:
          'Sync now must stay disabled until the dataset has been created or '
          'joined — running a sync round before bootstrap would fail against '
          'a backend with no init marker.',
    );
  });

  testWidgets('a sync error is shown, and then CLEARED by the next '
      'successful run', (tester) async {
    await tester.runAsync(setUpService);
    await pumpScreen(tester);

    // 1. Bootstrap so Sync now becomes available.
    await setUpDatasetViaUi(tester);
    expect(find.text('Ready'), findsOneWidget);

    // 2. Make the next sync fail, and run it.
    backend.failNextSync = true;
    await tester.tap(find.text('Sync now'));
    await settle(tester);

    expect(
      find.textContaining('drive unreachable'),
      findsWidgets,
      reason: 'The real error text must reach the user, not a generic message.',
    );

    // 3. Fix the backend and sync again. The error must not survive.
    backend.failNextSync = false;
    await tester.tap(find.text('Sync now'));
    await settle(tester);

    expect(
      find.textContaining('drive unreachable'),
      findsNothing,
      reason:
          'REGRESSION GUARD: the previous run\'s error survived a subsequent '
          'successful sync, leaving the screen permanently reporting a '
          'problem the user had already fixed.',
    );
    expect(find.textContaining('Sync complete'), findsWidgets);
    expect(find.textContaining('Last run:'), findsOneWidget);
  });

  testWidgets(
    'a CONNECT error does not outlive the successful sync that follows it',
    (tester) async {
      // This is the exact shape of the bug found in review, and the one the
      // sibling test above does NOT cover: a connect/disconnect/dataset
      // failure lands in the screen's own transient slot, which takes
      // precedence over the persisted sync outcome. Before `_beginAction`,
      // that slot was only ever *written* (on failure) and never cleared, so
      // the stale error kept winning over every subsequent success — the
      // screen reported a problem the user had already resolved, forever.
      await tester.runAsync(setUpService);
      await pumpScreen(tester);

      await setUpDatasetViaUi(tester);
      expect(find.text('Ready'), findsOneWidget);

      // A failed Connect leaves a transient error banner.
      auth.failConnect = true;
      await tester.tap(find.text('Connect Google Drive'));
      await settle(tester);
      expect(find.textContaining('consent cancelled by user'), findsWidgets);

      // A successful sync must clear it.
      await tester.tap(find.text('Sync now'));
      await settle(tester);

      expect(
        find.textContaining('consent cancelled by user'),
        findsNothing,
        reason:
            'REGRESSION GUARD: the transient error banner survived a later '
            'successful action because it was never cleared at the start of '
            'the next one.',
      );
      expect(find.textContaining('Sync complete'), findsWidgets);
    },
  );

  testWidgets(
    'a last-sync outcome stored BEFORE M2.10 (three counters, no seed phase) '
    'still renders as a sentence rather than raw digits',
    (tester) async {
      // M2.10 changed the persisted format from `drained/pulled/pushed` to
      // `drained/seeded/pulled/pushed`. A user upgrading has a three-part row
      // already sitting in `sync_state`, and the formatter's length check
      // decides whether they see a sentence or a bare "1/2/3". Pinned here
      // because the compatibility branch is otherwise unreachable from any
      // test — nothing writes the old format any more.
      await tester.runAsync(() async {
        await setUpService();
        await (await db.database).insert('sync_state', {
          'key': CloudSyncService.lastSyncStateKey,
          'value': jsonEncode({
            'at': DateTime(2026, 1, 2, 3, 4, 5).toIso8601String(),
            'succeeded': true,
            'detail': '7/8/9',
          }),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      await pumpScreen(tester);

      expect(
        find.textContaining('drained 7'),
        findsWidgets,
        reason: 'the three legacy counters keep their original meaning',
      );
      expect(find.textContaining('pulled 8'), findsWidgets);
      expect(find.textContaining('pushed 9'), findsWidgets);
      expect(
        find.textContaining('seeded 0'),
        findsWidgets,
        reason:
            'a round that ran before the seed phase existed genuinely seeded '
            'nothing, so zero is the truthful value to show',
      );
      expect(
        find.text('7/8/9'),
        findsNothing,
        reason: 'never the raw fallback',
      );
    },
  );

  testWidgets(
    'a degraded round is shown to the user, not hidden behind the success '
    'counters',
    (tester) async {
      // BLOCKER REGRESSION. The reporting spine's whole purpose is that it
      // reaches a human: a session that finished but did not sync everything
      // must not render as an unqualified success.
      await tester.runAsync(() async {
        await setUpService();
        final raw = await db.database;
        await raw.insert('notes', {
          'id': 'n1',
          'title': 'owner',
          'content': '',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        // Real data in a table no receiving device can build. **Which table
        // that is has moved twice**: `subnotes` until M2.14 put its owner FK
        // on `__exists__`, then `app_revisions` until M3.1 carried `appCode`
        // as a blob. What is left is `user_app_libraries`, blocked on a
        // non-portable `INTEGER PRIMARY KEY` — an identity problem an id
        // migration has to solve rather than a content one, so it will
        // outlast the blob deferrals.
        await raw.insert('user_apps', {
          'id': 'app1',
          'uuid': 'uuid-app1',
          'name': 'Counter',
          'description': 'counts',
          'steps': '[]',
          'htmlContent': '',
          'type': 'normal',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await raw.insert('user_app_libraries', {
          'app_uuid': 'uuid-app1',
          'revision_id': 1,
          'name': 'chart.js',
          'usage_instructions': 'draws charts',
        });
      });
      await pumpScreen(tester);

      await setUpDatasetViaUi(tester);
      await tester.tap(find.text('Sync now'));
      await settle(tester);

      expect(
        find.textContaining('some data did not sync'),
        findsWidgets,
        reason:
            'the degraded state must be visible — reporting it into a field '
            'nobody reads is the exact defect this surface exists to fix',
      );
      expect(
        find.textContaining('Mini app libraries'),
        findsWidgets,
        reason: 'and it must say WHAT did not sync',
      );
      expect(
        find.textContaining('user_app_libraries'),
        findsNothing,
        reason:
            'in the user\'s language, not schema jargon — "user_app_libraries '
            '(1, non-portable id)" tells an engineer everything and a user '
            'nothing',
      );
    },
  );

  testWidgets('the plaintext-storage notice names Google itself', (
    tester,
  ) async {
    await tester.runAsync(setUpService);
    await pumpScreen(tester);

    // Users cannot weigh the risk of unencrypted sync without being told who
    // can actually read it. "Only Note Synapse and anyone with access to your
    // Google account" (the earlier wording) omitted the most obvious reader.
    final notice = tester
        .widget<Text>(find.textContaining('without end-to-end encryption'))
        .data!;
    expect(notice, contains('Google'));
  });

  // =========================================================================
  // M2.11 — the folder is named by the user, and identified by its Drive ID.
  // =========================================================================

  testWidgets(
    'the setup step asks which folder to use, and shows back what was chosen',
    (tester) async {
      await tester.runAsync(setUpService);
      await pumpScreen(tester);

      await tester.tap(find.text('Set up dataset'));
      await settle(tester);

      // The whole point of the dialog: the name is no longer a hardcoded
      // string the user never sees, and it is pre-filled rather than blank.
      expect(find.text('Sync folder'), findsOneWidget);
      final nameField = find.widgetWithText(TextField, 'Note Synapse Sync');
      expect(nameField, findsOneWidget);

      await tester.enterText(nameField, 'Family Notes');
      await tester.tap(find.text('Continue'));
      await settle(tester);

      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Folder: Family Notes'), findsOneWidget);
    },
  );

  testWidgets(
    'two REAL folders with the same name are reported as something the user '
    'can act on, not as a raw exception',
    (tester) async {
      // Driven through a real `GoogleDriveBackend` against a real ambiguous
      // Drive state (review round 2). The previous version of this test
      // hand-threw the exception from a mock, so it passed unchanged with
      // `_findRootFolder`'s ambiguity check reverted to the pre-M2.11
      // `existing.first` — it pinned the rendering of a message, not the
      // refusal that produces it.
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() async {
        await setUpDriveService(transport);
        transport.debugCreateFolder('Note Synapse Sync');
        transport.debugCreateFolder('Note Synapse Sync');
      });
      await pumpScreen(tester);

      await setUpDatasetViaUi(tester);

      expect(
        find.textContaining('2 folders in your Drive are called'),
        findsWidgets,
        reason:
            'the count and the name are what let a user find the duplicates',
      );
      expect(
        find.textContaining('rename or remove'),
        findsWidgets,
        reason: 'and the remedy is in Drive, not in this app',
      );
      expect(
        find.textContaining('SyncAmbiguousRootFolderException'),
        findsNothing,
        reason: 'a typed exception exists so the UI never has to quote one',
      );
      expect(
        find.text('Ready'),
        findsNothing,
        reason: 'an ambiguous resolution must not leave the device set up',
      );
      expect(
        transport.debugFolderIds,
        hasLength(2),
        reason: 'and nothing may have been created on the way to that report',
      );
    },
  );

  // =========================================================================
  // M2.11 review round 2 — what the user can actually see and do.
  // =========================================================================

  testWidgets(
    'the folder ID is on screen, selectable, with the hint that says what it '
    'is for',
    (tester) async {
      // The affordance the whole join path depends on, and which no widget
      // test covered because every one of them ran against a backend that
      // cannot record an id.
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() => setUpDriveService(transport));
      await pumpScreen(tester);

      await tester.tap(find.text('Set up dataset'));
      await settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Note Synapse Sync'),
        'Family Notes',
      );
      await tester.tap(find.text('Continue'));
      await settle(tester);

      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Folder: Family Notes'), findsOneWidget);
      final folderId = transport.debugFolderIds.single;
      expect(
        find.text('Folder ID: $folderId'),
        findsOneWidget,
        reason:
            'a user who cannot copy this out of the screen has no way to set '
            'up a second device',
      );
      expect(find.text('Use this ID to set up another device.'), findsOneWidget);
      expect(
        find.textContaining('not recorded yet'),
        findsNothing,
        reason: 'the pending line is for upgraded installs, not for this one',
      );
    },
  );

  testWidgets(
    'the dataset step is busy for as long as its dialog is open, not only '
    'after it closes',
    (tester) async {
      // The guard `if (_settingUp) return;` was checked before the dialog
      // while the flag was set only after it, so every other action on the
      // screen stayed enabled for the whole time the dialog was up. Only a
      // modal barrier hid it, which is not the same as it being right — the
      // dialog is dismissible, and the ordering is what any future
      // non-modal step would inherit.
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() => setUpDriveService(transport));
      await pumpScreen(tester);

      await tester.tap(find.text('Set up dataset'));
      await settle(tester);

      expect(find.text('Sync folder'), findsOneWidget);
      final setUpButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Setting up…'),
      );
      expect(
        setUpButton.onPressed,
        isNull,
        reason: 'the action is in flight the moment the user is being asked',
      );
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      // And cancelling must hand the screen back, not leave it wedged busy.
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Set up dataset'),
            )
            .onPressed,
        isNotNull,
      );
      expect(transport.debugFolderIds, isEmpty);
    },
  );

  testWidgets(
    'F1 REGRESSION: a device that created its own folder can be re-pointed at '
    'the folder another device is using',
    (tester) async {
      // The failure M2.11\'s own fail-loud argument depends on: name
      // discovery finds nothing, so this device creates its own folder,
      // correctly says "Created a new sync folder" — and then, before this
      // fix, had no way back. "Set up dataset" is hidden once Ready, "Reset
      // sync" is offered only for a missing dataset or a diverged log, and
      // the folder dialog was gated on `folderId == null`. The honest
      // fallback was reinstalling the app.
      final transport = FakeDriveHttpTransport();
      late String peerFolder;
      await tester.runAsync(() async {
        await setUpDriveService(transport);
        // Another device's dataset, in a folder this one will not discover
        // (different name).
        peerFolder = await _plantPeerDataset(transport, 'Shared Notes');
      });
      await pumpScreen(tester);

      await setUpDatasetViaUi(tester);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.textContaining('Created a new sync folder'), findsWidgets);
      final ownFolder = (await tester.runAsync(
        () async => getIt<CloudSyncService>().status(),
      ))!.folder.folderId!;
      expect(ownFolder, isNot(peerFolder));

      // The remedy `google_drive_backend.dart` claims is "already on the same
      // screen".
      await tester.tap(find.text('Change folder'));
      await settle(tester);

      expect(
        find.widgetWithText(TextField, ownFolder),
        findsOneWidget,
        reason: 'the dialog re-opens pre-filled, as an edit, not as a blank',
      );
      await tester.enterText(
        find.widgetWithText(TextField, ownFolder),
        peerFolder,
      );
      await tester.tap(find.text('Continue'));
      await settle(tester);

      // Look before committing: a valid-but-wrong id is visible here.
      expect(find.text('Use this folder?'), findsOneWidget);
      expect(find.textContaining('holds a sync dataset started on'), findsOneWidget);
      await tester.tap(find.text('Use this folder'));
      await settle(tester);

      expect(find.textContaining('leaves the dataset it is in now'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Change folder'),
      ));
      await settle(tester);

      expect(
        find.textContaining('Joined the sync dataset'),
        findsWidgets,
        reason: 'the re-point actually joined, rather than creating a third',
      );
      expect(find.text('Folder ID: $peerFolder'), findsOneWidget);
      expect(
        transport.debugFolderIds,
        hasLength(2),
        reason: 'no third folder may be built on the way',
      );
    },
  );

  testWidgets(
    'F1 control: confirming the folder this device already uses changes '
    'nothing and does not reset it',
    (tester) async {
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() => setUpDriveService(transport));
      await pumpScreen(tester);
      await setUpDatasetViaUi(tester);
      final before = (await tester.runAsync(
        () async => getIt<CloudSyncService>().status(),
      ))!;

      await tester.tap(find.text('Change folder'));
      await settle(tester);
      await tester.tap(find.text('Continue'));
      await settle(tester);

      expect(
        find.textContaining('leaves the dataset it is in now'),
        findsNothing,
        reason: 'no warning, because nothing is being changed',
      );
      final after = (await tester.runAsync(
        () async => getIt<CloudSyncService>().status(),
      ))!;
      expect(after.folder.folderId, before.folder.folderId);
      expect(after.bootstrapStatus, before.bootstrapStatus);
      expect(find.text('Ready'), findsOneWidget);
      expect(transport.debugFolderIds, hasLength(1));
    },
  );

  testWidgets(
    'F2 REGRESSION: an already-Ready device that hits an ambiguous folder '
    'name is told what to do, and is still told after leaving the screen',
    (tester) async {
      // The population the ambiguity throw was added for: an install that
      // predates M2.11 has no recorded folder id, so its first sync on the
      // new build resolves by name. Before this fix `_syncNow` had no
      // handler, `bootstrapStatus` stayed `ready`, `needsReset` stayed false,
      // and both the snackbar and the persisted `lastSync.detail` were the
      // raw exception string.
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() async {
        await setUpDriveService(transport);
        final service = getIt<CloudSyncService>();
        await service.setUpDataset(folderName: 'Note Synapse Sync');
        await service.syncNow();
        // Reconstruct genuine pre-M2.11 local state: the folder rows did not
        // exist in that build.
        await (await db.database).delete(
          'sync_state',
          where: 'key IN (?, ?)',
          whereArgs: ['drive_root_folder_id', 'drive_root_folder_name'],
        );
        transport.debugCreateFolder('Note Synapse Sync');
        service.invalidateBackend();
      });
      await pumpScreen(tester);

      expect(
        find.text('Ready'),
        findsOneWidget,
        reason: 'this device believes it is fine, which is the whole problem',
      );
      await tester.tap(find.text('Sync now'));
      // Snackbar left up on purpose: the immediate acknowledgement is a
      // second place the raw exception used to appear, and asserting only
      // on the card would let that half of the defect back in.
      await settle(tester, dismissSnackBars: false);

      expect(
        find.textContaining('2 folders in your Drive are called'),
        findsWidgets,
      );
      expect(
        find.textContaining('SyncAmbiguousRootFolderException'),
        findsNothing,
        reason:
            'neither the snackbar nor the persisted outcome may quote the '
            'exception; the sentinel is what re-renders on every visit',
      );
      await settle(tester);

      // Leave and come back: a snackbar cannot be what is carrying this.
      await pumpScreen(tester);
      expect(
        find.textContaining('2 folders in your Drive are called'),
        findsWidgets,
        reason:
            'recorded on M2.10\'s health spine, so it survives leaving the '
            'screen exactly like M2.13\'s two states do',
      );
      expect(find.textContaining('some data did not sync'), findsWidgets);
    },
  );

  testWidgets(
    'an upgraded install shows its folder section before its first sync, '
    'rather than hiding the ID affordance exactly when it is looked for',
    (tester) async {
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() async {
        await setUpDriveService(transport);
        final service = getIt<CloudSyncService>();
        await service.setUpDataset(folderName: 'Note Synapse Sync');
        await (await db.database).delete(
          'sync_state',
          where: 'key IN (?, ?)',
          whereArgs: ['drive_root_folder_id', 'drive_root_folder_name'],
        );
        service.invalidateBackend();
      });
      await pumpScreen(tester);

      expect(find.text('Folder: Note Synapse Sync'), findsOneWidget);
      expect(
        find.textContaining('Folder ID: not recorded yet'),
        findsOneWidget,
        reason:
            'the id is written lazily by the backend, so saying nothing at '
            'all reads as a missing feature',
      );
    },
  );

  // ── M2.11 review round 3 ────────────────────────────────────────────────

  testWidgets(
    'round-3 finding 1: an UPGRADED install accepting the pre-filled folder '
    'defaults unchanged does not reset itself',
    (tester) async {
      // The upgrade population is the one this milestone exists to serve, and
      // it is the only one where the dialog's pre-filled values differ from
      // the raw stored ones: neither `drive_root_folder_*` row exists, so
      // `folderName` is null while the dialog shows the default. Comparing
      // the choice against the RAW values read as "changed", so one tap on
      // Continue — editing nothing — retired the device identity, wiped the
      // control plane and re-seeded, after showing a warning ("This device
      // leaves the dataset it is in now") that was false for this path.
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() async {
        await setUpDriveService(transport);
        final service = getIt<CloudSyncService>();
        await service.setUpDataset(folderName: 'Note Synapse Sync');
        await service.syncNow();
        await (await db.database).delete(
          'sync_state',
          where: 'key IN (?, ?)',
          whereArgs: ['drive_root_folder_id', 'drive_root_folder_name'],
        );
        service.invalidateBackend();
      });
      await pumpScreen(tester);

      final deviceIdBefore = await tester.runAsync(
        () async => (await (await db.database).query(
          'sync_state',
          where: 'key = ?',
          whereArgs: ['device_id'],
        )).single['value'],
      );

      await tester.tap(find.text('Change folder'));
      await settle(tester);
      await tester.tap(find.text('Continue'));
      await settle(tester);

      expect(
        find.textContaining('leaves the dataset it is in now'),
        findsNothing,
        reason: 'the user edited nothing; there is nothing to warn about',
      );
      final deviceIdAfter = await tester.runAsync(
        () async => (await (await db.database).query(
          'sync_state',
          where: 'key = ?',
          whereArgs: ['device_id'],
        )).single['value'],
      );
      expect(
        deviceIdAfter,
        deviceIdBefore,
        reason: 'a reset retires the identity — the surest signal one ran',
      );
      expect(find.text('Ready'), findsOneWidget);
    },
  );

  testWidgets(
    'round-3 finding 3: a name-only edit is acknowledged rather than '
    'silently dropped',
    (tester) async {
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() => setUpDriveService(transport));
      await pumpScreen(tester);
      await setUpDatasetViaUi(tester);

      await tester.tap(find.text('Change folder'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'Family Notes');
      await tester.tap(find.text('Continue'));
      await settle(tester, dismissSnackBars: false);

      expect(
        find.textContaining('name now follows Drive'),
        findsWidgets,
        reason:
            'once an id is recorded the name is never read for resolution and '
            '_findRootFolder overwrites the stored copy from Drive, so the '
            'edit is correctly inert — but an editable field whose edit '
            'vanishes without a word reads as a bug',
      );
    },
  );

  testWidgets(
    'round-3 finding 5: created-vs-joined survives leaving the screen',
    (tester) async {
      final transport = FakeDriveHttpTransport();
      await tester.runAsync(() => setUpDriveService(transport));
      await pumpScreen(tester);
      await setUpDatasetViaUi(tester);

      // A genuine re-entry, not a re-pump of the same State: pump something
      // else first so the screen's State is disposed.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await pumpScreen(tester);

      expect(
        find.textContaining('This device created this sync dataset'),
        findsOneWidget,
        reason:
            'this is the signal that distinguishes "joined device 1\'s '
            'dataset" from "silently made a second one" — the whole '
            'diagnosability story for the unverified drive.file cross-device '
            'listing question. A line lost on the next tap is not a signal.',
      );
    },
  );

  testWidgets(
    'the storage cleanup card shows pending and eligible SEPARATELY, and '
    'offers deletion only when something is actually eligible',
    (tester) async {
      await tester.runAsync(setUpService);
      await pumpScreen(tester);
      await setUpDatasetViaUi(tester);

      // The card sits below the fold on a test-sized viewport.
      await tester.scrollUntilVisible(
        find.text('Check for reclaimable files'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Check for reclaimable files'));
      await settle(tester);

      expect(
        find.textContaining('Nothing to reclaim'),
        findsOneWidget,
        reason:
            'a fresh dataset has nothing unreferenced, and saying so beats '
            'an empty card the user cannot interpret',
      );
      expect(
        find.text('Delete now'),
        findsNothing,
        reason:
            'the delete action appears only when the grace period has '
            'actually elapsed for something — requirement 10 makes the human '
            'checkpoint the last layer, not the only one',
      );
    },
  );

}

/// Creates a second device's dataset in its own Drive folder, and returns
/// that folder's id — the thing a user would copy off the other device's
/// settings screen.
Future<String> _plantPeerDataset(
  FakeDriveHttpTransport transport,
  String folderName,
) async {
  final peerDb = DatabaseService.createNew();
  final peer = CloudSyncService(
    peerDb,
    authService: _ConnectedAuthService(),
    backendFactory: () => GoogleDriveBackend(
      tokenManager: OAuthTokenManager(
        endpointId: 'drive-test',
        config: _testOAuthConfig(),
        storagePrefix: 'gdrive_oauth_test_',
      ),
      httpClient: transport,
      folderIdentityStore: SyncStateDriveFolderIdentityStore(peerDb),
    ),
  );
  await peer.setUpDataset(folderName: folderName);
  final id = (await peer.status()).folder.folderId!;
  await peerDb.close();
  return id;
}