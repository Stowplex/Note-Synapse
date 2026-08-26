// Network simulation harness: random device graphs, full and partial
// (mid-sync-interruption) pull ordering, and shared invariant checks used
// by both the regression suite and the randomized/exhaustive suites.

import 'dart:math';

import 'app_ops.dart';
import 'model.dart';
import 'replica.dart';
import 'tag_ops.dart';

class Simulator {
  final Map<String, Replica> replicas = {};
  final Random random;

  Simulator({int? seed}) : random = Random(seed);

  /// The simulator's only notion of time: a simple integer tick/generation
  /// counter used by the grace-period GC mechanism (`gc.dart`, §
  /// Architecture 4/6). There is no real wall-clock concept anywhere in
  /// this simulator — this advances only on an explicit call, never on
  /// its own.
  int tick = 0;

  void advanceTick([int by = 1]) => tick += by;

  /// Log-pruning generations (certificate-construction ticks) that have
  /// actually been physically pruned — used by tests to assert log
  /// pruning did or didn't proceed.
  final Set<int> prunedLogGenerations = {};

  Replica addReplica(String id) {
    final r = Replica(id);
    replicas[id] = r;
    return r;
  }

  /// Delivers every operation in [from]'s outbox that [to] hasn't yet
  /// observed, in outbox order (preserves per-authorId ordering, i.e.
  /// never skips a gap for any single author). Runs the tag
  /// collision-resolution pass afterward — the walk-based catch-up that
  /// covers an incoming `__exists__` colliding with an already-live local
  /// tag, and any cycle-suppression revival, per § Architecture 10.
  void syncFull(Replica from, Replica to) {
    for (final op in from.outbox) {
      to.apply(op);
    }
    TagEngine(to).resolveAllNameCollisions();
  }

  /// Delivers a random-length prefix of each author's pending operations
  /// — simulates a sync interrupted partway through, still honoring the
  /// no-gap-skipping invariant per author.
  void syncPartial(Replica from, Replica to) {
    final byAuthor = <String, List<Operation>>{};
    for (final op in from.outbox) {
      byAuthor.putIfAbsent(op.authorId, () => []).add(op);
    }
    for (final entry in byAuthor.entries) {
      final already = to.frontier[entry.key] ?? 0;
      final pending = entry.value.where((op) => op.authorSeq > already).toList();
      if (pending.isEmpty) continue;
      final n = 1 + random.nextInt(pending.length);
      for (var i = 0; i < n; i++) {
        to.apply(pending[i]);
      }
    }
    TagEngine(to).resolveAllNameCollisions();
  }

  /// All-pairs full sync, repeated until every replica's outbox length is
  /// reflected in every other replica's frontier — i.e. full convergence.
  void syncAllToAll({int rounds = 3}) {
    final all = replicas.values.toList();
    for (var r = 0; r < rounds; r++) {
      for (final a in all) {
        for (final b in all) {
          if (a == b) continue;
          syncFull(a, b);
        }
      }
    }
  }

  Replica pickRandom() => replicas.values.elementAt(random.nextInt(replicas.length));
}

// ---- shared invariant checks ---------------------------------------------

/// After full convergence, every replica must materialize the identical
/// value for every field it has observed (fieldState winners agree).
void assertFieldStateConverged(Iterable<Replica> replicas) {
  final all = replicas.toList();
  if (all.length < 2) return;
  final keys = <String>{};
  for (final r in all) {
    keys.addAll(r.fieldState.keys);
  }
  for (final key in keys) {
    final values = <dynamic>{};
    for (final r in all) {
      final op = r.fieldState[key];
      if (op != null) values.add(op.value);
    }
    if (values.length > 1) {
      throw StateError('Field $key did not converge: $values');
    }
  }
}

/// No two effectively-live tags may share an exact name on any replica —
/// the invariant the partial-unique-index + auto-merge mechanism exists
/// to guarantee.
void assertNoLiveTagNameCollision(Replica replica) {
  final engine = TagEngine(replica);
  final state = engine.computeEffectiveState();
  final seen = <String, String>{};
  for (final id in engine.allTagIds) {
    if (state.effectiveDeleted[id] != false) continue;
    final name = engine.tagName(id);
    if (name == null) continue;
    if (seen.containsKey(name)) {
      throw StateError(
          'Replica ${replica.id}: tags $id and ${seen[name]} are both effectively live with name "$name"');
    }
    seen[name] = id;
  }
}

/// After full convergence, every replica must compute the identical
/// effective-visibility state for User App revisions — same set of
/// effectively-deleted revisions, and the same fallback (or lack thereof)
/// per app — regardless of the order operations were pulled in (§
/// Architecture 10's User App visibility fix, `app_ops.dart`).
void assertAppVisibilityConverged(Iterable<Replica> replicas) {
  final all = replicas.toList();
  if (all.length < 2) return;
  final states = {for (final r in all) r.id: AppEngine(r).computeEffectiveState()};

  final revisionIds = <String>{};
  final appIds = <String>{};
  for (final r in all) {
    final engine = AppEngine(r);
    revisionIds.addAll(engine.allRevisionIds);
    appIds.addAll(engine.allAppIds);
  }

  for (final revisionId in revisionIds) {
    final values = <bool>{};
    for (final r in all) {
      final state = states[r.id]!;
      if (state.effectiveRevisionDeleted.containsKey(revisionId)) {
        values.add(state.effectiveRevisionDeleted[revisionId]!);
      }
    }
    if (values.length > 1) {
      throw StateError('Revision $revisionId effective-deletedness did not converge: $values');
    }
  }

  for (final appId in appIds) {
    final values = <String?>{};
    var anyKnows = false;
    for (final r in all) {
      final state = states[r.id]!;
      if (state.fallbackRevisionForApp.containsKey(appId)) {
        anyKnows = true;
        values.add(state.fallbackRevisionForApp[appId]);
      }
    }
    if (anyKnows && values.length > 1) {
      throw StateError('App $appId fallback revision did not converge: $values');
    }
  }
}

/// No `sync_conflict_copies('field_conflict')` record should ever be a
/// causal ancestor of its field's current winner (the class of bug
/// recheck-on-discovery exists to eliminate).
void assertNoStaleConflictCopies(Replica replica) {
  for (final entry in replica.conflictCopies.entries) {
    final winner = replica.fieldState[entry.key];
    if (winner == null) continue;
    for (final loser in entry.value) {
      if (replica.causallyIncludes(winner, loser)) {
        throw StateError(
            'Replica ${replica.id}: conflict copy ${loser.dot} on ${entry.key} is a proven causal ancestor of winner ${winner.dot} — should have been discarded, not retained');
      }
    }
  }
}
