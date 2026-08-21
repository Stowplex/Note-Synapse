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

/// § 11.5: "`'v': 1` inside the JSON is sufficient for forward
/// compatibility... Treated as a resolved decision, not left open." The
/// only version this codec currently understands.
const int wireFormatVersion = 1;

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

/// Encodes [op] into the § 11.5 JSON envelope, ready to pass as
/// `SyncBackend.appendCommit`'s `commitBytes` parameter.
Uint8List encodeCommitBytes(WireOperation op) {
  final envelope = <String, Object?>{
    'v': wireFormatVersion,
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
  final Map<String, dynamic> decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } on FormatException catch (e) {
    throw WireFormatIntegrityException('malformed commitBytes payload: $e');
  }

  final v = decoded['v'];
  if (v != wireFormatVersion) {
    throw WireFormatIntegrityException(
      'unsupported wire format version: expected $wireFormatVersion, got $v',
    );
  }

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
    throw WireFormatIntegrityException(
      'commit payload missing required "hlc" field',
    );
  }
  final kind = decoded['kind'] as String?;
  final entityTable = decoded['entityTable'] as String?;
  final entityId = decoded['entityId'] as String?;
  if (kind == null || entityTable == null || entityId == null) {
    throw WireFormatIntegrityException(
      'commit payload missing one of the required "kind"/"entityTable"/"entityId" fields',
    );
  }

  final targetDotsRaw = decoded['targetDots'] as List<dynamic>?;
  final frontierRaw = decoded['frontier'] as Map<String, dynamic>?;
  if (frontierRaw == null) {
    throw WireFormatIntegrityException(
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
