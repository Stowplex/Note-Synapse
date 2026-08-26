// `contentKey`-based deduplication, canonical-winner rule, and permanent
// redirect recording against `sync_dedup_index`/`sync_dot_redirects` — §
// Architecture 1's round-8/9/14 fixes. Direct SQL port of the `contentKey`
// handling block inside `test/sync_protocol/replica.dart`'s `apply()`:
//
// ```
// final ck = op.contentKey;
// if (ck != null) {
//   _dotContentKey[op.dot] = ck;
//   final cls = contentKeyClass.putIfAbsent(ck, () => {});
//   if (cls.containsKey(op.dot)) {
//     return; // already fully processed, idempotent re-apply
//   }
//   cls[op.dot] = op;
//
//   final existingCanonical = dedupIndex[ck];
//   if (existingCanonical == null) {
//     dedupIndex[ck] = op.dot; // first-seen member becomes canonical
//   } else {
//     final newCanonical = op.dot < existingCanonical ? op.dot : existingCanonical;
//     if (newCanonical != existingCanonical) {
//       dedupIndex[ck] = newCanonical;
//       dotRedirects[existingCanonical] = newCanonical;
//     } else {
//       dotRedirects[op.dot] = newCanonical;
//     }
//     skipMaterialize = true;
//     recheckTrigger = op;
//   }
// }
// ```
//
// **The one real impedance mismatch, disclosed precisely.** The abstract
// model detects "already fully processed, idempotent re-apply" via
// `cls.containsKey(op.dot)` — an in-memory registry of every dot ever seen
// for this contentKey. This milestone's schema has no such permanent
// per-contentKey membership registry; instead, "already processed" is
// derived from the two tables the design doc actually specifies:
// `sync_dedup_index` always holds the CURRENT, fully up-to-date canonical
// dot for a contentKey (rewritten in place on every swap, never chained —
// see [ContentKeyDedupEngine.process]'s own comment), so a dot is
// "already processed" iff it either (a) already equals that canonical dot,
// or (b) already has its own row in `sync_dot_redirects` as the observed
// (non-canonical) side. This is an exact behavioral match for the
// abstract model's registry-membership check — every dot that would ever
// be present in `cls` has, by construction, gone through exactly one of
// these two tables by the time this function returns for it — not a
// weaker approximation of it.
//
// M2.5, § Architecture 11.4 ("local causal engine").

import 'package:sqflite/sqflite.dart';

import 'dot.dart';

enum DedupOutcome {
  /// This exact dot has already gone through dedup for this contentKey
  /// before (either as the recorded canonical, or as an already-redirected
  /// non-canonical alias) — a no-op, idempotent re-apply.
  alreadyProcessed,

  /// No prior member of this contentKey class was known — this dot becomes
  /// the (initial) canonical dot. The caller should materialize normally.
  firstSeen,

  /// A canonical dot already existed and stays canonical; this dot is a
  /// non-canonical duplicate — a permanent redirect was just recorded.
  /// Never materialized directly; the caller must trigger a field/set
  /// recheck passing this operation as an explicit extra candidate
  /// (§ Architecture 1 finding 1/2, "recheck-on-discovery").
  redirectedNonCanonical,

  /// A canonical dot already existed, but this dot is lexicographically
  /// smaller and becomes the NEW canonical dot — the previous canonical
  /// now redirects to this one. Never materialized directly under its own
  /// identity by this call (mirrors the abstract model: only the
  /// first-seen member of a contentKey class is ever passed to
  /// materialize); the caller must trigger a recheck exactly as for
  /// [redirectedNonCanonical].
  canonicalSwapped,
}

class DedupResult {
  const DedupResult({required this.outcome, required this.canonicalDot});

  final DedupOutcome outcome;

  /// The contentKey class's canonical dot after this call.
  final Dot canonicalDot;

  /// Mirrors the abstract model's `skipMaterialize` flag: true for every
  /// outcome except [DedupOutcome.firstSeen].
  bool get skipMaterialize => outcome != DedupOutcome.firstSeen;

  /// Mirrors the abstract model's `recheckTrigger != null` condition: a
  /// field/set recheck must fire, passing the just-processed operation in
  /// as an explicit extra candidate, for [DedupOutcome.redirectedNonCanonical]
  /// and [DedupOutcome.canonicalSwapped] — never for [DedupOutcome.firstSeen]
  /// (nothing to recheck against yet) or [DedupOutcome.alreadyProcessed]
  /// (already fully handled by an earlier call).
  bool get recheckNeeded =>
      outcome == DedupOutcome.redirectedNonCanonical ||
      outcome == DedupOutcome.canonicalSwapped;
}

/// Runs the `contentKey` dedup/canonical-winner/redirect algorithm against
/// `sync_dedup_index`/`sync_dot_redirects`.
class ContentKeyDedupEngine {
  const ContentKeyDedupEngine();

  /// Processes one `(contentKey, dot)` observation. Must be called inside
  /// the same transaction the caller uses to decide whether/how to
  /// materialize — the write here (canonical index + redirect row) and the
  /// caller's own materialize-or-skip decision must be atomic together,
  /// exactly like the abstract model's single synchronous `apply()` call.
  Future<DedupResult> process(
    DatabaseExecutor txn, {
    required String contentKey,
    required Dot dot,
  }) async {
    final existing = await _readCanonical(txn, contentKey);

    if (existing == null) {
      await txn.insert('sync_dedup_index', {
        'contentKey': contentKey,
        'canonicalAuthorId': dot.authorId,
        'canonicalAuthorSeq': dot.authorSeq,
      });
      return DedupResult(outcome: DedupOutcome.firstSeen, canonicalDot: dot);
    }

    if (existing == dot) {
      return DedupResult(
        outcome: DedupOutcome.alreadyProcessed,
        canonicalDot: existing,
      );
    }

    if (await _hasRedirect(txn, dot)) {
      return DedupResult(
        outcome: DedupOutcome.alreadyProcessed,
        canonicalDot: existing,
      );
    }

    final newCanonical = dot < existing ? dot : existing;
    if (newCanonical != existing) {
      // This dot becomes the new canonical; the OLD canonical now
      // redirects to it (a single new sync_dot_redirects entry — any dot
      // that already redirected to the old canonical resolves through it
      // transitively via DotRedirectResolver.resolveDot's multi-hop walk,
      // exactly as the abstract model relies on).
      await _writeCanonical(txn, contentKey, newCanonical);
      await _writeRedirect(txn, observed: existing, canonical: newCanonical);
      return DedupResult(
        outcome: DedupOutcome.canonicalSwapped,
        canonicalDot: newCanonical,
      );
    } else {
      await _writeRedirect(txn, observed: dot, canonical: existing);
      return DedupResult(
        outcome: DedupOutcome.redirectedNonCanonical,
        canonicalDot: existing,
      );
    }
  }

  Future<Dot?> _readCanonical(DatabaseExecutor txn, String contentKey) async {
    final rows = await txn.query(
      'sync_dedup_index',
      columns: const ['canonicalAuthorId', 'canonicalAuthorSeq'],
      where: 'contentKey = ?',
      whereArgs: [contentKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Dot(
      rows.first['canonicalAuthorId'] as String,
      rows.first['canonicalAuthorSeq'] as int,
    );
  }

  Future<void> _writeCanonical(
    DatabaseExecutor txn,
    String contentKey,
    Dot dot,
  ) async {
    await txn.insert('sync_dedup_index', {
      'contentKey': contentKey,
      'canonicalAuthorId': dot.authorId,
      'canonicalAuthorSeq': dot.authorSeq,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> _hasRedirect(DatabaseExecutor txn, Dot observed) async {
    final rows = await txn.query(
      'sync_dot_redirects',
      columns: const ['observedAuthorId'],
      where: 'observedAuthorId = ? AND observedAuthorSeq = ?',
      whereArgs: [observed.authorId, observed.authorSeq],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _writeRedirect(
    DatabaseExecutor txn, {
    required Dot observed,
    required Dot canonical,
  }) async {
    await txn.insert('sync_dot_redirects', {
      'observedAuthorId': observed.authorId,
      'observedAuthorSeq': observed.authorSeq,
      'canonicalAuthorId': canonical.authorId,
      'canonicalAuthorSeq': canonical.authorSeq,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
