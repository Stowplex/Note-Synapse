// Tests for M2.3's `DatasetBootstrap` (`lib/services/sync/dataset_bootstrap.dart`)
// — § Architecture 11.1's 5-step create-or-join sequence. See
// `device_identity_test.dart` for the `test/sync_engine/` placement
// rationale.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/dataset_bootstrap.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';

import '../sync_backend/mock_sync_backend.dart';

/// Test fixture: one "device" is its own `DatabaseService` (a distinct
/// in-memory-equivalent ffi database) plus the `DeviceIdentity`/
/// `DatasetBootstrap` wired against it — modeling two genuinely separate
/// installs that only ever communicate through the shared `SyncBackend`.
class _Device {
  _Device(this.db, this.identity, this.bootstrap);
  final DatabaseService db;
  final DeviceIdentity identity;
  final DatasetBootstrap bootstrap;

  static Future<_Device> create(
    MockSyncBackend backend, {
    PassphraseVerifier? passphraseVerifier,
  }) async {
    final db = DatabaseService.createNew();
    await db.database;
    final identity = DeviceIdentity(db);
    final bootstrap = DatasetBootstrap(
      db,
      backend,
      identity,
      passphraseVerifier: passphraseVerifier,
    );
    return _Device(db, identity, bootstrap);
  }

  Future<void> close() => db.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('DatasetBootstrap — basic create/join', () {
    test('creates an unencrypted dataset and reaches ready', () async {
      final backend = MockSyncBackend();
      final device = await _Device.create(backend);
      addTearDown(device.close);

      final marker = await device.bootstrap.bootstrap(encryptionEnabled: false);

      expect(marker.encryptionEnabled, isFalse);
      expect(marker.createdByDeviceId, await device.identity.ensureDeviceId());
      expect(await device.bootstrap.currentStatus(), DatasetBootstrapStatus.ready);

      final db = await device.db.database;
      final rows = await db.query(
        'sync_state',
        where: 'key = ?',
        whereArgs: ['dataset_bootstrap_status'],
      );
      expect(rows.single['value'], 'ready');
    });

    test('a second device joins an already-created dataset without building its own marker', () async {
      final backend = MockSyncBackend();
      final creator = await _Device.create(backend);
      addTearDown(creator.close);
      final joiner = await _Device.create(backend);
      addTearDown(joiner.close);

      final createdMarker = await creator.bootstrap.bootstrap(encryptionEnabled: false);
      final joinedMarker = await joiner.bootstrap.bootstrap(encryptionEnabled: false);

      expect(joinedMarker.createdByDeviceId, createdMarker.createdByDeviceId);
      expect(
        joinedMarker.createdByDeviceId,
        isNot(await joiner.identity.ensureDeviceId()),
        reason: 'the joiner must adopt the creator\'s marker, not its own identity',
      );
      expect(await joiner.bootstrap.currentStatus(), DatasetBootstrapStatus.ready);
    });

    test('bootstrap() is idempotent: calling it again after success returns the same marker', () async {
      final backend = MockSyncBackend();
      final device = await _Device.create(backend);
      addTearDown(device.close);

      final first = await device.bootstrap.bootstrap(encryptionEnabled: false);
      final second = await device.bootstrap.bootstrap(encryptionEnabled: false);

      expect(second.createdByDeviceId, first.createdByDeviceId);
      expect(second.createdAt, first.createdAt);
    });
  });

  group('DatasetBootstrap — create-vs-join race', () {
    test(
      'two devices independently build+submit a DatasetInitMarker to the same backend; '
      'both later converge on reading back the single winning marker',
      () async {
        final backend = MockSyncBackend();

        // Two devices, each believing (correctly, at the time) that no
        // marker exists yet, independently construct their own local
        // DatasetInitMarker and submit it directly to the shared backend —
        // the exact race primitive § 11.1 step 2 describes: "two separate
        // DatasetInitMarker construction + initializeDatasetOnce calls
        // against the same MockSyncBackend instance."
        final markerFromA = DatasetInitMarker(
          encryptionEnabled: false,
          kdfSalt: null,
          passphraseCanary: null,
          createdByDeviceId: 'device-a',
          createdAt: DateTime.utc(2026, 1, 1),
        );
        final markerFromB = DatasetInitMarker(
          encryptionEnabled: false,
          kdfSalt: null,
          passphraseCanary: null,
          createdByDeviceId: 'device-b',
          createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        );

        // Device A's write reaches the backend first and wins.
        await backend.initializeDatasetOnce(markerFromA);
        // Device B's write is the loser: per SyncBackend's documented
        // contract this is a silent no-op, not an error, and the backend
        // continues reporting device A's marker.
        await backend.initializeDatasetOnce(markerFromB);

        // Now run the *real* end-to-end DatasetBootstrap sequence for two
        // fresh devices (their own local databases, own DeviceIdentity) and
        // confirm both converge on device A's marker via step 3's
        // mandatory re-read — this is the "create and join are the same
        // code path" property: neither device trusts a locally-built
        // marker, both defer to what the backend actually reports.
        final deviceA = await _Device.create(backend);
        addTearDown(deviceA.close);
        final deviceB = await _Device.create(backend);
        addTearDown(deviceB.close);

        final resultFromDeviceA = await deviceA.bootstrap.bootstrap(encryptionEnabled: false);
        final resultFromDeviceB = await deviceB.bootstrap.bootstrap(encryptionEnabled: false);

        expect(resultFromDeviceA.createdByDeviceId, 'device-a');
        expect(resultFromDeviceB.createdByDeviceId, 'device-a');
        expect(
          resultFromDeviceA.createdAt,
          resultFromDeviceB.createdAt,
          reason: 'both devices must observe the exact same single winning marker',
        );
      },
    );

    test(
      'two devices concurrently racing to create the same dataset (via bootstrap() itself) '
      'converge on exactly one winning marker',
      () async {
        final backend = MockSyncBackend();
        final deviceA = await _Device.create(backend);
        addTearDown(deviceA.close);
        final deviceB = await _Device.create(backend);
        addTearDown(deviceB.close);

        final idA = await deviceA.identity.ensureDeviceId();
        final idB = await deviceB.identity.ensureDeviceId();

        // Genuine concurrency: both devices' full bootstrap() sequences
        // (each doing its own local-database work, own step-1 read, and
        // potentially its own step-2 create attempt) run interleaved via
        // Dart's single-threaded async scheduler, racing against the same
        // MockSyncBackend instance. Which one actually wins is not
        // asserted (that's scheduling-dependent and not this test's
        // concern); what must always hold is that both converge on
        // identical output.
        final results = await Future.wait([
          deviceA.bootstrap.bootstrap(encryptionEnabled: false),
          deviceB.bootstrap.bootstrap(encryptionEnabled: false),
        ]);

        expect(
          results[0].createdByDeviceId,
          results[1].createdByDeviceId,
          reason: 'both devices must converge on exactly one winning marker',
        );
        expect([idA, idB], contains(results[0].createdByDeviceId));
        expect(await deviceA.bootstrap.currentStatus(), DatasetBootstrapStatus.ready);
        expect(await deviceB.bootstrap.currentStatus(), DatasetBootstrapStatus.ready);
      },
    );
  });

  group('DatasetBootstrap — crash-mid-bootstrap resume', () {
    test('resumes when the crash happened before the backend was ever touched', () async {
      final backend = MockSyncBackend();
      final device = await _Device.create(backend);
      addTearDown(device.close);

      // Simulate an earlier, crashed attempt: dataset_bootstrap_status was
      // written as 'bootstrapping' (this milestone's design: mark
      // 'bootstrapping' *before* touching the backend) but the process
      // died before ever calling into the backend at all.
      final rawDb = await device.db.database;
      await rawDb.insert('sync_state', {
        'key': 'dataset_bootstrap_status',
        'value': 'bootstrapping',
      });
      expect(await device.bootstrap.currentStatus(), DatasetBootstrapStatus.bootstrapping);

      // A fresh DatasetBootstrap instance stands in for the restarted
      // process. It must neither get stuck (e.g. refusing to proceed
      // because it thinks bootstrap is "already in flight") nor silently
      // skip work — it must actually complete the sequence.
      final marker = await device.bootstrap.bootstrap(encryptionEnabled: false);

      expect(marker, isNotNull);
      expect(await device.bootstrap.currentStatus(), DatasetBootstrapStatus.ready);
      expect(await backend.readDatasetInitMarker(), isNotNull);
    });

    test(
      'resumes when the crash happened after the backend write landed but before status flipped to ready',
      () async {
        final backend = MockSyncBackend();
        final device = await _Device.create(backend);
        addTearDown(device.close);

        final deviceId = await device.identity.ensureDeviceId();
        final alreadyWrittenMarker = DatasetInitMarker(
          encryptionEnabled: false,
          kdfSalt: null,
          passphraseCanary: null,
          createdByDeviceId: deviceId,
          createdAt: DateTime.utc(2026, 1, 1),
        );
        // The crashed attempt got as far as successfully calling
        // initializeDatasetOnce...
        await backend.initializeDatasetOnce(alreadyWrittenMarker);

        // ...but died before ever writing 'ready' — status is stuck at
        // 'bootstrapping' on disk.
        final rawDb = await device.db.database;
        await rawDb.insert('sync_state', {
          'key': 'dataset_bootstrap_status',
          'value': 'bootstrapping',
        });

        final marker = await device.bootstrap.bootstrap(encryptionEnabled: false);

        // Resuming must not attempt a second, competing create (which
        // would be harmless anyway per the backend's own idempotency
        // contract, but the resumed marker must still be exactly the
        // already-written one, not a fresh one with a different
        // createdAt).
        expect(marker.createdAt, alreadyWrittenMarker.createdAt);
        expect(marker.createdByDeviceId, deviceId);
        expect(await device.bootstrap.currentStatus(), DatasetBootstrapStatus.ready);
      },
    );

    test('a fresh instance re-reading status "ready" does not re-touch the backend to reach ready again', () async {
      final backend = MockSyncBackend();
      final device = await _Device.create(backend);
      addTearDown(device.close);

      final first = await device.bootstrap.bootstrap(encryptionEnabled: false);

      // Fresh DatasetBootstrap instance, same underlying database (status
      // already 'ready' on disk) — models a fresh process that never saw
      // the in-memory state of the first bootstrap() call.
      final resumedBootstrap = DatasetBootstrap(device.db, backend, device.identity);
      final second = await resumedBootstrap.bootstrap(encryptionEnabled: false);

      expect(second.createdByDeviceId, first.createdByDeviceId);
      expect(second.createdAt, first.createdAt);
    });
  });

  group('DatasetBootstrap — encryption hook (structural only, no real crypto)', () {
    test('throws UnimplementedError when the authoritative marker is encrypted and no verifier was injected', () async {
      final backend = MockSyncBackend();
      final device = await _Device.create(backend); // no passphraseVerifier injected
      addTearDown(device.close);

      await expectLater(
        device.bootstrap.bootstrap(
          encryptionEnabled: true,
          kdfSalt: Uint8List.fromList([1, 2, 3]),
          passphraseCanary: Uint8List.fromList([4, 5, 6]),
        ),
        throwsA(isA<UnimplementedError>()),
      );

      // Must not silently pretend to have verified anything — status stays
      // at 'bootstrapping', not 'ready'.
      expect(await device.bootstrap.currentStatus(), DatasetBootstrapStatus.bootstrapping);
    });

    test('proceeds to ready when the injected verifier returns true', () async {
      final backend = MockSyncBackend();
      final device = await _Device.create(
        backend,
        passphraseVerifier: (marker) async => true,
      );
      addTearDown(device.close);

      final salt = Uint8List.fromList([9, 9, 9]);
      final canary = Uint8List.fromList([7, 7, 7]);
      final marker = await device.bootstrap.bootstrap(
        encryptionEnabled: true,
        kdfSalt: salt,
        passphraseCanary: canary,
      );

      expect(marker.encryptionEnabled, isTrue);
      expect(marker.kdfSalt, salt);
      expect(marker.passphraseCanary, canary);
      expect(await device.bootstrap.currentStatus(), DatasetBootstrapStatus.ready);
    });

    test(
      'throws DatasetPassphraseVerificationFailedException and leaves status at "bootstrapping" '
      'when the injected verifier returns false',
      () async {
        final backend = MockSyncBackend();
        final device = await _Device.create(
          backend,
          passphraseVerifier: (marker) async => false,
        );
        addTearDown(device.close);

        await expectLater(
          device.bootstrap.bootstrap(
            encryptionEnabled: true,
            kdfSalt: Uint8List.fromList([1]),
            passphraseCanary: Uint8List.fromList([2]),
          ),
          throwsA(isA<DatasetPassphraseVerificationFailedException>()),
        );

        expect(await device.bootstrap.currentStatus(), DatasetBootstrapStatus.bootstrapping);
      },
    );

    test('a joining device also runs the verifier against the creator\'s encrypted marker, not its own', () async {
      final backend = MockSyncBackend();
      DatasetInitMarker? seenByVerifier;
      final creator = await _Device.create(backend, passphraseVerifier: (m) async => true);
      addTearDown(creator.close);
      final joiner = await _Device.create(
        backend,
        passphraseVerifier: (m) async {
          seenByVerifier = m;
          return true;
        },
      );
      addTearDown(joiner.close);

      final created = await creator.bootstrap.bootstrap(
        encryptionEnabled: true,
        kdfSalt: Uint8List.fromList([1, 1]),
        passphraseCanary: Uint8List.fromList([2, 2]),
      );
      await joiner.bootstrap.bootstrap(encryptionEnabled: false); // irrelevant — join path ignores this

      expect(seenByVerifier, isNotNull);
      expect(seenByVerifier!.createdByDeviceId, created.createdByDeviceId);
      expect(seenByVerifier!.kdfSalt, created.kdfSalt);
    });
  });
}
