// Uniform policy-based GC mechanism (§ Architecture 4/6 of the plan):
// certificate-preconditioned, grace-period-bounded, fresh-recheck-gated
// physical removal. Round 8's core finding is that a compaction
// certificate proves only a PAST-looking fact ("everyone had, by
// construction time, already incorporated snapshot S") — it can never
// prove the FUTURE-looking property physical removal actually needs
// ("nothing will ever newly reference/undelete/join afterward"). The fix
// is not a stronger proof but a genuinely different, policy-based
// mechanism, applied UNIFORMLY (round 11) to every kind of tombstoned/
// GC-able thing this plan discusses:
//
//   1. a certificate (or, for orphan messages, the raw tombstone write
//      itself) is a NECESSARY PRECONDITION for candidacy — never proof;
//   2. candidacy alone only STARTS A GRACE PERIOD — deliberately generous
//      time for a legitimate late reference/undelete/join to arrive;
//   3. at grace-period END, a FRESH RECHECK against the latest available
//      state (never the stale state that started the window) determines
//      final eligibility — un-candidating anything referenced/undeleted/
//      newly-joined since;
//   4. physical removal is the final step, gated on that fresh recheck
//      (manual confirmation, per requirement 10, is a UI-layer concern
//      out of scope for this abstract protocol model).
//
// This file introduces the simulator's only notion of time: a simple
// integer tick/generation counter (`Simulator.tick`), advanced only by an
// explicit `Simulator.advanceTick()` call — never real wall-clock time,
// exactly as every other mechanism in this simulator is abstract rather
// than tied to real infrastructure.

import 'replica.dart';
import 'simulator.dart';

/// Policy configuration for the grace period, analogous to the real app's
/// (e.g. 30-day) default — expressed in abstract ticks here, since this
/// simulator has no wall-clock concept at all.
class GcPolicy {
  final int gracePeriodTicks;
  const GcPolicy({this.gracePeriodTicks = 10});
}

/// Marks the tick at which something became a GC candidate — i.e. the
/// tick its necessary-precondition certificate (or, for orphan messages,
/// its raw tombstone) was observed. Recording this, by itself, authorizes
/// NOTHING: it only starts the grace-period clock (step 2 above).
class GcCandidate {
  final String id;
  final int candidateSinceTick;
  const GcCandidate(this.id, this.candidateSinceTick);
}

/// Outcome of evaluating a [GcCandidate] against the current tick: never
/// eligible before the grace period elapses, and even after it elapses,
/// eligible only if the fresh recheck predicate still holds.
enum GcOutcome {
  /// No certificate/tombstone has ever been observed for this id at all.
  notYetCandidate,

  /// A candidate exists, but the grace period hasn't elapsed yet — always
  /// retained untouched during this window, regardless of anything else.
  withinGracePeriod,

  /// Grace period elapsed, but the fresh recheck against CURRENT state
  /// found renewed relevance (a new reference, an undelete, a new
  /// member) — un-candidated, not removed. This is a policy outcome, not
  /// a proof of anything: a device offline for the entire grace period
  /// could still have its legitimate reference lost (the plan's own
  /// disclosed, bounded residual risk).
  unCandidated,

  /// Grace period elapsed AND the fresh recheck confirms nothing renewed
  /// its relevance — physical removal may now proceed.
  eligibleForRemoval,
}

/// The single shared grace-period-then-fresh-recheck primitive every one
/// of the three concrete mechanisms below is built on. [freshRecheckStillEligible]
/// is evaluated ONLY once the grace period has elapsed, and always against
/// whatever [freshRecheckStillEligible] itself chooses to consult (which
/// must be current/latest state, never the state captured at candidacy
/// time — that's the whole point of "fresh").
GcOutcome evaluateGcCandidate({
  required GcCandidate? candidate,
  required int currentTick,
  required GcPolicy policy,
  required bool Function() freshRecheckStillEligible,
}) {
  if (candidate == null) return GcOutcome.notYetCandidate;
  if (currentTick < candidate.candidateSinceTick + policy.gracePeriodTicks) {
    return GcOutcome.withinGracePeriod;
  }
  return freshRecheckStillEligible() ? GcOutcome.eligibleForRemoval : GcOutcome.unCandidated;
}

// ---------------------------------------------------------------------
// 1. Blob GC (§ Architecture 4)
// ---------------------------------------------------------------------

/// A stand-in for the compaction certificate's consolidated state, scoped
/// to blobs: the set of blob hashes referenced by the dataset AS OF the
/// tick this snapshot was certified. Never mutates after construction —
/// a later reference must be captured by a LATER snapshot, never by
/// retroactively updating an earlier one (that would defeat the whole
/// "fresh recheck against the latest available snapshot" step).
class BlobSnapshot {
  final int certifiedAtTick;
  final Set<String> referencedBlobHashes;
  BlobSnapshot(this.certifiedAtTick, Set<String> referenced) : referencedBlobHashes = Set.of(referenced);
}

/// Blob GC (§ Architecture 4): a blob is a GC candidate once absent from
/// the most recently certified snapshot's consolidated state; grace
/// period; fresh recheck against the LATEST available certified snapshot
/// at grace-period end (which, by then, likely postdates the one that
/// started the window).
class BlobGcEngine {
  final Replica replica;
  BlobGcEngine(this.replica);

  /// Certifies a snapshot of currently-referenced blob hashes as of
  /// [tick] — the "everyone has incorporated this consolidated state"
  /// fact, scoped to blob references specifically.
  BlobSnapshot certify(int tick) => BlobSnapshot(tick, replica.referencedBlobHashes);

  /// Step 1: necessary precondition only. A blob absent from the
  /// certified snapshot becomes a candidate; one already known as a
  /// candidate keeps its ORIGINAL candidacy tick (re-certifying the same
  /// absence doesn't restart the grace-period clock).
  GcCandidate considerCandidate(String blobHash, BlobSnapshot snapshot, {GcCandidate? existing}) {
    assert(!snapshot.referencedBlobHashes.contains(blobHash),
        'considerCandidate should only be called for a blob absent from the snapshot');
    if (existing != null && existing.id == blobHash) return existing;
    return GcCandidate(blobHash, snapshot.certifiedAtTick);
  }

  /// Steps 2-3: grace period, then fresh recheck against [latestSnapshot]
  /// (which the caller must have certified no earlier than [currentTick],
  /// i.e. the LATEST available one, not the one that started the window).
  GcOutcome evaluate({
    required GcCandidate? candidate,
    required int currentTick,
    required BlobSnapshot latestSnapshot,
    GcPolicy policy = const GcPolicy(),
  }) =>
      evaluateGcCandidate(
        candidate: candidate,
        currentTick: currentTick,
        policy: policy,
        freshRecheckStillEligible: () => !latestSnapshot.referencedBlobHashes.contains(candidate!.id),
      );

  /// Step 4: physical removal, gated on [outcome] already being
  /// `eligibleForRemoval` — never performed as a side effect of
  /// evaluation itself. On success, the caller owns dropping its own
  /// [GcCandidate] tracking entry for [blobHash] — this method only
  /// mutates blob storage, never the caller's candidate map, so a future
  /// absence can start a fresh candidacy rather than reusing a stale tick.
  bool pruneIfEligible(String blobHash, GcOutcome outcome) {
    if (outcome != GcOutcome.eligibleForRemoval) return false;
    replica.knownBlobHashes.remove(blobHash);
    return true;
  }
}

// ---------------------------------------------------------------------
// 2. Orphan-message cleanup (§ Architecture 6)
// ---------------------------------------------------------------------

/// Orphan-message physical removal (§ Architecture 6): the tombstone is
/// RAW `message.__deleted__=true`, but physical removal must be gated on
/// EFFECTIVE deletedness — raw `__deleted__` AND no live membership
/// currently references the message — because a tombstone and a
/// concurrent membership-add are writes to two different CRDT subjects
/// (`message.__deleted__` vs. `conversation_message_mapping`) the
/// ordinary per-field conflict rule has no mechanism to relate at all.
/// Reuses the exact same generic `liveMembershipRefs`/
/// `hasLiveMembershipReference` mechanism already established for tags
/// (`replica.dart`) rather than inventing message-specific machinery —
/// it was already generic (entityId -> referenced-id), not tag-specific.
class MessageGcEngine {
  final Replica replica;
  MessageGcEngine(this.replica);

  bool rawDeleted(String messageId) => replica.fieldValue<bool>('message', messageId, '__deleted__') ?? false;

  /// Derived, always-recomputed — never a minted write, exactly like the
  /// tag `effective___deleted__` formula and the message-parent
  /// cycle-break.
  bool effectiveDeleted(String messageId) => rawDeleted(messageId) && !replica.hasLiveMembershipReference(messageId);

  /// Step 1: the raw tombstone is the necessary precondition for
  /// candidacy (a live message is never a candidate at all, regardless of
  /// membership state). Grace period starts at [tick] — the tick the
  /// tombstone was first observed as raw-deleted — and, matching
  /// [BlobGcEngine.considerCandidate], never restarts on repeated calls.
  GcCandidate? considerCandidate(String messageId, int tick, {GcCandidate? existing}) {
    if (!rawDeleted(messageId)) return null;
    if (existing != null && existing.id == messageId) return existing;
    return GcCandidate(messageId, tick);
  }

  /// Steps 2-3: grace period, then a fresh recheck of EFFECTIVE (not raw)
  /// deletedness — the fix for the tombstone-vs-concurrent-membership-add
  /// race, since effective deletedness naturally incorporates whatever
  /// membership state is known BY THEN, regardless of write-arrival order.
  GcOutcome evaluate({
    required GcCandidate? candidate,
    required int currentTick,
    GcPolicy policy = const GcPolicy(),
  }) =>
      evaluateGcCandidate(
        candidate: candidate,
        currentTick: currentTick,
        policy: policy,
        freshRecheckStillEligible: () => effectiveDeleted(candidate!.id),
      );

  /// Step 4: physical removal — writes a `sync_grave` marker (unchanged
  /// invariant: purging retains a grave marker, § Architecture 6) before
  /// discarding the message's own data. On success, the caller owns
  /// dropping its own [GcCandidate] tracking entry for [messageId] — see
  /// [BlobGcEngine.pruneIfEligible]'s doc comment for why.
  bool pruneIfEligible(String messageId, GcOutcome outcome) {
    if (outcome != GcOutcome.eligibleForRemoval) return false;
    replica.grave.add(messageId);
    replica.physicallyRemovedMessages.add(messageId);
    return true;
  }
}

// ---------------------------------------------------------------------
// 3. Log-pruning join race (§ Architecture 6)
// ---------------------------------------------------------------------

/// A stand-in for the compaction certificate's membership attestation:
/// which devices were active dataset members as of the tick the
/// certificate for snapshot S was constructed.
class DatasetMembersSnapshot {
  final int certifiedAtTick;
  final Set<String> members;
  DatasetMembersSnapshot(this.certifiedAtTick, Set<String> members) : members = Set.of(members);
}

/// Outcome of a log-pruning eligibility evaluation. Deliberately a
/// separate enum from [GcOutcome] even though it's built on the exact
/// same shared grace-period primitive: the plan is explicit that a device
/// joining mid-grace-period must DEFER (retry next cycle) the compaction
/// round, not ABANDON it the way an un-candidated blob effectively is
/// (dropped until some future certificate re-establishes candidacy from
/// scratch) — a real semantic distinction worth keeping visible in the
/// type rather than overloading one shared vocabulary for both.
enum LogPruneDecision { withinGracePeriod, deferred, proceed }

/// Log-pruning's join-vs-compaction race (§ Architecture 6, round 14): a
/// joining (or long-returning) device is structurally the same shape of
/// risk as a blob reference or undelete arriving after a certificate is
/// built. Physical deletion of logs consolidated by certified snapshot S
/// is gated on: (a) the certificate (necessary precondition, unchanged);
/// (b) a grace period after certificate construction; (c) an immediate
/// FRESH RECHECK of dataset membership before deletion — if any device
/// has joined since the certificate was built, the round is DEFERRED
/// (not abandoned — retried next cycle), giving the new device the same
/// grace window to complete its bootstrap read of the old logs it needs.
class LogPruneEngine {
  final Simulator sim;
  LogPruneEngine(this.sim);

  /// Certifies dataset membership as of the current tick — the "everyone
  /// active had, by construction time, already incorporated S" fact,
  /// scoped to WHO counted as active at that time.
  DatasetMembersSnapshot certify() => DatasetMembersSnapshot(sim.tick, sim.replicas.keys.toSet());

  /// Step 1: necessary precondition only — a certified snapshot alone
  /// starts candidacy for pruning the logs it consolidates.
  GcCandidate startCandidacy(DatasetMembersSnapshot snapshot) =>
      GcCandidate('log-prune-upto-${snapshot.certifiedAtTick}', snapshot.certifiedAtTick);

  /// Steps 2-3: grace period, then an immediate fresh recheck of CURRENT
  /// dataset membership against the membership captured at certificate
  /// time — any new member not in [certifiedSnapshot.members] defers the
  /// round rather than proceeding.
  LogPruneDecision evaluate({
    required GcCandidate candidate,
    required DatasetMembersSnapshot certifiedSnapshot,
    GcPolicy policy = const GcPolicy(),
  }) {
    final outcome = evaluateGcCandidate(
      candidate: candidate,
      currentTick: sim.tick,
      policy: policy,
      freshRecheckStillEligible: () => sim.replicas.keys.toSet().difference(certifiedSnapshot.members).isEmpty,
    );
    switch (outcome) {
      case GcOutcome.notYetCandidate:
      case GcOutcome.withinGracePeriod:
        return LogPruneDecision.withinGracePeriod;
      case GcOutcome.unCandidated:
        return LogPruneDecision.deferred;
      case GcOutcome.eligibleForRemoval:
        return LogPruneDecision.proceed;
    }
  }

  /// Step 4: physical deletion of the logs consolidated by [snapshot] —
  /// gated on [decision] already being `proceed`.
  bool pruneIfProceeding(DatasetMembersSnapshot snapshot, LogPruneDecision decision) {
    if (decision != LogPruneDecision.proceed) return false;
    sim.prunedLogGenerations.add(snapshot.certifiedAtTick);
    return true;
  }
}
