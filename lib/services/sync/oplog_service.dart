import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../models/sync_operation.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'field_version_registry.dart';
import 'sync_encryption_service.dart';
import 'sync_storage_provider.dart';
import 'sync_utils.dart';

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
  }) : _db = db,
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

    if (pending.isNotEmpty) {
      LoggerService.debug(
        'OplogWriter found ${pending.length} pending changes',
      );
    }

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

      operations.add(
        SyncOperation(
          id: _uuid.v4(),
          deviceId: _deviceId,
          sequence: startSequence + i,
          timestamp: DateTime.parse(timestamp),
          table: table,
          rowId: rowId,
          action: action,
          fields: fields,
          schemaVersion: _schemaVersion,
        ),
      );

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
  /// Uses chunked reads for large columns to avoid Android CursorWindow overflow.
  Future<Map<String, SyncFieldValue>> _buildFieldsFromRow(
    String table,
    String rowId,
  ) async {
    final db = await _db.database;

    // Get primary key columns for this table
    final pkColumns = _getPrimaryKeyColumns(table);

    // Build WHERE clause for the query
    final whereClause = _buildWhereClause(pkColumns, rowId);

    // Check for large columns that need chunked reads
    final largeCols = largeColumnsByTable[table];

    // Query the row, excluding large columns if any
    final List<Map<String, dynamic>> rows;
    if (largeCols != null) {
      final allColumns = fieldVersionRegistry[table]!.keys.toList();
      final safeColumns = allColumns
          .where((c) => !largeCols.contains(c))
          .toList();
      rows = await db.query(
        table,
        columns: safeColumns,
        where: whereClause.where,
        whereArgs: whereClause.args,
      );
    } else {
      rows = await db.query(
        table,
        where: whereClause.where,
        whereArgs: whereClause.args,
      );
    }

    if (rows.isEmpty) {
      // Row might have been deleted since changelog was created
      return {};
    }

    final row = Map<String, dynamic>.from(rows.first);
    final tableRegistry = fieldVersionRegistry[table] ?? {};

    // Read large columns separately via chunked substr
    if (largeCols != null) {
      // Get the row id for chunked reads (assumes 'id' column for single-key tables)
      final idForChunked = pkColumns.length == 1 ? rowId : row['id'] as String?;
      if (idForChunked != null) {
        for (final col in largeCols) {
          row[col] = await readLargeColumn(db, table, col, idForChunked);
        }
      }
    }

    final fields = <String, SyncFieldValue>{};
    for (final entry in row.entries) {
      final columnName = entry.key;
      final value = entry.value;
      final minVersion = tableRegistry[columnName] ?? 1;

      fields[columnName] = SyncFieldValue(value: value, minVersion: minVersion);
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
      return _WhereClause(where: '${pkColumns.first} = ?', args: [rowId]);
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

      return _WhereClause(where: conditions.join(' AND '), args: args);
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

/// Information about an oplog file extracted from its filename.
class OplogFileInfo {
  final String path;
  final String deviceId;
  final int seqStart;
  final int seqEnd;

  OplogFileInfo({
    required this.path,
    required this.deviceId,
    required this.seqStart,
    required this.seqEnd,
  });
}

/// Result of reading new operations from remote oplog files.
class OplogReadResult {
  /// Operations that can be applied (schemaVersion <= current).
  final List<SyncOperation> applicableOps;

  /// Operations deferred for later (schemaVersion > current).
  final List<SyncOperation> deferredOps;

  /// Updated sequence map after processing all files.
  final Map<String, int> newLastSeenSequences;

  /// Warnings for parsing errors, corrupted files, etc.
  final List<String> warnings;

  OplogReadResult({
    required this.applicableOps,
    required this.deferredOps,
    required this.newLastSeenSequences,
    required this.warnings,
  });
}

/// Reads oplog files from cloud storage for the "pull" phase of sync.
///
/// The OplogReader discovers what operations other devices have written,
/// downloads and validates them, and prepares them for the merge engine.
/// It also handles schema version filtering to allow devices at different
/// versions to coexist.
class OplogReader {
  final SyncStorageProvider _provider;
  final SyncEncryptionService? _encryption;
  final String _ownDeviceId;
  final int _currentSchemaVersion;

  OplogReader({
    required SyncStorageProvider provider,
    SyncEncryptionService? encryption,
    required String ownDeviceId,
    required int currentSchemaVersion,
  }) : _provider = provider,
       _encryption = encryption,
       _ownDeviceId = ownDeviceId,
       _currentSchemaVersion = currentSchemaVersion;

  /// Lists all oplog files and parses their filenames.
  ///
  /// Filename format: `{deviceId}-{seqStart}-{seqEnd}.json`
  /// Note: deviceId may contain dashes, so we parse from the end.
  Future<List<OplogFileInfo>> listOplogFiles() async {
    final files = await _provider.listFiles('oplog');
    final result = <OplogFileInfo>[];

    for (final file in files) {
      final info = _parseOplogFilename(file.path);
      if (info != null) {
        result.add(info);
      }
    }

    return result;
  }

  /// Parses an oplog filename to extract deviceId, seqStart, seqEnd.
  ///
  /// Format: `oplog/{deviceId}-{seqStart}-{seqEnd}.json`
  /// Since deviceId may contain dashes, we parse seqStart and seqEnd from the end.
  OplogFileInfo? _parseOplogFilename(String path) {
    // Extract just the filename
    final filename = path.split('/').last;

    // Remove .json extension
    if (!filename.endsWith('.json')) {
      return null;
    }
    final withoutExt = filename.substring(0, filename.length - 5);

    // Parse from end: last two dash-separated parts are seqStart and seqEnd
    final parts = withoutExt.split('-');
    if (parts.length < 3) {
      return null;
    }

    try {
      final seqEnd = int.parse(parts.last);
      final seqStart = int.parse(parts[parts.length - 2]);
      final deviceId = parts.sublist(0, parts.length - 2).join('-');

      return OplogFileInfo(
        path: path,
        deviceId: deviceId,
        seqStart: seqStart,
        seqEnd: seqEnd,
      );
    } catch (e) {
      // Invalid sequence numbers
      return null;
    }
  }

  /// Reads and parses a single oplog file.
  ///
  /// Decrypts if encryption service is provided.
  Future<List<SyncOperation>> readOplogFile(String path) async {
    final bytes = await _provider.readFile(path);

    final Uint8List jsonBytes;
    if (_encryption != null) {
      jsonBytes = await _encryption.decrypt(bytes);
    } else {
      jsonBytes = bytes;
    }

    final jsonList = jsonDecode(utf8.decode(jsonBytes)) as List<dynamic>;
    return jsonList
        .map((item) => SyncOperation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Reads new operations from remote oplog files.
  ///
  /// This is the main method for the pull phase:
  /// 1. Lists all oplog files
  /// 2. Filters to files from other devices with new operations
  /// 3. Downloads, decrypts, and parses qualifying files
  /// 4. Separates ops by schema version (applicable vs deferred)
  /// 5. Sorts applicable ops for replay order
  ///
  /// [lastSeenSequences] maps deviceId -> highest sequence already processed.
  Future<OplogReadResult> readNewOperations(
    Map<String, int> lastSeenSequences,
  ) async {
    final warnings = <String>[];
    final applicableOps = <SyncOperation>[];
    final deferredOps = <SyncOperation>[];
    final newLastSeenSequences = Map<String, int>.from(lastSeenSequences);

    // List all oplog files
    final files = await listOplogFiles();

    // Filter to qualifying files
    final qualifyingFiles = files.where((file) {
      // Skip our own device's files
      if (file.deviceId == _ownDeviceId) {
        return false;
      }
      // Skip files entirely older than lastSeen
      final lastSeen = lastSeenSequences[file.deviceId] ?? 0;
      return file.seqEnd > lastSeen;
    }).toList();

    // Process each qualifying file
    for (final file in qualifyingFiles) {
      final lastSeen = lastSeenSequences[file.deviceId] ?? 0;

      List<SyncOperation> ops;
      try {
        ops = await _readOplogFileWithWarnings(file.path, warnings);
      } catch (e) {
        // Skip file entirely on read/decrypt errors
        warnings.add('Failed to read oplog file ${file.path}: $e');
        continue;
      }

      // Filter out already-seen operations (partial overlap case)
      ops = ops.where((op) => op.sequence > lastSeen).toList();

      // Track the highest sequence we've seen for this device
      for (final op in ops) {
        final currentMax = newLastSeenSequences[op.deviceId] ?? 0;
        if (op.sequence > currentMax) {
          newLastSeenSequences[op.deviceId] = op.sequence;
        }
      }

      // Separate by schema version
      for (final op in ops) {
        if (op.schemaVersion <= _currentSchemaVersion) {
          applicableOps.add(op);
        } else {
          deferredOps.add(op);
        }
      }
    }

    // Sort applicable ops by (deviceId, sequence) for consistent replay order
    applicableOps.sort((a, b) {
      final deviceCompare = a.deviceId.compareTo(b.deviceId);
      if (deviceCompare != 0) return deviceCompare;
      return a.sequence.compareTo(b.sequence);
    });

    return OplogReadResult(
      applicableOps: applicableOps,
      deferredOps: deferredOps,
      newLastSeenSequences: newLastSeenSequences,
      warnings: warnings,
    );
  }

  /// Reads and parses an oplog file, handling individual operation parsing errors.
  Future<List<SyncOperation>> _readOplogFileWithWarnings(
    String path,
    List<String> warnings,
  ) async {
    final bytes = await _provider.readFile(path);

    final Uint8List jsonBytes;
    if (_encryption != null) {
      jsonBytes = await _encryption.decrypt(bytes);
    } else {
      jsonBytes = bytes;
    }

    final jsonList = jsonDecode(utf8.decode(jsonBytes)) as List<dynamic>;
    final ops = <SyncOperation>[];

    for (final item in jsonList) {
      try {
        ops.add(SyncOperation.fromJson(item as Map<String, dynamic>));
      } catch (e) {
        warnings.add('Failed to parse operation in $path: $e');
        // Continue to next operation
      }
    }

    return ops;
  }
}
