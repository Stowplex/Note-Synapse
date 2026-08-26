// Operation-to-commit-bytes wire format — M2.6, § Architecture 11.5 of the
// CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// `SyncBackend.appendCommit`'s cleartext framing (`deviceLogId`, `deviceSeq`,
// `publishIntentId`, `parentCommitHash`) is already fixed by
// `sync_backend.dart` and is never part of `commitBytes` — this file owns
// only what's *inside* `commitBytes`: a JSON envelope,
// `commitBytes = utf8.encode(jsonEncode(envelope))`, matching § 11.5's exact
// field list: `v`, `authorId`, `authorSeq`, `hlc`, `contentKey`, `kind`,
// `entityTable`, `entityId`, `fieldName`, `memberUuid`, `value`, `blobHash`,
// `targetDots`, `frontier`.
//
// **`authorId`/`authorSeq` are redundant with the cleartext `deviceLogId`/
// `deviceSeq` framing, deliberately** (§ 11.5): a decoded [WireOperation]
// never needs its envelope back in scope, and the redundancy buys a free
// integrity check at decode time — [decodeCommitBytes] asserts
// `decoded.authorId == expectedAuthorId && decoded.authorSeq ==
// expectedAuthorSeq`, throwing [WireFormatIntegrityException] rather than
// silently trusting mismatched framing.
//
// **No separate binary version/length prefix** — `"v": 1` inside the JSON is
// sufficient (§ 11.5: "this codebase has no existing binary-framing
// precedent to be consistent with, and JSON stays human-readable in logs and
// tests. Treated as a resolved decision, not left open"). [decodeCommitBytes]
// throws [WireFormatIntegrityException] on any `v` other than
// [wireFormatVersion] rather than silently attempting a best-effort parse.
//
// **The one real encoding subtlety: `value` vs. `valueJson`.** Every other
// column in this codebase (`sync_pending_ops.valueJson`,
// `sync_field_state.valueJson`, ...) stores an *already JSON-encoded*
// string (e.g. `jsonEncode("hello")` == the 2-character-longer string
// `"\"hello\""`). § 11.5's sample envelope shows `"value": "New title"` —
// the DECODED value nested directly in the envelope, not a JSON string
// containing an escaped JSON string. So encoding first `jsonDecode`s the
// stored `valueJson` string back into a raw Dart value before nesting it
// under the `value` key, and decoding does the reverse (`jsonEncode` the
// raw `value` back into the `valueJson` string convention every downstream
// consumer — `IncomingOperation.valueJson`, `sync_pending_ops.valueJson` —
// already expects). This is the only field where "encode" and "decode" are
// not simple identity/round-trip copies of each other.
//
// **`value`'s absence vs. explicit JSON `null`, disambiguated by key
// presence, not by the decoded value alone.** A `kind == 'set_remove'`
// operation has no value at all (`WireOperation.valueJson == null`,
// "not applicable" — `CausalEngine.apply`'s `set_remove` branch never reads
// it). A `kind == 'field'` operation clearing a nullable column to JSON
// `null` has a real value that happens to BE null
// (`WireOperation.valueJson == 'null'`, the 4-character JSON-encoded string,
// per `jsonEncode(null)`). Both would collapse to the same "envelope value
// key holds Dart `null`" state if the `value` key were always written —
// indistinguishable on decode. [encodeCommitBytes] resolves this by OMITTING
// the `value` key entirely when [WireOperation.valueJson] is `null`
// ("not applicable"), and always including it (possibly as JSON `null`)
// otherwise; [decodeCommitBytes] checks `containsKey('value')`, not merely
// whether the decoded value is null, to reconstruct the correct one of the
// two cases.

import 'dart:convert';
import 'dart:typed_data';

import 'causal/dot.dart';
import 'hlc.dart';

// ---------------------------------------------------------------------------
// M2.12: `v: 2` — a batch envelope. One commit, N operations.
// ---------------------------------------------------------------------------
//
// § Architecture 3's hash-linked commit log never required one operation per
// commit — `commitBytes` is opaque to the backend, and § 11.5 simply *chose*
// a one-operation envelope. Field-level granularity is what conflict
// resolution needs; it is not what TRANSPORT needs. A measured first sync of
// a 22-entity library produced 152 single-operation commits and roughly 456
// Drive round trips.
//
// The v2 envelope is the identical per-operation field list, unchanged, in a
// list:
//
//     {"v": 2, "ops": [ {authorId, authorSeq, hlc, contentKey, kind,
//                        entityTable, entityId, fieldName, memberUuid,
//                        value?, blobHash, targetDots, frontier}, ... ]}
//
// Every operation still carries its own `authorId`/`authorSeq` — **the dot
// space is completely unchanged.** What changes is only that a commit's
// cleartext `deviceSeq` is now a COMMIT-CHAIN POSITION rather than
// (incidentally) also an `authorSeq`. See `push_phase.dart`'s own doc
// comment for that separation in full; the consequence here is that v2
// decoding cannot, and does not, cross-check `authorSeq` against
// `deviceSeq`. The `authorId` half of § 11.5's integrity check survives
// intact (every operation in a commit must be authored by the log that
// commit lives in), and it is joined by two checks a batch makes possible
// that a single-operation envelope did not: the batch must be non-empty,
// and its `authorSeq`s must be strictly increasing (a batch is a contiguous
// run of one author's outbox, in order — a decoder that accepted an
// out-of-order or repeated seq would be accepting a payload no encoder in
// this codebase can produce).
//
// **v1 decode compatibility is preserved, unconditionally and permanently.**
// Commits already on Drive are v1 and stay v1 forever (nothing rewrites
// history), so [decodeCommitOperations] dispatches on `v` and keeps the
// original single-operation reader — including its full `authorSeq ==
// deviceSeq` integrity check, which is exactly right for a v1 commit
// because a v1 commit is by construction 1:1. Nothing about the v1 reader
// was relaxed to make room for v2.
//
// **An unknown FUTURE version is refused with a clear, typed error rather
// than best-effort parsed** ([WireFormatUnsupportedVersionException]). A
// best-effort parse of a payload whose shape you do not know is how a
// receiving device applies half an operation and then advances its frontier
// past the rest — silent, permanent, partial data loss, and precisely the
// class § 11.7 says must surface. The typed subclass exists so
// `pull_phase.dart` can CONTAIN it (park the commit, keep syncing) instead
// of wedging the whole device, which is the other half of "an older build
// must not choke": an old build meeting a newer commit stops making
// progress on that ONE log rather than losing the ability to publish its
// own work. (A build older than this one cannot be retrofitted with that
// behaviour, of course — it will throw on `v: 2`. That is why v1 remains
// readable rather than being migrated away.)

/// § 11.5's original single-operation envelope version. Still emitted by
/// [encodeCommitBytes] and still read by [decodeCommitBytes]/
/// [decodeCommitOperations]; no longer what the push path writes.
const int wireFormatVersion = 1;

/// M2.12's batch envelope version — what [encodeCommitBatchBytes] writes and
/// what `push_phase.dart` now publishes.
const int wireFormatBatchVersion = 2;

/// Thrown by [decodeCommitBytes] on any violation of this wire format's own
/// contract: an unsupported `v`, a malformed envelope, or — the specific
/// check § 11.5 calls out by name — `decoded.authorId`/`decoded.authorSeq`
/// disagreeing with the cleartext `deviceLogId`/`deviceSeq` framing the
/// caller already trusted before ever decoding the payload. Deliberately a
/// loud, thrown error rather than a silently-ignored mismatch: § 11.5 frames
/// this as "a free integrity check," and a check nobody enforces is not a
/// check.
class WireFormatIntegrityException implements Exception {
  final String message;
  const WireFormatIntegrityException(this.message);
  @override
  String toString() => 'WireFormatIntegrityException: $message';
}

/// The specific integrity failure "this commit's envelope version is one
/// this build does not implement" — split out from the general
/// [WireFormatIntegrityException] (which it still is-a, so every existing
/// `catch` keeps working) because the two want different handling.
///
/// A malformed or mismatched payload means the LOG is untrustworthy and must
/// stop the round. An unknown version means only that the writer is newer
/// than the reader: the log is fine, this build simply cannot interpret one
/// commit in it. `pull_phase.dart` parks that commit and carries on, so a
/// device meeting a future format keeps publishing its own work instead of
/// wedging — the failure class M2.10 spent a milestone removing.
class WireFormatUnsupportedVersionException
    extends WireFormatIntegrityException {
  final Object? version;
  const WireFormatUnsupportedVersionException(this.version)
    : super(
        'unsupported wire format version: this build understands 1 and 2, '
        'got $version — the commit was written by a newer version of Note '
        'Synapse; update the app to sync it',
      );
  @override
  String toString() => 'WireFormatUnsupportedVersionException: $message';
}

/// The SQL/local-shaped equivalent of one § 11.5 envelope — the type
/// [encodeCommitBytes]/[decodeCommitBytes] operate on. Field names and
/// nullability mirror `sync_pending_ops`'s own columns
/// (`database_service.dart`) directly, so building one from a queried
/// `sync_pending_ops` row ([WireOperation.fromPendingOpsRow]) and decoding
/// one off the wire are both straightforward, not two independently-
/// maintained shapes.
class WireOperation {
  const WireOperation({
    required this.authorId,
    required this.authorSeq,
    required this.hlc,
    this.contentKey,
    required this.kind,
    required this.entityTable,
    required this.entityId,
    this.fieldName,
    this.memberUuid,
    this.valueJson,
    this.blobHash,
    this.targetDots,
    required this.frontier,
  });

  final String authorId;
  final int authorSeq;
  final Hlc hlc;
  final String? contentKey;

  /// `'__exists__' | 'field' | 'set_add' | 'set_remove'`.
  final String kind;
  final String entityTable;
  final String entityId;
  final String? fieldName;
  final String? memberUuid;

  /// Already JSON-encoded, matching `sync_pending_ops.valueJson`'s own
  /// storage convention — `null` means "not applicable to this kind"
  /// (`set_remove`), never "applicable and happens to be JSON null" (that
  /// case is the literal string `'null'`). See this file's top doc comment.
  final String? valueJson;
  final String? blobHash;

  /// `set_remove` only: the add-dot(s) being observed as removed.
  final List<Dot>? targetDots;
  final Map<String, int> frontier;

  /// Builds a [WireOperation] from a `sync_pending_ops` row
  /// (`database_service.dart`'s `_createSyncPendingOpsTable`) — the shape
  /// `push_phase.dart` reads to encode this device's own outbox.
  factory WireOperation.fromPendingOpsRow(Map<String, Object?> row) {
    final targetDotsJson = row['targetDotsJson'] as String?;
    return WireOperation(
      authorId: row['authorId'] as String,
      authorSeq: row['authorSeq'] as int,
      hlc: Hlc.parse(row['hlc'] as String),
      contentKey: row['contentKey'] as String?,
      kind: row['kind'] as String,
      entityTable: row['entityTable'] as String,
      entityId: row['entityId'] as String,
      fieldName: row['fieldName'] as String?,
      memberUuid: row['memberUuid'] as String?,
      valueJson: row['valueJson'] as String?,
      blobHash: row['blobHash'] as String?,
      targetDots: targetDotsJson == null
          ? null
          : _decodeTargetDots(targetDotsJson),
      frontier: _decodeFrontier(row['frontierJson'] as String),
    );
  }

  static List<Dot> _decodeTargetDots(String json) {
    final decoded = jsonDecode(json) as List<dynamic>;
    return [
      for (final entry in decoded)
        Dot(
          (entry as Map<String, dynamic>)['authorId'] as String,
          entry['authorSeq'] as int,
        ),
    ];
  }

  static Map<String, int> _decodeFrontier(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v as int));
  }
}

/// The per-operation field list shared by the v1 envelope (where it IS the
/// envelope, plus a `v` key) and the v2 envelope (where it is one element of
/// `ops`). Written once so the two versions can never drift.
Map<String, Object?> _encodeOperationFields(WireOperation op) =>
    <String, Object?>{
      'authorId': op.authorId,
      'authorSeq': op.authorSeq,
      'hlc': op.hlc.toString(),
      'contentKey': op.contentKey,
      'kind': op.kind,
      'entityTable': op.entityTable,
      'entityId': op.entityId,
      'fieldName': op.fieldName,
      'memberUuid': op.memberUuid,
      // See this file's top doc comment: the 'value' key is omitted entirely
      // when valueJson is null ("not applicable"), never written as a
      // disambiguation-losing `null`.
      if (op.valueJson != null) 'value': jsonDecode(op.valueJson!),
      'blobHash': op.blobHash,
      'targetDots': op.targetDots
          ?.map((d) => {'authorId': d.authorId, 'authorSeq': d.authorSeq})
          .toList(),
      'frontier': op.frontier,
    };

/// Encodes [op] into the § 11.5 JSON envelope (`v: 1`).
///
/// **No longer the push path's encoder** — `push_phase.dart` writes v2
/// batches as of M2.12. Kept because it is still the exact byte-for-byte
/// definition of what every v1 commit already on a backend contains, which
/// is what the resume path re-derives a stored `payloadHash` from, and
/// because a batch-of-one is not byte-identical to a v1 commit (so
/// re-encoding a legacy pending intent must use this, not the batch
/// encoder).
Uint8List encodeCommitBytes(WireOperation op) {
  final envelope = <String, Object?>{
    'v': wireFormatVersion,
    ..._encodeOperationFields(op),
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
}

/// Encodes [ops] into one M2.12 `v: 2` batch envelope, ready to pass as
/// `SyncBackend.appendCommit`'s `commitBytes` parameter.
///
/// [ops] must be non-empty and in strictly increasing `authorSeq` order —
/// the same contract [decodeCommitOperations] enforces on the way back in.
/// Throws [ArgumentError] otherwise rather than emitting a payload this
/// codebase's own decoder would reject.
Uint8List encodeCommitBatchBytes(List<WireOperation> ops) {
  if (ops.isEmpty) {
    throw ArgumentError.value(ops, 'ops', 'a commit batch cannot be empty');
  }
  for (var i = 1; i < ops.length; i++) {
    if (ops[i].authorSeq <= ops[i - 1].authorSeq) {
      throw ArgumentError.value(
        ops,
        'ops',
        'a commit batch must be in strictly increasing authorSeq order '
            '(${ops[i - 1].authorSeq} then ${ops[i].authorSeq})',
      );
    }
  }
  final envelope = <String, Object?>{
    'v': wireFormatBatchVersion,
    'ops': [for (final op in ops) _encodeOperationFields(op)],
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
}

/// Decodes [bytes] (as returned by `SyncBackend.readCommits`'s
/// `StoredCommit.commitBytes`) back into a [WireOperation], asserting § 11.5's
/// integrity check: [expectedAuthorId]/[expectedAuthorSeq] (the caller's
/// already-trusted `deviceLogId`/`StoredCommit.deviceSeq`) must agree with
/// what's encoded inside the payload itself. Throws
/// [WireFormatIntegrityException] on any violation of that check, an
/// unsupported `v`, or a structurally malformed envelope.
WireOperation decodeCommitBytes(
  Uint8List bytes, {
  required String expectedAuthorId,
  required int expectedAuthorSeq,
}) {
  final decoded = _decodeEnvelope(bytes);
  final v = decoded['v'];
  if (v != wireFormatVersion) {
    throw WireFormatIntegrityException(
      'unsupported wire format version: expected $wireFormatVersion, got $v',
    );
  }
  return _decodeOperationFields(
    decoded,
    expectedAuthorId: expectedAuthorId,
    expectedAuthorSeq: expectedAuthorSeq,
  );
}

/// Decodes [bytes] into the list of operations it carries, whatever envelope
/// version wrote it — **the reader every pull path should use.**
///
///  * `v: 1` -> exactly one operation, with § 11.5's original integrity
///    check applied in full: the payload's `authorId`/`authorSeq` must equal
///    [expectedAuthorId]/[deviceSeq]. Sound because a v1 commit is 1:1 by
///    construction.
///  * `v: 2` -> the batch's operations, in order. Each must be authored by
///    [expectedAuthorId]; the batch must be non-empty and strictly
///    increasing in `authorSeq`. No `authorSeq`-vs-`deviceSeq` comparison is
///    made or possible — [deviceSeq] is a commit-chain position here, not a
///    dot component.
///  * anything else -> [WireFormatUnsupportedVersionException].
///
/// Throws [WireFormatIntegrityException] on any other violation.
List<WireOperation> decodeCommitOperations(
  Uint8List bytes, {
  required String expectedAuthorId,
  required int deviceSeq,
}) {
  final decoded = _decodeEnvelope(bytes);
  final v = decoded['v'];

  if (v == wireFormatVersion) {
    return [
      _decodeOperationFields(
        decoded,
        expectedAuthorId: expectedAuthorId,
        expectedAuthorSeq: deviceSeq,
      ),
    ];
  }

  if (v != wireFormatBatchVersion) {
    throw WireFormatUnsupportedVersionException(v);
  }

  final rawOps = decoded['ops'];
  if (rawOps is! List) {
    throw const WireFormatIntegrityException(
      'v2 commit payload missing required "ops" list',
    );
  }
  if (rawOps.isEmpty) {
    throw const WireFormatIntegrityException(
      'v2 commit payload carries an empty "ops" list — no encoder in this '
      'codebase produces one, so this payload is not trustworthy',
    );
  }

  final ops = <WireOperation>[];
  int? previousSeq;
  for (final raw in rawOps) {
    if (raw is! Map<String, dynamic>) {
      throw const WireFormatIntegrityException(
        'v2 commit payload has a non-object entry in "ops"',
      );
    }
    final authorId = raw['authorId'] as String?;
    if (authorId != expectedAuthorId) {
      throw WireFormatIntegrityException(
        'v2 commit payload contains an operation authored by "$authorId" in '
        'the log of "$expectedAuthorId" — every operation in a commit must be '
        "authored by that commit's own device log",
      );
    }
    final authorSeq = raw['authorSeq'];
    if (authorSeq is! int) {
      throw WireFormatIntegrityException(
        'v2 commit payload operation has a non-integer "authorSeq": $authorSeq',
      );
    }
    if (previousSeq != null && authorSeq <= previousSeq) {
      throw WireFormatIntegrityException(
        'v2 commit payload operations are not in strictly increasing '
        'authorSeq order ($previousSeq then $authorSeq)',
      );
    }
    previousSeq = authorSeq;
    ops.add(
      _decodeOperationFields(
        raw,
        expectedAuthorId: expectedAuthorId,
        expectedAuthorSeq: authorSeq,
      ),
    );
  }
  return ops;
}

Map<String, dynamic> _decodeEnvelope(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const WireFormatIntegrityException(
        'commitBytes payload is not a JSON object',
      );
    }
    return decoded;
  } on FormatException catch (e) {
    throw WireFormatIntegrityException('malformed commitBytes payload: $e');
  }
}

/// The per-operation reader shared by both envelope versions — the exact
/// inverse of [_encodeOperationFields].
///
/// [expectedAuthorId]/[expectedAuthorSeq] are asserted against the payload
/// for v1 (§ 11.5's free integrity check) and are, for v2, the values the
/// caller has ALREADY validated out of the same map — so this function's own
/// check is a cheap tautology there rather than a second, divergent rule.
WireOperation _decodeOperationFields(
  Map<String, dynamic> decoded, {
  required String expectedAuthorId,
  required int expectedAuthorSeq,
}) {
  final authorId = decoded['authorId'] as String?;
  final authorSeq = decoded['authorSeq'] as int?;
  if (authorId != expectedAuthorId || authorSeq != expectedAuthorSeq) {
    throw WireFormatIntegrityException(
      'commit payload authorId/authorSeq ($authorId/$authorSeq) does not match '
      'the framing this commit was read under ($expectedAuthorId/$expectedAuthorSeq)',
    );
  }

  final hlcRaw = decoded['hlc'] as String?;
  if (hlcRaw == null) {
    throw const WireFormatIntegrityException(
      'commit payload missing required "hlc" field',
    );
  }
  final kind = decoded['kind'] as String?;
  final entityTable = decoded['entityTable'] as String?;
  final entityId = decoded['entityId'] as String?;
  if (kind == null || entityTable == null || entityId == null) {
    throw const WireFormatIntegrityException(
      'commit payload missing one of the required "kind"/"entityTable"/"entityId" fields',
    );
  }

  final targetDotsRaw = decoded['targetDots'] as List<dynamic>?;
  final frontierRaw = decoded['frontier'] as Map<String, dynamic>?;
  if (frontierRaw == null) {
    throw const WireFormatIntegrityException(
      'commit payload missing required "frontier" field',
    );
  }

  return WireOperation(
    // Equal to the decoded authorId/authorSeq by construction — the
    // integrity check above already threw if they disagreed. Using the
    // (non-nullable) expected* parameters directly here, rather than the
    // decoded String?/int? locals, avoids a redundant null-assertion.
    authorId: expectedAuthorId,
    authorSeq: expectedAuthorSeq,
    hlc: Hlc.parse(hlcRaw),
    contentKey: decoded['contentKey'] as String?,
    kind: kind,
    entityTable: entityTable,
    entityId: entityId,
    fieldName: decoded['fieldName'] as String?,
    memberUuid: decoded['memberUuid'] as String?,
    // See this file's top doc comment: presence of the key (not merely a
    // non-null decoded value) is what distinguishes "no value, not
    // applicable" from "a value that happens to be JSON null".
    valueJson: decoded.containsKey('value')
        ? jsonEncode(decoded['value'])
        : null,
    blobHash: decoded['blobHash'] as String?,
    targetDots: targetDotsRaw == null
        ? null
        : [
            for (final entry in targetDotsRaw)
              Dot(
                (entry as Map<String, dynamic>)['authorId'] as String,
                entry['authorSeq'] as int,
              ),
          ],
    frontier: frontierRaw.map((k, v) => MapEntry(k, v as int)),
  );
}
