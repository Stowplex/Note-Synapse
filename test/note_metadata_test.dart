import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  test('updateNoteMetadata persists and getNoteMetadata retrieves', () async {
    final db = DatabaseService.createNew(
      databaseName:
          'test_note_meta_${DateTime.now().millisecondsSinceEpoch}.db',
    );

    // Create a minimal note
    const noteId = 'test-note-1';
    final dbInstance = await db.database;
    await dbInstance.insert('notes', {
      'id': noteId,
      'title': 'Test',
      'content': '',
      'type': 'text',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'pinned': 0,
      'isArchived': 0,
    });

    await db.updateNoteMetadata(noteId, {'markers': []});
    final meta = await db.getNoteMetadata(noteId);
    expect(meta, isNotNull);
    expect(meta!['markers'], isEmpty);
  });

  test('getNoteMetadata returns null for note with no metadata', () async {
    final db = DatabaseService.createNew(
      databaseName:
          'test_note_meta_null_${DateTime.now().millisecondsSinceEpoch}.db',
    );

    const noteId = 'test-note-2';
    final dbInstance = await db.database;
    await dbInstance.insert('notes', {
      'id': noteId,
      'title': 'Test',
      'content': '',
      'type': 'text',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'pinned': 0,
      'isArchived': 0,
    });

    final meta = await db.getNoteMetadata(noteId);
    expect(meta, isNull);
  });

  test('updateNoteMetadata with null clears metadata', () async {
    final db = DatabaseService.createNew(
      databaseName:
          'test_note_meta_clear_${DateTime.now().millisecondsSinceEpoch}.db',
    );

    const noteId = 'test-note-3';
    final dbInstance = await db.database;
    await dbInstance.insert('notes', {
      'id': noteId,
      'title': 'Test',
      'content': '',
      'type': 'text',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'pinned': 0,
      'isArchived': 0,
    });

    await db.updateNoteMetadata(noteId, {'markers': ['x']});
    await db.updateNoteMetadata(noteId, null);
    final meta = await db.getNoteMetadata(noteId);
    expect(meta, isNull);
  });
}
