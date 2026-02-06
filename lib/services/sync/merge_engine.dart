import 'package:sqflite/sqflite.dart';

import '../../models/sync_operation.dart';

/// The result of applying a batch of [SyncOperation]s via [MergeEngine].
class MergeResult {
  final int inserted;
  final int updated;
  final int deleted;
  final int conflictsCreated;
  final List<String> errors;

  MergeResult({
    required this.inserted,
    required this.updated,
    required this.deleted,
    required this.conflictsCreated,
    required this.errors,
  });
}

/// Applies remote [SyncOperation]s to a staging database with field-level
/// conflict resolution.
///
/// The merge engine handles three operation types:
/// - **INSERT**: Creates a new row, or merges into an existing row if one
///   already exists (upsert semantics).
/// - **UPDATE**: Modifies an existing row, or creates it if missing (upsert).
///   Uses timestamp comparison to resolve conflicts.
/// - **DELETE**: Removes a row. Idempotent -- no error if the row is missing.
///
/// Fields whose [SyncFieldValue.minVersion] exceeds [_currentSchemaVersion]
/// are silently skipped, enabling forward-compatible sync between devices
/// running different app versions.
class MergeEngine {
  final Database _db;
  final int _currentSchemaVersion;

  /// Tables that use composite primary keys instead of a single `id` column.
  /// Maps table name to the ordered list of key column names.
  static const Map<String, List<String>> _compositeKeyTables = {
    'note_tags': ['noteId', 'tagId'],
    'conversation_message_mapping': ['conversationId', 'messageId'],
    'conversation_note_mapping': ['conversationId', 'noteId'],
    'conversation_tags': ['conversationId', 'tagId'],
  };

  /// Maximum time difference (in milliseconds) between local and remote
  /// timestamps to consider edits "concurrent" and create a conflict record.
  static const int _concurrentEditThresholdMs = 2000;

  MergeEngine({required Database db, required int currentSchemaVersion})
      : _db = db,
        _currentSchemaVersion = currentSchemaVersion;

  /// Applies a list of [SyncOperation]s in order and returns a [MergeResult].
  Future<MergeResult> applyOperations(List<SyncOperation> ops) async {
    int inserted = 0;
    int updated = 0;
    int deleted = 0;
    int conflictsCreated = 0;
    final errors = <String>[];

    for (final op in ops) {
      try {
        switch (op.action) {
          case SyncAction.insert:
            final result = await _applyInsert(op);
            if (result._isUpdate) {
              updated++;
              conflictsCreated += result._conflicts;
            } else {
              inserted++;
            }
          case SyncAction.update:
            final result = await _applyUpdate(op);
            if (result._isInsert) {
              inserted++;
            } else if (result._applied) {
              updated++;
            }
            conflictsCreated += result._conflicts;
          case SyncAction.delete:
            final count = await _applyDelete(op);
            deleted += count;
        }
      } catch (e) {
        errors.add('Error applying ${op.action.name} on ${op.table}/${op.rowId}: $e');
      }
    }

    return MergeResult(
      inserted: inserted,
      updated: updated,
      deleted: deleted,
      conflictsCreated: conflictsCreated,
      errors: errors,
    );
  }

  /// Filters op fields to only those compatible with the current schema version.
  Map<String, dynamic> _filteredFields(SyncOperation op) {
    final result = <String, dynamic>{};
    for (final entry in op.fields.entries) {
      if (entry.value.minVersion <= _currentSchemaVersion) {
        result[entry.key] = entry.value.value;
      }
    }
    return result;
  }

  /// Returns the WHERE clause and args for looking up a row by primary key.
  _PkQuery _pkQuery(String table, String rowId, SyncOperation op) {
    final compositeKeys = _compositeKeyTables[table];
    if (compositeKeys != null) {
      // For composite keys, try to get values from op fields first
      final values = <dynamic>[];
      var allFromFields = true;
      for (final key in compositeKeys) {
        final fieldValue = op.fields[key];
        if (fieldValue != null) {
          values.add(fieldValue.value);
        } else {
          allFromFields = false;
          break;
        }
      }

      if (allFromFields && values.length == compositeKeys.length) {
        final where = compositeKeys.map((k) => '$k = ?').join(' AND ');
        return _PkQuery(where, values);
      }

      // Fallback: split rowId on '-' -- but this is fragile for values
      // containing dashes. We use a two-part split from the end.
      final parts = _splitCompositeRowId(rowId, compositeKeys.length);
      final where = compositeKeys.map((k) => '$k = ?').join(' AND ');
      return _PkQuery(where, parts);
    }

    return _PkQuery('id = ?', [rowId]);
  }

  /// Splits a composite rowId into the expected number of parts.
  ///
  /// The rowId format is `value1-value2` where values are concatenated with
  /// `-`. Since values themselves may contain dashes, the first key gets the
  /// first segment and the last key gets all remaining segments (matching the
  /// oplog writer's parsing strategy).
  List<String> _splitCompositeRowId(String rowId, int partCount) {
    final segments = rowId.split('-');
    if (segments.length <= partCount) return segments;

    // First (partCount - 1) keys each get one segment, last key gets the rest.
    final result = <String>[];
    for (var i = 0; i < partCount; i++) {
      if (i == partCount - 1) {
        result.add(segments.sublist(i).join('-'));
      } else {
        result.add(segments[i]);
      }
    }
    return result;
  }

  /// Applies an INSERT operation. If the row already exists, falls through to
  /// an UPDATE (merge).
  Future<_InsertResult> _applyInsert(SyncOperation op) async {
    final pk = _pkQuery(op.table, op.rowId, op);
    final existing = await _db.query(op.table, where: pk.where, whereArgs: pk.args);

    if (existing.isNotEmpty) {
      // Row exists -- merge as update
      final updateResult = await _mergeUpdate(op, existing.first);
      return _InsertResult(isUpdate: true, conflicts: updateResult._conflicts);
    }

    final fields = _filteredFields(op);
    if (fields.isEmpty) return _InsertResult(isUpdate: false, conflicts: 0);

    await _db.insert(op.table, fields);
    return _InsertResult(isUpdate: false, conflicts: 0);
  }

  /// Applies an UPDATE operation. If the row doesn't exist, performs an INSERT
  /// (upsert).
  Future<_UpdateResult> _applyUpdate(SyncOperation op) async {
    final pk = _pkQuery(op.table, op.rowId, op);
    final existing = await _db.query(op.table, where: pk.where, whereArgs: pk.args);

    if (existing.isEmpty) {
      // Row doesn't exist -- upsert as insert
      final fields = _filteredFields(op);
      if (fields.isNotEmpty) {
        await _db.insert(op.table, fields);
      }
      return _UpdateResult(isInsert: true, applied: false, conflicts: 0);
    }

    return _mergeUpdate(op, existing.first);
  }

  /// Merges an operation's fields into an existing row using timestamp-based
  /// conflict resolution.
  Future<_UpdateResult> _mergeUpdate(
    SyncOperation op,
    Map<String, dynamic> existingRow,
  ) async {
    final pk = _pkQuery(op.table, op.rowId, op);
    final winningValues = <String, dynamic>{};
    int conflicts = 0;

    // Check if the table has an updatedAt field for timestamp comparison
    final hasUpdatedAt = existingRow.containsKey('updatedAt') &&
        op.fields.containsKey('updatedAt');

    if (hasUpdatedAt) {
      final localUpdatedAt = existingRow['updatedAt'];
      final remoteUpdatedAt = op.fields['updatedAt']!.value;

      // Parse timestamps (stored as millisecondsSinceEpoch integers)
      final localTs = localUpdatedAt is int ? localUpdatedAt : 0;
      final remoteTs = remoteUpdatedAt is int ? remoteUpdatedAt as int : 0;

      final diff = (remoteTs - localTs).abs();
      final isConcurrent = diff < _concurrentEditThresholdMs && diff > 0;

      if (remoteTs <= localTs && !isConcurrent) {
        // Local is newer -- skip all updates
        return _UpdateResult(isInsert: false, applied: false, conflicts: 0);
      }

      // Check each field for conflicts
      for (final entry in op.fields.entries) {
        if (entry.value.minVersion > _currentSchemaVersion) continue;

        final fieldName = entry.key;
        final remoteValue = entry.value.value;
        final localValue = existingRow[fieldName];

        if (isConcurrent && _valuesAreDifferent(localValue, remoteValue)) {
          // Concurrent edit on same field with different values -- record conflict
          conflicts++;
          await _db.insert('sync_conflicts', {
            'table_name': op.table,
            'row_id': op.rowId,
            'field_name': fieldName,
            'local_value': localValue?.toString(),
            'remote_value': remoteValue?.toString(),
            'remote_device_id': op.deviceId,
            'remote_timestamp': op.timestamp.toUtc().toIso8601String(),
            'resolved': 0,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });
        }

        // Remote wins (either newer or concurrent -- remote still wins for
        // the applied value; conflict record is just for user review)
        winningValues[fieldName] = remoteValue;
      }
    } else {
      // No updatedAt field -- just apply all compatible fields
      for (final entry in op.fields.entries) {
        if (entry.value.minVersion <= _currentSchemaVersion) {
          winningValues[entry.key] = entry.value.value;
        }
      }
    }

    if (winningValues.isEmpty) {
      return _UpdateResult(isInsert: false, applied: false, conflicts: conflicts);
    }

    await _db.update(op.table, winningValues, where: pk.where, whereArgs: pk.args);
    return _UpdateResult(isInsert: false, applied: true, conflicts: conflicts);
  }

  /// Returns true if the two values are meaningfully different.
  bool _valuesAreDifferent(dynamic local, dynamic remote) {
    if (local == null && remote == null) return false;
    if (local == null || remote == null) return true;
    return local.toString() != remote.toString();
  }

  /// Applies a DELETE operation. Returns 1 if a row was deleted, 0 otherwise.
  Future<int> _applyDelete(SyncOperation op) async {
    final pk = _pkQuery(op.table, op.rowId, op);
    final count = await _db.delete(op.table, where: pk.where, whereArgs: pk.args);
    return count > 0 ? 1 : 0;
  }
}

/// Internal helper for primary key queries.
class _PkQuery {
  final String where;
  final List<dynamic> args;
  _PkQuery(this.where, this.args);
}

/// Internal result type for INSERT operations.
class _InsertResult {
  final bool _isUpdate;
  final int _conflicts;
  _InsertResult({required bool isUpdate, required int conflicts})
      : _isUpdate = isUpdate,
        _conflicts = conflicts;
}

/// Internal result type for UPDATE operations.
class _UpdateResult {
  final bool _isInsert;
  final bool _applied;
  final int _conflicts;
  _UpdateResult({
    required bool isInsert,
    required bool applied,
    required int conflicts,
  })  : _isInsert = isInsert,
        _applied = applied,
        _conflicts = conflicts;
}
