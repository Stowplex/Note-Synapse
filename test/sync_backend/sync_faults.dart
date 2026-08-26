// Fault-injection taxonomy for `MockSyncBackend` — § Architecture 8.2 of
// the CRDT-cloud-sync design doc, which enumerates 15 required scenarios a
// fault-injecting mock backend must be able to produce. This file is the
// vocabulary (`SyncFault` subclasses + the two `FaultSource` strategies §
// 8.2 explicitly recommends building both of); `mock_sync_backend.dart`
// is what actually interprets each fault against in-memory state.
//
// Coverage note (kept honest in the M2.1 report, not just here): several
// of the 15 items don't need a dedicated `SyncFault` subclass because
// they fall naturally out of ordinary API usage against shared in-memory
// state (item 5's conditional-delete race, item 13's concurrent-writer
// collision) or out of dedicated `debugX` mutation methods on
// `MockSyncBackend` rather than the fault-queue/generator path (item 9's
// post-write corruption, item 15's external tampering) — those are
// documented at their point of implementation in `mock_sync_backend.dart`,
// not modeled as `SyncFault`s here.

import 'dart:math';

/// Which `SyncBackend` method a [SyncFault] applies to. Mirrors the
/// interface's method set one-for-one so a [FaultSource] can be asked
/// "what should happen on the next call to this method" without knowing
/// anything about `MockSyncBackend`'s internals.
enum SyncOp {
  initializeDatasetOnce,
  readDatasetInitMarker,
  appendCommit,
  listDeviceLogIds,
  readCommits,
  blobExists,
  uploadBlob,
  downloadBlob,
  deleteConditionally,
  publishSnapshot,
  readSnapshot,
}

/// Base type for every injectable fault. `sealed` so `MockSyncBackend`'s
/// per-fault `switch` gets exhaustiveness checking.
sealed class SyncFault {
  final SyncOp op;
  const SyncFault(this.op);
}

/// § 8.2 item 1a: connection drops before the backend received anything.
/// No state is mutated; the caller sees a plain transport failure and,
/// per § Architecture 3's publish-intent idempotency, is expected to
/// retry the identical call.
class NetworkPartitionBeforeWrite extends SyncFault {
  const NetworkPartitionBeforeWrite(super.op);
}

/// § 8.2 item 1b (and the mid-batch flavor of item 3): connection drops
/// *after* the backend durably applied the write but before the response
/// reached the caller. The write **does** land; the caller just doesn't
/// get to see success. For `appendCommit` this is expressed as
/// `AppendCommitAmbiguous` rather than an exception (§ 8.1's outcome
/// type exists specifically for this); for the other mutating calls
/// (`uploadBlob`, `publishSnapshot`, `initializeDatasetOnce`), which have
/// no dedicated ambiguous-outcome type, it's a thrown
/// `SyncNetworkException` *after* the mutation is applied.
class NetworkPartitionAfterWrite extends SyncFault {
  const NetworkPartitionAfterWrite(super.op);
}

/// § 8.2 item 2: the backend accepted the bytes but the stored object is
/// truncated/corrupted (crash mid-fsync on local-folder; interrupted
/// WebDAV `PUT`). [manifestsOnUploadCheck] selects which of the two
/// documented defenses catches it: `true` models `uploadBlob`'s own
/// post-write hash check catching it immediately (the corruption never
/// becomes visible to any other caller); `false` models it slipping past
/// that check and only being caught later by `downloadBlob`'s
/// hash-verified-on-read contract (§ 8.2 item 9's "independent of the
/// write path" framing) — i.e. the write silently "succeeds" with
/// corrupted bytes on disk.
class TornWrite extends SyncFault {
  final bool manifestsOnUploadCheck;
  const TornWrite(super.op, {this.manifestsOnUploadCheck = true});
}

/// § 8.2 item 3: access-token expiry mid-operation (401). This is a
/// forward-looking hook — § 8.3's refresh-on-401 code doesn't exist
/// anywhere in this codebase yet (out of scope for M2.1) — so all this
/// fault does is make `MockSyncBackend` throw the typed exception a
/// future retry/refresh layer would catch.
class AuthExpired extends SyncFault {
  const AuthExpired(super.op);
}

/// § 8.2 item 11: the *refresh* token has been revoked, not merely the
/// access token expired — must be distinguishable from [AuthExpired] by
/// exception type alone, since the correct response (reauthorize vs.
/// silently refresh-and-retry) differs.
class RefreshTokenRevoked extends SyncFault {
  const RefreshTokenRevoked(super.op);
}

/// § 8.2 item 4: 429/503-shaped rate limiting, with or without a
/// `Retry-After` hint.
class RateLimited extends SyncFault {
  final Duration? retryAfter;
  const RateLimited(super.op, {this.retryAfter});
}

/// § 8.2 item 10: storage-quota-exceeded — must be a distinct,
/// user-actionable error class, not retried into a hot loop.
class QuotaExceeded extends SyncFault {
  const QuotaExceeded(super.op);
}

/// § 8.2 item 6: `readCommits` returns a page whose `deviceSeq` values
/// aren't contiguous from `afterSeq` — models eventually-consistent
/// listing. `MockSyncBackend` responds by removing a middle entry from
/// what would otherwise be a clean page and setting `hasGap = true`.
class OutOfOrderDelivery extends SyncFault {
  const OutOfOrderDelivery(super.op);
}

/// § 8.2 item 7 (listing-side flavor): the same commit appears twice in
/// one `readCommits` page — the belt-and-suspenders scenario the
/// protocol layer's `contentKey`/dot-redirect dedup (already proven by
/// M0, `test/sync_protocol/`) is supposed to absorb without the backend
/// layer's own publish-intent dedup needing to be perfect.
class DuplicateDelivery extends SyncFault {
  const DuplicateDelivery(super.op);
}

/// § 8.2 item 14: a read from a *different* simulated client doesn't yet
/// see a commit another client just successfully appended. Records
/// written within [delay] of `MockSyncBackend.clock.now()` at read time
/// are filtered out of the result, as if they hadn't propagated yet.
class ReadAfterWriteGap extends SyncFault {
  final Duration delay;
  const ReadAfterWriteGap(super.op, this.delay);
}

// ---------------------------------------------------------------------------
// Fault sources — § 8.2's explicit recommendation to support both a
// scripted per-call queue (deterministic regression suite, mirroring M0's
// `regression_test.dart`) and a seeded-random generator (mirroring M0's
// `randomized_test.dart`), "for the same reason M0 built three suites
// rather than one."
// ---------------------------------------------------------------------------

/// Strategy interface `MockSyncBackend` calls once per intercepted method
/// invocation. Returning `null` means "no fault, proceed normally."
abstract class FaultSource {
  SyncFault? next(SyncOp op);
}

/// Deterministic, explicit fault-per-call queue — one FIFO queue per
/// [SyncOp]. The regression-suite analog: exact, reproducible scenarios
/// like "the 2nd of 3 blob uploads in this batch gets a 401."
class ScriptedFaultQueue implements FaultSource {
  final Map<SyncOp, List<SyncFault>> _queues = {};

  void enqueue(SyncFault fault) {
    _queues.putIfAbsent(fault.op, () => []).add(fault);
  }

  void enqueueAll(Iterable<SyncFault> faults) {
    for (final f in faults) {
      enqueue(f);
    }
  }

  @override
  SyncFault? next(SyncOp op) {
    final q = _queues[op];
    if (q == null || q.isEmpty) return null;
    return q.removeAt(0);
  }
}

/// Seeded-random fault generator — the randomized-suite analog. For each
/// intercepted call, with probability [probability] picks a uniformly
/// random fault from [catalog]'s entry for that op (if any faults are
/// registered for it). Seeded so a failing run is exactly reproducible by
/// re-running with the same `seed`, matching this project's existing
/// `test/sync_protocol/randomized_test.dart` convention of printing the
/// seed on failure.
class RandomFaultGenerator implements FaultSource {
  final Random _random;
  final double probability;
  final Map<SyncOp, List<SyncFault>> catalog;

  RandomFaultGenerator({
    required int seed,
    required this.catalog,
    this.probability = 0.2,
  }) : _random = Random(seed);

  @override
  SyncFault? next(SyncOp op) {
    final candidates = catalog[op];
    if (candidates == null || candidates.isEmpty) return null;
    if (_random.nextDouble() >= probability) return null;
    return candidates[_random.nextInt(candidates.length)];
  }
}

/// Tries each source in order, returning the first non-null decision —
/// lets a test combine a scripted queue (checked first, for a precise
/// setup) with a random generator (background noise) in one backend
/// instance.
class CompositeFaultSource implements FaultSource {
  final List<FaultSource> sources;
  const CompositeFaultSource(this.sources);

  @override
  SyncFault? next(SyncOp op) {
    for (final s in sources) {
      final decision = s.next(op);
      if (decision != null) return decision;
    }
    return null;
  }
}
