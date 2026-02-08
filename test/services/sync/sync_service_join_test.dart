import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity_service.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:note_synapse/services/sync/snapshot_version_service.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- Device A (initializer) ---
  late DatabaseService dbA;
  late DeviceIdentityService identityA;
  late FakeSecureStorage storageA;
  late SyncService syncServiceA;

  // --- Device B (joiner) ---
  late DatabaseService dbB;
  late DeviceIdentityService identityB;
  late FakeSecureStorage storageB;
  late SyncService syncServiceB;

  // --- Shared ---
  late Directory tempDir;
  late Directory appDocDir;
  late FolderSyncProvider provider;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('sync_join_test_');
    appDocDir = Directory('${tempDir.path}/app_docs')..createSync();

    // Mock path_provider for both devices (attachment uploads need it)
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            if (methodCall.method == 'getApplicationDocumentsDirectory') {
              return appDocDir.path;
            }
            return null;
          },
        );

    // Shared remote storage
    provider = FolderSyncProvider(rootPath: '${tempDir.path}/remote');
    Directory('${tempDir.path}/remote').createSync();

    // Device A
    dbA = DatabaseService.createNew();
    await dbA.database;
    storageA = FakeSecureStorage();
    identityA = DeviceIdentityService(secureStorage: storageA);
    syncServiceA = SyncService(db: dbA, identity: identityA);

    // Device B
    dbB = DatabaseService.createNew();
    await dbB.database;
    storageB = FakeSecureStorage();
    identityB = DeviceIdentityService(secureStorage: storageB);
    syncServiceB = SyncService(db: dbB, identity: identityB);
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  /// Helper: insert notes into a DatabaseService.
  Future<void> insertNotes(
      DatabaseService db, List<Map<String, dynamic>> notes) async {
    final database = await db.database;
    for (final note in notes) {
      await database.insert('notes', note);
    }
  }

  /// Helper: insert tags into a DatabaseService.
  Future<void> insertTags(
      DatabaseService db, List<Map<String, dynamic>> tags) async {
    final database = await db.database;
    for (final tag in tags) {
      await database.insert('tags', tag);
    }
  }

  /// Helper: create a note map.
  Map<String, dynamic> makeNote(String id, String title) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': id,
      'title': title,
      'content': 'Content of $title',
      'type': 'note',
      'createdAt': now,
      'updatedAt': now,
      'pinned': 0,
      'isArchived': 0,
    };
  }

  /// Helper: create a tag map.
  Map<String, dynamic> makeTag(String id, String name) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': id,
      'name': name,
      'color': '#FF0000',
      'createdAt': now,
      'usageCount': 0,
    };
  }

  group('joinSyncRoot', () {
    test('merges both databases — B gets A\'s and its own data', () async {
      // Device A: create notes 1-3 and initialize sync root
      await insertNotes(dbA, [
        makeNote('note-a1', 'A Note 1'),
        makeNote('note-a2', 'A Note 2'),
        makeNote('note-a3', 'A Note 3'),
      ]);
      await syncServiceA.initializeSyncRoot(provider: provider);

      // Device B: create notes 4-6
      await insertNotes(dbB, [
        makeNote('note-b4', 'B Note 4'),
        makeNote('note-b5', 'B Note 5'),
        makeNote('note-b6', 'B Note 6'),
      ]);

      // Device B joins the sync root
      await syncServiceB.joinSyncRoot(provider: provider);

      // Verify B's DB has all 6 notes
      final database = await dbB.database;
      final notes = await database.query('notes', orderBy: 'id');
      final noteIds = notes.map((n) => n['id'] as String).toSet();

      expect(noteIds, contains('note-a1'));
      expect(noteIds, contains('note-a2'));
      expect(noteIds, contains('note-a3'));
      expect(noteIds, contains('note-b4'));
      expect(noteIds, contains('note-b5'));
      expect(noteIds, contains('note-b6'));
      expect(notes.length, 6);
    });

    test('pushes B\'s unique data as oplog', () async {
      // Device A: create 1 note and initialize
      await insertNotes(dbA, [makeNote('note-a1', 'A Note 1')]);
      await syncServiceA.initializeSyncRoot(provider: provider);

      // Device B: create 1 note
      await insertNotes(dbB, [makeNote('note-b1', 'B Note 1')]);

      // Join
      await syncServiceB.joinSyncRoot(provider: provider);

      // Verify oplog directory has files (B pushed its data)
      // Oplog files use .json extension: oplog/{deviceId}-{seqStart}-{seqEnd}.json
      final oplogDir = Directory('${tempDir.path}/remote/oplog');
      final oplogFiles =
          oplogDir.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.json'),
          );
      expect(oplogFiles, isNotEmpty,
          reason: 'B should have pushed oplog files');
    });

    test('increments snapshot version after join', () async {
      await insertNotes(dbA, [makeNote('note-a1', 'A Note 1')]);
      await syncServiceA.initializeSyncRoot(provider: provider);

      // Get version after A's initialization
      final versionService = SnapshotVersionService(provider: provider);
      final versionAfterInit = await versionService.readVersion();

      // B joins
      await insertNotes(dbB, [makeNote('note-b1', 'B Note 1')]);
      await syncServiceB.joinSyncRoot(provider: provider);

      // Version should have increased
      final versionAfterJoin = await versionService.readVersion();
      expect(versionAfterJoin, greaterThan(versionAfterInit));
    });

    test('duplicate rows handled gracefully — same tag on both devices',
        () async {
      // Both devices have the same tag
      final sharedTag = makeTag('shared-tag', 'Common Tag');

      await insertTags(dbA, [sharedTag]);
      await syncServiceA.initializeSyncRoot(provider: provider);

      await insertTags(dbB, [sharedTag]);

      // Should not throw
      await syncServiceB.joinSyncRoot(provider: provider);

      // Verify only one tag row
      final database = await dbB.database;
      final tags = await database.query(
        'tags',
        where: "id = ?",
        whereArgs: ['shared-tag'],
      );
      expect(tags.length, 1);
      expect(tags.first['name'], 'Common Tag');
    });

    test('registers joining device in device registry', () async {
      await syncServiceA.initializeSyncRoot(provider: provider);
      final deviceIdA = await identityA.getDeviceId();

      await syncServiceB.joinSyncRoot(provider: provider);
      final deviceIdB = await identityB.getDeviceId();

      // Read registry from remote
      final registryBytes =
          await provider.readFile('meta/device-registry.json');
      final registryJson =
          jsonDecode(utf8.decode(registryBytes)) as Map<String, dynamic>;
      final devices = registryJson['devices'] as Map<String, dynamic>;

      expect(devices, contains(deviceIdA));
      expect(devices, contains(deviceIdB));
    });

    test('joinSyncRoot with encrypted sync root', () async {
      const passphrase = 'test-password-123';

      // A initializes encrypted
      await insertNotes(dbA, [makeNote('note-enc-a', 'Encrypted A')]);
      await syncServiceA.initializeSyncRoot(
        provider: provider,
        passphrase: passphrase,
        kdfMemory: 1024,
        kdfIterations: 1,
        kdfParallelism: 1,
      );

      // B joins with same passphrase
      await insertNotes(dbB, [makeNote('note-enc-b', 'Encrypted B')]);
      await syncServiceB.joinSyncRoot(
        provider: provider,
        passphrase: passphrase,
      );

      // B should have both notes
      final database = await dbB.database;
      final notes = await database.query('notes', orderBy: 'id');
      final noteIds = notes.map((n) => n['id'] as String).toSet();

      expect(noteIds, contains('note-enc-a'));
      expect(noteIds, contains('note-enc-b'));
    });

    test('joinSyncRoot fails with wrong passphrase', () async {
      // A initializes encrypted
      await syncServiceA.initializeSyncRoot(
        provider: provider,
        passphrase: 'correct-password',
        kdfMemory: 1024,
        kdfIterations: 1,
        kdfParallelism: 1,
      );

      // B tries to join with wrong passphrase
      expect(
        () => syncServiceB.joinSyncRoot(
          provider: provider,
          passphrase: 'wrong-password',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Invalid passphrase'),
        )),
      );
    });

    test('joinSyncRoot fails when encrypted root but no passphrase', () async {
      await syncServiceA.initializeSyncRoot(
        provider: provider,
        passphrase: 'some-password',
        kdfMemory: 1024,
        kdfIterations: 1,
        kdfParallelism: 1,
      );

      expect(
        () => syncServiceB.joinSyncRoot(provider: provider),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('no passphrase provided'),
        )),
      );
    });

    test('joinSyncRoot merges tags and note_tags correctly', () async {
      // A has a note with a tag
      await insertNotes(dbA, [makeNote('note-a', 'A Note')]);
      await insertTags(dbA, [makeTag('tag-a', 'Tag A')]);
      final dbAHandle = await dbA.database;
      await dbAHandle.insert('note_tags', {
        'noteId': 'note-a',
        'tagId': 'tag-a',
      });
      await syncServiceA.initializeSyncRoot(provider: provider);

      // B has a different note with a different tag
      await insertNotes(dbB, [makeNote('note-b', 'B Note')]);
      await insertTags(dbB, [makeTag('tag-b', 'Tag B')]);
      final dbBHandle = await dbB.database;
      await dbBHandle.insert('note_tags', {
        'noteId': 'note-b',
        'tagId': 'tag-b',
      });

      await syncServiceB.joinSyncRoot(provider: provider);

      // B should have both notes, both tags, and both note_tags
      final database = await dbB.database;
      final notes = await database.query('notes');
      expect(notes.length, 2);

      final tags = await database.query('tags');
      expect(tags.length, 2);

      final noteTags = await database.query('note_tags');
      expect(noteTags.length, 2);
    });
  });

  group('syncRootExists', () {
    test('returns false when no sync root', () async {
      final emptyDir = Directory('${tempDir.path}/empty')..createSync();
      final emptyProvider = FolderSyncProvider(rootPath: emptyDir.path);
      expect(await syncServiceA.syncRootExists(emptyProvider), isFalse);
    });

    test('returns true after initialization', () async {
      await syncServiceA.initializeSyncRoot(provider: provider);
      expect(await syncServiceA.syncRootExists(provider), isTrue);
    });
  });

  group('joinSyncRoot configures service', () {
    test('service is configured after join', () async {
      await syncServiceA.initializeSyncRoot(provider: provider);

      expect(syncServiceB.isConfigured, isFalse);
      await syncServiceB.joinSyncRoot(provider: provider);
      expect(syncServiceB.isConfigured, isTrue);
    });

    test('B can sync after joining', () async {
      await insertNotes(dbA, [makeNote('note-a1', 'A Note')]);
      await syncServiceA.initializeSyncRoot(provider: provider);

      await syncServiceB.joinSyncRoot(provider: provider);

      // B should be able to run a regular sync without errors
      final result = await syncServiceB.sync();
      expect(result.success, isTrue);
    });
  });
}
