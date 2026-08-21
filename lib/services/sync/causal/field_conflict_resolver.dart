// The SCC-condensation + `winnerScc`-guarded `chainDom` field-conflict
// resolution algorithm — § Architecture 1's "Round 20" fix, the single most
// adversarially-reviewed piece of logic in the whole design doc (four
// review passes in round 20 alone: "the bug", the W/P/Q counterexample, the
// `i ∉ winnerScc` guard fix, and finding 5's 3-hop transitive case).
//
// Direct, deliberately faithful SQL port of
// `test/sync_protocol/replica.dart`'s `_recomputeField` (and its
// `_groupMembers`/`_unionFrontier`/`_groupDominates`/`_representative`
// helpers) — ported, not re-derived, per the milestone brief: correctness
// is established by differential testing against the exact named
// regression scenarios (`field_conflict_resolver_test.dart`), not by
// re-reasoning about the algorithm from scratch.
//
// M2.5, § Architecture 11.4 ("local causal engine").
//
// ---------------------------------------------------------------------
// `sync_conflict_copies` full-history retention — § 11.4's open question,
// EMPIRICALLY SETTLED (not deferred) by this milestone's own required
// differential replay.
// ---------------------------------------------------------------------
//
// § 11.4 poses this precisely: `replica.dart` recomputes over
// `_fieldHistory[key]` — a permanent, NEVER-pruned set of every dot ever
// locally observed for a field, specifically so a proven-dominated
// ancestor discarded in one recompute remains available as a `chainDom`
// singleton witness for a LATER recompute (finding 5's 3-hop `X>Y>Z`
// case) — while the real, already-built schema's `sync_conflict_copies`
// only ever holds the CURRENT live (non-discarded) set. § 11.4's own text:
// "Build now... literally per its existing schema... this milestone
// should NOT invent the `supersededAt` fallback column preemptively... If
// [differential testing] finds even one disagreement, the disclosed
// fallback is a nullable `supersededAt` column on `sync_conflict_copies`
// — not a redesign."
//
// **This milestone's own required regression replay (per its brief,
// non-negotiably including finding 5's exact 3-hop scenario) found
// exactly that disagreement, directly, by hand-tracing the algorithm
// before writing any test**: `X` wins over `Y` (discarded, dominated
// directly); `Y`'s row is dropped entirely; `Z` then arrives and is
// compared only against `X` (the current winner) — `X`'s own frontier
// never mentions `Z`'s author (finding 5's whole premise), so with no
// `Y` witness available, `X` and `Z` are found CONCURRENT, and `Z` wins
// the HLC tie-break outright (hlc 3 > hlc 2) — silently overwriting the
// correct answer, the exact failure finding 5 exists to prevent. This is
// not a hypothetical: it is what a bare "narrower candidate set" port of
// this algorithm actually does on the literal scenario the milestone
// brief names as required.
//
// **Fix applied, per § 11.4's own disclosed contingency — but via the
// EXISTING `kind` discriminator column, not a new `supersededAt` column,
// avoiding a schema migration entirely.** `sync_conflict_copies.kind` is
// already a free-form discriminator ("the same table, a `kind`
// discriminator rather than a separate mechanism," § Architecture 1).
// This resolver adds one more locally-scoped value,
// `'field_conflict_superseded'`, alongside the existing `'field_conflict'`
// — written for exactly the dots `chainDom` proves are causal ancestors,
// instead of dropping them. [recompute]'s candidate-set query reads BOTH
// kinds (the full historical set, mirroring `_fieldHistory`); only
// `'field_conflict'` rows are ever the LIVE, user-facing set (what
// [FieldRecomputeResult.retainedConflicts] returns, and what a future
// M2.7 materializer or UI would query). A candidate can move between the
// two kinds across successive recomputes (e.g. from live to superseded,
// once something newly proves it's an ancestor) — the write-back always
// deletes and fully rewrites both kinds for a field in one pass, so no
// stale duplicate under the other kind can linger.
//
// **This is not a "new" column and not unbounded growth beyond what § 11.4
// already discloses and accepts.** § 11.4's own boundedness paragraph:
// "unlike `sync_dot_redirects`'s `O(devices)`-class bound, an unpruned
// `sync_conflict_copies` is bounded only by `O(genuinely concurrent,
// never-since-dominated edits ever made to the same field)`." Retaining
// superseded (proven-ancestor) rows too, rather than dropping them, adds
// no NEW unboundedness class — it is the identical disclosed residual
// (physical pruning deferred to the not-yet-built snapshot/certificate
// machinery, § Architecture 6), just now covering superseded rows as well
// as live ones. See the milestone report for the full trace of why the
// narrower, no-retention version fails and why this fix (not a redesign)
// closes it.
//
// **A second, related gap — also found by this milestone's own required
// differential replay (the round-20 `A1`/`A2`/`B1`/`B2` mutual-domination
// regression test), fixed the same way, via a THIRD `kind` value.**
// `_groupMembers(canon)` in `replica.dart` draws from `contentKeyClass[ck]`
// — a PERMANENT registry of every dot ever observed for a `contentKey`,
// entirely independent of what currently sits in `fieldState`/
// `conflictCopies`. This matters because `_recomputeField` only ever
// PERSISTS a single "representative" operation for the group that wins
// (`fieldState[key] = finalWinner`, one `Operation`, never a union) — a
// non-representative alias that contributed to that group winning (e.g.
// `A2`, whose own frontier is what makes group `A` dominate group `B`) is
// otherwise never independently persisted anywhere once its group wins,
// so a LATER recompute that needs `A`'s full unioned frontier again
// (e.g. once `B2` arrives and the domination becomes genuinely mutual)
// would silently lose `A2`'s contribution — reproducing the exact
// silent-discard failure round 20 exists to prevent, via a different
// mechanism than finding 5's (this one is about `contentKey`-GROUP
// membership, not about a single dot's own history). Confirmed by
// hand-tracing the round-20 regression construction against this
// resolver's own code before writing this comment: group `A` was found to
// wrongly vanish entirely once `B2` arrived, exactly because `A2`'s
// individually-observed frontier (the only witness that `A` ever
// dominated `B` in the first place) had nowhere left to be read from.
//
// **Fix, via the same mechanism as above — no new column.** Every
// `contentKey`-bearing candidate ([recompute]'s `extraCandidate`, when it
// carries one) is durably recorded, unconditionally and permanently, as
// its own `sync_conflict_copies` row under a third `kind` value,
// `'contentkey_alias_witness'` — mirroring `contentKeyClass[ck][op.dot] =
// op`'s own unconditional recording, which happens before any skip/
// materialize decision. These rows are NEVER cleared by ordinary
// recompute (they are not part of the live-vs-superseded churn
// `_replaceHistory` manages) and are folded into the raw candidate set
// on every future recompute for the same field, restoring exactly the
// `_fieldHistory`/`contentKeyClass` split's effect: `canons` (which
// operations are DISTINCT resolved identities) is unaffected by these
// extra rows — they only ever resolve to an ALREADY-present canonical
// identity — but `groupMembersFor`/`_unionFrontier` now see every alias
// ever observed, not only whichever one happens to still be independently
// persisted as a winner or (non-superseded) conflict copy.
//
// **Boundedness of `kindContentKeyAliasWitness`, stated explicitly rather
// than assumed to share `kindFieldConflictSuperseded`'s bound — it does
// NOT.** `kindFieldConflictSuperseded` retains proven ancestors, bounded
// the same way the baseline `sync_conflict_copies` design already argues
// (§ Architecture 1): `O(genuinely concurrent, never-since-dominated
// edits ever made to the same field)` — a proven ancestor, once
// discarded, is never re-examined by anything other than a future
// `chainDom` walk over the SAME small set of live/superseded candidates.
// `kindContentKeyAliasWitness` is different in kind, not just degree: it
// permanently records EVERY `contentKey`-bearing candidate ever observed
// for a field, full stop — including, concretely, every successive
// external-edit round-trip on the same field, each of which mints a
// fresh, distinct `contentKey` (its `baseContext` is the prior
// projection's own digest, § Architecture 1's round-14 formula, so it is
// never equal to any earlier or later transition's `contentKey`). Its
// bound is therefore `O(total contentKey-bearing operations ever
// observed for the field)` — total historical count, not concurrent-edit
// count — a materially different, potentially much worse profile than
// the baseline argument, and this file makes no claim it shares that
// bound. This is a genuine, disclosed residual, not a silently-assumed
// one: physical pruning/compaction is deferred to the same not-yet-built
// certificate/snapshot machinery (§ Architecture 6) that finding 5's own
// `sync_conflict_copies` boundedness discussion already defers to, and
// this milestone does not attempt to build it.
//
// **Group membership ("`_groupMembers`") scope, restated with both fixes
// in place.** This resolver's notion of "every locally-known alias of a
// resolved dot" is the full set of: the current `sync_field_state`
// winner, every `sync_conflict_copies` row for this field (all three
// kinds), and the just-arrived extra candidate — matching
// `_fieldHistory`/`contentKeyClass`-backed `_groupMembers` exactly, not a
// narrower live-only view. `isSingleton` (the `chainDom` pass-through
// guard) is evaluated against this same full set.
//
// ---------------------------------------------------------------------
// **Why `_groupDominates` does NOT call `causallyIncludesGenesisAware`.**
// ---------------------------------------------------------------------
// `causal_comparator.dart`'s top doc comment already flags this; restated
// here because it is load-bearing for THIS file's own correctness. Reading
// `replica.dart`'s actual `_groupDominates` body (not its doc comment,
// which is a looser paraphrase) shows it does its own direct "does the
// source group's UNIONED frontier dominate ANY member of the target
// group" check via plain `dominates()`, applied uniformly whether the
// target group is genesis or not — it never calls the separate,
// genesis-gated `causallyIncludes` function. Hand-tracing the "Task A"
// motivating regression scenario (`field_conflict_resolver_test.dart`,
// group 'causal comparator — Task A motivating scenario, replayed through
// the field-conflict resolver') through this exact code confirms this is
// what makes that scenario resolve correctly: `y`'s group (a singleton,
// no contentKey) is found to dominate the seed-pair's group specifically
// because the loop checks `dominates(unionFrontier(y), seedA.dot)` — a
// witness search over the target group's members, done unconditionally,
// not gated behind "is the seed group genesis." This is safe specifically
// because round 20's SCC/`chainDom` construction on top of it is proven
// robust to `_groupDominates` being non-transitive/non-antisymmetric
// between groups (that is the entire point of "the bug" and its fix) —
// `_groupDominates` itself does not need to be independently "sound" the
// way the genesis-restricted `causally_includes'''` does.
//
// This resolver therefore does NOT import `causallyIncludesGenesisAware`
// at all — only the base `dominates()` primitive, exactly mirroring
// `_groupDominates`'s actual dependency.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'causal_comparator.dart' show dominates, hlcTieBreakWins;
import 'dot.dart';
import 'dot_redirect_resolver.dart';
import 'field_candidate.dart';

/// Result of one [FieldConflictResolver.recompute] call.
class FieldRecomputeResult {
  const FieldRecomputeResult({
    required this.winner,
    required this.retainedConflicts,
    required this.winnerChanged,
  });

  /// The recomputed winner, now written into `sync_field_state`.
  final FieldCandidate winner;

  /// Every other retained (genuinely concurrent, not causally dominated)
  /// candidate, now written into `sync_conflict_copies`
  /// (`kind='field_conflict'`) — replacing whatever was there before.
  final List<FieldCandidate> retainedConflicts;

  /// Whether [winner]'s dot differs from whatever `sync_field_state` held
  /// before this call (or there was no prior row at all). Informational
  /// only — the algorithm itself always writes unconditionally, exactly
  /// like `replica.dart`'s own `fieldState[key] = finalWinner;` (no
  /// "only if changed" guard exists in the ported code, despite the
  /// design doc's prose using that phrase — see this file's own git
  /// history / the milestone report for why an unconditional write is the
  /// faithful port). Useful for a future M2.7 materializer to know
  /// whether app-table work is actually needed.
  final bool winnerChanged;
}

/// Ported `_recomputeField` — the single, order-independent field-conflict
/// (re)computation routine, used both for ordinary materialization (the
/// just-arrived op as [FieldConflictResolver.recompute]'s `extraCandidate`)
/// and for recheck-on-discovery (fired whenever `content_key_dedup.dart`
/// records ANY contentKey redirect, the just-arrived, dedup-absorbed
/// operation passed the same way).
class FieldConflictResolver {
  const FieldConflictResolver(this._redirects);

  final DotRedirectResolver _redirects;

  /// `sync_conflict_copies.kind` value for the live, user-facing
  /// genuinely-concurrent set — unchanged from the pre-existing schema.
  static const kindFieldConflict = 'field_conflict';

  /// `sync_conflict_copies.kind` value for a candidate `chainDom` has
  /// proven is a causal ancestor — retained (never shown to a user, never
  /// part of [FieldRecomputeResult.retainedConflicts]) purely so it stays
  /// available as a future `chainDom` witness, mirroring `_fieldHistory`.
  /// See this file's top doc comment for why this exists and why it is
  /// not a schema migration.
  static const kindFieldConflictSuperseded = 'field_conflict_superseded';

  /// `sync_conflict_copies.kind` value for a PERMANENT, per-dot record of
  /// every `contentKey`-bearing candidate ever observed for a field —
  /// mirroring `contentKeyClass[ck][op.dot] = op`'s own unconditional,
  /// never-pruned recording. Never cleared by ordinary recompute, never
  /// part of [FieldRecomputeResult.retainedConflicts]. See this file's top
  /// doc comment ("A second, related gap") for why this is required, not
  /// merely defensive. **Boundedness is `O(total contentKey-bearing
  /// operations ever observed for the field)`, NOT the same, smaller
  /// bound as [kindFieldConflictSuperseded]** — see this file's top doc
  /// comment ("Boundedness of `kindContentKeyAliasWitness`") for why, and
  /// why this is a disclosed residual rather than solved here.
  static const kindContentKeyAliasWitness = 'contentkey_alias_witness';

  /// Recomputes the winner/retained-conflict set for one
  /// `(entityTable, entityId, fieldName)` field, over `{current
  /// sync_field_state winner} ∪ {every sync_conflict_copies row for this
  /// field, all three kinds} ∪ {extraCandidate, if supplied}` (§ this
  /// file's own top doc comment) — the full historical candidate set,
  /// mirroring `_fieldHistory`/`contentKeyClass`. Returns `null` if there
  /// is nothing to compute at all (no prior winner, no conflict copies, no
  /// extra candidate) — mirrors `replica.dart`'s `if (history.isEmpty)
  /// return;`.
  Future<FieldRecomputeResult?> recompute(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    FieldCandidate? extraCandidate,
  }) async {
    if (extraCandidate != null && extraCandidate.contentKey != null) {
      await _recordAliasWitness(
        txn,
        entityTable,
        entityId,
        fieldName,
        extraCandidate,
      );
    }

    final priorWinnerRow = await _readWinnerRow(
      txn,
      entityTable,
      entityId,
      fieldName,
    );
    final priorWinner = priorWinnerRow == null
        ? null
        : FieldCandidate.fromFieldStateRow(priorWinnerRow);
    final priorHistory = await _readAllHistoryRows(
      txn,
      entityTable,
      entityId,
      fieldName,
    );

    final raw = <FieldCandidate>[
      if (priorWinner != null) priorWinner,
      ...priorHistory,
      if (extraCandidate != null) extraCandidate,
    ];
    if (raw.isEmpty) return null;

    // canons = history.map(resolveDot).toSet().toList() — collapse to the
    // distinct set of resolved (canonical) identities. Sorted purely for
    // deterministic iteration/representative selection — the algorithm's
    // own result is order-independent by construction regardless.
    final resolvedDots = <Dot>[];
    for (final c in raw) {
      resolvedDots.add(await _redirects.resolveDot(txn, c.dot));
    }
    final canons = <Dot>{...resolvedDots}.toList()..sort();

    // Deduplicated by DOT (not just collected as-is): the same real dot can
    // legitimately appear more than once in `raw` — e.g. a dot that is
    // simultaneously the current `sync_field_state` winner AND has its own
    // permanent `kindContentKeyAliasWitness` row (written unconditionally
    // by every call that saw it as a `contentKey`-bearing extraCandidate,
    // including the very call that first made it the winner). Two raw
    // entries for the SAME dot are always byte-identical in value/hlc/
    // frontier (an Operation is immutable once minted; every persisted
    // copy traces back to the same original candidate object) — but
    // leaving them uncollapsed would inflate `groups[idx].length`, making
    // `isSingleton` wrongly return false for a dot that has no OTHER real
    // alias, breaking `chainDom`'s pass-through restriction in the
    // conservative-but-unfaithful direction (spurious extra retained
    // conflicts, never silent loss — still a correctness gap worth
    // closing precisely, given how much this restriction's exactness
    // matters, per this file's own top doc comment).
    List<FieldCandidate> groupMembersFor(int canonIndex) {
      final canon = canons[canonIndex];
      final members = <Dot, FieldCandidate>{};
      for (var i = 0; i < raw.length; i++) {
        if (resolvedDots[i] == canon) members[raw[i].dot] = raw[i];
      }
      return members.values.toList();
    }

    FieldCandidate representativeOf(Dot canon, List<FieldCandidate> members) {
      for (final m in members) {
        if (m.dot == canon) return m;
      }
      return members.first;
    }

    if (canons.length == 1) {
      // Every raw candidate resolves to the SAME identity -- these are
      // aliases of one logical event, not causally-ordered distinct
      // operations, so there is no ancestor to preserve as a witness:
      // clearing both kinds is correct (mirrors `_fieldHistory` too, since
      // `_fieldHistory` only retains distinct DOTS, and aliases collapse
      // via `resolveDot` there exactly as here).
      final members = groupMembersFor(0);
      final winner = representativeOf(canons.single, members);
      await _writeWinner(txn, entityTable, entityId, fieldName, winner);
      await _clearAllHistory(txn, entityTable, entityId, fieldName);
      return FieldRecomputeResult(
        winner: winner,
        retainedConflicts: const [],
        winnerChanged: priorWinner == null || priorWinner.dot != winner.dot,
      );
    }

    // Round 20: SCC condensation of the `_groupDominates` graph, then the
    // `winnerScc`-guarded `chainDom` discard rule — ported verbatim from
    // `replica.dart:511-667`.
    final n = canons.length;
    final groups = [for (var i = 0; i < n; i++) groupMembersFor(i)];
    final unions = [for (final g in groups) _unionFrontier(g)];

    bool groupDominates(int a, int b) {
      if (a == b) return false;
      for (final y in groups[b]) {
        if (dominates(unions[a], y.dot.authorId, y.dot.authorSeq)) return true;
      }
      return false;
    }

    final dom = List.generate(n, (_) => List<bool>.filled(n, false));
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (i != j && groupDominates(i, j)) dom[i][j] = true;
      }
    }

    // Transitive closure (Floyd-Warshall) -> SCC id via mutual reachability.
    final reach = List.generate(n, (i) => List<bool>.of(dom[i]));
    for (var k = 0; k < n; k++) {
      for (var i = 0; i < n; i++) {
        if (!reach[i][k]) continue;
        for (var j = 0; j < n; j++) {
          if (reach[k][j]) reach[i][j] = true;
        }
      }
    }
    final sccId = List<int>.filled(n, -1);
    var sccCount = 0;
    for (var i = 0; i < n; i++) {
      if (sccId[i] != -1) continue;
      sccId[i] = sccCount;
      for (var j = i + 1; j < n; j++) {
        if (sccId[j] == -1 && reach[i][j] && reach[j][i]) sccId[j] = sccCount;
      }
      sccCount++;
    }

    // SCC condensation of ANY directed graph is provably a DAG, so
    // `maximalSccs` is always non-empty — the pre-round-20 defensive
    // `maximal.isEmpty` fallback is retired as genuinely unreachable, not
    // merely empirically rare (see design doc, round 20, fix part 1).
    bool sccDominates(int a, int b) {
      if (a == b) return false;
      for (var i = 0; i < n; i++) {
        if (sccId[i] != a) continue;
        for (var j = 0; j < n; j++) {
          if (sccId[j] == b && dom[i][j]) return true;
        }
      }
      return false;
    }

    final maximalSccs = <int>{
      for (var s = 0; s < sccCount; s++)
        if (!List.generate(
          sccCount,
          (o) => o,
        ).any((other) => other != s && sccDominates(other, s)))
          s,
    };
    final poolIndices = [
      for (var i = 0; i < n; i++)
        if (maximalSccs.contains(sccId[i])) i,
    ];

    var bestIdx = poolIndices.first;
    var bestRep = representativeOf(canons[bestIdx], groups[bestIdx]);
    for (final idx in poolIndices.skip(1)) {
      final rep = representativeOf(canons[idx], groups[idx]);
      if (hlcTieBreakWins(
        aHlc: rep.hlc,
        aDot: rep.dot,
        bHlc: bestRep.hlc,
        bDot: bestRep.dot,
      )) {
        bestIdx = idx;
        bestRep = rep;
      }
    }
    final finalWinner = bestRep;
    final winnerScc = sccId[bestIdx];

    // `chainDom(w, i)`: a path from `w` to `i` in `dom` whose INTERMEDIATE
    // nodes are all singleton groups — sound for chains of genuinely
    // distinct, non-aliased operations (the Transitivity Corollary),
    // unsound as a pass-through for a multi-member alias group. Singleton
    // status is evaluated fresh every call (never cached) — group
    // membership changes on every contentKey-redirect discovery.
    bool isSingleton(int idx) => groups[idx].length == 1;

    Set<int> chainDomReachable(int w) {
      final seen = <int>{w};
      final reached = <int>{};
      final queue = <int>[w];
      while (queue.isNotEmpty) {
        final cur = queue.removeAt(0);
        // A non-singleton, non-source node is a valid endpoint only —
        // never a pass-through witness.
        if (cur != w && !isSingleton(cur)) continue;
        for (var nxt = 0; nxt < n; nxt++) {
          if (dom[cur][nxt] && seen.add(nxt)) {
            reached.add(nxt);
            queue.add(nxt);
          }
        }
      }
      return reached;
    }

    // A fellow member of the winner's own (possibly cyclic) SCC is NEVER
    // discard-eligible — this is the `i ∉ winnerScc` guard round 20's
    // SECOND adversarial pass found missing from the first draft of this
    // fix, without which `chainDom`'s vacuous zero-hop case reproduces
    // "the bug" itself. Only a candidate OUTSIDE `winnerScc`, reachable
    // from some `winnerScc` member via a singleton-witnessed chain, is
    // discarded.
    final winnerSccMembers = [
      for (var i = 0; i < n; i++)
        if (sccId[i] == winnerScc) i,
    ];
    final discardable = <int>{};
    for (final w in winnerSccMembers) {
      discardable.addAll(chainDomReachable(w));
    }

    final retained = <FieldCandidate>[];
    final superseded = <FieldCandidate>[];
    for (var i = 0; i < n; i++) {
      if (i == bestIdx) continue;
      final rep = representativeOf(canons[i], groups[i]);
      if (sccId[i] != winnerScc && discardable.contains(i)) {
        // proven ancestor: not shown live, but retained as a permanent
        // `chainDom` witness for a future recompute (§ this file's top
        // doc comment) -- never physically dropped.
        superseded.add(rep);
      } else {
        retained.add(rep);
      }
    }

    await _writeWinner(txn, entityTable, entityId, fieldName, finalWinner);
    await _replaceHistory(
      txn,
      entityTable,
      entityId,
      fieldName,
      live: retained,
      superseded: superseded,
    );

    return FieldRecomputeResult(
      winner: finalWinner,
      retainedConflicts: retained,
      winnerChanged: priorWinner == null || priorWinner.dot != finalWinner.dot,
    );
  }

  /// Direct port of `_unionFrontier`: the per-author MAX height across
  /// every member of [members].
  Map<String, int> _unionFrontier(List<FieldCandidate> members) {
    final union = <String, int>{};
    for (final m in members) {
      m.frontier.forEach((author, height) {
        final cur = union[author];
        if (cur == null || height > cur) union[author] = height;
      });
    }
    return union;
  }

  // ── sync_field_state / sync_conflict_copies I/O ──────────────────────

  Future<Map<String, Object?>?> _readWinnerRow(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
  ) async {
    final rows = await txn.query(
      'sync_field_state',
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Reads ALL THREE `kind`s — the full historical candidate set this
  /// file's top doc comment explains is required to match
  /// `_fieldHistory`/`contentKeyClass`'s semantics.
  Future<List<FieldCandidate>> _readAllHistoryRows(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
  ) async {
    final rows = await txn.query(
      'sync_conflict_copies',
      where:
          'subjectTable = ? AND subjectId = ? AND fieldName = ? AND kind IN (?, ?, ?)',
      whereArgs: [
        entityTable,
        entityId,
        fieldName,
        kindFieldConflict,
        kindFieldConflictSuperseded,
        kindContentKeyAliasWitness,
      ],
    );
    return [
      for (final r in rows)
        FieldCandidate.fromResolvedFieldsJson(
          r['resolvedFieldsJson'] as String,
        ),
    ];
  }

  /// Permanently records [candidate] as a `kindContentKeyAliasWitness` row,
  /// unconditionally — mirrors `contentKeyClass[ck][op.dot] = op`'s own
  /// unconditional recording in `apply()`, which happens before any skip/
  /// materialize decision. Never cleared by [_clearAllHistory]/
  /// [_replaceHistory] (those only ever touch [kindFieldConflict]/
  /// [kindFieldConflictSuperseded]) — see this file's top doc comment for
  /// why permanent retention here, specifically, is required.
  Future<void> _recordAliasWitness(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
    FieldCandidate candidate,
  ) async {
    await txn.insert('sync_conflict_copies', {
      'id': _rowId(
        kindContentKeyAliasWitness,
        entityTable,
        entityId,
        fieldName,
        candidate.dot,
      ),
      'subjectTable': entityTable,
      'subjectId': entityId,
      'kind': kindContentKeyAliasWitness,
      'fieldName': fieldName,
      'resolvedFieldsJson': candidate.toResolvedFieldsJson(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _writeWinner(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
    FieldCandidate winner,
  ) async {
    await txn.insert('sync_field_state', {
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'valueJson': winner.valueJson,
      'blobHash': winner.blobHash,
      'authorId': winner.dot.authorId,
      'authorSeq': winner.dot.authorSeq,
      'hlc': winner.hlc.toString(),
      'contentKey': winner.contentKey,
      'frontierJson': jsonEncode(winner.frontier),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Deletes every LIVE/SUPERSEDED `sync_conflict_copies` row for this
  /// field ([kindFieldConflict]/[kindFieldConflictSuperseded] only —
  /// [kindContentKeyAliasWitness] rows are permanent and never touched
  /// here, see this file's top doc comment).
  Future<void> _clearAllHistory(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName,
  ) async {
    await txn.delete(
      'sync_conflict_copies',
      where:
          'subjectTable = ? AND subjectId = ? AND fieldName = ? AND kind IN (?, ?)',
      whereArgs: [
        entityTable,
        entityId,
        fieldName,
        kindFieldConflict,
        kindFieldConflictSuperseded,
      ],
    );
  }

  /// Deletes every existing `sync_conflict_copies` row for this field
  /// (both kinds — a candidate can move from one kind to the other across
  /// successive recomputes, so a full rewrite avoids ever leaving a stale
  /// duplicate under its old kind) and rewrites exactly [live] (kind=
  /// [kindFieldConflict]) and [superseded] (kind=
  /// [kindFieldConflictSuperseded]).
  Future<void> _replaceHistory(
    DatabaseExecutor txn,
    String entityTable,
    String entityId,
    String fieldName, {
    required List<FieldCandidate> live,
    required List<FieldCandidate> superseded,
  }) async {
    await _clearAllHistory(txn, entityTable, entityId, fieldName);
    final now = DateTime.now().millisecondsSinceEpoch;

    Future<void> writeRow(FieldCandidate c, String kind) =>
        txn.insert('sync_conflict_copies', {
          'id': _rowId(kind, entityTable, entityId, fieldName, c.dot),
          'subjectTable': entityTable,
          'subjectId': entityId,
          'kind': kind,
          'fieldName': fieldName,
          'resolvedFieldsJson': c.toResolvedFieldsJson(),
          'createdAt': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

    for (final c in live) {
      await writeRow(c, kindFieldConflict);
    }
    for (final c in superseded) {
      await writeRow(c, kindFieldConflictSuperseded);
    }
  }

  /// `id` is deterministically derived from `(kind, dot)` (§ Architecture
  /// 1: "`id` deterministically derived... a stable hash of the losing
  /// dot/operation, so independent detection converges on one record, not
  /// duplicates") — a sha256 of a stable composite key, matching this
  /// codebase's existing deterministic-id convention elsewhere
  /// (`conversation_attachment_service.dart`, `block_note_scope_service.dart`).
  /// Embeds `kind`, unlike an earlier draft of this file: with THREE kinds
  /// now able to coexist for related-but-distinct purposes (live,
  /// superseded, and the permanent alias-witness record — the last of
  /// which is written independently of, and can coexist with, either of
  /// the other two for the SAME dot, § this file's top doc comment), a
  /// kind-independent id would let an alias-witness write and a live/
  /// superseded write for the same dot collide under one shared row.
  /// [_replaceHistory]'s full delete-then-rewrite of the live/superseded
  /// kinds already prevents a stale duplicate when a candidate moves
  /// between THOSE two kinds specifically, independent of this choice.
  String _rowId(
    String kind,
    String entityTable,
    String entityId,
    String fieldName,
    Dot dot,
  ) {
    final raw =
        'sync_conflict_copy|$kind|$entityTable|$entityId|$fieldName|${dot.authorId}|${dot.authorSeq}';
    return sha256.convert(utf8.encode(raw)).toString();
  }
}
