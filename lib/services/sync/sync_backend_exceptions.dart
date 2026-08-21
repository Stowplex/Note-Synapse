// Typed exceptions a [SyncBackend] implementation may throw. These are part
// of the production interface's contract (§ Architecture 8), not a
// mock-only concept: a real `GoogleDriveBackend`/`WebDAVBackend` is expected
// to throw these same types for the same conditions, so the (not-yet-built)
// sync engine can write one set of catch clauses that works against any
// backend. `MockSyncBackend` (`test/sync_backend/mock_sync_backend.dart`)
// throws them under fault injection so that engine-side handling can be
// developed and tested well before a real backend exists.
//
// Deliberately a flat set of concrete classes rather than a `sealed`
// hierarchy: unlike the outcome types in `sync_backend.dart` (which model a
// *closed* set of protocol-defined states a caller must switch over
// exhaustively), this is an open set — additional backend-specific failure
// modes will keep appearing as real backends are implemented, and forcing
// every future exception into a pre-declared sealed hierarchy here would
// fight that. Callers should catch specific types they care about and let
// everything else propagate as a generic failure.

/// Access token expired mid-operation (HTTP 401 or backend equivalent).
/// § 8.2 fault-injection item 3, § 8.3's not-yet-built refresh-on-401 path.
/// Distinguished from [SyncRefreshTokenRevokedException]: this is expected
/// to be transient and resolved by a token refresh + single retry, once
/// that code exists (§ 8.3 — out of scope for this milestone; this
/// exception type is the hook that future code catches).
class SyncAuthExpiredException implements Exception {
  final String message;
  const SyncAuthExpiredException([this.message = 'Access token expired']);
  @override
  String toString() => 'SyncAuthExpiredException: $message';
}

/// The refresh token itself has been revoked (not merely the access token
/// expired) — § 8.2 fault-injection item 11. Must be surfaced as
/// "reauthorize needed," distinct from [SyncAuthExpiredException], and
/// never retried silently forever by anything upstream.
class SyncRefreshTokenRevokedException implements Exception {
  final String message;
  const SyncRefreshTokenRevokedException([
    this.message = 'Refresh token revoked; reauthorization required',
  ]);
  @override
  String toString() => 'SyncRefreshTokenRevokedException: $message';
}

/// 429/503-shaped rate limiting. § 8.2 fault-injection item 4: must trigger
/// backoff-with-jitter upstream, never be treated as a hard failure, and
/// must never cause a `publishIntentId` to be abandoned and reissued as a
/// new intent — the caller is expected to retry the *same* call.
class SyncRateLimitedException implements Exception {
  final Duration? retryAfter;
  const SyncRateLimitedException({this.retryAfter});
  @override
  String toString() => 'SyncRateLimitedException(retryAfter: $retryAfter)';
}

/// Storage quota exceeded. § 8.2 fault-injection item 10: must surface as a
/// distinct, user-actionable error class, not be retried into a hot loop.
class SyncQuotaExceededException implements Exception {
  final String message;
  const SyncQuotaExceededException([this.message = 'Storage quota exceeded']);
  @override
  String toString() => 'SyncQuotaExceededException: $message';
}

/// A generic transport failure whose write-outcome is unresolvable from the
/// exception alone (dropped connection, DNS failure, timeout). For
/// `appendCommit` this situation is expressed via `AppendCommitAmbiguous`
/// instead of an exception (§ 8.1); this exception type is for the other
/// mutating calls (`uploadBlob`, `publishSnapshot`) which have no
/// dedicated ambiguous-outcome type — the caller resolves ambiguity for
/// those via `blobExists` / re-reading, exactly as documented on
/// `SyncBackend.uploadBlob`.
class SyncNetworkException implements Exception {
  final String message;
  const SyncNetworkException([this.message = 'Network failure']);
  @override
  String toString() => 'SyncNetworkException: $message';
}

/// A downloaded blob's bytes do not hash to the requested `contentHash`, or
/// a read commit's bytes do not hash to its recorded `commitHash` /
/// correctly chain to its recorded `parentCommitHash`. Raised for both the
/// ordinary corruption case (§ 8.2 item 2/9) and the external-tampering
/// case (§ 8.2 item 15a/15b) — from the caller's side these are
/// indistinguishable without out-of-band evidence, which is itself part of
/// what item 15 discloses as a residual risk, not a gap this exception
/// type is expected to close.
class SyncHashMismatchException implements Exception {
  final String expectedHash;
  final String? actualHash;
  const SyncHashMismatchException({
    required this.expectedHash,
    required this.actualHash,
  });
  @override
  String toString() =>
      'SyncHashMismatchException(expected: $expectedHash, actual: $actualHash)';
}
