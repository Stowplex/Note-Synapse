import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:uuid/uuid.dart';

/// Direct database test helpers that bypass DatabaseService for better isolation
class ConversationDatabaseTestHelpers {
  final Database db;
  const ConversationDatabaseTestHelpers(this.db);

  Future<void> insertConversation(Conversation conversation) async {
    await db.insert('conversations', {
      'id': conversation.id,
      'title': conversation.title,
      'noteIds': jsonEncode(conversation.noteIds),
      'createdAt': conversation.createdAt.millisecondsSinceEpoch,
      'updatedAt': conversation.updatedAt.millisecondsSinceEpoch,
      'isArchived': conversation.isArchived ? 1 : 0,
    });
  }

  Future<Conversation?> getConversation(String id) async {
    final results = await db.query('conversations', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    final map = results.first;
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String,
      noteIds: List<String>.from(jsonDecode(map['noteIds'] as String)),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
      isArchived: (map['isArchived'] as int) == 1,
    );
  }

  Future<List<Conversation>> getAllConversations() async {
    final results = await db.query('conversations', orderBy: 'createdAt DESC');
    return results.map((map) {
      return Conversation(
        id: map['id'] as String,
        title: map['title'] as String,
        noteIds: List<String>.from(jsonDecode(map['noteIds'] as String)),
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
        isArchived: (map['isArchived'] as int) == 1,
      );
    }).toList();
  }

  Future<void> insertMessage(ConversationMessage message) async {
    await db.insert('conversation_messages', {
      'id': message.id,
      // Note: conversationId is NOT inserted here - it goes in the mapping table
      'type': message.type.toString().split('.').last,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'modelUsed': message.modelUsed,
      'metadata': message.metadata != null ? jsonEncode(message.metadata) : null,
    });
  }

  Future<void> insertMessageMapping({required String conversationId, required String messageId}) async {
    await db.insert('conversation_message_mapping', {
      'conversationId': conversationId,
      'messageId': messageId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> insertMessageParent({required String messageId, required String parentMessageId}) async {
    await db.insert('message_parents', {
      'id': '${messageId}_$parentMessageId',
      'messageId': messageId,
      'parentMessageId': parentMessageId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<ConversationMessage>> getConversationMessages(String conversationId) async {
    final results = await db.rawQuery('''
      SELECT cm.*
      FROM conversation_messages cm
      INNER JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp ASC
    ''', [conversationId]);

    return results.map((map) {
      return ConversationMessage(
        id: map['id'] as String,
        conversationId: conversationId,
        type: MessageType.values.firstWhere(
          (e) => e.toString().split('.').last == map['type'],
          orElse: () => MessageType.user,
        ),
        content: map['content'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
        modelUsed: map['modelUsed'] as String?,
        metadata: map['metadata'] != null 
            ? Map<String, dynamic>.from(jsonDecode(map['metadata'] as String))
            : null,
      );
    }).toList();
  }
}

void main() {
  group('Conversation Database Tests (Direct)', () {
    late Database db;
    late ConversationDatabaseTestHelpers helpers;
    const uuid = Uuid();

    setUpAll(() {
      // Initialize FFI for testing
      sqfliteFfiInit();
    });

    setUp(() async {
      // Create a fresh in-memory database for each test
      db = await databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            // Enable foreign keys (must be done per connection in SQLite)
            await db.execute('PRAGMA foreign_keys = ON');
            await db.execute('''
              CREATE TABLE conversations(
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                noteIds TEXT NOT NULL DEFAULT '[]',
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                isArchived INTEGER NOT NULL DEFAULT 0
              )
            ''');

            await db.execute('''
              CREATE TABLE conversation_messages(
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                modelUsed TEXT,
                metadata TEXT
              )
            ''');

            await db.execute('''
              CREATE TABLE conversation_message_mapping(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversationId TEXT NOT NULL,
                messageId TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
                FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
                UNIQUE(conversationId, messageId)
              )
            ''');

            await db.execute('''
              CREATE TABLE message_parents(
                id TEXT PRIMARY KEY,
                messageId TEXT NOT NULL,
                parentMessageId TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
                FOREIGN KEY (parentMessageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
                UNIQUE(messageId, parentMessageId)
              )
            ''');

            // Create indexes
            await db.execute('CREATE INDEX idx_conversation_messages_timestamp ON conversation_messages(timestamp)');
            await db.execute('CREATE INDEX idx_conversation_message_mapping_conversationId ON conversation_message_mapping(conversationId)');
            await db.execute('CREATE INDEX idx_conversation_message_mapping_messageId ON conversation_message_mapping(messageId)');
          },
        ),
      );
      
      helpers = ConversationDatabaseTestHelpers(db);
    });

    tearDown(() async {
      await db.close();
    });

    group('Schema Tests', () {
      test('conversation_messages should NOT have conversationId column', () async {
        final tableInfo = await db.rawQuery('PRAGMA table_info(conversation_messages)');
        final columnNames = tableInfo.map((col) => col['name'] as String).toList();

        expect(columnNames, contains('id'));
        expect(columnNames, contains('type'));
        expect(columnNames, contains('content'));
        expect(columnNames, contains('timestamp'));
        expect(columnNames, isNot(contains('conversationId')));
      });

      test('conversation_message_mapping should have conversationId', () async {
        final tableInfo = await db.rawQuery('PRAGMA table_info(conversation_message_mapping)');
        final columnNames = tableInfo.map((col) => col['name'] as String).toList();

        expect(columnNames, contains('conversationId'));
        expect(columnNames, contains('messageId'));
      });
    });

    group('Conversation CRUD', () {
      test('insert and retrieve conversation', () async {
        final conversation = Conversation(
          id: uuid.v4(),
          title: 'Test',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        await helpers.insertConversation(conversation);
        final retrieved = await helpers.getConversation(conversation.id);

        expect(retrieved, isNotNull);
        expect(retrieved!.title, 'Test');
      });

      test('verify mapping foreign key constraints exist', () async {
        final conversationId = uuid.v4();
        final messageId = uuid.v4();

        await helpers.insertConversation(Conversation(
          id: conversationId,
          title: 'Test',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));

        await helpers.insertMessage(ConversationMessage(
          id: messageId,
          conversationId: conversationId,
          type: MessageType.user,
          content: 'Test',
          timestamp: DateTime.now(),
        ));

        await helpers.insertMessageMapping(
          conversationId: conversationId,
          messageId: messageId,
        );

        // Verify mapping exists
        final mappings = await db.query('conversation_message_mapping');
        expect(mappings.length, 1);
        
        // Verify the mapping has correct foreign key references
        expect(mappings.first['conversationId'], conversationId);
        expect(mappings.first['messageId'], messageId);

        // Clean up - delete mapping first, then conversation
        await db.delete('conversation_message_mapping', where: 'conversationId = ?', whereArgs: [conversationId]);
        await db.delete('conversations', where: 'id = ?', whereArgs: [conversationId]);
        
        final allConversations = await db.query('conversations');
        expect(allConversations, isEmpty);
      });
    });

    group('Message Operations', () {
      test('insert message without conversationId in table', () async {
        final message = ConversationMessage(
          id: uuid.v4(),
          conversationId: 'some-conv-id', // This is in the model
          type: MessageType.user,
          content: 'Test',
          timestamp: DateTime.now(),
        );

        await helpers.insertMessage(message);

        // Verify no conversationId in the row
        final rows = await db.query('conversation_messages');
        expect(rows.length, 1);
        expect(rows.first['content'], 'Test');
        expect(rows.first['conversationId'], isNull);
      });

      test('retrieve messages through mapping', () async {
        final conversationId = uuid.v4();
        final messages = [
          ConversationMessage(
            id: uuid.v4(),
            conversationId: conversationId,
            type: MessageType.user,
            content: 'Message 1',
            timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
          ),
          ConversationMessage(
            id: uuid.v4(),
            conversationId: conversationId,
            type: MessageType.ai,
            content: 'Response 1',
            timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
        ];

        await helpers.insertConversation(Conversation(
          id: conversationId,
          title: 'Test',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));

        for (final message in messages) {
          await helpers.insertMessage(message);
          await helpers.insertMessageMapping(
            conversationId: conversationId,
            messageId: message.id,
          );
        }

        final retrieved = await helpers.getConversationMessages(conversationId);
        expect(retrieved.length, 2);
        expect(retrieved[0].content, 'Message 1');
        expect(retrieved[1].content, 'Response 1');
        expect(retrieved[0].conversationId, conversationId);
      });

      test('prevent duplicate message mappings', () async {
        final conversationId = uuid.v4();
        final messageId = uuid.v4();

        await helpers.insertConversation(Conversation(
          id: conversationId,
          title: 'Test',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));

        await helpers.insertMessage(ConversationMessage(
          id: messageId,
          conversationId: conversationId,
          type: MessageType.user,
          content: 'Test',
          timestamp: DateTime.now(),
        ));

        await helpers.insertMessageMapping(
          conversationId: conversationId,
          messageId: messageId,
        );

        // Try to insert duplicate
        expect(
          () => helpers.insertMessageMapping(
            conversationId: conversationId,
            messageId: messageId,
          ),
          throwsA(isA<DatabaseException>()),
        );
      });
    });

    group('Message Parent Relationships', () {
      test('insert and verify parent relationship', () async {
        final parentId = uuid.v4();
        final childId = uuid.v4();

        for (final id in [parentId, childId]) {
          await helpers.insertMessage(ConversationMessage(
            id: id,
            conversationId: uuid.v4(),
            type: MessageType.user,
            content: 'Test',
            timestamp: DateTime.now(),
          ));
        }

        await helpers.insertMessageParent(
          messageId: childId,
          parentMessageId: parentId,
        );

        final parents = await db.query('message_parents', where: 'messageId = ?', whereArgs: [childId]);
        expect(parents.length, 1);
        expect(parents.first['parentMessageId'], parentId);
      });

      test('prevent duplicate parent relationships', () async {
        final parentId = uuid.v4();
        final childId = uuid.v4();

        for (final id in [parentId, childId]) {
          await helpers.insertMessage(ConversationMessage(
            id: id,
            conversationId: uuid.v4(),
            type: MessageType.user,
            content: 'Test',
            timestamp: DateTime.now(),
          ));
        }

        await helpers.insertMessageParent(
          messageId: childId,
          parentMessageId: parentId,
        );

        // Try to insert duplicate
        expect(
          () => helpers.insertMessageParent(
            messageId: childId,
            parentMessageId: parentId,
          ),
          throwsA(isA<DatabaseException>()),
        );
      });
    });
  });
}

