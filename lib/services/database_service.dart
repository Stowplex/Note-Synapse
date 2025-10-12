import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/ai_interaction.dart';
import '../models/tag.dart';
import '../models/filter.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import 'logger_service.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal() {
    // Initialize database factory for desktop platforms
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  // For testing, allow creating new instances
  DatabaseService.createNew() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
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
      version: 11,
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

    // AI Interactions table
    await db.execute('''
      CREATE TABLE ai_interactions(
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        prompt TEXT NOT NULL,
        response TEXT NOT NULL,
        contextNoteIds TEXT NOT NULL,
        transformedNoteId TEXT,
        createdNoteIds TEXT,
        createdAt INTEGER NOT NULL,
        expiresAt INTEGER NOT NULL
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

    // Create indexes for better performance
    await db.execute('CREATE INDEX idx_notes_type ON notes(type)');
    await db.execute('CREATE INDEX idx_notes_createdAt ON notes(createdAt)');
    await db.execute('CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)');
    await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
    await db.execute('CREATE INDEX idx_notes_pinned ON notes(pinned)');
    await db.execute('CREATE INDEX idx_notes_isArchived ON notes(isArchived)');
    await db.execute('CREATE INDEX idx_relationships_fromNoteId ON relationships(fromNoteId)');
    await db.execute('CREATE INDEX idx_relationships_toNoteId ON relationships(toNoteId)');
    await db.execute('CREATE INDEX idx_ai_interactions_expiresAt ON ai_interactions(expiresAt)');
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
        await db.execute('DROP TABLE IF EXISTS ai_interactions');
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
        await db.execute('DROP TABLE IF EXISTS ai_interactions');
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
        await db.execute('DROP TABLE IF EXISTS ai_interactions');
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
        await db.execute('DROP TABLE IF EXISTS ai_interactions');
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
        await db.execute('DROP TABLE IF EXISTS ai_interactions');
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
          await db.execute('DROP TABLE IF EXISTS ai_interactions');
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
    final List<Map<String, dynamic>> maps = await db.query(
      'notes',
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
        usageCount: maps[i]['usageCount'],
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

  // AI Interactions CRUD
  Future<String> insertAIInteraction(AIInteraction interaction) async {
    final db = await database;
    final json = interaction.toJson();
    json['createdAt'] = interaction.createdAt.millisecondsSinceEpoch;
    json['expiresAt'] = interaction.expiresAt.millisecondsSinceEpoch;
    json['contextNoteIds'] = interaction.contextNoteIds.join(',');
    if (interaction.createdNoteIds != null) {
      json['createdNoteIds'] = interaction.createdNoteIds!.join(',');
    }
    await db.insert('ai_interactions', json);
    return interaction.id;
  }

  Future<List<AIInteraction>> getAllAIInteractions() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'ai_interactions',
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      return AIInteraction(
        id: maps[i]['id'],
        type: AIInteractionType.values.firstWhere(
          (e) => e.toString().split('.').last == maps[i]['type'],
          orElse: () => AIInteractionType.noteQa,
        ),
        prompt: maps[i]['prompt'],
        response: maps[i]['response'],
        contextNoteIds: maps[i]['contextNoteIds']?.split(',') ?? [],
        transformedNoteId: maps[i]['transformedNoteId'],
        createdNoteIds: maps[i]['createdNoteIds']?.split(','),
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['expiresAt']),
      );
    });
  }

  // Helper methods
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
    final fileType = fileName.split('.').last.toLowerCase();
    
    await db.insert('attachments', {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'noteId': noteId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // Cleanup expired AI interactions
  Future<void> cleanupExpiredAIInteractions() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.delete(
      'ai_interactions',
      where: 'expiresAt < ?',
      whereArgs: [now],
    );
  }

  // Clear all data
  Future<void> clearAllData() async {
    final db = await database;
    
    // Delete all data from all tables
    await db.delete('ai_interactions');
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
    final json = filter.toJson();
    json['createdAt'] = filter.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = filter.updatedAt.millisecondsSinceEpoch;
    json['includeArchived'] = filter.includeArchived ? 1 : 0;
    json['includeTags'] = filter.includeTags.join(',');
    
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
        includeArchived: maps[i]['includeArchived'] == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['updatedAt']),
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
      includeArchived: map['includeArchived'] == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt']),
    );
  }

  Future<void> updateFilter(Filter filter) async {
    final db = await database;
    final json = filter.toJson();
    json['updatedAt'] = filter.updatedAt.millisecondsSinceEpoch;
    json['includeArchived'] = filter.includeArchived ? 1 : 0;
    json['includeTags'] = filter.includeTags.join(',');
    
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
      'name': app.name,
      'description': app.description,
      'steps': app.steps.join('|'), // Store steps as pipe-separated string
      'htmlContent': app.htmlContent,
      'appState': app.appState != null ? jsonEncode(app.appState) : null,
      'type': app.type.toString().split('.').last, // Store enum as string
      'selectedRevisionId': app.selectedRevisionId,
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
      'name': app.name,
      'description': app.description,
      'steps': app.steps.join('|'), // Store steps as pipe-separated string
      'htmlContent': app.htmlContent,
      'appState': app.appState != null ? jsonEncode(app.appState) : null,
      'type': app.type.toString().split('.').last, // Store enum as string
      'selectedRevisionId': app.selectedRevisionId,
      'createdAt': app.createdAt.millisecondsSinceEpoch,
      'updatedAt': app.updatedAt.millisecondsSinceEpoch,
    };
    
    await db.update('user_apps', json, where: 'id = ?', whereArgs: [app.id]);
  }

  Future<void> deleteUserApp(String id) async {
    final db = await database;
    // Delete app revisions first (foreign key constraint will handle this automatically)
    await db.delete('app_revisions', where: 'appId = ?', whereArgs: [id]);
    // Then delete the app
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
}
