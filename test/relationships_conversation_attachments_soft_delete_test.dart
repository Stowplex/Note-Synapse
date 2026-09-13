// Tests for the M1.8 "relationships + conversation_attachments soft-delete
// conversion" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Phased
// delivery — the seven dependency-ordered sub-milestones list: "M1.8 —
// `relationships` + `conversation_attachments`: independent entities,
// touched only on explicit removal (no reinsert pattern).
// `NoteModificationService._applyLinkModifications`'s dual `txn`/non-`txn`
// code paths need converting consistently — flagged as the one place most
// likely to drift.").
//
// `relationships`/`conversation_attachments` gain a `__deleted__` tombstone
// column; `deleteRelationship`/`deleteRelationshipBetween`/
// `deleteRelationshipsForNote`/`deleteConversationAttachment` become
// ordinary tombstone writes instead of real SQL deletes; every read path in
// both tables filters on `__deleted__ = 0`.
//
// `_applyLinkModifications` (note_modification_service.dart) has two
// separate code paths for removing a relationship depending on whether a
// `txn` was passed in: one issues a direct SQL delete against `relationships`,
// the other calls `DatabaseService.deleteRelationshipBetween`. Both are
// converted here and both are tested directly, since the scoping pass
// flagged this as the single most likely place for the two paths to drift.
//
// `_deleteMessagesBatch`'s own `conversation_attachments` delete (a side
// effect of deleting `conversation_messages` rows) was deliberately left as
// a real delete by THIS milestone — `conversation_messages` itself had no
// `__deleted__` column yet and was scoped to M1.12. **M1.12 update**: now
// that `conversation_messages` itself is soft-delete (see
// test/conversations_messages_soft_delete_test.dart), that deferred
// conversion has landed too — `_deleteMessagesBatch`'s
// `conversation_attachments` delete is now ALSO a tombstone write, for the
// same "the parent row is only tombstoned, not physically gone, so its
// children shouldn't be either" reasoning as every other conversion in
// this effort. The group below, which used to assert the OLD (real-delete)
// behavior, is updated accordingly rather than left to bit-rot or be
// deleted outright — a future regression reintroducing a real delete here
// is still caught, just against the corrected expectation.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_attachment.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';

/// The exact pre-M1.8 (DATABASE_VERSION <= 53) shape of `relationships`: no
/// `__deleted__` column. Hand-written rather than derived from
/// DatabaseService.getSchema() — as of M1.8, getSchema() already returns the
/// NEW DDL — same approach test/filters_workflow_bindings_soft_delete_test.dart
/// established for M1.7.
const _oldRelationshipsTableDdl = '''
    CREATE TABLE relationships(
      id TEXT PRIMARY KEY,
      fromNoteId TEXT NOT NULL,
      toNoteId TEXT NOT NULL,
      type TEXT NOT NULL,
      createdAt INTEGER NOT NULL,
      FOREIGN KEY (fromNoteId) REFERENCES notes (id) ON DELETE CASCADE,
      FOREIGN KEY (toNoteId) REFERENCES notes (id) ON DELETE CASCADE
    )
''';

/// The exact pre-M1.8 shape of `conversation_attachments`: no `__deleted__`
/// column.
const _oldConversationAttachmentsTableDdl = '''
    CREATE TABLE conversation_attachments(
      id TEXT PRIMARY KEY,
      messageId TEXT NOT NULL,
      filePath TEXT NOT NULL,
      fileName TEXT NOT NULL,
      fileType TEXT NOT NULL,
      isRelativePath INTEGER NOT NULL DEFAULT 0,
      createdAt INTEGER NOT NULL,
      FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE
    )
''';

Future<List<Map<String, Object?>>> _tableInfo(Database db, String table) =>
    db.rawQuery("PRAGMA table_info('$table')");

Future<bool> _hasColumn(Database db, String table, String column) async {
  final cols = await _tableInfo(db, table);
  return cols.any((c) => c['name'] == column);
}

Note _buildNote(String id) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Note(
    id: id,
    title: 'Note $id',
    content: 'content',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
  );
}

Relationship _buildRelationship({
  required String id,
  required String fromNoteId,
  required String toNoteId,
  String type = 'related',
}) {
  return Relationship(
    id: id,
    fromNoteId: fromNoteId,
    toNoteId: toNoteId,
    type: type,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group(
    'M1.8 relationships/conversation_attachments soft-delete — fresh install',
    () {
      late DatabaseService databaseService;

      setUp(() async {
        databaseService = DatabaseService.createNew();
        await databaseService.database;
      });

      tearDown(() async {
        await databaseService.close();
      });

      test(
        'relationships and conversation_attachments both have __deleted__ '
        '(NOT NULL, default 0)',
        () async {
          final db = await databaseService.database;

          for (final table in ['relationships', 'conversation_attachments']) {
            final cols = await _tableInfo(db, table);
            final deletedCol = cols.firstWhere(
              (c) => c['name'] == '__deleted__',
            );
            expect(
              deletedCol['notnull'],
              1,
              reason: '$table.__deleted__ should be NOT NULL',
            );
            expect(
              deletedCol['dflt_value'],
              '0',
              reason: '$table.__deleted__ should default to 0',
            );
          }
        },
      );
    },
  );

  group(
    'M1.8 relationships/conversation_attachments soft-delete — migration '
    'round-trip (v53 -> v54)',
    () {
      late Database preMigrationDb;

      setUp(() async {
        preMigrationDb = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
        );

        // Old-shape tables must exist before getSchema()'s own
        // _createIndexes statements run below.
        await preMigrationDb.execute(_oldRelationshipsTableDdl);
        await preMigrationDb.execute(_oldConversationAttachmentsTableDdl);

        for (final statement in DatabaseService.getSchema()) {
          if (statement.contains('CREATE TABLE relationships(') ||
              statement.contains('CREATE TABLE conversation_attachments(')) {
            continue;
          }
          await preMigrationDb.execute(statement);
        }

        await preMigrationDb.execute('''
          CREATE TABLE _schema_version (version INTEGER NOT NULL)
        ''');
        await preMigrationDb.insert('_schema_version', {'version': 53});

        expect(
          await _hasColumn(preMigrationDb, 'relationships', '__deleted__'),
          isFalse,
        );
        expect(
          await _hasColumn(
            preMigrationDb,
            'conversation_attachments',
            '__deleted__',
          ),
          isFalse,
        );
      });

      tearDown(() async {
        await preMigrationDb.close();
      });

      test(
        'existing rows in both tables survive migration with __deleted__=0, '
        'ids unchanged',
        () async {
          await preMigrationDb.insert('notes', {
            'id': 'note-1',
            'title': 'N1',
            'content': '',
            'type': 'note',
            'createdAt': 100,
            'updatedAt': 100,
          });
          await preMigrationDb.insert('notes', {
            'id': 'note-2',
            'title': 'N2',
            'content': '',
            'type': 'note',
            'createdAt': 100,
            'updatedAt': 100,
          });
          await preMigrationDb.insert('relationships', {
            'id': 'rel-1',
            'fromNoteId': 'note-1',
            'toNoteId': 'note-2',
            'type': 'related',
            'createdAt': 100,
          });

          await preMigrationDb.insert('conversation_messages', {
            'id': 'msg-1',
            'type': 'user',
            'content': 'hi',
            'timestamp': 100,
          });
          await preMigrationDb.insert('conversation_attachments', {
            'id': 'att-1',
            'messageId': 'msg-1',
            'filePath': 'attachments/foo.png',
            'fileName': 'foo.png',
            'fileType': 'image/png',
            'isRelativePath': 1,
            'createdAt': 100,
          });

          final service = DatabaseService.createNew();
          await service.migrateBackupDatabase(preMigrationDb, 53, 54);

          expect(
            await _hasColumn(preMigrationDb, 'relationships', '__deleted__'),
            isTrue,
          );
          expect(
            await _hasColumn(
              preMigrationDb,
              'conversation_attachments',
              '__deleted__',
            ),
            isTrue,
          );

          final relationships = await preMigrationDb.query('relationships');
          expect(relationships.single['id'], 'rel-1');
          expect(relationships.single['__deleted__'], 0);

          final attachments = await preMigrationDb.query(
            'conversation_attachments',
          );
          expect(attachments.single['id'], 'att-1');
          expect(attachments.single['__deleted__'], 0);
        },
      );

      test(
        'running the v53 -> v54 migration twice does not error and leaves '
        'schema/data unchanged the second time',
        () async {
          await preMigrationDb.insert('notes', {
            'id': 'note-1',
            'title': 'N1',
            'content': '',
            'type': 'note',
            'createdAt': 100,
            'updatedAt': 100,
          });
          await preMigrationDb.insert('notes', {
            'id': 'note-2',
            'title': 'N2',
            'content': '',
            'type': 'note',
            'createdAt': 100,
            'updatedAt': 100,
          });
          await preMigrationDb.insert('relationships', {
            'id': 'rel-1',
            'fromNoteId': 'note-1',
            'toNoteId': 'note-2',
            'type': 'related',
            'createdAt': 100,
          });

          final service = DatabaseService.createNew();
          await service.migrateBackupDatabase(preMigrationDb, 53, 54);
          final afterFirst = await preMigrationDb.query(
            'relationships',
            orderBy: 'id',
          );

          await service.migrateBackupDatabase(preMigrationDb, 53, 54);
          final afterSecond = await preMigrationDb.query(
            'relationships',
            orderBy: 'id',
          );

          expect(afterSecond, equals(afterFirst));
        },
      );
    },
  );

  group(
    'M1.8 soft-delete confirmation — tombstone writes, not real deletes',
    () {
      late DatabaseService databaseService;
      late Database db;

      setUp(() async {
        databaseService = DatabaseService.createNew();
        db = await databaseService.database;
        await databaseService.insertNote(_buildNote('note-1'));
        await databaseService.insertNote(_buildNote('note-2'));
        await databaseService.insertNote(_buildNote('note-3'));
      });

      tearDown(() async {
        await databaseService.close();
      });

      test(
        'deleteRelationship writes a single __deleted__=1 update; row count '
        'unchanged',
        () async {
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-1',
              fromNoteId: 'note-1',
              toNoteId: 'note-2',
            ),
          );

          final rowsBefore = await db.query('relationships');
          await databaseService.deleteRelationship('rel-1');
          final rowsAfter = await db.query('relationships');

          expect(rowsAfter.length, rowsBefore.length);
          expect(rowsAfter.single['__deleted__'], 1);
        },
      );

      test(
        'deleteRelationshipBetween writes a single __deleted__=1 update; '
        'row count unchanged; removes both directions and every type '
        '(unfiltered by type, matching the pre-existing semantics)',
        () async {
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-1',
              fromNoteId: 'note-1',
              toNoteId: 'note-2',
              type: 'related',
            ),
          );
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-2',
              fromNoteId: 'note-2',
              toNoteId: 'note-1',
              type: 'answers',
            ),
          );
          // Unrelated relationship, must survive untouched.
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-3',
              fromNoteId: 'note-1',
              toNoteId: 'note-3',
            ),
          );

          await databaseService.deleteRelationshipBetween('note-1', 'note-2');

          final rows = await db.query('relationships', orderBy: 'id');
          expect(rows.length, 3, reason: 'no real row was deleted');
          expect(
            rows.firstWhere((r) => r['id'] == 'rel-1')['__deleted__'],
            1,
          );
          expect(
            rows.firstWhere((r) => r['id'] == 'rel-2')['__deleted__'],
            1,
          );
          expect(
            rows.firstWhere((r) => r['id'] == 'rel-3')['__deleted__'],
            0,
          );
        },
      );

      test(
        'deleteRelationshipsForNote tombstones every relationship touching '
        'that note in either direction; row count unchanged',
        () async {
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-1',
              fromNoteId: 'note-1',
              toNoteId: 'note-2',
            ),
          );
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-2',
              fromNoteId: 'note-3',
              toNoteId: 'note-1',
            ),
          );
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-3',
              fromNoteId: 'note-2',
              toNoteId: 'note-3',
            ),
          );

          await databaseService.deleteRelationshipsForNote('note-1');

          final rows = await db.query('relationships', orderBy: 'id');
          expect(rows.length, 3);
          expect(
            rows.firstWhere((r) => r['id'] == 'rel-1')['__deleted__'],
            1,
          );
          expect(
            rows.firstWhere((r) => r['id'] == 'rel-2')['__deleted__'],
            1,
          );
          expect(
            rows.firstWhere((r) => r['id'] == 'rel-3')['__deleted__'],
            0,
            reason: 'does not touch note-1, must stay live',
          );
        },
      );

      test(
        'deleteConversationAttachment writes a single __deleted__=1 update; '
        'row count unchanged',
        () async {
          await databaseService.insertConversationMessage(
            ConversationMessage(
              id: 'msg-1',
              conversationId: 'conv-1',
              type: MessageType.user,
              content: 'hi',
              timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          );
          await databaseService.insertConversationAttachment(
            ConversationAttachment(
              id: 'att-1',
              messageId: 'msg-1',
              filePath: 'attachments/foo.png',
              fileName: 'foo.png',
              fileType: 'image/png',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          );

          final rowsBefore = await db.query('conversation_attachments');
          await databaseService.deleteConversationAttachment('att-1');
          final rowsAfter = await db.query('conversation_attachments');

          expect(rowsAfter.length, rowsBefore.length);
          expect(rowsAfter.single['__deleted__'], 1);
        },
      );
    },
  );

  group('M1.8 read-path filtering', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
      await databaseService.insertNote(_buildNote('note-1'));
      await databaseService.insertNote(_buildNote('note-2'));
      await databaseService.insertNote(_buildNote('note-3'));
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'getRelationships/getOutgoingRelationships/getIncomingRelationships '
      'hide a tombstoned relationship',
      () async {
        await databaseService.insertRelationship(
          _buildRelationship(
            id: 'rel-1',
            fromNoteId: 'note-1',
            toNoteId: 'note-2',
          ),
        );
        await databaseService.insertRelationship(
          _buildRelationship(
            id: 'rel-2',
            fromNoteId: 'note-3',
            toNoteId: 'note-1',
          ),
        );

        expect(await databaseService.getRelationships('note-1'), hasLength(2));
        expect(
          await databaseService.getOutgoingRelationships('note-1'),
          hasLength(1),
        );
        expect(
          await databaseService.getIncomingRelationships('note-1'),
          hasLength(1),
        );

        await databaseService.deleteRelationship('rel-1');

        expect(await databaseService.getRelationships('note-1'), hasLength(1));
        expect(
          await databaseService.getOutgoingRelationships('note-1'),
          isEmpty,
        );
        expect(
          await databaseService.getIncomingRelationships('note-1'),
          hasLength(1),
        );
      },
    );

    test('relationshipExists is false once tombstoned', () async {
      await databaseService.insertRelationship(
        _buildRelationship(
          id: 'rel-1',
          fromNoteId: 'note-1',
          toNoteId: 'note-2',
          type: 'related',
        ),
      );
      expect(
        await databaseService.relationshipExists('note-1', 'note-2', 'related'),
        isTrue,
      );

      await databaseService.deleteRelationship('rel-1');

      expect(
        await databaseService.relationshipExists('note-1', 'note-2', 'related'),
        isFalse,
      );
    });

    test(
      'getConversationAttachments hides a tombstoned attachment',
      () async {
        await databaseService.insertConversationMessage(
          ConversationMessage(
            id: 'msg-1',
            conversationId: 'conv-1',
            type: MessageType.user,
            content: 'hi',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        );
        await databaseService.insertConversationAttachment(
          ConversationAttachment(
            id: 'att-1',
            messageId: 'msg-1',
            filePath: 'attachments/foo.png',
            fileName: 'foo.png',
            fileType: 'image/png',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        );
        await databaseService.insertConversationAttachment(
          ConversationAttachment(
            id: 'att-2',
            messageId: 'msg-1',
            filePath: 'attachments/bar.png',
            fileName: 'bar.png',
            fileType: 'image/png',
            createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
          ),
        );

        expect(
          await databaseService.getConversationAttachments('msg-1'),
          hasLength(2),
        );

        await databaseService.deleteConversationAttachment('att-1');

        final remaining = await databaseService.getConversationAttachments(
          'msg-1',
        );
        expect(remaining.map((a) => a.id), ['att-2']);
      },
    );
  });

  group(
    'M1.8 _applyLinkModifications dual txn/non-txn code paths, both '
    'converted consistently',
    () {
      late DatabaseService databaseService;
      late Database db;
      late NoteModificationService service;

      setUp(() async {
        databaseService = DatabaseService.createNew();
        db = await databaseService.database;
        service = NoteModificationService(databaseService);
        await databaseService.insertNote(_buildNote('note-1'));
        await databaseService.insertNote(_buildNote('note-2'));
      });

      tearDown(() async {
        await databaseService.close();
      });

      test(
        'non-txn path (txn: null): removing a link tombstones the '
        'relationship instead of deleting it',
        () async {
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-1',
              fromNoteId: 'note-1',
              toNoteId: 'note-2',
              type: 'related',
            ),
          );

          await service.applyLinkModificationsForTest('note-1', {
            'added': [],
            'removed': ['note-2'],
          }, txn: null);

          final rows = await db.query('relationships');
          expect(rows.length, 1, reason: 'no real row was deleted');
          expect(rows.single['__deleted__'], 1);
          expect(
            await databaseService.relationshipExists(
              'note-1',
              'note-2',
              'related',
            ),
            isFalse,
          );
        },
      );

      test(
        'txn path: removing a link tombstones the relationship instead of '
        'deleting it, using the identical where clause as the non-txn path',
        () async {
          await databaseService.insertRelationship(
            _buildRelationship(
              id: 'rel-1',
              fromNoteId: 'note-1',
              toNoteId: 'note-2',
              type: 'related',
            ),
          );

          await db.transaction((txn) async {
            await service.applyLinkModificationsForTest('note-1', {
              'added': [],
              'removed': ['note-2'],
            }, txn: txn);
          });

          final rows = await db.query('relationships');
          expect(rows.length, 1, reason: 'no real row was deleted');
          expect(rows.single['__deleted__'], 1);
          expect(
            await databaseService.relationshipExists(
              'note-1',
              'note-2',
              'related',
            ),
            isFalse,
          );
        },
      );
    },
  );

  group(
    'M1.12 _deleteMessagesBatch conversation_attachments -- now tombstoned, '
    'not a real delete (resolves the M1.8-era deferral above)',
    () {
      late DatabaseService databaseService;
      late Database db;

      setUp(() async {
        databaseService = DatabaseService.createNew();
        db = await databaseService.database;
      });

      tearDown(() async {
        await databaseService.close();
      });

      test(
        'deleteMessageWithSubtree tombstones the conversation_attachments '
        'row for that message (still physically present, __deleted__=1), '
        'not a real delete',
        () async {
          await databaseService.insertConversationMessage(
            ConversationMessage(
              id: 'msg-1',
              conversationId: 'conv-1',
              type: MessageType.user,
              content: 'hi',
              timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          );
          await databaseService.insertConversationAttachment(
            ConversationAttachment(
              id: 'att-1',
              messageId: 'msg-1',
              filePath: 'attachments/foo.png',
              fileName: 'foo.png',
              fileType: 'image/png',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          );

          await databaseService.deleteMessageWithSubtree('msg-1');

          final rows = await db.query(
            'conversation_attachments',
            where: 'id = ?',
            whereArgs: ['att-1'],
          );
          expect(
            rows,
            hasLength(1),
            reason:
                'M1.12: conversation_messages itself is now soft-delete too, '
                'so its batch-delete side effect on conversation_attachments '
                'is now a tombstone write, not a real delete -- the row must '
                'still physically exist',
          );
          expect(rows.single['__deleted__'], 1);
        },
      );
    },
  );
}
