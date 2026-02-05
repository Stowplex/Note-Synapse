import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/field_version_registry.dart';

void main() {
  group('SyncChangelog triggers', () {
    late DatabaseService databaseService;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
    });

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('sync_changelog table exists after enableSyncTriggers', () async {
      final db = await databaseService.database;

      // Verify table does NOT exist initially
      var tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_changelog'",
      );
      expect(tables, isEmpty, reason: 'sync_changelog should not exist before enable');

      // Enable triggers
      await databaseService.enableSyncTriggers();

      // Verify table now exists
      tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_changelog'",
      );
      expect(tables.length, 1, reason: 'sync_changelog should exist after enable');
    });

    test('no triggers active by default', () async {
      final db = await databaseService.database;

      // Check for sync triggers
      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%'",
      );
      expect(triggers, isEmpty, reason: 'No sync triggers should exist by default');
    });

    test('triggers are created for all synced tables after enable', () async {
      final db = await databaseService.database;

      await databaseService.enableSyncTriggers();

      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%'",
      );
      final triggerNames = triggers.map((t) => t['name'] as String).toSet();

      // Verify triggers exist for each synced table
      for (final table in syncedTables) {
        expect(
          triggerNames.contains('sync_insert_$table'),
          isTrue,
          reason: 'Insert trigger should exist for $table',
        );
        expect(
          triggerNames.contains('sync_update_$table'),
          isTrue,
          reason: 'Update trigger should exist for $table',
        );
        expect(
          triggerNames.contains('sync_delete_$table'),
          isTrue,
          reason: 'Delete trigger should exist for $table',
        );
      }
    });

    test('insert trigger captures note creation', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Insert a note
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'test-note-1',
        'title': 'Test Note',
        'content': 'Test content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Check sync_changelog
      final changes = await db.query('sync_changelog');
      expect(changes.length, 1);
      expect(changes.first['table_name'], 'notes');
      expect(changes.first['row_id'], 'test-note-1');
      expect(changes.first['action'], 'insert');
      expect(changes.first['pushed'], 0);
    });

    test('update trigger captures changed fields', () async {
      final db = await databaseService.database;

      // Insert a note first (before enabling triggers)
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'test-note-2',
        'title': 'Original Title',
        'content': 'Original content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Enable triggers
      await databaseService.enableSyncTriggers();

      // Clear any changelog entries from enabling (shouldn't be any)
      await db.delete('sync_changelog');

      // Update the note
      await db.update(
        'notes',
        {'title': 'Updated Title', 'updatedAt': now + 1000},
        where: 'id = ?',
        whereArgs: ['test-note-2'],
      );

      // Check sync_changelog
      final changes = await db.query('sync_changelog');
      expect(changes.length, 1);
      expect(changes.first['table_name'], 'notes');
      expect(changes.first['row_id'], 'test-note-2');
      expect(changes.first['action'], 'update');

      // Verify changed_fields contains 'title' and 'updatedAt'
      final changedFields = changes.first['changed_fields'] as String;
      expect(changedFields, contains('title'));
      expect(changedFields, contains('updatedAt'));
      // Should NOT contain 'content' since we didn't change it
      expect(changedFields, isNot(contains('content')));
    });

    test('delete trigger captures deletion', () async {
      final db = await databaseService.database;

      // Insert a note first (before enabling triggers)
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'test-note-3',
        'title': 'Note to Delete',
        'content': 'Will be deleted',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Enable triggers
      await databaseService.enableSyncTriggers();

      // Clear any changelog entries
      await db.delete('sync_changelog');

      // Delete the note
      await db.delete('notes', where: 'id = ?', whereArgs: ['test-note-3']);

      // Check sync_changelog
      final changes = await db.query('sync_changelog');
      expect(changes.length, 1);
      expect(changes.first['table_name'], 'notes');
      expect(changes.first['row_id'], 'test-note-3');
      expect(changes.first['action'], 'delete');
    });

    test('disableSyncTriggers drops triggers and table', () async {
      final db = await databaseService.database;

      // Enable first
      await databaseService.enableSyncTriggers();

      // Verify they exist
      var triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%'",
      );
      expect(triggers, isNotEmpty);

      var tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_changelog'",
      );
      expect(tables.length, 1);

      // Disable
      await databaseService.disableSyncTriggers();

      // Verify triggers are gone
      triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%'",
      );
      expect(triggers, isEmpty, reason: 'All sync triggers should be dropped');

      // Verify table is gone
      tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_changelog'",
      );
      expect(tables, isEmpty, reason: 'sync_changelog table should be dropped');
    });

    test('getPendingSyncChanges returns only unpushed rows', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Insert two notes
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'note-pending-1',
        'title': 'Pending Note 1',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'note-pending-2',
        'title': 'Pending Note 2',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Mark first change as pushed manually
      await db.update(
        'sync_changelog',
        {'pushed': 1},
        where: 'row_id = ?',
        whereArgs: ['note-pending-1'],
      );

      // Get pending changes
      final pending = await databaseService.getPendingSyncChanges();
      expect(pending.length, 1);
      expect(pending.first['row_id'], 'note-pending-2');
    });

    test('markSyncChangesPushed marks specified rows', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Insert notes
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'note-mark-1',
        'title': 'Note 1',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'note-mark-2',
        'title': 'Note 2',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'note-mark-3',
        'title': 'Note 3',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Get all changes and mark some as pushed
      final allChanges = await db.query('sync_changelog', orderBy: 'id');
      final idsToMark = [allChanges[0]['id'] as int, allChanges[1]['id'] as int];
      await databaseService.markSyncChangesPushed(idsToMark);

      // Verify only two are marked
      final markedChanges = await db.query(
        'sync_changelog',
        where: 'pushed = 1',
      );
      expect(markedChanges.length, 2);

      final unmarkedChanges = await db.query(
        'sync_changelog',
        where: 'pushed = 0',
      );
      expect(unmarkedChanges.length, 1);
      expect(unmarkedChanges.first['row_id'], 'note-mark-3');
    });

    test('prunePushedSyncChanges removes pushed rows', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Insert notes
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'note-prune-1',
        'title': 'Note 1',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'note-prune-2',
        'title': 'Note 2',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Mark first as pushed
      await db.update(
        'sync_changelog',
        {'pushed': 1},
        where: 'row_id = ?',
        whereArgs: ['note-prune-1'],
      );

      // Verify we have 2 entries
      var allChanges = await db.query('sync_changelog');
      expect(allChanges.length, 2);

      // Prune
      await databaseService.prunePushedSyncChanges();

      // Verify only unpushed remains
      allChanges = await db.query('sync_changelog');
      expect(allChanges.length, 1);
      expect(allChanges.first['row_id'], 'note-prune-2');
    });

    test('composite key tables use correct row_id format', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Create prerequisites for note_tags
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'note-for-tag',
        'title': 'Note for Tag',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });
      await db.insert('tags', {
        'id': 'tag-1',
        'name': 'Test Tag',
        'color': '#FF0000',
        'createdAt': now,
        'usageCount': 0,
      });

      // Clear changelog to isolate the note_tags insert
      await db.delete('sync_changelog');

      // Insert note_tag (composite key: noteId, tagId)
      await db.insert('note_tags', {
        'noteId': 'note-for-tag',
        'tagId': 'tag-1',
      });

      // Check changelog
      final changes = await db.query(
        'sync_changelog',
        where: "table_name = 'note_tags'",
      );
      expect(changes.length, 1);
      expect(changes.first['row_id'], 'note-for-tag-tag-1');
    });

    test('old_values captures previous values for updates', () async {
      final db = await databaseService.database;

      // Insert a note first (before enabling triggers)
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('notes', {
        'id': 'test-note-oldvals',
        'title': 'Original Title',
        'content': 'Original content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Enable triggers
      await databaseService.enableSyncTriggers();

      // Clear changelog
      await db.delete('sync_changelog');

      // Update the note
      await db.update(
        'notes',
        {'title': 'New Title'},
        where: 'id = ?',
        whereArgs: ['test-note-oldvals'],
      );

      // Check old_values
      final changes = await db.query('sync_changelog');
      expect(changes.length, 1);

      final oldValuesJson = changes.first['old_values'] as String;
      final oldValues = jsonDecode(oldValuesJson) as Map<String, dynamic>;

      // old_values should contain the original title
      expect(oldValues['title'], 'Original Title');
    });

    test('conversation_message_mapping uses correct row_id format', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Create prerequisites
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('conversations', {
        'id': 'conv-1',
        'title': 'Test Conversation',
        'noteIds': '[]',
        'createdAt': now,
        'updatedAt': now,
        'isArchived': 0,
      });
      await db.insert('conversation_messages', {
        'id': 'msg-1',
        'type': 'user',
        'content': 'Hello',
        'timestamp': now,
      });

      // Clear changelog
      await db.delete('sync_changelog');

      // Insert mapping
      await db.insert('conversation_message_mapping', {
        'conversationId': 'conv-1',
        'messageId': 'msg-1',
        'createdAt': now,
      });

      // Check changelog
      final changes = await db.query(
        'sync_changelog',
        where: "table_name = 'conversation_message_mapping'",
      );
      expect(changes.length, 1);
      expect(changes.first['row_id'], 'conv-1-msg-1');
    });

    test('conversation_note_mapping uses correct row_id format', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Create prerequisites
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('conversations', {
        'id': 'conv-2',
        'title': 'Test Conversation 2',
        'noteIds': '[]',
        'createdAt': now,
        'updatedAt': now,
        'isArchived': 0,
      });
      await db.insert('notes', {
        'id': 'note-2',
        'title': 'Note 2',
        'content': 'Content',
        'type': 'note',
        'createdAt': now,
        'updatedAt': now,
        'pinned': 0,
        'isArchived': 0,
      });

      // Clear changelog
      await db.delete('sync_changelog');

      // Insert mapping
      await db.insert('conversation_note_mapping', {
        'conversationId': 'conv-2',
        'noteId': 'note-2',
        'createdAt': now,
      });

      // Check changelog
      final changes = await db.query(
        'sync_changelog',
        where: "table_name = 'conversation_note_mapping'",
      );
      expect(changes.length, 1);
      expect(changes.first['row_id'], 'conv-2-note-2');
    });

    test('conversation_tags uses correct row_id format', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Create prerequisites
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('conversations', {
        'id': 'conv-3',
        'title': 'Test Conversation 3',
        'noteIds': '[]',
        'createdAt': now,
        'updatedAt': now,
        'isArchived': 0,
      });
      await db.insert('tags', {
        'id': 'tag-2',
        'name': 'Test Tag 2',
        'color': '#00FF00',
        'createdAt': now,
        'usageCount': 0,
      });

      // Clear changelog
      await db.delete('sync_changelog');

      // Insert conversation tag
      await db.insert('conversation_tags', {
        'conversationId': 'conv-3',
        'tagId': 'tag-2',
      });

      // Check changelog
      final changes = await db.query(
        'sync_changelog',
        where: "table_name = 'conversation_tags'",
      );
      expect(changes.length, 1);
      expect(changes.first['row_id'], 'conv-3-tag-2');
    });

    test('getPendingSyncChanges returns results ordered by id', () async {
      final db = await databaseService.database;
      await databaseService.enableSyncTriggers();

      // Insert multiple notes in sequence
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 1; i <= 3; i++) {
        await db.insert('notes', {
          'id': 'ordered-note-$i',
          'title': 'Note $i',
          'content': 'Content $i',
          'type': 'note',
          'createdAt': now + i,
          'updatedAt': now + i,
          'pinned': 0,
          'isArchived': 0,
        });
      }

      // Get pending changes
      final pending = await databaseService.getPendingSyncChanges();
      expect(pending.length, 3);
      expect(pending[0]['row_id'], 'ordered-note-1');
      expect(pending[1]['row_id'], 'ordered-note-2');
      expect(pending[2]['row_id'], 'ordered-note-3');
    });
  });
}
