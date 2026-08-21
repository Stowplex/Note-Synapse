import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';

void main() {
  late DatabaseService db;
  late DataChangeNotifier notifier;
  late NoteModificationService service;
  late List<DataChangeEvent> events;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    getIt.registerSingleton<DatabaseService>(db);
    getIt.registerSingleton<TagWorkflowService>(TagWorkflowService(db));
    notifier = DataChangeNotifier();
    events = [];
    notifier.addListener((event) async => events.add(event));
    service = NoteModificationService(db, changeNotifier: notifier);
  });

  tearDown(() async {
    await db.close();
  });

  Future<Note> insertNote({
    String id = 'note-1',
    List<String> tags = const [],
  }) async {
    final now = DateTime.now();
    final note = Note(
      id: id,
      title: 'title',
      content: 'original content',
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
      tags: tags,
    );
    await db.insertNote(note);
    return note;
  }

  DataChangeEvent merged() =>
      events.fold(const DataChangeEvent(), (a, b) => a.merge(b));

  group('createNote', () {
    test('publishes the new note id and tag change post-commit', () async {
      final note = await service.createNote({
        'title': 'created',
        'content': 'body',
        'tags': ['t1'],
      });
      await notifier.waitForIdle();

      expect(await db.getNote(note.id), isNotNull);
      expect(merged().noteIds, {note.id});
      expect(merged().tagsChanged, isTrue);
    });

    test('publishes relationship endpoints for created links', () async {
      final target = await insertNote();
      final note = await service.createNote({
        'title': 'linked',
        'content': 'body',
        'link': [
          {'relation': 'related', 'target': target.id},
        ],
      });
      await notifier.waitForIdle();

      expect(merged().noteIds, {note.id});
      expect(merged().relationshipNoteIds, {note.id, target.id});
    });
  });

  group('applyModifications', () {
    test('persists and publishes the note id', () async {
      final note = await insertNote();
      await service.applyModifications(note.id, {
        'content': {'action': 'append', 'text': 'appended'},
      });
      await notifier.waitForIdle();

      final stored = await db.getNote(note.id);
      expect(stored!.content, contains('appended'));
      expect(merged().noteIds, {note.id});
      expect(merged().tagsChanged, isFalse);
    });

    test('publishes tagsChanged for tag modifications', () async {
      final note = await insertNote();
      await service.applyModifications(note.id, {
        'tags': {'added': ['fresh-tag'], 'removed': []},
      });
      await notifier.waitForIdle();

      expect(merged().tagsChanged, isTrue);
      final stored = await db.getNote(note.id);
      expect(stored!.tags, contains('fresh-tag'));
    });

    test('publishes relationship endpoints from the payload, including '
        'removals', () async {
      final note = await insertNote();
      // Real rows: relationships carry FK constraints on both endpoints.
      await insertNote(id: 'target-a');
      await insertNote(id: 'target-b');
      await service.applyModifications(note.id, {
        'link': {
          'added': [
            {'relation': 'related', 'target': 'target-a'},
          ],
          'removed': ['target-b'],
        },
      });
      await notifier.waitForIdle();

      expect(
        merged().relationshipNoteIds,
        {note.id, 'target-a', 'target-b'},
      );
    });

    test('atomicity: a link failure rolls back the note update and publishes '
        'nothing', () async {
      final note = await insertNote();

      await expectLater(
        service.applyModifications(note.id, {
          'content': {'action': 'replace', 'text': 'should not commit'},
          'link': {
            'added': [
              // target must be a String; the cast failure throws inside the
              // transaction after the note row was already written.
              {'relation': 'related', 'target': 42},
            ],
          },
        }),
        throwsA(anything),
      );
      await notifier.waitForIdle();

      final stored = await db.getNote(note.id);
      expect(stored!.content, 'original content',
          reason: 'the note update must roll back with the failed link');
      expect(events, isEmpty,
          reason: 'nothing committed, so nothing may be published');
    });
  });

  group('persistence safety', () {
    test('applyModifications preserves notes.metadata (markers)', () async {
      final note = await insertNote();
      await db.updateNoteMetadata(note.id, {'markers': [{'id': 'm1'}]});

      await service.applyModifications(note.id, {
        'content': {'action': 'append', 'text': 'more'},
      });

      final metadata = await db.getNoteMetadata(note.id);
      expect(metadata?['markers'], isNotEmpty,
          reason: 'modifications must not wipe marker metadata');
    });

    test('DatabaseService.updateNote on a deleted note creates no orphan '
        'child rows', () async {
      final note = await insertNote(tags: ['orphan-tag']);
      await db.deleteNote(note.id);

      await db.updateNote(note);

      final rawDb = await db.database;
      // M1.10: deleteNote now tombstones `notes` instead of really
      // deleting the row (`__deleted__=1`, `AND __deleted__ = 0` is what
      // makes updateNote's own guard correctly skip re-inserting child
      // rows below -- see updateNote's own doc comment).
      final notesRows = await rawDb.query(
        'notes',
        where: 'id = ?',
        whereArgs: [note.id],
      );
      expect(notesRows.single['__deleted__'], 1);
      expect(
        await rawDb.query('note_tags', where: 'noteId = ?', whereArgs: [note.id]),
        isEmpty,
        reason: 'no child rows may be re-created for a deleted note',
      );
      expect(
        await rawDb.query('subnotes', where: 'noteId = ?', whereArgs: [note.id]),
        isEmpty,
      );
    });

    test('applyModifications on a concurrently-deleted note throws and '
        'publishes nothing', () async {
      final note = await insertNote();
      await db.deleteNote(note.id);
      await notifier.waitForIdle();
      events.clear();

      await expectLater(
        service.applyModifications(note.id, {
          'content': {'action': 'append', 'text': 'x'},
        }),
        throwsA(anything),
      );
      await notifier.waitForIdle();
      expect(events, isEmpty);
    });
  });

  group('applyBatchModifications', () {
    test('publishes one merged event for all updated notes', () async {
      final now = DateTime.now();
      for (final id in ['b1', 'b2']) {
        await db.insertNote(Note(
          id: id,
          title: id,
          content: 'content',
          type: NoteType.note,
          createdAt: now,
          updatedAt: now,
        ));
      }

      await service.applyBatchModifications([
        {
          'note_id': 'b1',
          'modification': {
            'content': {'action': 'append', 'text': 'x'},
          },
        },
        {
          'note_id': 'b2',
          'modification': {
            'tags': {'added': ['batch-tag'], 'removed': []},
          },
        },
      ]);
      await notifier.waitForIdle();

      expect(events, hasLength(1));
      expect(events.single.noteIds, {'b1', 'b2'});
      expect(events.single.tagsChanged, isTrue);
    });
  });
}
