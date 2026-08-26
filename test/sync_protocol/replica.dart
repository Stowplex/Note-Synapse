// Replica state machine: frontier tracking, contentKey dedup +
// sync_dot_redirects, causallyIncludes''' (genesis-only alias expansion),
// field-conflict resolution, and the corrected recheck-on-discovery
// algorithm (§ Architecture 1-2 of the plan).

import 'model.dart';

/// A single-field conflict-copy record — mirrors `sync_conflict_copies`
/// (`kind='field_conflict'`), persisting the losing operation's full
/// {value, dot, frontier, hlc} as required by recheck-on-discovery.
typedef ConflictCopy = Operation;

class Replica {
  final String id;
  final List<Operation> outbox = [];

  final Map<String, int> _localSeq = {}; // per-authorId (own namespaces only)
  int _hlcClock = 0;

  /// Observation-based delta frontier: authorId -> max observed authorSeq.
  final Map<String, int> frontier = {};

  /// sync_field_state: fieldKey -> current winning operation.
  final Map<String, Operation> fieldState = {};

  /// sync_conflict_copies (kind='field_conflict'): fieldKey -> losers.
  final Map<String, List<ConflictCopy>> conflictCopies = {};

  /// sync_dedup_index: contentKey -> canonical dot.
  final Map<String, Dot> dedupIndex = {};

  /// sync_dot_redirects: observed (non-canonical) dot -> canonical dot.
  final Map<Dot, Dot> dotRedirects = {};

  /// Locally-known members of each contentKey's equivalence class, used
  /// for genesis alias-expansion and for recheck-on-discovery.
  final Map<String, Map<Dot, Operation>> contentKeyClass = {};

  /// OR-Set membership: setKey -> memberUuid -> live add-dots.
  final Map<String, Map<String, Set<Dot>>> setState = {};

  /// Every dot ever applied, regardless of contentKey — a general
  /// idempotency guard so re-delivering the same operation (e.g. two
  /// overlapping partial syncs) never double-counts it as a distinct
  /// field-conflict candidate.
  final Set<Dot> _appliedDots = {};

  /// A permanent-lookup registry (dot -> Operation) so a dot's frontier is
  /// never lost even once it stops being separately tracked in
  /// fieldState/conflictCopies.
  final Map<Dot, Operation> _allKnownOps = {};

  /// A fourth M0-simulation finding, distinct from the contentKey/dedup
  /// issues above and reachable with NO contentKey involved at all: the
  /// base incremental protocol, exactly as specified ("single row per
  /// field, each arrival compared only against the current winner"),
  /// PERMANENTLY discards a dominated ancestor the moment a later op
  /// supersedes it. That's fine as long as domination is always provable
  /// directly — but frontier propagation is deliberately narrow (observing
  /// an op only records THAT op's own author/seq, never the frontier IT
  /// carried, § Architecture 2's "narrow fix" reasoning) — so a genuinely
  /// real, three-hop transitive chain (X dominates Y, Y dominates Z, but
  /// X's own frontier never directly mentions Z's author at all) can only
  /// be PROVEN by keeping Y around as a witness. Discarding Y the moment
  /// X supersedes it, then later comparing X directly against Z, finds
  /// them "concurrent" (neither's frontier mentions the other) and lets Z
  /// win an ordinary HLC tie-break it should never have been eligible to
  /// win — a real, permanent divergence, not a display nicety. Fix:
  /// retain every dot ever locally observed for a field, permanently
  /// (not just the current winner and live conflict-copies), and always
  /// recompute over the FULL retained history — `conflictCopies` remains
  /// the smaller, user-facing "genuinely concurrent" subset; this is the
  /// larger, internal set `_recomputeField` actually reasons over.
  final Map<String, Set<Dot>> _fieldHistory = {};

  /// dot -> the contentKey it was minted/observed with, if any — the
  /// reverse of `contentKeyClass`, letting `_groupMembers` recover a
  /// canonical dot's *full* alias set (see its doc comment for why a
  /// single arbitrary representative is not enough).
  final Map<Dot, String> _dotContentKey = {};

  /// sync_grave: tombstoned entity ids that have been through the general
  /// delete-then-purge-eligible flow (used by the tag-merge layer).
  final Set<String> grave = {};

  /// Simplified stand-in for note_tags/conversation_tags/filter_* rows:
  /// a live entity (e.g. a note) referencing a tag's raw uuid directly.
  /// entityId -> set of referenced tag uuids.
  final Map<String, Set<String>> liveMembershipRefs = {};

  void addMembershipRef(String entityId, String tagId) {
    liveMembershipRefs.putIfAbsent(entityId, () => {}).add(tagId);
  }

  void removeMembershipRef(String entityId, String tagId) {
    liveMembershipRefs[entityId]?.remove(tagId);
  }

  bool hasLiveMembershipReference(String tagId) =>
      liveMembershipRefs.values.any((refs) => refs.contains(tagId));

  /// Content-addressed blob storage state (§ Architecture 4): a
  /// simplified stand-in for `blobs/<hash>` plus `sync_blob_refs` —
  /// [knownBlobHashes] is what's actually stored; [referencedBlobHashes]
  /// is the subset some live entity currently references. GC (`gc.dart`)
  /// only ever consults/mutates this pair.
  final Set<String> knownBlobHashes = {};
  final Set<String> referencedBlobHashes = {};

  void uploadBlob(String hash) {
    knownBlobHashes.add(hash);
    referencedBlobHashes.add(hash);
  }

  void referenceBlob(String hash) => referencedBlobHashes.add(hash);

  void unreferenceBlob(String hash) => referencedBlobHashes.remove(hash);

  /// Messages physically removed by orphan-message GC (`gc.dart`) — kept
  /// separate from `grave` (which merely records that SOME tombstoned
  /// entity went through the purge flow) so tests can assert specifically
  /// on message removal.
  final Set<String> physicallyRemovedMessages = {};

  Replica(this.id);

  // ---- minting -------------------------------------------------------

  int _nextSeq(String authorId) {
    final n = (_localSeq[authorId] ?? 0) + 1;
    _localSeq[authorId] = n;
    return n;
  }

  int _nextHlc() => ++_hlcClock;

  Map<String, int> _frontierSnapshot(String authorId, int seq) {
    final snap = Map<String, int>.of(frontier);
    final cur = snap[authorId] ?? 0;
    if (seq > cur) snap[authorId] = seq;
    return snap;
  }

  Operation mintExists({
    required String table,
    required String id,
    required dynamic value,
    String? contentKey,
    String authorNamespace = '',
    int? hlcOverride,
  }) =>
      _mint(
        authorId: authorNamespace.isEmpty ? this.id : authorNamespace,
        kind: OpKind.exists,
        table: table,
        entityId: id,
        field: null,
        value: value,
        contentKey: contentKey,
        hlcOverride: hlcOverride,
      );

  Operation mintField({
    required String table,
    required String id,
    required String field,
    required dynamic value,
    String? contentKey,
    String authorNamespace = '',
    int? hlcOverride,
  }) =>
      _mint(
        authorId: authorNamespace.isEmpty ? this.id : authorNamespace,
        kind: OpKind.field,
        table: table,
        entityId: id,
        field: field,
        value: value,
        contentKey: contentKey,
        hlcOverride: hlcOverride,
      );

  /// [value] defaults to `true` (bare membership) but may carry data
  /// associated with the add-event itself — e.g. a conversation-message
  /// mapping's `createdAtMillis` (`conversation_ops.dart`), which
  /// materialization (`_materializeSetAdd`) doesn't otherwise retain
  /// anywhere queryable. [authorNamespace]/[hlcOverride] mirror
  /// [mintField]/[mintExists]'s seed-op pattern, needed once OR-Set
  /// membership itself gained a genesis-seed case (round-8/14 correction,
  /// conversation-mapping ordering).
  Operation mintSetAdd({
    required String table,
    required String id,
    required String memberUuid,
    dynamic value = true,
    String? contentKey,
    String authorNamespace = '',
    int? hlcOverride,
  }) =>
      _mint(
        authorId: authorNamespace.isEmpty ? this.id : authorNamespace,
        kind: OpKind.setAdd,
        table: table,
        entityId: id,
        field: memberUuid,
        value: value,
        contentKey: contentKey,
        hlcOverride: hlcOverride,
      );

  Operation mintSetRemove({
    required String table,
    required String id,
    required String memberUuid,
    required List<Dot> targetDots,
  }) {
    final authorId = this.id;
    final seq = _nextSeq(authorId);
    final hlc = _nextHlc();
    final op = Operation(
      authorId: authorId,
      authorSeq: seq,
      hlc: hlc,
      kind: OpKind.setRemove,
      entityTable: table,
      entityId: id,
      fieldName: memberUuid,
      targetDots: targetDots,
      frontier: _frontierSnapshot(authorId, seq),
    );
    apply(op);
    outbox.add(op);
    return op;
  }

  Operation _mint({
    required String authorId,
    required OpKind kind,
    required String table,
    required String entityId,
    required String? field,
    required dynamic value,
    String? contentKey,
    int? hlcOverride,
  }) {
    final seq = _nextSeq(authorId);
    final hlc = hlcOverride ?? _nextHlc();
    final op = Operation(
      authorId: authorId,
      authorSeq: seq,
      hlc: hlc,
      contentKey: contentKey,
      kind: kind,
      entityTable: table,
      entityId: entityId,
      fieldName: field,
      value: value,
      frontier: _frontierSnapshot(authorId, seq),
    );
    apply(op);
    outbox.add(op);
    return op;
  }

  // ---- causal comparator (causally_includes''') -----------------------

  bool causallyIncludes(Operation x, Operation y) {
    final ck = y.contentKey;
    if (ck != null) {
      final cls = contentKeyClass[ck];
      if (cls != null && cls.isNotEmpty) {
        final isGenesis = cls.keys.every((d) => isSeedAuthor(d.authorId));
        if (isGenesis) {
          for (final d in cls.keys) {
            if (dominates(x.frontier, d.authorId, d.authorSeq)) return true;
          }
          return false;
        }
      }
    }
    return dominates(x.frontier, y.dot.authorId, y.dot.authorSeq);
  }

  bool concurrent(Operation x, Operation y) =>
      !causallyIncludes(x, y) && !causallyIncludes(y, x);

  // ---- dot redirect resolution -----------------------------------------

  Dot resolveDot(Dot d) {
    var cur = d;
    final seen = <Dot>{};
    while (dotRedirects.containsKey(cur) && seen.add(cur)) {
      cur = dotRedirects[cur]!;
    }
    return cur;
  }

  // ---- apply -----------------------------------------------------------

  /// Applies a locally-minted or pulled operation. Idempotent: re-applying
  /// an already-known dot is a no-op.
  void apply(Operation op) {
    if (!_appliedDots.add(op.dot)) return; // already applied, idempotent no-op
    _allKnownOps[op.dot] = op;

    // Observation-based frontier update — happens unconditionally, before
    // dedup/materialization outcome is known (round 14's fix).
    final curHeight = frontier[op.authorId] ?? 0;
    if (op.authorSeq > curHeight) frontier[op.authorId] = op.authorSeq;

    bool skipMaterialize = false;
    Operation? recheckTrigger;

    final ck = op.contentKey;
    if (ck != null) {
      _dotContentKey[op.dot] = ck;
      final cls = contentKeyClass.putIfAbsent(ck, () => {});
      if (cls.containsKey(op.dot)) {
        return; // already fully processed, idempotent re-apply
      }
      cls[op.dot] = op;

      final existingCanonical = dedupIndex[ck];
      if (existingCanonical == null) {
        dedupIndex[ck] = op.dot; // first-seen member becomes canonical
      } else {
        final newCanonical = op.dot < existingCanonical ? op.dot : existingCanonical;
        if (newCanonical != existingCanonical) {
          dedupIndex[ck] = newCanonical;
          dotRedirects[existingCanonical] = newCanonical;
        } else {
          dotRedirects[op.dot] = newCanonical;
        }
        skipMaterialize = true; // dedup fast-path: never a live candidate
        // M0-simulation finding: recheck must fire for ANY contentKey
        // redirect, not only genesis-class ones. Genesis-only alias
        // expansion in `causallyIncludes` is sound (proven), but a
        // non-genesis class (e.g. an auto-merge write) can still contain
        // a member whose OWN frontier (same-author domination, no alias
        // expansion needed at all) proves a stale field-conflict decision
        // wrong — and since the dedup fast-path never lets that member
        // reach ordinary field-conflict comparison, nothing else ever
        // re-examines the decision. Passing the triggering op itself into
        // the recheck (below) is what actually supplies the missing
        // domination proof; genesis-class alias expansion was never the
        // only source of it.
        recheckTrigger = op;
      }
    }

    if (!skipMaterialize) {
      _materialize(op);
    }

    if (recheckTrigger != null) {
      _recomputeField(op.fieldKey, extraCandidate: recheckTrigger);
    }
  }

  void _materialize(Operation op) {
    switch (op.kind) {
      case OpKind.exists:
      case OpKind.field:
        _recomputeField(op.fieldKey, extraCandidate: op);
        break;
      case OpKind.setAdd:
        _materializeSetAdd(op);
        break;
      case OpKind.setRemove:
        _materializeSetRemove(op);
        break;
    }
  }

  void _materializeSetAdd(Operation op) {
    final key = '${op.entityTable}:${op.entityId}';
    final members = setState.putIfAbsent(key, () => {});
    members.putIfAbsent(op.fieldName!, () => {}).add(op.dot);
  }

  void _materializeSetRemove(Operation op) {
    final key = '${op.entityTable}:${op.entityId}';
    final members = setState[key];
    if (members == null) return;
    final dots = members[op.fieldName!];
    if (dots == null) return;
    for (final target in op.targetDots!) {
      final resolved = resolveDot(target);
      dots.removeWhere((d) => resolveDot(d) == resolved);
    }
  }

  bool setContains(String table, String id, String memberUuid) {
    final dots = setState['$table:$id']?[memberUuid];
    return dots != null && dots.isNotEmpty;
  }

  // ---- field-conflict (re)computation, unified and order-independent ----

  /// All locally-known members of the alias group a resolved (canonical)
  /// dot belongs to. A second M0-simulation finding: comparing group
  /// identity via a single arbitrary representative (e.g. always
  /// preferring "whichever op IS the canonical dot") can silently discard
  /// the *specific* alias whose frontier is what actually proves a
  /// domination — concretely, a device's own later, canonical-losing
  /// auto-merge write can have a frontier that trivially dominates an
  /// intervening same-device write (same-author sequencing), while the
  /// lexicographically-canonical alias (minted by a different, earlier-
  /// observing device) cannot. Picking only the canonical representative
  /// for comparison purposes threw that proof away. Using every known
  /// alias — via the permanent `_allKnownOps` registry, never pruned even
  /// once an alias stops being separately tracked in fieldState/
  /// conflictCopies — recovers it.
  List<Operation> _groupMembers(Dot canon) {
    final ck = _dotContentKey[canon];
    if (ck != null) {
      final members = contentKeyClass[ck]?.values;
      if (members != null && members.isNotEmpty) return members.toList();
    }
    final op = _allKnownOps[canon];
    return op != null ? [op] : const [];
  }

  /// The union of every known alias's frontier in a group — per-author
  /// MAX height across all aliases. A third M0-simulation finding: naive
  /// "does ANY member of A dominate ANY member of B" existential matching
  /// is NOT transitive/acyclic across groups, even though the underlying
  /// per-operation Theorem is — because a single contentKey group can
  /// itself span a causal *range* (its earliest alias to its latest), so
  /// "any-vs-any" can find A-dominates-B via A's latest alias *and*
  /// B-dominates-A via B's own latest alias simultaneously, a genuine
  /// cross-group cycle the per-operation Theorem never needed to rule out
  /// (it assumes a single, one-shot frontier per side). Collapsing each
  /// group to the UNION of everything any of its aliases had ever
  /// observed restores a well-defined, order-independent SINGLE frontier
  /// per group — the group's true combined causal knowledge — without
  /// discarding any alias's individual contribution the way picking one
  /// arbitrary representative did (§ `_groupMembers`'s doc comment).
  Map<String, int> _unionFrontier(Dot canon) {
    final union = <String, int>{};
    for (final op in _groupMembers(canon)) {
      op.frontier.forEach((author, height) {
        final cur = union[author];
        if (cur == null || height > cur) union[author] = height;
      });
    }
    return union;
  }

  /// Does alias-group [a]'s UNION frontier causally include [b]'s
  /// canonical dot (or, when [b]'s own class is genesis, any witness in
  /// it — reusing `causallyIncludes`'s existing alias-expansion by
  /// comparing against `_representative(b)`, which is always a real,
  /// locally-known operation, § `_groupMembers`). Comparisons are only
  /// ever made ACROSS distinct resolved identities (`a != b`), matching
  /// the no-cyclic-domination Theorem's own non-aliased hypothesis and the
  /// Exclusion Lemma's guarantee — members WITHIN one group (true aliases
  /// of each other) are never compared against each other, which is what
  /// a naive single-representative comparison risked doing (§ the
  /// M0-simulation finding on trivial self-domination, `_recomputeField`'s
  /// earlier revision).
  bool _groupDominates(Dot a, Dot b) {
    if (a == b) return false;
    final unionA = _unionFrontier(a);
    for (final y in _groupMembers(b)) {
      if (dominates(unionA, y.dot.authorId, y.dot.authorSeq)) return true;
    }
    return false;
  }

  Operation _representative(Dot canon) {
    final direct = _allKnownOps[canon];
    if (direct != null) return direct;
    return _groupMembers(canon).first;
  }

  /// The single, order-independent field-conflict resolution routine —
  /// used both for ordinary materialization (every `field`/`exists` write,
  /// [extraCandidate] being the just-arrived op) and for recheck-on-
  /// discovery (fired whenever a contentKey redirect is newly learned,
  /// [extraCandidate] being the just-arrived, dedup-absorbed op the fast
  /// path would otherwise hide from comparison entirely — an M0-simulation
  /// finding: for a non-genesis contentKey class, that operation's own
  /// frontier, not alias expansion — which is genesis-only — is what
  /// supplies the missing domination proof).
  ///
  /// Recomputes the winner over the WHOLE known set of resolved identities
  /// (`canons`) at once, as a pure function of the set (order-independent
  /// by construction) — never an incremental pairwise fold (new-arrival-
  /// vs-current-winner, one at a time), which an M0-simulation finding
  /// showed is NOT order-independent in general: the combined relation
  /// "dominates, else HLC tie-break" is not transitive, so three
  /// operations A, B, C on the same field (B causally dominates A; A and C
  /// concurrent, A wins their tie-break; B and C ALSO concurrent, C wins
  /// THEIR tie-break) form a genuine pairwise cycle whenever two replicas'
  /// HLCs collide — which the authorId secondary tie-break exists
  /// precisely to handle, so it cannot be assumed rare enough to ignore.
  /// Fix: first restrict to the *maximal* identities — those not dominated
  /// (via `_groupDominates`) by any other identity in the set (well-defined
  /// and order-independent, since causal domination is a proven-acyclic
  /// partial order among genuinely distinct, non-aliased operations) —
  /// then, only among that maximal set, break any remaining tie via the
  /// ordinary total (hlc, authorId, authorSeq) order. A dominated
  /// candidate can never be the answer regardless of what it might win a
  /// pairwise HLC tie-break against, which is exactly what breaks the
  /// cycle above: A is excluded up front (dominated by B), so the real
  /// contest is only between B and C.
  ///
  /// Then reclassifies every other identity against the recomputed
  /// winner, discarding (never re-filing) a proven causal ancestor.
  void _recomputeField(String key, {Operation? extraCandidate}) {
    final history = _fieldHistory.putIfAbsent(key, () => {});
    final current = fieldState[key];
    if (current != null) history.add(current.dot);
    for (final loser in conflictCopies[key] ?? const <ConflictCopy>[]) {
      history.add(loser.dot);
    }
    if (extraCandidate != null) history.add(extraCandidate.dot);
    if (history.isEmpty) return;

    // Recompute over the FULL retained history (§ `_fieldHistory`'s doc
    // comment), not just the current winner and live conflict-copies —
    // a discarded dominated ancestor can be the only witness that proves
    // a later-arriving operation is ALSO dominated, transitively.
    final canons = history.map(resolveDot).toSet().toList();
    if (canons.length == 1) {
      fieldState[key] = _representative(canons.single);
      conflictCopies.remove(key);
      return;
    }

    // Round 20 M0-simulation finding: naive pairwise "maximal" filtering
    // via `_groupDominates` (the pre-round-20 version of this method) is
    // itself unsound once candidates are alias GROUPS rather than single
    // real operations — two different groups can mutually "dominate"
    // each other (via their unioned frontiers) even though no individual
    // alias pair does, and the old defensive `maximal.isEmpty` fallback
    // would then silently discard one of them as a "proven ancestor,"
    // real and untraceable data loss. Fix: a proper SCC (strongly-
    // connected-component) condensation of the `_groupDominates` graph,
    // in two independently-verified parts — SCC condensation for WINNER
    // SELECTION (this part alone), and a separate, more conservative rule
    // for the DISCARD decision (below).
    final n = canons.length;
    final dom = List.generate(n, (_) => List<bool>.filled(n, false));
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (i != j && _groupDominates(canons[i], canons[j])) dom[i][j] = true;
      }
    }

    // Transitive closure (Floyd-Warshall; candidate counts here are always
    // small) to assign each candidate an SCC id via mutual reachability.
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

    // SCC condensation of ANY directed graph is provably a DAG (if two
    // distinct SCCs were mutually reachable they would, by definition,
    // already be one SCC) — so `maximalSccs` is always non-empty, and the
    // pre-round-20 `maximal.isEmpty` defensive fallback is retired as
    // genuinely unreachable, not merely empirically rare.
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
        if (!List.generate(sccCount, (o) => o).any((other) => other != s && sccDominates(other, s)))
          s,
    };
    final poolIndices = [
      for (var i = 0; i < n; i++)
        if (maximalSccs.contains(sccId[i])) i,
    ];
    var bestIdx = poolIndices.first;
    for (final idx in poolIndices.skip(1)) {
      if (hlcTieBreakWins(_representative(canons[idx]), _representative(canons[bestIdx]))) {
        bestIdx = idx;
      }
    }
    final finalWinner = _representative(canons[bestIdx]);
    final winnerScc = sccId[bestIdx];

    // Discard decision, corrected after adversarial review found the
    // natural "discard every member of a dominated SCC" rule unsound (it
    // can discard a candidate whose only proof-path runs through an
    // unrelated alias of some OTHER member of its own SCC, a fact that
    // has nothing to do with the winner). `chainDom(w, i)`: true iff a
    // path from `w` to `i` exists in `dom` whose INTERMEDIATE nodes
    // (strictly between the two endpoints) are all SINGLETON groups —
    // sound for chains of genuinely distinct, non-aliased operations
    // (finding 4's Theorem, extended by a Transitivity Corollary — see
    // plan), unsound as a pass-through for a multi-member alias group,
    // since a group's `dom` edges are union-frontier facts that can
    // conflate independent aliases' knowledge. Singleton status is
    // evaluated fresh on every call (group membership changes on every
    // contentKey-redirect discovery), never cached.
    bool isSingleton(int idx) => _groupMembers(canons[idx]).length == 1;
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
    // discard-eligible: mutual reachability within `winnerScc` is exactly
    // the premise that neither member is a proven ancestor of the other
    // — this guard is what stops a direct mutual-domination pair (e.g.
    // "the bug" this whole fix targets) from reproducing itself via
    // `chainDom`'s vacuous zero-hop case. Only a candidate OUTSIDE
    // `winnerScc`, reachable from some `winnerScc` member via a
    // singleton-witnessed chain, is discarded.
    final winnerSccMembers = [
      for (var i = 0; i < n; i++) if (sccId[i] == winnerScc) i,
    ];
    final discardable = <int>{};
    for (final w in winnerSccMembers) {
      discardable.addAll(chainDomReachable(w));
    }

    final retained = <ConflictCopy>[];
    for (var i = 0; i < n; i++) {
      if (i == bestIdx) continue;
      if (sccId[i] != winnerScc && discardable.contains(i)) continue; // proven ancestor: discard
      retained.add(_representative(canons[i]));
    }

    fieldState[key] = finalWinner;
    conflictCopies[key] = retained;
  }

  // ---- convenience reads -------------------------------------------------

  T? fieldValue<T>(String table, String id, String field) {
    final op = fieldState['$table:$id:$field'];
    return op?.value as T?;
  }

  /// Looks up the full operation behind any dot this replica has ever
  /// applied, of any kind — the general permanent-registry read backing
  /// per-set-member metadata (e.g. a conversation-message mapping's
  /// `createdAtMillis`, `conversation_ops.dart`) that OR-Set
  /// materialization itself doesn't retain anywhere else (`setState` only
  /// ever stores the bare dot, never the operation it came from — see
  /// `_materializeSetAdd`). Returns null for a dot this replica has never
  /// observed at all.
  Operation? operationForDot(Dot dot) => _allKnownOps[dot];
}
