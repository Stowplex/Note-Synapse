// M3.8 — CursorWindow-safe reads, from a field failure.
//
// Reported from a real device:
//
//     DatabaseException(Row too big to fit into CursorWindow
//     requirePos=0, totalRows=1)
//     sql 'Select * from user_apps WHERE CAST(id as text) = ? limit 1'
//
// Android caps a query's result window at ~2 MB and a row over it cannot be
// read AT ALL — an exception, not a truncation, taking the whole sync round
// with it. Two of the engine's readers were `SELECT *`, and M3.2 had just
// brought `app_revisions.appCode` into sync scope, where a mini app that
// inline-vendors a WebAssembly build is megabytes on its own.
//
// **These tests cannot reproduce the exception itself**: the FFI/desktop
// sqflite this suite runs on has no CursorWindow, which is exactly why the
// original `SELECT *` passed every test in this repo and failed on a phone.
// So they pin the two properties that would have prevented it — the engine
// never asks for a column outside its sync scope, and an oversized column
// round-trips through chunked reads — and say plainly that the platform
// behaviour behind them is not under test here.
//
// Writing them also corrected a wrong belief: `user_apps.htmlContent` is
// described in CLAUDE.md as a column that "should NOT be used" and was
// recorded in M2.14 as always empty, so this file first asserted it does not
// sync. It has been in `user_apps`' sync scope since M2.4. That assertion
// failing is what turned it into a content-blob rather than leaving a
// legacy app's HTML travelling inline in every commit that touched the row.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/large_row_reader.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/mock_sync_backend.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService svc;

  setUp(() => svc = DatabaseService.createNew());
  tearDown(() => svc.close());

  /// Larger than [syncLargeColumnThreshold], so it takes the chunked path.
  String vendoredWasm() => 'W' * (syncLargeColumnThreshold + 1024);

  test('an oversized column round-trips exactly through the chunked read',
      () async {
    final db = await svc.database;
    final code = vendoredWasm();
    await db.insert('user_apps', {
      'id': 'app1',
      'uuid': 'u1',
      'name': 'Counter',
      'description': 'd',
      'steps': '[]',
      'htmlContent': code,
      'type': 'normal',
      'createdAt': 1,
      'updatedAt': 1,
    });

    final row = await readSyncRow(
      db,
      table: 'user_apps',
      idColumn: 'id',
      entityId: 'app1',
      columns: const ['id', 'name', 'htmlContent'],
    );
    expect(row!['name'], 'Counter');
    expect(
      row['htmlContent'],
      code,
      reason:
          'chunking must be invisible to the caller — a reader that has to '
          'remember which columns were chunked is a reader that will forget',
    );
  });

  test('a small column is still returned inline, in one query', () async {
    final db = await svc.database;
    await db.insert('notes', {
      'id': 'n1',
      'title': 'small',
      'content': 'body',
      'type': 'note',
      'createdAt': 1,
      'updatedAt': 1,
    });
    final row = await readSyncRow(
      db,
      table: 'notes',
      idColumn: 'id',
      entityId: 'n1',
      columns: const ['id', 'title', 'content'],
    );
    expect(row!['title'], 'small');
    expect(row['content'], 'body');
  });

  test('a missing row is null rather than an empty map', () async {
    final db = await svc.database;
    expect(
      await readSyncRow(
        db,
        table: 'notes',
        idColumn: 'id',
        entityId: 'nope',
        columns: const ['id'],
      ),
      isNull,
    );
  });

  test('syncColumnLength never reads the value it measures', () async {
    final db = await svc.database;
    final code = vendoredWasm();
    await db.insert('user_apps', {
      'id': 'app1',
      'uuid': 'u1',
      'name': 'n',
      'description': 'd',
      'steps': '[]',
      'htmlContent': code,
      'type': 'normal',
      'createdAt': 1,
      'updatedAt': 1,
    });
    expect(
      await syncColumnLength(
        db,
        table: 'user_apps',
        column: 'htmlContent',
        idColumn: 'id',
        entityId: 'app1',
      ),
      code.length,
    );
  });

  test(
    'a mini app with a vendored-WebAssembly-sized appCode syncs end to end, '
    'and so does the legacy htmlContent — both as blobs',
    () async {
      final backend = MockSyncBackend();
      final b = DatabaseService.createNew();
      addTearDown(b.close);

      final code = vendoredWasm();
      final db = await svc.database;
      await db.insert('user_apps', {
        'id': 'app1',
        'uuid': 'uuid-app1',
        'name': 'Counter',
        'description': 'd',
        'steps': '[]',
        // The legacy column, deliberately populated. It IS in sync scope
        // (since M2.4) — the comment here previously claimed it was not,
        // and this test failing is what corrected that. M3.8 makes it a
        // content-blob so it travels once instead of inline.
        'htmlContent': vendoredWasm(),
        'type': 'normal',
        'selectedRevisionId': 'rev1',
        'createdAt': 1,
        'updatedAt': 1,
      });
      await db.insert('app_revisions', {
        'id': 'rev1',
        'appId': 'app1',
        'revisionNumber': 1,
        'revisionTimestamp': 1,
        'userPrompt': 'p',
        'aiResponse': 'r',
        'appCode': code,
      });

      for (var i = 0; i < 3; i++) {
        await SyncSession(svc).run(backend);
      }
      for (var i = 0; i < 3; i++) {
        await SyncSession(b).run(backend);
      }

      final revision = (await (await b.database).query(
        'app_revisions',
        columns: const ['id', 'appCode'],
      )).single;
      expect(revision['appCode'], code);

      expect(
        (await (await b.database).query(
          'user_apps',
          columns: const ['htmlContent'],
        )).single['htmlContent'],
        vendoredWasm(),
        reason:
            'it arrives, but as a BLOB rather than inline in a commit — the '
            'legacy column is in sync scope and cannot simply be dropped '
            'without losing a legacy app\'s content on the second device',
      );
    },
  );
}
