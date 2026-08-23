// M2.8, § Architecture 11.8 item 6's backend
// (`lib/services/sync/debug_loopback_backend.dart`) — a real, if
// deliberately minimal, `SyncBackend` implementation shipped in `lib/`
// production code (not test-only), so it gets the same real-code-path
// verification standard as everything else that ships, not just a manual
// smoke test via the debug menu.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/debug_loopback_backend.dart';
import 'package:note_synapse/services/sync/sync_backend.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  test('a real SyncSession.run() against DebugLoopbackSyncBackend drains and pushes a local write, '
      'and a second run is a clean no-op', () async {
    final databaseService = DatabaseService.createNew();
    final backend = DebugLoopbackSyncBackend();
    final session = SyncSession(databaseService);

    try {
      final db = await databaseService.database;
      await db.insert('notes', {
        'id': 'n1',
        'title': 'debug-menu note',
        'content': 'body',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });

      final first = await session.run(backend);
      expect(first.drain.touchesProcessed, greaterThan(0));
      expect(first.push.publishedCount, greaterThan(0));
      // Nothing else exists in the backend for this device to pull back.
      expect(first.pull.operationsApplied, 0);

      final titleRow = await db.query(
        'sync_field_state',
        where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
        whereArgs: ['notes', 'n1', 'title'],
      );
      expect(jsonDecode(titleRow.single['valueJson'] as String), 'debug-menu note');

      // A real commit actually landed in the backend, hash-chained correctly.
      final ownAuthorId = titleRow.single['authorId'] as String;
      final commits = await backend.readCommits(deviceLogId: ownAuthorId, afterSeq: 0);
      expect(commits.commits, isNotEmpty);
      expect(commits.hasGap, isFalse);

      // A second run: nothing new locally, nothing new remotely (this
      // device skips its own log on pull) — a clean, idempotent no-op,
      // exactly what the debug menu's "tap twice" UX should show.
      final second = await session.run(backend);
      expect(second.drain.touchesProcessed, 0);
      expect(second.push.publishedCount, 0);
      expect(second.pull.operationsApplied, 0);
    } finally {
      await databaseService.close();
    }
  });

  test('appendCommit correctly rejects a parent-hash mismatch (real chain-integrity behavior, '
      'not a stub)', () async {
    final backend = DebugLoopbackSyncBackend();
    final first = await backend.appendCommit(
      deviceLogId: 'dev1',
      deviceSeq: 1,
      publishIntentId: 'intent-1',
      parentCommitHash: null,
      commitBytes: Uint8List.fromList(utf8.encode('a')),
    );
    expect(first, isA<AppendCommitSucceeded>());

    final mismatched = await backend.appendCommit(
      deviceLogId: 'dev1',
      deviceSeq: 2,
      publishIntentId: 'intent-2',
      parentCommitHash: 'not-the-real-tip',
      commitBytes: Uint8List.fromList(utf8.encode('b')),
    );
    expect(mismatched, isA<AppendCommitParentMismatch>());
  });
}
