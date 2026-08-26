// A causal dot: (authorId, authorSeq) — § Architecture 1/2 of the
// CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// Direct port of `test/sync_protocol/model.dart`'s `Dot`/`isSeedAuthor`/
// `isExternalAuthor` — M2.5, § Architecture 11.4's "local causal engine"
// milestone. Kept byte-identical in behavior to the abstract simulator's
// version (comparison, equality, hashing) since every downstream piece of
// the ported algorithm (dedup canonical-winner rule, `causally_includes'''`,
// the SCC/`chainDom` field-conflict resolver) depends on `Dot`'s exact
// ordering and equality semantics matching what `replica.dart` was proven
// correct against.

/// A causal dot: the pair `(authorId, authorSeq)` that uniquely identifies
/// one minted operation. `authorId` is a real device id, `"seed:<device>"`,
/// or `"external:<device>"` (§ Architecture 1's canonical operation
/// encoding). Comparison is the lexicographic tie-break used throughout the
/// protocol (canonical-winner rule, cycle tie-break, auto-merge tie-break).
class Dot implements Comparable<Dot> {
  final String authorId;
  final int authorSeq;

  const Dot(this.authorId, this.authorSeq);

  @override
  bool operator ==(Object other) =>
      other is Dot &&
      other.authorId == authorId &&
      other.authorSeq == authorSeq;

  @override
  int get hashCode => Object.hash(authorId, authorSeq);

  @override
  int compareTo(Dot other) {
    final c = authorId.compareTo(other.authorId);
    if (c != 0) return c;
    return authorSeq.compareTo(other.authorSeq);
  }

  bool operator <(Dot other) => compareTo(other) < 0;
  bool operator <=(Dot other) => compareTo(other) <= 0;
  bool operator >(Dot other) => compareTo(other) > 0;
  bool operator >=(Dot other) => compareTo(other) >= 0;

  @override
  String toString() => '$authorId#$authorSeq';
}

/// Whether an authorId denotes a genesis-seed author (`"seed:<device>"`).
/// Genesis-class contentKey classes (all members seed-authored) are the
/// only ones eligible for alias-expansion in `causallyIncludesGenesisAware`
/// (§ Architecture 1's `causally_includes'''`).
bool isSeedAuthor(String authorId) => authorId.startsWith('seed:');

/// Whether an authorId denotes an external-edit author
/// (`"external:<device>"`).
bool isExternalAuthor(String authorId) => authorId.startsWith('external:');
