// M3.3 — an encrypted dataset, end to end.
//
// The load-bearing assertions here are the two a user actually cares about:
// two devices sharing a passphrase converge exactly as they do without
// encryption, and a backend holding the dataset holds no readable note.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/cloud_sync_service.dart';
import 'package:note_synapse/services/sync/dataset_bootstrap.dart';
import 'package:note_synapse/services/sync/google_drive_auth_service.dart';
import 'package:note_synapse/services/sync/sync_crypto.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/mock_sync_backend.dart';

void main() {
  const slow = Timeout(Duration(minutes: 5));

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late MockSyncBackend backend;
  late Uint8List salt;

  setUp(() {
    backend = MockSyncBackend();
    salt = SyncCrypto.newSalt();
  });

  Future<DatasetCrypto> keyFor(String passphrase) async => DatasetCrypto(
    await SyncCrypto.deriveFromPassphrase(passphrase: passphrase, salt: salt),
  );

  Future<void> seedNote(DatabaseService svc) async {
    await (await svc.database).insert('notes', {
      'id': 'n1',
      'title': 'SECRET_TITLE_MARKER',
      'content': 'SECRET_BODY_MARKER',
      'type': 'note',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
  }

  Future<String> allCommitBytesAsText() async {
    final buffer = StringBuffer();
    for (final logId in await backend.listDeviceLogIds()) {
      final page = await backend.readCommits(deviceLogId: logId, afterSeq: 0);
      for (final commit in page.commits) {
        buffer.write(String.fromCharCodes(commit.commitBytes));
      }
    }
    return buffer.toString();
  }

  test(
    'two devices sharing a passphrase converge, and the backend holds '
    'nothing readable',
    () async {
      final crypto = await keyFor('correct horse battery staple');
      final a = DatabaseService.createNew();
      final b = DatabaseService.createNew();
      addTearDown(a.close);
      addTearDown(b.close);
      await seedNote(a);

      for (var i = 0; i < 3; i++) {
        await SyncSession(a, crypto: crypto).run(backend);
      }
      for (var i = 0; i < 3; i++) {
        await SyncSession(b, crypto: crypto).run(backend);
      }

      final note = (await (await b.database).query('notes')).single;
      expect(note['title'], 'SECRET_TITLE_MARKER');
      expect(note['content'], 'SECRET_BODY_MARKER');

      final onBackend = await allCommitBytesAsText();
      expect(
        onBackend.contains('SECRET_TITLE_MARKER'),
        isFalse,
        reason:
            'the commit log carries note titles, bodies, tag names and whole '
            'conversations as operation payloads — reading § Architecture 4 '
            'literally as "only blobs are encrypted" would have left a '
            'plaintext copy of the notebook in Drive',
      );
      expect(onBackend.contains('SECRET_BODY_MARKER'), isFalse);
      expect(
        onBackend.contains('"kind"'),
        isFalse,
        reason: 'not even the operation structure is legible',
      );
    },
    timeout: slow,
  );

  test(
    'a device with the WRONG passphrase cannot read the dataset, and fails '
    'as an integrity error rather than silently syncing nothing',
    () async {
      final right = await keyFor('correct horse battery staple');
      final a = DatabaseService.createNew();
      addTearDown(a.close);
      await seedNote(a);
      for (var i = 0; i < 3; i++) {
        await SyncSession(a, crypto: right).run(backend);
      }

      final wrong = DatasetCrypto(
        await SyncCrypto.deriveFromPassphrase(
          passphrase: 'not the passphrase',
          salt: salt,
        ),
      );
      final c = DatabaseService.createNew();
      addTearDown(c.close);

      await expectLater(
        SyncSession(c, crypto: wrong).run(backend),
        throwsA(isA<SyncDecryptionFailedException>()),
        reason:
            'silently pulling nothing would look exactly like an empty '
            'dataset. In production the canary catches this at bootstrap, '
            'before a round is ever attempted; this is the backstop.',
      );
      expect(await (await c.database).query('notes'), isEmpty);
    },
    timeout: slow,
  );

  test(
    'an UNENCRYPTED dataset is byte-identical to the pre-M3.3 engine',
    () async {
      final a = DatabaseService.createNew();
      addTearDown(a.close);
      await seedNote(a);
      for (var i = 0; i < 3; i++) {
        await SyncSession(a).run(backend); // default: plaintext
      }

      final onBackend = await allCommitBytesAsText();
      expect(
        onBackend.contains('SECRET_TITLE_MARKER'),
        isTrue,
        reason:
            'the default must not change: every existing dataset on a real '
            'user\'s Drive was written unencrypted, and a build that started '
            'sealing by default would make all of it unreadable',
      );
      expect(jsonDecode(jsonEncode({'ok': true}))['ok'], isTrue);
    },
    timeout: slow,
  );

  test(
    'the publish intent survives encryption — payloadHash is over the '
    'plaintext, so a resumed push still recognises its own commit',
    () async {
      final crypto = await keyFor('pass');
      final a = DatabaseService.createNew();
      addTearDown(a.close);
      await seedNote(a);

      for (var i = 0; i < 3; i++) {
        await SyncSession(a, crypto: crypto).run(backend);
      }

      final intents = await (await a.database).query(
        'sync_publish_intent',
        where: 'status = ?',
        whereArgs: ['pending'],
      );
      expect(
        intents,
        isEmpty,
        reason:
            'AES-GCM seals the same batch differently every time, so hashing '
            'the SEALED bytes would leave every intent unresolvable and every '
            'push stuck in step 0 forever',
      );
    },
    timeout: slow,
  );

  test(
    'blob bytes are sealed too, addressed by the PLAINTEXT hash, and the '
    'backend holds no readable file',
    () async {
      final crypto = await keyFor('pass');
      final a = DatabaseService.createNew();
      final b = DatabaseService.createNew();
      addTearDown(a.close);
      addTearDown(b.close);

      // A mini app's source is a content-backed blob, so this exercises the
      // blob path without needing file storage.
      final dbA = await a.database;
      await dbA.insert('user_apps', {
        'id': 'app1',
        'uuid': 'uuid-app1',
        'name': 'Counter',
        'description': 'd',
        'steps': '[]',
        'htmlContent': '',
        'type': 'normal',
        'selectedRevisionId': 'rev1',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await dbA.insert('app_revisions', {
        'id': 'rev1',
        'appId': 'app1',
        'revisionNumber': 1,
        'revisionTimestamp': 1000,
        'userPrompt': 'p',
        'aiResponse': 'r',
        'appCode': 'SECRET_APP_SOURCE_MARKER',
      });

      for (var i = 0; i < 3; i++) {
        await SyncSession(a, crypto: crypto).run(backend);
      }
      for (var i = 0; i < 3; i++) {
        await SyncSession(b, crypto: crypto).run(backend);
      }

      expect(
        (await (await b.database).query('app_revisions')).single['appCode'],
        'SECRET_APP_SOURCE_MARKER',
        reason: 'a peer with the passphrase gets the real source back',
      );

      final storedBlobs = backend.debugAllBlobBytes();
      expect(storedBlobs, isNotEmpty);
      for (final bytes in storedBlobs) {
        expect(
          String.fromCharCodes(bytes).contains('SECRET_APP_SOURCE_MARKER'),
          isFalse,
          reason: 'blob bytes are sealed on the backend',
        );
      }
    },
    timeout: slow,
  );

  // ── M3.5: the passphrase, through CloudSyncService ──────────────────────

  test(
    'setUpDataset(passphrase:) creates an encrypted dataset, and a second '
    'device joins it with the same passphrase',
    () async {
      final a = DatabaseService.createNew();
      final b = DatabaseService.createNew();
      addTearDown(a.close);
      addTearDown(b.close);
      await seedNote(a);

      final serviceA = CloudSyncService(
        a,
        authService: _AlwaysConnected(),
        backendFactory: () => backend,
      );
      await serviceA.setUpDataset(passphrase: 'correct horse battery staple');
      await serviceA.syncNow();

      final serviceB = CloudSyncService(
        b,
        authService: _AlwaysConnected(),
        backendFactory: () => backend,
      );
      await serviceB.setUpDataset(passphrase: 'correct horse battery staple');
      for (var i = 0; i < 3; i++) {
        await serviceB.syncNow();
      }

      expect(
        (await (await b.database).query('notes')).single['title'],
        'SECRET_TITLE_MARKER',
      );
      expect(
        (await allCommitBytesAsText()).contains('SECRET_TITLE_MARKER'),
        isFalse,
      );
    },
    timeout: slow,
  );

  test(
    'the WRONG passphrase is refused at setup, by the canary, before any '
    'sync is attempted',
    () async {
      final a = DatabaseService.createNew();
      final b = DatabaseService.createNew();
      addTearDown(a.close);
      addTearDown(b.close);
      await seedNote(a);

      final serviceA = CloudSyncService(
        a,
        authService: _AlwaysConnected(),
        backendFactory: () => backend,
      );
      await serviceA.setUpDataset(passphrase: 'right');
      await serviceA.syncNow();

      final serviceB = CloudSyncService(
        b,
        authService: _AlwaysConnected(),
        backendFactory: () => backend,
      );
      await expectLater(
        serviceB.setUpDataset(passphrase: 'wrong'),
        throwsA(isA<DatasetPassphraseVerificationFailedException>()),
        reason:
            'one clear failure at the moment the user typed it, rather than '
            'an AEAD authentication failure deep inside a pull that the '
            'engine cannot distinguish from tampering. The type is '
            'DatasetBootstrap\'s rather than SyncCrypto\'s because § 11.1 '
            'assigns canary verification to step 4 of the create-or-join '
            'sequence — the crypto layer reports WHY, the bootstrap layer '
            'owns WHEN.',
      );
    },
    timeout: slow,
  );

  test(
    'joining an encrypted dataset with NO passphrase is reported, not '
    'silently treated as plaintext',
    () async {
      final a = DatabaseService.createNew();
      final b = DatabaseService.createNew();
      addTearDown(a.close);
      addTearDown(b.close);

      await CloudSyncService(
        a,
        authService: _AlwaysConnected(),
        backendFactory: () => backend,
      ).setUpDataset(passphrase: 'right');

      await expectLater(
        CloudSyncService(
          b,
          authService: _AlwaysConnected(),
          backendFactory: () => backend,
        ).setUpDataset(),
        throwsA(isA<PassphraseRequiredException>()),
      );
    },
    timeout: slow,
  );
}

/// Reports a live connection so `CloudSyncService` proceeds; nothing else
/// about auth is exercised here.
class _AlwaysConnected extends GoogleDriveAuthService {
  @override
  Future<GoogleDriveConnectionState> connectionState() async =>
      GoogleDriveConnectionState.connected;
}
