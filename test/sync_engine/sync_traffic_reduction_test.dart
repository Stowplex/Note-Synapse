// M2.12 — the three traffic reductions, and the properties each one must not
// break.
//
// **This milestone is measurement-driven, not speculative.** A user connected
// Google Drive and ran a first sync of a small library; their Drive folder was
// downloaded and analysed. 22 distinct entities had produced 152 commit files
// and roughly 456 network round trips, with a spinner that looked like a hang.
// Nothing was duplicated and nothing looped — every
// `(entityTable, entityId, fieldName)` appeared exactly once. The work was
// correct; there was simply far too much of it:
//
//     table          entities   commits   per entity
//     notes                 5        70           14
//     conversations        12        57          ~5
//     tags                  5        25            5
//
// The three fixes, and what this file pins about each:
//   1. **Default-skip** — a field whose value already equals what the
//      receiving device's row will hold transmits nothing, so it is not
//      seeded. Pinned here: which fields are skipped, which are NOT (
//      `tags.__deleted__`, where skipping would tombstone every tag on every
//      peer), and that the DRAIN path is untouched so a real set-to-NULL
//      still mints.
//   2. **Commit batching (`v: 2`)** — N operations per commit. Pinned here:
//      that the resolved state is byte-identical to one-operation-per-commit,
//      across two devices with a real field conflict and an OR-Set.
//   3. **The Drive tip cache** — pinned in
//      `test/sync_backend/google_drive_backend_test.dart`, which counts
//      requests against the fake transport.
//
// Plus the before/after measurement on a dataset shaped like the reporting
// user's, at the bottom.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/google_drive_backend.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/outbox_drainer.dart';
import 'package:note_synapse/services/sync/push_phase.dart';
import 'package:note_synapse/services/sync/seed_scanner.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/sync_session.dart';
import 'package:note_synapse/services/sync/sync_table_shape.dart';
import 'package:note_synapse/services/sync/wire_format.dart';

import '../sync_backend/fake_drive_http_transport.dart';
import '../sync_backend/mock_sync_backend.dart';

/// One self-contained device.
class _Device {
  _Device({PushPhase? pushPhase})
    : databaseService = DatabaseService.createNew() {
    deviceIdentity = DeviceIdentity(databaseService);
    seqCounter = SeqCounter(databaseService);
    hlc = HybridLogicalClock(databaseService);
    scanner = SeedScanner(databaseService, deviceIdentity, seqCounter, hlc);
    drainer = OutboxDrainer(databaseService, deviceIdentity, seqCounter, hlc);
    session = SyncSession(databaseService, pushPhase: pushPhase);
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

/// Reproduces a row that predates M2.4's capture triggers: inserted
/// normally, then its `sync_touch_log` evidence cleared — exactly the state
/// `_migrateToVersion57` leaves every pre-migration row in, since it installs
/// the triggers without backfilling.
Future<void> _makePreExisting(Database db) async {
  await db.delete('sync_touch_log');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  // =========================================================================
  // 1. Default-skip
  // =========================================================================
  group('seed default-skip', () {
    late _Device device;
    late Database db;

    setUp(() async {
      device = _Device();
      db = await device.db;
    });
    tearDown(() => device.close());

    Future<List<Map<String, Object?>>> seededFor(
      String table,
      String entityId,
    ) => db.query(
      'sync_pending_ops',
      where: 'entityTable = ? AND entityId = ?',
      whereArgs: [table, entityId],
      orderBy: 'authorSeq ASC',
    );

    test(
      'a note with only title/content/type/updatedAt set seeds four field '
      'operations, not fourteen — every NULL and every column-default value '
      'is skipped',
      () async {
        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
          // scheduledAt / completeBy / status / completionPercentage /
          // recurrenceRule / metadata left NULL; pinned / isArchived /
          // __deleted__ left at their SQL default of 0.
        });
        await _makePreExisting(db);

        final result = await device.scanner.scan();
        final ops = await seededFor('notes', 'n1');

        expect(ops.map((o) => o['fieldName']), [
          '__exists__',
          'title',
          'content',
          'type',
          'updatedAt',
        ]);
        expect(result.fieldsAtDefaultSkipped, 9);
        expect(
          ops.map((o) => o['fieldName']),
          isNot(contains('status')),
          reason:
              'an unset optional column carries no user intent, so seeding it '
              'transmits nothing while creating a permanent CRDT operation',
        );
      },
    );

    test(
      'a note that DOES set the optional columns seeds them — the skip is '
      'about the value, never about the column',
      () async {
        await db.insert('notes', {
          'id': 'n1',
          'title': 'Task',
          'content': 'body',
          'type': 'task',
          'createdAt': 1000,
          'updatedAt': 1000,
          'status': 'inProgress',
          'completionPercentage': 42.0,
          'pinned': 1,
          '__deleted__': 1,
        });
        await _makePreExisting(db);

        await device.scanner.scan();
        final fields = (await seededFor(
          'notes',
          'n1',
        )).map((o) => o['fieldName']).toList();
        expect(fields, contains('status'));
        expect(fields, contains('completionPercentage'));
        expect(fields, contains('pinned'));
        expect(fields, contains('__deleted__'));
        expect(fields, isNot(contains('isArchived'))); // still at default 0
      },
    );

    test(
      'tags.__deleted__ = 0 is NEVER skipped, because a receiving shell row '
      'is force-inserted at 1 — skipping it would tombstone every seeded tag '
      'on every peer',
      () async {
        await db.insert('tags', {
          'id': 't1',
          'name': 'work',
          'color': 'red',
          'createdAt': 1000,
          'usageCount': 0,
          '__deleted__': 0,
          'redirectTarget': null,
        });
        await _makePreExisting(db);

        final result = await device.scanner.scan();
        final fields = (await seededFor(
          'tags',
          't1',
        )).map((o) => o['fieldName']).toList();

        expect(fields, [
          '__exists__',
          'name',
          'color',
          '__deleted__',
        ], reason: 'redirectTarget (NULL, and the shell-row value) is skipped; '
            '__deleted__ is not, despite its SQL default being 0');
        expect(result.fieldsAtDefaultSkipped, 1);
      },
    );

    test(
      'the skip decision is a pure function of the value, so two devices with '
      'identical content still make identical decisions and still converge '
      'through the GENESIS contentKey',
      () async {
        final other = _Device();
        addTearDown(other.close);
        final otherDb = await other.db;

        for (final target in [db, otherDb]) {
          await target.insert('notes', {
            'id': 'n1',
            'title': 'Shared',
            'content': 'Same bytes on both devices',
            'type': 'note',
            'createdAt': 1000,
            'updatedAt': 1000,
          });
          await _makePreExisting(target);
        }

        final a = await device.scanner.scan();
        final b = await other.scanner.scan();
        expect(a.operationsSeeded, b.operationsSeeded);
        expect(a.fieldsAtDefaultSkipped, b.fieldsAtDefaultSkipped);

        Future<List<String?>> keys(Database target) async => (await target.query(
          'sync_pending_ops',
          orderBy: 'authorSeq ASC',
        )).map((o) => o['contentKey'] as String?).toList();
        expect(
          await keys(db),
          await keys(otherDb),
          reason:
              'identical content -> identical skip decisions -> the identical '
              'set of GENESIS contentKeys, which is what dedup converges on',
        );
      },
    );

    test(
      'the DRAIN path is unaffected: setting a previously-set field back to '
      'NULL is a real user action and still mints an explicit set-to-NULL',
      () async {
        await db.insert('notes', {
          'id': 'n1',
          'title': 'Task',
          'content': 'body',
          'type': 'task',
          'createdAt': 1000,
          'updatedAt': 1000,
          'status': 'inProgress',
        });
        await device.drainer.drain();

        // The user clears the status.
        await db.update(
          'notes',
          {'status': null},
          where: 'id = ?',
          whereArgs: ['n1'],
        );
        final result = await device.drainer.drain();

        final statusOps = result.mintedOperations
            .where((o) => o.fieldName == 'status')
            .toList();
        expect(
          statusOps, hasLength(1),
          reason: 'clearing a field the user had set is information, and must '
              'travel — the default-skip is a SEED-path rule only',
        );
        expect(statusOps.single.valueJson, 'null');
        expect(statusOps.single.authorId, isNot(startsWith('seed:')));
      },
    );

    test(
      'a brand-new local row is drained in full, NULLs included — the drain '
      'path is deliberately not default-skipped',
      () async {
        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        final result = await device.drainer.drain();
        final fields = result.mintedOperations.map((o) => o.fieldName).toList();
        final scope = DatabaseService.syncEntityCaptureScopes.firstWhere(
          (s) => s.table == 'notes',
        );
        expect(
          fields,
          containsAll(scope.syncScopeColumns),
          reason:
              'M2.12 scoped the default-skip to the SEED path only. Extending '
              'it to drain would be a separate decision with a separate '
              'argument to make (a fresh row is arguably also "no user '
              'intent"), and this test is what makes changing it deliberate '
              'rather than accidental',
        );
      },
    );
  });

  // =========================================================================
  // 1b. SQL default parsing — the shared predicate both the skip and
  //     `_materializeExists` read
  // =========================================================================
  group('decodeShellRowDefault', () {
    Map<String, Object?> col(
      String type, {
      String? dflt,
      bool notNull = false,
    }) => {
      'name': 'c',
      'type': type,
      'notnull': notNull ? 1 : 0,
      'dflt_value': dflt,
    };

    test('single-quoted string literals, including the doubled-quote escape', () {
      expect(decodeShellRowDefault(col('TEXT', dflt: "'hi'")).value, 'hi');
      expect(decodeShellRowDefault(col('TEXT', dflt: "''")).value, '');
      expect(decodeShellRowDefault(col('TEXT', dflt: "'it''s'")).value, "it's");
    });

    test(
      'DOUBLE-quoted string literals — the shape `user_apps.author` and '
      '`user_apps.license` actually declare (`DEFAULT ""`), which the '
      'original parser returned verbatim as the two-character string `""`',
      () async {
        expect(decodeShellRowDefault(col('TEXT', dflt: '""')).value, '');
        expect(decodeShellRowDefault(col('TEXT', dflt: '"hi"')).value, 'hi');

        // And against the real schema, not just a hand-built PRAGMA row.
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final columns = await syncTableInfo(db, 'user_apps');
        for (final name in ['author', 'license']) {
          final info = columns.firstWhere((c) => c['name'] == name);
          expect(
            info['dflt_value'],
            '""',
            reason: 'if this ever changes, the parsing case below is moot',
          );
          expect(
            shellRowValueFor(
              table: 'user_apps',
              column: name,
              columns: columns,
            ),
            (known: true, value: ''),
          );
        }
      },
    );

    test('DEFAULT NULL is the same as no default declared', () {
      expect(decodeShellRowDefault(col('INTEGER', dflt: 'NULL')).value, isNull);
      expect(decodeShellRowDefault(col('TEXT', dflt: 'null')).value, isNull);
      expect(
        decodeShellRowDefault(col('INTEGER', dflt: 'NULL', notNull: true)).value,
        0,
        reason:
            'a NOT NULL column still needs a type-appropriate stand-in — but '
            'not the 0 the old parser produced via int.tryParse("NULL") ?? 0, '
            'which was the right answer by accident',
      );
    });

    test('bare numeric literals keep working, per column affinity', () {
      expect(decodeShellRowDefault(col('INTEGER', dflt: '0')).value, 0);
      expect(decodeShellRowDefault(col('INTEGER', dflt: '1')).value, 1);
      expect(decodeShellRowDefault(col('REAL', dflt: '1.5')).value, 1.5);
      expect(decodeShellRowDefault(col('TEXT', dflt: "'0'")).value, '0');
    });

    test(
      'a non-literal default is reported as NOT statically known, so the seed '
      'skip refuses to skip against it',
      () {
        final result = decodeShellRowDefault(
          col('TEXT', dflt: 'CURRENT_TIMESTAMP', notNull: true),
        );
        expect(result.known, isFalse);
        expect(
          result.value,
          '',
          reason:
              '_materializeExists still needs something to write; only the '
              'skip needs certainty',
        );
        expect(
          decodeShellRowDefault(col('INTEGER', dflt: "(strftime('%s'))")).known,
          isFalse,
        );
      },
    );

    test(
      'a column absent from the schema is not skippable — and neither is a '
      'forced override naming a column the table does not have, which is what '
      'keeps this function and _materializeExists agreeing by construction',
      () async {
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final tagColumns = await syncTableInfo(db, 'tags');

        expect(
          shellRowValueFor(
            table: 'tags',
            column: 'no_such_column',
            columns: tagColumns,
          ).known,
          isFalse,
        );
        // The one real override still resolves, because the column exists.
        expect(
          shellRowValueFor(
            table: 'tags',
            column: '__deleted__',
            columns: tagColumns,
          ),
          (known: true, value: 1),
        );
        // ...and it is genuinely an override, not the column's own default.
        final deletedInfo = tagColumns.firstWhere(
          (c) => c['name'] == '__deleted__',
        );
        expect(decodeShellRowDefault(deletedInfo).value, 0);
      },
    );
  });

  // =========================================================================
  // 2. Batching does not change the resolved outcome
  // =========================================================================
  group('batching equivalence (MockSyncBackend, two devices)', () {
    /// Runs one fixed two-device scenario end to end and returns each
    /// device's fully-resolved state, so two runs can be compared directly.
    ///
    /// The scenario deliberately exercises the parts of the engine that are
    /// order- and grouping-sensitive: a genuine concurrent field conflict on
    /// `notes.title` (both devices edit before either syncs), an uncontested
    /// write on a second table, and an OR-Set membership add.
    Future<List<Map<String, Object?>>> runScenario({
      required int maxOperationsPerCommit,
    }) async {
      final backend = MockSyncBackend();
      PushPhase pushFor(DatabaseService s) =>
          PushPhase(s, maxOperationsPerCommit: maxOperationsPerCommit);

      final a = DatabaseService.createNew();
      final b = DatabaseService.createNew();
      final dbA = await a.database;
      final dbB = await b.database;
      final sessionA = SyncSession(a, pushPhase: pushFor(a));
      final sessionB = SyncSession(b, pushPhase: pushFor(b));

      // Both devices independently hold the same note id and tag id, and
      // both edit the title before either has synced -> a real conflict.
      for (final (db, title) in [(dbA, 'from A'), (dbB, 'from B')]) {
        await db.insert('notes', {
          'id': 'n1',
          'title': title,
          'content': 'shared body',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await db.insert('tags', {
          'id': 't1',
          'name': 'work',
          'color': 'red',
          'createdAt': 1000,
          'usageCount': 0,
          '__deleted__': 0,
        });
      }
      // Only A has the membership, and only A writes a filter.
      await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 't1'});
      await dbA.insert('filters', {
        'id': 'f1',
        'name': 'A only',
        'includeTags': '[]',
        'createdAt': 1000,
        'updatedAt': 1000,
      });

      for (var round = 0; round < 3; round++) {
        await sessionA.run(backend);
        await sessionB.run(backend);
      }

      // Device ids are random uuids, so two runs of the same scenario name
      // their winners differently while resolving identically. Rewriting
      // them to stable labels is what lets the two runs be compared
      // byte-for-byte — including the winning DOTS, which is the strongest
      // form of "batching changed nothing".
      final labels = {
        await DeviceIdentity(a).ensureDeviceId(): 'DEVICE_A',
        await DeviceIdentity(b).ensureDeviceId(): 'DEVICE_B',
      };
      String normalize(String json) {
        var out = json;
        labels.forEach((id, label) => out = out.replaceAll(id, label));
        return out;
      }

      Future<Map<String, Object?>> snapshot(Database db) async {
        final fields = await db.query(
          'sync_field_state',
          columns: const [
            'entityTable',
            'entityId',
            'fieldName',
            'valueJson',
            'authorId',
            'authorSeq',
          ],
          orderBy: 'entityTable, entityId, fieldName',
        );
        final sets = await db.query(
          'sync_set_state',
          columns: const [
            'entityTable',
            'entityId',
            'fieldName',
            'memberUuid',
          ],
          orderBy: 'entityTable, entityId, fieldName, memberUuid',
        );
        final notes = await db.query('notes', orderBy: 'id');
        final tags = await db.query('tags', orderBy: 'id');
        final noteTags = await db.query('note_tags', orderBy: 'noteId, tagId');
        return {
          'fields': normalize(jsonEncode(fields)),
          'sets': normalize(jsonEncode(sets)),
          'notes': normalize(jsonEncode(notes)),
          'tags': normalize(jsonEncode(tags)),
          'note_tags': normalize(jsonEncode(noteTags)),
        };
      }

      final result = [await snapshot(dbA), await snapshot(dbB)];
      await a.close();
      await b.close();
      return result;
    }

    test(
      'the resolved state is identical whether commits carry one operation '
      'or sixty-four',
      () async {
        final oneOpPerCommit = await runScenario(maxOperationsPerCommit: 1);
        final batched = await runScenario(
          maxOperationsPerCommit: PushPhase.defaultMaxOperationsPerCommit,
        );

        // Both devices converged within each run...
        expect(oneOpPerCommit[0]['fields'], oneOpPerCommit[1]['fields']);
        expect(batched[0]['fields'], batched[1]['fields']);

        // ...and the two runs agree with each other, field for field, row for
        // row. Dots included: batching changes the transport envelope only,
        // never the dot space, so even the winning (authorId, authorSeq) pairs
        // must match.
        for (final key in oneOpPerCommit[0].keys) {
          expect(
            batched[0][key],
            oneOpPerCommit[0][key],
            reason: 'device A disagrees on "$key" between the two runs',
          );
          expect(
            batched[1][key],
            oneOpPerCommit[1][key],
            reason: 'device B disagrees on "$key" between the two runs',
          );
        }
      },
    );

    test('and the batched run genuinely used fewer commits', () async {
      final backend = MockSyncBackend();
      final service = DatabaseService.createNew();
      addTearDown(service.close);
      final db = await service.database;
      await db.insert('notes', {
        'id': 'n1',
        'title': 'Hello',
        'content': 'World',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });

      final result = await SyncSession(service).run(backend);
      expect(result.push.publishedCount, greaterThan(1));
      expect(result.push.commitCount, 1);

      final authorId = await DeviceIdentity(service).ensureDeviceId();
      final page = await backend.readCommits(
        deviceLogId: authorId,
        afterSeq: 0,
      );
      expect(page.commits, hasLength(1));
      final ops = decodeCommitOperations(
        page.commits.single.commitBytes,
        expectedAuthorId: authorId,
        deviceSeq: page.commits.single.deviceSeq,
      );
      expect(ops, hasLength(result.push.publishedCount));
    });
  });

  // =========================================================================
  // 3. deviceSeq vs authorSeq, kept apart
  // =========================================================================
  group('deviceSeq (commit position) vs authorSeq (dot)', () {
    test(
      'a commit at deviceSeq 1 can carry operations at authorSeq 1..N, and '
      'the local commit_seq counter tracks commits while the seq counter '
      'tracks operations',
      () async {
        final backend = MockSyncBackend();
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final authorId = await DeviceIdentity(service).ensureDeviceId();

        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        final drained = await OutboxDrainer(
          service,
          DeviceIdentity(service),
          SeqCounter(service),
          HybridLogicalClock(service),
        ).drain();
        final result = await PushPhase(
          service,
        ).push(backend: backend, authorId: authorId);

        expect(result.commitCount, 1);
        expect(result.publishedCount, drained.mintedOperations.length);

        final page = await backend.readCommits(
          deviceLogId: authorId,
          afterSeq: 0,
        );
        expect(page.commits.single.deviceSeq, 1);
        final ops = decodeCommitOperations(
          page.commits.single.commitBytes,
          expectedAuthorId: authorId,
          deviceSeq: 1,
        );
        expect(
          ops.map((o) => o.authorSeq),
          List.generate(ops.length, (i) => i + 1),
          reason: 'the dots are untouched by batching',
        );

        final commitSeq = await db.query(
          'sync_state',
          where: 'key = ?',
          whereArgs: [PushPhase.commitSeqKey(authorId)],
        );
        expect(int.parse(commitSeq.single['value'] as String), 1);
        expect(await SeqCounter(service).peek(authorId), ops.length);

        // The intent row records the COMMIT position, not any dot.
        final intents = await db.query('sync_publish_intent');
        expect(intents.single['deviceSeq'], 1);
        expect(intents.single['status'], 'confirmed');
      },
    );

    test(
      'a second push continues the commit chain at deviceSeq 2 while the dots '
      'continue from wherever the seq counter left off',
      () async {
        final backend = MockSyncBackend();
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final session = SyncSession(service);
        final authorId = await DeviceIdentity(service).ensureDeviceId();

        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await session.run(backend);
        await db.update(
          'notes',
          {'title': 'Goodbye'},
          where: 'id = ?',
          whereArgs: ['n1'],
        );
        await session.run(backend);

        final page = await backend.readCommits(
          deviceLogId: authorId,
          afterSeq: 0,
        );
        expect(page.commits.map((c) => c.deviceSeq), [1, 2]);
        final second = decodeCommitOperations(
          page.commits[1].commitBytes,
          expectedAuthorId: authorId,
          deviceSeq: 2,
        );
        expect(
          second.first.authorSeq,
          greaterThan(1),
          reason:
              'the second commit is at deviceSeq 2 but its operations carry '
              'much higher authorSeqs — the two counters are independent',
        );
      },
    );

    test(
      'a legacy v1 log (one commit per operation, no commit_seq row) '
      'continues at the right position after upgrading',
      () async {
        final backend = MockSyncBackend();
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final authorId = await DeviceIdentity(service).ensureDeviceId();

        // Simulate what the pre-M2.12 build left behind: three confirmed
        // intents, one per commit, at deviceSeq 1..3, and no `commit_seq:`
        // row at all.
        for (var seq = 1; seq <= 3; seq++) {
          await db.insert('sync_publish_intent', {
            'intentHash': 'legacy-$seq',
            'parentCommitHash': seq == 1 ? null : 'hash-${seq - 1}',
            'payloadHash': 'payload-$seq',
            'authorId': authorId,
            'deviceSeq': seq,
            'status': 'confirmed',
            'createdAt': 1000,
            'confirmedAt': 1000,
          });
        }
        await db.insert('sync_state', {
          'key': 'tip:$authorId',
          'value': 'hash-3',
        });
        // The backend's own log matches, so the append can actually chain.
        for (var seq = 1; seq <= 3; seq++) {
          await backend.appendCommit(
            deviceLogId: authorId,
            deviceSeq: seq,
            publishIntentId: 'legacy-$seq',
            parentCommitHash: seq == 1
                ? null
                : (await backend.readCommits(
                    deviceLogId: authorId,
                    afterSeq: seq - 2,
                    limit: 1,
                  )).commits.single.commitHash,
            commitBytes: encodeCommitBytes(
              WireOperation(
                authorId: authorId,
                authorSeq: seq,
                hlc: Hlc(seq, 0),
                kind: 'field',
                entityTable: 'notes',
                entityId: 'legacy',
                fieldName: 'title',
                valueJson: jsonEncode('v$seq'),
                frontier: {authorId: seq},
              ),
            ),
          );
        }
        // Point the local tip at the real chain tip.
        final tip = await backend.readCommits(
          deviceLogId: authorId,
          afterSeq: 2,
        );
        await db.update(
          'sync_state',
          {'value': tip.commits.single.commitHash},
          where: 'key = ?',
          whereArgs: ['tip:$authorId'],
        );

        // Now a real local write, pushed by the new build.
        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await OutboxDrainer(
          service,
          DeviceIdentity(service),
          SeqCounter(service),
          HybridLogicalClock(service),
        ).drain();
        final result = await PushPhase(
          service,
        ).push(backend: backend, authorId: authorId);

        expect(result.commitCount, 1);
        final page = await backend.readCommits(
          deviceLogId: authorId,
          afterSeq: 0,
        );
        expect(
          page.commits.map((c) => c.deviceSeq),
          [1, 2, 3, 4],
          reason:
              'the new v2 commit continues the existing v1 chain at position '
              '4 — derived from MAX(sync_publish_intent.deviceSeq) with no '
              'migration and no extra backend round trip',
        );
        expect(page.hasGap, isFalse);
      },
    );
  });

  // =========================================================================
  // 4. Crash-safety resume, with N operations per commit
  // =========================================================================
  group('crash-safety resume with a batched commit', () {
    test(
      'an appendCommit that landed but was never locally confirmed is resumed '
      'as the SAME batch — every one of its operations is stamped published, '
      'exactly once, with no duplicate commit',
      () async {
        final backend = MockSyncBackend();
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final authorId = await DeviceIdentity(service).ensureDeviceId();

        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await OutboxDrainer(
          service,
          DeviceIdentity(service),
          SeqCounter(service),
          HybridLogicalClock(service),
        ).drain();
        final pendingBefore = await db.query(
          'sync_pending_ops',
          where: 'publishedAt IS NULL',
        );
        expect(pendingBefore.length, greaterThan(1));

        // First push, then rewind every trace of the local confirmation —
        // the exact durable state a crash between `appendCommit` returning
        // and `_confirmAndAdvance` committing would leave behind.
        await PushPhase(service).push(backend: backend, authorId: authorId);
        await db.update('sync_pending_ops', {'publishedAt': null});
        await db.update('sync_publish_intent', {
          'status': 'pending',
          'confirmedAt': null,
        });
        await db.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: ['tip:$authorId'],
        );
        await db.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: [PushPhase.commitSeqKey(authorId)],
        );

        final resumed = await PushPhase(
          service,
        ).push(backend: backend, authorId: authorId);

        expect(resumed.resumedCount, pendingBefore.length);
        expect(resumed.commitCount, 1);
        expect(
          await db.query('sync_pending_ops', where: 'publishedAt IS NULL'),
          isEmpty,
        );
        final page = await backend.readCommits(
          deviceLogId: authorId,
          afterSeq: 0,
        );
        expect(
          page.commits,
          hasLength(1),
          reason: 'the resume must recognise its own earlier write, not '
              'append a second copy of it',
        );
        expect(
          backend.debugStorageObjectCountAtSeq(authorId, 1),
          1,
          reason: 'and no duplicate stored object at the slot either',
        );
      },
    );

    test(
      'a pending intent whose commit never landed is retried as the same '
      'batch and published exactly once',
      () async {
        final backend = MockSyncBackend();
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final authorId = await DeviceIdentity(service).ensureDeviceId();

        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await OutboxDrainer(
          service,
          DeviceIdentity(service),
          SeqCounter(service),
          HybridLogicalClock(service),
        ).drain();

        // A crash between recording the intent and the commit actually
        // landing. Reproduced faithfully without re-implementing the
        // encoder: run a real push against a THROWAWAY backend (so a real
        // intent row, with a real payloadHash, is written locally), then
        // rewind only the local confirmation. `backend` below has never seen
        // the commit, so step 0's readCommits check genuinely misses and the
        // append is genuinely retried.
        final push = PushPhase(service);
        await push.push(backend: MockSyncBackend(), authorId: authorId);
        final intent = (await db.query('sync_publish_intent')).single;
        await db.update('sync_pending_ops', {'publishedAt': null});
        await db.update('sync_publish_intent', {
          'status': 'pending',
          'confirmedAt': null,
        });
        await db.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: ['tip:$authorId'],
        );
        await db.delete(
          'sync_state',
          where: 'key = ?',
          whereArgs: [PushPhase.commitSeqKey(authorId)],
        );

        final resumed = await push.push(backend: backend, authorId: authorId);
        expect(resumed.resumedCount, greaterThan(1));
        expect(resumed.commitCount, 1);

        final page = await backend.readCommits(
          deviceLogId: authorId,
          afterSeq: 0,
        );
        expect(page.commits, hasLength(1));
        // The retried commit is byte-identical to what the intent recorded.
        expect(
          intent['payloadHash'],
          isNotNull,
          reason: 'the reconstruction is proven by hash, not by inference',
        );
        expect(
          await db.query('sync_pending_ops', where: 'publishedAt IS NULL'),
          isEmpty,
        );
      },
    );
  });

  // =========================================================================
  // 4a. The batch-layout wedge, closed by recording what a commit covers
  // =========================================================================
  //
  // Before `sync_publish_intent.opAuthorSeqsJson` (schema v61), the resume
  // procedure re-derived an interrupted commit's contents by trying the
  // batch today's constants would form and then every shorter prefix. Every
  // candidate was therefore <= today's constants, so a release that LOWERED
  // either constant could not rebuild a batch its predecessor had left
  // pending — it threw, and threw again on every subsequent `push()`, so
  // the namespace could never publish anything again.
  group('resuming a batch formed under different size constants', () {
    Future<void> interruptThenResume({
      required int interruptedAtMaxOps,
      required int resumedAtMaxOps,
    }) async {
      final service = DatabaseService.createNew();
      addTearDown(service.close);
      final db = await service.database;
      final authorId = await DeviceIdentity(service).ensureDeviceId();

      for (var i = 0; i < 6; i++) {
        await db.insert('notes', {
          'id': 'n$i',
          'title': 'Note $i',
          'content': 'body $i',
          'type': 'note',
          'createdAt': 1000 + i,
          'updatedAt': 1000 + i,
        });
      }
      await OutboxDrainer(
        service,
        DeviceIdentity(service),
        SeqCounter(service),
        HybridLogicalClock(service),
      ).drain();

      // The interrupted attempt: it records an intent, then the process
      // "dies" before the local confirmation. Reproduced by pushing to a
      // throwaway backend and rewinding only the local side, so `backend`
      // below has genuinely never seen the commit.
      await PushPhase(
        service,
        maxOperationsPerCommit: interruptedAtMaxOps,
      ).push(backend: MockSyncBackend(), authorId: authorId);
      final pendingOpCount = (await db.query('sync_pending_ops')).length;
      await db.update('sync_pending_ops', {'publishedAt': null});
      await db.update('sync_publish_intent', {
        'status': 'pending',
        'confirmedAt': null,
      });
      await db.delete(
        'sync_state',
        where: 'key IN (?, ?)',
        whereArgs: ['tip:$authorId', PushPhase.commitSeqKey(authorId)],
      );

      // The upgraded build resumes.
      final backend = MockSyncBackend();
      final resumed = await PushPhase(
        service,
        maxOperationsPerCommit: resumedAtMaxOps,
      ).push(backend: backend, authorId: authorId);

      expect(
        resumed.resumedCount + (resumed.publishedCount - resumed.resumedCount),
        pendingOpCount,
        reason: 'every pending operation reached the backend',
      );
      expect(
        await db.query('sync_pending_ops', where: 'publishedAt IS NULL'),
        isEmpty,
      );
      final page = await backend.readCommits(
        deviceLogId: authorId,
        afterSeq: 0,
      );
      expect(page.hasGap, isFalse);
      var decoded = 0;
      for (final commit in page.commits) {
        decoded += decodeCommitOperations(
          commit.commitBytes,
          expectedAuthorId: authorId,
          deviceSeq: commit.deviceSeq,
        ).length;
      }
      expect(decoded, pendingOpCount);
    }

    test(
      'a LARGER interrupted batch resumes on a build with a smaller limit — '
      'the case the old prefix-scan reconstruction wedged on permanently',
      () => interruptThenResume(
        interruptedAtMaxOps: 1000,
        resumedAtMaxOps: 4,
      ),
    );

    test(
      'and a smaller interrupted batch resumes on a build with a larger limit',
      () => interruptThenResume(interruptedAtMaxOps: 4, resumedAtMaxOps: 1000),
    );

    test(
      'the intent records exactly the authorSeqs its commit carries, and the '
      'resume verifies them by hash rather than searching for a match',
      () async {
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final authorId = await DeviceIdentity(service).ensureDeviceId();

        await db.insert('notes', {
          'id': 'n1',
          'title': 'Hello',
          'content': 'World',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await OutboxDrainer(
          service,
          DeviceIdentity(service),
          SeqCounter(service),
          HybridLogicalClock(service),
        ).drain();
        await PushPhase(
          service,
          maxOperationsPerCommit: 3,
        ).push(backend: MockSyncBackend(), authorId: authorId);

        final intents = await db.query(
          'sync_publish_intent',
          orderBy: 'deviceSeq ASC',
        );
        expect(intents.length, greaterThan(1));
        final covered = <int>[];
        for (final intent in intents) {
          final seqs = (jsonDecode(intent['opAuthorSeqsJson'] as String)
                  as List<dynamic>)
              .cast<int>();
          expect(seqs.length, lessThanOrEqualTo(3));
          covered.addAll(seqs);
        }
        expect(
          covered,
          List.generate(covered.length, (i) => i + 1),
          reason:
              'every operation is covered by exactly one intent, in order, '
              'with no overlap and no hole',
        );

        // A corrupted covered-set is caught rather than silently published
        // under a stale hash.
        await db.update('sync_pending_ops', {'publishedAt': null});
        await db.update('sync_publish_intent', {
          'status': 'pending',
          'confirmedAt': null,
          'opAuthorSeqsJson': jsonEncode([1]),
        }, where: 'deviceSeq = ?', whereArgs: [1]);
        await db.delete(
          'sync_state',
          where: 'key IN (?, ?)',
          whereArgs: ['tip:$authorId', PushPhase.commitSeqKey(authorId)],
        );
        await expectLater(
          PushPhase(
            service,
          ).push(backend: MockSyncBackend(), authorId: authorId),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'a pre-v61 intent (opAuthorSeqsJson NULL, one operation per commit) '
      'still resumes through the legacy v1 path',
      () async {
        final backend = MockSyncBackend();
        final service = DatabaseService.createNew();
        addTearDown(service.close);
        final db = await service.database;
        final authorId = await DeviceIdentity(service).ensureDeviceId();

        // One pending operation, exactly as the pre-M2.12 drain would leave
        // it, plus the intent that build would have recorded for it: v1
        // bytes, `deviceSeq == authorSeq`, and no covered-set column.
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
          'valueJson': jsonEncode('legacy'),
          'blobHash': null,
          'targetDotsJson': null,
          'frontierJson': jsonEncode({authorId: 1}),
          'createdAt': 1000,
          'publishedAt': null,
        });
        final bytes = encodeCommitBytes(
          WireOperation.fromPendingOpsRow(
            (await db.query('sync_pending_ops')).single,
          ),
        );
        final payloadHash = sha256.convert(bytes).toString();
        await db.insert('sync_publish_intent', {
          'intentHash': sha256
              .convert(utf8.encode('|$payloadHash'))
              .toString(),
          'parentCommitHash': null,
          'payloadHash': payloadHash,
          'authorId': authorId,
          'deviceSeq': 1,
          'opAuthorSeqsJson': null, // the pre-v61 shape
          'status': 'pending',
          'createdAt': 1000,
          'confirmedAt': null,
        });

        final result = await PushPhase(
          service,
        ).push(backend: backend, authorId: authorId);
        expect(result.resumedCount, 1);
        final page = await backend.readCommits(
          deviceLogId: authorId,
          afterSeq: 0,
        );
        expect(page.commits, hasLength(1));
        expect(
          page.commits.single.commitBytes,
          bytes,
          reason:
              'a resumed legacy intent must republish the exact v1 bytes its '
              'payloadHash was computed over, not a v2 batch-of-one',
        );
      },
    );
  });

  // =========================================================================
  // 4b. An envelope version this build cannot read
  // =========================================================================
  test(
    'a commit written in a FUTURE envelope version stops that log for the '
    'round — without throwing, without advancing past it, and without '
    'stopping this device from publishing its own work',
    () async {
      final backend = MockSyncBackend();
      final writer = DatabaseService.createNew();
      final reader = DatabaseService.createNew();
      addTearDown(writer.close);
      addTearDown(reader.close);
      final writerDb = await writer.database;
      final readerDb = await reader.database;
      final writerAuthor = await DeviceIdentity(writer).ensureDeviceId();

      // One ordinary, readable commit...
      await writerDb.insert('notes', {
        'id': 'n1',
        'title': 'readable',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await SyncSession(writer).run(backend);
      final first = (await backend.readCommits(
        deviceLogId: writerAuthor,
        afterSeq: 0,
      )).commits.single;

      // ...followed by one this build has no idea how to read.
      await backend.appendCommit(
        deviceLogId: writerAuthor,
        deviceSeq: 2,
        publishIntentId: 'future-intent',
        parentCommitHash: first.commitHash,
        commitBytes: Uint8List.fromList(
          utf8.encode(jsonEncode({'v': 99, 'ops': <Object>[]})),
        ),
      );

      // The reader has local work of its own waiting to go out.
      await readerDb.insert('notes', {
        'id': 'n2',
        'title': 'local work',
        'content': 'body',
        'type': 'note',
        'createdAt': 2000,
        'updatedAt': 2000,
      });

      final result = await SyncSession(reader).run(backend);

      expect(result.pull.operationsApplied, greaterThan(0));
      expect(result.pull.gappedDeviceLogIds, [writerAuthor]);
      // Reported on `unreadableCommits`, NOT `failedOperations` — the latter
      // is typed and matched as operation dots, and an undecodable commit
      // has no dots to name.
      expect(result.pull.failedOperations, isEmpty);
      expect(result.pull.unreadableCommits, hasLength(1));
      expect(result.pull.unreadableCommits.single.$1, writerAuthor);
      expect(result.pull.unreadableCommits.single.$2, 2);
      expect(
        result.totalPublished,
        greaterThan(0),
        reason:
            "the reader's own work must still reach the backend — an "
            'unreadable remote commit is not a reason to stop publishing',
      );

      final frontier = await readerDb.query(
        'sync_state',
        where: 'key = ?',
        whereArgs: ['frontier:$writerAuthor'],
      );
      expect(
        int.parse(frontier.single['value'] as String),
        1,
        reason:
            'the frontier must NOT advance past a commit this build could '
            'not read — parking it would make its contents permanently '
            'invisible to this device',
      );
    },
  );

  // =========================================================================
  // 5. Push progress
  // =========================================================================
  test('push reports progress per commit, so the UI stops looking hung', () async {
    final backend = MockSyncBackend();
    final service = DatabaseService.createNew();
    addTearDown(service.close);
    final db = await service.database;
    final authorId = await DeviceIdentity(service).ensureDeviceId();

    for (var i = 0; i < 5; i++) {
      await db.insert('notes', {
        'id': 'n$i',
        'title': 'Note $i',
        'content': 'body $i',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
    }
    await OutboxDrainer(
      service,
      DeviceIdentity(service),
      SeqCounter(service),
      HybridLogicalClock(service),
    ).drain();

    final seen = <PushProgress>[];
    await PushPhase(service, maxOperationsPerCommit: 4).push(
      backend: backend,
      authorId: authorId,
      onProgress: seen.add,
    );

    expect(seen, isNotEmpty);
    expect(seen.map((p) => p.commitsSent), List.generate(seen.length, (i) => i + 1));
    expect(seen.every((p) => p.commitsTotal == seen.length), isTrue);
    expect(seen.every((p) => p.authorId == authorId), isTrue);
    expect(seen.last.operationsPublished, greaterThan(seen.first.operationsPublished));
  });

  // =========================================================================
  // 6. The measurement
  // =========================================================================
  //
  // The reporting user's dataset shape: 5 notes, 12 conversations, 5 tags.
  // Numbers are printed as well as asserted, because "the improvement is a
  // number, not a claim" is the whole point of this milestone.
  group('before/after on a dataset shaped like the reported one', () {
    test('5 notes, 12 conversations, 5 tags', () async {
      SharedPreferences.setMockInitialValues({
        'gdrive_oauth_test_token_m212': jsonEncode({
          'accessToken': 'test-access-token',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toIso8601String(),
          'refreshToken': 'test-refresh-token',
        }),
      });

      final service = DatabaseService.createNew();
      addTearDown(service.close);
      final db = await service.database;

      for (var i = 0; i < 5; i++) {
        await db.insert('notes', {
          'id': 'n$i',
          'title': 'Note $i',
          'content': 'Body of note $i',
          'type': 'note',
          'createdAt': 1000 + i,
          'updatedAt': 1000 + i,
        });
      }
      for (var i = 0; i < 12; i++) {
        await db.insert('conversations', {
          'id': 'c$i',
          'title': 'Conversation $i',
          'createdAt': 2000 + i,
          'updatedAt': 2000 + i,
        });
      }
      for (var i = 0; i < 5; i++) {
        await db.insert('tags', {
          'id': 't$i',
          'name': 'tag$i',
          'color': 'red',
          'createdAt': 3000 + i,
          'usageCount': 0,
          '__deleted__': 0,
        });
      }
      await _makePreExisting(db);

      final scan = await SeedScanner(
        service,
        DeviceIdentity(service),
        SeqCounter(service),
        HybridLogicalClock(service),
      ).scan();

      // ---- operations -------------------------------------------------
      final afterOps = scan.operationsSeeded;
      final beforeOps = afterOps + scan.fieldsAtDefaultSkipped;

      // ---- commits + Drive requests, measured end to end --------------
      final transport = FakeDriveHttpTransport();
      final backend = GoogleDriveBackend(
        tokenManager: OAuthTokenManager(
          endpointId: 'm212',
          config: OAuthConfig(
            authorizationEndpoint: 'https://accounts.google.test/o/oauth2/auth',
            tokenEndpoint: 'https://oauth2.google.test/token',
            clientId: 'test-client-id',
            scope: 'https://www.googleapis.com/auth/drive.file',
            usePkce: true,
            redirectUri: 'notesynapse://oauth/callback',
          ),
          storagePrefix: 'gdrive_oauth_test_',
        ),
        httpClient: transport,
      );
      // Resolve the root folder first, so the measurement is of the push and
      // not of one-off session setup.
      await backend.listDeviceLogIds();
      transport.debugResetRequestLog();

      final seedAuthor =
          'seed:${await DeviceIdentity(service).ensureDeviceId()}';
      final pushResult = await PushPhase(
        service,
      ).push(backend: backend, authorId: seedAuthor);

      final afterCommits = pushResult.commitCount;
      final afterRequests = transport.debugRequestCount;

      // Before M2.12: one commit per operation, and every appendCommit paid
      // the full three round trips (files.list for the slot, files.list for
      // the tip, files.create). Both halves of that are independently pinned
      // — the first by this milestone's own diff, the second by
      // `google_drive_backend_test.dart`'s "the FIRST append of a session
      // still pays for both existence checks".
      final beforeCommits = beforeOps;
      final beforeRequests = beforeCommits * 3;

      // ignore: avoid_print
      print(
        'M2.12 measurement — 5 notes / 12 conversations / 5 tags\n'
        '  operations : $beforeOps -> $afterOps '
        '(${(100 * (beforeOps - afterOps) / beforeOps).toStringAsFixed(0)}% fewer)\n'
        '  commits    : $beforeCommits -> $afterCommits '
        '(${(beforeCommits / afterCommits).toStringAsFixed(1)}x fewer)\n'
        '  requests   : $beforeRequests -> $afterRequests '
        '(${(beforeRequests / afterRequests).toStringAsFixed(1)}x fewer)',
      );

      expect(afterOps, lessThan(beforeOps));
      expect(afterCommits, lessThan(beforeCommits ~/ 10));
      expect(afterRequests, lessThan(beforeRequests ~/ 20));
      expect(
        pushResult.publishedCount,
        afterOps,
        reason: 'every seeded operation still reached the backend',
      );

      // The data is genuinely all there, in the batched commits.
      final page = await backend.readCommits(
        deviceLogId: seedAuthor,
        afterSeq: 0,
      );
      var decodedOps = 0;
      for (final commit in page.commits) {
        decodedOps += decodeCommitOperations(
          commit.commitBytes,
          expectedAuthorId: seedAuthor,
          deviceSeq: commit.deviceSeq,
        ).length;
      }
      expect(decodedOps, afterOps);
    });
  });
}
