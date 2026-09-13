// Tests for M2.7's `SyncMaterializer` (`lib/services/sync/materializer.dart`)
// — § Architecture 11.6, the final piece that writes a resolved
// `sync_field_state`/`sync_set_state` value back into a real `notes`/
// `tags`/... app-table row. Exercised end-to-end through real
// `SyncSession.run()` calls against a shared `MockSyncBackend`, the same
// harness `sync_session_test.dart` (M2.6) already established, for every
// scenario except the cycle-suppression-adjacent one at the bottom (which
// needs to hand-construct a raw redirect cycle no ordinary pull could
// produce organically — the one place this file drives `CausalEngine`/
// `SyncMaterializer` directly with a hand-built `IncomingOperation`).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/materializer.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_session.dart';
import 'package:note_synapse/services/sync/wire_format.dart';

import '../sync_backend/mock_sync_backend.dart';

class _SimDevice {
  _SimDevice() : databaseService = DatabaseService.createNew() {
    session = SyncSession(databaseService);
  }

  final DatabaseService databaseService;
  late final SyncSession session;

  Future<Database> get db => databaseService.database;
  Future<String> get authorId => DeviceIdentity(databaseService).ensureDeviceId();
  Future<void> close() => databaseService.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late MockSyncBackend backend;
  late _SimDevice deviceA;
  late _SimDevice deviceB;

  setUp(() {
    backend = MockSyncBackend();
    deviceA = _SimDevice();
    deviceB = _SimDevice();
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  group('basic field materialization', () {
    test('a pulled winning value lands in the real row, verified by querying it directly', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;

      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });

      await deviceA.session.run(backend); // A drains + pushes
      await deviceB.session.run(backend); // B pulls -> materializes a brand-new row

      final rowB = (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1'])).single;
      expect(rowB['title'], 'Hello');
      expect(rowB['content'], 'World');
      expect(rowB['type'], 'note');

      // A later edit on A propagates as an ordinary field UPDATE on B.
      await dbA.update('notes', {'title': 'Hello, edited', 'updatedAt': 2000}, where: 'id = ?', whereArgs: ['n1']);
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);
      final rowB2 = (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1'])).single;
      expect(rowB2['title'], 'Hello, edited');
      // content untouched by the edit — no redundant write should have
      // disturbed it (and no diff-and-reinsert side effect, since
      // materialization deliberately bypasses updateNote/_persistNote).
      expect(rowB2['content'], 'World');
    });

    test('a losing concurrent edit does not overwrite the winner on either device', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      for (final db in [dbA, dbB]) {
        await db.insert('notes', {
          'id': 'n1',
          'title': 'shared',
          'content': 'body',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
      }
      await dbA.update('notes', {'title': 'from A'}, where: 'id = ?', whereArgs: ['n1']);
      await dbB.update('notes', {'title': 'from B'}, where: 'id = ?', whereArgs: ['n1']);

      await deviceA.session.run(backend);
      await deviceB.session.run(backend);
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      final titleA = (await dbA.query('notes', where: 'id = ?', whereArgs: ['n1'])).single['title'];
      final titleB = (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1'])).single['title'];
      expect(titleA, titleB, reason: 'both real rows must converge to the identical winner');
      expect(titleA, anyOf('from A', 'from B'));
    });
  });

  group('__exists__ materialization', () {
    test('a brand-new entity materializes as a real INSERT, not just a sync_field_state row', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;

      await dbA.insert('filters', {
        'id': 'f1',
        'name': 'My filter',
        'includeText': 'hello',
        'includeTags': '["a"]',
        'excludeTags': '',
        'noteTypes': '',
        'includeArchived': 0,
        'isPinned': 1,
        'createdAt': 1234,
        'updatedAt': 1234,
      });

      final beforePull = await dbB.query('filters', where: 'id = ?', whereArgs: ['f1']);
      expect(beforePull, isEmpty);

      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      final rowB = (await dbB.query('filters', where: 'id = ?', whereArgs: ['f1'])).single;
      expect(rowB['name'], 'My filter');
      expect(rowB['includeText'], 'hello');
      expect(rowB['includeTags'], '["a"]');
      expect(rowB['isPinned'], 1);
      expect(rowB['__deleted__'], 0);
    });

    test('conversations preserve their original creation timestamp', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      await dbA.insert('conversations', {
        'id': 'c1',
        'title': 'Conv',
        'noteIds': '[]',
        'createdAt': 999999,
        'updatedAt': 999999,
        'isArchived': 0,
      });

      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      final rowB = (await dbB.query('conversations', where: 'id = ?', whereArgs: ['c1'])).single;
      expect(rowB['title'], 'Conv');
      expect(rowB['createdAt'], 999999);
    });
  });

  group('OR-Set membership materialization', () {
    test('set_add materializes a real membership row for an uncontested add', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      for (final db in [dbA, dbB]) {
        await db.insert('notes', {
          'id': 'n1',
          'title': 'shared',
          'content': 'body',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await db.insert('tags', {'id': 'tag1', 'name': 'work', 'color': '#000', 'createdAt': 1000});
      }
      await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});

      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      final rowsB = await dbB.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']);
      expect(rowsB, isNotEmpty);
    });

    test('set_remove deletes the real membership row once zero live add-dots remain (the boundary case)', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      for (final db in [dbA, dbB]) {
        await db.insert('notes', {
          'id': 'n1',
          'title': 'shared',
          'content': 'body',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await db.insert('tags', {'id': 'tag1', 'name': 'work', 'color': '#000', 'createdAt': 1000});
      }
      await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});

      // Round 1: add converges to both.
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);
      expect(await dbB.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isNotEmpty);

      // A removes the tag; B must materialize the removal (real DELETE).
      await dbA.delete('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']);
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      final rowsAfter = await dbB.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']);
      expect(rowsAfter, isEmpty);
      // sync_set_state itself must also be empty (no live dots) — the same
      // condition that gates the real-table delete.
      final setStateAfter = await dbB.query('sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tag1']);
      expect(setStateAfter, isEmpty);
    });

    test('a second, concurrent add-dot keeps the member live until BOTH are removed', () async {
      // Hand-crafted, precisely-dotted wire operations (mirroring
      // pull_phase_test.dart's own style) rather than two real devices'
      // ordinary local deletes — an ordinary local `note_tags` DELETE on a
      // real device is captured as an OR-Set "remove everything I can
      // currently see" (matches `OutboxDrainer._processSetTouch`'s own
      // documented semantics: it targets EVERY currently-recorded dot, not
      // just this device's own), so it can't isolate "only ONE of two
      // concurrent add-dots was removed" — a `set_remove` that targets a
      // SPECIFIC single dot only reaches this device via a remote,
      // independently-authored operation.
      final dbA = await deviceA.db;
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'shared',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await dbA.insert('tags', {'id': 'tag1', 'name': 'work', 'color': '#000', 'createdAt': 1000});

      const authorX = 'device-X';
      const authorY = 'device-Y';
      const authorZ = 'device-Z';

      final tips = <String, String?>{};
      Future<void> push(String deviceLogId, int seq, WireOperation op) async {
        final parent = tips[deviceLogId];
        final outcome = await backend.appendCommit(
          deviceLogId: deviceLogId,
          deviceSeq: seq,
          publishIntentId: '$deviceLogId-$seq',
          parentCommitHash: parent,
          commitBytes: encodeCommitBytes(op),
        );
        tips[deviceLogId] = (outcome as AppendCommitSucceeded).commitHash;
      }

      await push(
        authorX,
        1,
        WireOperation(
          authorId: authorX,
          authorSeq: 1,
          hlc: const Hlc(10, 0),
          kind: 'set_add',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'tags',
          memberUuid: 'tag1',
          valueJson: jsonEncode(true),
          frontier: const {authorX: 1},
        ),
      );
      await push(
        authorY,
        1,
        WireOperation(
          authorId: authorY,
          authorSeq: 1,
          hlc: const Hlc(11, 0),
          kind: 'set_add',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'tags',
          memberUuid: 'tag1',
          valueJson: jsonEncode(true),
          frontier: const {authorY: 1},
        ),
      );

      await deviceA.session.run(backend);

      expect(await dbA.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isNotEmpty);
      final setStateAfterBothAdds = await dbA.query('sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tag1']);
      expect(setStateAfterBothAdds, hasLength(2));

      // A remote set_remove targeting ONLY X's dot — Y's add-dot is
      // untouched and still live.
      await push(
        authorZ,
        1,
        WireOperation(
          authorId: authorZ,
          authorSeq: 1,
          hlc: const Hlc(20, 0),
          kind: 'set_remove',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'tags',
          memberUuid: 'tag1',
          targetDots: const [Dot(authorX, 1)],
          frontier: const {authorX: 1, authorZ: 1},
        ),
      );
      await deviceA.session.run(backend);

      expect(await dbA.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isNotEmpty,
          reason: 'Y\'s independent add-dot is still live — the member must stay materialized');
      final setStateAfterOneRemove = await dbA.query('sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tag1']);
      expect(setStateAfterOneRemove, hasLength(1));

      // Now Y's own dot is targeted too — only then must the real row go.
      await push(
        authorZ,
        2,
        WireOperation(
          authorId: authorZ,
          authorSeq: 2,
          hlc: const Hlc(21, 0),
          kind: 'set_remove',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'tags',
          memberUuid: 'tag1',
          targetDots: const [Dot(authorY, 1)],
          frontier: const {authorX: 1, authorY: 1, authorZ: 2},
        ),
      );
      await deviceA.session.run(backend);

      expect(await dbA.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isEmpty);
      final setStateAfterBothRemoves = await dbA.query('sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tag1']);
      expect(setStateAfterBothRemoves, isEmpty);
    });

    test('a set_add whose OWNER and MEMBER are both missing at first attempt does not wedge sync once the '
        'owner alone resolves and the member still has not (regression for the confirmed NO-GO finding)', () async {
      // Reproduces the exact failure mode found during review: a prior
      // version of _materializeSetAdd checked owner-then-member and
      // short-circuited on the FIRST missing one, recording only THAT one
      // as `waitingOn` — so when BOTH were missing, only the owner ever got
      // recorded. If the owner alone later resolved while the member still
      // hadn't, sweepMissingExists trusted the single recorded blocker and
      // attempted the INSERT blindly, which threw a real FOREIGN KEY
      // violation (ConflictAlgorithm.ignore does NOT suppress FK
      // violations), uncaught out of SyncSession.run() — aborting the
      // entire session (including any of the user's own unrelated pending
      // pushes) and, since the queue row was never cleared, recurring on
      // EVERY future sync attempt: a permanent sync outage for that device.
      final dbA = await deviceA.db;

      const authorX = 'device-X'; // mints the set_add
      const authorY = 'device-Y'; // later mints notes/n1's own __exists__
      const authorZ = 'device-Z'; // later mints tags/tag1's own __exists__

      final tips = <String, String?>{};
      Future<void> push(String deviceLogId, int seq, WireOperation op) async {
        final parent = tips[deviceLogId];
        final outcome = await backend.appendCommit(
          deviceLogId: deviceLogId,
          deviceSeq: seq,
          publishIntentId: '$deviceLogId-$seq',
          parentCommitHash: parent,
          commitBytes: encodeCommitBytes(op),
        );
        tips[deviceLogId] = (outcome as AppendCommitSucceeded).commitHash;
      }

      // The set_add arrives FIRST — neither its owning note nor its member
      // tag exists locally on A yet. Both are missing simultaneously.
      await push(
        authorX,
        1,
        WireOperation(
          authorId: authorX,
          authorSeq: 1,
          hlc: const Hlc(10, 0),
          kind: 'set_add',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'tags',
          memberUuid: 'tag1',
          valueJson: jsonEncode(true),
          frontier: const {authorX: 1},
        ),
      );
      await deviceA.session.run(backend);

      // Still nothing materialized, and no crash — one queue row, blocked
      // on WHICHEVER prerequisite is checked first (the owner).
      expect(await dbA.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isEmpty);
      var queueRows = await dbA.query('sync_materialize_queue', where: 'blockingReason = ?', whereArgs: ['missing_exists']);
      expect(queueRows, hasLength(1));

      // Now ONLY the owner (notes/n1) resolves — the member (tags/tag1)
      // deliberately still does not exist anywhere. Under the confirmed bug,
      // the very next sweep would blindly INSERT into note_tags and throw a
      // FK violation, uncaught, right here.
      await push(
        authorY,
        1,
        WireOperation(
          authorId: authorY,
          authorSeq: 1,
          hlc: const Hlc(20, 0),
          kind: '__exists__',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: '__exists__',
          valueJson: jsonEncode(true),
          frontier: const {authorY: 1},
        ),
      );

      // Must complete WITHOUT throwing.
      await deviceA.session.run(backend);

      // The note itself is now a real (shell) row...
      expect(await dbA.query('notes', where: 'id = ?', whereArgs: ['n1']), isNotEmpty);
      // ...but the membership must still NOT be materialized (the member
      // tag genuinely does not exist yet) — and, critically, the queue
      // entry must still be present (not silently dropped) and now correctly
      // re-pointed at the member, not stuck referencing the now-resolved
      // owner forever.
      expect(await dbA.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isEmpty);
      queueRows = await dbA.query('sync_materialize_queue', where: 'blockingReason = ?', whereArgs: ['missing_exists']);
      expect(queueRows, hasLength(1));
      final payload = jsonDecode(queueRows.single['operationJson'] as String) as Map<String, dynamic>;
      expect(payload['waitingOnTable'], 'tags');
      expect(payload['waitingOnId'], 'tag1');

      // A second sync with STILL no tag must also complete safely and
      // change nothing (no repeated crash, no duplicate queue rows).
      await deviceA.session.run(backend);
      expect(await dbA.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isEmpty);
      expect(
          await dbA.query('sync_materialize_queue', where: 'blockingReason = ?', whereArgs: ['missing_exists']),
          hasLength(1));

      // Finally the member tag resolves too — NOW the membership must
      // materialize and the queue must drain.
      await push(
        authorZ,
        1,
        WireOperation(
          authorId: authorZ,
          authorSeq: 1,
          hlc: const Hlc(30, 0),
          kind: '__exists__',
          entityTable: 'tags',
          entityId: 'tag1',
          fieldName: '__exists__',
          valueJson: jsonEncode(true),
          frontier: const {authorZ: 1},
        ),
      );
      await deviceA.session.run(backend);

      expect(await dbA.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']), isNotEmpty);
      expect(
          await dbA.query('sync_materialize_queue', where: 'blockingReason = ?', whereArgs: ['missing_exists']),
          isEmpty);
    });
  });

  group('§ 11.6(e) auto-merge / tag name collision', () {
    test('two devices concurrently create same-named tags -> exactly one survives live, the other redirects, '
        'and the resolution is minted mid-pull and pushed within the SAME session', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      final authorA = await deviceA.authorId;

      const tagA = 'tagA-uuid';
      const tagB = 'tagB-uuid';
      await dbA.insert('tags', {'id': tagA, 'name': 'urgent', 'color': '#111', 'createdAt': 1000});
      await dbB.insert('tags', {'id': tagB, 'name': 'urgent', 'color': '#222', 'createdAt': 1000});

      // Each device pushes its own creation first, with neither having
      // observed the other yet (genuine concurrency).
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      // A now pulls B's tag — this is where A's own collision check first
      // fires (§ 11.6(e), mid-pull), and where, per requirement 7, its
      // resolution must be minted AND pushed within this SAME run() call
      // (Phase B pull -> Phase A push, `sync_session.dart`'s own ordering).
      await deviceA.session.run(backend);

      final rowsA = await dbA.query('tags', where: 'id IN (?, ?)', whereArgs: [tagA, tagB]);
      final liveA = rowsA.where((r) => r['__deleted__'] == 0 && r['redirectTarget'] == null).toList();
      final tombstonedA = rowsA.where((r) => r['__deleted__'] == 1).toList();
      expect(liveA, hasLength(1), reason: 'exactly one of the two same-named tags must survive live');
      expect(tombstonedA, hasLength(1));
      final winnerId = liveA.single['id'] as String;
      final loserId = tombstonedA.single['id'] as String;
      expect(tombstonedA.single['redirectTarget'], winnerId);

      // The mint-mid-pull-then-push-same-session claim, verified directly
      // (not just reasoned about): the auto-merge write pair for the loser
      // must already be present in A's OWN sync_pending_ops, authored by A,
      // with publishedAt already stamped by the END of this ONE run() call.
      // Filtered to `contentKey IS NOT NULL` specifically: if the loser
      // happens to be A's OWN originally-created tag (a real, symmetric
      // outcome this test doesn't force either way — see the comment
      // above), A's own ORDINARY creation-time __deleted__/redirectTarget
      // writes (no contentKey) ALSO match entityId/fieldName, and must not
      // be confused with the auto-merge mint pair specifically (which
      // always carries one, per round 19's dedup fix).
      final mintedOps = await dbA.query(
        'sync_pending_ops',
        where: 'authorId = ? AND entityTable = ? AND entityId = ? AND fieldName IN (?, ?) AND contentKey IS NOT NULL',
        whereArgs: [authorA, 'tags', loserId, '__deleted__', 'redirectTarget'],
      );
      expect(mintedOps, hasLength(2));
      for (final row in mintedOps) {
        expect(row['publishedAt'], isNotNull, reason: 'must be pushed within the same session, per § 11.6(e)');
        expect(row['contentKey'], isNotNull, reason: 'auto-merge writes must carry a contentKey (round-19 dedup)');
      }

      // B independently detects the identical collision on its own next
      // pull (both directions of the write-driven transition are checked —
      // see materializer.dart's own top doc comment) and must resolve to
      // the SAME winner, not a different one and not a raw redirectTarget
      // cycle.
      await deviceB.session.run(backend);
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      final rowsB = await dbB.query('tags', where: 'id IN (?, ?)', whereArgs: [tagA, tagB]);
      final liveB = rowsB.where((r) => r['__deleted__'] == 0 && r['redirectTarget'] == null).toList();
      expect(liveB, hasLength(1));
      expect(liveB.single['id'], winnerId, reason: 'B must converge to the SAME winner A computed');

      // A third, independent device pulling from BOTH A and B's logs (via
      // the shared backend) must converge to the identical, non-duplicated
      // outcome — confirming the round-19 contentKey dedup actually
      // prevents a spurious visible conflict from two independently-minted,
      // identical-outcome auto-merge write pairs.
      final deviceC = _SimDevice();
      addTearDown(deviceC.close);
      await deviceC.session.run(backend);
      await deviceC.session.run(backend); // second round, in case of ordering gaps

      final dbC = await deviceC.db;
      final rowsC = await dbC.query('tags', where: 'id IN (?, ?)', whereArgs: [tagA, tagB]);
      final liveC = rowsC.where((r) => r['__deleted__'] == 0 && r['redirectTarget'] == null).toList();
      expect(liveC, hasLength(1));
      expect(liveC.single['id'], winnerId);

      // No spurious, permanent field_conflict noise for the auto-merge
      // fields themselves (round-19's whole point).
      final spuriousConflicts = await dbC.query(
        'sync_conflict_copies',
        where: 'subjectTable = ? AND subjectId = ? AND fieldName IN (?, ?) AND kind = ?',
        whereArgs: ['tags', loserId, '__deleted__', 'redirectTarget', 'field_conflict'],
      );
      expect(spuriousConflicts, isEmpty);
    });

    test('replaceTag reconciliation: a REMOTE device\'s manual merge materializes correctly on the '
        'pulling device, traced end-to-end rather than assumed', () async {
      // M2.4 already made replaceTag populate redirectTarget, but only for
      // the REAL-MERGE branch (`isRealMerge`, i.e. a live 'new' tag already
      // exists) — the plain-rename branch deliberately never sets it
      // (database_service.dart's own doc comment: "not the same tag,
      // redirected"). So the real-merge branch needs BOTH 'old' and 'new'
      // already live locally on A before replaceTag runs.
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      const oldId = 'old-tag-uuid';
      const newId = 'new-tag-uuid';
      for (final db in [dbA, dbB]) {
        await db.insert('tags', {'id': oldId, 'name': 'old', 'color': '#111', 'createdAt': 1000});
        await db.insert('tags', {'id': newId, 'name': 'new', 'color': '#222', 'createdAt': 1000});
      }

      await deviceA.session.run(backend);
      await deviceB.session.run(backend); // B observes both tags before the merge, like a real prior-sync state

      // A performs a real, manual merge — 'new' already exists live, so
      // isRealMerge=true and old's tombstone carries redirectTarget=newId
      // in the same write (the M2.4 replaceTag fix this test reconciles).
      await deviceA.databaseService.replaceTag('old', 'new');
      final oldRowA = (await dbA.query('tags', where: 'id = ?', whereArgs: [oldId])).single;
      expect(oldRowA['__deleted__'], 1);
      expect(oldRowA['redirectTarget'], newId, reason: 'sanity check: this must be the real-merge branch');

      await deviceA.session.run(backend);
      await deviceB.session.run(backend);
      await deviceB.session.run(backend); // second round in case the two fields land in separate commits

      // B must materialize BOTH sides: 'new' stays live and untouched, and
      // 'old' is correctly tombstoned+redirecting — an ordinary ambient
      // field-write materialization, not the collision path (redirectTarget
      // is becoming NON-null here, the opposite of what triggers § 11.6(e)).
      final oldRowB = (await dbB.query('tags', where: 'id = ?', whereArgs: [oldId])).single;
      expect(oldRowB['__deleted__'], 1);
      expect(oldRowB['redirectTarget'], newId);

      final newRowB = await dbB.query('tags', where: 'id = ? AND __deleted__ = 0', whereArgs: [newId]);
      expect(newRowB, isNotEmpty);
      expect(newRowB.single['name'], 'new');
      expect(newRowB.single['__deleted__'], 0);
      expect(newRowB.single['redirectTarget'], isNull);
    });
  });

  group('cycle-suppression-adjacent collision detection', () {
    test('a raw-tombstoned, cycle-suppressed (effectively-live) tag is still treated as live for '
        'collision purposes, even though findLiveTagByName alone would miss it', () async {
      final dbA = await deviceA.db;

      // Hand-construct a 2-cycle directly at the DB/sync_field_state level
      // (the read-path walk that discovers cycles organically is explicitly
      // out of this milestone's scope — see materializer.dart's top doc
      // comment): T1 "urgent" <-> T2 "important", both raw-tombstoned,
      // redirecting at each other.
      const t1 = 't1-uuid';
      const t2 = 't2-uuid';
      await dbA.insert('tags', {
        'id': t1,
        'name': 'urgent',
        'color': '#111',
        'createdAt': 1000,
        '__deleted__': 1,
        'redirectTarget': t2,
      });
      await dbA.insert('tags', {
        'id': t2,
        'name': 'important',
        'color': '#222',
        'createdAt': 1000,
        '__deleted__': 1,
        'redirectTarget': t1,
      });

      // sync_field_state needs real dots for both tags' __exists__ and
      // redirectTarget writes for the tie-break to be computable —
      // T1's redirect-write dot is made LOWER-ranked than T2's, so T1 is
      // the suppressed (effectively-live) cycle member, per § Architecture
      // 10's tie-break (lowest (authorId, authorSeq) wins).
      Future<void> writeFieldState(String tagId, String field, {required String authorId, required int seq}) async {
        await dbA.insert('sync_field_state', {
          'entityTable': 'tags',
          'entityId': tagId,
          'fieldName': field,
          'valueJson': field == '__exists__' ? jsonEncode(true) : jsonEncode(field == 'redirectTarget'
              ? (tagId == t1 ? t2 : t1)
              : null),
          'blobHash': null,
          'authorId': authorId,
          'authorSeq': seq,
          'hlc': Hlc(1000, seq).toString(),
          'contentKey': null,
          'frontierJson': jsonEncode({authorId: seq}),
          'updatedAt': 1000,
        });
      }

      await writeFieldState(t1, '__exists__', authorId: 'dev1', seq: 1);
      await writeFieldState(t2, '__exists__', authorId: 'dev2', seq: 1);
      // T1's own redirect-write dot ("dev1", seq 2) is lexicographically
      // LOWER than T2's ("dev2", seq 2) -> T1 is the suppressed member.
      await writeFieldState(t1, 'redirectTarget', authorId: 'dev1', seq: 2);
      await writeFieldState(t2, 'redirectTarget', authorId: 'dev2', seq: 2);

      // A brand-new incoming tag also named "urgent" now arrives, undeleted
      // (a write-driven liveness-flipping transition, § 11.6(e)) — this
      // must collide against T1 (the cycle-suppressed, effectively-live
      // member), even though findLiveTagByName's raw-liveness-only view
      // would report T1 as tombstoned and see no collision at all.
      const incoming = 'incoming-uuid';
      await dbA.insert('tags', {
        'id': incoming,
        'name': 'urgent',
        'color': '#333',
        'createdAt': 2000,
        '__deleted__': 1, // materializer's own forced-tombstone-at-insert convention
        'redirectTarget': null,
      });
      await writeFieldState(incoming, '__exists__', authorId: 'dev3', seq: 1);

      // Standalone use of CausalEngine + SyncMaterializer directly (no full
      // pull loop needed for this narrow, DB-state-driven scenario) —
      // exactly the two collaborators `pull_phase.dart` itself wires
      // together, called the same way.
      final engine = CausalEngine();
      final materializer =
          SyncMaterializer(SeqCounter(deviceA.databaseService), HybridLogicalClock(deviceA.databaseService));
      final db = await deviceA.databaseService.database;
      await db.transaction((txn) async {
        final op = IncomingOperation(
          dot: const Dot('dev3', 2),
          hlc: const Hlc(2000, 0),
          kind: 'field',
          entityTable: 'tags',
          entityId: incoming,
          fieldName: '__deleted__',
          valueJson: jsonEncode(0),
          frontier: const {'dev3': 2},
        );
        final result = await engine.apply(txn, op);
        await materializer.materialize(txn, op: op, result: result, ownAuthorId: 'this-device');
      });

      final incomingRow = (await dbA.query('tags', where: 'id = ?', whereArgs: [incoming])).single;
      // The incoming tag must have LOST the collision (T1's creation dot
      // ("dev1", 1) is lower than the incoming tag's ("dev3", 1)) and been
      // amended to redirect to T1, the cycle-suppressed effectively-live
      // member — not silently allowed to become live and violate
      // idx_tags_name_live's spirit (a real, raw UNIQUE violation is
      // avoided here specifically because the collision check ran first).
      expect(incomingRow['__deleted__'], 1);
      expect(incomingRow['redirectTarget'], t1);
    });
  });
}
