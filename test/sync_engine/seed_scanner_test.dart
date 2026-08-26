// Tests for M2.10's `SeedScanner` (`lib/services/sync/seed_scanner.dart`) —
// § Architecture 1's initial seed scan: the `seed:<deviceUuid>` namespace,
// the GENESIS `contentKey`, the round-18 corrected minting precondition, and
// the idempotency/resumability properties that precondition buys.
//
// **How "pre-existing" data is simulated, and why it is faithful.** A row
// that predates M2.4's capture triggers is, by construction, a row with no
// `sync_touch_log` evidence — `_migrateToVersion57` installs the triggers
// without backfilling, so every pre-migration row is in exactly that state.
// Both `OutboxDrainer` and `SeedScanner` read only `sync_touch_log` and the
// `sync_*` state tables, never anything that could tell them WHEN a row was
// written, so inserting normally and then clearing `sync_touch_log`
// reproduces that state exactly, not approximately.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
import 'package:note_synapse/services/sync/seed_scanner.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/pull_phase.dart';
import 'package:note_synapse/services/sync/sync_health.dart';
import 'package:note_synapse/services/sync/sync_table_shape.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/mock_sync_backend.dart';

/// One self-contained device: its own database, its own sync primitives.
class _Device {
  _Device() : databaseService = DatabaseService.createNew() {
    deviceIdentity = DeviceIdentity(databaseService);
    seqCounter = SeqCounter(databaseService);
    hlc = HybridLogicalClock(databaseService);
    scanner = SeedScanner(databaseService, deviceIdentity, seqCounter, hlc);
    drainer = OutboxDrainer(databaseService, deviceIdentity, seqCounter, hlc);
    session = SyncSession(databaseService);
  }

  final DatabaseService databaseService;
  late final DeviceIdentity deviceIdentity;
  late final SeqCounter seqCounter;
  late final HybridLogicalClock hlc;
  late final SeedScanner scanner;
  late final OutboxDrainer drainer;
  late final SyncSession session;

  Future<Database> get db => databaseService.database;

  Future<void> close() => databaseService.close();
}

Future<void> _insertPreExistingNote(
  Database db, {
  required String id,
  required String title,
  required String content,
}) async {
  await db.insert('notes', {
    'id': id,
    'title': title,
    'content': content,
    'type': 'note',
    'createdAt': 1000,
    'updatedAt': 1000,
  });
}

Future<void> _insertPreExistingTag(
  Database db, {
  required String id,
  required String name,
  String color = 'red',
}) async {
  await db.insert('tags', {
    'id': id,
    'name': name,
    'color': color,
    'createdAt': 1000,
    'usageCount': 0,
    '__deleted__': 0,
    'redirectTarget': null,
  });
}

/// Erases every trace of the capture triggers having fired — see this file's
/// top doc comment for why this is an exact reproduction of the
/// pre-migration state rather than an approximation.
Future<void> _makePreExisting(Database db) async {
  await db.delete('sync_touch_log');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late _Device device;
  late Database db;

  setUp(() async {
    device = _Device();
    db = await device.db;
  });

  tearDown(() async {
    await device.close();
  });

  Future<List<Map<String, Object?>>> pendingOps() =>
      db.query('sync_pending_ops', orderBy: 'id ASC');

  // ══════════════════════════════════════════════════════════════════════
  group('minting shape', () {
    test(
      'seeds pre-existing rows under seed:<deviceId> with a real monotonic seq, '
      'a real HLC, and the GENESIS contentKey',
      () async {
        await _insertPreExistingNote(
          db,
          id: 'n1',
          title: 'Hello',
          content: 'World',
        );
        await _makePreExisting(db);

        final result = await device.scanner.scan();
        expect(result.skippedAlreadyComplete, isFalse);
        expect(result.completed, isTrue);
        expect(result.operationsSeeded, greaterThan(0));

        final deviceId = await device.deviceIdentity.ensureDeviceId();
        final expectedAuthor = 'seed:$deviceId';
        final ops = await pendingOps();
        expect(ops, isNotEmpty);

        // ---- authorId namespace -------------------------------------
        expect(
          ops.map((o) => o['authorId']).toSet(),
          {expectedAuthor},
          reason:
              'every seeded operation belongs to the seed: namespace, never '
              'the ordinary device namespace',
        );

        // ---- a real, contiguous, monotonic counter (round 8's whole
        // point: a frontier entry only means "and everything below" for a
        // genuine counter) -----------------------------------------------
        final seqs = ops.map((o) => o['authorSeq'] as int).toList();
        expect(seqs, List.generate(seqs.length, (i) => i + 1));
        expect(
          await device.seqCounter.peek(expectedAuthor),
          seqs.length,
          reason: 'the seed namespace has its own SeqCounter row',
        );
        expect(
          await device.seqCounter.peek(deviceId),
          0,
          reason:
              'the ordinary namespace counter is untouched — seeding never '
              'consumes an ordinary dot',
        );

        // ---- a real HLC, strictly increasing ------------------------
        final hlcs = ops.map((o) => Hlc.parse(o['hlc'] as String)).toList();
        for (var i = 1; i < hlcs.length; i++) {
          expect(
            hlcs[i].compareTo(hlcs[i - 1]),
            greaterThan(0),
            reason: 'seed HLCs come from the real per-device clock, in order',
          );
        }
        expect(
          hlcs.first.toString(),
          isNot('0:0'),
          reason: 'never a placeholder (§ 11.2: seed HLCs are load-bearing '
              'the moment a seed competes in ordinary field-conflict '
              'resolution)',
        );

        // ---- __exists__ first, then one field op per sync-scope column
        expect(ops.first['kind'], '__exists__');
        expect(ops.first['fieldName'], '__exists__');
        final scope = DatabaseService.syncEntityCaptureScopes.firstWhere(
          (s) => s.table == 'notes',
        );
        // M2.12: only columns whose live value DIFFERS from what a receiving
        // device's shell row already holds. This note sets title/content/
        // type/updatedAt and leaves everything else at NULL or the column
        // default, so nine of the thirteen sync-scope columns carry no
        // information and are not seeded at all.
        final seededFields = ops.skip(1).map((o) => o['fieldName']).toList();
        expect(
          seededFields,
          ['title', 'content', 'type', 'updatedAt'],
          reason:
              'columns are minted in syncScopeColumns list order — the same '
              'order OutboxDrainer uses, which materializer.dart depends on — '
              'and only for columns not already at the receiving shell row '
              "value (M2.12's default-skip)",
        );
        expect(
          seededFields,
          orderedEquals(
            scope.syncScopeColumns.where(seededFields.contains).toList(),
          ),
          reason: 'the surviving columns keep syncScopeColumns list order',
        );
        expect(result.fieldsAtDefaultSkipped, 9);

        // ---- the GENESIS contentKey, byte for byte -------------------
        final titleOp = ops.firstWhere((o) => o['fieldName'] == 'title');
        expect(
          titleOp['contentKey'],
          genesisContentKey(
            entityTable: 'notes',
            entityId: 'n1',
            fieldName: 'title',
            valueJson: jsonEncode('Hello'),
          ),
        );
        expect(
          ops.first['contentKey'],
          genesisContentKey(
            entityTable: 'notes',
            entityId: 'n1',
            fieldName: '__exists__',
            valueJson: jsonEncode(true),
          ),
        );
        expect(
          ops.every((o) => o['contentKey'] != null),
          isTrue,
          reason: 'every seed operation carries a contentKey',
        );

        // ---- the mint was applied locally too (dedup registration +
        // sync_field_state), which is what makes the precondition
        // self-enforcing -------------------------------------------------
        final fieldState = await db.query(
          'sync_field_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: ['notes', 'n1', 'title'],
        );
        expect(fieldState, hasLength(1));
        expect(fieldState.single['authorId'], expectedAuthor);
        expect(fieldState.single['valueJson'], jsonEncode('Hello'));
        expect(fieldState.single['contentKey'], titleOp['contentKey']);

        final dedup = await db.query(
          'sync_dedup_index',
          where: 'contentKey = ?',
          whereArgs: [titleOp['contentKey']],
        );
        expect(
          dedup,
          hasLength(1),
          reason:
              'a locally minted seed registers itself as first-seen canonical, '
              'or it could never recognize another device\'s identical '
              'operation as a duplicate',
        );
      },
    );

    test('seeds OR-Set memberships as set_add with a member-scoped GENESIS key',
        () async {
      await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
      await _insertPreExistingTag(db, id: 'tag1', name: 'urgent');
      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
      await _makePreExisting(db);

      await device.scanner.scan();

      final ops = await pendingOps();
      final setAdds = ops.where((o) => o['kind'] == 'set_add').toList();
      expect(setAdds, hasLength(1));
      final op = setAdds.single;
      expect(op['entityTable'], 'notes');
      expect(op['entityId'], 'n1');
      expect(op['fieldName'], 'tags');
      expect(op['memberUuid'], 'tag1');
      expect(
        op['valueJson'],
        'true',
        reason:
            'note_tags has no payloadColumns — its two columns ARE the whole '
            'row — so the add-event payload is the bare-membership sentinel',
      );
      expect(
        op['contentKey'],
        genesisContentKey(
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'tags',
          memberUuid: 'tag1',
          valueJson: 'true',
        ),
      );

      final setState = await db.query('sync_set_state');
      expect(setState, hasLength(1));
      expect(setState.single['memberUuid'], 'tag1');
    });

    test('never writes to a real app table, so no capture trigger fires',
        () async {
      await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
      await _makePreExisting(db);

      final before = await db.query('notes');
      await device.scanner.scan();

      expect(
        await db.query('sync_touch_log'),
        isEmpty,
        reason: 'a seed scan reads app tables; it never writes them',
      );
      expect(await db.query('notes'), before);
    });

    test(
      'membership seed HLCs follow local autoincrement order — round 14\'s '
      'deliberate conversation_message_mapping exception',
      () async {
        await db.insert('conversations', {
          'id': 'c1',
          'title': 'Chat',
          'createdAt': 1000,
          'updatedAt': 1000,
          'isArchived': 0,
          'noteIds': '[]',
        });
        // Three mappings inserted in a deliberate order whose UUIDs sort the
        // OPPOSITE way, ALL sharing one `createdAt` millisecond — exactly
        // what `insertConversationMessageMappingsBatch` produces (it computes
        // one timestamp outside the insert loop), which is why local
        // insertion order is the only thing that carries the real history.
        for (final messageId in ['m_z', 'm_y', 'm_x']) {
          await db.insert('conversation_messages', {
            'id': messageId,
            'type': 'user',
            'content': 'msg $messageId',
            'timestamp': 1000,
          });
          await db.insert('conversation_message_mapping', {
            'conversationId': 'c1',
            'messageId': messageId,
            'createdAt': 1000,
          });
        }
        await _makePreExisting(db);

        await device.scanner.scan();

        final adds = await db.query(
          'sync_pending_ops',
          where: 'kind = ? AND fieldName = ?',
          whereArgs: ['set_add', 'messageIds'],
          orderBy: 'authorSeq ASC',
        );
        expect(
          adds.map((o) => o['memberUuid']).toList(),
          ['m_z', 'm_y', 'm_x'],
          reason: 'seeded in local insertion (rowid) order, not uuid order',
        );
        final hlcs = adds.map((o) => Hlc.parse(o['hlc'] as String)).toList();
        for (var i = 1; i < hlcs.length; i++) {
          expect(hlcs[i].compareTo(hlcs[i - 1]), greaterThan(0));
        }
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('idempotency and resumability', () {
    test('re-running the scan mints nothing new', () async {
      await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
      await _insertPreExistingTag(db, id: 'tag1', name: 'urgent');
      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
      await _makePreExisting(db);

      final first = await device.scanner.scan();
      final afterFirst = await pendingOps();
      expect(first.operationsSeeded, afterFirst.length);

      final second = await device.scanner.scan();
      expect(second.skippedAlreadyComplete, isTrue);
      expect(second.operationsSeeded, 0);
      expect(await pendingOps(), afterFirst);
    });

    test(
      'the precondition alone is sufficient — deleting the completion marker '
      'and re-running still mints nothing (progress tracking is a fast path, '
      'not the correctness mechanism)',
      () async {
        await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
        await _insertPreExistingTag(db, id: 'tag1', name: 'urgent');
        await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
        await _makePreExisting(db);

        await device.scanner.scan();
        final afterFirst = await pendingOps();

        await db.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: [seedScanCompletedAtKey],
        );

        final second = await device.scanner.scan();
        expect(second.skippedAlreadyComplete, isFalse);
        expect(
          second.operationsSeeded,
          0,
          reason: 'every field is gated by its own sync_field_state row',
        );
        expect(second.entitiesScanned, greaterThan(0));
        expect(await pendingOps(), afterFirst);
      },
    );

    test(
      'an interrupted scan resumes exactly where it stopped, with no '
      'duplicates — the mint and the gate commit in one transaction, so there '
      'is no mid-flight window',
      () async {
        for (var i = 0; i < 5; i++) {
          await _insertPreExistingNote(
            db,
            id: 'n$i',
            title: 'Title $i',
            content: 'Content $i',
          );
        }
        await _makePreExisting(db);

        // Stop hard, partway through, several times over — the shape a
        // process kill / user backgrounding produces.
        var rounds = 0;
        SeedScanResult last;
        do {
          last = await device.scanner.scan(maxOperations: 7);
          rounds++;
          expect(rounds, lessThan(20), reason: 'must make progress each pass');
        } while (!last.completed);
        expect(rounds, greaterThan(1), reason: 'genuinely interrupted');

        final ops = await pendingOps();
        // No duplicate operation for any (entity, field) slot.
        final slots = ops
            .map((o) => '${o['entityTable']}|${o['entityId']}|${o['fieldName']}')
            .toList();
        expect(slots.toSet(), hasLength(slots.length));
        // Contiguous seq, unbroken across the interruptions.
        expect(
          ops.map((o) => o['authorSeq']).toList(),
          List.generate(ops.length, (i) => i + 1),
        );

        // Identical to what one uninterrupted pass over the same data
        // produces — verified against a second, independent device.
        final reference = _Device();
        addTearDown(reference.close);
        final refDb = await reference.db;
        for (var i = 0; i < 5; i++) {
          await _insertPreExistingNote(
            refDb,
            id: 'n$i',
            title: 'Title $i',
            content: 'Content $i',
          );
        }
        await _makePreExisting(refDb);
        final refResult = await reference.scanner.scan();
        expect(refResult.operationsSeeded, ops.length);
        expect(
          (await refDb.query('sync_pending_ops', orderBy: 'id ASC'))
              .map((o) => o['contentKey'])
              .toList(),
          ops.map((o) => o['contentKey']).toList(),
          reason:
              'the same pre-existing content yields the same GENESIS keys in '
              'the same order regardless of how the scan was interrupted',
        );
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('the minting precondition (round 18\'s corrected gate)', () {
    test(
      'a field that already has sync_field_state is never re-seeded — a device '
      'that already synced normally does not get its data seeded on top',
      () async {
        await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
        // Do NOT clear the touch log: this row was captured by the triggers,
        // so drain owns it. It is the ordinary post-M2.4 path.
        final drained = await device.drainer.drain();
        expect(drained.mintedOperations, isNotEmpty);
        final deviceId = await device.deviceIdentity.ensureDeviceId();

        final result = await device.scanner.scan();

        expect(
          result.operationsSeeded,
          0,
          reason: 'every field already has real history from drain',
        );
        expect(
          (await pendingOps()).map((o) => o['authorId']).toSet(),
          {deviceId},
          reason: 'nothing was minted in the seed namespace',
        );
      },
    );

    test(
      'a field is skipped while a sync_materialize_queue entry references it, '
      'and seeded once that entry clears — the observation-vs-materialization '
      'gap the original gate missed',
      () async {
        await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
        await _makePreExisting(db);

        // An operation on (notes/n1, title) pulled from another device and
        // parked on a missing prerequisite: fully OBSERVED (this device's
        // frontier already reflects it) with no sync_field_state row at all.
        await db.insert('sync_materialize_queue', {
          'blockingReason': 'missing_exists',
          'entityTable': 'notes',
          'entityId': 'n1',
          'fieldName': 'title',
          'operationJson': jsonEncode({'kind': 'field', 'fieldName': 'title'}),
          'blockingKey': 'notes:n1',
          'enqueuedAt': 1,
        });

        final first = await device.scanner.scan();
        expect(first.fieldsDeferred, 1);
        expect(
          first.completed,
          isFalse,
          reason:
              'a deferral is transient, so the completion marker must not be '
              'written — the next sync re-checks',
        );
        expect(
          await db.query(
            'sync_pending_ops',
            where: 'fieldName = ?',
            whereArgs: ['title'],
          ),
          isEmpty,
          reason:
              'seeding title here would give the seed a frontier that already '
              'dominates the queued operation, violating the Key Lemma',
        );
        // Everything else on the same entity WAS seeded — the gate is
        // per-field, not per-entity.
        expect(first.operationsSeeded, greaterThan(0));
        expect(
          await db.query(
            'sync_pending_ops',
            where: 'fieldName = ?',
            whereArgs: ['content'],
          ),
          hasLength(1),
        );

        // The blocked operation eventually materializes and leaves the queue.
        await db.delete('sync_materialize_queue');
        final second = await device.scanner.scan();
        expect(second.fieldsDeferred, 0);
        expect(second.completed, isTrue);
        expect(
          await db.query(
            'sync_pending_ops',
            where: 'fieldName = ?',
            whereArgs: ['title'],
          ),
          hasLength(1),
          reason: 'once the blocker clears, the field is seedable again',
        );
      },
    );

    test('a queue entry with a NULL fieldName defers the whole entity',
        () async {
      await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
      await _makePreExisting(db);
      await db.insert('sync_materialize_queue', {
        'blockingReason': 'pending_recheck',
        'entityTable': 'notes',
        'entityId': 'n1',
        'fieldName': null,
        'operationJson': null,
        'blockingKey': null,
        'enqueuedAt': 1,
      });

      final result = await device.scanner.scan();
      expect(result.operationsSeeded, 0);
      expect(result.fieldsDeferred, greaterThan(0));
      expect(result.completed, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('a later edit causally descends from the seed it edits', () {
    // REGRESSION GUARD for the round-17 "stale seed wins" failure, which
    // M2.10 made reachable: before `frontier.dart` folded this device's own
    // `next_seq:` namespaces into a locally-minted operation's frontier, an
    // ordinary edit carried NO entry for `seed:<self>`, so it compared as
    // CONCURRENT with the seed value it was made from and could lose the
    // `(hlc, authorId, authorSeq)` tie-break — silently reverting the user's
    // edit and leaving a spurious field_conflict copy as the only trace.

    test(
      'a locally-minted ordinary operation\'s frontier includes this device\'s '
      'own seed: namespace position',
      () async {
        await _insertPreExistingNote(db, id: 'n1', title: 'Seeded', content: 'C');
        await _makePreExisting(db);
        await device.scanner.scan();

        final deviceId = await device.deviceIdentity.ensureDeviceId();
        final seedAuthor = 'seed:$deviceId';
        final seedTitleDot = (await db.query(
          'sync_pending_ops',
          where: 'authorId = ? AND fieldName = ?',
          whereArgs: [seedAuthor, 'title'],
        )).single;

        // An ordinary user edit of a seeded field.
        await db.update(
          'notes',
          {'title': 'Edited by the user'},
          where: 'id = ?',
          whereArgs: ['n1'],
        );
        await device.drainer.drain();

        final editOp = (await db.query(
          'sync_pending_ops',
          where: 'authorId = ? AND fieldName = ?',
          whereArgs: [deviceId, 'title'],
        )).single;
        final frontier =
            jsonDecode(editOp['frontierJson'] as String) as Map<String, dynamic>;

        expect(
          frontier[seedAuthor],
          isNotNull,
          reason:
              'without an entry for its own seed: namespace the edit cannot '
              'witness that it descends from the seed it edits — the exact '
              'round-17 premise (plan line 975)',
        );
        expect(
          frontier[seedAuthor] as int,
          greaterThanOrEqualTo(seedTitleDot['authorSeq'] as int),
          reason: 'the frontier must dominate the seed dot for THIS field',
        );
        expect(frontier[deviceId], editOp['authorSeq']);
      },
    );

    test(
      'three devices, one edits a seeded field: the edit wins everywhere and '
      'leaves no spurious conflict copy',
      () async {
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        final c = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        addTearDown(c.close);
        final dbA = await a.db;
        final dbB = await b.db;
        final dbC = await c.db;

        // The same pre-existing library on all three devices — so all three
        // independently seed identical content and the GENESIS classes are
        // genuinely multi-member, which is what makes the comparator's
        // alias-expansion path live.
        for (final target in [dbA, dbB, dbC]) {
          await _insertPreExistingNote(
            target,
            id: 'n1',
            title: 'Original seeded title',
            content: 'Body',
          );
          await _makePreExisting(target);
        }

        Future<void> syncAll({int rounds = 3}) async {
          for (var r = 0; r < rounds; r++) {
            for (final d in [a, b, c]) {
              await d.session.run(backend);
            }
          }
        }

        await syncAll();

        // Now a real, later, intentional user edit on ONE device.
        await dbA.update(
          'notes',
          {'title': 'Edited by the user'},
          where: 'id = ?',
          whereArgs: ['n1'],
        );

        await syncAll(rounds: 4);

        for (final (label, target) in [('A', dbA), ('B', dbB), ('C', dbC)]) {
          expect(
            jsonDecode(
              (await target.query(
                'sync_field_state',
                where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
                whereArgs: ['notes', 'n1', 'title'],
              )).single['valueJson'] as String,
            ),
            'Edited by the user',
            reason:
                '$label: the user\'s later edit must beat the seed value it '
                'was made from — never be silently reverted by it',
          );
          expect(
            (await target.query('notes', where: 'id = ?', whereArgs: ['n1']))
                .single['title'],
            'Edited by the user',
            reason: '$label: the real materialized row must agree',
          );
          expect(
            await target.query(
              'sync_conflict_copies',
              where: 'subjectTable = ? AND subjectId = ? AND fieldName = ? '
                  'AND kind = ?',
              whereArgs: ['notes', 'n1', 'title', 'field_conflict'],
            ),
            isEmpty,
            reason:
                '$label: an edit that causally descends from the seed is not '
                'concurrent with it, so it must produce no user-facing '
                'conflict copy at all',
          );
        }
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('non-portable entity ids are never seeded', () {
    test(
      'autoincrement-keyed tables are skipped wholesale — their entityIds '
      'collide across devices, and the materializer\'s UPDATE path has no '
      'guard of its own',
      () async {
        await db.insert('user_apps', {
          'id': 'appA',
          'uuid': 'uuidA',
          'name': 'App A',
          'description': '',
          'steps': '[]',
          'htmlContent': '',
          'type': 'normal',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await db.insert('user_app_libraries', {
          'app_uuid': 'uuidA',
          'revision_id': 1,
          'name': 'alpha',
          'usage_instructions': 'use alpha',
        });
        await db.insert('user_app_library_dependencies', {
          'original_url': 'https://example.test/a.js',
          'local_path': 'a.js',
          'bytes': Uint8List.fromList([1, 2, 3]),
          'library_id': 1,
        });
        await _makePreExisting(db);

        final result = await device.scanner.scan();

        expect(
          result.nonPortableTablesSkipped.map((e) => e.split(' ').first),
          containsAll(<String>[
            'user_app_libraries',
            'user_app_library_dependencies',
          ]),
        );
        expect(
          result.nonPortableTablesSkipped
              .where((e) => e.startsWith('user_app_libraries ')),
          everyElement(contains('non-portable id')),
          reason: 'the reported reason names WHY, not just that it skipped',
        );
        for (final table in [
          'user_app_libraries',
          'user_app_library_dependencies',
        ]) {
          expect(
            await db.query(
              'sync_pending_ops',
              where: 'entityTable = ?',
              whereArgs: [table],
            ),
            isEmpty,
            reason:
                '$table keys on INTEGER PRIMARY KEY AUTOINCREMENT: device A\'s '
                'row 1 and device B\'s row 1 are unrelated rows, so seeding '
                'them mints operations whose entityId (and, since __exists__ '
                'and __deleted__ carry identical values everywhere, whose '
                'GENESIS contentKey) collide unconditionally',
          );
        }
        // The guard is narrow: a table that CAN materialize on a peer is
        // still seeded normally. (`user_apps` is not such a table — its
        // `uuid` is NOT NULL and outside sync scope, so it is gated for the
        // other reason; see the syncability audit below.)
        await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
        await db.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: [seedScanCompletedAtKey],
        );
        await device.scanner.scan();
        expect(
          await db.query(
            'sync_pending_ops',
            where: 'entityTable = ?',
            whereArgs: ['notes'],
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'the DEFAULT route is guarded too: an ordinary app import on one device '
      'never rewrites an unrelated library row on another',
      () async {
        // No seed scan and no UPDATE call site is involved in this one. The
        // reproduction is an everyday action: importing an app calls
        // insertUserAppLibrary, whose AFTER INSERT trigger feeds drain, which
        // minted __exists__/name/usage_instructions at entityId='1'. On the
        // receiving device the __exists__ INSERT was correctly skipped while
        // the field operations silently UPDATEd whatever row occupied id 1 —
        // no conflict copy, no queue entry, no error.
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;

        Future<void> installApp(Database target, String suffix) async {
          await target.insert('user_apps', {
            'id': 'app$suffix',
            'uuid': 'uuid$suffix',
            'name': 'App $suffix',
            'description': '',
            'steps': '[]',
            'htmlContent': '',
            'type': 'normal',
            'createdAt': 1000,
            'updatedAt': 1000,
          });
        }

        // B already holds a library at local id 1, fully synced/settled.
        await installApp(dbB, 'B');
        await dbB.insert('user_app_libraries', {
          'app_uuid': 'uuidB',
          'revision_id': 1,
          'name': 'beta',
          'usage_instructions': 'use beta',
        });
        await installApp(dbA, 'A');
        for (var round = 0; round < 2; round++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        // Now the everyday action on A: import an app that brings a library.
        // This fires the capture trigger — no seed scan involved.
        await dbA.insert('user_app_libraries', {
          'app_uuid': 'uuidA',
          'revision_id': 1,
          'name': 'alpha',
          'usage_instructions': 'use alpha',
        });
        final drained = await a.drainer.drain();
        expect(
          drained.touchesProcessed,
          greaterThan(0),
          reason: 'the trigger fired — this is the default route, not an edge',
        );
        expect(
          drained.mintedOperations
              .where((o) => o.entityTable == 'user_app_libraries'),
          isEmpty,
          reason:
              'drain must refuse to mint an operation whose entityId is a '
              'locally-assigned integer that means nothing on another device',
        );

        for (var round = 0; round < 3; round++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        final libB = (await dbB.query('user_app_libraries')).single;
        expect(
          libB['name'],
          'beta',
          reason:
              'REGRESSION GUARD: B\'s unrelated library row must survive A\'s '
              'import untouched',
        );
        expect(libB['usage_instructions'], 'use beta');
        expect(libB['app_uuid'], 'uuidB');
      },
    );

    test(
      'the MATERIALIZER-side guard holds on its own, against operations an '
      'older build already published',
      () async {
        // COVERAGE GUARD for `materializer.dart`'s `_writeResolvedFieldValue`
        // portability check. That half exists precisely because operations
        // published by a build without the mint-side guard stay dangerous
        // forever — so it cannot be tested through the drainer, which now
        // refuses to mint them. Operations are injected straight into
        // `sync_pending_ops` instead, which is exactly what such a build
        // would have left behind. Deleting the guard must fail this test.
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;

        // B holds a library at local id 1.
        await dbB.insert('user_apps', {
          'id': 'appB',
          'uuid': 'uuidB',
          'name': 'App B',
          'description': '',
          'steps': '[]',
          'htmlContent': '',
          'type': 'normal',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await dbB.insert('user_app_libraries', {
          'app_uuid': 'uuidB',
          'revision_id': 1,
          'name': 'beta',
          'usage_instructions': 'use beta',
        });

        // A publishes operations for `user_app_libraries` id 1 the way a
        // pre-guard build would have.
        final authorId = await a.deviceIdentity.ensureDeviceId();
        Future<void> injectOp(String kind, String field, String value) async {
          final seq = await a.seqCounter.mintNextSeq(authorId);
          final hlc = await a.hlc.generate();
          await dbA.insert('sync_pending_ops', {
            'authorId': authorId,
            'authorSeq': seq,
            'hlc': hlc.toString(),
            'contentKey': null,
            'kind': kind,
            'entityTable': 'user_app_libraries',
            'entityId': '1',
            'fieldName': field,
            'memberUuid': null,
            'valueJson': value,
            'blobHash': null,
            'targetDotsJson': null,
            'frontierJson': jsonEncode({authorId: seq}),
            'createdAt': 1000,
            'publishedAt': null,
          });
        }

        await injectOp('__exists__', '__exists__', jsonEncode(true));
        await injectOp('field', 'name', jsonEncode('alpha'));
        await injectOp('field', 'usage_instructions', jsonEncode('use alpha'));

        for (var round = 0; round < 3; round++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        final libB = (await dbB.query('user_app_libraries')).single;
        expect(
          libB['name'],
          'beta',
          reason:
              'REGRESSION GUARD for materializer.dart\'s _writeResolvedFieldValue '
              'portability check: without it, a pulled field operation UPDATEs '
              'WHERE id = 1 and renames B\'s unrelated library. The __exists__ '
              'INSERT guard alone does not prevent this — no INSERT is needed.',
        );
        expect(libB['usage_instructions'], 'use beta');
        expect(libB['app_uuid'], 'uuidB');
      },
    );

    test('the drain-side refusal is observable, not silent', () async {
      await db.insert('user_apps', {
        'id': 'appA',
        'uuid': 'uuidA',
        'name': 'App A',
        'description': '',
        'steps': '[]',
        'htmlContent': '',
        'type': 'normal',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('user_app_libraries', {
        'app_uuid': 'uuidA',
        'revision_id': 1,
        'name': 'alpha',
        'usage_instructions': 'use alpha',
      });

      final result = await device.drainer.drain();

      expect(
        result.nonPortableTablesSkipped,
        contains('user_app_libraries (non-portable id)'),
        reason:
            'a user whose User-App libraries do not sync must be able to find '
            'out — the silence here is what let the materializer-side guard '
            'ship with no coverage at all',
      );
      expect(
        result.mintedOperations
            .where((o) => o.entityTable == 'user_app_libraries'),
        isEmpty,
      );
      expect(
        await db.query('sync_touch_log', where: 'processedAt IS NULL'),
        isEmpty,
        reason: 'the touch is consumed — it will never become mintable',
      );
    });

    test('two devices holding unrelated rows at the same autoincrement id do '
        'not corrupt each other', () async {
      final backend = MockSyncBackend();
      final a = _Device();
      final b = _Device();
      addTearDown(a.close);
      addTearDown(b.close);
      final dbA = await a.db;
      final dbB = await b.db;

      // Same local id (1), genuinely different libraries belonging to
      // genuinely different apps.
      var appSuffix = 'A';
      for (final target in [dbA, dbB]) {
        await target.insert('user_apps', {
          'id': 'app$appSuffix',
          'uuid': 'uuid$appSuffix',
          'name': 'App $appSuffix',
          'description': '',
          'steps': '[]',
          'htmlContent': '',
          'type': 'normal',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await target.insert('user_app_libraries', {
          'app_uuid': 'uuid$appSuffix',
          'revision_id': 1,
          'name': appSuffix == 'A' ? 'alpha' : 'beta',
          'usage_instructions': 'use ${appSuffix == 'A' ? 'alpha' : 'beta'}',
        });
        await _makePreExisting(target);
        appSuffix = 'B';
      }

      for (var round = 0; round < 3; round++) {
        await a.session.run(backend);
        await b.session.run(backend);
      }

      expect(
        (await dbA.query('user_app_libraries')).single['name'],
        'alpha',
        reason:
            'REGRESSION GUARD: device B\'s library row (same local id 1, '
            'different app) must not rename A\'s — the materializer\'s '
            'non-portable-id guard exists only on the __exists__ INSERT path, '
            'so a pulled field operation would UPDATE by id with no guard',
      );
      expect(
        (await dbA.query('user_app_libraries')).single['usage_instructions'],
        'use alpha',
      );
      expect(
        (await dbB.query('user_app_libraries')).single['name'],
        'beta',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('membership add-event payloads', () {
    // § Architecture 1's round-14 conversation-mapping correction: a
    // mapping's createdAt is real add-event data and belongs in the seed's
    // contentKey, matching test/sync_protocol/conversation_ops.dart's own
    // validated genesisContentKey(conversationId, messageId, createdAtMillis).

    Future<void> seedOneMapping(Database target, int createdAt) async {
      await target.insert('conversations', {
        'id': 'c1',
        'title': 'Chat',
        'createdAt': 1000,
        'updatedAt': 1000,
        'isArchived': 0,
        'noteIds': '[]',
      });
      await target.insert('conversation_messages', {
        'id': 'm1',
        'type': 'user',
        'content': 'hi',
        'timestamp': 1000,
      });
      await target.insert('conversation_message_mapping', {
        'conversationId': 'c1',
        'messageId': 'm1',
        'createdAt': createdAt,
      });
      await _makePreExisting(target);
    }

    Future<String> mappingContentKey(_Device d) async {
      final rows = await (await d.db).query(
        'sync_pending_ops',
        where: 'kind = ? AND fieldName = ?',
        whereArgs: ['set_add', 'messageIds'],
      );
      return rows.single['contentKey'] as String;
    }

    test('the mapping\'s createdAt is part of the seed contentKey and is '
        'carried on the operation', () async {
      await seedOneMapping(db, 4242);
      await device.scanner.scan();

      final op = (await db.query(
        'sync_pending_ops',
        where: 'kind = ? AND fieldName = ?',
        whereArgs: ['set_add', 'messageIds'],
      )).single;
      expect(
        op['valueJson'],
        jsonEncode({'createdAt': 4242}),
        reason:
            'keying on a value the operation does not transmit would leave '
            'the fact that decided dedup unrecoverable to other replicas',
      );
      expect(
        op['contentKey'],
        genesisContentKey(
          entityTable: 'conversations',
          entityId: 'c1',
          fieldName: 'messageIds',
          memberUuid: 'm1',
          valueJson: jsonEncode({'createdAt': 4242}),
        ),
      );
    });

    test('same createdAt on two devices converges; DIFFERENT createdAt does '
        'not dedup, so neither device\'s real history is discarded', () async {
      final same1 = _Device();
      final same2 = _Device();
      final diff = _Device();
      addTearDown(same1.close);
      addTearDown(same2.close);
      addTearDown(diff.close);

      await seedOneMapping(await same1.db, 1111);
      await seedOneMapping(await same2.db, 1111);
      await seedOneMapping(await diff.db, 2222);
      for (final d in [same1, same2, diff]) {
        await d.scanner.scan();
      }

      expect(
        await mappingContentKey(same1),
        await mappingContentKey(same2),
        reason:
            'the shared-backup case still converges — this is what the '
            'GENESIS sentinel exists for',
      );
      expect(
        await mappingContentKey(diff),
        isNot(await mappingContentKey(same1)),
        reason:
            'two replicas whose mappings carry genuinely different historical '
            'timestamps must NOT dedup into one dot — deduping them would '
            'permanently discard one device\'s real ordering, the exact loss '
            'round 14 exists to prevent',
      );
    });

    test('a payload-free membership table keeps the bare sentinel', () async {
      await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
      await _insertPreExistingTag(db, id: 'tag1', name: 'urgent');
      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
      await _makePreExisting(db);
      await device.scanner.scan();

      final op = (await db.query(
        'sync_pending_ops',
        where: 'kind = ? AND fieldName = ?',
        whereArgs: ['set_add', 'tags'],
      )).single;
      expect(op['valueJson'], 'true');
      expect(
        DatabaseService.syncSetCaptureScopes
            .firstWhere((s) => s.membershipTable == 'note_tags')
            .payloadColumns,
        isEmpty,
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('mapping memberships reach the real app tables', () {
    // REGRESSION GUARD. `_materializeSetAdd` used to INSERT only the two id
    // columns with ConflictAlgorithm.ignore. All three mapping tables
    // declare `createdAt INTEGER NOT NULL` with no default (and
    // message_parents also declares `id TEXT PRIMARY KEY`), so every one of
    // those INSERTs failed a NOT NULL constraint and OR IGNORE swallowed it
    // whole: a live sync_set_state row alongside an EMPTY mapping table,
    // with no queue entry and no error. Pre-existing since M2.7; fixable
    // once M2.10 put the add-event payload on the wire.

    Future<void> buildConversation(Database target) async {
      await target.insert('conversations', {
        'id': 'c1',
        'title': 'Chat',
        'createdAt': 1000,
        'updatedAt': 1000,
        'isArchived': 0,
        'noteIds': '[]',
      });
      await _insertPreExistingNote(target, id: 'n1', title: 'T', content: 'C');
      for (final id in ['m1', 'm2']) {
        await target.insert('conversation_messages', {
          'id': id,
          'type': 'user',
          'content': 'msg $id',
          'timestamp': 1000,
        });
      }
      await target.insert('conversation_note_mapping', {
        'conversationId': 'c1',
        'noteId': 'n1',
        'createdAt': 5150,
      });
      await target.insert('conversation_message_mapping', {
        'conversationId': 'c1',
        'messageId': 'm1',
        'createdAt': 5151,
      });
      await target.insert('message_parents', {
        'id': 'local-uuid-on-A',
        'messageId': 'm2',
        'parentMessageId': 'm1',
        'createdAt': 5152,
      });
    }

    /// [expectDerivedId] is false when the device being checked ALREADY held
    /// the row locally: nothing was materialized there, so `message_parents.id`
    /// is still that device's own local uuid, which is correct.
    Future<void> assertMappingsMaterialized(
      Database target,
      String label, {
      bool expectDerivedId = true,
    }) async {
      final noteMap = await target.query('conversation_note_mapping');
      expect(
        noteMap,
        hasLength(1),
        reason:
            '$label: conversation_note_mapping must actually receive the row '
            '— an empty table beside a live sync_set_state row is the exact '
            'silent-swallow signature being guarded against',
      );
      expect(noteMap.single['noteId'], 'n1');
      expect(
        noteMap.single['createdAt'],
        5150,
        reason: '$label: the add-event payload carried the real createdAt',
      );

      final msgMap = await target.query('conversation_message_mapping');
      expect(msgMap, hasLength(1));
      expect(msgMap.single['messageId'], 'm1');
      expect(msgMap.single['createdAt'], 5151);

      final parents = await target.query('message_parents');
      expect(parents, hasLength(1));
      expect(parents.single['messageId'], 'm2');
      expect(parents.single['parentMessageId'], 'm1');
      expect(parents.single['createdAt'], 5152);
      if (expectDerivedId) {
        expect(
          parents.single['id'],
          isNot('local-uuid-on-A'),
          reason:
              '$label: the surrogate key is derived deterministically from '
              'the membership, never carried from the origin device (carrying '
              'it would put a local uuid in the contentKey and break '
              'convergence)',
        );
      }

      expect(
        await target.query(
          'sync_materialize_queue',
          where: 'blockingReason = ?',
          whereArgs: ['unfillable_membership_column'],
        ),
        isEmpty,
        reason: '$label: every column was fillable, so nothing was parked',
      );
    }

    test('via the SEED path', () async {
      final backend = MockSyncBackend();
      final a = _Device();
      final b = _Device();
      addTearDown(a.close);
      addTearDown(b.close);
      await buildConversation(await a.db);
      await _makePreExisting(await a.db);

      for (var round = 0; round < 4; round++) {
        await a.session.run(backend);
        await b.session.run(backend);
      }

      await assertMappingsMaterialized(await b.db, 'B (seed path)');
    });

    test('via the ordinary DRAIN path (post-trigger writes)', () async {
      final backend = MockSyncBackend();
      final a = _Device();
      final b = _Device();
      addTearDown(a.close);
      addTearDown(b.close);
      // No _makePreExisting: these rows are captured by the triggers, so
      // drain owns them end to end and never touches the seed scanner.
      await buildConversation(await a.db);

      for (var round = 0; round < 4; round++) {
        await a.session.run(backend);
        await b.session.run(backend);
      }

      await assertMappingsMaterialized(await b.db, 'B (drain path)');
      expect(
        (await (await a.db).query(
          'sync_pending_ops',
          where: 'kind = ? AND fieldName = ?',
          whereArgs: ['set_add', 'noteIds'],
        )).single['valueJson'],
        jsonEncode({'createdAt': 5150}),
        reason:
            'drain must carry the payload too, or an ordinary post-trigger '
            'mapping add still cannot materialize on the receiving device',
      );
    });

    test('a duplicate concurrent add-dot is still a harmless no-op against '
        'the real table', () async {
      // What the OR IGNORE legitimately did, now done by an explicit
      // existence check so a NOT NULL failure can no longer hide behind it.
      final backend = MockSyncBackend();
      final a = _Device();
      final b = _Device();
      addTearDown(a.close);
      addTearDown(b.close);
      // Both devices independently hold the same mapping with the SAME
      // createdAt — identical contentKeys, so this exercises dedup; then a
      // differing one, which produces two genuinely live add-dots.
      await buildConversation(await a.db);
      await buildConversation(await b.db);
      await _makePreExisting(await a.db);
      await _makePreExisting(await b.db);

      for (var round = 0; round < 4; round++) {
        await a.session.run(backend);
        await b.session.run(backend);
      }

      for (final (label, d) in [('A', a), ('B', b)]) {
        final target = await d.db;
        expect(
          await target.query('conversation_note_mapping'),
          hasLength(1),
          reason: '$label: exactly one real row, never a duplicate or a throw',
        );
        // Both devices already held these rows locally, so neither
        // materialized anything — their own local surrogate ids are correct.
        await assertMappingsMaterialized(
          target,
          label,
          expectDerivedId: false,
        );
      }
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('one bad operation cannot wedge a device', () {
    /// Publishes a `set_add` for `conversations.noteIds` straight into A's
    /// outbox with the exact [valueJson] given — the shapes another build
    /// (older, newer, or buggy) can legitimately put on the wire.
    Future<void> publishRawSetAdd(_Device d, String? valueJson) async {
      final target = await d.db;
      final authorId = await d.deviceIdentity.ensureDeviceId();
      final seq = await d.seqCounter.mintNextSeq(authorId);
      final hlc = await d.hlc.generate();
      await target.insert('sync_pending_ops', {
        'authorId': authorId,
        'authorSeq': seq,
        'hlc': hlc.toString(),
        'contentKey': null,
        'kind': 'set_add',
        'entityTable': 'conversations',
        'entityId': 'c1',
        'fieldName': 'noteIds',
        'memberUuid': 'n1',
        'valueJson': valueJson,
        'blobHash': null,
        'targetDotsJson': null,
        'frontierJson': jsonEncode({authorId: seq}),
        'createdAt': 1000,
        'publishedAt': null,
      });
    }

    Future<void> buildOwners(Database target) async {
      await target.insert('conversations', {
        'id': 'c1',
        'title': 'Chat',
        'createdAt': 1000,
        'updatedAt': 1000,
        'isArchived': 0,
        'noteIds': '[]',
      });
      await _insertPreExistingNote(target, id: 'n1', title: 'T', content: 'C');
    }

    test(
      'a set_add carrying an explicit null payload materializes instead of '
      'throwing — containsKey is not the same as having a value',
      () async {
        // BLOCKER REGRESSION. `{"createdAt": null}` populated the key, passed
        // a containsKey-only fillability check, and hit the (now
        // conflict-algorithm-free) INSERT: NOT NULL constraint failed,
        // escaping SyncSession.run() on six consecutive sessions while the
        // device's own unpushed work never left.
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        await buildOwners(await a.db);
        await buildOwners(await b.db);
        await publishRawSetAdd(a, jsonEncode({'createdAt': null}));

        for (var round = 0; round < 3; round++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        expect(
          await (await b.db).query('conversation_note_mapping'),
          hasLength(1),
          reason:
              'a null payload column falls back to the operation\'s own HLC '
              'wall clock, exactly as an entity\'s createdAt does',
        );
      },
    );

    test(
      'a pre-M2.10 set_add with NO payload at all materializes — it is a '
      'normal operation, not a malformed one',
      () async {
        // BLOCKER REGRESSION. valueJson == null is exactly what
        // decodeSetAddPayload documents as an ordinary older-build operation.
        // Parking it reproduced the very "live sync_set_state row, empty
        // mapping table" signature this milestone set out to kill — under a
        // queue reason nothing read.
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        await buildOwners(await a.db);
        await buildOwners(await b.db);
        await publishRawSetAdd(a, null);

        for (var round = 0; round < 3; round++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        final dbB = await b.db;
        expect(await dbB.query('conversation_note_mapping'), hasLength(1));
        expect(
          await dbB.query(
            'sync_materialize_queue',
            where: 'blockingReason = ?',
            whereArgs: ['unfillable_membership_column'],
          ),
          isEmpty,
          reason: 'nothing should be parked for an ordinary legacy operation',
        );
      },
    );

    test(
      'a genuinely unapplicable operation parks and the session still '
      'completes — the whole push included',
      () async {
        // The general form of both blockers: one poisoned operation must
        // never stop a device from syncing its own unrelated work.
        //
        // The poison is deliberately a failure NO pre-check could predict —
        // a PRIMARY KEY collision on `message_parents.id`, arranged by
        // pre-occupying the exact deterministic id the incoming membership
        // will derive. Every column is fillable, every FK is satisfied, both
        // prerequisite rows exist: the INSERT simply cannot succeed. That is
        // the class the per-operation guard exists for, rather than any one
        // shape a fillability check could learn to recognize.
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;
        await buildOwners(dbA);
        await buildOwners(dbB);
        for (final target in [dbA, dbB]) {
          for (final id in ['m1', 'm2', 'm3', 'm4']) {
            await target.insert('conversation_messages', {
              'id': id,
              'type': 'user',
              'content': 'msg $id',
              'timestamp': 1000,
            });
          }
        }

        // B already holds an UNRELATED parent-edge squatting on the id that
        // the incoming (m1 -> m2) membership will derive for itself.
        final collidingId = deterministicMembershipRowId(
          membershipTable: 'message_parents',
          entityId: 'm1',
          memberUuid: 'm2',
        );
        await dbB.insert('message_parents', {
          'id': collidingId,
          'messageId': 'm3',
          'parentMessageId': 'm4',
          'createdAt': 1000,
        });

        // A publishes the (m1 -> m2) membership.
        final authorIdA = await a.deviceIdentity.ensureDeviceId();
        final seq = await a.seqCounter.mintNextSeq(authorIdA);
        final hlc = await a.hlc.generate();
        await dbA.insert('sync_pending_ops', {
          'authorId': authorIdA,
          'authorSeq': seq,
          'hlc': hlc.toString(),
          'contentKey': null,
          'kind': 'set_add',
          'entityTable': 'conversation_messages',
          'entityId': 'm1',
          'fieldName': 'parentMessageIds',
          'memberUuid': 'm2',
          'valueJson': jsonEncode({'createdAt': 7000}),
          'blobHash': null,
          'targetDotsJson': null,
          'frontierJson': jsonEncode({authorIdA: seq}),
          'createdAt': 1000,
          'publishedAt': null,
        });

        // B has real local work of its own waiting to be pushed — this is
        // what a wedge used to strand permanently.
        await dbB.update(
          'notes',
          {'title': 'B edited this locally'},
          where: 'id = ?',
          whereArgs: ['n1'],
        );

        await a.session.run(backend);

        // The session must COMPLETE, not throw.
        final resultB = await b.session.run(backend);

        expect(
          resultB.pull.failedOperations,
          hasLength(1),
          reason:
              'the poisoned operation must actually have failed — otherwise '
              'this test proves nothing about the guard',
        );
        expect(resultB.pull.failedOperations.single.$1, authorIdA);
        expect(resultB.pull.failedOperations.single.$3, isNotEmpty);
        expect(
          await dbB.query(
            'sync_materialize_queue',
            where: 'blockingReason = ?',
            whereArgs: ['operation_failed'],
          ),
          hasLength(1),
          reason: 'parked durably, with its payload and the real error text',
        );

        expect(
          resultB.totalPublished,
          greaterThan(0),
          reason:
              "B's own unrelated local work must still reach the backend — "
              'push runs after pull, so a pull-side throw used to strand it '
              'permanently',
        );
        expect(
          await dbB.query(
            'sync_pending_ops',
            where: 'fieldName = ? AND publishedAt IS NOT NULL',
            whereArgs: ['title'],
          ),
          isNotEmpty,
        );

        // B's OWN unrelated pulled state is intact — the failure was
        // contained to one operation, not the whole round.
        expect(
          (await dbB.query('message_parents')).single['messageId'],
          'm3',
          reason: "the squatting row is untouched; nothing was half-applied",
        );

        // Later sessions keep completing. The bounded replay re-attempts the
        // parked operation (a transient fault would clear here) and, since
        // this poison is deterministic, exhausts its attempts and then stops
        // retrying — reported throughout, never thrown, never forgotten.
        for (var round = 0; round < maxParkedOperationAttempts + 2; round++) {
          final again = await b.session.run(backend);
          expect(again.pull.operationsApplied, greaterThanOrEqualTo(0));
        }
        final parked = await dbB.query(
          'sync_materialize_queue',
          where: 'blockingReason = ?',
          whereArgs: ['operation_failed'],
        );
        expect(parked, hasLength(1), reason: 'still exactly one, not a pile');
        expect(
          jsonDecode(parked.single['operationJson'] as String)['attempts'],
          maxParkedOperationAttempts,
          reason: 'retries are bounded, not endless',
        );
        expect(
          (await b.session.run(backend)).pull.failedOperations,
          isEmpty,
          reason: 'once exhausted it stops being retried each round',
        );
        // But it is still REPORTED — permanently, via the health surface.
        final health = await recomputeSyncHealth(b.databaseService);
        expect(health.isDegraded, isTrue);
        expect(
          health.issues.map((i) => i.kind),
          contains(SyncHealthIssueKind.operationsFailed),
        );
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('a removal is never resurrected by waiting', () {
    // BLOCKER REGRESSION. `missing_referenced_dot` briefly carried a
    // pass-count ageout, which is a data-losing remedy for what was only a
    // COST complaint — and in a CRDT specifically a resurrected deletion.
    // Worse, the counter advanced on rounds that observed no new commits at
    // all, so idle syncing burned the budget: a user tapping Sync a few
    // times while a backend read-after-write gap was still open would
    // permanently keep a membership every other replica had removed.

    test(
      'a set_remove parked before its add arrives still applies, no matter '
      'how many no-op rounds happen in between',
      () async {
        final backend = MockSyncBackend();
        final a = _Device(); // owns the add, publishes it LATE
        final b = _Device(); // holds the remove, waiting for that add
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;

        for (final target in [dbA, dbB]) {
          await _insertPreExistingNote(
            target,
            id: 'n1',
            title: 'T',
            content: 'C',
          );
          await _insertPreExistingTag(target, id: 'tag1', name: 'urgent');
        }

        // A adds the membership and mints the operation, but does NOT
        // publish it yet — so B cannot possibly observe the add-dot.
        await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
        await a.drainer.drain();
        final addDot = (await dbA.query(
          'sync_pending_ops',
          where: 'kind = ? AND memberUuid = ?',
          whereArgs: ['set_add', 'tag1'],
        )).single;

        // B is in the state a device is in after pulling a `set_remove`
        // whose target it has never seen: the remove is parked, waiting.
        await dbB.insert('sync_materialize_queue', {
          'blockingReason': 'missing_referenced_dot',
          'entityTable': 'notes',
          'entityId': 'n1',
          'fieldName': 'tags',
          'operationJson': jsonEncode({
            'entityTable': 'notes',
            'entityId': 'n1',
            'fieldName': 'tags',
            'memberUuid': 'tag1',
            'targetAuthorId': addDot['authorId'],
            'targetAuthorSeq': addDot['authorSeq'],
          }),
          'blockingKey': '${addDot['authorId']}#${addDot['authorSeq']}',
          'enqueuedAt': 1000,
        });

        // The part the ageout broke: rounds that observe nothing new. Under
        // a pass-count budget each of these spent a retry that could not
        // possibly have helped — an impatient user tapping Sync a few times
        // while the add was still in flight.
        for (var i = 0; i < maxParkedOperationAttempts * 3; i++) {
          await b.session.run(backend);
        }

        // Only now does A publish the add.
        await a.session.run(backend);

        // B pulls it and must apply the remove it has been holding.
        for (var i = 0; i < 3; i++) {
          await b.session.run(backend);
          await a.session.run(backend);
        }

        expect(
          await dbB.query('note_tags'),
          isEmpty,
          reason:
              'REGRESSION GUARD: B must converge on "removed" with A. Under '
              'the pass-count ageout, enough no-op rounds before the add '
              'arrived left this membership live on B forever, while every '
              'other replica removed it — a resurrected deletion.',
        );
        expect(
          await dbB.query(
            'sync_set_state',
            where: 'memberUuid = ?',
            whereArgs: ['tag1'],
          ),
          isEmpty,
        );
        expect(
          await dbB.query(
            'sync_materialize_queue',
            where: 'blockingReason = ?',
            whereArgs: ['missing_referenced_dot'],
          ),
          isEmpty,
          reason: 'the queue entry is resolved, not abandoned',
        );
      },
    );

    test('an unresolvable referenced dot costs no write transaction per pull',
        () async {
      // The cost complaint the ageout was the wrong answer to. A queued
      // remove whose target this device has never observed must be skipped
      // by a read-only pre-check, not by opening a transaction to discover
      // there is nothing to do.
      final db = await device.db;
      await db.insert('sync_materialize_queue', {
        'blockingReason': 'missing_referenced_dot',
        'entityTable': 'notes',
        'entityId': 'n1',
        'fieldName': 'tags',
        'operationJson': jsonEncode({
          'entityTable': 'notes',
          'entityId': 'n1',
          'fieldName': 'tags',
          'memberUuid': 'tag1',
          'targetAuthorId': 'someone-else',
          'targetAuthorSeq': 7,
        }),
        'blockingKey': 'someone-else#7',
        'enqueuedAt': 1000,
      });

      for (var i = 0; i < maxParkedOperationAttempts * 2; i++) {
        await device.session.run(MockSyncBackend());
      }

      final rows = await db.query(
        'sync_materialize_queue',
        where: 'blockingReason = ?',
        whereArgs: ['missing_referenced_dot'],
      );
      expect(rows, hasLength(1), reason: 'still waiting — never abandoned');
      expect(
        rows.single['enqueuedAt'],
        1000,
        reason:
            'and its aging signal is intact, which the health surface now '
            'actually reads',
      );
      expect(
        jsonDecode(rows.single['operationJson'] as String),
        isNot(contains('attempts')),
        reason: 'no pass-count ageout is recorded for a waiting entry',
      );

      final health = await recomputeSyncHealth(device.databaseService);
      final issue = health.issues.firstWhere(
        (i) => i.kind == SyncHealthIssueKind.waitingOnMissingDot,
      );
      expect(
        issue.oldestEntryAt,
        DateTime.fromMillisecondsSinceEpoch(1000),
        reason:
            'enqueuedAt was write-only before — two places preserved it and '
            'nothing read it',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('schema-shape assumptions', () {
    test('no sync-scope table is WITHOUT ROWID (the walk orders by rowid)',
        () async {
      final tables = <String>[
        for (final s in DatabaseService.syncEntityCaptureScopes) s.table,
        for (final s in DatabaseService.syncSetCaptureScopes) s.membershipTable,
      ];
      for (final table in tables) {
        final sql = (await db.query(
          'sqlite_master',
          columns: const ['sql'],
          where: 'type = ? AND name = ?',
          whereArgs: ['table', table],
        )).single['sql'] as String;
        expect(
          sql.toUpperCase().contains('WITHOUT ROWID'),
          isFalse,
          reason:
              '$table is WITHOUT ROWID, so SeedScanner\'s "ORDER BY rowid ASC" '
              'insertion-order walk would throw. Decide what insertion order '
              'means for it rather than dropping the ORDER BY.',
        );
      }
    });

    test('every membership table\'s payloadColumns match its real schema',
        () async {
      for (final scope in DatabaseService.syncSetCaptureScopes) {
        final columns = await db.rawQuery(
          'PRAGMA table_info(${scope.membershipTable})',
        );
        final names = columns.map((c) => c['name'] as String).toSet();
        for (final payload in scope.payloadColumns) {
          expect(
            names,
            contains(payload),
            reason:
                '${scope.membershipTable}.payloadColumns names $payload, which '
                'the table does not have — the seed contentKey and the '
                'materializer both read it',
          );
        }
        // Every NOT NULL, no-default column must be covered by the two id
        // columns, payloadColumns, or a derivable surrogate key — otherwise
        // materialization cannot build a complete row.
        for (final column in columns) {
          final name = column['name'] as String;
          final notNull = (column['notnull'] as int? ?? 0) != 0;
          final hasDefault = column['dflt_value'] != null;
          final pk = column['pk'] as int? ?? 0;
          final isIntegerPk =
              pk != 0 &&
              (column['type'] as String? ?? '').toUpperCase().contains('INT');
          if (!notNull || hasDefault || isIntegerPk) continue;
          final covered =
              name == scope.entityIdColumn ||
              name == scope.memberIdColumn ||
              scope.payloadColumns.contains(name) ||
              pk != 0;
          expect(
            covered,
            isTrue,
            reason:
                '${scope.membershipTable}.$name is NOT NULL with no default '
                'and is not an id column, a payload column, or a derivable '
                'surrogate key — set_add materialization cannot fill it',
          );
        }
      }
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('golden membership rows', () {
    // The generic PRAGMA-driven membership builder held under direct
    // probing, so it is NOT restructured. What it lacked was a pin: these
    // tests assert the EXACT row it produces for each of the five membership
    // tables, by column name, so any drift in the fill rules fails by name
    // rather than by some downstream shape.

    Future<Map<String, Object?>> materializeOne({
      required String membershipTable,
      required Future<void> Function(Database target) seedOwners,
      required String entityId,
      required String memberUuid,
      required String entityTable,
      required String fieldName,
      required String? valueJson,
    }) async {
      final backend = MockSyncBackend();
      final a = _Device();
      final b = _Device();
      addTearDown(a.close);
      addTearDown(b.close);
      final dbA = await a.db;
      final dbB = await b.db;
      await seedOwners(dbA);
      await seedOwners(dbB);

      final authorId = await a.deviceIdentity.ensureDeviceId();
      final seq = await a.seqCounter.mintNextSeq(authorId);
      final hlc = await a.hlc.generate();
      await dbA.insert('sync_pending_ops', {
        'authorId': authorId,
        'authorSeq': seq,
        'hlc': hlc.toString(),
        'contentKey': null,
        'kind': 'set_add',
        'entityTable': entityTable,
        'entityId': entityId,
        'fieldName': fieldName,
        'memberUuid': memberUuid,
        'valueJson': valueJson,
        'blobHash': null,
        'targetDotsJson': null,
        'frontierJson': jsonEncode({authorId: seq}),
        'createdAt': 1000,
        'publishedAt': null,
      });

      for (var round = 0; round < 3; round++) {
        await a.session.run(backend);
        await b.session.run(backend);
      }
      final rows = await dbB.query(membershipTable);
      expect(rows, hasLength(1), reason: '$membershipTable must materialize');
      return rows.single;
    }

    Future<void> noteAndTag(Database target) async {
      await _insertPreExistingNote(target, id: 'n1', title: 'T', content: 'C');
      await _insertPreExistingTag(target, id: 'tag1', name: 'urgent');
    }

    Future<void> conversationAndNote(Database target) async {
      await target.insert('conversations', {
        'id': 'c1',
        'title': 'Chat',
        'createdAt': 1000,
        'updatedAt': 1000,
        'isArchived': 0,
        'noteIds': '[]',
      });
      await noteAndTag(target);
      for (final id in ['m1', 'm2']) {
        await target.insert('conversation_messages', {
          'id': id,
          'type': 'user',
          'content': 'msg $id',
          'timestamp': 1000,
        });
      }
    }

    test('note_tags', () async {
      final row = await materializeOne(
        membershipTable: 'note_tags',
        seedOwners: noteAndTag,
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        valueJson: 'true',
      );
      expect(row, {'noteId': 'n1', 'tagId': 'tag1'});
    });

    test('conversation_tags', () async {
      final row = await materializeOne(
        membershipTable: 'conversation_tags',
        seedOwners: conversationAndNote,
        entityTable: 'conversations',
        entityId: 'c1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        valueJson: 'true',
      );
      expect(row, {'conversationId': 'c1', 'tagId': 'tag1'});
    });

    test('conversation_note_mapping', () async {
      final row = await materializeOne(
        membershipTable: 'conversation_note_mapping',
        seedOwners: conversationAndNote,
        entityTable: 'conversations',
        entityId: 'c1',
        fieldName: 'noteIds',
        memberUuid: 'n1',
        valueJson: jsonEncode({'createdAt': 4242}),
      );
      expect(row, {
        // `id` is this table's own INTEGER PRIMARY KEY — assigned locally by
        // SQLite, deliberately never carried across devices.
        'id': row['id'],
        'conversationId': 'c1',
        'noteId': 'n1',
        'createdAt': 4242,
      });
      expect(row['id'], isA<int>());
    });

    test('conversation_message_mapping', () async {
      final row = await materializeOne(
        membershipTable: 'conversation_message_mapping',
        seedOwners: conversationAndNote,
        entityTable: 'conversations',
        entityId: 'c1',
        fieldName: 'messageIds',
        memberUuid: 'm1',
        valueJson: jsonEncode({'createdAt': 4243}),
      );
      expect(row, {
        'id': row['id'],
        'conversationId': 'c1',
        'messageId': 'm1',
        'createdAt': 4243,
      });
      expect(row['id'], isA<int>());
    });

    test('message_parents', () async {
      final row = await materializeOne(
        membershipTable: 'message_parents',
        seedOwners: conversationAndNote,
        entityTable: 'conversation_messages',
        entityId: 'm2',
        fieldName: 'parentMessageIds',
        memberUuid: 'm1',
        valueJson: jsonEncode({'createdAt': 4244}),
      );
      expect(row, {
        // A TEXT PRIMARY KEY: derived deterministically from the membership
        // so every device agrees, and never folded into any contentKey.
        'id': deterministicMembershipRowId(
          membershipTable: 'message_parents',
          entityId: 'm2',
          memberUuid: 'm1',
        ),
        'messageId': 'm2',
        'parentMessageId': 'm1',
        'createdAt': 4244,
      });
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('syncability audit', () {
    test('every sync-scope entity table is classified, and the classification '
        'matches what the materializer can actually do', () async {
      final canSync = <String>[];
      final blocked = <String, String>{};
      for (final scope in DatabaseService.syncEntityCaptureScopes) {
        final syncability = await entitySyncability(db, scope);
        if (syncability.canSync) {
          canSync.add(scope.table);
        } else {
          blocked[scope.table] = syncability.reasonLabel;
        }
      }

      expect(
        canSync,
        <String>[
          'notes',
          // M2.14: the five tables below became syncable when `__exists__`
          // started carrying owner references and identity columns.
          'subnotes',
          'tags',
          'filters',
          'relationships',
          'tag_workflow_bindings',
          'conversations',
          'conversation_messages',
          'conversation_attachments',
          'attachments',
          'user_apps',
          // M3.1: appCode's CONTENT is a blob, so the last blocker is gone.
          'app_revisions',
        ],
        reason:
            'exactly these eleven can be built by a receiving device today. '
            'If this list changes, something either became syncable (good — '
            'say so in the milestone notes) or regressed (fix it).',
      );
      expect(blocked, {
        // The one column in the whole schema still unresolvable and NOT a
        // reference: an app revision's source code, a blob in a TEXT column
        // awaiting M3's content-addressed blob mechanism. Note the reported
        // column — before M2.14 it was `appId`, an owner FK now carried, and
        // `revisionTimestamp`, which was never really unresolvable at all
        // (it is this table's createdAt-equivalent; see
        // `syncEntityCreatedAtColumnByTable`).
        'user_app_libraries': 'non-portable id',
        'user_app_library_dependencies': 'non-portable id',
      });
    });

    test('every carried column is a declared reference or a unique identity, '
        'and no blob is ever carried', () async {
      final carried = <String, List<String>>{};
      for (final scope in DatabaseService.syncEntityCaptureScopes) {
        final syncability = await entitySyncability(db, scope);
        if (syncability.existsCarriedColumns.isEmpty) continue;
        carried[scope.table] = syncability.existsCarriedColumns;
      }

      expect(carried, {
        'subnotes': ['noteId'],
        // Sorted, not schema order — see `_computeEntitySyncability`'s note
        // on why declaration order is not stable across devices.
        'relationships': ['fromNoteId', 'toNoteId'],
        'conversation_attachments': ['messageId'],
        'attachments': ['noteId'],
        'user_apps': ['uuid'],
        'app_revisions': ['appId'],
        // `user_app_libraries`/`user_app_library_dependencies` are absent,
        // not empty-by-coincidence: a non-portable INTEGER PRIMARY KEY is
        // rejected before any column classification runs, because there is
        // no cross-device row for a carried value to belong to. Porting
        // those ids (a separate, tracked milestone) is what makes them
        // appear here — automatically, with no change to this rule.
      });

      // The load-bearing negative: the naive rule ("carry every NOT NULL,
      // no-default column outside sync scope") would carry these two, and
      // they are a whole mini-app's source and a dependency's raw file bytes
      // — inlined into a permanent CRDT operation and hashed into its
      // GENESIS contentKey. If this ever fails, the carried-column rule has
      // been widened past what it can safely carry.
      for (final entry in syncContentDeferredTables.entries) {
        for (final column in entry.value) {
          expect(
            carried[entry.key] ?? const [],
            isNot(contains(column)),
            reason:
                '${entry.key}.$column is deferred to M3 and must never ride '
                'on an __exists__ payload',
          );
        }
      }
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('progress reporting', () {
    test('onProgress fires per table so a first sync is not a frozen button',
        () async {
      await _insertPreExistingNote(db, id: 'n1', title: 'T', content: 'C');
      await _makePreExisting(db);

      final seen = <SeedScanProgress>[];
      final result = await device.scanner.scan(onProgress: seen.add);

      expect(seen, isNotEmpty);
      expect(
        seen.last.tablesDone,
        seen.last.tablesTotal,
        reason: 'the final callback reports a finished walk',
      );
      expect(seen.last.operationsSeededSoFar, result.operationsSeeded);
      expect(
        seen.map((p) => p.tablesDone).toList(),
        List.generate(seen.length, (i) => i + 1),
        reason: 'monotonic, one callback per sync-scope table',
      );
      // Reaches the UI: CloudSyncService forwards it into SyncSession.
      expect(seen.first.table, isNotEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('GENESIS convergence across two devices', () {
    test(
      'two devices seeding IDENTICAL pre-existing content converge on one '
      'canonical operation with a redirect for the other, instead of '
      'duplicating',
      () async {
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;

        // The scenario the GENESIS sentinel exists for: the same library on
        // two devices (restored from the same backup / same export), neither
        // of which has ever synced.
        for (final target in [dbA, dbB]) {
          await _insertPreExistingNote(
            target,
            id: 'n1',
            title: 'Shared title',
            content: 'Shared body',
          );
          await _insertPreExistingTag(target, id: 'tag1', name: 'urgent');
          await target.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
          await _makePreExisting(target);
        }

        for (var round = 0; round < 3; round++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        final seedA = await a.scanner.seedAuthorId();
        final seedB = await b.scanner.seedAuthorId();
        final sharedKey = genesisContentKey(
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'title',
          valueJson: jsonEncode('Shared title'),
        );

        for (final (label, target) in [('A', dbA), ('B', dbB)]) {
          // Both devices minted the same contentKey under different dots...
          final canonical = await target.query(
            'sync_dedup_index',
            where: 'contentKey = ?',
            whereArgs: [sharedKey],
          );
          expect(
            canonical,
            hasLength(1),
            reason: '$label: exactly one canonical dot for the shared key',
          );
          final canonicalAuthor = canonical.single['canonicalAuthorId'];
          // ...and the lexicographically smallest dot wins, identically on
          // both devices.
          expect(
            canonicalAuthor,
            [seedA, seedB].reduce((x, y) => x.compareTo(y) <= 0 ? x : y),
            reason: '$label: canonical-winner rule is (authorId, authorSeq)',
          );
          final loser = canonicalAuthor == seedA ? seedB : seedA;

          // ...and the loser is redirected, never silently discarded
          // (round 9: "deduplication must never discard a dot without a
          // trace").
          final redirects = await target.query(
            'sync_dot_redirects',
            where: 'observedAuthorId = ? AND canonicalAuthorId = ?',
            whereArgs: [loser, canonicalAuthor],
          );
          expect(
            redirects,
            isNotEmpty,
            reason: '$label: the non-canonical dot has a permanent redirect',
          );

          // The observable outcome: ONE note, ONE tag, ONE membership —
          // not two of each.
          expect(await target.query('notes'), hasLength(1));
          expect(
            (await target.query('notes')).single['title'],
            'Shared title',
          );
          expect(await target.query('note_tags'), hasLength(1));
          final setRows = await target.query(
            'sync_set_state',
            where: 'entityTable = ? AND entityId = ? AND memberUuid = ?',
            whereArgs: ['notes', 'n1', 'tag1'],
          );
          expect(
            setRows,
            hasLength(1),
            reason:
                '$label: the two identical add-dots collapsed to one live '
                'membership dot, not two competing ones',
          );
        }
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('end to end: the scenario the user actually hit', () {
    test(
      'a library that predates the capture triggers reaches a second device '
      'in full — the "drained 0, pulled 0, pushed 0" bug',
      () async {
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;

        await _insertPreExistingNote(
          dbA,
          id: 'n1',
          title: 'Old note one',
          content: 'Body one',
        );
        await _insertPreExistingNote(
          dbA,
          id: 'n2',
          title: 'Old note two',
          content: 'Body two',
        );
        await _insertPreExistingTag(dbA, id: 'tag1', name: 'urgent');
        await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 'tag1'});
        await dbA.insert('filters', {
          'id': 'f1',
          'name': 'Old filter',
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
        await _makePreExisting(dbA);

        // ---- The pre-M2.10 behaviour, demonstrated ------------------
        final drained = await a.drainer.drain();
        expect(
          drained.touchesProcessed,
          0,
          reason:
              'this is the whole bug: no touch rows exist for pre-trigger '
              'data, so drain has nothing to do',
        );

        // ---- One real sync round, as the user would run it ----------
        final resultA = await a.session.run(backend);
        expect(resultA.drain.touchesProcessed, 0);
        expect(
          resultA.seed.operationsSeeded,
          greaterThan(0),
          reason: 'the seed scan is what actually has work to do',
        );
        expect(
          resultA.seedPush.publishedCount,
          resultA.seed.operationsSeeded,
          reason: 'the seed namespace is its own log and must be pushed too',
        );
        expect(resultA.totalPublished, resultA.seed.operationsSeeded);

        // ---- The second device pulls and materializes ---------------
        for (var round = 0; round < 3; round++) {
          await b.session.run(backend);
          await a.session.run(backend);
        }

        final notesB = await dbB.query('notes', orderBy: 'id ASC');
        expect(notesB, hasLength(2));
        expect(notesB[0]['id'], 'n1');
        expect(notesB[0]['title'], 'Old note one');
        expect(notesB[0]['content'], 'Body one');
        expect(notesB[1]['title'], 'Old note two');
        expect(notesB[1]['content'], 'Body two');

        final tagsB = await dbB.query('tags');
        expect(tagsB, hasLength(1));
        expect(tagsB.single['name'], 'urgent');
        expect(tagsB.single['__deleted__'], 0);

        final filtersB = await dbB.query('filters');
        expect(filtersB, hasLength(1));
        expect(filtersB.single['name'], 'Old filter');

        expect(
          await dbB.query('note_tags'),
          hasLength(1),
          reason: 'the OR-Set membership seeded and materialized too',
        );

        // ---- And the follow-up sync is a genuine no-op --------------
        final quiet = await a.session.run(backend);
        expect(quiet.seed.skippedAlreadyComplete, isTrue);
        expect(quiet.seed.operationsSeeded, 0);
        expect(quiet.totalPublished, 0);
      },
    );

    test(
      'tables no receiving device could ever build are gated at MINT time, '
      'and reported — not minted, pushed, and parked forever on every peer',
      () async {
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;

        await _insertPreExistingNote(dbA, id: 'n1', title: 'Owner', content: 'C');
        // **M2.14 moved the subject of this test.** It used to be `subnotes`,
        // whose `noteId` owner FK made it unbuildable on any peer; `__exists__`
        // now carries that value and subnotes round-trip (see
        // `child_entity_sync_test.dart`). `app_revisions` is what is left:
        // `appCode` is a `NOT NULL` column that is neither in sync scope nor
        // a reference — it is an app's whole source, awaiting M3's blob
        // mechanism — so no peer can construct the row, and every operation
        // minted for it would become a permanent missing_exists entry.
        await dbA.insert('user_apps', {
          'id': 'app1',
          'uuid': 'uuid-app1',
          'name': 'Counter',
          'description': 'counts',
          'steps': '[]',
          'htmlContent': '',
          'type': 'normal',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await dbA.insert('app_revisions', {
          'id': 'rev1',
          'appId': 'app1',
          'revisionNumber': 1,
          'revisionTimestamp': 1000,
          'userPrompt': 'make a counter',
          'aiResponse': 'ok',
          'appCode': '<html>lots of code</html>',
        });
        // Two tables with nothing unresolvable, which DO sync end to end.
        await dbA.insert('tag_workflow_bindings', {
          'pattern': 'proj/',
          'isPrefix': 1,
          'skillNoteId': 'n1',
          'prompt': 'go',
          'contentImmutable': 0,
        });
        await dbA.insert('conversation_messages', {
          'id': 'm1',
          'type': 'user',
          'content': 'hello',
          'timestamp': 1000,
        });
        await _makePreExisting(dbA);

        final seedResult = await a.scanner.scan();
        expect(
          seedResult.nonPortableTablesSkipped,
          isNot(contains(startsWith('app_revisions'))),
          reason:
              'M3.1 closed the last blocker: appCode is in sync scope and its '
              'CONTENT is a blob, so the table is no longer gated out',
        );

        for (var round = 0; round < 3; round++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        expect(
          await dbB.query(
            'sync_materialize_queue',
            where: 'entityTable = ?',
            whereArgs: ['app_revisions'],
          ),
          isEmpty,
          reason: 'and no undrainable backlog on the receiver',
        );
        final revision = (await dbB.query('app_revisions')).single;
        expect(revision['userPrompt'], 'make a counter');
        expect(
          revision['appCode'],
          '<html>lots of code</html>',
          reason:
              'the whole point of M3.1: the revision arrives WITH its source, '
              'carried as a blob rather than inline in the commit log. This '
              'assertion used to read `expect(await dbB.query(\'app_revisions\'), '
              'isEmpty)` and was correct at the time — it pinned a disclosed '
              'residual, and the residual is now closed.',
        );
        expect((await dbB.query('user_apps')).single['name'], 'Counter');

        // The tables that CAN sync are untouched by the gate.
        expect(
          (await dbB.query('tag_workflow_bindings')).single['skillNoteId'],
          'n1',
        );
        expect(
          (await dbB.query('conversation_messages')).single['content'],
          'hello',
        );

        // And the user can find out, rather than wondering.
        //
        // **This used to assert `app_revisions` was reported as not syncing,
        // and that was correct until M3.1 closed it.** With nothing left
        // unsyncable in this fixture the round is clean, which is the whole
        // point — the assertion now pins that the surface stops accusing the
        // user once the reason is gone, rather than pinning the accusation.
        final health = await recomputeSyncHealth(a.databaseService);
        final tablesNotSynced = health.issues
            .where((i) => i.kind == SyncHealthIssueKind.tablesNotSynced)
            .toList();
        expect(
          tablesNotSynced.map((i) => i.detail).join(','),
          isNot(contains('app_revisions')),
          reason: 'M3.1: appCode is a blob now, so the table syncs',
        );
        expect(
          tablesNotSynced.map((i) => i.detail).join(','),
          isNot(contains('user_app_libraries')),
          reason:
              'only tables the user actually HAS rows in are reported — an '
              'unconditional list would mark every device permanently '
              'degraded and train people to ignore the warning',
        );
      },
    );

    test(
      'a pre-existing row that was edited after the triggers were installed '
      'gets its edit from drain and everything else from the seed, with no '
      'field covered twice',
      () async {
        final backend = MockSyncBackend();
        final a = _Device();
        final b = _Device();
        addTearDown(a.close);
        addTearDown(b.close);
        final dbA = await a.db;
        final dbB = await b.db;

        await _insertPreExistingNote(
          dbA,
          id: 'n1',
          title: 'Original',
          content: 'Body',
        );
        await _makePreExisting(dbA);
        // Now the user edits it — this DOES fire the AFTER UPDATE trigger.
        await dbA.update(
          'notes',
          {'title': 'Edited'},
          where: 'id = ?',
          whereArgs: ['n1'],
        );

        final resultA = await a.session.run(backend);
        expect(resultA.drain.touchesProcessed, 1);

        final deviceIdA = await a.deviceIdentity.ensureDeviceId();
        final titleOps = await dbA.query(
          'sync_pending_ops',
          where: 'entityId = ? AND fieldName = ?',
          whereArgs: ['n1', 'title'],
        );
        expect(
          titleOps,
          hasLength(1),
          reason: 'title is covered exactly once, by drain — never re-seeded',
        );
        expect(titleOps.single['authorId'], deviceIdA);
        expect(titleOps.single['valueJson'], jsonEncode('Edited'));

        final existsOps = await dbA.query(
          'sync_pending_ops',
          where: 'entityId = ? AND kind = ?',
          whereArgs: ['n1', '__exists__'],
        );
        expect(
          existsOps,
          hasLength(1),
          reason:
              'drain\'s field-touch path never mints __exists__, so without '
              'the seed the note could never be created on another device',
        );
        expect(existsOps.single['authorId'], 'seed:$deviceIdA');

        for (var round = 0; round < 3; round++) {
          await b.session.run(backend);
          await a.session.run(backend);
        }

        final noteB = (await dbB.query('notes')).single;
        expect(noteB['title'], 'Edited');
        expect(noteB['content'], 'Body');
      },
    );
  });
}
