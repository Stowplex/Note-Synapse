// Tests for M2.6's `PullPhase` (`lib/services/sync/pull_phase.dart`) — §
// Architecture 11.7 Phase B: pulling another device's commits, decoding
// them, and routing them into M2.5's `CausalEngine` — asserting the
// resolution LANDS in `sync_field_state`/`sync_set_state`, per this
// milestone's own scope boundary with M2.7 (materialization into real
// app-table rows does not exist yet and is not tested here).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
import 'package:note_synapse/services/sync/pull_phase.dart';
import 'package:note_synapse/services/sync/push_phase.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/wire_format.dart';

import '../sync_backend/mock_sync_backend.dart';
import '../sync_backend/sync_faults.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late MockSyncBackend backend;

  // Device under test.
  late DatabaseService dbServiceA;
  late Database dbA;
  late DeviceIdentity identityA;
  late PullPhase pullA;
  late String authorA;

  // A second, fully independent local device ("B") whose OWN drain+push
  // populates the shared backend — the natural way to produce a real,
  // wire-format-encoded remote commit without hand-authoring one.
  late DatabaseService dbServiceB;
  late DeviceIdentity identityB;
  late OutboxDrainer drainerB;
  late PushPhase pushB;
  late String authorB;

  setUp(() async {
    backend = MockSyncBackend();

    dbServiceA = DatabaseService.createNew();
    dbA = await dbServiceA.database;
    identityA = DeviceIdentity(dbServiceA);
    authorA = await identityA.ensureDeviceId();
    pullA = PullPhase(dbServiceA, HybridLogicalClock(dbServiceA));

    dbServiceB = DatabaseService.createNew();
    identityB = DeviceIdentity(dbServiceB);
    authorB = await identityB.ensureDeviceId();
    drainerB = OutboxDrainer(dbServiceB, identityB, SeqCounter(dbServiceB), HybridLogicalClock(dbServiceB));
    pushB = PushPhase(dbServiceB);
  });

  tearDown(() async {
    await dbServiceA.close();
    await dbServiceB.close();
  });

  Future<Map<String, Object?>?> fieldStateRow(String table, String id, String field) async {
    final rows = await dbA.query('sync_field_state',
        where: 'entityTable = ? AND entityId = ? AND fieldName = ?', whereArgs: [table, id, field]);
    return rows.isEmpty ? null : rows.first;
  }

  group('full pull cycle', () {
    test("device B's pushed commits are pulled, decoded, and correctly resolved into sync_field_state", () async {
      final dbB = await dbServiceB.database;
      await dbB.insert('notes', {
        'id': 'n1',
        'title': 'from B',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final drainResult = await drainerB.drain();
      final pushResult = await pushB.push(backend: backend, authorId: authorB);

      final result = await pullA.pull(backend: backend, ownAuthorId: authorA);

      expect(result.operationsApplied, drainResult.mintedOperations.length);
      expect(result.operationsBlocked, 0);
      expect(result.gappedDeviceLogIds, isEmpty);

      final titleRow = await fieldStateRow('notes', 'n1', 'title');
      expect(titleRow, isNotNull);
      expect(jsonDecode(titleRow!['valueJson'] as String), 'from B');
      expect(titleRow['authorId'], authorB);

      // Frontier + pull tip persisted for B's log. **The frontier counts
      // COMMITS, not operations** (M2.12) — `deviceSeq` is a commit-chain
      // position, and B's whole drain went out as a single batched commit.
      final frontierRows =
          await dbA.query('sync_state', where: 'key = ?', whereArgs: ['frontier:$authorB']);
      expect(int.parse(frontierRows.single['value'] as String), pushResult.commitCount);
      expect(pushResult.commitCount, lessThan(drainResult.mintedOperations.length));

      // sync_ack_frontier opportunistically updated from B's own carried frontier.
      final ackRows = await dbA.query('sync_ack_frontier', where: 'deviceId = ? AND authorId = ?', whereArgs: [authorB, authorB]);
      expect(ackRows, isNotEmpty);
    });

    test('pulling twice in a row applies nothing new the second time', () async {
      final dbB = await dbServiceB.database;
      await dbB.insert('notes', {
        'id': 'n1',
        'title': 'from B',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await drainerB.drain();
      await pushB.push(backend: backend, authorId: authorB);

      final first = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(first.operationsApplied, greaterThan(0));
      final second = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(second.operationsApplied, 0);
      expect(second.operationsBlocked, 0);
    });

    test(
        'crash-safety: a pull "session" that only ever gets partway through before the process dies, '
        'and a brand-new PullPhase instance resuming later, applies exactly the not-yet-applied commits — '
        'no skip, no double-apply', () async {
      // § 11.7 Phase B step 5's own design: "persist the advanced
      // frontier:<deviceLogId> value in the SAME transaction as the last
      // commit it reflects" — so a real process crash can only ever leave
      // `sync_state['frontier:<authorId>']` sitting at some exact prior
      // commit boundary, never a half-applied one (each commit's apply +
      // frontier bump is one atomic transaction, per PullPhase's own
      // per-commit loop). This test doesn't need to inject a literal
      // exception mid-loop to prove resumption is safe: it reproduces the
      // EXACT durable state a crash would leave behind (a frontier
      // advanced through commit K, no further) simply by running a
      // complete, ordinary pull() call against a backend that only has K
      // commits available yet — then more commits arrive, and an entirely
      // NEW `PullPhase` instance (never having seen the first call, mirrors
      // "the app restarted") is asked to pull again, reading `afterSeq`
      // fresh from the durably-persisted frontier row, exactly as a
      // post-crash resume would.
      final dbB = await dbServiceB.database;

      // Session 1 (pre-crash): B has authored one field's worth of ops;
      // A pulls and durably applies them.
      await dbB.insert('notes', {
        'id': 'n1',
        'title': 'v1',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final firstDrain = await drainerB.drain();
      final firstPush = await pushB.push(backend: backend, authorId: authorB);

      final firstPullResult = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(firstPullResult.operationsApplied, firstDrain.mintedOperations.length);

      final frontierAfterFirst =
          await dbA.query('sync_state', where: 'key = ?', whereArgs: ['frontier:$authorB']);
      final frontierValueAfterFirst = int.parse(frontierAfterFirst.single['value'] as String);
      // Commits, not operations — see the M2.12 note in the test above.
      expect(frontierValueAfterFirst, firstPush.commitCount);
      final titleRowAfterFirst = await fieldStateRow('notes', 'n1', 'title');
      expect(jsonDecode(titleRowAfterFirst!['valueJson'] as String), 'v1');
      final firstWinnerDot = (titleRowAfterFirst['authorId'], titleRowAfterFirst['authorSeq']);

      // "The process dies here" — nothing about A's state changes further
      // until the next line. Meanwhile B keeps working and produces MORE
      // ops before A's next sync ever runs.
      await dbB.update('notes', {'title': 'v2', 'content': 'body2'}, where: 'id = ?', whereArgs: ['n1']);
      final secondDrain = await drainerB.drain();
      expect(secondDrain.mintedOperations, isNotEmpty);
      await pushB.push(backend: backend, authorId: authorB);

      // "The app restarts and syncs again" — a BRAND-NEW PullPhase
      // instance, never having observed session 1's in-memory call at all,
      // resuming purely from what's durably on disk.
      final resumedPull = PullPhase(dbServiceA, HybridLogicalClock(dbServiceA));
      final secondPullResult = await resumedPull.pull(backend: backend, ownAuthorId: authorA);

      // No skip: exactly the new (post-crash) ops are applied, not zero.
      expect(secondPullResult.operationsApplied, secondDrain.mintedOperations.length);

      final titleRowAfterSecond = await fieldStateRow('notes', 'n1', 'title');
      expect(jsonDecode(titleRowAfterSecond!['valueJson'] as String), 'v2',
          reason: 'the post-crash resume must land the new value, not remain stuck on the pre-crash one');

      // No double-apply: the pre-crash winner dot is not reprocessed as a
      // "new" LIVE candidate a second time — v1 is B's own causal ancestor
      // of v2 (same author, monotonically increasing authorSeq), so it is
      // correctly retained only as a permanent 'field_conflict_superseded'
      // witness (§ Architecture 11.4's chainDom mechanism), never as a
      // live 'field_conflict' row. A double-apply bug that spuriously
      // treated the resumed pull as observing v1 fresh, concurrently with
      // v2, would be exactly the kind of thing that could fork this into a
      // LIVE conflict-copy pair instead.
      final secondWinnerDot = (titleRowAfterSecond['authorId'], titleRowAfterSecond['authorSeq']);
      expect(secondWinnerDot, isNot(firstWinnerDot));
      final liveConflictRows = await dbA.query(
        'sync_conflict_copies',
        where: 'subjectTable = ? AND subjectId = ? AND fieldName = ? AND kind = ?',
        whereArgs: ['notes', 'n1', 'title', 'field_conflict'],
      );
      expect(liveConflictRows, isEmpty,
          reason: 'B is the sole author of both v1 and v2 (a causal chain, not a fork) — a double-apply bug would '
              'be exactly the kind of thing that could spuriously fork this into a LIVE conflict-copy pair');

      // Frontier now reflects BOTH sessions' worth of B's commits, durably —
      // one batched commit per push round (M2.12).
      final frontierAfterSecond =
          await dbA.query('sync_state', where: 'key = ?', whereArgs: ['frontier:$authorB']);
      expect(int.parse(frontierAfterSecond.single['value'] as String), 2);

      // A third pull (nothing new available) must apply zero — the
      // steady-state confirmation that resumption converged cleanly.
      final thirdPullResult = await resumedPull.pull(backend: backend, ownAuthorId: authorA);
      expect(thirdPullResult.operationsApplied, 0);
    });

    test("skips this device's own authorId — a device never pulls its own pushed commits back", () async {
      final dbAA = dbA;
      await dbAA.insert('notes', {
        'id': 'n1',
        'title': 'from A',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final drainerA =
          OutboxDrainer(dbServiceA, identityA, SeqCounter(dbServiceA), HybridLogicalClock(dbServiceA));
      await drainerA.drain();
      await PushPhase(dbServiceA).push(backend: backend, authorId: authorA);

      final result = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(result.operationsApplied, 0);
    });
  });

  group('duplicate delivery', () {
    test('a DuplicateDelivery fault on readCommits does not double-apply or corrupt state', () async {
      final dbB = await dbServiceB.database;
      await dbB.insert('notes', {
        'id': 'n1',
        'title': 'from B',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final drainResult = await drainerB.drain();
      await pushB.push(backend: backend, authorId: authorB);

      final faults = ScriptedFaultQueue();
      faults.enqueue(const DuplicateDelivery(SyncOp.readCommits));
      backend.faultSource = faults;

      final result = await pullA.pull(backend: backend, ownAuthorId: authorA);
      // Exactly one real op is applied despite the duplicate delivery.
      expect(result.operationsApplied, drainResult.mintedOperations.length);

      final titleRow = await fieldStateRow('notes', 'n1', 'title');
      expect(jsonDecode(titleRow!['valueJson'] as String), 'from B');
    });
  });

  group('hasGap handling', () {
    test('stops applying at the gap this round, and resumes correctly on a later call', () async {
      final dbB = await dbServiceB.database;
      // M2.12: one drain now produces ONE batched commit, so three separate
      // drain+push rounds are what give B's log three commits — which is
      // what `OutOfOrderDelivery`'s middle-element removal needs in order to
      // remove something and leave a real hole behind.
      await dbB.insert('notes', {
        'id': 'n1',
        'title': 'from B',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      var totalOps = (await drainerB.drain()).mintedOperations.length;
      await pushB.push(backend: backend, authorId: authorB);
      await dbB.update('notes', {'title': 'from B v2'}, where: 'id = ?', whereArgs: ['n1']);
      totalOps += (await drainerB.drain()).mintedOperations.length;
      await pushB.push(backend: backend, authorId: authorB);
      await dbB.update('notes', {'title': 'from B v3'}, where: 'id = ?', whereArgs: ['n1']);
      totalOps += (await drainerB.drain()).mintedOperations.length;
      final lastPush = await pushB.push(backend: backend, authorId: authorB);
      expect(lastPush.commitCount, 1);

      final allCommits = await backend.readCommits(deviceLogId: authorB, afterSeq: 0);
      expect(allCommits.commits.length, 3);

      final faults = ScriptedFaultQueue();
      faults.enqueue(const OutOfOrderDelivery(SyncOp.readCommits));
      backend.faultSource = faults;

      final first = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(first.gappedDeviceLogIds, [authorB]);
      expect(first.operationsApplied, greaterThan(0));
      expect(first.operationsApplied, lessThan(totalOps));

      // No fault this time -> the rest gets pulled and applied.
      backend.faultSource = null;
      final second = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(second.gappedDeviceLogIds, isEmpty);

      final frontierRows =
          await dbA.query('sync_state', where: 'key = ?', whereArgs: ['frontier:$authorB']);
      // Three commits observed, whatever the operation count inside them.
      expect(int.parse(frontierRows.single['value'] as String), 3);
    });
  });

  group('sync_materialize_queue: missing_referenced_dot blocking + retry', () {
    test('a set_remove referencing an unobserved add-dot is queued, then resolved once the add is pulled', () async {
      const authorX = 'device-X'; // will mint the set_add
      const authorY = 'device-Y'; // will mint the set_remove, observed FIRST

      // M2.7: OR-Set materialization gates on the owning entity's real row
      // already existing (`SyncMaterializer`'s own `missing_exists` queue) —
      // insert it locally so this test exercises ONLY the
      // `missing_referenced_dot` scenario it's actually about, not also
      // tripping the (correct, but orthogonal) `missing_exists` gate.
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'T',
        'content': 'C',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      // note_tags.tagId is a real, enforced FOREIGN KEY -> tags(id) — the
      // member row needs to exist locally too (SyncMaterializer's own
      // missing_exists gate on the OR-Set member, not just the owner).
      await dbA.insert('tags', {'id': 'tag1', 'name': 'tag1', 'color': '#fff', 'createdAt': 1000});

      final removeOp = WireOperation(
        authorId: authorY,
        authorSeq: 1,
        hlc: const Hlc(10, 0),
        kind: 'set_remove',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        targetDots: const [Dot(authorX, 1)],
        frontier: const {authorX: 1, authorY: 1},
      );
      await backend.appendCommit(
        deviceLogId: authorY,
        deviceSeq: 1,
        publishIntentId: 'y-1',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(removeOp),
      );

      final pull1 = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(pull1.operationsBlocked, 1);
      expect(pull1.operationsApplied, 0);

      final queueRows = await dbA.query('sync_materialize_queue', where: 'blockingReason = ?', whereArgs: ['missing_referenced_dot']);
      expect(queueRows, hasLength(1));
      expect(queueRows.single['blockingKey'], '$authorX#1');

      // The set_remove's own frontier bump/observation still happened —
      // round 14's "even if the operation then blocks" property.
      final frontierRows =
          await dbA.query('sync_state', where: 'key = ?', whereArgs: ['frontier:$authorY']);
      expect(int.parse(frontierRows.single['value'] as String), 1);

      // Now the referenced add-dot arrives.
      final addOp = WireOperation(
        authorId: authorX,
        authorSeq: 1,
        hlc: const Hlc(5, 0),
        kind: 'set_add',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        valueJson: jsonEncode(true),
        frontier: const {authorX: 1},
      );
      await backend.appendCommit(
        deviceLogId: authorX,
        deviceSeq: 1,
        publishIntentId: 'x-1',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(addOp),
      );

      final pull2 = await pullA.pull(backend: backend, ownAuthorId: authorA);
      // X's add applies normally this round, and the end-of-round sweep
      // resolves the queued remove.
      expect(pull2.operationsApplied, 1);
      expect(pull2.materializeQueueResolved, 1);

      final queueAfter = await dbA.query('sync_materialize_queue');
      expect(queueAfter, isEmpty);

      // Net effect: add then remove -> no live membership row remains.
      final setRows = await dbA.query('sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tag1']);
      expect(setRows, isEmpty);
    });

    test('a still-unresolved queue entry survives a sweep with no matching add observed', () async {
      const authorY = 'device-Y';
      const authorX = 'device-X';
      final removeOp = WireOperation(
        authorId: authorY,
        authorSeq: 1,
        hlc: const Hlc(10, 0),
        kind: 'set_remove',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        targetDots: const [Dot(authorX, 1)],
        frontier: const {authorX: 1, authorY: 1},
      );
      await backend.appendCommit(
        deviceLogId: authorY,
        deviceSeq: 1,
        publishIntentId: 'y-1',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(removeOp),
      );

      final pull1 = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(pull1.operationsBlocked, 1);

      // Nothing new to observe -> the sweep finds the entry still blocked.
      final pull2 = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(pull2.materializeQueueResolved, 0);
      final queueRows = await dbA.query('sync_materialize_queue');
      expect(queueRows, hasLength(1));
    });
  });

  group('hash-chain verification: linkage', () {
    test('a correctly hash-chained multi-commit log pulls cleanly with no false positive', () async {
      final op1 = WireOperation(
        authorId: 'device-Z',
        authorSeq: 1,
        hlc: const Hlc(1, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('x'),
        frontier: const {'device-Z': 1},
      );
      final firstOutcome = await backend.appendCommit(
        deviceLogId: 'device-Z',
        deviceSeq: 1,
        publishIntentId: 'z-1',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(op1),
      );
      final firstHash = (firstOutcome as AppendCommitSucceeded).commitHash;

      final op2 = WireOperation(
        authorId: 'device-Z',
        authorSeq: 2,
        hlc: const Hlc(2, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'content',
        valueJson: jsonEncode('y'),
        frontier: const {'device-Z': 2},
      );
      await backend.appendCommit(
        deviceLogId: 'device-Z',
        deviceSeq: 2,
        publishIntentId: 'z-2',
        parentCommitHash: firstHash,
        commitBytes: encodeCommitBytes(op2),
      );

      final result = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(result.operationsApplied, 2);
      expect(result.gappedDeviceLogIds, isEmpty);
    });

    test(
        'throws SyncChainVerificationException when a validly-chained new commit disagrees with this '
        "device's own already-recorded pull_tip for that log", () async {
      final op1 = WireOperation(
        authorId: 'device-Z',
        authorSeq: 1,
        hlc: const Hlc(1, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('x'),
        frontier: const {'device-Z': 1},
      );
      final firstOutcome = await backend.appendCommit(
        deviceLogId: 'device-Z',
        deviceSeq: 1,
        publishIntentId: 'z-1',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(op1),
      );
      final firstHash = (firstOutcome as AppendCommitSucceeded).commitHash;

      final firstPull = await pullA.pull(backend: backend, ownAuthorId: authorA);
      expect(firstPull.operationsApplied, 1);
      final tipRow =
          (await dbA.query('sync_state', where: 'key = ?', whereArgs: ['pull_tip:device-Z'])).single;
      expect(tipRow['value'], firstHash);

      // Directly corrupt this device's own recorded pull_tip for device-Z —
      // simulating local corruption (or, equivalently, a hypothetical
      // backend that served a commit belonging to a different chain
      // lineage than what this device last verified). The backend's own
      // chain (op1 -> op2) is perfectly valid; only this device's local
      // bookkeeping disagrees with it now.
      await dbA.update('sync_state', {'value': 'corrupted-hash'},
          where: 'key = ?', whereArgs: ['pull_tip:device-Z']);

      final op2 = WireOperation(
        authorId: 'device-Z',
        authorSeq: 2,
        hlc: const Hlc(2, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'content',
        valueJson: jsonEncode('y'),
        frontier: const {'device-Z': 2},
      );
      await backend.appendCommit(
        deviceLogId: 'device-Z',
        deviceSeq: 2,
        publishIntentId: 'z-2',
        parentCommitHash: firstHash, // the REAL, correct parent hash
        commitBytes: encodeCommitBytes(op2),
      );

      await expectLater(
        pullA.pull(backend: backend, ownAuthorId: authorA),
        throwsA(isA<SyncChainVerificationException>()),
      );
    });
  });

  group('hash-chain verification: content integrity (§ 8.2 item 15b)', () {
    test(
        'a commit-log object tampered in place after being written (debugTamperCommit) is caught '
        'through PullPhase itself, not just in a standalone check against the mock', () async {
      final op = WireOperation(
        authorId: 'device-Z',
        authorSeq: 1,
        hlc: const Hlc(1, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('x'),
        frontier: const {'device-Z': 1},
      );
      await backend.appendCommit(
        deviceLogId: 'device-Z',
        deviceSeq: 1,
        publishIntentId: 'z-1',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(op),
      );

      // Mutates the stored commitBytes in place, WITHOUT recomputing the
      // recorded commitHash to match (a real tamper, not a legitimate
      // replacement) — see MockSyncBackend.debugTamperCommit's own doc
      // comment for why re-hashing on read is expected to catch this.
      backend.debugTamperCommit('device-Z', 1);

      await expectLater(
        pullA.pull(backend: backend, ownAuthorId: authorA),
        throwsA(isA<SyncCommitHashMismatchException>()),
      );

      // And nothing from the tampered commit was applied.
      final titleRow = await fieldStateRow('notes', 'n1', 'title');
      expect(titleRow, isNull);
    });

    test('a tampered SECOND commit in an otherwise-valid chain is still caught, after the first '
        'commit applies cleanly', () async {
      final op1 = WireOperation(
        authorId: 'device-Z',
        authorSeq: 1,
        hlc: const Hlc(1, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('x'),
        frontier: const {'device-Z': 1},
      );
      final firstOutcome = await backend.appendCommit(
        deviceLogId: 'device-Z',
        deviceSeq: 1,
        publishIntentId: 'z-1',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(op1),
      );
      final firstHash = (firstOutcome as AppendCommitSucceeded).commitHash;

      final op2 = WireOperation(
        authorId: 'device-Z',
        authorSeq: 2,
        hlc: const Hlc(2, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'content',
        valueJson: jsonEncode('y'),
        frontier: const {'device-Z': 2},
      );
      await backend.appendCommit(
        deviceLogId: 'device-Z',
        deviceSeq: 2,
        publishIntentId: 'z-2',
        parentCommitHash: firstHash,
        commitBytes: encodeCommitBytes(op2),
      );

      backend.debugTamperCommit('device-Z', 2);

      await expectLater(
        pullA.pull(backend: backend, ownAuthorId: authorA),
        throwsA(isA<SyncCommitHashMismatchException>()),
      );

      // The first, untampered commit still applied before the exception.
      final titleRow = await fieldStateRow('notes', 'n1', 'title');
      expect(jsonDecode(titleRow!['valueJson'] as String), 'x');
      // The tampered second commit did not.
      final contentRow = await fieldStateRow('notes', 'n1', 'content');
      expect(contentRow, isNull);
    });
  });
}
