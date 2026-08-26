// Tests for M2.6's top-level orchestration, `SyncSession`
// (`lib/services/sync/sync_session.dart`) — the first piece of code that
// chains M2.3 (identity/HLC/seq) + M2.4 (outbox) + M2.5 (causal engine) +
// M2.1/M2.2 (`SyncBackend`) together into one callable "do a sync"
// operation: Phase 0 (drain) -> Phase B (pull) -> Phase A (push).
//
// The centerpiece is a full two-device convergence run through
// `MockSyncBackend` — "the connective-tissue test M0 itself structurally
// could not run" (§ 8.6/§ 11.8) and the first point in this milestone
// sequence it's actually buildable: each device mints its own local
// operations, both push, both pull each other's commits, and both must
// converge to the same `sync_field_state`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/mock_sync_backend.dart';

/// A full local device stack (its own database, its own identity) sharing
/// a common [MockSyncBackend] with any other [_SimDevice] in the same test
/// — the minimum needed to run a real, two-sided `SyncSession.run` scenario
/// without hand-authoring wire bytes.
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

  setUp(() async {
    backend = MockSyncBackend();
    deviceA = _SimDevice();
    deviceB = _SimDevice();
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  Future<dynamic> fieldValue(DatabaseService dbService, String table, String id, String field) async {
    final db = await dbService.database;
    final rows = await db.query('sync_field_state',
        where: 'entityTable = ? AND entityId = ? AND fieldName = ?', whereArgs: [table, id, field]);
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['valueJson'] as String);
  }

  group('run() phase ordering', () {
    test('drains local writes, then pushes them — a fresh device with one local note ends up on the backend',
        () async {
      final dbA = await deviceA.db;
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });

      final result = await deviceA.session.run(backend);
      expect(result.drain.mintedOperations, isNotEmpty);
      expect(result.push.publishedCount, result.drain.mintedOperations.length);
      expect(result.pull.operationsApplied, 0); // nothing else on the backend yet

      final authorA = await deviceA.authorId;
      final page = await backend.readCommits(deviceLogId: authorA, afterSeq: 0);
      // M2.12: every drained operation goes out in ONE batched commit.
      expect(page.commits.length, 1);
      expect(result.push.commitCount, 1);
      expect(
        result.push.publishedCount,
        greaterThan(result.push.commitCount),
        reason: 'batching is what makes these two numbers differ at all',
      );
    });

    test('a second call with nothing new locally and nothing new remotely is a safe no-op', () async {
      final dbA = await deviceA.db;
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final first = await deviceA.session.run(backend);
      expect(first.push.publishedCount, greaterThan(0));

      final second = await deviceA.session.run(backend);
      expect(second.drain.mintedOperations, isEmpty);
      expect(second.pull.operationsApplied, 0);
      expect(second.push.publishedCount, 0);
    });
  });

  group('full multi-device convergence through MockSyncBackend', () {
    test('two devices, each minting local operations, converge to the same sync_field_state after '
        'both push and both pull', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;

      // Both devices independently create the SAME note locally (simulating
      // two devices that both already had this note from some earlier,
      // out-of-scope-for-this-test seeding step) — device A sets the title,
      // device B sets a different one, so there's a genuine field conflict
      // to resolve, not just two disjoint fields.
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'from A',
        'content': 'shared body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await dbB.insert('notes', {
        'id': 'n1',
        'title': 'from B',
        'content': 'shared body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      // A second, disjoint note only device A ever creates — should end up
      // fully replicated to B with no conflict at all.
      await dbA.insert('notes', {
        'id': 'n2',
        'title': 'only on A',
        'content': 'body2',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });

      // Round 1: each device drains + pulls (nothing yet) + pushes its own
      // local mints.
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      // Round 2: each device pulls whatever it hasn't already seen and
      // pushes anything new. (Since A ran first in round 1, B's own round-1
      // pull already observed A's round-1 push — so B may already be fully
      // converged by the end of round 1, and only A strictly needs round 2
      // to see B's round-1 push; this asymmetry is a property of call
      // ORDER, not a bug, which is why the assertions below check final
      // convergence rather than operationsApplied at any specific call.)
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      // Converged: both devices' sync_field_state agree on n1's title...
      final titleA = await fieldValue(deviceA.databaseService, 'notes', 'n1', 'title');
      final titleB = await fieldValue(deviceB.databaseService, 'notes', 'n1', 'title');
      expect(titleA, anyOf('from A', 'from B'));
      expect(titleA, titleB, reason: 'both devices must resolve the concurrent title edit identically');

      // ...and on n1's uncontested content field...
      final contentA = await fieldValue(deviceA.databaseService, 'notes', 'n1', 'content');
      final contentB = await fieldValue(deviceB.databaseService, 'notes', 'n1', 'content');
      expect(contentA, 'shared body');
      expect(contentA, contentB);

      // ...and B has fully replicated the disjoint n2 note A alone created.
      final n2TitleB = await fieldValue(deviceB.databaseService, 'notes', 'n2', 'title');
      expect(n2TitleB, 'only on A');

      // The losing side of the title conflict is retained as a conflict
      // copy, identically on both devices (M2.5's resolution surface).
      final conflictsA = await dbA.query('sync_conflict_copies',
          where: 'subjectTable = ? AND subjectId = ? AND fieldName = ? AND kind = ?',
          whereArgs: ['notes', 'n1', 'title', 'field_conflict']);
      final conflictsB = await dbB.query('sync_conflict_copies',
          where: 'subjectTable = ? AND subjectId = ? AND fieldName = ? AND kind = ?',
          whereArgs: ['notes', 'n1', 'title', 'field_conflict']);
      expect(conflictsA.length, conflictsB.length);

      // M2.7 update — BEFORE this milestone, neither device's real `notes`
      // row was ever touched by a pull (materialization did not exist yet):
      // each device's row kept whatever it had locally written itself ("from
      // A" on A, "from B" on B), diverging from `sync_field_state`'s own
      // resolved winner whenever that device lost the conflict. Now that
      // `SyncMaterializer` (M2.7, § 11.6) writes a changed winner into the
      // real row, BOTH devices' real `notes.title` converge to the SAME
      // value `sync_field_state` itself resolved (`titleA`/`titleB`,
      // asserted equal above) — whichever device lost the LWW tie-break has
      // its real row overwritten by the pull that observes the winner,
      // exactly mirroring what already happened to `sync_field_state`.
      final rawTitleA = (await dbA.query('notes', where: 'id = ?', whereArgs: ['n1'])).single['title'];
      final rawTitleB = (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1'])).single['title'];
      expect(rawTitleA, titleA, reason: 'A\'s real row must match the resolved sync_field_state winner');
      expect(rawTitleB, titleB, reason: 'B\'s real row must match the resolved sync_field_state winner');
      expect(rawTitleA, rawTitleB, reason: 'both devices\' real notes.title rows must converge identically');

      // n2 (only ever created on A, no conflict) must materialize into B's
      // real row too — the ordinary, uncontested case.
      final rawN2TitleB = (await dbB.query('notes', where: 'id = ?', whereArgs: ['n2'])).single['title'];
      expect(rawN2TitleB, 'only on A');
    });

    test('OR-Set tag membership converges across two devices', () async {
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
        await db.insert('tags', {'id': 'tag1', 'name': 'work', 'color': '#000000', 'createdAt': 1000});
      }
      await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});

      await deviceA.session.run(backend);
      await deviceB.session.run(backend);
      await deviceA.session.run(backend);
      await deviceB.session.run(backend);

      final setRowsA = await dbA.query('sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tag1']);
      final setRowsB = await dbB.query('sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tag1']);
      expect(setRowsA, isNotEmpty);
      expect(setRowsB, isNotEmpty);

      // M2.7: the real `note_tags` membership row must also materialize on
      // B — B never locally inserted it (only A did); this is the
      // uncontested cross-device `set_add` materialization case.
      final noteTagsB =
          await dbB.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']);
      expect(noteTagsB, isNotEmpty);
    });
  });
}
