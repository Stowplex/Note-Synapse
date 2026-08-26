// The real-engine analog of `test/sync_protocol/tag_ops.dart`'s `TagEngine`
// — same operations (create/merge/restore/genericUndelete/
// resolveAllNameCollisions), driving a `RealReplica` (`real_replica_
// adapter.dart`) instead of a `Replica`, so `randomized_test.dart`'s own
// tag/merge/collision generator can be replayed against the real,
// SQL-backed `CausalEngine` for M2.8's differential-testing suite.
//
// One deliberate, disclosed representational difference from the abstract
// `TagEngine.createTag`, required for fidelity to the REAL schema rather
// than a shortcut around it: the abstract model bundles a tag's `name`/
// `color` INSIDE its single `__exists__` operation's `value` map
// (`replica.mintExists(..., value: {'name': name, 'color': color})`) — a
// simulator convenience with no real-schema analog. The real engine (per
// the M2.7 `tags.name`/`color` fix, § Architecture 11.6(e)'s addendum)
// captures `name`/`color` as their OWN ordinary `field`-kind operations,
// separate from the `__exists__` sentinel — exactly what `OutboxDrainer.
// _processExistsTouch`'s real diff loop over `syncScopeColumns` actually
// produces in production, in the same documented order (name, then color,
// then `__deleted__`/`redirectTarget` — see `syncEntityCaptureScopes`'s
// `tags` entry in `database_service.dart`). `createTag` below mints in
// that exact real order, not the abstract model's bundled shape.
import 'dart:convert';

import 'real_replica_adapter.dart';

/// Mirrors `tag_ops.dart`'s `EffectiveTagState`.
class RealEffectiveTagState {
  RealEffectiveTagState(this.effectiveRedirectTarget, this.effectiveDeleted, this.cycleLosers);

  final Map<String, String?> effectiveRedirectTarget;
  final Map<String, bool> effectiveDeleted;
  final Set<String> cycleLosers;
}

class RealTagEngine {
  RealTagEngine(this.replica);

  final RealReplica replica;
  int _tagCounter = 0;

  // ---- raw reads (async — real sync_field_state reads, not in-memory maps) ----

  Future<bool> rawDeleted(String tagId) async {
    final v = await fieldValue<bool>('tags', tagId, '__deleted__');
    return v ?? false;
  }

  Future<String?> rawRedirectTarget(String tagId) => fieldValue<String>('tags', tagId, 'redirectTarget');

  Future<String?> tagName(String tagId) => fieldValue<String>('tags', tagId, 'name');

  Future<(String authorId, int authorSeq)?> creationDot(String tagId) async {
    final row = await replica.fieldStateRow('tags', tagId, '__exists__');
    if (row == null) return null;
    return (row['authorId'] as String, row['authorSeq'] as int);
  }

  /// All tag ids this replica has ever observed a `__exists__` operation
  /// for — mirrors `TagEngine.allTagIds`.
  Future<Set<String>> allTagIds() async {
    final rows = await replica.db.query(
      'sync_field_state',
      columns: const ['entityId'],
      where: 'entityTable = ? AND fieldName = ?',
      whereArgs: ['tags', '__exists__'],
    );
    return {for (final r in rows) r['entityId'] as String};
  }

  Future<T?> fieldValue<T>(String table, String id, String field) async {
    final row = await replica.fieldStateRow(table, id, field);
    if (row == null) return null;
    final valueJson = row['valueJson'] as String?;
    if (valueJson == null) return null;
    return jsonDecode(valueJson) as T?;
  }

  // ---- creation / merge / restore / undelete -----------------------------

  /// Real-schema-faithful port of `TagEngine.createTag` — see this file's
  /// top doc comment for why the mint SHAPE differs from the abstract
  /// model (separate `name`/`color` field ops, real production order),
  /// even though the net EFFECT (a new, live, named/colored tag) is the
  /// same operation this method's abstract counterpart performs.
  ///
  /// **A second, related adapter-fidelity fix, also found and fixed
  /// empirically (not assumed safe) via the same throwaway-reproduction
  /// process as the partial-sync deviation documented in
  /// `differential_random_test.dart`'s top doc comment.** The abstract
  /// `TagEngine.createTag` mints 3 operations, each its OWN, separately-
  /// incrementing HLC tick (`_nextHlc()` is called once per `mint*` call,
  /// with no override). A first version of this method minted 5 SEPARATE
  /// ticks (one per op) — structurally correct per-op, but it meant the
  /// real side's per-device HLC counter raced ahead of the abstract side's
  /// by 2 extra ticks per tag creation, so by the time later, genuinely
  /// CONCURRENT candidates on two different devices needed an HLC tie-
  /// break, the two systems' RELATIVE ordering of those candidates'
  /// absolute HLC values could legitimately differ (both self-consistent
  /// per-system, but disagreeing on which side "wins" the tie-break) —
  /// found via an instrumented reproduction of a real observed
  /// disagreement (a `tags.__deleted__` retained-conflict-set mismatch),
  /// traced to exactly this HLC-drift mechanism, not to any resolution-
  /// algorithm defect. **Fix**: `name`/`color` reuse the EXACT SAME HLC
  /// tick as `__exists__` (via `hlcOverride`) rather than each consuming
  /// their own — treating all three as one bundled "tag creation" event
  /// for HLC-ticking purposes, mirroring how the abstract model bundles
  /// them into a SINGLE `mintExists` call (and therefore a single tick) in
  /// the first place. `__deleted__`/`redirectTarget` still each get their
  /// own fresh tick, exactly matching the abstract model's own 2nd/3rd
  /// `mintField` calls — so both systems consume EXACTLY 3 HLC ticks per
  /// `createTag`, keeping every device's HLC counter in lockstep with its
  /// abstract counterpart for the rest of the scenario.
  Future<String> createTag(String name, {String color = 'blue'}) async {
    final newId = '${replica.id}-tag-${_tagCounter++}';
    final existsOp = await replica.mintExists(table: 'tags', entityId: newId, value: true);
    final sharedTick = existsOp.hlc.wallMs;
    await replica.mintField(table: 'tags', entityId: newId, field: 'name', value: name, hlcOverride: sharedTick);
    await replica.mintField(table: 'tags', entityId: newId, field: 'color', value: color, hlcOverride: sharedTick);
    await replica.mintField(table: 'tags', entityId: newId, field: '__deleted__', value: false);
    await replica.mintField(table: 'tags', entityId: newId, field: 'redirectTarget', value: null);
    await resolveAllNameCollisions();
    return newId;
  }

  Future<void> tagMerge(String fromId, String toId) async {
    await replica.mintField(table: 'tags', entityId: fromId, field: 'redirectTarget', value: toId);
    await replica.mintField(table: 'tags', entityId: fromId, field: '__deleted__', value: true);
  }

  Future<void> restoreTag(String tagId) async {
    await replica.mintField(table: 'tags', entityId: tagId, field: '__deleted__', value: false);
    await replica.mintField(table: 'tags', entityId: tagId, field: 'redirectTarget', value: null);
    await resolveAllNameCollisions();
  }

  Future<void> genericUndelete(String tagId) async {
    await replica.mintField(table: 'tags', entityId: tagId, field: '__deleted__', value: false);
    await resolveAllNameCollisions();
  }

  /// Direct port of `TagEngine.resolveAllNameCollisions` / `_mintAutoMerge
  /// WritePair` — same generation-marked `contentKey` formula (§
  /// Architecture 10's rounds 18-19), same deterministic-by-creation-dot
  /// tie-break, reading real `sync_field_state` instead of in-memory maps.
  Future<void> resolveAllNameCollisions() async {
    final state = await computeEffectiveState();
    final byName = <String, List<String>>{};
    for (final id in await allTagIds()) {
      if (state.effectiveDeleted[id] != false) continue;
      final name = await tagName(id);
      if (name == null) continue;
      byName.putIfAbsent(name, () => []).add(id);
    }
    for (final group in byName.values) {
      if (group.length <= 1) continue;
      final dots = <String, (String, int)>{};
      for (final id in group) {
        dots[id] = (await creationDot(id))!;
      }
      group.sort((a, b) {
        final da = dots[a]!;
        final db_ = dots[b]!;
        final c = da.$1.compareTo(db_.$1);
        if (c != 0) return c;
        return da.$2.compareTo(db_.$2);
      });
      final winnerId = group.first;
      for (final loserId in group.skip(1)) {
        await _mintAutoMergeWritePair(loserId, winnerId);
      }
    }
  }

  Future<void> _mintAutoMergeWritePair(String loserId, String winnerId) async {
    if (await rawRedirectTarget(loserId) == winnerId) return;

    final deletedRow = await replica.fieldStateRow('tags', loserId, '__deleted__');
    final existsRow = await replica.fieldStateRow('tags', loserId, '__exists__');
    final trigger = deletedRow ?? existsRow;
    final generation = trigger == null ? '' : '${trigger['authorId']}#${trigger['authorSeq']}';

    await replica.mintField(
      table: 'tags',
      entityId: loserId,
      field: 'redirectTarget',
      value: winnerId,
      contentKey: 'autoTagMerge:redirectTarget:$loserId:$winnerId:$generation',
    );
    await replica.mintField(
      table: 'tags',
      entityId: loserId,
      field: '__deleted__',
      value: true,
      contentKey: 'autoTagMerge:deleted:$loserId:$generation',
    );
  }

  // ---- derived effective state: three-state cycle-suppression walk ------

  /// Direct port of `TagEngine.computeEffectiveState`'s white/gray/black
  /// functional-graph walk.
  Future<RealEffectiveTagState> computeEffectiveState() async {
    final ids = (await allTagIds()).toList();
    final rawTarget = <String, String?>{};
    final rawDel = <String, bool>{};
    for (final id in ids) {
      rawTarget[id] = await rawRedirectTarget(id);
      rawDel[id] = await rawDeleted(id);
    }

    final color = <String, int>{}; // 0 implicit(white), 1=gray, 2=black
    final loserSet = <String>{};

    for (final start in ids) {
      if ((color[start] ?? 0) != 0) continue;
      final path = <String>[];
      var cur = start;
      while (true) {
        final c = color[cur] ?? 0;
        if (c == 2) break;
        if (c == 1) {
          final idx = path.indexOf(cur);
          final cycle = path.sublist(idx);
          await _suppressLowestRankedEdge(cycle, loserSet);
          break;
        }
        color[cur] = 1;
        path.add(cur);
        final next = rawTarget[cur];
        if (next == null || !ids.contains(next)) break;
        cur = next;
      }
      for (final n in path) {
        color[n] = 2;
      }
    }

    final effRedirect = <String, String?>{};
    final effDeleted = <String, bool>{};
    for (final id in ids) {
      if (loserSet.contains(id)) {
        effRedirect[id] = null;
        effDeleted[id] = false;
      } else {
        effRedirect[id] = rawTarget[id];
        effDeleted[id] = rawTarget[id] != null ? true : rawDel[id]!;
      }
    }
    return RealEffectiveTagState(effRedirect, effDeleted, loserSet);
  }

  Future<void> _suppressLowestRankedEdge(List<String> cycle, Set<String> loserSet) async {
    String? loser;
    Map<String, Object?>? loserRow;
    for (final from in cycle) {
      final redirectRow = await replica.fieldStateRow('tags', from, 'redirectTarget');
      if (redirectRow == null) continue;
      if (loserRow == null || !_hlcTieBreakWins(redirectRow, loserRow)) {
        loserRow = redirectRow;
        loser = from;
      }
    }
    if (loser != null) loserSet.add(loser);
  }

  /// Direct port of `hlcTieBreakWins` (`model.dart`), reading `sync_field_
  /// state`'s own `hlc`/`authorId`/`authorSeq` columns — `hlc` is stored as
  /// the zero-padded `"<wall>:<logical>"` string (`Hlc.toString`), which
  /// sorts lexicographically exactly like numeric comparison would (see
  /// `hlc.dart`'s own doc comment) — a plain `String.compareTo` is
  /// therefore a faithful, real-schema equivalent of the abstract model's
  /// `int` comparison.
  bool _hlcTieBreakWins(Map<String, Object?> a, Map<String, Object?> b) {
    final ahlc = a['hlc'] as String;
    final bhlc = b['hlc'] as String;
    if (ahlc != bhlc) return ahlc.compareTo(bhlc) > 0;
    final aAuthor = a['authorId'] as String;
    final bAuthor = b['authorId'] as String;
    final c = aAuthor.compareTo(bAuthor);
    if (c != 0) return c > 0;
    return (a['authorSeq'] as int) > (b['authorSeq'] as int);
  }
}
