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

/// The dataset's root location cannot be resolved because more than one
/// candidate answers to the configured name — M2.11.
///
/// **This exists to replace a silent `.first`.** `GoogleDriveBackend` used
/// to sort same-named folders by creation time and take the oldest, which is
/// deterministic on one device and says nothing about what a *second* device
/// picks: two devices resolving to two different folders is a split-brain in
/// which each syncs happily against a different dataset and neither reports
/// anything wrong. Only the user can say which folder they meant, so the
/// only correct behaviour is to stop and ask.
///
/// **Reachable only where a name is still the identity** — first setup, or
/// the one-shot upgrade resolution for an install that predates M2.11. Once
/// a folder id has been persisted, the name is never resolved again and this
/// cannot be thrown.
///
/// Phrased in "folder" terms rather than something Drive-specific because
/// every backend this interface targets (Drive, WebDAV, local folder) roots a
/// dataset in a folder, and all three can be pointed at an ambiguous name.
class SyncAmbiguousRootFolderException implements Exception {
  /// The name that matched more than once.
  final String folderName;

  /// How many candidates matched.
  final int candidateCount;

  /// Backend-native ids of the candidates, when the backend has them —
  /// diagnostic only, and deliberately not something a caller is expected to
  /// choose from automatically. Picking for the user is the defect.
  final List<String> candidateIds;

  const SyncAmbiguousRootFolderException({
    required this.folderName,
    required this.candidateCount,
    this.candidateIds = const [],
  });

  @override
  String toString() =>
      'SyncAmbiguousRootFolderException: $candidateCount locations are named '
      '"$folderName" (${candidateIds.join(', ')}); refusing to guess which one '
      'holds this dataset';
}

/// The dataset's root location was addressed by a durably-recorded id, and
/// the backend definitively reports that id no longer exists — M2.11.
///
/// **"Definitively" is the whole content of this type.** A 404/`trashed`
/// answer means the folder is gone; a timeout, a DNS failure, a 5xx or a
/// rate-limit means nothing at all about whether it is gone, and those must
/// keep surfacing as [SyncNetworkException]/[SyncRateLimitedException] so
/// that an offline device is never told its data was deleted. That
/// distinction is the one M2.13 fought for in
/// `DatasetBootstrap.verifyDatasetStillExists`, and this exception exists so
/// that a backend can honour it at the folder level too.
///
/// **Ordinarily the user never sees this**, because the path that matters
/// reaches them through M2.13's existing recovery flow instead: a vanished
/// root makes `readDatasetInitMarker()` return null, which
/// `verifyDatasetStillExists` turns into `DatasetPresence.missing` and the
/// settings screen renders as "Sync dataset is missing → Reset sync". This
/// type is what the remaining, non-pre-flighted call paths throw rather than
/// silently creating a replacement folder underneath a device that still
/// believes it is Ready.
///
/// **And when they DO see it, here is what happens** — the half that was
/// missing until review round 2, when "ordinarily" was doing all the work.
/// The reachable path is a device whose bootstrap never finished:
/// `verifyDatasetStillExists` returns `notBootstrapped` without a backend
/// call (correctly — there is nothing yet to verify), so the round runs and
/// the first call needing the root folder throws this. Before, it landed in
/// `CloudSyncScreen._syncNow`'s generic `catch (e)` and was quoted at the
/// user, and persisted as the quoted string. `CloudSyncService.syncNow` now
/// catches it and reports it as [DatasetMissingException] with the same
/// stable sentinel — because a definitively-gone root folder means exactly
/// what a definitively-absent marker means, and inventing a second way of
/// saying it would be inventing a second dead end.
class SyncRootFolderMissingException implements Exception {
  /// The recorded id that no longer resolves.
  final String folderId;

  const SyncRootFolderMissingException(this.folderId);

  @override
  String toString() =>
      'SyncRootFolderMissingException: the recorded dataset root ($folderId) '
      'no longer exists on the backend';
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
