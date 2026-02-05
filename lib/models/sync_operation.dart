/// Actions that a sync operation can represent.
enum SyncAction { insert, update, delete }

/// A versioned field value within a sync operation.
///
/// Each field carries a [minVersion] indicating the minimum schema version
/// required to interpret this field, enabling forward-compatible sync between
/// devices running different app versions.
class SyncFieldValue {
  final dynamic value;
  final int minVersion;

  SyncFieldValue({required this.value, required this.minVersion});

  factory SyncFieldValue.fromJson(Map<String, dynamic> json) {
    return SyncFieldValue(
      value: json['value'],
      minVersion: json['minVersion'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'minVersion': minVersion,
  };
}

/// A single database change captured in the sync oplog.
///
/// Each [SyncOperation] represents an insert, update, or delete on a specific
/// table row. Operations are serialized into oplog batch files for syncing
/// between devices.
class SyncOperation {
  final String id;
  final String deviceId;
  final int sequence;
  final DateTime timestamp;
  final String table;
  final String rowId;
  final SyncAction action;
  final Map<String, SyncFieldValue> fields;
  final int schemaVersion;

  SyncOperation({
    required this.id,
    required this.deviceId,
    required this.sequence,
    required this.timestamp,
    required this.table,
    required this.rowId,
    required this.action,
    required this.fields,
    required this.schemaVersion,
  });

  factory SyncOperation.fromJson(Map<String, dynamic> json) {
    final fieldsJson = json['fields'] as Map<String, dynamic>;
    return SyncOperation(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      sequence: json['sequence'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
      table: json['table'] as String,
      rowId: json['rowId'] as String,
      action: SyncAction.values.byName(json['action'] as String),
      fields: fieldsJson.map(
        (key, value) =>
            MapEntry(key, SyncFieldValue.fromJson(value as Map<String, dynamic>)),
      ),
      schemaVersion: json['schemaVersion'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'deviceId': deviceId,
    'sequence': sequence,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'table': table,
    'rowId': rowId,
    'action': action.name,
    'fields': fields.map((key, value) => MapEntry(key, value.toJson())),
    'schemaVersion': schemaVersion,
  };
}
