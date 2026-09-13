// CursorWindow-safe row reads for the sync engine — M3.8.
//
// ---------------------------------------------------------------------
// **The field failure this exists for.**
// ---------------------------------------------------------------------
// A real device reported:
//
//     DatabaseException(Row too big to fit into CursorWindow
//     requirePos=0, totalRows=1)
//     sql 'Select * from user_apps WHERE CAST(id as text) = ? limit 1'
//
// Android hands query results back through a CursorWindow with a hard size
// limit (2 MB in practice). A single row larger than that cannot be read AT
// ALL — the failure is not truncation, it is an exception, and it takes the
// whole sync round with it.
//
// Two of this engine's readers were plain `SELECT *`
// (`seed_scanner.dart`'s `_seedEntity`, `outbox_drainer.dart`'s
// `_currentRow`), which pulls every column whether the sync scope wants it
// or not. `user_apps.htmlContent` is a legacy column holding an app's whole
// HTML — dead data nothing reads, dragged into every seed of every mini app
// purely because the query said `*`. One of `outbox_drainer.dart`'s own doc
// comments even asserted that "every excluded BLOB/large column stays
// excluded"; `SELECT *` had been quietly making that false since M2.4.
//
// ---------------------------------------------------------------------
// **Restricting the columns is necessary and NOT sufficient, which is the
// part worth getting right.**
// ---------------------------------------------------------------------
// M3.2 brought `app_revisions.appCode` INTO sync scope, so it is a column
// the engine genuinely needs. A mini app that inline-vendors a WebAssembly
// build is megabytes on its own — the user who reported this named exactly
// that case. So a needed column can be over the limit by itself, and no
// amount of narrowing the select list helps.
//
// This file therefore does what `database_service.dart` already does for
// `notes.content` and `subnotes.content` (`_readLargeString`, the
// `_contentLength` pattern): ask for a column's LENGTH rather than its
// value when it might be too big, then read it back in `substr` chunks.
// CLAUDE.md's "Database Columns (Large Data)" note is the standing
// instruction; this brings the sync engine under it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

/// Maximum inline byte budget for a selected row, and the byte count per
/// chunk. Byte-based reads preserve Unicode and embedded NUL characters.
///
/// Well under Android's ~2 MB CursorWindow, because the budget is for the
/// WHOLE ROW: a row can carry several near-threshold columns plus the
/// engine's own bookkeeping and still have to fit. Deliberately not tuned to
/// the limit — the cost of chunking a column that would have fitted is one
/// extra query, and the cost of guessing wrong in the other direction is a
/// sync that cannot run at all.
const int syncLargeColumnThreshold = 256 * 1024;

/// Reads one row's [columns] without ever asking SQLite for a result set
/// that could exceed the CursorWindow.
///
/// The inline byte budget is shared by [columns]. Any column exceeding its
/// share comes back through [readLargeTextColumn] instead of inline. The returned map has the same
/// shape either way, so callers cannot tell which columns were chunked —
/// that is the point: a caller that has to remember is a caller that will
/// forget.
Future<Map<String, Object?>?> readSyncRow(
  DatabaseExecutor txn, {
  required String table,
  required String idColumn,
  required String entityId,
  required List<String> columns,
}) async {
  if (columns.isEmpty) return null;

  // `CASE WHEN length(c) > N THEN NULL ELSE c END` keeps every small column
  // inline (one query for the common case) while making a large one cost
  // nothing but its length here. Both are aliased back to the plain column
  // name so the result map matches what a naive `query()` would have given.
  final select = <String>[];
  final columnByteLimit = syncLargeColumnThreshold ~/ columns.length;
  for (final column in columns) {
    select.add(
      'CASE WHEN length(CAST("$column" AS BLOB)) > $columnByteLimit '
      'THEN NULL ELSE "$column" END AS "$column"',
    );
    select.add('length(CAST("$column" AS BLOB)) AS "${column}__len"');
  }

  final rows = await txn.rawQuery(
    'SELECT ${select.join(', ')} FROM "$table" '
    'WHERE CAST("$idColumn" AS TEXT) = ? LIMIT 1',
    [entityId],
  );
  if (rows.isEmpty) return null;

  final row = Map<String, Object?>.from(rows.first);
  final result = <String, Object?>{};
  for (final column in columns) {
    final value = row[column];
    final length = row['${column}__len'] as int? ?? 0;
    if (value == null && length > 0) {
      result[column] = await readLargeTextColumn(
        txn,
        table: table,
        column: column,
        idColumn: idColumn,
        entityId: entityId,
        totalLength: length,
      );
    } else {
      result[column] = value;
    }
  }
  return result;
}

/// Reads one oversized TEXT column back in byte slices. [totalLength] is
/// its UTF-8 byte length, as reported by `length(CAST(column AS BLOB))`.
/// Decoding happens only after reassembly, so a chunk may split a code point.
///
/// The sync engine's counterpart to `DatabaseService._readLargeString`,
/// which is private and keyed on a plain `id`. This one takes the same
/// `CAST(id AS TEXT)` predicate every sync reader uses, so a table whose id
/// is not TEXT (the two User-App library tables) behaves identically.
///
/// Fails if any chunk cannot be read completely. Returning a prefix would
/// mint a new sync operation containing truncated user data and publish it
/// as a legitimate edit, so an incomplete read must abort the transaction.
Future<String> readLargeTextColumn(
  DatabaseExecutor txn, {
  required String table,
  required String column,
  required String idColumn,
  required String entityId,
  required int totalLength,
  int chunkSize = syncLargeColumnThreshold,
}) => _readLargeWhere(
  txn,
  table: table,
  column: column,
  where: 'CAST("$idColumn" AS TEXT) = ?',
  whereArgs: [entityId],
  totalLength: totalLength,
  chunkSize: chunkSize,
);

/// The UTF-8 byte length of a column without reading it — for the places
/// that only need to know whether a value is present or empty.
///
/// `blob_gc.dart` and `blob_sync.dart` both used to ask for the column
/// itself to decide "is `appCode` still the empty placeholder?", which reads
/// a whole vendored WebAssembly build in order to compare it against `''`.
Future<int> syncColumnLength(
  DatabaseExecutor txn, {
  required String table,
  required String column,
  required String idColumn,
  required String entityId,
}) async {
  final rows = await txn.rawQuery(
    'SELECT length(CAST("$column" AS BLOB)) AS len FROM "$table" '
    'WHERE CAST("$idColumn" AS TEXT) = ? LIMIT 1',
    [entityId],
  );
  return rows.isEmpty ? 0 : (rows.first['len'] as int? ?? 0);
}

/// The where-clause form of [readSyncRow], for tables the sync engine keys
/// by something other than a single entity id.
///
/// **Added in M3.8's second half, for the push path.** The commit encoder
/// reads `sync_pending_ops` by `(authorId, authorSeq)` and the register
/// reader keys `sync_field_state` by three columns — neither fits the
/// single-`CAST(id AS TEXT)` shape, and both carry `valueJson`, which since
/// M3.2 can hold an entire mini app. Batching bounds a BATCH at 256 KiB but
/// deliberately sends a single oversized operation alone, so exactly the row
/// that cannot fit through a CursorWindow is the one push is guaranteed to
/// read on its own.
Future<List<Map<String, Object?>>> readSyncRowsWhere(
  DatabaseExecutor txn, {
  required String table,
  required List<String> columns,
  required String where,
  required List<Object?> whereArgs,
  String? orderBy,
  required List<String> keyColumns,
}) async {
  final selectedColumns = {...columns, ...keyColumns};
  if (selectedColumns.isEmpty) return [];
  final select = <String>[];
  final columnByteLimit = syncLargeColumnThreshold ~/ selectedColumns.length;
  for (final column in selectedColumns) {
    select.add(
      'CASE WHEN length(CAST("$column" AS BLOB)) > $columnByteLimit '
      'THEN NULL ELSE "$column" END AS "$column"',
    );
    select.add('length(CAST("$column" AS BLOB)) AS "${column}__len"');
  }
  final rows = await txn.rawQuery(
    'SELECT ${select.join(', ')} FROM "$table" WHERE $where'
    '${orderBy == null ? '' : ' ORDER BY $orderBy'}',
    whereArgs,
  );

  final out = <Map<String, Object?>>[];
  for (final raw in rows) {
    final result = <String, Object?>{};
    for (final column in {...columns, ...keyColumns}) {
      final value = raw[column];
      final length = raw['${column}__len'] as int? ?? 0;
      if (value == null && length > 0) {
        // Re-read this one column for this one row, addressed by the key
        // columns the caller named — the same substr walk as the entity
        // reader, without needing the table to have a single id column.
        result[column] = await _readLargeWhere(
          txn,
          table: table,
          column: column,
          where: [for (final k in keyColumns) '"$k" = ?'].join(' AND '),
          whereArgs: [for (final k in keyColumns) raw[k]],
          totalLength: length,
        );
      } else {
        result[column] = value;
      }
    }
    out.add(result);
  }
  return out;
}

Future<String> _readLargeWhere(
  DatabaseExecutor txn, {
  required String table,
  required String column,
  required String where,
  required List<Object?> whereArgs,
  required int totalLength,
  int chunkSize = syncLargeColumnThreshold,
}) async {
  if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
  final buffer = BytesBuilder(copy: false);
  for (var offset = 0; offset < totalLength; offset += chunkSize) {
    final size = (offset + chunkSize > totalLength)
        ? totalLength - offset
        : chunkSize;
    final rows = await txn.rawQuery(
      'SELECT substr(CAST("$column" AS BLOB), ?, ?) AS chunk '
      'FROM "$table" WHERE $where',
      [offset + 1, size, ...whereArgs],
    );
    final value = rows.isEmpty ? null : rows.first['chunk'];
    // SQLite TEXT length/substr stop at NUL. BLOB slices preserve every
    // byte and keep the CursorWindow budget independent of character set.
    if (value is! List<int> || value.length != size) {
      throw StateError(
        'Incomplete sync read of $table.$column at $offset/$totalLength',
      );
    }
    buffer.add(value);
  }
  return utf8.decode(buffer.takeBytes());
}
