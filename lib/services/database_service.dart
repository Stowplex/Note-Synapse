import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Conditional imports for platform-specific code
import 'database_service_io.dart'
    if (dart.library.html) 'database_service_web.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/services.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/tag.dart';
import '../models/filter.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/conversation.dart';
import '../models/conversation_attachment.dart';
import '../models/attachment.dart';
import 'logger_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/global_keys.dart';
import '../screens/recovery_screen.dart';
import '../models/note_annotation.dart';

class MigrationStep {
  final String description;
  final Future<void> Function(Database db, {required bool isBackupMigration})
  execute;

  const MigrationStep({required this.description, required this.execute});
}

class DatabaseService {
  final String? _databaseNameOverride;

  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal({String? databaseNameOverride})
    : _databaseNameOverride = databaseNameOverride {
    // Initialize database factory using platform-specific implementation
    initializeDatabaseFactory();
  }

  // Current database version - exported for use by recovery/import operations
  static const int DATABASE_VERSION = 44; // Target schema version
  static const int SQFLITE_VERSION =
      999; // High value to prevent sqflite onUpgrade

  // Table schema constants - single source of truth for all table definitions
  static const String _createNotesTable = '''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY, -- Unique identifier
        title TEXT NOT NULL, -- Note title
        content TEXT NOT NULL, -- Note content
        type TEXT NOT NULL, -- 'note' or 'task'
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL, -- Last update timestamp
        scheduledAt TEXT, -- Scheduled date (for tasks)
        completeBy TEXT, -- Due date (for tasks)
        status TEXT, -- Task status: 'todo', 'inProgress', 'completed', 'cancelled'
        completionPercentage REAL, -- Task completion percentage
        pinned INTEGER NOT NULL DEFAULT 0, -- Whether note is pinned
        isArchived INTEGER NOT NULL DEFAULT 0, -- Whether note is archived
        recurrenceRule TEXT, -- JSON string defining recurrence rules
        metadata TEXT -- JSON metadata (e.g. in-note markers)
      )
  ''';

  static const String _createSubNotesTable = '''
      CREATE TABLE subnotes(
        id TEXT PRIMARY KEY, -- Unique identifier
        noteId TEXT NOT NULL, -- Parent note ID
        name TEXT NOT NULL, -- Subnote name (task item)
        content TEXT NOT NULL, -- Subnote content
        createdAt INTEGER NOT NULL, -- Creation timestamp
        isCompleted INTEGER NOT NULL DEFAULT 0, -- Completion status
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  static const String _createTagsTable = '''
      CREATE TABLE tags(
        id TEXT PRIMARY KEY, -- Unique identifier
        name TEXT NOT NULL UNIQUE, -- Tag name
        color TEXT NOT NULL, -- Tag color
        createdAt INTEGER NOT NULL, -- Creation timestamp
        usageCount INTEGER NOT NULL DEFAULT 0 -- Usage count
      )
  ''';

  static const String _createTagImagesTable = '''
      CREATE TABLE tag_images(
        tagId TEXT PRIMARY KEY,
        imagePath TEXT NOT NULL,
        FOREIGN KEY (tagId) REFERENCES tags(id) ON DELETE CASCADE
      )
  ''';

  static const String _createNoteAnnotationsTable = '''
      CREATE TABLE IF NOT EXISTS note_annotations (
        id              TEXT PRIMARY KEY,
        note_id         TEXT,
        attachment_id   TEXT,
        content         TEXT NOT NULL,
        attachment_paths TEXT,
        created_at      TEXT NOT NULL
      )
  ''';

  static const String _createNoteTagsTable = '''
      CREATE TABLE note_tags(
        noteId TEXT NOT NULL, -- Note ID
        tagId TEXT NOT NULL, -- Tag ID
        PRIMARY KEY (noteId, tagId),
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
  ''';

  static const String _createConversationTagsTable = '''
      -- conversation_tags table links conversations with tags, so that conversations can be searched / filtered by tag.
      CREATE TABLE conversation_tags(
        conversationId TEXT NOT NULL, -- Conversation ID
        tagId TEXT NOT NULL, -- Tag ID
        PRIMARY KEY (conversationId, tagId),
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
  ''';

  static const String _createAttachmentsTable = '''
      -- Attachments are external files associated with notes.
      CREATE TABLE attachments(
        id TEXT PRIMARY KEY, -- Unique identifier
        noteId TEXT NOT NULL, -- Parent note ID
        filePath TEXT NOT NULL, -- Path to file
        fileName TEXT NOT NULL, -- Original file name
        fileType TEXT NOT NULL, -- MIME type or extension
        isRelativePath INTEGER NOT NULL DEFAULT 1, -- Whether path is relative to app dir
        createdAt INTEGER NOT NULL, -- Creation timestamp
        includeInAIContext INTEGER NOT NULL DEFAULT 1, -- Whether to include in AI context
        metadata TEXT, -- JSON storage for attachment-specific data (bookmarks, AI context config, etc.)
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  static const String _createRelationshipsTable = '''
      -- Relationships table links notes with a relationship.
      CREATE TABLE relationships(
        id TEXT PRIMARY KEY, -- Unique identifier
        fromNoteId TEXT NOT NULL, -- Source note ID
        toNoteId TEXT NOT NULL, -- Target note ID
        type TEXT NOT NULL, -- Relationship type (e.g., 'linked', 'parent', 'child')
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (fromNoteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (toNoteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  static const String _createFiltersTable = '''
      -- Filters are set of tags and substring conditions to select certain notes.
      --   Filters can be considered to have hierarchy. A filter that matches tags A and B,
      --   is a parent filter of a filter that matches tags A, B and C.
      CREATE TABLE filters(
        id TEXT PRIMARY KEY, -- Unique identifier
        name TEXT NOT NULL, -- Filter name
        includeText TEXT, -- Text to search for
        includeTags TEXT NOT NULL, -- JSON array of tags to include
        excludeTags TEXT NOT NULL DEFAULT '', -- JSON array of tags to exclude
        noteTypes TEXT NOT NULL DEFAULT '', -- JSON array of note types
        includeArchived INTEGER NOT NULL DEFAULT 0, -- Whether to include archived notes
        isPinned INTEGER NOT NULL DEFAULT 0, -- Whether filter is pinned to top
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL -- Last update timestamp
      )
  ''';

  static const String _createUserAppsTable = '''
      CREATE TABLE user_apps(
        id TEXT PRIMARY KEY, -- Unique identifier
        uuid TEXT NOT NULL UNIQUE, -- Stable UUID across imports/exports
        name TEXT NOT NULL, -- App name
        description TEXT NOT NULL, -- App description
        steps TEXT NOT NULL, -- JSON array of steps/requirements
        htmlContent TEXT NOT NULL, -- Current HTML content (legacy, use revisions)
        appState TEXT, -- JSON object storage for app persistence
        type TEXT NOT NULL DEFAULT 'normal', -- App type: 'normal', 'noteAction', 'aiTool', etc.
        selectedRevisionId TEXT, -- Currently active revision ID
        author TEXT DEFAULT "", -- Author name
        license TEXT DEFAULT "", -- License text
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL -- Last update timestamp
      )
  ''';

  static const String _createAppRevisionsTable = '''
      CREATE TABLE app_revisions(
        id TEXT PRIMARY KEY, -- Unique identifier
        appId TEXT NOT NULL, -- Parent app ID
        revisionNumber INTEGER NOT NULL, -- Revision number
        revisionTimestamp INTEGER NOT NULL, -- Timestamp
        userPrompt TEXT NOT NULL, -- User instructions causing revision
        aiResponse TEXT NOT NULL, -- AI explanation/response
        appCode TEXT NOT NULL, -- Full HTML code of the app
        attachmentPaths TEXT, -- JSON array of attachment paths
        FOREIGN KEY (appId) REFERENCES user_apps (id) ON DELETE CASCADE
      )
  ''';

  static const String _createUserAppLibrariesTable = '''
      CREATE TABLE user_app_libraries(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        app_uuid TEXT NOT NULL, -- App UUID this library belongs to
        revision_id INTEGER NOT NULL, -- Revision number this library belongs to
        name TEXT NOT NULL, -- Library name
        usage_instructions TEXT, -- Instructions for using the library
        FOREIGN KEY (app_uuid) REFERENCES user_apps (uuid) ON DELETE CASCADE
      )
  ''';

  static const String _createUserAppLibraryDependenciesTable = '''
      CREATE TABLE user_app_library_dependencies(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        original_url TEXT, -- Original URL of the library
        local_path TEXT NOT NULL, -- Local storage path
        bytes BLOB NOT NULL, -- Raw file content
        library_id INTEGER NOT NULL, -- Parent library ID
        FOREIGN KEY (library_id) REFERENCES user_app_libraries (id) ON DELETE CASCADE
      )
  ''';

  static const String _createConversationsTable = '''
      -- conversations are threads of messages that represents interactions with AI.
      CREATE TABLE conversations(
        id TEXT PRIMARY KEY, -- Unique identifier
        title TEXT NOT NULL, -- Conversation title
        noteIds TEXT NOT NULL DEFAULT '[]', -- JSON array of linked note IDs (DEPRECATED, use conversation_note_mapping instead)
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL, -- Last update timestamp
        isArchived INTEGER NOT NULL DEFAULT 0 -- Whether archived
      )
  ''';

  static const String _createConversationMessagesTable = '''
      -- conversation_messages represent individual messages that appear in conversations. A message can be associated with multiple conversations
      -- in NoteSynapse's tree-structured conversation model.
      CREATE TABLE conversation_messages(
        id TEXT PRIMARY KEY, -- Unique identifier
        type TEXT NOT NULL, -- Message type: 'user', 'ai'
        content TEXT NOT NULL, -- Message content
        timestamp INTEGER NOT NULL, -- Timestamp
        modelUsed TEXT, -- AI model identifier if applicable
        metadata TEXT -- JSON string for extra metadata
      )
  ''';

  static const String _createConversationAttachmentsTable = '''
      CREATE TABLE conversation_attachments(
        id TEXT PRIMARY KEY, -- Unique identifier
        messageId TEXT NOT NULL, -- Parent message ID
        filePath TEXT NOT NULL, -- Path to file
        fileName TEXT NOT NULL, -- File name
        fileType TEXT NOT NULL, -- MIME type or extension
        isRelativePath INTEGER NOT NULL DEFAULT 0, -- Whether path is relative
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE
      )
  ''';

  static const String _createConversationMessageMappingTable = '''
      CREATE TABLE conversation_message_mapping(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        conversationId TEXT NOT NULL, -- Conversation ID
        messageId TEXT NOT NULL, -- Message ID
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        UNIQUE(conversationId, messageId)
      )
  ''';

  Future<void> insertConversationMessageMappingsBatch(
    String conversationId,
    List<String> messageIds,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final messageId in messageIds) {
        batch.insert('conversation_message_mapping', {
          'conversationId': conversationId,
          'messageId': messageId,
          'createdAt': now,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  static const String _createMessageParentsTable = '''
      CREATE TABLE message_parents(
        id TEXT PRIMARY KEY, -- Unique identifier
        messageId TEXT NOT NULL, -- Child message ID
        parentMessageId TEXT NOT NULL, -- Parent message ID
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        FOREIGN KEY (parentMessageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        UNIQUE(messageId, parentMessageId)
      )
  ''';

  static const String _createConversationNoteMappingTable = '''
      CREATE TABLE conversation_note_mapping(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        conversationId TEXT NOT NULL, -- Conversation ID
        noteId TEXT NOT NULL, -- Note ID
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
        UNIQUE(conversationId, noteId)
      )
  ''';
  static const String _createMultiFunctionAppsTable = '''
      CREATE TABLE multi_function_apps(
        appId TEXT PRIMARY KEY, -- App ID
        isDefault INTEGER NOT NULL DEFAULT 0, -- Whether it is the default app
        addedAt INTEGER NOT NULL, -- Timestamp added
        FOREIGN KEY (appId) REFERENCES user_apps (id) ON DELETE CASCADE
      )
  ''';

  static const String _createTagAiConfigsTable = '''
      CREATE TABLE tag_ai_configs (
        tagId TEXT PRIMARY KEY,
        extractionPrompt TEXT,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
  ''';

  // FTS4 is universally supported on all platforms (Android, iOS, macOS, Windows, Linux)
  static const String _createNotesFtsTable = '''
      CREATE VIRTUAL TABLE notes_fts USING fts4(
        title, 
        content
      );
  ''';

  static const String _createNotesFtsInsertTrigger = '''
      CREATE TRIGGER notes_ai_insert AFTER INSERT ON notes
      BEGIN
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
  ''';

  static const String _createNotesFtsDeleteTrigger = '''
      CREATE TRIGGER notes_ai_delete AFTER DELETE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
      END;
  ''';

  static const String _createNotesFtsUpdateTrigger = '''
      CREATE TRIGGER notes_ai_update AFTER UPDATE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
  ''';

  // Index creation constants
  static const List<String> _createIndexes = [
    'CREATE INDEX idx_notes_type ON notes(type)',
    'CREATE INDEX idx_notes_createdAt ON notes(createdAt)',
    'CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)',
    'CREATE INDEX idx_notes_completeBy ON notes(completeBy)',
    'CREATE INDEX idx_notes_pinned ON notes(pinned)',
    'CREATE INDEX idx_notes_isArchived ON notes(isArchived)',
    'CREATE INDEX idx_relationships_fromNoteId ON relationships(fromNoteId)',
    'CREATE INDEX idx_relationships_toNoteId ON relationships(toNoteId)',
    'CREATE INDEX idx_user_app_libraries_app_uuid ON user_app_libraries(app_uuid)',
    'CREATE INDEX idx_user_app_libraries_revision_id ON user_app_libraries(revision_id)',
    'CREATE INDEX idx_user_app_library_dependencies_library_id ON user_app_library_dependencies(library_id)',
    'CREATE INDEX idx_user_app_library_dependencies_local_path ON user_app_library_dependencies(local_path)',
    'CREATE INDEX idx_conversations_createdAt ON conversations(createdAt)',
    'CREATE INDEX idx_conversations_isArchived ON conversations(isArchived)',
    'CREATE INDEX idx_conversation_messages_timestamp ON conversation_messages(timestamp)',
    'CREATE INDEX idx_conversation_attachments_messageId ON conversation_attachments(messageId)',
    'CREATE INDEX idx_conversation_message_mapping_conversationId ON conversation_message_mapping(conversationId)',
    'CREATE INDEX idx_conversation_message_mapping_messageId ON conversation_message_mapping(messageId)',
    'CREATE INDEX idx_message_parents_messageId ON message_parents(messageId)',
    'CREATE INDEX idx_message_parents_parentMessageId ON message_parents(parentMessageId)',
    'CREATE INDEX idx_conversation_note_mapping_conversationId ON conversation_note_mapping(conversationId)',
    'CREATE INDEX idx_conversation_note_mapping_noteId ON conversation_note_mapping(noteId)',
    'CREATE INDEX idx_conversation_tags_conversationId ON conversation_tags(conversationId)',
    'CREATE INDEX idx_conversation_tags_tagId ON conversation_tags(tagId)',
  ];

  final Uuid _uuid = const Uuid();

  static String _generateTestDatabaseName() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final randomSuffix = const Uuid().v4();
    return 'note_synapse_test_${timestamp}_$randomSuffix.db';
  }

  /// Returns the complete schema of the database as a list of CREATE TABLE statements
  static List<String> getSchema() {
    return [
      _createNotesTable,
      _createSubNotesTable,
      _createTagsTable,
      _createNoteTagsTable,
      _createConversationTagsTable,
      _createAttachmentsTable,
      _createRelationshipsTable,
      _createFiltersTable,
      _createUserAppsTable,
      _createAppRevisionsTable,
      _createUserAppLibrariesTable,
      _createUserAppLibraryDependenciesTable,
      _createConversationsTable,
      _createConversationMessagesTable,
      _createConversationAttachmentsTable,
      _createConversationMessageMappingTable,
      _createMessageParentsTable,
      _createConversationNoteMappingTable,
      _createMultiFunctionAppsTable,
      ..._createIndexes,
    ];
  }

  /// Returns the complete schema description as a formatted string
  static String getSchemaDescription() {
    return getSchema().join('\n\n');
  }

  // For testing, allow creating new instances
  DatabaseService.createNew({String? databaseName})
    : _databaseNameOverride = databaseName ?? _generateTestDatabaseName() {
    // Initialize database factory using platform-specific implementation
    initializeDatabaseFactory();
  }

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbName = _databaseNameOverride ?? 'note_synapse.db';
    final path = p.join(await getDatabasesPath(), dbName);

    // Perform pre-migration backup BEFORE openDatabase
    // This is critical because _onUpgrade runs inside a transaction
    // where PRAGMA wal_checkpoint cannot be executed
    await _performPreMigrationBackupIfNeeded(path);

    return await openDatabase(
      path,
      version: SQFLITE_VERSION, // High value to prevent sqflite's onUpgrade
      onCreate: _onCreate,
      // onUpgrade removed - migrations now handled in onOpen via _handleCustomMigrations
      onOpen: _onOpen,
      singleInstance: _databaseNameOverride == null,
    );
  }

  /// Check if migration is needed and create a backup before openDatabase
  /// This runs outside any transaction, allowing WAL checkpoint to succeed
  Future<void> _performPreMigrationBackupIfNeeded(String dbPath) async {
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      // New database, no backup needed
      return;
    }

    // Open database read-only to check version, without triggering migration
    Database? checkDb;
    try {
      checkDb = await openDatabase(
        dbPath,
        readOnly: true,
        singleInstance: false,
      );
      final versionResult = await checkDb.rawQuery('PRAGMA user_version');
      final currentVersion = versionResult.isNotEmpty
          ? versionResult.first['user_version'] as int
          : 0;

      if (currentVersion < DATABASE_VERSION && currentVersion > 0) {
        // Migration is needed, create backup
        LoggerService.info(
          'Migration needed from version $currentVersion to $DATABASE_VERSION. Creating backup...',
        );
        await checkDb.close();
        checkDb = null;

        // Now create backup with a fresh connection that can do WAL checkpoint
        await _createPreMigrationBackup(dbPath, currentVersion);
      }
    } catch (e) {
      LoggerService.error('Error checking database version: $e', error: e);
      // If we can't check the version, we'll let openDatabase handle it
    } finally {
      if (checkDb != null && checkDb.isOpen) {
        await checkDb.close();
      }
    }
  }

  /// Create a backup of the database before migration
  /// Called outside any transaction, so WAL checkpoint should succeed
  Future<void> _createPreMigrationBackup(String dbPath, int fromVersion) async {
    Database? backupDb;
    try {
      LoggerService.info('Starting pre-migration backup...');

      // Open a fresh connection (not read-only) to do the checkpoint
      backupDb = await openDatabase(dbPath, singleInstance: false);

      // Force checkpoint to ensure WAL is merged
      await backupDb.rawQuery('PRAGMA wal_checkpoint(FULL)');
      await backupDb.close();
      backupDb = null;

      // Now copy the file
      final dbFile = File(dbPath);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final backupPath = p.join(
        p.dirname(dbPath),
        'backup_v${fromVersion}_pre_migration_$timestamp.db',
      );

      await dbFile.copy(backupPath);
      LoggerService.info('Pre-migration backup created at: $backupPath');
    } catch (e) {
      LoggerService.error(
        'Failed to create pre-migration backup: $e',
        error: e,
      );
      // Rethrow to let the caller handle it - migration should not proceed without backup
      rethrow;
    } finally {
      if (backupDb != null && backupDb.isOpen) {
        await backupDb.close();
      }
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    // Enable foreign key constraints for new databases
    await db.execute('PRAGMA foreign_keys = ON');

    // Create schema version tracking table
    await db.execute('''
      CREATE TABLE _schema_version (
        version INTEGER NOT NULL
      )
    ''');
    // Initialize with current schema version for new databases
    await db.insert('_schema_version', {'version': DATABASE_VERSION});

    // Create all tables using schema constants
    await db.execute(_createNotesTable);
    await db.execute(_createSubNotesTable);
    await db.execute(_createTagsTable);
    await db.execute(_createTagImagesTable);
    await db.execute(_createNoteTagsTable);
    await db.execute(_createAttachmentsTable);
    await db.execute(_createRelationshipsTable);
    await db.execute(_createFiltersTable);
    await db.execute(_createUserAppsTable);
    await db.execute(_createAppRevisionsTable);
    await db.execute(_createUserAppLibrariesTable);
    await db.execute(_createUserAppLibraryDependenciesTable);
    await db.execute(_createConversationsTable);
    await db.execute(_createConversationMessagesTable);
    await db.execute(_createConversationAttachmentsTable);

    await db.execute(_createConversationMessageMappingTable);
    await db.execute(_createMessageParentsTable);
    await db.execute(_createConversationNoteMappingTable);
    await db.execute(_createConversationTagsTable);
    await db.execute(_createMultiFunctionAppsTable);
    await db.execute(_createNoteAnnotationsTable);

    // Create AI-related tables (missing in previous versions' onCreate)
    await db.execute(_createTagAiConfigsTable);

    // Create FTS table and triggers
    await db.execute(_createNotesFtsTable);
    await db.execute(_createNotesFtsInsertTrigger);
    await db.execute(_createNotesFtsDeleteTrigger);
    await db.execute(_createNotesFtsUpdateTrigger);

    // Create all indexes
    for (final indexSql in _createIndexes) {
      await db.execute(indexSql);
    }
  }

  Future<void> _onOpen(Database db) async {
    // Enable foreign key constraints every time the database is opened
    // This is required because SQLite disables foreign keys by default
    await db.execute('PRAGMA foreign_keys = ON');

    // Custom schema version tracking - migrations only run onOpen, not onUpgrade
    await _handleCustomMigrations(db);
  }

  /// Handles migrations using custom _schema_version table
  /// Version is only updated AFTER successful migration
  Future<void> _handleCustomMigrations(Database db) async {
    // Check if _schema_version table exists (might be legacy DB)
    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='_schema_version'",
    );

    int currentVersion;
    if (tableCheck.isEmpty) {
      // Legacy database - create version table and get version from PRAGMA
      await db.execute('''
        CREATE TABLE _schema_version (
          version INTEGER NOT NULL
        )
      ''');
      // Get current version from sqflite's PRAGMA
      final pragmaVersion = await db.rawQuery('PRAGMA user_version');
      currentVersion = pragmaVersion.isNotEmpty
          ? pragmaVersion.first['user_version'] as int
          : 0;
      // SQFLITE_VERSION (999) is a sentinel value passed to openDatabase()
      // to prevent sqflite's built-in onUpgrade. If we read it back here,
      // it means this is a legacy DB that was already opened with the new
      // system but never had _schema_version created. Fall back to the
      // last known pre-custom-migration version.
      if (currentVersion == 0 || currentVersion >= SQFLITE_VERSION) {
        currentVersion = 19; // Assume min supported version
      }
      await db.insert('_schema_version', {'version': currentVersion});
      LoggerService.info(
        'Created _schema_version table, initialized from PRAGMA: v$currentVersion',
      );
    } else {
      // Read current version from custom table
      final versionResult = await db.query('_schema_version');
      currentVersion = versionResult.isNotEmpty
          ? versionResult.first['version'] as int
          : 0;
      // Fix corrupted version: if _schema_version was set to the SQFLITE_VERSION
      // sentinel (999) due to the legacy PRAGMA fallback bug, reset it to the
      // actual DATABASE_VERSION and re-run any missing migrations.
      if (currentVersion >= SQFLITE_VERSION) {
        LoggerService.warning(
          'Detected corrupted _schema_version ($currentVersion), resetting to run missing migrations',
        );
        // Determine actual version by checking which tables/columns exist
        currentVersion = await _detectActualSchemaVersion(db);
        await db.update('_schema_version', {'version': currentVersion});
      }
    }

    if (currentVersion >= DATABASE_VERSION) {
      return; // No migration needed
    }

    LoggerService.info(
      'Migration needed: v$currentVersion -> v$DATABASE_VERSION',
    );

    // Run migrations
    bool migrationSuccess = true;
    for (
      int version = currentVersion + 1;
      version <= DATABASE_VERSION;
      version++
    ) {
      final migrationStep = _migrationSteps[version];
      if (migrationStep == null) {
        LoggerService.warning('No migration step defined for version $version');
        continue;
      }

      try {
        LoggerService.info(
          'Executing migration to version $version: ${migrationStep.description}',
        );
        await migrationStep.execute(db, isBackupMigration: false);
        LoggerService.info('Successfully migrated to version $version');
      } catch (e) {
        LoggerService.error(
          'Migration to version $version failed: $e',
          error: e,
        );
        migrationSuccess = false;

        // Navigate to RecoveryScreen with error
        _navigateToRecoveryScreen('Migration failed at version $version: $e');
        break; // Stop migration on error
      }
    }

    // Only update version if ALL migrations succeeded
    if (migrationSuccess) {
      await db.update('_schema_version', {'version': DATABASE_VERSION});
      LoggerService.info('Schema version updated to $DATABASE_VERSION');
    }
  }

  /// Detect the actual schema version by probing for tables/columns
  /// introduced in known migration steps. Returns the highest version
  /// whose schema changes are present.
  static Future<int> _detectActualSchemaVersion(Database db) async {
    int detected = 19; // Minimum supported version

    // Check for tag_images table (v41)
    final tagImagesCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tag_images'",
    );
    if (tagImagesCheck.isNotEmpty) detected = 41;

    // Check for notes_fts table (v31/v36)
    if (detected < 36) {
      final ftsCheck = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='notes_fts'",
      );
      if (ftsCheck.isNotEmpty) detected = 36;
    }

    // Check for metadata column in attachments (v32)
    if (detected < 32) {
      final attachCols = await db.rawQuery("PRAGMA table_info('attachments')");
      if (attachCols.any((c) => c['name'] == 'metadata')) detected = 32;
    }

    // Check for recurrenceRule in notes (v30)
    if (detected < 30) {
      final notesCols = await db.rawQuery("PRAGMA table_info('notes')");
      if (notesCols.any((c) => c['name'] == 'recurrenceRule')) detected = 30;
    }

    // Check for excludeTags in filters (v28)
    if (detected < 28) {
      final filtersCols = await db.rawQuery("PRAGMA table_info('filters')");
      if (filtersCols.any((c) => c['name'] == 'excludeTags')) detected = 28;
    }

    LoggerService.info('Detected actual schema version: $detected');
    return detected;
  }

  /// Navigate to RecoveryScreen with error message
  void _navigateToRecoveryScreen(String error) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = navigatorKey.currentContext;
      if (context != null) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => RecoveryScreen(error: error)),
          (route) => false, // Remove all previous routes
        );
      } else {
        LoggerService.error(
          'Navigator context is null, cannot navigate to recovery screen. Error: $error',
        );
      }
    });
  }

  // Note: _onUpgrade removed - migrations now in _handleCustomMigrations

  // Migration configuration structure
  // All clients are now on version 20 or later
  static const Map<int, MigrationStep> _migrationSteps = {
    20: MigrationStep(
      description:
          'Fix conversation_messages table schema (remove conversationId if still present)',
      execute: _migrateToVersion20,
    ),
    21: MigrationStep(
      description:
          'Create conversation_note_mapping table and migrate existing noteIds data',
      execute: _migrateToVersion21,
    ),
    22: MigrationStep(
      description: 'Create conversation_tags table for shared tag support',
      execute: _migrateToVersion22,
    ),
    23: MigrationStep(
      description:
          'Add UNIQUE constraint to user_apps.uuid column for foreign key integrity',
      execute: _migrateToVersion23,
    ),
    25: MigrationStep(
      description: 'Add includeInAIContext column to attachments table',
      execute: _migrateToVersion24,
    ),
    26: MigrationStep(
      description: 'Create multi_function_apps table',
      execute: _migrateToVersion26,
    ),
    27: MigrationStep(
      description: 'Add isPinned column to filters table',
      execute: _migrateToVersion27,
    ),
    28: MigrationStep(
      description: 'Add excludeTags and noteTypes columns to filters table',
      execute: _migrateToVersion28,
    ),
    29: MigrationStep(
      description: 'Ensure multi_function_apps table exists',
      execute: _migrateToVersion29,
    ),
    30: MigrationStep(
      description: 'Add recurrenceRule column to notes table',
      execute: _migrateToVersion30,
    ),
    31: MigrationStep(
      description: 'Create notes_fts virtual table and tag_ai_configs table',
      execute: _migrateToVersion31,
    ),
    32: MigrationStep(
      description:
          'Add metadata column to attachments table for PDF bookmarks and AI context config',
      execute: _migrateToVersion32,
    ),
    36: MigrationStep(
      description:
          'Fix notes_fts FTS5 table by removing incorrect content_rowid option',
      execute: _migrateToVersion36,
    ),
    41: MigrationStep(
      description: 'Create tag_images table for image-augmented tags',
      execute: _migrateToVersion41,
    ),
    42: MigrationStep(
      description: 'Add metadata column to notes table for in-note markers',
      execute: _migrateToVersion42,
    ),
    43: MigrationStep(
      description:
          'Convert absolute paths to relative in conversation_attachments',
      execute: _migrateToVersion43,
    ),
    44: MigrationStep(
      description: 'Create note_annotations table for scratchpad annotations',
      execute: _migrateToVersion44,
    ),
  };

  static Future<void> _migrateToVersion43(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Migrating conversation_attachments absolute paths to relative paths (v43)',
    );

    // Find all conversation_attachments with absolute paths
    final attachments = await db.query(
      'conversation_attachments',
      where: "filePath LIKE '/%'",
    );

    int migratedCount = 0;
    for (final attachment in attachments) {
      final id = attachment['id'] as String;
      final filePath = attachment['filePath'] as String;
      final fileName = attachment['fileName'] as String;
      final messageId = attachment['messageId'] as String;

      String newRelativePath;

      if (filePath.contains('/attachments/')) {
        // Path is absolute but already points inside attachments/
        // Just extract the attachments/ part
        final parts = filePath.split('/attachments/');
        if (parts.length > 1) {
          newRelativePath = 'attachments/${parts[1]}';
        } else {
          newRelativePath = 'attachments/$fileName';
        }
      } else {
        // Path is completely external (e.g., in synapse_temp)
        final uniqueName = '${messageId}_$fileName';
        newRelativePath = 'attachments/$uniqueName';

        try {
          final file = File(filePath);
          if (await file.exists()) {
            final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
            final targetPath = p.join(attachmentsDir.path, uniqueName);
            // Don't copy if it's already there (shouldn't happen due to the else branch, but safe to check)
            if (filePath != targetPath) {
              await file.copy(targetPath);
            }
          }
        } catch (e) {
          LoggerService.warning(
            'Failed to copy attachment during v43 migration: $filePath, error: $e',
          );
        }
      }

      await db.update(
        'conversation_attachments',
        {'filePath': newRelativePath, 'isRelativePath': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
      migratedCount++;
    }

    LoggerService.info(
      'Migrated $migratedCount absolute paths in conversation_attachments',
    );
  }

  static Future<void> _migrateToVersion44(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute(_createNoteAnnotationsTable);
  }

  static Future<void> _migrateToVersion28(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // Add new columns to filters table
    await db.execute(
      "ALTER TABLE filters ADD COLUMN excludeTags TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE filters ADD COLUMN noteTypes TEXT NOT NULL DEFAULT ''",
    );
  }

  static Future<void> _migrateToVersion30(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // Add recurrenceRule column to notes table
    await db.execute("ALTER TABLE notes ADD COLUMN recurrenceRule TEXT");
  }

  static Future<void> _migrateToVersion31(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // 1. Create notes_fts virtual table using FTS4 (universally supported on all platforms)
    await db.execute('''
      CREATE VIRTUAL TABLE notes_fts USING fts4(
        title, 
        content
      );
    ''');

    // 2. Populate notes_fts with existing data
    await db.execute('''
      INSERT INTO notes_fts(docid, title, content)
      SELECT rowid, title, content FROM notes;
    ''');

    // 3. Create Triggers to keep notes_fts in sync
    // INSERT Trigger
    await db.execute('''
      CREATE TRIGGER notes_ai_insert AFTER INSERT ON notes
      BEGIN
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
    ''');

    // DELETE Trigger
    await db.execute('''
      CREATE TRIGGER notes_ai_delete AFTER DELETE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
      END;
    ''');

    // UPDATE Trigger
    await db.execute('''
      CREATE TRIGGER notes_ai_update AFTER UPDATE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
    ''');

    // 4. Create tag_ai_configs table
    await db.execute('''
      CREATE TABLE tag_ai_configs (
        tagId TEXT PRIMARY KEY,
        extractionPrompt TEXT,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
    ''');
  }

  // Individual migration methods
  static Future<void> _migrateToVersion20(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 20: Ensuring conversation_messages schema is correct',
    );

    try {
      // Check if conversationId column exists by trying to query it
      final testQuery = await db.rawQuery(
        'PRAGMA table_info(conversation_messages)',
      );
      final hasConversationId = testQuery.any(
        (col) => col['name'] == 'conversationId',
      );

      if (hasConversationId) {
        LoggerService.info(
          'Found conversationId column in conversation_messages, removing it...',
        );

        // Drop the index if it exists
        await db.execute(
          'DROP INDEX IF EXISTS idx_conversation_messages_conversationId',
        );

        // Recreate the table without conversationId
        await db.execute(
          'ALTER TABLE conversation_messages RENAME TO conversation_messages_old',
        );
        await db.execute(_createConversationMessagesTable);

        // Copy data from old table to new table
        await db.execute('''
          INSERT INTO conversation_messages (id, type, content, timestamp, modelUsed, metadata)
          SELECT id, type, content, timestamp, modelUsed, metadata FROM conversation_messages_old
        ''');

        // Drop the old table
        await db.execute('DROP TABLE conversation_messages_old');

        // Recreate the timestamp index
        await db.execute(
          'CREATE INDEX idx_conversation_messages_timestamp ON conversation_messages(timestamp)',
        );

        LoggerService.info(
          'Successfully removed conversationId column from conversation_messages',
        );
      } else {
        LoggerService.info(
          'conversation_messages table already has correct schema (no conversationId column)',
        );
      }

      // Ensure all required tables and indexes exist
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS conversation_message_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
            FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
            UNIQUE(conversationId, messageId)
          )
        ''');
      } catch (e) {
        LoggerService.debug(
          'conversation_message_mapping table already exists',
        );
      }

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS message_parents(
            id TEXT PRIMARY KEY,
            messageId TEXT NOT NULL,
            parentMessageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
            FOREIGN KEY (parentMessageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
            UNIQUE(messageId, parentMessageId)
          )
        ''');
      } catch (e) {
        LoggerService.debug('message_parents table already exists');
      }

      // Ensure indexes exist
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_message_mapping_conversationId ON conversation_message_mapping(conversationId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_message_mapping_messageId ON conversation_message_mapping(messageId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_message_parents_messageId ON message_parents(messageId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_message_parents_parentMessageId ON message_parents(parentMessageId)',
      );

      LoggerService.info('Migration to version 20 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 20: $e', error: e);
      rethrow;
    }
  }

  // Migration to version 21: Create conversation_note_mapping table and migrate data
  static Future<void> _migrateToVersion21(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 21: Creating conversation_note_mapping table and migrating data',
    );

    try {
      // Create the conversation_note_mapping table
      await db.execute('''
        CREATE TABLE conversation_note_mapping(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversationId TEXT NOT NULL,
          noteId TEXT NOT NULL,
          createdAt INTEGER NOT NULL,
          FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
          FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
          UNIQUE(conversationId, noteId)
        )
      ''');

      // Create indexes
      await db.execute(
        'CREATE INDEX idx_conversation_note_mapping_conversationId ON conversation_note_mapping(conversationId)',
      );
      await db.execute(
        'CREATE INDEX idx_conversation_note_mapping_noteId ON conversation_note_mapping(noteId)',
      );

      LoggerService.info('Created conversation_note_mapping table and indexes');

      // Migrate existing noteIds data to the new mapping table
      final conversations = await db.query('conversations');
      int migratedCount = 0;

      for (final conversation in conversations) {
        final conversationId = conversation['id'] as String;
        final noteIdsJson = conversation['noteIds'] as String?;

        if (noteIdsJson != null && noteIdsJson.isNotEmpty) {
          try {
            final noteIds = List<String>.from(jsonDecode(noteIdsJson));
            final now = DateTime.now().millisecondsSinceEpoch;

            for (final noteId in noteIds) {
              // Check if the note still exists before creating the mapping
              final noteExists = await db.query(
                'notes',
                where: 'id = ?',
                whereArgs: [noteId],
                limit: 1,
              );

              if (noteExists.isNotEmpty) {
                await db.insert(
                  'conversation_note_mapping',
                  {
                    'conversationId': conversationId,
                    'noteId': noteId,
                    'createdAt': now,
                  },
                  conflictAlgorithm: ConflictAlgorithm.ignore,
                );
                migratedCount++;
              } else {
                LoggerService.warning(
                  'Skipping migration for non-existent note: $noteId in conversation: $conversationId',
                );
              }
            }
          } catch (e) {
            LoggerService.error(
              'Error parsing noteIds for conversation $conversationId: $e',
            );
          }
        }
      }

      LoggerService.info('Migrated $migratedCount note-conversation mappings');
      LoggerService.info('Migration to version 21 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 21: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion22(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 22: Creating conversation_tags table',
    );

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS conversation_tags(
          conversationId TEXT NOT NULL,
          tagId TEXT NOT NULL,
          PRIMARY KEY (conversationId, tagId),
          FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
          FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
        )
      ''');

      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_tags_conversationId ON conversation_tags(conversationId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_tags_tagId ON conversation_tags(tagId)',
      );

      LoggerService.info('Migration to version 22 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 22: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion23(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 23: Adding UNIQUE constraint to user_apps.uuid column',
    );

    try {
      // Check if user_apps table exists
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='user_apps'",
      );

      if (tables.isEmpty) {
        LoggerService.info(
          'user_apps table does not exist, skipping migration',
        );
        return;
      }

      // Temporarily disable foreign key constraints
      await db.execute('PRAGMA foreign_keys = OFF');

      // Begin transaction
      await db.execute('BEGIN TRANSACTION');

      try {
        // Rename the old table
        await db.execute('ALTER TABLE user_apps RENAME TO user_apps_old');

        // Create the new table with UNIQUE constraint on uuid
        await db.execute(_createUserAppsTable);

        // Copy data from old table to new table
        await db.execute('''
          INSERT INTO user_apps (id, uuid, name, description, steps, htmlContent, appState, type, selectedRevisionId, author, license, createdAt, updatedAt)
          SELECT id, uuid, name, description, steps, htmlContent, appState, type, selectedRevisionId, author, license, createdAt, updatedAt
          FROM user_apps_old
        ''');

        // Drop the old table
        await db.execute('DROP TABLE user_apps_old');

        // Commit transaction
        await db.execute('COMMIT');

        LoggerService.info(
          'Successfully migrated user_apps table with UNIQUE uuid constraint',
        );
      } catch (e) {
        // Rollback on error
        await db.execute('ROLLBACK');
        LoggerService.error(
          'Error during user_apps table migration, rolled back: $e',
        );
        rethrow;
      } finally {
        // Re-enable foreign key constraints
        await db.execute('PRAGMA foreign_keys = ON');
      }

      LoggerService.info('Migration to version 23 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 23: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion24(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 24: Adding includeInAIContext column to attachments table',
    );

    try {
      // Check if column already exists
      final tableInfo = await db.rawQuery('PRAGMA table_info(attachments)');
      final hasColumn = tableInfo.any(
        (column) => column['name'] == 'includeInAIContext',
      );

      if (!hasColumn) {
        await db.execute(
          'ALTER TABLE attachments ADD COLUMN includeInAIContext INTEGER NOT NULL DEFAULT 1',
        );
        LoggerService.info(
          'Successfully added includeInAIContext column to attachments table',
        );
      } else {
        LoggerService.info(
          'includeInAIContext column already exists in attachments table',
        );
      }
    } catch (e) {
      LoggerService.error('Error in migration to version 24: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion26(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute(_createMultiFunctionAppsTable);
  }

  static Future<void> _migrateToVersion29(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // Ensure multi_function_apps table exists
    // We use a safe creation check
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='multi_function_apps'",
    );

    if (tables.isEmpty) {
      LoggerService.info('Creating multi_function_apps table (migration v29)');
      await db.execute(_createMultiFunctionAppsTable);
    } else {
      LoggerService.info(
        'multi_function_apps table already exists (migration v29)',
      );
    }
  }

  static Future<void> _migrateToVersion32(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 32: Adding metadata column to attachments table',
    );

    try {
      // Check if column already exists
      final tableInfo = await db.rawQuery('PRAGMA table_info(attachments)');
      final hasColumn = tableInfo.any((column) => column['name'] == 'metadata');

      if (!hasColumn) {
        await db.execute('ALTER TABLE attachments ADD COLUMN metadata TEXT');
        LoggerService.info(
          'Successfully added metadata column to attachments table',
        );
      } else {
        LoggerService.info(
          'metadata column already exists in attachments table',
        );
      }
    } catch (e) {
      LoggerService.error('Error in migration to version 32: $e', error: e);
      rethrow;
    }
  }

  // Migration to version 36: Fix notes_fts table by recreating it with FTS4
  // The original migration had issues (FTS5 with incorrect content_rowid option on iOS,
  // and mixed FTS4/FTS5 code paths). This migration drops and recreates the FTS table
  // using only FTS4 for cross-platform compatibility.
  static Future<void> _migrateToVersion36(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 33: Recreating notes_fts as FTS4',
    );

    try {
      // Drop existing triggers first (they may reference wrong FTS variant)
      await db.execute('DROP TRIGGER IF EXISTS notes_ai_insert');
      await db.execute('DROP TRIGGER IF EXISTS notes_ai_delete');
      await db.execute('DROP TRIGGER IF EXISTS notes_ai_update');

      // Drop existing FTS table (could be FTS4 or FTS5)
      await db.execute('DROP TABLE IF EXISTS notes_fts');

      // Create FTS4 table (universally supported)
      await db.execute('''
        CREATE VIRTUAL TABLE notes_fts USING fts4(
          title, 
          content
        );
      ''');

      // Repopulate notes_fts with existing data
      await db.execute('''
        INSERT INTO notes_fts(docid, title, content)
        SELECT rowid, title, content FROM notes;
      ''');

      // Create triggers for FTS4
      // INSERT Trigger
      await db.execute('''
        CREATE TRIGGER notes_ai_insert AFTER INSERT ON notes
        BEGIN
          INSERT INTO notes_fts(docid, title, content)
          VALUES(new.rowid, new.title, new.content);
        END;
      ''');

      // DELETE Trigger
      await db.execute('''
        CREATE TRIGGER notes_ai_delete AFTER DELETE ON notes
        BEGIN
          DELETE FROM notes_fts WHERE docid = old.rowid;
        END;
      ''');

      // UPDATE Trigger
      await db.execute('''
        CREATE TRIGGER notes_ai_update AFTER UPDATE ON notes
        BEGIN
          DELETE FROM notes_fts WHERE docid = old.rowid;
          INSERT INTO notes_fts(docid, title, content)
          VALUES(new.rowid, new.title, new.content);
        END;
      ''');

      LoggerService.info('Successfully recreated notes_fts table using FTS4');
    } catch (e) {
      LoggerService.error('Error in migration to version 33: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion41(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tag_images (
        tagId TEXT PRIMARY KEY,
        imagePath TEXT NOT NULL,
        FOREIGN KEY (tagId) REFERENCES tags(id) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _migrateToVersion42(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute('ALTER TABLE notes ADD COLUMN metadata TEXT');
  }

  // Migrate existing conversation data to new structure

  // Migration helper method to create initial revisions for existing apps

  // Validate that all note IDs in a conversation exist
  Future<List<String>> validateConversationNotes(String conversationId) async {
    final noteIds = await getConversationNoteIds(conversationId);
    if (noteIds.isEmpty) return [];

    final db = await database;
    // Efficiently check which IDs exist using a simple COUNT query
    final placeholders = List.filled(noteIds.length, '?').join(',');
    final result = await db.rawQuery(
      'SELECT id FROM notes WHERE id IN ($placeholders)',
      noteIds,
    );

    final existingNoteIds = result.map((row) => row['id'] as String).toSet();

    // Find missing note IDs
    final missingNoteIds = noteIds
        .where((noteId) => !existingNoteIds.contains(noteId))
        .toList();

    if (missingNoteIds.isNotEmpty) {
      LoggerService.warning(
        'Conversation $conversationId references missing notes: $missingNoteIds',
      );
    }

    return missingNoteIds;
  }

  // Insert a new note into the database
  Future<String> insertNote(Note note) async {
    final db = await database;
    final json = note.toJson();
    json['createdAt'] = note.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = note.updatedAt.millisecondsSinceEpoch;
    json['pinned'] = note.pinned ? 1 : 0;
    json['isArchived'] = note.isArchived ? 1 : 0;

    // Remove complex objects that can't be stored directly
    json.remove('subNotes');
    json.remove('tags');
    json.remove('attachmentPaths');

    await db.insert('notes', json);

    // Insert subnotes
    for (final subNote in note.subNotes) {
      await insertSubNote(subNote, note.id);
    }

    // Insert tags
    for (final tagName in note.tags) {
      await _linkNoteToTag(note.id, tagName);
    }

    // Insert attachments
    for (final attachmentPath in note.attachmentPaths) {
      // Check if path is relative (starts with 'attachments/')
      bool isRelativePath = attachmentPath.startsWith('attachments/');
      String finalPath = attachmentPath;

      if (!isRelativePath) {
        // Try to convert absolute path to relative if it's in the app dir
        final relativePath = await FileUtils.getRelativePath(attachmentPath);
        if (relativePath != null) {
          finalPath = relativePath;
          isRelativePath = true;
        }
      }

      await _insertAttachment(
        note.id,
        finalPath,
        isRelativePath: isRelativePath,
      );
    }

    return note.id;
  }

  // Get all notes from the database
  Future<List<Note>> getAllNotes() async {
    final db = await database;
    LoggerService.info('Querying notes table...');
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
    SELECT 
      id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived, recurrenceRule,
      CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
      length(content) as _contentLength
    FROM notes
    ORDER BY pinned DESC, createdAt DESC
  ''');
    LoggerService.info('Found ${maps.length} notes in database');

    return await _batchLoadNotes(maps);
  }

  Future<List<Note>> _batchLoadNotes(
    List<Map<String, dynamic>> noteMaps,
  ) async {
    if (noteMaps.isEmpty) return [];

    final db = await database;
    final notes = <Note>[];
    final noteIds = noteMaps.map((m) => m['id'] as String).toList();

    // Batch fetch associated data
    // Chunking to avoid "too many variables" SQLite error (limit is usually 999)
    const chunkSize = 500;
    final Map<String, List<SubNote>> subNotesMap = {};
    final Map<String, List<String>> tagsMap = {};
    final Map<String, List<String>> attachmentsMap = {};

    for (var i = 0; i < noteIds.length; i += chunkSize) {
      final end = (i + chunkSize < noteIds.length)
          ? i + chunkSize
          : noteIds.length;
      final chunkIds = noteIds.sublist(i, end);
      final placeholders = List.filled(chunkIds.length, '?').join(',');

      // Fetch SubNotes
      final subNoteResults = await db.rawQuery('''
      SELECT 
        id, noteId, name, createdAt, isCompleted,
        CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
        length(content) as _contentLength
      FROM subnotes
      WHERE noteId IN ($placeholders)
      ORDER BY createdAt ASC
      ''', chunkIds);

      for (final row in subNoteResults) {
        final noteId = row['noteId'] as String;
        String content = row['content'] as String? ?? '';
        if (content.isEmpty && (row['_contentLength'] as int? ?? 0) > 0) {
          content = await _readLargeString(
            db,
            'subnotes',
            'content',
            row['id'] as String,
          );
        }

        final subNote = SubNote(
          id: row['id'] as String,
          name: row['name'] as String,
          content: content,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['createdAt'] as int,
          ),
          isCompleted: (row['isCompleted'] as int) == 1,
        );

        if (!subNotesMap.containsKey(noteId)) {
          subNotesMap[noteId] = [];
        }
        subNotesMap[noteId]!.add(subNote);
      }

      // Fetch Tags
      final tagResults = await db.rawQuery('''
      SELECT nt.noteId, t.name 
      FROM tags t 
      JOIN note_tags nt ON t.id = nt.tagId 
      WHERE nt.noteId IN ($placeholders)
      ''', chunkIds);

      for (final row in tagResults) {
        final noteId = row['noteId'] as String;
        final tagName = row['name'] as String;

        if (!tagsMap.containsKey(noteId)) {
          tagsMap[noteId] = [];
        }
        tagsMap[noteId]!.add(tagName);
      }

      // Fetch Attachments
      final attachmentResults = await db.query(
        'attachments',
        where: 'noteId IN ($placeholders)',
        whereArgs: chunkIds,
      );

      for (final row in attachmentResults) {
        final noteId = row['noteId'] as String;
        final filePath = row['filePath'] as String;
        final isRelativePath = (row['isRelativePath'] as int) == 1;

        String finalPath;
        if (isRelativePath) {
          finalPath = await FileUtils.getFullFilePath(filePath, true);
        } else {
          finalPath = filePath;
        }

        if (!attachmentsMap.containsKey(noteId)) {
          attachmentsMap[noteId] = [];
        }
        attachmentsMap[noteId]!.add(finalPath);
      }
    }

    // Assemble Notes
    for (final map in noteMaps) {
      try {
        final noteId = map['id'] as String;
        String content = map['content'] as String? ?? '';
        if (content.isEmpty && (map['_contentLength'] as int? ?? 0) > 0) {
          content = await _readLargeString(db, 'notes', 'content', noteId);
        }

        final note = Note(
          id: noteId,
          title: map['title'] as String,
          content: content,
          type: map['type'] != null
              ? NoteType.values.firstWhere(
                  (e) => e.toString().split('.').last == map['type'],
                  orElse: () => NoteType.note,
                )
              : NoteType.note,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            map['createdAt'] as int,
          ),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            map['updatedAt'] as int,
          ),
          subNotes: subNotesMap[noteId] ?? [],
          tags: tagsMap[noteId] ?? [],
          attachmentPaths: attachmentsMap[noteId] ?? [],
          scheduledAt: map['scheduledAt'] as String?,
          completeBy: map['completeBy'] as String?,
          status: map['status'] != null
              ? _stringToTaskStatus(map['status'] as String)
              : null,
          completionPercentage: map['completionPercentage'] as double?,
          pinned: (map['pinned'] as int? ?? 0) == 1,
          isArchived: (map['isArchived'] as int? ?? 0) == 1,
          recurrenceRule: map['recurrenceRule'] as String?,
        );
        notes.add(note);
      } catch (e) {
        LoggerService.error(
          'Error assembling note with id ${map['id']}: $e',
          error: e,
        );
        // Skip corrupted notes
      }
    }

    LoggerService.info('Successfully batch loaded ${notes.length} notes');
    return notes;
  }

  // Clean up invalid note references from conversations
  Future<void> cleanupInvalidNoteReferences() async {
    final allNotes = await getAllNotes();
    final existingNoteIds = allNotes.map((note) => note.id).toSet();

    // Get all conversations
    final conversations = await getAllConversations();

    for (final conversation in conversations) {
      final currentNoteIds = await getConversationNoteIds(conversation.id);
      final validNoteIds = currentNoteIds
          .where((noteId) => existingNoteIds.contains(noteId))
          .toList();

      if (validNoteIds.length != currentNoteIds.length) {
        LoggerService.info(
          'Cleaning up invalid note references for conversation ${conversation.id}',
        );

        // Remove invalid mappings
        final invalidNoteIds = currentNoteIds
            .where((noteId) => !existingNoteIds.contains(noteId))
            .toList();
        for (final invalidNoteId in invalidNoteIds) {
          await deleteConversationNoteMapping(
            conversationId: conversation.id,
            noteId: invalidNoteId,
          );
        }
      }
    }
  }

  Future<List<Note>> getNotesByArchiveStatus({bool? isArchived}) async {
    final db = await database;
    String whereClause = '';
    List<dynamic> whereArgs = [];

    if (isArchived != null) {
      whereClause = 'WHERE isArchived = ?';
      whereArgs.add(isArchived ? 1 : 0);
    }

    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT 
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived,
        CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
        length(content) as _contentLength
      FROM notes
      $whereClause
      ORDER BY pinned DESC, createdAt DESC
      ''', whereArgs);

    return await _batchLoadNotes(maps);
  }

  Future<List<Note>> getPinnedNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT 
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived,
        CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
        length(content) as _contentLength
      FROM notes
      WHERE pinned = 1 AND isArchived = 0
      ORDER BY createdAt DESC
    ''');

    return await _batchLoadNotes(maps);
  }

  Future<List<Note>> getArchivedNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT 
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived,
        CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
        length(content) as _contentLength
      FROM notes
      WHERE isArchived = 1
      ORDER BY createdAt DESC
    ''');

    return await _batchLoadNotes(maps);
  }

  Future<Note?> getNote(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT 
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived, recurrenceRule,
        CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
        length(content) as _contentLength
      FROM notes
      WHERE id = ?
      ''',
      [id],
    );

    if (maps.isEmpty) return null;
    return await _mapToNote(maps.first);
  }

  // Get multiple notes by their IDs efficiently
  Future<List<Note>> getNotesByIds(List<String> noteIds) async {
    if (noteIds.isEmpty) return [];

    final db = await database;
    // Use WHERE IN clause for efficient batch retrieval
    final placeholders = List.filled(noteIds.length, '?').join(',');
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT 
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived, recurrenceRule,
        CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
        length(content) as _contentLength
      FROM notes
      WHERE id IN ($placeholders)
      ''', noteIds);

    return await _batchLoadNotes(maps);
  }

  Future<void> updateNote(Note note) async {
    final db = await database;
    final json = note.toJson();
    json['createdAt'] = note.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = note.updatedAt.millisecondsSinceEpoch;
    json['pinned'] = note.pinned ? 1 : 0;
    json['isArchived'] = note.isArchived ? 1 : 0;

    // Remove complex objects that can't be stored directly
    json.remove('subNotes');
    json.remove('tags');
    json.remove('attachmentPaths');

    await db.update('notes', json, where: 'id = ?', whereArgs: [note.id]);

    // Update subnotes
    await db.delete('subnotes', where: 'noteId = ?', whereArgs: [note.id]);
    for (final subNote in note.subNotes) {
      await insertSubNote(subNote, note.id);
    }

    // Update tags: delete old links and create new ones
    await db.delete('note_tags', where: 'noteId = ?', whereArgs: [note.id]);
    for (final tagName in note.tags) {
      await _linkNoteToTag(note.id, tagName);
    }

    // Update attachments
    // Get existing attachments to preserve IDs and metadata
    final existingAttachmentsRows = await db.query(
      'attachments',
      columns: ['filePath', 'includeInAIContext'],
      where: 'noteId = ?',
      whereArgs: [note.id],
    );

    final existingPaths = <String>{};
    final Map<String, bool> existingContextMap = {};

    for (final row in existingAttachmentsRows) {
      final path = row['filePath'] as String;
      existingPaths.add(path);
      existingContextMap[path] = (row['includeInAIContext'] as int?) != 0;
    }

    final pathsToKeep = <String>{};

    for (final attachmentPath in note.attachmentPaths) {
      // Check if path is relative (starts with 'attachments/')
      bool isRelativePath = attachmentPath.startsWith('attachments/');
      String finalPath = attachmentPath;

      if (!isRelativePath) {
        // Try to convert absolute path to relative if it's in the app dir
        final relativePath = await FileUtils.getRelativePath(attachmentPath);
        if (relativePath != null) {
          finalPath = relativePath;
          isRelativePath = true;
        }
      }

      if (existingPaths.contains(finalPath)) {
        // Attachment exists, keep it
        pathsToKeep.add(finalPath);
      } else {
        // New attachment, insert it
        // Preserve includeInAIContext if it existed in some form (robustness), otherwise default to true
        final includeInAIContext =
            existingContextMap[finalPath] ??
            existingContextMap[attachmentPath] ??
            true;

        await _insertAttachment(
          note.id,
          finalPath,
          isRelativePath: isRelativePath,
          includeInAIContext: includeInAIContext,
        );
      }
    }

    // Delete attachments that are no longer in the note
    // We do this by checking which existing paths were NOT in the new list
    for (final existingPath in existingPaths) {
      if (!pathsToKeep.contains(existingPath)) {
        await db.delete(
          'attachments',
          where: 'noteId = ? AND filePath = ?',
          whereArgs: [note.id, existingPath],
        );
      }
    }
  }

  /// Updates the includeInAIContext flag for a specific attachment
  Future<void> updateAttachmentAIContext(
    String noteId,
    String filePath,
    bool include,
  ) async {
    final db = await database;
    await db.update(
      'attachments',
      {'includeInAIContext': include ? 1 : 0},
      where: 'noteId = ? AND filePath = ?',
      whereArgs: [noteId, filePath],
    );
  }

  /// Updates the metadata JSON for a specific attachment
  Future<void> updateAttachmentMetadata(
    String attachmentId,
    Map<String, dynamic>? metadata,
  ) async {
    final db = await database;
    await db.update(
      'attachments',
      {'metadata': metadata != null ? jsonEncode(metadata) : null},
      where: 'id = ?',
      whereArgs: [attachmentId],
    );
  }

  /// Updates the metadata JSON for a specific note
  Future<void> updateNoteMetadata(
    String noteId,
    Map<String, dynamic>? metadata,
  ) async {
    final db = await database;
    await db.update(
      'notes',
      {'metadata': metadata != null ? jsonEncode(metadata) : null},
      where: 'id = ?',
      whereArgs: [noteId],
    );
  }

  /// Gets the metadata JSON for a specific note
  Future<Map<String, dynamic>?> getNoteMetadata(String noteId) async {
    final db = await database;
    final rows = await db.query(
      'notes',
      columns: ['metadata'],
      where: 'id = ?',
      whereArgs: [noteId],
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['metadata'] as String?;
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ── NoteAnnotation CRUD ─────────────────────────────────────────────────

  Future<void> saveNoteAnnotation(NoteAnnotation annotation) async {
    final db = await database;
    await db.insert(
      'note_annotations',
      annotation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<NoteAnnotation?> getNoteAnnotation(String id) async {
    final db = await database;
    final rows = await db.query(
      'note_annotations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return NoteAnnotation.fromMap(rows.first);
  }

  Future<List<NoteAnnotation>> getNoteAnnotationsForNote(String noteId) async {
    final db = await database;
    final rows = await db.query(
      'note_annotations',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'created_at DESC',
    );
    return rows.map(NoteAnnotation.fromMap).toList();
  }

  Future<List<NoteAnnotation>> getNoteAnnotationsForAttachment(
    String attachmentId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'note_annotations',
      where: 'attachment_id = ?',
      whereArgs: [attachmentId],
      orderBy: 'created_at DESC',
    );
    return rows.map(NoteAnnotation.fromMap).toList();
  }

  Future<void> deleteNoteAnnotation(String id) async {
    final db = await database;
    await db.delete('note_annotations', where: 'id = ?', whereArgs: [id]);
  }

  // ────────────────────────────────────────────────────────────────────────

  /// Updates just the lastViewedPage in attachment metadata
  /// Preserves other metadata fields
  Future<void> updateLastViewedPage(String attachmentId, int pageNumber) async {
    try {
      // Ensure metadata column exists
      final db = await database;
      final tableInfo = await db.rawQuery('PRAGMA table_info(attachments)');
      final hasColumn = tableInfo.any((column) => column['name'] == 'metadata');
      if (!hasColumn) {
        LoggerService.warning(
          'metadata column missing from attachments table - applying migration',
        );
        await db.execute('ALTER TABLE attachments ADD COLUMN metadata TEXT');
      }

      final attachment = await getAttachmentById(attachmentId);
      if (attachment == null) return;

      final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
      metadata['lastViewedPage'] = pageNumber;

      await updateAttachmentMetadata(attachmentId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to update last viewed page: $e');
    }
  }

  /// Gets an attachment by its ID
  Future<Attachment?> getAttachmentById(String attachmentId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'id = ?',
      whereArgs: [attachmentId],
    );
    if (maps.isEmpty) return null;
    return Attachment.fromDatabase(maps.first);
  }

  /// Gets all attachments for a specific note
  Future<List<Attachment>> getAttachmentsForNote(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'noteId = ?',
      whereArgs: [noteId],
    );

    return List.generate(maps.length, (i) {
      return Attachment.fromDatabase(maps[i]);
    });
  }

  Future<void> deleteNote(String id) async {
    final db = await database;
    // Delete note-conversation mappings first (foreign key constraints will handle cascade deletion)
    await deleteNoteConversationMappings(id);
    // CASCADE will handle note_tags deletion automatically
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  // SubNotes CRUD
  Future<String> insertSubNote(SubNote subNote, String noteId) async {
    final db = await database;
    final json = subNote.toJson();
    json['noteId'] = noteId;
    json['createdAt'] = subNote.createdAt.millisecondsSinceEpoch;
    json['isCompleted'] = subNote.isCompleted ? 1 : 0;
    await db.insert('subnotes', json);
    return subNote.id;
  }

  Future<List<SubNote>> getSubNotes(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT 
        id, noteId, name, createdAt, isCompleted,
        CASE WHEN length(content) < 500000 THEN content ELSE NULL END as content,
        length(content) as _contentLength
      FROM subnotes
      WHERE noteId = ?
      ORDER BY createdAt ASC
      ''',
      [noteId],
    );

    final List<SubNote> subNotes = [];
    for (final map in maps) {
      String content = map['content'] as String? ?? '';
      if (content.isEmpty && (map['_contentLength'] as int? ?? 0) > 0) {
        content = await _readLargeString(
          db,
          'subnotes',
          'content',
          map['id'] as String,
        );
      }

      subNotes.add(
        SubNote(
          id: map['id'],
          name: map['name'],
          content: content,
          createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt']),
          isCompleted: map['isCompleted'] == 1,
        ),
      );
    }
    return subNotes;
  }

  // Tags CRUD
  Future<String> insertTag(Tag tag) async {
    final db = await database;
    final json = tag.toJson();
    json['createdAt'] = tag.createdAt.millisecondsSinceEpoch;
    json.remove('conversationUsageCount');
    await db.insert('tags', json);
    return tag.id;
  }

  Future<List<Tag>> getAllTags() async {
    final db = await database;
    // Use GROUP BY to calculate usage count on the fly, sorted alphabetically
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT 
        t.id,
        t.name,
        t.color,
        t.createdAt,
        COALESCE(COUNT(DISTINCT nt.noteId), 0) as noteUsageCount,
        COALESCE(COUNT(DISTINCT ct.conversationId), 0) as conversationUsageCount
      FROM tags t
      LEFT JOIN note_tags nt ON t.id = nt.tagId
      LEFT JOIN conversation_tags ct ON t.id = ct.tagId
      GROUP BY t.id, t.name, t.color, t.createdAt
      ORDER BY t.name ASC
    ''');

    return List.generate(maps.length, (i) {
      return Tag(
        id: maps[i]['id'],
        name: maps[i]['name'],
        color: maps[i]['color'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
        usageCount: (maps[i]['noteUsageCount'] as num?)?.toInt() ?? 0,
        conversationUsageCount:
            (maps[i]['conversationUsageCount'] as num?)?.toInt() ?? 0,
      );
    });
  }

  Future<void> deleteTag(String tagName) async {
    final db = await database;

    // First, get the tag ID
    final tagMaps = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [tagName],
    );

    if (tagMaps.isEmpty) return; // Tag doesn't exist

    final tagId = tagMaps.first['id'] as String;

    // Delete all note-tag relationships for this tag
    await db.delete('note_tags', where: 'tagId = ?', whereArgs: [tagId]);
    await db.delete(
      'conversation_tags',
      where: 'tagId = ?',
      whereArgs: [tagId],
    );

    // Delete the tag itself
    await db.delete('tags', where: 'id = ?', whereArgs: [tagId]);
  }

  /// Set or update the image for a tag.
  Future<void> setTagImage(String tagId, String imagePath) async {
    final db = await database;
    await db.insert('tag_images', {
      'tagId': tagId,
      'imagePath': imagePath,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Remove the image for a tag.
  Future<void> removeTagImage(String tagId) async {
    final db = await database;
    await db.delete('tag_images', where: 'tagId = ?', whereArgs: [tagId]);
  }

  /// Get all tag images as a map of tagId -> imagePath.
  Future<Map<String, String>> getAllTagImages() async {
    final db = await database;
    final rows = await db.query('tag_images');
    return {
      for (final row in rows)
        row['tagId'] as String: row['imagePath'] as String,
    };
  }

  /// Get the image path for a specific tag.
  Future<String?> getTagImage(String tagId) async {
    final db = await database;
    final rows = await db.query(
      'tag_images',
      where: 'tagId = ?',
      whereArgs: [tagId],
    );
    if (rows.isEmpty) return null;
    return rows.first['imagePath'] as String;
  }

  Future<void> replaceTag(String oldTagName, String newTagName) async {
    final db = await database;

    // Get the old tag ID
    final oldTagMaps = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [oldTagName],
    );

    if (oldTagMaps.isEmpty) return; // Old tag doesn't exist

    final oldTagId = oldTagMaps.first['id'] as String;

    // Check if new tag already exists
    final newTagMaps = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [newTagName],
    );

    String newTagId;
    if (newTagMaps.isEmpty) {
      // Create new tag preserving original color when available
      final newTag = Tag(
        id: _uuid.v4(),
        name: newTagName,
        color: oldTagMaps.first['color'] as String,
        createdAt: DateTime.now(),
      );
      final json = newTag.toJson();
      json['createdAt'] = newTag.createdAt.millisecondsSinceEpoch;
      json.remove('conversationUsageCount');
      await db.insert('tags', json);
      newTagId = newTag.id;
    } else {
      newTagId = newTagMaps.first['id'] as String;
    }

    // Get all notes that have the old tag
    final noteTagMaps = await db.query(
      'note_tags',
      where: 'tagId = ?',
      whereArgs: [oldTagId],
    );

    // For each note, add the new tag if it doesn't already exist
    // For each note, add the new tag if it doesn't already exist
    for (final noteTagMap in noteTagMaps) {
      final noteId = noteTagMap['noteId'] as String;

      // Verify note exists to avoid Foreign Key violations (orphaned tags)
      final noteExists = await db.query(
        'notes',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [noteId],
        limit: 1,
      );

      if (noteExists.isEmpty) {
        // Cleanup orphan
        LoggerService.warning(
          'Found orphaned note_tag for noteId: $noteId. Cleaning up.',
        );
        await db.delete('note_tags', where: 'noteId = ?', whereArgs: [noteId]);
        continue;
      }

      // Check if this note already has the new tag
      final existingNewTag = await db.query(
        'note_tags',
        where: 'noteId = ? AND tagId = ?',
        whereArgs: [noteId, newTagId],
      );

      // Only insert if the note doesn't already have the new tag
      if (existingNewTag.isEmpty) {
        await db.insert('note_tags', {
          'noteId': noteId,
          'tagId': newTagId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }

    // Update conversation tag relationships
    final conversationTagMaps = await db.query(
      'conversation_tags',
      where: 'tagId = ?',
      whereArgs: [oldTagId],
    );

    final now = DateTime.now().millisecondsSinceEpoch;

    for (final conversationTagMap in conversationTagMaps) {
      final conversationId = conversationTagMap['conversationId'] as String;

      final existingNewConversationTag = await db.query(
        'conversation_tags',
        where: 'conversationId = ? AND tagId = ?',
        whereArgs: [conversationId, newTagId],
      );

      if (existingNewConversationTag.isEmpty) {
        await db.insert('conversation_tags', {
          'conversationId': conversationId,
          'tagId': newTagId,
        });
      }

      await db.update(
        'conversations',
        {'updatedAt': now},
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    }

    // Delete all old tag relationships
    await db.delete('note_tags', where: 'tagId = ?', whereArgs: [oldTagId]);
    await db.delete(
      'conversation_tags',
      where: 'tagId = ?',
      whereArgs: [oldTagId],
    );

    // Delete the old tag
    await db.delete('tags', where: 'id = ?', whereArgs: [oldTagId]);
  }

  // Relationships CRUD
  Future<String> insertRelationship(Relationship relationship) async {
    final db = await database;
    final json = relationship.toJson();
    json['createdAt'] = relationship.createdAt.millisecondsSinceEpoch;
    await db.insert('relationships', json);
    return relationship.id;
  }

  Future<List<Relationship>> getRelationships(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'fromNoteId = ? OR toNoteId = ?',
      whereArgs: [noteId, noteId],
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      return Relationship(
        id: maps[i]['id'],
        fromNoteId: maps[i]['fromNoteId'],
        toNoteId: maps[i]['toNoteId'],
        type: maps[i]['type'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
      );
    });
  }

  Future<List<Relationship>> getOutgoingRelationships(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'fromNoteId = ?',
      whereArgs: [noteId],
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      return Relationship(
        id: maps[i]['id'],
        fromNoteId: maps[i]['fromNoteId'],
        toNoteId: maps[i]['toNoteId'],
        type: maps[i]['type'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
      );
    });
  }

  Future<List<Relationship>> getIncomingRelationships(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'toNoteId = ?',
      whereArgs: [noteId],
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      return Relationship(
        id: maps[i]['id'],
        fromNoteId: maps[i]['fromNoteId'],
        toNoteId: maps[i]['toNoteId'],
        type: maps[i]['type'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
      );
    });
  }

  Future<void> deleteRelationship(String relationshipId) async {
    final db = await database;
    await db.delete(
      'relationships',
      where: 'id = ?',
      whereArgs: [relationshipId],
    );
  }

  Future<void> deleteRelationshipsForNote(String noteId) async {
    final db = await database;
    await db.delete(
      'relationships',
      where: 'fromNoteId = ? OR toNoteId = ?',
      whereArgs: [noteId, noteId],
    );
  }

  Future<bool> relationshipExists(
    String fromNoteId,
    String toNoteId,
    String type,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'fromNoteId = ? AND toNoteId = ? AND type = ?',
      whereArgs: [fromNoteId, toNoteId, type],
    );
    return maps.isNotEmpty;
  }

  // Helper methods
  DateTime _validateTimestamp(
    dynamic timestamp,
    String fieldName,
    String recordId,
  ) {
    if (timestamp is int) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else if (timestamp is String) {
      // This indicates a schema violation - string timestamps should not exist
      LoggerService.error(
        'Database schema violation: $fieldName field contains string timestamp in record $recordId',
        error: 'Expected integer timestamp, got string: $timestamp',
      );
      throw FormatException(
        'Database schema violation: $fieldName field should contain integer timestamp, but contains string: $timestamp',
      );
    } else {
      LoggerService.error(
        'Database schema violation: $fieldName field has invalid type in record $recordId',
        error:
            'Expected integer timestamp, got ${timestamp.runtimeType}: $timestamp',
      );
      throw FormatException(
        'Database schema violation: $fieldName field should contain integer timestamp, but got ${timestamp.runtimeType}: $timestamp',
      );
    }
  }

  Future<Note> _mapToNote(Map<String, dynamic> map) async {
    final subNotes = await getSubNotes(map['id']);
    final tags = await _getNoteTags(map['id']);
    final attachments = await _getNoteAttachments(map['id']);

    String content = map['content'] as String? ?? '';
    if (content.isEmpty && (map['_contentLength'] as int? ?? 0) > 0) {
      // Content was too large and skipped in initial query, fetch it now in chunks
      final db = await database;
      content = await _readLargeString(
        db,
        'notes',
        'content',
        map['id'] as String,
      );
    }

    return Note(
      id: map['id'],
      title: map['title'],
      content: content,
      type: NoteType.values.firstWhere(
        (e) => e.toString().split('.').last == map['type'],
        orElse: () => NoteType.note,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt']),
      subNotes: subNotes,
      tags: tags,
      attachmentPaths: attachments,
      scheduledAt: map['scheduledAt'],
      completeBy: map['completeBy'],
      status: map['status'] != null ? _stringToTaskStatus(map['status']) : null,
      completionPercentage: map['completionPercentage'],
      pinned: (map['pinned'] ?? 0) == 1,
      isArchived: (map['isArchived'] ?? 0) == 1,
      recurrenceRule: map['recurrenceRule'],
    );
  }

  Future<List<String>> _getNoteTags(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT t.name 
      FROM tags t 
      JOIN note_tags nt ON t.id = nt.tagId 
      WHERE nt.noteId = ?
    ''',
      [noteId],
    );

    return maps.map((map) => map['name'] as String).toList();
  }

  Future<List<String>> _getNoteAttachments(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'noteId = ?',
      whereArgs: [noteId],
    );

    final List<String> attachmentPaths = [];
    for (final map in maps) {
      final filePath = map['filePath'] as String;
      final isRelativePath = (map['isRelativePath'] as int) == 1;

      if (isRelativePath) {
        // Convert relative path to full path for backward compatibility
        final fullPath = await FileUtils.getFullFilePath(filePath, true);
        attachmentPaths.add(fullPath);
      } else {
        // Legacy absolute path
        attachmentPaths.add(filePath);
      }
    }

    return attachmentPaths;
  }

  // Verify if an attachment path belongs to any note
  Future<bool> verifyAttachmentPath(String attachmentPath) async {
    final db = await database;

    // Check if the path is absolute (starts with /) or relative
    final isAbsolutePath = attachmentPath.startsWith('/');

    if (isAbsolutePath) {
      // Case 1: Absolute path - try both relative and absolute variants
      // 1a) Try relative path variant (like existing behavior)
      final fileName = attachmentPath.split('/').last;
      final relativePath = 'attachments/$fileName';

      final List<Map<String, dynamic>> rel = await db.query(
        'attachments',
        where: 'filePath = ?',
        whereArgs: [relativePath],
      );
      if (rel.isNotEmpty) return true;

      // 1b) Try absolute path as-is with isRelativePath = 0
      final List<Map<String, dynamic>> abs = await db.query(
        'attachments',
        where: 'filePath = ? AND isRelativePath = 0',
        whereArgs: [attachmentPath],
      );
      return abs.isNotEmpty;
    } else {
      // Path is already relative, search directly
      final List<Map<String, dynamic>> maps = await db.query(
        'attachments',
        where: 'filePath = ?',
        whereArgs: [attachmentPath],
      );

      return maps.isNotEmpty;
    }
  }

  // Get the note ID for a given attachment path
  Future<String?> getNoteIdForAttachment(String attachmentPath) async {
    final db = await database;

    // Check if the path is absolute (starts with /) or relative
    final isAbsolutePath = attachmentPath.startsWith('/');

    String searchPath;
    if (isAbsolutePath) {
      // Convert absolute path to relative path for database lookup
      final fileName = attachmentPath.split('/').last;
      searchPath = 'attachments/$fileName';
    } else {
      // Path is already relative, use as is
      searchPath = attachmentPath;
    }

    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'filePath = ?',
      whereArgs: [searchPath],
    );

    return maps.isNotEmpty ? maps.first['noteId'] as String? : null;
  }

  Future<String> _getOrCreateTagId(Database db, String tagName) async {
    final existingTag = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [tagName],
      limit: 1,
    );

    if (existingTag.isNotEmpty) {
      return existingTag.first['id'] as String;
    }

    final now = DateTime.now();
    final tagId = _uuid.v4();
    await db.insert('tags', {
      'id': tagId,
      'name': tagName,
      'color': '#2196F3',
      'createdAt': now.millisecondsSinceEpoch,
      'usageCount': 0,
    });
    return tagId;
  }

  Future<void> _linkNoteToTag(String noteId, String tagName) async {
    final db = await database;
    final tagId = await _getOrCreateTagId(db, tagName);

    // Link note to tag (only if not already linked)
    final existingLink = await db.query(
      'note_tags',
      where: 'noteId = ? AND tagId = ?',
      whereArgs: [noteId, tagId],
    );

    if (existingLink.isEmpty) {
      await db.insert('note_tags', {
        'noteId': noteId,
        'tagId': tagId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _insertAttachment(
    String noteId,
    String filePath, {
    bool isRelativePath = false,
    bool includeInAIContext = true,
  }) async {
    final db = await database;
    final fileName = filePath.split('/').last;
    final fileType = FileTypeUtils.getFileExtension(fileName);
    final uuid = Uuid();

    // Default HTML files to be excluded from AI context to save tokens
    final isHtml =
        fileType.toLowerCase() == 'html' || fileType.toLowerCase() == 'htm';
    final finalIncludeInAIContext = isHtml ? false : includeInAIContext;

    await db.insert('attachments', {
      'id': uuid.v4(),
      'noteId': noteId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
      'isRelativePath': isRelativePath ? 1 : 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': finalIncludeInAIContext ? 1 : 0,
    });
  }

  // Get all attachments from database
  Future<List<Map<String, dynamic>>> getAllAttachments() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('attachments');
    return maps;
  }

  // Get database path
  Future<String> getDatabasePath() async {
    final dbName = _databaseNameOverride ?? 'note_synapse.db';
    return p.join(await getDatabasesPath(), dbName);
  }

  // Force database checkpoint
  Future<void> checkpoint() async {
    final db = await database;
    await db.rawQuery('PRAGMA wal_checkpoint(FULL);');
  }

  // Migrate a backup database to current version
  Future<void> migrateBackupDatabase(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    LoggerService.info(
      'Migrating backup database from version $oldVersion to $newVersion',
    );

    // Inline migration execution for backup databases (no RecoveryScreen navigation)
    for (int version = oldVersion + 1; version <= newVersion; version++) {
      final migrationStep = _migrationSteps[version];
      if (migrationStep == null) {
        LoggerService.warning('No migration step defined for version $version');
        continue;
      }

      try {
        LoggerService.info(
          'Executing backup migration to version $version: ${migrationStep.description}',
        );
        await migrationStep.execute(db, isBackupMigration: true);
        LoggerService.info('Successfully migrated backup to version $version');
      } catch (e) {
        LoggerService.error(
          'Backup migration to version $version failed: $e',
          error: e,
        );
        break; // Stop on error
      }
    }
  }

  // Clear all data
  Future<void> clearAllData() async {
    final db = await database;

    // Delete all data from all tables
    await db.delete('relationships');
    await db.delete('attachments');
    await db.delete('note_tags');
    await db.delete('subnotes');
    await db.delete('notes');
    await db.delete('tags');
    await db.delete('filters');

    await db.delete('conversation_messages');
    await db.delete('conversation_attachments');
    await db.delete('conversation_message_mapping');
    await db.delete('conversation_note_mapping');
    await db.delete('conversation_tags');
    await db.delete('message_parents');
    await db.delete('conversations');
  }

  // Utility methods
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }

  // Helper method to convert string to TaskStatus
  TaskStatus _stringToTaskStatus(String statusString) {
    switch (statusString) {
      case 'abandoned':
        return TaskStatus.abandoned;
      case 'complete':
        return TaskStatus.complete;
      case 'in_progress':
        return TaskStatus.inProgress;
      case 'todo':
        return TaskStatus.todo;
      default:
        return TaskStatus.todo;
    }
  }

  // Filters CRUD
  Future<String> insertFilter(Filter filter) async {
    final db = await database;

    // Build the map directly for database insertion
    final json = {
      'id': filter.id,
      'name': filter.name,
      'includeText': filter.includeText,
      'includeTags': filter.includeTags.join(','),
      'excludeTags': filter.excludeTags.join(','),
      'noteTypes': filter.noteTypes
          .map((t) => t.toString().split('.').last)
          .join(','),
      'includeArchived': filter.includeArchived ? 1 : 0,
      'isPinned': filter.isPinned ? 1 : 0,
      'createdAt': filter.createdAt.millisecondsSinceEpoch,
      'updatedAt': filter.updatedAt.millisecondsSinceEpoch,
    };

    await db.insert('filters', json);
    return filter.id;
  }

  Future<List<Filter>> getAllFilters() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'filters',
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      final includeTagsString = maps[i]['includeTags'] as String? ?? '';
      final includeTags = includeTagsString.isEmpty
          ? <String>[]
          : includeTagsString.split(',');

      final excludeTagsString = maps[i]['excludeTags'] as String? ?? '';
      final excludeTags = excludeTagsString.isEmpty
          ? <String>[]
          : excludeTagsString.split(',');

      final noteTypesString = maps[i]['noteTypes'] as String? ?? '';
      final noteTypes = noteTypesString.isEmpty
          ? NoteType
                .values // Default to all types if empty (backward compatibility)
          : noteTypesString.split(',').map((e) {
              return NoteType.values.firstWhere(
                (type) => type.toString().split('.').last == e,
                orElse: () => NoteType.note,
              );
            }).toList();

      return Filter(
        id: maps[i]['id'],
        name: maps[i]['name'],
        includeText: maps[i]['includeText'],
        includeTags: includeTags,
        excludeTags: excludeTags,
        noteTypes: noteTypes,
        includeArchived: (maps[i]['includeArchived'] ?? 0) == 1,
        isPinned: (maps[i]['isPinned'] ?? 0) == 1,
        createdAt: _validateTimestamp(
          maps[i]['createdAt'],
          'createdAt',
          maps[i]['id'],
        ),
        updatedAt: _validateTimestamp(
          maps[i]['updatedAt'],
          'updatedAt',
          maps[i]['id'],
        ),
      );
    });
  }

  Future<Filter?> getFilter(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'filters',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;

    final map = maps.first;
    final includeTagsString = map['includeTags'] as String? ?? '';
    final includeTags = includeTagsString.isEmpty
        ? <String>[]
        : includeTagsString.split(',');

    final excludeTagsString = map['excludeTags'] as String? ?? '';
    final excludeTags = excludeTagsString.isEmpty
        ? <String>[]
        : excludeTagsString.split(',');

    final noteTypesString = map['noteTypes'] as String? ?? '';
    final noteTypes = noteTypesString.isEmpty
        ? NoteType
              .values // Default to all types
        : noteTypesString.split(',').map((e) {
            return NoteType.values.firstWhere(
              (type) => type.toString().split('.').last == e,
              orElse: () => NoteType.note,
            );
          }).toList();

    return Filter(
      id: map['id'],
      name: map['name'],
      includeText: map['includeText'],
      includeTags: includeTags,
      excludeTags: excludeTags,
      noteTypes: noteTypes,
      includeArchived: (map['includeArchived'] ?? 0) == 1,
      isPinned: (map['isPinned'] ?? 0) == 1,
      createdAt: _validateTimestamp(map['createdAt'], 'createdAt', map['id']),
      updatedAt: _validateTimestamp(map['updatedAt'], 'updatedAt', map['id']),
    );
  }

  Future<void> updateFilter(Filter filter) async {
    final db = await database;

    // Build the map directly for database update
    final json = {
      'id': filter.id,
      'name': filter.name,
      'includeText': filter.includeText,
      'includeTags': filter.includeTags.join(','),
      'excludeTags': filter.excludeTags.join(','),
      'noteTypes': filter.noteTypes
          .map((t) => t.toString().split('.').last)
          .join(','),
      'includeArchived': filter.includeArchived ? 1 : 0,
      'isPinned': filter.isPinned ? 1 : 0,
      'createdAt': filter.createdAt.millisecondsSinceEpoch,
      'updatedAt': filter.updatedAt.millisecondsSinceEpoch,
    };

    await db.update('filters', json, where: 'id = ?', whereArgs: [filter.id]);
  }

  Future<void> deleteFilter(String id) async {
    final db = await database;
    await db.delete('filters', where: 'id = ?', whereArgs: [id]);
  }

  // Execute raw SQL query for user apps
  Future<List<Map<String, dynamic>>> executeRawQuery(String sql) async {
    final db = await database;
    try {
      final trimmedSql = sql.trim().toLowerCase();

      // Execute the query
      final result = await db.rawQuery(sql);
      return result;
    } catch (e) {
      throw Exception('SQL query execution failed: $e');
    }
  }

  // User Apps CRUD
  Future<String> insertUserApp(UserApp app) async {
    final db = await database;
    // Build JSON manually to avoid conflicts with toJson() DateTime serialization
    final json = {
      'id': app.id,
      'uuid': app.uuid,
      'name': app.name,
      'description': app.description,
      'steps': app.steps.join('|'), // Store steps as pipe-separated string
      'htmlContent': app.htmlContent,
      'appState': app.appState != null ? jsonEncode(app.appState) : null,
      'type': app.type.toString().split('.').last, // Store enum as string
      'selectedRevisionId': app.selectedRevisionId,
      'author': app.author,
      'license': app.license,
      'createdAt': app.createdAt.millisecondsSinceEpoch,
      'updatedAt': app.updatedAt.millisecondsSinceEpoch,
    };

    LoggerService.debug(
      'DatabaseService.insertUserApp: Inserting app ${app.id} - ${app.name}',
    );
    await db.insert('user_apps', json);
    LoggerService.debug(
      'DatabaseService.insertUserApp: Successfully inserted app ${app.id}',
    );
    return app.id;
  }

  Future<List<UserApp>> getAllUserApps() async {
    final db = await database;
    // Exclude appState to avoid CursorWindow issues with large state data.
    // App state should be loaded on-demand via getUserAppState().
    final maps = await db.rawQuery('''
      SELECT id, uuid, name, description, steps, htmlContent, type, 
             selectedRevisionId, author, license, createdAt, updatedAt
      FROM user_apps
      ORDER BY createdAt DESC
    ''');
    LoggerService.debug(
      'DatabaseService.getAllUserApps: Found ${maps.length} user apps',
    );
    return maps.map((map) => _userAppFromMap(map)).toList();
  }

  Future<UserApp?> getUserApp(String id) async {
    final db = await database;
    // Explicitly select columns excluding appState to avoid CursorWindow size limits
    final maps = await db.rawQuery(
      '''
      SELECT id, uuid, name, description, steps, htmlContent, type, 
             selectedRevisionId, author, license, createdAt, updatedAt
      FROM user_apps
      WHERE id = ?
    ''',
      [id],
    );

    if (maps.isNotEmpty) {
      return _userAppFromMap(maps.first);
    }
    return null;
  }

  Future<void> updateUserApp(UserApp app) async {
    final db = await database;
    // Build JSON manually to avoid conflicts with toJson() DateTime serialization
    final json = {
      'id': app.id,
      'uuid': app.uuid,
      'name': app.name,
      'description': app.description,
      'steps': app.steps.join('|'), // Store steps as pipe-separated string
      'htmlContent': app.htmlContent,
      'type': app.type.toString().split('.').last, // Store enum as string
      'selectedRevisionId': app.selectedRevisionId,
      'author': app.author,
      'license': app.license,
      'createdAt': app.createdAt.millisecondsSinceEpoch,
      'updatedAt': app.updatedAt.millisecondsSinceEpoch,
    };

    if (app.appState != null) {
      json['appState'] = jsonEncode(app.appState);
    }

    await db.update('user_apps', json, where: 'id = ?', whereArgs: [app.id]);
  }

  Future<void> deleteUserApp(String id) async {
    final db = await database;

    // Get the app to find its UUID for library deletion
    final app = await getUserApp(id);
    if (app == null) return;

    // Delete app libraries and their dependencies first
    // (foreign key constraints will handle cascade deletion)
    await db.delete(
      'user_app_libraries',
      where: 'app_uuid = ?',
      whereArgs: [app.uuid],
    );

    // Delete app revisions (this will also delete any remaining libraries via foreign key)
    await db.delete('app_revisions', where: 'appId = ?', whereArgs: [id]);

    // Finally delete the app
    await db.delete('user_apps', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateUserAppState(String id, Map<String, dynamic> state) async {
    final db = await database;
    await db.update(
      'user_apps',
      {
        'appState': jsonEncode(state),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, dynamic>?> getUserAppState(String id) async {
    final db = await database;

    // Use raw query with chunked TEXT reading to avoid cursor window issues
    final results = await db.rawQuery(
      '''
      SELECT id,
             CASE 
               WHEN length(appState) > 0 THEN 'TEXT_DATA'
               ELSE NULL 
             END as has_text
      FROM user_apps 
      WHERE id = ?
    ''',
      [id],
    );

    if (results.isEmpty || results.first['has_text'] == null) {
      return null;
    }

    // Read TEXT data in chunks to avoid cursor window issues
    try {
      final textData = await _readLargeString(db, 'user_apps', 'appState', id);
      if (textData.isEmpty) {
        return null;
      }
      return jsonDecode(textData) as Map<String, dynamic>;
    } catch (e) {
      LoggerService.error('Failed to read appState for app $id: $e', error: e);
      return null;
    }
  }

  UserApp _userAppFromMap(Map<String, dynamic> map) {
    // Handle both int and string timestamps for backward compatibility
    DateTime parseTimestamp(dynamic timestamp) {
      if (timestamp is int) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp);
      } else if (timestamp is String) {
        return DateTime.parse(timestamp);
      } else {
        throw Exception('Invalid timestamp format: $timestamp');
      }
    }

    return UserApp(
      id: map['id'] as String,
      uuid:
          map['uuid'] as String? ??
          const Uuid()
              .v4(), // Generate UUID if missing for backward compatibility
      name: map['name'] as String,
      description: map['description'] as String,
      steps: (map['steps'] as String).split('|'), // Parse pipe-separated steps
      htmlContent: map['htmlContent'] as String,
      appState: map['appState'] != null
          ? jsonDecode(map['appState'] as String) as Map<String, dynamic>
          : null,
      type: map['type'] != null
          ? UserAppType.values.firstWhere(
              (e) => e.toString().split('.').last == map['type'],
              orElse: () => UserAppType.normal,
            )
          : UserAppType.normal,
      selectedRevisionId: map['selectedRevisionId'] as String?,
      author: map['author'] as String? ?? '',
      license: map['license'] as String? ?? '',
      createdAt: parseTimestamp(map['createdAt']),
      updatedAt: parseTimestamp(map['updatedAt']),
    );
  }

  // App Revisions CRUD
  Future<String> insertAppRevision(AppRevision revision) async {
    final db = await database;
    final json = {
      'id': revision.id,
      'appId': revision.appId,
      'revisionNumber': revision.revisionNumber,
      'revisionTimestamp': revision.revisionTimestamp.millisecondsSinceEpoch,
      'userPrompt': revision.userPrompt,
      'aiResponse': revision.aiResponse,
      'appCode': revision.appCode,
      'attachmentPaths': revision.attachmentPaths.join(
        '|',
      ), // Store attachment paths as pipe-separated string
    };

    LoggerService.debug(
      'DatabaseService.insertAppRevision: Inserting revision ${revision.id} for app ${revision.appId}',
    );
    await db.insert('app_revisions', json);
    LoggerService.debug(
      'DatabaseService.insertAppRevision: Successfully inserted revision ${revision.id}',
    );
    return revision.id;
  }

  Future<List<AppRevision>> getAppRevisions(String appId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT 
        id, appId, revisionNumber, revisionTimestamp, userPrompt, aiResponse, attachmentPaths,
        CASE WHEN length(appCode) < 500000 THEN appCode ELSE NULL END as appCode,
        length(appCode) as _appCodeLength
      FROM app_revisions
      WHERE appId = ?
      ORDER BY revisionNumber ASC
      ''',
      [appId],
    );
    LoggerService.debug(
      'DatabaseService.getAppRevisions: Found ${maps.length} revisions for app $appId',
    );
    if (maps.isNotEmpty) {
      LoggerService.debug('First revision data: ${maps.first}');
    }

    final List<AppRevision> revisions = [];
    for (final map in maps) {
      revisions.add(await _appRevisionFromMap(map));
    }

    if (revisions.isNotEmpty) {
      LoggerService.debug(
        'First revision appCode length: ${revisions.first.appCode.length}',
      );
    }
    return revisions;
  }

  Future<AppRevision?> getAppRevision(String id) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT 
        id, appId, revisionNumber, revisionTimestamp, userPrompt, aiResponse, attachmentPaths,
        CASE WHEN length(appCode) < 500000 THEN appCode ELSE NULL END as appCode,
        length(appCode) as _appCodeLength
      FROM app_revisions
      WHERE id = ?
      ''',
      [id],
    );
    if (maps.isNotEmpty) {
      return await _appRevisionFromMap(maps.first);
    }
    return null;
  }

  Future<void> deleteAppRevision(String id) async {
    final db = await database;

    // Get the revision to find its appId and revision number
    final revision = await getAppRevision(id);
    if (revision == null) return;

    // Get all revisions for this app to check if this is the only one
    final allRevisions = await getAppRevisions(revision.appId);
    if (allRevisions.length <= 1) {
      throw Exception(
        'Cannot delete the only remaining revision. At least one revision must exist.',
      );
    }

    // Get the app to check if this is the pinned revision
    final app = await getUserApp(revision.appId);
    if (app == null) return;

    // If this is the pinned revision, move the pin to the previous "latest" revision
    if (app.selectedRevisionId == id) {
      // Find the latest remaining revision (highest revision number)
      final remainingRevisions = allRevisions.where((r) => r.id != id).toList();
      if (remainingRevisions.isNotEmpty) {
        // Sort by revision number descending to get the latest
        remainingRevisions.sort(
          (a, b) => b.revisionNumber.compareTo(a.revisionNumber),
        );
        final newPinnedRevision = remainingRevisions.first;

        // Update the app's selectedRevisionId
        final updatedApp = app.copyWith(
          selectedRevisionId: newPinnedRevision.id,
        );
        await updateUserApp(updatedApp);
      }
    }

    // Delete libraries and dependencies for this specific revision
    await deleteUserAppLibrariesForRevision(revision.revisionNumber);

    // Finally delete the revision
    await db.delete('app_revisions', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAppRevisions(String appId) async {
    final db = await database;
    await db.delete('app_revisions', where: 'appId = ?', whereArgs: [appId]);
  }

  Future<int> getNextRevisionNumber(String appId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(revisionNumber) as maxRevision FROM app_revisions WHERE appId = ?',
      [appId],
    );
    final maxRevision = result.first['maxRevision'] as int?;
    return (maxRevision ?? 0) + 1;
  }

  Future<AppRevision?> getLatestAppRevision(String appId) async {
    final db = await database;
    final result = await db.rawQuery(
      '''
      SELECT 
        id, appId, revisionNumber, revisionTimestamp, userPrompt, aiResponse, attachmentPaths,
        CASE WHEN length(appCode) < 500000 THEN appCode ELSE NULL END as appCode,
        length(appCode) as _appCodeLength
      FROM app_revisions 
      WHERE appId = ? 
      ORDER BY revisionNumber DESC 
      LIMIT 1
      ''',
      [appId],
    );
    if (result.isNotEmpty) {
      return await _appRevisionFromMap(result.first);
    }
    return null;
  }

  Future<AppRevision> _appRevisionFromMap(Map<String, dynamic> map) async {
    String appCode = map['appCode'] as String? ?? '';
    if (appCode.isEmpty && (map['_appCodeLength'] as int? ?? 0) > 0) {
      final db = await database;
      appCode = await _readLargeString(
        db,
        'app_revisions',
        'appCode',
        map['id'] as String,
      );
    }

    final revision = AppRevision(
      id: map['id'] as String,
      appId: map['appId'] as String,
      revisionNumber: map['revisionNumber'] as int,
      revisionTimestamp: DateTime.fromMillisecondsSinceEpoch(
        map['revisionTimestamp'] as int,
      ),
      userPrompt: map['userPrompt'] as String,
      aiResponse: map['aiResponse'] as String,
      appCode: appCode,
      attachmentPaths: map['attachmentPaths'] != null
          ? (map['attachmentPaths'] as String)
                .split('|')
                .where((path) => path.isNotEmpty)
                .toList()
          : [],
    );
    LoggerService.debug(
      '_appRevisionFromMap: Created revision ${revision.id} with appCode length: ${revision.appCode.length}',
    );
    return revision;
  }

  // User App Libraries CRUD
  Future<int> insertUserAppLibrary({
    required String appUuid,
    required int revisionId,
    required String name,
    String? usageInstructions,
  }) async {
    final db = await database;
    final result = await db.insert('user_app_libraries', {
      'app_uuid': appUuid,
      'revision_id': revisionId,
      'name': name,
      'usage_instructions': usageInstructions,
    });
    return result;
  }

  Future<List<Map<String, dynamic>>> getUserAppLibraries(
    String appUuid,
    int revisionId,
  ) async {
    final db = await database;
    return await db.query(
      'user_app_libraries',
      where: 'app_uuid = ? AND revision_id = ?',
      whereArgs: [appUuid, revisionId],
    );
  }

  Future<void> deleteUserAppLibrary(int libraryId) async {
    final db = await database;
    await db.delete(
      'user_app_libraries',
      where: 'id = ?',
      whereArgs: [libraryId],
    );
  }

  Future<void> deleteUserAppLibrariesForRevision(int revisionId) async {
    final db = await database;
    await db.delete(
      'user_app_libraries',
      where: 'revision_id = ?',
      whereArgs: [revisionId],
    );
  }

  // User App Library Dependencies CRUD
  Future<int> insertUserAppLibraryDependency({
    String? originalUrl,
    required String localPath,
    required List<int> bytes,
    required int libraryId,
  }) async {
    final db = await database;
    final result = await db.insert('user_app_library_dependencies', {
      'original_url': originalUrl,
      'local_path': localPath,
      'bytes': Uint8List.fromList(bytes),
      'library_id': libraryId,
    });
    return result;
  }

  Future<List<Map<String, dynamic>>> getUserAppLibraryDependencies(
    int libraryId,
  ) async {
    final db = await database;

    // Use raw query with chunked BLOB reading to avoid cursor window issues
    final results = await db.rawQuery(
      '''
      SELECT id, original_url, local_path, library_id,
             CASE 
               WHEN length(bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL 
             END as has_blob
      FROM user_app_library_dependencies 
      WHERE library_id = ?
    ''',
      [libraryId],
    );

    final List<Map<String, dynamic>> processedResults = [];
    for (final map in results) {
      final newMap = Map<String, dynamic>.from(map);

      // Read BLOB data in chunks to avoid cursor window issues
      if (map['has_blob'] != null) {
        try {
          final blobData = await _readLargeBlob(
            db,
            'user_app_library_dependencies',
            'bytes',
            map['id'] as int,
          );
          newMap['bytes'] = blobData;
        } catch (e) {
          LoggerService.error(
            'Failed to read BLOB data for dependency ${map['id']}: $e',
            error: e,
          );
          newMap['bytes'] = <int>[];
        }
      } else {
        newMap['bytes'] = <int>[];
      }

      processedResults.add(newMap);
    }

    return processedResults;
  }

  Future<Map<String, dynamic>?> getUserAppLibraryDependencyByPath(
    String localPath,
  ) async {
    final db = await database;

    // Use raw query to avoid cursor window issues
    final results = await db.rawQuery(
      '''
      SELECT id, original_url, local_path, library_id,
             CASE 
               WHEN length(bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL 
             END as has_blob
      FROM user_app_library_dependencies 
      WHERE local_path = ?
    ''',
      [localPath],
    );

    if (results.isNotEmpty) {
      final result = Map<String, dynamic>.from(results.first);

      // Read BLOB data in chunks to avoid cursor window issues
      if (result['has_blob'] != null) {
        try {
          final blobData = await _readLargeBlob(
            db,
            'user_app_library_dependencies',
            'bytes',
            result['id'] as int,
          );
          result['bytes'] = blobData;
        } catch (e) {
          LoggerService.error(
            'Failed to read BLOB data for dependency ${result['id']}: $e',
            error: e,
          );
          result['bytes'] = <int>[];
        }
      } else {
        result['bytes'] = <int>[];
      }

      return result;
    }
    return null;
  }

  Future<void> deleteUserAppLibraryDependency(int dependencyId) async {
    final db = await database;
    await db.delete(
      'user_app_library_dependencies',
      where: 'id = ?',
      whereArgs: [dependencyId],
    );
  }

  // Get dependency by app UUID, revision ID, and local path
  Future<Map<String, dynamic>?> getDependencyByAppAndPath(
    String appUuid,
    int revisionId,
    String localPath,
  ) async {
    final db = await database;
    final results = await db.rawQuery(
      '''
      SELECT d.id, d.original_url, d.local_path, d.library_id,
             CASE 
               WHEN length(d.bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL 
             END as has_blob
      FROM user_app_library_dependencies d
      JOIN user_app_libraries l ON d.library_id = l.id
      WHERE l.app_uuid = ? AND l.revision_id = ? AND d.local_path = ?
    ''',
      [appUuid, revisionId, localPath],
    );

    if (results.isNotEmpty) {
      final result = Map<String, dynamic>.from(results.first);

      // Read BLOB data in chunks to avoid cursor window issues
      if (result['has_blob'] != null) {
        try {
          final blobData = await _readLargeBlob(
            db,
            'user_app_library_dependencies',
            'bytes',
            result['id'] as int,
          );
          result['bytes'] = blobData;
        } catch (e) {
          LoggerService.error(
            'Failed to read BLOB data for dependency ${result['id']}: $e',
            error: e,
          );
          result['bytes'] = <int>[];
        }
      } else {
        result['bytes'] = <int>[];
      }

      return result;
    }
    return null;
  }

  // Helper method to read TEXT data in chunks to avoid cursor window issues
  Future<String> _readLargeString(
    Database db,
    String table,
    String column,
    String id, {
    String idColumn = 'id',
    int chunkSize = 1024 * 1024, // 1MB
  }) async {
    final StringBuffer allText = StringBuffer();

    try {
      // Get the total size of the TEXT
      final sizeResult = await db.rawQuery(
        'SELECT length($column) as text_size FROM $table WHERE $idColumn = ?',
        [id],
      );

      if (sizeResult.isEmpty) {
        return '';
      }

      final int totalSize = sizeResult.first['text_size'] as int;
      if (totalSize == 0) {
        return '';
      }

      // Read TEXT in chunks
      for (int offset = 0; offset < totalSize; offset += chunkSize) {
        final int currentChunkSize = (offset + chunkSize > totalSize)
            ? totalSize - offset
            : chunkSize;

        final chunkResult = await db.rawQuery(
          'SELECT substr($column, ?, ?) as chunk FROM $table WHERE $idColumn = ?',
          [offset + 1, currentChunkSize, id],
        );

        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as String;
          allText.write(chunk);
        }
      }

      return allText.toString();
    } catch (e) {
      LoggerService.error(
        'Error reading large string from $table.$column: $e',
        error: e,
      );
      return '';
    }
  }

  Future<List<int>> _readLargeBlob(
    Database db,
    String table,
    String column,
    int id, {
    String idColumn = 'id',
    int chunkSize = 1024 * 1024, // 1MB
  }) async {
    final List<int> allBytes = [];

    try {
      // Get the total size of the BLOB
      final sizeResult = await db.rawQuery(
        'SELECT length($column) as blob_size FROM $table WHERE $idColumn = ?',
        [id],
      );

      if (sizeResult.isEmpty) {
        return <int>[];
      }

      final int totalSize = sizeResult.first['blob_size'] as int;

      // Read BLOB in chunks
      for (int offset = 0; offset < totalSize; offset += chunkSize) {
        final int currentChunkSize = (offset + chunkSize > totalSize)
            ? totalSize - offset
            : chunkSize;

        final chunkResult = await db.rawQuery(
          'SELECT substr($column, ?, ?) as chunk FROM $table WHERE $idColumn = ?',
          [offset + 1, currentChunkSize, id],
        );

        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as Uint8List;
          allBytes.addAll(chunk);
        }
      }

      return allBytes;
    } catch (e) {
      LoggerService.error(
        'Error reading large blob from $table.$column: $e',
        error: e,
      );
      return <int>[];
    }
  }

  // Conversations CRUD
  Future<String> insertConversation(Conversation conversation) async {
    final db = await database;
    final json = conversation.toJson();
    json['createdAt'] = conversation.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = conversation.updatedAt.millisecondsSinceEpoch;
    json['isArchived'] = conversation.isArchived ? 1 : 0;
    json['noteIds'] = '[]'; // Always empty, managed by mapping table

    await db.insert('conversations', json);
    return conversation.id;
  }

  // Get all conversations
  Future<List<Conversation>> getAllConversations({
    Duration? maxAge,
    List<String>? conversationIds,
    List<String>? tagNames,
    bool includeEmpty = true,
  }) async {
    final db = await database;

    final filters = <String>[];
    final filterArgs = <dynamic>[];

    if (maxAge != null) {
      filters.add('c.updatedAt >= ?');
      filterArgs.add(DateTime.now().subtract(maxAge).millisecondsSinceEpoch);
    }

    if (conversationIds != null && conversationIds.isNotEmpty) {
      final idsPlaceholder = List.filled(conversationIds.length, '?').join(',');
      filters.add('c.id IN ($idsPlaceholder)');
      filterArgs.addAll(conversationIds);
    }

    if (tagNames != null && tagNames.isNotEmpty) {
      final tagPlaceholders = List.filled(tagNames.length, '?').join(',');
      final whereSegments = <String>['t.name IN ($tagPlaceholders)'];
      whereSegments.addAll(filters);

      if (!includeEmpty) {
        whereSegments.add('''
          EXISTS (
            SELECT 1 FROM conversation_message_mapping cmm
            WHERE cmm.conversationId = c.id
          )
        ''');
      }

      final query =
          '''
        SELECT c.*
        FROM conversations c
        JOIN conversation_tags ct ON c.id = ct.conversationId
        JOIN tags t ON t.id = ct.tagId
        WHERE ${whereSegments.join(' AND ')}
        GROUP BY c.id
        HAVING COUNT(DISTINCT t.name) = ?
        ORDER BY c.updatedAt DESC
      ''';

      final queryArgs = <dynamic>[...tagNames, ...filterArgs, tagNames.length];

      final maps = await db.rawQuery(query, queryArgs);
      return maps.map((map) => _mapToConversation(map)).toList();
    }

    // Prepare simple query filters
    var queryFilters = List<String>.from(filters);
    if (!includeEmpty) {
      queryFilters.add('''
        EXISTS (
          SELECT 1 FROM conversation_message_mapping cmm
          WHERE cmm.conversationId = conversations.id
        )
      ''');
    }

    final whereClause = queryFilters.isNotEmpty
        ? queryFilters
              .map((clause) => clause.replaceAll('c.', ''))
              .join(' AND ')
        : null;

    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      where: whereClause,
      whereArgs: filterArgs.isEmpty ? null : filterArgs,
      orderBy: 'updatedAt DESC',
    );

    return maps.map((map) => _mapToConversation(map)).toList();
  }

  /// Gets the first and last message of a conversation for preview purposes
  /// efficiently using LIMIT 1 queries.
  Future<List<ConversationMessage>> getConversationPreviewMessages(
    String conversationId,
  ) async {
    final db = await database;

    // Get the first message
    final firstMsgMaps = await db.rawQuery(
      '''
      SELECT cm.*
      FROM conversation_messages cm
      JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp ASC
      LIMIT 1
      ''',
      [conversationId],
    );

    if (firstMsgMaps.isEmpty) return [];

    // Get the last message
    final lastMsgMaps = await db.rawQuery(
      '''
      SELECT cm.*
      FROM conversation_messages cm
      JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp DESC
      LIMIT 1
      ''',
      [conversationId],
    );

    final messages = <ConversationMessage>[];
    final firstMap = Map<String, dynamic>.from(firstMsgMaps.first);
    await _populateMessageAttachmentPaths(db, firstMap);
    messages.add(_mapToConversationMessage(firstMap, conversationId));

    // Only add last message if it's different from the first
    if (lastMsgMaps.isNotEmpty) {
      final lastMap = Map<String, dynamic>.from(lastMsgMaps.first);
      if (lastMap['id'] != firstMap['id']) {
        await _populateMessageAttachmentPaths(db, lastMap);
        messages.add(_mapToConversationMessage(lastMap, conversationId));
      }
    }

    return messages;
  }

  Future<Conversation?> getConversation(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return _mapToConversation(maps.first);
  }

  Future<void> updateConversation(Conversation conversation) async {
    final db = await database;
    final json = conversation.toJson();
    json['createdAt'] = conversation.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = conversation.updatedAt.millisecondsSinceEpoch;
    json['isArchived'] = conversation.isArchived ? 1 : 0;
    json['noteIds'] = '[]'; // Always empty, managed by mapping table

    await db.update(
      'conversations',
      json,
      where: 'id = ?',
      whereArgs: [conversation.id],
    );
  }

  Future<void> deleteConversation(String id) async {
    final db = await database;
    // Delete note mappings first (foreign key constraints will handle cascade deletion)
    await deleteConversationNoteMappings(id);
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  // Conversation Messages CRUD
  Future<String> insertConversationMessage(ConversationMessage message) async {
    final db = await database;
    final json = message.toJson();
    json['timestamp'] = message.timestamp.millisecondsSinceEpoch;
    json['metadata'] = message.metadata != null
        ? jsonEncode(message.metadata)
        : null;
    // Remove attachmentPaths and conversationId as they're not in the database schema
    json.remove('attachmentPaths');
    json.remove('conversationId');

    await db.insert('conversation_messages', json);
    return message.id;
  }

  Future<List<ConversationMessage>> getConversationMessages(
    String conversationId,
  ) async {
    final db = await database;
    // Join with conversation_message_mapping to get messages for this conversation
    // EXCLUDE metadata from the main query to avoid CursorWindow size limits
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT cm.id, cm.type, cm.content, cm.timestamp, cm.modelUsed
      FROM conversation_messages cm
      INNER JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp ASC
    ''',
      [conversationId],
    );

    final messages = <ConversationMessage>[];

    for (final map in maps) {
      // Create a mutable copy of the map
      final messageMap = Map<String, dynamic>.from(map);

      // Fetch metadata separately
      try {
        final metadataResult = await db.query(
          'conversation_messages',
          columns: ['metadata'],
          where: 'id = ?',
          whereArgs: [messageMap['id']],
        );

        if (metadataResult.isNotEmpty) {
          messageMap['metadata'] = metadataResult.first['metadata'];
        }
      } catch (e) {
        // Fallback: If fetching full metadata fails (e.g. single row too big),
        // try to read it in chunks using substr.
        // Note: This is a last resort and might be slow.
        LoggerService.error(
          'Error fetching metadata for message ${messageMap['id']}: $e. Attempting chunked read.',
        );
        try {
          messageMap['metadata'] = await _readLargeMetadata(
            db,
            messageMap['id'] as String,
          );
        } catch (e2) {
          LoggerService.error('Failed to read large metadata: $e2');
          // Proceed without metadata rather than crashing the whole view
        }
      }

      await _populateMessageAttachmentPaths(db, messageMap);
      messages.add(_mapToConversationMessage(messageMap, conversationId));
    }

    return messages;
  }

  // Helper to read potentially huge metadata in chunks
  Future<String?> _readLargeMetadata(Database db, String messageId) async {
    final sb = StringBuffer();
    int offset = 1; // SQLite substr is 1-based
    const chunkSize = 1000000; // 1MB chunks

    while (true) {
      final List<Map<String, dynamic>> result = await db.rawQuery(
        'SELECT substr(metadata, ?, ?) as chunk FROM conversation_messages WHERE id = ?',
        [offset, chunkSize, messageId],
      );

      if (result.isEmpty || result.first['chunk'] == null) break;

      final chunk = result.first['chunk'] as String;
      if (chunk.isEmpty) break;

      sb.write(chunk);
      offset += chunkSize;

      // If chunk is smaller than requested, we reached the end
      if (chunk.length < chunkSize) break;
    }

    return sb.isNotEmpty ? sb.toString() : null;
  }

  Future<ConversationMessage?> getConversationMessage(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversation_messages',
      columns: [
        'id',
        'type',
        'content',
        'timestamp',
        'modelUsed',
      ], // Exclude metadata
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;

    // Get the conversationId from the mapping table
    final mappingResult = await db.query(
      'conversation_message_mapping',
      where: 'messageId = ?',
      whereArgs: [id],
      limit: 1,
    );

    final conversationId = mappingResult.isNotEmpty
        ? mappingResult.first['conversationId'] as String
        : '';

    final messageMap = Map<String, dynamic>.from(maps.first);

    // Fetch metadata separately
    try {
      final metadataResult = await db.query(
        'conversation_messages',
        columns: ['metadata'],
        where: 'id = ?',
        whereArgs: [id],
      );

      if (metadataResult.isNotEmpty) {
        messageMap['metadata'] = metadataResult.first['metadata'];
      }
    } catch (e) {
      LoggerService.error(
        'Error fetching metadata for message $id: $e. Attempting chunked read.',
      );
      try {
        messageMap['metadata'] = await _readLargeMetadata(db, id);
      } catch (e2) {
        LoggerService.error('Failed to read large metadata: $e2');
      }
    }

    await _populateMessageAttachmentPaths(db, messageMap);
    return _mapToConversationMessage(messageMap, conversationId);
  }

  Future<void> updateConversationMessage(ConversationMessage message) async {
    final db = await database;
    final json = message.toJson();
    json['timestamp'] = message.timestamp.millisecondsSinceEpoch;
    json['metadata'] = message.metadata != null
        ? jsonEncode(message.metadata)
        : null;
    // Remove attachmentPaths and conversationId as they're not in the database schema
    json.remove('attachmentPaths');
    json.remove('conversationId');

    await db.update(
      'conversation_messages',
      json,
      where: 'id = ?',
      whereArgs: [message.id],
    );
  }

  Future<void> deleteConversationMessage(String id) async {
    final db = await database;
    await db.delete('conversation_messages', where: 'id = ?', whereArgs: [id]);
  }

  // Comprehensive message deletion with subtree cleanup
  Future<void> deleteMessageWithSubtree(String messageId) async {
    LoggerService.info(
      'Starting deletion of message $messageId and its subtree',
    );

    // 1. Find all messages in the subtree (children recursively)
    final messagesToDelete = await _getMessageSubtree(messageId);
    LoggerService.info(
      'Found ${messagesToDelete.length} messages to delete in subtree',
    );

    // 2. Delete all related data efficiently
    await _deleteMessagesBatch(messagesToDelete);

    // 3. Find conversations that now have no messages and delete them
    await _cleanupEmptyConversations();

    LoggerService.info(
      'Successfully deleted message $messageId and its subtree',
    );
  }

  // Efficiently delete a batch of messages and all their related data
  Future<void> _deleteMessagesBatch(List<String> messageIds) async {
    if (messageIds.isEmpty) return;

    final db = await database;

    // Create placeholders for IN clause
    final placeholders = messageIds.map((_) => '?').join(',');

    // 1. Delete attachments for all messages
    await db.delete(
      'conversation_attachments',
      where: 'messageId IN ($placeholders)',
      whereArgs: messageIds,
    );

    // 2. Delete message-parent relationships for all messages
    await db.delete(
      'message_parents',
      where:
          'messageId IN ($placeholders) OR parentMessageId IN ($placeholders)',
      whereArgs: [...messageIds, ...messageIds],
    );

    // 3. Delete conversation-message mappings for all messages
    await db.delete(
      'conversation_message_mapping',
      where: 'messageId IN ($placeholders)',
      whereArgs: messageIds,
    );

    // 4. Delete the messages themselves
    await db.delete(
      'conversation_messages',
      where: 'id IN ($placeholders)',
      whereArgs: messageIds,
    );
  }

  // Get all messages in the subtree of a given message using proper recursive traversal
  Future<List<String>> _getMessageSubtree(String messageId) async {
    final db = await database;
    final messagesToDelete = <String>{};

    // Recursive function to traverse the tree
    Future<void> traverseSubtree(String currentMessageId) async {
      if (messagesToDelete.contains(currentMessageId)) {
        return; // Already processed
      }

      messagesToDelete.add(currentMessageId);

      // Find all children of current message
      final children = await db.query(
        'message_parents',
        where: 'parentMessageId = ?',
        whereArgs: [currentMessageId],
      );

      // Recursively process each child
      for (final child in children) {
        final childId = child['messageId'] as String;
        await traverseSubtree(childId);
      }
    }

    await traverseSubtree(messageId);
    return messagesToDelete.toList();
  }

  // Clean up conversations that have no messages
  Future<void> _cleanupEmptyConversations() async {
    final db = await database;

    // Find conversations with no message mappings
    final emptyConversations = await db.rawQuery('''
      SELECT c.id
      FROM conversations c
      LEFT JOIN conversation_message_mapping cmm ON c.id = cmm.conversationId
      WHERE cmm.conversationId IS NULL
    ''');

    for (final conversation in emptyConversations) {
      final conversationId = conversation['id'] as String;
      LoggerService.info('Deleting empty conversation: $conversationId');
      await db.delete(
        'conversations',
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    }

    if (emptyConversations.isNotEmpty) {
      LoggerService.info(
        'Cleaned up ${emptyConversations.length} empty conversations',
      );
    }

    // Remove conversations that only reference messages owned by earlier conversations
    final redundantConversations = await db.rawQuery('''
      WITH message_mappings AS (
        SELECT
          cmm.conversationId,
          cmm.messageId,
          ROW_NUMBER() OVER (
            PARTITION BY cmm.messageId
            ORDER BY c.createdAt ASC, c.id ASC
          ) AS messageRank
        FROM conversation_message_mapping cmm
        JOIN conversations c ON c.id = cmm.conversationId
      ),
      conversation_note_counts AS (
        SELECT conversationId, COUNT(*) AS noteCount
        FROM conversation_note_mapping
        GROUP BY conversationId
      )
      SELECT mm.conversationId AS id
      FROM message_mappings mm
      LEFT JOIN conversation_note_counts cnc ON mm.conversationId = cnc.conversationId
      GROUP BY mm.conversationId, COALESCE(cnc.noteCount, 0)
      HAVING SUM(CASE WHEN mm.messageRank = 1 THEN 1 ELSE 0 END) = 0
         AND COALESCE(cnc.noteCount, 0) = 0
    ''');

    for (final conversation in redundantConversations) {
      final conversationId = conversation['id'] as String;
      LoggerService.info('Deleting redundant conversation: $conversationId');
      await db.delete(
        'conversations',
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    }

    if (redundantConversations.isNotEmpty) {
      LoggerService.info(
        'Removed ${redundantConversations.length} redundant conversations',
      );
    }
  }

  // Delete conversation (only if explicitly requested)
  Future<void> deleteConversationExplicitly(String conversationId) async {
    final db = await database;

    LoggerService.info('Explicitly deleting conversation: $conversationId');

    // Delete conversation-note mappings first
    await deleteConversationNoteMappings(conversationId);

    // Get all messages in this conversation
    final messageMappings = await db.query(
      'conversation_message_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );

    // Delete all messages in this conversation
    for (final mapping in messageMappings) {
      final messageId = mapping['messageId'] as String;
      await deleteMessageWithSubtree(messageId);
    }

    // Delete the conversation itself
    await db.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
    );

    LoggerService.info('Successfully deleted conversation: $conversationId');
  }

  // Delete messages using tree node traversal (for UI efficiency)
  Future<void> deleteMessagesFromTreeNodes(List<String> messageIds) async {
    if (messageIds.isEmpty) return;

    LoggerService.info(
      'Deleting ${messageIds.length} messages from tree nodes',
    );

    // Delete all related data efficiently
    await _deleteMessagesBatch(messageIds);

    // Find conversations that now have no messages and delete them
    await _cleanupEmptyConversations();

    LoggerService.info('Successfully deleted messages from tree nodes');
  }

  // Conversation Attachments CRUD
  Future<String> insertConversationAttachment(
    ConversationAttachment attachment,
  ) async {
    final db = await database;
    final json = attachment.toDatabase();
    await db.insert('conversation_attachments', json);
    return attachment.id;
  }

  Future<List<ConversationAttachment>> getConversationAttachments(
    String messageId,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversation_attachments',
      where: 'messageId = ?',
      whereArgs: [messageId],
      orderBy: 'createdAt ASC',
    );

    return maps.map((map) => ConversationAttachment.fromDatabase(map)).toList();
  }

  Future<void> deleteConversationAttachment(String id) async {
    final db = await database;
    await db.delete(
      'conversation_attachments',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Helper methods for mapping database results to models
  Conversation _mapToConversation(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String,
      noteIds: const [], // Always empty, managed by mapping table
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
      isArchived: (map['isArchived'] ?? 0) == 1,
    );
  }

  Future<void> _populateMessageAttachmentPaths(
    Database db,
    Map<String, dynamic> messageMap,
  ) async {
    try {
      final attachmentRecords = await db.query(
        'conversation_attachments',
        columns: ['filePath'],
        where: 'messageId = ?',
        whereArgs: [messageMap['id']],
        orderBy: 'createdAt ASC',
      );
      if (attachmentRecords.isNotEmpty) {
        final paths = attachmentRecords
            .map((r) => r['filePath'] as String)
            .toList();
        messageMap['attachmentPaths'] = jsonEncode(paths);
      }
    } catch (e) {
      LoggerService.error(
        'Failed to get attachments for message ${messageMap['id']}: $e',
      );
    }
  }

  ConversationMessage _mapToConversationMessage(
    Map<String, dynamic> map,
    String conversationId,
  ) {
    return ConversationMessage(
      id: map['id'] as String,
      conversationId: conversationId,
      type: MessageType.values.firstWhere(
        (e) => e.toString().split('.').last == map['type'],
        orElse: () => MessageType.user,
      ),
      content: map['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      attachmentPaths: map['attachmentPaths'] != null
          ? List<String>.from(jsonDecode(map['attachmentPaths'] as String))
          : [],
      modelUsed: map['modelUsed'] as String?,
      metadata: map['metadata'] != null
          ? Map<String, dynamic>.from(jsonDecode(map['metadata'] as String))
          : null,
    );
  }

  // New conversation-message mapping methods
  Future<String> insertConversationMessageMapping({
    required String conversationId,
    required String messageId,
  }) async {
    final db = await database;
    final result = await db.insert('conversation_message_mapping', {
      'conversationId': conversationId,
      'messageId': messageId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    return result.toString();
  }

  Future<List<Map<String, dynamic>>> getConversationMessageMappings(
    String conversationId,
  ) async {
    final db = await database;
    return await db.query(
      'conversation_message_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'id ASC', // Use auto-increment ID for canonical ordering
    );
  }

  Future<List<String>> getConversationMessageIds(String conversationId) async {
    final mappings = await getConversationMessageMappings(conversationId);
    return mappings.map((m) => m['messageId'] as String).toList();
  }

  // New message parent methods
  Future<String> insertMessageParent({
    required String messageId,
    required String parentMessageId,
  }) async {
    final db = await database;
    final id = '${messageId}_$parentMessageId';
    await db.insert('message_parents', {
      'id': id,
      'messageId': messageId,
      'parentMessageId': parentMessageId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllMessageParents() async {
    final db = await database;
    return await db.query('message_parents');
  }

  Future<String?> getMessageParent(String messageId) async {
    final db = await database;
    final results = await db.query(
      'message_parents',
      where: 'messageId = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return results.isNotEmpty
        ? results.first['parentMessageId'] as String?
        : null;
  }

  Future<List<String>> getMessageChildren(String parentMessageId) async {
    final db = await database;
    final results = await db.query(
      'message_parents',
      where: 'parentMessageId = ?',
      whereArgs: [parentMessageId],
    );
    return results.map((r) => r['messageId'] as String).toList();
  }

  Future<void> deleteEmptyConversations({required Duration olderThan}) async {
    final db = await database;
    final since = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    final emptyConversations = await db.rawQuery(
      '''
      SELECT c.id 
      FROM conversations c 
      LEFT JOIN conversation_message_mapping cmm ON c.id = cmm.conversationId 
      WHERE cmm.conversationId IS NULL AND c.updatedAt < ?
    ''',
      [since],
    );

    for (final conversation in emptyConversations) {
      final conversationId = conversation['id'] as String;
      await db.delete(
        'conversations',
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    }
  }

  // Find all conversations that contain a specific message
  Future<List<String>> getConversationsContainingMessage(
    String messageId,
  ) async {
    final db = await database;
    final results = await db.query(
      'conversation_message_mapping',
      where: 'messageId = ?',
      whereArgs: [messageId],
    );
    return results.map((r) => r['conversationId'] as String).toList();
  }

  // Conversation-Note Mapping CRUD methods
  Future<String> insertConversationNoteMapping({
    required String conversationId,
    required String noteId,
  }) async {
    final db = await database;
    final result = await db.insert('conversation_note_mapping', {
      'conversationId': conversationId,
      'noteId': noteId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return result.toString();
  }

  Future<List<String>> getConversationNoteIds(String conversationId) async {
    final db = await database;
    final results = await db.query(
      'conversation_note_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
    );
    return results.map((r) => r['noteId'] as String).toList();
  }

  Future<List<String>> getNoteConversationIds(String noteId) async {
    final db = await database;
    final results = await db.query(
      'conversation_note_mapping',
      where: 'noteId = ?',
      whereArgs: [noteId],
      orderBy: 'createdAt ASC',
    );
    return results.map((r) => r['conversationId'] as String).toList();
  }

  Future<void> deleteConversationNoteMapping({
    required String conversationId,
    required String noteId,
  }) async {
    final db = await database;
    await db.delete(
      'conversation_note_mapping',
      where: 'conversationId = ? AND noteId = ?',
      whereArgs: [conversationId, noteId],
    );
  }

  Future<void> deleteConversationNoteMappings(String conversationId) async {
    final db = await database;
    await db.delete(
      'conversation_note_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> deleteNoteConversationMappings(String noteId) async {
    final db = await database;
    await db.delete(
      'conversation_note_mapping',
      where: 'noteId = ?',
      whereArgs: [noteId],
    );
  }

  Future<bool> conversationNoteMappingExists({
    required String conversationId,
    required String noteId,
  }) async {
    final db = await database;
    final results = await db.query(
      'conversation_note_mapping',
      where: 'conversationId = ? AND noteId = ?',
      whereArgs: [conversationId, noteId],
      limit: 1,
    );
    return results.isNotEmpty;
  }

  Future<int> getNoteConversationCount(String noteId) async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT COUNT(*) as count FROM conversation_note_mapping WHERE noteId = ?',
      [noteId],
    );
    return results.first['count'] as int;
  }

  Future<int> getConversationNoteCount(String conversationId) async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT COUNT(*) as count FROM conversation_note_mapping WHERE conversationId = ?',
      [conversationId],
    );
    return results.first['count'] as int;
  }

  // Conversation-Tag mapping methods
  Future<void> addTagsToConversation(
    String conversationId,
    List<String> tagNames,
  ) async {
    if (tagNames.isEmpty) return;

    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final tagName in tagNames) {
      final tagId = await _getOrCreateTagId(db, tagName);
      await db.insert('conversation_tags', {
        'conversationId': conversationId,
        'tagId': tagId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    await db.update(
      'conversations',
      {'updatedAt': now},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> setConversationTags(
    String conversationId,
    List<String> tagNames,
  ) async {
    final db = await database;
    final currentMappings = await db.query(
      'conversation_tags',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );

    final currentTagIds = currentMappings
        .map((row) => row['tagId'] as String)
        .toSet();
    final desiredTagIds = <String>{};

    for (final tagName in tagNames) {
      final tagId = await _getOrCreateTagId(db, tagName);
      desiredTagIds.add(tagId);
    }

    for (final tagId in currentTagIds) {
      if (!desiredTagIds.contains(tagId)) {
        await db.delete(
          'conversation_tags',
          where: 'conversationId = ? AND tagId = ?',
          whereArgs: [conversationId, tagId],
        );
      }
    }

    for (final tagId in desiredTagIds) {
      await db.insert('conversation_tags', {
        'conversationId': conversationId,
        'tagId': tagId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    await db.update(
      'conversations',
      {'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> removeTagFromConversation(
    String conversationId,
    String tagName,
  ) async {
    final db = await database;

    final tagRecord = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [tagName],
      limit: 1,
    );

    if (tagRecord.isEmpty) return;

    final tagId = tagRecord.first['id'] as String;
    await db.delete(
      'conversation_tags',
      where: 'conversationId = ? AND tagId = ?',
      whereArgs: [conversationId, tagId],
    );

    await db.update(
      'conversations',
      {'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<List<Tag>> getConversationTags(String conversationId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT t.id, t.name, t.color, t.createdAt, t.usageCount
      FROM conversation_tags ct
      INNER JOIN tags t ON t.id = ct.tagId
      WHERE ct.conversationId = ?
      ORDER BY t.name COLLATE NOCASE ASC
    ''',
      [conversationId],
    );

    return maps.map((map) {
      return Tag(
        id: map['id'] as String,
        name: map['name'] as String,
        color: map['color'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
        usageCount: (map['usageCount'] as int?) ?? 0,
        conversationUsageCount: 0,
      );
    }).toList();
  }

  Future<List<String>> getConversationTagNames(String conversationId) async {
    final tags = await getConversationTags(conversationId);
    return tags.map((tag) => tag.name).toList();
  }

  // Multi-function Apps Methods

  Future<void> addAppToMultiFunction(String appId) async {
    final db = await database;
    await db.insert('multi_function_apps', {
      'appId': appId,
      'isDefault': 0,
      'addedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeAppFromMultiFunction(String appId) async {
    final db = await database;
    await db.delete(
      'multi_function_apps',
      where: 'appId = ?',
      whereArgs: [appId],
    );
  }

  Future<void> setMultiFunctionDefaultApp(String appId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Reset all to not default
      await txn.update('multi_function_apps', {'isDefault': 0});
      // Set the specific app to default
      await txn.update(
        'multi_function_apps',
        {'isDefault': 1},
        where: 'appId = ?',
        whereArgs: [appId],
      );
    });
  }

  Future<void> clearMultiFunctionDefaultApp() async {
    final db = await database;
    await db.update('multi_function_apps', {'isDefault': 0});
  }

  Future<List<String>> getMultiFunctionApps() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'multi_function_apps',
      orderBy: 'addedAt DESC',
    );
    return maps.map((map) => map['appId'] as String).toList();
  }

  Future<String?> getMultiFunctionDefaultAppId() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'multi_function_apps',
      where: 'isDefault = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return maps.first['appId'] as String;
    }
    return null;
  }

  static Future<void> _migrateToVersion27(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 27: Adding isPinned column to filters table',
    );

    try {
      // Check if column already exists
      final columns = await db.rawQuery('PRAGMA table_info(filters)');
      final hasIsPinned = columns.any((col) => col['name'] == 'isPinned');

      if (!hasIsPinned) {
        await db.execute(
          'ALTER TABLE filters ADD COLUMN isPinned INTEGER NOT NULL DEFAULT 0',
        );
      }
    } catch (e) {
      LoggerService.error('Error adding isPinned column: $e', error: e);
      rethrow;
    }
  }

  /// Batch fetch messages for multiple conversations efficiently
  Future<List<ConversationMessage>> getMessagesForConversations(
    List<String> conversationIds,
  ) async {
    if (conversationIds.isEmpty) return [];

    final db = await database;
    // SQLite has a limit on variables, so we chunk requests if necessary
    const chunkSize = 500;
    final messages = <ConversationMessage>[];

    for (var i = 0; i < conversationIds.length; i += chunkSize) {
      final end = (i + chunkSize < conversationIds.length)
          ? i + chunkSize
          : conversationIds.length;
      final chunk = conversationIds.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');

      final results = await db.rawQuery('''
        SELECT 
          cm.id, 
          cm.type, 
          cm.content, 
          cm.timestamp, 
          cm.modelUsed, 
          cmm.conversationId
        FROM conversation_messages cm
        JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
        WHERE cmm.conversationId IN ($placeholders)
        ORDER BY cm.timestamp ASC
        ''', chunk);

      for (final map in results) {
        final messageMap = Map<String, dynamic>.from(map);
        await _populateMessageAttachmentPaths(db, messageMap);
        messages.add(
          _mapToConversationMessage(
            messageMap,
            messageMap['conversationId'] as String,
          ),
        );
      }
    }

    return messages;
  }

  /// Batch fetch conversation IDs for multiple messages
  /// Returns a map of messageId -> List<conversationId>
  Future<Map<String, List<String>>> getConversationIdsForMessages(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return {};

    final db = await database;
    final result = <String, List<String>>{};

    // Chunking to avoid variable limit
    const chunkSize = 500;

    for (var i = 0; i < messageIds.length; i += chunkSize) {
      final end = (i + chunkSize < messageIds.length)
          ? i + chunkSize
          : messageIds.length;
      final chunk = messageIds.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');

      final rows = await db.rawQuery('''
        SELECT messageId, conversationId
        FROM conversation_message_mapping
        WHERE messageId IN ($placeholders)
        ''', chunk);

      for (final row in rows) {
        final messageId = row['messageId'] as String;
        final conversationId = row['conversationId'] as String;

        if (!result.containsKey(messageId)) {
          result[messageId] = [];
        }
        result[messageId]!.add(conversationId);
      }
    }

    return result;
  }
  // --- Agent / AI Features ---

  /// Search notes using Full-Text Search
  Future<List<Note>> searchNotesFTS(String query, {List<String>? tags}) async {
    final db = await database;
    // FTS5 match query
    // We sanitize the query to prevent syntax errors in FTS match expression
    final sanitizedQuery = '"$query"';
    final hasTags = tags != null && tags.isNotEmpty;

    try {
      String sql = '''
        SELECT n.* 
        FROM notes_fts fts
        JOIN notes n ON fts.rowid = n.rowid
        WHERE notes_fts MATCH ?
      ''';

      List<Object?> args = [sanitizedQuery];

      // Add tag filtering
      // Since tags are stored as a JSON string or comma-separated string in 'tags' column (TEXT),
      // we can use LIKE. Assuming tags is a JSON array string like "['tag1', 'tag2']".
      // Or if it's a simple string. The Note model says List<String> tags.
      // In DB creation (checked before), tags is TEXT.
      // We will perform a crude check using LIKE for each tag.
      // Ideally we should normalize tags table, but for now:
      if (hasTags) {
        for (final tag in tags) {
          sql += ' AND n.tags LIKE ?';
          args.add('%"$tag"%'); // Assuming JSON format "tag"
        }
      }

      sql += ' ORDER BY rank LIMIT 50';

      final results = await db.rawQuery(sql, args);
      return await _batchLoadNotes(results);
    } catch (e) {
      // If FTS5 'rank' column is missing (FTS4 fallback), try without ordering by rank
      if (e.toString().contains('no such column: rank')) {
        try {
          String sql = '''
            SELECT n.* 
            FROM notes_fts fts
            JOIN notes n ON fts.rowid = n.rowid
            WHERE notes_fts MATCH ?
          ''';
          List<Object?> args = [sanitizedQuery];

          if (hasTags) {
            for (final tag in tags) {
              sql += ' AND n.tags LIKE ?';
              args.add('%"$tag"%');
            }
          }

          sql += ' LIMIT 50';

          final results = await db.rawQuery(sql, args);
          return await _batchLoadNotes(results);
        } catch (e2) {
          LoggerService.error('FTS Search failed: $e2');
          return [];
        }
      }
      LoggerService.error('FTS Search failed: $e');
      return [];
    }
  }

  /// Executes a raw SQL query. USE WITH CAUTION.
  Future<List<Map<String, dynamic>>> runRawQuery(
    String query, [
    List<Object?>? arguments,
  ]) async {
    final db = await database;
    return await db.rawQuery(query, arguments);
  }

  /// Fallback search using LIKE
  Future<List<Note>> searchNotes(String query) async {
    final db = await database;
    final results = await db.query(
      'notes',
      where: 'title LIKE ? OR content LIKE ?',
      whereArgs: ['%$query%', '%$query%'],
      orderBy: 'updatedAt DESC',
      limit: 50,
    );
    return await _batchLoadNotes(results);
  }

  /// Get the AI extraction prompt for a specific tag
  Future<String?> getTagExtractionPrompt(String tagId) async {
    final db = await database;
    try {
      final results = await db.query(
        'tag_ai_configs',
        columns: ['extractionPrompt'],
        where: 'tagId = ?',
        whereArgs: [tagId],
      );

      if (results.isNotEmpty) {
        return results.first['extractionPrompt'] as String?;
      }
    } catch (e) {
      // Table might not exist yet if migration hasn't run or dev mode
      LoggerService.warning('Failed to get tag config: $e');
    }
    return null;
  }

  /// Update or Insert the AI extraction prompt for a tag
  Future<void> updateTagExtractionPrompt(String tagId, String? prompt) async {
    final db = await database;
    if (prompt == null || prompt.isEmpty) {
      await db.delete('tag_ai_configs', where: 'tagId = ?', whereArgs: [tagId]);
    } else {
      await db.insert('tag_ai_configs', {
        'tagId': tagId,
        'extractionPrompt': prompt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<Note?> getNoteById(String id) async {
    final db = await database;
    final results = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    final notes = await _batchLoadNotes(results);
    return notes.isNotEmpty ? notes.first : null;
  }

  // --- End Agent / AI Features ---
}
