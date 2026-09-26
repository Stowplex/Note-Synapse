import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/plugin_facing_exception.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/models/note.dart';

@GenerateMocks([DatabaseService, TagWorkflowService])
import 'note_modification_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late MockTagWorkflowService mockTagWorkflow;
  late NoteModificationService service;
  Database? rawDb;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockTagWorkflow = MockTagWorkflowService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<TagWorkflowService>(mockTagWorkflow);
    // Default: no immutable bindings
    when(
      mockTagWorkflow.hasImmutableBinding(any),
    ).thenAnswer((_) async => false);
    service = NoteModificationService(getIt<DatabaseService>());
  });

  tearDown(() async {
    await rawDb?.close();
    rawDb = null;
    await resetForTesting();
  });

  // applyModifications persists through db.transaction, so tests that reach
  // persistence stub mockDb.database with a real in-memory database. Built
  // from DatabaseService.getSchema() — the production DDL — so this can
  // never drift from the real table definitions.
  Future<Database> openRawNotesDb() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    for (final statement in DatabaseService.getSchema()) {
      await raw.execute(statement);
    }
    return raw;
  }

  Future<void> seedRawNote(Note note) async {
    await rawDb!.insert('notes', {
      'id': note.id,
      'title': note.title,
      'content': note.content,
      'type': 'note',
      'createdAt': note.createdAt.millisecondsSinceEpoch,
      'updatedAt': note.updatedAt.millisecondsSinceEpoch,
      'pinned': 0,
      'isArchived': 0,
    });
  }

  Future<String> rawNoteContent(String id) async {
    final rows = await rawDb!.query('notes', where: 'id = ?', whereArgs: [id]);
    return rows.single['content'] as String;
  }

  group('NoteModificationService', () {
    test('applyModifications fetches note from database', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Original content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      rawDb = await openRawNotesDb();
      await seedRawNote(note);
      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.database).thenAnswer((_) async => rawDb!);

      await service.applyModifications('test-id', {
        'content': {'action': 'append', 'text': 'More'},
      });

      verify(mockDb.getNoteById('test-id')).called(1);
    });

    test('applyModifications rejects an empty (no-op) modification before '
        'touching the database', () async {
      expect(
        () => service.applyModifications('test-id', {}),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('no recognized fields'),
          ),
        ),
      );
      verifyNever(mockDb.getNoteById(any));
    });

    test('applyModifications throws when note not found', () async {
      when(mockDb.getNoteById('missing-id')).thenAnswer((_) async => null);

      expect(
        () => service.applyModifications('missing-id', {
          'content': {'action': 'append', 'text': 'x'},
        }),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'applyModifications rejects scalar content with a self-describing error',
      () async {
        // The agent commonly sends content as a raw string instead of the
        // {action, text} object. Previously this surfaced as an opaque
        // type-cast error; now it must explain the expected shape.
        expect(
          () => service.applyModifications('test-id', {
            'content': '### Summary text',
            'tags': {
              'added': ['ingested'],
            },
          }),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('"content"'),
                contains('expected an object'),
                contains('action'),
              ),
            ),
          ),
        );
        // Validation happens before the DB is touched.
        verifyNever(mockDb.getNoteById(any));
      },
    );

    test('applyModifications rejects array-shaped tags field', () async {
      expect(
        () => service.applyModifications('test-id', {
          'tags': ['ingested'],
        }),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('"tags"'), contains('added')),
          ),
        ),
      );
    });

    test('applyModifications appends content when action is append', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Original',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      rawDb = await openRawNotesDb();
      await seedRawNote(note);
      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.database).thenAnswer((_) async => rawDb!);

      final result = await service.applyModifications('test-id', {
        'content': {'action': 'append', 'text': ' appended'},
      });

      expect(result.content, 'Original\n appended');
      expect(await rawNoteContent('test-id'), 'Original\n appended');
    });

    test('empty replace clears the whole note', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: r'\[x\]',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      rawDb = await openRawNotesDb();
      await seedRawNote(note);
      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.database).thenAnswer((_) async => rawDb!);

      final result = await service.applyModifications('test-id', {
        'content': {'action': 'replace', 'text': ''},
      });

      expect(result.content, isEmpty);
      expect(await rawNoteContent('test-id'), isEmpty);
    });

    test('applyModifications can append within a markdown section', () async {
      final note = Note(
        id: 'test-id',
        title: 'Index',
        content: '# Index\n\n## Entities\n- Existing\n\n## Topics\n- Topic',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      rawDb = await openRawNotesDb();
      await seedRawNote(note);
      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.database).thenAnswer((_) async => rawDb!);

      final result = await service.applyModifications('test-id', {
        'content': {
          'action': 'append',
          'section': '## Entities',
          'insert_position': 'append',
          'text': '- Added entity',
        },
      });

      expect(
        result.content,
        contains('## Entities\n- Existing\n\n- Added entity'),
      );
      expect(result.content, contains('## Topics\n- Topic'));
      expect(
        await rawNoteContent('test-id'),
        contains('## Entities\n- Existing\n\n- Added entity'),
      );
    });

    group('replace_text', () {
      const readingRecord =
          '## 2026-07-30\n'
          '- [ ] Book A\n'
          '\n'
          '## 2026-07-31\n'
          '- [ ] Book A\n'
          '- [ ] Book B\n';

      Note recordNote() => Note(
        id: 'record-1',
        title: 'Reading Record',
        content: readingRecord,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      Future<Note> apply(Map<String, dynamic> content, {Note? note}) async {
        final target = note ?? recordNote();
        rawDb ??= await openRawNotesDb();
        await seedRawNote(target);
        when(mockDb.getNoteById(target.id)).thenAnswer((_) async => target);
        when(mockDb.database).thenAnswer((_) async => rawDb!);
        return service.applyModifications(target.id, {'content': content});
      }

      test('replaces a unique match (checks off a list item)', () async {
        final result = await apply({
          'action': 'replace_text',
          'old_text': '- [ ] Book B',
          'new_text': '- [x] Book B',
        });
        expect(result.content, contains('- [x] Book B'));
        expect(result.content, isNot(contains('- [ ] Book B')));
        // Other items untouched.
        expect(result.content, contains('## 2026-07-30\n- [ ] Book A'));
      });

      test('ambiguous match changes nothing and instructs disambiguation',
          () async {
        try {
          await apply({
            'action': 'replace_text',
            'old_text': '- [ ] Book A',
            'new_text': '- [x] Book A',
          });
          fail('expected an exception');
        } catch (e) {
          expect('$e', contains('matched 2 places'));
          expect('$e', contains('section'));
        }
      });

      test('section scope disambiguates a repeated item', () async {
        final result = await apply({
          'action': 'replace_text',
          'old_text': '- [ ] Book A',
          'new_text': '- [x] Book A',
          'section': '## 2026-07-31',
        });
        expect(result.content, contains('## 2026-07-30\n- [ ] Book A'));
        expect(result.content, contains('- [x] Book A\n- [ ] Book B'));
      });

      test('no match changes nothing and reports it', () async {
        try {
          await apply({
            'action': 'replace_text',
            'old_text': '- [ ] Book C',
            'new_text': '- [x] Book C',
          });
          fail('expected an exception');
        } catch (e) {
          expect('$e', contains('not found'));
          expect('$e', contains('no changes were made'));
        }
      });

      test('already-applied retry is an idempotent success', () async {
        final alreadyChecked = recordNote().copyWith(
          content: readingRecord.replaceFirst('- [ ] Book B', '- [x] Book B'),
        );
        final result = await apply({
          'action': 'replace_text',
          'old_text': '- [ ] Book B',
          'new_text': '- [x] Book B',
        }, note: alreadyChecked);
        expect(result.content, alreadyChecked.content);
      });

      test('old_text + new_text without an action infer replace_text', () async {
        final result = await apply({
          'old_text': '- [ ] Book B',
          'new_text': '- [x] Book B',
        });
        expect(result.content, contains('- [x] Book B'));
        expect(result.content, isNot(contains('- [ ] Book B')));
      });

      test('replaces a table Status cell (trace scenario)', () async {
        final tableNote = recordNote().copyWith(
          content:
              '## 2026-08-03\n'
              '| Status | Book Title | Count |\n'
              '| :----- | :--------- | ----- |\n'
              '|        | 小猪皮皮的游乐园之梦 |   1    |\n',
        );
        final result = await apply({
          'action': 'replace_text',
          'old_text': '|        | 小猪皮皮的游乐园之梦 |   1    |',
          'new_text': '| Done   | 小猪皮皮的游乐园之梦 |   1    |',
        }, note: tableNote);
        expect(result.content, contains('| Done   | 小猪皮皮的游乐园之梦'));
      });

      test('not-found, multiple-match and unknown-section failures are '
          'plugin-facing', () async {
        final failures = <Map<String, dynamic>>[
          {'old_text': '- [ ] Book C', 'new_text': '- [x] Book C'},
          {'old_text': '- [ ] Book A', 'new_text': '- [x] Book A'},
          {
            'old_text': '- [ ] Book A',
            'new_text': '- [x] Book A',
            'section': '## Missing',
          },
        ];
        final messages = <String>[];
        for (var i = 0; i < failures.length; i++) {
          final content = failures[i];
          try {
            await apply({
              'action': 'replace_text',
              ...content,
            }, note: recordNote().copyWith(id: 'record-fail-$i'));
            fail('expected an exception for $content');
          } on PluginFacingException catch (e) {
            messages.add(e.message);
          }
        }
        expect(messages[0], startsWith('replace_text: "old_text" was not found'));
        expect(messages[1], startsWith('replace_text: "old_text" matched 2'));
        expect(messages[2], 'Section not found: ## Missing');
      });

      test('missing old_text is rejected with the expected shape', () async {
        try {
          await apply({'action': 'replace_text', 'new_text': 'x'});
          fail('expected an exception');
        } catch (e) {
          expect('$e', contains('old_text'));
          expect('$e', contains('replace_text'));
        }
      });
    });

    group('subnote.updated', () {
      final created = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      Note checklist() => Note(
        id: 'list-1',
        title: 'Checklist',
        content: '',
        type: NoteType.note,
        createdAt: created,
        updatedAt: created,
        subNotes: [
          SubNote(id: 's1', name: 'One', content: 'a', createdAt: created),
          SubNote(id: 's2', name: 'Two', content: 'b', createdAt: created),
          SubNote(id: 's3', name: 'Three', content: 'c', createdAt: created),
        ],
      );

      Future<Note> apply(Map<String, dynamic> subnote) async {
        final note = checklist();
        if (rawDb == null) {
          rawDb = await openRawNotesDb();
          await seedRawNote(note);
        }
        when(mockDb.getNoteById(note.id)).thenAnswer((_) async => note);
        when(mockDb.database).thenAnswer((_) async => rawDb!);
        return service.applyModifications(note.id, {'subnote': subnote});
      }

      test('updates fields in place and keeps every id', () async {
        final result = await apply({
          'updated': [
            {'id': 's2', 'isCompleted': true},
            {'id': 's3', 'name': 'Three!', 'content': 'c2'},
          ],
        });
        expect(result.subNotes.map((s) => s.id), ['s1', 's2', 's3']);
        expect(result.subNotes[1].isCompleted, isTrue);
        expect(result.subNotes[1].name, 'Two');
        expect(result.subNotes[2].name, 'Three!');
        expect(result.subNotes[2].content, 'c2');
        expect(result.subNotes[2].isCompleted, isFalse);
        expect(result.subNotes[0].createdAt, created);

        final rows = await rawDb!.query(
          'subnotes',
          where: 'noteId = ?',
          whereArgs: ['list-1'],
          orderBy: 'id',
        );
        expect(rows.map((r) => r['id']), ['s1', 's2', 's3']);
        expect(rows.map((r) => r['isCompleted']), [0, 1, 0]);
      });

      test('combines with removed and added', () async {
        final result = await apply({
          'removed': ['s1'],
          'updated': [
            {'id': 's2', 'isCompleted': true},
          ],
          'added': [
            {'name': 'Four'},
          ],
        });
        expect(result.subNotes.map((s) => s.name), ['Two', 'Three', 'Four']);
        expect(result.subNotes.first.id, 's2');
        expect(result.subNotes.first.isCompleted, isTrue);
      });

      test('an id in both removed and updated is removed, not an error',
          () async {
        final result = await apply({
          'removed': ['s1'],
          'updated': [
            {'id': 's1', 'isCompleted': true},
            {'id': 's2', 'isCompleted': true},
          ],
        });
        expect(result.subNotes.map((s) => s.id), ['s2', 's3']);
        expect(result.subNotes.first.isCompleted, isTrue);
      });

      test('an empty or blank name leaves the name unchanged', () async {
        final result = await apply({
          'updated': [
            {'id': 's1', 'name': ''},
            {'id': 's2', 'name': '   '},
          ],
        });
        expect(result.subNotes.map((s) => s.name), ['One', 'Two', 'Three']);
      });

      test('an unknown id refuses the modification with a plugin-facing '
          'error', () async {
        await expectLater(
          apply({
            'updated': [
              {'id': 's2', 'isCompleted': true},
              {'id': 'gone', 'isCompleted': true},
            ],
          }),
          throwsA(
            isA<PluginFacingException>().having(
              (e) => e.message,
              'message',
              contains('Subnote gone not found in note list-1'),
            ),
          ),
        );
        final rows = await rawDb!.query('subnotes');
        expect(rows, isEmpty, reason: 'nothing was persisted');
      });

      test('rejects malformed entries', () async {
        for (final bad in <dynamic>[
          'not-a-list',
          [
            {'isCompleted': true},
          ],
          [
            {'id': 's1', 'isCompleted': 'yes'},
          ],
        ]) {
          await expectLater(
            apply({'updated': bad}),
            throwsA(isA<PluginFacingException>()),
            reason: '$bad',
          );
        }
      });
    });

    test('applyModifications throws when section does not exist', () async {
      final note = Note(
        id: 'test-id',
        title: 'Index',
        content: '# Index\n\n## Topics\n- Topic',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);

      expect(
        () => service.applyModifications('test-id', {
          'content': {
            'action': 'append',
            'section': '## Entities',
            'insert_position': 'append',
            'text': '- Added entity',
          },
        }),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'applyBatchModifications validates all notes before writing',
      () async {
        when(mockDb.getNoteById('note-1')).thenAnswer(
          (_) async => Note(
            id: 'note-1',
            title: 'One',
            content: 'A',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        when(mockDb.getNoteById('missing')).thenAnswer((_) async => null);

        expect(
          () => service.applyBatchModifications([
            {
              'note_id': 'note-1',
              'modification': {
                'content': {'action': 'append', 'text': 'x'},
              },
            },
            {
              'note_id': 'missing',
              'modification': {
                'content': {'action': 'append', 'text': 'y'},
              },
            },
          ]),
          throwsA(isA<Exception>()),
        );
        verifyNever(mockDb.database);
      },
    );

    test(
      'applyBatchModifications reports scalar modification by index with an '
      'instructive message, never a raw cast error',
      () async {
        for (final badValue in [4, 'Infinity', 1]) {
          try {
            await service.applyBatchModifications([
              {'note_id': 'note-1', 'modification': badValue},
            ]);
            fail('expected an exception for $badValue');
          } catch (e) {
            expect('$e', contains('modifications[0].modification'));
            expect('$e', contains('expected an object'));
            expect('$e', isNot(contains('is not a subtype')));
          }
        }
        verifyNever(mockDb.database);
      },
    );

    test(
      'applyBatchModifications reports non-string note_id instead of '
      'raw-casting it',
      () async {
        try {
          await service.applyBatchModifications([
            {
              'note_id': 42,
              'modification': {
                'content': {'action': 'append', 'text': 'x'},
              },
            },
          ]);
          fail('expected an exception');
        } catch (e) {
          expect('$e', contains('modifications[0].note_id'));
          expect('$e', isNot(contains('is not a subtype')));
        }
      },
    );

    test('empty and unrecognized modifications are rejected as no-ops',
        () async {
      for (final noOp in [
        <String, dynamic>{},
        {'content': null},
        {'bogus_field': 'x'},
      ]) {
        try {
          await service.applyBatchModifications([
            {'note_id': 'note-1', 'modification': noOp},
          ]);
          fail('expected an exception for $noOp');
        } catch (e) {
          expect('$e', isNot(contains('is not a subtype')));
        }
      }
      verifyNever(mockDb.database);
    });

    test(
      'applyBatchModifications writes atomically on in-memory database',
      () async {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        rawDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

        await rawDb!.execute('''
        CREATE TABLE notes (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          type TEXT NOT NULL,
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL,
          scheduledAt TEXT,
          completeBy TEXT,
          status TEXT,
          completionPercentage REAL,
          pinned INTEGER NOT NULL DEFAULT 0,
          isArchived INTEGER NOT NULL DEFAULT 0,
          recurrenceRule TEXT,
          metadata TEXT
        )
      ''');
        await rawDb!.execute('''
        CREATE TABLE subnotes (
          id TEXT PRIMARY KEY,
          noteId TEXT NOT NULL,
          name TEXT NOT NULL,
          content TEXT NOT NULL,
          createdAt INTEGER NOT NULL,
          isCompleted INTEGER NOT NULL DEFAULT 0
        )
      ''');
        await rawDb!.execute('''
        CREATE TABLE tags (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          color TEXT,
          createdAt INTEGER NOT NULL,
          usageCount INTEGER NOT NULL DEFAULT 0
        )
      ''');
        await rawDb!.execute('''
        CREATE TABLE note_tags (
          noteId TEXT NOT NULL,
          tagId TEXT NOT NULL,
          PRIMARY KEY (noteId, tagId)
        )
      ''');
        await rawDb!.execute('''
        CREATE TABLE attachments (
          id TEXT PRIMARY KEY,
          noteId TEXT NOT NULL,
          filePath TEXT NOT NULL,
          fileName TEXT NOT NULL,
          fileType TEXT NOT NULL,
          isRelativePath INTEGER NOT NULL DEFAULT 0,
          createdAt INTEGER NOT NULL,
          includeInAIContext INTEGER NOT NULL DEFAULT 1
        )
      ''');
        await rawDb!.execute('''
        CREATE TABLE relationships (
          id TEXT PRIMARY KEY,
          fromNoteId TEXT NOT NULL,
          toNoteId TEXT NOT NULL,
          type TEXT NOT NULL,
          createdAt INTEGER NOT NULL
        )
      ''');

        final now = DateTime.now();
        final indexNote = Note(
          id: 'index-1',
          title: 'Index',
          content: '# Index\n\n## Entities\n- Existing',
          type: NoteType.note,
          createdAt: now,
          updatedAt: now,
        );
        final logNote = Note(
          id: 'log-1',
          title: 'Log',
          content: '## Log',
          type: NoteType.note,
          createdAt: now,
          updatedAt: now,
        );
        for (final note in [indexNote, logNote]) {
          await rawDb!.insert('notes', {
            'id': note.id,
            'title': note.title,
            'content': note.content,
            'type': 'note',
            'createdAt': note.createdAt.millisecondsSinceEpoch,
            'updatedAt': note.updatedAt.millisecondsSinceEpoch,
            'pinned': 0,
            'isArchived': 0,
          });
        }

        when(mockDb.getNoteById('index-1')).thenAnswer((_) async => indexNote);
        when(mockDb.getNoteById('log-1')).thenAnswer((_) async => logNote);
        when(mockDb.database).thenAnswer((_) async => rawDb!);

        final updated = await service.applyBatchModifications([
          {
            'note_id': 'index-1',
            'modification': {
              'content': {
                'action': 'append',
                'section': '## Entities',
                'insert_position': 'append',
                'text': '- Added entity',
              },
            },
          },
          {
            'note_id': 'log-1',
            'modification': {
              'content': {
                'action': 'append',
                'text': '\n## 2026-04-06\n- Added entity',
              },
            },
          },
        ]);

        expect(updated, hasLength(2));
        final indexRow = await rawDb!.query(
          'notes',
          columns: ['content'],
          where: 'id = ?',
          whereArgs: ['index-1'],
        );
        final logRow = await rawDb!.query(
          'notes',
          columns: ['content'],
          where: 'id = ?',
          whereArgs: ['log-1'],
        );
        expect(indexRow.single['content'], contains('- Added entity'));
        expect(logRow.single['content'], contains('## 2026-04-06'));
      },
    );
  });
}
