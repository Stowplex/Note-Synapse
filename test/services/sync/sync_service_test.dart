import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/sync_config.dart';
import 'package:note_synapse/models/sync_operation.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity_service.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:note_synapse/services/sync/sync_service.dart';

/// Fake secure storage for testing DeviceIdentityService.
class FakeSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }
}

void main() {
  late DatabaseService db;
  late DeviceIdentityService identity;
  late FakeSecureStorage fakeStorage;
  late Directory tempDir;
  late FolderSyncProvider provider;
  late SyncService syncService;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database; // Initialize schema

    fakeStorage = FakeSecureStorage();
    identity = DeviceIdentityService(secureStorage: fakeStorage);

    tempDir = Directory.systemTemp.createTempSync('sync_service_test_');
    provider = FolderSyncProvider(rootPath: tempDir.path);

    syncService = SyncService(db: db, identity: identity);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('initializeSyncRoot', () {
    test('creates correct file structure', () async {
      await syncService.initializeSyncRoot(provider: provider);

      // Verify sync-config.json exists and is valid JSON
      expect(await provider.exists('sync-config.json'), isTrue);
      final configBytes = await provider.readFile('sync-config.json');
      final configJson =
          jsonDecode(utf8.decode(configBytes)) as Map<String, dynamic>;
      final config = SyncConfig.fromJson(configJson);
      expect(config.specVersion, 1);
      expect(config.schemaVersion, DatabaseService.DATABASE_VERSION);

      // Verify device-registry.json exists
      expect(await provider.exists('meta/device-registry.json'), isTrue);
      final registryBytes =
          await provider.readFile('meta/device-registry.json');
      final registryJson =
          jsonDecode(utf8.decode(registryBytes)) as Map<String, dynamic>;
      final registry = DeviceRegistry.fromJson(registryJson);
      final deviceId = await identity.getDeviceId();
      expect(registry.devices.containsKey(deviceId), isTrue);

      // Verify directory .keep files
      expect(await provider.exists('oplog/.keep'), isTrue);
      expect(await provider.exists('snapshots/.keep'), isTrue);
      expect(await provider.exists('attachments/.keep'), isTrue);
      expect(await provider.exists('apps/.keep'), isTrue);

      // Verify initial snapshot
      expect(await provider.exists('snapshots/latest.json'), isTrue);
    });

    test('without passphrase creates unencrypted config', () async {
      await syncService.initializeSyncRoot(provider: provider);

      final configBytes = await provider.readFile('sync-config.json');
      final configJson =
          jsonDecode(utf8.decode(configBytes)) as Map<String, dynamic>;
      final config = SyncConfig.fromJson(configJson);

      expect(config.encryption, 'none');
      expect(config.hmac, isNull);
      expect(config.isEncrypted, isFalse);
    });

    test('with passphrase creates encrypted config', () async {
      await syncService.initializeSyncRoot(
        provider: provider,
        passphrase: 'my-secret-passphrase',
        kdfMemory: 1024,
        kdfIterations: 1,
        kdfParallelism: 1,
      );

      final configBytes = await provider.readFile('sync-config.json');
      final configJson =
          jsonDecode(utf8.decode(configBytes)) as Map<String, dynamic>;
      final config = SyncConfig.fromJson(configJson);

      expect(config.encryption, isNot('none'));
      expect(config.hmac, isNotNull);
      expect(config.hmac!.isNotEmpty, isTrue);
      expect(config.isEncrypted, isTrue);
    });
  });

  group('sync', () {
    test('with no remote changes performs push only', () async {
      // Initialize sync root
      await syncService.initializeSyncRoot(provider: provider);

      // Insert local data with sync triggers enabled
      final database = await db.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      await database.insert('notes', {
        'id': 'note-push-1',
        'title': 'Push Test Note',
        'content': 'Content to push',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Sync should push the local change
      final result = await syncService.sync();

      expect(result.success, isTrue);
      expect(result.opsPushed, greaterThan(0));
      expect(result.opsPulled, 0);

      // Verify oplog file was written
      final oplogFiles = await provider.listFiles('oplog');
      // Filter out .keep file
      final jsonFiles =
          oplogFiles.where((f) => f.path.endsWith('.json')).toList();
      expect(jsonFiles.length, greaterThan(0));
    });

    test('pulls remote changes from another device', () async {
      // Initialize sync root
      await syncService.initializeSyncRoot(provider: provider);

      // Write an oplog file from a "remote device"
      final remoteDeviceId = 'remote-device-abc';
      final remoteOps = [
        SyncOperation(
          id: 'op-1',
          deviceId: remoteDeviceId,
          sequence: 1,
          timestamp: DateTime.now().toUtc(),
          table: 'notes',
          rowId: 'note-remote-1',
          action: SyncAction.insert,
          fields: {
            'id': SyncFieldValue(value: 'note-remote-1', minVersion: 1),
            'title': SyncFieldValue(value: 'Remote Note', minVersion: 1),
            'content': SyncFieldValue(value: 'From remote', minVersion: 1),
            'type': SyncFieldValue(value: 'note', minVersion: 1),
            'createdAt': SyncFieldValue(
                value: DateTime.now().millisecondsSinceEpoch, minVersion: 1),
            'updatedAt': SyncFieldValue(
                value: DateTime.now().millisecondsSinceEpoch, minVersion: 1),
            'pinned': SyncFieldValue(value: 0, minVersion: 1),
            'isArchived': SyncFieldValue(value: 0, minVersion: 1),
          },
          schemaVersion: DatabaseService.DATABASE_VERSION,
        ),
      ];

      final jsonBytes = utf8.encode(
        jsonEncode(remoteOps.map((op) => op.toJson()).toList()),
      );
      await provider.writeFile(
        'oplog/$remoteDeviceId-1-1.json',
        Uint8List.fromList(jsonBytes),
      );

      // Update device registry to include the remote device
      // Note: lastSequence is 0 (default) so the pull will see the new oplog file
      final registryBytes =
          await provider.readFile('meta/device-registry.json');
      final registryJson =
          jsonDecode(utf8.decode(registryBytes)) as Map<String, dynamic>;
      final registry = DeviceRegistry.fromJson(registryJson);
      final updatedRegistry = registry.registerDevice(
        remoteDeviceId,
        schemaVersion: DatabaseService.DATABASE_VERSION,
      );
      await provider.writeFile(
        'meta/device-registry.json',
        Uint8List.fromList(
            utf8.encode(jsonEncode(updatedRegistry.toJson()))),
      );

      // Sync should pull the remote change
      final result = await syncService.sync();

      expect(result.success, isTrue);
      expect(result.opsPulled, greaterThan(0));

      // Verify the remote note was merged into local DB
      final database = await db.database;
      final notes = await database
          .query('notes', where: "id = ?", whereArgs: ['note-remote-1']);
      expect(notes.length, 1);
      expect(notes.first['title'], 'Remote Note');
    });

    test('handles empty sync root gracefully', () async {
      // Configure without initializing (simulate empty remote)
      syncService.configure(provider: provider);

      // Sync should not crash
      final result = await syncService.sync();

      expect(result.success, isTrue);
      expect(result.opsPulled, 0);
      expect(result.opsPushed, 0);
    });
  });

  group('resetSyncFromThisDevice', () {
    test('replaces remote data with local state', () async {
      // Initialize sync root
      await syncService.initializeSyncRoot(provider: provider);

      // Insert local data
      final database = await db.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      await database.insert('notes', {
        'id': 'note-reset-1',
        'title': 'Reset Note',
        'content': 'Content after reset',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Write some fake oplog files from another device
      await provider.writeFile(
        'oplog/other-device-1-5.json',
        Uint8List.fromList(utf8.encode('[]')),
      );
      await provider.writeFile(
        'oplog/other-device-6-10.json',
        Uint8List.fromList(utf8.encode('[]')),
      );

      // Perform reset
      await syncService.resetSyncFromThisDevice();

      // Verify oplog files are cleared (except .keep)
      final oplogFiles = await provider.listFiles('oplog');
      final jsonFiles =
          oplogFiles.where((f) => f.path.endsWith('.json')).toList();
      expect(jsonFiles, isEmpty);

      // Verify snapshot exists with our data
      expect(await provider.exists('snapshots/latest.json'), isTrue);

      // Verify device registry only has this device with sequence 0
      final registryBytes =
          await provider.readFile('meta/device-registry.json');
      final registryJson =
          jsonDecode(utf8.decode(registryBytes)) as Map<String, dynamic>;
      final registry = DeviceRegistry.fromJson(registryJson);
      final deviceId = await identity.getDeviceId();
      expect(registry.devices.length, 1);
      expect(registry.devices.containsKey(deviceId), isTrue);
      expect(registry.devices[deviceId]!.lastSequence, 0);
    });
  });

  group('configure', () {
    test('sets provider for subsequent sync calls', () async {
      syncService.configure(provider: provider);

      // Should be able to sync without crashing
      final result = await syncService.sync();
      expect(result.success, isTrue);
    });
  });
}
