import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/pull_phase.dart';
import 'package:note_synapse/services/sync/wire_format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../sync_backend/mock_sync_backend.dart';

class _FailingEngine extends CausalEngine {
  bool fail = true;

  @override
  Future<ApplyResult> apply(DatabaseExecutor txn, IncomingOperation op) async {
    final result = await super.apply(txn, op);
    if (fail && (op.entityId == 'poisoned' || op.kind == 'set_remove')) {
      throw StateError('injected failure after causal-state writes');
    }
    return result;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService service;
  late Database db;
  late MockSyncBackend backend;
  late _FailingEngine engine;
  late PullPhase pull;

  setUp(() async {
    service = DatabaseService.createNew();
    db = await service.database;
    backend = MockSyncBackend();
    engine = _FailingEngine();
    pull = PullPhase(service, HybridLogicalClock(service), engine: engine);
    await db.insert('notes', {
      'id': 'n1',
      'title': 'local title',
      'content': '',
      'type': 'note',
      'createdAt': 1,
      'updatedAt': 1,
    });
    await db.insert('tags', {
      'id': 'tag1',
      'name': 'tag1',
      'color': '#fff',
      'createdAt': 1,
    });
  });

  tearDown(() => service.close());

  test(
    'fallback writes and parked payloads roll back if frontier cannot commit',
    () async {
      await backend.appendCommit(
        deviceLogId: 'peer',
        deviceSeq: 1,
        publishIntentId: 'batch',
        parentCommitHash: null,
        commitBytes: encodeCommitBatchBytes([
          for (final (seq, id) in [(1, 'n1'), (2, 'poisoned')])
            WireOperation(
              authorId: 'peer',
              authorSeq: seq,
              hlc: Hlc(10, seq),
              kind: 'field',
              entityTable: 'notes',
              entityId: id,
              fieldName: 'title',
              valueJson: jsonEncode('remote title'),
              frontier: {'peer': seq},
            ),
        ]),
      );
      await db.execute('''
      CREATE TRIGGER fail_pull_frontier BEFORE INSERT ON sync_state
      WHEN NEW.key = 'frontier:peer'
      BEGIN SELECT RAISE(ABORT, 'injected frontier persistence failure'); END
    ''');

      await expectLater(
        pull.pull(backend: backend, ownAuthorId: 'local'),
        throwsA(isA<DatabaseException>()),
      );
      expect((await db.query('notes')).single['title'], 'local title');
      expect(await db.query('sync_field_state'), isEmpty);
      expect(await db.query('sync_materialize_queue'), isEmpty);

      await db.execute('DROP TRIGGER fail_pull_frontier');
      final resumed = await pull.pull(backend: backend, ownAuthorId: 'local');
      expect(resumed.operationsApplied, 1);
      expect(resumed.failedOperations, hasLength(1));
      expect((await db.query('notes')).single['title'], 'remote title');
      expect(await db.query('sync_materialize_queue'), hasLength(1));
    },
  );

  test(
    'replaying a failed remove keeps waiting for its unobserved add',
    () async {
      const remove = WireOperation(
        authorId: 'remover',
        authorSeq: 1,
        hlc: Hlc(10, 0),
        kind: 'set_remove',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        targetDots: [Dot('adder', 1)],
        frontier: {'adder': 1, 'remover': 1},
      );
      await backend.appendCommit(
        deviceLogId: 'remover',
        deviceSeq: 1,
        publishIntentId: 'remove',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(remove),
      );
      final first = await pull.pull(backend: backend, ownAuthorId: 'local');
      expect(first.failedOperations, hasLength(1));

      engine.fail = false;
      await pull.pull(backend: backend, ownAuthorId: 'local');
      final waiting = await db.query('sync_materialize_queue');
      expect(waiting, hasLength(1));
      expect(
        waiting.single['blockingReason'],
        missingReferencedDotBlockingReason,
      );

      await backend.appendCommit(
        deviceLogId: 'adder',
        deviceSeq: 1,
        publishIntentId: 'add',
        parentCommitHash: null,
        commitBytes: encodeCommitBytes(
          const WireOperation(
            authorId: 'adder',
            authorSeq: 1,
            hlc: Hlc(5, 0),
            kind: 'set_add',
            entityTable: 'notes',
            entityId: 'n1',
            fieldName: 'tags',
            memberUuid: 'tag1',
            valueJson: 'true',
            frontier: {'adder': 1},
          ),
        ),
      );
      await pull.pull(backend: backend, ownAuthorId: 'local');
      expect(await db.query('sync_materialize_queue'), isEmpty);
      expect(await db.query('sync_set_state'), isEmpty);
      expect(await db.query('note_tags'), isEmpty);
    },
  );
}
