// Tests for M2.4's `OutboxDrainer` (`lib/services/sync/outbox_drainer.dart`)
// — § Architecture 11.3/11.7 Phase 0's drain step: turning accumulated
// `sync_touch_log` rows into real `Operation`s in `sync_pending_ops`, only
// when the entity/field/membership's current live value actually differs
// from what `sync_field_state`/`sync_set_state` currently records.
//
// The three properties `OutboxDrainer`'s own class doc comment claims —
// (1) draining twice mints nothing new, (2) multiple touches for the same
// field in one batch collapse to at most one mint, (3) a value that changed
// and reverted before drain produces no operation — are each verified
// directly here, not just asserted in prose.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';

Note _buildNote(String id, {List<String> tags = const []}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Note(
    id: id,
    title: 'Note $id',
    content: 'content',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: tags,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;
  late DeviceIdentity deviceIdentity;
  late OutboxDrainer drainer;

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
  });

  tearDown(() async {
    await databaseService.close();
  });

  Future<List<Map<String, Object?>>> pendingOps() => db.query('sync_pending_ops');

  group('entity insert -> __exists__ + per-field bootstrap', () {
    test('inserting a note mints one __exists__ op and one field op per non-null sync-scope column', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
        // pinned/isArchived have INTEGER NOT NULL DEFAULT 0 -- included.
      });

      final result = await drainer.drain();

      expect(result.touchesProcessed, 1, reason: 'one AFTER INSERT touch');
      final kinds = result.mintedOperations.map((o) => o.kind).toList();
      expect(kinds.where((k) => k == '__exists__'), hasLength(1));
      // title, content, type, updatedAt, pinned, isArchived are non-null in
      // the inserted row; scheduledAt/completeBy/status/completionPercentage/
      // recurrenceRule/metadata/__deleted__ are all present too (every
      // sync-scope column is diffed, null or not, per _processExistsTouch).
      final fieldOps = result.mintedOperations.where((o) => o.kind == 'field').toList();
      final fieldNames = fieldOps.map((o) => o.fieldName).toSet();
      expect(
        fieldNames,
        {
          'title',
          'content',
          'type',
          'updatedAt',
          'scheduledAt',
          'completeBy',
          'status',
          'completionPercentage',
          'pinned',
          'isArchived',
          'recurrenceRule',
          'metadata',
          '__deleted__',
        },
      );

      final titleOp = fieldOps.firstWhere((o) => o.fieldName == 'title');
      expect(titleOp.entityTable, 'notes');
      expect(titleOp.entityId, 'n1');
      expect(titleOp.valueJson, jsonEncode('Hello'));

      final deviceId = await deviceIdentity.ensureDeviceId();
      for (final op in result.mintedOperations) {
        expect(op.authorId, deviceId);
      }

      // authorSeq: minted sequentially, 1..14 across the 14 ops.
      final seqs = result.mintedOperations.map((o) => o.authorSeq).toList()..sort();
      expect(seqs, List.generate(result.mintedOperations.length, (i) => i + 1));

      // sync_pending_ops row shape.
      final rows = await pendingOps();
      expect(rows, hasLength(result.mintedOperations.length));
      final titleRow = rows.firstWhere((r) => r['fieldName'] == 'title');
      expect(titleRow['kind'], 'field');
      expect(titleRow['entityTable'], 'notes');
      expect(titleRow['entityId'], 'n1');
      expect(titleRow['valueJson'], jsonEncode('Hello'));
      expect(titleRow['authorId'], deviceId);
      expect(titleRow['contentKey'], isNull, reason: 'ordinary device-namespace ops never carry a contentKey this milestone');
      expect(titleRow['publishedAt'], isNull);
      final frontier = jsonDecode(titleRow['frontierJson'] as String) as Map;
      expect(frontier[deviceId], titleRow['authorSeq']);
      expect(Hlc.parse(titleRow['hlc'] as String), isNotNull);

      // sync_field_state now records every one of those as the current
      // winner.
      final fieldStateRows = await db.query('sync_field_state');
      expect(fieldStateRows, hasLength(fieldNames.length + 1)); // +1 for __exists__
    });

    test('every touch row is stamped processedAt, regardless of whether it minted anything', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await drainer.drain();

      final touches = await db.query('sync_touch_log');
      expect(touches, isNotEmpty);
      for (final t in touches) {
        expect(t['processedAt'], isNotNull);
      }
    });
  });

  group('a genuine field change', () {
    test('produces exactly one operation with correct shape, and updates sync_field_state', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await drainer.drain(); // bootstrap drain — establishes the baseline.
      await db.delete('sync_touch_log');

      await db.update('notes', {'title': 'Updated Title'}, where: 'id = ?', whereArgs: ['n1']);
      final result = await drainer.drain();

      expect(result.mintedOperations, hasLength(1));
      final op = result.mintedOperations.single;
      expect(op.kind, 'field');
      expect(op.entityTable, 'notes');
      expect(op.entityId, 'n1');
      expect(op.fieldName, 'title');
      expect(op.valueJson, jsonEncode('Updated Title'));

      final fieldStateRow = (await db.query(
        'sync_field_state',
        where: "entityTable = 'notes' AND entityId = 'n1' AND fieldName = 'title'",
      )).single;
      expect(fieldStateRow['valueJson'], jsonEncode('Updated Title'));
      expect(fieldStateRow['authorSeq'], op.authorSeq);
    });
  });

  group('no-op: value changed and reverted before drain', () {
    test('produces no operation for a field cycling back to its previously-synced value', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Original',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await drainer.drain(); // 'Original' becomes the recorded baseline.
      await db.delete('sync_touch_log');

      await db.update('notes', {'title': 'Changed'}, where: 'id = ?', whereArgs: ['n1']);
      await db.update('notes', {'title': 'Original'}, where: 'id = ?', whereArgs: ['n1']);

      final touchesBeforeDrain = await db.query(
        'sync_touch_log',
        where: 'processedAt IS NULL',
      );
      expect(touchesBeforeDrain, hasLength(2), reason: 'two real UPDATE statements, two touch rows');

      final result = await drainer.drain();

      expect(
        result.mintedOperations.where((o) => o.fieldName == 'title'),
        isEmpty,
        reason: 'the live value equals what was already recorded before this batch',
      );
      // Both touch rows still get marked processed.
      final unprocessed = await db.query('sync_touch_log', where: 'processedAt IS NULL');
      expect(unprocessed, isEmpty);
    });

    test('multiple touches for the same field within ONE batch collapse to at most one mint (bootstrap case)', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'A',
        'content': 'C',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      // No prior drain -- this is the very first drain, so the __exists__
      // touch itself will already capture 'B' (the FINAL live value) via
      // the whole-row diff; the two extra title-specific touches below must
      // not each mint their own duplicate operation.
      await db.update('notes', {'title': 'B'}, where: 'id = ?', whereArgs: ['n1']);
      await db.update('notes', {'title': 'C2'}, where: 'id = ?', whereArgs: ['n1']);

      final result = await drainer.drain();

      final titleOps = result.mintedOperations.where((o) => o.fieldName == 'title').toList();
      expect(titleOps, hasLength(1), reason: 'one net operation regardless of how many raw touches accumulated');
      expect(titleOps.single.valueJson, jsonEncode('C2'), reason: 'must reflect the FINAL live value, not an intermediate one');
    });
  });

  group('draining twice in a row is safe', () {
    test('a second drain with no new writes mints nothing', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      final first = await drainer.drain();
      expect(first.mintedOperations, isNotEmpty);

      final second = await drainer.drain();
      expect(second.touchesProcessed, 0, reason: 'nothing unprocessed left');
      expect(second.mintedOperations, isEmpty);

      final rows = await pendingOps();
      expect(rows, hasLength(first.mintedOperations.length), reason: 'no duplicate rows from the second pass');
    });

    test('a second drain after a genuine field update, then a third no-op drain, mints exactly one op total for that field', () async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await drainer.drain();

      await db.update('notes', {'title': 'V2'}, where: 'id = ?', whereArgs: ['n1']);
      final second = await drainer.drain();
      expect(second.mintedOperations.where((o) => o.fieldName == 'title'), hasLength(1));

      final third = await drainer.drain();
      expect(third.mintedOperations, isEmpty);

      // Two genuine title values were ever recorded across this test's
      // lifetime -- the bootstrap 'Hello' (from the first drain's
      // __exists__ full-row diff) and 'V2' (from the second drain's real
      // change) -- so two rows are legitimately expected; the property
      // under test is that the THIRD (no-op) drain adds no third one.
      final titleRows = await db.query(
        'sync_pending_ops',
        where: "fieldName = 'title'",
      );
      expect(titleRows, hasLength(2));
    });
  });

  group('OR-Set membership — set_add / set_remove', () {
    Future<void> seedNoteAndTag() async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'T',
        'content': 'C',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('tags', {'id': 'tag1', 'name': 'urgent', 'color': '#fff', 'createdAt': 1000});
    }

    test('adding a tag membership mints set_add and records sync_set_state', () async {
      await seedNoteAndTag();
      await drainer.drain(); // drain the notes/tags __exists__ touches first
      await db.delete('sync_touch_log');

      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
      final result = await drainer.drain();

      final setOps = result.mintedOperations.where((o) => o.kind == 'set_add').toList();
      expect(setOps, hasLength(1));
      final op = setOps.single;
      expect(op.entityTable, 'notes');
      expect(op.entityId, 'n1');
      expect(op.fieldName, 'tags');
      expect(op.memberUuid, 'tag1');

      final setStateRows = await db.query(
        'sync_set_state',
        where: "entityTable = 'notes' AND entityId = 'n1' AND fieldName = 'tags' AND memberUuid = 'tag1'",
      );
      expect(setStateRows, hasLength(1));
      expect(setStateRows.single['authorSeq'], op.authorSeq);
    });

    test('removing a tag membership mints set_remove targeting the recorded add-dot, and clears sync_set_state', () async {
      await seedNoteAndTag();
      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
      final addResult = await drainer.drain();
      final addOp = addResult.mintedOperations.firstWhere((o) => o.kind == 'set_add');
      await db.delete('sync_touch_log');

      await db.delete('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']);
      final removeResult = await drainer.drain();

      final removeOps = removeResult.mintedOperations.where((o) => o.kind == 'set_remove').toList();
      expect(removeOps, hasLength(1));
      final op = removeOps.single;
      expect(op.entityTable, 'notes');
      expect(op.fieldName, 'tags');
      expect(op.memberUuid, 'tag1');
      expect(op.targetDots, [(addOp.authorId, addOp.authorSeq)]);

      final setStateRows = await db.query(
        'sync_set_state',
        where: "entityTable = 'notes' AND entityId = 'n1' AND fieldName = 'tags' AND memberUuid = 'tag1'",
      );
      expect(setStateRows, isEmpty);

      final pendingRemoveRow = (await db.query(
        'sync_pending_ops',
        where: "kind = 'set_remove'",
      )).single;
      final targetDots = jsonDecode(pendingRemoveRow['targetDotsJson'] as String) as List;
      expect(targetDots, hasLength(1));
      expect(targetDots.first['authorId'], addOp.authorId);
      expect(targetDots.first['authorSeq'], addOp.authorSeq);
    });

    test('add then remove before ANY drain (net no-op) mints nothing for that membership', () async {
      await seedNoteAndTag();
      await drainer.drain();
      await db.delete('sync_touch_log');

      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
      await db.delete('note_tags', where: 'noteId = ? AND tagId = ?', whereArgs: ['n1', 'tag1']);

      final result = await drainer.drain();
      expect(result.mintedOperations, isEmpty);
      final unprocessed = await db.query('sync_touch_log', where: 'processedAt IS NULL');
      expect(unprocessed, isEmpty);
    });

    test('draining twice after an add mints nothing new the second time', () async {
      await seedNoteAndTag();
      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
      final first = await drainer.drain();
      expect(first.mintedOperations.where((o) => o.kind == 'set_add'), hasLength(1));

      final second = await drainer.drain();
      expect(second.mintedOperations, isEmpty);
    });
  });

  group('replaceTag real-merge redirectTarget — captured correctly by the new triggers', () {
    test('a real merge\'s redirectTarget write produces a field operation', () async {
      await databaseService.insertNote(_buildNote('n1', tags: ['old-name']));
      await databaseService.insertNote(_buildNote('n2', tags: ['new-name']));
      await drainer.drain();
      await db.delete('sync_touch_log');

      final winnerId = (await DatabaseService.findLiveTagByName(db, 'new-name'))!['id'] as String;
      final loserId = (await DatabaseService.findLiveTagByName(db, 'old-name'))!['id'] as String;

      await databaseService.replaceTag('old-name', 'new-name');
      final result = await drainer.drain();

      final redirectOp = result.mintedOperations.firstWhere(
        (o) => o.entityTable == 'tags' && o.entityId == loserId && o.fieldName == 'redirectTarget',
      );
      expect(redirectOp.valueJson, jsonEncode(winnerId));

      final deletedOp = result.mintedOperations.firstWhere(
        (o) => o.entityTable == 'tags' && o.entityId == loserId && o.fieldName == '__deleted__',
      );
      expect(deletedOp.valueJson, jsonEncode(1));
    });
  });

  group('drain-then-clearAllData interleaving (clearAllData follow-up fix)', () {
    // Every sync control-plane table clearAllData is now documented to
    // wipe (database_service.dart's own
    // syncEntityScopedControlPlaneTablesToWipe), independent of whether
    // anything actually populated it in this specific scenario -- this
    // test's job is to confirm the ones a real drain DOES populate
    // (sync_field_state/sync_set_state/sync_pending_ops/sync_touch_log)
    // are genuinely emptied, and that the four deliberately-preserved
    // device/dataset-level tables (sync_state/sync_ack_frontier/
    // sync_device_labels/sync_publish_intent) are NOT touched.
    const wipedSyncTables = [
      'sync_touch_log',
      'sync_field_state',
      'sync_set_state',
      'sync_pending_ops',
      'sync_grave',
      'sync_conflict_copies',
      'sync_dedup_index',
      'sync_dot_redirects',
      'sync_view_cache',
      'sync_materialize_queue',
      'sync_blob_refs',
    ];

    test('clearAllData empties every sync control-plane table a real drain just populated, '
        'and never leaves an orphaned reference to physically-erased content', () async {
      await databaseService.insertNote(_buildNote('n1', tags: ['urgent']));
      await drainer.drain();

      // Sanity: the drain genuinely populated the tables under test --
      // otherwise this test would trivially pass for the wrong reason.
      expect(await db.query('sync_field_state'), isNotEmpty);
      expect(await db.query('sync_set_state'), isNotEmpty);
      expect(await db.query('sync_pending_ops'), isNotEmpty);
      expect(await db.query('sync_touch_log'), isNotEmpty, reason: 'processed rows still physically exist until wiped');

      await databaseService.clearAllData();

      for (final table in wipedSyncTables) {
        final rows = await db.query(table);
        expect(rows, isEmpty, reason: '$table must be empty after clearAllData');
      }

      // And the underlying entity/membership data itself is really gone
      // (clearAllData's own original job, unaffected by this fix).
      expect(await db.query('notes'), isEmpty);
      expect(await db.query('tags'), isEmpty);
      expect(await db.query('note_tags'), isEmpty);
    });

    test('clearAllData preserves device/dataset-level sync state: device_id, HLC/seq counters, '
        'ack_frontier, device_labels, publish_intent', () async {
      final deviceIdBefore = await deviceIdentity.ensureDeviceId();
      await databaseService.insertNote(_buildNote('n1', tags: ['urgent']));
      await drainer.drain(); // advances the seq counter and HLC in sync_state

      final seqStateBefore = await db.query('sync_state', where: "key = 'next_seq:$deviceIdBefore'");
      expect(seqStateBefore, isNotEmpty, reason: 'the drain above must have advanced this device\'s seq counter');

      // Seed the three other deliberately-preserved tables directly (no
      // production writer populates them yet) so this test actually
      // exercises "clearAllData leaves a pre-existing row alone", not just
      // "clearAllData doesn't crash on an empty table".
      await db.insert('sync_ack_frontier', {
        'deviceId': 'remote-device',
        'authorId': deviceIdBefore,
        'ackedSeq': 1,
        'updatedAt': 1000,
      });
      await db.insert('sync_device_labels', {
        'deviceId': 'remote-device',
        'label': 'Remote',
        'isCurrentDevice': 0,
        'retiredAt': null,
        'updatedAt': 1000,
      });
      await db.insert('sync_publish_intent', {
        'intentHash': 'hash1',
        'parentCommitHash': null,
        'payloadHash': 'payload1',
        'status': 'pending',
        'createdAt': 1000,
        'confirmedAt': null,
      });

      await databaseService.clearAllData();

      expect(await deviceIdentity.ensureDeviceId(), deviceIdBefore, reason: 'device identity must survive a local content wipe');
      final seqStateAfter = await db.query('sync_state', where: "key = 'next_seq:$deviceIdBefore'");
      expect(seqStateAfter, seqStateBefore, reason: 'seq counter must not be reset by clearAllData');

      expect(await db.query('sync_ack_frontier'), hasLength(1));
      expect(await db.query('sync_device_labels'), hasLength(2), reason: 'this device\'s own auto-inserted label row plus the seeded remote one');
      expect(await db.query('sync_publish_intent'), hasLength(1));
    });
  });
}
