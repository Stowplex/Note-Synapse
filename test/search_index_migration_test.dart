import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';

/// Tests for migration 61 -> 62: search_chunks, chunk_embeddings,
/// search_index_state tables + chunks_fts FTS4 virtual table + indexes.
///
/// 62, not 47: the layered-search migration was renumbered when this branch
/// merged with cloud sync, which had already consumed 47..61. The upgrade
/// these tests exercise is therefore the real one a shipped device performs
/// — off the full cloud-sync schema (61) onto 62 — not a synthetic 46 -> 47
/// hop that no database can ever be in.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const searchTables = [
    'search_chunks',
    'chunk_embeddings',
    'search_index_state',
  ];

  const searchIndexes = [
    'idx_search_chunks_key',
    'idx_search_chunks_noteId',
    'idx_search_chunks_source',
    'idx_attachments_noteId',
  ];

  Future<Map<String, String>> readSchemaSql(
    Database db,
    List<String> names,
  ) async {
    final result = <String, String>{};
    for (final name in names) {
      final rows = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = ?",
        [name],
      );
      expect(rows, isNotEmpty, reason: '$name should exist in sqlite_master');
      // Normalize whitespace so formatting differences don't matter
      result[name] = (rows.first['sql'] as String)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return result;
  }

  Future<void> verifySearchIndexSchema(Database db) async {
    // Tables exist
    for (final table in searchTables) {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      expect(tables, isNotEmpty, reason: '$table table should exist');
    }

    // Indexes exist
    for (final index in searchIndexes) {
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
        [index],
      );
      expect(indexes, isNotEmpty, reason: '$index index should exist');
    }

    // search_chunks columns match the plan schema
    final columns = await db.rawQuery("PRAGMA table_info('search_chunks')");
    final colNames = columns.map((c) => c['name'] as String).toList();
    expect(
      colNames,
      containsAll([
        'id',
        'chunkKey',
        'noteId',
        'sourceType',
        'sourceId',
        'page',
        'seq',
        'text',
        'meta',
        'contentHash',
        'updatedAt',
      ]),
    );

    // chunks_fts works: INSERT + MATCH round trip
    final ftsTable = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='chunks_fts'",
    );
    expect(ftsTable, isNotEmpty, reason: 'chunks_fts should exist');

    await db.execute(
      "INSERT INTO chunks_fts(docid, content) VALUES(42, 'hello searchable chunk text')",
    );
    final matches = await db.rawQuery(
      "SELECT docid FROM chunks_fts WHERE content MATCH 'searchable'",
    );
    expect(matches.length, 1);
    expect(matches.first['docid'], 42);
    await db.execute('DELETE FROM chunks_fts WHERE docid = 42');
  }

  test(
    'migrating a v62 database to v63 creates the search index schema',
    () async {
      final dbName =
          'search_index_migration_test_${DateTime.now().microsecondsSinceEpoch}.db';

      // 1. Create a fresh (v63) database, then strip it back to the v62
      // schema — every other table, including the fifteen sync_* control-
      // plane tables and their triggers, stays exactly as v62 left it.
      final freshService = DatabaseService.createNew(databaseName: dbName);
      final freshDb = await freshService.database;

      // Capture the expected schema before downgrading
      final expectedSql = await readSchemaSql(freshDb, [
        ...searchTables,
        ...searchIndexes,
      ]);

      await freshDb.execute('DROP TABLE IF EXISTS chunks_fts');
      await freshDb.execute('DROP TABLE IF EXISTS search_chunks');
      await freshDb.execute('DROP TABLE IF EXISTS chunk_embeddings');
      await freshDb.execute('DROP TABLE IF EXISTS search_index_state');
      await freshDb.execute('DROP INDEX IF EXISTS idx_attachments_noteId');
      await freshDb.update('_schema_version', {'version': 61});
      await freshService.close();

      // 2. Reopen: _handleCustomMigrations should run migration 62
      final migratedService = DatabaseService.createNew(databaseName: dbName);
      final migratedDb = await migratedService.database;

      final version = await migratedDb.query('_schema_version');
      expect(version.first['version'], DatabaseService.DATABASE_VERSION);

      await verifySearchIndexSchema(migratedDb);
      expect(migratedService.chunksFtsAvailable, isTrue);

      // 3. The migrated schema must be identical to the from-scratch schema
      final migratedSql = await readSchemaSql(migratedDb, [
        ...searchTables,
        ...searchIndexes,
      ]);
      expect(migratedSql, expectedSql);

      // 4. Migration 62 is purely additive on top of the cloud-sync schema:
      // the v62 control-plane tables it upgraded from are untouched.
      final syncTables = await migratedDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name LIKE 'sync\\_%' ESCAPE '\\'",
      );
      expect(
        syncTables.map((r) => r['name']),
        containsAll(<String>[
          'sync_field_state',
          'sync_set_state',
          'sync_pending_ops',
          'sync_materialize_queue',
        ]),
        reason: 'the v62 sync control plane must survive migration 62',
      );

      await migratedService.close();
    },
  );

  test(
    'partially-applied migration 62 (crash mid-migration) completes on reopen',
    () async {
      final dbName =
          'search_index_partial_test_${DateTime.now().microsecondsSinceEpoch}.db';

      // Simulate a crash after the first CREATE of migration 62: only
      // search_chunks exists, version still 61.
      final freshService = DatabaseService.createNew(databaseName: dbName);
      final freshDb = await freshService.database;
      await freshDb.execute('DROP TABLE IF EXISTS chunks_fts');
      await freshDb.execute('DROP TABLE IF EXISTS chunk_embeddings');
      await freshDb.execute('DROP TABLE IF EXISTS search_index_state');
      await freshDb.execute('DROP INDEX IF EXISTS idx_attachments_noteId');
      await freshDb.execute('DROP INDEX IF EXISTS idx_search_chunks_key');
      await freshDb.execute('DROP INDEX IF EXISTS idx_search_chunks_noteId');
      await freshDb.execute('DROP INDEX IF EXISTS idx_search_chunks_source');
      await freshDb.update('_schema_version', {'version': 61});
      await freshService.close();

      // Reopen: migration 62 must re-run idempotently (IF NOT EXISTS) and
      // create the missing objects instead of throwing on search_chunks.
      final migratedService = DatabaseService.createNew(databaseName: dbName);
      final migratedDb = await migratedService.database;

      final version = await migratedDb.query('_schema_version');
      expect(version.first['version'], DatabaseService.DATABASE_VERSION);
      await verifySearchIndexSchema(migratedDb);

      await migratedService.close();
    },
  );

  test('_onCreate from scratch produces the search index schema', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    await verifySearchIndexSchema(db);
    expect(dbService.chunksFtsAvailable, isTrue);

    await dbService.close();
  });

  test('idx_search_chunks_key enforces chunkKey uniqueness', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    final now = DateTime.now().millisecondsSinceEpoch;
    final chunk = {
      'chunkKey': 'note-1:note_body:-:0',
      'noteId': 'note-1',
      'sourceType': 'note_body',
      'seq': 0,
      'text': 'chunk text',
      'contentHash': 'hash-1',
      'updatedAt': now,
    };
    await db.insert('search_chunks', chunk);
    expect(
      () => db.insert('search_chunks', chunk),
      throwsA(isA<DatabaseException>()),
    );

    await dbService.close();
  });

  test('search_chunks rowid is aliased by id (stable chunk ids)', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('search_chunks', {
      'chunkKey': 'note-1:note_body:-:0',
      'noteId': 'note-1',
      'sourceType': 'note_body',
      'seq': 0,
      'text': 'chunk text',
      'contentHash': 'hash-1',
      'updatedAt': now,
    });
    final rows = await db.rawQuery(
      'SELECT id, rowid AS rid FROM search_chunks WHERE id = ?',
      [id],
    );
    expect(rows.single['id'], rows.single['rid']);

    await dbService.close();
  });
}
