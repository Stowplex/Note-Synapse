import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _WindowDatabase implements Database {
  _WindowDatabase(this.delegate);
  final Database delegate;
  int noteChunks = 0;
  bool failNoteChunks = false;

  List<Map<String, Object?>> _bounded(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      final size = row.values.fold<int>(0, (sum, value) {
        if (value is String) return sum + utf8.encode(value).length;
        if (value is Uint8List) return sum + value.length;
        return sum + 8;
      });
      if (size > 2 * 1024 * 1024) {
        throw StateError('simulated Android CursorWindow overflow');
      }
    }
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (sql.startsWith('SELECT substr(') && sql.contains('FROM "notes"')) {
      noteChunks++;
      if (failNoteChunks && noteChunks >= 2) {
        throw StateError('simulated incomplete note read');
      }
    }
    return _bounded(await delegate.rawQuery(sql, arguments));
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
  }) async => _bounded(
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

  @override
  Future<void> close() => delegate.close();
  @override
  bool get isOpen => delegate.isOpen;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WindowService extends DatabaseService {
  _WindowService() : super.createNew();
  _WindowDatabase? window;
  Future<Database> get raw => super.database;
  @override
  Future<Database> get database async =>
      window ??= _WindowDatabase(await super.database);
}

Future<void> _insertNote(Database db, String content) => db
    .insert('notes', {
      'id': 'historical',
      'title': 'Preserved note',
      'content': content,
      'type': 'note',
      'createdAt': 1,
      'updatedAt': 2,
      'pinned': 1,
    })
    .then((_) {});

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  test(
    'startup and legacy note views preserve large Unicode and embedded NUL',
    () async {
      final service = _WindowService();
      addTearDown(service.close);
      final db = await service.raw;
      final content = 'prefix\u0000${'正文😀' * 300000}note-tail';
      final child = 'prefix\u0000${'子笔记😀' * 220000}child-tail';
      await _insertNote(db, content);
      await db.insert('subnotes', {
        'id': 'child',
        'noteId': 'historical',
        'name': 'Child',
        'content': child,
        'createdAt': 1,
        'isCompleted': 0,
      });
      await db.insert('tags', {
        'id': 'tag',
        'name': 'retained',
        'color': '#123456',
        'createdAt': 1,
      });
      await db.insert('note_tags', {'noteId': 'historical', 'tagId': 'tag'});

      for (final read in [
        service.getAllNotes,
        service.getPinnedNotes,
        () => service.getNotesByArchiveStatus(isArchived: false),
        () => service.getNotesByTag('retained'),
      ]) {
        final note = (await read()).single;
        expect(note.content, content);
        expect(note.subNotes.single.content, child);
      }
      expect((await service.getNote('historical'))?.content, content);
      expect((await service.getSubNotes('historical')).single.content, child);
      await db.update('notes', {'isArchived': 1});
      expect((await service.getArchivedNotes()).single.content, content);
      expect(service.window!.noteChunks, greaterThan(1));
    },
  );

  test(
    'legacy revision readers use the same complete byte-slice helper',
    () async {
      final service = _WindowService();
      addTearDown(service.close);
      final db = await service.raw;
      final code = 'prefix\u0000${'代码😀' * 300000}revision-tail';
      await db.insert('user_apps', {
        'id': 'app',
        'uuid': 'uuid',
        'name': 'App',
        'description': '',
        'steps': '[]',
        'htmlContent': '',
        'createdAt': 1,
        'updatedAt': 2,
      });
      await db.insert('app_revisions', {
        'id': 'revision',
        'appId': 'app',
        'revisionNumber': 1,
        'revisionTimestamp': 1,
        'userPrompt': '',
        'aiResponse': '',
        'appCode': code,
      });
      expect((await service.getAppRevisions('app')).single.appCode, code);
      expect((await service.getAppRevision('revision'))?.appCode, code);
      expect((await service.getLatestAppRevision('app'))?.appCode, code);
    },
  );

  test(
    'failed startup text read aborts instead of erasing content or references',
    () async {
      final service = _WindowService();
      addTearDown(service.close);
      final db = await service.raw;
      final content = 'x' * (2 * 1024 * 1024);
      await _insertNote(db, content);
      await db.insert('conversations', {
        'id': 'conversation',
        'title': 'Conversation',
        'createdAt': 1,
        'updatedAt': 2,
      });
      await db.insert('conversation_note_mapping', {
        'conversationId': 'conversation',
        'noteId': 'historical',
        'createdAt': 1,
      });
      await service.database;
      service.window!.failNoteChunks = true;
      await expectLater(service.getAllNotes(), throwsA(isA<StateError>()));
      await expectLater(
        service.cleanupInvalidNoteReferences(),
        throwsA(isA<StateError>()),
      );
      expect(await db.query('conversation_note_mapping'), hasLength(1));
      expect((await db.query('notes')).single['content'], content);
    },
  );
}
