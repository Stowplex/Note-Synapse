// Regression tests for idempotent sync_publish_intent upgrades: migration
// 60 adds authorId/deviceSeq; migration 63 adds opAuthorSeqsJson. Both run
// after released main v48. The first sync migration (49) uses the current
// CREATE TABLE statements, so these columns can already be present during
// a normal upgrade. A crash before the version stamp can also replay a step.
// Existing columns and pending intents must survive either path.
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

  /// Creates `sync_publish_intent` in the shape v49 leaves it in, optionally
  /// already carrying the two columns v60 wants to add.
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
    'v60 against a table that already has BOTH columns is a clean no-op '
    '(the deterministic v48 upgrade path, where v49 already created them)',
    () async {
      // This is exactly the state `_migrateToVersion49` leaves behind today,
      // because it builds the table from the live statement list that M2.6
      // extended. The buggy version threw `duplicate column name: authorId`
      // here and bricked the device on every subsequent launch.
      final db = await openWithPublishIntent(
        withAuthorId: true,
        withDeviceSeq: true,
      );
      addTearDown(() => db.close());

      final before = await columnsOf(db, 'sync_publish_intent');
      await DatabaseService().migrateBackupDatabase(db, 59, 60);
      final after = await columnsOf(db, 'sync_publish_intent');

      expect(
        after,
        equals(before),
        reason: 'v60 must be a pure no-op when both columns already exist',
      );
      expect(after.contains('authorId'), isTrue);
      expect(after.contains('deviceSeq'), isTrue);
    },
  );

  test(
    'v60 completes the job when only authorId exists -- the partial-state '
    'case that makes buggy vs. fixed unambiguously distinguishable',
    () async {
      // The buggy version throws on its FIRST bare ALTER (authorId already
      // exists), so its second ALTER never runs and deviceSeq stays missing.
      // The fixed version skips authorId and still adds deviceSeq. That
      // difference is observable in the schema itself, and backup migration
      // now also propagates any migration failure to its caller.
      final db = await openWithPublishIntent(
        withAuthorId: true,
        withDeviceSeq: false,
      );
      addTearDown(() => db.close());

      expect((await columnsOf(db, 'sync_publish_intent')).contains('deviceSeq'),
          isFalse);

      await DatabaseService().migrateBackupDatabase(db, 59, 60);

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
    'v60 still does its real work on a genuine pre-M2.6 table '
    '(the guard must not turn the migration into a no-op for everyone)',
    () async {
      final db = await openWithPublishIntent(
        withAuthorId: false,
        withDeviceSeq: false,
      );
      addTearDown(() => db.close());

      await DatabaseService().migrateBackupDatabase(db, 59, 60);

      final after = await columnsOf(db, 'sync_publish_intent');
      expect(after.contains('authorId'), isTrue);
      expect(after.contains('deviceSeq'), isTrue);
    },
  );

  test(
    'v60 replayed twice in a row is idempotent (the crash / failed-later-step '
    'path, where the version stamp never advanced)',
    () async {
      final db = await openWithPublishIntent(
        withAuthorId: false,
        withDeviceSeq: false,
      );
      addTearDown(() => db.close());

      final service = DatabaseService();
      await service.migrateBackupDatabase(db, 59, 60);
      final afterFirst = await columnsOf(db, 'sync_publish_intent');

      // Replay, exactly as a device does when v61/v62 failed or the process
      // died before `_schema_version` was stamped.
      await service.migrateBackupDatabase(db, 59, 60);
      final afterReplay = await columnsOf(db, 'sync_publish_intent');

      expect(afterReplay, equals(afterFirst));
      expect(afterReplay.contains('authorId'), isTrue);
      expect(afterReplay.contains('deviceSeq'), isTrue);
    },
  );

  // ==========================================================================
  // M2.12 / schema v63 — `opAuthorSeqsJson`, added by `_migrateToVersion63`.
  // ==========================================================================
  //
  // The same two arrival paths this file already documents for v60 apply
  // verbatim: `_migrateToVersion49` builds `sync_publish_intent` from the
  // LIVE `_syncControlPlaneTableStatements` list, which now already declares
  // this column, so every upgrade from v48 reaches v63 with it present; and
  // a crash after v63 but before `_schema_version` is stamped replays it. The
  // guard is present from the start this time, and these tests are what keep
  // it there.

  /// `sync_publish_intent` in its post-v60 shape, optionally already carrying
  /// the column v63 wants to add.
  Future<Database> openPostV60({required bool withOpAuthorSeqsJson}) async {
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

  test('v63 adds opAuthorSeqsJson when it is missing', () async {
    final db = await openPostV60(withOpAuthorSeqsJson: false);
    addTearDown(() => db.close());

    await DatabaseService().migrateBackupDatabase(db, 62, 63);

    expect(
      (await columnsOf(db, 'sync_publish_intent')).contains('opAuthorSeqsJson'),
      isTrue,
    );
  });

  test(
    'v63 against a table that already has the column is a clean no-op (the '
    'deterministic v48 upgrade path, where v49 already created it)',
    () async {
      final db = await openPostV60(withOpAuthorSeqsJson: true);
      addTearDown(() => db.close());

      final before = await columnsOf(db, 'sync_publish_intent');
      await DatabaseService().migrateBackupDatabase(db, 62, 63);

      expect(await columnsOf(db, 'sync_publish_intent'), equals(before));
    },
  );

  test('v63 replayed twice in a row is idempotent', () async {
    final db = await openPostV60(withOpAuthorSeqsJson: false);
    addTearDown(() => db.close());

    final service = DatabaseService();
    await service.migrateBackupDatabase(db, 62, 63);
    final afterFirst = await columnsOf(db, 'sync_publish_intent');
    await service.migrateBackupDatabase(db, 62, 63);

    expect(await columnsOf(db, 'sync_publish_intent'), equals(afterFirst));
    expect(afterFirst.contains('opAuthorSeqsJson'), isTrue);
  });

  test(
    'an existing pending intent survives v63 with opAuthorSeqsJson NULL — the '
    'pre-M2.12 shape push_phase.dart falls back to a single v1 operation for',
    () async {
      final db = await openPostV60(withOpAuthorSeqsJson: false);
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

      await DatabaseService().migrateBackupDatabase(db, 62, 63);

      final row = (await db.query('sync_publish_intent')).single;
      expect(row['intentHash'], 'legacy');
      expect(row['deviceSeq'], 1);
      expect(row['opAuthorSeqsJson'], isNull);
    },
  );
}
