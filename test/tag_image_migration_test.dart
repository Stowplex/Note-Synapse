import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('tag_images table exists after migration', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tag_images'",
    );
    expect(tables, isNotEmpty);
    expect(tables.first['name'], 'tag_images');
  });

  test('tag_images table has correct schema', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;
    final columns = await db.rawQuery("PRAGMA table_info('tag_images')");
    final colNames = columns.map((c) => c['name'] as String).toList();
    expect(colNames, contains('tagId'));
    expect(colNames, contains('imagePath'));
  });

  test('tag_images cascade deletes when tag is deleted', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    // Enable foreign keys (needed for cascade)
    await db.execute('PRAGMA foreign_keys = ON');

    // Insert a tag
    await db.insert('tags', {
      'id': 'test-tag-id',
      'name': 'TestTag',
      'color': '#2196F3',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
    });

    // Insert a tag image
    await db.insert('tag_images', {
      'tagId': 'test-tag-id',
      'imagePath': 'builtin:sunset-glow',
    });

    // Verify it exists
    var images = await db.query('tag_images',
        where: 'tagId = ?', whereArgs: ['test-tag-id']);
    expect(images.length, 1);

    // Delete the tag
    await db.delete('tags', where: 'id = ?', whereArgs: ['test-tag-id']);

    // Verify cascade delete
    images = await db.query('tag_images',
        where: 'tagId = ?', whereArgs: ['test-tag-id']);
    expect(images.length, 0);
  });

  test('DatabaseService.setTagImage inserts image path', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    await db.insert('tags', {
      'id': 'tag-1',
      'name': 'Work',
      'color': '#2196F3',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
    });

    await dbService.setTagImage('tag-1', 'builtin:sunset-glow');

    final result =
        await db.query('tag_images', where: 'tagId = ?', whereArgs: ['tag-1']);
    expect(result.length, 1);
    expect(result.first['imagePath'], 'builtin:sunset-glow');
  });

  test('DatabaseService.setTagImage updates existing image', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    await db.insert('tags', {
      'id': 'tag-1',
      'name': 'Work',
      'color': '#2196F3',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
    });

    await dbService.setTagImage('tag-1', 'builtin:sunset-glow');
    await dbService.setTagImage('tag-1', 'builtin:ocean-mist');

    final result =
        await db.query('tag_images', where: 'tagId = ?', whereArgs: ['tag-1']);
    expect(result.length, 1);
    expect(result.first['imagePath'], 'builtin:ocean-mist');
  });

  test('DatabaseService.removeTagImage deletes the row', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    await db.insert('tags', {
      'id': 'tag-1',
      'name': 'Work',
      'color': '#2196F3',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
    });

    await dbService.setTagImage('tag-1', 'builtin:sunset-glow');
    await dbService.removeTagImage('tag-1');

    final result =
        await db.query('tag_images', where: 'tagId = ?', whereArgs: ['tag-1']);
    expect(result.length, 0);
  });

  test('DatabaseService.getAllTagImages returns map of tagId to imagePath',
      () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    await db.insert('tags', {
      'id': 'tag-1',
      'name': 'Work',
      'color': '#2196F3',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
    });
    await db.insert('tags', {
      'id': 'tag-2',
      'name': 'Personal',
      'color': '#4CAF50',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
    });

    await dbService.setTagImage('tag-1', 'builtin:sunset-glow');
    await dbService.setTagImage('tag-2', 'tag_images/tag-2.png');

    final images = await dbService.getAllTagImages();
    expect(images.length, 2);
    expect(images['tag-1'], 'builtin:sunset-glow');
    expect(images['tag-2'], 'tag_images/tag-2.png');
  });

  test('DatabaseService.getTagImage returns path for existing tag', () async {
    final dbService = DatabaseService.createNew();
    final db = await dbService.database;

    await db.insert('tags', {
      'id': 'tag-1',
      'name': 'Work',
      'color': '#2196F3',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
    });

    await dbService.setTagImage('tag-1', 'builtin:sunset-glow');

    final path = await dbService.getTagImage('tag-1');
    expect(path, 'builtin:sunset-glow');
  });

  test('DatabaseService.getTagImage returns null for tag without image',
      () async {
    final dbService = DatabaseService.createNew();

    final path = await dbService.getTagImage('nonexistent');
    expect(path, isNull);
  });
}
