import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late DatabaseService service;
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    service = DatabaseService.createNew();
    db = await service.database;
    for (final id in ['original', 'other']) {
      await db.insert('notes', {
        'id': id,
        'title': id,
        'content': '',
        'type': 'note',
        'createdAt': 1,
        'updatedAt': 1,
      });
    }
    await db.insert('attachments', {
      'id': 'attachment',
      'noteId': 'original',
      'filePath': 'report.pdf',
      'fileName': 'report.pdf',
      'fileType': 'pdf',
      'createdAt': 1,
      'includeInAIContext': 0,
    });
  });

  tearDown(() => service.close());

  Future<int> insertChunk(String sourceType, {String? sourceId}) =>
      db.insert('search_chunks', {
        'chunkKey': 'original:$sourceType',
        'noteId': 'original',
        'sourceType': sourceType,
        'sourceId': sourceId,
        'seq': 0,
        'text': 'searchable attachment content',
        'contentHash': 'hash',
        'updatedAt': 1,
      });

  for (final sourceType in ['attachment_text', 'attachment_ocr', 'figure']) {
    test(
      '$sourceType disappears immediately when its attachment is deleted',
      () async {
        final id = await insertChunk(sourceType, sourceId: 'attachment');
        final before = await service.getSearchChunksByIds([id]);
        expect(before, hasLength(1));
        // Exclusion from AI must still leave a live attachment visible to users.
        expect(before.single.attachmentIncludeInAIContext, isFalse);
        await db.update(
          'attachments',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: ['attachment'],
        );
        expect(await service.getSearchChunksByIds([id]), isEmpty);
        // No asynchronous index cleanup has run: the stale row still exists.
        expect(await db.query('search_chunks'), hasLength(1));
      },
    );

    test(
      '$sourceType cannot expose a chunk under the previous owner',
      () async {
        final id = await insertChunk(sourceType, sourceId: 'attachment');
        await db.update(
          'attachments',
          {'noteId': 'other'},
          where: 'id = ?',
          whereArgs: ['attachment'],
        );
        expect(await service.getSearchChunksByIds([id]), isEmpty);
      },
    );

    test('$sourceType requires an existing source attachment', () async {
      final id = await insertChunk(sourceType, sourceId: 'missing');
      expect(await service.getSearchChunksByIds([id]), isEmpty);
    });
  }

  test(
    'note-derived chunks need no attachment and honor note tombstones',
    () async {
      final ids = <int>[];
      for (final type in ['meta', 'note_body', 'subnote', 'annotation']) {
        ids.add(await insertChunk(type));
      }
      expect(await service.getSearchChunksByIds(ids), hasLength(ids.length));
      await db.update(
        'notes',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: ['original'],
      );
      expect(await service.getSearchChunksByIds(ids), isEmpty);
    },
  );
}
