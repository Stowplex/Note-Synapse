/// Generates the SYNC_SPEC.md content that is written to every sync root
/// so users can reconstruct their data without the Note-Synapse application.
///
/// The generated spec documents:
/// - The encryption and KDF configuration
/// - The oplog format and merge rules
/// - The snapshot format
/// - The attachment convention
/// - The full SQLite schema for all synced tables
library;

import '../database_service.dart';
import 'field_version_registry.dart';

/// Generates a human-readable Markdown specification of the sync format.
///
/// This spec, combined with the passphrase and the files in the sync root,
/// provides everything needed to reconstruct the full database without the
/// Note-Synapse application.
class SyncSpecGenerator {
  final DatabaseService _db;

  SyncSpecGenerator({required DatabaseService db}) : _db = db;

  /// Generates the full SYNC_SPEC.md content.
  ///
  /// [schemaVersion] is the current database schema version to embed in the
  /// document.
  Future<String> generate({required int schemaVersion}) async {
    final buf = StringBuffer();

    _writeHeader(buf);
    _writeFormatVersion(buf, schemaVersion);
    _writeCipherRegistry(buf);
    _writeKdfSpecification(buf);
    _writeOplogFormat(buf);
    _writeSnapshotFormat(buf);
    _writeAttachmentConvention(buf);
    await _writeSqliteSchema(buf);

    return buf.toString();
  }

  void _writeHeader(StringBuffer buf) {
    buf.writeln('# Note-Synapse Sync Specification v1');
    buf.writeln();
    buf.writeln(
        'This document describes the sync format used by Note-Synapse. With this spec,');
    buf.writeln(
        'the passphrase, and the files in this sync root, you can reconstruct your');
    buf.writeln('full database without the Note-Synapse application.');
    buf.writeln();
  }

  void _writeFormatVersion(StringBuffer buf, int schemaVersion) {
    buf.writeln('## Format Version');
    buf.writeln();
    buf.writeln('- Spec version: 1');
    buf.writeln('- Schema version: $schemaVersion');
    buf.writeln();
  }

  void _writeCipherRegistry(StringBuffer buf) {
    buf.writeln('## Cipher Registry');
    buf.writeln();
    buf.writeln('| Cipher ID | Algorithm | Key Size | IV/Nonce Size |');
    buf.writeln('|-----------|-----------|----------|---------------|');
    buf.writeln(
        '| aes-256-gcm | AES-256-GCM | 256 bits | 12 bytes |');
    buf.writeln(
        '| xchacha20-poly1305 | XChaCha20-Poly1305 | 256 bits | 24 bytes |');
    buf.writeln();
    buf.writeln('### Encryption Procedure');
    buf.writeln();
    buf.writeln(
        '1. Read `sync-config.json` for cipher ID, KDF params, and salt');
    buf.writeln(
        '2. Derive key: Argon2id(passphrase, salt, params) \u2192 256-bit key');
    buf.writeln(
        '3. To decrypt a file: read first byte as nonce length, extract nonce,');
    buf.writeln(
        '   next 16 bytes as MAC tag, remaining bytes as ciphertext');
    buf.writeln(
        '4. Construct (nonce, ciphertext, MAC) and decrypt with the derived key');
    buf.writeln();
    buf.writeln('### HMAC Verification');
    buf.writeln();
    buf.writeln('- Algorithm: HMAC-SHA256 with the derived key');
    buf.writeln(
        '- Input: canonical JSON of sync-config.json (all fields except "hmac", keys sorted alphabetically)');
    buf.writeln('- Verify before trusting config');
    buf.writeln();
  }

  void _writeKdfSpecification(StringBuffer buf) {
    buf.writeln('## KDF Specification');
    buf.writeln();
    buf.writeln('- Algorithm: Argon2id');
    buf.writeln('- Output: 256-bit key (32 bytes)');
    buf.writeln(
        '- Parameters stored in sync-config.json: memory, iterations, parallelism');
    buf.writeln('- Salt: base64-encoded in sync-config.json');
    buf.writeln();
  }

  void _writeOplogFormat(StringBuffer buf) {
    buf.writeln('## Oplog Format');
    buf.writeln();
    buf.writeln(
        'Each file in `oplog/` is named `{deviceId}-{seqStart}-{seqEnd}.json`.');
    buf.writeln();
    buf.writeln('### Operation Schema');
    buf.writeln();
    buf.writeln('```json');
    buf.writeln('{');
    buf.writeln('  "id": "uuid",');
    buf.writeln('  "deviceId": "device-uuid",');
    buf.writeln('  "sequence": 42,');
    buf.writeln('  "timestamp": "ISO8601 UTC",');
    buf.writeln('  "table": "table_name",');
    buf.writeln('  "rowId": "primary_key_value",');
    buf.writeln('  "action": "insert | update | delete",');
    buf.writeln('  "fields": {');
    buf.writeln('    "column_name": { "value": "...", "minVersion": 1 }');
    buf.writeln('  },');
    buf.writeln('  "schemaVersion": 36');
    buf.writeln('}');
    buf.writeln('```');
    buf.writeln();
    buf.writeln('### Merge Rules');
    buf.writeln();
    buf.writeln('1. INSERT: Create row with known fields');
    buf.writeln(
        '2. UPDATE: Field-level merge. Same field conflict \u2192 newer timestamp wins.');
    buf.writeln(
        '   Timestamp tie \u2192 lexicographically higher deviceId wins.');
    buf.writeln('3. DELETE: Delete wins over update.');
    buf.writeln();
    buf.writeln('### Replay Algorithm');
    buf.writeln();
    buf.writeln(
        '1. Read `snapshots/latest.json` if exists \u2192 populate database');
    buf.writeln(
        '2. Read `meta/device-registry.json` for device sequences');
    buf.writeln(
        '3. List oplog files, sort by (deviceId, sequence)');
    buf.writeln('4. For each operation in order:');
    buf.writeln(
        '   a. Skip if field minVersion > your schema version');
    buf.writeln(
        '   b. INSERT: Insert row if not exists, else merge as UPDATE');
    buf.writeln(
        '   c. UPDATE: For each field, apply if newer timestamp');
    buf.writeln('   d. DELETE: Delete row');
    buf.writeln();
  }

  void _writeSnapshotFormat(StringBuffer buf) {
    buf.writeln('## Snapshot Format');
    buf.writeln();
    buf.writeln('`snapshots/latest.json` contains:');
    buf.writeln();
    buf.writeln('```json');
    buf.writeln('{');
    buf.writeln('  "schemaVersion": 36,');
    buf.writeln('  "timestamp": "ISO8601 UTC",');
    buf.writeln('  "tables": {');
    buf.writeln('    "table_name": [ { "col1": "val1", ... }, ... ]');
    buf.writeln('  },');
    buf.writeln('  "referencedAttachments": ["attachments/uuid.ext", ...]');
    buf.writeln('}');
    buf.writeln('```');
    buf.writeln();
  }

  void _writeAttachmentConvention(StringBuffer buf) {
    buf.writeln('## Attachment Convention');
    buf.writeln();
    buf.writeln('- Stored in `attachments/` directory');
    buf.writeln('- Named by UUID: `{uuid}.{ext}`');
    buf.writeln('- Immutable: once written, never modified');
    buf.writeln(
        '- Referenced by `filePath` field in `attachments` and `conversation_attachments` tables');
    buf.writeln(
        '- Unreferenced files are garbage-collected during compaction');
    buf.writeln();
  }

  Future<void> _writeSqliteSchema(StringBuffer buf) async {
    final db = await _db.database;

    buf.writeln('## SQLite Schema');
    buf.writeln();

    for (final table in syncedTables) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');

      buf.writeln('```sql');
      buf.write('CREATE TABLE $table (');

      final colDefs = <String>[];
      for (final col in columns) {
        final name = col['name'] as String;
        final type = col['type'] as String;
        final notNull = col['notnull'] as int;
        final pk = col['pk'] as int;
        final dfltValue = col['dflt_value'];

        final parts = <String>[name, type];
        if (pk > 0) parts.add('PRIMARY KEY');
        if (notNull == 1 && pk == 0) parts.add('NOT NULL');
        if (dfltValue != null) parts.add('DEFAULT $dfltValue');

        colDefs.add(parts.join(' '));
      }

      buf.writeln();
      buf.writeln('  ${colDefs.join(",\n  ")}');
      buf.writeln(');');
      buf.writeln('```');
      buf.writeln();
    }
  }
}
