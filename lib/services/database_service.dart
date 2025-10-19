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
import 'logger_service.dart';
import '../utils/file_type_utils.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal() {
    // Initialize database factory using platform-specific implementation
    initializeDatabaseFactory();
  }

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
      version: 16,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Notes table
    await db.execute('''
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
    ''');

    // SubNotes table
    await db.execute('''
      CREATE TABLE subnotes(
        id TEXT PRIMARY KEY,
        noteId TEXT NOT NULL,
        name TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        isCompleted INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
    ''');

    // Tags table
    await db.execute('''
      CREATE TABLE tags(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        color TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        usageCount INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Note-Tag relationships table
    await db.execute('''
      CREATE TABLE note_tags(
        noteId TEXT NOT NULL,
        tagId TEXT NOT NULL,
        PRIMARY KEY (noteId, tagId),
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
    ''');

    // Attachments table
    await db.execute('''
      CREATE TABLE attachments(
        id TEXT PRIMARY KEY,
        noteId TEXT NOT NULL,
        filePath TEXT NOT NULL,
        fileName TEXT NOT NULL,
        fileType TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
    ''');

    // Relationships table
    await db.execute('''
      CREATE TABLE relationships(
        id TEXT PRIMARY KEY,
        fromNoteId TEXT NOT NULL,
        toNoteId TEXT NOT NULL,
        type TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (fromNoteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (toNoteId) REFERENCES notes (id) ON DELETE CASCADE
      )
    ''');


    // Filters table
    await db.execute('''
      CREATE TABLE filters(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        includeText TEXT,
        includeTags TEXT NOT NULL,
        includeArchived INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');

    // User Apps table
    await db.execute('''
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
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');

    // App Revisions table
    await db.execute('''
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
    ''');

    // User App Libraries table
    await db.execute('''
      CREATE TABLE user_app_libraries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        app_uuid TEXT NOT NULL,
        revision_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        usage_instructions TEXT,
        FOREIGN KEY (app_uuid) REFERENCES user_apps (uuid) ON DELETE CASCADE
      )
    ''');

    // User App Library Dependencies table
    await db.execute('''
      CREATE TABLE user_app_library_dependencies(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        original_url TEXT,
        local_path TEXT NOT NULL,
        bytes BLOB NOT NULL,
        library_id INTEGER NOT NULL,
        FOREIGN KEY (library_id) REFERENCES user_app_libraries (id) ON DELETE CASCADE
      )
    ''');

    // Create indexes for better performance
    await db.execute('CREATE INDEX idx_notes_type ON notes(type)');
    await db.execute('CREATE INDEX idx_notes_createdAt ON notes(createdAt)');
    await db.execute('CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)');
    await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
    await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
    await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
    await db.execute('CREATE INDEX idx_relationships_fromNoteId ON relationships(fromNoteId)');
    await db.execute('CREATE INDEX idx_relationships_toNoteId ON relationships(toNoteId)');
    await db.execute('CREATE INDEX idx_user_app_libraries_app_uuid ON user_app_libraries(app_uuid)');
    await db.execute('CREATE INDEX idx_user_app_libraries_revision_id ON user_app_libraries(revision_id)');
    await db.execute('CREATE INDEX idx_user_app_library_dependencies_library_id ON user_app_library_dependencies(library_id)');
    await db.execute('CREATE INDEX idx_user_app_library_dependencies_local_path ON user_app_library_dependencies(local_path)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Migration from version 1 to 2: Remove dueDate column and add scheduledAt, completeBy columns
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
        // If migration fails, drop and recreate the database
        LoggerService.error('Migration failed, recreating database: $e', error: e);
        await db.execute('DROP TABLE IF EXISTS notes');
        await db.execute('DROP TABLE IF EXISTS subnotes');
        await db.execute('DROP TABLE IF EXISTS tags');
        await db.execute('DROP TABLE IF EXISTS note_tags');
        await db.execute('DROP TABLE IF EXISTS attachments');
        await db.execute('DROP TABLE IF EXISTS relationships');
        await _onCreate(db, newVersion);
      }
    }
    
    if (oldVersion < 3) {
      // Migration from version 2 to 3: Add pinned column
      try {
        await db.execute('ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
        await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
      } catch (e) {
        LoggerService.error('Migration to version 3 failed: $e', error: e);
        // If migration fails, drop and recreate the database
        await db.execute('DROP TABLE IF EXISTS notes');
        await db.execute('DROP TABLE IF EXISTS subnotes');
        await db.execute('DROP TABLE IF EXISTS tags');
        await db.execute('DROP TABLE IF EXISTS note_tags');
        await db.execute('DROP TABLE IF EXISTS attachments');
        await db.execute('DROP TABLE IF EXISTS relationships');
        await _onCreate(db, newVersion);
      }
    }
    
    if (oldVersion < 4) {
      // Migration from version 3 to 4: Add isArchived column
      try {
        await db.execute('ALTER TABLE notes ADD COLUMN isArchived INTEGER NOT NULL DEFAULT 0');
        await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
      } catch (e) {
        LoggerService.error('Migration to version 4 failed: $e', error: e);
        // If migration fails, drop and recreate the database
        await db.execute('DROP TABLE IF EXISTS notes');
        await db.execute('DROP TABLE IF EXISTS subnotes');
        await db.execute('DROP TABLE IF EXISTS tags');
        await db.execute('DROP TABLE IF EXISTS note_tags');
        await db.execute('DROP TABLE IF EXISTS attachments');
        await db.execute('DROP TABLE IF EXISTS relationships');
        await _onCreate(db, newVersion);
      }
    }
    
    if (oldVersion < 5) {
      // Migration from version 4 to 5: Ensure isArchived column exists
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
        // If migration fails, drop and recreate the database
        await db.execute('DROP TABLE IF EXISTS notes');
        await db.execute('DROP TABLE IF EXISTS subnotes');
        await db.execute('DROP TABLE IF EXISTS tags');
        await db.execute('DROP TABLE IF EXISTS note_tags');
        await db.execute('DROP TABLE IF EXISTS attachments');
        await db.execute('DROP TABLE IF EXISTS relationships');
        await _onCreate(db, newVersion);
      }
    }
    
    if (oldVersion < 6) {
      // Migration from version 5 to 6: Add filters table
      try {
        await db.execute('''
          CREATE TABLE filters(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            includeText TEXT,
            includeTags TEXT NOT NULL,
            includeArchived INTEGER NOT NULL DEFAULT 0,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL
          )
        ''');
      } catch (e) {
        LoggerService.error('Migration to version 6 failed: $e', error: e);
        // If migration fails, drop and recreate the database
        await db.execute('DROP TABLE IF EXISTS notes');
        await db.execute('DROP TABLE IF EXISTS subnotes');
        await db.execute('DROP TABLE IF EXISTS tags');
        await db.execute('DROP TABLE IF EXISTS note_tags');
        await db.execute('DROP TABLE IF EXISTS attachments');
        await db.execute('DROP TABLE IF EXISTS relationships');
        await db.execute('DROP TABLE IF EXISTS filters');
        await _onCreate(db, newVersion);
      }
    }
    
    if (oldVersion < 7) {
      // Migration from version 6 to 7: Add user_apps table
      try {
        // Check if user_apps table already exists
        final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='user_apps'");
        if (tables.isEmpty) {
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
        // Only drop and recreate if the table creation actually failed
        try {
          await db.execute('DROP TABLE IF EXISTS user_apps');
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
        } catch (e2) {
          LoggerService.error('Failed to create user_apps table: $e2', error: e2);
          // Only as last resort, recreate entire database
          await db.execute('DROP TABLE IF EXISTS notes');
          await db.execute('DROP TABLE IF EXISTS subnotes');
          await db.execute('DROP TABLE IF EXISTS tags');
          await db.execute('DROP TABLE IF EXISTS note_tags');
          await db.execute('DROP TABLE IF EXISTS attachments');
          await db.execute('DROP TABLE IF EXISTS relationships');
          await db.execute('DROP TABLE IF EXISTS filters');
          await db.execute('DROP TABLE IF EXISTS user_apps');
          await _onCreate(db, newVersion);
        }
      }
    }
    
    if (oldVersion < 8) {
      // Migration from version 7 to 8: Add type column to user_apps table
      try {
        // Check if type column exists in user_apps table
        final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('type')) {
          await db.execute('ALTER TABLE user_apps ADD COLUMN type TEXT NOT NULL DEFAULT "normal"');
        }
      } catch (e) {
        LoggerService.error('Migration to version 8 failed: $e', error: e);
        // If migration fails, recreate the user_apps table
        try {
          await db.execute('DROP TABLE IF EXISTS user_apps');
          await db.execute('''
            CREATE TABLE user_apps(
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              description TEXT NOT NULL,
              steps TEXT NOT NULL,
              htmlContent TEXT NOT NULL,
              appState TEXT,
              type TEXT NOT NULL DEFAULT 'normal',
              createdAt INTEGER NOT NULL,
              updatedAt INTEGER NOT NULL
            )
          ''');
        } catch (e2) {
          LoggerService.error('Failed to recreate user_apps table: $e2', error: e2);
        }
      }
    }
    
    if (oldVersion < 9) {
      // Migration from version 8 to 9: Add selectedRevisionId column and app_revisions table
      try {
        // Add selectedRevisionId column to user_apps table
        final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('selectedRevisionId')) {
          await db.execute('ALTER TABLE user_apps ADD COLUMN selectedRevisionId TEXT');
        }
        
        // Create app_revisions table
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
        await _migrateExistingAppsToRevisions(db);
      } catch (e) {
        LoggerService.error('Migration to version 9 failed: $e', error: e);
      }
    }
    
    if (oldVersion < 10) {
      // Migration from version 9 to 10: Add attachmentPaths column to user_apps table
      try {
        // Check if attachmentPaths column exists in user_apps table
        final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('attachmentPaths')) {
          await db.execute('ALTER TABLE user_apps ADD COLUMN attachmentPaths TEXT');
        }
      } catch (e) {
        LoggerService.error('Migration to version 10 failed: $e', error: e);
      }
    }
    
    if (oldVersion < 11) {
      // Migration from version 10 to 11: Move attachmentPaths from user_apps to app_revisions
      try {
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
      } catch (e) {
        LoggerService.error('Migration to version 11 failed: $e', error: e);
      }
    }
    
    if (oldVersion < 12) {
      // Migration from version 11 to 12: Remove AI interactions table
      try {
        // Check if ai_interactions table exists and drop it
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='ai_interactions'"
        );
        
        if (tables.isNotEmpty) {
          await db.execute('DROP TABLE IF EXISTS ai_interactions');
          LoggerService.info('Dropped ai_interactions table');
        }
      } catch (e) {
        // Ignore any errors - table might already be dropped
        LoggerService.warning('Migration to version 12: $e', error: e);
      }
    }
    
    if (oldVersion < 13) {
      // Migration from version 12 to 13: Fix string timestamps in filters table
      try {
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
      } catch (e) {
        LoggerService.warning('Migration to version 13: $e', error: e);
      }
    }
    
    if (oldVersion < 14) {
      // Migration from version 13 to 14: Add UUID column to user_apps table
      try {
        // Check if uuid column exists in user_apps table
        final columns = await db.rawQuery("PRAGMA table_info(user_apps)");
        final columnNames = columns.map((col) => col['name'] as String).toList();
        
        if (!columnNames.contains('uuid')) {
          // Add uuid column
          await db.execute('ALTER TABLE user_apps ADD COLUMN uuid TEXT');
          
          // Generate UUIDs for existing records that have null uuid
          await _migrateUserAppsWithUuid(db);
        }
      } catch (e) {
        LoggerService.error('Migration to version 14 failed: $e', error: e);
        // If migration fails, recreate the user_apps table
        try {
          await db.execute('DROP TABLE IF EXISTS user_apps');
          await db.execute('''
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
              createdAt INTEGER NOT NULL,
              updatedAt INTEGER NOT NULL
            )
          ''');
        } catch (e2) {
          LoggerService.error('Failed to recreate user_apps table: $e2', error: e2);
        }
      }
    }
    
    if (oldVersion < 15) {
      // Migration from version 14 to 15: Add user app libraries and dependencies tables
      try {
        // Create User App Libraries table
        await db.execute('''
          CREATE TABLE user_app_libraries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_uuid TEXT NOT NULL,
            revision_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            usage_instructions TEXT,
            FOREIGN KEY (app_uuid) REFERENCES user_apps (uuid) ON DELETE CASCADE
          )
        ''');

        // Create User App Library Dependencies table
        await db.execute('''
          CREATE TABLE user_app_library_dependencies(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            original_url TEXT,
            local_path TEXT NOT NULL,
            bytes BLOB NOT NULL,
            library_id INTEGER NOT NULL,
            FOREIGN KEY (library_id) REFERENCES user_app_libraries (id) ON DELETE CASCADE
          )
        ''');
        
        // Create indexes for better performance
        await db.execute('CREATE INDEX idx_user_app_libraries_app_uuid ON user_app_libraries(app_uuid)');
        await db.execute('CREATE INDEX idx_user_app_libraries_revision_id ON user_app_libraries(revision_id)');
        await db.execute('CREATE INDEX idx_user_app_library_dependencies_library_id ON user_app_library_dependencies(library_id)');
        await db.execute('CREATE INDEX idx_user_app_library_dependencies_local_path ON user_app_library_dependencies(local_path)');
        
        LoggerService.info('Migration to version 15 completed: Added user app libraries and dependencies tables');
      } catch (e) {
        LoggerService.error('Migration to version 15 failed: $e', error: e);
      }
    }
    
    if (oldVersion < 16) {
      // Migration from version 15 to 16: Add author and license fields to user_apps table
      try {
        // Add author and license columns to user_apps table
        await db.execute('ALTER TABLE user_apps ADD COLUMN author TEXT DEFAULT ""');
        await db.execute('ALTER TABLE user_apps ADD COLUMN license TEXT DEFAULT ""');
        
        LoggerService.info('Migration to version 16 completed: Added author and license fields to user_apps table');
      } catch (e) {
        LoggerService.error('Migration to version 16 failed: $e', error: e);
      }
    }
    
    
  }


  // Migration helper method to create initial revisions for existing apps
  Future<void> _migrateExistingAppsToRevisions(Database db) async {
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
  Future<void> _migrateUserAppsWithUuid(Database db) async {
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
      await _insertAttachment(note.id, attachmentPath);
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
      await _insertAttachment(note.id, attachmentPath);
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

    return maps.map((map) => map['filePath'] as String).toList();
  }

  // Verify if an attachment path belongs to any note
  Future<bool> verifyAttachmentPath(String attachmentPath) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'filePath = ?',
      whereArgs: [attachmentPath],
    );

    return maps.isNotEmpty;
  }

  // Get the note ID for a given attachment path
  Future<String?> getNoteIdForAttachment(String attachmentPath) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'filePath = ?',
      whereArgs: [attachmentPath],
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

  Future<void> _insertAttachment(String noteId, String filePath) async {
    final db = await database;
    final fileName = filePath.split('/').last;
    final fileType = FileTypeUtils.getFileExtension(fileName);
    
    await db.insert('attachments', {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'noteId': noteId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
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
}
