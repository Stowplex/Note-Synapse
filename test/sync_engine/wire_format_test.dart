// Tests for M2.6's wire format (`lib/services/sync/wire_format.dart`) — §
// Architecture 11.5's operation-to-commit-bytes JSON envelope. A dedicated
// encode/decode round-trip test, independent of the rest of the engine, per
// § 11.8's eventual requirement (built now since M2.6 needs it anyway).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/wire_format.dart';

void main() {
  group('round-trip: encode then decode reproduces the original operation', () {
    test('a "field" operation with a real value', () {
      final op = WireOperation(
        authorId: 'device-a',
        authorSeq: 42,
        hlc: const Hlc(1732900000123, 0),
        contentKey: null,
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        memberUuid: null,
        valueJson: jsonEncode('New title'),
        blobHash: null,
        targetDots: null,
        frontier: const {'device-a': 42},
      );

      final bytes = encodeCommitBytes(op);
      final decoded = decodeCommitBytes(bytes, expectedAuthorId: 'device-a', expectedAuthorSeq: 42);

      expect(decoded.authorId, op.authorId);
      expect(decoded.authorSeq, op.authorSeq);
      expect(decoded.hlc, op.hlc);
      expect(decoded.contentKey, op.contentKey);
      expect(decoded.kind, op.kind);
      expect(decoded.entityTable, op.entityTable);
      expect(decoded.entityId, op.entityId);
      expect(decoded.fieldName, op.fieldName);
      expect(decoded.memberUuid, op.memberUuid);
      expect(decoded.valueJson, op.valueJson);
      expect(decoded.blobHash, op.blobHash);
      expect(decoded.targetDots, op.targetDots);
      expect(decoded.frontier, op.frontier);
    });

    test('an "__exists__" operation', () {
      final op = WireOperation(
        authorId: 'device-a',
        authorSeq: 1,
        hlc: const Hlc(100, 0),
        kind: '__exists__',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: '__exists__',
        valueJson: jsonEncode(true),
        frontier: const {'device-a': 1},
      );
      final bytes = encodeCommitBytes(op);
      final decoded = decodeCommitBytes(bytes, expectedAuthorId: 'device-a', expectedAuthorSeq: 1);
      expect(decoded.kind, '__exists__');
      expect(decoded.valueJson, jsonEncode(true));
    });

    test('a "set_add" operation with a contentKey', () {
      final op = WireOperation(
        authorId: 'seed:device-a',
        authorSeq: 3,
        hlc: const Hlc(200, 1),
        contentKey: 'notes:n1:tags:GENESIS:tag1',
        kind: 'set_add',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        valueJson: jsonEncode(true),
        frontier: const {'seed:device-a': 3},
      );
      final bytes = encodeCommitBytes(op);
      final decoded =
          decodeCommitBytes(bytes, expectedAuthorId: 'seed:device-a', expectedAuthorSeq: 3);
      expect(decoded.contentKey, op.contentKey);
      expect(decoded.memberUuid, 'tag1');
    });

    test('a "set_remove" operation with multiple targetDots and no value', () {
      final op = WireOperation(
        authorId: 'device-b',
        authorSeq: 7,
        hlc: const Hlc(300, 0),
        kind: 'set_remove',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'tags',
        memberUuid: 'tag1',
        valueJson: null,
        targetDots: const [Dot('device-a', 3), Dot('seed:device-a', 1)],
        frontier: const {'device-a': 3, 'device-b': 7, 'seed:device-a': 1},
      );
      final bytes = encodeCommitBytes(op);
      final decoded = decodeCommitBytes(bytes, expectedAuthorId: 'device-b', expectedAuthorSeq: 7);
      expect(decoded.targetDots, op.targetDots);
      expect(decoded.frontier, op.frontier);
      // valueJson is "not applicable" for set_remove — see wire_format.dart's
      // top doc comment for why this round-trips to null, not "null".
      expect(decoded.valueJson, isNull);
    });

    test('a field explicitly cleared to JSON null is distinguished from "not applicable"', () {
      final op = WireOperation(
        authorId: 'device-a',
        authorSeq: 5,
        hlc: const Hlc(400, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'recurrenceRule',
        valueJson: jsonEncode(null), // the literal 4-char string "null"
        frontier: const {'device-a': 5},
      );
      expect(op.valueJson, 'null');

      final bytes = encodeCommitBytes(op);
      final decoded = decodeCommitBytes(bytes, expectedAuthorId: 'device-a', expectedAuthorSeq: 5);

      // Round-trips to the same "value present, and it's JSON null" string —
      // not Dart null, which would mean "not applicable" instead.
      expect(decoded.valueJson, 'null');
    });

    test('produces UTF-8-encoded JSON matching § 11.5\'s exact envelope shape', () {
      final op = WireOperation(
        authorId: 'device-a',
        authorSeq: 42,
        hlc: const Hlc(1732900000123, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('New title'),
        frontier: const {'device-a': 12, 'seed:device-a': 3},
      );
      final decoded = jsonDecode(utf8.decode(encodeCommitBytes(op))) as Map<String, dynamic>;
      expect(decoded['v'], 1);
      expect(decoded['authorId'], 'device-a');
      expect(decoded['authorSeq'], 42);
      expect(decoded['kind'], 'field');
      expect(decoded['entityTable'], 'notes');
      expect(decoded['entityId'], 'n1');
      expect(decoded['fieldName'], 'title');
      expect(decoded['value'], 'New title'); // the raw value, not a JSON string
      expect(decoded['frontier'], {'device-a': 12, 'seed:device-a': 3});
    });
  });

  group('integrity check: decode asserts authorId/authorSeq against the caller-supplied framing', () {
    test('throws when the decoded authorId disagrees with the framing deviceLogId', () {
      final bytes = encodeCommitBytes(WireOperation(
        authorId: 'device-a',
        authorSeq: 1,
        hlc: const Hlc(1, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('x'),
        frontier: const {'device-a': 1},
      ));
      expect(
        () => decodeCommitBytes(bytes, expectedAuthorId: 'device-b', expectedAuthorSeq: 1),
        throwsA(isA<WireFormatIntegrityException>()),
      );
    });

    test('throws when the decoded authorSeq disagrees with the framing deviceSeq', () {
      final bytes = encodeCommitBytes(WireOperation(
        authorId: 'device-a',
        authorSeq: 1,
        hlc: const Hlc(1, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('x'),
        frontier: const {'device-a': 1},
      ));
      expect(
        () => decodeCommitBytes(bytes, expectedAuthorId: 'device-a', expectedAuthorSeq: 2),
        throwsA(isA<WireFormatIntegrityException>()),
      );
    });

    test('throws on an unsupported wire format version', () {
      final tampered = jsonDecode(utf8.decode(encodeCommitBytes(WireOperation(
        authorId: 'device-a',
        authorSeq: 1,
        hlc: const Hlc(1, 0),
        kind: 'field',
        entityTable: 'notes',
        entityId: 'n1',
        fieldName: 'title',
        valueJson: jsonEncode('x'),
        frontier: const {'device-a': 1},
      )))) as Map<String, dynamic>;
      tampered['v'] = 2;
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(tampered)));
      expect(
        () => decodeCommitBytes(bytes, expectedAuthorId: 'device-a', expectedAuthorSeq: 1),
        throwsA(isA<WireFormatIntegrityException>()),
      );
    });

    test('throws on structurally malformed bytes (not valid JSON)', () {
      final bytes = Uint8List.fromList(utf8.encode('not json'));
      expect(
        () => decodeCommitBytes(bytes, expectedAuthorId: 'device-a', expectedAuthorSeq: 1),
        throwsA(isA<WireFormatIntegrityException>()),
      );
    });
  });

  group('WireOperation.fromPendingOpsRow', () {
    test('builds a WireOperation from a sync_pending_ops-shaped row, including targetDotsJson', () {
      final row = <String, Object?>{
        'authorId': 'device-a',
        'authorSeq': 9,
        'hlc': '0000000000000000500:0000000000000000000',
        'contentKey': null,
        'kind': 'set_remove',
        'entityTable': 'notes',
        'entityId': 'n1',
        'fieldName': 'tags',
        'memberUuid': 'tag1',
        'valueJson': null,
        'blobHash': null,
        'targetDotsJson': jsonEncode([
          {'authorId': 'device-b', 'authorSeq': 2},
        ]),
        'frontierJson': jsonEncode({'device-a': 9}),
      };
      final op = WireOperation.fromPendingOpsRow(row);
      expect(op.authorId, 'device-a');
      expect(op.authorSeq, 9);
      expect(op.hlc, const Hlc(500, 0));
      expect(op.kind, 'set_remove');
      expect(op.targetDots, const [Dot('device-b', 2)]);
      expect(op.frontier, {'device-a': 9});

      // And it survives a full encode/decode round-trip too.
      final bytes = encodeCommitBytes(op);
      final decoded = decodeCommitBytes(bytes, expectedAuthorId: 'device-a', expectedAuthorSeq: 9);
      expect(decoded.targetDots, op.targetDots);
    });
  });
}
