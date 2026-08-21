// Durable per-`authorId`-namespace sequence counters — M2.3, § Architecture
// 11.2 ("Durable per-author-seq and HLC generation") of the CRDT-cloud-sync
// design (`plan-and-propse-the-glistening-dolphin.md`).
//
// **Kept in its own file, deliberately not merged with `hlc.dart`.** § 11.2
// is explicit that `authorSeq` (dot-identity, per-namespace, causal
// ordering) and `hlc` (one per physical device, tie-breaking only) are "two
// genuinely different things... and conflating them is a real risk... They
// must not share a name or a code path." This file owns only the former.

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';

/// Mints the next sequence number for one `authorId` namespace — one row
/// per namespace actually in use, `sync_state['next_seq:<authorId>']` (§
/// 11.2's proposed key), absent meaning "not yet used, treated as 0". A
/// single physical device owns up to three independent namespaces (the
/// ordinary `device_id`, `"seed:" + device_id`, `"external:" + device_id`),
/// each with its own real, monotonic, contiguous counter, because each is
/// its own hash-linked chain (§ Architecture 1) — [mintNextSeq] is
/// namespace-agnostic; the caller supplies whichever `authorId` string is
/// appropriate.
///
/// **This milestone does not write to `sync_pending_ops`** — that outbox
/// insert is M2.4's job. What this class owes M2.4 is a transaction
/// boundary M2.4 can compose with: [mintNextSeq] accepts an optional
/// [DatabaseExecutor] via `executor`, the same idiom
/// `deleteRelationshipsForNote` (`database_service.dart`) already
/// establishes for "let a caller fold this into its own transaction." When
/// M2.4 mints an operation, it is expected to open its own `db.transaction`,
/// call `mintNextSeq(authorId, executor: txn)` to get the seq number, then
/// insert the `sync_pending_ops` row (which embeds that seq via its own
/// `authorId`/`authorSeq` columns) *inside that same transaction* — exactly
/// the "read the current value, increment it, and writes the operation into
/// sync_pending_ops... in the same local transaction, so a crash between the
/// two is impossible to observe as 'seq consumed, no operation to show for
/// it'" guarantee § 11.2 requires. `sync_pending_ops`'s own
/// `UNIQUE(authorId, authorSeq)` constraint is the documented last-resort
/// backstop if that invariant is ever violated some other way.
class SeqCounter {
  SeqCounter(this._databaseService);

  final DatabaseService _databaseService;

  static String _keyFor(String authorId) => 'next_seq:$authorId';

  /// Reads the current counter for [authorId] (0 if the namespace has never
  /// minted anything), increments it, persists the new value, and returns
  /// it — as one atomic read-increment-write. When [executor] is supplied,
  /// this call participates in the caller's own transaction instead of
  /// opening its own (see the class doc comment for why M2.4 needs this).
  Future<int> mintNextSeq(String authorId, {DatabaseExecutor? executor}) async {
    Future<int> body(DatabaseExecutor txn) async {
      final key = _keyFor(authorId);
      final rows = await txn.query(
        'sync_state',
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      final current = rows.isEmpty
          ? 0
          : int.parse(rows.first['value'] as String);
      final next = current + 1;
      await txn.insert('sync_state', {
        'key': key,
        'value': '$next',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return next;
    }

    if (executor != null) return body(executor);
    final db = await _databaseService.database;
    return db.transaction((txn) => body(txn));
  }

  /// Reads the current counter for [authorId] without minting — 0 if the
  /// namespace has never minted anything. Test/diagnostic helper; no
  /// production call site needs this in this milestone (M2.4's outbox
  /// insert only needs the minted value [mintNextSeq] already returns).
  Future<int> peek(String authorId, {DatabaseExecutor? executor}) async {
    final db = executor ?? await _databaseService.database;
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: [_keyFor(authorId)],
      limit: 1,
    );
    return rows.isEmpty ? 0 : int.parse(rows.first['value'] as String);
  }
}
