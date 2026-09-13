import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Desktop SQLite has no CursorWindow. Bound the rows at the actual reader
/// boundary so a plain SELECT of the oversized source fails this regression.
class _BoundedDatabase implements Database {
  _BoundedDatabase(this.delegate);
  final Database delegate;
  final List<String> queries = [];
  int chunkReads = 0;

  @override
  Future<void> close() => delegate.close();

  @override
  bool get isOpen => delegate.isOpen;

  List<Map<String, Object?>> _check(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      final bytes = row.values.fold<int>(0, (sum, value) {
        if (value is String) return sum + utf8.encode(value).length;
        if (value is Uint8List) return sum + value.length;
        return sum + 8;
      });
      if (bytes > 2 * 1024 * 1024) {
        throw StateError('row exceeds Android CursorWindow');
      }
    }
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    queries.add(sql);
    if (sql.startsWith('SELECT substr(')) chunkReads++;
    return _check(await delegate.rawQuery(sql, arguments));
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    return _check(
      await delegate.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BoundedService extends DatabaseService {
  _BoundedService() : super.createNew();
  _BoundedDatabase? bounded;
  Future<Database> get unbounded => super.database;

  @override
  Future<Database> get database async =>
      bounded ??= _BoundedDatabase(await super.database);
}

void main() {
  test(
    'note and subnote sources survive a bounded Android-sized row window',
    () async {
      final service = _BoundedService();
      addTearDown(service.close);
      final db = await service.unbounded;
      // Embedded NUL defeats SQLite length(TEXT); UTF-8 bytes must be used.
      final noteText = 'before\u0000${'正文😀' * 300000}note-tail';
      final subnoteText = 'before\u0000${'子笔记😀' * 250000}subnote-tail';
      await db.insert('notes', {
        'id': 'large',
        'title': 'Historical note',
        'content': noteText,
        'type': 'note',
        'createdAt': 1,
        'updatedAt': 2,
      });
      await db.insert('subnotes', {
        'id': 'child',
        'noteId': 'large',
        'name': 'Historical subnote',
        'content': subnoteText,
        'createdAt': 1,
        'isCompleted': 0,
      });
      // This metadata isn't needed to assemble note paths and must stay out of
      // that reader, even though old PDF marker metadata can be very large.
      await db.insert('attachments', {
        'id': 'attachment',
        'noteId': 'large',
        'fileName': 'source.pdf',
        'filePath': '/missing/source.pdf',
        'isRelativePath': 0,
        'fileType': 'pdf',
        'createdAt': 1,
        'metadata': jsonEncode({'legacy': 'x' * (3 * 1024 * 1024)}),
      });
      final note = (await service.getNotesByIds(['large'])).single;
      expect(note.content, noteText);
      expect(note.subNotes.single.content, subnoteText);
      expect(service.bounded!.chunkReads, greaterThan(2));
    },
  );

  test(
    'annotation indexing reads large content but omits large path payloads',
    () async {
      final service = DatabaseService.createNew();
      addTearDown(service.close);
      final db = await service.database;
      await db.insert('notes', {
        'id': 'large',
        'title': 'Historical note',
        'content': '',
        'type': 'note',
        'createdAt': 1,
        'updatedAt': 2,
      });
      final content = 'before\u0000${'批注😀' * 300000}annotation-tail';
      await db.insert('note_annotations', {
        'id': 'annotation',
        'note_id': 'large',
        'content': content,
        'attachment_paths': jsonEncode(['x' * (3 * 1024 * 1024)]),
        'created_at': '2026-01-01T00:00:00.000',
      });
      final reader = _BoundedDatabase(db);
      final annotations = await NoteIndexService.loadIndexAnnotations(reader, [
        'large',
      ]);
      expect(annotations['large']!.single.content, content);
      expect(reader.chunkReads, greaterThan(2));
      expect(
        reader.queries.any((q) => q.contains('attachment_paths')),
        isFalse,
      );
    },
  );

  test(
    'large attachment and note metadata retain all search exclusion policy',
    () async {
      final service = _BoundedService();
      addTearDown(service.close);
      final db = await service.unbounded;
      final largeMetadata = 'x' * (3 * 1024 * 1024);
      await db.insert('notes', {
        'id': 'owner',
        'title': 'Historical note',
        'content': '',
        'type': 'note',
        'createdAt': 1,
        'updatedAt': 2,
        'metadata': jsonEncode({
          'searchIndex': {'exclude': true},
          'legacy': largeMetadata,
        }),
      });
      await db.insert('attachments', {
        'id': 'attachment',
        'noteId': 'owner',
        'fileName': 'source.pdf',
        'filePath': '/missing/source.pdf',
        'isRelativePath': 0,
        'fileType': 'pdf',
        'createdAt': 1,
        'includeInAIContext': 0,
        'metadata': jsonEncode({
          'searchIndex': {'text': 'off', 'ocr': false, 'embed': false},
          'legacy': largeMetadata,
        }),
      });
      final metadata = await service.getNoteMetadata('owner');
      expect(NoteIndexService.isNoteSearchExcluded(metadata), isTrue);
      final incrementalAttachment = (await service.getAttachmentsForNote(
        'owner',
      )).single;
      expect(
        incrementalAttachment.getSearchIndexConfig().isFullyExcluded,
        isTrue,
      );
      expect(incrementalAttachment.metadata!['legacy'], largeMetadata);
      final work = await NoteIndexService.loadIndexAttachments(
        await service.database,
      );
      final (attachment, excluded) = work.single;
      expect(excluded, isTrue);
      expect(attachment.getSearchIndexConfig().isFullyExcluded, isTrue);
      expect(attachment.includeInAIContext, isFalse);
      expect(
        attachment.metadata!.containsKey('legacy'),
        isFalse,
        reason:
            'backfill retains only index inputs after safely reading the full policy',
      );
      final hydrated = (await NoteIndexService.hydrateIndexEmbedPolicies(
        await service.database,
        [
          {
            'liveNoteId': 'owner',
            'attachmentId': 'attachment',
            'noteMetadata': null,
            'attachmentMetadata': null,
            'noteMetadataBytes': largeMetadata.length + 100,
            'attachmentMetadataBytes': largeMetadata.length + 100,
          },
        ],
      )).single;
      expect(
        jsonDecode(
          hydrated['noteMetadata'] as String,
        )['searchIndex']['exclude'],
        isTrue,
      );
      expect(
        jsonDecode(
          hydrated['attachmentMetadata'] as String,
        )['searchIndex']['embed'],
        isFalse,
      );
      expect(service.bounded!.chunkReads, greaterThan(2));
    },
  );
}
