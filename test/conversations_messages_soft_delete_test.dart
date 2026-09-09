// Tests for the M1.12 "conversations + conversation_messages family
// soft-delete conversion" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Phased
// delivery, M1.12; § Architecture 6, "orphan-message cleanup" / derived
// effective-deletedness).
//
// `conversations` gains a plain `__deleted__` tombstone column
// (straightforward entity tombstone, no derived-visibility complexity of
// its own). `conversation_messages` gains `__deleted__` for the first time
// ever, but a raw `__deleted__=1` there does NOT by itself mean the row is
// treated as deleted: `computeConversationMessageVisibility` derives
// effective visibility as `NOT __deleted__ OR (EXISTS a live
// conversation_message_mapping row referencing it)` — a message with any
// live membership is never effectively deleted, regardless of its raw
// flag or write ordering (round 14's cross-subject-race fix).
//
// `deleteConversationMessage`/`_deleteMessagesBatch`/`deleteConversation`/
// `deleteConversationExplicitly` are converted to tombstone writes for
// their own entity row(s), with explicit real-delete cascade-replacement
// for every OR-Set membership table (`conversation_message_mapping`,
// `conversation_tags`, `conversation_note_mapping`, `message_parents`)
// that used to be cleaned up implicitly via `ON DELETE CASCADE` before
// this milestone.
//
// `_cleanupEmptyConversations`/`deleteEmptyConversations` are NOT given
// the mechanical "swap DELETE for tombstone UPDATE" treatment — see their
// own doc comments in database_service.dart for the full reasoning this
// milestone worked through: writing `conversations.__deleted__` eagerly
// from a derived "is this conversation empty/redundant right now?" check
// would reintroduce, at the conversation level, the exact same
// cross-subject tombstone-vs-concurrent-membership-add race round 14
// already fixed for messages. Instead, "empty"/"redundant" becomes a pure,
// always-recomputed-at-read-time property consulted by
// `getAllConversations(includeEmpty: false)`, and the two cleanup
// functions are repurposed to only garbage-collect the now-permanently-
// unreachable OR-Set membership rows for such a conversation — never its
// own `__deleted__` column. This file tests that design decision directly
// (a conversation that becomes derived-empty is NOT tombstoned or removed,
// stays visible to `includeEmpty: true` callers, and becomes invisible
// only to `includeEmpty: false` callers).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_attachment.dart';
import 'package:note_synapse/services/database_service.dart';

/// The exact pre-M1.12 (DATABASE_VERSION <= 54) shape of `conversations`:
/// no `__deleted__` column. Hand-written rather than derived from
/// DatabaseService.getSchema() — as of M1.12, getSchema() already returns
/// the NEW DDL — same approach every prior soft-delete milestone's test
/// file established.
const _oldConversationsTableDdl = '''
    CREATE TABLE conversations(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      noteIds TEXT NOT NULL DEFAULT '[]',
      createdAt INTEGER NOT NULL,
      updatedAt INTEGER NOT NULL,
      isArchived INTEGER NOT NULL DEFAULT 0
    )
''';

/// The exact pre-M1.12 shape of `conversation_messages`: no `__deleted__`
/// column (it never had one before this milestone at all).
const _oldConversationMessagesTableDdl = '''
    CREATE TABLE conversation_messages(
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      content TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      modelUsed TEXT,
      metadata TEXT
    )
''';

Future<List<Map<String, Object?>>> _tableInfo(Database db, String table) =>
    db.rawQuery("PRAGMA table_info('$table')");

Future<bool> _hasColumn(Database db, String table, String column) async {
  final cols = await _tableInfo(db, table);
  return cols.any((c) => c['name'] == column);
}

Conversation _buildConversation(
  String id, {
  DateTime? createdAt,
  DateTime? updatedAt,
}) {
  final created = createdAt ?? DateTime.fromMillisecondsSinceEpoch(1000);
  return Conversation(
    id: id,
    title: 'Conversation $id',
    createdAt: created,
    updatedAt: updatedAt ?? created,
  );
}

ConversationMessage _buildMessage(String id, {DateTime? timestamp}) {
  return ConversationMessage(
    id: id,
    conversationId: '', // not persisted; managed by the mapping table
    type: MessageType.user,
    content: 'content for $id',
    timestamp: timestamp ?? DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group(
    'M1.12 conversations/conversation_messages soft-delete — fresh install',
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
        'conversations and conversation_messages both have __deleted__ '
        '(NOT NULL, default 0)',
        () async {
          final db = await databaseService.database;

          for (final table in ['conversations', 'conversation_messages']) {
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
    'M1.12 conversations/conversation_messages soft-delete — migration '
    'round-trip (v55 -> v56)',
    () {
      late Database preMigrationDb;

      setUp(() async {
        preMigrationDb = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
        );

        await preMigrationDb.execute(_oldConversationsTableDdl);
        await preMigrationDb.execute(_oldConversationMessagesTableDdl);

        for (final statement in DatabaseService.getSchema()) {
          if (statement.contains('CREATE TABLE conversations(') ||
              statement.contains('CREATE TABLE conversation_messages(')) {
            continue;
          }
          await preMigrationDb.execute(statement);
        }

        await preMigrationDb.execute('''
          CREATE TABLE _schema_version (version INTEGER NOT NULL)
        ''');
        await preMigrationDb.insert('_schema_version', {'version': 54});

        expect(
          await _hasColumn(preMigrationDb, 'conversations', '__deleted__'),
          isFalse,
        );
        expect(
          await _hasColumn(
            preMigrationDb,
            'conversation_messages',
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
          await preMigrationDb.insert('conversations', {
            'id': 'conv-1',
            'title': 'C1',
            'noteIds': '[]',
            'createdAt': 100,
            'updatedAt': 100,
            'isArchived': 0,
          });
          await preMigrationDb.insert('conversation_messages', {
            'id': 'msg-1',
            'type': 'user',
            'content': 'hi',
            'timestamp': 100,
          });

          final service = DatabaseService.createNew();
          await service.migrateBackupDatabase(preMigrationDb, 55, 56);

          expect(
            await _hasColumn(preMigrationDb, 'conversations', '__deleted__'),
            isTrue,
          );
          expect(
            await _hasColumn(
              preMigrationDb,
              'conversation_messages',
              '__deleted__',
            ),
            isTrue,
          );

          final conversations = await preMigrationDb.query('conversations');
          expect(conversations.single['id'], 'conv-1');
          expect(conversations.single['__deleted__'], 0);

          final messages = await preMigrationDb.query('conversation_messages');
          expect(messages.single['id'], 'msg-1');
          expect(messages.single['__deleted__'], 0);

          await service.close();
        },
      );

      test(
        'running the v55 -> v56 migration twice does not error and leaves '
        'schema/data unchanged the second time',
        () async {
          await preMigrationDb.insert('conversations', {
            'id': 'conv-1',
            'title': 'C1',
            'noteIds': '[]',
            'createdAt': 100,
            'updatedAt': 100,
            'isArchived': 0,
          });

          final service = DatabaseService.createNew();
          await service.migrateBackupDatabase(preMigrationDb, 55, 56);
          await service.migrateBackupDatabase(preMigrationDb, 55, 56);

          final cols = await _tableInfo(preMigrationDb, 'conversations');
          expect(cols.where((c) => c['name'] == '__deleted__').length, 1);

          final conversations = await preMigrationDb.query('conversations');
          expect(conversations.single['id'], 'conv-1');
          expect(conversations.single['__deleted__'], 0);

          await service.close();
        },
      );
    },
  );

  group('M1.12 computeConversationMessageVisibility — derived formula', () {
    late DatabaseService db;

    setUp(() async {
      db = DatabaseService.createNew();
      await db.database;
    });

    tearDown(() async {
      await db.close();
    });

    test('nonexistent message id is never visible', () async {
      expect(
        await db.computeConversationMessageVisibility('no-such-id'),
        isFalse,
      );
    });

    test(
      'raw __deleted__=0, live mapping exists -> visible (trivial case)',
      () async {
        await db.insertConversation(_buildConversation('conv-1'));
        await db.insertConversationMessage(_buildMessage('msg-1'));
        await db.insertConversationMessageMapping(
          conversationId: 'conv-1',
          messageId: 'msg-1',
        );

        expect(
          await db.computeConversationMessageVisibility('msg-1'),
          isTrue,
        );
      },
    );

    test(
      'raw __deleted__=1, live mapping exists -> visible (round-14 race fix: '
      'a live membership always wins over a stale tombstone bit)',
      () async {
        await db.insertConversation(_buildConversation('conv-1'));
        await db.insertConversationMessage(_buildMessage('msg-1'));
        await db.insertConversationMessageMapping(
          conversationId: 'conv-1',
          messageId: 'msg-1',
        );
        final rawDb = await db.database;
        await rawDb.update(
          'conversation_messages',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: ['msg-1'],
        );

        expect(
          await db.computeConversationMessageVisibility('msg-1'),
          isTrue,
        );
      },
    );

    test(
      'raw __deleted__=1, zero live memberships -> effectively deleted',
      () async {
        await db.insertConversation(_buildConversation('conv-1'));
        await db.insertConversationMessage(_buildMessage('msg-1'));
        // No mapping inserted at all.
        final rawDb = await db.database;
        await rawDb.update(
          'conversation_messages',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: ['msg-1'],
        );

        expect(
          await db.computeConversationMessageVisibility('msg-1'),
          isFalse,
        );
      },
    );

    test(
      'raw __deleted__=0, zero live memberships (never-tombstoned orphan) '
      '-> STILL visible: the formula is __deleted__ AND no-live-membership, '
      'not "no-live-membership alone" -- orphan detection is a separate, '
      'future write-side mechanism this milestone deliberately does not '
      'build (see doc comment)',
      () async {
        await db.insertConversationMessage(_buildMessage('msg-1'));
        // No conversation, no mapping -- a message that simply has never
        // been placed in any conversation, or lost its only one via
        // deleteConversation without ever being explicitly tombstoned
        // itself.

        expect(
          await db.computeConversationMessageVisibility('msg-1'),
          isTrue,
        );
      },
    );
  });

  group('M1.12 getConversationMessage — the one direct-by-id read path', () {
    late DatabaseService db;

    setUp(() async {
      db = DatabaseService.createNew();
      await db.database;
    });

    tearDown(() async {
      await db.close();
    });

    test('returns null for a nonexistent id', () async {
      expect(await db.getConversationMessage('missing'), isNull);
    });

    test(
      'returns null for an effectively-deleted message (tombstoned, zero '
      'live memberships)',
      () async {
        await db.insertConversationMessage(_buildMessage('msg-1'));
        final rawDb = await db.database;
        await rawDb.update(
          'conversation_messages',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: ['msg-1'],
        );

        expect(await db.getConversationMessage('msg-1'), isNull);
      },
    );

    test(
      'still returns the message when tombstoned but a live mapping exists '
      '(derived visibility overriding the raw flag)',
      () async {
        await db.insertConversation(_buildConversation('conv-1'));
        await db.insertConversationMessage(_buildMessage('msg-1'));
        await db.insertConversationMessageMapping(
          conversationId: 'conv-1',
          messageId: 'msg-1',
        );
        final rawDb = await db.database;
        await rawDb.update(
          'conversation_messages',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: ['msg-1'],
        );

        final result = await db.getConversationMessage('msg-1');
        expect(result, isNotNull);
        expect(result!.id, 'msg-1');
      },
    );
  });

  group('M1.12 deleteConversationMessage / _deleteMessagesBatch', () {
    late DatabaseService db;

    setUp(() async {
      db = DatabaseService.createNew();
      await db.database;
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'tombstones the message (row still present, __deleted__=1) instead '
      'of deleting it; real-deletes its mapping and message_parents rows; '
      'tombstones (not real-deletes) its attachment',
      () async {
        final rawDb = await db.database;

        await db.insertConversation(_buildConversation('conv-1'));
        await db.insertConversationMessage(_buildMessage('parent-1'));
        await db.insertConversationMessage(_buildMessage('msg-1'));
        await db.insertConversationMessageMapping(
          conversationId: 'conv-1',
          messageId: 'msg-1',
        );
        await db.insertMessageParent(
          messageId: 'msg-1',
          parentMessageId: 'parent-1',
        );
        await db.insertConversationAttachment(
          ConversationAttachment(
            id: 'att-1',
            messageId: 'msg-1',
            filePath: 'attachments/foo.png',
            fileName: 'foo.png',
            fileType: 'image/png',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        );

        await db.deleteConversationMessage('msg-1');

        final messageRows = await rawDb.query(
          'conversation_messages',
          where: 'id = ?',
          whereArgs: ['msg-1'],
        );
        expect(
          messageRows,
          hasLength(1),
          reason: 'the row must still physically exist (tombstone, not a '
              'real delete)',
        );
        expect(messageRows.single['__deleted__'], 1);

        final mappings = await rawDb.query(
          'conversation_message_mapping',
          where: 'messageId = ?',
          whereArgs: ['msg-1'],
        );
        expect(
          mappings,
          isEmpty,
          reason: 'the OR-Set membership row must be REAL-deleted',
        );

        final parentEdges = await rawDb.query(
          'message_parents',
          where: 'messageId = ? OR parentMessageId = ?',
          whereArgs: ['msg-1', 'msg-1'],
        );
        expect(parentEdges, isEmpty);

        final attachmentRows = await rawDb.query(
          'conversation_attachments',
          where: 'id = ?',
          whereArgs: ['att-1'],
        );
        expect(
          attachmentRows,
          hasLength(1),
          reason: 'the attachment row must still physically exist too '
              '(M1.12: tombstoned, not real-deleted, now that its parent '
              'message is also only ever tombstoned)',
        );
        expect(attachmentRows.single['__deleted__'], 1);

        // Effective visibility formula agrees: tombstoned + zero live
        // memberships = effectively deleted.
        expect(
          await db.computeConversationMessageVisibility('msg-1'),
          isFalse,
        );
      },
    );

    test(
      'deleteMessageWithSubtree tombstones an entire subtree, not just the '
      'root message',
      () async {
        final rawDb = await db.database;

        await db.insertConversation(_buildConversation('conv-1'));
        for (final id in ['root', 'child-1', 'child-2', 'grandchild']) {
          await db.insertConversationMessage(_buildMessage(id));
          await db.insertConversationMessageMapping(
            conversationId: 'conv-1',
            messageId: id,
          );
        }
        await db.insertMessageParent(
          messageId: 'child-1',
          parentMessageId: 'root',
        );
        await db.insertMessageParent(
          messageId: 'child-2',
          parentMessageId: 'root',
        );
        await db.insertMessageParent(
          messageId: 'grandchild',
          parentMessageId: 'child-1',
        );

        await db.deleteMessageWithSubtree('root');

        for (final id in ['root', 'child-1', 'child-2', 'grandchild']) {
          final rows = await rawDb.query(
            'conversation_messages',
            where: 'id = ?',
            whereArgs: [id],
          );
          expect(rows.single['__deleted__'], 1, reason: '$id should be tombstoned');
          expect(
            await db.computeConversationMessageVisibility(id),
            isFalse,
            reason: '$id should be effectively deleted (no live mapping left)',
          );
        }
      },
    );
  });

  group('M1.12 deleteConversation — tombstone + cascade replacement', () {
    late DatabaseService db;

    setUp(() async {
      db = DatabaseService.createNew();
      await db.database;
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'tombstones the conversation (row still present, __deleted__=1); '
      'real-deletes its message-mapping/tag/note-mapping rows; leaves its '
      'messages untouched',
      () async {
        final rawDb = await db.database;

        await db.insertConversation(_buildConversation('conv-1'));
        await db.insertConversationMessage(_buildMessage('msg-1'));
        await db.insertConversationMessageMapping(
          conversationId: 'conv-1',
          messageId: 'msg-1',
        );
        await rawDb.insert('tags', {
          'id': 'tag-1',
          'name': 'tag-1-name',
          'color': '#fff',
          'createdAt': 1000,
        });
        await rawDb.insert('conversation_tags', {
          'conversationId': 'conv-1',
          'tagId': 'tag-1',
        });
        await rawDb.insert('notes', {
          'id': 'note-1',
          'title': 'N1',
          'content': '',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });
        await db.insertConversationNoteMapping(
          conversationId: 'conv-1',
          noteId: 'note-1',
        );

        await db.deleteConversation('conv-1');

        final convRows = await rawDb.query(
          'conversations',
          where: 'id = ?',
          whereArgs: ['conv-1'],
        );
        expect(
          convRows,
          hasLength(1),
          reason: 'row must still physically exist (tombstone, not delete)',
        );
        expect(convRows.single['__deleted__'], 1);

        final tagMappings = await rawDb.query(
          'conversation_tags',
          where: 'conversationId = ?',
          whereArgs: ['conv-1'],
        );
        expect(
          tagMappings,
          isEmpty,
          reason: 'conversation_tags is an OR-Set table with a cascade that '
              'no longer fires -- must be explicitly real-deleted',
        );

        final msgMappings = await rawDb.query(
          'conversation_message_mapping',
          where: 'conversationId = ?',
          whereArgs: ['conv-1'],
        );
        expect(msgMappings, isEmpty);

        final noteMappings = await rawDb.query(
          'conversation_note_mapping',
          where: 'conversationId = ?',
          whereArgs: ['conv-1'],
        );
        expect(noteMappings, isEmpty);

        // The message itself is untouched -- deleteConversation never
        // touched conversation_messages, same as before this milestone.
        final msgRows = await rawDb.query(
          'conversation_messages',
          where: 'id = ?',
          whereArgs: ['msg-1'],
        );
        expect(msgRows.single['__deleted__'], 0);
      },
    );

    test('getConversation/getAllConversations no longer return a deleted conversation', () async {
      await db.insertConversation(_buildConversation('conv-1'));
      await db.deleteConversation('conv-1');

      expect(await db.getConversation('conv-1'), isNull);
      final all = await db.getAllConversations();
      expect(all.where((c) => c.id == 'conv-1'), isEmpty);
    });
  });

  group(
    'M1.12 deleteConversationExplicitly — tombstone + cascade replacement',
    () {
      late DatabaseService db;

      setUp(() async {
        db = DatabaseService.createNew();
        await db.database;
      });

      tearDown(() async {
        await db.close();
      });

      test(
        'tombstones the conversation, tombstones its messages via subtree '
        'deletion, and real-deletes its conversation_tags rows',
        () async {
          final rawDb = await db.database;

          await db.insertConversation(_buildConversation('conv-1'));
          await db.insertConversationMessage(_buildMessage('msg-1'));
          await db.insertConversationMessageMapping(
            conversationId: 'conv-1',
            messageId: 'msg-1',
          );
          await rawDb.insert('tags', {
            'id': 'tag-1',
            'name': 'tag-1-name',
            'color': '#fff',
            'createdAt': 1000,
          });
          await rawDb.insert('conversation_tags', {
            'conversationId': 'conv-1',
            'tagId': 'tag-1',
          });

          await db.deleteConversationExplicitly('conv-1');

          final convRows = await rawDb.query(
            'conversations',
            where: 'id = ?',
            whereArgs: ['conv-1'],
          );
          expect(convRows.single['__deleted__'], 1);

          final msgRows = await rawDb.query(
            'conversation_messages',
            where: 'id = ?',
            whereArgs: ['msg-1'],
          );
          expect(msgRows.single['__deleted__'], 1);

          final tagMappings = await rawDb.query(
            'conversation_tags',
            where: 'conversationId = ?',
            whereArgs: ['conv-1'],
          );
          expect(tagMappings, isEmpty);
        },
      );
    },
  );

  group(
    'M1.12 design decision — _cleanupEmptyConversations/'
    'deleteEmptyConversations no longer write conversations.__deleted__',
    () {
      late DatabaseService db;

      setUp(() async {
        db = DatabaseService.createNew();
        await db.database;
      });

      tearDown(() async {
        await db.close();
      });

      test(
        'a conversation that becomes empty via deleteMessageWithSubtree '
        '(which internally runs _cleanupEmptyConversations) is NOT '
        'tombstoned or removed -- it stays a live, __deleted__=0 row, '
        'visible to includeEmpty: true callers and getConversation, but '
        'excluded from includeEmpty: false listings; its now-orphaned '
        'conversation_tags row is garbage-collected',
        () async {
          final rawDb = await db.database;

          await db.insertConversation(_buildConversation('conv-1'));
          await db.insertConversationMessage(_buildMessage('msg-1'));
          await db.insertConversationMessageMapping(
            conversationId: 'conv-1',
            messageId: 'msg-1',
          );
          await rawDb.insert('tags', {
            'id': 'tag-1',
            'name': 'tag-1-name',
            'color': '#fff',
            'createdAt': 1000,
          });
          await rawDb.insert('conversation_tags', {
            'conversationId': 'conv-1',
            'tagId': 'tag-1',
          });

          // Deleting the conversation's only message makes it derived-empty
          // and internally triggers _cleanupEmptyConversations.
          await db.deleteMessageWithSubtree('msg-1');

          // The conversation row itself: still present, still __deleted__=0.
          final convRows = await rawDb.query(
            'conversations',
            where: 'id = ?',
            whereArgs: ['conv-1'],
          );
          expect(
            convRows,
            hasLength(1),
            reason: 'the design decision is to NOT tombstone a derived-'
                'empty conversation -- see doc comment in '
                'database_service.dart',
          );
          expect(convRows.single['__deleted__'], 0);

          // getConversation (direct lookup) still finds it.
          expect(await db.getConversation('conv-1'), isNotNull);

          // includeEmpty: true still returns it.
          final allIncludingEmpty = await db.getAllConversations();
          expect(
            allIncludingEmpty.where((c) => c.id == 'conv-1'),
            hasLength(1),
          );

          // includeEmpty: false excludes it.
          final nonEmptyOnly = await db.getAllConversations(
            includeEmpty: false,
          );
          expect(nonEmptyOnly.where((c) => c.id == 'conv-1'), isEmpty);

          // Its conversation_tags row was garbage-collected as a safe
          // OR-Set delete, even though the conversation itself was left
          // alone.
          final tagMappings = await rawDb.query(
            'conversation_tags',
            where: 'conversationId = ?',
            whereArgs: ['conv-1'],
          );
          expect(tagMappings, isEmpty);
        },
      );

      test(
        'a redundant conversation (all its messages already owned by an '
        'earlier conversation, no notes of its own) is excluded from '
        'includeEmpty: false but not from includeEmpty: true, and its own '
        'conversation_message_mapping row is garbage-collected once '
        '_cleanupEmptyConversations runs',
        () async {
          final rawDb = await db.database;

          await db.insertConversation(
            _buildConversation(
              'conv-earlier',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          );
          await db.insertConversation(
            _buildConversation(
              'conv-later',
              createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
            ),
          );
          await db.insertConversationMessage(_buildMessage('shared-msg'));
          await db.insertConversationMessageMapping(
            conversationId: 'conv-earlier',
            messageId: 'shared-msg',
          );
          await db.insertConversationMessageMapping(
            conversationId: 'conv-later',
            messageId: 'shared-msg',
          );

          // Trigger _cleanupEmptyConversations (it also runs the redundant
          // pass) via any message-subtree deletion elsewhere -- use an
          // unrelated throwaway message/conversation so `shared-msg`
          // itself isn't touched.
          await db.insertConversation(_buildConversation('conv-throwaway'));
          await db.insertConversationMessage(_buildMessage('throwaway-msg'));
          await db.insertConversationMessageMapping(
            conversationId: 'conv-throwaway',
            messageId: 'throwaway-msg',
          );
          await db.deleteMessageWithSubtree('throwaway-msg');

          // conv-later is redundant (its only message is already owned,
          // rank 1, by conv-earlier) and has no notes -- excluded from
          // includeEmpty: false.
          final nonEmptyOnly = await db.getAllConversations(
            includeEmpty: false,
          );
          expect(nonEmptyOnly.map((c) => c.id), contains('conv-earlier'));
          expect(
            nonEmptyOnly.map((c) => c.id),
            isNot(contains('conv-later')),
          );

          // includeEmpty: true still returns both.
          final allIncludingEmpty = await db.getAllConversations();
          expect(allIncludingEmpty.map((c) => c.id), contains('conv-earlier'));
          expect(allIncludingEmpty.map((c) => c.id), contains('conv-later'));

          // conv-later itself was never tombstoned.
          final convLaterRows = await rawDb.query(
            'conversations',
            where: 'id = ?',
            whereArgs: ['conv-later'],
          );
          expect(convLaterRows.single['__deleted__'], 0);

          // Its own (redundant) message mapping was garbage-collected...
          final laterMappings = await rawDb.query(
            'conversation_message_mapping',
            where: 'conversationId = ? AND messageId = ?',
            whereArgs: ['conv-later', 'shared-msg'],
          );
          expect(laterMappings, isEmpty);

          // ...but the earlier (canonical) conversation's own mapping for
          // the same message is untouched, so the message still has a live
          // membership and remains effectively visible.
          final earlierMappings = await rawDb.query(
            'conversation_message_mapping',
            where: 'conversationId = ? AND messageId = ?',
            whereArgs: ['conv-earlier', 'shared-msg'],
          );
          expect(earlierMappings, hasLength(1));
          expect(
            await db.computeConversationMessageVisibility('shared-msg'),
            isTrue,
          );
        },
      );

      test(
        'deleteEmptyConversations only real-deletes membership rows for '
        'candidates older than olderThan, never tombstones conversations, '
        'and does not apply the "redundant" condition (scope unchanged '
        'from pre-M1.12)',
        () async {
          final rawDb = await db.database;
          final old = DateTime.now().subtract(const Duration(days: 10));
          final recent = DateTime.now();

          await db.insertConversation(
            _buildConversation(
              'conv-old-empty',
              createdAt: old,
              updatedAt: old,
            ),
          );
          await db.insertConversation(
            _buildConversation(
              'conv-recent-empty',
              createdAt: recent,
              updatedAt: recent,
            ),
          );
          await rawDb.insert('tags', {
            'id': 'tag-1',
            'name': 'tag-1-name',
            'color': '#fff',
            'createdAt': 1000,
          });
          await rawDb.insert('conversation_tags', {
            'conversationId': 'conv-old-empty',
            'tagId': 'tag-1',
          });

          await db.deleteEmptyConversations(olderThan: const Duration(days: 1));

          // Neither conversation row was tombstoned or removed.
          for (final id in ['conv-old-empty', 'conv-recent-empty']) {
            final rows = await rawDb.query(
              'conversations',
              where: 'id = ?',
              whereArgs: [id],
            );
            expect(rows, hasLength(1));
            expect(rows.single['__deleted__'], 0);
          }

          // The old one's membership rows were garbage-collected...
          final oldTagMappings = await rawDb.query(
            'conversation_tags',
            where: 'conversationId = ?',
            whereArgs: ['conv-old-empty'],
          );
          expect(oldTagMappings, isEmpty);

          // includeEmpty: false still excludes BOTH (age only gates the
          // membership-row GC side effect, not the derived-visibility read
          // filter, which has no age concept at all).
          final nonEmptyOnly = await db.getAllConversations(
            includeEmpty: false,
          );
          expect(
            nonEmptyOnly.map((c) => c.id),
            isNot(contains('conv-old-empty')),
          );
          expect(
            nonEmptyOnly.map((c) => c.id),
            isNot(contains('conv-recent-empty')),
          );
        },
      );
    },
  );
}
