import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/sync_operation.dart';

void main() {
  group('SyncFieldValue', () {
    test('toJson returns correct map', () {
      final fieldValue = SyncFieldValue(value: 'hello', minVersion: 1);

      final json = fieldValue.toJson();

      expect(json, {'value': 'hello', 'minVersion': 1});
    });

    test('fromJson creates correct instance', () {
      final json = {'value': 42, 'minVersion': 2};

      final fieldValue = SyncFieldValue.fromJson(json);

      expect(fieldValue.value, 42);
      expect(fieldValue.minVersion, 2);
    });

    test('roundtrip preserves string value', () {
      final original = SyncFieldValue(value: 'test string', minVersion: 1);
      final restored = SyncFieldValue.fromJson(original.toJson());

      expect(restored.value, original.value);
      expect(restored.minVersion, original.minVersion);
    });

    test('roundtrip preserves int value', () {
      final original = SyncFieldValue(value: 42, minVersion: 3);
      final restored = SyncFieldValue.fromJson(original.toJson());

      expect(restored.value, original.value);
      expect(restored.minVersion, original.minVersion);
    });

    test('roundtrip preserves null value', () {
      final original = SyncFieldValue(value: null, minVersion: 1);
      final restored = SyncFieldValue.fromJson(original.toJson());

      expect(restored.value, isNull);
      expect(restored.minVersion, original.minVersion);
    });

    test('roundtrip preserves bool value', () {
      final original = SyncFieldValue(value: true, minVersion: 1);
      final restored = SyncFieldValue.fromJson(original.toJson());

      expect(restored.value, true);
      expect(restored.minVersion, original.minVersion);
    });

    test('roundtrip preserves double value', () {
      final original = SyncFieldValue(value: 3.14, minVersion: 1);
      final restored = SyncFieldValue.fromJson(original.toJson());

      expect(restored.value, 3.14);
      expect(restored.minVersion, original.minVersion);
    });

    test('roundtrip preserves list value', () {
      final original = SyncFieldValue(value: [1, 2, 3], minVersion: 1);
      final restored = SyncFieldValue.fromJson(original.toJson());

      expect(restored.value, [1, 2, 3]);
      expect(restored.minVersion, original.minVersion);
    });
  });

  group('SyncAction', () {
    test('enum has expected values', () {
      expect(SyncAction.values, containsAll([
        SyncAction.insert,
        SyncAction.update,
        SyncAction.delete,
      ]));
      expect(SyncAction.values.length, 3);
    });
  });

  group('SyncOperation', () {
    late DateTime testTimestamp;
    late SyncOperation testOperation;

    setUp(() {
      testTimestamp = DateTime.utc(2026, 1, 15, 10, 30, 0);
      testOperation = SyncOperation(
        id: 'op-001',
        deviceId: 'device-abc',
        sequence: 42,
        timestamp: testTimestamp,
        table: 'notes',
        rowId: 'note-123',
        action: SyncAction.update,
        fields: {
          'title': SyncFieldValue(value: 'My Note', minVersion: 1),
          'content': SyncFieldValue(value: 'Hello world', minVersion: 1),
          'priority': SyncFieldValue(value: 5, minVersion: 2),
        },
        schemaVersion: 3,
      );
    });

    test('toJson serializes all fields correctly', () {
      final json = testOperation.toJson();

      expect(json['id'], 'op-001');
      expect(json['deviceId'], 'device-abc');
      expect(json['sequence'], 42);
      expect(json['timestamp'], '2026-01-15T10:30:00.000Z');
      expect(json['table'], 'notes');
      expect(json['rowId'], 'note-123');
      expect(json['action'], 'update');
      expect(json['schemaVersion'], 3);

      // Fields map
      final fields = json['fields'] as Map<String, dynamic>;
      expect(fields.length, 3);
      expect(fields['title'], {'value': 'My Note', 'minVersion': 1});
      expect(fields['content'], {'value': 'Hello world', 'minVersion': 1});
      expect(fields['priority'], {'value': 5, 'minVersion': 2});
    });

    test('toJson serializes timestamp as UTC ISO8601', () {
      // Use a non-UTC timestamp to verify conversion
      final localTime = DateTime(2026, 6, 15, 14, 30, 0);
      final op = SyncOperation(
        id: 'op-002',
        deviceId: 'device-abc',
        sequence: 1,
        timestamp: localTime,
        table: 'notes',
        rowId: 'note-456',
        action: SyncAction.insert,
        fields: {},
        schemaVersion: 1,
      );

      final json = op.toJson();
      final timestampStr = json['timestamp'] as String;

      // Must end with Z (UTC indicator)
      expect(timestampStr, endsWith('Z'));
      // Must be parseable back to the same instant
      expect(DateTime.parse(timestampStr).isUtc, isTrue);
      expect(
        DateTime.parse(timestampStr).millisecondsSinceEpoch,
        localTime.toUtc().millisecondsSinceEpoch,
      );
    });

    test('toJson serializes action as name string', () {
      for (final action in SyncAction.values) {
        final op = SyncOperation(
          id: 'op-test',
          deviceId: 'device-abc',
          sequence: 1,
          timestamp: testTimestamp,
          table: 'notes',
          rowId: 'note-789',
          action: action,
          fields: {},
          schemaVersion: 1,
        );

        final json = op.toJson();
        expect(json['action'], action.name);
      }
    });

    test('fromJson deserializes all fields correctly', () {
      final json = {
        'id': 'op-001',
        'deviceId': 'device-abc',
        'sequence': 42,
        'timestamp': '2026-01-15T10:30:00.000Z',
        'table': 'notes',
        'rowId': 'note-123',
        'action': 'update',
        'fields': {
          'title': {'value': 'My Note', 'minVersion': 1},
          'content': {'value': 'Hello world', 'minVersion': 1},
          'priority': {'value': 5, 'minVersion': 2},
        },
        'schemaVersion': 3,
      };

      final op = SyncOperation.fromJson(json);

      expect(op.id, 'op-001');
      expect(op.deviceId, 'device-abc');
      expect(op.sequence, 42);
      expect(op.timestamp, DateTime.utc(2026, 1, 15, 10, 30, 0));
      expect(op.timestamp.isUtc, isTrue);
      expect(op.table, 'notes');
      expect(op.rowId, 'note-123');
      expect(op.action, SyncAction.update);
      expect(op.schemaVersion, 3);

      expect(op.fields.length, 3);
      expect(op.fields['title']!.value, 'My Note');
      expect(op.fields['title']!.minVersion, 1);
      expect(op.fields['content']!.value, 'Hello world');
      expect(op.fields['content']!.minVersion, 1);
      expect(op.fields['priority']!.value, 5);
      expect(op.fields['priority']!.minVersion, 2);
    });

    test('fromJson parses all action types', () {
      for (final action in SyncAction.values) {
        final json = {
          'id': 'op-test',
          'deviceId': 'device-abc',
          'sequence': 1,
          'timestamp': '2026-01-15T10:30:00.000Z',
          'table': 'notes',
          'rowId': 'note-789',
          'action': action.name,
          'fields': <String, dynamic>{},
          'schemaVersion': 1,
        };

        final op = SyncOperation.fromJson(json);
        expect(op.action, action);
      }
    });

    test('roundtrip toJson then fromJson preserves all fields', () {
      final json = testOperation.toJson();
      final restored = SyncOperation.fromJson(json);

      expect(restored.id, testOperation.id);
      expect(restored.deviceId, testOperation.deviceId);
      expect(restored.sequence, testOperation.sequence);
      expect(
        restored.timestamp.millisecondsSinceEpoch,
        testOperation.timestamp.millisecondsSinceEpoch,
      );
      expect(restored.timestamp.isUtc, isTrue);
      expect(restored.table, testOperation.table);
      expect(restored.rowId, testOperation.rowId);
      expect(restored.action, testOperation.action);
      expect(restored.schemaVersion, testOperation.schemaVersion);

      expect(restored.fields.length, testOperation.fields.length);
      for (final key in testOperation.fields.keys) {
        expect(restored.fields[key]!.value, testOperation.fields[key]!.value);
        expect(
          restored.fields[key]!.minVersion,
          testOperation.fields[key]!.minVersion,
        );
      }
    });

    test('roundtrip preserves insert action', () {
      final op = SyncOperation(
        id: 'op-insert',
        deviceId: 'device-abc',
        sequence: 1,
        timestamp: testTimestamp,
        table: 'notes',
        rowId: 'note-new',
        action: SyncAction.insert,
        fields: {
          'title': SyncFieldValue(value: 'New Note', minVersion: 1),
        },
        schemaVersion: 1,
      );

      final restored = SyncOperation.fromJson(op.toJson());
      expect(restored.action, SyncAction.insert);
      expect(restored.fields['title']!.value, 'New Note');
    });

    test('delete action with empty fields map', () {
      final op = SyncOperation(
        id: 'op-delete',
        deviceId: 'device-xyz',
        sequence: 10,
        timestamp: testTimestamp,
        table: 'notes',
        rowId: 'note-to-delete',
        action: SyncAction.delete,
        fields: {},
        schemaVersion: 1,
      );

      final json = op.toJson();
      expect(json['action'], 'delete');
      expect(json['fields'], <String, dynamic>{});

      final restored = SyncOperation.fromJson(json);
      expect(restored.action, SyncAction.delete);
      expect(restored.fields, isEmpty);
    });

    test('roundtrip with various field value types', () {
      final op = SyncOperation(
        id: 'op-types',
        deviceId: 'device-abc',
        sequence: 5,
        timestamp: testTimestamp,
        table: 'test_table',
        rowId: 'row-1',
        action: SyncAction.insert,
        fields: {
          'stringField': SyncFieldValue(value: 'hello', minVersion: 1),
          'intField': SyncFieldValue(value: 42, minVersion: 1),
          'doubleField': SyncFieldValue(value: 3.14, minVersion: 1),
          'boolField': SyncFieldValue(value: true, minVersion: 1),
          'nullField': SyncFieldValue(value: null, minVersion: 1),
        },
        schemaVersion: 2,
      );

      final restored = SyncOperation.fromJson(op.toJson());

      expect(restored.fields['stringField']!.value, 'hello');
      expect(restored.fields['intField']!.value, 42);
      expect(restored.fields['doubleField']!.value, 3.14);
      expect(restored.fields['boolField']!.value, true);
      expect(restored.fields['nullField']!.value, isNull);
    });

    test('roundtrip preserves high sequence numbers', () {
      final op = SyncOperation(
        id: 'op-high-seq',
        deviceId: 'device-abc',
        sequence: 999999,
        timestamp: testTimestamp,
        table: 'notes',
        rowId: 'note-1',
        action: SyncAction.update,
        fields: {'x': SyncFieldValue(value: 1, minVersion: 1)},
        schemaVersion: 1,
      );

      final restored = SyncOperation.fromJson(op.toJson());
      expect(restored.sequence, 999999);
    });
  });
}
