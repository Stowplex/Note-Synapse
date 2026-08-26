// Tag identity, merge, cycle-suppression, name-collision auto-merge, and
// purge-eligibility machinery (§ Architecture 10 of the plan). Built on
// top of a `Replica` — tags.name/__deleted__/redirectTarget and
// tag_images.imagePath are ordinary fields routed through the same
// causal comparator / contentKey dedup / field-conflict resolution as
// everything else.

import 'model.dart';
import 'replica.dart';

/// Derived effective state for every known tag on a replica, per the
/// three-branch formula corrected in round 18 (redirect-authoritative,
/// no longer assuming permanent raw tombstone/redirect coupling).
class EffectiveTagState {
  final Map<String, String?> effectiveRedirectTarget;
  final Map<String, bool> effectiveDeleted;
  final Set<String> cycleLosers;

  EffectiveTagState(this.effectiveRedirectTarget, this.effectiveDeleted, this.cycleLosers);
}

class TagEngine {
  final Replica replica;
  int _tagCounter = 0;

  TagEngine(this.replica);

  // ---- raw reads ---------------------------------------------------------

  bool rawDeleted(String tagId) =>
      replica.fieldValue<bool>('tags', tagId, '__deleted__') ?? false;

  String? rawRedirectTarget(String tagId) =>
      replica.fieldValue<String>('tags', tagId, 'redirectTarget');

  String? tagName(String tagId) {
    final existsVal =
        replica.fieldState['tags:$tagId:__exists__']?.value as Map?;
    return existsVal?['name'] as String?;
  }

  Dot? creationDot(String tagId) => replica.fieldState['tags:$tagId:__exists__']?.dot;

  Set<String> get allTagIds {
    final ids = <String>{};
    for (final key in replica.fieldState.keys) {
      if (key.startsWith('tags:') && key.endsWith(':__exists__')) {
        ids.add(key.substring('tags:'.length, key.length - ':__exists__'.length));
      }
    }
    return ids;
  }

  // ---- creation / merge / restore / undelete -----------------------------

  /// Creates a brand-new tag (ordinary random identity, unchanged from
  /// current app behavior — round 18 retracts name-derived deterministic
  /// UUIDs). Runs the write-path collision guard before returning.
  String createTag(String name, {String color = 'blue'}) {
    final newId = '${replica.id}-tag-${_tagCounter++}';
    replica.mintExists(table: 'tags', id: newId, value: {'name': name, 'color': color});
    replica.mintField(table: 'tags', id: newId, field: '__deleted__', value: false);
    replica.mintField(table: 'tags', id: newId, field: 'redirectTarget', value: null);
    resolveAllNameCollisions();
    return newId;
  }

  /// Ordinary, user-initiated tagMerge(from, to) — two sequential, ordinary
  /// field writes. No contentKey: a single user action mints this once,
  /// unlike auto-merge, which independent detectors may mint redundantly.
  void tagMerge(String fromId, String toId) {
    replica.mintField(table: 'tags', id: fromId, field: 'redirectTarget', value: toId);
    replica.mintField(table: 'tags', id: fromId, field: '__deleted__', value: true);
  }

  /// The tag-specific "restore a merge" action: explicitly clears both
  /// fields (a plain single-field undelete is insufficient by design,
  /// § Architecture 10). Write-driven — runs the same collision-resolution
  /// pass as creation before its own writes are considered final.
  void restoreTag(String tagId) {
    replica.mintField(table: 'tags', id: tagId, field: '__deleted__', value: false);
    replica.mintField(table: 'tags', id: tagId, field: 'redirectTarget', value: null);
    resolveAllNameCollisions();
  }

  /// Generic entity undelete (§ Architecture 6), applicable to any
  /// tombstoned entity including tags — writes only `__deleted__=false`,
  /// never touches `redirectTarget`. Also write-driven; also guarded
  /// (round 18, eighth leader-review pass: the guard is a property of the
  /// write path, not an enumerable list of named actions).
  void genericUndelete(String tagId) {
    replica.mintField(table: 'tags', id: tagId, field: '__deleted__', value: false);
    resolveAllNameCollisions();
  }

  /// The general, uniformly-invoked collision-resolution pass — one step
  /// of the effective-tag-state walk (§ Architecture 10's "two categories
  /// of liveness-flipping event"), covering every way a tag's raw state
  /// can leave two effectively-live tags sharing a name: write-driven
  /// transitions call this immediately after their own write (creation,
  /// restore, generic undelete, above), and pulling a remote replica's
  /// operations should call this too (§ Simulator.syncFull/syncPartial) —
  /// covering the "incoming `__exists__` collides with an already-live
  /// local tag" case the original, narrower per-action guard missed, and
  /// the cycle-suppression-revival case that can never be tied to a
  /// discrete local write at all. Idempotent and order-independent:
  /// repeatedly callable, only mints a write pair where raw state doesn't
  /// already reflect the resolution.
  void resolveAllNameCollisions() {
    final state = computeEffectiveState();
    final byName = <String, List<String>>{};
    for (final id in allTagIds) {
      if (state.effectiveDeleted[id] != false) continue;
      final name = tagName(id);
      if (name == null) continue;
      byName.putIfAbsent(name, () => []).add(id);
    }
    for (final group in byName.values) {
      if (group.length <= 1) continue;
      group.sort((a, b) => creationDot(a)!.compareTo(creationDot(b)!));
      final winnerId = group.first;
      for (final loserId in group.skip(1)) {
        _mintAutoMergeWritePair(loserId, winnerId);
      }
    }
  }

  void _mintAutoMergeWritePair(String loserId, String winnerId) {
    // Already resolved (e.g. a prior identical-outcome auto-merge from
    // another replica already landed and materialized here)? No-op.
    if (rawRedirectTarget(loserId) == winnerId) return;

    // M0-simulation finding: a bare `(loserId, winnerId)` contentKey — no
    // "generation" component — conflates every instance of this pair ever
    // colliding as "the same event," across time. This is unsound whenever
    // a tag is restored after an earlier auto-merge and then collides with
    // the SAME winner again: the second, causally-later auto-merge attempt
    // shares the first attempt's contentKey, so contentKey dedup discards
    // it in favor of the now-STALE first attempt's frontier — exactly the
    // "value cycling" hazard `baseContext` exists to prevent for
    // seed/external-edit contentKeys (§ Architecture 1), left unaddressed
    // here at design time and confirmed reachable by randomized
    // simulation (repeated restore-then-recollide cycles). Fix: include
    // the specific write that made this tag collide-eligible again (its
    // current `__deleted__`/`__exists__` dot) as a generation marker, so
    // each restore-then-recollide cycle gets a genuinely distinct
    // contentKey rather than reusing the first attempt's.
    final trigger = replica.fieldState['tags:$loserId:__deleted__'] ??
        replica.fieldState['tags:$loserId:__exists__'];
    final generation = trigger?.dot.toString() ?? '';

    replica.mintField(
      table: 'tags',
      id: loserId,
      field: 'redirectTarget',
      value: winnerId,
      contentKey: 'autoTagMerge:redirectTarget:$loserId:$winnerId:$generation',
    );
    replica.mintField(
      table: 'tags',
      id: loserId,
      field: '__deleted__',
      value: true,
      contentKey: 'autoTagMerge:deleted:$loserId:$generation',
    );
  }

  String? _findEffectivelyLiveByName(String name, EffectiveTagState state, {required String excluding}) {
    for (final id in allTagIds) {
      if (id == excluding) continue;
      if (state.effectiveDeleted[id] == false && tagName(id) == name) return id;
    }
    return null;
  }

  // ---- derived effective state: three-state cycle-suppression walk ------

  /// Computes effective_redirectTarget/effective___deleted__ via the
  /// single-pass white/gray/black functional-graph walk, then — as one
  /// more step of the same pass — resolves any residual same-name
  /// collision among the walk's resulting effectively-live tags (the
  /// self-healing catch-up for cycle-suppression revival, § Architecture
  /// 10's "two categories of liveness-flipping event").
  EffectiveTagState computeEffectiveState() {
    final ids = allTagIds.toList();
    final rawTarget = {for (final id in ids) id: rawRedirectTarget(id)};
    final rawDel = {for (final id in ids) id: rawDeleted(id)};

    final color = <String, int>{}; // 0 implicit(white), 1=gray, 2=black
    final loserSet = <String>{};

    for (final start in ids) {
      if ((color[start] ?? 0) != 0) continue;
      final path = <String>[];
      var cur = start;
      while (true) {
        final c = color[cur] ?? 0;
        if (c == 2) break; // merges into an already-resolved chain
        if (c == 1) {
          final idx = path.indexOf(cur);
          final cycle = path.sublist(idx);
          _suppressLowestRankedEdge(cycle, loserSet);
          break;
        }
        color[cur] = 1;
        path.add(cur);
        final next = rawTarget[cur];
        if (next == null || !ids.contains(next)) break;
        cur = next;
      }
      for (final n in path) {
        color[n] = 2;
      }
    }

    final effRedirect = <String, String?>{};
    final effDeleted = <String, bool>{};
    for (final id in ids) {
      if (loserSet.contains(id)) {
        effRedirect[id] = null;
        effDeleted[id] = false;
      } else {
        effRedirect[id] = rawTarget[id];
        effDeleted[id] = rawTarget[id] != null ? true : rawDel[id]!;
      }
    }
    return EffectiveTagState(effRedirect, effDeleted, loserSet);
  }

  void _suppressLowestRankedEdge(List<String> cycle, Set<String> loserSet) {
    String? loser;
    Operation? loserOp;
    for (final from in cycle) {
      final redirectOp = replica.fieldState['tags:$from:redirectTarget'];
      if (redirectOp == null) continue;
      if (loserOp == null || !hlcTieBreakWins(redirectOp, loserOp)) {
        loserOp = redirectOp;
        loser = from;
      }
    }
    if (loser != null) loserSet.add(loser);
  }

  /// A locally-recomputed, non-synced display cache for cycle-loser
  /// renames and auto-merges — mirrors the `'rejected_merge'`/
  /// `'auto_tag_merge'` `sync_conflict_copies` rows described in the plan.
  /// Exposed here purely so tests can assert on it.
  List<String> cycleLoserIds() => computeEffectiveState().cycleLosers.toList();

  // ---- image / AI-config derivation --------------------------------------

  String? effectiveImagePath(String tagId, [EffectiveTagState? precomputed]) {
    final state = precomputed ?? computeEffectiveState();
    final direct = replica.fieldValue<String>('tag_images', tagId, 'imagePath');
    if (direct != null) return direct;
    final sources = _inboundSources(tagId, state);
    if (sources.isEmpty) return null;
    sources.sort((a, b) {
      final opA = replica.fieldState['tags:$a:redirectTarget'];
      final opB = replica.fieldState['tags:$b:redirectTarget'];
      if (opA == null || opB == null) return 0;
      return hlcTieBreakWins(opA, opB) ? -1 : 1;
    });
    for (final s in sources) {
      final v = replica.fieldValue<String>('tag_images', s, 'imagePath');
      if (v != null) return v;
    }
    return null;
  }

  /// Every tag whose effective_redirectTarget chain resolves (directly or
  /// transitively) to [tagId].
  List<String> _inboundSources(String tagId, EffectiveTagState state) {
    final result = <String>[];
    for (final id in allTagIds) {
      if (id == tagId) continue;
      var cur = id;
      final seen = <String>{};
      while (state.effectiveRedirectTarget[cur] != null && seen.add(cur)) {
        cur = state.effectiveRedirectTarget[cur]!;
      }
      if (cur == tagId) result.add(id);
    }
    return result;
  }

  // ---- purge eligibility --------------------------------------------------

  /// A tombstoned tag's underlying row data is purge-eligible only if none
  /// of the three composed checks (§ Architecture 10, rounds 17-18) find a
  /// live dependent: an inbound raw redirect edge (protects merge-chain
  /// hops), a live membership reference (protects the chain's root), or
  /// being a live tag's currently-chosen inherited image/AI-config source.
  bool tagPurgeEligible(String tagId) {
    final state = computeEffectiveState();
    if (state.effectiveDeleted[tagId] != true) return false;

    for (final other in allTagIds) {
      if (other == tagId) continue;
      if (rawRedirectTarget(other) == tagId) return false; // check 1
    }
    if (replica.hasLiveMembershipReference(tagId)) return false; // check 2

    for (final id in allTagIds) {
      if (state.effectiveDeleted[id] == false &&
          replica.fieldValue<String>('tag_images', id, 'imagePath') == null &&
          _inboundSources(id, state).isNotEmpty) {
        // id inherits an image; is tagId its chosen (first, by tie-break) source?
        final sources = _inboundSources(id, state);
        sources.sort((a, b) {
          final opA = replica.fieldState['tags:$a:redirectTarget'];
          final opB = replica.fieldState['tags:$b:redirectTarget'];
          if (opA == null || opB == null) return 0;
          return hlcTieBreakWins(opA, opB) ? -1 : 1;
        });
        for (final s in sources) {
          if (replica.fieldValue<String>('tag_images', s, 'imagePath') != null) {
            if (s == tagId) return false; // check 3
            break; // found the chosen source, and it isn't tagId
          }
        }
      }
    }
    return true;
  }
}
