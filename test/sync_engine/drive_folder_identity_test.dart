// M2.11 — the Drive sync root is identified by its Drive file ID, chosen by
// the user at setup, and never re-resolved from a name once it is known.
//
// Every scenario below is one of the three defects
// `drive_folder_identity.dart`'s header names, or one of the two states
// M2.13 built the recovery path for. Grouped that way rather than by class
// under test, because the point of the milestone is the behaviour, not the
// call graph:
//
//   * a folder the user named, and an ID recorded for it;
//   * a rename in Drive that changes nothing;
//   * two same-named folders that stop the app instead of being guessed at;
//   * a recorded ID that vanishes, reaching the user as M2.13's
//     missing-dataset flow — and a transport failure that pointedly does
//     NOT;
//   * an install that predates all of this, upgraded in one listing.
//
// **Fidelity, stated once.** These run against `FakeDriveHttpTransport`, a
// hand-written model of Drive's REST v3 surface, not the real API — the
// same standing every other `GoogleDriveBackend` test in this repo has, and
// the same disclosure: no request in this effort has ever reached a real
// Google server. What that means specifically for M2.11 is that the
// cross-device *listing* question the join path turns on (can device B see
// the folder device A created, under `drive.file`?) is NOT settled by any
// test here; see `google_drive_backend.dart`'s M2.11 note. What is settled
// here is that the failure, if it goes the other way, is a folder this
// device created and says it created — not an empty dataset reported as a
// successful join.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/sync/cloud_sync_service.dart';
import 'package:note_synapse/services/sync/dataset_bootstrap.dart';
import 'package:note_synapse/services/sync/dataset_reset.dart';
import 'package:note_synapse/services/sync/drive_folder_identity.dart';
import 'package:note_synapse/services/sync/google_drive_auth_service.dart';
import 'package:note_synapse/services/sync/google_drive_backend.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_backend_exceptions.dart';
import 'package:note_synapse/services/sync/sync_health.dart';

import '../sync_backend/fake_drive_http_transport.dart';

OAuthConfig _testOAuthConfig() => OAuthConfig(
  authorizationEndpoint: 'https://accounts.google.test/o/oauth2/auth',
  tokenEndpoint: 'https://oauth2.google.test/token',
  clientId: 'test-client-id',
  scope: 'https://www.googleapis.com/auth/drive.file',
  usePkce: true,
  redirectUri: 'notesynapse://oauth/callback',
);

GoogleDriveBackend _backend(
  FakeDriveHttpTransport transport, {
  DriveFolderIdentityStore? store,
  String rootFolderName = defaultDriveRootFolderName,
}) {
  return GoogleDriveBackend(
    tokenManager: OAuthTokenManager(
      endpointId: 'drive-test',
      config: _testOAuthConfig(),
      storagePrefix: 'gdrive_oauth_test_',
    ),
    httpClient: transport,
    rootFolderName: rootFolderName,
    folderIdentityStore: store,
  );
}

DatasetInitMarker _marker(String deviceId) => DatasetInitMarker(
  encryptionEnabled: false,
  kdfSalt: null,
  passphraseCanary: null,
  createdByDeviceId: deviceId,
  createdAt: DateTime.utc(2026, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'gdrive_oauth_test_token_drive-test': 'test-access-token',
    });
  });

  // =========================================================================
  group('M2.11 folder identity — GoogleDriveBackend', () {
    // =======================================================================

    test(
      'fresh setup creates a folder with the name the user chose and records '
      'its Drive ID',
      () async {
        final transport = FakeDriveHttpTransport();
        final store = InMemoryDriveFolderIdentityStore(
          const DriveFolderIdentity(folderName: 'Bruce の Notes'),
        );
        final backend = _backend(transport, store: store);

        await backend.initializeDatasetOnce(_marker('device-a'));

        final folders = transport.debugFolderIds;
        expect(folders, hasLength(1));
        expect(transport.debugNameOf(folders.single), 'Bruce の Notes');

        final stored = await store.read();
        expect(stored.folderId, folders.single);
        expect(stored.folderName, 'Bruce の Notes');
      },
    );

    test(
      'renaming the folder in Drive does not orphan the dataset: a later run '
      'resolves it by ID and creates nothing',
      () async {
        final transport = FakeDriveHttpTransport();
        final store = InMemoryDriveFolderIdentityStore();

        await _backend(transport, store: store)
            .initializeDatasetOnce(_marker('device-a'));
        final folderId = transport.debugFolderIds.single;

        // Exactly what a user does in Drive's own UI, and what pre-M2.11
        // resolution had no answer for.
        transport.debugRenameFile(folderId, 'Old Sync Junk');

        // A new instance, i.e. the next app launch: no in-memory cache, only
        // the durable identity.
        final relaunched = _backend(transport, store: store);
        final marker = await relaunched.readDatasetInitMarker();

        expect(
          marker?.createdByDeviceId,
          'device-a',
          reason: 'the renamed folder is still this dataset',
        );
        expect(
          transport.debugFolderIds,
          hasLength(1),
          reason: 'a second folder here would be the orphaning bug',
        );
      },
    );

    test(
      'two folders answering to the configured name fail loudly instead of '
      'one being picked',
      () async {
        final transport = FakeDriveHttpTransport();
        transport.debugCreateFolder(defaultDriveRootFolderName);
        transport.debugCreateFolder(defaultDriveRootFolderName);

        final store = InMemoryDriveFolderIdentityStore();
        final backend = _backend(transport, store: store);

        await expectLater(
          backend.readDatasetInitMarker(),
          throwsA(
            isA<SyncAmbiguousRootFolderException>()
                .having((e) => e.candidateCount, 'candidateCount', 2)
                .having((e) => e.folderName, 'folderName',
                    defaultDriveRootFolderName)
                .having((e) => e.candidateIds, 'candidateIds', hasLength(2)),
          ),
        );

        expect(
          (await store.read()).folderId,
          isNull,
          reason: 'nothing may be recorded from an ambiguous resolution',
        );
        expect(
          transport.debugFolderIds,
          hasLength(2),
          reason: 'and nothing may be created from one either',
        );
      },
    );

    test(
      'ambiguity is unreachable once an ID is recorded — a duplicate created '
      'later cannot confuse a device that already knows its folder',
      () async {
        final transport = FakeDriveHttpTransport();
        final store = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: store)
            .initializeDatasetOnce(_marker('device-a'));

        transport.debugCreateFolder(defaultDriveRootFolderName);
        transport.debugCreateFolder(defaultDriveRootFolderName);

        final marker =
            await _backend(transport, store: store).readDatasetInitMarker();
        expect(marker?.createdByDeviceId, 'device-a');
      },
    );

    test(
      'a recorded folder ID that 404s reads as "no dataset", and no '
      'replacement folder is created underneath the device',
      () async {
        final transport = FakeDriveHttpTransport();
        final store = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: store)
            .initializeDatasetOnce(_marker('device-a'));
        final folderId = transport.debugFolderIds.single;

        transport.debugDeleteFile(folderId);

        final relaunched = _backend(transport, store: store);
        expect(
          await relaunched.readDatasetInitMarker(),
          isNull,
          reason: 'this null is what M2.13 turns into DatasetPresence.missing',
        );
        expect(transport.debugFolderIds, isEmpty);

        // And a write path must refuse rather than quietly building a new
        // dataset root for a device that still believes it is Ready.
        await expectLater(
          relaunched.appendCommit(
            deviceLogId: 'device-a',
            deviceSeq: 1,
            publishIntentId: 'i1',
            parentCommitHash: null,
            commitBytes: Uint8List.fromList([1, 2, 3]),
          ),
          throwsA(isA<SyncRootFolderMissingException>()),
        );
        expect(transport.debugFolderIds, isEmpty);
      },
    );

    test(
      'a folder moved to Drive\'s trash counts as gone, even though it still '
      'resolves by ID',
      () async {
        final transport = FakeDriveHttpTransport();
        final store = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: store)
            .initializeDatasetOnce(_marker('device-a'));
        transport.debugTrashFile(transport.debugFolderIds.single);

        expect(
          await _backend(transport, store: store).readDatasetInitMarker(),
          isNull,
        );
      },
    );

    test(
      'a transport failure while resolving the recorded ID propagates as a '
      'transport failure — never as a vanished dataset',
      () async {
        final transport = FakeDriveHttpTransport();
        final store = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: store)
            .initializeDatasetOnce(_marker('device-a'));
        final folderId = transport.debugFolderIds.single;

        transport.scriptedFailures.add(
          ScriptedDriveFailure.serverError(
            matches: (r) =>
                r.method == 'GET' && r.url.path.endsWith('/files/$folderId'),
          ),
        );

        final relaunched = _backend(transport, store: store);
        await expectLater(
          relaunched.readDatasetInitMarker(),
          throwsA(isA<SyncNetworkException>()),
          reason:
              'telling an offline user their data was deleted is a far worse '
              'bug than the one M2.11 fixes',
        );

        expect(
          (await store.read()).folderId,
          folderId,
          reason: 'a transport failure must not un-record anything',
        );
        // And the very next attempt, with the network back, is fine.
        expect(
          (await relaunched.readDatasetInitMarker())?.createdByDeviceId,
          'device-a',
        );
      },
    );

    test(
      'upgrade path: an install that predates M2.11 resolves its existing '
      'name-created folder exactly once, then addresses it by ID forever',
      () async {
        final transport = FakeDriveHttpTransport();

        // The pre-M2.11 world: a folder created under the hardcoded name,
        // with nothing recorded anywhere about its ID.
        await _backend(
          transport,
          store: InMemoryDriveFolderIdentityStore(),
        ).initializeDatasetOnce(_marker('device-a'));
        final folderId = transport.debugFolderIds.single;

        // The updated build's first run: an empty durable store.
        final store = InMemoryDriveFolderIdentityStore();
        final upgraded = _backend(transport, store: store);
        expect(
          (await upgraded.readDatasetInitMarker())?.createdByDeviceId,
          'device-a',
        );
        expect((await store.read()).folderId, folderId);
        expect(transport.debugFolderIds, hasLength(1));

        // From here the name is dead weight: rename it and the next launch
        // still finds the dataset, which is the whole claim.
        transport.debugRenameFile(folderId, 'renamed after upgrade');
        final afterRename = _backend(transport, store: store);
        transport.debugResetRequestLog();
        expect(
          (await afterRename.readDatasetInitMarker())?.createdByDeviceId,
          'device-a',
        );
        expect(
          transport.debugRequestLog.first,
          'GET /drive/v3/files/$folderId',
          reason:
              'resolution must start from the recorded ID, not from a '
              'name-filtered listing',
        );
      },
    );

    test(
      'an ambiguous upgrade throws out of the BACKEND rather than picking',
      // **Renamed in review round 2, because the old name named a
      // beneficiary this test says nothing about.** It read "the existing
      // user is exactly who an arbitrary pick would hurt" and then asserted
      // only that `readDatasetInitMarker` throws — while that same user, on
      // the shipped build, saw the exception's `toString()` in a red box
      // with no remedy, because `CloudSyncScreen._syncNow` had no handler
      // for it (finding F2). What the user actually sees is now pinned where
      // it can be: the `CloudSyncService` group below (durable sentinel plus
      // a health issue) and `cloud_sync_screen_test.dart`'s "F2 REGRESSION"
      // widget test.
      () async {
        final transport = FakeDriveHttpTransport();
        await _backend(
          transport,
          store: InMemoryDriveFolderIdentityStore(),
        ).initializeDatasetOnce(_marker('device-a'));
        // A duplicate left behind by a Drive cleanup / an earlier run.
        transport.debugCreateFolder(defaultDriveRootFolderName);

        await expectLater(
          _backend(transport, store: InMemoryDriveFolderIdentityStore())
              .readDatasetInitMarker(),
          throwsA(isA<SyncAmbiguousRootFolderException>()),
        );
      },
    );

    test(
      'two devices racing to create the root folder converge on one, rather '
      'than each recording the folder it personally created',
      () async {
        // The regression M2.11 could have introduced from the other end:
        // recording an ID removes the pre-M2.11 "everyone re-lists and takes
        // the oldest" convergence, so the create/create race would have
        // produced two permanent datasets. See `_createRootFolder`.
        final transport = FakeDriveHttpTransport();
        final storeA = InMemoryDriveFolderIdentityStore();
        final storeB = InMemoryDriveFolderIdentityStore();

        await Future.wait([
          _backend(transport, store: storeA)
              .initializeDatasetOnce(_marker('device-a')),
          _backend(transport, store: storeB)
              .initializeDatasetOnce(_marker('device-b')),
        ]);

        final idA = (await storeA.read()).folderId;
        final idB = (await storeB.read()).folderId;
        expect(idA, isNotNull);
        expect(
          idA,
          idB,
          reason: 'both devices must end up in the same folder',
        );

        // And both read back the same dataset, whichever marker won.
        final seenByA =
            await _backend(transport, store: storeA).readDatasetInitMarker();
        final seenByB =
            await _backend(transport, store: storeB).readDatasetInitMarker();
        expect(seenByA!.createdByDeviceId, seenByB!.createdByDeviceId);
      },
    );

    test(
      'adoptRootFolder validates before recording: a bad ID throws and leaves '
      'the store untouched; a good one joins that exact folder',
      () async {
        final transport = FakeDriveHttpTransport();
        final storeA = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: storeA)
            .initializeDatasetOnce(_marker('device-a'));
        final folderId = transport.debugFolderIds.single;

        final storeB = InMemoryDriveFolderIdentityStore();
        final joiner = _backend(transport, store: storeB);

        await expectLater(
          joiner.adoptRootFolder('file-does-not-exist'),
          throwsA(isA<SyncRootFolderMissingException>()),
        );
        expect(
          (await storeB.read()).folderId,
          isNull,
          reason: 'a typo must never become a stored handle',
        );

        final adopted = await joiner.adoptRootFolder('  $folderId  ');
        expect(adopted.folderId, folderId);
        expect((await storeB.read()).folderId, folderId);
        expect(
          (await joiner.readDatasetInitMarker())?.createdByDeviceId,
          'device-a',
          reason: 'the joiner sees the creator\'s dataset, not a new one',
        );
        expect(transport.debugFolderIds, hasLength(1));
      },
    );
  });

  // =========================================================================
  group('M2.11 folder identity — CloudSyncService wiring', () {
    // =======================================================================

    /// A service whose backend is a REAL `GoogleDriveBackend` over the fake
    /// transport, with the production `sync_state`-backed folder store —
    /// i.e. the whole M2.11 path, not a stand-in for part of it.
    (CloudSyncService, DatabaseService) makeService(
      FakeDriveHttpTransport transport,
    ) {
      final db = DatabaseService.createNew();
      final service = CloudSyncService(
        db,
        authService: GoogleDriveAuthService(),
        backendFactory: () => _backend(
          transport,
          store: SyncStateDriveFolderIdentityStore(db),
        ),
      );
      return (service, db);
    }

    test(
      'setUpDataset(folderName:) creates the folder under that name and the '
      'settings screen can read back both name and ID',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        final marker = await service.setUpDataset(folderName: 'Family Notes');
        expect(await service.datasetWasCreatedByThisDevice(marker), isTrue);

        final status = await service.status();
        expect(status.bootstrapStatus, DatasetBootstrapStatus.ready);
        expect(status.folder.folderName, 'Family Notes');
        expect(status.folder.folderId, transport.debugFolderIds.single);
        expect(transport.debugNameOf(status.folder.folderId!), 'Family Notes');
      },
    );

    test(
      'setUpDataset(folderId:) joins the dataset that folder already holds, '
      'and reports itself as a join rather than a creation',
      () async {
        final transport = FakeDriveHttpTransport();
        final (creator, dbA) = makeService(transport);
        addTearDown(dbA.close);
        await creator.setUpDataset(folderName: 'Shared');
        final folderId = (await creator.status()).folder.folderId!;

        final (joiner, dbB) = makeService(transport);
        addTearDown(dbB.close);
        final marker = await joiner.setUpDataset(folderId: folderId);

        expect(
          await joiner.datasetWasCreatedByThisDevice(marker),
          isFalse,
          reason:
              'created-vs-joined is what makes a failed join diagnosable '
              'instead of an empty dataset that looks fine',
        );
        expect((await joiner.status()).folder.folderId, folderId);
        expect(transport.debugFolderIds, hasLength(1));
      },
    );

    test('setUpDataset with an unusable folder ID fails before recording it',
        () async {
      final transport = FakeDriveHttpTransport();
      final (service, db) = makeService(transport);
      addTearDown(db.close);

      await expectLater(
        service.setUpDataset(folderId: 'nope'),
        throwsA(isA<SyncRootFolderMissingException>()),
      );
      final status = await service.status();
      expect(status.folder.folderId, isNull);
      expect(status.bootstrapStatus, DatasetBootstrapStatus.none);
      expect(transport.debugFolderIds, isEmpty);
    });

    test(
      'a vanished folder reaches the user as M2.13\'s missing-dataset flow, '
      'not as a fresh empty dataset',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        await service.setUpDataset(folderName: 'Notes');
        await service.syncNow();
        final folderId = (await service.status()).folder.folderId!;

        transport.debugDeleteFile(folderId);
        // Next launch / next resolution: drop the in-memory folder cache the
        // way `invalidateBackend` does after a disconnect or a reset.
        service.invalidateBackend();

        await expectLater(
          service.syncNow(),
          throwsA(isA<DatasetMissingException>()),
        );

        final status = await service.status();
        expect(status.bootstrapStatus, DatasetBootstrapStatus.needsReset);
        expect(status.needsReset, isTrue);
        expect(status.canReset, isTrue);
        expect(
          status.health.issues.map((i) => i.kind),
          contains(SyncHealthIssueKind.datasetMissing),
        );
        expect(
          status.lastSync?.detail,
          syncFailureDatasetMissing,
          reason: 'the settings screen localizes this sentinel',
        );
        expect(
          transport.debugFolderIds,
          isEmpty,
          reason: 'nothing may have been recreated on the way to that report',
        );
      },
    );

    test(
      'a transport failure resolving the folder is NOT reported as a deleted '
      'dataset',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        await service.setUpDataset(folderName: 'Notes');
        await service.syncNow();
        final folderId = (await service.status()).folder.folderId!;

        service.invalidateBackend();
        transport.scriptedFailures.add(
          ScriptedDriveFailure.serverError(
            matches: (r) =>
                r.method == 'GET' && r.url.path.endsWith('/files/$folderId'),
          ),
        );

        await expectLater(
          service.syncNow(),
          throwsA(isA<SyncNetworkException>()),
        );

        final status = await service.status();
        expect(
          status.bootstrapStatus,
          DatasetBootstrapStatus.ready,
          reason: 'the dataset is fine; the network was not',
        );
        expect(status.needsReset, isFalse);
        expect(
          status.health.issues.map((i) => i.kind),
          isNot(contains(SyncHealthIssueKind.datasetMissing)),
        );
        expect(status.folder.folderId, folderId);
      },
    );

    test(
      'a reset preserves the folder identity, so the device rejoins the same '
      'folder instead of re-resolving a name',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        await service.setUpDataset(folderName: 'Notes');
        await service.syncNow();
        final folderId = (await service.status()).folder.folderId!;

        await service.resetSyncState();

        final afterReset = await service.status();
        expect(afterReset.bootstrapStatus, DatasetBootstrapStatus.none);
        expect(
          afterReset.folder.folderId,
          folderId,
          reason: DatasetReset.preservedSyncStateKeys.toString(),
        );

        // Rename it too, to prove the rejoin is by ID and not by luck.
        transport.debugRenameFile(folderId, 'renamed while reset');
        final marker = await service.setUpDataset();
        expect(
          await service.datasetWasCreatedByThisDevice(marker),
          isFalse,
          reason: 'the reset device rejoins the dataset it was already in',
        );
        expect(transport.debugFolderIds, hasLength(1));
      },
    );

    test(
      'a reset after the folder was deleted is not stranded: setup builds a '
      'fresh folder and reuses the name the user chose',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        await service.setUpDataset(folderName: 'Notes');
        await service.syncNow();
        final folderId = (await service.status()).folder.folderId!;

        transport.debugDeleteFile(folderId);
        service.invalidateBackend();
        await expectLater(
          service.syncNow(),
          throwsA(isA<DatasetMissingException>()),
        );

        await service.resetSyncState();
        final marker = await service.setUpDataset();

        expect(await service.datasetWasCreatedByThisDevice(marker), isTrue);
        final status = await service.status();
        expect(status.bootstrapStatus, DatasetBootstrapStatus.ready);
        expect(transport.debugFolderIds, hasLength(1));
        expect(status.folder.folderId, isNot(folderId));
        expect(transport.debugNameOf(status.folder.folderId!), 'Notes');
      },
    );
  });

  // =========================================================================
  group('M2.11 review round 2 — root-folder reconciliation', () {
    // =======================================================================
    //
    // Every test below is one of the four findings the second adversarial
    // pass reproduced against the shipped tree, plus the control that shows
    // the correct behaviour it must not cost.

    test(
      'F3 tie-break: two folders Drive reports as created at the identical '
      'instant still resolve to ONE folder on both devices',
      () async {
        // `createdTime` is millisecond-resolution in Drive, so two folders
        // created in the same millisecond by two racing devices is an
        // ordinary outcome rather than an exotic one. A strict `isBefore`
        // comparison is a partial order: under a tie neither candidate beats
        // the other, so each device keeps the folder it personally created —
        // the split-brain the reconciliation exists to prevent, reached
        // through the reconciliation itself.
        final transport = FakeDriveHttpTransport();
        transport.debugFreezeCreatedTimeAt(DateTime.utc(2026, 3, 3));
        final storeA = InMemoryDriveFolderIdentityStore();
        final storeB = InMemoryDriveFolderIdentityStore();

        await Future.wait([
          _backend(transport, store: storeA)
              .initializeDatasetOnce(_marker('device-a')),
          _backend(transport, store: storeB)
              .initializeDatasetOnce(_marker('device-b')),
        ]);

        expect(
          transport.debugFolderIds,
          hasLength(2),
          reason: 'the create/create race must actually have happened',
        );
        final idA = (await storeA.read()).folderId;
        expect(idA, isNotNull);
        expect(
          idA,
          (await storeB.read()).folderId,
          reason:
              'a tie must be broken by something total and stable — '
              '(createdTime, id) — not left to each device',
        );
      },
    );

    test(
      'F4: three same-named folders behind a lagging first listing are '
      'refused, not silently resolved to one of them',
      () async {
        // The identical Drive state throws one call earlier (`_findRootFolder`
        // sees all three) and, before this fix, was silently resolved one call
        // later: the first listing lagged, saw zero, so a fourth folder was
        // created and the post-create reconciliation quietly adopted the
        // oldest of the three — a folder this device neither created nor
        // discovered.
        final transport = FakeDriveHttpTransport();
        final planted = [
          transport.debugCreateFolder(defaultDriveRootFolderName),
          transport.debugCreateFolder(defaultDriveRootFolderName),
          transport.debugCreateFolder(defaultDriveRootFolderName),
        ];
        for (final id in planted) {
          transport.debugHideFromListings(id, forListCalls: 2);
        }

        final store = InMemoryDriveFolderIdentityStore();
        await expectLater(
          _backend(transport, store: store)
              .initializeDatasetOnce(_marker('device-a')),
          throwsA(
            isA<SyncAmbiguousRootFolderException>().having(
              (e) => e.candidateCount,
              'candidateCount',
              3,
            ),
          ),
        );
        expect(
          (await store.read()).folderId,
          isNull,
          reason: 'nothing may be recorded from an ambiguous reconciliation',
        );
      },
    );

    test(
      'F4 control: ONE pre-existing folder behind the same lagging listing '
      'still converges on it — the ambiguity rule must not cost that',
      () async {
        final transport = FakeDriveHttpTransport();
        final peer = transport.debugCreateFolder(defaultDriveRootFolderName);
        transport.debugHideFromListings(peer, forListCalls: 2);

        final store = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: store)
            .initializeDatasetOnce(_marker('device-a'));

        expect(
          (await store.read()).folderId,
          peer,
          reason:
              'the whole point of the post-create reconciliation: the older '
              'folder wins even though this device could not see it first',
        );
      },
    );

    test(
      'F3 disclosure: a listing that lags on ONE side leaves the two devices '
      'permanently split, and no later launch repairs it',
      () async {
        // Pinned as a DISCLOSURE, not as a desired behaviour. The shipped
        // doc claimed the exposure needed the listing to lag on *both*
        // devices and that it matched pre-M2.11; both were false — a lag on
        // the single side that created the newer folder suffices, and
        // pre-M2.11 re-resolved by name every launch, so it healed on the
        // next run. Persisting an id is what makes it permanent. If a
        // self-heal is ever added, this test is the thing that must be
        // consciously rewritten.
        final transport = FakeDriveHttpTransport();
        final storeB = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: storeB)
            .initializeDatasetOnce(_marker('device-b'));
        final folderB = (await storeB.read()).folderId!;

        // Drive's listing index has not yet surfaced B's folder to A.
        transport.debugHideFromListings(folderB, forListCalls: 10);

        final storeA = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: storeA)
            .initializeDatasetOnce(_marker('device-a'));
        final folderA = (await storeA.read()).folderId!;
        expect(folderA, isNot(folderB));

        // Three relaunches each, with the index now fully caught up. Neither
        // device ever lists by name again, so neither ever notices.
        for (var i = 0; i < 3; i++) {
          expect(
            (await _backend(transport, store: storeA).readDatasetInitMarker())
                ?.createdByDeviceId,
            'device-a',
          );
          expect(
            (await _backend(transport, store: storeB).readDatasetInitMarker())
                ?.createdByDeviceId,
            'device-b',
          );
        }
        expect((await storeA.read()).folderId, folderA);
        expect((await storeB.read()).folderId, folderB);
      },
    );

    test(
      'a folder renamed in Drive updates the name this device shows, rather '
      'than displaying the old one forever',
      () async {
        final transport = FakeDriveHttpTransport();
        final store = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: store)
            .initializeDatasetOnce(_marker('device-a'));
        final folderId = transport.debugFolderIds.single;
        expect((await store.read()).folderName, defaultDriveRootFolderName);

        transport.debugRenameFile(folderId, 'Bruce の Notes');
        await _backend(transport, store: store).readDatasetInitMarker();

        expect(
          (await store.read()).folderName,
          'Bruce の Notes',
          reason:
              'DriveFolderIdentity.folderName documents itself as the name '
              'the folder "was last seen under"',
        );
        expect((await store.read()).folderId, folderId);
      },
    );

    test(
      'adoptRootFolder reports WHICH dataset the pasted folder holds, before '
      'anything is recorded',
      () async {
        // A valid-but-wrong paste — the id of some other Synapse sync folder
        // — passes every check `adoptRootFolder` made (it resolves, it is not
        // trashed, it carries the datasetRoot tag) and was committed to
        // silently. The marker is the only thing that says which dataset it
        // actually is.
        final transport = FakeDriveHttpTransport();
        final storeA = InMemoryDriveFolderIdentityStore();
        await _backend(transport, store: storeA)
            .initializeDatasetOnce(_marker('device-a'));
        final folderId = transport.debugFolderIds.single;

        final storeB = InMemoryDriveFolderIdentityStore();
        final preview = await _backend(
          transport,
          store: storeB,
        ).inspectRootFolder(folderId);

        expect(preview.identity.folderId, folderId);
        expect(preview.identity.folderName, defaultDriveRootFolderName);
        expect(preview.marker?.createdByDeviceId, 'device-a');
        expect(
          (await storeB.read()).folderId,
          isNull,
          reason: 'inspecting must not record anything',
        );
      },
    );

    test(
      'inspectRootFolder answers "no dataset in there yet" for a valid, '
      'tagged, but empty folder',
      () async {
        final transport = FakeDriveHttpTransport();
        final empty = transport.debugCreateFolder('Someone else\'s folder');
        final store = InMemoryDriveFolderIdentityStore();

        final preview = await _backend(
          transport,
          store: store,
        ).inspectRootFolder(empty);
        expect(preview.identity.folderId, empty);
        expect(preview.marker, isNull);
      },
    );
  });

  // =========================================================================
  group('M2.11 review round 2 — CloudSyncService', () {
    // =======================================================================

    (CloudSyncService, DatabaseService) makeService(
      FakeDriveHttpTransport transport,
    ) {
      final db = DatabaseService.createNew();
      final service = CloudSyncService(
        db,
        authService: GoogleDriveAuthService(),
        backendFactory: () =>
            _backend(transport, store: SyncStateDriveFolderIdentityStore(db)),
      );
      return (service, db);
    }

    test(
      'F2: an ambiguous name on a device that predates M2.11 reaches the user '
      'as an actionable outcome, not a raw exception string',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        // Set up and sync the ordinary way, then reconstruct genuine
        // pre-M2.11 local state: `sync_state` holds the bootstrap status, the
        // device id, the last outcome, the seed marker and the health
        // snapshot, and neither `drive_root_folder_*` row — because the build
        // that wrote it had no such concept.
        await service.setUpDataset(folderName: defaultDriveRootFolderName);
        await service.syncNow();
        final raw = await db.database;
        await raw.delete(
          'sync_state',
          where: 'key IN (?, ?)',
          whereArgs: [driveRootFolderIdStateKey, driveRootFolderNameStateKey],
        );
        // A duplicate left behind by a Drive cleanup / an earlier run.
        transport.debugCreateFolder(defaultDriveRootFolderName);
        service.invalidateBackend();

        await expectLater(
          service.syncNow(),
          throwsA(isA<SyncAmbiguousRootFolderException>()),
        );

        final status = await service.status();
        expect(
          status.lastSync?.detail,
          isNot(contains('SyncAmbiguousRootFolderException')),
          reason:
              'a typed exception exists so nothing has to persist and '
              're-render its toString()',
        );
        expect(
          status.folderAmbiguity,
          isNotNull,
          reason: 'the count and the name are what let a user act on it',
        );
        expect(status.folderAmbiguity!.candidateCount, 2);
        expect(status.folderAmbiguity!.folderName, defaultDriveRootFolderName);
        expect(
          status.health.issues.map((i) => i.kind),
          contains(SyncHealthIssueKind.rootFolderAmbiguous),
          reason:
              'it survives leaving the screen only if it is on the health '
              'spine, exactly like M2.13\'s two states',
        );
      },
    );

    test(
      'F2 control: the ambiguity clears itself once the duplicate is gone — '
      'it must not become a state only a reset can leave',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        await service.setUpDataset(folderName: defaultDriveRootFolderName);
        await service.syncNow();
        final realFolder = (await service.status()).folder.folderId!;
        final raw = await db.database;
        await raw.delete(
          'sync_state',
          where: 'key IN (?, ?)',
          whereArgs: [driveRootFolderIdStateKey, driveRootFolderNameStateKey],
        );
        final duplicate = transport.debugCreateFolder(
          defaultDriveRootFolderName,
        );
        service.invalidateBackend();
        await expectLater(
          service.syncNow(),
          throwsA(isA<SyncAmbiguousRootFolderException>()),
        );

        // The remedy the message names: remove the duplicate in Drive.
        transport.debugDeleteFile(duplicate);
        service.invalidateBackend();
        await service.syncNow();

        final status = await service.status();
        expect(status.folderAmbiguity, isNull);
        expect(
          status.health.issues.map((i) => i.kind),
          isNot(contains(SyncHealthIssueKind.rootFolderAmbiguous)),
        );
        expect(status.folder.folderId, realFolder);
        expect(status.bootstrapStatus, DatasetBootstrapStatus.ready);
      },
    );

    test(
      'a SyncRootFolderMissingException that escapes mid-round is reported as '
      'the missing dataset it is, not quoted at the user',
      () async {
        // The one path that reaches the throw: a device whose bootstrap never
        // finished (`bootstrapping`) is not re-checked by
        // `verifyDatasetStillExists` at all — correctly, since there is
        // nothing yet to verify — so the round runs, and the first call that
        // needs the root folder finds the recorded id definitively gone.
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        await service.setUpDataset(folderName: 'Notes');
        final folderId = (await service.status()).folder.folderId!;
        final raw = await db.database;
        await raw.insert('sync_state', {
          'key': datasetBootstrapStatusKey,
          'value': 'bootstrapping',
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        transport.debugDeleteFile(folderId);
        service.invalidateBackend();

        await expectLater(
          service.syncNow(),
          throwsA(isA<DatasetMissingException>()),
        );

        final status = await service.status();
        expect(
          status.lastSync?.detail,
          syncFailureDatasetMissing,
          reason: 'a stable sentinel the screen localizes, not a toString()',
        );
        expect(
          status.lastSync?.detail,
          isNot(contains('SyncRootFolderMissingException')),
        );
      },
    );

    test(
      'F1: leaving the folder-ID field empty clears a recorded id, so a '
      'device welded to the wrong folder can go back to resolving by name',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        // The wrong-but-valid paste: a real, tagged Synapse root folder that
        // simply is not this user's dataset.
        final wrong = transport.debugCreateFolder('Someone else\'s folder');
        await service.setUpDataset(folderId: wrong);
        expect((await service.status()).folder.folderId, wrong);

        await service.resetSyncState();
        await service.setUpDataset(
          folderName: 'Family Notes',
          forgetRecordedFolderId: true,
        );

        final status = await service.status();
        expect(
          status.folder.folderId,
          isNot(wrong),
          reason: 'copyWith could not express "clear the id"; this path must',
        );
        expect(status.folder.folderName, 'Family Notes');
        expect(transport.debugNameOf(status.folder.folderId!), 'Family Notes');
      },
    );

    test(
      'F1 control: re-submitting the id this device already holds does NOT '
      're-validate it, so a reset after the folder was deleted still rebuilds',
      () async {
        final transport = FakeDriveHttpTransport();
        final (service, db) = makeService(transport);
        addTearDown(db.close);

        await service.setUpDataset(folderName: 'Notes');
        await service.syncNow();
        final folderId = (await service.status()).folder.folderId!;

        transport.debugDeleteFile(folderId);
        service.invalidateBackend();
        await expectLater(
          service.syncNow(),
          throwsA(isA<DatasetMissingException>()),
        );
        await service.resetSyncState();

        // Exactly what the re-openable setup dialog now submits: the id it
        // was pre-filled with. Validating it here would turn the one flow
        // that has to work into a dead end.
        final marker = await service.setUpDataset(
          folderName: 'Notes',
          folderId: folderId,
        );
        expect(await service.datasetWasCreatedByThisDevice(marker), isTrue);
        final status = await service.status();
        expect(status.bootstrapStatus, DatasetBootstrapStatus.ready);
        expect(status.folder.folderId, isNot(folderId));
        expect(transport.debugNameOf(status.folder.folderId!), 'Notes');
      },
    );
  });
}
