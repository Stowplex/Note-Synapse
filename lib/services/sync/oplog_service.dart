import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../models/sync_operation.dart';
import '../database_service.dart';
import 'field_version_registry.dart';
import 'sync_encryption_service.dart';
import 'sync_storage_provider.dart';

/// Writes local database changes to oplog files for cloud sync.
///
/// The OplogWriter is the "push" side of sync. It reads local changes captured
/// by SQLite triggers, converts them to the oplog format with field version
/// tagging, and writes batched oplog files to remote storage.
class OplogWriter {
  final DatabaseService _db;
  final SyncStorageProvider _provider;
  final SyncEncryptionService? _encryption;
  final String _deviceId;
  final int _schemaVersion;

  static const _uuid = Uuid();

  OplogWriter({
    required DatabaseService db,
    required SyncStorageProvider provider,
    SyncEncryptionService? encryption,
    required String deviceId,
    required int schemaVersion,
  })  : _db = db,
        _provider = provider,
        _encryption = encryption,
        _deviceId = deviceId,
        _schemaVersion = schemaVersion;

  /// Writes pending changelog entries as a batch oplog file.
  ///
  /// Returns the next sequence number to use (startSequence + number of ops written).
  /// If there are no pending changes, returns [startSequence] unchanged.
  Future<int> writeOplogBatch(int startSequence) async {
    final pending = await _db.getPendingSyncChanges();

    if (pending.isEmpty) {
      return startSequence;
    }

    final operations = <SyncOperation>[];
    final changelogIds = <int>[];

    for (var i = 0; i < pending.length; i++) {
      final entry = pending[i];
      final action = _parseAction(entry['action'] as String);
      final table = entry['table_name'] as String;
      final rowId = entry['row_id'] as String;
      final timestamp = entry['timestamp'] as String;

      // Build fields map for insert/update, empty for delete
      final fields = action == SyncAction.delete
          ? <String, SyncFieldValue>{}
          : await _buildFieldsFromRow(table, rowId);

      operations.add(SyncOperation(
        id: _uuid.v4(),
        deviceId: _deviceId,
        sequence: startSequence + i,
        timestamp: DateTime.parse(timestamp),
        table: table,
        rowId: rowId,
        action: action,
        fields: fields,
        schemaVersion: _schemaVersion,
      ));

      changelogIds.add(entry['id'] as int);
    }

    // Serialize to JSON
    final jsonList = operations.map((op) => op.toJson()).toList();
    final jsonBytes = utf8.encode(jsonEncode(jsonList));

    // Encrypt if encryption service is provided
    final Uint8List dataToWrite;
    if (_encryption != null) {
      dataToWrite = await _encryption.encrypt(Uint8List.fromList(jsonBytes));
    } else {
      dataToWrite = Uint8List.fromList(jsonBytes);
    }

    // Compute filename: deviceId-startSeq-endSeq.json
    final endSequence = startSequence + operations.length - 1;
    final filename = '$_deviceId-$startSequence-$endSequence.json';
    final path = 'oplog/$filename';

    // Write to storage
    await _provider.writeFile(path, dataToWrite);

    // Mark changelog entries as pushed
    await _db.markSyncChangesPushed(changelogIds);

    return endSequence + 1;
  }

  /// Parses a string action into [SyncAction].
  SyncAction _parseAction(String action) {
    switch (action.toLowerCase()) {
      case 'insert':
        return SyncAction.insert;
      case 'update':
        return SyncAction.update;
      case 'delete':
        return SyncAction.delete;
      default:
        throw ArgumentError('Unknown sync action: $action');
    }
  }

  /// Builds a map of field name to [SyncFieldValue] from the current row data.
  ///
  /// For each column, looks up the minVersion from [fieldVersionRegistry].
  Future<Map<String, SyncFieldValue>> _buildFieldsFromRow(
    String table,
    String rowId,
  ) async {
    final db = await _db.database;

    // Get primary key columns for this table
    final pkColumns = _getPrimaryKeyColumns(table);

    // Build WHERE clause for the query
    final whereClause = _buildWhereClause(pkColumns, rowId);

    // Query the row
    final rows = await db.query(
      table,
      where: whereClause.where,
      whereArgs: whereClause.args,
    );

    if (rows.isEmpty) {
      // Row might have been deleted since changelog was created
      return {};
    }

    final row = rows.first;
    final tableRegistry = fieldVersionRegistry[table] ?? {};

    final fields = <String, SyncFieldValue>{};
    for (final entry in row.entries) {
      final columnName = entry.key;
      final value = entry.value;
      final minVersion = tableRegistry[columnName] ?? 1;

      fields[columnName] = SyncFieldValue(
        value: value,
        minVersion: minVersion,
      );
    }

    return fields;
  }

  /// Returns the primary key column(s) for a table.
  List<String> _getPrimaryKeyColumns(String table) {
    const primaryKeys = {
      'notes': ['id'],
      'subnotes': ['id'],
      'tags': ['id'],
      'note_tags': ['noteId', 'tagId'],
      'relationships': ['id'],
      'conversations': ['id'],
      'conversation_messages': ['id'],
      'conversation_message_mapping': ['conversationId', 'messageId'],
      'message_parents': ['id'],
      'conversation_note_mapping': ['conversationId', 'noteId'],
      'conversation_tags': ['conversationId', 'tagId'],
      'attachments': ['id'],
      'conversation_attachments': ['id'],
    };

    return primaryKeys[table] ?? ['id'];
  }

  /// Builds a WHERE clause and args from a row_id for tables with composite keys.
  ///
  /// For single-key tables, row_id is the key value.
  /// For composite keys, row_id is key1-key2 (concatenated with '-').
  _WhereClause _buildWhereClause(List<String> pkColumns, String rowId) {
    if (pkColumns.length == 1) {
      return _WhereClause(
        where: '${pkColumns.first} = ?',
        args: [rowId],
      );
    }

    // Composite key: split by '-'
    final parts = rowId.split('-');

    // Handle case where parts might have dashes in them
    // We need to join with proper number of parts per key
    // Since we know the exact number of keys, we can split accordingly
    if (parts.length >= pkColumns.length) {
      final args = <String>[];
      final conditions = <String>[];

      // For simplicity, assume each key is one part
      // In practice, if keys contain dashes, we'd need a different separator
      for (var i = 0; i < pkColumns.length; i++) {
        if (i == pkColumns.length - 1) {
          // Last key gets all remaining parts
          args.add(parts.sublist(i).join('-'));
        } else {
          args.add(parts[i]);
        }
        conditions.add('${pkColumns[i]} = ?');
      }

      return _WhereClause(
        where: conditions.join(' AND '),
        args: args,
      );
    }

    // Fallback: shouldn't happen if row_id was constructed correctly
    throw ArgumentError(
      'Invalid row_id format for composite key: $rowId (expected ${pkColumns.length} parts)',
    );
  }
}

/// Helper class for WHERE clause construction.
class _WhereClause {
  final String where;
  final List<String> args;

  _WhereClause({required this.where, required this.args});
}
