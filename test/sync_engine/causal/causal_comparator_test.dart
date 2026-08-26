// Direct unit tests for `causal_comparator.dart` — the ported
// `dominates()`/`causally_includes'''`/`concurrent`/`hlcTieBreakWins`
// primitives (M2.5, § Architecture 11.4). Pure-function tests: no
// database involved, matching how `test/sync_protocol/model.dart`'s own
// versions are tested (implicitly, via `replica.dart`'s regression suite)
// but exercised directly here per the milestone brief's requirement to
// unit-test the ported comparator in isolation.
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/causal/causal_comparator.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/hlc.dart';

void main() {
  group('dominates', () {
    test('true when the frontier height for the author is >= the seq', () {
      expect(dominates({'A': 5}, 'A', 5), isTrue);
      expect(dominates({'A': 5}, 'A', 3), isTrue);
    });

    test('false when the frontier height is below the seq', () {
      expect(dominates({'A': 2}, 'A', 5), isFalse);
    });

    test('false when the author is absent from the frontier entirely', () {
      expect(dominates({'B': 5}, 'A', 1), isFalse);
      expect(dominates(const {}, 'A', 1), isFalse);
    });
  });

  group('causallyIncludesGenesisAware — no known class (non-alias case)', () {
    test('reduces to the literal dominates() check when yResolvedClassMembers is null', () {
      final yDot = Dot('B', 3);
      expect(
        causallyIncludesGenesisAware(xFrontier: {'B': 3}, yDot: yDot),
        isTrue,
      );
      expect(
        causallyIncludesGenesisAware(xFrontier: {'B': 2}, yDot: yDot),
        isFalse,
      );
    });

    test('reduces to the literal check when the class list is supplied but empty', () {
      final yDot = Dot('B', 3);
      expect(
        causallyIncludesGenesisAware(xFrontier: {'B': 3}, yDot: yDot, yResolvedClassMembers: const []),
        isTrue,
      );
    });
  });

  group('causallyIncludesGenesisAware — genesis alias expansion', () {
    test(
        'Task A motivating scenario: a later edit built on ONE alias of a genesis seed pair is recognized as '
        'causally descending via witness, even with no entry for the OTHER alias\'s author', () {
      // Devices A and B independently seed identical value X (dots seedA,
      // seedB — both "seed:" authored, so the class is genesis). A device
      // mints an ordinary edit Y whose frontier dominates seedA (its own
      // prior seed) but has NO entry at all for seedB's author, since it
      // never observed B. A receiving replica has learned both seeds are
      // aliases of each other (contentKey class = {seedA, seedB}) and must
      // recognize Y as causally descending from "the seed" via the seedA
      // witness, not find it concurrent.
      final seedA = Dot('seed:A', 1);
      final seedB = Dot('seed:B', 1);
      final yFrontier = {'seed:A': 1, 'A': 1}; // no entry for 'seed:B' at all

      expect(
        causallyIncludesGenesisAware(
          xFrontier: yFrontier,
          yDot: seedB, // comparing Y against the seed's canonical/other alias
          yResolvedClassMembers: [seedA, seedB],
        ),
        isTrue,
        reason: 'Y dominates seedA, a witness in seedB\'s genesis class -> causally includes',
      );

      // Sanity: without alias expansion (single-member "class"), the same
      // frontier does NOT dominate seedB directly -- confirms the genesis
      // witness is doing real work, not being trivially true anyway.
      expect(
        causallyIncludesGenesisAware(xFrontier: yFrontier, yDot: seedB, yResolvedClassMembers: [seedB]),
        isFalse,
      );
    });

    test('genesis class with a single currently-known member behaves identically to the non-alias case', () {
      final seedA = Dot('seed:A', 1);
      expect(
        causallyIncludesGenesisAware(xFrontier: {'seed:A': 1}, yDot: seedA, yResolvedClassMembers: [seedA]),
        isTrue,
      );
      expect(
        causallyIncludesGenesisAware(xFrontier: {'seed:A': 0}, yDot: seedA, yResolvedClassMembers: [seedA]),
        isFalse,
      );
    });

    test('alias expansion only fires when EVERY class member is seed-authored', () {
      // Mixed class (one seed-authored, one ordinary device-authored) must
      // NOT be treated as genesis -- falls back to the literal check
      // against y's own dot only.
      final seedA = Dot('seed:A', 1);
      final ordinaryB = Dot('B', 9);
      final xFrontier = {'seed:A': 1}; // dominates seedA, NOT ordinaryB

      expect(
        causallyIncludesGenesisAware(xFrontier: xFrontier, yDot: ordinaryB, yResolvedClassMembers: [seedA, ordinaryB]),
        isFalse,
        reason: 'mixed class is not genesis -> literal dominates(x, ordinaryB) only, which is false',
      );
    });

    test('external-authored classes are never treated as genesis', () {
      final extA = Dot('external:A', 1);
      final extB = Dot('external:B', 1);
      final xFrontier = {'external:A': 1}; // dominates extA, not extB

      expect(
        causallyIncludesGenesisAware(xFrontier: xFrontier, yDot: extB, yResolvedClassMembers: [extA, extB]),
        isFalse,
        reason: 'external: classes are non-genesis -> no alias expansion, documented residual limitation',
      );
    });
  });

  group('concurrent', () {
    test('true when neither side causally includes the other', () {
      final xDot = Dot('X', 1);
      final yDot = Dot('Y', 1);
      expect(
        concurrent(xFrontier: const {}, xDot: xDot, yFrontier: const {}, yDot: yDot),
        isTrue,
      );
    });

    test('false when one side dominates the other', () {
      final xDot = Dot('X', 1);
      final yDot = Dot('Y', 1);
      expect(
        concurrent(xFrontier: {'Y': 1}, xDot: xDot, yFrontier: const {}, yDot: yDot),
        isFalse,
      );
    });
  });

  group('hlcTieBreakWins', () {
    test('higher hlc wins outright', () {
      expect(
        hlcTieBreakWins(
          aHlc: const Hlc(10, 0),
          aDot: Dot('A', 1),
          bHlc: const Hlc(5, 0),
          bDot: Dot('Z', 1),
        ),
        isTrue,
      );
    });

    test('ties on hlc break by authorId, then authorSeq', () {
      expect(
        hlcTieBreakWins(
          aHlc: const Hlc(10, 0),
          aDot: Dot('B', 1),
          bHlc: const Hlc(10, 0),
          bDot: Dot('A', 1),
        ),
        isTrue,
        reason: '"B" > "A" lexicographically',
      );
      expect(
        hlcTieBreakWins(
          aHlc: const Hlc(10, 0),
          aDot: Dot('A', 2),
          bHlc: const Hlc(10, 0),
          bDot: Dot('A', 1),
        ),
        isTrue,
        reason: 'same authorId, higher authorSeq wins',
      );
    });
  });

  group('isSeedAuthor / isExternalAuthor', () {
    test('classify authorId namespaces correctly', () {
      expect(isSeedAuthor('seed:abc'), isTrue);
      expect(isSeedAuthor('external:abc'), isFalse);
      expect(isSeedAuthor('abc'), isFalse);
      expect(isExternalAuthor('external:abc'), isTrue);
      expect(isExternalAuthor('seed:abc'), isFalse);
    });
  });
}
