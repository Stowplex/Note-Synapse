// Abstract protocol model for the Note Synapse cloud-sync M0 validation
// harness. This implements the causal dot/frontier machinery and the
// canonical operation encoding specified in
// .claude/plans/plan-and-propse-the-glistening-dolphin.md (§ Architecture 1-2)
// so it can be exercised by a randomized simulator and by bounded exhaustive
// interleaving tests. It is intentionally a standalone model, not tied to
// the real app's database layer — M0 validates the protocol on paper and
// in simulation before any schema/implementation work begins.

/// A causal dot: (authorId, authorSeq). Comparison is the lexicographic
/// tie-break used throughout the protocol spec (canonical-winner rule,
/// cycle tie-break, auto-merge tie-break).
class Dot implements Comparable<Dot> {
  final String authorId;
  final int authorSeq;

  const Dot(this.authorId, this.authorSeq);

  @override
  bool operator ==(Object other) =>
      other is Dot && other.authorId == authorId && other.authorSeq == authorSeq;

  @override
  int get hashCode => Object.hash(authorId, authorSeq);

  @override
  int compareTo(Dot other) {
    final c = authorId.compareTo(other.authorId);
    if (c != 0) return c;
    return authorSeq.compareTo(other.authorSeq);
  }

  bool operator <(Dot other) => compareTo(other) < 0;

  @override
  String toString() => '$authorId#$authorSeq';
}

/// Whether an authorId denotes a genesis-seed author ("seed:<device>").
/// Genesis-class contentKey classes (all members seed-authored) are the
/// only ones eligible for alias-expansion in `causallyIncludes` below.
bool isSeedAuthor(String authorId) => authorId.startsWith('seed:');

bool isExternalAuthor(String authorId) => authorId.startsWith('external:');

enum OpKind { exists, field, setAdd, setRemove }

/// The canonical operation encoding (§ Architecture 1). `frontier` is the
/// minting replica's observation-based delta frontier at creation time
/// (baseline/snapshot flattening is elided in this abstract model — it
/// only affects log-pruning/compaction, explicitly out of scope for the
/// causal-comparator and tag-merge properties under test here).
class Operation {
  final String authorId;
  final int authorSeq;
  final int hlc;
  final String? contentKey;
  final OpKind kind;
  final String entityTable;
  final String entityId;
  final String? fieldName; // or memberUuid for set ops
  final dynamic value; // valueJson | blobHash, present for exists/field/setAdd
  final List<Dot>? targetDots; // present only for setRemove
  final Map<String, int> frontier; // observation-based delta frontier

  Operation({
    required this.authorId,
    required this.authorSeq,
    required this.hlc,
    this.contentKey,
    required this.kind,
    required this.entityTable,
    required this.entityId,
    this.fieldName,
    this.value,
    this.targetDots,
    required this.frontier,
  });

  Dot get dot => Dot(authorId, authorSeq);

  /// entityTable:entityId:fieldName key used for field-conflict resolution.
  String get fieldKey => '$entityTable:$entityId:${fieldName ?? "__exists__"}';

  @override
  String toString() =>
      'Op($dot $kind $fieldKey=$value ck=$contentKey hlc=$hlc)';
}

/// dominates(X.frontier, authorA, seqN) — § Architecture 2's closed-form
/// causal comparator, minus baseline-snapshot lookup (elided, see above).
bool dominates(Map<String, int> frontier, String authorA, int seqN) {
  final h = frontier[authorA];
  if (h == null) return false;
  return h >= seqN;
}

/// The ordinary field-conflict / cycle-edge tie-break: higher
/// (hlc, authorId, authorSeq) wins. Used both for ordinary field conflict
/// resolution and for selecting a cycle's loser edge (the *lower*-ranked
/// edge, i.e. the one for which this returns false against its rival).
bool hlcTieBreakWins(Operation a, Operation b) {
  if (a.hlc != b.hlc) return a.hlc > b.hlc;
  final c = a.authorId.compareTo(b.authorId);
  if (c != 0) return c > 0;
  return a.authorSeq > b.authorSeq;
}
