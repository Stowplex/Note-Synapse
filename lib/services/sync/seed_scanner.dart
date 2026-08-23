// Initial seed scan — M2.10, § Architecture 1 ("Initial seed scan ordering",
// the round-8 canonical operation encoding, the round-14 GENESIS
// `contentKey` formula, and the round-18 corrected minting precondition) of
// the CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// ---------------------------------------------------------------------
// **The gap this closes.**
// ---------------------------------------------------------------------
// M2.4's mutation-capture triggers (`database_service.dart`'s
// `_syncMutationCaptureTriggerStatements`, installed by `_onCreate` and
// `_migrateToVersion57`) fire on INSERT/UPDATE/DELETE and nothing else.
// `_migrateToVersion57` installs them but deliberately does not backfill, so
// every row that already existed when the migration ran has **zero**
// `sync_touch_log` rows. `OutboxDrainer` reads exactly that table, so it
// mints nothing for those rows: sync works perfectly for data created AFTER
// the triggers and not at all for data created before. A user who connects
// Drive and taps "Sync now" on an existing library gets "drained 0, pulled
// 0, pushed 0" — their whole notebook is invisible to the sync engine.
//
// This file is the missing "initial seed scan": a one-per-device walk over
// every row already present in every sync-scope table, minting the
// operations the triggers never got a chance to.
//
// ---------------------------------------------------------------------
// **Author identity: a real `seed:<deviceUuid>` namespace, not a synthetic
// per-event author (round 8).**
// ---------------------------------------------------------------------
// Every operation minted here uses `authorId = "seed:" + deviceId` with a
// real, monotonic, contiguous `authorSeq` from the SAME [SeqCounter]
// primitive an ordinary device operation uses — `mintNextSeq` has always
// been namespace-agnostic for exactly this reason (see its own doc comment,
// which names `"seed:" + device_id` explicitly). This matters structurally,
// not cosmetically: a frontier's `{authorId: maxSeq}` entry means "I have
// observed this author through sequence N, and therefore everything below N
// too", a property that only holds for a genuine counter. Round 7's
// content-hash-derived `authorSeq` broke that outright; round 8 replaced it
// with this. Frontier growth stays bounded by device count (× 3 namespaces),
// never by event count.
//
// `pull_phase.dart` already knows about this namespace
// (`_ownNamespaceIds` excludes `seed:<own>` from being pulled back), and
// `dot.dart` already has `isSeedAuthor`, which `causal_comparator.dart`'s
// genesis-aware alias expansion (`causally_includes'''`) keys off. Nothing
// downstream needed changing to accept these operations.
//
// ---------------------------------------------------------------------
// **HLC: a real one, from this device's own clock — never a placeholder.**
// ---------------------------------------------------------------------
// § 11.2's "load-bearing distinction, stated precisely": § Architecture 1
// calls seed HLCs "decorative", but ONLY for the `contentKey` dedup
// mechanism, whose canonical-winner rule is the purely lexicographic
// `(authorId, authorSeq)` comparison and never consults an HLC at all. The
// moment a seed operation is submitted to ordinary field-conflict
// resolution as a live candidate — which the round-14 "stale seed wins"
// scenario shows happens in real cases — its HLC is exactly as load-bearing
// for the `(hlc, authorId, authorSeq)` tie-break as any ordinary edit's. So
// every operation minted here is stamped with a real [HybridLogicalClock]
// value, from the same per-device clock every other mint in this codebase
// uses.
//
// ---------------------------------------------------------------------
// **The one exception: a POST-RESET re-seed is recessive (M2.13, review
// round 3, finding F1).**
// ---------------------------------------------------------------------
// `DatasetReset` writes `sync_state[postResetRecessiveSeedStateKey]`. While
// it is set, every `field` and `__exists__` operation minted here is stamped
// [Hlc.zero] instead — deliberately the minimum representable value, so it
// LOSES every conflict it is in rather than winning on recency, and decides
// only the content the dataset genuinely lacks (where it is uncontested and
// wins).
//
// **The exact scope, after three rounds of getting it wrong in both
// directions. State it as a list of kinds, not as a slogan:**
//
//   * **`field` — recessive.** This is where F1 travels: a field operation
//     carries a VALUE, and a dominant one republishes stale content over a
//     peer edit this device has not observed yet.
//   * **`__exists__` — recessive** (restored in round 5, after round 4
//     excluded it). Round 3's version of this comment was right that the
//     stamp reaches `materializer.dart`'s creation-timestamp write and
//     wrong that excluding the kind was the remedy: the `__exists__`
//     register also records the WINNER'S DOT, which `_creationDot` and
//     `_generationDot` both read, so a dominant `__exists__` seed silently
//     re-parents every entity's creation dot on every peer. The 1970-01-01
//     problem is fixed in the materializer's own derivation instead. Full
//     argument at the mint site and at `_createdAtFromHlcWall`.
//   * **`set_add` — NOT recessive**, and this is a positive choice rather
//     than an omission. `OrSetResolver` is add-wins plus `contentKey` dedup
//     and never compares an HLC, so the stamp decides nothing there — but it
//     is not inert either: a `set_add`'s `hlc.wallMs` is the fallback source
//     for a membership table's `createdAt` in `_insertMembershipRow`, i.e.
//     exactly the hazard `__exists__` had. A real HLC decides nothing and
//     carries no hazard, so that is what is minted. See
//     [SeedScanner._seedMembershipBatch].
//   * **`set_remove` — not minted by this scanner at all** (a seed describes
//     what exists, never what does not).
//
// The membership consequence of a reset is therefore handled by disclosure,
// not by an HLC: a reset can re-assert a membership a peer deliberately
// removed. That is convergent and lossless, and it is documented in
// `causal/or_set_resolver.dart`, in `dataset_reset.dart`, and in the reset
// confirmation dialog's own text.
//
// **Why the exception does not contradict the paragraph above.** That
// paragraph is about a first-ever seed of content nobody has synced: its HLC
// is a real statement about when this device first knew this value, and the
// round-14 scenario turns on it. A post-reset seed is a *re-statement* of
// content this device already had and, in the diverged case, may already
// have published — the dataset's copy, if it has one, is the authority, and
// there is no version of "when did this device first know this" that a fresh
// clock reading would be telling the truth about. Recessive is the honest
// encoding of "I am not claiming this is new."
//
// **Ordering cannot substitute for it**, which is what the round-2 fix
// (pull before seed for one round) assumed and why it was reproduced
// failing three separate ways — see `dataset_reset.dart`'s F1 section. The
// short version: a device can never know it has observed everything the
// backend holds, so no phase order makes the precondition
// ([_isPristine]) sufficient.
//
// **Scope, and the clock itself.** The marker is cleared in the same
// transaction that writes [seedScanCompletedAtKey] ([_markComplete]), so a
// seed deferred by a `sync_materialize_queue` row stays recessive across
// every round it takes. In recessive mode `generate()` is called only for
// `set_add` — one call per seeded membership, never per field or entity —
// so § 11.2 property (a), monotonicity of this device's own successive
// GENERATED values, is unaffected either way: the clock only ever moves
// forward, and a recessive `field`/`__exists__` seed does not move it at
// all. See [Hlc.zero]'s own doc comment.
//
// **Conversation-mapping ordering (round 14's deliberate exception).** For
// `conversation_message_mapping` the local autoincrement `id` order IS the
// real historical message order (`database_service.dart`'s batch insert
// computes one `createdAt` millisecond outside the insert loop, so several
// mappings genuinely share a millisecond and only insertion order
// distinguishes them — the app's own existing justification for
// `orderBy: 'id ASC'`). Round 8 removed local ids from *ongoing,
// cross-replica-compared* keys, correctly; round 14 restored them for the
// one-time seed-time HLC specifically, because using each device's own real
// local order preserves that device's actual history faithfully and costs
// nothing (convergence is `contentKey`'s job, not the HLC's). This scanner
// gets that property structurally rather than by computing HLCs by hand:
// membership rows are enumerated in `rowid ASC` order (== insertion order
// for these tables) and HLCs are strictly increasing per `generate()` call,
// so seed HLCs come out in real historical order. The same ordering is
// applied uniformly to every membership table since it costs nothing. (This
// property holds for a post-reset seed too, since round 5: membership seeds
// keep a real, strictly increasing HLC even in recessive mode — see
// [SeedScanner._seedMembershipBatch].)
//
// ---------------------------------------------------------------------
// **`contentKey` with `baseContext = "GENESIS"` (round 14).**
// ---------------------------------------------------------------------
// Two devices that independently seed the SAME pre-existing content must
// converge to one canonical operation instead of permanently duplicating
// it. Seed dots are real-device-scoped, so the two operations have
// genuinely different dots; convergence is handled by the orthogonal
// `contentKey` mechanism (`causal/content_key_dedup.dart`, M2.5): identical
// content produces an identical `contentKey`, the lexicographically
// smallest dot in that class wins, and the loser gets a permanent
// `sync_dot_redirects` entry rather than being silently dropped (round 9).
//
// [genesisContentKey] implements § Architecture 1's formula
// `hash(entityUuid + ":" + fieldName [+ ":" + memberUuid] + ":" +
// baseContext + ":" + valueHash)` with `baseContext = "GENESIS"`, the fixed
// sentinel shared by every device seeding the same never-before-synced
// field (there is by definition no prior state to distinguish). The exact
// string hashed is:
//
//     sha256( entityTable ":" entityId ":" fieldName
//             [ ":" memberUuid ] ":" "GENESIS" ":" sha256(valueJson) )
//
// Two deliberate deviations from the doc's literal formula, disclosed
// separately because their standing differs:
//   * The key is **table-qualified** (`entityTable` prefixed). The doc's
//     formula assumes a globally unique `entityUuid`; this codebase has
//     entity ids that are not (`tag_workflow_bindings.pattern` is a
//     free-form pattern), so an unqualified key could collide two genuinely
//     different rows in different tables. **This one has direct precedent**:
//     `test/sync_protocol/conversation_ops.dart`'s validated
//     `genesisContentKey` is table-qualified too, and its own doc comment
//     says so.
//   * `valueHash` is `sha256(valueJson)` rather than the value inlined.
//     **This has NO simulator precedent** — the simulator inlines its
//     values, which are small by construction. It is justified on its own
//     terms rather than by precedent: `notes.content` can be megabytes, and
//     since a `contentKey` is only ever compared for equality against
//     another key computed by this same function, hashing preserves every
//     property the protocol asks of it while keeping the key bounded. The
//     doc's own formula names a `valueHash` component, so this is arguably
//     the literal reading rather than a deviation at all.
//
// ---------------------------------------------------------------------
// **The minting precondition (round 18's corrected gate) — and why it is
// also, by itself, the idempotency mechanism.**
// ---------------------------------------------------------------------
// The Key Lemma requires: *if `d` is a genesis seed of field `(e,g)` minted
// by device `p`, then `d.frontier` dominates no operation on `(e,g)` — by
// any device, including `p` itself.* Round 18 broadened the gate from "no
// existing `sync_field_state` record" to also cover
// `sync_materialize_queue`, because round 14's observation-vs-materialization
// split means a replica's frontier updates on OBSERVATION
// (`pull_phase.dart` bumps `sync_state['frontier:<log>']` unconditionally,
// even for a commit that then blocks) while a materialized-state table need
// not have caught up.
//
// **How that lands in THIS implementation, stated precisely rather than
// restated from the design.** `pull_phase.dart` calls `CausalEngine.apply`
// and `SyncMaterializer.materialize` in that order, inside ONE transaction
// per commit — and `apply` is what writes `sync_field_state` (via
// `recompute` -> `_writeWinner`), while only `materialize` enqueues
// `missing_exists`. So for a `field`/`__exists__` operation the two are
// simultaneous: a blocked field operation has BOTH a `sync_field_state` row
// AND a queue entry, never a queue entry alone. The queue half of this gate
// is therefore currently redundant for field-scoped operations. It is kept,
// for three reasons that are not stylistic: the design mandates it; it is
// the only correct gate the moment apply-and-materialize stop sharing a
// transaction (a plausible future change, since materialization is the
// expensive half); and for MEMBERSHIPS it is genuinely load-bearing today —
// `applySetRemove` deletes `sync_set_state` rows rather than writing one,
// so a `missing_referenced_dot` entry really can be the only local evidence
// that a membership has history.
//
// So [_isPristine] checks BOTH tables: a field/entity/membership is seeded
// only if it has no `sync_field_state`/`sync_set_state` row AND no
// `sync_materialize_queue` entry referencing it.
//
// **For `field` and `__exists__` operations that gate is complete**, and
// the completeness argument is specifically theirs: an arriving
// field-scoped operation either materializes (populating
// `sync_field_state`, win or lose — `field_conflict_resolver.dart`'s
// `recompute` always writes a winner) or fails a named blocking reason and
// enters the queue. There is no third resting state for that kind.
// (`sync_dedup_index`/`sync_dot_redirects` need no separate check: they
// only ever gain an entry for the second-or-later observed member of a
// `contentKey` class, and that class's first-observed member necessarily
// already passed through the ordinary pipeline into one of the two checked
// tables.)
//
// **For `set_add` the same claim would be false, and is not made.** A
// membership genuinely can be observed with neither a `sync_set_state` row
// nor a queue entry: `OrSetResolver.applySetAdd` returns `dedupSkipped` for
// a `contentKey`-deduped add without writing either, and an applied
// `set_remove` deletes the `sync_set_state` row outright. So for
// memberships this gate is a best-effort filter, not a completeness proof —
// which is exactly the status § Architecture 1 assigns it: membership
// seeding needs the gate only for BOUNDEDNESS, never for soundness, since
// OR-Set membership uses no domination-based winner-picking at all (the
// canonical-winner rule plus `sync_dot_redirects` decides it). The worst
// case a missed gate produces there is a duplicate add-dot that resolves
// itself.
//
// This applies to `field` and `__exists__` seeding for a **soundness**
// reason, not merely to avoid duplicates: `__exists__` conflicts follow the
// ordinary path and compete under the same domination-based
// `causally_includes'''` comparator the Key Lemma protects for fields, so
// an under-gated `__exists__` seed risks the identical cyclic-domination
// failure mode. `set_add` seeding is the one genuine exception — OR-Set
// membership never uses domination-based winner-picking at all, so an
// under-gated membership seed could at worst produce a harmless,
// self-resolving duplicate add-dot. The gate is applied uniformly anyway,
// since checking the same two tables for memberships costs nothing.
//
// **Idempotency and resumability, and the mid-flight window.** The
// precondition is not merely *checked* before minting; the very same
// transaction that mints an operation also makes that precondition false,
// because the mint is routed through `CausalEngine.apply` (see below),
// which writes `sync_field_state`/`sync_set_state` for it. Mint and gate
// therefore commit or roll back together. Concretely, the window the brief
// asks about — between an operation being minted and it being
// materialized/pushed — does not exist for this scanner:
//   * A crash/kill anywhere in a scan leaves a prefix of entities fully
//     seeded and the rest untouched (each entity is one transaction). A
//     re-run finds every already-seeded field gated by its own
//     `sync_field_state` row and mints nothing for it.
//   * An operation sitting unpushed in `sync_pending_ops` (Drive
//     unreachable, app killed before Phase A) is still gated, because the
//     gate is `sync_field_state`, not `publishedAt`.
//   * A field seeded here and then edited by the user before the seed was
//     ever pushed is still gated: drain overwrites the `sync_field_state`
//     row with its own ordinary-namespace dot, but the ROW still exists.
//   * The `sync_state` completion marker ([seedScanCompletedAtKey]) is a
//     pure fast path — it lets an already-seeded device skip the walk
//     instead of re-deriving "nothing to do" row by row. Correctness never
//     depends on it: deleting that key and re-running mints nothing new.
//     This is deliberate, per the brief's "do not rely on progress-tracking
//     alone when the precondition can do it correctly."
//
// **Interaction with `clearAllData`, checked rather than assumed.** That
// function wipes `sync_field_state`/`sync_set_state`/`sync_pending_ops` and
// friends but deliberately keeps `sync_state` (device identity, HLC, seq
// counters — see its own doc comment for why). So the completion marker
// survives a clear while the gate tables do not. That is the correct
// outcome and needs no special handling: every app row is gone too, so
// there is nothing left to seed, and anything the user subsequently imports
// arrives through ordinary INSERTs that fire M2.4's triggers and are drained
// normally. (The triggers are real, persistent SQLite triggers, so they fire
// regardless of which code path performs the insert.)
//
// **One disclosed, narrow, non-default-path exception**, for the
// boundedness-only membership case the design already singles out: a
// membership that was seeded and has since been legitimately removed leaves
// neither a real membership row nor a `sync_set_state` row, so a re-scan
// correctly does not resurrect it — UNLESS the marker is manually cleared
// while a pulled `set_remove` is still un-materialized, in which case the
// still-present local row would be seeded a second time. That produces a
// duplicate add-dot, which OR-Set semantics resolve harmlessly (membership
// never uses domination-based winner-picking), never a soundness violation
// — exactly the boundedness-only characterization § Architecture 1 gives
// for `set_add` seeding.
//
// ---------------------------------------------------------------------
// **Why mints are routed through `CausalEngine.apply`.**
// ---------------------------------------------------------------------
// `materializer.dart`'s `_mintAndApplyTagField` (M2.7's auto-merge write
// pair) already established this pattern for the same reason: a locally
// minted `contentKey`-bearing operation must register itself in
// `sync_dedup_index` as the first-seen member of its class, or the device
// will fail to recognize ANOTHER device's identical-`contentKey` operation
// as a duplicate when it later pulls it — each would materialize as an
// independent, permanently-competing candidate, which is exactly the
// duplication the GENESIS sentinel exists to prevent. Routing through the
// engine also gets `sync_field_state`/`sync_set_state` written by the same
// resolvers that write them for remote operations, rather than a second,
// independently-maintained copy of that logic. `test/sync_protocol/
// replica.dart`'s own `_mint` does the same thing (`apply(op); outbox.add
// (op);`).
//
// Nothing here writes to a real app table: the app row IS the source the
// seed was derived from. That also means no capture trigger fires, so a
// seed scan never pollutes `sync_touch_log`.
//
// ---------------------------------------------------------------------
// **M2.12: fields already at the receiving device's own default are not
// seeded at all.**
// ---------------------------------------------------------------------
// Measured on a real first sync of a small library: 22 entities produced
// 152 commits. `tags` spent 2 of every 5 operations on `redirectTarget`
// (always NULL — M1.3 left it unused) and `__deleted__`; `notes` spent
// six of its fourteen on `scheduledAt`/`completeBy`/`status`/
// `completionPercentage`/`recurrenceRule`/`metadata`, all typically NULL.
// Every one of those is a permanent CRDT operation that competes in
// conflict resolution forever, and none of them carries any information:
// the receiving device's row already holds that exact value the moment its
// `__exists__` materializes.
//
// So [_seedEntity] skips a column whose live value equals
// `shellRowValueFor` (`sync_table_shape.dart`) — the SAME function
// `materializer.dart`'s `_materializeExists` uses to fill a shell row, not
// a re-derivation of it, because the skip is only sound if the two agree by
// construction. In particular that is why the rule is stated against the
// SHELL-ROW value rather than the column's raw `PRAGMA table_info`
// `dflt_value`: `tags.__deleted__` has a SQL default of `0` but a shell row
// is force-inserted at `1`, so skipping a live tag's `__deleted__ = 0`
// would leave that tag permanently tombstoned on every peer.
//
// **Why this does not violate "nothing discarded" (requirement 2/3).** The
// principle constrains what the protocol may throw away once it exists; it
// does not oblige the protocol to manufacture an operation for a decision
// nobody made. A field left unset carries no user intent — it is the
// absence of a value, not a chosen one. Concretely, for the adversarial
// case: device A holds `status = NULL`, device B independently holds
// `status = 'done'`, both pre-existing, both seeding.
//   * BEFORE: both mint a GENESIS operation. Their `contentKey`s differ
//     (different values), so dedup does not fire; the two dots are
//     concurrent, and `FieldConflictResolver` picks between them on
//     `(hlc, authorId, authorSeq)` — i.e. on which device's clock happened
//     to be later and, failing that, on a lexicographic device-id
//     comparison. A coin flip decides whether the user keeps `'done'` or
//     silently loses it to a NULL that nobody ever typed.
//   * AFTER: A mints nothing, B's `'done'` wins uncontested, and A
//     materializes it. The user's only actual datum survives, on both
//     devices, deterministically.
// The change therefore removes an opportunity to discard information rather
// than creating one. The genuinely-intentional counterpart — A *clearing* a
// field it had previously set — is not affected at all: that is an ordinary
// post-trigger edit, drained by `outbox_drainer.dart`, which mints an
// explicit set-to-NULL under A's ORDINARY namespace with a real causal
// frontier that dominates whatever it is clearing. The drain path is
// untouched by this milestone, deliberately, and
// `seed_scanner_test.dart`/`outbox_drainer_test.dart` both pin that.
//
// **GENESIS `contentKey` convergence is preserved**, and for a structural
// reason rather than an empirical one: the skip predicate is a pure
// function of `(table, column, live value)` evaluated against the same
// schema, so two devices holding identical content necessarily make
// identical skip decisions and therefore mint the identical SET of
// operations — the same values, hence the same `contentKey`s, hence the
// same dedup classes and the same canonical winners. A skipped field
// contributes no operation on either side and both rows already hold the
// same default, so there is nothing left to converge. (Two devices running
// DIFFERENT schema versions whose default for some column changed between
// them could disagree; the disagreement is benign — the seeding device
// simply transmits a value the other one already had — and is disclosed
// rather than defended against, since a schema migration that changes a
// default already has to reason about existing rows.)
//
// ---------------------------------------------------------------------
// **What is deliberately NOT here.** No `external:` namespace (that is
// requirement 8, plain-file external edits, much later). No Drive folder
// naming/identity changes (M2.11). No encryption, no conflict-resolution
// UI.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'causal/causal_engine.dart';
import 'causal/dot.dart';
import 'dataset_reset.dart';
import 'device_identity.dart';
import 'frontier.dart';
import 'hlc.dart';
import 'seq_counter.dart';
import 'sync_table_shape.dart';

/// § Architecture 1's reserved `baseContext` sentinel for seed operations:
/// "a fixed sentinel shared by every device seeding the same pre-existing,
/// never-before-synced field, since there is by definition no prior state
/// to distinguish."
const String genesisBaseContext = 'GENESIS';

String _sha256Hex(String input) =>
    sha256.convert(utf8.encode(input)).toString();

/// § Architecture 1's `contentKey` formula, `baseContext = "GENESIS"`:
/// `hash(entityUuid + ":" + fieldName [+ ":" + memberUuid] + ":" +
/// baseContext + ":" + valueHash)`. See this file's top doc comment for the
/// two disclosed, equality-only-safe deviations (table qualification, and
/// hashing the value rather than inlining it).
///
/// [valueJson] must be the already-JSON-encoded value, exactly as it is
/// stored in `sync_pending_ops.valueJson`/`sync_field_state.valueJson` —
/// two replicas holding the same logical value must produce the same string
/// here, which the shared `jsonEncode` of the same raw SQLite value gives.
String genesisContentKey({
  required String entityTable,
  required String entityId,
  required String fieldName,
  String? memberUuid,
  required String valueJson,
}) {
  final parts = <String>[
    entityTable,
    entityId,
    fieldName,
    if (memberUuid != null) memberUuid,
    genesisBaseContext,
    _sha256Hex(valueJson),
  ];
  return _sha256Hex(parts.join(':'));
}

/// Summary of one [SeedScanner.scan] call.
class SeedScanResult {
  const SeedScanResult({
    required this.operationsSeeded,
    required this.entitiesScanned,
    required this.membershipsScanned,
    required this.nonPortableTablesSkipped,
    required this.fieldsDeferred,
    required this.completed,
    required this.skippedAlreadyComplete,
    this.fieldsAtDefaultSkipped = 0,
    this.recessive = false,
  });

  /// How many operations this call minted into `sync_pending_ops` — the
  /// number the UI needs so a first sync of a pre-existing library does not
  /// read as "0/0/0" while it is in fact doing all the work.
  final int operationsSeeded;

  /// Rows visited in the entity tables (`syncEntityCaptureScopes`),
  /// regardless of whether anything was minted for them.
  final int entitiesScanned;

  /// Rows visited in the OR-Set membership tables
  /// (`syncSetCaptureScopes`).
  final int membershipsScanned;

  /// Tables skipped wholesale because their primary key is a non-portable
  /// `INTEGER PRIMARY KEY AUTOINCREMENT` — see `hasPortableEntityId`
  /// (`sync_table_shape.dart`), the single shared predicate every minting
  /// and materializing site now uses. Reported so a test can assert the
  /// guard actually fires rather than inferring it from an absence.
  final List<String> nonPortableTablesSkipped;

  /// Fields/memberships skipped because a `sync_materialize_queue` entry
  /// referenced them — a TRANSIENT blocker (a pulled operation waiting on a
  /// prerequisite), unlike a `sync_field_state` row, which is permanent and
  /// correct evidence that the field already has real history. A non-zero
  /// count suppresses the completion marker so the next sync re-checks.
  final int fieldsDeferred;

  /// Whether this call finished a full pass with nothing deferred and no
  /// budget exhaustion — i.e. whether [seedScanCompletedAtKey] was written.
  final bool completed;

  /// True when the scan was skipped outright because
  /// [seedScanCompletedAtKey] was already set (the steady state on any
  /// device that has synced once).
  final bool skippedAlreadyComplete;

  /// M2.12: fields not seeded because their live value already equals what
  /// a receiving device's shell row will hold for that column
  /// (`shellRowValueFor`, `sync_table_shape.dart`). Reported so the saving
  /// is a measured number rather than a claim, and so a regression that
  /// silently stops skipping shows up as a count going to zero rather than
  /// as a slower sync nobody attributes to anything.
  final int fieldsAtDefaultSkipped;

  /// **M2.13.** Whether this pass ran in post-reset RECESSIVE mode — every
  /// minted operation stamped [Hlc.zero] so it loses any field conflict it
  /// is in (see this file's HLC section). Reported rather than inferred so a
  /// test can assert the mode was actually in force, and so a regression
  /// that silently stops applying it shows up as a `false` rather than as a
  /// reverted note nobody attributes to anything.
  final bool recessive;

  static const SeedScanResult noop = SeedScanResult(
    operationsSeeded: 0,
    entitiesScanned: 0,
    membershipsScanned: 0,
    nonPortableTablesSkipped: [],
    fieldsDeferred: 0,
    completed: true,
    skippedAlreadyComplete: true,
  );
}

/// Progress callback payload — emitted once per entity table / membership
/// table finished, so a caller can drive a determinate-ish progress UI
/// without this class knowing anything about Flutter.
class SeedScanProgress {
  const SeedScanProgress({
    required this.table,
    required this.tablesDone,
    required this.tablesTotal,
    required this.operationsSeededSoFar,
  });

  final String table;
  final int tablesDone;
  final int tablesTotal;
  final int operationsSeededSoFar;
}

/// `sync_state` key marking that a full seed pass has completed on this
/// device. Purely a fast path — see this file's top doc comment on why
/// correctness never depends on it.
const String seedScanCompletedAtKey = 'seed_scan_completed_at';

/// Walks every table in [DatabaseService.syncEntityCaptureScopes] /
/// [DatabaseService.syncSetCaptureScopes] and mints the operations M2.4's
/// triggers could never have produced for rows that predate them.
///
/// Safe to call on every sync: the first call does the work, every
/// subsequent one short-circuits on [seedScanCompletedAtKey], and even with
/// that key deleted a re-run mints nothing new (see the top doc comment's
/// idempotency argument).
class SeedScanner {
  SeedScanner(
    this._databaseService,
    this._deviceIdentity,
    this._seqCounter,
    this._hlc, {
    CausalEngine? engine,
  }) : _engine = engine ?? CausalEngine();

  final DatabaseService _databaseService;
  final DeviceIdentity _deviceIdentity;
  final SeqCounter _seqCounter;
  final HybridLogicalClock _hlc;
  final CausalEngine _engine;

  static const String _existsFieldSentinel = existsFieldSentinel;

  /// Column aliases for the membership walk's projected owner/member ids —
  /// named so they can never collide with a real payload column.
  static const String _seedEntityIdAlias = 'seedEntityId';
  static const String _seedMemberIdAlias = 'seedMemberId';

  /// How many membership rows share one transaction. Entity rows get one
  /// transaction each (an entity's `__exists__` plus all its fields belong
  /// together); membership rows are individually tiny, so batching them
  /// keeps transaction overhead sane on a large `note_tags` without
  /// weakening resumability — an interrupted batch simply rolls back whole
  /// and is redone identically on the next run.
  static const int _membershipBatchSize = 100;

  /// The `seed:` namespace this device mints under.
  Future<String> seedAuthorId() async =>
      'seed:${await _deviceIdentity.ensureDeviceId()}';

  /// Runs (or resumes) the seed scan.
  ///
  /// [maxOperations] optionally caps how many operations one call will mint
  /// before stopping early — the scan is fully resumable, so a capped call
  /// simply leaves the rest for the next sync. Defaults to `null` (no cap):
  /// a partial seed is worse UX than a slow first sync, and the real
  /// bottleneck for a large library is Phase A's one-network-round-trip-per-
  /// operation push, not this walk. The parameter exists so a caller that
  /// does want to bound a single round (a future background scheduler) can.
  Future<SeedScanResult> scan({
    int? maxOperations,
    void Function(SeedScanProgress)? onProgress,
  }) async {
    final db = await _databaseService.database;
    if (await _isAlreadyComplete(db)) return SeedScanResult.noop;

    final authorId = await seedAuthorId();

    // Read once per pass, not per mint: `DatasetReset` writes this marker
    // inside its own transaction and only [_markComplete] clears it, so it
    // cannot change under a running scan.
    final recessive = await _isRecessive(db);

    var seeded = 0;
    var entities = 0;
    var memberships = 0;
    var deferred = 0;
    var atDefault = 0;
    var budgetExhausted = false;
    final nonPortable = <String>[];
    final syncabilityCache = <String, EntitySyncability>{};

    final entityScopes = DatabaseService.syncEntityCaptureScopes;
    final setScopes = DatabaseService.syncSetCaptureScopes;
    final tablesTotal = entityScopes.length + setScopes.length;
    var tablesDone = 0;

    /// Emitted for every table the walk finishes, INCLUDING one it skipped —
    /// a skipped table is still one fewer left to do, and swallowing its
    /// callback would make `tablesDone` jump, which is exactly what a
    /// progress UI must not do.
    void reportTableDone(String table) {
      tablesDone++;
      onProgress?.call(
        SeedScanProgress(
          table: table,
          tablesDone: tablesDone,
          tablesTotal: tablesTotal,
          operationsSeededSoFar: seeded,
        ),
      );
    }

    for (final scope in entityScopes) {
      if (budgetExhausted) break;
      // Same syncability gate the drain path and the materializer apply —
      // one predicate, `entitySyncability` (`sync_table_shape.dart`). Seeding
      // a table no receiving device can build would mint an operation per
      // field per row and produce a permanent `missing_exists` entry for
      // each, on every peer.
      final syncability = await entitySyncability(
        db,
        scope,
        cache: syncabilityCache,
      );
      if (!syncability.canSync) {
        nonPortable.add('${scope.table} (${syncability.reasonLabel})');
        reportTableDone(scope.table);
        continue;
      }
      final ids = await _entityIds(db, scope);
      for (final entityId in ids) {
        if (maxOperations != null && seeded >= maxOperations) {
          budgetExhausted = true;
          break;
        }
        final outcome = await db.transaction(
          (txn) => _seedEntity(
            txn,
            authorId: authorId,
            scope: scope,
            syncability: syncability,
            entityId: entityId,
            recessive: recessive,
          ),
        );
        entities++;
        seeded += outcome.$1;
        deferred += outcome.$2;
        atDefault += outcome.$3;
      }
      // Not reported when the budget cut this table off partway: the table
      // is not done, and claiming otherwise would make a resumed scan look
      // like it was re-walking finished work.
      if (!budgetExhausted) reportTableDone(scope.table);
    }

    for (final scope in setScopes) {
      if (budgetExhausted) break;
      // A membership's own `entityId`/`memberUuid` are the OWNING entity's
      // and member's ids, never the membership table's own surrogate key
      // (`conversation_note_mapping.id` is an autoincrement integer, but the
      // dot it seeds is keyed on `conversationId`/`noteId`, both portable
      // uuids). Guarded generically anyway, on the owning entity table, so a
      // future non-portable owner can never slip through the same way
      // `user_app_libraries` did.
      final ownerScope = DatabaseService.syncEntityCaptureScopes
          .where((s) => s.table == scope.entityTable)
          .firstOrNull;
      if (ownerScope != null &&
          !(await entitySyncability(
            db,
            ownerScope,
            cache: syncabilityCache,
          )).canSync) {
        nonPortable.add(scope.membershipTable);
        reportTableDone(scope.membershipTable);
        continue;
      }
      final rows = await _membershipRows(db, scope);
      for (var i = 0; i < rows.length; i += _membershipBatchSize) {
        if (maxOperations != null && seeded >= maxOperations) {
          budgetExhausted = true;
          break;
        }
        final batch = rows.sublist(
          i,
          (i + _membershipBatchSize).clamp(0, rows.length),
        );
        final outcome = await db.transaction(
          (txn) => _seedMembershipBatch(
            txn,
            authorId: authorId,
            scope: scope,
            batch: batch,
          ),
        );
        memberships += batch.length;
        seeded += outcome.$1;
        deferred += outcome.$2;
      }
      if (!budgetExhausted) reportTableDone(scope.membershipTable);
    }

    final completed = !budgetExhausted && deferred == 0;
    if (completed) await _markComplete(db);

    return SeedScanResult(
      operationsSeeded: seeded,
      entitiesScanned: entities,
      membershipsScanned: memberships,
      nonPortableTablesSkipped: List.unmodifiable(nonPortable),
      fieldsDeferred: deferred,
      completed: completed,
      skippedAlreadyComplete: false,
      fieldsAtDefaultSkipped: atDefault,
      recessive: recessive,
    );
  }

  // ── Entity rows: __exists__ + one operation per sync-scope column ─────

  /// Returns `(operationsMinted, fieldsDeferred, fieldsAtDefaultSkipped)`
  /// for one entity row.
  ///
  /// `__exists__` is minted first, then one `field` operation per
  /// [SyncEntityCaptureScope.syncScopeColumns] entry **in list order** —
  /// the same order `OutboxDrainer._processExistsTouch` uses, which is
  /// load-bearing for `tags` specifically (`name`/`color` must materialize
  /// before `__deleted__`/`redirectTarget` so `materializer.dart`'s
  /// liveness-collision check always has the real name to check against;
  /// see that file's own ordering argument). Since `authorSeq` and the HLC
  /// both increase per mint, minting in list order is what preserves that
  /// property on the receiving device.
  Future<(int, int, int)> _seedEntity(
    DatabaseExecutor txn, {
    required String authorId,
    required SyncEntityCaptureScope scope,
    required EntitySyncability syncability,
    required String entityId,
    required bool recessive,
  }) async {
    final rows = await txn.query(
      scope.table,
      where: 'CAST(${scope.idColumn} AS TEXT) = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return (0, 0, 0); // deleted between enumeration and now
    }
    final row = rows.first;
    final columns = await _tableInfo(txn, scope.table);

    var minted = 0;
    var deferred = 0;
    var atDefault = 0;

    final existsState = await _isPristine(
      txn,
      entityTable: scope.table,
      entityId: entityId,
      fieldName: _existsFieldSentinel,
    );
    switch (existsState) {
      case _Pristine.yes:
        // RECESSIVE in recessive mode, like every other `field` operation
        // this scan mints — and getting here took two rounds of being
        // wrong in opposite directions, so both are recorded.
        //
        // **Round 3** made `__exists__` recessive along with everything
        // else, and `materializer.dart`'s `_materializeExists` wrote the
        // operation's `hlc.wallMs` straight into the entity's
        // creation-timestamp column (`syncEntityCreatedAtColumnByTable`,
        // outside every scope's `syncScopeColumns`, so nothing ever
        // corrects it) — dating every rebuilt note, tag, filter and
        // conversation 1970-01-01, permanently, on exactly the flow this
        // milestone exists to serve.
        //
        // **Round 4 fixed that by excluding `__exists__` from the stamp,
        // and that was the wrong place.** The `__exists__` register records
        // the WINNER'S DOT as well as its HLC, and `materializer.dart`
        // reads that dot twice: `_creationDot` feeds § Architecture 10's
        // tag name-collision tie-break, and `_generationDot` is folded into
        // both `contentKey`s `_mintAutoMergeLoserPair` mints, where two
        // devices must agree or the pair fails to dedup. A dominant
        // `__exists__` seed therefore flipped the creation dot of EVERY
        // entity on EVERY peer that pulled a post-reset seed. The round-4
        // justification — "either side of that conflict materializes the
        // identical outcome" — was true of the VALUE (a constant `true`)
        // and silent about the dot.
        //
        // **Round 5** puts the stamp back and fixes the timestamp where it
        // is actually derived: `_materializeExists` now falls back to the
        // receiving device's own clock for a wall-0 operation. See
        // `_createdAtFromHlcWall` in `materializer.dart` for the full
        // weighing, including why carrying the real `createdAt` on the wire
        // was not chosen.
        //
        // **M2.14** replaces the constant `true` with this row's carried
        // owner/identity values (`encodeExistsPayloadJson`). It stays a
        // constant — the bare `true` sentinel — for the ten tables that
        // carry nothing, so every GENESIS `contentKey` already published for
        // `notes`/`tags`/`filters`/`conversations`/`conversation_messages`/
        // `tag_workflow_bindings` is byte-identical before and after, and
        // two devices seeding the same subnote still produce the same key
        // (see [encodeExistsPayloadJson]'s own doc comment for that
        // argument, and for what happens if they ever disagree).
        await _mintAndApplyField(
          txn,
          authorId: authorId,
          kind: '__exists__',
          entityTable: scope.table,
          entityId: entityId,
          fieldName: _existsFieldSentinel,
          valueJson: encodeExistsPayloadJson(
            syncability.existsCarriedColumns,
            row,
          ),
          recessive: recessive,
        );
        minted++;
      case _Pristine.hasHistory:
        break;
      case _Pristine.queued:
        deferred++;
    }

    for (final column in scope.syncScopeColumns) {
      if (!row.containsKey(column)) {
        // Defensive: a scope column that is not in the live schema. The
        // trigger-completeness scanner (`mutation_capture_test.dart`) makes
        // this unreachable today; a seed scan must not crash on schema
        // drift regardless.
        continue;
      }
      final valueJson = jsonEncode(row[column]);

      // M2.12's default-skip. Checked BEFORE `_isPristine`, deliberately:
      // it is a pure in-memory comparison against a `PRAGMA table_info`
      // result already read once per entity, whereas `_isPristine` is two
      // indexed queries per field. On the measured dataset that ordering
      // removes ~40% of this loop's database work as well as ~40% of its
      // operations.
      //
      // Skipping writes NO `sync_field_state` row, and that is correct
      // rather than merely acceptable: `sync_field_state` records "an
      // operation exists for this field," and after a skip none does. The
      // consequences are all the desirable ones — a later real edit to the
      // field drains normally (`_diffAndMaybeMintField` sees no recorded
      // value and mints), a remote non-default value applies uncontested,
      // and a re-run of this scan re-evaluates the same predicate and skips
      // again.
      final shell = shellRowValueFor(
        table: scope.table,
        column: column,
        columns: columns,
      );
      if (shell.known && jsonEncode(shell.value) == valueJson) {
        atDefault++;
        continue;
      }

      final state = await _isPristine(
        txn,
        entityTable: scope.table,
        entityId: entityId,
        fieldName: column,
      );
      switch (state) {
        case _Pristine.yes:
          await _mintAndApplyField(
            txn,
            authorId: authorId,
            kind: 'field',
            entityTable: scope.table,
            entityId: entityId,
            fieldName: column,
            valueJson: valueJson,
            recessive: recessive,
          );
          minted++;
        case _Pristine.hasHistory:
          break;
        case _Pristine.queued:
          deferred++;
      }
    }

    return (minted, deferred, atDefault);
  }

  /// `PRAGMA table_info`, memoized for the life of this scanner instance —
  /// schema shape is immutable for an open database, and the walk asks for
  /// the same table's shape once per entity row.
  final Map<String, List<Map<String, Object?>>> _tableInfoCache = {};

  Future<List<Map<String, Object?>>> _tableInfo(
    DatabaseExecutor txn,
    String table,
  ) async => _tableInfoCache[table] ??= await syncTableInfo(txn, table);

  // ── OR-Set membership rows: one set_add each ─────────────────────────

  /// **Membership seeds are never recessive, even in recessive mode
  /// (M2.13, review round 5) — and the reason is not "the stamp is
  /// harmless", which is what an earlier version assumed.**
  ///
  /// Round 3 stamped `set_add` recessively and round 4 built a rule in
  /// `causal/or_set_resolver.dart` that keyed off the stamp. Round 5
  /// retracted that rule as non-convergent (see that file's "post-reset
  /// re-add" section), which left the stamp with no reader at all as a
  /// tie-break: `OrSetResolver` is add-wins plus `contentKey` dedup and
  /// never compares an HLC.
  ///
  /// It does not follow that keeping it would be inert. A `set_add`'s
  /// `hlc.wallMs` IS read — by `materializer.dart`'s `_insertMembershipRow`,
  /// as the fallback source for a membership table's `createdAt` column. A
  /// `Hlc.zero` stamp there is the same 1970-01-01 defect `__exists__` had,
  /// one layer down, currently masked only by every createdAt-bearing
  /// membership scope declaring `payloadColumns: ['createdAt']` so the
  /// payload always wins first. So the choice is between a stamp that
  /// decides nothing and carries a latent hazard, and a real HLC that
  /// decides nothing and carries none.
  ///
  /// A real HLC is chosen. `generate()` is called once per seeded
  /// membership, exactly as an ordinary (non-reset) seed does — which also
  /// restores the round-14 ordering property (`rowid ASC` enumeration plus
  /// strictly increasing HLCs preserves each device's real historical
  /// membership order) for the post-reset seed rather than flattening it to
  /// a tie. § 11.2 property (a) is untouched either way: the clock only ever
  /// moves forward.
  ///
  /// The membership consequence of a reset is therefore not managed by an
  /// HLC at all; it is the disclosed, convergent re-add residual documented
  /// in `or_set_resolver.dart` and named in `cloudSyncResetConfirm`.
  Future<(int, int)> _seedMembershipBatch(
    DatabaseExecutor txn, {
    required String authorId,
    required SyncSetCaptureScope scope,
    required List<Map<String, Object?>> batch,
  }) async {
    var minted = 0;
    var deferred = 0;
    for (final row in batch) {
      final entityId = row[_seedEntityIdAlias] as String;
      final memberUuid = row[_seedMemberIdAlias] as String;
      final state = await _isPristine(
        txn,
        entityTable: scope.entityTable,
        entityId: entityId,
        fieldName: scope.fieldName,
        memberUuid: memberUuid,
      );
      switch (state) {
        case _Pristine.yes:
          await _mintAndApplySetAdd(
            txn,
            authorId: authorId,
            scope: scope,
            entityId: entityId,
            memberUuid: memberUuid,
            valueJson: encodeSetAddPayloadJson(scope, row),
          );
          minted++;
        case _Pristine.hasHistory:
          break;
        case _Pristine.queued:
          deferred++;
      }
    }
    return (minted, deferred);
  }

  // ── The minting precondition ─────────────────────────────────────────

  /// The round-18 corrected gate. [memberUuid] non-null selects the
  /// `sync_set_state` variant (an OR-Set membership); otherwise
  /// `sync_field_state` (a `field` or `__exists__` register).
  ///
  /// The `sync_materialize_queue` half is checked at
  /// `(entityTable, entityId, fieldName)` granularity — matching how
  /// `materializer.dart`'s `_enqueueMissingExists` and `pull_phase.dart`'s
  /// `missing_referenced_dot` enqueue both populate those three columns —
  /// plus any entry with a NULL `fieldName`, which cannot be ruled out as
  /// unrelated to this field. For memberships that is coarser than strictly
  /// necessary (a queued `set_remove` for a DIFFERENT member of the same
  /// set also defers), which is harmless: membership seeding needs the gate
  /// only for boundedness, and deferring is always the safe direction.
  Future<_Pristine> _isPristine(
    DatabaseExecutor txn, {
    required String entityTable,
    required String entityId,
    required String fieldName,
    String? memberUuid,
  }) async {
    final stateRows = memberUuid == null
        ? await txn.query(
            'sync_field_state',
            columns: const ['fieldName'],
            where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
            whereArgs: [entityTable, entityId, fieldName],
            limit: 1,
          )
        : await txn.query(
            'sync_set_state',
            columns: const ['fieldName'],
            where:
                'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
            whereArgs: [entityTable, entityId, fieldName, memberUuid],
            limit: 1,
          );
    if (stateRows.isNotEmpty) return _Pristine.hasHistory;

    final queued = await txn.query(
      'sync_materialize_queue',
      columns: const ['id'],
      where:
          'entityTable = ? AND entityId = ? AND (fieldName = ? OR fieldName IS NULL)',
      whereArgs: [entityTable, entityId, fieldName],
      limit: 1,
    );
    if (queued.isNotEmpty) return _Pristine.queued;

    return _Pristine.yes;
  }

  // ── Mint + local apply ───────────────────────────────────────────────

  /// Mints one `field`/`__exists__` seed operation into `sync_pending_ops`
  /// and applies it locally through [CausalEngine] — the same
  /// mint-then-apply shape `materializer.dart`'s `_mintAndApplyTagField`
  /// uses, minus its real-table write (the real row is what this value was
  /// read FROM).
  Future<void> _mintAndApplyField(
    DatabaseExecutor txn, {
    required String authorId,
    required String kind,
    required String entityTable,
    required String entityId,
    required String fieldName,
    required String valueJson,
    required bool recessive,
  }) async {
    final authorSeq = await _seqCounter.mintNextSeq(authorId, executor: txn);
    final hlc = await _mintHlc(txn, recessive);
    final frontierJson = await currentFrontierJson(txn, authorId, authorSeq);
    final contentKey = genesisContentKey(
      entityTable: entityTable,
      entityId: entityId,
      fieldName: fieldName,
      valueJson: valueJson,
    );

    await txn.insert('sync_pending_ops', {
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': contentKey,
      'kind': kind,
      'entityTable': entityTable,
      'entityId': entityId,
      'fieldName': fieldName,
      'memberUuid': null,
      'valueJson': valueJson,
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': frontierJson,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'publishedAt': null,
    });

    await _engine.apply(
      txn,
      IncomingOperation(
        dot: Dot(authorId, authorSeq),
        hlc: hlc,
        contentKey: contentKey,
        kind: kind,
        entityTable: entityTable,
        entityId: entityId,
        fieldName: fieldName,
        valueJson: valueJson,
        frontier: _decodeFrontier(frontierJson),
      ),
    );
  }

  /// [valueJson] is the add-event's payload per
  /// [SyncSetCaptureScope.payloadColumns] (the mapping tables' `createdAt`)
  /// or the bare-membership sentinel. It is folded into the `contentKey` AND
  /// carried on the operation itself: keying on a value the operation does
  /// not transmit would leave the fact that decided dedup unrecoverable to
  /// every other replica. `OutboxDrainer._mintSetAdd` writes `null` here for
  /// an ordinary post-trigger add, which is not a divergence — that path has
  /// no payload to carry, and every consumer (`wire_format.dart`,
  /// `OrSetResolver.applySetAdd`, `materializer.dart`'s membership INSERT)
  /// already treats a `set_add` value as optional.
  Future<void> _mintAndApplySetAdd(
    DatabaseExecutor txn, {
    required String authorId,
    required SyncSetCaptureScope scope,
    required String entityId,
    required String memberUuid,
    required String valueJson,
  }) async {
    final authorSeq = await _seqCounter.mintNextSeq(authorId, executor: txn);
    // Always a real HLC — see [_seedMembershipBatch]'s doc comment.
    final hlc = await _hlc.generate(executor: txn);
    final frontierJson = await currentFrontierJson(txn, authorId, authorSeq);
    final contentKey = genesisContentKey(
      entityTable: scope.entityTable,
      entityId: entityId,
      fieldName: scope.fieldName,
      memberUuid: memberUuid,
      valueJson: valueJson,
    );

    await txn.insert('sync_pending_ops', {
      'authorId': authorId,
      'authorSeq': authorSeq,
      'hlc': hlc.toString(),
      'contentKey': contentKey,
      'kind': 'set_add',
      'entityTable': scope.entityTable,
      'entityId': entityId,
      'fieldName': scope.fieldName,
      'memberUuid': memberUuid,
      'valueJson': valueJson,
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': frontierJson,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'publishedAt': null,
    });

    await _engine.apply(
      txn,
      IncomingOperation(
        dot: Dot(authorId, authorSeq),
        hlc: hlc,
        contentKey: contentKey,
        kind: 'set_add',
        entityTable: scope.entityTable,
        entityId: entityId,
        fieldName: scope.fieldName,
        memberUuid: memberUuid,
        valueJson: valueJson,
        frontier: _decodeFrontier(frontierJson),
      ),
    );
  }

  // ── Row enumeration ──────────────────────────────────────────────────

  /// Entity ids only — never the whole row. `notes.content`,
  /// `conversation_messages.metadata` and friends are exactly the columns
  /// CLAUDE.md flags as "can be very large"; holding one table's worth of
  /// them in memory to seed them would be a real regression on a big
  /// library. Each row is re-read individually inside its own transaction
  /// instead, mirroring `OutboxDrainer._currentRow`.
  ///
  /// `rowid ASC` is insertion order; see the top doc comment on why that
  /// matters (conversation-mapping ordering) and why it is applied
  /// uniformly.
  ///
  /// **`rowid` assumption, stated rather than assumed.** A `WITHOUT ROWID`
  /// table has no `rowid` column and this query would throw against one.
  /// No sync-scope table is `WITHOUT ROWID` today (verified by
  /// `seed_scanner_test.dart`'s schema assertion, which fails loudly if one
  /// ever becomes so) — and the fix if that changes is not a fallback here
  /// but a decision about what "insertion order" even means for such a
  /// table, which is exactly the kind of thing that should surface as a
  /// failing test rather than be silently papered over with an
  /// `ORDER BY`-less query.
  Future<List<String>> _entityIds(
    DatabaseExecutor db,
    SyncEntityCaptureScope scope,
  ) async {
    final rows = await db.rawQuery(
      'SELECT CAST(${scope.idColumn} AS TEXT) AS seedEntityId '
      'FROM ${scope.table} ORDER BY rowid ASC',
    );
    return [
      for (final row in rows)
        if (row['seedEntityId'] != null) row['seedEntityId'] as String,
    ];
  }

  /// Membership rows, each carrying its owner id, member id, and whatever
  /// [SyncSetCaptureScope.payloadColumns] names — the payload goes into both
  /// the seed's `contentKey` and the operation itself, so it has to come
  /// back with the row. Unlike the entity walk, the whole row set is read at
  /// once: a membership row is three or four small columns, never a
  /// large-data column. Same `rowid` assumption as [_entityIds] — see there.
  Future<List<Map<String, Object?>>> _membershipRows(
    DatabaseExecutor db,
    SyncSetCaptureScope scope,
  ) async {
    final payloadSelect = [
      for (final column in scope.payloadColumns) ', $column',
    ].join();
    final rows = await db.rawQuery(
      'SELECT CAST(${scope.entityIdColumn} AS TEXT) AS $_seedEntityIdAlias, '
      'CAST(${scope.memberIdColumn} AS TEXT) AS $_seedMemberIdAlias'
      '$payloadSelect '
      'FROM ${scope.membershipTable} ORDER BY rowid ASC',
    );
    return [
      for (final row in rows)
        if (row[_seedEntityIdAlias] != null && row[_seedMemberIdAlias] != null)
          row,
    ];
  }

  // ── Completion marker ────────────────────────────────────────────────

  Future<bool> _isAlreadyComplete(DatabaseExecutor db) async {
    final rows = await db.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [seedScanCompletedAtKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The two `sync_state` keys that put this scan in post-reset recessive
  /// mode. [legacyPullBeforeSeedStateKey] is honoured as well as
  /// [postResetRecessiveSeedStateKey] so a device that took this update
  /// midway through a recovery started by the previous build is not silently
  /// downgraded to dominant seeds — see that constant's doc comment.
  ///
  /// **The legacy key's reach is narrower than "any device mid-recovery",
  /// and its lifetime is not what an earlier note claimed (review round 3,
  /// finding F-E).** The round-2 build cleared its own flag after a single
  /// round, so the only device this rescues is one that reset and completed
  /// *no* sync round before upgrading. And it is not "dead the first time a
  /// seed completes": if the key is present while [seedScanCompletedAtKey] is
  /// already set, [scan] short-circuits on `_isAlreadyComplete` before
  /// reaching [_markComplete], so the stale key survives until the next
  /// reset. Inert — nothing else reads it — but stated accurately here rather
  /// than optimistically.
  static const List<String> _recessiveMarkerKeys = [
    postResetRecessiveSeedStateKey,
    legacyPullBeforeSeedStateKey,
  ];

  Future<bool> _isRecessive(DatabaseExecutor db) async {
    final rows = await db.query(
      'sync_state',
      columns: const ['key'],
      where: 'key IN (?, ?)',
      whereArgs: _recessiveMarkerKeys,
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The HLC one minted seed operation carries.
  ///
  /// In recessive mode this returns [Hlc.zero] **without calling
  /// `generate()`**, which is the whole of why the durable clock is
  /// untouched (§ 11.2 property (a) is about successive generated values).
  /// It also means recessive seed operations do not come out in strictly
  /// increasing HLC order the way ordinary ones do — the round-14
  /// conversation-mapping ordering property above is a property of ordinary
  /// seeds. That costs nothing here: it is a tie among operations that are
  /// all designed to lose, and `contentKey`, not the HLC, is what converges
  /// them.
  Future<Hlc> _mintHlc(DatabaseExecutor txn, bool recessive) async =>
      recessive ? Hlc.zero : await _hlc.generate(executor: txn);

  /// Writes the completion marker **and** clears the post-reset recessive
  /// marker, in one transaction. The two must move together: the recessive
  /// window is exactly "from the reset until the seed genuinely finishes",
  /// and a seed deferred by a `sync_materialize_queue` row takes several
  /// rounds to get there. The round-2 fix this replaced cleared its flag
  /// after ONE round and was defeated by precisely that.
  Future<void> _markComplete(Database db) async {
    await db.transaction((txn) async {
      await txn.insert('sync_state', {
        'key': seedScanCompletedAtKey,
        'value': '${DateTime.now().millisecondsSinceEpoch}',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete(
        'sync_state',
        where: 'key IN (?, ?)',
        whereArgs: _recessiveMarkerKeys,
      );
    });
  }

  static Map<String, int> _decodeFrontier(String json) =>
      (jsonDecode(json) as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v as int),
      );
}

/// Outcome of the minting precondition for one field/membership.
enum _Pristine {
  /// No `sync_field_state`/`sync_set_state` row and no
  /// `sync_materialize_queue` entry — safe to seed.
  yes,

  /// Real, materialized history exists. Permanently not seedable, and
  /// correctly so.
  hasHistory,

  /// A pulled operation referencing this field is parked in
  /// `sync_materialize_queue`. Transient — re-checked on the next scan.
  queued,
}
