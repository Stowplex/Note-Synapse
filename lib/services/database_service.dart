import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';

// Conditional imports for platform-specific code
import 'database_service_io.dart' if (dart.library.html) 'database_service_web.dart';
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
import 'logger_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';

// Migration step configuration
class MigrationStep {
  final String description;
  final Future<void> Function(Database db, {required bool isBackupMigration}) execute;

  const MigrationStep({
    required this.description,
    required this.execute,
  });
}

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal() {
    // Initialize database factory using platform-specific implementation
    initializeDatabaseFactory();
  }

  // Table schema constants - single source of truth for all table definitions
  static const String _createNotesTable = '''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        type TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        scheduledAt TEXT,
        completeBy TEXT,
        status TEXT,
        completionPercentage REAL,
        pinned INTEGER NOT NULL DEFAULT 0,
        isArchived INTEGER NOT NULL DEFAULT 0
      )
  ''';

  static const String _createSubNotesTable = '''
      CREATE TABLE subnotes(
        id TEXT PRIMARY KEY,
        noteId TEXT NOT NULL,
        name TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        isCompleted INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  static const String _createTagsTable = '''
      CREATE TABLE tags(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        color TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        usageCount INTEGER NOT NULL DEFAULT 0
      )
  ''';

  static const String _createNoteTagsTable = '''
      CREATE TABLE note_tags(
        noteId TEXT NOT NULL,
        tagId TEXT NOT NULL,
        PRIMARY KEY (noteId, tagId),
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
  ''';

  static const String _createAttachmentsTable = '''
      CREATE TABLE attachments(
        id TEXT PRIMARY KEY,
        noteId TEXT NOT NULL,
        filePath TEXT NOT NULL,
        fileName TEXT NOT NULL,
        fileType TEXT NOT NULL,
        isRelativePath INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  static const String _createRelationshipsTable = '''
      CREATE TABLE relationships(
        id TEXT PRIMARY KEY,
        fromNoteId TEXT NOT NULL,
        toNoteId TEXT NOT NULL,
        type TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (fromNoteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (toNoteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  static const String _createFiltersTable = '''
      CREATE TABLE filters(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        includeText TEXT,
        includeTags TEXT NOT NULL,
        includeArchived INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
  ''';

  static const String _createUserAppsTable = '''
      CREATE TABLE user_apps(
        id TEXT PRIMARY KEY,
        uuid TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT NOT NULL,
        steps TEXT NOT NULL,
        htmlContent TEXT NOT NULL,
        appState TEXT,
        type TEXT NOT NULL DEFAULT 'normal',
        selectedRevisionId TEXT,
      author TEXT DEFAULT "",
      license TEXT DEFAULT "",
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
  ''';

  static const String _createAppRevisionsTable = '''
      CREATE TABLE app_revisions(
        id TEXT PRIMARY KEY,
        appId TEXT NOT NULL,
        revisionNumber INTEGER NOT NULL,
        revisionTimestamp INTEGER NOT NULL,
        userPrompt TEXT NOT NULL,
        aiResponse TEXT NOT NULL,
        appCode TEXT NOT NULL,
        attachmentPaths TEXT,
        FOREIGN KEY (appId) REFERENCES user_apps (id) ON DELETE CASCADE
      )
  ''';

  static const String _createUserAppLibrariesTable = '''
      CREATE TABLE user_app_libraries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        app_uuid TEXT NOT NULL,
        revision_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        usage_instructions TEXT,
        FOREIGN KEY (app_uuid) REFERENCES user_apps (uuid) ON DELETE CASCADE
      )
  ''';

  static const String _createUserAppLibraryDependenciesTable = '''
      CREATE TABLE user_app_library_dependencies(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        original_url TEXT,
        local_path TEXT NOT NULL,
        bytes BLOB NOT NULL,
        library_id INTEGER NOT NULL,
        FOREIGN KEY (library_id) REFERENCES user_app_libraries (id) ON DELETE CASCADE
      )
  ''';

  static const String _createConversationsTable = '''
      CREATE TABLE conversations(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        noteIds TEXT NOT NULL DEFAULT '[]',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        isArchived INTEGER NOT NULL DEFAULT 0
      )
  ''';

  static const String _createConversationMessagesTable = '''
      CREATE TABLE conversation_messages(
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        modelUsed TEXT,
        metadata TEXT
      )
  ''';

  static const String _createConversationAttachmentsTable = '''
      CREATE TABLE conversation_attachments(
        id TEXT PRIMARY KEY,
        messageId TEXT NOT NULL,
        filePath TEXT NOT NULL,
        fileName TEXT NOT NULL,
        fileType TEXT NOT NULL,
        isRelativePath INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE
      )
  ''';

  static const String _createConversationTreeTable = '''
      CREATE TABLE conversation_tree(
        id TEXT PRIMARY KEY,
        treeData TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
  ''';

  static const String _createConversationMessageMappingTable = '''
      CREATE TABLE conversation_message_mapping(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversationId TEXT NOT NULL,
        messageId TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        UNIQUE(conversationId, messageId)
      )
  ''';

  static const String _createMessageParentsTable = '''
      CREATE TABLE message_parents(
        id TEXT PRIMARY KEY,
        messageId TEXT NOT NULL,
        parentMessageId TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        FOREIGN KEY (parentMessageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        UNIQUE(messageId, parentMessageId)
      )
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
  ];

  // For testing, allow creating new instances
  DatabaseService.createNew() {
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
    String path = join(await getDatabasesPath(), 'note_synapse.db');
    return await openDatabase(
      path,
      version: 19,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Create all tables using schema constants
    await db.execute(_createNotesTable);
    await db.execute(_createSubNotesTable);
    await db.execute(_createTagsTable);
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
    await db.execute(_createConversationTreeTable);
    await db.execute(_createConversationMessageMappingTable);
    await db.execute(_createMessageParentsTable);

    // Create all indexes
    for (final indexSql in _createIndexes) {
      await db.execute(indexSql);
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await _executeMigrations(db, oldVersion, newVersion, isBackupMigration: false);
  }

  // Migration configuration structure
  static const Map<int, MigrationStep> _migrationSteps = {
    2: MigrationStep(
      description: 'Remove dueDate column and add scheduledAt, completeBy columns',
      execute: _migrateToVersion2,
    ),
    3: MigrationStep(
      description: 'Add pinned column',
      execute: _migrateToVersion3,
    ),
    4: MigrationStep(
      description: 'Add isArchived column',
      execute: _migrateToVersion4,
    ),
    5: MigrationStep(
      description: 'Ensure isArchived column exists',
      execute: _migrateToVersion5,
    ),
    6: MigrationStep(
      description: 'Add filters table',
      execute: _migrateToVersion6,
    ),
    7: MigrationStep(
      description: 'Add user_apps table',
      execute: _migrateToVersion7,
    ),
    8: MigrationStep(
      description: 'Add type column to user_apps table',
      execute: _migrateToVersion8,
    ),
    9: MigrationStep(
      description: 'Add selectedRevisionId column and app_revisions table',
      execute: _migrateToVersion9,
    ),
    10: MigrationStep(
      description: 'Add attachmentPaths column to user_apps table',
      execute: _migrateToVersion10,
    ),
    11: MigrationStep(
      description: 'Move attachmentPaths from user_apps to app_revisions',
      execute: _migrateToVersion11,
    ),
    12: MigrationStep(
      description: 'Remove AI interactions table',
      execute: _migrateToVersion12,
    ),
    13: MigrationStep(
      description: 'Fix string timestamps in filters table',
      execute: _migrateToVersion13,
    ),
    14: MigrationStep(
      description: 'Add UUID column to user_apps table',
      execute: _migrateToVersion14,
    ),
    15: MigrationStep(
      description: 'Add user app libraries and dependencies tables',
      execute: _migrateToVersion15,
    ),
    16: MigrationStep(
      description: 'Add author and license fields to user_apps table',
      execute: _migrateToVersion16,
    ),
    17: MigrationStep(
      description: 'Add isRelativePath column to attachments table',
      execute: _migrateToVersion17,
    ),
    18: MigrationStep(
      description: 'Add conversation tables for AI chat functionality',
      execute: _migrateToVersion18,
    ),
    19: MigrationStep(
      description: 'Restructure conversation system with message mapping and parent relationships',
      execute: _migrateToVersion19,
    ),
  };

  // Main migration execution method
  Future<void> _executeMigrations(Database db, int oldVersion, int newVersion, {required bool isBackupMigration}) async {
    for (int version = oldVersion + 1; version <= newVersion; version++) {
      final migrationStep = _migrationSteps[version];
      if (migrationStep == null) {
        LoggerService.warning('No migration step defined for version $version');
        continue;
      }

      try {
        LoggerService.info('Executing migration to version $version: ${migrationStep.description}');
        await migrationStep.execute(db, isBackupMigration: isBackupMigration);
        LoggerService.info('Successfully migrated to version $version');
      } catch (e) {
        LoggerService.error('Migration to version $version failed: $e', error: e);
        
        // Apply granular error handling based on the specific migration
        await _handleMigrationError(db, version, e, isBackupMigration: isBackupMigration);
        break; // Stop migration on error
      }
    }
  }

  // Handle migration errors with granular table recreation
  Future<void> _handleMigrationError(Database db, int version, dynamic error, {required bool isBackupMigration}) async {
    switch (version) {
      case 2:
        // Notes table migration failed - recreate notes and related tables
        LoggerService.error('Recreating notes table and related tables due to migration failure');
        await _recreateNotesTables(db, isBackupMigration: isBackupMigration);
        break;
        
      case 3:
      case 4:
      case 5:
        // Notes table column additions failed - recreate notes table
        LoggerService.error('Recreating notes table due to column addition failure');
        await _recreateNotesTable(db, isBackupMigration: isBackupMigration);
        break;
        
      case 6:
        // Filters table creation failed - recreate filters table
        LoggerService.error('Recreating filters table due to creation failure');
        await _recreateFiltersTable(db, isBackupMigration: isBackupMigration);
        break;
        
      case 7:
      case 8:
        // User apps table operations failed - recreate user_apps table
        LoggerService.error('Recreating user_apps table due to operation failure');
        await _recreateUserAppsTable(db, isBackupMigration: isBackupMigration);
        break;
        
      case 9:
        // App revisions table creation failed - recreate app_revisions table
        LoggerService.error('Recreating app_revisions table due to creation failure');
        await _recreateAppRevisionsTable(db, isBackupMigration: isBackupMigration);
        break;
        
      case 10:
      case 11:
      case 14:
        // User apps table modifications failed - recreate user_apps table
        LoggerService.error('Recreating user_apps table due to modification failure');
        await _recreateUserAppsTable(db, isBackupMigration: isBackupMigration);
        break;
        
      case 15:
        // Library tables creation failed - recreate library tables
        LoggerService.error('Recreating library tables due to creation failure');
        await _recreateLibraryTables(db, isBackupMigration: isBackupMigration);
        break;
        
      case 12:
      case 13:
      case 16:
      case 17:
        // These are safe operations - log warning but don't recreate anything
        LoggerService.warning('Migration $version failed but is considered safe - continuing');
        break;
        
      default:
        // Unknown migration - fall back to full database recreation
        LoggerService.error('Unknown migration $version failed - recreating entire database');
        if (isBackupMigration) {
          await _recreateBackupDatabase(db, version);
        } else {
          await _recreateMainDatabase(db, version);
        }
    }
  }

  // Granular table recreation methods
  Future<void> _recreateNotesTables(Database db, {required bool isBackupMigration}) async {
    // Drop notes and related tables
    await db.execute('DROP TABLE IF EXISTS relationships');
    await db.execute('DROP TABLE IF EXISTS attachments');
    await db.execute('DROP TABLE IF EXISTS note_tags');
    await db.execute('DROP TABLE IF EXISTS subnotes');
    await db.execute('DROP TABLE IF EXISTS notes');
    
    // Recreate tables using schema constants
    await db.execute(_createNotesTable);
    await db.execute(_createSubNotesTable);
    await db.execute(_createAttachmentsTable);
    await db.execute(_createRelationshipsTable);
    
    // Recreate relevant indexes
    await db.execute('CREATE INDEX idx_notes_type ON notes(type)');
    await db.execute('CREATE INDEX idx_notes_createdAt ON notes(createdAt)');
    await db.execute('CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)');
    await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
    await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
    await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
    await db.execute('CREATE INDEX idx_relationships_fromNoteId ON relationships(fromNoteId)');
    await db.execute('CREATE INDEX idx_relationships_toNoteId ON relationships(toNoteId)');
  }

  Future<void> _recreateNotesTable(Database db, {required bool isBackupMigration}) async {
    // Drop and recreate only the notes table
    await db.execute('DROP TABLE IF EXISTS notes');
    await db.execute(_createNotesTable);
    
    // Recreate indexes
    await db.execute('CREATE INDEX idx_notes_type ON notes(type)');
    await db.execute('CREATE INDEX idx_notes_createdAt ON notes(createdAt)');
    await db.execute('CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)');
    await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
    await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
    await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
  }

  Future<void> _recreateFiltersTable(Database db, {required bool isBackupMigration}) async {
    await db.execute('DROP TABLE IF EXISTS filters');
    await db.execute(_createFiltersTable);
  }

  Future<void> _recreateUserAppsTable(Database db, {required bool isBackupMigration}) async {
    await db.execute('DROP TABLE IF EXISTS user_apps');
    await db.execute(_createUserAppsTable);
  }

  Future<void> _recreateAppRevisionsTable(Database db, {required bool isBackupMigration}) async {
    await db.execute('DROP TABLE IF EXISTS app_revisions');
    await db.execute(_createAppRevisionsTable);
  }

  Future<void> _recreateLibraryTables(Database db, {required bool isBackupMigration}) async {
    await db.execute('DROP TABLE IF EXISTS user_app_library_dependencies');
    await db.execute('DROP TABLE IF EXISTS user_app_libraries');
    
    await db.execute(_createUserAppLibrariesTable);
    await db.execute(_createUserAppLibraryDependenciesTable);
    
    // Create indexes
    await db.execute('CREATE INDEX idx_user_app_libraries_app_uuid ON user_app_libraries(app_uuid)');
    await db.execute('CREATE INDEX idx_user_app_libraries_revision_id ON user_app_libraries(revision_id)');
    await db.execute('CREATE INDEX idx_user_app_library_dependencies_library_id ON user_app_library_dependencies(library_id)');
    await db.execute('CREATE INDEX idx_user_app_library_dependencies_local_path ON user_app_library_dependencies(local_path)');
  }

  // Recreate main database tables
  Future<void> _recreateMainDatabase(Database db, int newVersion) async {
    // Drop all tables
    await db.execute('DROP TABLE IF EXISTS relationships');
    await db.execute('DROP TABLE IF EXISTS attachments');
    await db.execute('DROP TABLE IF EXISTS note_tags');
    await db.execute('DROP TABLE IF EXISTS subnotes');
    await db.execute('DROP TABLE IF EXISTS notes');
    await db.execute('DROP TABLE IF EXISTS tags');
    await db.execute('DROP TABLE IF EXISTS filters');
    await db.execute('DROP TABLE IF EXISTS user_apps');
    await db.execute('DROP TABLE IF EXISTS app_revisions');
    await db.execute('DROP TABLE IF EXISTS user_app_libraries');
    await db.execute('DROP TABLE IF EXISTS user_app_library_dependencies');
    
    // Recreate all tables using schema constants
    await _onCreate(db, newVersion);
  }

  // Individual migration methods
  static Future<void> _migrateToVersion2(Database db, {required bool isBackupMigration}) async {
      try {
        // Check if dueDate column exists
        final columns = await db.rawQuery("PRAGMA table_info(notes)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (columnNames.contains('dueDate')) {
          // Create a new table with the updated schema
          await db.execute('''
            CREATE TABLE notes_new(
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              content TEXT NOT NULL,
              type TEXT NOT NULL,
              createdAt INTEGER NOT NULL,
              updatedAt INTEGER NOT NULL,
              scheduledAt TEXT,
              completeBy TEXT,
              status TEXT,
              completionPercentage REAL
            )
          ''');
          
          // Copy data from old table to new table, migrating dueDate to completeBy
          await db.execute('''
            INSERT INTO notes_new (id, title, content, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage)
            SELECT id, title, content, type, createdAt, updatedAt, NULL, dueDate, status, completionPercentage
            FROM notes
          ''');
          
          // Drop old table and rename new table
          await db.execute('DROP TABLE notes');
          await db.execute('ALTER TABLE notes_new RENAME TO notes');
          
          // Recreate indexes
          await db.execute('CREATE INDEX idx_notes_type ON notes(type)');
          await db.execute('CREATE INDEX idx_notes_createdAt ON notes(createdAt)');
          await db.execute('CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)');
          await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
        }
      } catch (e) {
      LoggerService.error('Migration to version 2 failed: $e', error: e);
      rethrow; // Let the error handling system deal with it
    }
  }

  static Future<void> _migrateToVersion3(Database db, {required bool isBackupMigration}) async {
      try {
        await db.execute('ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
        await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
      } catch (e) {
        LoggerService.error('Migration to version 3 failed: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion4(Database db, {required bool isBackupMigration}) async {
      try {
        await db.execute('ALTER TABLE notes ADD COLUMN isArchived INTEGER NOT NULL DEFAULT 0');
        await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
      } catch (e) {
        LoggerService.error('Migration to version 4 failed: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion5(Database db, {required bool isBackupMigration}) async {
      try {
        // Check if isArchived column exists
        final columns = await db.rawQuery("PRAGMA table_info(notes)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('isArchived')) {
          await db.execute('ALTER TABLE notes ADD COLUMN isArchived INTEGER NOT NULL DEFAULT 0');
          await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
        }
      } catch (e) {
        LoggerService.error('Migration to version 5 failed: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion6(Database db, {required bool isBackupMigration}) async {
    try {
      await db.execute(_createFiltersTable);
    } catch (e) {
      LoggerService.error('Migration to version 6 failed: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion7(Database db, {required bool isBackupMigration}) async {
    try {
      // Check if user_apps table already exists
      final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='user_apps'");
      if (tables.isEmpty) {
        // Create user_apps table without uuid, author, license columns (will be added in later migrations)
        await db.execute('''
          CREATE TABLE user_apps(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            steps TEXT NOT NULL,
            htmlContent TEXT NOT NULL,
            appState TEXT,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL
          )
        ''');
      }
    } catch (e) {
      LoggerService.error('Migration to version 7 failed: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion8(Database db, {required bool isBackupMigration}) async {
        // Check if type column exists in user_apps table
        final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('type')) {
          await db.execute('ALTER TABLE user_apps ADD COLUMN type TEXT NOT NULL DEFAULT "normal"');
    }
  }

  static Future<void> _migrateToVersion9(Database db, {required bool isBackupMigration}) async {
    // Add selectedRevisionId column to user_apps table
    final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
    final columnNames = columns.map((col) => col['name'] as String).toList();
    
    if (!columnNames.contains('selectedRevisionId')) {
      await db.execute('ALTER TABLE user_apps ADD COLUMN selectedRevisionId TEXT');
    }
    
    // Create app_revisions table (without attachmentPaths column - will be added in later migration)
    await db.execute('''
      CREATE TABLE app_revisions(
        id TEXT PRIMARY KEY,
        appId TEXT NOT NULL,
        revisionNumber INTEGER NOT NULL,
        revisionTimestamp INTEGER NOT NULL,
        userPrompt TEXT NOT NULL,
        aiResponse TEXT NOT NULL,
        appCode TEXT NOT NULL,
        FOREIGN KEY (appId) REFERENCES user_apps (id) ON DELETE CASCADE
      )
    ''');
    
    // Migrate existing apps to have initial revisions
    await DatabaseService._migrateExistingAppsToRevisions(db);
  }
    
  static Future<void> _migrateToVersion10(Database db, {required bool isBackupMigration}) async {
        // Check if attachmentPaths column exists in user_apps table
        final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('attachmentPaths')) {
          await db.execute('ALTER TABLE user_apps ADD COLUMN attachmentPaths TEXT');
      }
    }
    
  static Future<void> _migrateToVersion11(Database db, {required bool isBackupMigration}) async {
        // Add attachmentPaths column to app_revisions table
        final columns = await db.rawQuery("PRAGMA table_info(app_revisions)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('attachmentPaths')) {
          await db.execute('ALTER TABLE app_revisions ADD COLUMN attachmentPaths TEXT');
        }
        
        // Remove attachmentPaths column from user_apps table if it exists
        final userAppColumns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final userAppColumnNames = userAppColumns.map((col) => col['name'] as String).toList();
        
        if (userAppColumnNames.contains('attachmentPaths')) {
          // SQLite doesn't support DROP COLUMN, so we need to recreate the table
          await db.execute('''
            CREATE TABLE user_apps_new(
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              description TEXT NOT NULL,
              steps TEXT NOT NULL,
              htmlContent TEXT NOT NULL,
              appState TEXT,
              type TEXT NOT NULL DEFAULT 'normal',
              selectedRevisionId TEXT,
              createdAt INTEGER NOT NULL,
              updatedAt INTEGER NOT NULL
            )
          ''');
          
          await db.execute('''
            INSERT INTO user_apps_new 
            SELECT id, name, description, steps, htmlContent, appState, type, selectedRevisionId, createdAt, updatedAt 
            FROM user_apps
          ''');
          
          await db.execute('DROP TABLE user_apps');
          await db.execute('ALTER TABLE user_apps_new RENAME TO user_apps');
      }
    }
    
  static Future<void> _migrateToVersion12(Database db, {required bool isBackupMigration}) async {
        // Check if ai_interactions table exists and drop it
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='ai_interactions'"
        );
        
        if (tables.isNotEmpty) {
          await db.execute('DROP TABLE IF EXISTS ai_interactions');
          LoggerService.info('Dropped ai_interactions table');
      }
    }
    
  static Future<void> _migrateToVersion13(Database db, {required bool isBackupMigration}) async {
        // Check if filters table exists
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='filters'"
        );
        
        if (tables.isNotEmpty) {
          // Find records with string timestamps and fix them
          final corruptedRecords = await db.rawQuery(
            "SELECT id, createdAt, updatedAt FROM filters WHERE typeof(createdAt) = 'text' OR typeof(updatedAt) = 'text'"
          );
          
          if (corruptedRecords.isNotEmpty) {
            LoggerService.warning('Found ${corruptedRecords.length} filter records with string timestamps, fixing...');
            
            for (final record in corruptedRecords) {
              final id = record['id'] as String;
              final now = DateTime.now().millisecondsSinceEpoch;
              
              // Update with current timestamp as fallback
              await db.execute(
                'UPDATE filters SET createdAt = ?, updatedAt = ? WHERE id = ?',
                [now, now, id]
              );
            }
            
            LoggerService.info('Fixed ${corruptedRecords.length} filter records with corrupted timestamps');
          }
      }
    }
    
  static Future<void> _migrateToVersion14(Database db, {required bool isBackupMigration}) async {
        // Check if uuid column exists in user_apps table
        final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('uuid')) {
          // Add uuid column
          await db.execute('ALTER TABLE user_apps ADD COLUMN uuid TEXT');
          
          // Generate UUIDs for existing records that have null uuid
      if (isBackupMigration) {
        // Simplified UUID generation for backup migration
        final apps = await db.query('user_apps', where: 'uuid IS NULL');
        for (final app in apps) {
          final uuid = DateTime.now().millisecondsSinceEpoch.toString();
          await db.update('user_apps', {'uuid': uuid}, where: 'id = ?', whereArgs: [app['id']]);
        }
      } else {
        // Use proper UUID generation for main migration
        await DatabaseService._migrateUserAppsWithUuid(db);
      }
    }
  }

  static Future<void> _migrateToVersion15(Database db, {required bool isBackupMigration}) async {
    // Create User App Libraries table
    await db.execute(_createUserAppLibrariesTable);

    // Create User App Library Dependencies table
    await db.execute(_createUserAppLibraryDependenciesTable);
    
    // Create indexes for better performance
    await db.execute('CREATE INDEX idx_user_app_libraries_app_uuid ON user_app_libraries(app_uuid)');
    await db.execute('CREATE INDEX idx_user_app_libraries_revision_id ON user_app_libraries(revision_id)');
    await db.execute('CREATE INDEX idx_user_app_library_dependencies_library_id ON user_app_library_dependencies(library_id)');
    await db.execute('CREATE INDEX idx_user_app_library_dependencies_local_path ON user_app_library_dependencies(local_path)');
    
    LoggerService.info('Migration to version 15 completed: Added user app libraries and dependencies tables');
  }
    
  static Future<void> _migrateToVersion16(Database db, {required bool isBackupMigration}) async {
        // Add author and license columns to user_apps table
        await db.execute('ALTER TABLE user_apps ADD COLUMN author TEXT DEFAULT ""');
        await db.execute('ALTER TABLE user_apps ADD COLUMN license TEXT DEFAULT ""');
        
        LoggerService.info('Migration to version 16 completed: Added author and license fields to user_apps table');
    }
    
  static Future<void> _migrateToVersion17(Database db, {required bool isBackupMigration}) async {
        // Add isRelativePath column to attachments table
        await db.execute('ALTER TABLE attachments ADD COLUMN isRelativePath INTEGER NOT NULL DEFAULT 0');
        
        LoggerService.info('Migration to version 17 completed: Added isRelativePath column to attachments table');
  }

  static Future<void> _migrateToVersion18(Database db, {required bool isBackupMigration}) async {
        // Create conversation tables
        await db.execute(_createConversationsTable);
        await db.execute(_createConversationMessagesTable);
        await db.execute(_createConversationAttachmentsTable);
        await db.execute(_createConversationTreeTable);
        
        // Create indexes for conversation tables
        await db.execute('CREATE INDEX idx_conversations_parentConversationId ON conversations(parentConversationId)');
        await db.execute('CREATE INDEX idx_conversations_createdAt ON conversations(createdAt)');
        await db.execute('CREATE INDEX idx_conversations_isArchived ON conversations(isArchived)');
        await db.execute('CREATE INDEX idx_conversation_messages_conversationId ON conversation_messages(conversationId)');
        await db.execute('CREATE INDEX idx_conversation_messages_timestamp ON conversation_messages(timestamp)');
        await db.execute('CREATE INDEX idx_conversation_attachments_messageId ON conversation_attachments(messageId)');
        
        LoggerService.info('Migration to version 18 completed: Added conversation tables for AI chat functionality');
  }

  static Future<void> _migrateToVersion19(Database db, {required bool isBackupMigration}) async {
        LoggerService.info('Starting migration to version 19: Restructuring conversation system');
        
        // Create new tables
        await db.execute(_createConversationMessageMappingTable);
        await db.execute(_createMessageParentsTable);
        
        // Create indexes for new tables
        await db.execute('CREATE INDEX idx_conversation_message_mapping_conversationId ON conversation_message_mapping(conversationId)');
        await db.execute('CREATE INDEX idx_conversation_message_mapping_messageId ON conversation_message_mapping(messageId)');
        await db.execute('CREATE INDEX idx_message_parents_messageId ON message_parents(messageId)');
        await db.execute('CREATE INDEX idx_message_parents_parentMessageId ON message_parents(parentMessageId)');
        
        // Migrate existing data
        await _migrateExistingConversationData(db);
        
        // Clear old tree data to force rebuild
        await db.delete('conversation_tree');
        
        LoggerService.info('Migration to version 19 completed: Restructured conversation system');
  }

  // Migrate existing conversation data to new structure
  static Future<void> _migrateExistingConversationData(Database db) async {
        LoggerService.info('Migrating existing conversation data to new structure');
        
        // Get all existing conversations
        final conversations = await db.query('conversations');
        LoggerService.info('Found ${conversations.length} conversations to migrate');
        
        for (final conversation in conversations) {
          final conversationId = conversation['id'] as String;
          
          // Get messages for this conversation
          final messages = await db.query(
            'conversation_messages',
            where: 'conversationId = ?',
            whereArgs: [conversationId],
            orderBy: 'timestamp ASC',
          );
          
          LoggerService.info('Migrating conversation $conversationId with ${messages.length} messages');
          
          // Create message mappings and parent relationships
          String? previousMessageId;
          for (int i = 0; i < messages.length; i++) {
            final message = messages[i];
            final messageId = message['id'] as String;
            
            // Create conversation-message mapping
            await db.insert('conversation_message_mapping', {
              'conversationId': conversationId,
              'messageId': messageId,
              'createdAt': DateTime.now().millisecondsSinceEpoch,
            });
            
            // Create parent relationship (except for first message)
            if (previousMessageId != null) {
              await db.insert('message_parents', {
                'id': '${messageId}_${previousMessageId}',
                'messageId': messageId,
                'parentMessageId': previousMessageId,
                'createdAt': DateTime.now().millisecondsSinceEpoch,
              });
            }
            
            previousMessageId = messageId;
          }
        }
        
        LoggerService.info('Completed migration of existing conversation data');
  }


  // Migration helper method to create initial revisions for existing apps
  static Future<void> _migrateExistingAppsToRevisions(Database db) async {
    try {
      LoggerService.info('Starting migration of existing apps to revisions...');
      
      // Get all existing apps
      final apps = await db.query('user_apps');
      LoggerService.info('Found ${apps.length} existing apps to migrate');
      
      for (final appMap in apps) {
        final appId = appMap['id'] as String;
        final appName = appMap['name'] as String;
        final htmlContent = appMap['htmlContent'] as String;
        
        // Check if this app already has revisions
        final existingRevisions = await db.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: [appId],
        );
        
        if (existingRevisions.isNotEmpty) {
          LoggerService.debug('App $appId already has revisions, skipping...');
          continue;
        }
        
        // Create initial revision for this app
        final revisionId = '${appId}_rev_1';
        final revisionTimestamp = DateTime.now().millisecondsSinceEpoch;
        
        final revisionData = {
          'id': revisionId,
          'appId': appId,
          'revisionNumber': 1,
          'revisionTimestamp': revisionTimestamp,
          'userPrompt': 'Initial app creation',
          'aiResponse': 'This is the initial version of the app created during migration.',
          'appCode': htmlContent,
        };
        
        // Insert the revision
        await db.insert('app_revisions', revisionData);
        
        // Update the app to set the selected revision
        await db.update(
          'user_apps',
          {'selectedRevisionId': revisionId},
          where: 'id = ?',
          whereArgs: [appId],
        );
        
        LoggerService.debug('Created initial revision for app: $appName (ID: $appId)');
      }
      
      LoggerService.info('Migration of existing apps to revisions completed successfully');
    } catch (e) {
      LoggerService.error('Error during migration of existing apps to revisions: $e', error: e);
      // Don't rethrow - this is a migration helper, we don't want to break the entire migration
    }
  }

  // Migration helper method to add UUIDs to existing user apps
  static Future<void> _migrateUserAppsWithUuid(Database db) async {
    try {
      LoggerService.info('Starting migration of user apps with UUID...');
      
      // Get all existing apps that don't have a UUID
      final apps = await db.query('user_apps', where: 'uuid IS NULL');
      LoggerService.info('Found ${apps.length} user apps without UUID to migrate');
      
      for (final appMap in apps) {
        final appId = appMap['id'] as String;
        final appName = appMap['name'] as String;
        
        // Generate a new UUID
        final uuid = const Uuid().v4();
        
        // Update the app with the new UUID
        await db.update(
          'user_apps',
          {'uuid': uuid},
          where: 'id = ?',
          whereArgs: [appId],
        );
        
        LoggerService.debug('Added UUID $uuid to app: $appName (ID: $appId)');
      }
      
      LoggerService.info('Migration of user apps with UUID completed successfully');
    } catch (e) {
      LoggerService.error('Error during migration of user apps with UUID: $e', error: e);
      // Don't rethrow - this is a migration helper, we don't want to break the entire migration
    }
  }

  // Notes CRUD
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
      final isRelativePath = attachmentPath.startsWith('attachments/');
      await _insertAttachment(note.id, attachmentPath, isRelativePath: isRelativePath);
    }

    return note.id;
  }

  Future<List<Note>> getAllNotes() async {
    final db = await database;
    LoggerService.info('Querying notes table...');
    final List<Map<String, dynamic>> maps = await db.query(
      'notes',
      orderBy: 'pinned DESC, createdAt DESC',
    );
    LoggerService.info('Found ${maps.length} notes in database');

    final List<Note> notes = [];
    for (final map in maps) {
      try {
        LoggerService.info('Mapping note with id: ${map['id']}');
        final note = await _mapToNote(map);
        notes.add(note);
      } catch (e) {
        LoggerService.error('Error mapping note with id ${map['id']}: $e', error: e);
        LoggerService.error('Note data: $map');
        // Skip corrupted notes instead of crashing
        continue;
      }
    }
    LoggerService.info('Successfully mapped ${notes.length} notes');
    return notes;
  }

  // Validate that all note IDs in a conversation exist
  Future<List<String>> validateConversationNotes(String conversationId) async {
    final conversation = await getConversation(conversationId);
    if (conversation == null) return [];
    
    final allNotes = await getAllNotes();
    final existingNoteIds = allNotes.map((note) => note.id).toSet();
    
    // Find missing note IDs
    final missingNoteIds = conversation.noteIds.where((noteId) => !existingNoteIds.contains(noteId)).toList();
    
    if (missingNoteIds.isNotEmpty) {
      LoggerService.warning('Conversation $conversationId references missing notes: $missingNoteIds');
    }
    
    return missingNoteIds;
  }

  // Clean up invalid note references from conversations
  Future<void> cleanupInvalidNoteReferences() async {
    final db = await database;
    final allNotes = await getAllNotes();
    final existingNoteIds = allNotes.map((note) => note.id).toSet();
    
    // Get all conversations
    final conversations = await getAllConversations();
    
    for (final conversation in conversations) {
      final validNoteIds = conversation.noteIds.where((noteId) => existingNoteIds.contains(noteId)).toList();
      
      if (validNoteIds.length != conversation.noteIds.length) {
        LoggerService.info('Cleaning up invalid note references for conversation ${conversation.id}');
        
        // Update conversation with only valid note IDs
        final updatedConversation = conversation.copyWith(noteIds: validNoteIds);
        await updateConversation(updatedConversation);
      }
    }
  }

  Future<List<Note>> getNotesByArchiveStatus({bool? isArchived}) async {
    final db = await database;
    String whereClause = '';
    List<dynamic> whereArgs = [];
    
    if (isArchived != null) {
      whereClause = 'isArchived = ?';
      whereArgs.add(isArchived ? 1 : 0);
    }
    
    final List<Map<String, dynamic>> maps = await db.query(
      'notes',
      where: whereClause.isEmpty ? null : whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'pinned DESC, createdAt DESC',
    );

    final List<Note> notes = [];
    for (final map in maps) {
      try {
        final note = await _mapToNote(map);
        notes.add(note);
      } catch (e) {
        LoggerService.error('Error mapping note with id ${map['id']}: $e', error: e);
        // Skip corrupted notes instead of crashing
        continue;
      }
    }
    return notes;
  }

  Future<List<Note>> getPinnedNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'notes',
      where: 'pinned = ? AND isArchived = ?',
      whereArgs: [1, 0],
      orderBy: 'createdAt DESC',
    );

    final List<Note> notes = [];
    for (final map in maps) {
      try {
        final note = await _mapToNote(map);
        notes.add(note);
      } catch (e) {
        LoggerService.error('Error mapping note with id ${map['id']}: $e', error: e);
        // Skip corrupted notes instead of crashing
        continue;
      }
    }
    return notes;
  }

  Future<List<Note>> getArchivedNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'notes',
      where: 'isArchived = ?',
      whereArgs: [1],
      orderBy: 'createdAt DESC',
    );

    final List<Note> notes = [];
    for (final map in maps) {
      try {
        final note = await _mapToNote(map);
        notes.add(note);
      } catch (e) {
        LoggerService.error('Error mapping note with id ${map['id']}: $e', error: e);
        // Skip corrupted notes instead of crashing
        continue;
      }
    }
    return notes;
  }

  Future<Note?> getNote(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'notes',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return await _mapToNote(maps.first);
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
    
    await db.update(
      'notes',
      json,
      where: 'id = ?',
      whereArgs: [note.id],
    );

    // Update subnotes
    await db.delete('subnotes', where: 'noteId = ?', whereArgs: [note.id]);
    for (final subNote in note.subNotes) {
      await insertSubNote(subNote, note.id);
    }

    // Update tags
    await db.delete('note_tags', where: 'noteId = ?', whereArgs: [note.id]);
    for (final tagName in note.tags) {
      await _linkNoteToTag(note.id, tagName);
    }

    // Update attachments
    await db.delete('attachments', where: 'noteId = ?', whereArgs: [note.id]);
    for (final attachmentPath in note.attachmentPaths) {
      // Check if path is relative (starts with 'attachments/')
      final isRelativePath = attachmentPath.startsWith('attachments/');
      await _insertAttachment(note.id, attachmentPath, isRelativePath: isRelativePath);
    }
  }

  Future<void> deleteNote(String id) async {
    final db = await database;
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
    final List<Map<String, dynamic>> maps = await db.query(
      'subnotes',
      where: 'noteId = ?',
      whereArgs: [noteId],
      orderBy: 'createdAt ASC',
    );

    return List.generate(maps.length, (i) {
      return SubNote(
        id: maps[i]['id'],
        name: maps[i]['name'],
        content: maps[i]['content'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
        isCompleted: maps[i]['isCompleted'] == 1,
      );
    });
  }

  // Tags CRUD
  Future<String> insertTag(Tag tag) async {
    final db = await database;
    final json = tag.toJson();
    json['createdAt'] = tag.createdAt.millisecondsSinceEpoch;
    await db.insert('tags', json);
    return tag.id;
  }

  Future<List<Tag>> getAllTags() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'tags',
      orderBy: 'usageCount DESC, name ASC',
    );

    return List.generate(maps.length, (i) {
      return Tag(
        id: maps[i]['id'],
        name: maps[i]['name'],
        color: maps[i]['color'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
        usageCount: maps[i]['usageCount'] ?? 0,
      );
    });
  }

  Future<int> getTagUsageCount(String tagName) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM note_tags nt
      JOIN tags t ON nt.tagId = t.id
      WHERE t.name = ?
    ''', [tagName]);
    
    return maps.first['count'] as int;
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
    
    // Delete the tag itself
    await db.delete('tags', where: 'id = ?', whereArgs: [tagId]);
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
      // Create new tag
      final newTag = Tag(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: newTagName,
        color: oldTagMaps.first['color'] as String, // Use same color as old tag
        createdAt: DateTime.now(),
      );
      newTagId = await insertTag(newTag);
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
    for (final noteTagMap in noteTagMaps) {
      final noteId = noteTagMap['noteId'] as String;
      
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
        });
      }
    }
    
    // Delete all old tag relationships
    await db.delete('note_tags', where: 'tagId = ?', whereArgs: [oldTagId]);
    
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
    await db.delete('relationships', where: 'id = ?', whereArgs: [relationshipId]);
  }

  Future<void> deleteRelationshipsForNote(String noteId) async {
    final db = await database;
    await db.delete('relationships', where: 'fromNoteId = ? OR toNoteId = ?', whereArgs: [noteId, noteId]);
  }

  Future<bool> relationshipExists(String fromNoteId, String toNoteId, String type) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'fromNoteId = ? AND toNoteId = ? AND type = ?',
      whereArgs: [fromNoteId, toNoteId, type],
    );
    return maps.isNotEmpty;
  }


  // Helper methods
  DateTime _validateTimestamp(dynamic timestamp, String fieldName, String recordId) {
    if (timestamp is int) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else if (timestamp is String) {
      // This indicates a schema violation - string timestamps should not exist
      LoggerService.error(
        'Database schema violation: $fieldName field contains string timestamp in record $recordId',
        error: 'Expected integer timestamp, got string: $timestamp'
      );
      throw FormatException(
        'Database schema violation: $fieldName field should contain integer timestamp, but contains string: $timestamp'
      );
    } else {
      LoggerService.error(
        'Database schema violation: $fieldName field has invalid type in record $recordId',
        error: 'Expected integer timestamp, got ${timestamp.runtimeType}: $timestamp'
      );
      throw FormatException(
        'Database schema violation: $fieldName field should contain integer timestamp, but got ${timestamp.runtimeType}: $timestamp'
      );
    }
  }

  Future<Note> _mapToNote(Map<String, dynamic> map) async {
    final subNotes = await getSubNotes(map['id']);
    final tags = await _getNoteTags(map['id']);
    final attachments = await _getNoteAttachments(map['id']);

    return Note(
      id: map['id'],
      title: map['title'],
      content: map['content'],
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
      status: map['status'] != null
          ? _stringToTaskStatus(map['status'])
          : null,
      completionPercentage: map['completionPercentage'],
      pinned: (map['pinned'] ?? 0) == 1,
      isArchived: (map['isArchived'] ?? 0) == 1,
    );
  }

  Future<List<String>> _getNoteTags(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT t.name 
      FROM tags t 
      JOIN note_tags nt ON t.id = nt.tagId 
      WHERE nt.noteId = ?
    ''', [noteId]);

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
      // Convert absolute path to relative path for database lookup
      final fileName = attachmentPath.split('/').last;
      final relativePath = 'attachments/$fileName';
      
      final List<Map<String, dynamic>> maps = await db.query(
        'attachments',
        where: 'filePath = ?',
        whereArgs: [relativePath],
      );
      
      return maps.isNotEmpty;
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

  Future<void> _linkNoteToTag(String noteId, String tagName) async {
    final db = await database;
    
    // Check if tag exists, create if not
    final tagMaps = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [tagName],
    );

    String tagId;
    if (tagMaps.isEmpty) {
      // Create new tag
      final tag = Tag(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: tagName,
        color: '#2196F3', // Default blue color
        createdAt: DateTime.now(),
      );
      tagId = await insertTag(tag);
    } else {
      tagId = tagMaps.first['id'] as String;
      // Increment usage count
      await db.rawUpdate(
        'UPDATE tags SET usageCount = usageCount + 1 WHERE id = ?',
        [tagId],
      );
    }

    // Link note to tag
    await db.insert('note_tags', {
      'noteId': noteId,
      'tagId': tagId,
    });
  }

  Future<void> _insertAttachment(String noteId, String filePath, {bool isRelativePath = false}) async {
    final db = await database;
    final fileName = filePath.split('/').last;
    final fileType = FileTypeUtils.getFileExtension(fileName);
    
    await db.insert('attachments', {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'noteId': noteId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
      'isRelativePath': isRelativePath ? 1 : 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
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
    return join(await getDatabasesPath(), 'note_synapse.db');
  }

  // Force database checkpoint
  Future<void> checkpoint() async {
    final db = await database;
    await db.rawQuery('PRAGMA wal_checkpoint(FULL);');
  }

  // Migrate a backup database to current version
  Future<void> migrateBackupDatabase(Database db, int oldVersion, int newVersion) async {
    LoggerService.info('Migrating backup database from version $oldVersion to $newVersion');
    await _executeMigrations(db, oldVersion, newVersion, isBackupMigration: true);
  }

  Future<void> _createBackupDatabaseTables(Database db, int version) async {
    // Create all tables using schema constants (same as main database)
    await _onCreate(db, version);
  }

  Future<void> _recreateBackupDatabase(Database db, int newVersion) async {
    // Drop all tables and recreate using schema constants
    await db.execute('DROP TABLE IF EXISTS relationships');
    await db.execute('DROP TABLE IF EXISTS attachments');
    await db.execute('DROP TABLE IF EXISTS note_tags');
    await db.execute('DROP TABLE IF EXISTS subnotes');
    await db.execute('DROP TABLE IF EXISTS notes');
    await db.execute('DROP TABLE IF EXISTS tags');
    await db.execute('DROP TABLE IF EXISTS filters');
    await db.execute('DROP TABLE IF EXISTS user_apps');
    await db.execute('DROP TABLE IF EXISTS app_revisions');
    await db.execute('DROP TABLE IF EXISTS user_app_libraries');
    await db.execute('DROP TABLE IF EXISTS user_app_library_dependencies');
    
    await _createBackupDatabaseTables(db, newVersion);
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
    await db.delete('conversation_tree');
    await db.delete('conversation_messages');
    await db.delete('conversation_attachments');
    await db.delete('conversations');
  }

  // Utility methods
  Future<void> close() async {
    final db = await database;
    await db.close();
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
      'includeArchived': filter.includeArchived ? 1 : 0,
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
      final includeTags = includeTagsString.isEmpty ? <String>[] : includeTagsString.split(',');
      
      return Filter(
        id: maps[i]['id'],
        name: maps[i]['name'],
        includeText: maps[i]['includeText'],
        includeTags: includeTags,
        includeArchived: (maps[i]['includeArchived'] ?? 0) == 1,
        createdAt: _validateTimestamp(maps[i]['createdAt'], 'createdAt', maps[i]['id']),
        updatedAt: _validateTimestamp(maps[i]['updatedAt'], 'updatedAt', maps[i]['id']),
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
    final includeTags = includeTagsString.isEmpty ? <String>[] : includeTagsString.split(',');
    
    return Filter(
      id: map['id'],
      name: map['name'],
      includeText: map['includeText'],
      includeTags: includeTags,
      includeArchived: (map['includeArchived'] ?? 0) == 1,
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
      'includeArchived': filter.includeArchived ? 1 : 0,
      'createdAt': filter.createdAt.millisecondsSinceEpoch,
      'updatedAt': filter.updatedAt.millisecondsSinceEpoch,
    };
    
    await db.update(
      'filters',
      json,
      where: 'id = ?',
      whereArgs: [filter.id],
    );
  }

  Future<void> deleteFilter(String id) async {
    final db = await database;
    await db.delete('filters', where: 'id = ?', whereArgs: [id]);
  }

  // Execute raw SQL query for user apps
  Future<List<Map<String, dynamic>>> executeRawQuery(String sql) async {
    final db = await database;
    try {
      // Basic security check - only allow SELECT queries
      final trimmedSql = sql.trim().toLowerCase();
      if (!trimmedSql.startsWith('select')) {
        throw Exception('Only SELECT queries are allowed');
      }
      
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
    
    LoggerService.debug('DatabaseService.insertUserApp: Inserting app ${app.id} - ${app.name}');
    await db.insert('user_apps', json);
    LoggerService.debug('DatabaseService.insertUserApp: Successfully inserted app ${app.id}');
    return app.id;
  }

  Future<List<UserApp>> getAllUserApps() async {
    final db = await database;
    final maps = await db.query('user_apps', orderBy: 'createdAt DESC');
    LoggerService.debug('DatabaseService.getAllUserApps: Found ${maps.length} user apps');
    return maps.map((map) => _userAppFromMap(map)).toList();
  }

  Future<UserApp?> getUserApp(String id) async {
    final db = await database;
    final maps = await db.query('user_apps', where: 'id = ?', whereArgs: [id]);
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
      'appState': app.appState != null ? jsonEncode(app.appState) : null,
      'type': app.type.toString().split('.').last, // Store enum as string
      'selectedRevisionId': app.selectedRevisionId,
      'author': app.author,
      'license': app.license,
      'createdAt': app.createdAt.millisecondsSinceEpoch,
      'updatedAt': app.updatedAt.millisecondsSinceEpoch,
    };
    
    await db.update('user_apps', json, where: 'id = ?', whereArgs: [app.id]);
  }

  Future<void> deleteUserApp(String id) async {
    final db = await database;
    
    // Get the app to find its UUID for library deletion
    final app = await getUserApp(id);
    if (app == null) return;
    
    // Delete app libraries and their dependencies first
    // (foreign key constraints will handle cascade deletion)
    await db.delete('user_app_libraries', where: 'app_uuid = ?', whereArgs: [app.uuid]);
    
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
    final maps = await db.query(
      'user_apps',
      columns: ['appState'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty && maps.first['appState'] != null) {
      return jsonDecode(maps.first['appState'] as String) as Map<String, dynamic>;
    }
    return null;
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
      uuid: map['uuid'] as String? ?? const Uuid().v4(), // Generate UUID if missing for backward compatibility
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
      'attachmentPaths': revision.attachmentPaths.join('|'), // Store attachment paths as pipe-separated string
    };
    
    LoggerService.debug('DatabaseService.insertAppRevision: Inserting revision ${revision.id} for app ${revision.appId}');
    await db.insert('app_revisions', json);
    LoggerService.debug('DatabaseService.insertAppRevision: Successfully inserted revision ${revision.id}');
    return revision.id;
  }

  Future<List<AppRevision>> getAppRevisions(String appId) async {
    final db = await database;
    final maps = await db.query(
      'app_revisions', 
      where: 'appId = ?', 
      whereArgs: [appId],
      orderBy: 'revisionNumber ASC',
    );
    LoggerService.debug('DatabaseService.getAppRevisions: Found ${maps.length} revisions for app $appId');
    if (maps.isNotEmpty) {
      LoggerService.debug('First revision data: ${maps.first}');
    }
    final revisions = maps.map((map) => _appRevisionFromMap(map)).toList();
    if (revisions.isNotEmpty) {
      LoggerService.debug('First revision appCode length: ${revisions.first.appCode.length}');
    }
    return revisions;
  }

  Future<AppRevision?> getAppRevision(String id) async {
    final db = await database;
    final maps = await db.query('app_revisions', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) {
      return _appRevisionFromMap(maps.first);
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
      throw Exception('Cannot delete the only remaining revision. At least one revision must exist.');
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
        remainingRevisions.sort((a, b) => b.revisionNumber.compareTo(a.revisionNumber));
        final newPinnedRevision = remainingRevisions.first;
        
        // Update the app's selectedRevisionId
        final updatedApp = app.copyWith(selectedRevisionId: newPinnedRevision.id);
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
      'SELECT * FROM app_revisions WHERE appId = ? ORDER BY revisionNumber DESC LIMIT 1',
      [appId],
    );
    if (result.isNotEmpty) {
      return _appRevisionFromMap(result.first);
    }
    return null;
  }

  AppRevision _appRevisionFromMap(Map<String, dynamic> map) {
    final revision = AppRevision(
      id: map['id'] as String,
      appId: map['appId'] as String,
      revisionNumber: map['revisionNumber'] as int,
      revisionTimestamp: DateTime.fromMillisecondsSinceEpoch(map['revisionTimestamp'] as int),
      userPrompt: map['userPrompt'] as String,
      aiResponse: map['aiResponse'] as String,
      appCode: map['appCode'] as String,
      attachmentPaths: map['attachmentPaths'] != null 
          ? (map['attachmentPaths'] as String).split('|').where((path) => path.isNotEmpty).toList()
          : [],
    );
    LoggerService.debug('_appRevisionFromMap: Created revision ${revision.id} with appCode length: ${revision.appCode.length}');
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

  Future<List<Map<String, dynamic>>> getUserAppLibraries(String appUuid, int revisionId) async {
    final db = await database;
    return await db.query(
      'user_app_libraries',
      where: 'app_uuid = ? AND revision_id = ?',
      whereArgs: [appUuid, revisionId],
    );
  }

  Future<void> deleteUserAppLibrary(int libraryId) async {
    final db = await database;
    await db.delete('user_app_libraries', where: 'id = ?', whereArgs: [libraryId]);
  }

  Future<void> deleteUserAppLibrariesForRevision(int revisionId) async {
    final db = await database;
    await db.delete('user_app_libraries', where: 'revision_id = ?', whereArgs: [revisionId]);
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

  Future<List<Map<String, dynamic>>> getUserAppLibraryDependencies(int libraryId) async {
    final db = await database;
    
    // Use raw query with chunked BLOB reading to avoid cursor window issues
    final results = await db.rawQuery('''
      SELECT id, original_url, local_path, library_id,
             CASE 
               WHEN length(bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL 
             END as has_blob
      FROM user_app_library_dependencies 
      WHERE library_id = ?
    ''', [libraryId]);
    
    final List<Map<String, dynamic>> processedResults = [];
    for (final map in results) {
      final newMap = Map<String, dynamic>.from(map);
      
      // Read BLOB data in chunks to avoid cursor window issues
      if (map['has_blob'] != null) {
        try {
          final blobData = await _readBlobInChunks(db, map['id'] as int);
          newMap['bytes'] = blobData;
        } catch (e) {
          LoggerService.error('Failed to read BLOB data for dependency ${map['id']}: $e', error: e);
          newMap['bytes'] = <int>[];
        }
      } else {
        newMap['bytes'] = <int>[];
      }
      
      processedResults.add(newMap);
    }
    
    return processedResults;
  }

  Future<Map<String, dynamic>?> getUserAppLibraryDependencyByPath(String localPath) async {
    final db = await database;
    
    // Use raw query to avoid cursor window issues
    final results = await db.rawQuery('''
      SELECT id, original_url, local_path, library_id,
             CASE 
               WHEN length(bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL 
             END as has_blob
      FROM user_app_library_dependencies 
      WHERE local_path = ?
    ''', [localPath]);
    
    if (results.isNotEmpty) {
      final result = Map<String, dynamic>.from(results.first);
      
      // Read BLOB data in chunks to avoid cursor window issues
      if (result['has_blob'] != null) {
        try {
          final blobData = await _readBlobInChunks(db, result['id'] as int);
          result['bytes'] = blobData;
        } catch (e) {
          LoggerService.error('Failed to read BLOB data for dependency ${result['id']}: $e', error: e);
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
    await db.delete('user_app_library_dependencies', where: 'id = ?', whereArgs: [dependencyId]);
  }

  // Get dependency by app UUID, revision ID, and local path
  Future<Map<String, dynamic>?> getDependencyByAppAndPath(String appUuid, int revisionId, String localPath) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT d.id, d.original_url, d.local_path, d.library_id,
             CASE 
               WHEN length(d.bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL 
             END as has_blob
      FROM user_app_library_dependencies d
      JOIN user_app_libraries l ON d.library_id = l.id
      WHERE l.app_uuid = ? AND l.revision_id = ? AND d.local_path = ?
    ''', [appUuid, revisionId, localPath]);
    
    if (results.isNotEmpty) {
      final result = Map<String, dynamic>.from(results.first);
      
      // Read BLOB data in chunks to avoid cursor window issues
      if (result['has_blob'] != null) {
        try {
          final blobData = await _readBlobInChunks(db, result['id'] as int);
          result['bytes'] = blobData;
        } catch (e) {
          LoggerService.error('Failed to read BLOB data for dependency ${result['id']}: $e', error: e);
          result['bytes'] = <int>[];
        }
      } else {
        result['bytes'] = <int>[];
      }
      
      return result;
    }
    return null;
  }

  // Helper method to read BLOB data in chunks to avoid cursor window issues
  Future<List<int>> _readBlobInChunks(Database db, int dependencyId) async {
    const int chunkSize = 1024 * 1024; // 1MB chunks
    final List<int> allBytes = [];
    
    try {
      // Get the total size of the BLOB
      final sizeResult = await db.rawQuery('''
        SELECT length(bytes) as blob_size 
        FROM user_app_library_dependencies 
        WHERE id = ?
      ''', [dependencyId]);
      
      if (sizeResult.isEmpty) {
        return <int>[];
      }
      
      final int totalSize = sizeResult.first['blob_size'] as int;
      
      // Read BLOB in chunks
      for (int offset = 0; offset < totalSize; offset += chunkSize) {
        final int currentChunkSize = (offset + chunkSize > totalSize) 
            ? totalSize - offset 
            : chunkSize;
            
        final chunkResult = await db.rawQuery('''
          SELECT substr(bytes, ?, ?) as chunk
          FROM user_app_library_dependencies 
          WHERE id = ?
        ''', [offset + 1, currentChunkSize, dependencyId]);
        
        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as Uint8List;
          allBytes.addAll(chunk);
        }
      }
      
      return allBytes;
    } catch (e) {
      LoggerService.error('Error reading BLOB in chunks: $e', error: e);
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
    json['noteIds'] = jsonEncode(conversation.noteIds);
    
    await db.insert('conversations', json);
    return conversation.id;
  }

  Future<List<Conversation>> getAllConversations() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      orderBy: 'createdAt DESC',
    );

    return maps.map((map) => _mapToConversation(map)).toList();
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
    json['noteIds'] = jsonEncode(conversation.noteIds);
    
    await db.update(
      'conversations',
      json,
      where: 'id = ?',
      whereArgs: [conversation.id],
    );
  }

  Future<void> deleteConversation(String id) async {
    final db = await database;
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  // Conversation Messages CRUD
  Future<String> insertConversationMessage(ConversationMessage message) async {
    final db = await database;
    final json = message.toJson();
    json['timestamp'] = message.timestamp.millisecondsSinceEpoch;
    json['metadata'] = message.metadata != null ? jsonEncode(message.metadata) : null;
    // Remove attachmentPaths as it's not in the database schema
    json.remove('attachmentPaths');
    
    await db.insert('conversation_messages', json);
    return message.id;
  }

  Future<List<ConversationMessage>> getConversationMessages(String conversationId) async {
    final db = await database;
    // Join with conversation_message_mapping to get messages for this conversation
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT cm.* 
      FROM conversation_messages cm
      INNER JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp ASC
    ''', [conversationId]);

    return maps.map((map) => _mapToConversationMessage(map)).toList();
  }

  Future<ConversationMessage?> getConversationMessage(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversation_messages',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return _mapToConversationMessage(maps.first);
  }

  Future<void> updateConversationMessage(ConversationMessage message) async {
    final db = await database;
    final json = message.toJson();
    json['timestamp'] = message.timestamp.millisecondsSinceEpoch;
    json['metadata'] = message.metadata != null ? jsonEncode(message.metadata) : null;
    // Remove attachmentPaths as it's not in the database schema
    json.remove('attachmentPaths');
    
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
    final db = await database;
    
    LoggerService.info('Starting deletion of message $messageId and its subtree');
    
    // 1. Find all messages in the subtree (children recursively)
    final messagesToDelete = await _getMessageSubtree(messageId);
    LoggerService.info('Found ${messagesToDelete.length} messages to delete in subtree');
    
    // 2. Delete all related data efficiently
    await _deleteMessagesBatch(messagesToDelete);
    
    // 3. Find conversations that now have no messages and delete them
    await _cleanupEmptyConversations();
    
    LoggerService.info('Successfully deleted message $messageId and its subtree');
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
      where: 'messageId IN ($placeholders) OR parentMessageId IN ($placeholders)', 
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
    Future<void> _traverseSubtree(String currentMessageId) async {
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
        await _traverseSubtree(childId);
      }
    }
    
    await _traverseSubtree(messageId);
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
      await db.delete('conversations', where: 'id = ?', whereArgs: [conversationId]);
    }
    
    if (emptyConversations.isNotEmpty) {
      LoggerService.info('Cleaned up ${emptyConversations.length} empty conversations');
    }
  }

  // Delete conversation (only if explicitly requested)
  Future<void> deleteConversationExplicitly(String conversationId) async {
    final db = await database;
    
    LoggerService.info('Explicitly deleting conversation: $conversationId');
    
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
    await db.delete('conversations', where: 'id = ?', whereArgs: [conversationId]);
    
    LoggerService.info('Successfully deleted conversation: $conversationId');
  }

  // Delete messages using tree node traversal (for UI efficiency)
  Future<void> deleteMessagesFromTreeNodes(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    
    LoggerService.info('Deleting ${messageIds.length} messages from tree nodes');
    
    // Delete all related data efficiently
    await _deleteMessagesBatch(messageIds);
    
    // Find conversations that now have no messages and delete them
    await _cleanupEmptyConversations();
    
    LoggerService.info('Successfully deleted messages from tree nodes');
  }

  // Conversation Attachments CRUD
  Future<String> insertConversationAttachment(ConversationAttachment attachment) async {
    final db = await database;
    final json = attachment.toDatabase();
    await db.insert('conversation_attachments', json);
    return attachment.id;
  }

  Future<List<ConversationAttachment>> getConversationAttachments(String messageId) async {
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
    await db.delete('conversation_attachments', where: 'id = ?', whereArgs: [id]);
  }

  // Conversation Tree CRUD
  Future<String> insertConversationTree(ConversationTree tree) async {
    final db = await database;
    final json = {
      'id': tree.id,
      'treeData': jsonEncode(tree.toJson()),
      'createdAt': tree.createdAt.millisecondsSinceEpoch,
      'updatedAt': tree.updatedAt.millisecondsSinceEpoch,
    };
    
    await db.insert('conversation_tree', json);
    return tree.id;
  }

  Future<ConversationTree?> getConversationTree(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversation_tree',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return _mapToConversationTree(maps.first);
  }

  Future<void> updateConversationTree(ConversationTree tree) async {
    final db = await database;
    final json = {
      'id': tree.id,
      'treeData': jsonEncode(tree.toJson()),
      'createdAt': tree.createdAt.millisecondsSinceEpoch,
      'updatedAt': tree.updatedAt.millisecondsSinceEpoch,
    };
    
    await db.update(
      'conversation_tree',
      json,
      where: 'id = ?',
      whereArgs: [tree.id],
    );
  }

  Future<void> upsertConversationTree(ConversationTree tree) async {
    final db = await database;
    final json = {
      'id': tree.id,
      'treeData': jsonEncode(tree.toJson()),
      'createdAt': tree.createdAt.millisecondsSinceEpoch,
      'updatedAt': tree.updatedAt.millisecondsSinceEpoch,
    };
    
    // Try to insert first, if it fails due to unique constraint, update instead
    try {
      await db.insert('conversation_tree', json);
    } catch (e) {
      if (e.toString().contains('UNIQUE constraint failed')) {
        await db.update(
          'conversation_tree',
          json,
          where: 'id = ?',
          whereArgs: [tree.id],
        );
      } else {
        rethrow;
      }
    }
  }

  Future<void> deleteConversationTree(String id) async {
    final db = await database;
    await db.delete('conversation_tree', where: 'id = ?', whereArgs: [id]);
  }

  // Helper methods for mapping database results to models
  Conversation _mapToConversation(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String,
      noteIds: map['noteIds'] != null 
          ? List<String>.from(jsonDecode(map['noteIds'] as String))
          : [],
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
      isArchived: (map['isArchived'] ?? 0) == 1,
    );
  }

  ConversationMessage _mapToConversationMessage(Map<String, dynamic> map) {
    return ConversationMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
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

  ConversationTree _mapToConversationTree(Map<String, dynamic> map) {
    final treeData = jsonDecode(map['treeData'] as String) as Map<String, dynamic>;
    return ConversationTree.fromJson(treeData);
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

  Future<List<Map<String, dynamic>>> getConversationMessageMappings(String conversationId) async {
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
    final id = '${messageId}_${parentMessageId}';
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
    return results.isNotEmpty ? results.first['parentMessageId'] as String? : null;
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

  // Find all conversations that contain a specific message
  Future<List<String>> getConversationsContainingMessage(String messageId) async {
    final db = await database;
    final results = await db.query(
      'conversation_message_mapping',
      where: 'messageId = ?',
      whereArgs: [messageId],
    );
    return results.map((r) => r['conversationId'] as String).toList();
  }

}
