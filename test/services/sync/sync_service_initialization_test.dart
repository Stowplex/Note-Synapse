import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

import 'package:note_synapse/models/sync_config.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity_service.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:note_synapse/services/sync/sync_service.dart';
import 'package:note_synapse/services/sync/sync_encryption_service.dart';

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
  }) async => _store[key];

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

  late DatabaseService db;
  late DeviceIdentityService identity;
  late FakeSecureStorage fakeStorage;
  late Directory tempDir;
  late Directory appDocDir;
  late FolderSyncProvider provider;
  late SyncService syncService;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    // Mock path_provider
    tempDir = Directory.systemTemp.createTempSync('sync_init_test_');
    appDocDir = Directory('${tempDir.path}/app_docs')..createSync();

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

    db = DatabaseService.createNew();
    await db.database; // Initialize schema

    fakeStorage = FakeSecureStorage();
    identity = DeviceIdentityService(secureStorage: fakeStorage);

    provider = FolderSyncProvider(rootPath: tempDir.path);
    syncService = SyncService(db: db, identity: identity);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  test('initializeSyncRoot generates SYNC_SPEC.md', () async {
    await syncService.initializeSyncRoot(provider: provider);

    // Verify SYNC_SPEC.md exists
    expect(await provider.exists('SYNC_SPEC.md'), isTrue);
    final specContent = utf8.decode(await provider.readFile('SYNC_SPEC.md'));
    expect(specContent, contains('# Note-Synapse Sync Specification'));
  });

  test('initializeSyncRoot uploads attachments', () async {
    // Setup: Create a dummy attachment file in appDocDir
    final attachmentName = 'test-attachment.txt';
    final attachmentPath = '${appDocDir.path}/attachments';
    Directory(attachmentPath).createSync(recursive: true);
    File(
      '$attachmentPath/test-attachment-uuid.txt',
    ).writeAsStringSync('Hello World');

    // Setup: Insert dummy note
    final database = await db.database;
    await database.insert('notes', {
      'id': 'note-1',
      'title': 'Test Note',
      'content': 'Content',
      'type': 'note',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'pinned': 0,
      'isArchived': 0,
    });

    // Setup: Insert attachment record into DB
    final relativePath = 'attachments/test-attachment-uuid.txt';
    await database.insert('attachments', {
      'id': 'att-1',
      'noteId': 'note-1',
      'filePath': relativePath,
      'fileName': attachmentName,
      'fileType': 'txt',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    // Run initialization
    await syncService.initializeSyncRoot(provider: provider);

    // Verify attachment file exists in provider
    expect(await provider.exists(relativePath), isTrue);
    final remoteContent = utf8.decode(await provider.readFile(relativePath));
    expect(remoteContent, 'Hello World'); // No encryption in this test case
  });

  test(
    'initializeSyncRoot uploads encrypted attachments when encryption is enabled',
    () async {
      // Setup: Create a dummy attachment file
      final attachmentName = 'test-encrypted.txt';
      final attachmentPath = '${appDocDir.path}/attachments';
      Directory(attachmentPath).createSync(recursive: true);
      File(
        '$attachmentPath/test-encrypted-uuid.txt',
      ).writeAsStringSync('Secret Data');

      // Setup: Insert dummy note
      final database = await db.database;
      await database.insert('notes', {
        'id': 'note-1',
        'title': 'Test Note',
        'content': 'Content',
        'type': 'note',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'pinned': 0,
        'isArchived': 0,
      });

      // Setup: Insert attachment record into DB
      final relativePath = 'attachments/test-encrypted-uuid.txt';
      await database.insert('attachments', {
        'id': 'att-enc-1',
        'noteId': 'note-1',
        'filePath': relativePath,
        'fileName': attachmentName,
        'fileType': 'txt',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });

      // Run initialization with passphrase
      await syncService.initializeSyncRoot(
        provider: provider,
        passphrase: 'password123',
      );

      // Verify attachment file exists in provider
      expect(await provider.exists(relativePath), isTrue);
      final remoteBytes = await provider.readFile(relativePath);

      // Should NOT be plain text "Secret Data"
      try {
        final text = utf8.decode(remoteBytes);
        if (text == 'Secret Data') {
          fail('Attachment was stored as plain text');
        }
      } catch (_) {
        // utf8 decode failing is a good sign (binary/encrypted data)
      }

      // Verify we can decrypt it
      final salt = (await syncService.readSyncConfig()).salt;
      final encryption = await SyncEncryptionService.create(
        passphrase: 'password123',
        cipherId: 'aes-256-gcm',
        salt: salt,
      );
      final decryptedBytes = await encryption.decrypt(remoteBytes);
      expect(utf8.decode(decryptedBytes), 'Secret Data');
    },
  );
}
