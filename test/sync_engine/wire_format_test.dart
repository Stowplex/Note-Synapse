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

  // =========================================================================
  // M2.12: the `v: 2` batch envelope, and v1 decode compatibility.
  // =========================================================================
  group('v2 batch envelope', () {
    WireOperation opAt(int seq, {String kind = 'field', String? value}) =>
        WireOperation(
          authorId: 'device-a',
          authorSeq: seq,
          hlc: Hlc(1732900000000 + seq, 0),
          contentKey: 'ck-$seq',
          kind: kind,
          entityTable: 'notes',
          entityId: 'n$seq',
          fieldName: 'title',
          valueJson: value ?? jsonEncode('title $seq'),
          frontier: {'device-a': seq},
        );

    test('round-trips every operation in order, with its own dot intact', () {
      final ops = [opAt(1), opAt(2), opAt(3)];
      final bytes = encodeCommitBatchBytes(ops);

      // deviceSeq is a COMMIT position here and deliberately unrelated to any
      // operation's authorSeq — 7 is picked to be a number that appears
      // nowhere in the batch, so a decoder that conflated the two would fail.
      final decoded = decodeCommitOperations(
        bytes,
        expectedAuthorId: 'device-a',
        deviceSeq: 7,
      );

      expect(decoded, hasLength(3));
      for (var i = 0; i < ops.length; i++) {
        expect(decoded[i].authorId, ops[i].authorId);
        expect(decoded[i].authorSeq, ops[i].authorSeq);
        expect(decoded[i].hlc, ops[i].hlc);
        expect(decoded[i].contentKey, ops[i].contentKey);
        expect(decoded[i].kind, ops[i].kind);
        expect(decoded[i].entityTable, ops[i].entityTable);
        expect(decoded[i].entityId, ops[i].entityId);
        expect(decoded[i].fieldName, ops[i].fieldName);
        expect(decoded[i].valueJson, ops[i].valueJson);
        expect(decoded[i].frontier, ops[i].frontier);
      }
    });

    test('declares v: 2 and nests the operations under "ops"', () {
      final envelope =
          jsonDecode(utf8.decode(encodeCommitBatchBytes([opAt(1), opAt(2)])))
              as Map<String, dynamic>;
      expect(envelope['v'], 2);
      expect(envelope['ops'], hasLength(2));
      expect((envelope['ops'] as List).first['authorSeq'], 1);
    });

    test(
      'preserves the value-absent vs. value-is-JSON-null distinction per '
      'operation, exactly as v1 does',
      () {
        final bytes = encodeCommitBatchBytes([
          // A field cleared to NULL: a real value that happens to be null.
          opAt(1, value: jsonEncode(null)),
          // A set_remove: no value at all.
          WireOperation(
            authorId: 'device-a',
            authorSeq: 2,
            hlc: const Hlc(200, 0),
            kind: 'set_remove',
            entityTable: 'notes',
            entityId: 'n1',
            fieldName: 'tags',
            memberUuid: 'tag1',
            targetDots: const [Dot('device-b', 4)],
            frontier: const {'device-a': 2},
          ),
        ]);
        final decoded = decodeCommitOperations(
          bytes,
          expectedAuthorId: 'device-a',
          deviceSeq: 1,
        );
        expect(decoded[0].valueJson, 'null');
        expect(decoded[1].valueJson, isNull);
        expect(decoded[1].targetDots, const [Dot('device-b', 4)]);
      },
    );

    test('a batch of one is still a valid v2 batch', () {
      final decoded = decodeCommitOperations(
        encodeCommitBatchBytes([opAt(5)]),
        expectedAuthorId: 'device-a',
        deviceSeq: 1,
      );
      expect(decoded, hasLength(1));
      expect(decoded.single.authorSeq, 5);
    });

    test('refuses to encode an empty or out-of-order batch', () {
      expect(() => encodeCommitBatchBytes([]), throwsArgumentError);
      expect(
        () => encodeCommitBatchBytes([opAt(2), opAt(1)]),
        throwsArgumentError,
      );
      expect(
        () => encodeCommitBatchBytes([opAt(2), opAt(2)]),
        throwsArgumentError,
      );
    });

    test('rejects an operation authored by a different device log', () {
      final envelope = {
        'v': 2,
        'ops': [
          jsonDecode(
            utf8.decode(encodeCommitBatchBytes([opAt(1)])),
          )['ops'][0],
        ],
      };
      expect(
        () => decodeCommitOperations(
          Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
          expectedAuthorId: 'device-b',
          deviceSeq: 1,
        ),
        throwsA(isA<WireFormatIntegrityException>()),
      );
    });

    test('rejects an empty ops list and a non-increasing authorSeq run', () {
      Uint8List raw(Object envelope) =>
          Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
      final one =
          jsonDecode(utf8.decode(encodeCommitBatchBytes([opAt(1)])))['ops'][0];
      expect(
        () => decodeCommitOperations(
          raw({'v': 2, 'ops': <Object>[]}),
          expectedAuthorId: 'device-a',
          deviceSeq: 1,
        ),
        throwsA(isA<WireFormatIntegrityException>()),
      );
      expect(
        () => decodeCommitOperations(
          raw({
            'v': 2,
            'ops': [one, one],
          }),
          expectedAuthorId: 'device-a',
          deviceSeq: 1,
        ),
        throwsA(isA<WireFormatIntegrityException>()),
      );
    });
  });

  group('v1 decode compatibility (commits already on a backend)', () {
    test(
      'decodeCommitOperations reads a v1 single-operation envelope, applying '
      "§ 11.5's authorSeq-equals-deviceSeq integrity check",
      () {
        final op = WireOperation(
          authorId: 'device-a',
          authorSeq: 3,
          hlc: const Hlc(300, 1),
          kind: 'field',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'title',
          valueJson: jsonEncode('legacy'),
          frontier: const {'device-a': 3},
        );
        // Bytes produced by the PRE-M2.12 encoder — `encodeCommitBytes` is
        // unchanged and still emits exactly this.
        final bytes = encodeCommitBytes(op);
        expect(jsonDecode(utf8.decode(bytes))['v'], 1);

        final decoded = decodeCommitOperations(
          bytes,
          expectedAuthorId: 'device-a',
          deviceSeq: 3,
        );
        expect(decoded, hasLength(1));
        expect(decoded.single.authorSeq, 3);
        expect(decoded.single.valueJson, jsonEncode('legacy'));

        // For v1 the two counters really are the same number, so the check
        // stays in force and a disagreement is still an integrity failure.
        expect(
          () => decodeCommitOperations(
            bytes,
            expectedAuthorId: 'device-a',
            deviceSeq: 4,
          ),
          throwsA(isA<WireFormatIntegrityException>()),
        );
      },
    );

    test(
      'a v1 payload byte-frozen from before M2.12 still decodes — this is the '
      'literal shape sitting on the reporting user\'s Drive folder',
      () {
        const frozen =
            '{"v":1,"authorId":"device-a","authorSeq":2,'
            '"hlc":"0000000000000000500:0000000000000000000","contentKey":null,'
            '"kind":"field","entityTable":"notes","entityId":"n1",'
            '"fieldName":"status","memberUuid":null,"value":null,'
            '"blobHash":null,"targetDots":null,"frontier":{"device-a":2}}';
        final decoded = decodeCommitOperations(
          Uint8List.fromList(utf8.encode(frozen)),
          expectedAuthorId: 'device-a',
          deviceSeq: 2,
        );
        expect(decoded, hasLength(1));
        expect(decoded.single.kind, 'field');
        expect(decoded.single.fieldName, 'status');
        expect(
          decoded.single.valueJson,
          'null',
          reason:
              'an explicit set-to-NULL is a real value, not an absent one — '
              'the distinction survives unchanged',
        );
      },
    );

    test(
      'an unknown FUTURE version is refused with a typed, clear error rather '
      'than best-effort parsed',
      () {
        final bytes = Uint8List.fromList(
          utf8.encode(jsonEncode({'v': 99, 'ops': <Object>[]})),
        );
        expect(
          () => decodeCommitOperations(
            bytes,
            expectedAuthorId: 'device-a',
            deviceSeq: 1,
          ),
          throwsA(
            isA<WireFormatUnsupportedVersionException>()
                .having((e) => e.version, 'version', 99)
                .having((e) => e.message, 'message', contains('update the app')),
          ),
        );
        // Still a WireFormatIntegrityException, so every existing catch site
        // keeps working.
        expect(
          () => decodeCommitOperations(
            bytes,
            expectedAuthorId: 'device-a',
            deviceSeq: 1,
          ),
          throwsA(isA<WireFormatIntegrityException>()),
        );
      },
    );

    test('the v1-only decodeCommitBytes still refuses a v2 payload', () {
      final bytes = encodeCommitBatchBytes([
        WireOperation(
          authorId: 'device-a',
          authorSeq: 1,
          hlc: const Hlc(1, 0),
          kind: 'field',
          entityTable: 'notes',
          entityId: 'n1',
          fieldName: 'title',
          valueJson: jsonEncode('x'),
          frontier: const {'device-a': 1},
        ),
      ]);
      expect(
        () => decodeCommitBytes(
          bytes,
          expectedAuthorId: 'device-a',
          expectedAuthorSeq: 1,
        ),
        throwsA(isA<WireFormatIntegrityException>()),
      );
    });
  });
}
