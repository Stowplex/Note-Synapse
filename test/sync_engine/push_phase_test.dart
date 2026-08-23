// Tests for M2.6's `PushPhase` (`lib/services/sync/push_phase.dart`) — §
// Architecture 11.7 Phase A: per-`authorId`-namespace push against
// `SyncBackend`, including the crash-safety resume procedure (step 0) that
// was a must-fix correction from the design's own adversarial review round.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
import 'package:note_synapse/services/sync/push_phase.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/wire_format.dart';

import '../sync_backend/mock_sync_backend.dart';
import '../sync_backend/sync_faults.dart';

// Independently re-derives push_phase.dart's own (private, so
// unreachable from this test file directly) payloadHash/intentHash
// formulas, per its doc comments — needed to hand-construct a
// sync_publish_intent row for the crash-resume simulation below.
String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
String _payloadHash(Uint8List commitBytes) => _sha256Hex(commitBytes);
String _intentHash(String? parentCommitHash, String payloadHash) =>
    _sha256Hex(utf8.encode('${parentCommitHash ?? ''}|$payloadHash'));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;
  late DeviceIdentity deviceIdentity;
  late OutboxDrainer drainer;
  late PushPhase push;
  late MockSyncBackend backend;

  setUp(() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
    deviceIdentity = DeviceIdentity(databaseService);
    drainer = OutboxDrainer(
      databaseService,
      deviceIdentity,
      SeqCounter(databaseService),
      HybridLogicalClock(databaseService),
    );
    push = PushPhase(databaseService);
    backend = MockSyncBackend();
  });

  tearDown(() async {
    await databaseService.close();
  });

  Future<String> deviceId() => deviceIdentity.ensureDeviceId();

  group('ordinary push', () {
    test('publishes every pending op in authorSeq order and the local tip advances', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final drainResult = await drainer.drain();
      expect(drainResult.mintedOperations, isNotEmpty);

      final authorId = await deviceId();
      final result = await push.push(backend: backend, authorId: authorId);

      expect(result.publishedCount, drainResult.mintedOperations.length);
      expect(result.resumedCount, 0);

      // Every pending op is now marked published.
      final stillPending =
          await db.query('sync_pending_ops', where: 'authorId = ? AND publishedAt IS NULL', whereArgs: [authorId]);
      expect(stillPending, isEmpty);

      // M2.12: the backend stored them BATCHED — one commit carrying every
      // operation, not one commit each — still in authorSeq order and still
      // hash-chained. `deviceSeq` (commit position) and `authorSeq` (dot)
      // are now different counters, so the assertions below check each
      // against the right thing.
      final page = await backend.readCommits(deviceLogId: authorId, afterSeq: 0);
      expect(page.hasGap, isFalse);
      expect(page.commits.length, 1);
      expect(page.commits.single.deviceSeq, 1);
      expect(result.commitCount, 1);

      String? expectedParent;
      final decodedSeqs = <int>[];
      for (final commit in page.commits) {
        expect(commit.parentCommitHash, expectedParent);
        final ops = decodeCommitOperations(
          commit.commitBytes,
          expectedAuthorId: authorId,
          deviceSeq: commit.deviceSeq,
        );
        for (final op in ops) {
          expect(op.authorId, authorId);
          decodedSeqs.add(op.authorSeq);
        }
        expectedParent = commit.commitHash;
      }
      expect(
        decodedSeqs,
        drainResult.mintedOperations.map((o) => o.authorSeq).toList(),
      );

      // sync_state['tip:<authorId>'] reflects the LAST commit's hash.
      final tipRows =
          await db.query('sync_state', where: 'key = ?', whereArgs: ['tip:$authorId']);
      expect(tipRows.single['value'], page.commits.last.commitHash);
    });

    test('a second push() call with nothing new pending is a safe no-op', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await drainer.drain();
      final authorId = await deviceId();
      final first = await push.push(backend: backend, authorId: authorId);
      expect(first.publishedCount, greaterThan(0));

      final second = await push.push(backend: backend, authorId: authorId);
      expect(second.publishedCount, 0);
      expect(second.resumedCount, 0);
    });
  });

  group('Ambiguous outcome, resolved inline within the same push() call', () {
    test('a NetworkPartitionAfterWrite on appendCommit still results in exactly one confirmed commit', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final drainResult = await drainer.drain();
      final authorId = await deviceId();

      final faults = ScriptedFaultQueue();
      // Only the FIRST appendCommit call in this push() gets the fault —
      // the write lands, but the caller sees Ambiguous instead of Succeeded.
      faults.enqueue(const NetworkPartitionAfterWrite(SyncOp.appendCommit));
      backend.faultSource = faults;

      final result = await push.push(backend: backend, authorId: authorId);
      expect(result.publishedCount, drainResult.mintedOperations.length);

      final page = await backend.readCommits(deviceLogId: authorId, afterSeq: 0);
      // M2.12: one batched commit carrying every operation.
      expect(page.commits.length, 1);
      // No duplicate object was created at the first commit's position
      // despite the ambiguous outcome.
      expect(backend.debugStorageObjectCountAtSeq(authorId, page.commits.first.deviceSeq), 1);

      final stillPending =
          await db.query('sync_pending_ops', where: 'authorId = ? AND publishedAt IS NULL', whereArgs: [authorId]);
      expect(stillPending, isEmpty);
    });
  });

  group('crash-safety resume procedure (§ 11.7 Phase A step 0)', () {
    test(
        'appendCommit succeeded but the local confirm never happened — a fresh push() resumes correctly, '
        'with no duplicate commit and no lost pending op', () async {
      final authorId = await deviceId();

      // Mint exactly one pending op directly (bypassing OutboxDrainer's own
      // multi-op note-insert path, so this scenario is precisely about ONE
      // op's crash window, not entangled with a batch).
      await db.insert('sync_pending_ops', {
        'authorId': authorId,
        'authorSeq': 1,
        'hlc': const Hlc(1000, 0).toString(),
        'contentKey': null,
        'kind': 'field',
        'entityTable': 'notes',
        'entityId': 'n1',
        'fieldName': 'title',
        'memberUuid': null,
        'valueJson': jsonEncode('Hello'),
        'blobHash': null,
        'targetDotsJson': null,
        'frontierJson': jsonEncode({authorId: 1}),
        'createdAt': 1000,
        'publishedAt': null,
      });

      final opRow = (await db.query('sync_pending_ops',
              where: 'authorId = ? AND authorSeq = ?', whereArgs: [authorId, 1]))
          .single;
      final commitBytes = encodeCommitBytes(WireOperation.fromPendingOpsRow(opRow));
      final payloadHash = _payloadHash(commitBytes);
      final intentHash = _intentHash(null, payloadHash);

      // Step 2's "record the intent BEFORE calling appendCommit" — done here
      // by hand, simulating session 1 having reached exactly that point.
      await db.insert('sync_publish_intent', {
        'intentHash': intentHash,
        'parentCommitHash': null,
        'payloadHash': payloadHash,
        'authorId': authorId,
        'deviceSeq': 1,
        'status': 'pending',
        'createdAt': 1000,
        'confirmedAt': null,
      });

      // Session 1's appendCommit call — it succeeds durably on the backend.
      final outcome = await backend.appendCommit(
        deviceLogId: authorId,
        deviceSeq: 1,
        publishIntentId: intentHash,
        parentCommitHash: null,
        commitBytes: commitBytes,
      );
      expect(outcome, isA<AppendCommitSucceeded>());

      // Session 1 crashes here — _confirmAndAdvance never runs. Verify the
      // simulated crash state: still pending, still unpublished.
      final intentBefore =
          (await db.query('sync_publish_intent', where: 'intentHash = ?', whereArgs: [intentHash])).single;
      expect(intentBefore['status'], 'pending');
      final opBefore =
          (await db.query('sync_pending_ops', where: 'authorId = ? AND authorSeq = ?', whereArgs: [authorId, 1]))
              .single;
      expect(opBefore['publishedAt'], isNull);

      // A fresh session's push() call — step 0 must find the pending intent,
      // discover the commit already landed, and resume correctly.
      final freshPush = PushPhase(databaseService);
      final result = await freshPush.push(backend: backend, authorId: authorId);

      expect(result.resumedCount, 1);
      expect(result.publishedCount, 1);

      // Exactly one stored commit at that position — resume did not
      // re-append a duplicate.
      expect(backend.debugStorageObjectCountAtSeq(authorId, 1), 1);

      final intentAfter =
          (await db.query('sync_publish_intent', where: 'intentHash = ?', whereArgs: [intentHash])).single;
      expect(intentAfter['status'], 'confirmed');
      expect(intentAfter['confirmedAt'], isNotNull);

      final opAfter =
          (await db.query('sync_pending_ops', where: 'authorId = ? AND authorSeq = ?', whereArgs: [authorId, 1]))
              .single;
      expect(opAfter['publishedAt'], isNotNull);

      final tipRows = await db.query('sync_state', where: 'key = ?', whereArgs: ['tip:$authorId']);
      final page = await backend.readCommits(deviceLogId: authorId, afterSeq: 0);
      expect(tipRows.single['value'], page.commits.single.commitHash);
    });

    test('a pending intent whose appendCommit never actually landed is retried, not skipped', () async {
      final authorId = await deviceId();
      await db.insert('sync_pending_ops', {
        'authorId': authorId,
        'authorSeq': 1,
        'hlc': const Hlc(1000, 0).toString(),
        'contentKey': null,
        'kind': 'field',
        'entityTable': 'notes',
        'entityId': 'n1',
        'fieldName': 'title',
        'memberUuid': null,
        'valueJson': jsonEncode('Hello'),
        'blobHash': null,
        'targetDotsJson': null,
        'frontierJson': jsonEncode({authorId: 1}),
        'createdAt': 1000,
        'publishedAt': null,
      });
      final opRow = (await db.query('sync_pending_ops',
              where: 'authorId = ? AND authorSeq = ?', whereArgs: [authorId, 1]))
          .single;
      final commitBytes = encodeCommitBytes(WireOperation.fromPendingOpsRow(opRow));
      final payloadHash = _payloadHash(commitBytes);
      final intentHash = _intentHash(null, payloadHash);

      // Intent recorded, but appendCommit was NEVER actually called this
      // time (crash landed even earlier than the previous test's scenario).
      await db.insert('sync_publish_intent', {
        'intentHash': intentHash,
        'parentCommitHash': null,
        'payloadHash': payloadHash,
        'authorId': authorId,
        'deviceSeq': 1,
        'status': 'pending',
        'createdAt': 1000,
        'confirmedAt': null,
      });
      expect(backend.debugStorageObjectCountAtSeq(authorId, 1), 0);

      final result = await push.push(backend: backend, authorId: authorId);
      expect(result.resumedCount, 1);
      expect(backend.debugStorageObjectCountAtSeq(authorId, 1), 1);
      final intentAfter =
          (await db.query('sync_publish_intent', where: 'intentHash = ?', whereArgs: [intentHash])).single;
      expect(intentAfter['status'], 'confirmed');
    });
  });

  group('ParentMismatch — halt-not-retarget, surfaced as a real error', () {
    test('throws PushParentMismatchException and does not confirm the mismatched op', () async {
      final authorId = await deviceId();
      await db.insert('sync_pending_ops', {
        'authorId': authorId,
        'authorSeq': 1,
        'hlc': const Hlc(1000, 0).toString(),
        'contentKey': null,
        'kind': 'field',
        'entityTable': 'notes',
        'entityId': 'n1',
        'fieldName': 'title',
        'memberUuid': null,
        'valueJson': jsonEncode('Hello'),
        'blobHash': null,
        'targetDotsJson': null,
        'frontierJson': jsonEncode({authorId: 1}),
        'createdAt': 1000,
        'publishedAt': null,
      });

      // A foreign commit lands at deviceSeq=1 under the same authorId,
      // out-of-band — something PushPhase has no local record of. Its own
      // attempt to append its op at deviceSeq=1 now disagrees with the
      // backend's actual state.
      await backend.appendCommit(
        deviceLogId: authorId,
        deviceSeq: 1,
        publishIntentId: 'foreign-intent',
        parentCommitHash: null,
        commitBytes: Uint8List.fromList(utf8.encode('{"foreign":true}')),
      );

      await expectLater(
        push.push(backend: backend, authorId: authorId),
        throwsA(isA<PushParentMismatchException>()),
      );

      // The mismatched op was never confirmed.
      final opAfter =
          (await db.query('sync_pending_ops', where: 'authorId = ? AND authorSeq = ?', whereArgs: [authorId, 1]))
              .single;
      expect(opAfter['publishedAt'], isNull);
    });
  });
}
