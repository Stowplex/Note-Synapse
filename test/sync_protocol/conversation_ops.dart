// Conversation-message mapping ordering (§ Architecture 10 of the plan —
// search "Conversation-mapping ordering, corrected in round 8" and the
// following "Round 14 correction" paragraph). A mapping ("message M
// belongs to conversation C") is an OR-Set membership entity, built on
// `Replica.mintSetAdd`/`setState` exactly like tag-collision machinery is
// built on `fieldState` (`tag_ops.dart`) — this file is that OR-Set
// membership entity's analog: a thin engine wrapping a `Replica`, plus a
// derived read for its effective order.
//
// Two genuinely different ordering concerns are involved, and the plan is
// explicit they must be kept separate:
//
//   1. The ONGOING, cross-replica-compared ordering key —
//      `(createdAtMillis, conversationId, messageId)`, same-millisecond
//      ties broken by the SORTED TUPLE of the mapping's own stable UUIDs,
//      never any local/replica-specific value. `effectiveOrder` below is
//      this key, materialized as a read.
//
//   2. The one-time SEED-TIME `hlc` computation, used only when
//      bootstrapping pre-existing local data into sync for the first
//      time: the seed op's `hlc` may safely use the device's own real
//      local batch-insert order (ties within a shared `createdAtMillis`
//      broken by the local autoincrement `id`'s insertion rank,
//      `database_service.dart:~332`/`~4588`) — safe specifically because
//      HLC is decorative for a contentKey-deduplicated seed operation
//      (§ Architecture 1: HLC never needs to match across replicas for
//      the same logical event to converge, only `contentKey` matching
//      does that work). `seedBatch` below is this computation.
//
// If two replicas hold genuinely different local content for what
// otherwise looks like "the same" mapping — a real but narrow edge case:
// divergent pre-existing `createdAtMillis` recorded independently on two
// devices before sync ever existed for the identical (conversationId,
// messageId) pair — their seed ops get DIFFERENT `contentKey`s (the
// formula's `valueHash` differs) and are correctly NOT deduplicated: both
// add-dots stay permanently live (a harmless, self-resolving OR-Set
// duplicate, § Architecture 1's round-18 boundedness note — "an
// under-gated membership seed can produce at most a harmless duplicate
// add-dot, never a soundness violation"). `effectiveOrder`'s per-member
// resolution then applies the SAME lexicographically-smallest-
// `(authorId, authorSeq)`-wins comparator already established as the
// canonical-winner rule (§ Architecture 1) — generalized here from "pick
// the canonical dot among same-contentKey aliases" to "pick the canonical
// dot among whichever add-dots are live for one member" — to deterministically
// pick ONE device's recorded `createdAtMillis` for display, on every
// replica, once both incarnations are known. This is judged a reasonable,
// product-acceptable resolution (§ plan, round 14): "some device's real
// history wins, rather than an arbitrary uuid-sort that preserves
// neither" — not a bug to fix further.

import 'model.dart';
import 'replica.dart';

class ConversationMappingEngine {
  final Replica replica;
  ConversationMappingEngine(this.replica);

  static const String table = 'conversation_message_mapping';

  /// The round-14 GENESIS `contentKey` formula (§ Architecture 1's
  /// `hash(entityUuid + ":" + fieldName [+ ":" + memberUuid] + ":" +
  /// baseContext + ":" + valueHash)`, `baseContext="GENESIS"`) applied to
  /// a mapping: `entityUuid`=conversationId, `fieldName`=table (this
  /// entity's own kind, since a mapping has no scalar field of its own to
  /// name), `memberUuid`=messageId, `valueHash`=createdAtMillis. The
  /// concatenation below puts `table` first, matching `mintSeed`'s own
  /// established precedent in `regression_test.dart` (`'$table:$id:
  /// $field:GENESIS:$value'`) rather than the spec formula's literal
  /// component order — harmless, since a `contentKey` is only ever
  /// compared for exact string equality by this same function on every
  /// replica, never parsed back into its components. Two replicas seeding
  /// the identical logical mapping (same conversationId/messageId/
  /// createdAtMillis) share this key and converge via the ordinary
  /// contentKey-dedup + canonical-winner mechanism (`replica.dart`'s
  /// `apply`); two replicas seeding genuinely different `createdAtMillis`
  /// for the same (conversationId, messageId) do not, per this file's
  /// header comment.
  static String genesisContentKey(String conversationId, String messageId, int createdAtMillis) =>
      '$table:$conversationId:$messageId:GENESIS:$createdAtMillis';

  /// Mints a single genesis seed set-add for one pre-existing mapping.
  /// [hlcOverride] is the seed-time HLC (point 2 above) — ordinarily
  /// supplied by [seedBatch]'s local-batch-insert-order computation, not
  /// chosen ad hoc; an ordinary, post-sync-era add should use
  /// [addMapping] instead, never this.
  Operation seedMapping(Replica onto, {
    required String conversationId,
    required String messageId,
    required int createdAtMillis,
    required int hlcOverride,
  }) =>
      onto.mintSetAdd(
        table: table,
        id: conversationId,
        memberUuid: messageId,
        value: createdAtMillis,
        contentKey: genesisContentKey(conversationId, messageId, createdAtMillis),
        authorNamespace: 'seed:${onto.id}',
        hlcOverride: hlcOverride,
      );

  /// Seeds a whole locally-pre-existing batch of mappings at once —
  /// models the real app's batch-insert path
  /// (`database_service.dart:~332`'s `insertConversationMessageMappingsBatch`),
  /// where every mapping in one call shares the IDENTICAL `createdAt`
  /// millisecond (computed once, outside the insert loop) and
  /// `messageIds` arrive in the caller's real intended order — which
  /// becomes each row's local autoincrement `id` order.
  ///
  /// [localInsertOrder] is THIS device's own real local insertion order
  /// for the batch (messageIds, first-inserted first) — consulted ONLY to
  /// compute each mapping's seed-time `hlc` tiebreak (point 2): the i-th
  /// entry gets `hlc = baseHlc + i`. This never feeds into the mapping's
  /// identity, its `contentKey`, or the ongoing cross-replica ordering key
  /// ([effectiveOrder]) — exactly the round-8 fix's point (dropping local-
  /// id dependency from the synced key) combined with the round-14
  /// correction (restoring it for the decorative seed-hlc only).
  List<Operation> seedBatch(Replica onto, {
    required String conversationId,
    required int createdAtMillis,
    required List<String> localInsertOrder,
    required int baseHlc,
  }) {
    final ops = <Operation>[];
    for (var i = 0; i < localInsertOrder.length; i++) {
      ops.add(seedMapping(
        onto,
        conversationId: conversationId,
        messageId: localInsertOrder[i],
        createdAtMillis: createdAtMillis,
        hlcOverride: baseHlc + i,
      ));
    }
    return ops;
  }

  /// An ordinary, live (post-sync-era) mapping add — no seed namespace, no
  /// contentKey: a single real event, exactly like `TagEngine.createTag`'s
  /// ordinary field writes need no dedup machinery at all.
  Operation addMapping(Replica onto, {
    required String conversationId,
    required String messageId,
    required int createdAtMillis,
  }) =>
      onto.mintSetAdd(table: table, id: conversationId, memberUuid: messageId, value: createdAtMillis);

  /// Whether [messageId] currently, effectively belongs to [conversationId]
  /// — an ordinary OR-Set membership read (mirrors `Replica.setContains`).
  bool contains(String conversationId, String messageId) => replica.setContains(table, conversationId, messageId);

  /// Point 1's ordering key, materialized as a read: every live member of
  /// [conversationId], ordered by `(createdAtMillis, conversationId,
  /// messageId)` — same-millisecond ties broken by the sorted
  /// `(conversationId, messageId)` tuple (conversationId is constant
  /// across one call, so this reduces to a plain messageId sort, but is
  /// written out per the spec's literal key). Never consults `hlc`, a
  /// dot's `authorId`, or any other local/replica-specific value for the
  /// tie-break — only the mapping's own stable identity — so this is
  /// identical across any replica holding the same converged membership
  /// set, regardless of each replica's own local seed-time HLC/insert
  /// order (point 2 is a purely local, decorative concern that never
  /// leaks into this key).
  ///
  /// When a member has more than one live add-dot (the divergent-
  /// `createdAtMillis` edge case, header comment above), the dot chosen to
  /// supply that member's `createdAtMillis` is the lexicographically
  /// smallest by `(authorId, authorSeq)` — the same canonical-winner
  /// comparator `Dot.compareTo` already implements — deterministic and
  /// identical on every replica once all live dots are known there.
  List<String> effectiveOrder(String conversationId) {
    final members = replica.setState['$table:$conversationId'] ?? const <String, Set<Dot>>{};
    final resolved = <MapEntry<String, int>>[]; // messageId -> createdAtMillis
    for (final entry in members.entries) {
      final messageId = entry.key;
      final dots = entry.value;
      if (dots.isEmpty) continue; // no live add-dot: not currently a member
      // Canonicalize every raw dot through `resolveDot` before comparing.
      // `setState` only ever retains whichever specific alias happened to
      // materialize FIRST on THIS replica — the contentKey dedup fast path
      // (`apply()`) skips re-materializing a later-arriving alias even when
      // it's the lexicographically-smaller (true canonical) one, recording
      // only a `dotRedirects` entry instead. Left unresolved, two replicas
      // can hold DIFFERENT raw representative dots for the SAME logical
      // contentKey group (whichever each happened to materialize first),
      // and comparing those raw dots' authorIds directly against another
      // group's dot can flip the cross-group tie-break winner depending on
      // which replica is asking — exactly the cross-replica divergence
      // this key's own contract forbids. `_allKnownOps` (and therefore
      // `operationForDot`) is populated unconditionally for every applied
      // dot regardless of materialization outcome, so resolving first and
      // reading through the canonical dot is always available and correct.
      final canonicalDots = dots.map(replica.resolveDot).toSet();
      var winner = canonicalDots.first;
      for (final d in canonicalDots.skip(1)) {
        if (d.compareTo(winner) < 0) winner = d;
      }
      final createdAtMillis = replica.operationForDot(winner)!.value as int;
      resolved.add(MapEntry(messageId, createdAtMillis));
    }
    resolved.sort((a, b) {
      final byCreatedAt = a.value.compareTo(b.value);
      if (byCreatedAt != 0) return byCreatedAt;
      return a.key.compareTo(b.key); // sorted-uuid-tuple tiebreak (conversationId constant here)
    });
    return resolved.map((e) => e.key).toList();
  }
}
