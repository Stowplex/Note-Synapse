/// Maps every column of every synced table to the minimum schema version that
/// introduced it.
///
/// The sync engine uses this registry to tag each field in an oplog entry with
/// the minimum schema version needed to interpret it. When a device running an
/// older schema receives an op whose field has a [minVersion] higher than its
/// own schema version, it preserves but does not apply that field.
///
/// **Maintenance rule**: whenever a migration adds a column to a synced table,
/// the developer must also add an entry here. The enforcement tests in
/// `test/services/sync/field_version_registry_test.dart` will fail CI if a
/// column is present in the live database but missing from this registry.
library;

import '../database_service.dart';

/// Tables ordered by foreign key dependencies (parents before children).
/// Used when merging data from one DB into another so that parent rows
/// exist before child rows reference them.
const List<String> syncedTablesInMergeOrder = [
  'notes',
  'tags',
  'conversations',
  'subnotes',
  'relationships',
  'conversation_messages',
  'note_tags',
  'conversation_tags',
  'conversation_note_mapping',
  'conversation_message_mapping',
  'message_parents',
  'attachments',
  'conversation_attachments',
];

/// The set of table names that participate in oplog-based cloud sync.
const Set<String> syncedTables = {
  'notes',
  'subnotes',
  'tags',
  'note_tags',
  'relationships',
  'conversations',
  'conversation_messages',
  'conversation_message_mapping',
  'message_parents',
  'conversation_note_mapping',
  'conversation_tags',
  'attachments',
  'conversation_attachments',
};

/// Registry mapping `tableName -> { columnName -> minSchemaVersion }`.
///
/// The version number is the [DatabaseService.DATABASE_VERSION] value at which
/// the column was first introduced (either via the original CREATE TABLE or a
/// later ALTER TABLE / recreate-table migration).
const Map<String, Map<String, int>> fieldVersionRegistry = {
  'notes': {
    'id': 1,
    'title': 1,
    'content': 1,
    'type': 1,
    'createdAt': 1,
    'updatedAt': 1,
    'scheduledAt': 1,
    'completeBy': 1,
    'status': 1,
    'completionPercentage': 1,
    'pinned': 1,
    'isArchived': 1,
    'recurrenceRule': 30,
    'metadata': 42,
  },
  'subnotes': {
    'id': 1,
    'noteId': 1,
    'name': 1,
    'content': 1,
    'createdAt': 1,
    'isCompleted': 1,
  },
  'tags': {
    'id': 1,
    'name': 1,
    'color': 1,
    'createdAt': 1,
    'usageCount': 1,
  },
  'note_tags': {
    'noteId': 1,
    'tagId': 1,
  },
  'relationships': {
    'id': 1,
    'fromNoteId': 1,
    'toNoteId': 1,
    'type': 1,
    'createdAt': 1,
  },
  'conversations': {
    'id': 1,
    'title': 1,
    'noteIds': 1,
    'createdAt': 1,
    'updatedAt': 1,
    'isArchived': 1,
  },
  'conversation_messages': {
    'id': 1,
    'type': 1,
    'content': 1,
    'timestamp': 1,
    'modelUsed': 1,
    'metadata': 1,
  },
  'conversation_message_mapping': {
    'conversationId': 20,
    'messageId': 20,
    'createdAt': 20,
  },
  'message_parents': {
    'id': 20,
    'messageId': 20,
    'parentMessageId': 20,
    'createdAt': 20,
  },
  'conversation_note_mapping': {
    'conversationId': 21,
    'noteId': 21,
    'createdAt': 21,
  },
  'conversation_tags': {
    'conversationId': 22,
    'tagId': 22,
  },
  'attachments': {
    'id': 1,
    'noteId': 1,
    'filePath': 1,
    'fileName': 1,
    'fileType': 1,
    'isRelativePath': 1,
    'createdAt': 1,
    'includeInAIContext': 25,
    'metadata': 32,
  },
  'conversation_attachments': {
    'id': 1,
    'messageId': 1,
    'filePath': 1,
    'fileName': 1,
    'fileType': 1,
    'isRelativePath': 1,
    'createdAt': 1,
  },
};
