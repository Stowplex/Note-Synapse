// M2.14 — "carry the owner reference on `__exists__`, so child entities can
// actually sync."
//
// **What this file is for, and why it is not a test that the operation
// carries a field.** Before M2.14 a user asked why note links, note
// attachments, chat attachments and mini apps never appeared on a second
// device. The answer was that `materializer.dart` could not build those rows
// at all: each table declares a `NOT NULL` owner pointer with no SQL default
// that sits outside `syncScopeColumns`, so the shell-row `INSERT` had no
// source for it and was skipped, and M2.10 made minting gate on the same
// predicate. Asserting that an `__exists__` operation now has a `noteId` in
// its payload would prove none of that is fixed. So the load-bearing test
// here is a SECOND DEVICE REBUILDING THE REAL THING — a note with subnotes
// and a link to another note, a conversation with an attachment row, a mini
// app with a pinned revision — created on device A and reconstructed on a
// fresh device B through real `SyncSession.run()` calls against
// `MockSyncBackend`, asserted row by row against the originals.
//
// Four other things are pinned here because each is a separate way the
// mechanism could be built and still not work:
//
//  * **Ordering.** A child cannot be inserted before the row it references,
//    and this codebase runs with `PRAGMA foreign_keys = ON`, so an unchecked
//    INSERT throws rather than silently skipping. The child-before-owner
//    path is driven directly (queue, then sweep) rather than hoped for.
//  * **The pre-M2.14 payload.** Every one of these tables minted and
//    published `__exists__` normally until M2.10 gated them, so real
//    operations carrying the constant `true` exist on real backends. A
//    device holding one of those registers must (a) not crash, (b) not
//    invent an owner, and (c) eventually upgrade itself — otherwise the
//    milestone works for data created after the upgrade and silently never
//    works for the data that prompted it.
//  * **The wire format is unchanged.** `value` has always carried arbitrary
//    JSON; a v1 and a v2 envelope both round-trip an object payload verbatim.
//  * **What is still NOT synced**, so the claim in the milestone notes is
//    checkable rather than assumed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/materializer.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
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
  Future<void> close() => databaseService.close();
}

/// Builds the whole scenario library on [db] — one function so the "created
/// on A" and "expected on B" sides can never drift apart.
Future<void> _buildLibrary(Database db) async {
  await db.insert('notes', {
    'id': 'n1',
    'title': 'Project plan',
    'content': 'the body',
    'type': 'note',
    'createdAt': 1000,
    'updatedAt': 1000,
  });
  await db.insert('notes', {
    'id': 'n2',
    'title': 'Background reading',
    'content': 'refs',
    'type': 'note',
    'createdAt': 1001,
    'updatedAt': 1001,
  });

  // Subnotes — blocked before M2.14 by `noteId`.
  await db.insert('subnotes', {
    'id': 's1',
    'noteId': 'n1',
    'name': 'Draft the spec',
    'content': 'by friday',
    'createdAt': 1002,
    'isCompleted': 0,
  });
  await db.insert('subnotes', {
    'id': 's2',
    'noteId': 'n1',
    'name': 'Review it',
    'content': '',
    'createdAt': 1003,
    'isCompleted': 1,
  });

  // A note link — blocked before M2.14 by BOTH `fromNoteId` and `toNoteId`,
  // which is the only two-reference table in the schema.
  await db.insert('relationships', {
    'id': 'r1',
    'fromNoteId': 'n1',
    'toNoteId': 'n2',
    'type': 'related',
    'createdAt': 1004,
  });

  // A note attachment — blocked before M2.14 by `noteId`.
  await db.insert('attachments', {
    'id': 'a1',
    'noteId': 'n1',
    'filePath': 'attachments/diagram.png',
    'fileName': 'diagram.png',
    'fileType': 'image/png',
    'isRelativePath': 1,
    'createdAt': 1005,
    'includeInAIContext': 1,
    'metadata': null,
  });

  // A conversation with a message and a chat attachment — the last blocked
  // before M2.14 by `messageId`.
  await db.insert('conversations', {
    'id': 'c1',
    'title': 'Planning chat',
    'noteIds': '[]',
    'createdAt': 1006,
    'updatedAt': 1006,
  });
  await db.insert('conversation_messages', {
    'id': 'm1',
    'type': 'user',
    'content': 'here is the diagram',
    'timestamp': 1007,
  });
  await db.insert('conversation_message_mapping', {
    'conversationId': 'c1',
    'messageId': 'm1',
    'createdAt': 1007,
  });
  await db.insert('conversation_attachments', {
    'id': 'ca1',
    'messageId': 'm1',
    'filePath': 'attachments/m1_diagram.png',
    'fileName': 'diagram.png',
    'fileType': 'image/png',
    'isRelativePath': 1,
    'createdAt': 1008,
  });

  // A mini app with a pinned revision — `user_apps` blocked before M2.14 by
  // `uuid` (a required identity column, not an owner FK).
  await db.insert('user_apps', {
    'id': 'app1',
    'uuid': 'uuid-app1',
    'name': 'Counter',
    'description': 'counts things',
    'steps': '["tap"]',
    'htmlContent': '',
    'appState': '{"n":3}',
    'type': 'normal',
    'selectedRevisionId': 'rev1',
    'author': 'me',
    'license': 'MIT',
    'createdAt': 1009,
    'updatedAt': 1009,
  });
  await db.insert('app_revisions', {
    'id': 'rev1',
    'appId': 'app1',
    'revisionNumber': 1,
    'revisionTimestamp': 1010,
    'userPrompt': 'make a counter',
    'aiResponse': 'done',
    'appCode': '<html><body>counter</body></html>',
    'attachmentPaths': null,
  });
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
    backend = MockSyncBackend();
    a = _Device();
    b = _Device();
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  Future<void> syncBoth({int rounds = 3}) async {
    for (var r = 0; r < rounds; r++) {
      await a.session.run(backend);
      await b.session.run(backend);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  group('a fresh device rebuilds the real thing', () {
    test(
      'subnotes, a note link, a note attachment, a chat attachment and a mini '
      'app all arrive on device B as real rows — asserted column by column',
      () async {
        final dbA = await a.db;
        final dbB = await b.db;
        await _buildLibrary(dbA);

        await syncBoth();

        Future<Map<String, Object?>> rowB(String table, String id) async =>
            (await dbB.query(table, where: 'id = ?', whereArgs: [id])).single;

        // ---- subnotes -------------------------------------------------
        final subnotes = await dbB.query('subnotes', orderBy: 'id ASC');
        expect(subnotes, hasLength(2));
        expect(subnotes[0], {
          'id': 's1',
          // The whole point: an owner pointer that no field operation could
          // ever have supplied.
          'noteId': 'n1',
          'name': 'Draft the spec',
          'content': 'by friday',
          // createdAt is derived from the __exists__ operation's own HLC wall
          // clock, not carried — see `_createdAtFromHlcWall`. Asserted as a
          // plausible instant rather than as A's 1002, because it is a
          // documented origin/receiver split, not an identity.
          'createdAt': isA<int>(),
          'isCompleted': 0,
          '__deleted__': 0,
        });
        expect(subnotes[1]['id'], 's2');
        expect(subnotes[1]['noteId'], 'n1');
        expect(subnotes[1]['name'], 'Review it');
        expect(subnotes[1]['isCompleted'], 1);

        // ---- the note link -------------------------------------------
        final link = await rowB('relationships', 'r1');
        expect(link['fromNoteId'], 'n1');
        expect(link['toNoteId'], 'n2');
        expect(link['type'], 'related');
        expect(link['__deleted__'], 0);

        // ---- the note attachment -------------------------------------
        final attachment = await rowB('attachments', 'a1');
        expect(attachment['noteId'], 'n1');
        expect(attachment['filePath'], 'attachments/diagram.png');
        expect(attachment['fileName'], 'diagram.png');
        expect(attachment['fileType'], 'image/png');
        expect(attachment['isRelativePath'], 1);
        expect(attachment['includeInAIContext'], 1);

        // ---- the chat attachment -------------------------------------
        final chatAttachment = await rowB('conversation_attachments', 'ca1');
        expect(chatAttachment['messageId'], 'm1');
        expect(chatAttachment['filePath'], 'attachments/m1_diagram.png');
        expect(chatAttachment['fileName'], 'diagram.png');
        expect(chatAttachment['fileType'], 'image/png');

        // ---- the mini app --------------------------------------------
        final app = await rowB('user_apps', 'app1');
        expect(app['uuid'], 'uuid-app1');
        expect(app['name'], 'Counter');
        expect(app['description'], 'counts things');
        expect(app['steps'], '["tap"]');
        expect(app['appState'], '{"n":3}');
        expect(app['type'], 'normal');
        expect(app['selectedRevisionId'], 'rev1');
        expect(app['author'], 'me');
        expect(app['license'], 'MIT');

        // ---- and the honest half of the mini-app story ----------------
        expect(
          await dbB.query('app_revisions'),
          isEmpty,
          reason:
              'app_revisions is still blocked by appCode, which is an entire '
              'app source and belongs to M3 blob sync — the app row syncs, '
              'its runnable code does not',
        );
      },
    );

    test('the owner reference survives a round trip through a real commit, '
        'not just through local state', () async {
      final dbA = await a.db;
      await _buildLibrary(dbA);
      await a.session.run(backend);

      // Read the published operations straight back off the backend and
      // decode them the way a peer does. This is what proves the value is on
      // the WIRE rather than merely in device A's own sync_field_state.
      final authorIdA = await a.authorId;
      final page = await backend.readCommits(
        deviceLogId: authorIdA,
        afterSeq: 0,
      );
      final commits = page.commits;
      final payloads = <String, Map<String, Object?>>{};
      for (final commit in commits) {
        for (final op in decodeCommitOperations(
          commit.commitBytes,
          expectedAuthorId: authorIdA,
          deviceSeq: commit.deviceSeq,
        )) {
          if (op.kind != existsFieldSentinel) continue;
          payloads['${op.entityTable}/${op.entityId}'] = decodeExistsPayload(
            op.valueJson,
          );
        }
      }

      expect(payloads['subnotes/s1'], {'noteId': 'n1'});
      expect(payloads['relationships/r1'], {
        // Sorted, not schema order — two devices must produce the identical
        // string or their GENESIS contentKeys diverge, and `ALTER TABLE ADD
        // COLUMN` makes declaration order device-dependent.
        'fromNoteId': 'n1',
        'toNoteId': 'n2',
      });
      expect(payloads['attachments/a1'], {'noteId': 'n1'});
      expect(payloads['conversation_attachments/ca1'], {'messageId': 'm1'});
      expect(payloads['user_apps/app1'], {'uuid': 'uuid-app1'});

      // Ten of the fourteen tables carry nothing, and their payload is
      // byte-for-byte the constant every already-published operation has:
      // no GENESIS contentKey anywhere in the field changes.
      for (final commit in commits) {
        for (final op in decodeCommitOperations(
          commit.commitBytes,
          expectedAuthorId: authorIdA,
          deviceSeq: commit.deviceSeq,
        )) {
          if (op.kind != existsFieldSentinel) continue;
          if (const {
            'notes',
            'tags',
            'filters',
            'conversations',
            'conversation_messages',
            'tag_workflow_bindings',
          }.contains(op.entityTable)) {
            expect(
              op.valueJson,
              bareExistsPayloadJson,
              reason: '${op.entityTable} must still carry the constant true',
            );
          }
        }
      }
    });

    test('an edit made on B after the rebuild travels back to A — the child '
        'rows are live, not inert copies', () async {
      final dbA = await a.db;
      final dbB = await b.db;
      await _buildLibrary(dbA);
      await syncBoth();

      await dbB.update(
        'subnotes',
        {'isCompleted': 1},
        where: 'id = ?',
        whereArgs: ['s1'],
      );
      await dbB.update(
        'attachments',
        {'includeInAIContext': 0},
        where: 'id = ?',
        whereArgs: ['a1'],
      );
      await syncBoth();

      expect(
        (await dbA.query('subnotes', where: 'id = ?', whereArgs: ['s1']))
            .single['isCompleted'],
        1,
      );
      expect(
        (await dbA.query('attachments', where: 'id = ?', whereArgs: ['a1']))
            .single['includeInAIContext'],
        0,
      );
    });

    test('a tombstone on a child row propagates too', () async {
      final dbA = await a.db;
      final dbB = await b.db;
      await _buildLibrary(dbA);
      await syncBoth();

      await dbA.update(
        'relationships',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: ['r1'],
      );
      await syncBoth();

      expect(
        (await dbB.query('relationships', where: 'id = ?', whereArgs: ['r1']))
            .single['__deleted__'],
        1,
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('ordering: a child pulled before its owner', () {
    /// Applies one hand-built operation through the real engine +
    /// materializer, exactly as `pull_phase.dart` does (apply, then
    /// materialize, in one transaction).
    Future<void> applyOne(
      _Device device,
      SyncMaterializer materializer,
      IncomingOperation op,
    ) async {
      final db = await device.db;
      // Resolved BEFORE the transaction: `ensureDeviceId` runs its own query
      // on the same single sqflite connection, and awaiting it from inside a
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

    test(
      "a subnote's __exists__ that arrives before its note is queued under "
      'missing_exists, and the sweep builds it the moment the note lands',
      () async {
        final db = await b.db;
        final materializer = SyncMaterializer(
          SeqCounter(b.databaseService),
          HybridLogicalClock(b.databaseService),
        );

        await applyOne(
          b,
          materializer,
          IncomingOperation(
            dot: const Dot('remote', 1),
            hlc: Hlc(5000, 0),
            kind: existsFieldSentinel,
            entityTable: 'subnotes',
            entityId: 's1',
            fieldName: existsFieldSentinel,
            valueJson: jsonEncode({'noteId': 'n1'}),
            frontier: const {'remote': 1},
          ),
        );

        expect(
          await db.query('subnotes'),
          isEmpty,
          reason:
              'the note does not exist yet, and PRAGMA foreign_keys is ON — '
              'inserting anyway would throw out of the whole session',
        );
        final queued = (await db.query('sync_materialize_queue')).single;
        expect(queued['blockingReason'], missingExistsBlockingReason);
        expect(queued['entityTable'], 'subnotes');
        expect(queued['entityId'], 's1');
        expect(
          queued['blockingKey'],
          'notes:n1',
          reason:
              'the entry records what is ACTUALLY missing (the owner), which '
              'is a different row from the one being materialized',
        );

        // The owner arrives.
        await applyOne(
          b,
          materializer,
          IncomingOperation(
            dot: const Dot('remote', 2),
            hlc: Hlc(5001, 0),
            kind: existsFieldSentinel,
            entityTable: 'notes',
            entityId: 'n1',
            fieldName: existsFieldSentinel,
            valueJson: bareExistsPayloadJson,
            frontier: const {'remote': 2},
          ),
        );

        final resolved = await materializer.sweepMissingExists(
          db,
          ownAuthorId: await b.authorId,
        );
        expect(resolved, 1);
        final subnote = (await db.query('subnotes')).single;
        expect(subnote['id'], 's1');
        expect(subnote['noteId'], 'n1');
        expect(await db.query('sync_materialize_queue'), isEmpty);
      },
    );

    test(
      'a relationship blocked on its SECOND endpoint updates the recorded '
      'blocker rather than being retried against an already-resolved one',
      () async {
        final db = await b.db;
        final materializer = SyncMaterializer(
          SeqCounter(b.databaseService),
          HybridLogicalClock(b.databaseService),
        );

        Future<void> note(String id, int seq) => applyOne(
          b,
          materializer,
          IncomingOperation(
            dot: Dot('remote', seq),
            hlc: Hlc(5000 + seq, 0),
            kind: existsFieldSentinel,
            entityTable: 'notes',
            entityId: id,
            fieldName: existsFieldSentinel,
            valueJson: bareExistsPayloadJson,
            frontier: {'remote': seq},
          ),
        );

        await applyOne(
          b,
          materializer,
          IncomingOperation(
            dot: const Dot('remote', 1),
            hlc: Hlc(5001, 0),
            kind: existsFieldSentinel,
            entityTable: 'relationships',
            entityId: 'r1',
            fieldName: existsFieldSentinel,
            valueJson: jsonEncode({'fromNoteId': 'n1', 'toNoteId': 'n2'}),
            frontier: const {'remote': 1},
          ),
        );
        expect(
          (await db.query('sync_materialize_queue')).single['blockingKey'],
          'notes:n1',
        );

        // Only the FIRST endpoint arrives. The retry must NOT insert — that
        // is the exact shape (`ConflictAlgorithm.ignore` does not suppress a
        // FOREIGN KEY violation) that once threw out of SyncSession.run and
        // wedged a device permanently.
        await note('n1', 2);
        expect(
          await materializer.sweepMissingExists(
            db,
            ownAuthorId: await b.authorId,
          ),
          0,
        );
        expect(await db.query('relationships'), isEmpty);
        expect(
          (await db.query('sync_materialize_queue')).single['blockingKey'],
          'notes:n2',
          reason:
              'the entry now points at what is genuinely missing, so the next '
              'sweep checks the right thing',
        );

        await note('n2', 3);
        expect(
          await materializer.sweepMissingExists(
            db,
            ownAuthorId: await b.authorId,
          ),
          1,
        );
        final link = (await db.query('relationships')).single;
        expect(link['fromNoteId'], 'n1');
        expect(link['toNoteId'], 'n2');
      },
    );

    test(
      'one sweep drains a whole entity: the __exists__ entry is retried '
      'before the field entries that are waiting on the row it creates',
      () async {
        final db = await b.db;
        final materializer = SyncMaterializer(
          SeqCounter(b.databaseService),
          HybridLogicalClock(b.databaseService),
        );

        // The child's __exists__ AND one of its fields both arrive with no
        // owner. Enqueued in that order, so `id ASC` alone would happen to
        // work; the field is enqueued FIRST here precisely so the ordering
        // rule is what makes this pass.
        await applyOne(
          b,
          materializer,
          IncomingOperation(
            dot: const Dot('remote', 1),
            hlc: Hlc(5001, 0),
            kind: 'field',
            entityTable: 'subnotes',
            entityId: 's1',
            fieldName: 'name',
            valueJson: jsonEncode('Draft the spec'),
            frontier: const {'remote': 1},
          ),
        );
        await applyOne(
          b,
          materializer,
          IncomingOperation(
            dot: const Dot('remote', 2),
            hlc: Hlc(5002, 0),
            kind: existsFieldSentinel,
            entityTable: 'subnotes',
            entityId: 's1',
            fieldName: existsFieldSentinel,
            valueJson: jsonEncode({'noteId': 'n1'}),
            frontier: const {'remote': 2},
          ),
        );
        expect(await db.query('sync_materialize_queue'), hasLength(2));

        await applyOne(
          b,
          materializer,
          IncomingOperation(
            dot: const Dot('remote', 3),
            hlc: Hlc(5003, 0),
            kind: existsFieldSentinel,
            entityTable: 'notes',
            entityId: 'n1',
            fieldName: existsFieldSentinel,
            valueJson: bareExistsPayloadJson,
            frontier: const {'remote': 3},
          ),
        );

        expect(
          await materializer.sweepMissingExists(
            db,
            ownAuthorId: await b.authorId,
          ),
          2,
          reason: 'both entries resolve in ONE pass, not one pass each',
        );
        final subnote = (await db.query('subnotes')).single;
        expect(subnote['noteId'], 'n1');
        expect(
          subnote['name'],
          'Draft the spec',
          reason:
              "the field that was waiting for the row is applied in the same "
              'sweep that created it',
        );
        expect(await db.query('sync_materialize_queue'), isEmpty);
      },
    );

    // **Named for what it actually proves.** Whether device C sees the
    // subnote's log before the note's is decided by `pull_phase.dart`'s
    // device iteration order, which this test cannot pin — reverting the
    // owner check above leaves this one passing, so it is a convergence
    // test, not the ordering proof. The three tests above ARE the ordering
    // proof: each fails with a real `FOREIGN KEY constraint failed` when the
    // check is removed.
    test('a child and its owner authored by two DIFFERENT devices converge on '
        'a third device that has seen neither before', () async {
      final dbA = await a.db;
      final dbB = await b.db;
      final c = _Device();
      addTearDown(c.close);
      final dbC = await c.db;

      // A owns the note; B (having pulled it) owns the subnote. C, a fresh
      // device, has to reconcile two independent logs in whatever order the
      // backend hands them over.
      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'Owner',
        'content': '',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await a.session.run(backend);
      await b.session.run(backend);
      await dbB.insert('subnotes', {
        'id': 's1',
        'noteId': 'n1',
        'name': 'child',
        'content': '',
        'createdAt': 1001,
        'isCompleted': 0,
      });
      await b.session.run(backend);

      for (var r = 0; r < 3; r++) {
        await c.session.run(backend);
      }

      final subnote = (await dbC.query('subnotes')).single;
      expect(subnote['id'], 's1');
      expect(subnote['noteId'], 'n1');
      expect(subnote['name'], 'child');
      expect(
        await dbC.query(
          'sync_materialize_queue',
          where: 'entityTable = ?',
          whereArgs: ['subnotes'],
        ),
        isEmpty,
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('operations minted before M2.14', () {
    test('an __exists__ carrying the constant true is read without throwing '
        'and never invents an owner', () async {
      final db = await b.db;
      final materializer = SyncMaterializer(
        SeqCounter(b.databaseService),
        HybridLogicalClock(b.databaseService),
      );

      await db.insert('notes', {
        'id': 'n1',
        'title': 'Owner',
        'content': '',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });

      final ownAuthorId = await b.authorId;
      await db.transaction((txn) async {
        final op = IncomingOperation(
          dot: const Dot('legacy', 1),
          hlc: Hlc(5000, 0),
          kind: existsFieldSentinel,
          entityTable: 'subnotes',
          entityId: 's1',
          fieldName: existsFieldSentinel,
          // Exactly what every build before M2.14 minted.
          valueJson: 'true',
          frontier: const {'legacy': 1},
        );
        final result = await CausalEngine().apply(txn, op);
        await materializer.materialize(
          txn,
          op: op,
          result: result,
          ownAuthorId: ownAuthorId,
        );
      });

      expect(
        await db.query('subnotes'),
        isEmpty,
        reason:
            'no owner value is available, and guessing one would put a row '
            'under a fabricated parent',
      );
    });

    test(
      "a device holding a pre-M2.14 __exists__ register re-mints it with the "
      'owner reference on the next drain, and the entity then reaches a peer',
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
        await b.session.run(backend);
        expect(await dbB.query('subnotes'), hasLength(1));

        // Now simulate the real starting state: this device synced under a
        // build that minted `true` for subnotes. Rewind A's register to that
        // payload and clear the upgrade marker, leaving everything else
        // exactly as a pre-M2.14 device would have it.
        await dbA.update(
          'sync_field_state',
          {'valueJson': 'true'},
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: ['subnotes', 's1', existsFieldSentinel],
        );
        await dbA.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: [OutboxDrainer.existsRegisterRepairStateKey],
        );

        // A fresh peer that has never seen this subnote.
        final c = _Device();
        addTearDown(c.close);
        final dbC = await c.db;

        for (var r = 0; r < 3; r++) {
          await a.session.run(backend);
          await c.session.run(backend);
        }

        final registerA = (await dbA.query(
          'sync_field_state',
          where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
          whereArgs: ['subnotes', 's1', existsFieldSentinel],
        )).single;
        expect(
          registerA['valueJson'],
          jsonEncode({'noteId': 'n1'}),
          reason: 'the stale register was replaced, not left in place',
        );
        expect(
          registerA['contentKey'],
          isNull,
          reason:
              'the upgrade re-mints through the ORDINARY drain namespace — a '
              'GENESIS re-seed would violate the seed precondition the Key '
              'Lemma rests on for __exists__ specifically',
        );

        final subnoteC = (await dbC.query('subnotes')).single;
        expect(subnoteC['id'], 's1');
        expect(subnoteC['noteId'], 'n1');
        expect(subnoteC['name'], 'Draft the spec');
      },
    );

    test('the upgrade pass is a no-op on a device whose registers are already '
        'complete — it does not re-mint every entity on every drain', () async {
      final dbA = await a.db;
      await _buildLibrary(dbA);
      await a.session.run(backend);
      final publishedFirst = (await dbA.query('sync_pending_ops')).length;

      // Clear the marker and drain again: the pass runs, finds every
      // register complete, and mints nothing.
      await dbA.delete(
        'sync_state',
        where: 'key = ?',
        whereArgs: [OutboxDrainer.existsRegisterRepairStateKey],
      );
      await a.session.run(backend);

      expect((await dbA.query('sync_pending_ops')).length, publishedFirst);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('wire format', () {
    WireOperation existsOp(String valueJson) => WireOperation(
      authorId: 'dev-a',
      authorSeq: 7,
      hlc: Hlc(1234, 0),
      contentKey: 'ck',
      kind: existsFieldSentinel,
      entityTable: 'subnotes',
      entityId: 's1',
      fieldName: existsFieldSentinel,
      valueJson: valueJson,
      frontier: const {'dev-a': 7},
    );

    test('an object payload round-trips through the v1 envelope unchanged — '
        'no version bump, because `value` was always arbitrary JSON', () {
      final payload = jsonEncode({'fromNoteId': 'n1', 'toNoteId': 'n2'});
      final decoded = decodeCommitBytes(
        encodeCommitBytes(existsOp(payload)),
        expectedAuthorId: 'dev-a',
        expectedAuthorSeq: 7,
      );
      expect(decoded.valueJson, payload);
      expect(decodeExistsPayload(decoded.valueJson), {
        'fromNoteId': 'n1',
        'toNoteId': 'n2',
      });
    });

    test('and through the v2 batch envelope', () {
      final payload = jsonEncode({'noteId': 'n1'});
      final ops = decodeCommitOperations(
        encodeCommitBatchBytes([existsOp(payload)]),
        expectedAuthorId: 'dev-a',
        deviceSeq: 1,
      );
      expect(ops.single.valueJson, payload);
      expect(decodeExistsPayload(ops.single.valueJson), {'noteId': 'n1'});
    });

    test('a v1 commit carrying the old constant still decodes, permanently — '
        'real v1 commits with this payload exist on real backends', () {
      final decoded = decodeCommitBytes(
        encodeCommitBytes(existsOp(bareExistsPayloadJson)),
        expectedAuthorId: 'dev-a',
        expectedAuthorSeq: 7,
      );
      expect(decoded.valueJson, 'true');
      expect(
        decodeExistsPayload(decoded.valueJson),
        isEmpty,
        reason: 'a legacy payload decodes to "no owner values", never a throw',
      );
    });

    test('an envelope version this build does not implement still fails loudly '
        'rather than being best-effort parsed', () {
      final bytes = Uint8List.fromList(utf8.encode('{"v":99,"ops":[]}'));
      expect(
        () => decodeCommitOperations(
          bytes,
          expectedAuthorId: 'dev-a',
          deviceSeq: 1,
        ),
        throwsA(isA<WireFormatUnsupportedVersionException>()),
      );
    });

    test('a malformed exists payload decodes to empty rather than throwing', () {
      expect(decodeExistsPayload(null), isEmpty);
      expect(decodeExistsPayload('not json'), isEmpty);
      expect(decodeExistsPayload('[1,2,3]'), isEmpty);
      expect(decodeExistsPayload('123'), isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  group('what is still not synced, stated so it stays true', () {
    test('an attachment row arrives without its file, and a mini app without '
        'its code — the two disclosed halves of this milestone', () async {
      final dbA = await a.db;
      await _buildLibrary(dbA);
      await syncBoth();
      final dbB = await b.db;

      // The row is complete; the file it names has never been part of any
      // operation (it lives on disk). What a user sees is the existing
      // per-attachment affordance at the point of use — a greyed card
      // reading "File not found", tap disabled — not a global sync badge;
      // see `SyncHealthIssueKind.tablesNotSynced`'s doc comment for why a
      // second health kind for this was written and then removed.
      final attachment = (await dbB.query('attachments')).single;
      expect(attachment['filePath'], 'attachments/diagram.png');
      expect(syncContentDeferredTables.keys, contains('attachments'));
      expect(
        syncContentDeferredTables.keys,
        contains('conversation_attachments'),
      );

      // The mini app arrives with no revision, so it has no runnable code.
      // `user_app_view_screen.dart` renders an explicit "code has not synced
      // yet" state for exactly this, rather than the blank body it used to.
      expect(await dbB.query('app_revisions'), isEmpty);
      expect(syncContentDeferredTables['app_revisions'], contains('appCode'));

      // And app_revisions is on the health surface with the true reason.
      final health = await recomputeSyncHealth(a.databaseService);
      final gated = health.issues.firstWhere(
        (i) => i.kind == SyncHealthIssueKind.tablesNotSynced,
      );
      expect(gated.subjects, contains('app_revisions'));
      expect(
        gated.subjects,
        isNot(contains('attachments')),
        reason:
            'attachments now sync — reporting them here would be false, and '
            'reporting every device with an attachment as degraded is what '
            'trains people to ignore the warning',
      );
    });
  });
}
