// Regression test for the v58 migration brick.
//
// A real device reported `Migration failed at version 58: DatabaseException(
// duplicate column name: authorId ... ALTER TABLE sync_publish_intent ADD
// COLUMN authorId TEXT)` and was then stuck in the Recovery Manager on every
// launch, permanently, with no way forward.
//
// Root cause: `_migrateToVersion58` (M2.6) was the ONLY `ADD COLUMN` migration
// in this file's entire history written without the `PRAGMA table_info`
// existence guard that every sibling uses (`_migrateToVersion49`/`51`/`52`/
// `53`/`54`/`55`). That made it non-idempotent, and there are two independent
// ways to reach it with the columns already present:
//
//   1. DETERMINISTIC: any upgrade from schema version <= 46.
//      `_migrateToVersion47` builds the fifteen sync_* tables from the *live,
//      shared* `_syncControlPlaneTableStatements` list, and M2.6 added
//      `authorId`/`deviceSeq` to that list's `CREATE TABLE
//      sync_publish_intent`. So v47 creates the table already carrying both
//      columns, and v58 -- a few steps later in the very same chain -- then
//      tried to add them again. Every such device bricked, 100% of the time.
//
//   2. Any crash or later-step failure mid-chain: the runner stamps
//      `_schema_version` only after ALL steps succeed, but SQLite commits each
//      DDL immediately and nothing rolls it back, so a failure in v59/v60 (or
//      a process kill) left the version stamp behind and replayed v58 against
//      its own already-applied result on the next launch.
//
// Why no existing test caught it: every migration test in this repo starts
// from a version >= 47 (M2.3+ used v49->v56, v55->v56, v56->v57, etc.) or
// tests a fresh install. Neither shape can reach the <= 46 path, and none
// replayed a step against its own output.
//
// TESTING NOTE, and the reason these tests assert on schema shape rather than
// on a thrown exception: `migrateBackupDatabase` *catches* a failing step,
// logs it, and `break`s out of its loop -- it does not rethrow. So "v58 threw"
// is invisible to a naive `expect(..., throwsA(...))`. What IS unambiguously
// observable is the partial-application signature: the buggy version issues
// two bare `ALTER`s in sequence, so if the first one throws, the second never
// runs and `deviceSeq` is silently left missing. Each test below is built so
// that the buggy and fixed versions produce genuinely different schema, with
// no dependence on exception propagation.
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Set<String>> columnsOf(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((r) => r['name'] as String).toSet();
  }

  /// Creates `sync_publish_intent` in the shape v47 leaves it in, optionally
  /// already carrying the two columns v58 wants to add.
  Future<Database> openWithPublishIntent({
    required bool withAuthorId,
    required bool withDeviceSeq,
  }) async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE sync_publish_intent (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        intentHash TEXT NOT NULL UNIQUE,
        parentCommitHash TEXT,
        payloadHash TEXT NOT NULL,
        ${withAuthorId ? 'authorId TEXT,' : ''}
        ${withDeviceSeq ? 'deviceSeq INTEGER,' : ''}
        status TEXT NOT NULL DEFAULT 'pending',
        createdAt INTEGER NOT NULL,
        confirmedAt INTEGER
      )
    ''');
    return db;
  }

  test(
    'v58 against a table that already has BOTH columns is a clean no-op '
    '(the deterministic <=v46 path, where v47 already created them)',
    () async {
      // This is exactly the state `_migrateToVersion47` leaves behind today,
      // because it builds the table from the live statement list that M2.6
      // extended. The buggy version threw `duplicate column name: authorId`
      // here and bricked the device on every subsequent launch.
      final db = await openWithPublishIntent(
        withAuthorId: true,
        withDeviceSeq: true,
      );
      addTearDown(() => db.close());

      final before = await columnsOf(db, 'sync_publish_intent');
      await DatabaseService().migrateBackupDatabase(db, 57, 58);
      final after = await columnsOf(db, 'sync_publish_intent');

      expect(
        after,
        equals(before),
        reason: 'v58 must be a pure no-op when both columns already exist',
      );
      expect(after.contains('authorId'), isTrue);
      expect(after.contains('deviceSeq'), isTrue);
    },
  );

  test(
    'v58 completes the job when only authorId exists -- the partial-state '
    'case that makes buggy vs. fixed unambiguously distinguishable',
    () async {
      // The buggy version throws on its FIRST bare ALTER (authorId already
      // exists), so its second ALTER never runs and deviceSeq stays missing.
      // The fixed version skips authorId and still adds deviceSeq. That
      // difference is observable in the schema itself, independent of whether
      // the exception propagates -- which it does not, since
      // migrateBackupDatabase swallows it.
      final db = await openWithPublishIntent(
        withAuthorId: true,
        withDeviceSeq: false,
      );
      addTearDown(() => db.close());

      expect((await columnsOf(db, 'sync_publish_intent')).contains('deviceSeq'),
          isFalse);

      await DatabaseService().migrateBackupDatabase(db, 57, 58);

      expect(
        (await columnsOf(db, 'sync_publish_intent')).contains('deviceSeq'),
        isTrue,
        reason:
            'the guarded migration must skip the already-present authorId and '
            'still add the missing deviceSeq; the unguarded version threw on '
            'authorId and silently never reached deviceSeq',
      );
    },
  );

  test(
    'v58 still does its real work on a genuine pre-M2.6 table '
    '(the guard must not turn the migration into a no-op for everyone)',
    () async {
      final db = await openWithPublishIntent(
        withAuthorId: false,
        withDeviceSeq: false,
      );
      addTearDown(() => db.close());

      await DatabaseService().migrateBackupDatabase(db, 57, 58);

      final after = await columnsOf(db, 'sync_publish_intent');
      expect(after.contains('authorId'), isTrue);
      expect(after.contains('deviceSeq'), isTrue);
    },
  );

  test(
    'v58 replayed twice in a row is idempotent (the crash / failed-later-step '
    'path, where the version stamp never advanced)',
    () async {
      final db = await openWithPublishIntent(
        withAuthorId: false,
        withDeviceSeq: false,
      );
      addTearDown(() => db.close());

      final service = DatabaseService();
      await service.migrateBackupDatabase(db, 57, 58);
      final afterFirst = await columnsOf(db, 'sync_publish_intent');

      // Replay, exactly as a device does when v59/v60 failed or the process
      // died before `_schema_version` was stamped.
      await service.migrateBackupDatabase(db, 57, 58);
      final afterReplay = await columnsOf(db, 'sync_publish_intent');

      expect(afterReplay, equals(afterFirst));
      expect(afterReplay.contains('authorId'), isTrue);
      expect(afterReplay.contains('deviceSeq'), isTrue);
    },
  );

  // ==========================================================================
  // M2.12 / schema v61 — `opAuthorSeqsJson`, added by `_migrateToVersion61`.
  // ==========================================================================
  //
  // The same two arrival paths this file already documents for v58 apply
  // verbatim: `_migrateToVersion47` builds `sync_publish_intent` from the
  // LIVE `_syncControlPlaneTableStatements` list, which now already declares
  // this column, so every upgrade from <= 46 reaches v61 with it present; and
  // a crash after v61 but before `_schema_version` is stamped replays it. The
  // guard is present from the start this time, and these tests are what keep
  // it there.

  /// `sync_publish_intent` in its post-v58 shape, optionally already carrying
  /// the column v61 wants to add.
  Future<Database> openPostV58({required bool withOpAuthorSeqsJson}) async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE sync_publish_intent (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        intentHash TEXT NOT NULL UNIQUE,
        parentCommitHash TEXT,
        payloadHash TEXT NOT NULL,
        authorId TEXT,
        deviceSeq INTEGER,
        ${withOpAuthorSeqsJson ? 'opAuthorSeqsJson TEXT,' : ''}
        status TEXT NOT NULL DEFAULT 'pending',
        createdAt INTEGER NOT NULL,
        confirmedAt INTEGER
      )
    ''');
    return db;
  }

  test('v61 adds opAuthorSeqsJson when it is missing', () async {
    final db = await openPostV58(withOpAuthorSeqsJson: false);
    addTearDown(() => db.close());

    await DatabaseService().migrateBackupDatabase(db, 60, 61);

    expect(
      (await columnsOf(db, 'sync_publish_intent')).contains('opAuthorSeqsJson'),
      isTrue,
    );
  });

  test(
    'v61 against a table that already has the column is a clean no-op (the '
    'deterministic <=v46 path, where v47 already created it)',
    () async {
      final db = await openPostV58(withOpAuthorSeqsJson: true);
      addTearDown(() => db.close());

      final before = await columnsOf(db, 'sync_publish_intent');
      await DatabaseService().migrateBackupDatabase(db, 60, 61);

      expect(await columnsOf(db, 'sync_publish_intent'), equals(before));
    },
  );

  test('v61 replayed twice in a row is idempotent', () async {
    final db = await openPostV58(withOpAuthorSeqsJson: false);
    addTearDown(() => db.close());

    final service = DatabaseService();
    await service.migrateBackupDatabase(db, 60, 61);
    final afterFirst = await columnsOf(db, 'sync_publish_intent');
    await service.migrateBackupDatabase(db, 60, 61);

    expect(await columnsOf(db, 'sync_publish_intent'), equals(afterFirst));
    expect(afterFirst.contains('opAuthorSeqsJson'), isTrue);
  });

  test(
    'an existing pending intent survives v61 with opAuthorSeqsJson NULL — the '
    'pre-M2.12 shape push_phase.dart falls back to a single v1 operation for',
    () async {
      final db = await openPostV58(withOpAuthorSeqsJson: false);
      addTearDown(() => db.close());
      await db.insert('sync_publish_intent', {
        'intentHash': 'legacy',
        'parentCommitHash': null,
        'payloadHash': 'p',
        'authorId': 'device-a',
        'deviceSeq': 1,
        'status': 'pending',
        'createdAt': 1000,
      });

      await DatabaseService().migrateBackupDatabase(db, 60, 61);

      final row = (await db.query('sync_publish_intent')).single;
      expect(row['intentHash'], 'legacy');
      expect(row['deviceSeq'], 1);
      expect(row['opAuthorSeqsJson'], isNull);
    },
  );
}
