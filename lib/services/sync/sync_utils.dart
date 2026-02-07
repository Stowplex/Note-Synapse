import 'package:sqflite/sqflite.dart';

/// Map of synced tables to their columns that require chunked reads
/// to avoid Android's 2 MB CursorWindow overflow.
const Map<String, List<String>> largeColumnsByTable = {
  'notes': ['content'],
  'conversation_messages': ['metadata'],
  'subnotes': ['content'],
};

/// Reads a potentially large TEXT column in chunks to avoid CursorWindow overflow.
///
/// Returns `null` when the column value is NULL or has zero length.
Future<String?> readLargeColumn(
  Database db,
  String table,
  String column,
  String id, {
  String idColumn = 'id',
  int chunkSize = 500000,
}) async {
  // Get total length
  final sizeResult = await db.rawQuery(
    'SELECT length($column) as sz FROM $table WHERE $idColumn = ?',
    [id],
  );
  if (sizeResult.isEmpty) return null;

  final totalSize = sizeResult.first['sz'] as int?;
  if (totalSize == null || totalSize == 0) return null;

  // Read in chunks using substr (1-based offset in SQLite)
  final sb = StringBuffer();
  for (int offset = 1; offset <= totalSize; offset += chunkSize) {
    final result = await db.rawQuery(
      'SELECT substr($column, ?, ?) as chunk FROM $table WHERE $idColumn = ?',
      [offset, chunkSize, id],
    );
    if (result.isNotEmpty && result.first['chunk'] != null) {
      sb.write(result.first['chunk'] as String);
    }
  }
  return sb.toString();
}
