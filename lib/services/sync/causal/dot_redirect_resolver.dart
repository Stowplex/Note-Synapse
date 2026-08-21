// Dot redirect resolution against `sync_dot_redirects` — § Architecture 1's
// "Every reference to a target dot anywhere in the protocol... is resolved
// through this redirect table first, transitively, before being compared
// or applied." Direct SQL port of `test/sync_protocol/replica.dart`'s
// `resolveDot`.
//
// M2.5, § Architecture 11.4 ("local causal engine").

import 'package:sqflite/sqflite.dart';

import 'dot.dart';

/// Resolves a dot through `sync_dot_redirects`, transitively, to whatever
/// dot it ultimately redirects to (itself, if it has no outgoing redirect
/// at all — the common case for a canonical dot).
class DotRedirectResolver {
  const DotRedirectResolver();

  /// Direct port of `replica.dart`'s:
  /// ```
  /// Dot resolveDot(Dot d) {
  ///   var cur = d;
  ///   final seen = <Dot>{};
  ///   while (dotRedirects.containsKey(cur) && seen.add(cur)) {
  ///     cur = dotRedirects[cur]!;
  ///   }
  ///   return cur;
  /// }
  /// ```
  /// The loop condition here is restructured slightly for the SQL-backed
  /// case (check-membership-then-add collapses naturally into "does a
  /// redirect row exist for `cur`, and have we not already visited `cur`")
  /// but is behaviorally identical: it terminates on the first dot with no
  /// outgoing redirect, or defensively on a cycle (which should never arise
  /// by construction — `sync_dot_redirects` is only ever written toward a
  /// dot proven lexicographically smaller, so a cycle would imply a real
  /// bug elsewhere, not a legitimate protocol state).
  Future<Dot> resolveDot(DatabaseExecutor txn, Dot d) async {
    var cur = d;
    final seen = <Dot>{};
    while (seen.add(cur)) {
      final next = await _lookupRedirect(txn, cur);
      if (next == null) break;
      cur = next;
    }
    return cur;
  }

  /// Resolves every dot in [dots], in order — the `set_remove`
  /// `targetDots` case (§ Architecture 1: "a `set_remove`'s target add-
  /// dot(s)... each resolved through `sync_dot_redirects` before
  /// comparison/application").
  Future<List<Dot>> resolveMany(DatabaseExecutor txn, List<Dot> dots) async {
    final out = <Dot>[];
    for (final d in dots) {
      out.add(await resolveDot(txn, d));
    }
    return out;
  }

  Future<Dot?> _lookupRedirect(DatabaseExecutor txn, Dot d) async {
    final rows = await txn.query(
      'sync_dot_redirects',
      columns: const ['canonicalAuthorId', 'canonicalAuthorSeq'],
      where: 'observedAuthorId = ? AND observedAuthorSeq = ?',
      whereArgs: [d.authorId, d.authorSeq],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Dot(
      rows.first['canonicalAuthorId'] as String,
      rows.first['canonicalAuthorSeq'] as int,
    );
  }
}
