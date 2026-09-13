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
  _Device(this.root) : databaseService = DatabaseService.createNew() {
    blobs = BlobSyncPhase(databaseService, resolver: _TempDirResolver(root));
    session = SyncSession(databaseService, blobs: blobs);
  }

  final Directory root;
  final DatabaseService databaseService;
  late final BlobSyncPhase blobs;
  late final SyncSession session;

  Future<Database> get db => databaseService.database;
  Future<void> close() => databaseService.close();
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

  test(
    'a second device receives the attachment BYTES, not just the row — the '
    'gap M2.14 left open',
    () async {
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
        reason: 'the path is the register value and travels as an ordinary '
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
    },
  );

  test('the bytes are addressed by content, so an identical file uploads once',
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
  });

  test(
    'a row whose file is missing still syncs its metadata, and the blob is '
    'reported outstanding rather than failing the round',
    () async {
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
    },
  );

  test('an interrupted download never leaves a truncated file in place',
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
  });

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

  test(
    'a mini app arrives on a second device WITH its code — app_revisions '
    'was the last table blocked by an unresolvable column',
    () async {
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
    },
  );

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
    expect(
      (await (await b.db).query('app_revisions')).single['appCode'],
      code,
    );
  });

  test(
    'a revision whose code has not arrived yet is reported, not silently '
    'blank',
    () async {
      await createMiniApp(a, code: 'some code');
      await syncFully(a);

      backend.failNextDownload = true;
      await syncFully(b, rounds: 2);

      final outstanding = await b.blobs.outstandingReferences();
      expect(outstanding.map((r) => r.entityTable), contains('app_revisions'));
      expect(
        (await (await b.db).query('app_revisions')).single['appCode'],
        '',
        reason: 'the shell row placeholder, which the UI renders as "code '
            'hasn\'t arrived" rather than as a blank app',
      );

      backend.failNextDownload = false;
      await syncFully(b, rounds: 2);
      expect(
        (await (await b.db).query('app_revisions')).single['appCode'],
        'some code',
      );
    },
  );
}
