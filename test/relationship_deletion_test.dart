import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/service_locator.dart';

// applyModifications persists notes and link changes inside one transaction,
// so these tests run against a real in-memory database and assert on the
// relationships table itself instead of verifying mock delegation.
void main() {
  late DatabaseService db;
  late NoteModificationService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> insertNote(String id) async {
    final now = DateTime.now();
    await db.insertNote(Note(
      id: id,
      title: 'Note $id',
      content: 'Content',
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
      tags: const ['wiki-compiled-ml'],
    ));
  }

  Future<Set<String>> relationshipTargets(String fromId) async {
    // M1.8: relationships is now soft-delete only -- a removed relationship
    // row still physically exists (tombstoned), so this helper must filter
    // to live rows the same way every real read path
    // (DatabaseService.getRelationships et al.) now does.
    final rows = await (await db.database).query(
      'relationships',
      where: '(fromNoteId = ? OR toNoteId = ?) AND __deleted__ = 0',
      whereArgs: [fromId, fromId],
    );
    return rows
        .expand((r) => [r['fromNoteId'] as String, r['toNoteId'] as String])
        .where((id) => id != fromId)
        .toSet();
  }

  setUp(() async {
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    getIt.registerSingleton<DatabaseService>(db);
    getIt.registerSingleton<TagWorkflowService>(TagWorkflowService(db));
    service = NoteModificationService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('link.removed in modify_note', () {
    test('deletes relationship when removed contains target noteId', () async {
      await insertNote('note-1');
      await insertNote('note-b');
      await service.applyModifications('note-1', {
        'link': [
          {'relation': 'related', 'target': 'note-b'},
        ],
      });
      expect(await relationshipTargets('note-1'), {'note-b'});

      await service.applyModifications('note-1', {
        'link': {
          'removed': ['note-b'],
        },
      });

      expect(await relationshipTargets('note-1'), isEmpty);
    });

    test('creates AND deletes relationships in same call', () async {
      await insertNote('note-1');
      await insertNote('old-target');
      await insertNote('new-target');
      await service.applyModifications('note-1', {
        'link': [
          {'relation': 'related', 'target': 'old-target'},
        ],
      });

      await service.applyModifications('note-1', {
        'link': {
          'added': [
            {'relation': 'related', 'target': 'new-target'},
          ],
          'removed': ['old-target'],
        },
      });

      expect(await relationshipTargets('note-1'), {'new-target'});
    });

    test('existing link creation behavior unchanged (array of objects)',
        () async {
      await insertNote('note-1');
      await insertNote('note-c');

      await service.applyModifications('note-1', {
        'link': [
          {'relation': 'related', 'target': 'note-c'},
        ],
      });

      expect(await relationshipTargets('note-1'), {'note-c'});
    });
  });
}
