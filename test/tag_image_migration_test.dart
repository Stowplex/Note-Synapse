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

  test(
    'tag_images becomes invisible (not cascade-deleted) once the owning '
    'tag is tombstoned',
    () async {
      // This test used to prove `tag_images` real-cascade-deletes via the
      // schema's `ON DELETE CASCADE` FK when `tags` itself is
      // real-deleted. That stopped being how tag removal actually works
      // back in M1.9 (`deleteTag`/`replaceTag` tombstone the `tags` row,
      // an UPDATE, never a real DELETE -- the FK cascade genuinely never
      // fires for either function since then), and M1.13 additionally
      // installed a hard-delete guard trigger directly on `tags` at the
      // database level, so a raw `db.delete('tags', ...)` like this test
      // used to issue now throws outright rather than merely being
      // unreachable through the service layer. What actually happens to a
      // tag's image today -- proven here via the real `deleteTag` call,
      // not a raw DELETE -- is M1.9's "derive, don't tombstone" design:
      // the `tag_images` row is left physically in place (no `__deleted__`
      // column of its own) and `getTagImage`/`getAllTagImages` instead
      // derive its visibility from the owning tag's own liveness via a
      // JOIN.
      final dbService = DatabaseService.createNew();
      final db = await dbService.database;

      await db.insert('tags', {
        'id': 'test-tag-id',
        'name': 'TestTag',
        'color': '#2196F3',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'usageCount': 0,
      });
      await db.insert('tag_images', {
        'tagId': 'test-tag-id',
        'imagePath': 'builtin:sunset-glow',
      });

      var images = await db.query(
        'tag_images',
        where: 'tagId = ?',
        whereArgs: ['test-tag-id'],
      );
      expect(images.length, 1);
      expect(await dbService.getTagImage('test-tag-id'), 'builtin:sunset-glow');

      await dbService.deleteTag('TestTag');

      // Still physically present -- not cascade-deleted, not tombstoned
      // itself.
      images = await db.query(
        'tag_images',
        where: 'tagId = ?',
        whereArgs: ['test-tag-id'],
      );
      expect(images.length, 1);
      // ...but no longer visible through the read path, since the owning
      // tag is now tombstoned.
      expect(await dbService.getTagImage('test-tag-id'), isNull);
      expect(await dbService.getAllTagImages(), isNot(contains('test-tag-id')));
    },
  );

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
