// M2.14, review round 1 — the three defects two adversarial reviews found in
// "carry the owner reference on `__exists__`", each reproduced here BEFORE it
// was fixed, each beside a control that showed correct behaviour throughout.
//
// **All three are one shape**, which is why they share a file and (for two of
// them) a fix: an `__exists__` operation that cannot be materialized *right
// now* left no retry record anywhere, because "cannot build with this code,
// in this state" and "can never build" were collapsed into one outcome.
//
//  * **A — a complete register with no local row.** An M2.13 build that pulls
//    a NEW-format `__exists__` consumes the operation, records the register
//    as complete, builds no row and enqueues nothing for the `__exists__`
//    itself. Nothing ever rebuilds it afterwards. Triggered by M2.14's OWN
//    upgrade pass: the first device to upgrade re-mints for every stale child
//    row, and a device still on the old build consumes that stream and loses
//    exactly the data the milestone exists to deliver.
//  * **B — no register at all.** Entities created while an M2.10..M2.13 build
//    gated their table: `drain()` marked the `AFTER INSERT` touch processed
//    and minted nothing, and the seed scan short-circuits on
//    `seedScanCompletedAtKey`, so every subnote, note link, note attachment,
//    chat attachment and mini app created on those builds was permanently
//    invisible to sync with no error anywhere.
//  * **C — a `user_apps.uuid` UNIQUE collision.** `_materializeExists`
//    reported `inserted` without checking the rowid `ConflictAlgorithm
//    .ignore` returns, so a row that was never written looked like a success
//    and every one of the entity's field operations parked forever.
//
// A and B are fixed by ONE mechanism — `OutboxDrainer._repairExistsRegisters`,
// which reconciles registers against rows in both directions — and the last
// group here is that mechanism's own tests.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/materializer.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
import 'package:note_synapse/services/sync/pull_phase.dart';
import 'package:note_synapse/services/sync/seed_scanner.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/sync_health.dart';
import 'package:note_synapse/services/sync/sync_session.dart';
import 'package:note_synapse/services/sync/sync_table_shape.dart';
import 'package:note_synapse/services/sync/wire_format.dart';

import '../sync_backend/mock_sync_backend.dart';

class _Device {
  _Device() : databaseService = DatabaseService.createNew() {
    session = SyncSession(databaseService);
  }

  final DatabaseService databaseService;
  late final SyncSession session;

  Future<Database> get db => databaseService.database;
  Future<String> get authorId =>
      DeviceIdentity(databaseService).ensureDeviceId();
  SyncMaterializer materializer() => SyncMaterializer(
    SeqCounter(databaseService),
    HybridLogicalClock(databaseService),
  );
  OutboxDrainer drainer() => OutboxDrainer(
    databaseService,
    DeviceIdentity(databaseService),
    SeqCounter(databaseService),
    HybridLogicalClock(databaseService),
  );
  Future<void> close() => databaseService.close();

  /// One `sync_state` value, or null. Used by the round-3 tests to assert
  /// which repair arm actually completed.
  Future<String?> stateKey(String key) async {
    final rows = await (await db).query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }
}

/// Marks this device as one that finished its seed scan long ago — the state
/// every device in all three scenarios is actually in, and a precondition of
/// the repair pass (before the seed completes, a row legitimately has no
/// register and re-minting it through the ordinary namespace would preempt
/// the seed's own `seed:` namespace and its GENESIS `contentKey`s).
Future<void> _markSeedComplete(Database db) => db.insert('sync_state', {
  'key': seedScanCompletedAtKey,
  'value': '1',
}, conflictAlgorithm: ConflictAlgorithm.replace);

int _seq = 0;

IncomingOperation _op({
  required String kind,
  required String table,
  required String id,
  required String field,
  required String valueJson,
}) {
  _seq++;
  return IncomingOperation(
    dot: Dot('remote', _seq),
    hlc: Hlc(5000 + _seq, 0),
    kind: kind,
    entityTable: table,
    entityId: id,
    fieldName: field,
    valueJson: valueJson,
    frontier: {'remote': _seq},
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late MockSyncBackend backend;
  late _Device a;
  late _Device b;

  setUp(() {
    _seq = 0;
    backend = MockSyncBackend();
    a = _Device();
    b = _Device();
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  /// The operation stream an ALREADY-UPGRADED peer publishes for one note
  /// with one subnote — the exact stream M2.14's own repair pass emits.
  List<IncomingOperation> subnoteStream() => [
    _op(
      kind: existsFieldSentinel,
      table: 'notes',
      id: 'n1',
      field: existsFieldSentinel,
      valueJson: bareExistsPayloadJson,
    ),
    for (final entry in const {
      'title': 'Project plan',
      'content': 'the body',
      'type': 'note',
    }.entries)
      _op(
        kind: 'field',
        table: 'notes',
        id: 'n1',
        field: entry.key,
        valueJson: jsonEncode(entry.value),
      ),
    _op(
      kind: existsFieldSentinel,
      table: 'subnotes',
      id: 's1',
      field: existsFieldSentinel,
      valueJson: jsonEncode({'noteId': 'n1'}),
    ),
    for (final entry in const <String, Object?>{
      'name': 'Draft the spec',
      'content': 'by friday',
      'isCompleted': 0,
      '__deleted__': 0,
    }.entries)
      _op(
        kind: 'field',
        table: 'subnotes',
        id: 's1',
        field: entry.key,
        valueJson: jsonEncode(entry.value),
      ),
  ];

  /// Applies one operation the way `pull_phase.dart` does: apply, then
  /// materialize, in one transaction.
  Future<void> applyOne(
    _Device device,
    SyncMaterializer materializer,
    IncomingOperation op,
  ) async {
    final db = await device.db;
    // Resolved BEFORE the transaction: `ensureDeviceId` runs its own query on
    // the same single sqflite connection, and awaiting it from inside a
    // transaction deadlocks.
    final ownAuthorId = await device.authorId;
    await db.transaction((txn) async {
      final result = await CausalEngine().apply(txn, op);
      await materializer.materialize(
        txn,
        op: op,
        result: result,
        ownAuthorId: ownAuthorId,
      );
    });
  }

  // ══════════════════════════════════════════════════════════════════════
  group('A — a complete __exists__ register with no local row', () {
    /// Applies [op] the way the PARENT-COMMIT build did (`git checkout
    /// 9c2fe90^ -- lib/services/sync/materializer.dart`, i.e. M2.13).
    ///
    /// That build's `_materializeExists` fell out of its `resolvable = false`
    /// branch for any table with a `NOT NULL` column outside sync scope and
    /// returned with a bare `return` — no row, no queue entry, no outcome.
    /// Modelled here by applying the `__exists__` through `CausalEngine`
    /// alone. Every other operation goes through the ordinary materializer,
    /// whose `field` path 9c2fe90 did not touch (`git diff` confirms the
    /// change is confined to the `__exists__` branch).
    ///
    /// **Derived against the real parent-commit file, not guessed.** Running
    /// [subnoteStream] against a checkout of `9c2fe90^`'s materializer
    /// produced, verbatim:
    ///
    ///     subnotes                : []
    ///     sync_field_state        : subnotes/s1 __exists__ = {"noteId":"n1"}
    ///                               @ remote#5, plus name / content /
    ///                               isCompleted / __deleted__
    ///     sync_materialize_queue  : 4 rows, all `missing_exists`, all for
    ///                               FIELD names, blockingKey `subnotes:s1`
    ///                               — none for `__exists__` itself
    ///     sweepMissingExists x2   : 0, 0 resolved; subnotes still []
    ///
    /// The reproduction below asserts that exact state before doing anything
    /// else, so the model cannot silently stop matching what it models.
    Future<void> applyAsM213(
      _Device device,
      SyncMaterializer materializer,
      IncomingOperation op,
    ) async {
      final carriedTable = const {
        'subnotes',
        'relationships',
        'attachments',
        'conversation_attachments',
        'user_apps',
        'app_revisions',
      }.contains(op.entityTable);
      if (op.kind == existsFieldSentinel && carriedTable) {
        final db = await device.db;
        await db.transaction((txn) => CausalEngine().apply(txn, op));
        return;
      }
      await applyOne(device, materializer, op);
    }

    test(
      'REPRODUCTION: an M2.13 build consumes a new-format __exists__, and '
      'after upgrading, the register is complete, the row is absent and '
      'nothing anywhere will ever build it',
      () async {
        final db = await b.db;
        await _markSeedComplete(db);
        final materializer = b.materializer();

        for (final op in subnoteStream()) {
          await applyAsM213(b, materializer, op);
        }

        // ---- the captured post-M2.13 state, asserted ------------------
        expect(await db.query('subnotes'), isEmpty);
        final register = (await db.query(
          'sync_field_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: ['subnotes', 's1', existsFieldSentinel],
        )).single;
        expect(
          register['valueJson'],
          '{"noteId":"n1"}',
          reason: 'the register is COMPLETE — the owner value is right there',
        );
        final queued = await db.query('sync_materialize_queue');
        expect(queued, hasLength(4));
        expect(
          queued.map((r) => r['fieldName']),
          isNot(contains(existsFieldSentinel)),
          reason:
              'nothing was enqueued for the __exists__ itself — this is the '
              'defect: the only two callers of _materializeExists are a '
              'winnerChanged gate and a sweep over rows already in the queue',
        );

        // ---- the device upgrades to M2.14 -----------------------------
        // Two sweeps and a full drain, which is what the reviewer ran. Before
        // the fix this left the row absent and all four entries permanent.
        await materializer.sweepMissingExists(db, ownAuthorId: await b.authorId);
        await b.drainer().drain();
        await materializer.sweepMissingExists(db, ownAuthorId: await b.authorId);

        final subnote = (await db.query('subnotes')).single;
        expect(subnote['id'], 's1');
        expect(subnote['noteId'], 'n1');
        expect(
          subnote['name'],
          'Draft the spec',
          reason:
              'the field entries waiting on the row drain in the same sweep '
              'that creates it — __exists__ entries are retried first',
        );
        expect(
          subnote['createdAt'],
          5005,
          reason:
              "the rebuilt row derives createdAt from the REGISTER's own HLC, "
              'not from whenever the repair happened to run',
        );
        expect(await db.query('sync_materialize_queue'), isEmpty);
      },
    );

    test(
      'CONTROL: the identical operation stream on this build materializes the '
      'row as it arrives, with nothing queued at any point',
      () async {
        final db = await b.db;
        await _markSeedComplete(db);
        final materializer = b.materializer();
        for (final op in subnoteStream()) {
          await applyOne(b, materializer, op);
        }
        final subnote = (await db.query('subnotes')).single;
        expect(subnote['noteId'], 'n1');
        expect(subnote['name'], 'Draft the spec');
        expect(await db.query('sync_materialize_queue'), isEmpty);
      },
    );

    test(
      'the staggered-upgrade deployment end to end: A upgrades and re-mints, '
      'B consumes it on the old build, then B upgrades and recovers',
      () async {
        final dbA = await a.db;
        final dbB = await b.db;

        await dbA.insert('notes', {
          'id': 'n1',
          'title': 'Owner',
          'content': '',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await dbA.insert('subnotes', {
          'id': 's1',
          'noteId': 'n1',
          'name': 'Draft the spec',
          'content': '',
          'createdAt': 1001,
          'isCompleted': 0,
        });
        await a.session.run(backend);

        // B is the device still on the old build: it applies A's operations
        // through CausalEngine only for the carried-column __exists__.
        final materializerB = b.materializer();
        await _markSeedComplete(dbB);
        final authorIdA = await a.authorId;
        final page = await backend.readCommits(
          deviceLogId: authorIdA,
          afterSeq: 0,
        );
        for (final commit in page.commits) {
          for (final wire in decodeCommitOperations(
            commit.commitBytes,
            expectedAuthorId: authorIdA,
            deviceSeq: commit.deviceSeq,
          )) {
            final op = IncomingOperation(
              dot: Dot(wire.authorId, wire.authorSeq),
              hlc: wire.hlc,
              contentKey: wire.contentKey,
              kind: wire.kind,
              entityTable: wire.entityTable,
              entityId: wire.entityId,
              fieldName: wire.fieldName,
              memberUuid: wire.memberUuid,
              valueJson: wire.valueJson,
              frontier: wire.frontier,
            );
            await applyAsM213(b, materializerB, op);
          }
        }
        expect(
          await dbB.query('subnotes'),
          isEmpty,
          reason: 'the old build silently dropped it — that is the trigger',
        );

        // B upgrades. One ordinary sync is all it gets.
        await b.session.run(backend);

        final subnote = (await dbB.query('subnotes')).single;
        expect(subnote['id'], 's1');
        expect(subnote['noteId'], 'n1');
        expect(subnote['name'], 'Draft the spec');
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('B — entities created while an M2.10..M2.13 build gated their table', ()
  {
    /// The state such a build leaves: the row is there, the `AFTER INSERT`
    /// touch was marked processed by `drain()`'s syncability gate, and
    /// nothing was minted. Faithful because that gate's action was exactly
    /// "mark the touch processed, mint nothing" — see `drain()`'s own comment,
    /// which still carries the assumption M2.14 falsifies ("there is no
    /// future point at which it becomes mintable").
    Future<void> createUnderGatedBuild(Database db) async {
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Project plan',
        'content': 'the body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await db.insert('subnotes', {
        'id': 's1',
        'noteId': 'n1',
        'name': 'Draft the spec',
        'content': 'by friday',
        'createdAt': 1002,
        'isCompleted': 0,
      });
      await db.update(
        'sync_touch_log',
        {'processedAt': DateTime.now().millisecondsSinceEpoch},
        where: 'entityTable = ? AND processedAt IS NULL',
        whereArgs: ['subnotes'],
      );
      // A device that has been syncing for a while: the seed scan finished
      // under the gated build, so it will never revisit these rows.
      await _markSeedComplete(db);
    }

    test(
      'REPRODUCTION: the subnote has no __exists__ register at all, and '
      'without the repair it never reaches a peer',
      () async {
        final dbA = await a.db;
        final dbB = await b.db;
        await createUnderGatedBuild(dbA);

        expect(
          await dbA.query(
            'sync_field_state',
            where: 'entityTable = ?',
            whereArgs: ['subnotes'],
          ),
          isEmpty,
          reason: 'COHORT: A registers = 0 — nothing was ever minted',
        );

        for (var r = 0; r < 3; r++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        expect(
          (await dbA.query(
            'sync_field_state',
            where: 'entityTable = ? AND fieldName = ?',
            whereArgs: ['subnotes', existsFieldSentinel],
          )).single['valueJson'],
          '{"createdAt":1002,"noteId":"n1"}',
          reason: 'the repair pass minted the missing register',
        );
        final subnote = (await dbB.query('subnotes')).single;
        expect(subnote['id'], 's1');
        expect(subnote['noteId'], 'n1');
        expect(subnote['name'], 'Draft the spec');
        expect(subnote['content'], 'by friday');
      },
    );

    test(
      'CONTROL: a subnote created AFTER the upgrade syncs, which is what made '
      'the cohort split invisible — the feature demonstrably works',
      () async {
        final dbA = await a.db;
        final dbB = await b.db;
        await createUnderGatedBuild(dbA);
        // Created now, on the current build: its touch is unprocessed and
        // drain mints for it through the ordinary path with no repair
        // involved at all.
        await dbA.insert('subnotes', {
          'id': 's2',
          'noteId': 'n1',
          'name': 'Review it',
          'content': '',
          'createdAt': 1003,
          'isCompleted': 1,
        });

        for (var r = 0; r < 3; r++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        expect(
          (await dbB.query('subnotes', where: 'id = ?', whereArgs: ['s2']))
              .single['name'],
          'Review it',
          reason: 'CONTROL B subnotes contains the post-upgrade child',
        );
      },
    );

    test('every carried-column table in the cohort is covered, not just '
        'subnotes', () async {
      final dbA = await a.db;
      final dbB = await b.db;
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'Owner',
        'content': '',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await dbA.insert('notes', {
        'id': 'n2',
        'title': 'Other',
        'content': '',
        'type': 'note',
        'createdAt': 1001,
        'updatedAt': 1001,
      });
      await dbA.insert('subnotes', {
        'id': 's1',
        'noteId': 'n1',
        'name': 'child',
        'content': '',
        'createdAt': 1002,
        'isCompleted': 0,
      });
      await dbA.insert('relationships', {
        'id': 'r1',
        'fromNoteId': 'n1',
        'toNoteId': 'n2',
        'type': 'related',
        'createdAt': 1003,
      });
      await dbA.insert('attachments', {
        'id': 'at1',
        'noteId': 'n1',
        'filePath': 'attachments/x.png',
        'fileName': 'x.png',
        'fileType': 'image/png',
        'isRelativePath': 1,
        'createdAt': 1004,
        'includeInAIContext': 1,
      });
      await dbA.insert('user_apps', {
        'id': 'app1',
        'uuid': 'uuid-app1',
        'name': 'Counter',
        'description': '',
        'steps': '[]',
        'htmlContent': '',
        'type': 'normal',
        'createdAt': 1005,
        'updatedAt': 1005,
      });
      // Everything the gated build swallowed.
      await dbA.update(
        'sync_touch_log',
        {'processedAt': DateTime.now().millisecondsSinceEpoch},
        where: 'entityTable IN (?, ?, ?, ?) AND processedAt IS NULL',
        whereArgs: ['subnotes', 'relationships', 'attachments', 'user_apps'],
      );
      await _markSeedComplete(dbA);

      for (var r = 0; r < 3; r++) {
        await a.session.run(backend);
        await b.session.run(backend);
      }

      expect((await dbB.query('subnotes')).single['noteId'], 'n1');
      expect((await dbB.query('relationships')).single['toNoteId'], 'n2');
      expect((await dbB.query('attachments')).single['fileName'], 'x.png');
      expect((await dbB.query('user_apps')).single['uuid'], 'uuid-app1');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('C — a user_apps.uuid UNIQUE collision', () {
    /// What `import_app_screen.dart`'s `_createNewApp` produces: the YAML's
    /// `uuid` kept verbatim, a fresh `id` minted from the local wall clock.
    /// Installing the same bundled contrib plugin on two devices is the
    /// ordinary distribution path for every plugin this app ships.
    Future<void> installPlugin(
      Database db, {
      required String id,
      required String uuid,
    }) => db.insert('user_apps', {
      'id': id,
      'uuid': uuid,
      'name': 'Table Studio',
      'description': 'edits tables',
      'steps': '[]',
      'htmlContent': '',
      'type': 'normal',
      'createdAt': 1000,
      'updatedAt': 1000,
    });

    test(
      'REPRODUCTION: the shell INSERT is swallowed by ConflictAlgorithm'
      '.ignore, and the row that was never written is parked and named '
      'instead of reported as a success',
      () async {
        final db = await b.db;
        await _markSeedComplete(db);
        await installPlugin(db, id: 'local-1724', uuid: 'uuid-table-studio');
        final materializer = b.materializer();

        // Device A's copy of the same plugin arrives.
        await applyOne(
          b,
          materializer,
          _op(
            kind: existsFieldSentinel,
            table: 'user_apps',
            id: 'app-1699',
            field: existsFieldSentinel,
            valueJson: jsonEncode({'uuid': 'uuid-table-studio'}),
          ),
        );

        expect(
          await db.query('user_apps', where: 'id = ?', whereArgs: ['app-1699']),
          isEmpty,
          reason: 'the INSERT hit uuid NOT NULL UNIQUE and wrote nothing',
        );
        final parked = (await db.query('sync_materialize_queue')).single;
        expect(
          parked['blockingReason'],
          existsIdentityConflictBlockingReason,
          reason:
              'reporting `inserted` here is what produced the 11 permanent '
              'missing_exists entries the pre-M2.14 bug was reported as',
        );
        expect(parked['entityTable'], 'user_apps');
        expect(parked['entityId'], 'app-1699');
        expect(parked['fieldName'], existsFieldSentinel);
        expect(
          parked['blockingKey'],
          'user_apps.uuid:uuid-table-studio',
          reason: 'the entry names the colliding column and value',
        );
        expect(
          jsonDecode(parked['operationJson'] as String),
          containsPair('conflictExistingId', 'local-1724'),
        );

        // A field operation for the same entity parks too, exactly as before
        // — the difference is that one entry now explains the others.
        await applyOne(
          b,
          materializer,
          _op(
            kind: 'field',
            table: 'user_apps',
            id: 'app-1699',
            field: 'name',
            valueJson: jsonEncode('Table Studio'),
          ),
        );
        expect(await db.query('sync_materialize_queue'), hasLength(2));

        // Sweeping does not resolve it and does not reset its aging.
        expect(
          await materializer.sweepMissingExists(
            db,
            ownAuthorId: await b.authorId,
          ),
          0,
        );
        expect(
          (await db.query(
            'sync_materialize_queue',
            where: 'blockingReason = ?',
            whereArgs: [existsIdentityConflictBlockingReason],
          )).single['entityId'],
          'app-1699',
        );

        // And it is on the health surface under its own kind, so the user is
        // told rather than shown a green card.
        final health = await recomputeSyncHealth(b.databaseService);
        final issue = health.issues.firstWhere(
          (i) => i.kind == SyncHealthIssueKind.entityIdentityConflict,
        );
        expect(issue.count, 1);
        expect(issue.detail, contains('user_apps/app-1699'));
      },
    );

    test(
      'CONTROL: the same operation with a uuid nothing local holds inserts '
      'the row and parks nothing',
      () async {
        final db = await b.db;
        await _markSeedComplete(db);
        await installPlugin(db, id: 'local-1724', uuid: 'uuid-table-studio');
        final materializer = b.materializer();

        await applyOne(
          b,
          materializer,
          _op(
            kind: existsFieldSentinel,
            table: 'user_apps',
            id: 'app-1699',
            field: existsFieldSentinel,
            valueJson: jsonEncode({'uuid': 'uuid-diagram-studio'}),
          ),
        );

        expect(
          (await db.query(
            'user_apps',
            where: 'id = ?',
            whereArgs: ['app-1699'],
          )).single['uuid'],
          'uuid-diagram-studio',
        );
        expect(await db.query('sync_materialize_queue'), isEmpty);
      },
    );

    test(
      'the parked entry resolves by itself if the collision ever clears — it '
      'is a statement about local rows, not about the protocol',
      () async {
        final db = await b.db;
        await _markSeedComplete(db);
        await installPlugin(db, id: 'local-1724', uuid: 'uuid-table-studio');
        final materializer = b.materializer();
        await applyOne(
          b,
          materializer,
          _op(
            kind: existsFieldSentinel,
            table: 'user_apps',
            id: 'app-1699',
            field: existsFieldSentinel,
            valueJson: jsonEncode({'uuid': 'uuid-table-studio'}),
          ),
        );
        expect(await db.query('sync_materialize_queue'), hasLength(1));

        // NOTE: this is deliberately not "the user deletes the duplicate".
        // `user_apps` is hard-delete guarded, so deleting a mini app writes
        // `__deleted__ = 1` and leaves the row — and its uuid — in place. No
        // user action available today clears this; M4's identity mapping is
        // what does. What this asserts is that the MECHANISM is retryable, so
        // that fix lands as a fix and not as a second migration.
        await db.update(
          'user_apps',
          {'uuid': 'uuid-table-studio-local'},
          where: 'id = ?',
          whereArgs: ['local-1724'],
        );

        expect(
          await materializer.sweepMissingExists(
            db,
            ownAuthorId: await b.authorId,
          ),
          1,
        );
        expect(
          (await db.query(
            'user_apps',
            where: 'id = ?',
            whereArgs: ['app-1699'],
          )).single['uuid'],
          'uuid-table-studio',
        );
        expect(await db.query('sync_materialize_queue'), isEmpty);
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('the repair pass itself', () {
    test('is a no-op on a device with nothing to repair, so re-running it '
        'costs nothing and mints nothing', () async {
      final dbA = await a.db;
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'Owner',
        'content': '',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await dbA.insert('subnotes', {
        'id': 's1',
        'noteId': 'n1',
        'name': 'child',
        'content': '',
        'createdAt': 1001,
        'isCompleted': 0,
      });
      await a.session.run(backend);
      await a.session.run(backend);
      final before = (await dbA.query('sync_pending_ops')).length;

      await dbA.delete(
        'sync_state',
        where: 'key = ?',
        whereArgs: [OutboxDrainer.existsRegisterRepairStateKey],
      );
      await a.session.run(backend);

      expect((await dbA.query('sync_pending_ops')).length, before);
      expect(await dbA.query('sync_materialize_queue'), isEmpty);
    });

    test(
      'does not run before the seed scan has completed — otherwise it would '
      'mint every pre-existing row through the ordinary namespace and '
      'preempt the seed',
      () async {
        final dbA = await a.db;
        await dbA.insert('notes', {
          'id': 'n1',
          'title': 'Owner',
          'content': '',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await dbA.insert('subnotes', {
          'id': 's1',
          'noteId': 'n1',
          'name': 'child',
          'content': '',
          'createdAt': 1001,
          'isCompleted': 0,
        });
        // Exactly the pre-seed state: rows present, nothing drained, no seed
        // marker.
        await dbA.update('sync_touch_log', {
          'processedAt': DateTime.now().millisecondsSinceEpoch,
        }, where: 'processedAt IS NULL');

        await a.drainer().drain();

        expect(
          await dbA.query(
            'sync_state',
            where: 'key = ?',
            whereArgs: [OutboxDrainer.existsRegisterRepairStateKey],
          ),
          isEmpty,
          reason: 'the pass declined to run, so it did not mark itself done',
        );
        expect(await dbA.query('sync_pending_ops'), isEmpty);
      },
    );

    test(
      'PREDICATE DRIFT: a PARTIALLY complete object payload is repaired, '
      "which the v1 pass's SQL `NOT LIKE '{%'` test called fresh",
      () async {
        final dbA = await a.db;
        await dbA.insert('notes', {
          'id': 'n1',
          'title': 'Owner',
          'content': '',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await dbA.insert('notes', {
          'id': 'n2',
          'title': 'Other',
          'content': '',
          'type': 'note',
          'createdAt': 1001,
          'updatedAt': 1001,
        });
        await dbA.insert('relationships', {
          'id': 'r1',
          'fromNoteId': 'n1',
          'toNoteId': 'n2',
          'type': 'related',
          'createdAt': 1002,
        });
        await a.session.run(backend);
        await a.session.run(backend);

        // Exactly what adding a carried column to an existing table
        // produces: an object payload that is a JSON object (so it passes
        // `LIKE '{%'`) and is missing one carried column (so
        // `existsPayloadIsComplete` rejects it). `relationships` is the only
        // two-reference table in the schema, which is why it is used here.
        await dbA.update(
          'sync_field_state',
          {'valueJson': jsonEncode({'fromNoteId': 'n1'})},
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: ['relationships', 'r1', existsFieldSentinel],
        );
        await dbA.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: [OutboxDrainer.existsRegisterRepairStateKey],
        );

        await a.session.run(backend);

        expect(
          (await dbA.query(
            'sync_field_state',
            where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
            whereArgs: ['relationships', 'r1', existsFieldSentinel],
          )).single['valueJson'],
          '{"createdAt":1002,"fromNoteId":"n1","toNoteId":"n2"}',
          reason:
              'the completeness test is the SAME function the runtime uses, '
              'so the two cannot disagree about a partial payload',
        );
      },
    );

    test('an incomplete register with no local row queues nothing — an entry '
        'whose prerequisite can never arrive is the backlog M2.10 deleted', ()
        async {
      final db = await b.db;
      await _markSeedComplete(db);
      // A pre-M2.14 `true` payload for an entity this device has no row for:
      // the only device that can fix this is the one that HAS the row.
      final materializer = b.materializer();
      await applyOne(
        b,
        materializer,
        _op(
          kind: existsFieldSentinel,
          table: 'subnotes',
          id: 's1',
          field: existsFieldSentinel,
          valueJson: bareExistsPayloadJson,
        ),
      );
      await b.drainer().drain();

      expect(await db.query('subnotes'), isEmpty);
      expect(await db.query('sync_materialize_queue'), isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('the health surface fires on the RECEIVING device', () {
    test(
      'M3.1 made this rule unreachable in the live schema, and that is '
      'recorded rather than deleted',
      () async {
        final dbA = await a.db;
        final dbB = await b.db;
        await dbA.insert('user_apps', {
          'id': 'app1',
          'uuid': 'uuid-app1',
          'name': 'Counter',
          'description': '',
          'steps': '[]',
          'htmlContent': '',
          'type': 'normal',
          'selectedRevisionId': 'rev1',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await dbA.insert('app_revisions', {
          'id': 'rev1',
          'appId': 'app1',
          'revisionNumber': 1,
          'revisionTimestamp': 1001,
          'userPrompt': 'make a counter',
          'aiResponse': 'done',
          'appCode': '<html></html>',
        });
        for (var r = 0; r < 3; r++) {
          await a.session.run(backend);
          await b.session.run(backend);
        }

        // **What this test was written for no longer exists, and the reason
        // is a fix rather than a regression.** M2.14's review found that
        // `tablesNotSynced` guarded on the table's OWN row count, so a
        // receiving device — which had zero `app_revisions` — was never told
        // its mini apps had no code. The remedy was to fire when a blocked
        // table's OWNER is populated locally. `app_revisions` was that
        // rule's only beneficiary in the live schema, and M3.1 unblocked it.
        //
        // So the rule is now unreachable, and this pins that honestly: the
        // receiving device is clean because there is genuinely nothing
        // wrong, not because the detector went quiet again. The rule stays
        // for the next table that is blocked AND has an owner reference; if
        // this assertion ever flips, that is the case arriving.
        expect(
          (await dbB.query('app_revisions')).single['appCode'],
          isNotEmpty,
        );
        final health = await recomputeSyncHealth(b.databaseService);
        expect(
          health.issues
              .where((i) => i.kind == SyncHealthIssueKind.tablesNotSynced)
              .expand((i) => i.subjects),
          isNot(contains('app_revisions')),
        );
      },
    );

    test(
      'CONTROL: a device with no mini apps at all is not reported, so the '
      'detector still does not mark every device on earth degraded',
      () async {
        final dbB = await b.db;
        await dbB.insert('notes', {
          'id': 'n1',
          'title': 'Just a note',
          'content': '',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        final health = await recomputeSyncHealth(b.databaseService);
        expect(
          health.issues.where(
            (i) => i.kind == SyncHealthIssueKind.tablesNotSynced,
          ),
          isEmpty,
        );
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  group('the carried-column rule fails CLOSED on three latent schema shapes', () {
    late DatabaseService svc;
    late Database db;

    setUp(() async {
      svc = DatabaseService.createNew();
      db = await svc.database;
    });
    tearDown(() => svc.close());

    test(
      'a COMPOSITE foreign key is not treated as a carried reference — each '
      'column matching separately does not imply a matching row',
      () async {
        await db.execute(
          'CREATE TABLE composite_owner ('
          'x TEXT NOT NULL, y TEXT NOT NULL, PRIMARY KEY (x, y))',
        );
        await db.execute(
          'CREATE TABLE composite_child ('
          'id TEXT PRIMARY KEY, a TEXT NOT NULL, b TEXT NOT NULL, label TEXT, '
          'FOREIGN KEY (a, b) REFERENCES composite_owner(x, y))',
        );
        final syncability = await entitySyncability(
          db,
          const SyncEntityCaptureScope(
            table: 'composite_child',
            idColumn: 'id',
            syncScopeColumns: ['label'],
          ),
        );
        expect(
          syncability.existsCarriedColumns,
          isEmpty,
          reason:
              'carrying `a` and checking it against composite_owner.x on its '
              'own passes whenever two DIFFERENT owner rows match one column '
              'each — after which the INSERT throws',
        );
        expect(syncability.canSync, isFalse);
        expect(syncability.blocker, EntitySyncBlocker.unresolvableColumn);
      },
    );

    test(
      'REFERENCES T with the column omitted, where T has a COMPOSITE primary '
      'key, is not treated as a carried reference either',
      () async {
        await db.execute(
          'CREATE TABLE compound_pk ('
          'x TEXT NOT NULL, y TEXT NOT NULL, PRIMARY KEY (x, y))',
        );
        await db.execute(
          'CREATE TABLE omitted_ref_child ('
          'id TEXT PRIMARY KEY, '
          'ownerRef TEXT NOT NULL REFERENCES compound_pk, label TEXT)',
        );
        final syncability = await entitySyncability(
          db,
          const SyncEntityCaptureScope(
            table: 'omitted_ref_child',
            idColumn: 'id',
            syncScopeColumns: ['label'],
          ),
        );
        expect(
          syncability.existsCarriedColumns,
          isEmpty,
          reason:
              'there is no single target column to check, and checking the '
              'first half of a composite key is checking a fragment of it',
        );
        expect(syncability.canSync, isFalse);
      },
    );

    test(
      'a NOT NULL foreign key that is ALSO in syncScopeColumns blocks the '
      'table, because the shell row would write a placeholder into it',
      () async {
        await db.execute('CREATE TABLE plain_owner (id TEXT PRIMARY KEY)');
        await db.execute(
          'CREATE TABLE scoped_fk_child ('
          'id TEXT PRIMARY KEY, '
          'ownerId TEXT NOT NULL REFERENCES plain_owner(id), label TEXT)',
        );
        final syncability = await entitySyncability(
          db,
          // `ownerId` deliberately IN sync scope: the loop used to test scope
          // membership FIRST and `continue`, so the column was neither carried
          // nor blocking, and the shell row wrote `''` into a live FK column.
          const SyncEntityCaptureScope(
            table: 'scoped_fk_child',
            idColumn: 'id',
            syncScopeColumns: ['ownerId', 'label'],
          ),
        );
        expect(syncability.canSync, isFalse);
        expect(syncability.blockingColumn, 'ownerId');
      },
    );

    test(
      'CONTROL: no table in the live schema is in any of those three '
      'positions, so none of the above changes what syncs today',
      () async {
        final blocked = <String, String>{};
        for (final scope in DatabaseService.syncEntityCaptureScopes) {
          final syncability = await entitySyncability(db, scope);
          if (syncability.canSync) continue;
          blocked[scope.table] = syncability.reasonLabel;
        }
        expect(blocked, {
          'user_app_libraries': 'non-portable id',
          'user_app_library_dependencies': 'non-portable id',
        });
      },
    );

    test(
      'and the carried set is exactly six tables, eight bare — the count '
      'M2.14 stated as ten and four',
      () async {
        final carried = <String, List<String>>{};
        final bare = <String>[];
        for (final scope in DatabaseService.syncEntityCaptureScopes) {
          final syncability = await entitySyncability(db, scope);
          if (syncability.existsCarriedColumns.isEmpty) {
            bare.add(scope.table);
          } else {
            carried[scope.table] = syncability.existsCarriedColumns;
          }
        }
        expect(carried, {
          'subnotes': ['noteId'],
          'relationships': ['fromNoteId', 'toNoteId'],
          'conversation_attachments': ['messageId'],
          'attachments': ['noteId'],
          'user_apps': ['uuid'],
          'app_revisions': ['appId'],
        });
        expect(bare, hasLength(8));
        expect(
          bare,
          containsAll(const [
            // All six tables that already round-tripped before M2.14 are in
            // this set, which is the entire compatibility claim: no GENESIS
            // contentKey already published to a backend changes.
            'notes',
            'tags',
            'filters',
            'conversations',
            'conversation_messages',
            'tag_workflow_bindings',
          ]),
        );
      },
    );

    test('the payload byte form is pinned against a literal, not against '
        'jsonEncode of itself', () {
      expect(
        encodeExistsPayloadJson(const ['noteId'], const {'noteId': 'n1'}),
        '{"noteId":"n1"}',
        reason:
            'no whitespace anywhere. A reimplementation using Python json.'
            'dumps defaults emits {"noteId": "n1"} and silently stops '
            'deduping its GENESIS seeds against this one',
      );
      expect(
        encodeExistsPayloadJson(const ['fromNoteId', 'toNoteId'], const {
          'fromNoteId': 'n1',
          'toNoteId': 'n2',
        }),
        '{"fromNoteId":"n1","toNoteId":"n2"}',
      );
      expect(encodeExistsPayloadJson(const [], const {}), 'true');
    });
  });

  // ── M2.14 review round 3 ────────────────────────────────────────────────

  group('round 3 — the seed gate applies to arm 2 no longer (H1)', () {
    /// A device with one parked queue entry. `SeedScanner` withholds
    /// `seedScanCompletedAtKey` whenever `_isPristine` returns `queued`, and
    /// that state can be permanent — a `missing_referenced_dot` naming an
    /// add-dot in a log a peer's reset retired never resolves, and the design
    /// states retired logs are never reclaimed.
    Future<void> parkAnEntry(Database db) => db.insert('sync_materialize_queue', {
      'blockingReason': missingReferencedDotBlockingReason,
      'entityTable': 'notes',
      'entityId': 'n-parked',
      'fieldName': 'title',
      'operationJson': '{}',
      'blockingKey': 'nope#1',
      'enqueuedAt': 1,
    });

    test(
      'arm 2 repairs an orphaned register even though the seed never completed',
      () async {
        final db = await a.db;
        await parkAnEntry(db);
        // A complete register with no local row — defect A's cohort.
        await db.insert('sync_field_state', {
          'entityTable': 'subnotes',
          'entityId': 's-orphan',
          'fieldName': '__exists__',
          'valueJson': jsonEncode({'noteId': 'n1'}),
          'hlc': Hlc(4321, 0).toString(),
          'authorId': 'remote',
          'authorSeq': 1,
          'frontierJson': '{}',
          'updatedAt': 1,
        });
        // NOT calling _markSeedComplete: this is the stuck-in-deferral device.

        await a.drainer().drain();

        final queued = await db.query(
          'sync_materialize_queue',
          where: 'entityTable = ? AND fieldName = ?',
          whereArgs: ['subnotes', '__exists__'],
        );
        expect(
          queued,
          hasLength(1),
          reason:
              'arm 2 mints nothing — it enqueues a local materialization retry '
              'for a register this device already holds — so the seed-scan '
              'gate that protects arm 1 has no bearing on it. Gating both '
              'together let one parked entry disable the repair forever.',
        );
        expect(
          await a.stateKey(OutboxDrainer.existsOrphanRepairStateKey),
          isNotNull,
        );
      },
    );

    test(
      'CONTROL: arm 1 still waits for the seed, so it cannot preempt the '
      'seed namespace',
      () async {
        final db = await a.db;
        await parkAnEntry(db);
        await db.insert('notes', {
          'id': 'n1',
          'title': 'T',
          'content': '',
          'type': 'note',
          'createdAt': 1,
          'updatedAt': 1,
        });
        await db.insert('subnotes', {
          'id': 's1',
          'noteId': 'n1',
          'name': 'S',
          'content': '',
          'createdAt': 1,
        });

        await a.drainer().drain();

        expect(
          await a.stateKey(OutboxDrainer.existsRegisterRepairStateKey),
          isNull,
          reason:
              'arm 1 MINTS through the ordinary namespace, so running it '
              'before the seed finishes would preempt the seed`s own `seed:` '
              'namespace and destroy its GENESIS contentKeys. Its marker must '
              'stay unwritten so a later round retries it.',
        );
      },
    );
  });

  group('round 3 — a NOT NULL FK with a DEFAULT fails closed (M1)', () {
    test('a reference column is carried even when it has a SQL default', () async {
      final db = await a.db;
      await db.execute(
        'CREATE TABLE probe_child('
        '  id TEXT PRIMARY KEY,'
        '  ownerId TEXT NOT NULL DEFAULT \'\' REFERENCES notes(id),'
        '  createdAt INTEGER NOT NULL DEFAULT 0'
        ')',
      );
      const scope = SyncEntityCaptureScope(
        table: 'probe_child',
        idColumn: 'id',
        syncScopeColumns: [],
      );

      final syncability = await entitySyncability(db, scope);

      expect(
        syncability.existsCarriedColumns,
        ['ownerId'],
        reason:
            'a default satisfies NOT NULL and names no existing row, so '
            'omitting the column let SQLite write the default and the INSERT '
            'threw FOREIGN KEY constraint failed inside sweepMissingExists — '
            'escaping the whole session, the exact wedge the other three '
            'guards exist to prevent. ConflictAlgorithm.ignore does not '
            'swallow an FK failure.',
      );
      expect(syncability.canSync, isTrue);
    });

    test(
      'CONTROL: a non-reference NOT NULL column with a default is still '
      'excused, so nothing that syncs today stops',
      () async {
        final db = await a.db;
        await db.execute(
          'CREATE TABLE probe_plain('
          '  id TEXT PRIMARY KEY,'
          '  label TEXT NOT NULL DEFAULT \'x\','
          '  createdAt INTEGER NOT NULL DEFAULT 0'
          ')',
        );
        const scope = SyncEntityCaptureScope(
          table: 'probe_plain',
          idColumn: 'id',
          syncScopeColumns: [],
        );

        final syncability = await entitySyncability(db, scope);
        expect(syncability.existsCarriedColumns, isEmpty);
        expect(syncability.canSync, isTrue);
      },
    );
  });

  group('round 3 — identity conflicts are reported once, not twelve times (H2)', () {
    test(
      'field operations parked behind an identity conflict are not ALSO '
      'reported as waiting for an entity that will never arrive',
      () async {
        final db = await a.db;
        Future<void> park(String reason, String field) =>
            db.insert('sync_materialize_queue', {
              'blockingReason': reason,
              'entityTable': 'user_apps',
              'entityId': 'app-peer',
              'fieldName': field,
              'operationJson': '{}',
              'blockingKey': 'user_apps:app-peer',
              'enqueuedAt': 1,
            });
        await park(existsIdentityConflictBlockingReason, '__exists__');
        for (final f in ['name', 'description', 'steps']) {
          await park(missingExistsBlockingReason, f);
        }

        final health = await recomputeSyncHealth(a.databaseService);
        final kinds = health.issues.map((i) => i.kind).toSet();

        expect(kinds, contains(SyncHealthIssueKind.entityIdentityConflict));
        expect(
          kinds,
          isNot(contains(SyncHealthIssueKind.waitingOnMissingEntity)),
          reason:
              'two devices that installed the same bundled plugin land here, '
              'and reporting eleven "waiting for user_apps/app-peer" rows '
              'beside the one true cause reproduces the exact signature of '
              'the pre-M2.14 bug this milestone fixed',
        );
      },
    );

    test(
      'CONTROL: an ordinary missing-entity backlog with no identity conflict '
      'is still reported',
      () async {
        final db = await a.db;
        await db.insert('sync_materialize_queue', {
          'blockingReason': missingExistsBlockingReason,
          'entityTable': 'subnotes',
          'entityId': 's1',
          'fieldName': 'name',
          'operationJson': '{}',
          'blockingKey': 'notes:n1',
          'enqueuedAt': 1,
        });

        final health = await recomputeSyncHealth(a.databaseService);
        expect(
          health.issues.map((i) => i.kind),
          contains(SyncHealthIssueKind.waitingOnMissingEntity),
        );
      },
    );
  });
}
