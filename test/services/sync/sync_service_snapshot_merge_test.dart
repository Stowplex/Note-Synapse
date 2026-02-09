import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity_service.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:note_synapse/services/sync/snapshot_service.dart';
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
  late DatabaseService db;
  late DeviceIdentityService identity;
  late FakeSecureStorage fakeStorage;
  late Directory tempDir;
  late FolderSyncProvider provider;
  late SyncService syncService;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database; // Initialize schema

    fakeStorage = FakeSecureStorage();
    identity = DeviceIdentityService(secureStorage: fakeStorage);

    tempDir = Directory.systemTemp.createTempSync('sync_snapshot_merge_test_');
    provider = FolderSyncProvider(rootPath: tempDir.path);

    syncService = SyncService(db: db, identity: identity);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Helper to initialize a sync root and return the initial snapshot version.
  Future<int> initAndGetVersion() async {
    await syncService.initializeSyncRoot(provider: provider);
    return await identity.getLastSnapshotVersion();
  }

  /// Helper to write a snapshot directly to the provider (simulating another
  /// device compacting) and bump the remote snapshot version.
  Future<void> writeRemoteSnapshot(Snapshot snapshot) async {
    final jsonStr = jsonEncode(snapshot.toJson());
    await provider.writeFile(
      'snapshots/latest.json',
      Uint8List.fromList(utf8.encode(jsonStr)),
    );

    // Bump remote version
    final versionService = SnapshotVersionService(provider: provider);
    await versionService.incrementVersion();
  }

  group('Snapshot merge during sync', () {
    test('no merge when local and remote versions match', () async {
      await initAndGetVersion();

      // Sync should succeed with no merge activity
      final result = await syncService.sync();

      expect(result.success, isTrue);
      // Filter out attachment sync warnings (path_provider unavailable in test)
      final nonAttachmentWarnings = result.warnings
          .where((w) => !w.contains('Attachment sync failed'))
          .toList();
      expect(nonAttachmentWarnings, isEmpty);

      // Local version unchanged
      final localVersion = await identity.getLastSnapshotVersion();
      final remoteVersion =
          await SnapshotVersionService(provider: provider).readVersion();
      expect(localVersion, remoteVersion);
    });

    test('merge inserts new rows from remote snapshot', () async {
      await initAndGetVersion();

      final now = DateTime.now().millisecondsSinceEpoch;

      // Write a remote snapshot that has a note not in local DB
      final snapshot = Snapshot(
        schemaVersion: DatabaseService.DATABASE_VERSION,
        timestamp: DateTime.now().toUtc(),
        tables: {
          'notes': [
            {
              'id': 'remote-note-1',
              'title': 'Note From Remote',
              'content': 'Remote content',
              'type': 'note',
              'createdAt': now,
              'updatedAt': now,
              'pinned': 0,
              'isArchived': 0,
            },
          ],
          'tags': [
            {
              'id': 'remote-tag-1',
              'name': 'Remote Tag',
              'color': '#00FF00',
              'createdAt': now,
              'usageCount': 0,
            },
          ],
        },
        referencedAttachments: [],
      );

      await writeRemoteSnapshot(snapshot);

      // Sync should merge the snapshot
      final result = await syncService.sync();

      expect(result.success, isTrue);

      // Verify the remote note now exists in local DB
      final database = await db.database;
      final notes = await database.query(
        'notes',
        where: "id = ?",
        whereArgs: ['remote-note-1'],
      );
      expect(notes.length, 1);
      expect(notes.first['title'], 'Note From Remote');

      // Verify the remote tag exists
      final tags = await database.query(
        'tags',
        where: "id = ?",
        whereArgs: ['remote-tag-1'],
      );
      expect(tags.length, 1);
      expect(tags.first['name'], 'Remote Tag');

      // Verify local snapshot version updated
      final localVersion = await identity.getLastSnapshotVersion();
      final remoteVersion =
          await SnapshotVersionService(provider: provider).readVersion();
      expect(localVersion, remoteVersion);
    });

    test('merge uses timestamp — remote newer wins', () async {
      await initAndGetVersion();

      // Insert a local note with updatedAt=100
      final database = await db.database;
      await database.insert('notes', {
        'id': 'shared-note',
        'title': 'Local Title',
        'content': 'Local content',
        'type': 'note',
        'createdAt': 100,
        'updatedAt': 100,
        'pinned': 0,
        'isArchived': 0,
      });

      // Write a remote snapshot with the same note but updatedAt=200
      final snapshot = Snapshot(
        schemaVersion: DatabaseService.DATABASE_VERSION,
        timestamp: DateTime.now().toUtc(),
        tables: {
          'notes': [
            {
              'id': 'shared-note',
              'title': 'Remote Title (Newer)',
              'content': 'Remote content',
              'type': 'note',
              'createdAt': 100,
              'updatedAt': 200,
              'pinned': 1,
              'isArchived': 0,
            },
          ],
        },
        referencedAttachments: [],
      );

      await writeRemoteSnapshot(snapshot);

      final result = await syncService.sync();
      expect(result.success, isTrue);

      // Remote should win because updatedAt=200 > 100
      final refreshedDb = await db.database;
      final notes = await refreshedDb.query(
        'notes',
        where: "id = ?",
        whereArgs: ['shared-note'],
      );
      expect(notes.length, 1);
      expect(notes.first['title'], 'Remote Title (Newer)');
      expect(notes.first['updatedAt'], 200);
    });

    test('merge preserves newer local data', () async {
      await initAndGetVersion();

      // Insert a local note with updatedAt=200 (newer)
      final database = await db.database;
      await database.insert('notes', {
        'id': 'shared-note-2',
        'title': 'Local Title (Newer)',
        'content': 'Local content',
        'type': 'note',
        'createdAt': 100,
        'updatedAt': 200,
        'pinned': 0,
        'isArchived': 0,
      });

      // Write a remote snapshot with updatedAt=100 (older)
      final snapshot = Snapshot(
        schemaVersion: DatabaseService.DATABASE_VERSION,
        timestamp: DateTime.now().toUtc(),
        tables: {
          'notes': [
            {
              'id': 'shared-note-2',
              'title': 'Remote Title (Older)',
              'content': 'Remote content',
              'type': 'note',
              'createdAt': 100,
              'updatedAt': 100,
              'pinned': 1,
              'isArchived': 0,
            },
          ],
        },
        referencedAttachments: [],
      );

      await writeRemoteSnapshot(snapshot);

      final result = await syncService.sync();
      expect(result.success, isTrue);

      // Local should win because updatedAt=200 > 100
      final refreshedDb = await db.database;
      final notes = await refreshedDb.query(
        'notes',
        where: "id = ?",
        whereArgs: ['shared-note-2'],
      );
      expect(notes.length, 1);
      expect(notes.first['title'], 'Local Title (Newer)');
      expect(notes.first['updatedAt'], 200);
    });

    test('junction tables use INSERT OR IGNORE — no crash on duplicate',
        () async {
      await initAndGetVersion();

      final database = await db.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Create a note and a tag locally
      await database.insert('notes', {
        'id': 'junction-note',
        'title': 'Junction Test Note',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await database.insert('tags', {
        'id': 'junction-tag',
        'name': 'Junction Tag',
        'color': '#FF0000',
        'createdAt': now,
        'usageCount': 0,
      });
      await database.insert('note_tags', {
        'noteId': 'junction-note',
        'tagId': 'junction-tag',
      });

      // Write a remote snapshot that also has this note_tag
      final snapshot = Snapshot(
        schemaVersion: DatabaseService.DATABASE_VERSION,
        timestamp: DateTime.now().toUtc(),
        tables: {
          'notes': [
            {
              'id': 'junction-note',
              'title': 'Junction Test Note',
              'content': 'Content',
              'type': 'note',
              'createdAt': now,
              'updatedAt': now,
              'pinned': 0,
              'isArchived': 0,
            },
          ],
          'tags': [
            {
              'id': 'junction-tag',
              'name': 'Junction Tag',
              'color': '#FF0000',
              'createdAt': now,
              'usageCount': 0,
            },
          ],
          'note_tags': [
            {
              'noteId': 'junction-note',
              'tagId': 'junction-tag',
            },
          ],
        },
        referencedAttachments: [],
      );

      await writeRemoteSnapshot(snapshot);

      // Should not crash — duplicate junction row handled gracefully
      final result = await syncService.sync();
      expect(result.success, isTrue);

      // Verify only one note_tag row exists (no duplicate)
      final refreshedDb = await db.database;
      final noteTags = await refreshedDb.query(
        'note_tags',
        where: "noteId = ? AND tagId = ?",
        whereArgs: ['junction-note', 'junction-tag'],
      );
      expect(noteTags.length, 1);
    });

    test('handles missing snapshot file gracefully', () async {
      await initAndGetVersion();

      // Bump remote version WITHOUT writing a snapshot file
      // First delete the existing snapshot
      await provider.deleteFile('snapshots/latest.json');
      final versionService = SnapshotVersionService(provider: provider);
      await versionService.incrementVersion();

      final result = await syncService.sync();
      expect(result.success, isTrue);
      expect(
        result.warnings,
        contains('Snapshot version incremented but no snapshot found'),
      );

      // Local version should still be updated
      final localVersion = await identity.getLastSnapshotVersion();
      final remoteVersion = await versionService.readVersion();
      expect(localVersion, remoteVersion);
    });

    test('merge inserts new rows while preserving existing local rows',
        () async {
      await initAndGetVersion();

      final database = await db.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insert a local-only note
      await database.insert('notes', {
        'id': 'local-only-note',
        'title': 'Local Only',
        'content': 'This note exists only locally',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Write a remote snapshot with a different note (not the local one)
      final snapshot = Snapshot(
        schemaVersion: DatabaseService.DATABASE_VERSION,
        timestamp: DateTime.now().toUtc(),
        tables: {
          'notes': [
            {
              'id': 'remote-only-note',
              'title': 'Remote Only',
              'content': 'This note exists only remotely',
              'type': 'note',
              'createdAt': now,
              'updatedAt': now,
              'pinned': 0,
              'isArchived': 0,
            },
          ],
        },
        referencedAttachments: [],
      );

      await writeRemoteSnapshot(snapshot);

      final result = await syncService.sync();
      expect(result.success, isTrue);

      // Both notes should exist
      final refreshedDb = await db.database;
      final localNote = await refreshedDb.query(
        'notes',
        where: "id = ?",
        whereArgs: ['local-only-note'],
      );
      expect(localNote.length, 1);
      expect(localNote.first['title'], 'Local Only');

      final remoteNote = await refreshedDb.query(
        'notes',
        where: "id = ?",
        whereArgs: ['remote-only-note'],
      );
      expect(remoteNote.length, 1);
      expect(remoteNote.first['title'], 'Remote Only');
    });

    test('conversations table also uses timestamp merge', () async {
      await initAndGetVersion();

      final database = await db.database;

      // Insert a local conversation with updatedAt=100
      await database.insert('conversations', {
        'id': 'conv-1',
        'title': 'Local Conv Title',
        'noteIds': '[]',
        'createdAt': 100,
        'updatedAt': 100,
        'isArchived': 0,
      });

      // Write a remote snapshot with same conversation but updatedAt=200
      final snapshot = Snapshot(
        schemaVersion: DatabaseService.DATABASE_VERSION,
        timestamp: DateTime.now().toUtc(),
        tables: {
          'conversations': [
            {
              'id': 'conv-1',
              'title': 'Remote Conv Title (Newer)',
              'noteIds': '[]',
              'createdAt': 100,
              'updatedAt': 200,
              'isArchived': 0,
            },
          ],
        },
        referencedAttachments: [],
      );

      await writeRemoteSnapshot(snapshot);

      final result = await syncService.sync();
      expect(result.success, isTrue);

      final refreshedDb = await db.database;
      final convs = await refreshedDb.query(
        'conversations',
        where: "id = ?",
        whereArgs: ['conv-1'],
      );
      expect(convs.length, 1);
      expect(convs.first['title'], 'Remote Conv Title (Newer)');
      expect(convs.first['updatedAt'], 200);
    });
  });
}
