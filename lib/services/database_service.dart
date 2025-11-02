import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';

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
import 'logger_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';

// Migration step configuration
class MigrationStep {
  final String description;
  final Future<void> Function(Database db, {required bool isBackupMigration})
  execute;

  const MigrationStep({required this.description, required this.execute});
}

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal() {
    // Initialize database factory using platform-specific implementation
    initializeDatabaseFactory();
  }

  // Current database version - exported for use by recovery/import operations
  static const int DATABASE_VERSION = 22;

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

  static const String _createConversationTagsTable = '''
      CREATE TABLE conversation_tags(
        conversationId TEXT NOT NULL,
        tagId TEXT NOT NULL,
        PRIMARY KEY (conversationId, tagId),
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
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

  static const String _createConversationNoteMappingTable = '''
      CREATE TABLE conversation_note_mapping(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversationId TEXT NOT NULL,
        noteId TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
        UNIQUE(conversationId, noteId)
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
    'CREATE INDEX idx_conversation_note_mapping_conversationId ON conversation_note_mapping(conversationId)',
    'CREATE INDEX idx_conversation_note_mapping_noteId ON conversation_note_mapping(noteId)',
    'CREATE INDEX idx_conversation_tags_conversationId ON conversation_tags(conversationId)',
    'CREATE INDEX idx_conversation_tags_tagId ON conversation_tags(tagId)',
  ];

  final Uuid _uuid = const Uuid();

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
      version: DATABASE_VERSION,
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

    await db.execute(_createConversationMessageMappingTable);
    await db.execute(_createMessageParentsTable);
    await db.execute(_createConversationNoteMappingTable);
    await db.execute(_createConversationTagsTable);

    // Create all indexes
    for (final indexSql in _createIndexes) {
      await db.execute(indexSql);
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await _executeMigrations(
      db,
      oldVersion,
      newVersion,
      isBackupMigration: false,
    );
  }

  // Migration configuration structure
  // All clients are now on version 20 or later, so only keep version 20 migration for edge cases
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
  };

  // Main migration execution method
  Future<void> _executeMigrations(
    Database db,
    int oldVersion,
    int newVersion, {
    required bool isBackupMigration,
  }) async {
    for (int version = oldVersion + 1; version <= newVersion; version++) {
      final migrationStep = _migrationSteps[version];
      if (migrationStep == null) {
        LoggerService.warning('No migration step defined for version $version');
        continue;
      }

      try {
        LoggerService.info(
          'Executing migration to version $version: ${migrationStep.description}',
        );
        await migrationStep.execute(db, isBackupMigration: isBackupMigration);
        LoggerService.info('Successfully migrated to version $version');
      } catch (e) {
        LoggerService.error(
          'Migration to version $version failed: $e',
          error: e,
        );

        // Apply granular error handling based on the specific migration
        await _handleMigrationError(
          db,
          version,
          e,
          isBackupMigration: isBackupMigration,
        );
        break; // Stop migration on error
      }
    }
  }

  // Handle migration errors with granular table recreation
  Future<void> _handleMigrationError(
    Database db,
    int version,
    dynamic error, {
    required bool isBackupMigration,
  }) async {
    switch (version) {
      case 2:
        // Notes table migration failed - recreate notes and related tables
        LoggerService.error(
          'Recreating notes table and related tables due to migration failure',
        );
        await _recreateNotesTables(db, isBackupMigration: isBackupMigration);
        break;

      case 3:
      case 4:
      case 5:
        // Notes table column additions failed - recreate notes table
        LoggerService.error(
          'Recreating notes table due to column addition failure',
        );
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
        LoggerService.error(
          'Recreating user_apps table due to operation failure',
        );
        await _recreateUserAppsTable(db, isBackupMigration: isBackupMigration);
        break;

      case 9:
        // App revisions table creation failed - recreate app_revisions table
        LoggerService.error(
          'Recreating app_revisions table due to creation failure',
        );
        await _recreateAppRevisionsTable(
          db,
          isBackupMigration: isBackupMigration,
        );
        break;

      case 10:
      case 11:
      case 14:
        // User apps table modifications failed - recreate user_apps table
        LoggerService.error(
          'Recreating user_apps table due to modification failure',
        );
        await _recreateUserAppsTable(db, isBackupMigration: isBackupMigration);
        break;

      case 15:
        // Library tables creation failed - recreate library tables
        LoggerService.error(
          'Recreating library tables due to creation failure',
        );
        await _recreateLibraryTables(db, isBackupMigration: isBackupMigration);
        break;

      case 12:
      case 13:
      case 16:
      case 17:
        // These are safe operations - log warning but don't recreate anything
        LoggerService.warning(
          'Migration $version failed but is considered safe - continuing',
        );
        break;

      default:
        // Unknown migration - fall back to full database recreation
        LoggerService.error(
          'Unknown migration $version failed - recreating entire database',
        );
        if (isBackupMigration) {
          await _recreateBackupDatabase(db, version);
        } else {
          await _recreateMainDatabase(db, version);
        }
    }
  }

  // Granular table recreation methods
  Future<void> _recreateNotesTables(
    Database db, {
    required bool isBackupMigration,
  }) async {
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
    await db.execute(
      'CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)',
    );
    await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
    await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
    await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
    await db.execute(
      'CREATE INDEX idx_relationships_fromNoteId ON relationships(fromNoteId)',
    );
    await db.execute(
      'CREATE INDEX idx_relationships_toNoteId ON relationships(toNoteId)',
    );
  }

  Future<void> _recreateNotesTable(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // Drop and recreate only the notes table
    await db.execute('DROP TABLE IF EXISTS notes');
    await db.execute(_createNotesTable);

    // Recreate indexes
    await db.execute('CREATE INDEX idx_notes_type ON notes(type)');
    await db.execute('CREATE INDEX idx_notes_createdAt ON notes(createdAt)');
    await db.execute(
      'CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)',
    );
    await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
    await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
    await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
  }

  Future<void> _recreateFiltersTable(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute('DROP TABLE IF EXISTS filters');
    await db.execute(_createFiltersTable);
  }

  Future<void> _recreateUserAppsTable(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute('DROP TABLE IF EXISTS user_apps');
    await db.execute(_createUserAppsTable);
  }

  Future<void> _recreateAppRevisionsTable(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute('DROP TABLE IF EXISTS app_revisions');
    await db.execute(_createAppRevisionsTable);
  }

  Future<void> _recreateLibraryTables(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute('DROP TABLE IF EXISTS user_app_library_dependencies');
    await db.execute('DROP TABLE IF EXISTS user_app_libraries');

    await db.execute(_createUserAppLibrariesTable);
    await db.execute(_createUserAppLibraryDependenciesTable);

    // Create indexes
    await db.execute(
      'CREATE INDEX idx_user_app_libraries_app_uuid ON user_app_libraries(app_uuid)',
    );
    await db.execute(
      'CREATE INDEX idx_user_app_libraries_revision_id ON user_app_libraries(revision_id)',
    );
    await db.execute(
      'CREATE INDEX idx_user_app_library_dependencies_library_id ON user_app_library_dependencies(library_id)',
    );
    await db.execute(
      'CREATE INDEX idx_user_app_library_dependencies_local_path ON user_app_library_dependencies(local_path)',
    );
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
      final isRelativePath = attachmentPath.startsWith('attachments/');
      await _insertAttachment(
        note.id,
        attachmentPath,
        isRelativePath: isRelativePath,
      );
    }

    return note.id;
  }

  // Get all notes from the database
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
        LoggerService.error(
          'Error mapping note with id ${map['id']}: $e',
          error: e,
        );
        LoggerService.error('Note data: $map');
        // Skip corrupted notes instead of crashing
        continue;
      }
    }
    LoggerService.info('Successfully mapped ${notes.length} notes');
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
        LoggerService.error(
          'Error mapping note with id ${map['id']}: $e',
          error: e,
        );
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
        LoggerService.error(
          'Error mapping note with id ${map['id']}: $e',
          error: e,
        );
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
        LoggerService.error(
          'Error mapping note with id ${map['id']}: $e',
          error: e,
        );
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

  // Get multiple notes by their IDs efficiently
  Future<List<Note>> getNotesByIds(List<String> noteIds) async {
    if (noteIds.isEmpty) return [];

    final db = await database;
    // Use WHERE IN clause for efficient batch retrieval
    final placeholders = List.filled(noteIds.length, '?').join(',');
    final List<Map<String, dynamic>> maps = await db.query(
      'notes',
      where: 'id IN ($placeholders)',
      whereArgs: noteIds,
    );

    final List<Note> notes = [];
    for (final map in maps) {
      try {
        final note = await _mapToNote(map);
        notes.add(note);
      } catch (e) {
        LoggerService.error(
          'Error mapping note with id ${map['id']}: $e',
          error: e,
        );
        // Skip corrupted notes instead of crashing
        continue;
      }
    }
    return notes;
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
    await db.delete('attachments', where: 'noteId = ?', whereArgs: [note.id]);
    for (final attachmentPath in note.attachmentPaths) {
      // Check if path is relative (starts with 'attachments/')
      final isRelativePath = attachmentPath.startsWith('attachments/');
      await _insertAttachment(
        note.id,
        attachmentPath,
        isRelativePath: isRelativePath,
      );
    }
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
        await db.insert('note_tags', {'noteId': noteId, 'tagId': newTagId});
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
      status: map['status'] != null ? _stringToTaskStatus(map['status']) : null,
      completionPercentage: map['completionPercentage'],
      pinned: (map['pinned'] ?? 0) == 1,
      isArchived: (map['isArchived'] ?? 0) == 1,
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
      await db.insert('note_tags', {'noteId': noteId, 'tagId': tagId});
    }
  }

  Future<void> _insertAttachment(
    String noteId,
    String filePath, {
    bool isRelativePath = false,
  }) async {
    final db = await database;
    final fileName = filePath.split('/').last;
    final fileType = FileTypeUtils.getFileExtension(fileName);
    final uuid = Uuid();

    await db.insert('attachments', {
      'id': uuid.v4(),
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
  Future<void> migrateBackupDatabase(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    LoggerService.info(
      'Migrating backup database from version $oldVersion to $newVersion',
    );
    await _executeMigrations(
      db,
      oldVersion,
      newVersion,
      isBackupMigration: true,
    );
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
    await db.execute('DROP TABLE IF EXISTS conversation_tags');
    await db.execute('DROP TABLE IF EXISTS conversation_note_mapping');
    await db.execute('DROP TABLE IF EXISTS conversation_message_mapping');
    await db.execute('DROP TABLE IF EXISTS message_parents');
    await db.execute('DROP TABLE IF EXISTS conversation_attachments');
    await db.execute('DROP TABLE IF EXISTS conversation_messages');
    await db.execute('DROP TABLE IF EXISTS conversations');

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
      final includeTags = includeTagsString.isEmpty
          ? <String>[]
          : includeTagsString.split(',');

      return Filter(
        id: maps[i]['id'],
        name: maps[i]['name'],
        includeText: maps[i]['includeText'],
        includeTags: includeTags,
        includeArchived: (maps[i]['includeArchived'] ?? 0) == 1,
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
    final maps = await db.query('user_apps', orderBy: 'createdAt DESC');
    LoggerService.debug(
      'DatabaseService.getAllUserApps: Found ${maps.length} user apps',
    );
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
    final maps = await db.query(
      'user_apps',
      columns: ['appState'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty && maps.first['appState'] != null) {
      return jsonDecode(maps.first['appState'] as String)
          as Map<String, dynamic>;
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
    final maps = await db.query(
      'app_revisions',
      where: 'appId = ?',
      whereArgs: [appId],
      orderBy: 'revisionNumber ASC',
    );
    LoggerService.debug(
      'DatabaseService.getAppRevisions: Found ${maps.length} revisions for app $appId',
    );
    if (maps.isNotEmpty) {
      LoggerService.debug('First revision data: ${maps.first}');
    }
    final revisions = maps.map((map) => _appRevisionFromMap(map)).toList();
    if (revisions.isNotEmpty) {
      LoggerService.debug(
        'First revision appCode length: ${revisions.first.appCode.length}',
      );
    }
    return revisions;
  }

  Future<AppRevision?> getAppRevision(String id) async {
    final db = await database;
    final maps = await db.query(
      'app_revisions',
      where: 'id = ?',
      whereArgs: [id],
    );
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
      revisionTimestamp: DateTime.fromMillisecondsSinceEpoch(
        map['revisionTimestamp'] as int,
      ),
      userPrompt: map['userPrompt'] as String,
      aiResponse: map['aiResponse'] as String,
      appCode: map['appCode'] as String,
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
          final blobData = await _readBlobInChunks(db, map['id'] as int);
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
          final blobData = await _readBlobInChunks(db, result['id'] as int);
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
          final blobData = await _readBlobInChunks(db, result['id'] as int);
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

  // Helper method to read BLOB data in chunks to avoid cursor window issues
  Future<List<int>> _readBlobInChunks(Database db, int dependencyId) async {
    const int chunkSize = 1024 * 1024; // 1MB chunks
    final List<int> allBytes = [];

    try {
      // Get the total size of the BLOB
      final sizeResult = await db.rawQuery(
        '''
        SELECT length(bytes) as blob_size 
        FROM user_app_library_dependencies 
        WHERE id = ?
      ''',
        [dependencyId],
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
          '''
          SELECT substr(bytes, ?, ?) as chunk
          FROM user_app_library_dependencies 
          WHERE id = ?
        ''',
          [offset + 1, currentChunkSize, dependencyId],
        );

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
    json['noteIds'] = '[]'; // Always empty, managed by mapping table

    await db.insert('conversations', json);
    return conversation.id;
  }

  // Get all conversations
  Future<List<Conversation>> getAllConversations({
    Duration? maxAge,
    List<String>? conversationIds,
    List<String>? tagNames,
  }) async {
    final db = await database;

    final filters = <String>[];
    final filterArgs = <dynamic>[];

    if (maxAge != null) {
      filters.add('c.createdAt >= ?');
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

    final whereClause = filters.isNotEmpty
        ? filters.map((clause) => clause.replaceAll('c.', '')).join(' AND ')
        : null;

    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      where: whereClause,
      whereArgs: filterArgs.isEmpty ? null : filterArgs,
      orderBy: 'updatedAt DESC',
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
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT cm.* 
      FROM conversation_messages cm
      INNER JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp ASC
    ''',
      [conversationId],
    );

    return maps
        .map((map) => _mapToConversationMessage(map, conversationId))
        .toList()
        .cast<ConversationMessage>();
  }

  Future<ConversationMessage?> getConversationMessage(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversation_messages',
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

    return _mapToConversationMessage(maps.first, conversationId);
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
}
