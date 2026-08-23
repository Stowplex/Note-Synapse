// M2.13 — the recovery path out of a vanished/diverged sync dataset.
//
// **These tests are written against the reported device state, not against
// the implementation.** A user deleted their `Note Synapse Sync` folder in
// Drive; afterwards the settings screen still said "Ready — This device has
// joined the sync dataset" and every sync died with
// `PushParentMismatchException(authorId: seed:…, deviceSeq: 150,
// actualTipHash: , publishedBeforeHalt: 0)`. So the setup here is literally
// that: sync normally, then replace the backend with an empty one (a truer
// model of "the folder is gone" than reaching into the mock's internals,
// since it takes the dataset marker AND every log away at once).
//
// The load-bearing test is `reset -> set up -> sync` followed by a PEER
// device reconstructing the note from the backend. Asserting that the reset
// deleted rows would prove nothing: the failure mode this milestone had to
// avoid is a reset that clears the identity and the tips but leaves
// `sync_field_state`/`sync_set_state`/`sync_materialize_queue` standing, in
// which case `SeedScanner._isPristine` reads every field as "already has
// history", the device seeds nothing, pushes nothing, and syncs nothing —
// silently, and worse than the dead end it replaced. Only an end-to-end
// assertion that the user's data actually arrives somewhere else can tell
// the two apart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/cloud_sync_service.dart';
import 'package:note_synapse/services/sync/dataset_bootstrap.dart';
import 'package:note_synapse/services/sync/dataset_reset.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/google_drive_auth_service.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/push_phase.dart';
import 'package:note_synapse/services/sync/seed_scanner.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_health.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/mock_sync_backend.dart';

/// One device, with a swappable backend — `CloudSyncService` caches the
/// backend its factory returns, so "the Drive folder was deleted" is
/// modelled as a new [MockSyncBackend] plus `invalidateBackend()`, which is
/// exactly what the production code does after a disconnect.
class _Device {
  _Device({MockSyncBackend? sharedBackend, _LaggyListingBackend? lens})
      : databaseService = DatabaseService.createNew() {
    if (sharedBackend != null) backend = sharedBackend;
    service = CloudSyncService(
      databaseService,
      authService: GoogleDriveAuthService(),
      backendFactory: () => lens ?? backend,
    );
  }

  final DatabaseService databaseService;
  late final CloudSyncService service;
  MockSyncBackend backend = MockSyncBackend();

  Future<Database> get db => databaseService.database;

  void replaceBackendWithEmptyOne() {
    backend = MockSyncBackend();
    service.invalidateBackend();
  }

  Future<String?> stateValue(String key) async {
    final rows = await (await db).query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<int> rowCount(String table) async {
    final rows = await (await db).rawQuery(
      'SELECT COUNT(*) AS c FROM $table',
    );
    return (rows.first['c'] as int?) ?? -1;
  }

  Future<void> close() => databaseService.close();
}

/// A [PushPhase] that models the one outcome no real backend can be talked
/// into producing on demand: a push that durably lands [published]
/// operations and THEN meets `ParentMismatch`. `MockSyncBackend` can only
/// make the very first append mismatch (`publishedBeforeHalt: 0`), which is
/// exactly the case that hid F4.
class _HaltAfterPublishingPushPhase extends PushPhase {
  _HaltAfterPublishingPushPhase(super.databaseService, this.published);

  final int published;

  @override
  Future<PushResult> push({
    required SyncBackend backend,
    required String authorId,
    void Function(PushProgress)? onProgress,
  }) async {
    throw PushParentMismatchException(
      authorId: authorId,
      deviceSeq: published + 1,
      actualTipHash: '',
      publishedBeforeHalt: published,
    );
  }
}

/// A `SyncBackend` that delegates everything to [inner] but can, for as long
/// as a test leaves it armed, model two things that are **not faults**: an
/// eventually-consistent listing that has not caught up
/// ([hiddenLogIds] — `files.list` lag, § 8.2 item 6's ordinary case), and a
/// log whose page comes back empty even though it has commits
/// ([emptyReadLogIds] — a page that shrinks to zero, which `PullPhase`
/// exits via `if (page.commits.isEmpty) break` with `gapped = false`).
///
/// Both are deliberately modelled here rather than through `sync_faults.dart`:
/// the point of the review finding they exist for is that **neither is a
/// fault**. `PullPhase.pull` returns normally, reports no gap, and reports
/// no error — so nothing downstream can tell "there was nothing to observe"
/// from "everything was observed".
class _LaggyListingBackend implements SyncBackend {
  _LaggyListingBackend(this.inner);

  final MockSyncBackend inner;

  /// Log ids `listDeviceLogIds` pretends not to know about yet.
  Set<String> hiddenLogIds = {};

  /// Log ids whose `readCommits` returns an empty, gap-free page.
  Set<String> emptyReadLogIds = {};

  @override
  SyncBackendCapabilities get capabilities => inner.capabilities;

  @override
  Future<List<String>> listDeviceLogIds() async =>
      (await inner.listDeviceLogIds())
          .where((id) => !hiddenLogIds.contains(id))
          .toList();

  @override
  Future<CommitPage> readCommits({
    required String deviceLogId,
    required int afterSeq,
    int? limit,
  }) async {
    if (emptyReadLogIds.contains(deviceLogId)) {
      return const CommitPage(commits: [], hasGap: false);
    }
    return inner.readCommits(
      deviceLogId: deviceLogId,
      afterSeq: afterSeq,
      limit: limit,
    );
  }

  @override
  Future<AppendCommitOutcome> appendCommit({
    required String deviceLogId,
    required int deviceSeq,
    required String publishIntentId,
    required String? parentCommitHash,
    required Uint8List commitBytes,
  }) =>
      inner.appendCommit(
        deviceLogId: deviceLogId,
        deviceSeq: deviceSeq,
        publishIntentId: publishIntentId,
        parentCommitHash: parentCommitHash,
        commitBytes: commitBytes,
      );

  @override
  Future<void> initializeDatasetOnce(DatasetInitMarker marker) =>
      inner.initializeDatasetOnce(marker);

  @override
  Future<DatasetInitMarker?> readDatasetInitMarker() =>
      inner.readDatasetInitMarker();

  @override
  Future<bool> blobExists(String contentHash) => inner.blobExists(contentHash);

  @override
  Future<void> uploadBlob({
    required String contentHash,
    required Stream<List<int>> data,
    required int length,
  }) =>
      inner.uploadBlob(contentHash: contentHash, data: data, length: length);

  @override
  Future<Stream<List<int>>> downloadBlob(String contentHash) =>
      inner.downloadBlob(contentHash);

  @override
  Future<DeleteOutcome> deleteConditionally({
    required BackendRef ref,
    required DeletePrecondition precondition,
  }) =>
      inner.deleteConditionally(ref: ref, precondition: precondition);

  @override
  Future<void> publishSnapshot(String snapshotHash, Uint8List snapshotBytes) =>
      inner.publishSnapshot(snapshotHash, snapshotBytes);

  @override
  Future<SnapshotRef?> latestSnapshotRef() => inner.latestSnapshotRef();

  @override
  Future<Uint8List> readSnapshot(String snapshotHash) =>
      inner.readSnapshot(snapshotHash);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// A small but genuinely multi-table library: an entity with several
  /// fields, a second entity table, and an OR-Set membership between them.
  Future<void> seedUserContent(Database db) async {
    await db.insert('notes', {
      'id': 'n1',
      'title': 'Trip planning',
      'content': 'ferry times, packing list',
      'type': 'note',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
    await db.insert('tags', {
      'id': 't1',
      'name': 'travel',
      'color': 'blue',
      'createdAt': 1000,
      'usageCount': 0,
      '__deleted__': 0,
      'redirectTarget': null,
    });
    await db.insert('note_tags', {'noteId': 'n1', 'tagId': 't1'});
    await db.insert('conversations', {
      'id': 'c1',
      'title': 'About the trip',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
  }

  // =====================================================================
  // 1. The reported state: local tip at N, remote empty.
  // =====================================================================

  test(
    'a device whose dataset was deleted reports it instead of throwing a raw '
    'ParentMismatch, and stops claiming to be Ready',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);

      await device.service.setUpDataset();
      final first = await device.service.syncNow();
      expect(
        first.totalPublished,
        greaterThan(0),
        reason: 'the pre-condition for this test is a device that HAS synced',
      );

      // The folder is deleted out from under it.
      device.replaceBackendWithEmptyOne();

      // Detected up front, as its own type — not as an exception string
      // quoting a deviceSeq the user cannot act on.
      await expectLater(
        device.service.syncNow(),
        throwsA(isA<DatasetMissingException>()),
      );

      final status = await device.service.status();
      expect(
        status.bootstrapStatus,
        DatasetBootstrapStatus.needsReset,
        reason: 'the card must stop saying "Ready — this device has joined '
            'the sync dataset" about a dataset that is gone',
      );
      expect(status.canSync, isFalse);
      expect(status.needsReset, isTrue);
      expect(status.canReset, isTrue);
      expect(status.needsDatasetSetup, isFalse);

      // Folded into the health surface, so the outcome reads as degraded
      // with a named cause rather than as a bare exception.
      expect(
        status.health.issues.map((i) => i.kind),
        contains(SyncHealthIssueKind.datasetMissing),
      );
      expect(status.lastSync!.succeeded, isFalse);
      expect(status.lastSync!.degraded, isTrue);
      expect(
        status.lastSync!.detail,
        syncFailureDatasetMissing,
        reason: 'a stable sentinel, so the stored outcome re-renders in '
            'whatever language is active when it is displayed',
      );
    },
  );

  test(
    'the status stays needsReset across restarts, and setting the dataset up '
    'again is refused rather than quietly creating a second one',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();
      await device.service.syncNow();
      device.replaceBackendWithEmptyOne();
      await expectLater(
        device.service.syncNow(),
        throwsA(isA<DatasetMissingException>()),
      );

      // Persisted, so a restart does not "fix" the screen while leaving the
      // device just as stuck.
      expect(
        await device.stateValue(datasetBootstrapStatusKey),
        needsResetStatusValue,
      );

      // Re-bootstrapping would create a brand-new dataset while every local
      // tip still pointed into the deleted one — the exact shape of the
      // reported dead end, one layer down.
      await expectLater(
        device.service.setUpDataset(),
        throwsA(isA<DatasetMissingException>()),
      );
    },
  );

  // =====================================================================
  // 2. Reset preserves user data.
  // =====================================================================

  test('reset clears sync control-plane state and not one row of user content',
      () async {
    final device = _Device();
    addTearDown(device.close);
    final db = await device.db;
    await seedUserContent(db);
    await device.service.setUpDataset();
    await device.service.syncNow();

    // A peer acknowledgment recorded by some earlier round: a true fact
    // about what a REMOTE device has seen, which a local reset has no
    // business rewriting.
    await db.insert('sync_ack_frontier', {
      'deviceId': 'peer-device',
      'authorId': 'peer-device',
      'ackedSeq': 7,
      'updatedAt': 1,
    });

    const userTables = [
      'notes',
      'tags',
      'note_tags',
      'conversations',
    ];
    final before = {
      for (final table in userTables) table: await device.rowCount(table),
    };
    final noteBefore = (await db.query('notes', where: 'id = ?', whereArgs: ['n1'])).single;
    final hlcWallBefore = await device.stateValue(hlcWallStateKey);
    final deviceIdBefore = await device.stateValue('device_id');
    expect(hlcWallBefore, isNotNull);
    expect(deviceIdBefore, isNotNull);

    await device.service.resetSyncState();

    for (final table in userTables) {
      expect(
        await device.rowCount(table),
        before[table],
        reason: '$table must be untouched by a sync reset',
      );
    }
    expect(
      (await db.query('notes', where: 'id = ?', whereArgs: ['n1'])).single,
      noteBefore,
      reason: 'not merely the same COUNT — the same row, column for column',
    );

    // The control plane, on the other hand, is gone.
    for (final table
        in DatabaseService.syncEntityScopedControlPlaneTablesToWipe) {
      expect(
        await device.rowCount(table),
        0,
        reason: '$table is entity-scoped derived state and must be cleared',
      );
    }
    expect(await device.rowCount('sync_publish_intent'), 0);
    expect(await device.stateValue(datasetBootstrapStatusKey), isNull);
    expect(await device.stateValue(seedScanCompletedAtKey), isNull);
    expect(await device.stateValue('device_id'), isNull);

    // The two deliberate exceptions.
    expect(
      await device.stateValue(hlcWallStateKey),
      hlcWallBefore,
      reason: 'the HLC is per physical device and must never go backwards — '
          'a post-reset operation carrying an earlier HLC than one this same '
          'device already published would invert every tie-break on it',
    );
    expect(
      await device.rowCount('sync_ack_frontier'),
      1,
      reason: "what a remote peer has acknowledged is that peer's fact, not "
          'local bookkeeping this device may rewrite',
    );

    // The retired identity is kept but demoted, so exactly one row claims to
    // be the current device once a fresh id is minted.
    final retired = (await db.query(
      'sync_device_labels',
      where: 'deviceId = ?',
      whereArgs: [deviceIdBefore],
    )).single;
    expect(retired['isCurrentDevice'], 0);
    expect(retired['retiredAt'], isNotNull);

    final status = await device.service.status();
    expect(status.bootstrapStatus, DatasetBootstrapStatus.none);
    expect(status.needsReset, isFalse);
    expect(status.health.isDegraded, isFalse);
  });

  // =====================================================================
  // 3. The load-bearing one: reset -> re-bootstrap -> re-seed -> push, and
  //    the user's notes genuinely arrive on another device.
  // =====================================================================

  test(
    'after a reset the seed scan actually re-runs and the whole library '
    'reaches the backend — verified by a fresh peer rebuilding it',
    () async {
      final device = _Device();
      addTearDown(device.close);
      final db = await device.db;
      await seedUserContent(db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      final deviceIdBefore = await device.stateValue('device_id');

      // The dataset vanishes, exactly as reported.
      device.replaceBackendWithEmptyOne();
      await expectLater(
        device.service.syncNow(),
        throwsA(isA<DatasetMissingException>()),
      );

      // --- the recovery: two taps, reset then set up -------------------
      await device.service.resetSyncState();
      await device.service.setUpDataset();
      final recovered = await device.service.syncNow();

      expect(
        recovered.seed.operationsSeeded,
        greaterThan(0),
        reason: 'THE critical point: the seed scan must genuinely re-run. If '
            'sync_field_state/sync_set_state/sync_materialize_queue survived '
            'the reset, _isPristine would read every field as already having '
            'history and this would be 0 — a device that seeds nothing and '
            'syncs nothing, silently.',
      );
      expect(recovered.totalPublished, greaterThan(0));
      expect(recovered.divergedAuthorIds, isEmpty);

      // (c): a fresh device identity, so the new logs are empty by
      // construction and no peer holds a stale cursor into them.
      final deviceIdAfter = await device.stateValue('device_id');
      expect(deviceIdAfter, isNotNull);
      expect(
        deviceIdAfter,
        isNot(deviceIdBefore),
        reason: 'option (c): continuing the old identity would restart the '
            "commit chain at 1 under a log id peers already have a cursor "
            'and a pull_tip for',
      );
      final logIds = await device.backend.listDeviceLogIds();
      expect(
        logIds.where((id) => id.contains(deviceIdBefore!)),
        isEmpty,
        reason: 'nothing is ever written under the retired identity again',
      );

      // --- the actual proof: a peer rebuilds the library ---------------
      final peerDb = DatabaseService.createNew();
      addTearDown(peerDb.close);
      final peerSession = SyncSession(peerDb);
      for (var i = 0; i < 3; i++) {
        await peerSession.run(device.backend);
      }

      final peer = await peerDb.database;
      final peerNote = (await peer.query(
        'notes',
        where: 'id = ?',
        whereArgs: ['n1'],
      )).single;
      expect(peerNote['title'], 'Trip planning');
      expect(peerNote['content'], 'ferry times, packing list');

      final peerTag = (await peer.query(
        'tags',
        where: 'id = ?',
        whereArgs: ['t1'],
      )).single;
      expect(peerTag['name'], 'travel');
      expect(peerTag['__deleted__'], 0);

      expect(
        await peer.query('note_tags'),
        hasLength(1),
        reason: 'the OR-Set membership re-seeded too — sync_set_state is one '
            'of the three precondition tables the reset has to clear',
      );
      final peerConversation = (await peer.query(
        'conversations',
        where: 'id = ?',
        whereArgs: ['c1'],
      )).single;
      expect(peerConversation['title'], 'About the trip');

      // M2.13, review round 3 (finding F-A). This test already exercised the
      // exact flow the defect lived on and never looked at a timestamp.
      //
      // `materializer.dart`'s `_materializeExists` writes the `__exists__`
      // operation's `hlc.wallMs` straight into the entity's creation-timestamp
      // column, and `createdAt` is excluded from every scope's
      // `syncScopeColumns`, so no later operation ever corrects it. When the
      // post-reset seed stamped `__exists__` recessively (`Hlc.zero`), every
      // note, tag, filter and conversation materialized here at 1970-01-01 —
      // permanently, on the one flow this milestone exists to serve, with
      // `createdAt` being the ORDER BY at ~13 query sites.
      for (final row in [peerNote, peerTag, peerConversation]) {
        expect(
          row['createdAt'],
          greaterThan(0),
          reason: 'a recessive __exists__ writes epoch 0 into createdAt and '
              'nothing ever corrects it; only `field` seeds may be recessive',
        );
      }
    },
  );

  test('a sync run after the post-reset one is an ordinary no-op, not a '
      'perpetual re-seed', () async {
    final device = _Device();
    addTearDown(device.close);
    await seedUserContent(await device.db);
    await device.service.setUpDataset();
    await device.service.syncNow();
    device.replaceBackendWithEmptyOne();
    await expectLater(
      device.service.syncNow(),
      throwsA(isA<DatasetMissingException>()),
    );
    await device.service.resetSyncState();
    await device.service.setUpDataset();
    await device.service.syncNow();

    final quiet = await device.service.syncNow();
    expect(quiet.seed.operationsSeeded, 0);
    expect(quiet.seed.skippedAlreadyComplete, isTrue);
    expect(quiet.totalPublished, 0);
    expect(quiet.drain.touchesProcessed, 0);

    final status = await device.service.status();
    expect(status.bootstrapStatus, DatasetBootstrapStatus.ready);
    expect(status.needsReset, isFalse);
    expect(status.health.isDegraded, isFalse);
    expect(status.lastSync!.succeeded, isTrue);
  });

  // =====================================================================
  // 4. ParentMismatch is recoverable, not terminal.
  // =====================================================================

  test(
    'a diverged device log is reported through the health surface and does '
    'not kill the round',
    () async {
      final device = _Device();
      addTearDown(device.close);
      final db = await device.db;
      await seedUserContent(db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      // The dataset marker survives; this device's own logs do not. That is
      // the divergence case rather than the missing-dataset case — a
      // partially-deleted folder, or an identity reused after a reinstall.
      for (final logId in await device.backend.listDeviceLogIds()) {
        device.backend.debugDeleteDeviceLogExternally(logId);
      }

      // Something new to push, so Phase A actually attempts an append.
      await db.update(
        'notes',
        {'title': 'Trip planning (revised)'},
        where: 'id = ?',
        whereArgs: ['n1'],
      );

      final result = await device.service.syncNow();
      expect(
        result.divergedAuthorIds,
        isNotEmpty,
        reason: 'halt-not-retarget still halts — it just reports now',
      );

      final status = await device.service.status();
      expect(status.lastSync!.succeeded, isTrue);
      expect(
        status.lastSync!.degraded,
        isTrue,
        reason: 'a round that could not upload anything is not a clean success',
      );
      final issue = status.health.issues.singleWhere(
        (i) => i.kind == SyncHealthIssueKind.deviceLogDiverged,
      );
      expect(issue.subjects, isNotEmpty);
      expect(status.needsReset, isTrue);
      expect(status.canReset, isTrue);

      // Durable: the condition persists until something is done about it,
      // rather than being visible for exactly the one round that saw it.
      expect(await device.stateValue(divergedAuthorLogsStateKey), isNotNull);

      // And the remedy works — the same two taps, with the dataset intact.
      await device.service.resetSyncState();
      await device.service.setUpDataset();
      final recovered = await device.service.syncNow();
      expect(recovered.divergedAuthorIds, isEmpty);
      expect(recovered.totalPublished, greaterThan(0));
      expect(
        await device.stateValue(divergedAuthorLogsStateKey),
        isNull,
        reason: 'a successful push clears its own divergence; nothing has to '
            'remember to',
      );
      expect((await device.service.status()).health.isDegraded, isFalse);
    },
  );

  // =====================================================================
  // 6. F1 — a reset must not revert a PEER's newer content.
  // =====================================================================
  //
  // The review's construction, verbatim, plus its control. Two devices, one
  // backend, one field. B holds the newer value. A does something to itself.
  // The control (A merely syncs) pins the pre-existing, correct behavior, so
  // the reset case cannot pass vacuously — if the control ever stopped
  // showing "B NEWER title" the reset assertion would be measuring nothing.

  Future<void> insertSharedNote(Database db) async {
    await db.insert('notes', {
      'id': 'n1',
      'title': 'original title',
      'content': 'body',
      'type': 'note',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
  }

  Future<String?> noteTitle(_Device d) async {
    final rows = await (await d.db).query(
      'notes',
      columns: const ['title'],
      where: 'id = ?',
      whereArgs: ['n1'],
    );
    return rows.isEmpty ? null : rows.first['title'] as String?;
  }

  /// A publishes n1, B joins and pulls it, B edits the title and publishes.
  /// Returns `(A, B)` with B's newer value live on the backend and A still
  /// holding the original.
  Future<(_Device, _Device)> twoDevicesWithNewerPeerValue(
    MockSyncBackend backend,
  ) async {
    final a = _Device(sharedBackend: backend);
    final b = _Device(sharedBackend: backend);
    await insertSharedNote(await a.db);
    await a.service.setUpDataset();
    await a.service.syncNow();

    await b.service.setUpDataset();
    for (var i = 0; i < 2; i++) {
      await b.service.syncNow();
    }
    expect(
      await noteTitle(b),
      'original title',
      reason: 'precondition: B has materialized A\'s note',
    );

    await (await b.db).update(
      'notes',
      {'title': 'B NEWER title'},
      where: 'id = ?',
      whereArgs: ['n1'],
    );
    await b.service.syncNow();
    return (a, b);
  }

  test(
    'CONTROL: without a reset, A picks up B\'s newer title and B keeps it',
    () async {
      final backend = MockSyncBackend();
      final (a, b) = await twoDevicesWithNewerPeerValue(backend);
      addTearDown(a.close);
      addTearDown(b.close);

      await a.service.syncNow();
      await b.service.syncNow();

      expect(await noteTitle(a), 'B NEWER title');
      expect(await noteTitle(b), 'B NEWER title');
    },
  );

  test(
    'a reset on A must not revert B\'s newer title — on either device',
    () async {
      final backend = MockSyncBackend();
      final (a, b) = await twoDevicesWithNewerPeerValue(backend);
      addTearDown(a.close);
      addTearDown(b.close);

      await a.service.resetSyncState();
      await a.service.setUpDataset();
      await a.service.syncNow();
      await b.service.syncNow();
      await a.service.syncNow();

      expect(
        await noteTitle(a),
        'B NEWER title',
        reason: 'a reset re-seeds this device\'s own rows; if the seed runs '
            'before the pull it mints a fresh-HLC GENESIS operation for a '
            'field the backend already holds a newer value for, and the '
            'fresh HLC wins the (hlc, authorId, authorSeq) tie-break',
      );
      expect(
        await noteTitle(b),
        'B NEWER title',
        reason: 'and the revert propagates: B pulls A\'s re-seed and loses '
            'its own newer value, dataset-wide',
      );
    },
  );

  test(
    'an unpublished local edit survives the post-reset pull instead of being '
    'silently overwritten by the peer value it competes with',
    () async {
      final backend = MockSyncBackend();
      final (a, b) = await twoDevicesWithNewerPeerValue(backend);
      addTearDown(a.close);
      addTearDown(b.close);

      // A edits the same field and never gets to publish it — the shape the
      // `deviceLogDiverged` state produces by construction (a device that
      // cannot push accumulates exactly this).
      await (await a.db).update(
        'notes',
        {'title': 'A UNPUBLISHED title'},
        where: 'id = ?',
        whereArgs: ['n1'],
      );

      final reset = await a.service.resetSyncState();
      expect(
        reset.localWorkRetouched,
        greaterThan(0),
        reason: 'the reset must carry the identity of the unfinished edit '
            'across the wipe; otherwise it comes back only as a RECESSIVE '
            'seed, which loses to the peer value it should beat',
      );

      await a.service.setUpDataset();
      await a.service.syncNow();

      expect(
        await noteTitle(a),
        'A UNPUBLISHED title',
        reason: 'the re-touched field is drained into an ordinary operation '
            'with a real HLC in Phase 0, so it competes on the ordinary '
            '(hlc, authorId, authorSeq) path rather than deferring',
      );

      // And the value it beat is recorded rather than dropped — requirement
      // 2's "losing edits are never silently dropped".
      final copies = await (await a.db).query(
        'sync_conflict_copies',
        where: 'subjectTable = ? AND subjectId = ? AND fieldName = ?',
        whereArgs: ['notes', 'n1', 'title'],
      );
      expect(
        copies,
        isNotEmpty,
        reason: 'the peer value A won against must survive as a conflict copy',
      );

      await b.service.syncNow();
      expect(await noteTitle(b), 'A UNPUBLISHED title');
    },
  );

  // =====================================================================
  // 6b. F1, review round 2 — the ORDERING fix was not sufficient, and
  //     these are the three constructions that show it.
  // =====================================================================
  //
  // The round-1 fix inverted the phase order for ONE round, via a
  // `sync_state` flag consumed by `SyncSession.run`. The generalizable
  // reason it cannot work: **a device can never know it has observed
  // everything the backend holds**, so "pull first" does not imply "has
  // now seen the peer value". Three independent ways the inverted round
  // observes nothing and the seed then runs over still-pristine fields:
  //
  //   (a) `listDeviceLogIds` has not caught up (ordinary `files.list` lag).
  //   (b) a page comes back empty — `PullPhase` exits via
  //       `if (page.commits.isEmpty) break` with `gapped = false`.
  //   (c) the seed legitimately spans rounds (`SeedScanner` only writes its
  //       completion marker when nothing was deferred), so rounds 2..n run
  //       seed-before-pull with the flag long since cleared.
  //
  // All three are set up against a DIVERGED A — A's own logs deleted from
  // the backend, the dataset marker intact — which is (i) one of the two
  // states a reset is actually offered in, and (ii) the construction that
  // keeps the assertion about the seed's HLC alone: with A's retired
  // `seed:<oldUuid>` log gone, no second operation with the identical
  // GENESIS `contentKey` exists, so nothing here turns on which of two
  // aliases happens to be canonical.

  /// A publishes n1; B joins, pulls, edits the title and publishes; then A's
  /// OWN logs are deleted from the backend. Returns `(A, B)` with the
  /// backend holding B's newer value and nothing of A's.
  Future<(_Device, _Device)> divergedAWithNewerPeerValue(
    MockSyncBackend backend, {
    _LaggyListingBackend? lens,
  }) async {
    final a = _Device(sharedBackend: backend, lens: lens);
    final b = _Device(sharedBackend: backend);
    await insertSharedNote(await a.db);
    await a.service.setUpDataset();
    await a.service.syncNow();

    await b.service.setUpDataset();
    for (var i = 0; i < 2; i++) {
      await b.service.syncNow();
    }
    expect(await noteTitle(b), 'original title');

    await (await b.db).update(
      'notes',
      {'title': 'B NEWER title'},
      where: 'id = ?',
      whereArgs: ['n1'],
    );
    await b.service.syncNow();

    final aId = (await a.stateValue('device_id'))!;
    for (final logId in await backend.listDeviceLogIds()) {
      if (logId.contains(aId)) backend.debugDeleteDeviceLogExternally(logId);
    }
    return (a, b);
  }

  /// The recovery both halves of each pair perform, identically.
  Future<void> resetAndRecover(_Device a) async {
    await a.service.resetSyncState();
    await a.service.setUpDataset();
  }

  test(
    'CONTROL: with the lens present but unarmed, a diverged A picks up B\'s '
    'newer title after a reset',
    () async {
      final backend = MockSyncBackend();
      final lens = _LaggyListingBackend(backend);
      final (a, b) = await divergedAWithNewerPeerValue(backend, lens: lens);
      addTearDown(a.close);
      addTearDown(b.close);

      await resetAndRecover(a);
      await a.service.syncNow();
      await a.service.syncNow();
      await b.service.syncNow();

      expect(await noteTitle(a), 'B NEWER title');
      expect(await noteTitle(b), 'B NEWER title');
    },
  );

  test(
    'F1(a): a round in which listDeviceLogIds has not yet listed the peer\'s '
    'log must not let the post-reset seed republish this device\'s stale value',
    () async {
      final backend = MockSyncBackend();
      final lens = _LaggyListingBackend(backend);
      final (a, b) = await divergedAWithNewerPeerValue(backend, lens: lens);
      addTearDown(a.close);
      addTearDown(b.close);

      await resetAndRecover(a);

      // The whole listing is one round behind — no fault, no error, no gap.
      lens.hiddenLogIds = (await backend.listDeviceLogIds()).toSet();
      expect(lens.hiddenLogIds, isNotEmpty);
      await a.service.syncNow();

      // ...and it catches up immediately afterwards.
      lens.hiddenLogIds = {};
      await a.service.syncNow();
      await b.service.syncNow();
      await a.service.syncNow();

      expect(
        await noteTitle(a),
        'B NEWER title',
        reason: 'the post-reset seed re-states content this device already '
            'had; it must lose to a real edit it simply had not seen yet, '
            'however many rounds later that edit arrives',
      );
      expect(
        await noteTitle(b),
        'B NEWER title',
        reason: 'and it must not propagate the revert to the peer either',
      );
    },
  );

  test(
    'F1(b): a round whose readCommits page comes back empty must not let the '
    'post-reset seed republish this device\'s stale value',
    () async {
      final backend = MockSyncBackend();
      final lens = _LaggyListingBackend(backend);
      final (a, b) = await divergedAWithNewerPeerValue(backend, lens: lens);
      addTearDown(a.close);
      addTearDown(b.close);

      await resetAndRecover(a);

      // The log is listed; its page is simply empty. `PullPhase` returns
      // normally with `gappedDeviceLogIds` empty — the case checking for a
      // gap cannot catch.
      lens.emptyReadLogIds = (await backend.listDeviceLogIds()).toSet();
      expect(lens.emptyReadLogIds, isNotEmpty);
      final blind = await a.service.syncNow();
      expect(
        blind.pull.gappedDeviceLogIds,
        isEmpty,
        reason: 'the premise of this test: nothing observed, nothing reported',
      );
      expect(blind.pull.operationsApplied, 0);

      lens.emptyReadLogIds = {};
      await a.service.syncNow();
      await b.service.syncNow();
      await a.service.syncNow();

      expect(await noteTitle(a), 'B NEWER title');
      expect(await noteTitle(b), 'B NEWER title');
    },
  );

  test(
    'F1(c): a post-reset seed that spans rounds must stay recessive in the '
    'later rounds too, not only the first',
    () async {
      final backend = MockSyncBackend();
      final a = _Device(sharedBackend: backend);
      final b = _Device(sharedBackend: backend);
      addTearDown(a.close);
      addTearDown(b.close);

      await insertSharedNote(await a.db);
      await a.service.setUpDataset();
      await a.service.syncNow();
      await b.service.setUpDataset();
      for (var i = 0; i < 2; i++) {
        await b.service.syncNow();
      }
      expect(await noteTitle(b), 'original title');

      final aId = (await a.stateValue('device_id'))!;
      for (final logId in await backend.listDeviceLogIds()) {
        if (logId.contains(aId)) backend.debugDeleteDeviceLogExternally(logId);
      }

      await resetAndRecover(a);

      // A `sync_materialize_queue` row parks `notes/n1/title` for round one.
      // `SeedScanner._isPristine` queries that table by
      // `(entityTable, entityId, fieldName)` and ignores `blockingReason`
      // entirely, so any parked row defers the field; the routine post-reset
      // one is `missing_exists` (a field operation pulled from one log before
      // its `__exists__` arrives from another). `missing_parent` is used here
      // only because no sweeper touches it, which keeps the round boundary
      // under this test's control rather than the materializer's.
      await (await a.db).insert('sync_materialize_queue', {
        'blockingReason': 'missing_parent',
        'entityTable': 'notes',
        'entityId': 'n1',
        'fieldName': 'title',
        'operationJson': null,
        'blockingKey': 'test:deferral',
        'enqueuedAt': 1,
      });

      final deferredRound = await a.service.syncNow();
      expect(
        deferredRound.seed.fieldsDeferred,
        greaterThan(0),
        reason: 'the premise: the post-reset seed genuinely spans rounds',
      );
      expect(
        deferredRound.seed.completed,
        isFalse,
        reason: 'and therefore does not write its completion marker',
      );

      // B edits while A's seed is still unfinished, and publishes.
      await (await b.db).update(
        'notes',
        {'title': 'B NEWER title'},
        where: 'id = ?',
        whereArgs: ['n1'],
      );
      await b.service.syncNow();

      // The blocker clears, and round two seeds the field — in the ordinary,
      // documented seed-before-pull order, with the round-one flag long gone.
      await (await a.db).delete(
        'sync_materialize_queue',
        where: 'blockingKey = ?',
        whereArgs: ['test:deferral'],
      );
      await a.service.syncNow();
      await a.service.syncNow();
      await b.service.syncNow();

      expect(
        await noteTitle(a),
        'B NEWER title',
        reason: 'round two seeds this field, and its seed is still a '
            're-statement of pre-reset content, not a new edit',
      );
      expect(await noteTitle(b), 'B NEWER title');
    },
  );

  test(
    'CONTROL for F1(c): with nothing deferred, the same construction still '
    'converges on the peer value',
    () async {
      final backend = MockSyncBackend();
      final a = _Device(sharedBackend: backend);
      final b = _Device(sharedBackend: backend);
      addTearDown(a.close);
      addTearDown(b.close);

      await insertSharedNote(await a.db);
      await a.service.setUpDataset();
      await a.service.syncNow();
      await b.service.setUpDataset();
      for (var i = 0; i < 2; i++) {
        await b.service.syncNow();
      }

      final aId = (await a.stateValue('device_id'))!;
      for (final logId in await backend.listDeviceLogIds()) {
        if (logId.contains(aId)) backend.debugDeleteDeviceLogExternally(logId);
      }

      await resetAndRecover(a);
      final round = await a.service.syncNow();
      expect(round.seed.fieldsDeferred, 0);
      expect(round.seed.completed, isTrue);

      await (await b.db).update(
        'notes',
        {'title': 'B NEWER title'},
        where: 'id = ?',
        whereArgs: ['n1'],
      );
      await b.service.syncNow();
      await a.service.syncNow();
      await a.service.syncNow();
      await b.service.syncNow();

      expect(await noteTitle(a), 'B NEWER title');
      expect(await noteTitle(b), 'B NEWER title');
    },
  );

  // =====================================================================
  // 6c. The recessive seed's own properties — each one the direction was
  //     asked to CONFIRM rather than assume.
  // =====================================================================

  test(
    'the recessive mode is scoped to the post-reset seed: an ordinary first '
    'seed keeps its real HLCs, and the marker clears when the seed completes',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();

      final first = await device.service.syncNow();
      expect(
        first.seed.recessive,
        isFalse,
        reason: "M2.10's shipped behavior is untouched — this change is "
            'scoped to the reset case, which has a far smaller blast radius',
      );
      expect(
        await device.stateValue(postResetRecessiveSeedStateKey),
        isNull,
      );

      await device.service.resetSyncState();
      expect(
        await device.stateValue(postResetRecessiveSeedStateKey),
        isNotNull,
        reason: 'written inside the reset transaction, after the wipe',
      );

      await device.service.setUpDataset();
      final afterReset = await device.service.syncNow();
      expect(afterReset.seed.recessive, isTrue);
      expect(afterReset.seed.completed, isTrue);
      expect(
        await device.stateValue(postResetRecessiveSeedStateKey),
        isNull,
        reason: 'cleared in the same transaction as the completion marker',
      );
    },
  );

  test(
    'a recessive seed does not move this device\'s HLC, and the operations it '
    'mints carry the minimum value',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      await device.service.resetSyncState();

      // The scanner is driven DIRECTLY here, with no drain, no pull and no
      // push around it, because that is the only way to attribute a clock
      // movement to the seed: a full round legitimately advances the clock
      // via `HybridLogicalClock.merge` on every operation the pull observes
      // (including, after a reset, this device's own retired logs).
      final wallBefore = await device.stateValue(hlcWallStateKey);
      final logicalBefore = await device.stateValue(hlcLogicalStateKey);
      final scanner = SeedScanner(
        device.databaseService,
        DeviceIdentity(device.databaseService),
        SeqCounter(device.databaseService),
        HybridLogicalClock(device.databaseService),
      );
      final scan = await scanner.scan();
      expect(scan.recessive, isTrue);
      expect(scan.operationsSeeded, greaterThan(0));

      // The clock moves only by the `set_add` seeds, which are deliberately
      // NOT recessive (M2.13 review round 5: the stamp would decide nothing
      // in `OrSetResolver`, which never compares an HLC, while a `set_add`'s
      // wallMs IS read as a membership row's `createdAt` fallback). Every
      // `field` and `__exists__` seed calls generate() zero times, which is
      // what § 11.2 property (a)'s exception is scoped to.
      expect(
        int.parse(await device.stateValue(hlcWallStateKey) as String),
        greaterThanOrEqualTo(int.parse(wallBefore as String)),
        reason: 'the clock may only move forward, never backwards',
      );
      expect(logicalBefore, isNotNull);

      final db = await device.db;
      final tieBreakingSeedOps = await db.query(
        'sync_pending_ops',
        columns: const ['hlc', 'kind'],
        where: "authorId LIKE 'seed:%' AND kind IN ('field', '__exists__')",
      );
      expect(
        tieBreakingSeedOps.map((r) => r['kind']).toSet(),
        {'field', '__exists__'},
        reason: 'both kinds must actually be present, or the assertion below '
            'passes vacuously for whichever one is missing',
      );
      expect(
        tieBreakingSeedOps.map((r) => Hlc.parse(r['hlc'] as String)).toSet(),
        {Hlc.zero},
        reason: 'EVERY operation of a post-reset seed whose HLC is a '
            'tie-break input, not merely some. `field` carries the content F1 '
            'travels through; `__exists__` carries the creation DOT that '
            'materializer._creationDot/_generationDot read, and round 4 '
            'exempting it re-parented every entity on every peer (section 6d)',
      );

      final membershipSeedOps = await db.query(
        'sync_pending_ops',
        columns: const ['hlc'],
        where: "authorId LIKE 'seed:%' AND kind = 'set_add'",
      );
      expect(membershipSeedOps, isNotEmpty);
      expect(
        membershipSeedOps
            .map((r) => Hlc.parse(r['hlc'] as String))
            .every((h) => h.wallMs > 0),
        isTrue,
        reason: 'a set_add seed keeps a REAL clock (M2.13 round 5). '
            'OrSetResolver never compares an HLC, so a recessive stamp would '
            'decide nothing there — while a set_add\'s wallMs IS read, by '
            'materializer._insertMembershipRow, as a membership row\'s '
            'createdAt fallback. A stamp with no reader and a live hazard is '
            'strictly worse than a real value',
      );

      // And the clock still generates real, strictly-positive values
      // afterwards — the exception is scoped to the seed, not to the device.
      await device.service.setUpDataset();
      await (await device.db).update(
        'notes',
        {'title': 'edited after the recessive seed'},
        where: 'id = ?',
        whereArgs: ['n1'],
      );
      await device.service.syncNow();
      final ordinary = await (await device.db).query(
        'sync_pending_ops',
        columns: const ['hlc'],
        where: "authorId NOT LIKE 'seed:%' AND fieldName = 'title'",
      );
      expect(ordinary, isNotEmpty);
      for (final row in ordinary) {
        expect(Hlc.parse(row['hlc'] as String) > Hlc.zero, isTrue);
      }
    },
  );

  // =====================================================================
  // 6d. F4 (review round 5) — the `__exists__` register records the
  //     WINNER'S DOT as well as a timestamp, and two live consumers read
  //     it. A post-reset seed must not move it.
  // =====================================================================
  //
  // Round 4 excluded `__exists__` from the recessive stamp to stop a
  // `Hlc.zero` seed dating a rebuilt library 1970-01-01, and justified the
  // exclusion with "either side of that conflict materializes the identical
  // outcome, so it cannot reopen the original defect". That is false about
  // the VALUE (which is indeed the constant `true`) and silent about the
  // DOT. `sync_field_state`'s row for `(table, id, '__exists__')` also
  // stores the winner's `(authorId, authorSeq)`, and `materializer.dart`
  // reads it twice: `_creationDot` feeds § Architecture 10's tag
  // name-collision tie-break, and `_generationDot` is folded into BOTH
  // `contentKey`s minted by `_mintAutoMergeLoserPair`, where two devices
  // have to agree or the auto-merge pair fails to dedup and shows up as a
  // spurious permanent conflict record.
  //
  // With the exclusion shipped, a dominant `__exists__` seed won the
  // conflict on recency and flipped that dot on EVERY entity on EVERY peer
  // that pulled a post-reset seed. Round 5 restores the recessive stamp and
  // fixes the 1970 problem where it actually lives — in the materializer's
  // derivation of `createdAt` — so both properties hold at once. Both are
  // asserted here, permanently, because each was invisible to the other's
  // test.

  Future<String?> existsWinnerDot(_Device d, String table, String id) async {
    final rows = await (await d.db).query(
      'sync_field_state',
      columns: const ['authorId', 'authorSeq'],
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [table, id, '__exists__'],
    );
    return rows.isEmpty
        ? null
        : '${rows.first['authorId']}#${rows.first['authorSeq']}';
  }

  test(
    'F4: a peer pulling a post-reset seed keeps the entity\'s creation dot AND '
    'a non-zero createdAt',
    () async {
      final backend = MockSyncBackend();
      final a = _Device(sharedBackend: backend);
      final b = _Device(sharedBackend: backend);
      addTearDown(a.close);
      addTearDown(b.close);

      await insertSharedNote(await a.db);
      await a.service.setUpDataset();
      await a.service.syncNow();
      await b.service.setUpDataset();
      for (var i = 0; i < 2; i++) {
        await b.service.syncNow();
      }
      expect(await noteTitle(b), 'original title');

      final dotBefore = await existsWinnerDot(b, 'notes', 'n1');
      expect(dotBefore, isNotNull, reason: 'precondition: B resolved n1');
      final createdAtBefore = (await (await b.db).query(
        'notes',
        columns: const ['createdAt'],
        where: 'id = ?',
        whereArgs: ['n1'],
      )).single['createdAt'];

      await a.service.resetSyncState();
      await a.service.setUpDataset();
      await a.service.syncNow();
      for (var i = 0; i < 2; i++) {
        await b.service.syncNow();
      }

      expect(
        await existsWinnerDot(b, 'notes', 'n1'),
        dotBefore,
        reason: 'the creation dot is an INPUT to the tag collision tie-break '
            'and to both auto-merge contentKeys. A post-reset re-seed is a '
            're-statement, so it must lose the __exists__ conflict too — not '
            'only the field conflicts',
      );
      expect(
        (await (await b.db).query(
          'notes',
          columns: const ['createdAt'],
          where: 'id = ?',
          whereArgs: ['n1'],
        )).single['createdAt'],
        createdAtBefore,
        reason: 'and the row it already had is not re-dated either',
      );
    },
  );

  test(
    'F4: a device rebuilding from a post-reset seed dates the library from a '
    'real clock, never epoch 0',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      device.replaceBackendWithEmptyOne();
      await expectLater(
        device.service.syncNow(),
        throwsA(isA<DatasetMissingException>()),
      );
      await device.service.resetSyncState();
      await device.service.setUpDataset();
      await device.service.syncNow();

      // Every `__exists__` on the wire is recessive, i.e. wall 0 — that is
      // the whole point, and it is what makes the materializer's derivation
      // (not the operation's HLC) responsible for a plausible `createdAt`.
      final existsOps = await (await device.db).query(
        'sync_pending_ops',
        columns: const ['hlc'],
        where: "authorId LIKE 'seed:%' AND kind = '__exists__'",
      );
      expect(existsOps, isNotEmpty);
      expect(
        existsOps.map((r) => Hlc.parse(r['hlc'] as String)).toSet(),
        {Hlc.zero},
        reason: 'precondition: this test is worthless unless the __exists__ '
            'seeds really are recessive',
      );

      final peerDb = DatabaseService.createNew();
      addTearDown(peerDb.close);
      final peerSession = SyncSession(peerDb);
      for (var i = 0; i < 3; i++) {
        await peerSession.run(device.backend);
      }
      final peer = await peerDb.database;

      for (final probe in [
        ('notes', 'n1'),
        ('tags', 't1'),
        ('conversations', 'c1'),
      ]) {
        final row = (await peer.query(
          probe.$1,
          where: 'id = ?',
          whereArgs: [probe.$2],
        )).single;
        expect(
          row['createdAt'],
          greaterThan(0),
          reason: '${probe.$1}/${probe.$2}: a wall-0 __exists__ must not date '
              'the rebuilt row 1970-01-01 — materializer._materializeExists '
              'falls back to the receiving device\'s own clock',
        );
      }

      // And the membership rows one layer down (F5): the same fallback shape
      // exists in `_insertMembershipRow`, masked today only by every
      // createdAt-bearing membership scope declaring `payloadColumns:
      // ['createdAt']`. Asserted rather than trusted.
      final mappings = await peer.query('note_tags');
      expect(mappings, hasLength(1));
    },
  );

  test(
    'two devices that both reset and seed DIFFERENT content for one field '
    'converge deterministically, and the loser is kept as a conflict copy',
    () async {
      final backend = MockSyncBackend();
      final a = _Device(sharedBackend: backend);
      final b = _Device(sharedBackend: backend);
      addTearDown(a.close);
      addTearDown(b.close);

      await insertSharedNote(await a.db);
      await a.service.setUpDataset();
      await a.service.syncNow();
      await b.service.setUpDataset();
      for (var i = 0; i < 2; i++) {
        await b.service.syncNow();
      }
      expect(await noteTitle(b), 'original title');

      // Both devices lose their logs and both reset, holding different
      // content: both seeds are at HLC 0, so the tie-break falls through to
      // `(authorId, authorSeq)`.
      for (final logId in await backend.listDeviceLogIds()) {
        backend.debugDeleteDeviceLogExternally(logId);
      }
      await (await a.db).update('notes', {'title': 'A content'},
          where: 'id = ?', whereArgs: ['n1']);
      await (await b.db).update('notes', {'title': 'B content'},
          where: 'id = ?', whereArgs: ['n1']);
      // Drained into ordinary operations first, so the re-touch carry-over
      // is not what is being measured here: clear the evidence of the edit
      // so each device's value reaches the wire as a SEED.
      for (final d in [a, b]) {
        await (await d.db).delete('sync_touch_log');
      }

      await a.service.resetSyncState();
      await b.service.resetSyncState();
      // Same reason: the reset carries unfinished work across as touches.
      for (final d in [a, b]) {
        await (await d.db).delete('sync_touch_log');
      }
      await a.service.setUpDataset();
      await b.service.setUpDataset();

      for (var i = 0; i < 3; i++) {
        await a.service.syncNow();
        await b.service.syncNow();
      }

      final titleA = await noteTitle(a);
      expect(
        titleA,
        anyOf('A content', 'B content'),
        reason: 'one of the two, decided by (authorId, authorSeq)',
      );
      expect(
        await noteTitle(b),
        titleA,
        reason: 'the tie-break is a total order over distinct dots, so both '
            'devices must pick the SAME winner — an HLC tie is not a '
            'divergence',
      );

      for (final d in [a, b]) {
        final copies = await (await d.db).query(
          'sync_conflict_copies',
          where: 'subjectTable = ? AND subjectId = ? AND fieldName = ? '
              "AND kind = 'field_conflict'",
          whereArgs: ['notes', 'n1', 'title'],
        );
        expect(
          copies,
          isNotEmpty,
          reason: 'requirement 2: the losing seed is preserved as a '
              'recoverable conflict copy, never silently dropped',
        );
      }
    },
  );

  test(
    'the retired-log case: a reset against a live dataset adopts this '
    "device's own previously-published state, and genuinely unfinished local "
    'work still wins',
    () async {
      final backend = MockSyncBackend();
      final device = _Device(sharedBackend: backend);
      addTearDown(device.close);
      final db = await device.db;
      await insertSharedNote(db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      // Two changes, one of each kind. `title` is edited and PUBLISHED, so
      // the backend holds it under the soon-to-be-retired namespace.
      await db.update('notes', {'title': 'published title'},
          where: 'id = ?', whereArgs: ['n1']);
      await device.service.syncNow();

      // `content` is edited and never published — the outbox of a device
      // that cannot push.
      await db.update('notes', {'content': 'UNPUBLISHED body'},
          where: 'id = ?', whereArgs: ['n1']);

      await device.service.resetSyncState();
      await device.service.setUpDataset();
      for (var i = 0; i < 2; i++) {
        await device.service.syncNow();
      }

      expect(
        await noteTitle(device),
        'published title',
        reason: 'the dataset holds this device\'s own operation for the '
            'field; the recessive re-seed re-states it and does not out-rank '
            'it — and here they agree, so nothing changes',
      );
      final row = (await db.query('notes', where: 'id = ?', whereArgs: ['n1']))
          .single;
      expect(
        row['content'],
        'UNPUBLISHED body',
        reason: 'the re-touch re-mints unfinished local work as an ORDINARY '
            'operation with a real HLC, which beats both the retired '
            "namespace's older published value and the recessive seed",
      );
    },
  );

  // =====================================================================
  // 7. F2 — a deleted own-log with an EMPTY outbox.
  // =====================================================================

  test(
    'a device log deleted while nothing was pending is reported, not passed '
    'off as fully healthy',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      // The dataset marker survives; this device's own logs do not. Nothing
      // is pending, so Phase A attempts no append and can observe no
      // `ParentMismatch` — the only pre-existing divergence detector.
      for (final logId in await device.backend.listDeviceLogIds()) {
        device.backend.debugDeleteDeviceLogExternally(logId);
      }

      final result = await device.service.syncNow();
      expect(
        result.divergedAuthorIds,
        isNotEmpty,
        reason: 'the backend does not hold the commit this device recorded as '
            'its tip; that is a divergence whether or not anything was queued '
            'to push',
      );

      final status = await device.service.status();
      expect(status.needsReset, isTrue);
      expect(status.canReset, isTrue);
      expect(
        status.lastSync!.degraded,
        isTrue,
        reason: 'a round in which the user\'s entire library is absent from '
            'the backend is not a clean success',
      );
      expect(
        status.health.issues.map((i) => i.kind),
        contains(SyncHealthIssueKind.deviceLogDiverged),
      );
      expect(
        await device.stateValue(divergedAuthorLogsStateKey),
        isNotNull,
        reason: 'a round that pushes nothing must not erase a divergence the '
            'pre-flight check just detected',
      );

      // The remedy still works from this state.
      await device.service.resetSyncState();
      await device.service.setUpDataset();
      final recovered = await device.service.syncNow();
      expect(recovered.divergedAuthorIds, isEmpty);
      expect(recovered.totalPublished, greaterThan(0));
    },
  );

  test('a healthy device pays no divergence false positive', () async {
    final device = _Device();
    addTearDown(device.close);
    await seedUserContent(await device.db);
    await device.service.setUpDataset();
    await device.service.syncNow();

    final quiet = await device.service.syncNow();
    expect(quiet.divergedAuthorIds, isEmpty);
    expect((await device.service.status()).health.isDegraded, isFalse);
  });

  // =====================================================================
  // 7b. Finding 4a — the pre-flight divergence check's legacy commit-seq
  //     fallback must not read an UNCONFIRMED publish intent as a position
  //     the backend is expected to hold a commit at.
  // =====================================================================

  DatasetBootstrap bootstrapFor(_Device device) => DatasetBootstrap(
        device.databaseService,
        device.backend,
        DeviceIdentity(device.databaseService),
      );

  /// Turns a healthy, synced device into the pre-M2.12 shape the fallback
  /// exists for: no `commit_seq:` rows at all, plus the residue of a crash
  /// between `appendCommit` and the local write that would have confirmed
  /// it — one `pending` intent one position past the real tip.
  Future<void> makePreM212WithDanglingIntent(_Device device) async {
    final db = await device.db;
    final deviceId = (await device.stateValue('device_id'))!;
    await db.delete('sync_state', where: "key LIKE 'commit_seq:%'");
    for (final authorId in [deviceId, 'seed:$deviceId']) {
      final maxRow = await db.rawQuery(
        'SELECT MAX(deviceSeq) AS m FROM sync_publish_intent '
        "WHERE authorId = ? AND status = 'confirmed'",
        [authorId],
      );
      await db.insert('sync_publish_intent', {
        'intentHash': 'dangling-$authorId',
        'parentCommitHash': null,
        'payloadHash': 'never-landed',
        'authorId': authorId,
        'deviceSeq': ((maxRow.first['m'] as int?) ?? 0) + 1,
        'status': 'pending',
        'createdAt': 1,
      });
    }
  }

  test(
    'a healthy pre-M2.12 device carrying a dangling unconfirmed publish '
    'intent is not told to retire its identity',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      await makePreM212WithDanglingIntent(device);

      expect(
        await bootstrapFor(device).verifyOwnedLogsStillExist(),
        isEmpty,
        reason: 'only a CONFIRMED intent is evidence that a commit exists at '
            'a position. Unlike PushPhase, nothing resumes pending intents '
            'before this check runs, so reading MAX(deviceSeq) unfiltered '
            'asks the backend for a commit that was never durably recorded '
            'and reports a healthy user diverged',
      );
    },
  );

  test(
    'CONTROL for the above: the same device with its logs genuinely deleted '
    'is still reported diverged',
    () async {
      final device = _Device();
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      await makePreM212WithDanglingIntent(device);
      for (final logId in await device.backend.listDeviceLogIds()) {
        device.backend.debugDeleteDeviceLogExternally(logId);
      }

      expect(
        await bootstrapFor(device).verifyOwnedLogsStillExist(),
        isNotEmpty,
        reason: 'the fix must narrow the fallback, not disable the detector',
      );
    },
  );

  // =====================================================================
  // 7c. Finding 4b — a pre-flight divergence must not survive a round in
  //     which that namespace actually published.
  // =====================================================================

  test(
    'a namespace that publishes successfully clears the divergence the '
    'pre-flight check reported for it, in the SAME round',
    () async {
      final backend = MockSyncBackend();
      final lens = _LaggyListingBackend(backend);
      final device = _Device(sharedBackend: backend, lens: lens);
      addTearDown(device.close);
      await seedUserContent(await device.db);
      await device.service.setUpDataset();
      await device.service.syncNow();

      final deviceId = (await device.stateValue('device_id'))!;
      // The pre-flight `readCommits(limit: 1)` comes back empty for both
      // owned namespaces — an ordinary read-after-write listing gap, not a
      // deletion. The backend still holds the commits, so the append that
      // follows succeeds.
      lens.emptyReadLogIds = {deviceId, 'seed:$deviceId'};

      await (await device.db).update(
        'notes',
        {'title': 'something to push'},
        where: 'id = ?',
        whereArgs: ['n1'],
      );

      // The premise, asserted rather than assumed: the pre-flight check does
      // report this namespace as diverged going into the round.
      final preflight = await DatasetBootstrap(
        device.databaseService,
        lens,
        DeviceIdentity(device.databaseService),
      ).verifyOwnedLogsStillExist();
      expect(preflight, contains(deviceId));

      final result = await device.service.syncNow();
      expect(result.push.publishedCount, greaterThan(0));
      expect(
        result.divergedAuthorIds,
        isNot(contains(deviceId)),
        reason: 'a commit the backend ACCEPTED is proof the chain still '
            'continues — `ParentMismatch` is exactly the check it passed. '
            'Unioning preDivergedAuthorIds in unconditionally wrote the '
            'durable divergence row for a round in which the push fully '
            'succeeded, making the documented claim "a successful push '
            'clears its own divergence" untrue of that round',
      );
      expect(
        await device.stateValue(divergedAuthorLogsStateKey),
        isNull,
        reason: 'and nothing durable is left behind either',
      );
      // The counterpart — that a push which publishes NOTHING must not clear
      // a pre-flight divergence — is pinned by section 7's F2 test, which
      // fails outright if the clearing is not gated on `publishedCount > 0`.
    },
  );

  // =====================================================================
  // 8. F4 — a partially-successful push reports what it landed.
  // =====================================================================

  test('a push that halts after publishing reports what it published, not 0',
      () async {
    final device = _Device();
    addTearDown(device.close);
    await seedUserContent(await device.db);
    await device.service.setUpDataset();

    final session = SyncSession(
      device.databaseService,
      pushPhase: _HaltAfterPublishingPushPhase(device.databaseService, 40),
    );
    final result = await session.run(device.backend);

    expect(
      result.totalPublished,
      80,
      reason: 'PushPhase commits per commit and rolls nothing back, so a halt '
          'after 40 landed operations per namespace has durably published 80 '
          '— reporting 0 put "pushed 0" on screen for a round that uploaded '
          'most of the library',
    );
    expect(result.divergedAuthorIds, hasLength(2));
  });

  // =====================================================================
  // 5. Reset on a device that never synced.
  // =====================================================================

  test('reset is safe on a device that has never touched the sync engine',
      () async {
    final device = _Device();
    addTearDown(device.close);
    await seedUserContent(await device.db);

    final result = await DatasetReset(device.databaseService).reset();
    expect(result.previousDeviceId, isNull);
    expect(await device.rowCount('notes'), 1);
    expect(
      (await device.service.status()).bootstrapStatus,
      DatasetBootstrapStatus.none,
    );
  });
}
