// M3.6 — blob garbage collection.
//
// The assertions that matter are the refusals, not the deletions: this
// mechanism's whole design problem is that it must NOT reclaim bytes some
// unreachable device is about to reference, and § Architecture 4's own
// root-cause finding is that no backward-looking evidence can prove it
// will not. So most of what is pinned here is what the GC declines to do.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/blob_gc.dart';
import 'package:note_synapse/services/sync/blob_sync.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/mock_sync_backend.dart';

class _TempDirResolver implements BlobFileResolver {
  _TempDirResolver(this.root);
  final Directory root;
  @override
  Future<String> absolutePath(String storedPath, bool isRelative) async =>
      isRelative ? '${root.path}/$storedPath' : storedPath;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Directory tmp;
  late MockSyncBackend backend;
  late DatabaseService svc;
  late DateTime clock;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('blob_gc');
    backend = MockSyncBackend();
    svc = DatabaseService.createNew();
    clock = DateTime(2026, 1, 1);
  });

  tearDown(() async {
    await svc.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  BlobGc gc() => BlobGc(svc, now: () => clock);

  Future<void> syncWithAttachment({required String bytes}) async {
    final db = await svc.database;
    await db.insert('notes', {
      'id': 'n1',
      'title': 'T',
      'content': 'c',
      'type': 'note',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
    await db.insert('attachments', {
      'id': 'att1',
      'noteId': 'n1',
      'filePath': 'a/f.bin',
      'fileName': 'f.bin',
      'fileType': 'application/octet-stream',
      'isRelativePath': 1,
      'createdAt': 1000,
      'includeInAIContext': 1,
    });
    final f = File('${tmp.path}/a/f.bin');
    await f.parent.create(recursive: true);
    await f.writeAsString(bytes);

    final blobs = BlobSyncPhase(
      svc,
      resolver: _TempDirResolver(tmp),
      gc: gc(),
    );
    for (var i = 0; i < 3; i++) {
      await SyncSession(svc, blobs: blobs).run(backend);
    }
  }

  test('a blob referenced by a live row is never a candidate', () async {
    await syncWithAttachment(bytes: 'payload');
    final report = await gc().scan(backend);
    expect(report.candidates, isEmpty);
    expect(report.eligible, isEmpty);
  });

  test(
    'a blob referenced only by a TOMBSTONED row is still live — reclaiming '
    'it would turn a reversible delete into a permanent one',
    () async {
      await syncWithAttachment(bytes: 'payload');
      await (await svc.database).update(
        'attachments',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: ['att1'],
      );

      final report = await gc().scan(backend);
      expect(
        report.candidates,
        isEmpty,
        reason:
            '__deleted__ is reversible by design (§ Architecture 6 undelete), '
            'so the bytes behind a tombstone are still needed',
      );
    },
  );

  test(
    'an unreferenced blob becomes a candidate, ages, and is not eligible '
    'until the grace period has elapsed',
    () async {
      await syncWithAttachment(bytes: 'payload');
      // The row is gone entirely — not tombstoned. Nothing references the
      // bytes any more.
      await (await svc.database).delete('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);

      var report = await gc().scan(backend);
      expect(report.candidates, hasLength(1));
      expect(report.candidates.single.eligible, isFalse);
      expect(report.canDelete, isFalse);

      clock = clock.add(BlobGcPolicy.gracePeriod - const Duration(days: 1));
      report = await gc().scan(backend);
      expect(
        report.eligible,
        isEmpty,
        reason: 'day 29 of a 30-day window is still pending',
      );

      clock = clock.add(const Duration(days: 2));
      report = await gc().scan(backend);
      expect(report.eligible, hasLength(1));
      expect(report.canDelete, isTrue);
    },
  );

  test(
    'a blob that becomes referenced again during its grace period restarts '
    'the clock rather than resuming it',
    () async {
      await syncWithAttachment(bytes: 'payload');
      final db = await svc.database;
      final saved = await db.query('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);
      await db.delete('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);

      await gc().scan(backend); // candidacy starts
      clock = clock.add(const Duration(days: 25));

      for (final row in saved) {
        await db.insert('sync_field_state', row);
      }
      var report = await gc().scan(backend);
      expect(report.candidates, isEmpty, reason: 'referenced again');

      await db.delete('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);
      await gc().scan(backend);
      clock = clock.add(const Duration(days: 25));
      report = await gc().scan(backend);
      expect(
        report.eligible,
        isEmpty,
        reason:
            'a blob that flickers in and out of reference must earn a FULL '
            'grace period each time — resuming the old clock would let 25 '
            'days of being live count toward being dead',
      );
    },
  );

  test(
    'a multi-device dataset refuses to delete, and says why rather than '
    'quietly reclaiming nothing',
    () async {
      await syncWithAttachment(bytes: 'payload');
      await (await svc.database).delete('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);
      // Candidacy starts when the blob is FIRST OBSERVED unreferenced, not
      // retroactively from whenever the reference happened to go away — a
      // device that was switched off for the whole window has not given any
      // peer a chance to publish a reference.
      await gc().scan(backend);
      clock = clock.add(BlobGcPolicy.gracePeriod + const Duration(days: 1));

      // A peer publishes, so the dataset has a second member.
      final peer = DatabaseService.createNew();
      addTearDown(peer.close);
      await (await peer.database).insert('notes', {
        'id': 'n2',
        'title': 'peer',
        'content': '',
        'type': 'note',
        'createdAt': 1,
        'updatedAt': 1,
      });
      await SyncSession(peer).run(backend);

      final report = await gc().scan(backend);
      expect(report.eligible, hasLength(1), reason: 'the grace period elapsed');
      expect(
        report.blocker,
        BlobGcBlocker.multiDeviceWithoutCertificate,
        reason:
            'a certificate approximates "no other device will reference '
            'this". With another member present that question genuinely has '
            'no answer yet, and § Architecture 4 forbids guessing it.',
      );
      expect(report.canDelete, isFalse);
      await expectLater(
        gc().deleteConfirmed(backend, [report.eligible.single.blobHash]),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'on a single-device dataset an eligible blob is actually deleted, and '
    'the fresh recheck runs at confirmation time',
    () async {
      await syncWithAttachment(bytes: 'payload');
      final db = await svc.database;
      await db.delete('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);
      await gc().scan(backend); // candidacy starts here
      clock = clock.add(BlobGcPolicy.gracePeriod + const Duration(days: 1));

      final report = await gc().scan(backend);
      expect(report.canDelete, isTrue);
      final hash = report.eligible.single.blobHash;

      expect(await backend.blobExists(hash), isTrue);
      expect(await gc().deleteConfirmed(backend, [hash]), 1);
      expect(await backend.blobExists(hash), isFalse);
    },
  );

  test(
    'a blob that became referenced between the scan and the confirmation is '
    'left in place — the fresh recheck is not redundant',
    () async {
      await syncWithAttachment(bytes: 'payload');
      final db = await svc.database;
      final saved = await db.query('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);
      await db.delete('sync_field_state',
          where: 'entityTable = ?', whereArgs: ['attachments']);
      await gc().scan(backend); // candidacy starts here
      clock = clock.add(BlobGcPolicy.gracePeriod + const Duration(days: 1));

      final report = await gc().scan(backend);
      final hash = report.eligible.single.blobHash;

      // The user sits on the confirmation dialog; a sync brings the
      // reference back.
      for (final row in saved) {
        await db.insert('sync_field_state', row);
      }

      expect(
        await gc().deleteConfirmed(backend, [hash]),
        0,
        reason:
            '§ Architecture 4 requires a fresh recheck immediately before '
            'physical deletion, precisely because a confirmation dialog can '
            'be open for a long time',
      );
      expect(await backend.blobExists(hash), isTrue);
    },
  );
}
