// M3.1 — content-addressed blob transport for attachments.
//
// The load-bearing test here is not "a hash was computed". It is that a
// SECOND DEVICE ENDS UP WITH THE BYTES: M2.14 made the attachment row
// round-trip and left the file behind, so every attachment a user owned
// rendered as "file not found" on their other device. That is the whole
// point of the milestone, and the test that would fail if any single link
// in the chain (mint -> stamp -> upload -> commit -> pull -> materialize ->
// fetch) were missing.
//
// Every device here uses a `_TempDirResolver` rather than the production
// `AppDocumentsBlobFileResolver`, so the phase is driven against real files
// on disk without `path_provider` — the resolver interface exists for
// exactly this.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/blob_gc.dart';
import 'package:note_synapse/services/sync/blob_sync.dart';
import 'package:note_synapse/services/sync/sync_session.dart';
import 'package:note_synapse/services/sync/sync_health.dart';
import 'package:note_synapse/services/sync/sync_crypto.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';

import '../sync_backend/mock_sync_backend.dart';

/// Resolves every stored path under one temp directory, so two "devices" in
/// the same test process have genuinely separate file storage.
class _TempDirResolver implements BlobFileResolver {
  _TempDirResolver(this.root);
  final Directory root;

  @override
  Future<String> absolutePath(String storedPath, bool isRelative) async =>
      isRelative ? '${root.path}/$storedPath' : storedPath;
}

class _Device {
  _Device(this.root, {DatasetCrypto crypto = const DatasetCrypto.plaintext()})
    : databaseService = DatabaseService.createNew() {
    blobs = BlobSyncPhase(
      databaseService,
      resolver: _TempDirResolver(root),
      crypto: crypto,
    );
    session = SyncSession(databaseService, blobs: blobs, crypto: crypto);
  }

  final Directory root;
  final DatabaseService databaseService;
  late final BlobSyncPhase blobs;
  late final SyncSession session;

  Future<Database> get db => databaseService.database;
  Future<void> close() => databaseService.close();
}

class _DuringDownloadBackend extends MockSyncBackend {
  Future<void> Function()? duringDownload;

  @override
  Future<Stream<List<int>>> downloadBlob(
    String contentHash, {
    bool sealed = false,
  }) async {
    final callback = duringDownload;
    duringDownload = null;
    if (callback != null) await callback();
    return super.downloadBlob(contentHash, sealed: sealed);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Directory tmp;
  late MockSyncBackend backend;
  late _Device a;
  late _Device b;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('blob_sync_test');
    backend = MockSyncBackend();
    a = _Device(await Directory('${tmp.path}/a').create(recursive: true));
    b = _Device(await Directory('${tmp.path}/b').create(recursive: true));
  });

  tearDown(() async {
    await a.close();
    await b.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// A note with one attachment whose file really exists on [device].
  Future<void> createNoteWithAttachment(
    _Device device, {
    required String bytes,
    String storedPath = 'attachments/report.pdf',
  }) async {
    final db = await device.db;
    await db.insert('notes', {
      'id': 'n1',
      'title': 'Trip planning',
      'content': 'ferry times',
      'type': 'note',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
    await db.insert('attachments', {
      'id': 'att1',
      'noteId': 'n1',
      'filePath': storedPath,
      'fileName': 'report.pdf',
      'fileType': 'application/pdf',
      'isRelativePath': 1,
      'createdAt': 1000,
      'includeInAIContext': 1,
    });
    final file = File('${device.root.path}/$storedPath');
    await file.parent.create(recursive: true);
    await file.writeAsString(bytes);
  }

  Future<void> syncFully(_Device device, {int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      await device.session.run(backend);
    }
  }

  for (final encrypted in [false, true]) {
    test('first sync makes existing absolute attachment paths portable '
        '(encrypted=$encrypted)', () async {
      if (encrypted) {
        final crypto = DatasetCrypto(
          await SyncCrypto.deriveFromPassphrase(
            passphrase: 'test portable attachment',
            salt: SyncCrypto.newSalt(),
          ),
        );
        await a.close();
        await b.close();
        a = _Device(a.root, crypto: crypto);
        b = _Device(b.root, crypto: crypto);
      }
      await createNoteWithAttachment(a, bytes: 'legacy external attachment');
      final dbA = await a.db;
      final source = File('${a.root.path}/attachments/report.pdf');
      await dbA.update(
        'attachments',
        {'filePath': source.path, 'isRelativePath': 0},
        where: 'id = ?',
        whereArgs: ['att1'],
      );
      await dbA.delete('sync_touch_log'); // row predates capture/first upgrade

      await a.session.run(backend);
      final migrated = (await dbA.query('attachments')).single;
      expect(migrated['isRelativePath'], 1);
      final portablePath = migrated['filePath'] as String;
      expect(portablePath, startsWith('attachments/sync_'));
      expect(portablePath, endsWith('.pdf'));
      expect(await source.readAsString(), 'legacy external attachment');
      expect(
        await File('${a.root.path}/$portablePath').readAsString(),
        'legacy external attachment',
      );

      // An actual second sandbox must receive its own bytes, not observe the
      // sender's still-existing file through the shared test filesystem.
      await b.session.run(backend);
      final received = (await (await b.db).query('attachments')).single;
      expect(received['filePath'], portablePath);
      expect(received['isRelativePath'], 1);
      expect(
        await File('${b.root.path}/$portablePath').readAsString(),
        'legacy external attachment',
      );
      expect(await a.blobs.preparePortableAttachmentPaths(), 0);
      if (encrypted) {
        expect(
          backend.debugAllBlobBytes().every(
            (bytes) => !String.fromCharCodes(
              bytes,
            ).contains('legacy external attachment'),
          ),
          isTrue,
        );
      }
    });
  }

  test('missing legacy absolute files keep their original metadata', () async {
    await createNoteWithAttachment(a, bytes: 'now missing');
    final dbA = await a.db;
    final source = File('${a.root.path}/attachments/report.pdf');
    await dbA.update(
      'attachments',
      {'filePath': source.path, 'isRelativePath': 0},
      where: 'id = ?',
      whereArgs: ['att1'],
    );
    await source.delete();
    expect(await a.blobs.preparePortableAttachmentPaths(), 0);
    final unchanged = (await dbA.query('attachments')).single;
    expect(unchanged['filePath'], source.path);
    expect(unchanged['isRelativePath'], 0);
    expect(await a.blobs.missingUnhashedAttachments(), ['attachments/att1']);
    final health = await recomputeSyncHealth(a.databaseService);
    expect(
      health.issues
          .where(
            (issue) => issue.kind == SyncHealthIssueKind.attachmentBytesMissing,
          )
          .single
          .detail,
      'attachments/att1',
    );
  });

  test(
    'restoring originally missing bytes publishes a new blob operation',
    () async {
      await createNoteWithAttachment(a, bytes: 'restored original');
      final source = File('${a.root.path}/attachments/report.pdf');
      await source.delete();
      await a.session.run(backend);
      await b.session.run(backend);
      expect(
        await File('${b.root.path}/attachments/report.pdf').exists(),
        isFalse,
      );
      final dbA = await a.db;
      final first = (await dbA.query(
        'sync_pending_ops',
        where: 'entityTable = ? AND fieldName = ?',
        whereArgs: ['attachments', 'filePath'],
      )).single;
      expect(first['publishedAt'], isNotNull);
      expect(first['blobHash'], isNull);

      await source.writeAsString('restored original');
      await a.session.run(backend);
      await b.session.run(backend);
      expect(
        await File('${b.root.path}/attachments/report.pdf').readAsString(),
        'restored original',
      );
      final paths = await dbA.query(
        'sync_pending_ops',
        where: 'entityTable = ? AND fieldName = ?',
        whereArgs: ['attachments', 'filePath'],
        orderBy: 'id',
      );
      expect(paths, hasLength(2));
      expect(paths.first, first, reason: 'published history remains immutable');
      expect(
        paths.last['blobHash'],
        BlobSyncPhase.hashString('restored original'),
      );
      final repeat = await a.session.run(backend);
      expect(
        repeat.drain.mintedOperations.where(
          (op) => op.entityTable == 'attachments' && op.fieldName == 'filePath',
        ),
        isEmpty,
      );
    },
  );

  test(
    'legacy files keep independent paths for separate attachment rows',
    () async {
      await createNoteWithAttachment(a, bytes: 'identical source');
      final dbA = await a.db;
      final source = File('${a.root.path}/attachments/report.pdf');
      await dbA.update('attachments', {
        'filePath': source.path,
        'isRelativePath': 0,
      });
      final second = Map<String, Object?>.from(
        (await dbA.query('attachments')).single,
      )..['id'] = 'att2';
      await dbA.insert('attachments', second);
      expect(await a.blobs.preparePortableAttachmentPaths(), 2);
      final rows = await dbA.query('attachments', orderBy: 'id');
      expect(rows.first['filePath'], isNot(rows.last['filePath']));
      await File('${a.root.path}/${rows.first['filePath']}').delete();
      expect(
        await File('${a.root.path}/${rows.last['filePath']}').readAsString(),
        'identical source',
      );
    },
  );

  for (final deleteOwner in [true, false]) {
    test('restored-file snapshot is discarded after concurrent metadata change '
        '(owner=$deleteOwner)', () async {
      await createNoteWithAttachment(a, bytes: 'restored');
      final source = File('${a.root.path}/attachments/report.pdf');
      await source.delete();
      await a.session.run(backend);
      await source.writeAsString('restored');
      final references = await a.blobs.restoredAttachmentReferences();
      expect(references, hasLength(1));
      final dbA = await a.db;
      if (deleteOwner) {
        await dbA.update('notes', {'__deleted__': 1});
      } else {
        await dbA.update('attachments', {'isRelativePath': 0});
      }
      final service = a.databaseService;
      final result = await OutboxDrainer(
        service,
        DeviceIdentity(service),
        SeqCounter(service),
        HybridLogicalClock(service),
      ).drain(restoredAttachments: references);
      expect(
        result.mintedOperations.where(
          (op) => op.entityTable == 'attachments' && op.fieldName == 'filePath',
        ),
        isEmpty,
      );
    });
  }

  test(
    'peer-provided absolute paths never authorize reading local files',
    () async {
      await createNoteWithAttachment(a, bytes: 'shared attachment');
      await a.session.run(backend);
      await b.session.run(backend);
      final localOnly = File('${tmp.path}/local-only.txt');
      await localOnly.writeAsString('not an attachment');
      final dbB = await b.db;
      await dbB.update('attachments', {
        'filePath': localOnly.path,
        'isRelativePath': 0,
      });
      expect(await b.blobs.preparePortableAttachmentPaths(), 0);
      expect(await b.blobs.restoredAttachmentReferences(), isEmpty);
      expect(
        (await dbB.query('attachments')).single['filePath'],
        localOnly.path,
      );
    },
  );

  for (final deleteOwner in [true, false]) {
    test(
      'legacy portability skips deleted attachments (owner=$deleteOwner)',
      () async {
        await createNoteWithAttachment(a, bytes: 'deleted file');
        final dbA = await a.db;
        final source = File('${a.root.path}/attachments/report.pdf');
        await dbA.update('attachments', {
          'filePath': source.path,
          'isRelativePath': 0,
        });
        await dbA.update(deleteOwner ? 'notes' : 'attachments', {
          '__deleted__': 1,
        });
        expect(await a.blobs.preparePortableAttachmentPaths(), 0);
        await source.delete();
        expect(await a.blobs.missingUnhashedAttachments(), isEmpty);
      },
    );
  }

  for (final unsafePath in [
    '../outside.bin',
    r'..\outside.bin',
    '/absolute/outside.bin',
    r'C:\outside.bin',
  ]) {
    test(
      'receiver refuses unsafe attachment destination $unsafePath',
      () async {
        await createNoteWithAttachment(a, bytes: 'valid uploaded content');
        await a.session.run(backend);
        await b.session.run(backend);
        final dbB = await b.db;
        await dbB.update(
          'attachments',
          {
            'filePath': unsafePath,
            'isRelativePath': unsafePath.startsWith('/') ? 0 : 1,
          },
          where: 'id = ?',
          whereArgs: ['att1'],
        );
        final result = await b.blobs.fetchMissing(backend);
        expect(result.downloaded, 0);
        expect(result.failed, [
          BlobSyncPhase.hashString('valid uploaded content'),
        ]);
        expect(await b.blobs.outstandingReferences(), hasLength(1));
        expect(await File('${tmp.path}/outside.bin').exists(), isFalse);
      },
    );
  }

  test('a second device receives the attachment BYTES, not just the row — the '
      'gap M2.14 left open', () async {
    await createNoteWithAttachment(a, bytes: 'the actual pdf bytes');
    await syncFully(a);
    await syncFully(b);

    final row = (await (await b.db).query(
      'attachments',
      where: 'id = ?',
      whereArgs: ['att1'],
    )).single;
    expect(row['fileName'], 'report.pdf');
    expect(
      row['filePath'],
      'attachments/report.pdf',
      reason:
          'the path is the register value and travels as an ordinary '
          'field — the hash is carried BESIDE it, not instead of it',
    );

    final received = File('${b.root.path}/attachments/report.pdf');
    expect(
      await received.exists(),
      isTrue,
      reason:
          'THE point of the milestone. Before M3.1 the row arrived and the '
          'file did not, so every attachment rendered as "file not found" '
          'on the second device.',
    );
    expect(await received.readAsString(), 'the actual pdf bytes');
  });

  test(
    'the bytes are addressed by content, so an identical file uploads once',
    () async {
      await createNoteWithAttachment(a, bytes: 'identical content');
      await syncFully(a);

      // A second attachment on the SAME device naming a different path but
      // holding byte-identical content.
      final db = await a.db;
      await db.insert('attachments', {
        'id': 'att2',
        'noteId': 'n1',
        'filePath': 'attachments/copy.pdf',
        'fileName': 'copy.pdf',
        'fileType': 'application/pdf',
        'isRelativePath': 1,
        'createdAt': 1001,
        'includeInAIContext': 1,
      });
      final copy = File('${a.root.path}/attachments/copy.pdf');
      await copy.parent.create(recursive: true);
      await copy.writeAsString('identical content');

      await syncFully(a);
      await syncFully(b);

      expect(
        await File('${b.root.path}/attachments/copy.pdf').readAsString(),
        'identical content',
      );
      expect(
        await File('${b.root.path}/attachments/report.pdf').readAsString(),
        'identical content',
      );
    },
  );

  test('a row whose file is missing still syncs its metadata, and the blob is '
      'reported outstanding rather than failing the round', () async {
    await createNoteWithAttachment(a, bytes: 'x');
    // The user deleted the file out from under the row — a state this app
    // has rendered since long before sync existed.
    await File('${a.root.path}/attachments/report.pdf').delete();

    await syncFully(a);
    await syncFully(b);

    expect(
      (await (await b.db).query('attachments')).single['fileName'],
      'report.pdf',
      reason:
          'withholding the row would withhold the user\'s own metadata from '
          'their other device because of a file the app already shows as '
          'missing',
    );
    expect(
      await File('${b.root.path}/attachments/report.pdf').exists(),
      isFalse,
    );
  });

  test(
    'an interrupted download never leaves a truncated file in place',
    () async {
      await createNoteWithAttachment(a, bytes: 'complete content');
      await syncFully(a);

      // Pull the row, but make the download fail.
      backend.failNextDownload = true;
      await syncFully(b, rounds: 2);

      final target = File('${b.root.path}/attachments/report.pdf');
      expect(
        await target.exists(),
        isFalse,
        reason:
            'written to a .part sibling and renamed, so a partial transfer is '
            'never indistinguishable from a real attachment — it would fail at '
            'open time instead of here',
      );

      // And it recovers on the next round, with no queue to have kept.
      backend.failNextDownload = false;
      await syncFully(b, rounds: 2);
      expect(await target.readAsString(), 'complete content');
    },
  );

  test('outstandingReferences is the same set the fetch acts on', () async {
    await createNoteWithAttachment(a, bytes: 'bytes');
    await syncFully(a);

    // Phase C runs inside the same round as the pull, so the only way to
    // observe the outstanding set is to stop the fetch from clearing it.
    backend.failNextDownload = true;
    await syncFully(b, rounds: 2);

    final outstanding = await b.blobs.outstandingReferences();
    expect(outstanding, hasLength(1));
    expect(outstanding.single.entityTable, 'attachments');
    expect(outstanding.single.entityId, 'att1');

    backend.failNextDownload = false;
    await syncFully(b, rounds: 2);
    expect(
      await b.blobs.outstandingReferences(),
      isEmpty,
      reason:
          'the health surface reads this same query, so the number a user '
          'sees and the work the fetch does cannot drift apart',
    );
  });

  // ── M3.1 second half: a mini app's CODE ───────────────────────────────
  //
  // `app_revisions.appCode` was the last column blocking `app_revisions`
  // from syncing at all, so a mini app reached a second device with its
  // metadata and no runnable source. It is a blob whose bytes live in a
  // database column rather than in a file, which is the only way it differs
  // from an attachment.

  Future<void> createMiniApp(_Device device, {required String code}) async {
    final db = await device.db;
    await db.insert('user_apps', {
      'id': 'app1',
      'uuid': 'uuid-app1',
      'name': 'Counter',
      'description': 'counts',
      'steps': '[]',
      'htmlContent': '',
      'type': 'normal',
      'selectedRevisionId': 'rev1',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
    await db.insert('app_revisions', {
      'id': 'rev1',
      'appId': 'app1',
      'revisionNumber': 1,
      'revisionTimestamp': 1000,
      'userPrompt': 'make a counter',
      'aiResponse': 'done',
      'appCode': code,
    });
  }

  for (final changeWinner in [false, true]) {
    test('download cannot overwrite content changed while awaiting bytes '
        '(new register=$changeWinner)', () async {
      final racingBackend = _DuringDownloadBackend();
      backend = racingBackend;
      await createMiniApp(a, code: 'remote original');
      await a.session.run(backend);
      final dbB = await b.db;
      racingBackend.duringDownload = () async {
        if (changeWinner) {
          await dbB.update(
            'sync_field_state',
            {'blobHash': BlobSyncPhase.hashString('newer winner')},
            where: 'entityTable = ? AND fieldName = ?',
            whereArgs: ['app_revisions', 'appCode'],
          );
        } else {
          await dbB.update(
            'app_revisions',
            {'appCode': 'local edit'},
            where: 'id = ?',
            whereArgs: ['rev1'],
          );
        }
      };
      final result = await b.session.run(backend);
      expect(result.blobs.downloaded, 0);
      expect(
        (await dbB.query('app_revisions')).single['appCode'],
        changeWinner ? '' : 'local edit',
      );
    });
  }

  test('localized mini-app metadata syncs when created and updated', () async {
    await createMiniApp(a, code: 'code');
    final localized = jsonEncode({
      'zh': {'name': '计数器', 'description': '计数'},
    });
    await (await a.db).update('user_apps', {'i18n': localized});
    await syncFully(a);
    await syncFully(b);
    expect((await (await b.db).query('user_apps')).single['i18n'], localized);

    final updated = jsonEncode({
      'zh': {'name': '新计数器', 'description': '新的描述'},
    });
    await (await a.db).update('user_apps', {'i18n': updated});
    await syncFully(a);
    await syncFully(b);
    expect((await (await b.db).query('user_apps')).single['i18n'], updated);
  });

  test(
    'published mini-app code stays live for GC, including older sender state',
    () async {
      await createMiniApp(a, code: 'source code');
      await syncFully(a);
      final hash = BlobSyncPhase.hashString('source code');
      expect(
        (await a.blobs.allReferences()).map((r) => r.blobHash),
        contains(hash),
      );
      expect(
        (await BlobGc(a.databaseService).scan(backend)).candidates,
        isEmpty,
      );

      // Reproduce a sender that published with the old pending-only stamping.
      await (await a.db).update(
        'sync_field_state',
        {'blobHash': null},
        where: 'entityTable = ? AND fieldName = ?',
        whereArgs: ['app_revisions', 'appCode'],
      );
      expect(
        (await a.blobs.allReferences()).map((r) => r.blobHash),
        isNot(contains(hash)),
      );
      await syncFully(a);
      expect(
        (await a.blobs.allReferences()).map((r) => r.blobHash),
        contains(hash),
      );
      expect(
        (await BlobGc(a.databaseService).scan(backend)).candidates,
        isEmpty,
      );
    },
  );

  test('a mini app arrives on a second device WITH its code — app_revisions '
      'was the last table blocked by an unresolvable column', () async {
    const code = '<html><body>counter</body></html>';
    await createMiniApp(a, code: code);
    await syncFully(a);
    await syncFully(b);

    final revision = (await (await b.db).query(
      'app_revisions',
      where: 'id = ?',
      whereArgs: ['rev1'],
    )).single;
    expect(revision['appId'], 'app1');
    expect(revision['userPrompt'], 'make a counter');
    expect(
      revision['appCode'],
      code,
      reason:
          'the metadata used to arrive without this, so the app rendered '
          'as "code hasn\'t arrived on this device" forever',
    );
  });

  test('the code does NOT travel inline in the commit log', () async {
    const code = 'UNIQUE_MARKER_THAT_MUST_NOT_APPEAR_INLINE';
    await createMiniApp(a, code: code);
    await syncFully(a);

    final logIds = await backend.listDeviceLogIds();
    var sawMarkerInAnyCommit = false;
    for (final logId in logIds) {
      final page = await backend.readCommits(deviceLogId: logId, afterSeq: 0);
      for (final commit in page.commits) {
        if (String.fromCharCodes(commit.commitBytes).contains(code)) {
          sawMarkerInAnyCommit = true;
        }
      }
    }
    expect(
      sawMarkerInAnyCommit,
      isFalse,
      reason:
          'appCode is stripped at encode time and carried as a blobHash — '
          'inlining a mini app source into every commit that touches the row '
          'is what the blob mechanism exists to avoid',
    );

    // And it is genuinely on the backend as a blob, not simply dropped.
    await syncFully(b);
    expect((await (await b.db).query('app_revisions')).single['appCode'], code);
  });

  test('a revision whose code has not arrived yet is reported, not silently '
      'blank', () async {
    await createMiniApp(a, code: 'some code');
    await syncFully(a);

    backend.failNextDownload = true;
    await syncFully(b, rounds: 2);

    final outstanding = await b.blobs.outstandingReferences();
    expect(outstanding.map((r) => r.entityTable), contains('app_revisions'));
    expect(
      (await (await b.db).query('app_revisions')).single['appCode'],
      '',
      reason:
          'the shell row placeholder, which the UI renders as "code '
          'hasn\'t arrived" rather than as a blank app',
    );

    backend.failNextDownload = false;
    await syncFully(b, rounds: 2);
    expect(
      (await (await b.db).query('app_revisions')).single['appCode'],
      'some code',
    );
  });
}
