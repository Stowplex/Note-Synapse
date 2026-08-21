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
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/sync/cloud_sync_service.dart';
import 'package:note_synapse/services/sync/google_drive_auth_service.dart';

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
  Future<void> settle(WidgetTester tester) async {
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
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(Duration.zero);
    }
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
    await tester.tap(find.text('Set up dataset'));
    await settle(tester);
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

      await tester.tap(find.text('Set up dataset'));
      await settle(tester);
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
        // Real data in a table no receiving device can build.
        await raw.insert('subnotes', {
          'id': 's1',
          'noteId': 'n1',
          'name': 'step',
          'content': 'body',
          'createdAt': 1000,
          'isCompleted': 0,
        });
      });
      await pumpScreen(tester);

      await tester.tap(find.text('Set up dataset'));
      await settle(tester);
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
        find.textContaining('Sub-tasks'),
        findsWidgets,
        reason: 'and it must say WHAT did not sync',
      );
      expect(
        find.textContaining('subnotes'),
        findsNothing,
        reason:
            'in the user\'s language, not schema jargon — "subnotes (1, '
            'unresolvable column noteId)" tells an engineer everything and a '
            'user nothing',
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
}
