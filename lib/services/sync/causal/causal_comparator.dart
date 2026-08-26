// The causal comparator — § Architecture 2's closed-form `dominates()` and
// § Architecture 1's `causally_includes'''` (the genesis-seed-target-only
// alias-expansion rule, proven safe by direct construction in round 14/17-18
// of the design doc), ported byte-for-byte from
// `test/sync_protocol/model.dart`'s `dominates`/`hlcTieBreakWins` and
// `test/sync_protocol/replica.dart`'s `causallyIncludes`/`concurrent`.
//
// M2.5, § Architecture 11.4 ("local causal engine"). Deliberately a set of
// pure functions taking already-parsed frontier maps / dot lists — never
// something that queries the database itself — so it stays exactly as
// directly unit-testable as the abstract simulator's own version, per the
// milestone brief ("This should be a pure Dart function taking parsed
// frontier maps, not something that itself queries the database").
//
// **Why `causallyIncludesGenesisAware` is NOT called by the SCC/`chainDom`
// field-conflict resolver (`field_conflict_resolver.dart`).** Reading
// `replica.dart`'s actual code (not just its doc comments) shows
// `_groupDominates` — the primitive the SCC/`chainDom` algorithm is built
// on — does NOT call the top-level `causallyIncludes` function at all. It
// implements its own direct "does the source group's unioned frontier
// dominate ANY locally-known member of the target group" check via plain
// `dominates()`, for every group regardless of whether it's genesis or not
// — see `field_conflict_resolver.dart`'s own doc comment for the traced
// justification (hand-verified against the "Task A" regression scenario).
// This file's `causallyIncludesGenesisAware` is still required and ported
// faithfully: it is `replica.dart`'s own standalone, independently
// meaningful primitive (used elsewhere, e.g. `simulator.dart`'s GC checks),
// and the milestone brief explicitly requires porting `dominates()` and
// `causallyIncludes` as their own testable unit, replaying the
// genesis-alias-expansion scenario against it directly.

import '../hlc.dart';
import 'dot.dart';

/// `dominates(X.frontier, authorA, seqN)` — § Architecture 2's closed-form
/// causal comparator, minus baseline-snapshot lookup (this milestone's
/// frontiers are always the observation-based delta only — no snapshot/
/// baseline-flattening mechanism exists yet, § Architecture 6's future
/// work; `outbox_drainer.dart`'s own frontierJson convention is already
/// exactly this flat `{authorId: maxSeq}` shape, with no baseline wrapper).
bool dominates(Map<String, int> frontier, String authorA, int seqN) {
  final h = frontier[authorA];
  if (h == null) return false;
  return h >= seqN;
}

/// `causally_includes'''(X, Y)` — direct port of `replica.dart`'s
/// `causallyIncludes(Operation x, Operation y)`.
///
/// The abstract simulator resolves `y`'s contentKey equivalence class via
/// its own permanent, in-memory `contentKeyClass` registry. This function
/// takes that resolved class membership as an explicit parameter
/// ([yResolvedClassMembers]) instead of looking it up itself, so it stays a
/// pure function — the caller (§ `content_key_dedup.dart`/
/// `field_conflict_resolver.dart`, or a future recheck-completeness
/// caller) is responsible for resolving "every locally-known member of
/// y's contentKey class" from whatever real, SQL-backed candidate set it
/// has in hand.
///
/// Pass `null` (or an empty list) when `y` has no `contentKey`, or when the
/// caller has no known class members for it — this exactly matches
/// `replica.dart`'s own gate (`if (ck != null) { final cls = ...; if (cls
/// != null && cls.isNotEmpty) { ... } }`): only when class membership is
/// both present and known does genesis alias-expansion get a chance to
/// fire, and even then only when every known member is seed-authored.
bool causallyIncludesGenesisAware({
  required Map<String, int> xFrontier,
  required Dot yDot,
  List<Dot>? yResolvedClassMembers,
}) {
  if (yResolvedClassMembers != null && yResolvedClassMembers.isNotEmpty) {
    final isGenesis = yResolvedClassMembers.every(
      (d) => isSeedAuthor(d.authorId),
    );
    if (isGenesis) {
      for (final d in yResolvedClassMembers) {
        if (dominates(xFrontier, d.authorId, d.authorSeq)) return true;
      }
      return false;
    }
  }
  return dominates(xFrontier, yDot.authorId, yDot.authorSeq);
}

/// `concurrent(X, Y) := !causally_includes'''(X,Y) && !causally_includes'''(Y,X)`
/// — direct port of `replica.dart`'s `concurrent`.
bool concurrent({
  required Map<String, int> xFrontier,
  required Dot xDot,
  List<Dot>? xResolvedClassMembers,
  required Map<String, int> yFrontier,
  required Dot yDot,
  List<Dot>? yResolvedClassMembers,
}) {
  final xIncludesY = causallyIncludesGenesisAware(
    xFrontier: xFrontier,
    yDot: yDot,
    yResolvedClassMembers: yResolvedClassMembers,
  );
  if (xIncludesY) return false;
  final yIncludesX = causallyIncludesGenesisAware(
    xFrontier: yFrontier,
    yDot: xDot,
    yResolvedClassMembers: xResolvedClassMembers,
  );
  return !yIncludesX;
}

/// The ordinary field-conflict / cycle-edge tie-break: higher
/// `(hlc, authorId, authorSeq)` wins — direct port of `model.dart`'s
/// `hlcTieBreakWins(Operation a, Operation b)`, generalized over any
/// `(hlc, dot)` pair rather than a concrete `Operation` type so this file
/// has no dependency on the candidate-row shape (`field_candidate.dart`)
/// used elsewhere in this package.
bool hlcTieBreakWins({
  required Hlc aHlc,
  required Dot aDot,
  required Hlc bHlc,
  required Dot bDot,
}) {
  if (aHlc != bHlc) return aHlc > bHlc;
  final c = aDot.authorId.compareTo(bDot.authorId);
  if (c != 0) return c > 0;
  return aDot.authorSeq > bDot.authorSeq;
}
