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
}
