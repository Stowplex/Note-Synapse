// A single field-conflict candidate — the SQL-shaped equivalent of
// `test/sync_protocol/model.dart`'s `Operation`, narrowed to exactly the
// fields the field-conflict resolver (`field_conflict_resolver.dart`) and
// OR-Set resolver (`or_set_resolver.dart`) need: identity (dot), the
// contentKey dedup was run against (if any, purely informational at this
// layer — see `field_conflict_resolver.dart`'s doc comment for why grouping
// itself never needs to re-read it), the HLC tiebreak source, the frontier
// snapshot causal comparisons run against, and the value payload carried
// forward untouched.
//
// M2.5, § Architecture 11.4. Mirrors `sync_field_state`/
// `sync_conflict_copies.resolvedFieldsJson`'s actual column shapes
// (`database_service.dart`) directly, so constructing one from a queried
// row and serializing one back to a row is a straight field-for-field
// mapping — no re-derivation.

import 'dart:convert';

import '../hlc.dart';
import 'dot.dart';

/// One field-conflict candidate: `sync_field_state`'s current winner, one
/// `sync_conflict_copies` (`kind='field_conflict'`) row, or a just-arrived
/// incoming operation not yet written anywhere.
class FieldCandidate {
  const FieldCandidate({
    required this.dot,
    required this.hlc,
    this.contentKey,
    this.valueJson,
    this.blobHash,
    required this.frontier,
  });

  final Dot dot;
  final Hlc hlc;
  final String? contentKey;

  /// The winning value, already JSON-encoded (matches
  /// `sync_field_state.valueJson`/`sync_pending_ops.valueJson`'s own
  /// storage convention — kept as raw text here rather than decoded, so
  /// round-tripping through this type never risks a re-encoding mismatch).
  final String? valueJson;
  final String? blobHash;

  /// This operation's own frontier snapshot at mint/observation time —
  /// `{authorId: maxSeq}`, matching `outbox_drainer.dart`'s
  /// `_singleAuthorFrontierJson` convention (no baseline-snapshot wrapper
  /// exists yet).
  final Map<String, int> frontier;

  /// Builds a [FieldCandidate] from a `sync_field_state` row.
  factory FieldCandidate.fromFieldStateRow(Map<String, Object?> row) {
    return FieldCandidate(
      dot: Dot(row['authorId'] as String, row['authorSeq'] as int),
      hlc: Hlc.parse(row['hlc'] as String),
      contentKey: row['contentKey'] as String?,
      valueJson: row['valueJson'] as String?,
      blobHash: row['blobHash'] as String?,
      frontier: _decodeFrontier(row['frontierJson'] as String),
    );
  }

  /// Builds a [FieldCandidate] from a `sync_conflict_copies.resolvedFieldsJson`
  /// blob (this file's own serialization format, § below — the design doc
  /// specifies the payload's *content* — "the losing operation's full
  /// `{value, dot, frontier, hlc}`" — but not a byte-exact wire shape for
  /// it, since it is a local-only column, never transmitted).
  factory FieldCandidate.fromResolvedFieldsJson(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return FieldCandidate(
      dot: Dot(decoded['authorId'] as String, decoded['authorSeq'] as int),
      hlc: Hlc.parse(decoded['hlc'] as String),
      contentKey: decoded['contentKey'] as String?,
      valueJson: decoded['valueJson'] as String?,
      blobHash: decoded['blobHash'] as String?,
      frontier: _decodeFrontier(jsonEncode(decoded['frontier'])),
    );
  }

  String toResolvedFieldsJson() {
    return jsonEncode({
      'authorId': dot.authorId,
      'authorSeq': dot.authorSeq,
      'hlc': hlc.toString(),
      'contentKey': contentKey,
      'valueJson': valueJson,
      'blobHash': blobHash,
      'frontier': frontier,
    });
  }

  static Map<String, int> _decodeFrontier(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v as int));
  }

  @override
  String toString() =>
      'FieldCandidate($dot hlc=$hlc ck=$contentKey value=$valueJson)';
}
