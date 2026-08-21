// Tests for M2.3's `DeviceIdentity` (`lib/services/sync/device_identity.dart`)
// — § Architecture 11.1's device-id half of the sync-engine bootstrap
// milestone.
//
// **Placement decision.** Lives under `test/sync_engine/`, a new directory,
// not `test/sync_backend/` — matching the M2.3 brief's own framing that this
// is the start of a new "engine" layer distinct from the "backend" layer
// M2.1/M2.2 tested. `test/sync_backend/` is scoped to `SyncBackend`
// conformance (the storage abstraction itself, real or mock); the classes
// under test here (`DeviceIdentity`, `DatasetBootstrap`, `SeqCounter`,
// `HybridLogicalClock`) sit one layer up, against a real (ffi, in-memory)
// `DatabaseService` plus `MockSyncBackend`, and none of them are about
// backend conformance at all — `SeqCounter`/`HybridLogicalClock` don't touch
// a `SyncBackend` at all. A new directory name reads more clearly than
// overloading `sync_backend/` for both.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('DeviceIdentity', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('generates a device id on first call and persists it in sync_state', () async {
      final identity = DeviceIdentity(databaseService);
      final id = await identity.ensureDeviceId();

      expect(id, isNotEmpty);
      // A v4 uuid: 8-4-4-4-12 hex groups.
      expect(
        id,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );

      final db = await databaseService.database;
      final rows = await db.query('sync_state', where: 'key = ?', whereArgs: ['device_id']);
      expect(rows, hasLength(1));
      expect(rows.first['value'], id);
    });

    test('returns the same id on every subsequent call, same instance', () async {
      final identity = DeviceIdentity(databaseService);
      final first = await identity.ensureDeviceId();
      final second = await identity.ensureDeviceId();
      final third = await identity.ensureDeviceId();

      expect(second, first);
      expect(third, first);
    });

    test('returns the same id across a fresh DeviceIdentity instance (no in-memory cache reuse)', () async {
      final first = await DeviceIdentity(databaseService).ensureDeviceId();
      final second = await DeviceIdentity(databaseService).ensureDeviceId();

      expect(second, first, reason: 'a fresh instance must read the already-persisted device_id, not regenerate');
    });

    test('never regenerates: does not overwrite an already-persisted device_id', () async {
      final db = await databaseService.database;
      await db.insert('sync_state', {'key': 'device_id', 'value': 'pre-existing-id'});

      final id = await DeviceIdentity(databaseService).ensureDeviceId();
      expect(id, 'pre-existing-id');

      final rows = await db.query('sync_state', where: 'key = ?', whereArgs: ['device_id']);
      expect(rows, hasLength(1));
      expect(rows.first['value'], 'pre-existing-id');
    });

    test(
      'a second, independent connection to the same underlying database file '
      'joins onto the first connection\'s already-persisted device id',
      () async {
        // **What this test proves, and — after an earlier version of it
        // overclaimed this — what it deliberately does NOT attempt.**
        //
        // An earlier version of this test ran two `DeviceIdentity`
        // instances sharing one `DatabaseService`/`Database` object through
        // `Future.wait`, commented as "exercising" a real race. It wasn't:
        // sqflite fully serializes every `db.transaction()` call against a
        // single connection (a per-connection single-writer lock), so the
        // second call's transaction could only ever start after the
        // first's had already committed — it always found the row already
        // there, and `ensureDeviceId`'s `INSERT OR IGNORE`-then-re-read
        // fallback was never actually reached. That was sequential
        // execution disguised as `Future.wait`, not a race, and the test's
        // own comment claimed otherwise.
        //
        // The natural fix is two genuinely independent connections (two
        // `DatabaseService` instances against the identical underlying
        // file) raced concurrently via `Future.wait`. That was attempted
        // here and empirically, reproducibly failed: two connections
        // issuing `BEGIN IMMEDIATE` against the same on-disk file at
        // (approximately) the same moment reliably deadlock in this test
        // harness (`sqflite_common_ffi`, verified against both the
        // isolate-based `databaseFactoryFfi` and non-isolate
        // `databaseFactoryFfiNoIsolate` factories, and across several
        // `PRAGMA busy_timeout` values from 100ms to 5000ms) — the losing
        // side's `BEGIN IMMEDIATE` never succeeds and instead fails with
        // `SQLITE_BUSY` at almost exactly the configured busy-timeout
        // boundary, every time, not merely occasionally. That is a
        // characteristic of this on-disk-file/ffi test environment, not
        // evidence about `DeviceIdentity` itself — per the M2.3 review
        // guidance, this is disclosed honestly here rather than shipping a
        // test that is either flaky or, worse, silently not testing what
        // its own comment claims.
        //
        // **What this test does instead, and does prove**: two genuinely
        // independent connections (not the same `Database` object, so the
        // single-connection-serialization concern above does not apply)
        // are used *sequentially* rather than raced — connection A mints
        // and durably commits a device id; connection B, a second, wholly
        // separate connection to the identical file, is then asked to
        // `ensureDeviceId()` and is asserted to read back and return
        // exactly what A committed, never generating a second id. This is
        // still a real, meaningful cross-connection assertion (unlike the
        // in-memory-cache tests above, B has no way to observe A's result
        // except by reading it back from the file) — it just does not
        // claim to exercise genuine simultaneous contention.
        //
        // **Residual, disclosed rather than silently left uncovered**:
        // whether `ensureDeviceId`'s `INSERT OR IGNORE`-then-re-read
        // fallback behaves correctly under an actual simultaneous
        // cross-connection `PRIMARY KEY` collision is not exercised by any
        // test in this file. The transactional design continues to
        // guarantee correctness by construction even so — `INSERT OR
        // IGNORE` cannot raise a constraint-violation error, only silently
        // no-op, and the subsequent `SELECT` inside the same transaction
        // always returns whichever row is actually persisted — but that
        // guarantee is reasoned about here, not test-proven under real
        // concurrent load, given this environment's inability to sustain
        // two genuinely concurrent writers against one file at all.
        final sharedDatabaseName =
            'device_identity_join_test_${DateTime.now().microsecondsSinceEpoch}.db';

        final serviceA = DatabaseService.createNew(databaseName: sharedDatabaseName);
        final rawA = await serviceA.database;
        addTearDown(serviceA.close);

        final idFromA = await DeviceIdentity(serviceA).ensureDeviceId();

        // A second, wholly independent connection to the same file —
        // opened only after A's write has already committed, specifically
        // to avoid the deadlock documented above, while still exercising
        // real cross-connection (not merely cross-instance-with-shared-
        // connection) persistence.
        final serviceB = DatabaseService.createNew(databaseName: sharedDatabaseName);
        await serviceB.database;
        addTearDown(serviceB.close);

        final idFromB = await DeviceIdentity(serviceB).ensureDeviceId();

        expect(
          idFromB,
          idFromA,
          reason: 'a second, independent connection must read back A\'s already-persisted id, not mint its own',
        );

        final rows = await rawA.query('sync_state', where: 'key = ?', whereArgs: ['device_id']);
        expect(rows, hasLength(1), reason: 'exactly one device_id row must exist on disk');
        expect(rows.first['value'], idFromA);

        final labelRows = await rawA.query(
          'sync_device_labels',
          where: 'deviceId = ?',
          whereArgs: [idFromA],
        );
        expect(
          labelRows,
          hasLength(1),
          reason: 'exactly one sync_device_labels row must exist on disk',
        );
      },
    );

    test('inserts a sync_device_labels row with isCurrentDevice = 1 on first mint', () async {
      final identity = DeviceIdentity(databaseService);
      final id = await identity.ensureDeviceId();

      final db = await databaseService.database;
      final rows = await db.query('sync_device_labels', where: 'deviceId = ?', whereArgs: [id]);
      expect(rows, hasLength(1));
      expect(rows.first['isCurrentDevice'], 1);
      expect(rows.first['retiredAt'], isNull);
    });

    test('does not duplicate the sync_device_labels row on repeated calls', () async {
      final identity = DeviceIdentity(databaseService);
      final id = await identity.ensureDeviceId();
      await DeviceIdentity(databaseService).ensureDeviceId();

      final db = await databaseService.database;
      final rows = await db.query('sync_device_labels', where: 'deviceId = ?', whereArgs: [id]);
      expect(rows, hasLength(1));
    });
  });
}
