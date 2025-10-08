import 'dart:async';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/ai_interaction.dart';
import '../models/tag.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal() {
    // Initialize database factory for desktop platforms
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
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
      version: 2,
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
        completionPercentage REAL
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

    // Create indexes for better performance
    await db.execute('CREATE INDEX idx_notes_type ON notes(type)');
    await db.execute('CREATE INDEX idx_notes_createdAt ON notes(createdAt)');
    await db.execute('CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)');
    await db.execute('CREATE INDEX idx_notes_completeBy ON notes(completeBy)');
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
        print('Migration failed, recreating database: $e');
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
  }

  // Notes CRUD
  Future<String> insertNote(Note note) async {
    final db = await database;
    final json = note.toJson();
    json['createdAt'] = note.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = note.updatedAt.millisecondsSinceEpoch;
    
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
      orderBy: 'createdAt DESC',
    );

    final List<Note> notes = [];
    for (final map in maps) {
      try {
        final note = await _mapToNote(map);
        notes.add(note);
      } catch (e) {
        print('Error mapping note with id ${map['id']}: $e');
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
}
