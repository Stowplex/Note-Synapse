// Tests for M2.9's `CloudSyncService` — the coordinator that turns the
// M2.1-M2.8 machinery into something the settings screen can drive.
//
// Everything here runs against `MockSyncBackend` via the injectable
// `backendFactory`, so no Drive/HTTP/OAuth is involved: what is under test is
// the wiring (status snapshot, bootstrap step, sync round, last-outcome
// persistence), not the backend or the auth flow, both of which have their
// own tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/cloud_sync_service.dart';
import 'package:note_synapse/services/sync/sync_health.dart';
import 'package:note_synapse/services/sync/dataset_bootstrap.dart';
import 'package:note_synapse/services/sync/google_drive_auth_service.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';

import '../sync_backend/mock_sync_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<(CloudSyncService, DatabaseService, MockSyncBackend)>
  makeService() async {
    final db = DatabaseService.createNew();
    await db.database;
    final backend = MockSyncBackend();
    final service = CloudSyncService(
      db,
      authService: GoogleDriveAuthService(),
      backendFactory: () => backend,
    );
    return (service, db, backend);
  }

  test('status() is readable before anything is connected or bootstrapped, '
      'and makes no backend calls', () async {
    final db = DatabaseService.createNew();
    await db.database;
    addTearDown(db.close);

    // Any backend call at all throws, so a passing test is proof that
    // rendering the settings screen touches nothing remote — the user may
    // open it while offline, or before connecting at all.
    final service = CloudSyncService(
      db,
      authService: GoogleDriveAuthService(),
      backendFactory: _ExplodingBackend.new,
    );

    final status = await service.status();
    expect(status.bootstrapStatus, DatasetBootstrapStatus.none);
    expect(status.lastSync, isNull);
    expect(status.canSync, isFalse);
    expect(status.needsDatasetSetup, isFalse);
  });

  test('setUpDataset() runs the create-or-join sequence and flips the status '
      'to ready; a second call is a no-op', () async {
    final (service, db, _) = await makeService();
    addTearDown(db.close);

    final marker = await service.setUpDataset();
    expect(marker, isA<DatasetInitMarker>());
    expect(marker.encryptionEnabled, isFalse);

    expect(
      (await service.status()).bootstrapStatus,
      DatasetBootstrapStatus.ready,
    );

    // Idempotent — the UI offers this as a plain button that can be tapped
    // again after a failure, so re-running must be safe.
    await service.setUpDataset();
    expect(
      (await service.status()).bootstrapStatus,
      DatasetBootstrapStatus.ready,
    );
  });

  test('syncNow() runs a full round and persists the outcome so it survives '
      'leaving the screen', () async {
    final (service, db, _) = await makeService();
    addTearDown(db.close);

    await service.setUpDataset();
    final result = await service.syncNow();
    expect(result.drain.touchesProcessed, isNonNegative);

    final status = await service.status();
    expect(status.bootstrapStatus, DatasetBootstrapStatus.ready);
    // `canSync` is deliberately NOT asserted true here: it also requires a
    // live Drive connection, and this test run compiles with the placeholder
    // debug client ID (state `notConfigured`). That coupling is the point —
    // the Sync now button stays disabled until the account is actually
    // connected, no matter how ready the local dataset is.
    expect(status.canSync, isFalse);
    expect(status.lastSync, isNotNull);
    expect(status.lastSync!.succeeded, isTrue);
    expect(
      status.lastSync!.detail.split('/'),
      hasLength(4),
      reason:
          'A successful outcome stores raw counters '
          '(drained/seeded/pulled/pushed — M2.10 added the seed counter), '
          'not a rendered sentence, so it re-renders in whatever language is '
          'active when it is later displayed.',
    );

    // A fresh service instance over the same database sees it — i.e. it is
    // genuinely persisted, not held in memory.
    final reopened = CloudSyncService(
      db,
      authService: GoogleDriveAuthService(),
      backendFactory: MockSyncBackend.new,
    );
    expect((await reopened.status()).lastSync, isNotNull);
  });

  test('a failing sync records the failure and still rethrows', () async {
    final db = DatabaseService.createNew();
    await db.database;
    addTearDown(db.close);

    final service = CloudSyncService(
      db,
      authService: GoogleDriveAuthService(),
      backendFactory: _ThrowingBackend.new,
    );

    await expectLater(service.syncNow(), throwsA(isA<StateError>()));

    final last = (await service.status()).lastSync;
    expect(last, isNotNull);
    expect(last!.succeeded, isFalse);
    expect(
      last.detail,
      contains('backend is offline'),
      reason:
          'The user needs the real error text; swallowing it into a generic '
          '"sync failed" would make a misconfiguration undiagnosable.',
    );
  });

  test(
    'a round that finishes but does not sync everything is recorded as '
    'DEGRADED, not as a clean success',
    () async {
      // BLOCKER REGRESSION. Before the health surface, `succeeded: true` was
      // written for a session that had permanently dropped a remote
      // operation or skipped an entire table — a green checkmark over
      // undelivered data, which is worse than an error because nothing
      // prompts anyone to look.
      final db = DatabaseService.createNew();
      addTearDown(db.close);
      final service = CloudSyncService(
        db,
        authService: GoogleDriveAuthService(),
        backendFactory: MockSyncBackend.new,
      );
      await service.setUpDataset();

      // A healthy device reports a plain success.
      await service.syncNow();
      var status = await service.status();
      expect(status.lastSync!.succeeded, isTrue);
      expect(status.lastSync!.degraded, isFalse);
      expect(status.health.isDegraded, isFalse);

      // Now give the device real data in a table no peer can build.
      final raw = await db.database;
      await raw.insert('notes', {
        'id': 'n1',
        'title': 'owner',
        'content': '',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await raw.insert('subnotes', {
        'id': 's1',
        'noteId': 'n1',
        'name': 'step',
        'content': 'body',
        'createdAt': 1000,
        'isCompleted': 0,
      });

      await service.syncNow();
      status = await service.status();

      expect(
        status.lastSync!.succeeded,
        isTrue,
        reason: 'the round really did complete',
      );
      expect(
        status.lastSync!.degraded,
        isTrue,
        reason: 'but not everything synced, and the outcome must say so',
      );
      expect(status.health.isDegraded, isTrue);
      final issue = status.health.issues.firstWhere(
        (i) => i.kind == SyncHealthIssueKind.tablesNotSynced,
      );
      expect(issue.detail, contains('subnotes'));

      // Persisted: a fresh service over the same database sees it, so the
      // signal survives leaving the screen and restarting the app.
      final reopened = CloudSyncService(
        db,
        authService: GoogleDriveAuthService(),
        backendFactory: MockSyncBackend.new,
      );
      expect((await reopened.status()).health.isDegraded, isTrue);
    },
  );

  test('LastSyncOutcome tolerates a corrupt stored row', () {
    expect(LastSyncOutcome.fromJsonString(null), isNull);
    expect(LastSyncOutcome.fromJsonString(''), isNull);
    expect(LastSyncOutcome.fromJsonString('not json'), isNull);
    expect(LastSyncOutcome.fromJsonString('{"at":"nonsense"}'), isNull);
    final ok = LastSyncOutcome.fromJsonString(
      '{"at":"2026-01-02T03:04:05.000","succeeded":true,"detail":"1/2/3"}',
    );
    expect(ok, isNotNull);
    expect(ok!.succeeded, isTrue);
    expect(ok.detail, '1/2/3');
  });
}

/// A backend that fails on the first call any sync phase makes, to exercise
/// the failure-recording path without depending on which phase runs first.
class _ThrowingBackend extends MockSyncBackend {
  @override
  Future<List<String>> listDeviceLogIds() async =>
      throw StateError('backend is offline');
}

/// Throws on every `SyncBackend` member. Used to prove a code path makes no
/// backend calls at all.
class _ExplodingBackend implements SyncBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'SyncBackend.${invocation.memberName} was called when it should not have been',
  );
}
