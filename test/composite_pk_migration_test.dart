// Regression test for migration v43 (_migrateToVersion38).
//
// Covers the scenario where a previous migration attempt created
// conversation_message_mapping_new (or conversation_note_mapping_new) but was
// interrupted before completing, leaving a stranded temporary table.  Without
// the DROP TABLE IF EXISTS guard, every subsequent app launch would fail with
// "table conversation_message_mapping_new already exists".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // Create minimal parent tables required by FK constraints in the mapping tables.
  // SQLite enforces FK existence check at INSERT time when foreign_keys = ON.
  Future<void> _createParentTables(Database db) async {
    await db.execute(
      'CREATE TABLE conversations(id TEXT PRIMARY KEY)',
    );
    await db.execute(
      'CREATE TABLE conversation_messages(id TEXT PRIMARY KEY)',
    );
    await db.execute(
      'CREATE TABLE notes(id TEXT PRIMARY KEY)',
    );
  }

  group('migration v43 composite PK', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('migration_v43_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
      'succeeds when conversation_message_mapping_new already exists (stuck state)',
      () async {
        final dbPath = join(tempDir.path, 'test.db');

        // ── Phase 1: build the "stuck" database state ──────────────────────
        // Simulate a DB that is at _schema_version 42 but has a stranded
        // conversation_message_mapping_new table from a partial previous run.
        final rawDb = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(version: 1),
        );

        await rawDb.execute(
          'CREATE TABLE _schema_version (version INTEGER NOT NULL)',
        );
        await rawDb.insert('_schema_version', {'version': 42});

        // Parent tables required by FK constraints (checked on INSERT with FK=ON)
        await _createParentTables(rawDb);
        await rawDb.insert('conversations', {'id': 'conv-1'});
        await rawDb.insert('conversation_messages', {'id': 'msg-1'});
        await rawDb.insert('notes', {'id': 'note-1'});

        // Old-schema mapping tables (pre-v43 state)
        await rawDb.execute('''
          CREATE TABLE conversation_message_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            UNIQUE(conversationId, messageId)
          )
        ''');
        await rawDb.insert('conversation_message_mapping', {
          'conversationId': 'conv-1',
          'messageId': 'msg-1',
          'createdAt': 1000,
        });

        // Stranded _new table — the stuck state the bug manifests from
        await rawDb.execute('''
          CREATE TABLE conversation_message_mapping_new(
            conversationId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY (conversationId, messageId)
          )
        ''');

        await rawDb.execute('''
          CREATE TABLE conversation_note_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            noteId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            UNIQUE(conversationId, noteId)
          )
        ''');
        await rawDb.insert('conversation_note_mapping', {
          'conversationId': 'conv-1',
          'noteId': 'note-1',
          'createdAt': 2000,
        });

        // sync_conflicts already created by migration 42
        await rawDb.execute('''
          CREATE TABLE IF NOT EXISTS sync_conflicts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            row_id TEXT NOT NULL,
            field_name TEXT NOT NULL,
            local_value TEXT,
            remote_value TEXT,
            remote_device_id TEXT NOT NULL,
            remote_timestamp TEXT NOT NULL,
            resolved INTEGER DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');

        await rawDb.close();

        // ── Phase 2: open via DatabaseService — migration 43 must run ──────
        // Previously this would throw:
        //   DatabaseException(table conversation_message_mapping_new already exists)
        final dbService = DatabaseService.createNew(databaseName: dbPath);
        final db = await dbService.database; // must not throw

        // ── Phase 3: verify post-migration state ───────────────────────────
        // No stranded _new tables remain
        final stuckTables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_new'",
        );
        expect(stuckTables, isEmpty, reason: 'No _new tables should remain');

        // conversation_message_mapping now has composite PK
        final msgCols = await db.rawQuery(
          "PRAGMA table_info('conversation_message_mapping')",
        );
        final msgColNames = msgCols.map((c) => c['name'] as String).toList();
        expect(msgColNames, containsAll(['conversationId', 'messageId']));
        expect(msgColNames, isNot(contains('id')),
            reason: 'Old integer id column should be gone');

        // Data was migrated
        final mappings = await db.query('conversation_message_mapping');
        expect(mappings.length, 1);
        expect(mappings.first['conversationId'], 'conv-1');
        expect(mappings.first['messageId'], 'msg-1');

        // conversation_note_mapping also migrated
        final noteMappings = await db.query('conversation_note_mapping');
        expect(noteMappings.length, 1);
        expect(noteMappings.first['conversationId'], 'conv-1');
        expect(noteMappings.first['noteId'], 'note-1');

        // _schema_version updated to current
        final versionResult = await db.query('_schema_version');
        expect(versionResult.first['version'], DatabaseService.DATABASE_VERSION);
      },
    );

    test(
      'succeeds when mapping tables contain orphaned rows (FK constraint)',
      () async {
        // Regression test: orphaned rows (references to deleted conversations/messages/notes)
        // cause INSERT OR IGNORE to fail with SQLITE_CONSTRAINT_FOREIGNKEY because SQLite's
        // conflict-clause (OR IGNORE) does not suppress FK violations.
        // The fix filters orphaned rows via WHERE EXISTS during the INSERT.
        final dbPath = join(tempDir.path, 'test_orphans.db');

        final rawDb = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(version: 1),
        );
        await rawDb.execute(
          'CREATE TABLE _schema_version (version INTEGER NOT NULL)',
        );
        await rawDb.insert('_schema_version', {'version': 42});
        await _createParentTables(rawDb);

        // Insert one valid parent row each
        await rawDb.insert('conversations', {'id': 'conv-1'});
        await rawDb.insert('conversation_messages', {'id': 'msg-1'});
        await rawDb.insert('notes', {'id': 'note-1'});

        await rawDb.execute('''
          CREATE TABLE conversation_message_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            UNIQUE(conversationId, messageId)
          )
        ''');
        // Valid row
        await rawDb.insert('conversation_message_mapping', {
          'conversationId': 'conv-1',
          'messageId': 'msg-1',
          'createdAt': 1000,
        });
        // Orphaned row — 'ghost-conv' does not exist in conversations
        await rawDb.insert('conversation_message_mapping', {
          'conversationId': 'ghost-conv',
          'messageId': 'msg-1',
          'createdAt': 1001,
        });

        await rawDb.execute('''
          CREATE TABLE conversation_note_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            noteId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            UNIQUE(conversationId, noteId)
          )
        ''');
        // Valid row
        await rawDb.insert('conversation_note_mapping', {
          'conversationId': 'conv-1',
          'noteId': 'note-1',
          'createdAt': 2000,
        });
        // Orphaned row — 'ghost-note' does not exist in notes
        await rawDb.insert('conversation_note_mapping', {
          'conversationId': 'conv-1',
          'noteId': 'ghost-note',
          'createdAt': 2001,
        });

        await rawDb.execute('''
          CREATE TABLE IF NOT EXISTS sync_conflicts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            row_id TEXT NOT NULL,
            field_name TEXT NOT NULL,
            local_value TEXT,
            remote_value TEXT,
            remote_device_id TEXT NOT NULL,
            remote_timestamp TEXT NOT NULL,
            resolved INTEGER DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await rawDb.close();

        // Must not throw despite orphaned rows
        final dbService = DatabaseService.createNew(databaseName: dbPath);
        final db = await dbService.database;

        // Only the valid rows survive
        final msgMappings = await db.query('conversation_message_mapping');
        expect(msgMappings.length, 1);
        expect(msgMappings.first['conversationId'], 'conv-1');
        expect(msgMappings.first['messageId'], 'msg-1');

        final noteMappings = await db.query('conversation_note_mapping');
        expect(noteMappings.length, 1);
        expect(noteMappings.first['conversationId'], 'conv-1');
        expect(noteMappings.first['noteId'], 'note-1');

        final versionResult = await db.query('_schema_version');
        expect(versionResult.first['version'], DatabaseService.DATABASE_VERSION);
      },
    );

    test(
      'succeeds on a clean DB (no pre-existing _new table)',
      () async {
        final dbPath = join(tempDir.path, 'test_clean.db');

        final rawDb = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(version: 1),
        );
        await rawDb.execute(
          'CREATE TABLE _schema_version (version INTEGER NOT NULL)',
        );
        await rawDb.insert('_schema_version', {'version': 42});
        await _createParentTables(rawDb);
        await rawDb.execute('''
          CREATE TABLE conversation_message_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            UNIQUE(conversationId, messageId)
          )
        ''');
        await rawDb.execute('''
          CREATE TABLE conversation_note_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            noteId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            UNIQUE(conversationId, noteId)
          )
        ''');
        await rawDb.execute('''
          CREATE TABLE IF NOT EXISTS sync_conflicts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            row_id TEXT NOT NULL,
            field_name TEXT NOT NULL,
            local_value TEXT,
            remote_value TEXT,
            remote_device_id TEXT NOT NULL,
            remote_timestamp TEXT NOT NULL,
            resolved INTEGER DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await rawDb.close();

        final dbService = DatabaseService.createNew(databaseName: dbPath);
        final db = await dbService.database;

        final stuckTables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_new'",
        );
        expect(stuckTables, isEmpty);

        final msgCols = await db.rawQuery(
          "PRAGMA table_info('conversation_message_mapping')",
        );
        final msgColNames = msgCols.map((c) => c['name'] as String).toList();
        expect(msgColNames, isNot(contains('id')));

        final versionResult = await db.query('_schema_version');
        expect(versionResult.first['version'], DatabaseService.DATABASE_VERSION);
      },
    );
  });
}
