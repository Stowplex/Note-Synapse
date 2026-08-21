// M2.8, § Architecture 11.8 item 5(a) — "at least one full multi-device
// convergence run through MockSyncBackend."
//
// `sync_session_test.dart` (M2.6) already has a real, genuine two-device
// convergence run — but scoped to exactly what M2.6's own brief needed:
// `notes` (one field conflict, one uncontested field) plus one OR-Set
// membership case. `materializer_test.dart`'s (M2.7) own three-device test
// is similarly scoped narrowly to ITS purpose: proving the round-19 dedup
// mechanism collapses two independently-minted auto-merge write pairs for
// `tags` specifically.
//
// This file is the MORE comprehensive run this milestone's own brief asks
// for: THREE devices, in ONE combined scenario, touching a wider variety
// of operation kinds and entity tables than any single prior milestone's
// test needed to — an ordinary field conflict (`notes.title`), a
// same-name tag collision detected and auto-merged independently by TWO
// different devices (§ 11.6(e), `tags`), an uncontested ordinary field
// write on a different table entirely (`filters.name`), and an OR-Set
// membership add-then-remove observed across all three devices
// (`note_tags`) — all resolved through full `SyncSession.run()` calls
// (drain -> pull -> push, real materialization included) against a single
// shared `MockSyncBackend`, asserting convergence on BOTH `sync_field_
// state`/`sync_set_state` AND the real app-table rows every device ends
// up with.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/mock_sync_backend.dart';

class _Device {
  _Device() : databaseService = DatabaseService.createNew() {
    session = SyncSession(databaseService);
  }

  final DatabaseService databaseService;
  late final SyncSession session;

  Future<Database> get db => databaseService.database;

  Future<void> close() => databaseService.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late MockSyncBackend backend;
  late _Device a;
  late _Device b;
  late _Device c;

  setUp(() async {
    backend = MockSyncBackend();
    a = _Device();
    b = _Device();
    c = _Device();
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await c.close();
  });

  Future<dynamic> fieldValue(_Device d, String table, String id, String field) async {
    final db = await d.db;
    final rows = await db.query(
      'sync_field_state',
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [table, id, field],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['valueJson'] as String);
  }

  /// Every device runs a full sync round, in the same fixed order, `rounds`
  /// times — mirrors `test/sync_protocol/simulator.dart`'s own `syncAllToAll`
  /// shape (repeated all-device rounds to reach full convergence
  /// regardless of call-order asymmetry, § `sync_session_test.dart`'s own
  /// "this asymmetry is a property of call ORDER, not a bug" note).
  Future<void> syncAllDevices({int rounds = 3}) async {
    for (var r = 0; r < rounds; r++) {
      for (final d in [a, b, c]) {
        await d.session.run(backend);
      }
    }
  }

  test(
    'three devices converge across a combined notes/tags/filters/OR-Set scenario — '
    'sync_field_state, sync_set_state, AND the real materialized app-table rows all agree',
    () async {
      final dbA = await a.db;
      final dbB = await b.db;
      final dbC = await c.db;

      // ---- 1. notes: a genuine field conflict --------------------------
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

      // ---- 2. tags: same-name collision, independently detected on TWO
      // different devices (§ 11.6(e) auto-merge) -------------------------
      await dbA.insert('tags', {
        'id': 'tagA',
        'name': 'urgent',
        'color': 'red',
        'createdAt': 1000,
        'usageCount': 0,
        '__deleted__': 0,
        'redirectTarget': null,
      });
      await dbB.insert('tags', {
        'id': 'tagB',
        'name': 'urgent',
        'color': 'blue',
        'createdAt': 1000,
        'usageCount': 0,
        '__deleted__': 0,
        'redirectTarget': null,
      });

      // ---- 3. filters: an ordinary, uncontested field write on a THIRD
      // table entirely, created on the third device ----------------------
      await dbC.insert('filters', {
        'id': 'f1',
        'name': 'My filter',
        'includeText': null,
        'includeTags': '[]',
        'excludeTags': '',
        'noteTypes': '',
        'includeArchived': 0,
        'isPinned': 0,
        'createdAt': 1000,
        'updatedAt': 1000,
        '__deleted__': 0,
      });

      // ---- 4. note_tags: OR-Set membership, add on A -------------------
      await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 'tagA'});

      await syncAllDevices(rounds: 4);

      // ---- 5. note_tags: OR-Set membership, remove on C (observing what
      // synced there), after the add has already converged ---------------
      await dbC.delete('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tagA']);

      await syncAllDevices(rounds: 4);

      // ==== Convergence assertions ========================================

      // notes.title: all three devices agree on the same winner, and it's
      // one of the two genuinely-submitted values.
      final titleA = await fieldValue(a, 'notes', 'n1', 'title');
      final titleB = await fieldValue(b, 'notes', 'n1', 'title');
      final titleC = await fieldValue(c, 'notes', 'n1', 'title');
      expect(titleA, anyOf('from A', 'from B'));
      expect(titleB, titleA);
      expect(titleC, titleA);
      // Real, materialized notes.title row agrees with the resolved winner
      // on every device (M2.7 materialization, not just sync_field_state).
      for (final d in [a, b, c]) {
        final db = await d.db;
        final row = (await db.query('notes', where: 'id = ?', whereArgs: ['n1'])).single;
        expect(row['title'], titleA, reason: '${d.databaseService}: real notes.title must match the resolved winner');
      }

      // tags: auto-merge collapsed the two same-named tags to exactly ONE
      // live tag, identically on all three devices — the round-19 dedup
      // mechanism collapsing two independently-minted auto-merge write
      // pairs to one canonical outcome, now proven across THREE observers,
      // not just the two that authored the collision.
      for (final d in [a, b, c]) {
        final db = await d.db;
        final liveTags = await db.query('tags', where: '__deleted__ = 0 AND redirectTarget IS NULL');
        final liveNamedUrgent = liveTags.where((r) => r['name'] == 'urgent').toList();
        expect(liveNamedUrgent, hasLength(1),
            reason: '${d.databaseService}: exactly one live "urgent" tag must survive the auto-merge, not zero or two');
      }
      // All three devices agree on WHICH tag survived and which redirects.
      final winnerTagIdA =
          (await dbA.query('tags', where: '__deleted__ = 0 AND redirectTarget IS NULL AND name = ?', whereArgs: ['urgent']))
              .single['id'];
      for (final db in [dbB, dbC]) {
        final winnerHere =
            (await db.query('tags', where: '__deleted__ = 0 AND redirectTarget IS NULL AND name = ?', whereArgs: ['urgent']))
                .single['id'];
        expect(winnerHere, winnerTagIdA, reason: 'every device must agree on which tag won the auto-merge');
      }

      // filters.name: uncontested field, fully replicated to A and B from C.
      final filterNameA = await fieldValue(a, 'filters', 'f1', 'name');
      final filterNameB = await fieldValue(b, 'filters', 'f1', 'name');
      expect(filterNameA, 'My filter');
      expect(filterNameB, 'My filter');
      for (final d in [a, b]) {
        final db = await d.db;
        final row = (await db.query('filters', where: 'id = ?', whereArgs: ['f1'])).single;
        expect(row['name'], 'My filter', reason: '${d.databaseService}: real filters row must materialize');
      }

      // note_tags: the OR-Set add-then-remove converges to "not a member"
      // on every device — both in sync_set_state and in the real
      // membership table.
      for (final d in [a, b, c]) {
        final db = await d.db;
        final setRows = await db.query(
          'sync_set_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
          whereArgs: ['notes', 'n1', 'tags', 'tagA'],
        );
        expect(setRows, isEmpty, reason: '${d.databaseService}: sync_set_state must show zero live add-dots after the remove');
        final realRows = await db.query('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tagA']);
        expect(realRows, isEmpty, reason: '${d.databaseService}: real note_tags row must be gone once zero live dots remain');
      }
    },
  );
}
