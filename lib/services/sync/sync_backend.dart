// The `SyncBackend` abstraction — § Architecture 8.1 of the CRDT-cloud-sync
// design (`plan-and-propse-the-glistening-dolphin.md`). M2.1: interface only.
// No real Google Drive/WebDAV/local-folder implementation lives here yet
// (later M2 sub-milestones); no sync engine consumes this interface yet
// either (also later). This file, `mock_sync_backend.dart`
// (`test/sync_backend/`), and the conformance suite it's paired with are
// the whole of M2.1's deliverable: a stable, documented abstraction plus a
// fault-injecting in-memory implementation to develop and test the real
// backends and the sync engine against, without either existing yet.
//
// Every doc comment below that cites "§ 8.1" / "§ 8.2" / etc. is citing that
// design document by section number, not inventing new authority — this
// file's job is to *implement* what that section specifies, and to make the
// two decisions it explicitly left open for "M2 design review" (marked
// below at the exact point each is resolved), not to redesign it.

import 'dart:async';
import 'dart:typed_data';

/// Capability flags one [SyncBackend] implementation declares about the
/// concrete remote storage it wraps (§ 8.4). The interface itself never
/// branches on backend type — every method above is identical for Drive,
/// WebDAV, and local-folder; only capability *values* and the
/// [DeletePrecondition] union differ per backend. Callers (the GC engine,
/// eventually) read these flags to pick a strategy, not a backend-specific
/// code path.
class SyncBackendCapabilities {
  /// True for WebDAV (`If-Match`) and local-folder (atomic mtime-checked
  /// rename/write) — a native conditional-delete primitive exists. False
  /// for Google Drive, which has no such primitive; a GC engine checking
  /// this flag before deleting falls back to "recheck-before-delete is the
  /// primary mitigation" (§ Architecture 4) instead of trusting a
  /// conditional precondition.
  final bool supportsConditionalDelete;

  /// True when this backend can persist a reference to a user-chosen
  /// external folder across app restarts. False on iOS local-folder (§ 8.4)
  /// — no `LSSupportsOpeningDocumentsInPlace`/security-scoped-bookmark
  /// native code exists in this repo, so iOS local-folder sync is scoped to
  /// the app's own sandbox container rather than an arbitrary folder. The
  /// settings UI (§ Architecture 9, not built in this milestone) is meant
  /// to read this capability *before* offering a folder picker.
  final bool supportsPersistentExternalFolder;

  const SyncBackendCapabilities({
    required this.supportsConditionalDelete,
    required this.supportsPersistentExternalFolder,
  });
}

// ---------------------------------------------------------------------------
// appendCommit outcome (§ 8.1's central design problem: a network write is
// at-least-once from the caller's perspective, so success/failure/exception
// alone cannot express "I don't know whether the write landed").
// ---------------------------------------------------------------------------

/// Outcome of [SyncBackend.appendCommit]. The `Ambiguous` case exists
/// because a network write is at-least-once from the caller's perspective:
/// the request may have been received and durably applied by the backend
/// even though the response never arrived (connection dropped after send,
/// before the reply). § Architecture 3's "publish-intent idempotency" is
/// the mechanism intended to resolve `Ambiguous` — the caller re-reads the
/// log ([SyncBackend.readCommits]) or re-issues [SyncBackend.appendCommit]
/// with the *same* `publishIntentId`, and a conformant backend must return
/// the original outcome, never mint a duplicate.
///
/// A `sealed class` so callers get exhaustiveness checking from `switch`
/// (Dart 3, this project targets `sdk: ^3.9.2` per `pubspec.yaml`) — the
/// three cases below are meant to be handled, not defaulted-through.
sealed class AppendCommitOutcome {
  const AppendCommitOutcome();
}

/// The commit was durably appended (or, for a retried `publishIntentId`,
/// was already durably appended by an earlier attempt — idempotent replay
/// is `Succeeded`, not a distinct case, since from the caller's point of
/// view both mean "this commit now exists at this position").
class AppendCommitSucceeded extends AppendCommitOutcome {
  /// Hash of the commit as actually stored — the caller must use *this*
  /// value as `parentCommitHash` for the log's next append, not
  /// recompute its own, in case a backend-side idempotent-replay path
  /// returned an existing commit whose hash the caller can't otherwise
  /// observe from the request it sent.
  final String commitHash;

  const AppendCommitSucceeded(this.commitHash);
}

/// § Architecture 3's "halt-not-retarget": the backend's current tip for
/// this device's own log does not match the `parentCommitHash` the caller
/// supplied. The caller must stop and surface this as a real error — never
/// silently write past it, never retarget onto the actual tip and retry
/// automatically. (Also raised, in this implementation, when the supplied
/// `deviceSeq` doesn't match `actualTipSeq + 1`; see the doc comment on
/// [SyncBackend.appendCommit] for why that's folded into this same case
/// rather than a fourth outcome type.)
class AppendCommitParentMismatch extends AppendCommitOutcome {
  /// The hash of the commit actually at this log's current tip. **Empty
  /// string is a sentinel meaning "this log has no commits at all"** —
  /// i.e. the caller supplied a non-null `parentCommitHash` (implying it
  /// believed at least one prior commit existed) against a backend log
  /// that is actually still empty (`deviceSeq` would need to be `1` with a
  /// `null` parent to be valid there). This is deliberately *not* modeled
  /// as `String?` — every other caller of this field wants "the tip
  /// hash to build on top of next," and an empty log has no such hash to
  /// offer, so the empty string reads as "there is nothing to chain onto"
  /// without forcing every consumer to null-check a field that's
  /// non-null in the overwhelmingly common case. A caller that needs to
  /// distinguish "empty log" from "real (if unlikely) empty-string hash"
  /// can do so unambiguously: no real sha256 hex digest is ever empty.
  final String actualTipHash;

  const AppendCommitParentMismatch(this.actualTipHash);
}

/// The write's outcome is unknown — timeout, dropped connection, a 5xx
/// received only after the request body was fully sent. The caller must
/// resolve this via [SyncBackend.readCommits] or a retried call with the
/// identical `publishIntentId` before deciding whether to treat it as a
/// real failure. **Whether that retry is actually safe is backend-
/// dependent, not guaranteed by this type shape alone** — see § 8.4's
/// Drive-duplicate-create finding, resolved concretely for the mock in
/// `MockSyncBackend` (`test/sync_backend/mock_sync_backend.dart`).
class AppendCommitAmbiguous extends AppendCommitOutcome {
  const AppendCommitAmbiguous();
}

// ---------------------------------------------------------------------------
// readCommits
// ---------------------------------------------------------------------------

/// One commit as stored and returned by [SyncBackend.readCommits]. Not
/// specified as a named type in § 8.1's own pseudocode (which sketches
/// `readCommits` returning a `CommitPage` without spelling out its element
/// type) — this shape is this milestone's own inference from what a caller
/// needs to verify hash-chain linkage without a second round-trip:
/// `deviceSeq` + `commitHash` + `parentCommitHash` + the raw bytes.
class StoredCommit {
  final int deviceSeq;
  final String commitHash;
  final String? parentCommitHash; // null only for deviceSeq == 1
  final Uint8List commitBytes;

  const StoredCommit({
    required this.deviceSeq,
    required this.commitHash,
    required this.parentCommitHash,
    required this.commitBytes,
  });
}

/// Result of [SyncBackend.readCommits]. `hasGap` exists so a backend with
/// eventually-consistent listing (§ 8.2 fault-injection item 6) can be
/// caught at the interface boundary rather than deep inside merge logic —
/// § Architecture 2/3's no-gap-skipping property requires the caller to
/// *detect* a non-contiguous page and refuse to apply it, not silently
/// skip ahead. `hasGap = true` means: somewhere between `afterSeq` and the
/// last commit in `commits`, at least one `deviceSeq` is missing from what
/// was returned. Callers must not apply any commit past the gap.
class CommitPage {
  final List<StoredCommit> commits;
  final bool hasGap;

  const CommitPage({required this.commits, required this.hasGap});
}

// ---------------------------------------------------------------------------
// deleteConditionally (§ Architecture 4/6's uniform GC mechanism)
// ---------------------------------------------------------------------------

/// What to delete — a union because the same method covers both blob GC
/// (§ Architecture 4) and device-log pruning (§ Architecture 6, which
/// explicitly reuses § Architecture 4's mechanism rather than inventing a
/// second one). `sealed` for switch-exhaustiveness.
sealed class BackendRef {
  const BackendRef();
}

class BlobRef extends BackendRef {
  final String contentHash;
  const BlobRef(this.contentHash);
}

/// Prune device-log entries for `deviceLogId` up to and including
/// `throughSeq` — a *prefix* deletion, never an arbitrary range, matching
/// § Architecture 6's log-pruning being about discarding an already-
/// certified prefix, not individual commits out of order.
class DeviceLogPrefixRef extends BackendRef {
  final String deviceLogId;
  final int throughSeq;
  const DeviceLogPrefixRef(this.deviceLogId, this.throughSeq);
}

/// Precondition under which a delete may proceed — a capability-gated
/// union (§ 8.4) so the *interface* never branches on backend type, only
/// the precondition value does. `capabilities.supportsConditionalDelete`
/// tells the caller which variant a given backend can actually honor.
sealed class DeletePrecondition {
  const DeletePrecondition();
}

/// WebDAV `If-Match` / local-folder atomic mtime-check: delete only if the
/// object's current etag-or-mtime still equals [etagOrMtime]. Requires
/// `capabilities.supportsConditionalDelete == true`.
class IfUnmodifiedSince extends DeletePrecondition {
  final String etagOrMtime;
  const IfUnmodifiedSince(this.etagOrMtime);
}

/// No native conditional-delete primitive (Google Drive). The caller is
/// responsible for the "recheck-before-delete is the primary mitigation"
/// fallback (§ Architecture 4) *before* calling `deleteConditionally` with
/// this precondition — the backend performs an unconditional delete once
/// asked.
class Unconditional extends DeletePrecondition {
  const Unconditional();
}

/// Outcome of [SyncBackend.deleteConditionally]. `sealed` for
/// switch-exhaustiveness — a caller must handle "the precondition lost the
/// race" as a real, expected, safe-to-ignore case (§ 8.2 fault-injection
/// item 5), not treat it as an error.
sealed class DeleteOutcome {
  const DeleteOutcome();
}

class DeleteSucceeded extends DeleteOutcome {
  const DeleteSucceeded();
}

/// The precondition did not hold — something else (a new blob reference,
/// a joining device reading a log prefix) wrote in the gap between the
/// GC recheck and this call. The object was **not** deleted and remains
/// live; this is the literal mechanism § Architecture 4 describes as the
/// primary safety net, not a failure to be retried.
class DeletePreconditionFailed extends DeleteOutcome {
  const DeletePreconditionFailed();
}

/// The referenced object doesn't exist — already deleted (by this device
/// in an earlier, ambiguous attempt; §8.2 item 7's delete-side analog) or
/// never existed. Distinct from `DeletePreconditionFailed` because it is
/// *not* evidence of a concurrent write racing the delete, only of the
/// object's absence.
class DeleteNotFound extends DeleteOutcome {
  const DeleteNotFound();
}

// ---------------------------------------------------------------------------
// Dataset lifecycle (§ Architecture 5/7's requirement that encryption is
// chosen once at dataset creation and is immutable thereafter)
// ---------------------------------------------------------------------------

/// The write-once, backend-stored marker every device checks before
/// participating in a dataset — grounds requirement 5 ("encryption chosen
/// once at dataset creation, immutable thereafter"). No local table can
/// record this in a way a *second* device can read before it has pulled
/// anything (§ 8.1), so this has to live at the backend, readable before
/// any commit-log pull.
///
/// Fields are deliberately opaque/nullable rather than a fully-specified
/// crypto envelope: § 8.5's AEAD library selection and canary-value
/// construction are explicitly out of scope for this milestone (no
/// encryption implementation yet), but this shape must not *structurally
/// preclude* what § 8.5 proposes — a per-dataset random KDF salt and an
/// AEAD-encrypted canary value, both backend-visible-safe (a salt alone,
/// or a value only decryptable with the correct passphrase-derived key,
/// leaks nothing) — from being populated later without a shape change.
class DatasetInitMarker {
  final bool encryptionEnabled;

  /// Per-dataset random salt for the passphrase-derived KDF (§ 8.5, item 1
  /// — key management resolved as passphrase-derived by explicit user
  /// decision). Safe to be backend-visible: a salt alone is not a key.
  /// Null when `encryptionEnabled == false`.
  final Uint8List? kdfSalt;

  /// An AEAD-encrypted canary value a joining device decrypts with its own
  /// locally-derived key to confirm a re-entered passphrase is correct
  /// *before* attempting any real sync (§ 8.5) — opaque bytes here since
  /// no AEAD library is chosen yet (§ 8.5, item 2, explicitly deferred).
  /// Null when `encryptionEnabled == false`.
  final Uint8List? passphraseCanary;

  /// The device (ordinary device identity, per § Architecture 1) that
  /// created the dataset — diagnostic only, not load-bearing for any
  /// protocol decision.
  final String createdByDeviceId;

  final DateTime createdAt;

  const DatasetInitMarker({
    required this.encryptionEnabled,
    required this.kdfSalt,
    required this.passphraseCanary,
    required this.createdByDeviceId,
    required this.createdAt,
  });
}

// ---------------------------------------------------------------------------
// Certified snapshots (§ Architecture 6)
// ---------------------------------------------------------------------------

/// A pointer to the most recently published certified snapshot.
/// `publishedAt` is this milestone's own inference for how "latest" is
/// determined — § Architecture 6 never specifies the ordering mechanism a
/// real backend should use (a real WebDAV/local-folder backend might use a
/// well-known pointer file instead; Drive might use a well-known filename
/// plus modified-time). `publishedAt` here is `MockSyncBackend`'s own
/// notion of order (insertion order via its mock clock), not a claim about
/// what a real backend's `latestSnapshotRef` will key off internally.
class SnapshotRef {
  final String snapshotHash;
  final DateTime publishedAt;

  const SnapshotRef({required this.snapshotHash, required this.publishedAt});
}

// ---------------------------------------------------------------------------
// The interface itself
// ---------------------------------------------------------------------------

/// One already-configured connection to one already-selected root location
/// for **one dataset** (§ 8.1's scope decision) — analogous to how
/// `OAuthTokenManager` (`lib/services/oauth_token_manager.dart`) is
/// instantiated per MCP `endpointId` rather than taking an endpoint
/// parameter on every call. Connection setup (OAuth consent, WebDAV
/// URL/credentials, folder picker) is a factory-time concern outside this
/// interface; every method below is implicitly scoped to "this backend,
/// this dataset." If multi-dataset-per-install is ever wanted, the fix is
/// holding multiple `SyncBackend` instances, not adding a `datasetId`
/// parameter everywhere (§ 8.1, flagged there as an open question, not
/// resolved by this milestone since nothing in M2.1 needs it resolved).
abstract class SyncBackend {
  SyncBackendCapabilities get capabilities;

  // --- Dataset lifecycle -----------------------------------------------

  /// Writes [marker] iff no marker has been written yet for this dataset.
  /// Must be atomic against a second, concurrent first-write (two devices
  /// racing to create the same dataset) — whichever loses must observe its
  /// own marker silently discarded and [readDatasetInitMarker] returning
  /// the winner's marker, not an error and not two markers coexisting.
  /// This is what makes "encryption chosen once, immutable thereafter"
  /// actually enforceable across devices that have never directly
  /// communicated.
  Future<void> initializeDatasetOnce(DatasetInitMarker marker);

  /// Null iff no device has ever called [initializeDatasetOnce] for this
  /// dataset — the "brand new, empty dataset" case a first device
  /// distinguishes from "joining an existing one."
  Future<DatasetInitMarker?> readDatasetInitMarker();

  // --- Per-device, hash-linked, append-only commit log ------------------
  // Grounds § Architecture 3 in full: hash-linked chain, publish-intent
  // idempotency, halt-not-retarget.

  /// Appends one commit to `deviceLogId`'s hash-linked chain.
  ///
  /// [deviceSeq] is this log's own monotonic counter (1, 2, 3, ...);
  /// [parentCommitHash] must equal the hash of the commit currently at
  /// `deviceSeq - 1` (null only when `deviceSeq == 1`, i.e. the log's first
  /// commit). [publishIntentId] is presumed sourced from the local
  /// `sync_publish_intent` table (`lib/services/database_service.dart`,
  /// `_createSyncPublishIntentTable`) — confirmed against the actual schema
  /// while writing this file, not merely inferred as § 8.1's draft caveat
  /// noted it might need to be: that table already exists, keyed by
  /// `intentHash` (a deterministic hash of `parentCommitHash` +
  /// `payloadHash`), which is exactly the stable, replay-safe identifier
  /// this parameter needs.
  ///
  /// **On `deviceLogId` identity — resolving § 8.1's `dataset_members`
  /// bootstrap ambiguity, one of the two open questions this milestone was
  /// asked to close concretely:** § Architecture 1 gives seed-import and
  /// external-plain-file-edit operations their own `authorId` namespaces
  /// (`"seed:" + device`, `"external:" + device"`), each with its own
  /// independent monotonic sequence — meaning a single physical device can
  /// own up to three separate hash-linked chains (ordinary + `seed:` +
  /// `external:`), each a distinct `deviceLogId` at this interface's level.
  /// **Decision: `SyncBackend` treats `deviceLogId` as exactly this raw,
  /// uncollapsed identity space — one chain per `authorId`, full stop.**
  /// [listDeviceLogIds] therefore returns raw, potentially-pseudo-device
  /// identities (a real device that has both synced normally and done one
  /// seed import will show up as two entries), *not* an already-collapsed
  /// "physical device" list. The `seed:`/`external:` collapsing convention
  /// is implemented as [collapsePhysicalDeviceIds] below instead — a pure,
  /// documented helper the *caller* opts into, not a rule baked into this
  /// interface or its implementations. Reasoning: this interface's own
  /// framing throughout § 8.1/8.4 is "a generic storage interface" that
  /// only branches on capability flags, never on protocol-layer concepts;
  /// § Architecture 1's `authorId` namespacing is exactly such a
  /// protocol-layer concept (it belongs to the causal-operation model, §
  /// Architecture 2, not to storage), and § 8.1's own text calls baking
  /// that convention into the backend layer a leak of a protocol concept
  /// into what's supposed to be protocol-agnostic — the same reasoning
  /// this design already applies elsewhere (blobs are opaque
  /// content-addressed bytes; `commitBytes` is opaque to the backend too).
  /// Keeping `SyncBackend` ignorant of the `seed:`/`external:` convention
  /// also means a real backend implementation needs zero special-casing to
  /// be conformant — it only ever sees strings, and the collapsing helper
  /// is testable in complete isolation from any backend at all.
  Future<AppendCommitOutcome> appendCommit({
    required String deviceLogId,
    required int deviceSeq,
    required String publishIntentId,
    required String? parentCommitHash,
    required Uint8List commitBytes,
  });

  /// Discover what device-log identities exist at all — the read-side half
  /// of device-membership discovery. Returns **raw** log identities,
  /// including any `seed:`/`external:` pseudo-device entries; see
  /// [collapsePhysicalDeviceIds] and the long comment on [appendCommit]
  /// above for why collapsing is a caller-side concern, not this method's.
  Future<List<String>> listDeviceLogIds();

  /// Returns every commit for `deviceLogId` with `deviceSeq > afterSeq`, in
  /// ascending `deviceSeq` order, up to `limit` if given.
  /// `CommitPage.hasGap` is true iff the returned page is not a contiguous
  /// run starting at `afterSeq + 1` — § Architecture 2/3's no-gap-skipping
  /// property requires the caller to detect this and refuse to apply
  /// anything past the gap, rather than silently skip ahead into
  /// eventually-consistent-listing territory (§ 8.2 fault-injection item
  /// 6).
  Future<CommitPage> readCommits({
    required String deviceLogId,
    required int afterSeq,
    int? limit,
  });

  // --- Content-addressed blobs (§ Architecture 4) -----------------------

  /// Grounds the exact scenario § Architecture 4 names as the root cause of
  /// the round-8 certificate-scope finding: "a device reusing existing
  /// content H, skipping upload because the object already exists" — this
  /// is the check that decision is based on.
  Future<bool> blobExists(String contentHash);

  /// "Uploaded blobs are verified before any referencing commit is
  /// written" (§ Architecture 4). Contract: this does not return
  /// successfully until the backend has confirmed durable receipt *and*
  /// the caller-observable result has been independently confirmed (by
  /// re-hashing the bytes the backend claims to have stored, not by
  /// trusting a backend-reported etag) to match `contentHash`. On any
  /// ambiguity (§ 8.2 items 1-2), this throws rather than returning — there
  /// is no `Ambiguous` outcome type for blobs; the resolution mechanism is
  /// [blobExists], called again by the caller before retrying.
  Future<void> uploadBlob({
    required String contentHash,
    required Stream<List<int>> data,
    required int length,
  });

  /// "Downloaded blobs are always hash-verified" (§ Architecture 4) —
  /// contract: this never returns a stream whose bytes don't hash to
  /// `contentHash`; it throws instead (after fully reading and checking,
  /// not lazily mid-stream, so a caller cannot observe a partially-
  /// consumed, unverified stream as if it were trustworthy).
  Future<Stream<List<int>>> downloadBlob(String contentHash);

  // --- Conditional deletion (§ Architecture 4/6's uniform GC mechanism) -

  /// One method, not separate blob-delete/log-prune-delete methods — both
  /// are described as using "the same uniform policy-based mechanism" (§
  /// Architecture 6, re log pruning reusing § Architecture 4's approach).
  Future<DeleteOutcome> deleteConditionally({
    required BackendRef ref,
    required DeletePrecondition precondition,
  });

  // --- Certified snapshots (§ Architecture 6) ----------------------------

  Future<void> publishSnapshot(String snapshotHash, Uint8List snapshotBytes);

  /// Null iff no snapshot has ever been published for this dataset.
  Future<SnapshotRef?> latestSnapshotRef();

  Future<Uint8List> readSnapshot(String snapshotHash);
}

// ---------------------------------------------------------------------------
// dataset_members / physical-device collapsing convention
// ---------------------------------------------------------------------------

/// Collapses raw log identities (as returned by [SyncBackend.listDeviceLogIds])
/// down to the set of **physical device** identities they belong to, per §
/// Architecture 1's `authorId` convention: `"seed:" + device` and
/// `"external:" + device"` are pseudo-device namespaces owned by an
/// ordinary device identity, not independent dataset members. A dataset
/// with exactly one physical device that has also done one seed import and
/// one external plain-file edit reports three raw log ids but exactly one
/// physical device here.
///
/// This lives outside [SyncBackend] deliberately — see the long comment on
/// [SyncBackend.appendCommit] documenting the `dataset_members` bootstrap
/// decision this helper implements. Callers doing device-membership
/// discovery/display (§ Architecture 9's settings UI, eventually) are
/// expected to call `collapsePhysicalDeviceIds(await backend.listDeviceLogIds())`
/// rather than using the raw list directly.
///
/// Throws [ArgumentError] on a malformed id — a bare `"seed:"` or
/// `"external:"` with no device suffix. Decision: fail loud rather than
/// silently collapsing it to an empty-string "physical device" id.
/// Reasoning: § Architecture 1's own encoding is always `"seed:" +
/// thisDevice` / `"external:" + thisDevice"` — a real `deviceLogId` never
/// has an empty device component, so seeing one here means either a
/// backend implementation bug (an id was stored/returned that doesn't
/// conform to this interface's own convention) or a bug in whatever
/// minted it. An empty-string device id let through silently is exactly
/// the kind of value that causes confusing, hard-to-trace downstream bugs
/// — e.g. two different malformed inputs from different physical devices
/// would incorrectly collapse onto the *same* empty-string "device,"
/// merging two real members into one in the settings UI. Throwing here,
/// at the one place that understands this convention, surfaces the
/// problem immediately instead of letting it manifest as a silent
/// membership-count bug three layers away.
Set<String> collapsePhysicalDeviceIds(Iterable<String> rawDeviceLogIds) {
  const seedPrefix = 'seed:';
  const externalPrefix = 'external:';
  return rawDeviceLogIds.map((id) {
    if (id.startsWith(seedPrefix)) {
      final device = id.substring(seedPrefix.length);
      if (device.isEmpty) {
        throw ArgumentError.value(
          id,
          'rawDeviceLogIds',
          'malformed device-log id: "$seedPrefix" prefix with no device suffix',
        );
      }
      return device;
    }
    if (id.startsWith(externalPrefix)) {
      final device = id.substring(externalPrefix.length);
      if (device.isEmpty) {
        throw ArgumentError.value(
          id,
          'rawDeviceLogIds',
          'malformed device-log id: "$externalPrefix" prefix with no device suffix',
        );
      }
      return device;
    }
    return id;
  }).toSet();
}
