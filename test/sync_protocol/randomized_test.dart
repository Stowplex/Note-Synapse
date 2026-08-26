// Randomized simulation: many random device/operation/sync-order
// sequences, checking convergence and safety invariants after each run.
// Complements exhaustive_test.dart's small, fully-enumerated
// configurations with broad, shallow coverage over larger, more varied
// scenarios.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'app_ops.dart';
import 'gc.dart';
import 'simulator.dart';
import 'tag_ops.dart';

const _tagNames = ['urgent', 'important', 'critical', 'someday', 'work'];

void _runRandomScenario(int seed) {
  final sim = Simulator(seed: seed);
  final random = Random(seed * 7919 + 1);
  final deviceCount = 2 + random.nextInt(3); // 2-4 devices
  final devices = List.generate(deviceCount, (i) => sim.addReplica('D$i'));
  final engines = {for (final d in devices) d.id: TagEngine(d)};
  final createdTags = <String>[];

  final stepCount = 10 + random.nextInt(20);
  for (var step = 0; step < stepCount; step++) {
    final device = devices[random.nextInt(devices.length)];
    final engine = engines[device.id]!;
    final action = random.nextInt(6);
    switch (action) {
      case 0: // create a tag with a random (possibly colliding) name
        final name = _tagNames[random.nextInt(_tagNames.length)];
        createdTags.add(engine.createTag(name));
        break;
      case 1: // manual merge of two known tags on this device
        if (createdTags.length >= 2) {
          final from = createdTags[random.nextInt(createdTags.length)];
          final to = createdTags[random.nextInt(createdTags.length)];
          if (from != to) engine.tagMerge(from, to);
        }
        break;
      case 2: // restore a random tag
        if (createdTags.isNotEmpty) {
          engine.restoreTag(createdTags[random.nextInt(createdTags.length)]);
        }
        break;
      case 3: // generic undelete of a random tag
        if (createdTags.isNotEmpty) {
          engine.genericUndelete(createdTags[random.nextInt(createdTags.length)]);
        }
        break;
      case 4: // partial sync between two random devices
        if (devices.length >= 2) {
          final a = devices[random.nextInt(devices.length)];
          final b = devices[random.nextInt(devices.length)];
          if (a != b) sim.syncPartial(a, b);
        }
        break;
      case 5: // set an image on a random tag
        if (createdTags.isNotEmpty) {
          final t = createdTags[random.nextInt(createdTags.length)];
          device.mintField(table: 'tag_images', id: t, field: 'imagePath', value: '/img/$t.png');
        }
        break;
    }
  }

  sim.syncAllToAll(rounds: 4);
  for (final d in devices) {
    TagEngine(d).resolveAllNameCollisions();
  }
  sim.syncAllToAll(rounds: 2);

  for (final d in devices) {
    assertNoLiveTagNameCollision(d);
    assertNoStaleConflictCopies(d);
  }
  assertFieldStateConverged(devices);
}

/// Randomized fuzzing of blob GC's grace-period/fresh-recheck mechanism
/// (§ Architecture 4/6, `gc.dart`): random interleavings of
/// unreference/re-reference/tick-advance/evaluate actions, checking the
/// core safety invariant directly rather than any single fixed scenario —
/// a blob that is CURRENTLY referenced at the moment of a fresh recheck
/// must never be reported eligible for removal, regardless of how it got
/// there (how many times it was previously un/re-referenced, how the
/// grace-period ticks landed relative to those events).
void _runGcRandomScenario(int seed) {
  final sim = Simulator(seed: seed);
  final d1 = sim.addReplica('D1');
  final gc = BlobGcEngine(d1);
  final random = Random(seed * 104729 + 7);

  const hashes = ['H1', 'H2', 'H3'];
  for (final h in hashes) {
    d1.uploadBlob(h);
  }
  final candidates = <String, GcCandidate?>{};

  final stepCount = 15 + random.nextInt(20);
  for (var step = 0; step < stepCount; step++) {
    final hash = hashes[random.nextInt(hashes.length)];
    switch (random.nextInt(4)) {
      case 0: // becomes absent from the consolidated state -> candidate
        d1.unreferenceBlob(hash);
        final snap = gc.certify(sim.tick);
        candidates[hash] = gc.considerCandidate(hash, snap, existing: candidates[hash]);
        break;
      case 1: // a legitimate new reference arrives
        d1.referenceBlob(hash);
        break;
      case 2: // time passes
        sim.advanceTick(1 + random.nextInt(6));
        break;
      case 3: // a GC sweep evaluates (and prunes if eligible)
        final candidate = candidates[hash];
        if (candidate == null) break;
        final latest = gc.certify(sim.tick);
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick, latestSnapshot: latest);
        if (d1.referencedBlobHashes.contains(hash)) {
          expect(outcome, isNot(GcOutcome.eligibleForRemoval),
              reason: 'seed=$seed step=$step: a currently-referenced blob must never be reported GC-eligible');
        }
        final pruned = gc.pruneIfEligible(hash, outcome);
        if (pruned) {
          expect(d1.referencedBlobHashes.contains(hash), isFalse,
              reason: 'seed=$seed: pruneIfEligible must never remove a referenced blob');
          candidates.remove(hash);
        } else if (outcome == GcOutcome.unCandidated) {
          candidates.remove(hash); // spent — a future absence starts a fresh candidacy
        }
        break;
    }
  }
}

/// Randomized fuzzing of orphan-message cleanup's grace-period/fresh-
/// recheck mechanism (§ Architecture 6, `gc.dart`): random interleavings
/// of tombstone/add-membership/remove-membership/tick-advance/evaluate
/// actions, checking the core safety invariant directly — a message with
/// a CURRENTLY live membership reference at the moment of a fresh recheck
/// must never be reported eligible for removal, regardless of raw
/// tombstone state or the order tombstone-vs-membership writes arrived in
/// (the exact race the effective-vs-raw-deletedness fix exists to close).
void _runMessageGcRandomScenario(int seed) {
  final sim = Simulator(seed: seed);
  final d1 = sim.addReplica('D1');
  final gc = MessageGcEngine(d1);
  final random = Random(seed * 15485863 + 11);

  const messageIds = ['M1', 'M2', 'M3'];
  final candidates = <String, GcCandidate?>{};

  final stepCount = 15 + random.nextInt(20);
  for (var step = 0; step < stepCount; step++) {
    final id = messageIds[random.nextInt(messageIds.length)];
    switch (random.nextInt(5)) {
      case 0: // raw tombstone (idempotent re-write is harmless)
        d1.mintField(table: 'message', id: id, field: '__deleted__', value: true);
        candidates[id] = gc.considerCandidate(id, sim.tick, existing: candidates[id]);
        break;
      case 1: // a live membership reference arrives
        d1.addMembershipRef('conv-1', id);
        break;
      case 2: // the membership reference is removed
        d1.removeMembershipRef('conv-1', id);
        break;
      case 3: // time passes
        sim.advanceTick(1 + random.nextInt(6));
        break;
      case 4: // a GC sweep evaluates (and prunes if eligible)
        final candidate = candidates[id];
        if (candidate == null) break;
        final outcome = gc.evaluate(candidate: candidate, currentTick: sim.tick);
        if (d1.hasLiveMembershipReference(id)) {
          expect(outcome, isNot(GcOutcome.eligibleForRemoval),
              reason: 'seed=$seed step=$step: a message with a live membership reference must never be GC-eligible');
        }
        final pruned = gc.pruneIfEligible(id, outcome);
        if (pruned) {
          expect(d1.hasLiveMembershipReference(id), isFalse,
              reason: 'seed=$seed: pruneIfEligible must never remove a message with a live membership reference');
          candidates.remove(id);
        } else if (outcome == GcOutcome.unCandidated) {
          candidates.remove(id);
        }
        break;
    }
  }
}

/// Randomized fuzzing of the log-pruning join-race mechanism (§
/// Architecture 6, `gc.dart`): random interleavings of certify/join/tick-
/// advance/evaluate actions, checking the core safety invariant directly
/// — pruning must never `proceed` while a device that joined after the
/// evaluated certificate's construction tick is present, regardless of
/// how many join/certify cycles preceded it.
void _runLogPruneRandomScenario(int seed) {
  final sim = Simulator(seed: seed);
  sim.addReplica('D0');
  final engine = LogPruneEngine(sim);
  final random = Random(seed * 32452843 + 13);

  DatasetMembersSnapshot? snapshot;
  GcCandidate? candidate;
  var nextDeviceId = 1;

  final stepCount = 15 + random.nextInt(20);
  for (var step = 0; step < stepCount; step++) {
    switch (random.nextInt(4)) {
      case 0: // (re)certify — starts a fresh candidacy for the current membership
        snapshot = engine.certify();
        candidate = engine.startCandidacy(snapshot);
        break;
      case 1: // a new device joins
        sim.addReplica('D${nextDeviceId++}');
        break;
      case 2: // time passes
        sim.advanceTick(1 + random.nextInt(6));
        break;
      case 3: // a compaction sweep evaluates (and prunes if proceeding)
        if (snapshot == null || candidate == null) break;
        final decision = engine.evaluate(candidate: candidate, certifiedSnapshot: snapshot);
        final joinedSinceCertificate =
            sim.replicas.keys.toSet().difference(snapshot.members).isNotEmpty;
        if (joinedSinceCertificate) {
          expect(decision, isNot(LogPruneDecision.proceed),
              reason: 'seed=$seed step=$step: pruning must never proceed while a post-certificate joiner is present');
        }
        final pruned = engine.pruneIfProceeding(snapshot, decision);
        if (pruned || decision == LogPruneDecision.deferred) {
          snapshot = null;
          candidate = null; // spent — the next certify() starts a fresh round
        }
        break;
    }
  }
}

/// Randomized fuzzing of User App revision/library/dependency derived
/// visibility (§ Architecture 10, `app_ops.dart`): random interleavings of
/// create/delete/undelete across the app -> revision -> library ->
/// dependency ownership chain, plus partial syncs between random device
/// pairs — checking, after full convergence, both that every replica
/// agrees on effective-deletedness/fallback selection
/// (`assertAppVisibilityConverged`) AND the core safety invariant
/// requirement 4 exists for: whichever revision is currently serving as
/// an app's zero-live-revisions fallback (and everything transitively
/// beneath it) must never be reported purge-eligible.
void _runAppRandomScenario(int seed) {
  final sim = Simulator(seed: seed);
  final random = Random(seed * 2654435761 + 3);
  final deviceCount = 2 + random.nextInt(3); // 2-4 devices
  final devices = List.generate(deviceCount, (i) => sim.addReplica('D$i'));
  final engines = {for (final d in devices) d.id: AppEngine(d)};

  final apps = <String>[];
  final revisions = <String>[];
  final libraries = <String>[];
  final dependencies = <String>[];

  final stepCount = 15 + random.nextInt(25);
  for (var step = 0; step < stepCount; step++) {
    final device = devices[random.nextInt(devices.length)];
    final engine = engines[device.id]!;
    switch (random.nextInt(9)) {
      case 0: // create an app
        apps.add(engine.createApp());
        break;
      case 1: // create a revision under a random known app
        if (apps.isNotEmpty) {
          revisions.add(engine.createRevision(apps[random.nextInt(apps.length)]));
        }
        break;
      case 2: // create a library under a random known revision
        if (revisions.isNotEmpty) {
          libraries.add(engine.createLibrary(revisions[random.nextInt(revisions.length)]));
        }
        break;
      case 3: // create a dependency under a random known library
        if (libraries.isNotEmpty) {
          dependencies.add(engine.createDependency(libraries[random.nextInt(libraries.length)]));
        }
        break;
      case 4: // deleteAppRevision on a random known revision
        if (revisions.isNotEmpty) {
          engine.deleteAppRevision(revisions[random.nextInt(revisions.length)]);
        }
        break;
      case 5: // undelete a random known revision
        if (revisions.isNotEmpty) {
          engine.undeleteRevision(revisions[random.nextInt(revisions.length)]);
        }
        break;
      case 6: // the round-15 sibling fix: delete a library directly
        if (libraries.isNotEmpty) {
          engine.deleteUserAppLibrary(libraries[random.nextInt(libraries.length)]);
        }
        break;
      case 7: // the round-15 sibling fix: delete a dependency directly
        if (dependencies.isNotEmpty) {
          engine.deleteUserAppLibraryDependency(dependencies[random.nextInt(dependencies.length)]);
        }
        break;
      case 8: // partial sync between two random devices
        if (devices.length >= 2) {
          final a = devices[random.nextInt(devices.length)];
          final b = devices[random.nextInt(devices.length)];
          if (a != b) sim.syncPartial(a, b);
        }
        break;
    }
  }

  sim.syncAllToAll(rounds: 4);
  assertFieldStateConverged(devices);
  assertAppVisibilityConverged(devices);

  // Requirement 4: a fallback (and its whole transitive graph) is never
  // purge-eligible, on every replica, for every app that has one.
  for (final d in devices) {
    final engine = AppEngine(d);
    final state = engine.computeEffectiveState();
    for (final appId in engine.allAppIds) {
      final fallback = state.fallbackRevisionForApp[appId];
      if (fallback == null) continue;
      expect(engine.revisionPurgeEligible(fallback, state), isFalse,
          reason: 'seed=$seed: fallback revision $fallback for app $appId must never be purge-eligible on ${d.id}');
      for (final lib in engine.librariesForRevision(fallback)) {
        if (engine.rawLibraryDeleted(lib)) continue; // directly deleted independent of the revision — legitimately purge-eligible
        expect(engine.libraryPurgeEligible(lib, state), isFalse,
            reason: 'seed=$seed: library $lib under fallback revision $fallback must never be purge-eligible on ${d.id}');
      }
    }
  }
}

void main() {
  test('randomized: blob GC grace-period/fresh-recheck mechanism never removes a currently-referenced blob', () {
    const iterations = 1000;
    for (var seed = 0; seed < iterations; seed++) {
      try {
        _runGcRandomScenario(seed);
      } catch (e, st) {
        fail('seed=$seed failed: $e\n$st');
      }
    }
  });

  test('randomized: orphan-message GC never removes a message with a currently-live membership reference', () {
    const iterations = 1000;
    for (var seed = 0; seed < iterations; seed++) {
      try {
        _runMessageGcRandomScenario(seed);
      } catch (e, st) {
        fail('seed=$seed failed: $e\n$st');
      }
    }
  });

  test('randomized: log-pruning never proceeds while a post-certificate joiner is present', () {
    const iterations = 1000;
    for (var seed = 0; seed < iterations; seed++) {
      try {
        _runLogPruneRandomScenario(seed);
      } catch (e, st) {
        fail('seed=$seed failed: $e\n$st');
      }
    }
  });

  test('randomized: many random device/tag/sync sequences converge with no invariant violation', () {
    const iterations = 3000;
    for (var seed = 0; seed < iterations; seed++) {
      try {
        _runRandomScenario(seed);
      } catch (e, st) {
        fail('seed=$seed failed: $e\n$st');
      }
    }
  });

  test('randomized: User App revision/library/dependency visibility converges and never purge-flags a live fallback',
      () {
    const iterations = 1000;
    for (var seed = 0; seed < iterations; seed++) {
      try {
        _runAppRandomScenario(seed);
      } catch (e, st) {
        fail('seed=$seed failed: $e\n$st');
      }
    }
  });

  test('randomized: partial (interrupted) syncs alone still converge safely', () {
    for (var seed = 0; seed < 1000; seed++) {
      final sim = Simulator(seed: seed);
      final d1 = sim.addReplica('D1');
      final d2 = sim.addReplica('D2');
      final d3 = sim.addReplica('D3');
      final e1 = TagEngine(d1);
      final e2 = TagEngine(d2);

      e1.createTag('urgent');
      e2.createTag('urgent');
      final random = Random(seed);
      final devices = [d1, d2, d3];
      for (var i = 0; i < 12; i++) {
        final a = devices[random.nextInt(devices.length)];
        final b = devices[random.nextInt(devices.length)];
        if (a != b) sim.syncPartial(a, b);
      }
      sim.syncAllToAll(rounds: 5);
      for (final d in devices) {
        TagEngine(d).resolveAllNameCollisions();
      }
      sim.syncAllToAll(rounds: 2);
      for (final d in devices) {
        assertNoLiveTagNameCollision(d);
      }
    }
  });
}
