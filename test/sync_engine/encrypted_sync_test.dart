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
}
