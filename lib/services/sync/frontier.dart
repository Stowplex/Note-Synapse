// Shared frontier-JSON helper for freshly, locally-minted operations —
// factored out of `outbox_drainer.dart` (M2.4) so M2.7's own local mints
// (§ 11.6(e)'s auto-merge write pair) can share it rather than duplicating
// the same logic a second time.
//
// **Closes `OutboxDrainer`'s own disclosed residual, per its doc comment's
// explicit invitation ("M2.7 is the natural next place to close this").**
// § Architecture 2's frontier is `{authorId: maxSeq}` over every author this
// device has ever OBSERVED. Before M2.6's pull loop existed, no durable
// per-remote-author record existed at all, so `OutboxDrainer` stamped only
// `{authorId: authorSeq}` for the operation just minted — correct only for
// a device that had never merged a remote author's operations. M2.6 built
// the missing piece: `sync_state['frontier:<authorId>']`, maintained
// unconditionally on every observed pulled commit (§ 11.7 Phase B step 4).
// [currentFrontierJson] folds every such entry into the frontier stamped on
// a freshly-minted local operation, alongside the device's own just-minted
// dot — making a newly-minted operation's frontier as informative as it can
// be for another replica's causal comparisons, without changing anything
// about how a *received* operation's frontier is read or compared.
//
// ---------------------------------------------------------------------
// **M2.10 fix — a locally-minted operation must also carry this device's
// OWN OTHER namespaces' positions, or § Architecture 1's round-17 "stale
// seed wins" failure becomes live the moment anything mints into `seed:`.**
// ---------------------------------------------------------------------
// One physical device owns up to three `authorId` namespaces (`<uuid>`,
// `"seed:<uuid>"`, `"external:<uuid>"` — see `seq_counter.dart`). They are
// separate authors to the protocol, but they are the SAME observer: a
// device has, by construction, observed every operation it minted itself,
// under any of its namespaces.
//
// Before this fix, nothing recorded that. `sync_state['frontier:<log>']` is
// written only by `pull_phase.dart`, which deliberately skips this device's
// own namespaces (`_ownNamespaceIds`) — correctly, since a device does not
// pull its own logs. So an ordinary edit `Y` minted after a seed operation
// `a` on the same field carried NO entry for `seed:<self>` at all, and
// `dominates(Y.frontier, a)` was false. The design's Key-Lemma discussion
// (§ Architecture 1, round 17) explicitly relies on the opposite — "`Y`'s
// frontier dominates `a`, A's own prior dot" — as the witness that makes
// `causally_includes'''(Y, seed_op)` true. Without it, a user's real,
// later, intentional edit is classified as CONCURRENT with the seed value
// it was made from, and the ordinary `(hlc, authorId, authorSeq)` tie-break
// can hand the field back to the stale seed: the edit is silently reverted,
// with a spurious `field_conflict` copy as the only trace. This was inert
// while nothing minted `seed:` operations; M2.10's seed scanner makes it
// reachable, so it is fixed here rather than left to the caller.
//
// **The fix reads the seq counters, not a new table.** `sync_state
// ['next_seq:<authorId>']` already holds the LAST sequence number minted in
// each namespace (`SeqCounter.mintNextSeq` writes the value it just
// returned), and a `next_seq:` row exists for exactly the namespaces this
// device itself mints under — `SeqCounter` is never called with a remote
// author. So folding in every `next_seq:` row is precisely "every dot I
// have ever minted myself, in any of my own namespaces", which is a true
// observation claim, and it needs no new bookkeeping to stay accurate.
// `external:` is covered automatically by the same rule the day it exists.
//
// **Why this does not weaken the Key Lemma for seed operations, and what
// that argument actually rests on.** A seed's frontier now also carries
// this device's ordinary-namespace position — a claim of the form "I have
// observed `p`'s operations 1..N". The Lemma constrains what a seed's
// frontier may dominate *on the seed's own field*, so the step that makes
// it safe is: an entry for namespace `p` witnesses an operation on `(e,g)`
// only if `p` ever minted one for `(e,g)`, and `seed_scanner.dart`'s
// minting precondition refuses to seed `(e,g)` while any local evidence of
// one exists.
//
// **That step has a dependency worth naming, because the conclusion is
// worthless without it: every same-device field mint writes
// `sync_field_state` in the SAME transaction as its `sync_pending_ops`
// insert.** If any minting path recorded an operation without recording
// that field's state, its dot would sit inside a later seed's frontier
// while leaving that seed's precondition satisfied — and the Lemma would
// break. Verified across every such path in this codebase:
// `OutboxDrainer._mintFieldOperation` inserts into `sync_pending_ops` and
// `sync_field_state` back to back inside the caller's `txn`;
// `SyncMaterializer._mintAndApplyTagField` and `SeedScanner`'s own
// `_mintAndApplyField` both route through `CausalEngine.apply` ->
// `FieldConflictResolver.recompute` -> `_writeWinner`, again in the same
// `txn` as their outbox insert. Any future minting path must preserve this
// property or re-derive the Lemma.
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// Builds the frontier JSON to stamp on a freshly, locally-minted operation
/// for [authorId]/[authorSeq]: every remote author's frontier this device
/// has learned via `sync_state['frontier:<authorId>']`, every namespace this
/// device itself has ever minted under via `sync_state['next_seq:<authorId>']`
/// (see this file's top doc comment — this half is load-bearing, not
/// cosmetic), and this device's own just-minted dot. Safe to call with
/// either a top-level [Database] or an in-flight [DatabaseExecutor]
/// (transaction) — the same idiom every other sync primitive in this
/// codebase already uses.
///
/// Must be called AFTER `SeqCounter.mintNextSeq` for this operation, inside
/// the same transaction — every existing call site already does, and it is
/// what makes `next_seq:<authorId>` and [authorSeq] agree.
Future<String> currentFrontierJson(
  DatabaseExecutor db,
  String authorId,
  int authorSeq,
) async {
  final frontier = <String, int>{};

  void observe(String observedAuthorId, int seq) {
    final current = frontier[observedAuthorId];
    if (current == null || seq > current) frontier[observedAuthorId] = seq;
  }

  const frontierPrefix = 'frontier:';
  const seqPrefix = 'next_seq:';
  final rows = await db.query(
    'sync_state',
    where: 'key LIKE ? OR key LIKE ?',
    whereArgs: ['$frontierPrefix%', '$seqPrefix%'],
  );
  for (final row in rows) {
    final key = row['key'] as String;
    final rawValue = row['value'] as String?;
    final value = rawValue == null ? null : int.tryParse(rawValue);
    if (value == null) continue;
    if (key.startsWith(frontierPrefix)) {
      // A remote device log this device has pulled from.
      observe(key.substring(frontierPrefix.length), value);
    } else {
      // One of THIS device's own namespaces (`<uuid>`, `seed:<uuid>`,
      // `external:<uuid>`) — a namespace whose every operation this device
      // minted itself and has therefore certainly observed.
      observe(key.substring(seqPrefix.length), value);
    }
  }

  // This device's own just-minted dot. Equal to the `next_seq:<authorId>`
  // row already folded in above (the caller mints the seq first, in the same
  // transaction), so this is belt-and-braces rather than new information —
  // but it makes "an operation's frontier always includes its own dot" hold
  // unconditionally, independent of call-site ordering.
  observe(authorId, authorSeq);

  return jsonEncode(frontier);
}
