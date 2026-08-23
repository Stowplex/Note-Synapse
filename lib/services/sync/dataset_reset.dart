// Sync dataset reset — M2.13. The recovery path § Architecture 11.7 Phase A
// step 3 explicitly declined to design ("`ParentMismatch` on a device's own
// log ... **open for sync-engine design review**, no reconciliation flow for
// it designed yet").
//
// ---------------------------------------------------------------------
// **The dead end this exists to open.**
// ---------------------------------------------------------------------
// Reported from a real device. The user deleted the `Note Synapse Sync`
// folder in Drive to start clean. Afterwards:
//
//   * Settings -> Cloud Sync still said "Ready — This device has joined the
//     sync dataset", because `DatasetBootstrap.currentStatus()` reads one
//     purely local `sync_state` flag and nothing had ever re-checked the
//     backend.
//   * Every sync failed with `PushParentMismatchException(authorId: seed:…,
//     deviceSeq: 150, actualTipHash: '', publishedBeforeHalt: 0)` — local
//     bookkeeping said "my log is 150 commits long", the backend said "that
//     log does not exist".
//
// Halt-not-retarget (§ Architecture 3) was working exactly as designed: it
// refused to write past a mismatch rather than fork the log. But nothing in
// `lib/` could clear the local state that mismatch was measured against, so
// it halted forever. This file is that missing operation, and it is a
// genuinely ongoing scenario rather than an artifact of one user's mistake:
// accidental deletion, a Drive cleanup, a shared-drive reorganisation,
// deliberately starting over, and reinstalling the app all reach it.
//
// ---------------------------------------------------------------------
// **What a reset means, stated as one sentence, because every decision
// below follows from it.**
// ---------------------------------------------------------------------
// *A reset returns this device to the protocol state of a FRESH INSTALL
// that happens to already hold this content.*
//
// That is not a slogan; it is the only post-reset configuration the design
// has actually analysed. "A device with no sync history holding pre-existing
// rows" is precisely what M2.10's seed scan was built for, and every
// argument in `seed_scanner.dart` (the round-18 minting precondition, the
// Key Lemma, GENESIS `contentKey` convergence) is stated for exactly that
// starting point. Any half-measure — keeping some causal positions, keeping
// the author identity, keeping a frontier — produces a configuration nobody
// has reasoned about, and § Architecture 1's Key Lemma is not the kind of
// property to leave to chance.
//
// ===========================================================================
// The `authorSeq`-continuity decision: **(c) mint a fresh `device_id`.**
// ===========================================================================
// § Architecture 1 requires `authorSeq` to be "a real, contiguous, monotonic
// counter", because a frontier's `{authorId: maxSeq}` entry asserts *"I have
// observed this author through N, and therefore everything below N too."* A
// reset has to answer what happens to the counters. Three options, all three
// costed against that semantics rather than against convenience:
//
// **(a) Keep `device_id`, continue `next_seq` (151, 152, …).** Dots stay
// globally unique forever, which is the property that first makes this look
// like the safe choice. It is not, and the disqualifying reason is not the
// theoretical hole at 1..150 — it is what happens to OTHER devices, in this
// codebase's actual code:
//
//   * `pull_phase.dart` tracks each remote log with `sync_state
//     ['frontier:<logId>']` (the `readCommits(afterSeq:)` cursor, a COMMIT
//     position) and `sync_state['pull_tip:<logId>']` (that log's last-seen
//     commit hash). A peer that had already read K commits of log `X` before
//     the folder was deleted still holds both.
//   * Keeping `device_id` means the reset device re-publishes under the SAME
//     log id `X`, and — since the backend copy is gone — necessarily
//     restarts its commit chain at `deviceSeq = 1` with `parentCommitHash =
//     null`.
//   * The peer then calls `readCommits(deviceLogId: 'X', afterSeq: K)`. If
//     the new log is shorter than K it silently returns nothing and the peer
//     never sees any of this device's data again. If it is longer, the peer
//     receives commit K+1, whose `parentCommitHash` cannot match its stored
//     `pull_tip:X`, and `_pullOneLog` throws `SyncChainVerificationException`
//     — which is not caught per-log, so it kills that peer's ENTIRE pull
//     phase, for every log, on every future sync.
//
// So (a) does not merely leave a cosmetic hole in one log; it converts one
// halted device into a second, differently-halted device, with no local
// symptom on the machine that caused it. (The 1..150 hole is real too: a
// frontier entry of 200 would claim observation of operations that never
// existed on the wire. On its own that is survivable — nothing can hold a
// dot in a range no operation ever occupied — but it is a claim the protocol
// would be making falsely, and it is unnecessary.)
//
// **(b) Keep `device_id`, restart `next_seq` at 1.** Contiguity is restored,
// and correctness is destroyed: dots `X#1..150` were published, and a peer
// that pulled them holds them in `sync_field_state`, `sync_dedup_index`,
// `sync_dot_redirects` and `sync_ack_frontier`. Re-minting those same dots
// for DIFFERENT operations means two distinct operations share one identity
// — the one thing a causal engine may never allow. Rejected outright. (It
// also inherits every peer-side failure described under (a).)
//
// **(c) Mint a fresh `device_id`. Chosen.** The new namespaces (`<newUuid>`,
// `seed:<newUuid>`) have never existed, so:
//
//   * Their counters start at 1 and are contiguous by construction. The
//     frontier invariant holds literally, with no hole to reason about.
//   * Their backend logs are empty by construction — which is what makes the
//     reset fix the DIVERGED case as well as the deleted-folder case. Under
//     (a) or (b), a reset performed while the remote log still exists would
//     re-mismatch on the very next push and appear to have done nothing.
//   * Peers have no cursor, no `pull_tip`, and no acked frontier for a log
//     id they have never seen, so they read it from commit 1 with a `null`
//     parent and verify cleanly. The failure mode described under (a) cannot
//     arise.
//   * The old dots are never re-issued, so any peer still holding them
//     stays internally consistent.
//
// **The cost, accepted and handled rather than waved past.** Other devices
// keep a `sync_ack_frontier`/`sync_device_labels` entry for the retired id,
// and this device loses identity continuity. Handled here: this device's own
// label row for the old id is marked `retiredAt` + `isCurrentDevice = 0`
// (the `sync_device_labels` schema has carried `retiredAt` since M1.1 for
// exactly this "tracked even after it stops being active" case), so
// `DeviceIdentity.ensureDeviceId`'s fresh row is the only current one rather
// than the second of two both claiming to be this device. Peers' rows are
// display metadata and inert acknowledgment history; nothing reads them to
// decide what to send, and § 11.1 already documents that cross-device label
// propagation does not exist yet.
//
// **Two unbounded costs (c) introduces, disclosed here because there is no
// mechanism anywhere that reclaims either.**
//
//   * **Frontier/cursor growth.** § Architecture 2 bounds frontier size at
//     `O(devices ever, including retired ones) × 3 namespaces`. Every reset
//     permanently adds two more namespaces (`<newUuid>`, `seed:<newUuid>`)
//     to that count, and every peer keeps a `sync_state['frontier:<log>']`,
//     a `pull_tip:<log>` and a `sync_ack_frontier` row for the retired ones
//     forever — nothing GCs them, and nothing can, since a retired log's
//     dots stay referenceable. A device that is reset repeatedly therefore
//     grows every OTHER device's cursor set monotonically. Bounded by reset
//     count, which is user-driven and expected to be near zero; unbounded in
//     principle.
//   * **Backend logs are never reclaimed.** The retired `<oldUuid>` /
//     `seed:<oldUuid>` logs stay in the backend folder in full. `pull_phase.
//     dart` skips only `_ownNamespaceIds(<newUuid>)`, so after a reset
//     against a LIVE dataset this device pulls its own pre-reset logs back
//     as if they were a peer's — which, since (b) above, is load-bearing
//     rather than merely harmless. The dataset genuinely holds that history,
//     and a recessive seed is defined to lose to whatever the dataset holds;
//     skipping the retired namespaces would make the seed win by DEFAULT
//     against content the backend has, which is the F1 shape aimed at this
//     device's own history. So: **after a reset against a live dataset, this
//     device adopts its own previously-published state wherever the two
//     differ**, and the pre-reset local value is preserved as a
//     `sync_conflict_copies` row rather than dropped. Genuinely unfinished
//     local work is exempt by construction — the re-touch below re-mints it
//     as an ordinary operation with a real HLC, which beats the retired
//     history. Skipping retired namespaces was considered and REJECTED for
//     that reason; the retired id is still recoverable (`sync_device_labels`
//     retains it with `retiredAt` set), so the option stays open. The cost
//     stands: each reset permanently adds to what this device contributes to
//     backend size, with no reclamation path until a log-GC milestone exists.
//
// ---------------------------------------------------------------------
// **Why every causal position is cleared too, not just the identity.**
// ---------------------------------------------------------------------
// A fresh `device_id` alone is not enough, because of `frontier.dart`:
// `currentFrontierJson` stamps each newly-minted operation with every
// `frontier:<log>` row AND every `next_seq:<authorId>` row it can find. Left
// in place, the reset device's re-seeded operations would carry entries
// dominating its own pre-reset operations — and `seed_scanner.dart`'s Key
// Lemma requires the exact opposite: *a genesis seed of field (e,g) must
// dominate NO operation on (e,g), by any device, including itself.* Since a
// reset wipes `sync_field_state`, the seed precondition would pass for
// fields this device has demonstrably observed history for, which is the
// precise configuration the Lemma forbids and the one the genesis-aware
// alias expansion in `causal_comparator.dart` could cycle on.
//
// Clearing them restores the honest claim: after a reset this device asserts
// observation of nothing, which is true of a fresh install, and its
// re-seeded operations are ordinary GENESIS seeds that converge with other
// devices' seeds of the same content through `contentKey` dedup exactly as
// designed.
//
// The consequence, disclosed: this device's re-seeded operations are
// CONCURRENT with (rather than dominating) whatever it published before the
// reset, on any peer that still holds those. Field conflicts there resolve
// on `(hlc, authorId, authorSeq)`, and the seed's HLC is what decides them —
// see (b) below for why that HLC is deliberately the MINIMUM one rather than
// a fresh one, and why the device's preserved clock is nevertheless still
// the one piece of state the reset must not roll back.
//
// ===========================================================================
// **CORRECTION (review round 2, finding F1). The paragraph above used to end
// "…so the user's current content wins the tie-break it should win." That was
// wrong, and dataset-wide destructive.**
// ===========================================================================
// It only holds when the resetting device is the one holding the current
// content. Reproduced with two devices over one `MockSyncBackend`:
//
//     CONTROL (no reset):  A="B NEWER title"   B="B NEWER title"
//     WITH reset on A:     A="original title"  B="original title"
//
// The mechanism is the ORDER of the phases, not the reset's contents. A
// session runs drain -> seed -> pull -> push, and a reset makes every field
// pristine again (`SeedScanner._isPristine` keys on exactly the tables this
// file clears). So the first post-reset round re-seeds this device's own
// local value for EVERY field, with a fresh `_hlc.generate()`, BEFORE it has
// pulled anything. The frontier is empty so nothing dominates, the conflict
// falls to `(hlc, authorId, authorSeq)`, and a fresh HLC always wins. The
// vulnerable set is every field where the backend holds a value this device
// has not yet materialized — i.e. every edit any peer made since this device
// last synced. The resetting device does not merely fail to learn them; it
// republishes its own stale values over them, and the peers then adopt the
// revert.
//
// Two changes close it, and both are required.
//
// **(a) The action is gated to the states where it is the remedy**
// (`CloudSyncStatus.canReset`, `cloud_sync_service.dart`): dataset missing,
// or one of this device's own logs diverged. It used to be offered whenever
// `bootstrapStatus != none`, i.e. on a healthy, Ready, multi-device install,
// which is the configuration that makes the defect reachable at its worst.
// A reset is a recovery operation. There is deliberately NO "start over on a
// healthy dataset" escape hatch — see [DatasetReset] itself for that
// disclosure.
//
// **(b) The post-reset re-seed is RECESSIVE: every operation it mints is
// stamped `Hlc.zero` instead of a fresh `generate()` value, so it loses
// every field conflict it is in rather than winning on recency**
// ([postResetRecessiveSeedStateKey], consumed by `seed_scanner.dart`).
//
// ===========================================================================
// **CORRECTION (review round 3, finding F1 again). (b) used to be "the first
// sync round after a reset pulls BEFORE it seeds". That was the wrong SHAPE
// of fix, not a mis-tuned one, and it was independently reproduced failing.**
// ===========================================================================
// The ordering fix rested on "pull first, so the seed's own precondition
// sees the peer values". The premise is unobtainable: **a device can never
// know it has observed everything the backend holds.** `PullPhase.pull`
// returns normally, with no gap and no error, in at least three ordinary
// (not faulty) situations —
//
//   * `listDeviceLogIds` has not yet listed a peer's log (`files.list` lag);
//   * a page comes back empty, which `_pullOneLog` exits via
//     `if (page.commits.isEmpty) break` with `gapped = false`, so even
//     checking `PullResult.gappedDeviceLogIds` cannot catch it;
//   * `SeedScanner.scan` only writes its completion marker when
//     `!budgetExhausted && deferred == 0`, and `deferred` increments for
//     every field a `sync_materialize_queue` row gates — routine right after
//     a reset, since `missing_exists` arises whenever a field operation is
//     pulled from one log before its `__exists__` arrives from another. So
//     the post-reset seed legitimately spans rounds, and rounds 2..n ran
//     seed-before-pull with the one-round flag long since cleared.
//
// All three were reproduced against this tree, each with a control that
// still shows correct behavior (`dataset_reset_test.dart` section 6b). No
// ordering rule can be sufficient, so the fix moved to the tie-break.
//
// **What "recessive" expresses, stated as semantics rather than as a
// mechanism.** A post-reset seed is a *re-statement of content this device
// already had*, not a new edit. It must not out-rank a real edit it simply
// has not seen yet, whenever that edit turns up. The backend is
// authoritative for whatever it holds; the seed only decides content the
// backend genuinely lacks — which is exactly the deleted-folder case, where
// the backend holds nothing and every seed is uncontested and wins.
//
// **CORRECTION (review round 3, findings F-A and F-B). The paragraph above
// says "the seed only decides content the backend genuinely lacks". That is
// true of `field` operations and was false of the other two kinds, because
// "recessive" had been reasoned about only against the field-conflict path.**
// Both holes were reproduced with controls, and both are closed — but by
// *narrowing* the mechanism's claimed reach, not by widening the stamp:
//
//   * **`__exists__` is no longer stamped recessively at all.** An
//     `__exists__` HLC has a second consumer nobody enumerated:
//     `materializer.dart` writes its `wallMs` into the entity's `createdAt`,
//     a column outside `syncScopeColumns` that no later operation corrects.
//     A recessive `__exists__` dated every note, tag, filter and conversation
//     1970-01-01 on any device rebuilding from the backend — permanent,
//     silent, and on precisely the flow this file exists to serve. Safe to
//     exclude because an `__exists__` seed's value is the constant `true`:
//     either side of that conflict materializes the same outcome, so F1
//     cannot travel through it. (`seed_scanner.dart`'s mint site carries the
//     full argument.)
//   * **A recessive `set_add` decides nothing by itself**, because
//     `OrSetResolver` is add-wins plus `contentKey` dedup and never reads an
//     HLC. So a reset re-minted every live membership under a fresh GENESIS
//     dot, the peer's already-published `set_remove` targeting the *old* dot
//     parked in `missing_referenced_dot` forever, and a tag assignment the
//     user had deliberately removed came back — on both devices. Closed by an
//     explicit rule in `causal/or_set_resolver.dart`: a `set_remove` naming an
//     unseen dot supersedes a member whose live dots are *all* recessive. The
//     stamp is still applied to `set_add` for exactly that reason — it is the
//     marker the rule keys off, not a tie-break input.
//
// Read "recessive" as **recessive wherever the tie-break decides**, plus one
// named rule where it does not. The two rounds it took to get this stated
// accurately are the reason it is spelled out rather than summarised.
//
// **Why `Hlc.zero` specifically, and what it does NOT do.** § 11.2's
// property (a), monotonicity, is about a device's successive *generated*
// values. A recessive seed calls `generate()` only for the `__exists__`
// exclusion above — once per seeded entity, never per field — so the durable
// clock (`sync_state['hlc_wall_ms']`/`['hlc_logical']`) only ever moves
// forward and
// every later `generate()` on this device is unaffected. A peer that merges
// a wall-0 value is unaffected too: `merge` takes `max(physNow, lastWall,
// remoteWall)`, so a 0 can never drag any clock backwards. § 11.2's
// "seed HLCs must be real, never a placeholder" is a rule about the
// *ordinary* seed, whose HLC really is load-bearing in field-conflict
// resolution; this is a deliberate, scoped exception, documented at
// `hlc.dart`'s [Hlc.zero] where a maintainer will find it.
//
// **Ties among recessive seeds converge, and the loser is kept.** Two
// devices that both reset and seed different content for the same field are
// both at HLC 0, so `hlcTieBreakWins` falls through to `(authorId,
// authorSeq)` — a total order over real, distinct dots, so both devices pick
// the same winner. `FieldConflictResolver` retains the loser as a live
// `sync_conflict_copies` row (requirement 2), exactly as it does for any
// other concurrent pair.
//
// **Two asymmetries recessive seeds create, neither of which is a defect but
// neither of which was stated until review round 3 asked (finding F-C).**
//
//   * **A recessive seed loses to an ordinary FIRST-EVER seed, not only to a
//     real edit.** `hlcTieBreakWins` compares the HLC first, and an ordinary
//     seed's HLC is `generate()` ≈ now. So: folder deleted, this device
//     resets and republishes recessively, and the user then installs on a
//     second device from an older local backup and enables sync for the first
//     time — that device's *staler* library wins dataset-wide, and this
//     device's values survive only as conflict copies. Accepted rather than
//     mechanised: distinguishing the two would need a notion of "which
//     library is more current" that this design does not have, and the
//     preserving direction (nothing lost, the loser retained) is the one it
//     already guarantees.
//   * **Two recessive devices decide the whole library on one comparison.**
//     With both at HLC 0 the tie-break falls to `authorId.compareTo`, and
//     that comparison is the *same* for every field, so one device wins
//     everything rather than winning field by field. Deterministic and
//     convergent, which is what correctness requires; it is simply not the
//     "merge" a user might picture. Also accepted, and for the same reason.
//
// **The ordinary, non-reset initial seed is NOT changed.** That is M2.10's
// shipped behavior with a far larger blast radius, and the round-14 "stale
// seed wins" scenario § 11.2 cites is stated about it. The marker this file
// writes is what scopes the change to the post-reset case.
//
// **Scoped to the whole post-reset seed, not to one round.** The marker is
// cleared by `SeedScanner` in the same transaction that writes
// `seed_scan_completed_at` — i.e. exactly when the seed genuinely finishes —
// so a deferred/multi-round seed stays recessive for all of it. That is the
// same defect the ordering fix had, closed at its root rather than by a
// second flag.
//
// **The phase order is back to the documented one.** `SyncSession` runs
// drain -> seed -> pull -> push unconditionally again. Keeping the inversion
// as a traffic optimisation was considered and rejected: it makes the pull
// overwrite a real app row *before* anything mints an operation describing
// what that row held, so for any field whose pre-reset value the dataset no
// longer has an operation for, the local value is destroyed with no dot and
// therefore no conflict copy — the very residual (b) used to need the
// re-touch carry-over to patch. Seeding first mints a candidate for every
// such field, so it either wins uncontested or loses and is preserved. The
// cost of that is real and disclosed: a reset against a live dataset
// re-publishes this device's library once, most of it losing. That is the
// price of requirement 2, and in the deleted-folder case — the primary one —
// it is work that has to happen anyway.
//
// ---------------------------------------------------------------------
// **The re-touch of unfinished local work, which (b) still needs.**
// ---------------------------------------------------------------------
// A recessive seed loses to a peer value. That is right for content this
// device merely *held*, and wrong for an edit the user actually made and
// this device never managed to PUBLISH — the outbox of a device that cannot
// push, i.e. exactly the `deviceLogDiverged` state this reset exists for.
// Such an edit must compete as a real edit.
//
// Three remedies were weighed:
//
//   1. **Seed such a field with a real HLC so it competes.** Rejected: it
//      cannot be targeted. Which fields carried unpublished edits is not
//      knowable from `sync_field_state` after the wipe, so "anyway" means
//      "every field", which is F1 restated.
//   2. **Snapshot pre-pull row values, diff after the pull, file genuine
//      differences as conflict copies.** Rejected, and not for cost. After a
//      reset this device has no record of what it had published, so
//      "local value ≠ pulled value" cannot distinguish "I had an unpublished
//      edit" from "a peer edited a field since I last synced" — the ordinary,
//      lossless case. It would file a conflict copy for every peer edit,
//      i.e. train the user to ignore conflict copies.
//   3. **Accept and disclose.** Rejected as the default-by-laziness answer to
//      a requirement stated as a prohibition.
//
// **What is done instead: the evidence is carried across the reset rather
// than reconstructed after it.** Before the wipe, this file collects the
// identity (never the value) of every field/entity/membership with
// UNFINISHED local work — unprocessed `sync_touch_log` rows, plus
// unpublished `sync_pending_ops` rows in this device's ORDINARY namespace —
// and re-inserts them as fresh, unprocessed touch rows after the wipe. Phase
// 0 (drain) runs first, so the next round re-mints exactly those fields from
// their CURRENT row values under the new identity, as ordinary operations
// with a real dot and a real HLC. The seed then skips them (drain wrote
// `sync_field_state`), so an unpublished edit is an ORDINARY edit rather
// than a recessive seed, and it meets the peer's value on the ordinary
// field-conflict path with `FieldConflictResolver` recording the loser in
// `sync_conflict_copies` — the whole of what requirement 2 asks for. Nothing
// else is re-touched.
//
// **What "the newer HLC wins" does and does not mean here (review round 3,
// finding 3).** The re-mint happens at drain time, so a re-touched edit made
// three weeks ago carries an HLC generated *now* and beats a peer edit from
// yesterday. That is not a bug in this file and it is not real-time recency:
// § 11.3 defers minting to sync time for every operation this engine
// produces, and § 11.7 already discloses the consequence in its own words —
// "an operation's HLC reflects *when it was synced*, not *when it was
// actually edited*". The re-touch inherits that property; it does not
// introduce it. Preserving genuine recency was considered and not done:
// only the `sync_pending_ops` half of the carried set has an original HLC to
// preserve at all (an unprocessed `sync_touch_log` row has a `touchedAt`
// millisecond and no HLC), so honouring it would make the two halves of one
// set behave differently for no principled reason, and would emit an HLC
// below this device's own clock — the one thing the reset's HLC keep-list
// exists to prevent. The claim is corrected instead of the behaviour: the
// re-touched edit wins because it is minted last, and the peer value it beat
// is preserved as a conflict copy.
//
// **`seed:` pending operations are deliberately excluded from that
// carry-over.** A `seed:` operation is not an edit; it is a re-derivable
// snapshot of a pre-existing row, and the seed scan re-derives it from the
// same row with the identical GENESIS `contentKey` on the next round.
// Re-touching it would convert the whole library into ordinary-namespace
// operations and throw away the GENESIS dedup convergence the seed namespace
// exists for. The case where that would matter — a peer holding a value for
// a field this device's seed scan considered never-before-synced — is a
// contradiction in the ordinary path: had this device observed such a value,
// the field would not have been pristine when it was seeded.
//
// **Still not covered, and named rather than left to be rediscovered:** an
// unpublished local DELETION. `sync_grave` is cleared, the row is already
// gone, and `_processSetTouch`/`_processExistsTouch` mint from what exists
// now — so a re-touch of a deleted membership or entity finds nothing to
// describe, the delete is never published, and the pull resurrects it. This
// is the one loss the confirmation dialog names explicitly
// (`cloudSyncResetConfirm`).
//
// ---------------------------------------------------------------------
// **What is preserved — a keep-list of four keys, not a delete-list.**
// ---------------------------------------------------------------------
// `sync_state` is cleared by `DELETE ... WHERE key NOT IN (hlc_wall_ms,
// hlc_logical, drive_root_folder_id, drive_root_folder_name)` rather than
// by enumerating the keys to remove. That
// direction is deliberate: `sync_state` is a deliberately open key/value
// store (`database_service.dart`), and it has already grown `pull_tip:` and
// `commit_seq:` since this engine started. An enumerate-what-to-delete list
// would silently start leaving new keys behind — i.e. would silently stop
// being a reset — whereas enumerating what to KEEP means a newly-added key
// is cleared by default, which is the safe direction for an operation whose
// whole purpose is "forget the sync state."
//
// There are exactly two exceptions, and each has to earn its place.
//
// The HLC is the first, because its two keys are the one piece of sync
// state whose value must never go backwards: § 11.2's clock is
// per-physical-device, not per-identity, and resetting it would let a
// post-reset operation carry an HLC earlier than one this same physical
// device already published, inverting every tie-break that lands on it.
//
// The Drive folder identity (M2.11) is the second: a reset re-runs § 11.1's
// create-or-join against the SAME dataset, and clearing the folder id would
// send that re-run back to resolving by name — the failure mode M2.11 was
// built to remove. Full reasoning on [DatasetReset.preservedSyncStateKeys].
//
// ---------------------------------------------------------------------
// **What is NOT touched, and how that is guaranteed rather than asserted.**
// ---------------------------------------------------------------------
// Not one row of user content. The tables cleared are exactly
// `DatabaseService.syncEntityScopedControlPlaneTablesToWipe` (M1.13/M2.4's
// existing partition of the fifteen sync control-plane tables), plus
// `sync_publish_intent`, plus `sync_state`. No `notes`, `tags`,
// `conversations`, `attachments`, membership or User-App table is named
// anywhere in this file, and `dataset_reset_test.dart` asserts, before and
// after, the row counts of four representative entity tables (`notes`,
// `tags`, `note_tags`, `conversations`) plus one full row column-for-column
// — not of every entity table in the schema. The guarantee that the rest are
// untouched is the structural one above (no such table is named here), not
// the test's coverage.
//
// **One caveat on "not one row of user content", because
// `sync_conflict_copies` is in the wiped list and is not derived state in
// the way its neighbours are.** It is the only local record of edits that
// LOST a field conflict — content the user typed that no app table holds
// any more. Wiping it is still correct here (its rows reference dots and
// frontiers from a causal history this device is discarding, and
// `FieldConflictResolver.recompute` re-reads them as live candidates, so
// keeping them would re-inject operations from the abandoned identity into
// every future recompute), but it is a genuine, permanent loss of
// user-visible history and not a bookkeeping wipe. Nothing renders that
// table yet; the day something does, this line stops being a footnote.
//
// **`sync_touch_log` is cleared and then partially rewritten, and the
// original justification for clearing it outright no longer holds.** It used
// to read: those rows are undrained evidence of local edits, but the edits
// live in the real app rows and the post-reset seed scan reads those rows
// directly, so anything a dropped touch row described is re-derived. That
// argument is false once the seed is RECESSIVE: the seed still re-derives
// the value, but as an operation that deliberately loses, which is the wrong
// standing for an edit the user actually made and this device never got to
// publish. So the unfinished local work is carried across instead — see the
// re-touch section at the top of this file for what is carried, what is not,
// and why.
//
// **`sync_grave` is cleared, and today that is free only by accident.**
// Nothing in `lib/` writes that table yet: it is § Architecture 6's purge
// ledger, and no purge/GC path exists. The moment one does — the first
// milestone that hard-deletes an entity and records it there — a reset will
// silently resurrect every purged entity on the next pull, because the
// device will have forgotten that it ever agreed they were gone. That day is
// the day this line becomes a defect; it is not one now, and the reason it
// is not is worth stating so that whoever adds the first `sync_grave` writer
// finds this note instead of the bug.
//
// **`sync_field_state`/`sync_set_state`/`sync_materialize_queue` being
// cleared is not incidental — it is the half of this operation that makes it
// work at all.** Those three tables ARE `SeedScanner._isPristine`'s
// precondition. A reset that cleared the identity and the tips but left them
// standing would produce a device that re-bootstraps, seeds NOTHING (every
// field reads as "already has history"), pushes nothing, and syncs nothing —
// a worse dead end than the one being fixed, and a silent one. They are in
// the reused list above, and a test drives reset -> sync -> asserts the
// user's notes actually reach the backend rather than asserting the delete
// happened.

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import '../logger_service.dart';
import 'device_identity.dart';
import 'drive_folder_identity.dart';
import 'hlc.dart';

/// `sync_state` key written by [DatasetReset.reset] and consumed by
/// `seed_scanner.dart`: while it is present, every operation the seed scan
/// mints is stamped [Hlc.zero] instead of a fresh `generate()` value, so it
/// loses every field conflict it is in rather than winning on recency.
///
/// Deliberately a durable flag rather than a parameter: the seed that has to
/// be recessive is not necessarily the next call in the same process (the
/// user resets, closes the app, and syncs tomorrow), and recessiveness is a
/// property of the DATABASE's state, not of a call site. It is written inside
/// the reset transaction, after the `sync_state` wipe, so a crash between the
/// wipe and the flag is impossible.
///
/// **Cleared by `SeedScanner` in the same transaction that writes
/// [seedScanCompletedAtKey]**, i.e. exactly when the post-reset seed
/// genuinely finishes — never after one round. A seed deferred by a
/// `sync_materialize_queue` row spans rounds by design, and the round-2 fix
/// this replaced was defeated by exactly that.
///
/// See `dataset_reset.dart`'s F1 section for why the tie-break, and not the
/// phase order, is where this belongs.
const String postResetRecessiveSeedStateKey = 'post_reset_recessive_seed';

/// The key the round-2 (ordering) fix wrote, kept only so a device that is
/// mid-recovery when it takes this update is not silently downgraded to
/// dominant seeds. Nothing writes it any more; `SeedScanner` treats it as
/// equivalent to [postResetRecessiveSeedStateKey] and clears it alongside.
const String legacyPullBeforeSeedStateKey = 'post_reset_pull_before_seed';

/// What one [DatasetReset.reset] call actually did — diagnostics for the
/// log and for tests, not something the UI renders.
class DatasetResetResult {
  const DatasetResetResult({
    required this.previousDeviceId,
    required this.controlPlaneRowsCleared,
    required this.publishIntentsCleared,
    required this.syncStateKeysCleared,
    this.localWorkRetouched = 0,
  });

  /// The `device_id` this device is giving up, or null if it never had one
  /// (a reset performed before the sync engine was ever touched — allowed,
  /// and a no-op in every respect that matters).
  final String? previousDeviceId;

  /// Rows removed across
  /// [DatabaseService.syncEntityScopedControlPlaneTablesToWipe].
  final int controlPlaneRowsCleared;

  final int publishIntentsCleared;

  /// `sync_state` rows removed — everything except the two HLC keys.
  final int syncStateKeysCleared;

  /// Fresh, unprocessed `sync_touch_log` rows written after the wipe, one per
  /// distinct field/entity/membership that had UNFINISHED local work at reset
  /// time (see this file's re-touch section). Zero on a device whose
  /// outbox was empty, which is the ordinary deleted-folder case.
  final int localWorkRetouched;
}

/// Clears this device's local sync control plane so it can re-bootstrap and
/// re-seed from scratch, without touching a single row of user content.
///
/// One transaction: a crash partway through must never leave a device with,
/// say, a new identity but its old tips — which is a state neither this file
/// nor the engine has any recovery story for.
class DatasetReset {
  DatasetReset(this._databaseService);

  final DatabaseService _databaseService;

  /// The only `sync_state` keys a reset preserves. See this file's top doc
  /// comment on why this is a keep-list rather than a delete-list, and why
  /// the HLC specifically must not regress.
  ///
  /// **M2.11 added the two Drive-folder keys, and that is a deliberate
  /// exception to "a newly-added key is cleared by default", so it needs its
  /// reason on the record.** A reset is "forget what this device has already
  /// synced", not "leave the dataset" — `CloudSyncService.resetSyncState`'s
  /// own contract is that the device afterwards re-runs § 11.1's
  /// create-or-join "against whatever is actually in Drive". Clearing the
  /// folder id would make that re-run resolve by NAME again, which is the
  /// behaviour M2.11 exists to remove: a user who reset because one of their
  /// logs diverged, and who had at some point renamed the folder in Drive,
  /// would have a second, empty dataset built beside their real one and be
  /// told it was Ready. Keeping the id means that reset rejoins the same
  /// folder, by id, regardless of what it is called now.
  ///
  /// **The deleted-folder case is not stranded by this**, which is the
  /// obvious worry: post-reset bootstrap re-reads the marker, the recorded
  /// id resolves to a definitive 404, and `initializeDatasetOnce` — the one
  /// caller entitled to (see
  /// `GoogleDriveBackend._ensureRootFolderForDatasetCreation`) — builds a
  /// fresh folder, reusing the preserved NAME so the user's choice is not
  /// silently lost along with it.
  ///
  /// **What preservation must NOT be allowed to mean, found in M2.11's
  /// second review round (finding F1).** "The reset rejoins the same folder"
  /// is right when the recorded folder is the right one and wrong when it is
  /// not — and the id can be wrong two ways (a device that created its own
  /// folder because discovery found nothing; a valid-but-wrong pasted id).
  /// As shipped, preservation combined with a setup dialog gated on
  /// `folderId == null` meant the post-reset create-or-join silently skipped
  /// the question and built *another* new folder, so a reset was not a way
  /// out of either. Preservation is kept — it is still the right default —
  /// but the reset is no longer the last word: `cloud_sync_screen.dart`
  /// re-opens its folder dialog for any device that is not `ready`,
  /// pre-filled with this preserved pair, so accepting it keeps the
  /// behaviour described above and changing or clearing it is now possible.
  static const List<String> preservedSyncStateKeys = [
    hlcWallStateKey,
    hlcLogicalStateKey,
    driveRootFolderIdStateKey,
    driveRootFolderNameStateKey,
  ];

  Future<DatasetResetResult> reset() async {
    final db = await _databaseService.database;
    return db.transaction((txn) async {
      final previousDeviceId = await _readDeviceId(txn);

      // Read BEFORE the wipe, obviously — but also inside the same
      // transaction, so the collected set and the wipe cannot disagree about
      // what existed.
      final unfinished = await _collectUnfinishedLocalWork(
        txn,
        previousDeviceId,
      );

      var controlPlaneRows = 0;
      for (final table
          in DatabaseService.syncEntityScopedControlPlaneTablesToWipe) {
        controlPlaneRows += await txn.delete(table);
      }

      // Not in the reused list (it is not entity-scoped, so `clearAllData`
      // correctly leaves it alone) but unambiguously dead here: every row is
      // a publish-retry marker naming a `(authorId, deviceSeq)` position in
      // a log this device is about to stop writing to forever.
      final intents = await txn.delete('sync_publish_intent');

      final stateKeys = await txn.delete(
        'sync_state',
        where:
            'key NOT IN (${List.filled(preservedSyncStateKeys.length, '?').join(',')})',
        whereArgs: preservedSyncStateKeys,
      );

      // Written AFTER the wipe above, which would otherwise delete it — the
      // keep-list is deliberately a keep-list, so a key this operation itself
      // needs to survive has to be (re)written rather than exempted. See
      // [postResetRecessiveSeedStateKey].
      await txn.insert('sync_state', {
        'key': postResetRecessiveSeedStateKey,
        'value': '${DateTime.now().millisecondsSinceEpoch}',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Re-touch exactly the fields/entities/memberships that had unfinished
      // local work, so Phase 0's drain re-mints them as ORDINARY operations
      // with real HLCs — the one class of post-reset value that must compete
      // rather than defer. See this file's re-touch section.
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final touch in unfinished) {
        await txn.insert('sync_touch_log', {
          'entityTable': touch.entityTable,
          'entityId': touch.entityId,
          'fieldName': touch.fieldName,
          'memberUuid': touch.memberUuid,
          'touchedAt': now,
          'processedAt': null,
        });
      }

      // Retire the identity rather than deleting its label row: § Architecture
      // 2's boundedness claim is explicitly "O(devices ever, including retired
      // ones)", and `retiredAt` exists so a retired device stays distinct
      // instead of vanishing. Clearing `isCurrentDevice` is the part that
      // matters operationally — `DeviceIdentity` will insert a fresh row with
      // `isCurrentDevice = 1` on the next touch, and two rows both claiming to
      // be the current device would be a display bug with no owner.
      if (previousDeviceId != null) {
        await txn.update(
          'sync_device_labels',
          {
            'isCurrentDevice': 0,
            'retiredAt': DateTime.now().millisecondsSinceEpoch,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'deviceId = ?',
          whereArgs: [previousDeviceId],
        );
      }

      LoggerService.info(
        'DatasetReset: cleared local sync state (previous device id: '
        '${previousDeviceId ?? '<none>'}, $controlPlaneRows control-plane '
        'rows, $intents publish intents, $stateKeys sync_state keys, '
        '${unfinished.length} unfinished local edit(s) re-touched). User '
        'content untouched; a fresh device id will be minted on next use, '
        'and the re-seed is recessive until it completes.',
      );

      return DatasetResetResult(
        previousDeviceId: previousDeviceId,
        controlPlaneRowsCleared: controlPlaneRows,
        publishIntentsCleared: intents,
        syncStateKeysCleared: stateKeys,
        localWorkRetouched: unfinished.length,
      );
    });
  }

  Future<String?> _readDeviceId(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [deviceIdStateKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Every field/entity/membership this device had started but not finished
  /// publishing, as touch-row shapes. **Identities only — never values.** The
  /// value is re-read from the live row by the drain, which is the same
  /// "re-derived from the current value it described" property
  /// `sync_touch_log` has always had, and is what keeps this bounded on a
  /// library whose `notes.content` can be megabytes.
  ///
  /// Two sources, unioned:
  ///
  ///  * **Unprocessed `sync_touch_log` rows** — edits captured by M2.4's
  ///    triggers that no drain has reached yet.
  ///  * **Unpublished `sync_pending_ops` rows in the ORDINARY namespace** —
  ///    edits already drained into the outbox that push never landed. This is
  ///    the set that matters for the `deviceLogDiverged` case, where the
  ///    device has been unable to publish for some time. `seed:`/`external:`
  ///    namespaces are excluded on purpose (see the re-touch section).
  ///
  /// A `kind = '__exists__'` pending operation maps to a `fieldName IS NULL`
  /// touch — the whole-row shape `OutboxDrainer._processExistsTouch` handles,
  /// which re-mints the `__exists__` sentinel plus every sync-scope column.
  /// That breadth is correct here and nowhere else: an unpublished
  /// `__exists__` means no peer has this entity at all, so there is no peer
  /// value for the re-minted fields to override.
  Future<List<_TouchShape>> _collectUnfinishedLocalWork(
    DatabaseExecutor txn,
    String? previousDeviceId,
  ) async {
    final rows = <Map<String, Object?>>[
      ...await txn.query(
        'sync_touch_log',
        columns: const ['entityTable', 'entityId', 'fieldName', 'memberUuid'],
        where: 'processedAt IS NULL',
      ),
      if (previousDeviceId != null)
        ...await txn.rawQuery(
          'SELECT entityTable, entityId, '
          "CASE WHEN kind = '__exists__' THEN NULL ELSE fieldName END "
          'AS fieldName, memberUuid FROM sync_pending_ops '
          'WHERE publishedAt IS NULL AND authorId = ?',
          [previousDeviceId],
        ),
    ];

    // Deduplicated: a field can appear in both sources (drained into the
    // outbox, then edited again), and re-touching it twice would only make
    // the drain do the same no-op comparison twice.
    final seen = <String>{};
    final shapes = <_TouchShape>[];
    for (final row in rows) {
      final shape = _TouchShape(
        entityTable: row['entityTable'] as String,
        entityId: row['entityId'] as String,
        fieldName: row['fieldName'] as String?,
        memberUuid: row['memberUuid'] as String?,
      );
      if (seen.add(shape.key)) shapes.add(shape);
    }
    return shapes;
  }
}

/// One `sync_touch_log` row's identifying columns.
class _TouchShape {
  const _TouchShape({
    required this.entityTable,
    required this.entityId,
    required this.fieldName,
    required this.memberUuid,
  });

  final String entityTable;
  final String entityId;
  final String? fieldName;
  final String? memberUuid;

  String get key => '$entityTable $entityId $fieldName $memberUuid';
}
