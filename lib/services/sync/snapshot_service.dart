import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'field_version_registry.dart';
import 'sync_encryption_service.dart';
import 'sync_storage_provider.dart';
import 'sync_utils.dart';

/// Represents a full database snapshot for sync initialization or compaction.
///
/// A snapshot captures the complete state of all synced tables at a point in time.
/// It's used when:
/// - Initializing a new sync root
/// - A new device joins an existing sync root
/// - Compacting old oplog files during maintenance
class Snapshot {
  /// The database schema version when this snapshot was created.
  final int schemaVersion;

  /// When this snapshot was created.
  final DateTime timestamp;

  /// All synced table data: tableName -> list of row maps.
  final Map<String, List<Map<String, dynamic>>> tables;

  /// Paths to attachment files referenced by this snapshot.
  /// Used for attachment sync to know which files need to be present.
  final List<String> referencedAttachments;

  Snapshot({
    required this.schemaVersion,
    required this.timestamp,
    required this.tables,
    required this.referencedAttachments,
  });

  /// Creates a Snapshot from JSON data.
  factory Snapshot.fromJson(Map<String, dynamic> json) {
    final tablesJson = json['tables'] as Map<String, dynamic>;
    final tables = <String, List<Map<String, dynamic>>>{};

    for (final entry in tablesJson.entries) {
      final rows = (entry.value as List<dynamic>)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      tables[entry.key] = rows;
    }

    return Snapshot(
      schemaVersion: json['schemaVersion'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
      tables: tables,
      referencedAttachments: (json['referencedAttachments'] as List<dynamic>)
          .cast<String>(),
    );
  }

  /// Converts this Snapshot to JSON.
  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'timestamp': timestamp.toIso8601String(),
      'tables': tables,
      'referencedAttachments': referencedAttachments,
    };
  }
}

/// Service for creating and reading full database snapshots.
///
/// Snapshots are used for:
/// 1. First-time sync: new devices pull the latest snapshot as their baseline
/// 2. Compaction: replace accumulated oplog files with a fresh snapshot
/// 3. Recovery: restore database state from a known good point
class SnapshotService {
  final DatabaseService _db;
  final SyncStorageProvider _provider;
  final SyncEncryptionService? _encryption;

  static const _snapshotPath = 'snapshots/latest.json';

  SnapshotService({
    required DatabaseService db,
    required SyncStorageProvider provider,
    SyncEncryptionService? encryption,
  }) : _db = db,
       _provider = provider,
       _encryption = encryption;

  /// Creates a snapshot of the current database state and writes it to storage.
  ///
  /// The snapshot includes:
  /// - All rows from all synced tables
  /// - Paths to referenced attachments (deduplicated)
  /// - Schema version and timestamp metadata
  Future<void> writeSnapshot(int schemaVersion) async {
    final db = await _db.database;
    final timestamp = DateTime.now().toUtc();

    // Collect all table data
    final tables = <String, List<Map<String, dynamic>>>{};
    for (final tableName in syncedTables) {
      final largeCols = largeColumnsByTable[tableName];
      if (largeCols == null) {
        // No large columns — safe to SELECT *
        tables[tableName] = await db.query(tableName);
      } else {
        // Get all column names from fieldVersionRegistry
        final allColumns = fieldVersionRegistry[tableName]!.keys.toList();
        final safeColumns = allColumns
            .where((c) => !largeCols.contains(c))
            .toList();

        // Query only safe (small) columns
        final rows = await db.query(tableName, columns: safeColumns);

        // For each row, read large columns via chunked substr()
        final enrichedRows = <Map<String, dynamic>>[];
        for (final row in rows) {
          final mutableRow = Map<String, dynamic>.from(row);
          final rowId = row['id'] as String;
          for (final col in largeCols) {
            mutableRow[col] = await readLargeColumn(db, tableName, col, rowId);
          }
          enrichedRows.add(mutableRow);
        }
        tables[tableName] = enrichedRows;
      }
    }

    // Collect referenced attachments from both tables
    final attachmentPaths = <String>{};

    final attachments = await db.query('attachments', columns: ['filePath']);
    for (final row in attachments) {
      final path = row['filePath'] as String?;
      if (path != null && path.isNotEmpty) {
        attachmentPaths.add(path);
      }
    }

    final convAttachments = await db.query(
      'conversation_attachments',
      columns: ['filePath'],
    );
    for (final row in convAttachments) {
      final path = row['filePath'] as String?;
      if (path != null && path.isNotEmpty) {
        attachmentPaths.add(path);
      }
    }

    // Create snapshot
    final snapshot = Snapshot(
      schemaVersion: schemaVersion,
      timestamp: timestamp,
      tables: tables,
      referencedAttachments: attachmentPaths.toList(),
    );

    // Offload serialization and encryption to isolate
    final keyBytes = await _encryption?.getDerivedKeyBytes();
    final cipherId = _encryption?.getCipherId();

    final dataToWrite = await compute(_serializeAndEncryptSnapshot, {
      'snapshotJson': snapshot.toJson(),
      'keyBytes': keyBytes,
      'cipherId': cipherId,
    });

    // Write to storage
    await _provider.writeFile(_snapshotPath, dataToWrite);
  }

  /// Reads the latest snapshot from storage.
  ///
  /// Returns null if no snapshot exists.
  Future<Snapshot?> readSnapshot() async {
    // Check if snapshot exists
    final exists = await _provider.exists(_snapshotPath);
    if (!exists) {
      return null;
    }

    // Read bytes
    final bytes = await _provider.readFile(_snapshotPath);

    // Decrypt if encryption service is provided
    final Uint8List jsonBytes;
    if (_encryption != null) {
      jsonBytes = await _encryption.decrypt(bytes);
    } else {
      jsonBytes = bytes;
    }

    // Parse JSON
    final json = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    return Snapshot.fromJson(json);
  }

  /// Applies a snapshot to a target database, replacing all existing data.
  ///
  /// This is used for first-time sync or database reset. The operation:
  /// 1. Deletes all existing rows from each table in the snapshot
  /// 2. Inserts all rows from the snapshot
  /// 3. Wraps everything in a transaction for atomicity
  ///
  /// [targetDb] is typically a staging database, not the main database.
  Future<void> applySnapshotToDb(Snapshot snapshot, Database targetDb) async {
    await targetDb.transaction((txn) async {
      for (final entry in snapshot.tables.entries) {
        final tableName = entry.key;
        final rows = entry.value;

        // Delete existing data
        await txn.delete(tableName);

        // Insert all rows from snapshot
        for (final row in rows) {
          await txn.insert(tableName, row);
        }
      }
    });
  }

  /// execution in isolate
  static Future<Uint8List> _serializeAndEncryptSnapshot(
    Map<String, dynamic> args,
  ) async {
    final snapshotJson = args['snapshotJson'] as Map<String, dynamic>;
    final keyBytes = args['keyBytes'] as List<int>?;
    final cipherId = args['cipherId'] as String?;

    // 1. Encode JSON
    final jsonBytes = utf8.encode(jsonEncode(snapshotJson));

    // 2. Encrypt if needed
    if (keyBytes != null && cipherId != null) {
      final Cipher cipher;
      if (cipherId == 'aes-256-gcm') {
        cipher = AesGcm.with256bits();
      } else if (cipherId == 'xchacha20-poly1305') {
        cipher = Xchacha20.poly1305Aead();
      } else {
        throw StateError('Unsupported cipher: $cipherId');
      }

      final secretBox = await cipher.encrypt(
        jsonBytes,
        secretKey: SecretKey(keyBytes),
      );

      final nonce = secretBox.nonce;
      final mac = secretBox.mac.bytes;
      final ciphertext = secretBox.cipherText;

      final result = BytesBuilder(copy: false);
      result.addByte(nonce.length);
      result.add(nonce);
      result.add(mac);
      result.add(ciphertext);

      return result.toBytes();
    }

    // Return plain bytes if not encrypted
    return Uint8List.fromList(jsonBytes);
  }
}
