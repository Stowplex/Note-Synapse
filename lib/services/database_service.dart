import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Conditional imports for platform-specific code
import 'database_service_io.dart'
    if (dart.library.html) 'database_service_web.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/services.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/tag.dart';
import '../models/filter.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/conversation.dart';
import '../models/conversation_attachment.dart';
import '../models/attachment.dart';
import 'logger_service.dart';
import 'sync/large_row_reader.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/global_keys.dart';
import '../screens/recovery_screen.dart';
import '../models/note_annotation.dart';
import '../models/workflow_binding_row.dart';

class MigrationStep {
  final String description;
  final Future<void> Function(Database db, {required bool isBackupMigration})
  execute;

  const MigrationStep({required this.description, required this.execute});
}

/// One entity table's M2.4 sync mutation-capture scope (§ Architecture
/// 11.3) — which column holds its primary key, and the exact list of
/// columns that get their own `AFTER UPDATE` touch trigger. Public (not a
/// private implementation detail of the trigger-SQL generator below) so
/// that [OutboxDrainer] (`lib/services/sync/outbox_drainer.dart`) can
/// consume the exact same single source of truth the triggers themselves
/// were built from, instead of an independently-maintained duplicate list —
/// exactly the anti-drift reasoning this whole design already applies to
/// `_onCreate` vs. the migrations (see
/// `DatabaseService._syncMutationCaptureTriggerStatements`'s doc comment).
/// A duplicate list here would be a real drift risk: if a column were ever
/// added to `syncScopeColumns` without a corresponding update wherever
/// drain enumerates "this entity's sync-scope fields" (or vice versa), that
/// column's capture would silently break exactly the way this whole
/// milestone exists to prevent.
class SyncEntityCaptureScope {
  const SyncEntityCaptureScope({
    required this.table,
    required this.idColumn,
    required this.syncScopeColumns,
  });

  final String table;
  final String idColumn;
  final List<String> syncScopeColumns;
}

/// One OR-Set membership table's M2.4 sync mutation-capture scope. Public
/// for the same single-source-of-truth reason as [SyncEntityCaptureScope]
/// — see that class's doc comment.
class SyncSetCaptureScope {
  const SyncSetCaptureScope({
    required this.membershipTable,
    required this.entityTable,
    required this.entityIdColumn,
    required this.fieldName,
    required this.memberIdColumn,
    this.payloadColumns = const [],
  });

  final String membershipTable;
  final String entityTable;
  final String entityIdColumn;
  final String fieldName;
  final String memberIdColumn;

  /// Columns carrying data associated with the ADD EVENT itself, beyond the
  /// bare fact of membership — everything that is neither the membership
  /// table's own surrogate key nor [entityIdColumn]/[memberIdColumn].
  ///
  /// Added in M2.10. `note_tags`/`conversation_tags` genuinely have none
  /// (their two columns are the whole row), but the three mapping tables all
  /// carry a real `createdAt`, and § Architecture 1's round-14
  /// conversation-mapping correction makes that value part of the seed
  /// operation's `contentKey` — `test/sync_protocol/conversation_ops.dart`'s
  /// validated `genesisContentKey(conversationId, messageId,
  /// createdAtMillis)` is the reference. It has to be: if the payload were
  /// left out of the key, two replicas holding the same logical mapping with
  /// GENUINELY DIFFERENT `createdAt` values would compute the same
  /// `contentKey`, dedup to one dot, and permanently discard one device's
  /// real historical ordering — the exact loss round 14 exists to prevent.
  /// With the payload in the key they get different keys, both add-dots stay
  /// live, and OR-Set semantics keep the membership correct either way.
  ///
  /// Deliberately NOT a general "sync these columns" list: nothing captures
  /// or materializes these columns as fields today (a membership table has
  /// no `__exists__`/`field` operations at all). This names the add-event's
  /// payload for `contentKey` purposes only.
  final List<String> payloadColumns;
}

/// Result of [DatabaseService.runRawWriteWithChangeCapture]: the statement's
/// rows plus which note-domain data the write (including any persistent
/// triggers it fired) actually touched, as observed by the TEMP change
/// journal.
class RawWriteResult {
  const RawWriteResult({
    required this.rows,
    this.changedNoteIds = const {},
    this.relationshipNoteIds = const {},
    this.tagsChanged = false,
    this.filtersChanged = false,
    required this.captureComplete,
  });

  final List<Map<String, dynamic>> rows;
  final Set<String> changedNoteIds;
  final Set<String> relationshipNoteIds;
  final bool tagsChanged;
  final bool filtersChanged;

  /// False when the capture trigger set could not be (fully) installed — the
  /// journal may have missed writes and callers should invalidate broadly.
  /// Returned per execution so callers never race on mutable service state.
  final bool captureComplete;
}

/// Result of installing the TEMP capture objects on one connection.
/// Immutable and connection-keyed so per-call reads never race with
/// close()/reopen resetting mutable service fields.
class _CaptureState {
  const _CaptureState(
    this.db, {
    required this.journalReady,
    required this.complete,
  });

  final Database db;

  /// The TEMP journal + gate tables exist; capture transactions may
  /// reference them.
  final bool journalReady;

  /// Every monitored table's trigger group installed; the journal can be
  /// trusted. False ⇒ callers must invalidate broadly.
  final bool complete;
}

/// Effective visibility for one app's revisions — see
/// [DatabaseService.computeAppRevisionVisibility]'s doc comment (M1.4,
/// design doc § Architecture 10) for the full derivation rule.
class AppRevisionVisibility {
  /// `app_revisions.id` values that are effectively visible for this app.
  final Set<String> visibleRevisionIds;

  /// The revision currently serving as this app's zero-live-revisions
  /// fallback, or null if the app has at least one raw-live revision (no
  /// fallback needed) or no revisions/doesn't exist at all.
  final String? fallbackRevisionId;

  const AppRevisionVisibility(this.visibleRevisionIds, this.fallbackRevisionId);
}

class DatabaseService {
  final String? _databaseNameOverride;

  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal({String? databaseNameOverride})
    : _databaseNameOverride = databaseNameOverride {
    // Initialize database factory using platform-specific implementation
    initializeDatabaseFactory();
  }

  // Current database version - exported for use by recovery/import operations
  static const int DATABASE_VERSION = 64; // Target schema version
  static const int SQFLITE_VERSION =
      999; // High value to prevent sqflite onUpgrade

  // Table schema constants - single source of truth for all table definitions
  // M1.10 (design doc § Phased delivery, M1.10 — "notes (deleteNote
  // only)"): deletion is now always a tombstone write (`__deleted__=1`),
  // never a real SQL DELETE — see deleteNote below, and every read path
  // (getAllNotes/getNote/getNoteById/getNotesByIds/getNotesByTag/
  // getPinnedNotes/getArchivedNotes/getNotesByArchiveStatus/searchNotes/
  // searchNotesFTS and others), which all filter through `__deleted__ = 0`
  // on every read. Cascading into `subnotes`/`attachments`/`note_tags`/
  // `relationships`/`conversation_note_mapping` — previously implicit via
  // `ON DELETE CASCADE`, which only fires on a real `DELETE` — is now done
  // explicitly inside `deleteNote` itself; see that function's own doc
  // comment for the per-child-table replacement strategy (`subnotes`/
  // `attachments` deliberately stay real-deleted there, not tombstoned —
  // M1.10 itself did not add a `__deleted__` column to either).
  //
  // M1.11 update: `subnotes`/`attachments` now DO have their own
  // `__deleted__` column (below) — consumed by `updateNote`'s and
  // `NoteModificationService._persistNote`'s id-/filePath-keyed diff logic
  // (every ordinary note edit), not by `deleteNote`, which deliberately
  // still real-deletes both tables' rows for the note being deleted (out
  // of this milestone's scope — see `deleteNote`'s own doc comment).
  static const String _createNotesTable = '''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY, -- Unique identifier
        title TEXT NOT NULL, -- Note title
        content TEXT NOT NULL, -- Note content
        type TEXT NOT NULL, -- 'note' or 'task'
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL, -- Last update timestamp
        scheduledAt TEXT, -- Scheduled date (for tasks)
        completeBy TEXT, -- Due date (for tasks)
        status TEXT, -- Task status: 'todo', 'inProgress', 'completed', 'cancelled'
        completionPercentage REAL, -- Task completion percentage
        pinned INTEGER NOT NULL DEFAULT 0, -- Whether note is pinned
        isArchived INTEGER NOT NULL DEFAULT 0, -- Whether note is archived
        recurrenceRule TEXT, -- JSON string defining recurrence rules
        metadata TEXT, -- JSON metadata (e.g. in-note markers)
        __deleted__ INTEGER NOT NULL DEFAULT 0 -- Soft-delete tombstone flag (M1.10)
      )
  ''';

  static const String _createSubNotesTable = '''
      CREATE TABLE subnotes(
        id TEXT PRIMARY KEY, -- Unique identifier
        noteId TEXT NOT NULL, -- Parent note ID
        name TEXT NOT NULL, -- Subnote name (task item)
        content TEXT NOT NULL, -- Subnote content
        createdAt INTEGER NOT NULL, -- Creation timestamp
        isCompleted INTEGER NOT NULL DEFAULT 0, -- Completion status
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.11)
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  // M1.3: `name` was a column-level `UNIQUE` constraint (blanket, applying
  // to every row regardless of liveness) through DATABASE_VERSION 47. Once
  // tag deletion becomes a soft tombstone rather than a real `DELETE`
  // (M1.9 — this schema change landed ahead of that conversion so the
  // identity model was ready when it shipped), the deleted row's name
  // physically remains, and a blanket UNIQUE would then block a new tag
  // from ever reusing that name. `name` is now a plain, non-unique column;
  // uniqueness among *live* tags is enforced instead by the partial index
  // `idx_tags_name_live` below (design doc § Architecture 10, "Round 20
  // correction"). `__deleted__` is the tombstone flag. `redirectTarget` is
  // the id of the tag this one was merged into by a (not-yet-implemented)
  // `tagMerge` operation; nothing in the current app ever sets it, so it
  // reads NULL for every row today — added now, ahead of that machinery,
  // purely so the identity/index model doesn't need a second migration
  // later when tagMerge is wired up.
  static const String _createTagsTable = '''
      CREATE TABLE tags(
        id TEXT PRIMARY KEY, -- Unique identifier
        name TEXT NOT NULL, -- Tag name (uniqueness among live tags enforced by idx_tags_name_live, not a column constraint)
        color TEXT NOT NULL, -- Tag color
        createdAt INTEGER NOT NULL, -- Creation timestamp
        usageCount INTEGER NOT NULL DEFAULT 0, -- Usage count
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.3)
        redirectTarget TEXT -- tagMerge target id; always NULL until tagMerge is implemented (M1.3)
      )
  ''';

  /// Partial unique index enforcing name-uniqueness among *live,
  /// non-redirecting* tags only — see the doc comment on _createTagsTable.
  /// The `redirectTarget IS NULL` clause (not just `__deleted__ = 0`)
  /// matters: a tagMerge's `redirectTarget` write and its `__deleted__`
  /// write are sequential, so a replica can transiently observe
  /// `(redirectTarget != NULL, __deleted__ = 0)` — without excluding that
  /// transitional state here, an unrelated new tag claiming the same name
  /// during that window would hit a spurious violation (design doc's
  /// "Round 20 correction").
  static const String _createTagsNameLiveIndex =
      'CREATE UNIQUE INDEX idx_tags_name_live ON tags(name) '
      'WHERE __deleted__ = 0 AND redirectTarget IS NULL';

  // M1.9: `tagId` is this table's actual primary key — it has no
  // independent row identity of its own, so it never gets a `__deleted__`
  // tombstone; visibility is instead derived at read time from the owning
  // tag's `__deleted__` state (design doc § Architecture 10). The
  // `ON DELETE CASCADE` below only ever fires for a real `DELETE FROM
  // tags`, which no longer happens for `deleteTag`/`replaceTag` — a
  // tombstoned tag's `tag_images` row now physically persists, and every
  // read path (getAllTagImages/getTagImage) JOINs against `tags` to keep
  // it invisible.
  static const String _createTagImagesTable = '''
      CREATE TABLE tag_images(
        tagId TEXT PRIMARY KEY,
        imagePath TEXT NOT NULL,
        FOREIGN KEY (tagId) REFERENCES tags(id) ON DELETE CASCADE
      )
  ''';

  static const String _createNoteAnnotationsTable = '''
      CREATE TABLE IF NOT EXISTS note_annotations (
        id              TEXT PRIMARY KEY,
        note_id         TEXT,
        attachment_id   TEXT,
        content         TEXT NOT NULL,
        attachment_paths TEXT,
        created_at      TEXT NOT NULL,
        CHECK (note_id IS NOT NULL OR attachment_id IS NOT NULL)
      )
  ''';

  static const String _createNoteTagsTable = '''
      CREATE TABLE note_tags(
        noteId TEXT NOT NULL, -- Note ID
        tagId TEXT NOT NULL, -- Tag ID
        PRIMARY KEY (noteId, tagId),
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
  ''';

  static const String _createConversationTagsTable = '''
      -- conversation_tags table links conversations with tags, so that conversations can be searched / filtered by tag.
      CREATE TABLE conversation_tags(
        conversationId TEXT NOT NULL, -- Conversation ID
        tagId TEXT NOT NULL, -- Tag ID
        PRIMARY KEY (conversationId, tagId),
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
  ''';

  static const String _createAttachmentsTable = '''
      -- Attachments are external files associated with notes.
      CREATE TABLE attachments(
        id TEXT PRIMARY KEY, -- Unique identifier
        noteId TEXT NOT NULL, -- Parent note ID
        filePath TEXT NOT NULL, -- Path to file
        fileName TEXT NOT NULL, -- Original file name
        fileType TEXT NOT NULL, -- MIME type or extension
        isRelativePath INTEGER NOT NULL DEFAULT 1, -- Whether path is relative to app dir
        createdAt INTEGER NOT NULL, -- Creation timestamp
        includeInAIContext INTEGER NOT NULL DEFAULT 1, -- Whether to include in AI context
        metadata TEXT, -- JSON storage for attachment-specific data (bookmarks, AI context config, etc.)
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.11)
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  // M1.8 (design doc § Phased delivery, M1.8 — "relationships +
  // conversation_attachments: independent entities, touched only on
  // explicit removal"): deletion is now always a tombstone write
  // (`__deleted__=1`), never a real SQL DELETE — see deleteRelationship/
  // deleteRelationshipBetween/deleteRelationshipsForNote below, and
  // getRelationships/getOutgoingRelationships/getIncomingRelationships/
  // relationshipExists, which all filter through `__deleted__ = 0` on every
  // read. `notes -> relationships ON DELETE CASCADE` is a real FK edge in
  // the schema but, as of M1.10, no longer fires when `deleteNote` runs:
  // `deleteNote` now tombstones `notes` (an UPDATE, not a DELETE) and
  // explicitly tombstones a note's own relationships itself (reusing
  // `deleteRelationshipsForNote`) as an in-transaction replacement for the
  // cascade — see `deleteNote`'s own doc comment.
  static const String _createRelationshipsTable = '''
      -- Relationships table links notes with a relationship.
      CREATE TABLE relationships(
        id TEXT PRIMARY KEY, -- Unique identifier
        fromNoteId TEXT NOT NULL, -- Source note ID
        toNoteId TEXT NOT NULL, -- Target note ID
        type TEXT NOT NULL, -- Relationship type (e.g., 'linked', 'parent', 'child')
        createdAt INTEGER NOT NULL, -- Creation timestamp
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.8)
        FOREIGN KEY (fromNoteId) REFERENCES notes (id) ON DELETE CASCADE,
        FOREIGN KEY (toNoteId) REFERENCES notes (id) ON DELETE CASCADE
      )
  ''';

  // M1.7 (design doc § Phased delivery, M1.7 — "filters + tag_workflow_
  // bindings: independent, single-statement, no FK/diff complexity"):
  // deletion is now always a tombstone write (`__deleted__=1`), never a
  // real SQL DELETE — see deleteFilter below, and getAllFilters/getFilter,
  // which filter through `__deleted__ = 0` on every read. `filters` has no
  // incoming/outgoing FKs and no fallback-selection concept (unlike
  // app_revisions), so a plain `__deleted__ = 0` filter is already the
  // effective one — no derived-visibility helper is needed the way
  // computeAppRevisionVisibility was for the User-App family.
  static const String _createFiltersTable = '''
      -- Filters are set of tags and substring conditions to select certain notes.
      --   Filters can be considered to have hierarchy. A filter that matches tags A and B,
      --   is a parent filter of a filter that matches tags A, B and C.
      CREATE TABLE filters(
        id TEXT PRIMARY KEY, -- Unique identifier
        name TEXT NOT NULL, -- Filter name
        includeText TEXT, -- Text to search for
        includeTags TEXT NOT NULL, -- JSON array of tags to include
        excludeTags TEXT NOT NULL DEFAULT '', -- JSON array of tags to exclude
        noteTypes TEXT NOT NULL DEFAULT '', -- JSON array of note types
        includeArchived INTEGER NOT NULL DEFAULT 0, -- Whether to include archived notes
        isPinned INTEGER NOT NULL DEFAULT 0, -- Whether filter is pinned to top
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL, -- Last update timestamp
        isSpace INTEGER NOT NULL DEFAULT 0, -- Whether filter is usable as an activatable Space
        __deleted__ INTEGER NOT NULL DEFAULT 0 -- Soft-delete tombstone flag (M1.7)
      )
  ''';

  // M1.4 (design doc § Architecture 10, "User Apps + revision history"):
  // deletion across this whole family (user_apps/app_revisions/
  // user_app_libraries/user_app_library_dependencies) is now always a
  // tombstone write (`__deleted__=1`), never a real SQL DELETE — see
  // deleteUserApp/deleteAppRevision/deleteUserAppLibrary/
  // deleteUserAppLibraryDependency below, and the effective-visibility
  // computation (computeAppRevisionVisibility's doc comment) that every
  // read path in this section filters through instead of raw `__deleted__`.
  // `app_revisions.deletedAt` is new for this milestone too — see
  // computeAppRevisionVisibility for why (fallback-selection tie-break).
  static const String _createUserAppsTable = '''
      CREATE TABLE user_apps(
        id TEXT PRIMARY KEY, -- Unique identifier
        uuid TEXT NOT NULL UNIQUE, -- Stable UUID across imports/exports
        name TEXT NOT NULL, -- App name
        description TEXT NOT NULL, -- App description
        steps TEXT NOT NULL, -- JSON array of steps/requirements
        htmlContent TEXT NOT NULL, -- Current HTML content (legacy, use revisions)
        appState TEXT, -- JSON object storage for app persistence
        type TEXT NOT NULL DEFAULT 'normal', -- App type: 'normal', 'noteAction', 'aiTool', etc.
        selectedRevisionId TEXT, -- Currently active revision ID
        author TEXT DEFAULT "", -- Author name
        license TEXT DEFAULT "", -- License text
        i18n TEXT, -- JSON object: locale -> localized name/description
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL, -- Last update timestamp
        __deleted__ INTEGER NOT NULL DEFAULT 0 -- Soft-delete tombstone flag (M1.4). Apps have no fallback concept: this value is authoritative.
      )
  ''';

  static const String _createAppRevisionsTable = '''
      CREATE TABLE app_revisions(
        id TEXT PRIMARY KEY, -- Unique identifier
        appId TEXT NOT NULL, -- Parent app ID
        revisionNumber INTEGER NOT NULL, -- Revision number
        revisionTimestamp INTEGER NOT NULL, -- Timestamp
        userPrompt TEXT NOT NULL, -- User instructions causing revision
        aiResponse TEXT NOT NULL, -- AI explanation/response
        appCode TEXT NOT NULL, -- Full HTML code of the app
        attachmentPaths TEXT, -- JSON array of attachment paths
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.4). Raw value only -- see computeAppRevisionVisibility for the effective (fallback-aware) value.
        deletedAt INTEGER, -- Wall-clock ms when __deleted__ was last set to 1 (NULL if never deleted, or after an undelete). Fallback-selection tie-break input only.
        FOREIGN KEY (appId) REFERENCES user_apps (id) ON DELETE CASCADE
      )
  ''';

  static const String _createUserAppLibrariesTable = '''
      CREATE TABLE user_app_libraries(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        app_uuid TEXT NOT NULL, -- App UUID this library belongs to
        revision_id INTEGER NOT NULL, -- Revision number this library belongs to
        name TEXT NOT NULL, -- Library name
        usage_instructions TEXT, -- Instructions for using the library
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.4). Effective visibility also requires the owning revision to be effectively visible -- see isUserAppLibraryEffectivelyVisible.
        FOREIGN KEY (app_uuid) REFERENCES user_apps (uuid) ON DELETE CASCADE
      )
  ''';

  static const String _createUserAppLibraryDependenciesTable = '''
      CREATE TABLE user_app_library_dependencies(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        original_url TEXT, -- Original URL of the library
        local_path TEXT NOT NULL, -- Local storage path
        bytes BLOB NOT NULL, -- Raw file content
        library_id INTEGER NOT NULL, -- Parent library ID
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.4). Effective visibility also requires the owning library to be effectively visible -- see isUserAppLibraryDependencyEffectivelyVisible.
        FOREIGN KEY (library_id) REFERENCES user_app_libraries (id) ON DELETE CASCADE
      )
  ''';

  // M1.12 (design doc § Phased delivery, M1.12 — "conversations +
  // conversation_messages family"): deletion via `deleteConversation`/
  // `deleteConversationExplicitly` is now always a tombstone write
  // (`__deleted__=1`), never a real SQL DELETE — see those functions below,
  // and `getAllConversations`/`getConversation`, which filter through
  // `__deleted__ = 0` on every read. This is a straightforward entity
  // tombstone, no derived-visibility complexity (unlike
  // `conversation_messages` below): a conversation's own row identity is
  // never resurrected by some other table's live membership the way a
  // message's is. `_cleanupEmptyConversations`/`deleteEmptyConversations`
  // are a separate, related design decision — see `_cleanupEmptyConversations`'s
  // own doc comment for why this milestone deliberately does NOT write
  // `__deleted__` from either of them.
  static const String _createConversationsTable = '''
      -- conversations are threads of messages that represents interactions with AI.
      CREATE TABLE conversations(
        id TEXT PRIMARY KEY, -- Unique identifier
        title TEXT NOT NULL, -- Conversation title
        noteIds TEXT NOT NULL DEFAULT '[]', -- JSON array of linked note IDs (DEPRECATED, use conversation_note_mapping instead)
        createdAt INTEGER NOT NULL, -- Creation timestamp
        updatedAt INTEGER NOT NULL, -- Last update timestamp
        isArchived INTEGER NOT NULL DEFAULT 0, -- Whether archived
        __deleted__ INTEGER NOT NULL DEFAULT 0 -- Soft-delete tombstone flag (M1.12)
      )
  ''';

  // M1.12: `conversation_messages` gains a real `__deleted__` column for the
  // first time (it never had one before this milestone). Unlike every other
  // entity table converted in this effort, a raw `__deleted__=1` here does
  // NOT by itself mean the row is deleted for display/read purposes — see
  // `computeConversationMessageVisibility`'s doc comment (near the
  // conversation-messages CRUD section below) for the full derived-
  // effective-deletedness formula (§ Architecture 6): a message with ANY
  // live `conversation_message_mapping` row is never effectively deleted,
  // regardless of this raw flag. `deleteConversationMessage`/
  // `_deleteMessagesBatch` write this flag; every message-content read path
  // must consult the derived formula, not this column alone.
  static const String _createConversationMessagesTable = '''
      -- conversation_messages represent individual messages that appear in conversations. A message can be associated with multiple conversations
      -- in NoteSynapse's tree-structured conversation model.
      CREATE TABLE conversation_messages(
        id TEXT PRIMARY KEY, -- Unique identifier
        type TEXT NOT NULL, -- Message type: 'user', 'ai'
        content TEXT NOT NULL, -- Message content
        timestamp INTEGER NOT NULL, -- Timestamp
        modelUsed TEXT, -- AI model identifier if applicable
        metadata TEXT, -- JSON string for extra metadata
        __deleted__ INTEGER NOT NULL DEFAULT 0 -- Soft-delete tombstone flag (M1.12). Raw value only -- see computeConversationMessageVisibility for the effective (membership-aware) value.
      )
  ''';

  // M1.8 (design doc § Phased delivery, M1.8): deletion via the standalone
  // `deleteConversationAttachment` is now always a tombstone write
  // (`__deleted__=1`), never a real SQL DELETE — see
  // getConversationAttachments/_populateMessageAttachmentPaths below, which
  // filter through `__deleted__ = 0` on every read. **M1.12 update**:
  // `_deleteMessagesBatch`'s own `conversation_attachments` delete (part of
  // a batch `conversation_messages` deletion) is now ALSO converted to a
  // tombstone write, now that `conversation_messages` itself gained
  // `__deleted__` this same milestone — see `_deleteMessagesBatch`'s own
  // doc comment for the full reasoning (the M1.8-era justification for
  // leaving it real, "the parent row still gets a real hard delete", no
  // longer holds once the parent is tombstoned too). `conversation_messages
  // -> conversation_attachments ON DELETE CASCADE` remains declared in the
  // schema (an accurate, inert fact about what a real `DELETE FROM
  // conversation_messages` would still do) but no longer fires for any
  // converted function, same as every other cascade this whole effort has
  // replaced with explicit statements.
  static const String _createConversationAttachmentsTable = '''
      CREATE TABLE conversation_attachments(
        id TEXT PRIMARY KEY, -- Unique identifier
        messageId TEXT NOT NULL, -- Parent message ID
        filePath TEXT NOT NULL, -- Path to file
        fileName TEXT NOT NULL, -- File name
        fileType TEXT NOT NULL, -- MIME type or extension
        isRelativePath INTEGER NOT NULL DEFAULT 0, -- Whether path is relative
        createdAt INTEGER NOT NULL, -- Creation timestamp
        __deleted__ INTEGER NOT NULL DEFAULT 0, -- Soft-delete tombstone flag (M1.8, deleteConversationAttachment only -- see _deleteMessagesBatch's own doc comment for why the batch-delete path is unconverted)
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE
      )
  ''';

  static const String _createConversationMessageMappingTable = '''
      CREATE TABLE conversation_message_mapping(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        conversationId TEXT NOT NULL, -- Conversation ID
        messageId TEXT NOT NULL, -- Message ID
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        UNIQUE(conversationId, messageId)
      )
  ''';

  Future<void> insertConversationMessageMappingsBatch(
    String conversationId,
    List<String> messageIds,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final messageId in messageIds) {
        batch.insert('conversation_message_mapping', {
          'conversationId': conversationId,
          'messageId': messageId,
          'createdAt': now,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  static const String _createMessageParentsTable = '''
      CREATE TABLE message_parents(
        id TEXT PRIMARY KEY, -- Unique identifier
        messageId TEXT NOT NULL, -- Child message ID
        parentMessageId TEXT NOT NULL, -- Parent message ID
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        FOREIGN KEY (parentMessageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
        UNIQUE(messageId, parentMessageId)
      )
  ''';

  static const String _createConversationNoteMappingTable = '''
      CREATE TABLE conversation_note_mapping(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Unique identifier
        conversationId TEXT NOT NULL, -- Conversation ID
        noteId TEXT NOT NULL, -- Note ID
        createdAt INTEGER NOT NULL, -- Creation timestamp
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
        UNIQUE(conversationId, noteId)
      )
  ''';
  static const String _createMultiFunctionAppsTable = '''
      CREATE TABLE multi_function_apps(
        appId TEXT PRIMARY KEY, -- App ID
        isDefault INTEGER NOT NULL DEFAULT 0, -- Whether it is the default app
        addedAt INTEGER NOT NULL, -- Timestamp added
        FOREIGN KEY (appId) REFERENCES user_apps (id) ON DELETE CASCADE
      )
  ''';

  // M1.9: same derived-visibility model as `tag_images` above — no
  // independent tombstone, visibility derived from the owning tag's
  // `__deleted__` state at read time (getTagExtractionPrompt).
  static const String _createTagAiConfigsTable = '''
      CREATE TABLE tag_ai_configs (
        tagId TEXT PRIMARY KEY,
        extractionPrompt TEXT,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
  ''';

  // M1.7: deletion is now always a tombstone write (`__deleted__=1`), never
  // a real SQL DELETE — see deleteWorkflowBinding below, and
  // getExactWorkflowBinding/getPrefixWorkflowBindings/
  // getWorkflowBindingByPattern/getAllWorkflowBindings, which all filter
  // through `__deleted__ = 0` on every read (resolveBindings, in
  // tag_workflow_service.dart, must only ever match a LIVE binding).
  // `pattern` is the primary key and `insertWorkflowBinding` already always
  // writes via `ConflictAlgorithm.replace`, so re-registering a binding
  // under a previously-tombstoned pattern fully overwrites that row —
  // including implicitly resetting `__deleted__` back to its column
  // default of 0, since the INSERT never mentions the column — with no
  // separate identity-collision gap of the kind M1.3 hit for `tags.name`
  // (see registerBinding/insertWorkflowBinding).
  static const String _createTagWorkflowBindingsTable = '''
      CREATE TABLE IF NOT EXISTS tag_workflow_bindings (
        pattern TEXT PRIMARY KEY,
        isPrefix INTEGER NOT NULL DEFAULT 0,
        skillNoteId TEXT NOT NULL,
        prompt TEXT NOT NULL DEFAULT '',
        contentImmutable INTEGER NOT NULL DEFAULT 0,
        __deleted__ INTEGER NOT NULL DEFAULT 0 -- Soft-delete tombstone flag (M1.7)
      )
  ''';

  // ===========================================================================
  // CRDT cloud-sync control-plane tables (M1.1).
  //
  // These fifteen tables are the pure-additive schema milestone for the cloud
  // sync design (.claude/plans/plan-and-propse-the-glistening-dolphin.md).
  // They store sync *machinery* state (causal dots/frontiers, outbox,
  // dedup/redirect bookkeeping, GC bookkeeping) — never user-facing content —
  // so, unlike the tables above, they are deliberately:
  //   - NOT added to getSchema()/getSchemaDescription(), which feed the
  //     AI-facing schema documentation (user_app_service.dart, note_tools.dart)
  //     and the raw-data-manager schema viewer; the same reasoning that keeps
  //     `_schema_version` out of that list applies here.
  //   - NOT merged by recovery_screen.dart's backup-import flow, matching how
  //     `multi_function_apps` is already excluded — see the comment there.
  //
  // Column shapes fall into two groups:
  //   (a) Explicitly specified by the design doc, quoted almost verbatim:
  //       sync_conflict_copies, sync_dedup_index, sync_dot_redirects.
  //   (b) Named only, with PURPOSE described across many paragraphs but no
  //       column list ("Core tables unchanged in shape from round 4-7" —
  //       i.e. specified in a design round that predates this document, not
  //       recoverable from its text). For these, the schema below is this
  //       milestone's own reasoned inference from the doc's purpose
  //       descriptions, documented per-table below, citing the § Architecture
  //       section that motivated each inferred column.
  //
  // Every dot in the protocol is the pair (authorId, authorSeq) — a real
  // device id, or "seed:<deviceUuid>" / "external:<deviceUuid>" — per the
  // canonical operation encoding (§ Architecture 1, "Canonical operation
  // encoding"). A frontier is `{baselineSnapshotHash, deltaFrontier:
  // {authorId: maxSeq}}` (§ Architecture 2); stored as JSON text throughout
  // since sqlite has no native map type, matching how `appState`/`metadata`
  // JSON blobs are already stored elsewhere in this file.
  // ===========================================================================

  // sync_field_state: the current winning value for one CRDT register field,
  // one row per (entityTable, entityId, fieldName) — inferred from § Arch. 1's
  // repeated description of "the actual sync_field_state incremental protocol
  // (single row per field, each arrival compared only against the current
  // winner)" (line ~1200) and the recheck-on-discovery algorithm's step 4,
  // "materialize the final winner as the field's sync_field_state value".
  // Losing candidates are NOT retained here (they live in
  // sync_conflict_copies, which the recheck algorithm explicitly re-loads
  // separately from the current winner) — full per-field *history* retention
  // (round 19, phased-delivery section) is therefore sync_conflict_copies
  // never discarding a loser, not multiple rows in this table.
  // frontierJson/hlc/contentKey persist the winning operation's own identity
  // so a later arrival can be compared against it via causally_includes'''
  // without re-deriving it.
  static const String _createSyncFieldStateTable = '''
      CREATE TABLE IF NOT EXISTS sync_field_state (
        entityTable TEXT NOT NULL, -- table the field belongs to, e.g. 'notes'
        entityId TEXT NOT NULL, -- row id within entityTable
        fieldName TEXT NOT NULL, -- CRDT register field name
        valueJson TEXT, -- current winning value (JSON-encoded)
        blobHash TEXT, -- current winning value, when the field is blob-typed
        authorId TEXT NOT NULL, -- winning dot's authorId
        authorSeq INTEGER NOT NULL, -- winning dot's authorSeq
        hlc TEXT NOT NULL, -- winning operation's HLC (tiebreak source)
        contentKey TEXT, -- present only for seed/external-edit-originated winners
        frontierJson TEXT NOT NULL, -- winning operation's frontier snapshot
        updatedAt INTEGER NOT NULL, -- local wall-clock, for UI/debugging only
        PRIMARY KEY (entityTable, entityId, fieldName)
      )
  ''';

  // sync_set_state: live OR-Set membership rows, one row per still-live
  // add-dot — inferred from § Architecture 1's canonical operation encoding,
  // where a 'set_remove' carries `targetDots: [{authorId, authorSeq}]`, "the
  // add-dot(s) being observed as removed". Presence in this table (rather
  // than a boolean column) *is* OR-Set membership: a member is live iff at
  // least one of its add-dots has a row here; applying a matching
  // 'set_remove' deletes that specific dot's row (after resolving through
  // sync_dot_redirects, § Architecture 1). Multiple rows can legitimately
  // exist for the same (entity, field, member) when concurrent devices each
  // minted their own add-dot before observing each other — this is the OR-Set
  // property being modeled, not a bug.
  static const String _createSyncSetStateTable = '''
      CREATE TABLE IF NOT EXISTS sync_set_state (
        entityTable TEXT NOT NULL, -- table the set belongs to
        entityId TEXT NOT NULL, -- row id within entityTable
        fieldName TEXT NOT NULL, -- set/collection field name
        memberUuid TEXT NOT NULL, -- the member this add-dot adds
        authorId TEXT NOT NULL, -- this add-dot's authorId
        authorSeq INTEGER NOT NULL, -- this add-dot's authorSeq
        hlc TEXT NOT NULL, -- add operation's HLC
        contentKey TEXT, -- present only for seed/external-edit-originated adds
        frontierJson TEXT NOT NULL, -- add operation's frontier snapshot
        updatedAt INTEGER NOT NULL, -- local wall-clock, for UI/debugging only
        PRIMARY KEY (entityTable, entityId, fieldName, memberUuid, authorId, authorSeq)
      )
  ''';

  // sync_grave: tombstone marker retained after a deleted entity's underlying
  // data is physically purged — § Architecture 6, "Purging a deleted entity
  // retains a grave marker (sync_grave)", extended (round 11) to cover "any
  // tombstoned entity's underlying data, not only blobs and orphan messages".
  // Its purpose is to let a stale, late-arriving reference to already-purged
  // data be rejected with evidence rather than silently resurrecting it
  // (§ Architecture 4's orphan-message discussion makes this explicit for the
  // blob/orphan case; round 11 generalizes it to every purge). `reason` is an
  // inferred, non-normative diagnostic column — the doc never names purge
  // "reasons" as a controlled vocabulary the protocol itself branches on.
  static const String _createSyncGraveTable = '''
      CREATE TABLE IF NOT EXISTS sync_grave (
        subjectTable TEXT NOT NULL, -- purged entity's table
        subjectId TEXT NOT NULL, -- purged entity's row id
        purgedAt INTEGER NOT NULL, -- when physical removal happened
        reason TEXT, -- free-form diagnostic (e.g. 'user_delete', 'orphan', 'blob_gc')
        PRIMARY KEY (subjectTable, subjectId)
      )
  ''';

  // sync_touch_log: durable capture of raw local mutations on synced tables,
  // ahead of causal-operation minting — inferred from this section's own
  // title, "Local schema, durable mutation capture..." (§ Architecture 1),
  // and "mutation capture" being named (unchanged from round 6) alongside the
  // hard-delete guard and field allowlist as an already-decided mechanism
  // this document never re-quotes the shape of. The append-only log here is
  // what a durable-mutation-capture design needs: a crash between a local
  // write and its Operation being minted into sync_pending_ops must not lose
  // the write, so the capture step (assumed trigger-based, matching this
  // project's existing TEMP-journal capture-trigger pattern used elsewhere in
  // this file for note-domain change tracking) durably records the touch
  // first; `processedAt` marks when it was turned into a sync_pending_ops
  // operation (or found to need none, e.g. a write reverting a field to its
  // already-synced value).
  static const String _createSyncTouchLogTable = '''
      CREATE TABLE IF NOT EXISTS sync_touch_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entityTable TEXT NOT NULL, -- table that was touched
        entityId TEXT NOT NULL, -- row id that was touched
        fieldName TEXT, -- field touched, if field-scoped (null for whole-row/__exists__ touches)
        memberUuid TEXT, -- set member touched, if set-membership-scoped
        touchedAt INTEGER NOT NULL, -- local capture timestamp
        processedAt INTEGER -- when minted into sync_pending_ops (null = not yet processed)
      )
  ''';

  static const String _createSyncTouchLogUnprocessedIndex = '''
      CREATE INDEX IF NOT EXISTS idx_sync_touch_log_unprocessed
      ON sync_touch_log(processedAt)
  ''';

  // sync_pending_ops: the outbox of canonical Operations minted locally but
  // not yet published into the hash-linked commit log — § Architecture 2's
  // title names "the outbox" as part of the causal operation model; § 3
  // ("append-only, hash-linked commits... publish-intent idempotency")
  // describes what eventually drains this table. Columns mirror the
  // "Canonical operation encoding" written out in full in § Architecture 1
  // (`Operation { authorId, authorSeq, hlc, contentKey, kind, entityTable,
  // entityId, fieldName (or memberUuid for set ops), valueJson | blobHash,
  // targetDots, frontier }`) directly, one outbox row per Operation.
  // fieldName and memberUuid are kept as separate nullable columns (rather
  // than reusing one column for both, as the doc's shorthand "fieldName (or
  // memberUuid for set ops)" might suggest) purely for read clarity — no
  // protocol meaning depends on which column layout is used locally, since
  // this table is never a wire format. UNIQUE(authorId, authorSeq) enforces
  // dot uniqueness within this device's own outbox.
  static const String _createSyncPendingOpsTable = '''
      CREATE TABLE IF NOT EXISTS sync_pending_ops (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        authorId TEXT NOT NULL,
        authorSeq INTEGER NOT NULL,
        hlc TEXT NOT NULL,
        contentKey TEXT,
        kind TEXT NOT NULL, -- '__exists__' | 'field' | 'set_add' | 'set_remove'
        entityTable TEXT NOT NULL,
        entityId TEXT NOT NULL,
        fieldName TEXT,
        memberUuid TEXT,
        valueJson TEXT,
        blobHash TEXT,
        targetDotsJson TEXT, -- JSON array of {authorId, authorSeq}; 'set_remove' only
        frontierJson TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        publishedAt INTEGER, -- null = still pending publish
        UNIQUE (authorId, authorSeq)
      )
  ''';

  // sync_state: device/dataset-level singleton state — inferred purely from
  // the table's name and its placement alongside sync_ack_frontier/
  // sync_device_labels in § Architecture 1's table list, since the document
  // never elaborates on it further. Modeled as a generic key/value store
  // rather than fixed columns (e.g. this device's own id, the dataset id, the
  // per-authorId local sequence counters backing authorSeq minting, the
  // last-published commit hash, the last local snapshot hash) because none of
  // those individual pieces of singleton state are pinned down by name in the
  // document, and a key/value shape lets later milestones add a new piece of
  // singleton state without another schema migration — the same flexibility
  // reason `appState`/`metadata` JSON columns are used elsewhere in this
  // file for not-yet-fully-specified per-row state.
  static const String _createSyncStateTable = '''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
  ''';

  // sync_ack_frontier: per-remote-device acknowledged frontier heights —
  // inferred from § Architecture 6's "publication fence (a device that's
  // acknowledged S must build all future work on top of S)" and the
  // join-vs-log-pruning race fix's "fresh recheck of dataset_members" before
  // physical log deletion: both require knowing, per known remote device,
  // what it has acknowledged. One row per (deviceId, authorId) the remote
  // device has acknowledged observing up through `ackedSeq` — the same
  // `{authorId: maxSeq}` shape as a frontier (§ Architecture 2), just scoped
  // per remote device instead of per local operation.
  static const String _createSyncAckFrontierTable = '''
      CREATE TABLE IF NOT EXISTS sync_ack_frontier (
        deviceId TEXT NOT NULL, -- the remote device this row is about
        authorId TEXT NOT NULL, -- an author whose sequence deviceId has acknowledged
        ackedSeq INTEGER NOT NULL, -- highest authorSeq of authorId acknowledged by deviceId
        updatedAt INTEGER NOT NULL,
        PRIMARY KEY (deviceId, authorId)
      )
  ''';

  // sync_device_labels: deviceId -> user-facing label — inferred from the
  // table name plus § Architecture 9's "Settings UI, bootstrap, and restore
  // identity semantics" (devices must be presentable to the user somewhere)
  // and § Architecture 2's explicit "O(devices ever, including retired ones)"
  // boundedness claim, which implies devices are tracked even after they stop
  // being active — hence `retiredAt`, so a retired device can still be shown
  // distinctly rather than removed outright (removing its label row would
  // not shrink the actual frontier-growth bound the boundedness claim is
  // about, since that bound is over authorIds appearing in frontiers, not
  // over this display-only table).
  static const String _createSyncDeviceLabelsTable = '''
      CREATE TABLE IF NOT EXISTS sync_device_labels (
        deviceId TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        isCurrentDevice INTEGER NOT NULL DEFAULT 0,
        retiredAt INTEGER, -- null while the device is still an active dataset member
        updatedAt INTEGER NOT NULL
      )
  ''';

  // sync_view_cache: backs § Architecture 5, "Canonical human-readable views
  // and external plain-file edits". An external-edit operation's contentKey
  // `baseContext` is "the frontier/projectionDigest embedded in the edited
  // projection file... already tracked for that operation's frontier" (§
  // Architecture 1's contentKey round-14 correction) — this table is the
  // local record of "what did we last project to disk for this entity, and
  // what digest did that projection carry", needed to detect an external
  // edit (the on-disk file no longer matches the cache) and to compute its
  // contentKey's baseContext from the *previous* projection, not the new one.
  static const String _createSyncViewCacheTable = '''
      CREATE TABLE IF NOT EXISTS sync_view_cache (
        entityTable TEXT NOT NULL,
        entityId TEXT NOT NULL,
        filePath TEXT NOT NULL, -- external plain-file path this entity projects to
        projectionDigest TEXT NOT NULL, -- hash of the last-synced projected content
        lastSyncedAt INTEGER NOT NULL,
        PRIMARY KEY (entityTable, entityId)
      )
  ''';

  static const String _createSyncViewCacheFilePathIndex = '''
      CREATE INDEX IF NOT EXISTS idx_sync_view_cache_filePath
      ON sync_view_cache(filePath)
  ''';

  // sync_blob_refs: per-blob-hash GC bookkeeping for § Architecture 4's
  // policy-based blob GC — "a blob isn't even considered a GC candidate until
  // it's absent from the most recently certified snapshot's consolidated
  // state" (starts the `status='candidate'` grace period), "at the *end* of
  // the grace period, GC performs a fresh recheck... if the blob has since
  // become referenced, it's dropped from candidacy" (back to 'live'), "only
  // if it's *still* unreferenced does deletion proceed" ('eligible', shown to
  // the user for confirmation per the manual "Clean up deleted items" flow,
  // then 'deleted'). `candidateSince` records when the grace period started,
  // needed to know when it ends.
  static const String _createSyncBlobRefsTable = '''
      CREATE TABLE IF NOT EXISTS sync_blob_refs (
        blobHash TEXT PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'live', -- 'live' | 'candidate' | 'eligible' | 'deleted'
        candidateSince INTEGER, -- when the grace period started; null while 'live'
        lastCheckedAt INTEGER,
        createdAt INTEGER NOT NULL
      )
  ''';

  // sync_publish_intent: idempotent commit-publication marker — § Arch. 3's
  // summary names "publish-intent idempotency" as part of the unchanged
  // append-only hash-linked commit protocol. Its purpose (standard for this
  // pattern): record, in the same local transaction as minting a commit,
  // that this device *intends* to publish a specific commit (identified by a
  // deterministic hash of its parent + payload) before attempting the actual
  // remote write, so a crash/retry after a partially-completed publish
  // recognizes "I already have an intent for this exact commit" instead of
  // minting a second, divergent commit for the same local state — consistent
  // with the same section's "halt-not-retarget" policy on publish conflicts.
  //
  // M2.6 (`lib/services/sync/push_phase.dart`) adds `authorId`/`deviceSeq`
  // (fresh installs via this CREATE TABLE; existing installs via
  // `_migrateToVersion59`'s ALTER TABLE) — a schema gap the original
  // definition left open. § Architecture 11.7 Phase A step 0's resume
  // procedure requires scanning `sync_publish_intent` for `status='pending'`
  // rows "for this namespace" and calling `readCommits(deviceLogId, afterSeq
  // = <the pending intent's deviceSeq> - 1)`, but the original schema had no
  // column recording *which* namespace or *which* deviceSeq a pending intent
  // belongs to — `intentHash`/`payloadHash` alone are opaque hashes, not
  // reversible back to the (authorId, deviceSeq) they describe. Both columns
  // are nullable for backward compatibility with any row inserted before
  // this migration (none exist in any real install yet, since no code before
  // M2.6 ever called `appendCommit`), but every row `push_phase.dart` writes
  // populates both.
  static const String _createSyncPublishIntentTable = '''
      CREATE TABLE IF NOT EXISTS sync_publish_intent (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        intentHash TEXT NOT NULL UNIQUE, -- deterministic hash of (parentCommitHash, payloadHash)
        parentCommitHash TEXT,
        payloadHash TEXT NOT NULL,
        authorId TEXT, -- M2.6: the authorId namespace this intent publishes to
        deviceSeq INTEGER, -- M2.6: the COMMIT-CHAIN position this intent publishes at (never an authorSeq -- see push_phase.dart)
        opAuthorSeqsJson TEXT, -- M2.12: JSON array of the sync_pending_ops.authorSeq values this commit carries; NULL on a pre-M2.12 (one-operation-per-commit) intent
        status TEXT NOT NULL DEFAULT 'pending', -- 'pending' | 'confirmed'
        createdAt INTEGER NOT NULL,
        confirmedAt INTEGER
      )
  ''';

  // sync_materialize_queue: durable queue of operations/fields blocked on a
  // prerequisite — § Architecture 1 enumerates the blocking-reason values
  // this table must represent across several paragraphs: "missing parent or
  // __exists__" (the original reasons, named in passing while introducing
  // `missing_referenced_dot`), `missing_referenced_dot` ("a new blocking
  // reason... alongside the existing missing-parent and missing-__exists__
  // reasons"), and `pending_recheck` (recheck-on-discovery's durability fix,
  // "an enqueue of the affected field into the existing sync_materialize_queue
  // mechanism (a new blocking reason, pending_recheck...)"). `operationJson`
  // is nullable because `pending_recheck` entries queue a *recomputation* of
  // an already-materialized field, not a specific blocked incoming Operation.
  // `blockingKey` is an inferred column (not named in the doc) so a retry
  // sweep can index "what would unblock this entry" (a dot, an entity id, a
  // field) without deserializing every row's operationJson.
  static const String _createSyncMaterializeQueueTable = '''
      CREATE TABLE IF NOT EXISTS sync_materialize_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        blockingReason TEXT NOT NULL, -- 'missing_parent' | 'missing_exists' | 'missing_referenced_dot' | 'pending_recheck'
        entityTable TEXT NOT NULL,
        entityId TEXT NOT NULL,
        fieldName TEXT,
        operationJson TEXT, -- the blocked Operation payload; null for 'pending_recheck'
        blockingKey TEXT, -- what this entry is waiting on, for indexed retry sweeps
        enqueuedAt INTEGER NOT NULL
      )
  ''';

  static const String _createSyncMaterializeQueueBlockingKeyIndex = '''
      CREATE INDEX IF NOT EXISTS idx_sync_materialize_queue_blockingKey
      ON sync_materialize_queue(blockingKey)
  ''';

  // sync_conflict_copies: schema written out explicitly by the design doc
  // (§ Architecture 1, "sync_conflict_copies schema, written out explicitly
  // (round 10)"): `id` deterministically derived from the losing
  // dot/operation; `kind` discriminates 'field_conflict' | 'rejected_merge' |
  // 'displaced_field'; `fieldName` and `resolvedFieldsJson` persist the
  // losing operation's full `{value, dot, frontier, hlc}` for
  // 'field_conflict' rows specifically, needed by recheck-on-discovery to
  // recompute causal-dominance long after the original operation has left
  // the live log. The doc also specifies the supporting index verbatim:
  // "A new index (subjectTable, subjectId, fieldName, kind) supports that
  // mechanism's lookup."
  //
  // M2.5 (`lib/services/sync/causal/field_conflict_resolver.dart`) extends
  // `kind`'s vocabulary with two more locally-scoped values while settling
  // § Architecture 11.4's open `sync_conflict_copies` full-history-retention
  // question empirically: 'field_conflict_superseded' (a proven causal
  // ancestor, retained off the live/user-facing view purely as a future
  // `chainDom` witness) and 'contentkey_alias_witness' (a permanent,
  // never-cleared per-dot record of every contentKey-bearing candidate ever
  // observed for a field, needed so a non-representative alias's own
  // frontier survives once its group wins). No `CHECK` constraint enforces
  // `kind`'s vocabulary at the schema level — see that file's own top doc
  // comment for the full reasoning, the regression scenarios that required
  // each addition, and each new value's own boundedness characterization
  // (the two are NOT bounded the same way).
  static const String _createSyncConflictCopiesTable = '''
      CREATE TABLE IF NOT EXISTS sync_conflict_copies (
        id TEXT PRIMARY KEY, -- deterministic hash of the losing dot/operation
        subjectTable TEXT NOT NULL,
        subjectId TEXT NOT NULL,
        kind TEXT NOT NULL, -- 'field_conflict' | 'rejected_merge' | 'displaced_field' | 'field_conflict_superseded' | 'contentkey_alias_witness'
        fieldName TEXT, -- nullable; populated for 'field_conflict' rows
        resolvedFieldsJson TEXT, -- 'field_conflict': losing op's {value, dot, frontier, hlc}
        createdAt INTEGER NOT NULL
      )
  ''';

  static const String _createSyncConflictCopiesLookupIndex = '''
      CREATE INDEX IF NOT EXISTS idx_sync_conflict_copies_lookup
      ON sync_conflict_copies(subjectTable, subjectId, fieldName, kind)
  ''';

  // sync_dedup_index: schema given verbatim by the design doc (§ Architecture
  // 1): "sync_dedup_index(contentKey, canonicalAuthorId, canonicalAuthorSeq)".
  // Records the canonical-winner dot for each contentKey equivalence class
  // (lexicographically smallest `(authorId, authorSeq)` among competing dots
  // sharing that contentKey).
  static const String _createSyncDedupIndexTable = '''
      CREATE TABLE IF NOT EXISTS sync_dedup_index (
        contentKey TEXT PRIMARY KEY,
        canonicalAuthorId TEXT NOT NULL,
        canonicalAuthorSeq INTEGER NOT NULL
      )
  ''';

  // sync_dot_redirects: schema given verbatim by the design doc (§
  // Architecture 1): "sync_dot_redirects(observedAuthorId, observedAuthorSeq,
  // canonicalAuthorId, canonicalAuthorSeq)" — a permanent redirect from a
  // non-canonical duplicate dot to its contentKey class's canonical dot, so
  // any later reference to the non-canonical dot (e.g. a set_remove's
  // targetDots) still resolves correctly. Primary key is the observed dot,
  // since each non-canonical dot redirects to exactly one canonical dot.
  static const String _createSyncDotRedirectsTable = '''
      CREATE TABLE IF NOT EXISTS sync_dot_redirects (
        observedAuthorId TEXT NOT NULL,
        observedAuthorSeq INTEGER NOT NULL,
        canonicalAuthorId TEXT NOT NULL,
        canonicalAuthorSeq INTEGER NOT NULL,
        PRIMARY KEY (observedAuthorId, observedAuthorSeq)
      )
  ''';

  /// Single source of truth for the fifteen M1.1 sync control-plane
  /// tables (plus their non-primary-key indexes), shared verbatim by the
  /// fresh-install path (_onCreate) and the additive migration
  /// (_migrateToVersion48) so the two paths can never drift apart — every
  /// statement uses IF NOT EXISTS, so running it against either an empty
  /// database or an already-migrated one is always safe.
  static const List<String> _syncControlPlaneTableStatements = [
    _createSyncFieldStateTable,
    _createSyncSetStateTable,
    _createSyncGraveTable,
    _createSyncTouchLogTable,
    _createSyncTouchLogUnprocessedIndex,
    _createSyncPendingOpsTable,
    _createSyncStateTable,
    _createSyncAckFrontierTable,
    _createSyncDeviceLabelsTable,
    _createSyncViewCacheTable,
    _createSyncViewCacheFilePathIndex,
    _createSyncBlobRefsTable,
    _createSyncPublishIntentTable,
    _createSyncMaterializeQueueTable,
    _createSyncMaterializeQueueBlockingKeyIndex,
    _createSyncConflictCopiesTable,
    _createSyncConflictCopiesLookupIndex,
    _createSyncDedupIndexTable,
    _createSyncDotRedirectsTable,
  ];

  // ===========================================================================
  // M1.5 (extended by M1.13): the hard-delete guard (design doc §
  // Architecture 1, "the hard-delete guard... `BEFORE DELETE...
  // RAISE(ABORT, ...)` on every synced table"). One trigger per guarded
  // table that unconditionally aborts any real `DELETE` against it,
  // forcing every remaining code path (including any future regression)
  // through the ordinary `__deleted__=1` soft-delete write instead.
  //
  // **Original M1.5 scope, deliberately narrow (design doc § Status, M1
  // status section, "M1.5 remains the highest-risk remaining piece"): only
  // the four User-App-family tables M1.3/M1.4 already fully converted to
  // soft-delete** — `user_apps`, `app_revisions`, `user_app_libraries`,
  // `user_app_library_dependencies`. At the time, `notes`/`tags`/
  // `filters`/`conversations`/etc. were deliberately excluded:
  // test/hard_delete_audit_test.dart's own checked-in baseline (M1.2)
  // showed ~28 more functions across those tables still issuing real,
  // unconverted hard deletes (`deleteNote`, `deleteTag`, `deleteFilter`,
  // `deleteConversation`, and more) — installing the guard there then
  // would have aborted those currently-working call sites immediately.
  //
  // **M1.13 extension**: M1.7-M1.12 have since converted every remaining
  // entity table's own delete functions to tombstone writes (`filters`/
  // `tag_workflow_bindings` in M1.7, `relationships`/
  // `conversation_attachments` in M1.8, `tags` in M1.9, `notes` in M1.10,
  // `subnotes`/`attachments` in M1.11 for the `updateNote`/`_persistNote`
  // edit path plus `deleteNote` itself in M1.13 step 0 -- see that
  // function's own doc comment in this file -- and `conversations`/
  // `conversation_messages` in M1.12), and M1.13's own audit (test/
  // hard_delete_audit_test.dart's live scanner, re-run before this
  // extension was made) confirmed the only remaining real-delete call
  // sites against any of these ten tables were `clearAllData`'s own
  // (deliberately bypassed, not tombstoned -- see that function's own doc
  // comment for why) and the five OR-Set membership tables' own real
  // deletes (`note_tags`, `conversation_tags`, `message_parents`,
  // `conversation_message_mapping`, `conversation_note_mapping`), which
  // are correct by design and never guarded here. `_hardDeleteGuardedTables`
  // therefore now also covers `notes`, `subnotes`, `attachments`, `tags`,
  // `filters`, `relationships`, `tag_workflow_bindings`, `conversations`,
  // `conversation_messages`, `conversation_attachments`. Deliberately NOT
  // added: `tag_images`/`tag_ai_configs` (per M1.9's "derive, don't
  // tombstone" design -- their visibility derives entirely from their
  // owning tag's liveness, they never get their own `__deleted__`
  // column/tombstone, and `removeTagImage`/`updateTagExtractionPrompt` are
  // deliberately still real deletes, an accepted, disclosed residual out
  // of scope for this effort, not an oversight) and none of the five
  // OR-Set membership tables (real deletion is the correct CRDT semantics
  // for a Set membership row, not a bug to guard against).
  //
  // One known, pre-existing, disclosed exception within the guarded scope
  // itself: `deleteAppRevisions` (plural — database_service.dart, distinct
  // from the singular `deleteAppRevision` M1.4 converted) still issues a
  // real, unconverted hard delete against `app_revisions` (see its own doc
  // comment below). It was deliberately left out of M1.4's scope because
  // it has zero call sites anywhere in `lib/`
  // (verified dead code — see its own doc comment) — test/
  // hard_delete_audit_test.dart's baseline keeps it on record for exactly
  // this reason. Installing the guard on `app_revisions` does not break any
  // currently-working feature (nothing calls this function), and matches
  // this design's own stated philosophy of the guard as "the backstop
  // against any future code path regressing this" — if `deleteAppRevisions`
  // is ever revived without also being converted, it now fails loudly
  // instead of silently issuing an unscoped physical delete.
  //
  // A shared helper (`_hardDeleteGuardTrigger`) generating one consistent
  // trigger per table (rather than one independently hand-copied `CREATE
  // TRIGGER` statement per table) mirrors this file's own M1.1 precedent
  // (`_syncControlPlaneTableStatements` above) for the same anti-drift
  // reason: the exact trigger SQL for a given table must never be able to
  // diverge between the fresh-install path (_onCreate) and any additive
  // migration (_migrateToVersion51, _migrateToVersion57). This sharing is
  // deliberately scoped to the SQL-generation helper only, not to which
  // *tables* each call site targets -- see `_hardDeleteGuardTriggerStatements`'s
  // own doc comment below for why `_migrateToVersion51`/`_migrateToVersion57`
  // each use their own frozen, historical table list instead of the
  // shared, current one.
  static String _hardDeleteGuardTrigger(String table) {
    return '''
      CREATE TRIGGER IF NOT EXISTS guard_no_hard_delete_$table
      BEFORE DELETE ON $table
      BEGIN
        SELECT RAISE(ABORT, 'Hard DELETE is not allowed on "$table": this table is soft-delete only (M1.5 hard-delete guard). Set __deleted__=1 via the normal soft-delete write path instead of issuing a real DELETE.');
      END;
    ''';
  }

  static const List<String> _hardDeleteGuardedTables = [
    // M1.5: the original four User-App-family tables.
    'user_apps',
    'app_revisions',
    'user_app_libraries',
    'user_app_library_dependencies',
    // M1.13: every other entity table M1.7-M1.13 fully converted to
    // soft-delete (see the doc comment above for the full derivation).
    'notes',
    'subnotes',
    'attachments',
    'tags',
    'filters',
    'relationships',
    'tag_workflow_bindings',
    'conversations',
    'conversation_messages',
    'conversation_attachments',
  ];

  /// Single source of truth for "every table the hard-delete guard
  /// protects today", used by the fresh-install path (_onCreate, which
  /// legitimately always wants the current, complete list) and by
  /// `clearAllData`'s trigger-reinstall step (same reasoning: reinstall
  /// whatever is current). Deliberately NOT used by `_migrateToVersion51`
  /// or `_migrateToVersion57` — each of those is a frozen, historical
  /// migration step that must install exactly the tables it originally
  /// documented installing, not whatever this list has since grown to; see
  /// `_migrateToVersion51`'s own doc comment for the full reasoning and
  /// the bug this would otherwise cause for a real multi-step upgrade.
  static final List<String> _hardDeleteGuardTriggerStatements = [
    for (final table in _hardDeleteGuardedTables)
      _hardDeleteGuardTrigger(table),
  ];
  // ===========================================================================

  // ===========================================================================
  // M2.4: sync mutation-capture triggers (design doc § Architecture 11.3,
  // "Mutation capture: from ordinary writes to a durable outbox"). Real,
  // persistent (non-`TEMP`) `AFTER INSERT`/`AFTER UPDATE`/`AFTER DELETE`
  // triggers writing into `sync_touch_log` (already schema'd by M1.1,
  // unused until now — its own doc comment above `_createSyncTouchLogTable`
  // previously called the capture step "assumed... not implemented
  // behavior").
  //
  // Deliberately NOT the `_captureTriggerStatements`/`_installCaptureObjects`
  // mechanism above: that one is `CREATE TEMP TRIGGER`-based, connection-
  // local (gone on restart, only active on the one connection that ran
  // `_installCaptureObjects`), and built for an unrelated feature (the
  // AI-plugin raw-SQL approval path, `sql_query_service.dart`) that ordinary
  // `DatabaseService` mutation methods never go through (§ 11 intro). A real
  // trigger fires regardless of which of this file's ~30+ scattered call
  // sites performed the write — the same trigger-over-call-site-census
  // reasoning `_hardDeleteGuardedTables`'s own doc comment already
  // establishes for this codebase: the M1.2 hard-delete audit found real
  // call sites at three times its own prior estimate by actually scanning,
  // not by citation-chasing. Explicit mint-at-every-call-site would
  // reproduce exactly that missed-call-site risk here, just for "log a
  // touch" instead of "convert a delete".
  //
  // Deliberately trivial per statement, matching § 11.3's own text ("a
  // single `INSERT INTO sync_touch_log`, nothing else... on the hot write
  // path"): a trigger never records *what* changed, only *that* something
  // did. The actual old-vs-new comparison against `sync_field_state`/
  // `sync_set_state` happens at drain time
  // (`lib/services/sync/outbox_drainer.dart`), not capture time.
  //
  // Covers exactly requirement 1's sync scope, per § 11.3's own text: the
  // fourteen `_hardDeleteGuardedTables` entity tables (`AFTER INSERT` -> one
  // whole-row `__exists__` touch, `fieldName = NULL`; `AFTER UPDATE`, one
  // trigger per sync-scope column, guarded by `WHEN NEW.<col> IS NOT
  // OLD.<col>`; `__deleted__` gets no special-case trigger -- it is an
  // ordinary column, so its own `WHEN NEW.__deleted__ IS NOT OLD.__deleted__`
  // trigger produces an ordinary field-scoped touch, exactly like any other
  // field) plus the five OR-Set membership tables (`AFTER INSERT`/`AFTER
  // DELETE` -> one touch row with `memberUuid` populated).
  //
  // **One deliberate, disclosed deviation from § 11.3's literal text for
  // OR-Set touches.** § 11.3 says an OR-Set touch row should carry
  // `fieldName = NULL`. This implementation populates `fieldName` with the
  // synthetic set-field name instead (`'tags'`, `'noteIds'`, `'messageIds'`,
  // `'parentMessageIds'` -- see `_setCaptureSpecs` below), because
  // `sync_set_state.fieldName` is `NOT NULL` by its own schema (see
  // `_createSyncSetStateTable`) precisely so it can disambiguate multiple
  // independent OR-Set fields owned by the *same* `entityTable`: this
  // codebase's actual `conversations` table owns three separate OR-Sets
  // (`tags` via `conversation_tags`, `noteIds` via
  // `conversation_note_mapping`, `messageIds` via
  // `conversation_message_mapping`), all sharing `entityTable =
  // 'conversations'`. `sync_touch_log` has no column recording which
  // membership table fired a given trigger, so a `fieldName = NULL` touch
  // row for `entityTable = 'conversations'` would leave drain unable to
  // tell which of the three sets it needs to re-check. `memberUuid` alone
  // cannot disambiguate this either (a `tagId` and a `noteId` are both
  // opaque UUIDs from unrelated id spaces -- nothing about the value itself
  // says which set it belongs to). Populating `fieldName` at capture time is
  // the only way to make this generically correct rather than correct only
  // for tables (like `notes`) that happen to own exactly one OR-Set.
  //
  // A shared per-table statement list (`_syncMutationCaptureTriggerStatements`),
  // consumed by both the fresh-install path (`_onCreate`) and the additive
  // migration (`_migrateToVersion58`), so the two paths can never drift
  // apart -- the exact same M1.1/M1.5/M1.13 anti-drift pattern
  // `_syncControlPlaneTableStatements`/`_hardDeleteGuardTriggerStatements`
  // already establish in this file. Every statement uses `CREATE TRIGGER IF
  // NOT EXISTS`, so running the full list against either a brand-new
  // database or an already-migrated one is always safe.

  /// One `INSERT INTO sync_touch_log(...)` statement fragment, shared by
  /// every trigger body below. `touchedAt` uses second-resolution SQL
  /// `strftime`, not millisecond precision — acceptable because, per
  /// `sync_touch_log`'s own doc comment and § 11.3's "drain-ordering
  /// invariant", the *authoritative* ordering for drain is the `id`
  /// `AUTOINCREMENT` column, not `touchedAt` (which is purely a diagnostic
  /// "local capture timestamp"). `entityIdExpr`/`memberUuidExpr` are always
  /// wrapped in `CAST(... AS TEXT)`: `sync_touch_log.entityId`/`memberUuid`
  /// are `TEXT` columns, but two of the fourteen entity tables
  /// (`user_app_libraries`, `user_app_library_dependencies`) have an
  /// `INTEGER AUTOINCREMENT` primary key — SQLite's type-affinity coercion
  /// would handle this implicitly even without the cast, but an explicit
  /// cast documents the intent instead of relying on an implicit engine
  /// behavior a future reader would have to already know about.
  static String _syncTouchInsert({
    required String entityTable,
    required String entityIdExpr,
    String? fieldName,
    String? memberUuidExpr,
  }) {
    final fieldLiteral = fieldName == null ? 'NULL' : "'$fieldName'";
    final memberExpr = memberUuidExpr == null
        ? 'NULL'
        : 'CAST($memberUuidExpr AS TEXT)';
    return "INSERT INTO sync_touch_log(entityTable, entityId, fieldName, memberUuid, touchedAt) "
        "VALUES ('$entityTable', CAST($entityIdExpr AS TEXT), $fieldLiteral, $memberExpr, "
        "CAST(strftime('%s','now') AS INTEGER) * 1000);";
  }

  /// One entity table's mutation-capture trigger spec: which column holds
  /// its primary key (`id` for every table except `tag_workflow_bindings`,
  /// whose actual primary key is `pattern` -- see
  /// `_createTagWorkflowBindingsTable`), and the exact list of columns that
  /// get their own `AFTER UPDATE` touch trigger.
  ///
  /// **`syncScopeColumns` selection principle, applied uniformly below and
  /// documented per-table only where a column needs an *exception* to it:**
  /// a column is included unless it is (a) the table's own primary key
  /// (never changes by definition), (b) a foreign key establishing
  /// parent/owner linkage that this codebase never reassigns in place
  /// (verified per table below: every "move to a different parent" case in
  /// this file is modeled as delete-and-recreate under the new parent, not
  /// FK reassignment), or (c) a creation-only timestamp
  /// (`createdAt`/`revisionTimestamp`/`conversation_messages.timestamp`)
  /// that, even where an UPDATE statement's column list happens to
  /// literally re-mention it (several `updateX` methods round-trip the
  /// model's own unchanged `createdAt` value straight back into the SET
  /// list), never actually changes value in practice. Creation snapshots
  /// carry the original timestamp and owner linkage; these exclusions apply
  /// only to mutable-field UPDATE capture, not to initial synchronization.
  /// This mirrors this
  /// file's own trigger-over-call-site-census philosophy (see the section
  /// doc comment above): a column that in fact never changes just means its
  /// `WHEN` clause never fires (harmless); a column excluded here that
  /// later gains a genuine write path is the exact "silently breaks capture
  /// forever" failure this whole design exists to prevent. Uncertainty is
  /// therefore always resolved toward inclusion, verified against this
  /// file's actual `updateX`/`db.update` call sites at M2.4 authoring time,
  /// not merely guessed at.
  static List<String> _entityCaptureTriggerStatementsFor(
    SyncEntityCaptureScope scope,
  ) {
    final table = scope.table;
    final idColumn = scope.idColumn;
    final statements = <String>[
      '''
      CREATE TRIGGER IF NOT EXISTS sync_touch_${table}_ai
      AFTER INSERT ON $table
      BEGIN
        ${_syncTouchInsert(entityTable: table, entityIdExpr: 'NEW.$idColumn')}
      END;
      ''',
    ];
    for (final column in scope.syncScopeColumns) {
      statements.add('''
      CREATE TRIGGER IF NOT EXISTS sync_touch_${table}_au_$column
      AFTER UPDATE ON $table
      WHEN NEW.$column IS NOT OLD.$column
      BEGIN
        ${_syncTouchInsert(entityTable: table, entityIdExpr: 'NEW.$idColumn', fieldName: column)}
      END;
      ''');
    }
    return statements;
  }

  /// The fourteen `_hardDeleteGuardedTables` entity tables, each with its
  /// primary-key column and its own derived `syncScopeColumns` list — see
  /// [SyncEntityCaptureScope]'s doc comment for why this is public, and the
  /// general column-selection principle documented above
  /// `_entityCaptureTriggerStatementsFor`; per-table notes below cover the
  /// exceptions.
  static const List<SyncEntityCaptureScope> syncEntityCaptureScopes = [
    // notes: `id`/`createdAt` excluded per the general principle. Every
    // other column has a live write path via `updateNote` (title, content,
    // type, updatedAt, scheduledAt, completeBy, status,
    // completionPercentage, pinned, isArchived, recurrenceRule) or
    // `updateNoteMetadata` (metadata). `__deleted__` per the general rule.
    SyncEntityCaptureScope(
      table: 'notes',
      idColumn: 'id',
      syncScopeColumns: [
        'title',
        'content',
        'type',
        'updatedAt',
        'scheduledAt',
        'completeBy',
        'status',
        'completionPercentage',
        'pinned',
        'isArchived',
        'recurrenceRule',
        'metadata',
        '__deleted__',
      ],
    ),
    // subnotes: `id`/`noteId` (owner FK, never reassigned -- a subnote
    // "move" is delete-and-recreate)/`createdAt` excluded. `name`/
    // `content`/`isCompleted` all have a live write path via
    // `diffAndPersistSubNotes`'s in-place UPDATE for an existing live row
    // (see that function's own doc comment).
    SyncEntityCaptureScope(
      table: 'subnotes',
      idColumn: 'id',
      syncScopeColumns: ['name', 'content', 'isCompleted', '__deleted__'],
    ),
    // tags: `id`/`createdAt`/`usageCount` excluded. `usageCount` is written
    // only once, at creation (`'usageCount': 0`), and is never referenced by
    // any `db.update`/`UPDATE tags` call site anywhere in this file (its own
    // doc comment already flags this ambiguity) — it is a dead column in
    // practice, and even if it were live, a per-replica local activity
    // counter is the wrong shape for a plain LWW field register (one
    // device's count would silently clobber another's independent local
    // activity; a real synced counter needs its own counter-CRDT, out of
    // this milestone's scope). `redirectTarget` is included: M2.4's own
    // required `replaceTag` fix (see below) gives it its first real write
    // path.
    //
    // M2.7 addition — `name`/`color` are now included too, a required,
    // disclosed, adjacent fix (design doc § Architecture 11.6(e)'s own
    // precedent for this kind of adjacent change, same shape as M2.4's
    // `replaceTag` fix): `name`/`color` genuinely have no in-place UPDATE
    // call site (a rename is still tombstone-old + create-new-row, never an
    // in-place `name` UPDATE — that reasoning is unchanged), but excluding
    // them from `syncScopeColumns` ALSO meant their INITIAL value at
    // creation was never captured by `OutboxDrainer._processExistsTouch`'s
    // own "every sync-scope column is re-checked" step either — a brand-new
    // tag's name never reached another device at all. This is directly
    // load-bearing for § 11.6(e)'s auto-merge/collision-detection feature,
    // which cannot detect a same-name collision against a remote tag whose
    // name it was never told. **Order matters and is deliberate**: `name`/
    // `color` are listed BEFORE `__deleted__`/`redirectTarget` because
    // `_processExistsTouch`'s column loop mints one field operation per
    // entry IN LIST ORDER, and `materializer.dart`'s tags-liveness-
    // collision check (§ 11.6(e)) needs a tag's real `name` to already be
    // materialized by the time its `__deleted__`/`redirectTarget` fields
    // resolve — see `materializer.dart`'s own top doc comment for the full
    // ordering argument.
    SyncEntityCaptureScope(
      table: 'tags',
      idColumn: 'id',
      syncScopeColumns: ['name', 'color', '__deleted__', 'redirectTarget'],
    ),
    // filters: `id`/`createdAt` excluded. Every other column has a live
    // write path via `updateFilter`.
    //
    // `isSpace` is in scope for the same reason `isPinned` is: both are role
    // flags the user sets on a filter through `updateFilter`, so a filter
    // marked as a Space on one device must be a Space on the others. Which
    // Space is *active* is a per-device choice and is not stored here at all
    // (SpaceScopeService keeps it in SharedPreferences), so syncing the role
    // does not drag one device's scope onto another.
    SyncEntityCaptureScope(
      table: 'filters',
      idColumn: 'id',
      syncScopeColumns: [
        'name',
        'includeText',
        'includeTags',
        'excludeTags',
        'noteTypes',
        'includeArchived',
        'isPinned',
        'isSpace',
        'updatedAt',
        '__deleted__',
      ],
    ),
    // relationships: `id`/`fromNoteId`/`toNoteId` (both endpoint FKs, never
    // reassigned)/`createdAt` excluded — no `updateRelationship` function
    // exists anywhere in this file; the only writes against an existing
    // `relationships` row are `deleteRelationship`/
    // `deleteRelationshipBetween`/`deleteRelationshipsForNote`, all of which
    // only ever write `__deleted__`.
    //
    // M2.8 audit finding (§ Architecture 11.8's new sync-scope-exclusion-
    // reasoning audit, added per the M2.7 addendum) — `type` was excluded
    // here on exactly the same incomplete reasoning class M2.7 found for
    // `tags.name`/`color`: "no update call site" is true but was never
    // separately cross-checked against `insertRelationship`'s own creation
    // path. It is not: `insertRelationship(relationship)` inserts
    // `relationship.toJson()` directly, and `Relationship.type` is a real,
    // user-chosen, per-row-varying field (`RelationshipType`'s "answers"/
    // "causality"/"related"/... predefined set, or a free-form string) —
    // exactly the shape a newly-created relationship's type would silently
    // never reach another device with. Fixed the same way M2.7 fixed
    // `tags.name`/`color`: added to `syncScopeColumns`, so both an
    // `AFTER UPDATE` trigger (defense-in-depth; no real call site fires it
    // today) and `OutboxDrainer._processExistsTouch`'s creation-time diff
    // loop cover it. Creation snapshots carry both endpoint IDs and the
    // materializer queues the relationship until its parent notes exist.
    SyncEntityCaptureScope(
      table: 'relationships',
      idColumn: 'id',
      syncScopeColumns: ['type', '__deleted__'],
    ),
    // tag_workflow_bindings: `pattern` (its actual primary key) excluded.
    // Every other column is written by `insertWorkflowBinding`, which
    // always uses `ConflictAlgorithm.replace` -- an existing row under the
    // same `pattern` is re-registered via SQLite's REPLACE conflict
    // resolution, whose implicit pre-insert DELETE does not fire DELETE
    // triggers (SQLite only fires REPLACE's implicit delete triggers when
    // `recursive_triggers` is enabled, which this codebase never turns on),
    // but whose INSERT half always fires this table's own `AFTER INSERT`
    // trigger normally, every time -- including for what is semantically an
    // "update". That whole-row `__exists__` touch is enough for drain to
    // re-check every sync-scope column's current value against
    // `sync_field_state` (see `OutboxDrainer`'s doc comment), so no
    // `AFTER UPDATE` trigger below will ever fire via this table's actual
    // application code path today -- they are still installed (a) for
    // defense-in-depth against a hypothetical future direct-UPDATE call
    // site, and (b) because the trigger-completeness test verifies them via
    // direct SQL `UPDATE`, independent of what today's application code
    // happens to call.
    SyncEntityCaptureScope(
      table: 'tag_workflow_bindings',
      idColumn: 'pattern',
      syncScopeColumns: [
        'isPrefix',
        'skillNoteId',
        'prompt',
        'contentImmutable',
        '__deleted__',
      ],
    ),
    // conversations: `id`/`createdAt` excluded. `noteIds` is also excluded
    // — confirmed dead: `updateConversation` unconditionally pins it to the
    // constant `'[]'` on every call (`json['noteIds'] = '[]'; // Always
    // empty, managed by mapping table`), so its value never actually
    // changes; real membership lives in `conversation_note_mapping`, which
    // already has its own OR-Set capture triggers below. `title`/
    // `updatedAt`/`isArchived` all have a live write path via
    // `updateConversation`.
    SyncEntityCaptureScope(
      table: 'conversations',
      idColumn: 'id',
      syncScopeColumns: ['title', 'updatedAt', 'isArchived', '__deleted__'],
    ),
    // conversation_messages: `id`/`timestamp` excluded — `timestamp`
    // represents this message's creation instant (this table has no
    // separate `createdAt` column); `updateConversationMessage` does
    // literally include it in its SET list, but only ever round-trips the
    // same unchanged `message.timestamp` value read from the row being
    // edited, mirroring `notes.createdAt`'s own exclusion above. `type`/
    // `content`/`modelUsed`/`metadata` all have a live write path via
    // `updateConversationMessage`.
    SyncEntityCaptureScope(
      table: 'conversation_messages',
      idColumn: 'id',
      syncScopeColumns: [
        'type',
        'content',
        'modelUsed',
        'metadata',
        '__deleted__',
      ],
    ),
    // conversation_attachments: `id`/`messageId` (owner FK, never
    // reassigned)/`createdAt` excluded — no update function exists anywhere
    // in this file for an existing `conversation_attachments` row; the only
    // write path is `deleteConversationAttachment`'s `__deleted__`
    // tombstone.
    //
    // M2.8 audit finding — `filePath`/`fileName`/`fileType`/`isRelativePath`
    // were excluded on the same incomplete "no update call site" reasoning
    // the M2.7 addendum found for `tags.name`/`color`, never separately
    // cross-checked against `insertConversationAttachment`'s creation path.
    // It is not: `insertConversationAttachment` inserts
    // `attachment.toDatabase()` directly, and all four are real,
    // per-attachment-varying metadata (the file's actual path/name/MIME
    // type, and whether that path is app-relative) — small path/type
    // strings and a bool flag, not the attachment's file bytes themselves
    // (those live on disk, referenced by `filePath`, not stored inline in
    // this table at all — no large-blob concern applies here the way it
    // does for `user_app_library_dependencies.bytes` below). Fixed the same
    // way as `relationships.type` above: added to `syncScopeColumns`.
    // Creation snapshots carry message ownership; the materializer waits
    // for that message and the blob phase transfers the attachment bytes.
    SyncEntityCaptureScope(
      table: 'conversation_attachments',
      idColumn: 'id',
      syncScopeColumns: [
        'filePath',
        'fileName',
        'fileType',
        'isRelativePath',
        '__deleted__',
      ],
    ),
    // attachments: `id`/`noteId` (owner FK, never reassigned)/`createdAt`
    // excluded. `includeInAIContext`/`metadata` have a live write path via
    // `updateAttachmentAIContext`/`updateAttachmentMetadata`.
    //
    // M2.8 audit finding — `filePath`/`fileName`/`fileType`/`isRelativePath`
    // were excluded on `diffAndPersistAttachments`'s own doc comment
    // ("a resurrected row's path/type fields are left exactly as the row
    // already has it; only the tombstone flag flips") — a real, correct
    // statement about the UPDATE/resurrection path, but it was never
    // separately cross-checked against this table's actual creation path
    // the way the M2.7 addendum requires. It does not hold there: a
    // brand-new attachment's path/name/type are real, per-row-varying data
    // supplied at insert time (same shape, and the same fix, as
    // `conversation_attachments` immediately above — small metadata
    // strings/a bool flag, not the file bytes themselves). Fixed by adding
    // to `syncScopeColumns`. The creation snapshot carries note ownership;
    // materialization waits for the note and blob sync transfers the file.
    SyncEntityCaptureScope(
      table: 'attachments',
      idColumn: 'id',
      syncScopeColumns: [
        'filePath',
        'fileName',
        'fileType',
        'isRelativePath',
        'includeInAIContext',
        'metadata',
        '__deleted__',
      ],
    ),
    // user_apps: `id`/`uuid`/`createdAt` excluded. Every other column has a
    // live write path via `updateUserApp` (name, description, steps,
    // htmlContent, type, selectedRevisionId, author, license, i18n, updatedAt) or
    // `updateUserAppState` (appState).
    SyncEntityCaptureScope(
      table: 'user_apps',
      idColumn: 'id',
      syncScopeColumns: [
        'name',
        'description',
        'steps',
        'htmlContent',
        'appState',
        'type',
        'selectedRevisionId',
        'author',
        'license',
        'i18n',
        'updatedAt',
        '__deleted__',
      ],
    ),
    // Revisions are immutable history. Their creation snapshot carries
    // appId and the original revisionTimestamp. The materializer waits for
    // the parent app; appCode travels through content-addressed blob sync.
    // deletedAt is derived from the deletion operation for fallback ordering.
    SyncEntityCaptureScope(
      table: 'app_revisions',
      idColumn: 'id',
      // `appCode` joined sync scope in M3.1's second half: its CONTENT is
      // a blob (`syncContentBlobColumns`), so the operation carries a
      // `blobHash` and a null value rather than a megabyte of HTML inline,
      // and `app_revisions` stops being the last table blocked by an
      // unresolvable column. Being in scope is what makes the column
      // captured, minted and materialized at all; the blob layer is what
      // keeps it off the commit log.
      syncScopeColumns: [
        'revisionNumber',
        'userPrompt',
        'aiResponse',
        'attachmentPaths',
        'appCode',
        '__deleted__',
      ],
    ),
    // Library rows use device-local integer IDs. Capture remains installed,
    // but portable-identity guards exclude these rows from seed/drain/apply
    // until a stable identity/remapping protocol exists.
    SyncEntityCaptureScope(
      table: 'user_app_libraries',
      idColumn: 'id',
      syncScopeColumns: ['name', 'usage_instructions', '__deleted__'],
    ),
    // Dependencies share the library family's non-portable integer-ID
    // restriction. Their bytes stay local alongside the owning library.
    SyncEntityCaptureScope(
      table: 'user_app_library_dependencies',
      idColumn: 'id',
      syncScopeColumns: ['original_url', 'local_path', '__deleted__'],
    ),
  ];

  static final List<List<String>> _syncEntityCaptureStatementGroups = [
    for (final scope in syncEntityCaptureScopes)
      _entityCaptureTriggerStatementsFor(scope),
  ];

  /// One OR-Set membership table's mutation-capture trigger pair.
  /// `entityTable`/`fieldName` name the *logical* OR-Set field this
  /// membership table represents (see the section doc comment above for why
  /// `fieldName` is populated rather than left `NULL`); `entityIdColumn`/
  /// `memberIdColumn` are this membership table's own two columns.
  static List<String> _setCaptureTriggerStatementsFor(
    SyncSetCaptureScope scope,
  ) {
    final membershipTable = scope.membershipTable;
    final entityTable = scope.entityTable;
    final entityIdColumn = scope.entityIdColumn;
    final fieldName = scope.fieldName;
    final memberIdColumn = scope.memberIdColumn;
    return [
      '''
      CREATE TRIGGER IF NOT EXISTS sync_touch_${membershipTable}_ai
      AFTER INSERT ON $membershipTable
      BEGIN
        ${_syncTouchInsert(entityTable: entityTable, entityIdExpr: 'NEW.$entityIdColumn', fieldName: fieldName, memberUuidExpr: 'NEW.$memberIdColumn')}
      END;
      ''',
      '''
      CREATE TRIGGER IF NOT EXISTS sync_touch_${membershipTable}_ad
      AFTER DELETE ON $membershipTable
      BEGIN
        ${_syncTouchInsert(entityTable: entityTable, entityIdExpr: 'OLD.$entityIdColumn', fieldName: fieldName, memberUuidExpr: 'OLD.$memberIdColumn')}
      END;
      ''',
    ];
  }

  /// The five OR-Set membership tables (design doc § 11.3: "not
  /// hard-delete-guarded but... sync-scope"), each mapped to the logical
  /// entity/field it represents:
  ///  - `note_tags` -> `notes.tags`
  ///  - `conversation_tags` -> `conversations.tags`
  ///  - `conversation_note_mapping` -> `conversations.noteIds` (the real,
  ///    OR-Set-backed replacement for the dead `conversations.noteIds`
  ///    column excluded above)
  ///  - `conversation_message_mapping` -> `conversations.messageIds`
  ///  - `message_parents` -> `conversation_messages.parentMessageIds` (a
  ///    message is the OWNING side of its own parent-edge set — `messageId`
  ///    is this table's owner column, `parentMessageId` the member; this
  ///    codebase's own tree-structured conversation model allows a message
  ///    to have multiple parents)
  static const List<SyncSetCaptureScope> syncSetCaptureScopes = [
    SyncSetCaptureScope(
      membershipTable: 'note_tags',
      entityTable: 'notes',
      entityIdColumn: 'noteId',
      fieldName: 'tags',
      memberIdColumn: 'tagId',
    ),
    SyncSetCaptureScope(
      membershipTable: 'conversation_tags',
      entityTable: 'conversations',
      entityIdColumn: 'conversationId',
      fieldName: 'tags',
      memberIdColumn: 'tagId',
    ),
    SyncSetCaptureScope(
      membershipTable: 'conversation_note_mapping',
      entityTable: 'conversations',
      entityIdColumn: 'conversationId',
      fieldName: 'noteIds',
      memberIdColumn: 'noteId',
      payloadColumns: ['createdAt'],
    ),
    SyncSetCaptureScope(
      membershipTable: 'conversation_message_mapping',
      entityTable: 'conversations',
      entityIdColumn: 'conversationId',
      fieldName: 'messageIds',
      memberIdColumn: 'messageId',
      payloadColumns: ['createdAt'],
    ),
    SyncSetCaptureScope(
      membershipTable: 'message_parents',
      entityTable: 'conversation_messages',
      entityIdColumn: 'messageId',
      fieldName: 'parentMessageIds',
      memberIdColumn: 'parentMessageId',
      payloadColumns: ['createdAt'],
    ),
  ];

  static final List<List<String>> _syncSetCaptureStatementGroups = [
    for (final scope in syncSetCaptureScopes)
      _setCaptureTriggerStatementsFor(scope),
  ];

  /// Single source of truth for every M2.4 sync mutation-capture trigger —
  /// shared verbatim by `_onCreate` and `_migrateToVersion58`, the same
  /// anti-drift pattern as `_syncControlPlaneTableStatements`/
  /// `_hardDeleteGuardTriggerStatements` above.
  static final List<String> _syncMutationCaptureTriggerStatements = [
    for (final group in _syncEntityCaptureStatementGroups) ...group,
    for (final group in _syncSetCaptureStatementGroups) ...group,
  ];

  /// Which of the fifteen M1.1 sync control-plane tables are ENTITY-SCOPED —
  /// keyed by a specific entity/subject id, or by a dot-identity that only
  /// ever arises from an operation about one — and which are instead
  /// device/dataset-level or peer-relationship state.
  ///
  /// **Two consumers, and the partition means the same thing to both.**
  ///  1. `clearAllData` (M1.13/M2.4), this list's original reason to exist:
  ///     everything here describes content that call physically erases, so
  ///     leaving it behind would break that function's "genuinely empty
  ///     local database" promise.
  ///  2. `DatasetReset` (M2.13, `lib/services/sync/dataset_reset.dart`):
  ///     a sync reset must return this device to the protocol state of a
  ///     fresh install that happens to already hold this content — which is
  ///     exactly "drop every derived record ABOUT the content, keep the
  ///     content." That is the same partition, read from the other side, so
  ///     it reuses this list rather than maintaining a second one that
  ///     could drift. (A reset additionally clears device/dataset-level
  ///     `sync_state`, which `clearAllData` deliberately does not — see
  ///     `dataset_reset.dart` for why the two differ there, and why
  ///     `sync_field_state`/`sync_set_state`/`sync_materialize_queue` being
  ///     in THIS list is what makes a post-reset seed scan actually re-run.)
  ///
  /// `clearAllData` is documented as producing a "genuinely empty
  /// local database" (a full local reset/debug tool) — that promise is
  /// broken if a sync control-plane table is left holding rows that
  /// reference an entity, subject, or dot the same call just erased, even
  /// though nothing writes most of these tables yet (M2.5+ populates the
  /// rest): the gap would otherwise silently reopen the moment each one
  /// gains a real writer.
  ///
  /// **Wiped — every table keyed by a specific entity/subject id, or by a
  /// dot-identity that only ever arises from an operation ABOUT a specific
  /// entity:**
  ///  - `sync_field_state`/`sync_set_state` (`entityTable`+`entityId`) —
  ///    `OutboxDrainer`'s own current-winner bookkeeping; the explicit
  ///    trigger for this whole fix (a drain-then-`clearAllData` sequence
  ///    would otherwise leave these referencing rows that no longer exist).
  ///  - `sync_pending_ops` (`entityTable`+`entityId`) — this device's own
  ///    not-yet-published outbox; keeping an operation describing an edit
  ///    to now-physically-gone content would be actively wrong, not just
  ///    stale (a future push could publish a meaningless edit to nothing).
  ///  - `sync_grave`/`sync_conflict_copies` (`subjectTable`+`subjectId`) —
  ///    no writer exists yet (purge/GC and § 11.6 field-conflict
  ///    resolution are both later milestones), but both are entity-id-keyed
  ///    by schema, so a row here can only ever describe a specific local
  ///    entity that this function may have just erased.
  ///  - `sync_dedup_index`/`sync_dot_redirects` — no writer yet (M2.5's
  ///    causal engine), but both exist purely as bookkeeping for
  ///    operations minted about specific entities/fields; once entity
  ///    content and its `sync_pending_ops` rows are gone, any redirect/dedup
  ///    entry referencing those operations' dots is meaningless.
  ///  - `sync_view_cache` (`entityTable`+`entityId`) — no writer yet
  ///    (§ Architecture 5's external-plain-file projection cache), same
  ///    entity-id-keyed reasoning.
  ///  - `sync_materialize_queue` (`entityTable`+`entityId`) — no writer yet
  ///    (M2.7), same reasoning.
  ///  - `sync_blob_refs` (`blobHash`) — not entity-id-keyed, but is
  ///    content-addressed GC bookkeeping for attachment bytes this
  ///    function's `attachments`/`conversation_attachments` wipes make
  ///    unreachable; no writer exists yet (§ Architecture 4's blob GC), but
  ///    a stale "live" blob-hash entry for content this device no longer
  ///    has any record of would be exactly the same kind of gap.
  ///  - `sync_touch_log` (`entityTable`+`entityId`) — already wiped
  ///    separately above (predates this fix); listed here too so this one
  ///    list stays the actual single source of truth for "every sync
  ///    control-plane table `clearAllData` wipes", not two independently
  ///    maintained call sites.
  ///
  /// **Deliberately NOT wiped — device/dataset-level state, independent of
  /// which specific local entities happen to exist, or peer-relationship
  /// bookkeeping this function has no business resetting:**
  ///  - `sync_state` — this device's own identity (`device_id`), HLC clock
  ///    state, per-namespace seq counters, and dataset-bootstrap status.
  ///    Wiping this would not "clear local content", it would un-bootstrap
  ///    the device from its dataset and reset its causal clock —
  ///    `DeviceIdentity`/`SeqCounter`/`HybridLogicalClock` (M2.3) all
  ///    depend on these values being durable and monotonic *regardless* of
  ///    how much local content exists; "clear all data" and "leave the
  ///    sync dataset" are two different, unrelated operations, and this
  ///    function must never conflate them.
  ///  - `sync_ack_frontier` — what REMOTE devices have acknowledged
  ///    observing from this device. Independent of which local entities
  ///    currently exist (and, since `sync_state`'s seq counters are
  ///    preserved above, still meaningful bookkeeping afterward — a remote
  ///    peer's past acknowledgment of this device's now-wiped-locally
  ///    operations remains a true fact about what that peer has already
  ///    seen). Clearing it would risk a future push/pull loop
  ///    (M2.6/M2.7) misjudging what still needs (re-)sending.
  ///  - `sync_device_labels` — device display metadata (this device's own
  ///    label, other known devices' labels), not tied to entity content.
  ///  - `sync_publish_intent` — commit-publication idempotency markers
  ///    (`intentHash`/`parentCommitHash`/`payloadHash`), not entity-id-keyed
  ///    at all; describes this device's own push-retry safety state, not
  ///    specific local content.
  static const List<String> syncEntityScopedControlPlaneTablesToWipe = [
    'sync_touch_log',
    'sync_field_state',
    'sync_set_state',
    'sync_pending_ops',
    'sync_grave',
    'sync_conflict_copies',
    'sync_dedup_index',
    'sync_dot_redirects',
    'sync_view_cache',
    'sync_materialize_queue',
    'sync_blob_refs',
  ];
  // ===========================================================================

  // FTS4 is required because Android system sqlite ships without FTS5.
  // macOS system sqlite (3.52+) lacks FTS4, so flutter test on macOS needs a
  // sqlite3 binary that includes it — see test/flutter_test_config.dart.
  static const String _createNotesFtsTable = '''
      CREATE VIRTUAL TABLE notes_fts USING fts4(
        title,
        content
      );
  ''';

  static const String _createNotesFtsInsertTrigger = '''
      CREATE TRIGGER notes_ai_insert AFTER INSERT ON notes
      BEGIN
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
  ''';

  static const String _createNotesFtsDeleteTrigger = '''
      CREATE TRIGGER notes_ai_delete AFTER DELETE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
      END;
  ''';

  static const String _createNotesFtsUpdateTrigger = '''
      CREATE TRIGGER notes_ai_update AFTER UPDATE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
  ''';

  // Search index tables (v63). Hold data derived from notes/attachments —
  // rebuilt by the indexer and never merged during recovery. NOTE: DB backups
  // are whole-file copies, so these tables DO ship in backups today; size
  // impact is evaluated when the indexer lands. All v63 DDL uses IF NOT
  // EXISTS: migration 62 runs outside a transaction (custom-migration path),
  // so a mid-migration crash must be re-runnable, not a permanent recovery
  // loop.
  static const String _createSearchChunksTable = '''
      CREATE TABLE IF NOT EXISTS search_chunks(
        id INTEGER PRIMARY KEY, -- rowid alias: stable under VACUUM (raw SQL/VACUUM is exposed to user+AI)
        chunkKey TEXT NOT NULL, -- "{noteId}:{sourceType}:{sourceId|-}:{seq}" logical identity
        noteId TEXT NOT NULL, -- Owning note ID
        sourceType TEXT NOT NULL, -- meta|note_body|subnote|annotation|attachment_text|attachment_ocr|figure
        sourceId TEXT, -- Source row ID (subnote/annotation/attachment), NULL for note body
        page INTEGER, -- Page number for attachment-derived chunks (1-based)
        seq INTEGER NOT NULL, -- Chunk sequence within the source
        text TEXT NOT NULL, -- RAW chunk text (snippets + embedding input); can be very large
        meta TEXT, -- JSON: figure chunks {caption, rect, derivedAssetPath}; attachment_ocr chunks {blockBounds, renderScale}
        contentHash TEXT NOT NULL, -- Hash of source content for incremental diffing
        updatedAt INTEGER NOT NULL -- Last update timestamp
      )
  ''';

  static const String _createChunkEmbeddingsTable = '''
      CREATE TABLE IF NOT EXISTS chunk_embeddings(
        chunkId INTEGER NOT NULL, -- search_chunks.id
        providerKey TEXT NOT NULL, -- "{type}:{model}:{dims}"
        modality TEXT NOT NULL, -- 'text' or 'image'
        dims INTEGER NOT NULL, -- Vector dimensions
        vector BLOB NOT NULL, -- float32 little-endian, L2-normalized
        contentHash TEXT NOT NULL, -- Hash of the embedded content
        PRIMARY KEY (chunkId, providerKey)
      )
  ''';

  static const String _createSearchIndexStateTable = '''
      CREATE TABLE IF NOT EXISTS search_index_state(
        scopeType TEXT NOT NULL, -- note|attachment|chunk|global
        scopeId TEXT NOT NULL, -- Note/attachment ID, or 'all' for global scope
        stage TEXT NOT NULL, -- chunks|pdf_text|ocr|embed:<key>|figures:<key>
        contentHash TEXT, -- Content hash the stage last completed against
        status TEXT NOT NULL, -- Stage status
        errorMessage TEXT, -- Last error message, if any
        updatedAt INTEGER NOT NULL, -- Last update timestamp
        PRIMARY KEY (scopeType, scopeId, stage)
      )
  ''';

  // FTS4 (never FTS5 — Android/iOS consistency, same reason as notes_fts).
  // Holds NORMALIZED chunk text; docid = search_chunks.id. Deliberately no
  // triggers: the indexer writes content explicitly (CJK bigrams are computed
  // in Dart). Creation is wrapped in try/catch — FTS4 may be missing (web
  // wasm sqlite is FTS5-only; possible future iOS removal) and search then
  // degrades to substring matching; see [chunksFtsAvailable].
  static const String _createChunksFtsTable = '''
      CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts4(content);
  ''';

  // Search index indexes (v63) - shared by _createIndexes and migration 62
  static const String _createIdxSearchChunksKey =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_search_chunks_key ON search_chunks(chunkKey)';
  static const String _createIdxSearchChunksNoteId =
      'CREATE INDEX IF NOT EXISTS idx_search_chunks_noteId ON search_chunks(noteId)';
  static const String _createIdxSearchChunksSource =
      'CREATE INDEX IF NOT EXISTS idx_search_chunks_source ON search_chunks(sourceType, sourceId)';
  static const String _createIdxAttachmentsNoteId =
      'CREATE INDEX IF NOT EXISTS idx_attachments_noteId ON attachments(noteId)';

  // Index creation constants
  static const List<String> _createIndexes = [
    'CREATE INDEX idx_notes_type ON notes(type)',
    'CREATE INDEX idx_notes_createdAt ON notes(createdAt)',
    'CREATE INDEX idx_notes_scheduledAt ON notes(scheduledAt)',
    'CREATE INDEX idx_notes_completeBy ON notes(completeBy)',
    'CREATE INDEX idx_notes_pinned ON notes(pinned)',
    'CREATE INDEX idx_notes_isArchived ON notes(isArchived)',
    'CREATE INDEX idx_relationships_fromNoteId ON relationships(fromNoteId)',
    'CREATE INDEX idx_relationships_toNoteId ON relationships(toNoteId)',
    'CREATE INDEX idx_user_app_libraries_app_uuid ON user_app_libraries(app_uuid)',
    'CREATE INDEX idx_user_app_libraries_revision_id ON user_app_libraries(revision_id)',
    'CREATE INDEX idx_user_app_library_dependencies_library_id ON user_app_library_dependencies(library_id)',
    'CREATE INDEX idx_user_app_library_dependencies_local_path ON user_app_library_dependencies(local_path)',
    'CREATE INDEX idx_conversations_createdAt ON conversations(createdAt)',
    'CREATE INDEX idx_conversations_isArchived ON conversations(isArchived)',
    'CREATE INDEX idx_conversation_messages_timestamp ON conversation_messages(timestamp)',
    'CREATE INDEX idx_conversation_attachments_messageId ON conversation_attachments(messageId)',
    'CREATE INDEX idx_conversation_message_mapping_conversationId ON conversation_message_mapping(conversationId)',
    'CREATE INDEX idx_conversation_message_mapping_messageId ON conversation_message_mapping(messageId)',
    'CREATE INDEX idx_message_parents_messageId ON message_parents(messageId)',
    'CREATE INDEX idx_message_parents_parentMessageId ON message_parents(parentMessageId)',
    'CREATE INDEX idx_conversation_note_mapping_conversationId ON conversation_note_mapping(conversationId)',
    'CREATE INDEX idx_conversation_note_mapping_noteId ON conversation_note_mapping(noteId)',
    'CREATE INDEX idx_conversation_tags_conversationId ON conversation_tags(conversationId)',
    'CREATE INDEX idx_conversation_tags_tagId ON conversation_tags(tagId)',
    _createIdxSearchChunksKey,
    _createIdxSearchChunksNoteId,
    _createIdxSearchChunksSource,
    _createIdxAttachmentsNoteId,
    // M1.3: see _createTagsNameLiveIndex's doc comment.
    _createTagsNameLiveIndex,
  ];

  final Uuid _uuid = const Uuid();

  static String _generateTestDatabaseName() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final randomSuffix = const Uuid().v4();
    return 'note_synapse_test_${timestamp}_$randomSuffix.db';
  }

  /// Returns the complete schema of the database as a list of CREATE TABLE statements
  ///
  /// Deliberately excludes `_schema_version` and, as of M1.1, the fifteen
  /// `sync_*` control-plane tables (see _syncControlPlaneTableStatements):
  /// this list feeds AI-facing schema documentation
  /// (user_app_service.dart/note_tools.dart) and the raw-data-manager schema
  /// viewer, and sync machinery is not user content — the same reasoning
  /// that already kept `_schema_version` off this list. Both are still
  /// created for every database via _onCreate/_migrateToVersion48.
  static List<String> getSchema() {
    return [
      _createNotesTable,
      _createSubNotesTable,
      _createTagsTable,
      _createNoteTagsTable,
      _createConversationTagsTable,
      _createAttachmentsTable,
      _createRelationshipsTable,
      _createFiltersTable,
      _createUserAppsTable,
      _createAppRevisionsTable,
      _createUserAppLibrariesTable,
      _createUserAppLibraryDependenciesTable,
      _createConversationsTable,
      _createConversationMessagesTable,
      _createConversationAttachmentsTable,
      _createConversationMessageMappingTable,
      _createMessageParentsTable,
      _createConversationNoteMappingTable,
      _createMultiFunctionAppsTable,
      _createSearchChunksTable,
      _createChunkEmbeddingsTable,
      _createSearchIndexStateTable,
      // chunks_fts is deliberately omitted (virtual table, derivable —
      // mirrors the notes_fts omission).
      ..._createIndexes,
    ];
  }

  /// Returns the complete schema description as a formatted string
  static String getSchemaDescription() {
    return getSchema().join('\n\n');
  }

  // For testing, allow creating new instances
  DatabaseService.createNew({String? databaseName})
    : _databaseNameOverride = databaseName ?? _generateTestDatabaseName() {
    // Initialize database factory using platform-specific implementation
    initializeDatabaseFactory();
  }

  Database? _database;
  Future<Database>? _openingDatabase;

  /// Whether the chunks_fts FTS4 virtual table exists on this database.
  /// The FTS4 CREATE is allowed to fail (web wasm sqlite is FTS5-only;
  /// possible future iOS removal) — when false, chunk search must degrade
  /// to substring matching. Probed in _onOpen so the value survives
  /// restarts on databases whose migration ran (and failed) earlier.
  bool _chunksFtsAvailable = false;
  bool get chunksFtsAvailable => _chunksFtsAvailable;

  /// Post-write hooks for derived-data maintainers (the search indexer).
  ///
  /// The main UI write path (AppProvider) calls DatabaseService directly and
  /// never publishes DataChangeEvents, so these mutation-method hooks are the
  /// single choke point that covers AppProvider, tools, and services alike.
  /// Inversion of control keeps this file free of indexer imports: the
  /// indexer (NoteIndexService) registers itself here at construction.
  ///
  /// Invoked after the mutation completes. Exceptions are swallowed — a hook
  /// must never break a write.
  void Function(String noteId)? onNoteContentChanged;
  void Function(String noteId)? onNoteDeleted;

  void _notifyNoteContentChanged(String noteId) {
    try {
      onNoteContentChanged?.call(noteId);
    } catch (e) {
      LoggerService.warning('onNoteContentChanged hook failed: $e');
    }
  }

  void _notifyNoteDeleted(String noteId) {
    try {
      onNoteDeleted?.call(noteId);
    } catch (e) {
      LoggerService.warning('onNoteDeleted hook failed: $e');
    }
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    // Startup services can request the connection together. Share the whole
    // backup/open/migration operation so they cannot race an upgrade.
    return _openingDatabase ??= _openDatabaseOnce();
  }

  Future<Database> _openDatabaseOnce() async {
    try {
      return _database = await _initDatabase();
    } finally {
      // A failed open must remain retryable after recovery.
      _openingDatabase = null;
    }
  }

  Future<Database> _initDatabase() async {
    final dbName = _databaseNameOverride ?? 'note_synapse.db';
    final path = p.join(await getDatabasesPath(), dbName);

    // Perform pre-migration backup BEFORE openDatabase
    // This is critical because _onUpgrade runs inside a transaction
    // where PRAGMA wal_checkpoint cannot be executed
    await _performPreMigrationBackupIfNeeded(path);

    return await openDatabase(
      path,
      version: SQFLITE_VERSION, // High value to prevent sqflite's onUpgrade
      onCreate: _onCreate,
      // onUpgrade removed - migrations now handled in onOpen via _handleCustomMigrations
      onOpen: _onOpen,
      singleInstance: _databaseNameOverride == null,
    );
  }

  /// Check if migration is needed and create a backup before openDatabase
  /// This runs outside any transaction, allowing WAL checkpoint to succeed
  Future<void> _performPreMigrationBackupIfNeeded(String dbPath) async {
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      // New database, no backup needed
      return;
    }

    // Open database read-only to check version, without triggering migration
    Database? checkDb;
    try {
      checkDb = await openDatabase(
        dbPath,
        readOnly: true,
        singleInstance: false,
      );
      final schemaTable = await checkDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='_schema_version'",
      );
      final versionResult = schemaTable.isNotEmpty
          ? await checkDb.query('_schema_version')
          : await checkDb.rawQuery('PRAGMA user_version');
      final recordedVersion = versionResult.isNotEmpty
          ? versionResult.first[schemaTable.isNotEmpty
                    ? 'version'
                    : 'user_version']
                as int
          : 0;
      final currentVersion = await _migrationStartingVersion(
        checkDb,
        recordedVersion,
      );

      if (currentVersion < DATABASE_VERSION && currentVersion > 0) {
        // Migration is needed, create backup
        LoggerService.info(
          'Migration needed from version $currentVersion to $DATABASE_VERSION. Creating backup...',
        );
        await checkDb.close();
        checkDb = null;

        // Now create backup with a fresh connection that can do WAL checkpoint
        await _createPreMigrationBackup(dbPath, currentVersion);
      }
    } catch (e) {
      LoggerService.error('Error checking database version: $e', error: e);
      // A failed backup must stop the upgrade before schema/data changes.
      rethrow;
    } finally {
      if (checkDb != null && checkDb.isOpen) {
        await checkDb.close();
      }
    }
  }

  /// Create a backup of the database before migration
  /// Called outside any transaction, so WAL checkpoint should succeed
  Future<void> _createPreMigrationBackup(String dbPath, int fromVersion) async {
    Database? backupDb;
    try {
      LoggerService.info('Starting pre-migration backup...');

      // Open a fresh connection (not read-only) to do the checkpoint
      backupDb = await openDatabase(dbPath, singleInstance: false);

      // FULL reports a busy/incomplete checkpoint as a result row, not an
      // exception. Copying just the main file in that case silently omits
      // committed WAL-only data from the safety backup.
      final checkpoint = (await backupDb.rawQuery(
        'PRAGMA wal_checkpoint(FULL)',
      )).single;
      if (checkpoint['busy'] != 0 ||
          (checkpoint['log'] as int) > (checkpoint['checkpointed'] as int)) {
        throw StateError(
          'Cannot create a safe pre-migration backup: '
          'SQLite WAL checkpoint is busy or incomplete ($checkpoint)',
        );
      }
      await backupDb.close();
      backupDb = null;

      // Now copy the file
      final dbFile = File(dbPath);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final backupPath = p.join(
        p.dirname(dbPath),
        'backup_v${fromVersion}_pre_migration_$timestamp.db',
      );

      await dbFile.copy(backupPath);
      LoggerService.info('Pre-migration backup created at: $backupPath');
    } catch (e) {
      LoggerService.error(
        'Failed to create pre-migration backup: $e',
        error: e,
      );
      // Rethrow to let the caller handle it - migration should not proceed without backup
      rethrow;
    } finally {
      if (backupDb != null && backupDb.isOpen) {
        await backupDb.close();
      }
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    // Enable foreign key constraints for new databases
    await db.execute('PRAGMA foreign_keys = ON');

    // Create schema version tracking table
    await db.execute('''
      CREATE TABLE _schema_version (
        version INTEGER NOT NULL
      )
    ''');
    // Initialize with current schema version for new databases
    await db.insert('_schema_version', {'version': DATABASE_VERSION});

    // Create all tables using schema constants
    await db.execute(_createNotesTable);
    await db.execute(_createSubNotesTable);
    await db.execute(_createTagsTable);
    await db.execute(_createTagImagesTable);
    await db.execute(_createNoteTagsTable);
    await db.execute(_createAttachmentsTable);
    await db.execute(_createRelationshipsTable);
    await db.execute(_createFiltersTable);
    await db.execute(_createUserAppsTable);
    await db.execute(_createAppRevisionsTable);
    await db.execute(_createUserAppLibrariesTable);
    await db.execute(_createUserAppLibraryDependenciesTable);
    await db.execute(_createConversationsTable);
    await db.execute(_createConversationMessagesTable);
    await db.execute(_createConversationAttachmentsTable);

    await db.execute(_createConversationMessageMappingTable);
    await db.execute(_createMessageParentsTable);
    await db.execute(_createConversationNoteMappingTable);
    await db.execute(_createConversationTagsTable);
    await db.execute(_createMultiFunctionAppsTable);
    await db.execute(_createNoteAnnotationsTable);

    // Create AI-related tables (missing in previous versions' onCreate)
    await db.execute(_createTagAiConfigsTable);
    await db.execute(_createTagWorkflowBindingsTable);

    // Create the M1.1 sync control-plane tables (see the comment above
    // _syncControlPlaneTableStatements) so a brand-new install starts with
    // the same schema an existing install reaches via _migrateToVersion48.
    for (final statement in _syncControlPlaneTableStatements) {
      await db.execute(statement);
    }

    // Create the M1.5 hard-delete guard triggers (see
    // _hardDeleteGuardTriggerStatements's doc comment) so a brand-new
    // install starts with the same enforcement an existing install reaches
    // via _migrateToVersion51.
    for (final statement in _hardDeleteGuardTriggerStatements) {
      await db.execute(statement);
    }

    // Create the M2.4 sync mutation-capture triggers (see
    // _syncMutationCaptureTriggerStatements's doc comment) so a brand-new
    // install starts with the same capture coverage an existing install
    // reaches via _migrateToVersion58.
    for (final statement in _syncMutationCaptureTriggerStatements) {
      await db.execute(statement);
    }

    // Create FTS table and triggers
    await db.execute(_createNotesFtsTable);
    await db.execute(_createNotesFtsInsertTrigger);
    await db.execute(_createNotesFtsDeleteTrigger);
    await db.execute(_createNotesFtsUpdateTrigger);

    // Create search index tables (v63)
    await db.execute(_createSearchChunksTable);
    await db.execute(_createChunkEmbeddingsTable);
    await db.execute(_createSearchIndexStateTable);

    // chunks_fts may fail where FTS4 is unavailable (e.g. web wasm sqlite) —
    // never fail database creation over it; availability is recorded in
    // _onOpen (see chunksFtsAvailable).
    try {
      await db.execute(_createChunksFtsTable);
    } catch (e) {
      LoggerService.warning(
        'chunks_fts FTS4 creation failed, search will degrade to substring matching: $e',
      );
    }

    // Create all indexes
    for (final indexSql in _createIndexes) {
      await db.execute(indexSql);
    }
  }

  Future<void> _onOpen(Database db) async {
    // Enable foreign key constraints every time the database is opened
    // This is required because SQLite disables foreign keys by default
    await db.execute('PRAGMA foreign_keys = ON');

    // Custom schema version tracking - migrations only run onOpen, not onUpgrade
    await _handleCustomMigrations(db);
    await _ensureSearchSourceLookupIndexes(db);

    // Record chunks_fts availability (its FTS4 CREATE in _onCreate/migration
    // 62 is allowed to fail on platforms without FTS4).
    final chunksFtsCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='chunks_fts'",
    );
    _chunksFtsAvailable = chunksFtsCheck.isNotEmpty;
  }

  /// Handles migrations using custom _schema_version table
  /// Version is only updated AFTER successful migration
  Future<void> _handleCustomMigrations(Database db) async {
    // Check if _schema_version table exists (might be legacy DB)
    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='_schema_version'",
    );

    int currentVersion;
    if (tableCheck.isEmpty) {
      // Legacy database - create version table and get version from PRAGMA
      await db.execute('''
        CREATE TABLE _schema_version (
          version INTEGER NOT NULL
        )
      ''');
      // Get current version from sqflite's PRAGMA
      final pragmaVersion = await db.rawQuery('PRAGMA user_version');
      currentVersion = pragmaVersion.isNotEmpty
          ? pragmaVersion.first['user_version'] as int
          : 0;
      // openDatabase has already replaced PRAGMA user_version with 999.
      // Infer a safe starting point from the existing schema rather than
      // replaying every old destructive migration against a current DB.
      currentVersion = await _migrationStartingVersion(db, currentVersion);
      await db.insert('_schema_version', {'version': currentVersion});
      LoggerService.info(
        'Created _schema_version table, initialized from PRAGMA: v$currentVersion',
      );
    } else {
      // Read current version from custom table
      final versionResult = await db.query('_schema_version');
      currentVersion = versionResult.isNotEmpty
          ? versionResult.first['version'] as int
          : 0;
      if (versionResult.isEmpty) {
        currentVersion = await _detectActualSchemaVersion(db);
        await db.insert('_schema_version', {'version': currentVersion});
      }
      // Fix corrupted version: if _schema_version was set to the SQFLITE_VERSION
      // sentinel (999) due to the legacy PRAGMA fallback bug, reset it to the
      // actual DATABASE_VERSION and re-run any missing migrations.
      if (currentVersion >= SQFLITE_VERSION) {
        LoggerService.warning(
          'Detected corrupted _schema_version ($currentVersion), resetting to run missing migrations',
        );
        // Determine actual version by checking which tables/columns exist
        currentVersion = await _detectActualSchemaVersion(db);
        await db.update('_schema_version', {'version': currentVersion});
      }
    }

    currentVersion = await _migrationStartingVersion(db, currentVersion);
    if (currentVersion >= DATABASE_VERSION) {
      return; // No migration needed
    }

    LoggerService.info(
      'Migration needed: v$currentVersion -> v$DATABASE_VERSION',
    );

    // Run migrations
    for (
      int version = currentVersion + 1;
      version <= DATABASE_VERSION;
      version++
    ) {
      final migrationStep = _migrationSteps[version];
      if (migrationStep == null) {
        LoggerService.warning('No migration step defined for version $version');
        continue;
      }

      try {
        LoggerService.info(
          'Executing migration to version $version: ${migrationStep.description}',
        );
        await migrationStep.execute(db, isBackupMigration: false);
        LoggerService.info('Successfully migrated to version $version');
      } catch (e) {
        LoggerService.error(
          'Migration to version $version failed: $e',
          error: e,
        );

        // Navigate to RecoveryScreen with error
        _navigateToRecoveryScreen('Migration failed at version $version: $e');
        rethrow; // Never expose a connection with an incomplete schema.
      }
    }

    // Only update version if ALL migrations succeeded
    await db.update('_schema_version', {'version': DATABASE_VERSION});
    LoggerService.info('Schema version updated to $DATABASE_VERSION');
  }

  /// Main shipped localization as v48 while this branch used v48 for sync.
  /// Replaying that additive step handles either history and interrupted
  /// upgrades whose first sync table exists but whose later tables do not.
  static Future<int> _migrationStartingVersion(Database db, int version) async {
    if (version <= 0 || version >= SQFLITE_VERSION) {
      return _detectActualSchemaVersion(db);
    }
    if (version == 48) return 47;
    return version;
  }

  /// Recover a conservative starting point when version tracking is lost.
  /// Sync/index migrations are idempotent and may be only partly applied;
  /// replay them rather than inferring completion from a few table names.
  static Future<int> _detectActualSchemaVersion(Database db) async {
    int detected = 19; // Minimum supported version

    // Check for isSpace in filters (v47, Spaces)
    if (detected < 47) {
      final filtersCols = await db.rawQuery("PRAGMA table_info('filters')");
      if (filtersCols.any((c) => c['name'] == 'isSpace')) detected = 47;
    }

    // Check for tag_images table (v41)
    if (detected < 41) {
      final tagImagesCheck = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='tag_images'",
      );
      if (tagImagesCheck.isNotEmpty) detected = 41;
    }

    // Check for notes_fts table (v31/v36)
    if (detected < 36) {
      final ftsCheck = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='notes_fts'",
      );
      if (ftsCheck.isNotEmpty) detected = 36;
    }

    // Check for metadata column in attachments (v32)
    if (detected < 32) {
      final attachCols = await db.rawQuery("PRAGMA table_info('attachments')");
      if (attachCols.any((c) => c['name'] == 'metadata')) detected = 32;
    }

    // Check for recurrenceRule in notes (v30)
    if (detected < 30) {
      final notesCols = await db.rawQuery("PRAGMA table_info('notes')");
      if (notesCols.any((c) => c['name'] == 'recurrenceRule')) detected = 30;
    }

    // Check for excludeTags in filters (v28)
    if (detected < 28) {
      final filtersCols = await db.rawQuery("PRAGMA table_info('filters')");
      if (filtersCols.any((c) => c['name'] == 'excludeTags')) detected = 28;
    }

    LoggerService.info('Detected actual schema version: $detected');
    return detected;
  }

  /// Navigate to RecoveryScreen with error message
  void _navigateToRecoveryScreen(String error) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = navigatorKey.currentContext;
      if (context != null) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => RecoveryScreen(error: error)),
          (route) => false, // Remove all previous routes
        );
      } else {
        LoggerService.error(
          'Navigator context is null, cannot navigate to recovery screen. Error: $error',
        );
      }
    });
  }

  // Note: _onUpgrade removed - migrations now in _handleCustomMigrations

  // Migration configuration structure
  // All clients are now on version 20 or later
  static const Map<int, MigrationStep> _migrationSteps = {
    20: MigrationStep(
      description:
          'Fix conversation_messages table schema (remove conversationId if still present)',
      execute: _migrateToVersion20,
    ),
    21: MigrationStep(
      description:
          'Create conversation_note_mapping table and migrate existing noteIds data',
      execute: _migrateToVersion21,
    ),
    22: MigrationStep(
      description: 'Create conversation_tags table for shared tag support',
      execute: _migrateToVersion22,
    ),
    23: MigrationStep(
      description:
          'Add UNIQUE constraint to user_apps.uuid column for foreign key integrity',
      execute: _migrateToVersion23,
    ),
    25: MigrationStep(
      description: 'Add includeInAIContext column to attachments table',
      execute: _migrateToVersion24,
    ),
    26: MigrationStep(
      description: 'Create multi_function_apps table',
      execute: _migrateToVersion26,
    ),
    27: MigrationStep(
      description: 'Add isPinned column to filters table',
      execute: _migrateToVersion27,
    ),
    28: MigrationStep(
      description: 'Add excludeTags and noteTypes columns to filters table',
      execute: _migrateToVersion28,
    ),
    29: MigrationStep(
      description: 'Ensure multi_function_apps table exists',
      execute: _migrateToVersion29,
    ),
    30: MigrationStep(
      description: 'Add recurrenceRule column to notes table',
      execute: _migrateToVersion30,
    ),
    31: MigrationStep(
      description: 'Create notes_fts virtual table and tag_ai_configs table',
      execute: _migrateToVersion31,
    ),
    32: MigrationStep(
      description:
          'Add metadata column to attachments table for PDF bookmarks and AI context config',
      execute: _migrateToVersion32,
    ),
    36: MigrationStep(
      description:
          'Fix notes_fts FTS5 table by removing incorrect content_rowid option',
      execute: _migrateToVersion36,
    ),
    41: MigrationStep(
      description: 'Create tag_images table for image-augmented tags',
      execute: _migrateToVersion41,
    ),
    42: MigrationStep(
      description: 'Add metadata column to notes table for in-note markers',
      execute: _migrateToVersion42,
    ),
    43: MigrationStep(
      description:
          'Convert absolute paths to relative in conversation_attachments',
      execute: _migrateToVersion43,
    ),
    44: MigrationStep(
      description: 'Create note_annotations table for scratchpad annotations',
      execute: _migrateToVersion44,
    ),
    46: MigrationStep(
      description:
          'Create tag_workflow_bindings table for tag-to-workflow binding infrastructure',
      execute: _migrateToVersion45,
    ),
    47: MigrationStep(
      description:
          'Add isSpace to filters; tag existing agent-skill notes all-spaces',
      execute: _migrateToVersion47,
    ),
    48: MigrationStep(
      description:
          'Create the fifteen sync_* control-plane tables for CRDT cloud sync (M1.1, pure-additive)',
      execute: _migrateToVersion48,
    ),
    49: MigrationStep(
      description:
          'Convert tags.name from a column-level UNIQUE constraint to the '
          'partial unique index idx_tags_name_live, and add tags.__deleted__/'
          'tags.redirectTarget columns (M1.3, tags identity schema)',
      execute: _migrateToVersion49,
    ),
    50: MigrationStep(
      description:
          'Add __deleted__ tombstone columns to user_apps/app_revisions/'
          'user_app_libraries/user_app_library_dependencies, and '
          'app_revisions.deletedAt for fallback-selection tie-break (M1.4, '
          'User-App-family soft-delete conversion)',
      execute: _migrateToVersion50,
    ),
    51: MigrationStep(
      description:
          'Install the M1.5 hard-delete guard triggers on user_apps/'
          'app_revisions/user_app_libraries/user_app_library_dependencies '
          '(BEFORE DELETE ... RAISE(ABORT, ...))',
      execute: _migrateToVersion51,
    ),
    52: MigrationStep(
      description:
          'Add __deleted__ tombstone columns to filters and '
          'tag_workflow_bindings (M1.7, filters + tag_workflow_bindings '
          'soft-delete conversion)',
      execute: _migrateToVersion52,
    ),
    53: MigrationStep(
      description:
          'Add __deleted__ tombstone columns to relationships and '
          'conversation_attachments (M1.8, relationships + '
          'conversation_attachments soft-delete conversion)',
      execute: _migrateToVersion53,
    ),
    54: MigrationStep(
      description:
          'Add __deleted__ tombstone column to notes (M1.10, deleteNote '
          'soft-delete conversion)',
      execute: _migrateToVersion54,
    ),
    55: MigrationStep(
      description:
          'Add __deleted__ tombstone columns to subnotes and attachments '
          '(M1.11, updateNote/_persistNote diff-based soft-delete '
          'conversion)',
      execute: _migrateToVersion55,
    ),
    56: MigrationStep(
      description:
          'Add __deleted__ tombstone columns to conversations and '
          'conversation_messages (M1.12, conversations + '
          'conversation_messages family soft-delete conversion, including '
          'the new membership-derived effective-visibility formula for '
          'conversation_messages)',
      execute: _migrateToVersion56,
    ),
    57: MigrationStep(
      description:
          'Install the M1.13 hard-delete guard triggers on notes/subnotes/'
          'attachments/tags/filters/relationships/tag_workflow_bindings/'
          'conversations/conversation_messages/conversation_attachments '
          '(BEFORE DELETE ... RAISE(ABORT, ...), extending the M1.5 guard '
          'to every fully-converted entity table)',
      execute: _migrateToVersion57,
    ),
    58: MigrationStep(
      description:
          'Install the M2.4 sync mutation-capture triggers on every '
          'requirement-1 sync-scope table (the fourteen hard-delete-guarded '
          'entity tables, AFTER INSERT/AFTER UPDATE per sync-scope column, '
          'writing into sync_touch_log; the five OR-Set membership tables, '
          'AFTER INSERT/AFTER DELETE) — § Architecture 11.3, "Mutation '
          'capture: from ordinary writes to a durable outbox"',
      execute: _migrateToVersion58,
    ),
    59: MigrationStep(
      description:
          'Add authorId/deviceSeq columns to sync_publish_intent — M2.6 '
          '(§ Architecture 11.7 Phase A resume procedure needs to recover '
          'which namespace/deviceSeq a pending publish intent belongs to; '
          'no existing row is ever affected since no code before M2.6 ever '
          'called appendCommit)',
      execute: _migrateToVersion59,
    ),
    60: MigrationStep(
      description:
          'Install M2.4 sync mutation-capture triggers for tags.name/'
          'tags.color — M2.7 (Architecture 11.6(e) auto-merge/collision '
          'detection needs a remote tag name, which the original '
          'syncScopeColumns list never captured; a required, adjacent fix, '
          'same shape as M2.4\'s own replaceTag follow-up)',
      execute: _migrateToVersion60,
    ),
    61: MigrationStep(
      description:
          'Install M2.4 sync mutation-capture triggers for six more '
          'creation-time-varying columns the M2.8 sync-scope-exclusion-'
          'reasoning audit found excluded on incomplete (UPDATE-only) '
          'reasoning, the same gap class as the M2.7 tags.name/color fix: '
          'relationships.type; conversation_attachments.{filePath,fileName,'
          'fileType,isRelativePath}; attachments.{filePath,fileName,'
          'fileType,isRelativePath}; app_revisions.{revisionNumber,'
          'userPrompt,aiResponse,attachmentPaths}; '
          'user_app_libraries.{name,usage_instructions}; '
          'user_app_library_dependencies.{original_url,local_path} — '
          'see syncEntityCaptureScopes\' own per-table doc comments for '
          'the full finding-by-finding reasoning',
      execute: _migrateToVersion61,
    ),
    62: MigrationStep(
      description:
          'Add opAuthorSeqsJson to sync_publish_intent — M2.12 (a commit now '
          'carries a BATCH of operations, so the resume procedure has to know '
          'exactly which sync_pending_ops rows a pending intent covers; '
          're-deriving it by searching candidate batch layouts could not '
          'answer the question for a batch formed under different size '
          'constants, which would wedge the namespace permanently). NULL on '
          'every pre-existing row, which is exactly right: those intents were '
          'written when one commit meant one operation',
      execute: _migrateToVersion62,
    ),
    63: MigrationStep(
      description:
          'Create search_chunks, chunk_embeddings, search_index_state tables and chunks_fts virtual table for layered search',
      execute: _migrateToVersion63,
    ),
    64: MigrationStep(
      description: 'Add localized User App metadata and sync capture',
      execute: _migrateToVersion64,
    ),
  };

  /// Localization shipped as v48 on main before the sync/index merge.
  /// Its new step also upgrades branch databases that already reached v63.
  static Future<void> _migrateToVersion64(
    Database db, {
    required bool isBackupMigration,
  }) async {
    final columns = await db.rawQuery("PRAGMA table_info('user_apps')");
    // Some recovery fixtures and very old/minimal databases legitimately do
    // not contain the optional User Apps subsystem. There is nothing to
    // migrate in those databases; a later table creation uses the current DDL.
    if (columns.isEmpty) return;
    // Also cover branch databases that had already passed the sync step.
    await _repairLegacyUserAppForeignKeys(db);
    if (!columns.any((column) => column['name'] == 'i18n')) {
      await db.execute('ALTER TABLE user_apps ADD COLUMN i18n TEXT');
    }
    // Existing installations already have the other capture triggers. Only
    // install this field's trigger once the new column exists.
    final syncTables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_touch_log'",
    );
    if (syncTables.isNotEmpty) {
      for (final statement in _entityCaptureTriggerStatementsFor(
        const SyncEntityCaptureScope(
          table: 'user_apps',
          idColumn: 'id',
          syncScopeColumns: ['i18n'],
        ),
      )) {
        await db.execute(statement);
      }
    }
  }

  /// The reserved tag name migration 47 writes. A frozen copy of
  /// `SpaceScopeService.allSpacesTag` — see [_migrateToVersion47].
  static const String _allSpacesTagV47 = 'all-spaces';

  /// Row id of the reserved `all-spaces` tag minted by [_migrateToVersion47].
  ///
  /// **This literal must never change.** Every database mints the tag
  /// independently — the live one when it upgrades, and every backup migrated
  /// by [migrateBackupDatabase] — and recovery merges the two by *name*
  /// (`RecoveryScreen._mergeTags`) while inserting the backup's `note_tags`
  /// rows verbatim afterwards, with no id remap. A per-database random uuid
  /// would therefore leave every restored skill note pointing at a tag id that
  /// exists in no `tags` row: the note would lose `all-spaces` and become
  /// invisible in every Space, which is exactly what the back-fill exists to
  /// prevent. A fixed id makes both sides id-equal, so the merge is a no-op.
  static const String _allSpacesTagIdV47 =
      'a115face-0000-4000-8000-000000000047';

  /// v47: filters gain the [Filter.isSpace] role flag, and every skill that
  /// already exists becomes visible from every Space.
  ///
  /// Without the second step every skill a user already has would vanish the
  /// first time they activate a Space (a space-scoped skill is one that
  /// carries the space's tags; a pre-existing skill carries none).
  ///
  /// Both steps are idempotent and use raw SQL only: this runs inside the
  /// database's own connection (also for backups, via [migrateBackupDatabase]),
  /// so calling an instance helper that awaits the `database` getter would
  /// deadlock.
  ///
  /// Both reserved tag names are written as literals — [_allSpacesTagV47] and
  /// `'agent-skill'` — rather than read from `SpaceScopeService.allSpacesTag`
  /// or `SkillService.agentSkillTag`: a migration is frozen history, so it
  /// must keep writing these exact strings even if either constant is later
  /// renamed (and importing those services here would drag
  /// `shared_preferences` and the service locator into the database layer).
  /// The migration test asserts the pairing by reading the constants, so a
  /// rename fails there instead of silently rewriting what v47 wrote.
  static Future<void> _migrateToVersion47(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // 1. Add the column, guarded so a re-run is a no-op.
    final filterColumns = await db.rawQuery("PRAGMA table_info('filters')");
    if (!filterColumns.any((col) => col['name'] == 'isSpace')) {
      await db.execute(
        'ALTER TABLE filters ADD COLUMN isSpace INTEGER NOT NULL DEFAULT 0',
      );
    }

    // 2. Ensure the reserved all-spaces tag row exists, reusing it if the
    // user already has one. Shaped exactly like _getOrCreateTagId creates it,
    // except for the id: see [_allSpacesTagIdV47] for why that one is fixed.
    final existingAllSpaces = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [_allSpacesTagV47],
      limit: 1,
    );
    final String allSpacesTagId;
    if (existingAllSpaces.isNotEmpty) {
      allSpacesTagId = existingAllSpaces.first['id'] as String;
    } else {
      allSpacesTagId = _allSpacesTagIdV47;
      await db.insert('tags', {
        'id': allSpacesTagId,
        'name': _allSpacesTagV47,
        'color': '#2196F3',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'usageCount': 0,
      });
    }

    // 3. Link it to every note carrying agent-skill. INSERT OR IGNORE against
    // the (noteId, tagId) primary key makes a second run a no-op; the EXISTS
    // guard skips note_tags rows orphaned by a database written while foreign
    // keys were off, which would abort the statement rather than be ignored.
    final skillTag = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: ['agent-skill'],
      limit: 1,
    );
    if (skillTag.isEmpty) return;
    final skillTagId = skillTag.first['id'] as String;

    final linked = await db.rawInsert(
      '''
      INSERT OR IGNORE INTO note_tags (noteId, tagId)
      SELECT nt.noteId, ?
      FROM note_tags nt
      WHERE nt.tagId = ?
        AND EXISTS (SELECT 1 FROM notes n WHERE n.id = nt.noteId)
      ''',
      [allSpacesTagId, skillTagId],
    );
    LoggerService.info(
      'v47: tagged $linked existing skill notes with $_allSpacesTagV47',
    );
  }

  /// Adds `opAuthorSeqsJson` to `sync_publish_intent` (M2.12's batched
  /// commits). Guarded with the same `PRAGMA table_info` existence check
  /// every other `ADD COLUMN` migration in this file uses — and for the same
  /// two concrete reasons `_migrateToVersion59`'s doc comment sets out at
  /// length: `_migrateToVersion48` builds the sync tables from the *live*
  /// `_syncControlPlaneTableStatements` list (which now already contains this
  /// column, so an upgrade from <= 46 arrives here with it present), and a
  /// mid-chain crash replays a step whose DDL SQLite already committed.
  static Future<void> _migrateToVersion62(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 62: add opAuthorSeqsJson to '
      'sync_publish_intent (M2.12 batched commits)',
    );
    try {
      final tableExists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        ['sync_publish_intent'],
      );
      if (tableExists.isEmpty) {
        LoggerService.info(
          'sync_publish_intent does not exist, skipping (fresh installs get '
          'the current schema straight from _onCreate)',
        );
        return;
      }
      final columns = await db.rawQuery(
        'PRAGMA table_info(sync_publish_intent)',
      );
      final columnNames = columns.map((c) => c['name'] as String).toSet();
      if (!columnNames.contains('opAuthorSeqsJson')) {
        await db.execute(
          'ALTER TABLE sync_publish_intent ADD COLUMN opAuthorSeqsJson TEXT',
        );
      }
      LoggerService.info('Successfully migrated to version 62');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 62',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Adds `authorId`/`deviceSeq` to `sync_publish_intent` (M2.6's push-phase
  /// resume procedure needs to know which namespace/position a pending intent
  /// belongs to).
  ///
  /// **Bug fix — this migration was originally written with two bare,
  /// unguarded `ALTER TABLE ... ADD COLUMN` statements, which permanently
  /// bricked any device that reached it with those columns already present.**
  /// It was the sole `ADD COLUMN` migration in this file's entire history that
  /// omitted the `PRAGMA table_info` existence guard every sibling uses
  /// (`_migrateToVersion50`/`51`/`52`/`53`/`54`/`55`), and it shipped that way
  /// because every migration test only ever exercised a clean forward path
  /// from a version at or above 47.
  ///
  /// There are two independent ways a device arrives here with the columns
  /// already present, and the first is deterministic, not a rare race:
  ///
  /// 1. **Any upgrade from schema version <= 46.** `_migrateToVersion48`
  ///    creates the fifteen sync_* tables by looping over the *live, shared*
  ///    `_syncControlPlaneTableStatements` list — and M2.6 added
  ///    `authorId`/`deviceSeq` to that list's `CREATE TABLE
  ///    sync_publish_intent`. So v48 now creates the table *with* both
  ///    columns, and v59 then tried to add them again a few steps later in the
  ///    very same chain. (This is the same "an early migration reuses a
  ///    since-grown live list" pattern already noted for
  ///    `_migrateToVersion58`'s triggers — judged harmless there only because
  ///    `CREATE TRIGGER IF NOT EXISTS` is idempotent. `ADD COLUMN` is not, so
  ///    the same reuse was *not* harmless here.)
  /// 2. **Any crash or later-step failure mid-chain.** The runner stamps
  ///    `_schema_version` once, only after *every* step succeeds, but SQLite
  ///    commits each DDL statement immediately and nothing rolls them back. So
  ///    if v59 succeeded and v60/v61 then failed (or the process died), the
  ///    recorded version stayed put and the next launch replayed v59 against
  ///    its own already-applied result.
  ///
  /// Either way the failure repeated identically on every subsequent launch —
  /// the device could never get past v59, and the original error (if it was
  /// case 2) was masked from then on. Guarding the statements makes this step
  /// idempotent, which fixes both paths at once and lets an already-affected
  /// device recover simply by installing a build containing this fix, with its
  /// data intact and no restore required.
  static Future<void> _migrateToVersion59(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 59: add authorId/deviceSeq columns to '
      'sync_publish_intent (M2.6 push-phase resume procedure)',
    );
    try {
      final tableExists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        ['sync_publish_intent'],
      );
      if (tableExists.isEmpty) {
        LoggerService.info(
          'sync_publish_intent does not exist, skipping (fresh installs get '
          'the current schema straight from _onCreate)',
        );
        return;
      }

      final columns = await db.rawQuery(
        'PRAGMA table_info(sync_publish_intent)',
      );
      final columnNames = columns.map((c) => c['name'] as String).toSet();

      if (!columnNames.contains('authorId')) {
        await db.execute(
          'ALTER TABLE sync_publish_intent ADD COLUMN authorId TEXT',
        );
      }
      if (!columnNames.contains('deviceSeq')) {
        await db.execute(
          'ALTER TABLE sync_publish_intent ADD COLUMN deviceSeq INTEGER',
        );
      }
      LoggerService.info('Successfully migrated to version 59');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 59',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  static Future<void> _migrateToVersion43(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Migrating conversation_attachments absolute paths to relative paths (v43)',
    );

    // Find all conversation_attachments with absolute paths
    final attachments = await db.query(
      'conversation_attachments',
      where: "filePath LIKE '/%'",
    );

    int migratedCount = 0;
    for (final attachment in attachments) {
      final id = attachment['id'] as String;
      final filePath = attachment['filePath'] as String;
      final fileName = attachment['fileName'] as String;
      final messageId = attachment['messageId'] as String;

      String newRelativePath;

      if (filePath.contains('/attachments/')) {
        // Path is absolute but already points inside attachments/
        // Just extract the attachments/ part
        final parts = filePath.split('/attachments/');
        if (parts.length > 1) {
          newRelativePath = 'attachments/${parts[1]}';
        } else {
          newRelativePath = 'attachments/$fileName';
        }
      } else {
        // Path is completely external (e.g., in synapse_temp)
        final uniqueName = '${messageId}_$fileName';
        newRelativePath = 'attachments/$uniqueName';

        try {
          final file = File(filePath);
          if (await file.exists()) {
            final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
            final targetPath = p.join(attachmentsDir.path, uniqueName);
            // Don't copy if it's already there (shouldn't happen due to the else branch, but safe to check)
            if (filePath != targetPath) {
              await file.copy(targetPath);
            }
          }
        } catch (e) {
          LoggerService.warning(
            'Failed to copy attachment during v43 migration: $filePath, error: $e',
          );
        }
      }

      await db.update(
        'conversation_attachments',
        {'filePath': newRelativePath, 'isRelativePath': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
      migratedCount++;
    }

    LoggerService.info(
      'Migrated $migratedCount absolute paths in conversation_attachments',
    );
  }

  static Future<void> _migrateToVersion44(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute(_createNoteAnnotationsTable);
  }

  static Future<void> _migrateToVersion45(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute(_createTagWorkflowBindingsTable);
  }

  // Repair confirmed legacy User App FK damage before adding the fifteen
  // sync control-plane tables. The shared sync DDL itself is idempotent and
  // additive; only the targeted legacy repair needs a table transaction.
  static Future<void> _migrateToVersion48(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 48: Create the fifteen sync_* control-plane tables for CRDT cloud sync (M1.1, pure-additive)',
    );
    try {
      await _repairLegacyUserAppForeignKeys(db);
      for (final statement in _syncControlPlaneTableStatements) {
        await db.execute(statement);
      }
      LoggerService.info('Successfully migrated to version 48');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 48',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Older v23 releases renamed user_apps before rebuilding it. SQLite
  /// rewrote incoming foreign keys to user_apps_old, which was then dropped.
  /// Repair only affected children, preserving their actual columns, indexes,
  /// triggers and data instead of rebuilding them from today's schema.
  static Future<void> _repairLegacyUserAppForeignKeys(Database db) async {
    const candidates = [
      'app_revisions',
      'user_app_libraries',
      'multi_function_apps',
    ];
    final affected = <String>[];
    for (final table in candidates) {
      final foreignKeys = await db.rawQuery('PRAGMA foreign_key_list($table)');
      if (foreignKeys.any((key) => key['table'] == 'user_apps_old')) {
        affected.add(table);
      }
    }
    if (affected.isEmpty) return;

    final foreignKeysEnabled =
        (await db.rawQuery('PRAGMA foreign_keys')).single['foreign_keys'] == 1;
    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.transaction((txn) async {
        for (final table in affected) {
          final schema = await txn.rawQuery(
            'SELECT type, sql FROM sqlite_master '
            'WHERE tbl_name = ? AND sql IS NOT NULL',
            [table],
          );
          final sourceDdl =
              schema.singleWhere((row) => row['type'] == 'table')['sql']
                  as String;
          final replacement = '${table}_fk_repair';
          int? originalSequence;
          if (RegExp(
            'AUTOINCREMENT',
            caseSensitive: false,
          ).hasMatch(sourceDdl)) {
            final sequence = await txn.rawQuery(
              'SELECT seq FROM sqlite_sequence WHERE name = ?',
              [table],
            );
            originalSequence = sequence.isEmpty
                ? null
                : sequence.single['seq'] as int;
          }
          final columns = await txn.rawQuery('PRAGMA table_info($table)');
          final columnList = columns
              .map((column) {
                final name = (column['name'] as String).replaceAll('"', '""');
                return '"$name"';
              })
              .join(', ');
          final repairedDdl = sourceDdl
              .substring(sourceDdl.indexOf('('))
              .replaceAll(
                RegExp(
                  r'REFERENCES\s+(?:"user_apps_old"|\[user_apps_old\]|`user_apps_old`|user_apps_old)(?=\s|\()',
                  caseSensitive: false,
                ),
                'REFERENCES user_apps',
              );
          // Create-new/drop-old/rename-new avoids rewriting any incoming
          // references to this child (notably library dependency ownership).
          await txn.execute('CREATE TABLE "$replacement" $repairedDdl');
          await txn.execute(
            'INSERT INTO "$replacement" ($columnList) '
            'SELECT $columnList FROM "$table"',
          );
          await txn.execute('DROP TABLE "$table"');
          await txn.execute('ALTER TABLE "$replacement" RENAME TO "$table"');
          if (originalSequence != null) {
            final updated = await txn.rawUpdate(
              'UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = ?',
              [originalSequence, table],
            );
            if (updated == 0) {
              await txn.insert('sqlite_sequence', {
                'name': table,
                'seq': originalSequence,
              });
            }
          }
          for (final object in schema.where((row) => row['type'] != 'table')) {
            await txn.execute(object['sql'] as String);
          }
        }
      });
    } finally {
      await db.execute(
        'PRAGMA foreign_keys = ${foreignKeysEnabled ? 'ON' : 'OFF'}',
      );
    }
  }

  // M1.3: tags identity schema. Converting `name`'s column-level UNIQUE to
  // the partial index idx_tags_name_live requires recreating the table —
  // SQLite cannot alter a column-level constraint in place — following the
  // same overall shape _migrateToVersion23 established for this kind of
  // change (bump DATABASE_VERSION, register a step, transaction + foreign
  // keys toggled, rename/recreate/copy/drop). `tags.id` is unchanged by
  // this migration, so every child table's FK (note_tags.tagId,
  // conversation_tags.tagId, tag_images.tagId, tag_ai_configs.tagId) keeps
  // pointing at the correct row's data — but see the deliberate ORDER
  // difference from _migrateToVersion23 below, which matters precisely
  // because `tags` has real incoming FKs.
  //
  // **Deliberate deviation from _migrateToVersion23's exact statement
  // order — confirmed necessary against this project's actual sqflite
  // runtime, not just SQLite in the abstract, after an initial review
  // round incorrectly concluded otherwise (recorded here rather than
  // silently corrected, since the reasoning is genuinely useful for the
  // next migration that touches a table with incoming FKs).**
  // _migrateToVersion23 renames the OLD table out of the way first
  // (`tags RENAME TO tags_old`), creates the new table under the final
  // name, copies data in, then drops the old one. That order corrupts FK
  // integrity for a table with incoming foreign keys, but *only* under
  // SQLite's "modern" `legacy_alter_table = OFF` renaming behavior (the
  // default this project's actual sqflite/sqflite_common_ffi build uses):
  // renaming `tags` rewrites every OTHER table's `REFERENCES tags(...)`
  // clause in place to say `REFERENCES tags_old(...)`, and that rewrite
  // survives the old table's later drop, permanently dangling. This
  // migration's own round-trip test (test/tags_identity_schema_test.dart)
  // caught this directly — `PRAGMA foreign_key_check` reported
  // `tag_images`/`tag_ai_configs`/`conversation_tags`/`note_tags` all
  // left referencing the since-dropped `tags_old` — when a rename-old-
  // first version of this migration was tried. A first-pass review of
  // this finding tried to independently verify it via a standalone
  // sqlite3-CLI reproduction of the same statement sequence and initially
  // found no corruption, incorrectly concluding the original finding was
  // a false positive and reverting to _migrateToVersion23's literal
  // order — which then failed this migration's own test exactly as the
  // original finding predicted, immediately surfacing the discrepancy.
  // The root cause: the CLI reproduction's SQLite build happened to
  // default to `legacy_alter_table = ON` (the *legacy* mode, where this
  // rewrite never happens), silently masking the issue — confirmed by a
  // follow-up CLI reproduction with `PRAGMA legacy_alter_table = OFF` set
  // explicitly, which *does* reproduce the exact corruption. `PRAGMA
  // foreign_keys = OFF` (which both migrations already set) only
  // suppresses constraint *enforcement*; it has no effect on this
  // rename-time schema-text rewrite, which is gated by
  // `legacy_alter_table` alone. `user_apps` has the identical exposure
  // today via `app_revisions.appId REFERENCES user_apps(id)` — the
  // mechanism is now well-understood and demonstrated for this exact
  // "rename old table first" pattern under this project's actual
  // runtime. v23 now adds a unique index without renaming the table;
  // _repairLegacyUserAppForeignKeys repairs existing damage from older
  // releases. Neither path can copy the rename-first mistake into new code.
  //
  // The fix, and SQLite's own documented safe procedure for this exact
  // case (lang_altertable.html, "Making Other Kinds Of Table Schema
  // Changes"): create the replacement under a temporary name (`tags_new`,
  // never referenced by any FK clause, so the rename-rewrite has nothing
  // to touch), copy data in, drop the *original* `tags` (its dependents'
  // FK clauses still literally say `tags` — untouched, since renaming
  // never happened to `tags` itself), then rename `tags_new` to `tags`.
  // At no point does any child table's FK clause get rewritten to a name
  // that later stops existing.
  //
  // `DROP TABLE tags` below is a real DROP, immediately followed by
  // renaming its already-populated replacement into the now-free name — at
  // no point is user data actually destroyed. The M1.2 hard-delete-call-
  // site audit (test/hard_delete_audit_test.dart) does not flag it: its
  // scanner pattern-matches only `db.delete(...)`/`txn.delete(...)`/
  // `.rawDelete('DELETE FROM ...')` calls, never `db.execute('DROP TABLE
  // ...')` — the same reason _migrateToVersion23's own `DROP TABLE
  // user_apps_old` has never been flagged either.
  static Future<void> _migrateToVersion49(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 49: converting tags.name UNIQUE to '
      'partial index idx_tags_name_live, adding __deleted__/redirectTarget',
    );

    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='tags'",
      );
      if (tables.isEmpty) {
        LoggerService.info('tags table does not exist, skipping migration');
        return;
      }

      // Idempotency guard: if a previous run already completed (e.g. a
      // backup migration retried after a partial failure elsewhere), the
      // new columns already exist — skip re-running the rename dance.
      final tagColumns = await db.rawQuery('PRAGMA table_info(tags)');
      final alreadyMigrated = tagColumns.any((c) => c['name'] == '__deleted__');
      if (alreadyMigrated) {
        LoggerService.info(
          'tags table already has __deleted__ column, skipping rename step',
        );
        await db.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_name_live ON tags(name) '
          'WHERE __deleted__ = 0 AND redirectTarget IS NULL',
        );
        return;
      }

      await db.execute('PRAGMA foreign_keys = OFF');
      await db.execute('BEGIN TRANSACTION');

      try {
        // Create the replacement under a temporary name — see the
        // note above for why this must not be a rename-old-first dance
        // for a table with incoming FKs.
        await db.execute(
          _createTagsTable.replaceFirst(
            'CREATE TABLE tags(',
            'CREATE TABLE tags_new(',
          ),
        );

        await db.execute('''
          INSERT INTO tags_new (id, name, color, createdAt, usageCount, __deleted__, redirectTarget)
          SELECT id, name, color, createdAt, usageCount, 0, NULL
          FROM tags
        ''');

        await db.execute('DROP TABLE tags');
        await db.execute('ALTER TABLE tags_new RENAME TO tags');

        await db.execute(_createTagsNameLiveIndex);

        await db.execute('COMMIT');

        LoggerService.info(
          'Successfully migrated tags table to the M1.3 identity schema',
        );
      } catch (e) {
        await db.execute('ROLLBACK');
        LoggerService.error(
          'Error during tags table migration, rolled back: $e',
        );
        rethrow;
      } finally {
        await db.execute('PRAGMA foreign_keys = ON');
      }

      LoggerService.info('Migration to version 49 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 49: $e', error: e);
      rethrow;
    }
  }

  // M1.4: User-App-family soft-delete conversion (design doc § Architecture
  // 10). Adds `__deleted__` to user_apps/app_revisions/user_app_libraries/
  // user_app_library_dependencies, and `app_revisions.deletedAt` (the
  // fallback-selection tie-break input — see computeAppRevisionVisibility's
  // doc comment).
  //
  // **Deliberately plain `ALTER TABLE ... ADD COLUMN`, not the
  // temporary-table-rename dance `_migrateToVersion49` needed.** The two
  // tables here with real incoming FKs (`user_apps` — referenced by
  // `app_revisions.appId`/`user_app_libraries.app_uuid`/
  // `multi_function_apps.appId` — and `user_app_libraries`, referenced by
  // `user_app_library_dependencies.library_id`) look superficially like the
  // same hazard `_migrateToVersion49`'s doc comment documents for `tags`,
  // but the mechanism there is specific to `ALTER TABLE x RENAME TO y`:
  // renaming rewrites every OTHER table's `REFERENCES x(...)` clause to say
  // `y`, which dangles once the old table is dropped. This migration never
  // renames anything — it only adds new, defaulted/nullable columns to the
  // existing tables in place — so that rewrite never triggers, regardless
  // of `legacy_alter_table`. Verified empirically (not merely by this
  // reasoning, per this project's own M1.3 lesson about trusting plausible
  // arguments over direct verification): a standalone sqflite_common_ffi
  // reproduction of `ALTER TABLE parent ADD COLUMN ...` against a parent
  // table with a real incoming `ON DELETE CASCADE` FK confirmed
  // `PRAGMA foreign_key_check` stays clean and the cascade still fires
  // correctly afterward. `app_revisions` and `user_app_library_dependencies`
  // have no incoming FKs at all (`user_app_libraries.revision_id`, despite
  // its name, is never declared as a FK to `app_revisions` — see
  // `computeAppRevisionVisibility`'s doc comment for why), so they were
  // never in question either way.
  //
  // This also sidesteps the large-data-column risk CLAUDE.md flags
  // (`app_revisions.appCode`, `user_app_library_dependencies.bytes`): a
  // plain `ADD COLUMN` is metadata-only and touches zero existing row data,
  // so there is no `INSERT ... SELECT` copy of either large column to get
  // right (or wrong) in the first place — the safe-for-large-data
  // requirement that mattered so much for `_migrateToVersion49`'s
  // rename-dance (which never touches a large-data table anyway) simply
  // doesn't arise here.
  static Future<void> _migrateToVersion50(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 50: adding __deleted__ tombstone '
      'columns to the User-App family, and app_revisions.deletedAt '
      '(M1.4)',
    );
    try {
      const targetTables = [
        'user_apps',
        'app_revisions',
        'user_app_libraries',
        'user_app_library_dependencies',
      ];
      for (final tableName in targetTables) {
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tableExists.isEmpty) {
          LoggerService.info(
            '$tableName table does not exist, skipping (fresh installs get '
            'the current schema straight from _onCreate)',
          );
          continue;
        }

        final columns = await db.rawQuery('PRAGMA table_info($tableName)');
        final columnNames = columns.map((c) => c['name'] as String).toSet();

        if (!columnNames.contains('__deleted__')) {
          await db.execute(
            'ALTER TABLE $tableName ADD COLUMN __deleted__ INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (tableName == 'app_revisions' &&
            !columnNames.contains('deletedAt')) {
          await db.execute(
            'ALTER TABLE app_revisions ADD COLUMN deletedAt INTEGER',
          );
        }
      }
      LoggerService.info('Successfully migrated to version 50');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 50',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M1.5: install the hard-delete guard triggers (see the doc comment
  // above _hardDeleteGuardTriggerStatements) for an existing install —
  // pure-additive, `CREATE TRIGGER IF NOT EXISTS`, same shape
  // _migrateToVersion48 used for the sync control-plane tables: no
  // existing table/data is touched, so no rename/copy/drop dance or
  // transaction wrapping is needed.
  // Deliberately does NOT iterate the shared `_hardDeleteGuardTriggerStatements`
  // (unlike _onCreate and _migrateToVersion57, which legitimately want
  // "whatever the guarded-table list is today"): this migration step is a
  // frozen, historical fact about what version 51 specifically did --
  // install the guard on exactly the four original User-App-family
  // tables. `_hardDeleteGuardedTables` grew from 4 to 14 entries in M1.13;
  // had this migration kept referencing that shared, since-grown list, a
  // real multi-step upgrade landing on this step (e.g. an existing v46
  // install migrating straight to v57) would silently install all
  // fourteen triggers here instead of the four this step's own doc
  // comment and log message describe -- harmless today only by accident
  // (migrations 51-55 are pure `ALTER TABLE ADD COLUMN`, nothing that
  // could trip a trigger before its own dedicated migration step installs
  // it), but a latent trap for any future migration ever inserted between
  // 50 and 56. `newlyGuardedTablesAtV50` is therefore its own frozen
  // snapshot, local to this function, of exactly what M1.5 guarded at the
  // time this step was written -- immune to any future growth of the
  // shared list, exactly like _migrateToVersion57's own `newlyGuardedTables`
  // local list is immune to any growth beyond M1.13.
  static Future<void> _migrateToVersion51(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 51: install the M1.5 hard-delete '
      'guard triggers on user_apps/app_revisions/user_app_libraries/'
      'user_app_library_dependencies',
    );
    try {
      const newlyGuardedTablesAtV50 = [
        'user_apps',
        'app_revisions',
        'user_app_libraries',
        'user_app_library_dependencies',
      ];
      for (final table in newlyGuardedTablesAtV50) {
        await db.execute(_hardDeleteGuardTrigger(table));
      }
      LoggerService.info('Successfully migrated to version 51');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 51',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M1.7 (design doc § Phased delivery, M1.7): adds `__deleted__` to
  // `filters` and `tag_workflow_bindings` — the two lowest-risk remaining
  // entity tables (independent, single-statement deletes, no FK/diff
  // complexity), validating the M1.4 pattern generalizes outside the
  // User-App family.
  //
  // Deliberately a plain `ALTER TABLE ... ADD COLUMN`, the same
  // `_migrateToVersion50` precedent used, not `_migrateToVersion49`'s
  // temporary-table-rename dance: neither table has any incoming FK
  // (`filters`/`tag_workflow_bindings` are both leaf tables with no child
  // table referencing them — see kFkEdgeBaseline in
  // test/hard_delete_audit_test.dart), so the rename-specific
  // `REFERENCES x(...)` rewrite hazard `_migrateToVersion49`'s own doc
  // comment describes never arises here, and a plain `ADD COLUMN` is
  // metadata-only besides.
  static Future<void> _migrateToVersion52(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 52: adding __deleted__ tombstone '
      'columns to filters and tag_workflow_bindings (M1.7)',
    );
    try {
      const targetTables = ['filters', 'tag_workflow_bindings'];
      for (final tableName in targetTables) {
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tableExists.isEmpty) {
          LoggerService.info(
            '$tableName table does not exist, skipping (fresh installs get '
            'the current schema straight from _onCreate)',
          );
          continue;
        }

        final columns = await db.rawQuery('PRAGMA table_info($tableName)');
        final columnNames = columns.map((c) => c['name'] as String).toSet();

        if (!columnNames.contains('__deleted__')) {
          await db.execute(
            'ALTER TABLE $tableName ADD COLUMN __deleted__ INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
      LoggerService.info('Successfully migrated to version 52');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 52',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M1.8 (design doc § Phased delivery, M1.8): adds `__deleted__` to
  // `relationships` and `conversation_attachments` — "independent entities,
  // touched only on explicit removal (no reinsert pattern)".
  //
  // Deliberately a plain `ALTER TABLE ... ADD COLUMN`, the same
  // `_migrateToVersion50`/`_migrateToVersion52` precedent: both tables do
  // have incoming FKs from other tables (`notes -> relationships`,
  // `conversation_messages -> conversation_attachments`), but neither table
  // is itself the *target* of a rename or column-type change here — only a
  // new nullable-default column is being appended, so the
  // `_migrateToVersion49`-style temporary-table-rename dance (needed there
  // because `tags.name`'s UNIQUE constraint itself had to change) still
  // does not apply.
  static Future<void> _migrateToVersion53(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 53: adding __deleted__ tombstone '
      'columns to relationships and conversation_attachments (M1.8)',
    );
    try {
      const targetTables = ['relationships', 'conversation_attachments'];
      for (final tableName in targetTables) {
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tableExists.isEmpty) {
          LoggerService.info(
            '$tableName table does not exist, skipping (fresh installs get '
            'the current schema straight from _onCreate)',
          );
          continue;
        }

        final columns = await db.rawQuery('PRAGMA table_info($tableName)');
        final columnNames = columns.map((c) => c['name'] as String).toSet();

        if (!columnNames.contains('__deleted__')) {
          await db.execute(
            'ALTER TABLE $tableName ADD COLUMN __deleted__ INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
      LoggerService.info('Successfully migrated to version 53');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 53',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M1.10 (design doc § Phased delivery, M1.10): adds `__deleted__` to
  // `notes` only — `deleteNote` is the sole function this milestone
  // converts. `subnotes`/`attachments` deliberately do NOT gain a
  // `__deleted__` column here; see the doc comment above `deleteNote`
  // itself for why (their diff-based update-path rewrite is M1.11's job,
  // not this milestone's).
  //
  // Deliberately a plain `ALTER TABLE ... ADD COLUMN`, the same
  // `_migrateToVersion50`/`51`/`52` precedent: `notes` does have incoming
  // FKs from other tables (`subnotes`/`attachments`/`note_tags`/
  // `relationships`/`conversation_note_mapping` all reference it), but
  // `notes` itself is not the *target* of a rename or column-type change
  // here — only a new nullable-default column is being appended, so the
  // `_migrateToVersion49`-style temporary-table-rename dance still does
  // not apply.
  static Future<void> _migrateToVersion54(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 54: adding __deleted__ tombstone '
      'column to notes (M1.10)',
    );
    try {
      const targetTables = ['notes'];
      for (final tableName in targetTables) {
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tableExists.isEmpty) {
          LoggerService.info(
            '$tableName table does not exist, skipping (fresh installs get '
            'the current schema straight from _onCreate)',
          );
          continue;
        }

        final columns = await db.rawQuery('PRAGMA table_info($tableName)');
        final columnNames = columns.map((c) => c['name'] as String).toSet();

        if (!columnNames.contains('__deleted__')) {
          await db.execute(
            'ALTER TABLE $tableName ADD COLUMN __deleted__ INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
      LoggerService.info('Successfully migrated to version 54');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 54',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M1.11 (design doc § Phased delivery, M1.11 — "subnotes + attachments
  // via updateNote/_persistNote, per the dedicated design discussion
  // above"): adds `__deleted__` to `subnotes` and `attachments`, so
  // `updateNote`/`_persistNote`'s rewritten diff logic (id-keyed for
  // subnotes, filePath-diffed-but-id-targeted for attachments) can
  // tombstone a removed child row instead of hard-deleting it, matching
  // the entity-table treatment every other converted table in this effort
  // already has. `deleteNote` itself is unaffected — it deliberately keeps
  // real-deleting both tables' rows for the note being deleted (see its
  // own doc comment in this file), so this migration only adds the column;
  // it does not change what `deleteNote` does with it.
  //
  // Deliberately a plain `ALTER TABLE ... ADD COLUMN`, the same
  // `_migrateToVersion50`/`51`/`52`/`53` precedent: both tables have an
  // incoming FK from `notes`, but neither is itself the *target* of a
  // rename or column-type change here — only a new nullable-default column
  // is being appended, so the `_migrateToVersion49`-style temporary-table-
  // rename dance still does not apply.
  static Future<void> _migrateToVersion55(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 55: adding __deleted__ tombstone '
      'columns to subnotes and attachments (M1.11)',
    );
    try {
      const targetTables = ['subnotes', 'attachments'];
      for (final tableName in targetTables) {
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tableExists.isEmpty) {
          LoggerService.info(
            '$tableName table does not exist, skipping (fresh installs get '
            'the current schema straight from _onCreate)',
          );
          continue;
        }

        final columns = await db.rawQuery('PRAGMA table_info($tableName)');
        final columnNames = columns.map((c) => c['name'] as String).toSet();

        if (!columnNames.contains('__deleted__')) {
          await db.execute(
            'ALTER TABLE $tableName ADD COLUMN __deleted__ INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
      LoggerService.info('Successfully migrated to version 55');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 55',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M1.12 (design doc § Phased delivery, M1.12 — "conversations +
  // conversation_messages family"): adds `__deleted__` to `conversations`
  // and `conversation_messages`. `conversations` is a straightforward
  // entity tombstone (see the doc comment above `_createConversationsTable`).
  // `conversation_messages` additionally requires the new, membership-
  // derived effective-visibility formula (`computeConversationMessageVisibility`,
  // near the conversation-messages CRUD section) since this table never had
  // a tombstone column at all before this milestone.
  //
  // Deliberately a plain `ALTER TABLE ... ADD COLUMN`, the same
  // `_migrateToVersion50`/`51`/`52`/`53`/`54` precedent: both tables have
  // incoming FKs from other tables (`conversation_message_mapping`/
  // `conversation_note_mapping`/`conversation_tags` reference `conversations`;
  // `conversation_attachments`/`conversation_message_mapping`/
  // `message_parents` reference `conversation_messages`), but neither table
  // is itself the *target* of a rename or column-type change here — only a
  // new nullable-default column is being appended, so the
  // `_migrateToVersion49`-style temporary-table-rename dance still does not
  // apply.
  static Future<void> _migrateToVersion56(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 56: adding __deleted__ tombstone '
      'columns to conversations and conversation_messages (M1.12)',
    );
    try {
      const targetTables = ['conversations', 'conversation_messages'];
      for (final tableName in targetTables) {
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tableExists.isEmpty) {
          LoggerService.info(
            '$tableName table does not exist, skipping (fresh installs get '
            'the current schema straight from _onCreate)',
          );
          continue;
        }

        final columns = await db.rawQuery('PRAGMA table_info($tableName)');
        final columnNames = columns.map((c) => c['name'] as String).toSet();

        if (!columnNames.contains('__deleted__')) {
          await db.execute(
            'ALTER TABLE $tableName ADD COLUMN __deleted__ INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
      LoggerService.info('Successfully migrated to version 56');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 56',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M1.13: install the hard-delete guard triggers for every entity table
  // M1.7-M1.12 converted to soft-delete, extending the M1.5 guard beyond
  // its original four User-App-family tables (see the doc comment above
  // `_hardDeleteGuardedTables`). Pure-additive, `CREATE TRIGGER IF NOT
  // EXISTS`, same shape `_migrateToVersion51` used for the original four:
  // no existing table/data is touched, so no rename/copy/drop dance or
  // transaction wrapping is needed. Deliberately lists only the ten NEW
  // tables here (not the full, now-14-entry `_hardDeleteGuardedTables`) so
  // an existing install's migration log clearly shows what changed at
  // this version, even though re-running `CREATE TRIGGER IF NOT EXISTS`
  // for the original four would be harmless.
  static Future<void> _migrateToVersion57(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 57: install the M1.13 hard-delete '
      'guard triggers on notes/subnotes/attachments/tags/filters/'
      'relationships/tag_workflow_bindings/conversations/'
      'conversation_messages/conversation_attachments',
    );
    try {
      const newlyGuardedTables = [
        'notes',
        'subnotes',
        'attachments',
        'tags',
        'filters',
        'relationships',
        'tag_workflow_bindings',
        'conversations',
        'conversation_messages',
        'conversation_attachments',
      ];
      for (final table in newlyGuardedTables) {
        await db.execute(_hardDeleteGuardTrigger(table));
      }
      LoggerService.info('Successfully migrated to version 57');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 57',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M2.4: install the sync mutation-capture triggers (see
  // _syncMutationCaptureTriggerStatements's own doc comment for the full
  // design rationale). Pure-additive, `CREATE TRIGGER IF NOT EXISTS`, the
  // same shape `_migrateToVersion57` used for the hard-delete guard: no
  // existing table/data is touched, so no rename/copy/drop dance or extra
  // transaction wrapping is needed. Reuses the single shared statement list
  // (not a separately-hand-copied subset) since, unlike
  // `_migrateToVersion51`/`_migrateToVersion57`'s deliberately-frozen
  // historical table lists, this is the very first version this mechanism
  // is introduced at — there is no earlier, narrower historical scope to
  // preserve, so "current, complete list" and "this migration's own scope"
  // are the same list today.
  static Future<void> _migrateToVersion58(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 58: install the M2.4 sync '
      'mutation-capture triggers on every requirement-1 sync-scope table',
    );
    try {
      for (final statement in _syncMutationCaptureTriggerStatements) {
        // v64 creates i18n and its trigger together. Installing the trigger
        // before its column exists would break interim user_apps writes.
        if (statement.contains('sync_touch_user_apps_au_i18n')) continue;
        await db.execute(statement);
      }
      LoggerService.info('Successfully migrated to version 58');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 58',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M2.7: `tags.name`/`tags.color` joined `syncScopeColumns` after
  // `_migrateToVersion58` had already shipped, so that migration's own
  // reuse of the "current, complete" trigger-statement list no longer
  // covers an already-migrated install. Pure-additive, `CREATE TRIGGER IF
  // NOT EXISTS`, identical shape to `_migrateToVersion58` — explicit rather
  // than re-running the full (now-current) shared list, matching
  // `_migrateToVersion57`/`_migrateToVersion51`'s own "frozen historical
  // scope" precedent for a migration introduced after the mechanism's
  // initial version.
  static Future<void> _migrateToVersion60(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 60: install sync mutation-capture '
      'triggers for tags.name/tags.color',
    );
    try {
      for (final column in ['name', 'color']) {
        await db.execute('''
          CREATE TRIGGER IF NOT EXISTS sync_touch_tags_au_$column
          AFTER UPDATE ON tags
          WHEN NEW.$column IS NOT OLD.$column
          BEGIN
            ${_syncTouchInsert(entityTable: 'tags', entityIdExpr: 'NEW.id', fieldName: column)}
          END;
        ''');
      }
      LoggerService.info('Successfully migrated to version 60');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 60',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // M2.8: the sync-scope-exclusion-reasoning audit (§ Architecture 11.8,
  // added per the M2.7 addendum) found six more (table, column) pairs
  // excluded from `syncScopeColumns` on the same incomplete "no UPDATE call
  // site" reasoning the M2.7 addendum found for `tags.name`/`color` — see
  // each column's own finding, recorded at its `syncEntityCaptureScopes`
  // entry above. Pure-additive, `CREATE TRIGGER IF NOT EXISTS`, identical
  // shape and same "explicit rather than re-running the full current
  // shared list" precedent as `_migrateToVersion60`.
  static Future<void> _migrateToVersion61(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 61: install sync mutation-capture '
      'triggers for the M2.8 sync-scope-exclusion-reasoning audit findings',
    );
    try {
      const newColumnsByTable = {
        'relationships': ['type'],
        'conversation_attachments': [
          'filePath',
          'fileName',
          'fileType',
          'isRelativePath',
        ],
        'attachments': ['filePath', 'fileName', 'fileType', 'isRelativePath'],
        'app_revisions': [
          'revisionNumber',
          'userPrompt',
          'aiResponse',
          'attachmentPaths',
        ],
        'user_app_libraries': ['name', 'usage_instructions'],
        'user_app_library_dependencies': ['original_url', 'local_path'],
      };
      for (final entry in newColumnsByTable.entries) {
        final table = entry.key;
        for (final column in entry.value) {
          await db.execute('''
            CREATE TRIGGER IF NOT EXISTS sync_touch_${table}_au_$column
            AFTER UPDATE ON $table
            WHEN NEW.$column IS NOT OLD.$column
            BEGIN
              ${_syncTouchInsert(entityTable: table, entityIdExpr: 'NEW.id', fieldName: column)}
            END;
          ''');
        }
      }
      LoggerService.info('Successfully migrated to version 61');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to migrate to version 61',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Creates the layered-search index tables. Renumbered from 47 to 62 when
  /// the note-index branch merged with cloud sync, which had already
  /// consumed 47..61: a database already stamped 61 would never run a step
  /// keyed 47, and the whole search index would be silently absent.
  ///
  /// All DDL here is `IF NOT EXISTS`: migration 62 runs outside a
  /// transaction (custom-migration path), so a mid-migration crash must be
  /// re-runnable, not a permanent recovery loop.
  static Future<void> _migrateToVersion63(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute(_createSearchChunksTable);
    await db.execute(_createChunkEmbeddingsTable);
    await db.execute(_createSearchIndexStateTable);

    await db.execute(_createIdxSearchChunksKey);
    await db.execute(_createIdxSearchChunksNoteId);
    await db.execute(_createIdxSearchChunksSource);
    await db.execute(_createIdxAttachmentsNoteId);

    // FTS4 may be unavailable (web wasm sqlite is FTS5-only; possible future
    // iOS removal). Degrade to substring search instead of failing the
    // upgrade — availability is probed on every open (chunksFtsAvailable).
    try {
      await db.execute(_createChunksFtsTable);
    } catch (e) {
      LoggerService.warning(
        'chunks_fts FTS4 creation failed, search will degrade to substring matching: $e',
      );
    }
    await _ensureSearchSourceLookupIndexes(db);
  }

  /// Backfill reads sources by their owning note/attachment. Without these
  /// indexes every batch scans the whole source table. Ensure them on every
  /// open so existing index-branch databases also receive the lookup paths.
  static Future<void> _ensureSearchSourceLookupIndexes(Database db) async {
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name IN ('subnotes', 'note_annotations')",
    )).map((row) => row['name']).toSet();
    if (tables.contains('subnotes')) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_subnotes_noteId ON subnotes(noteId)',
      );
    }
    if (tables.contains('note_annotations')) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_note_annotations_note_id '
        'ON note_annotations(note_id)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_note_annotations_attachment_id '
        'ON note_annotations(attachment_id)',
      );
    }
  }

  static Future<void> _migrateToVersion28(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // Add new columns to filters table
    await db.execute(
      "ALTER TABLE filters ADD COLUMN excludeTags TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE filters ADD COLUMN noteTypes TEXT NOT NULL DEFAULT ''",
    );
  }

  static Future<void> _migrateToVersion30(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // Add recurrenceRule column to notes table
    await db.execute("ALTER TABLE notes ADD COLUMN recurrenceRule TEXT");
  }

  static Future<void> _migrateToVersion31(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // 1. Create notes_fts virtual table using FTS4 (universally supported on all platforms)
    await db.execute('''
      CREATE VIRTUAL TABLE notes_fts USING fts4(
        title, 
        content
      );
    ''');

    // 2. Populate notes_fts with existing data
    await db.execute('''
      INSERT INTO notes_fts(docid, title, content)
      SELECT rowid, title, content FROM notes;
    ''');

    // 3. Create Triggers to keep notes_fts in sync
    // INSERT Trigger
    await db.execute('''
      CREATE TRIGGER notes_ai_insert AFTER INSERT ON notes
      BEGIN
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
    ''');

    // DELETE Trigger
    await db.execute('''
      CREATE TRIGGER notes_ai_delete AFTER DELETE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
      END;
    ''');

    // UPDATE Trigger
    await db.execute('''
      CREATE TRIGGER notes_ai_update AFTER UPDATE ON notes
      BEGIN
        DELETE FROM notes_fts WHERE docid = old.rowid;
        INSERT INTO notes_fts(docid, title, content)
        VALUES(new.rowid, new.title, new.content);
      END;
    ''');

    // 4. Create tag_ai_configs table
    await db.execute('''
      CREATE TABLE tag_ai_configs (
        tagId TEXT PRIMARY KEY,
        extractionPrompt TEXT,
        FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
      )
    ''');
  }

  // Individual migration methods
  static Future<void> _migrateToVersion20(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 20: Ensuring conversation_messages schema is correct',
    );

    try {
      // Check if conversationId column exists by trying to query it
      final testQuery = await db.rawQuery(
        'PRAGMA table_info(conversation_messages)',
      );
      final hasConversationId = testQuery.any(
        (col) => col['name'] == 'conversationId',
      );

      if (hasConversationId) {
        LoggerService.info(
          'Found conversationId column in conversation_messages, removing it...',
        );

        // Drop the index if it exists
        await db.execute(
          'DROP INDEX IF EXISTS idx_conversation_messages_conversationId',
        );

        // Recreate the table without conversationId
        await db.execute(
          'ALTER TABLE conversation_messages RENAME TO conversation_messages_old',
        );
        await db.execute(_createConversationMessagesTable);

        // Copy data from old table to new table
        await db.execute('''
          INSERT INTO conversation_messages (id, type, content, timestamp, modelUsed, metadata)
          SELECT id, type, content, timestamp, modelUsed, metadata FROM conversation_messages_old
        ''');

        // Drop the old table
        await db.execute('DROP TABLE conversation_messages_old');

        // Recreate the timestamp index
        await db.execute(
          'CREATE INDEX idx_conversation_messages_timestamp ON conversation_messages(timestamp)',
        );

        LoggerService.info(
          'Successfully removed conversationId column from conversation_messages',
        );
      } else {
        LoggerService.info(
          'conversation_messages table already has correct schema (no conversationId column)',
        );
      }

      // Ensure all required tables and indexes exist
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS conversation_message_mapping(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversationId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
            FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
            UNIQUE(conversationId, messageId)
          )
        ''');
      } catch (e) {
        LoggerService.debug(
          'conversation_message_mapping table already exists',
        );
      }

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS message_parents(
            id TEXT PRIMARY KEY,
            messageId TEXT NOT NULL,
            parentMessageId TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            FOREIGN KEY (messageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
            FOREIGN KEY (parentMessageId) REFERENCES conversation_messages (id) ON DELETE CASCADE,
            UNIQUE(messageId, parentMessageId)
          )
        ''');
      } catch (e) {
        LoggerService.debug('message_parents table already exists');
      }

      // Ensure indexes exist
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_message_mapping_conversationId ON conversation_message_mapping(conversationId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_message_mapping_messageId ON conversation_message_mapping(messageId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_message_parents_messageId ON message_parents(messageId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_message_parents_parentMessageId ON message_parents(parentMessageId)',
      );

      LoggerService.info('Migration to version 20 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 20: $e', error: e);
      rethrow;
    }
  }

  // Migration to version 21: Create conversation_note_mapping table and migrate data
  static Future<void> _migrateToVersion21(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 21: Creating conversation_note_mapping table and migrating data',
    );

    try {
      // Create the conversation_note_mapping table
      await db.execute('''
        CREATE TABLE conversation_note_mapping(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversationId TEXT NOT NULL,
          noteId TEXT NOT NULL,
          createdAt INTEGER NOT NULL,
          FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
          FOREIGN KEY (noteId) REFERENCES notes (id) ON DELETE CASCADE,
          UNIQUE(conversationId, noteId)
        )
      ''');

      // Create indexes
      await db.execute(
        'CREATE INDEX idx_conversation_note_mapping_conversationId ON conversation_note_mapping(conversationId)',
      );
      await db.execute(
        'CREATE INDEX idx_conversation_note_mapping_noteId ON conversation_note_mapping(noteId)',
      );

      LoggerService.info('Created conversation_note_mapping table and indexes');

      // Migrate existing noteIds data to the new mapping table
      final conversations = await db.query('conversations');
      int migratedCount = 0;

      for (final conversation in conversations) {
        final conversationId = conversation['id'] as String;
        final noteIdsJson = conversation['noteIds'] as String?;

        if (noteIdsJson != null && noteIdsJson.isNotEmpty) {
          try {
            final noteIds = List<String>.from(jsonDecode(noteIdsJson));
            final now = DateTime.now().millisecondsSinceEpoch;

            for (final noteId in noteIds) {
              // Check if the note still exists before creating the mapping
              final noteExists = await db.query(
                'notes',
                where: 'id = ?',
                whereArgs: [noteId],
                limit: 1,
              );

              if (noteExists.isNotEmpty) {
                await db.insert(
                  'conversation_note_mapping',
                  {
                    'conversationId': conversationId,
                    'noteId': noteId,
                    'createdAt': now,
                  },
                  conflictAlgorithm: ConflictAlgorithm.ignore,
                );
                migratedCount++;
              } else {
                LoggerService.warning(
                  'Skipping migration for non-existent note: $noteId in conversation: $conversationId',
                );
              }
            }
          } catch (e) {
            LoggerService.error(
              'Error parsing noteIds for conversation $conversationId: $e',
            );
          }
        }
      }

      LoggerService.info('Migrated $migratedCount note-conversation mappings');
      LoggerService.info('Migration to version 21 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 21: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion22(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 22: Creating conversation_tags table',
    );

    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS conversation_tags(
          conversationId TEXT NOT NULL,
          tagId TEXT NOT NULL,
          PRIMARY KEY (conversationId, tagId),
          FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE,
          FOREIGN KEY (tagId) REFERENCES tags (id) ON DELETE CASCADE
        )
      ''');

      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_tags_conversationId ON conversation_tags(conversationId)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversation_tags_tagId ON conversation_tags(tagId)',
      );

      LoggerService.info('Migration to version 22 completed successfully');
    } catch (e) {
      LoggerService.error('Error in migration to version 22: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion23(
    Database db, {
    required bool isBackupMigration,
  }) async {
    final columns = await db.rawQuery('PRAGMA table_info(user_apps)');
    if (columns.isEmpty) return;

    // A unique index enforces UUID identity without rebuilding the table.
    // Rebuilding from today's CREATE statement assumed later columns (i18n)
    // existed in the source and renamed incoming app_revisions/library FKs
    // to user_apps_old. Preserve every existing column, row, index and FK.
    final indexes = await db.rawQuery('PRAGMA index_list(user_apps)');
    for (final index in indexes.where((row) => row['unique'] == 1)) {
      final name = (index['name'] as String).replaceAll("'", "''");
      final indexedColumns = await db.rawQuery("PRAGMA index_info('$name')");
      if (indexedColumns.length == 1 &&
          indexedColumns.single['name'] == 'uuid') {
        return;
      }
    }
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_user_apps_uuid ON user_apps(uuid)',
    );
  }

  static Future<void> _migrateToVersion24(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 24: Adding includeInAIContext column to attachments table',
    );

    try {
      // Check if column already exists
      final tableInfo = await db.rawQuery('PRAGMA table_info(attachments)');
      final hasColumn = tableInfo.any(
        (column) => column['name'] == 'includeInAIContext',
      );

      if (!hasColumn) {
        await db.execute(
          'ALTER TABLE attachments ADD COLUMN includeInAIContext INTEGER NOT NULL DEFAULT 1',
        );
        LoggerService.info(
          'Successfully added includeInAIContext column to attachments table',
        );
      } else {
        LoggerService.info(
          'includeInAIContext column already exists in attachments table',
        );
      }
    } catch (e) {
      LoggerService.error('Error in migration to version 24: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion26(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute(_createMultiFunctionAppsTable);
  }

  static Future<void> _migrateToVersion29(
    Database db, {
    required bool isBackupMigration,
  }) async {
    // Ensure multi_function_apps table exists
    // We use a safe creation check
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='multi_function_apps'",
    );

    if (tables.isEmpty) {
      LoggerService.info('Creating multi_function_apps table (migration v29)');
      await db.execute(_createMultiFunctionAppsTable);
    } else {
      LoggerService.info(
        'multi_function_apps table already exists (migration v29)',
      );
    }
  }

  static Future<void> _migrateToVersion32(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 32: Adding metadata column to attachments table',
    );

    try {
      // Check if column already exists
      final tableInfo = await db.rawQuery('PRAGMA table_info(attachments)');
      final hasColumn = tableInfo.any((column) => column['name'] == 'metadata');

      if (!hasColumn) {
        await db.execute('ALTER TABLE attachments ADD COLUMN metadata TEXT');
        LoggerService.info(
          'Successfully added metadata column to attachments table',
        );
      } else {
        LoggerService.info(
          'metadata column already exists in attachments table',
        );
      }
    } catch (e) {
      LoggerService.error('Error in migration to version 32: $e', error: e);
      rethrow;
    }
  }

  // Migration to version 36: Fix notes_fts table by recreating it with FTS4
  // The original migration had issues (FTS5 with incorrect content_rowid option on iOS,
  // and mixed FTS4/FTS5 code paths). This migration drops and recreates the FTS table
  // using only FTS4 for cross-platform compatibility.
  static Future<void> _migrateToVersion36(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 33: Recreating notes_fts as FTS4',
    );

    try {
      // Drop existing triggers first (they may reference wrong FTS variant)
      await db.execute('DROP TRIGGER IF EXISTS notes_ai_insert');
      await db.execute('DROP TRIGGER IF EXISTS notes_ai_delete');
      await db.execute('DROP TRIGGER IF EXISTS notes_ai_update');

      // Drop existing FTS table (could be FTS4 or FTS5)
      await db.execute('DROP TABLE IF EXISTS notes_fts');

      // Create FTS4 table (universally supported)
      await db.execute('''
        CREATE VIRTUAL TABLE notes_fts USING fts4(
          title, 
          content
        );
      ''');

      // Repopulate notes_fts with existing data
      await db.execute('''
        INSERT INTO notes_fts(docid, title, content)
        SELECT rowid, title, content FROM notes;
      ''');

      // Create triggers for FTS4
      // INSERT Trigger
      await db.execute('''
        CREATE TRIGGER notes_ai_insert AFTER INSERT ON notes
        BEGIN
          INSERT INTO notes_fts(docid, title, content)
          VALUES(new.rowid, new.title, new.content);
        END;
      ''');

      // DELETE Trigger
      await db.execute('''
        CREATE TRIGGER notes_ai_delete AFTER DELETE ON notes
        BEGIN
          DELETE FROM notes_fts WHERE docid = old.rowid;
        END;
      ''');

      // UPDATE Trigger
      await db.execute('''
        CREATE TRIGGER notes_ai_update AFTER UPDATE ON notes
        BEGIN
          DELETE FROM notes_fts WHERE docid = old.rowid;
          INSERT INTO notes_fts(docid, title, content)
          VALUES(new.rowid, new.title, new.content);
        END;
      ''');

      LoggerService.info('Successfully recreated notes_fts table using FTS4');
    } catch (e) {
      LoggerService.error('Error in migration to version 33: $e', error: e);
      rethrow;
    }
  }

  static Future<void> _migrateToVersion41(
    Database db, {
    required bool isBackupMigration,
  }) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tag_images (
        tagId TEXT PRIMARY KEY,
        imagePath TEXT NOT NULL,
        FOREIGN KEY (tagId) REFERENCES tags(id) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _migrateToVersion42(
    Database db, {
    required bool isBackupMigration,
  }) async {
    final columns = await db.rawQuery('PRAGMA table_info(notes)');
    if (!columns.any((column) => column['name'] == 'metadata')) {
      await db.execute('ALTER TABLE notes ADD COLUMN metadata TEXT');
    }
  }

  // Migrate existing conversation data to new structure

  // Migration helper method to create initial revisions for existing apps

  // Validate that all note IDs in a conversation exist
  Future<List<String>> validateConversationNotes(String conversationId) async {
    final noteIds = await getConversationNoteIds(conversationId);
    if (noteIds.isEmpty) return [];

    final db = await database;
    // Efficiently check which IDs exist using a simple COUNT query
    final placeholders = List.filled(noteIds.length, '?').join(',');
    // M1.10: a tombstoned note counts as "missing" for this validation —
    // a deleted note is conceptually gone regardless of whether its row
    // still physically exists.
    final result = await db.rawQuery(
      'SELECT id FROM notes WHERE id IN ($placeholders) AND __deleted__ = 0',
      noteIds,
    );

    final existingNoteIds = result.map((row) => row['id'] as String).toSet();

    // Find missing note IDs
    final missingNoteIds = noteIds
        .where((noteId) => !existingNoteIds.contains(noteId))
        .toList();

    if (missingNoteIds.isNotEmpty) {
      LoggerService.warning(
        'Conversation $conversationId references missing notes: $missingNoteIds',
      );
    }

    return missingNoteIds;
  }

  // Insert a new note into the database
  Future<String> insertNote(Note note) async {
    final db = await database;
    final json = note.toJson();
    json['createdAt'] = note.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = note.updatedAt.millisecondsSinceEpoch;
    json['pinned'] = note.pinned ? 1 : 0;
    json['isArchived'] = note.isArchived ? 1 : 0;

    // Remove complex objects that can't be stored directly
    json.remove('subNotes');
    json.remove('tags');
    json.remove('attachmentPaths');

    await db.insert('notes', json);

    // Insert subnotes
    for (final subNote in note.subNotes) {
      await insertSubNote(subNote, note.id);
    }

    // Insert tags
    for (final tagName in note.tags) {
      await _linkNoteToTag(note.id, tagName);
    }

    // Insert attachments
    for (final attachmentPath in note.attachmentPaths) {
      // Check if path is relative (starts with 'attachments/')
      bool isRelativePath = attachmentPath.startsWith('attachments/');
      String finalPath = attachmentPath;

      if (!isRelativePath) {
        // Try to convert absolute path to relative if it's in the app dir
        final relativePath = await FileUtils.getRelativePath(attachmentPath);
        if (relativePath != null) {
          finalPath = relativePath;
          isRelativePath = true;
        }
      }

      await _insertAttachment(
        note.id,
        finalPath,
        isRelativePath: isRelativePath,
      );
    }

    _notifyNoteContentChanged(note.id);
    return note.id;
  }

  // Get all notes from the database
  Future<List<Note>> getAllNotes() async {
    final db = await database;
    LoggerService.info('Querying notes table...');
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
    SELECT 
      id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived, recurrenceRule,
      CASE WHEN length(CAST(content AS BLOB)) < 500000 THEN content ELSE NULL END as content,
      length(CAST(content AS BLOB)) as _contentLength
    FROM notes
    WHERE __deleted__ = 0
    ORDER BY pinned DESC, createdAt DESC
  ''');
    LoggerService.info('Found ${maps.length} notes in database');

    return await _batchLoadNotes(maps);
  }

  Future<List<Note>> _batchLoadNotes(
    List<Map<String, dynamic>> noteMaps,
  ) async {
    if (noteMaps.isEmpty) return [];

    final db = await database;
    final notes = <Note>[];
    final noteIds = noteMaps.map((m) => m['id'] as String).toList();

    // Batch fetch associated data
    // Chunking to avoid "too many variables" SQLite error (limit is usually 999)
    const chunkSize = 500;
    final Map<String, List<SubNote>> subNotesMap = {};
    final Map<String, List<String>> tagsMap = {};
    final Map<String, List<String>> attachmentsMap = {};

    for (var i = 0; i < noteIds.length; i += chunkSize) {
      final end = (i + chunkSize < noteIds.length)
          ? i + chunkSize
          : noteIds.length;
      final chunkIds = noteIds.sublist(i, end);
      final placeholders = List.filled(chunkIds.length, '?').join(',');

      // Fetch SubNotes. M1.11: `AND __deleted__ = 0` -- a tombstoned
      // subnote row still physically exists, so without this guard it
      // would remain visible.
      final subNoteResults = await readSyncRowsWhere(
        db,
        table: 'subnotes',
        columns: [
          'id',
          'noteId',
          'name',
          'createdAt',
          'isCompleted',
          'content',
        ],
        keyColumns: ['id'],
        where: 'noteId IN ($placeholders) AND __deleted__ = 0',
        whereArgs: chunkIds,
        orderBy: 'createdAt ASC',
      );

      for (final row in subNoteResults) {
        final noteId = row['noteId'] as String;
        final content = row['content'] as String? ?? '';

        final subNote = SubNote(
          id: row['id'] as String,
          name: row['name'] as String,
          content: content,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['createdAt'] as int,
          ),
          isCompleted: (row['isCompleted'] as int) == 1,
        );

        if (!subNotesMap.containsKey(noteId)) {
          subNotesMap[noteId] = [];
        }
        subNotesMap[noteId]!.add(subNote);
      }

      // Fetch Tags. M1.9: `t.__deleted__ = 0` is defense-in-depth, not a
      // behavior-changing fix — deleteTag/replaceTag always purge the
      // matching note_tags rows in the same operation as tombstoning the
      // tag, so a note_tags row should never reference a tombstoned tag
      // id in practice; this keeps the display query correct even if that
      // invariant is ever violated.
      final tagResults = await db.rawQuery('''
      SELECT nt.noteId, t.name
      FROM tags t
      JOIN note_tags nt ON t.id = nt.tagId
      WHERE nt.noteId IN ($placeholders) AND t.__deleted__ = 0
      ''', chunkIds);

      for (final row in tagResults) {
        final noteId = row['noteId'] as String;
        final tagName = row['name'] as String;

        if (!tagsMap.containsKey(noteId)) {
          tagsMap[noteId] = [];
        }
        tagsMap[noteId]!.add(tagName);
      }

      // Fetch Attachments. M1.11: `AND __deleted__ = 0` -- a tombstoned
      // attachment row still physically exists, so without this guard it
      // would remain visible.
      final attachmentResults = await db.query(
        'attachments',
        columns: ['noteId', 'filePath', 'isRelativePath'],
        where: 'noteId IN ($placeholders) AND __deleted__ = 0',
        whereArgs: chunkIds,
      );

      for (final row in attachmentResults) {
        final noteId = row['noteId'] as String;
        final filePath = row['filePath'] as String;
        final isRelativePath = (row['isRelativePath'] as int) == 1;

        String finalPath;
        if (isRelativePath) {
          finalPath = await FileUtils.getFullFilePath(filePath, true);
        } else {
          finalPath = filePath;
        }

        if (!attachmentsMap.containsKey(noteId)) {
          attachmentsMap[noteId] = [];
        }
        attachmentsMap[noteId]!.add(finalPath);
      }
    }

    // Assemble Notes
    for (final map in noteMaps) {
      final noteId = map['id'] as String;
      String content = map['content'] as String? ?? '';
      // A failed source read must abort the snapshot. Treating it as a
      // malformed model and skipping the note could make reference cleanup
      // delete mappings to a note that is still present in the database.
      if (content.isEmpty && (map['_contentLength'] as int? ?? 0) > 0) {
        content = await _readLargeString(db, 'notes', 'content', noteId);
      }
      try {
        final note = Note(
          id: noteId,
          title: map['title'] as String,
          content: content,
          type: map['type'] != null
              ? NoteType.values.firstWhere(
                  (e) => e.toString().split('.').last == map['type'],
                  orElse: () => NoteType.note,
                )
              : NoteType.note,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            map['createdAt'] as int,
          ),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            map['updatedAt'] as int,
          ),
          subNotes: subNotesMap[noteId] ?? [],
          tags: tagsMap[noteId] ?? [],
          attachmentPaths: attachmentsMap[noteId] ?? [],
          scheduledAt: map['scheduledAt'] as String?,
          completeBy: map['completeBy'] as String?,
          status: map['status'] != null
              ? _stringToTaskStatus(map['status'] as String)
              : null,
          completionPercentage: map['completionPercentage'] as double?,
          pinned: (map['pinned'] as int? ?? 0) == 1,
          isArchived: (map['isArchived'] as int? ?? 0) == 1,
          recurrenceRule: map['recurrenceRule'] as String?,
        );
        notes.add(note);
      } catch (e) {
        LoggerService.error(
          'Error assembling note with id ${map['id']}: $e',
          error: e,
        );
        // Skip corrupted notes
      }
    }

    LoggerService.info('Successfully batch loaded ${notes.length} notes');
    return notes;
  }

  // Clean up invalid note references from conversations
  Future<void> cleanupInvalidNoteReferences() async {
    final allNotes = await getAllNotes();
    final existingNoteIds = allNotes.map((note) => note.id).toSet();

    // Get all conversations
    final conversations = await getAllConversations();

    for (final conversation in conversations) {
      final currentNoteIds = await getConversationNoteIds(conversation.id);
      final validNoteIds = currentNoteIds
          .where((noteId) => existingNoteIds.contains(noteId))
          .toList();

      if (validNoteIds.length != currentNoteIds.length) {
        LoggerService.info(
          'Cleaning up invalid note references for conversation ${conversation.id}',
        );

        // Remove invalid mappings
        final invalidNoteIds = currentNoteIds
            .where((noteId) => !existingNoteIds.contains(noteId))
            .toList();
        for (final invalidNoteId in invalidNoteIds) {
          await deleteConversationNoteMapping(
            conversationId: conversation.id,
            noteId: invalidNoteId,
          );
        }
      }
    }
  }

  Future<List<Note>> getNotesByArchiveStatus({bool? isArchived}) async {
    final db = await database;
    String whereClause = 'WHERE __deleted__ = 0';
    List<dynamic> whereArgs = [];

    if (isArchived != null) {
      whereClause = 'WHERE __deleted__ = 0 AND isArchived = ?';
      whereArgs.add(isArchived ? 1 : 0);
    }

    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived,
        CASE WHEN length(CAST(content AS BLOB)) < 500000 THEN content ELSE NULL END as content,
        length(CAST(content AS BLOB)) as _contentLength
      FROM notes
      $whereClause
      ORDER BY pinned DESC, createdAt DESC
      ''', whereArgs);

    return await _batchLoadNotes(maps);
  }

  Future<List<Note>> getPinnedNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived,
        CASE WHEN length(CAST(content AS BLOB)) < 500000 THEN content ELSE NULL END as content,
        length(CAST(content AS BLOB)) as _contentLength
      FROM notes
      WHERE pinned = 1 AND isArchived = 0 AND __deleted__ = 0
      ORDER BY createdAt DESC
    ''');

    return await _batchLoadNotes(maps);
  }

  Future<List<Note>> getArchivedNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived,
        CASE WHEN length(CAST(content AS BLOB)) < 500000 THEN content ELSE NULL END as content,
        length(CAST(content AS BLOB)) as _contentLength
      FROM notes
      WHERE isArchived = 1 AND __deleted__ = 0
      ORDER BY createdAt DESC
    ''');

    return await _batchLoadNotes(maps);
  }

  Future<Note?> getNote(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT 
        id, title, type, createdAt, updatedAt, scheduledAt, completeBy, status, completionPercentage, pinned, isArchived, recurrenceRule,
        CASE WHEN length(CAST(content AS BLOB)) < 500000 THEN content ELSE NULL END as content,
        length(CAST(content AS BLOB)) as _contentLength
      FROM notes
      WHERE id = ? AND __deleted__ = 0
      ''',
      [id],
    );

    if (maps.isEmpty) return null;
    return await _mapToNote(maps.first);
  }

  // Get multiple notes by their IDs efficiently
  Future<List<Note>> getNotesByIds(List<String> noteIds) async {
    if (noteIds.isEmpty) return [];

    final db = await database;
    // Batched WHERE IN retrieval, chunked to avoid the "too many variables"
    // SQLite error (limit is usually 999) — same pattern as _batchLoadNotes.
    const chunkSize = 500;
    final maps = <Map<String, dynamic>>[];
    for (var i = 0; i < noteIds.length; i += chunkSize) {
      final end = (i + chunkSize < noteIds.length)
          ? i + chunkSize
          : noteIds.length;
      final chunkIds = noteIds.sublist(i, end);
      final placeholders = List.filled(chunkIds.length, '?').join(',');
      maps.addAll(
        await readSyncRowsWhere(
          db,
          table: 'notes',
          columns: [
            'id',
            'title',
            'type',
            'createdAt',
            'updatedAt',
            'scheduledAt',
            'completeBy',
            'status',
            'completionPercentage',
            'pinned',
            'isArchived',
            'recurrenceRule',
            'content',
          ],
          keyColumns: ['id'],
          where: 'id IN ($placeholders) AND __deleted__ = 0',
          whereArgs: chunkIds,
        ),
      );
    }

    return await _batchLoadNotes(maps);
  }

  /// Returns all non-archived notes that have the given tag.
  Future<List<Note>> getNotesByTag(String tagName) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT
        n.id, n.title, n.type, n.createdAt, n.updatedAt, n.scheduledAt, n.completeBy,
        n.status, n.completionPercentage, n.pinned, n.isArchived, n.recurrenceRule,
        CASE WHEN length(CAST(n.content AS BLOB)) < 500000 THEN n.content ELSE NULL END as content,
        length(CAST(n.content AS BLOB)) as _contentLength
      FROM notes n
      JOIN note_tags nt ON n.id = nt.noteId
      JOIN tags t ON nt.tagId = t.id
      WHERE t.name = ? AND t.__deleted__ = 0 AND n.isArchived = 0 AND n.__deleted__ = 0
      ORDER BY n.createdAt DESC
    ''',
      [tagName],
    );

    return await _batchLoadNotes(maps);
  }

  // M1.11 (design doc § Phased delivery, M1.11 — "subnotes + attachments
  // via updateNote/_persistNote"): the liveness check (the `notes` UPDATE
  // + `updatedRows == 0` guard) and every subnote/tag/attachment write
  // below now run inside one `db.transaction`, closing the race M1.10
  // disclosed here and in `_persistNote`/`deleteNote`'s own doc comments.
  // Before this milestone `updateNote` issued each statement as its own
  // separate, un-transactioned call; sqflite (`sqflite_common`'s
  // `DatabaseMixin.txnSynchronized`) grabs and releases its single
  // per-connection write lock (`_rawLock`) around each such call
  // individually when no transaction is active, so a concurrent
  // `deleteNote` (already `db.transaction`-wrapped since M1.10) could
  // acquire that lock and run to completion in the gap between this
  // function's liveness check and its child-row writes — a real,
  // exploitable race, not a theoretical one. Wrapping the whole thing in
  // `db.transaction` means this function now holds `_rawLock` for the
  // entire liveness-check-through-child-writes duration (`transaction()`
  // itself takes the lock before invoking its callback), so a concurrent
  // `deleteNote` transaction is fully serialized against this one: either
  // it commits first (tombstoning `notes`, so this transaction's own
  // liveness check then correctly sees `__deleted__ = 1` and bails before
  // writing any child row), or it runs after (this transaction's writes
  // already committed, and `deleteNote` cleans them up same as it would
  // for any other live note). This closes the race for every child table
  // this function itself writes -- `subnotes`/`attachments` (this
  // milestone's own scope) and, as a side effect of moving the `note_tags`
  // delete-and-reinsert into the same transaction (no logic change to
  // `note_tags` itself, still a real delete-then-reinsert, correct for an
  // OR-Set membership table), `note_tags` too. It does NOT close the
  // analogous race for `relationships`/`conversation_note_mapping`
  // (`updateNote` never touches either table, so there is no shared
  // transaction to close a race for), nor does it change anything about
  // `deleteNote`'s own internal atomicity (already transactional, M1.10).
  Future<void> updateNote(Note note) async {
    final db = await database;
    final json = note.toJson();
    json['createdAt'] = note.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = note.updatedAt.millisecondsSinceEpoch;
    json['pinned'] = note.pinned ? 1 : 0;
    json['isArchived'] = note.isArchived ? 1 : 0;

    // Remove complex objects that can't be stored directly
    json.remove('subNotes');
    json.remove('tags');
    json.remove('attachmentPaths');
    // Note objects loaded from the database never carry metadata (markers
    // etc. are written only via updateNoteMetadata), so writing
    // toJson()'s null here would wipe the column on every save.
    json.remove('metadata');

    await db.transaction((txn) async {
      // M1.10: `AND __deleted__ = 0` — without this, a tombstoned note's
      // row still physically exists, so `updatedRows` would be 1 even
      // though the note is meant to be gone, and the subnote/tag/
      // attachment writes below would incorrectly revive child rows for a
      // deleted note. This does not touch json's own `__deleted__` value
      // (the `Note` model has no such field, so `json` never carries one)
      // — it only guards which row this UPDATE is allowed to match.
      final updatedRows = await txn.update(
        'notes',
        json,
        where: 'id = ? AND __deleted__ = 0',
        whereArgs: [note.id],
      );
      if (updatedRows == 0) {
        // The note row is gone or tombstoned (e.g. deleted concurrently by
        // a plugin/agent). Writing subnotes/tags/attachments below would
        // create orphan child rows for a nonexistent/deleted note. Since
        // this whole function now runs inside one transaction (see the
        // doc comment above), reaching this branch means no child-row
        // write below has happened yet, so simply returning leaves nothing
        // to roll back.
        LoggerService.warning(
          'updateNote skipped: note ${note.id} no longer exists',
        );
        // The notify still happens -- after the transaction, at the bottom of
        // this method (the indexer self-heals by purging chunks of a note that
        // turns out to be gone). Deliberately NOT fired here: `return` leaves
        // the transaction CLOSURE, not the method, so a call here would be a
        // duplicate of that one -- and it would run the hook inside the write
        // transaction, where anything the listener does against the database
        // synchronously would deadlock on the write lock. Every other notify
        // site in this file is outside its transaction; this one matches them.
        return;
      }

      await diffAndPersistSubNotes(txn, note.id, note.subNotes);

      // Update tags: delete old links and create new ones. Unchanged
      // real-delete-then-reinsert (OR-Set membership table, out of this
      // milestone's scope) -- only now runs via `txn` instead of `db`.
      await txn.delete('note_tags', where: 'noteId = ?', whereArgs: [note.id]);
      for (final tagName in note.tags) {
        await _linkNoteToTag(note.id, tagName, executor: txn);
      }

      await diffAndPersistAttachments(txn, note.id, note.attachmentPaths);
    });

    _notifyNoteContentChanged(note.id);
  }

  /// Diffs [subNotes] (the full desired subnote list for [noteId] -- the
  /// caller's `Note.subNotes`) against the `subnotes` table by `id` and
  /// writes exactly what changed, instead of the blind delete-then-
  /// reinsert this replaced:
  ///
  ///  - an id already present as a LIVE row: UPDATEd in place. This is the
  ///    case a naive "insert only if the id is missing" diff would get
  ///    wrong -- an existing subnote's content/name/isCompleted edits must
  ///    still be applied, not skipped just because the id already exists.
  ///  - an id present as a TOMBSTONED row: resurrected in place
  ///    (`__deleted__` cleared, fields overwritten with the incoming
  ///    values) rather than treated as a brand-new insert. Subnote ids are
  ///    stable across edits (`NoteModificationService._buildUpdatedNote`
  ///    never mints a new id for a kept subnote -- only a genuinely new
  ///    subnote gets a fresh uuid), so the same id reappearing in
  ///    [subNotes] means the same logical subnote is meant to exist again
  ///    (e.g. an undo of a removal, or two concurrent modifications where
  ///    one drops an id and another still references it). Reviving the
  ///    original row keeps `id` a single continuous identity instead of
  ///    letting one id refer to two disjoint "incarnations" over time --
  ///    every other id-keyed lookup in this codebase already assumes that,
  ///    and so will any future CRDT dot-tracking keyed by row id. Matches
  ///    the resurrect choice [diffAndPersistAttachments] makes below, for
  ///    consistency between the two tables this milestone converts.
  ///  - an id absent from the table entirely: INSERTed fresh.
  ///  - an existing LIVE id no longer present in [subNotes]: tombstoned
  ///    (`__deleted__ = 1`), never physically deleted.
  ///
  /// Shared by `updateNote` (this function's caller) and
  /// `NoteModificationService._persistNote` -- both call this single
  /// implementation instead of maintaining independently-duplicated diff
  /// logic, closing off the drift risk that motivated M1.11 requiring a
  /// test proving the two call sites behave identically (matches the
  /// `getOrCreateLiveTagId`/`findLiveTagByName` precedent M1.3 already
  /// established for the same reason on the tags side).
  ///
  /// Defensive within-pass dedup: if [subNotes] itself contains the same
  /// `id` more than once (never produced by today's callers -- `Note`
  /// objects loaded from the database can't have duplicate subnote ids,
  /// and `_buildUpdatedNote` never mints a colliding one -- but nothing
  /// in this function's own contract rules it out for a future caller),
  /// only the FIRST occurrence is written; later ones are skipped
  /// entirely. Without this, a second occurrence with an id not yet in
  /// [liveIds]/[tombstonedIds] would hit the INSERT branch and violate
  /// `subnotes.id`'s PRIMARY KEY constraint, throwing and rolling back
  /// the whole transaction -- a loud failure, not silent corruption, but
  /// still an unhandled case this function should defend against on its
  /// own terms rather than relying on every caller to pre-dedupe.
  ///
  /// [db] must be the same transaction executor the caller uses for the
  /// note's own liveness check, so this diff and that check commit or roll
  /// back together.
  static Future<void> diffAndPersistSubNotes(
    DatabaseExecutor db,
    String noteId,
    List<SubNote> subNotes,
  ) async {
    final existingRows = await db.query(
      'subnotes',
      columns: ['id', '__deleted__'],
      where: 'noteId = ?',
      whereArgs: [noteId],
    );
    final liveIds = <String>{};
    final tombstonedIds = <String>{};
    for (final row in existingRows) {
      final id = row['id'] as String;
      if ((row['__deleted__'] as int? ?? 0) == 0) {
        liveIds.add(id);
      } else {
        tombstonedIds.add(id);
      }
    }

    final incomingIds = <String>{};
    final processedIds = <String>{};
    for (final subNote in subNotes) {
      // Defensive dedup -- see doc comment above.
      if (!processedIds.add(subNote.id)) continue;
      incomingIds.add(subNote.id);
      final fields = {
        'name': subNote.name,
        'content': subNote.content,
        'createdAt': subNote.createdAt.millisecondsSinceEpoch,
        'isCompleted': subNote.isCompleted ? 1 : 0,
      };

      if (liveIds.contains(subNote.id)) {
        await db.update(
          'subnotes',
          fields,
          where: 'id = ?',
          whereArgs: [subNote.id],
        );
      } else if (tombstonedIds.contains(subNote.id)) {
        await db.update(
          'subnotes',
          {...fields, '__deleted__': 0},
          where: 'id = ?',
          whereArgs: [subNote.id],
        );
      } else {
        await db.insert('subnotes', {
          'id': subNote.id,
          'noteId': noteId,
          ...fields,
        });
      }
    }

    for (final id in liveIds.difference(incomingIds)) {
      await db.update(
        'subnotes',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  /// Diffs [attachmentPaths] (the full desired attachment-path list for
  /// [noteId], as `Note.attachmentPaths` holds them -- paths only, no id)
  /// against the `attachments` table and writes exactly what changed. The
  /// diff itself is necessarily keyed by `filePath`, the only identity
  /// `Note.attachmentPaths` carries, but every row *mutation* below targets
  /// `attachments.id` once the matching id is known from the lookup this
  /// function does up front -- `id`, not `filePath`, is this table's own
  /// addressable identity for tombstoning (`filePath` has no uniqueness
  /// constraint of its own, unlike a subnote's `id`).
  ///
  ///  - a path matching a LIVE row: no-op, matches prior "attachment
  ///    exists, keep it" behavior exactly.
  ///  - a path matching a TOMBSTONED row: resurrected in place
  ///    (`__deleted__` cleared on that row's own id) rather than inserted
  ///    as a new row with a fresh id. Reusing the id matters here for a
  ///    reason subnotes don't have: other tables reference an attachment
  ///    by id (`note_annotations.attachment_id`, and marker metadata saved
  ///    onto `attachments.metadata` via `NoteMarkerService`) -- minting a
  ///    fresh id for a "new" row representing the same file would silently
  ///    orphan any such reference instead of reconnecting it. Matches the
  ///    resurrect choice [diffAndPersistSubNotes] makes above, for
  ///    consistency between the two tables this milestone converts.
  ///  - a path matching neither: inserted fresh, same as before.
  ///  - an existing LIVE row whose path is no longer present: tombstoned
  ///    (`__deleted__ = 1`, targeted by id), never physically deleted.
  ///
  /// Shared by `updateNote` (this function's caller) and
  /// `NoteModificationService._persistNote`, for the same reason
  /// [diffAndPersistSubNotes] is.
  ///
  /// Defensive within-pass dedup: if [attachmentPaths] itself contains the
  /// same (normalized) path more than once (today's UI call sites already
  /// dedupe before calling `updateNote`, so this isn't currently
  /// reachable, but nothing in this function's own contract rules it out
  /// for a future caller), only the FIRST occurrence is written; later
  /// ones are skipped entirely. Without this, `livePathToId`/
  /// `tombstonedPathToId` -- snapshotted once from the table before this
  /// loop runs, never updated for a row this same pass just inserted --
  /// would not recognize the second occurrence of a genuinely-new path as
  /// already handled, so it would hit the "insert fresh" branch a second
  /// time and silently create a second live row for the same
  /// `(noteId, filePath)`, whose id would then be permanently unreachable
  /// to every future diff pass (neither `livePathToId` nor
  /// `tombstonedPathToId` is keyed to find it, since both are keyed by
  /// `filePath` and the *other*, first-inserted row already owns that
  /// key). Matches the analogous dedup guard [diffAndPersistSubNotes] has.
  static Future<void> diffAndPersistAttachments(
    DatabaseExecutor db,
    String noteId,
    List<String> attachmentPaths,
  ) async {
    final existingRows = await db.query(
      'attachments',
      columns: ['id', 'filePath', 'includeInAIContext', '__deleted__'],
      where: 'noteId = ?',
      whereArgs: [noteId],
    );

    final livePathToId = <String, String>{};
    final tombstonedPathToId = <String, String>{};
    // Keyed like the original blind "existingContextMap" was (by whatever
    // path string was on the row, live or tombstoned) -- preserved for
    // parity with the pre-M1.11 fallback lookup in the "insert fresh"
    // branch below, which checks the raw (unnormalized) attachmentPath as
    // well as the normalized one.
    final includeInAIContextByPath = <String, bool>{};
    for (final row in existingRows) {
      final path = row['filePath'] as String;
      final id = row['id'] as String;
      includeInAIContextByPath[path] = (row['includeInAIContext'] as int?) != 0;
      if ((row['__deleted__'] as int? ?? 0) == 0) {
        livePathToId[path] = id;
      } else {
        tombstonedPathToId[path] = id;
      }
    }

    final pathsToKeep = <String>{};
    final processedPaths = <String>{};
    for (final attachmentPath in attachmentPaths) {
      var isRelativePath = attachmentPath.startsWith('attachments/');
      var finalPath = attachmentPath;
      if (!isRelativePath) {
        final relativePath = await FileUtils.getRelativePath(attachmentPath);
        if (relativePath != null) {
          finalPath = relativePath;
          isRelativePath = true;
        }
      }

      // Defensive dedup -- see doc comment above. Keyed on the normalized
      // path, since two raw entries (e.g. a relative and an equivalent
      // absolute form of the same file) can normalize to the same
      // `finalPath`.
      if (!processedPaths.add(finalPath)) continue;

      if (livePathToId.containsKey(finalPath)) {
        // Already live -- no-op, matches prior "keep it" behavior.
        pathsToKeep.add(finalPath);
      } else if (tombstonedPathToId.containsKey(finalPath)) {
        // Resurrect the existing row by id -- see doc comment above. Every
        // other column (fileName/fileType/includeInAIContext/metadata/
        // isRelativePath) is left exactly as the row already has it; only
        // the tombstone flag flips.
        await db.update(
          'attachments',
          {'__deleted__': 0},
          where: 'id = ?',
          whereArgs: [tombstonedPathToId[finalPath]],
        );
        pathsToKeep.add(finalPath);
      } else {
        final includeInAIContext =
            includeInAIContextByPath[finalPath] ??
            includeInAIContextByPath[attachmentPath] ??
            true;
        await _insertAttachmentRow(
          db,
          noteId,
          finalPath,
          isRelativePath: isRelativePath,
          includeInAIContext: includeInAIContext,
        );
        pathsToKeep.add(finalPath);
      }
    }

    // Existing LIVE paths no longer present: tombstone by id, not path.
    for (final entry in livePathToId.entries) {
      if (!pathsToKeep.contains(entry.key)) {
        await db.update(
          'attachments',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: [entry.value],
        );
      }
    }
  }

  /// Updates the includeInAIContext flag for a specific attachment
  Future<void> updateAttachmentAIContext(
    String noteId,
    String filePath,
    bool include,
  ) async {
    final db = await database;
    await db.update(
      'attachments',
      {'includeInAIContext': include ? 1 : 0},
      where: 'noteId = ? AND filePath = ?',
      whereArgs: [noteId, filePath],
    );
    _notifyNoteContentChanged(noteId);
  }

  /// Updates the metadata JSON for a specific attachment
  Future<void> updateAttachmentMetadata(
    String attachmentId,
    Map<String, dynamic>? metadata,
  ) async {
    final db = await database;
    // Read the old row up front (only when a hook is registered, so the
    // common path stays a single UPDATE): if the only difference is
    // lastViewedPage, this is a page-view bookmark, not indexable content —
    // skip the indexer notification so page flips never trigger re-chunking.
    String? noteIdToNotify;
    if (onNoteContentChanged != null) {
      final rows = await db.query(
        'attachments',
        columns: ['noteId', 'metadata'],
        where: 'id = ?',
        whereArgs: [attachmentId],
      );
      if (rows.isNotEmpty) {
        Map<String, dynamic>? oldMetadata;
        final raw = rows.first['metadata'] as String?;
        if (raw != null && raw.isNotEmpty) {
          try {
            oldMetadata = jsonDecode(raw) as Map<String, dynamic>?;
          } catch (_) {
            oldMetadata = null;
          }
        }
        if (!_metadataEqualIgnoringLastViewedPage(oldMetadata, metadata)) {
          noteIdToNotify = rows.first['noteId'] as String;
        }
      }
    }
    await db.update(
      'attachments',
      {'metadata': metadata != null ? jsonEncode(metadata) : null},
      where: 'id = ?',
      whereArgs: [attachmentId],
    );
    if (noteIdToNotify != null) {
      _notifyNoteContentChanged(noteIdToNotify);
    }
  }

  /// Whether two attachment metadata maps are deep-equal once the
  /// lastViewedPage bookmark (not indexable content) is ignored.
  static bool _metadataEqualIgnoringLastViewedPage(
    Map<String, dynamic>? a,
    Map<String, dynamic>? b,
  ) {
    Map<String, dynamic> strip(Map<String, dynamic>? m) {
      final copy = Map<String, dynamic>.from(m ?? const {});
      copy.remove('lastViewedPage');
      return copy;
    }

    return _jsonDeepEquals(strip(a), strip(b));
  }

  static bool _jsonDeepEquals(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_jsonDeepEquals(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_jsonDeepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// Updates the metadata JSON for a specific note.
  ///
  /// M1.10: `AND __deleted__ = 0` -- a tombstoned note's row still
  /// physically exists, so without this guard a deleted note's metadata
  /// would remain writable.
  Future<void> updateNoteMetadata(
    String noteId,
    Map<String, dynamic>? metadata,
  ) async {
    final db = await database;
    await db.update(
      'notes',
      {'metadata': metadata != null ? jsonEncode(metadata) : null},
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [noteId],
    );
    // Metadata carries index policy (searchIndex.exclude), so the indexer
    // must re-evaluate the note.
    _notifyNoteContentChanged(noteId);
  }

  /// Gets the metadata JSON for a specific note.
  ///
  /// M1.10: `AND __deleted__ = 0` -- a tombstoned note's row still
  /// physically exists, so without this guard a deleted note's metadata
  /// would remain readable.
  Future<Map<String, dynamic>?> getNoteMetadata(String noteId) async {
    final db = await database;
    final rows = await readSyncRowsWhere(
      db,
      table: 'notes',
      columns: ['metadata'],
      keyColumns: ['id'],
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [noteId],
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['metadata'] as String?;
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ── NoteAnnotation CRUD ─────────────────────────────────────────────────

  Future<void> saveNoteAnnotation(NoteAnnotation annotation) async {
    final db = await database;
    // ConflictAlgorithm.replace can re-parent an existing annotation to a
    // different note/attachment; resolve the current owner BEFORE the write
    // so the old owner can be reindexed too (only when a hook is listening).
    String? previousOwnerNoteId;
    if (onNoteContentChanged != null) {
      final existing = await getNoteAnnotation(annotation.id);
      if (existing != null) {
        previousOwnerNoteId = await _resolveAnnotationNoteId(existing);
      }
    }
    await db.insert(
      'note_annotations',
      annotation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (onNoteContentChanged != null) {
      final owningNoteId = await _resolveAnnotationNoteId(annotation);
      if (owningNoteId != null) _notifyNoteContentChanged(owningNoteId);
      if (previousOwnerNoteId != null && previousOwnerNoteId != owningNoteId) {
        _notifyNoteContentChanged(previousOwnerNoteId);
      }
    }
  }

  /// Owning note of an annotation: direct note_id, or the note of the
  /// attachment it is scoped to.
  Future<String?> _resolveAnnotationNoteId(NoteAnnotation annotation) async {
    if (annotation.noteId != null) return annotation.noteId;
    final attachmentId = annotation.attachmentId;
    if (attachmentId == null) return null;
    final db = await database;
    final rows = await db.query(
      'attachments',
      columns: ['noteId'],
      where: 'id = ?',
      whereArgs: [attachmentId],
    );
    if (rows.isEmpty) return null;
    return rows.first['noteId'] as String;
  }

  Future<NoteAnnotation?> getNoteAnnotation(String id) async {
    final db = await database;
    final rows = await db.query(
      'note_annotations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return NoteAnnotation.fromMap(rows.first);
  }

  Future<List<NoteAnnotation>> getNoteAnnotationsForNote(String noteId) async {
    final db = await database;
    final rows = await db.query(
      'note_annotations',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'created_at DESC',
    );
    return rows.map(NoteAnnotation.fromMap).toList();
  }

  Future<List<NoteAnnotation>> getNoteAnnotationsForAttachment(
    String attachmentId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'note_annotations',
      where: 'attachment_id = ?',
      whereArgs: [attachmentId],
      orderBy: 'created_at DESC',
    );
    return rows.map(NoteAnnotation.fromMap).toList();
  }

  Future<void> deleteNoteAnnotation(String id) async {
    final db = await database;
    // Resolve the owning note before the row disappears (only when a hook
    // is listening).
    String? owningNoteId;
    if (onNoteContentChanged != null) {
      final annotation = await getNoteAnnotation(id);
      if (annotation != null) {
        owningNoteId = await _resolveAnnotationNoteId(annotation);
      }
    }
    await db.delete('note_annotations', where: 'id = ?', whereArgs: [id]);
    if (owningNoteId != null) _notifyNoteContentChanged(owningNoteId);
  }

  // ────────────────────────────────────────────────────────────────────────

  /// Updates just the lastViewedPage in attachment metadata
  /// Preserves other metadata fields
  Future<void> updateLastViewedPage(String attachmentId, int pageNumber) async {
    try {
      // Ensure metadata column exists
      final db = await database;
      final tableInfo = await db.rawQuery('PRAGMA table_info(attachments)');
      final hasColumn = tableInfo.any((column) => column['name'] == 'metadata');
      if (!hasColumn) {
        LoggerService.warning(
          'metadata column missing from attachments table - applying migration',
        );
        await db.execute('ALTER TABLE attachments ADD COLUMN metadata TEXT');
      }

      final attachment = await getAttachmentById(attachmentId);
      if (attachment == null) return;

      final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
      metadata['lastViewedPage'] = pageNumber;

      await updateAttachmentMetadata(attachmentId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to update last viewed page: $e');
    }
  }

  /// Gets an attachment by its ID.
  ///
  /// M1.11: `AND __deleted__ = 0` -- a tombstoned attachment row still
  /// physically exists, so without this guard it would remain readable.
  Future<Attachment?> getAttachmentById(String attachmentId) async {
    final db = await database;
    final maps = await readSyncRowsWhere(
      db,
      table: 'attachments',
      columns: [
        'id',
        'noteId',
        'filePath',
        'fileName',
        'fileType',
        'createdAt',
        'isRelativePath',
        'includeInAIContext',
        'metadata',
      ],
      keyColumns: ['id'],
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [attachmentId],
    );
    if (maps.isEmpty) return null;
    return Attachment.fromDatabase(maps.first);
  }

  /// Gets all attachments for a specific note.
  ///
  /// M1.11: `AND __deleted__ = 0` -- a tombstoned attachment row still
  /// physically exists, so without this guard it would remain visible.
  Future<List<Attachment>> getAttachmentsForNote(String noteId) async {
    final db = await database;
    final maps = await readSyncRowsWhere(
      db,
      table: 'attachments',
      columns: [
        'id',
        'noteId',
        'filePath',
        'fileName',
        'fileType',
        'createdAt',
        'isRelativePath',
        'includeInAIContext',
        'metadata',
      ],
      keyColumns: ['id'],
      where: 'noteId = ? AND __deleted__ = 0',
      whereArgs: [noteId],
    );

    return List.generate(maps.length, (i) {
      return Attachment.fromDatabase(maps[i]);
    });
  }

  // M1.10 (design doc § Phased delivery, M1.10 — "notes (deleteNote
  // only). Must land together with (not strictly before) M1.11"):
  // `notes` is now tombstone-only, never a real SQL DELETE. Before this
  // milestone, the trailing real `DELETE FROM notes` relied entirely on
  // `ON DELETE CASCADE` to clean up `subnotes`/`attachments`/`note_tags`/
  // `relationships`/`conversation_note_mapping` — none of those had an
  // explicit delete statement in this function; they were purely cascade
  // side effects. Cascades only fire on a real `DELETE`, so tombstoning
  // `notes` alone would silently stop every one of those five cleanups.
  // Each is therefore now replaced with an explicit statement below,
  // classified per the design doc's own Entity-table vs. OR-Set-table
  // split (M1.7-era scoping pass):
  //
  //  - `conversation_note_mapping`: OR-Set membership row — real deletion
  //    is correct. Already handled by the existing
  //    `deleteNoteConversationMappings` call (unchanged in shape, just now
  //    also runs inside this function's transaction).
  //  - `note_tags`: OR-Set membership row — real deletion is correct
  //    (matches deleteTag/replaceTag's own note_tags cleanup, M1.9).
  //  - `relationships`: already tombstoned (M1.8) — reuses
  //    `deleteRelationshipsForNote`'s own where clause via its `executor`
  //    parameter rather than duplicating it here.
  //  - `subnotes`/`attachments`: from M1.10 through M1.12 these were
  //    **deliberately still real-deleted here, not tombstoned**, even
  //    after M1.11 gave both tables their own `__deleted__` column.
  //    M1.11's own scope was `updateNote`/`_persistNote`'s diff logic
  //    specifically, not this function; the design doc's own "What NOT to
  //    touch" boundary for that milestone left `deleteNote` untouched
  //    beyond closing the race documented below. **M1.13 step 0 closed
  //    this gap**: both are now tombstone writes too (`{'__deleted__': 1}`
  //    via `txn.update`, scoped by `noteId`), a load-bearing prerequisite
  //    for M1.13 adding `subnotes`/`attachments` to
  //    `_hardDeleteGuardedTables` -- a real delete here would otherwise
  //    trip that guard's own `BEFORE DELETE RAISE(ABORT)` trigger on the
  //    very next `deleteNote` call against a note with children. This also
  //    resolves the tombstone-lifecycle non-uniformity this comment used
  //    to flag (a subnote/attachment row tombstoned by an ordinary note
  //    edit vs. hard-deleted when its whole parent note goes) -- both
  //    paths now leave a tombstone, not a mix of the two.
  //
  // Wrapped in a transaction (this function did not use one before): a
  // partial failure partway through this explicit cleanup would now be
  // worse than a partial failure under the old real-delete-and-cascade
  // version, which SQLite guaranteed atomic. Every statement below must
  // therefore commit or roll back together.
  //
  // **M1.10-disclosed race with `updateNote`/`_persistNote`, narrowed by
  // M1.11 -- closed for `subnotes`/`attachments`/`note_tags`, not for
  // `relationships`/`conversation_note_mapping`.** M1.10 recorded a race
  // here: this function's own transaction only protected itself, not
  // against interleaving with a concurrent `updateNote`/`_persistNote`
  // call, which was not transactional around its own liveness check +
  // child-row writes (`updateNote` issued each statement as a separate,
  // un-transactioned call; `_persistNote` ran inside its caller's
  // transaction, which -- per sqflite's own single-writer-lock semantics,
  // see `updateNote`'s doc comment in this file -- likely already
  // serialized it against this function even before M1.11, though that
  // was not verified at the time). M1.11 wrapped `updateNote`'s entire
  // liveness-check-through-child-writes sequence in one `db.transaction`,
  // which sqflite fully serializes against this function's own
  // transaction (both compete for the same per-connection write lock for
  // their whole duration, not just per-statement) -- so for every child
  // table `updateNote`/`_persistNote` themselves write (`subnotes`,
  // `attachments`, and `note_tags` as an incidental side effect of now
  // sharing the same transaction), the race is closed: whichever of this
  // function or `updateNote`/`_persistNote` commits first is fully visible
  // to the other before it proceeds. This does NOT close the analogous
  // race for `relationships`/`conversation_note_mapping` -- `updateNote`/
  // `_persistNote` never write either table (relationship/link changes go
  // through the separately-transactional `_applyLinkModifications`, M1.8),
  // so there is no shared transaction between this function and anything
  // that would race it there; that residual, to the (likely small) extent
  // it exists, remains open and out of scope for both M1.10 and M1.11.
  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      // OR-Set membership rows — real deletion is correct for both.
      await deleteNoteConversationMappings(id, executor: txn);
      await txn.delete('note_tags', where: 'noteId = ?', whereArgs: [id]);

      // Already-tombstoned entity table (M1.8) — reuse its own delete
      // function rather than duplicating the where clause.
      await deleteRelationshipsForNote(id, executor: txn);

      // M1.13 step 0: tombstone writes, not real deletes. `deleteNote` was
      // the last remaining real-delete call site against `subnotes`/
      // `attachments` (deliberately deferred by M1.10/M1.11, since
      // rewriting this whole-note cascade was out of scope for the
      // per-edit diff rewrite M1.11 did via
      // diffAndPersistSubNotes/diffAndPersistAttachments). This must land
      // before M1.13 can add either table to `_hardDeleteGuardedTables` —
      // otherwise the new guard trigger would abort this very function on
      // its next invocation against any note with children. Shape matches
      // the tombstone writes those two diff helpers already use
      // (`{'__deleted__': 1}` via `txn.update`), just scoped by `noteId`
      // instead of a single row `id` since every child row is being
      // removed here, not diffed against a new set.
      await txn.update(
        'subnotes',
        {'__deleted__': 1},
        where: 'noteId = ?',
        whereArgs: [id],
      );
      await txn.update(
        'attachments',
        {'__deleted__': 1},
        where: 'noteId = ?',
        whereArgs: [id],
      );

      // The note itself: tombstone write, not a real delete (M1.10).
      await txn.update(
        'notes',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    });

    _notifyNoteDeleted(id);
  }

  // SubNotes CRUD
  Future<String> insertSubNote(SubNote subNote, String noteId) async {
    final db = await database;
    final json = subNote.toJson();
    json['noteId'] = noteId;
    json['createdAt'] = subNote.createdAt.millisecondsSinceEpoch;
    json['isCompleted'] = subNote.isCompleted ? 1 : 0;
    await db.insert('subnotes', json);
    _notifyNoteContentChanged(noteId);
    return subNote.id;
  }

  // M1.11: `AND __deleted__ = 0` -- a tombstoned subnote row still
  // physically exists, so without this guard it would remain visible.
  Future<List<SubNote>> getSubNotes(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT
        id, noteId, name, createdAt, isCompleted,
        CASE WHEN length(CAST(content AS BLOB)) < 500000 THEN content ELSE NULL END as content,
        length(CAST(content AS BLOB)) as _contentLength
      FROM subnotes
      WHERE noteId = ? AND __deleted__ = 0
      ORDER BY createdAt ASC
      ''',
      [noteId],
    );

    final List<SubNote> subNotes = [];
    for (final map in maps) {
      String content = map['content'] as String? ?? '';
      if (content.isEmpty && (map['_contentLength'] as int? ?? 0) > 0) {
        content = await _readLargeString(
          db,
          'subnotes',
          'content',
          map['id'] as String,
        );
      }

      subNotes.add(
        SubNote(
          id: map['id'],
          name: map['name'],
          content: content,
          createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt']),
          isCompleted: map['isCompleted'] == 1,
        ),
      );
    }
    return subNotes;
  }

  // Tags CRUD
  Future<String> insertTag(Tag tag) async {
    final db = await database;
    final json = tag.toJson();
    json['createdAt'] = tag.createdAt.millisecondsSinceEpoch;
    json.remove('conversationUsageCount');
    await db.insert('tags', json);
    return tag.id;
  }

  Future<List<Tag>> getAllTags() async {
    final db = await database;
    // Use GROUP BY to calculate usage count on the fly, sorted alphabetically
    // M1.9: filtered to live tags only — the main tag-listing read path,
    // now that deleteTag/replaceTag leave a tombstoned `tags` row behind
    // instead of removing it.
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT
        t.id,
        t.name,
        t.color,
        t.createdAt,
        COALESCE(COUNT(DISTINCT nt.noteId), 0) as noteUsageCount,
        COALESCE(COUNT(DISTINCT ct.conversationId), 0) as conversationUsageCount
      FROM tags t
      LEFT JOIN note_tags nt ON t.id = nt.tagId
      LEFT JOIN conversation_tags ct ON t.id = ct.tagId
      WHERE t.__deleted__ = 0
      GROUP BY t.id, t.name, t.color, t.createdAt
      ORDER BY t.name ASC
    ''');

    return List.generate(maps.length, (i) {
      return Tag(
        id: maps[i]['id'],
        name: maps[i]['name'],
        color: maps[i]['color'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
        usageCount: (maps[i]['noteUsageCount'] as num?)?.toInt() ?? 0,
        conversationUsageCount:
            (maps[i]['conversationUsageCount'] as num?)?.toInt() ?? 0,
      );
    });
  }

  Future<void> deleteTag(String tagName) async {
    final db = await database;

    // M1.9: resolve via the shared live-tag lookup, not a bare
    // `WHERE name = ?`. This was the one divergent unguarded tag-name
    // lookup M1.3's consolidation pass didn't touch (it was harmless at
    // the time, since deleteTag itself still did a real DELETE — no
    // tombstoned row could ever stick around to collide with a later
    // live tag of the same name). Now that the delete below leaves a
    // tombstoned row behind, an unguarded match could pick a stale,
    // already-tombstoned row over the actual live tag the user means to
    // delete (design doc M1.9; see findLiveTagByName's own doc comment).
    final tag = await findLiveTagByName(db, tagName);

    if (tag == null) return; // Tag doesn't exist (or is already tombstoned)

    final tagId = tag['id'] as String;

    // Collect the owning notes BEFORE the join rows disappear: the tag name
    // is part of each note's indexed meta chunk, so the indexer must
    // re-chunk them or the deleted tag stays searchable forever.
    List<String> affectedNoteIds = const [];
    if (onNoteContentChanged != null) {
      final noteTagRows = await db.query(
        'note_tags',
        columns: ['noteId'],
        where: 'tagId = ?',
        whereArgs: [tagId],
      );
      affectedNoteIds = [
        for (final row in noteTagRows) row['noteId'] as String,
      ];
    }

    // Delete all note-tag relationships for this tag. Membership rows in
    // an OR-Set table — real deletion is the correct local representation
    // of a set_remove under this design's CRDT model, unaffected by this
    // milestone (design doc M1.9 / § Architecture 1).
    await db.delete('note_tags', where: 'tagId = ?', whereArgs: [tagId]);
    await db.delete(
      'conversation_tags',
      where: 'tagId = ?',
      whereArgs: [tagId],
    );

    // M1.9: tombstone the tag row instead of deleting it — reuses M1.3's
    // `__deleted__` column; `tag_images`/`tag_ai_configs` derive
    // visibility from this flag at read time rather than getting cascaded
    // away (they have no independent identity/tombstone of their own).
    await db.update(
      'tags',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [tagId],
    );

    for (final noteId in affectedNoteIds) {
      _notifyNoteContentChanged(noteId);
    }
  }

  /// Set or update the image for a tag.
  Future<void> setTagImage(String tagId, String imagePath) async {
    final db = await database;
    await db.insert('tag_images', {
      'tagId': tagId,
      'imagePath': imagePath,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Remove the image for a tag.
  Future<void> removeTagImage(String tagId) async {
    final db = await database;
    await db.delete('tag_images', where: 'tagId = ?', whereArgs: [tagId]);
  }

  /// Get all tag images as a map of tagId -> imagePath.
  ///
  /// M1.9: `tag_images` has no independent identity/tombstone of its own
  /// (`tagId` is its actual primary key) — it derives visibility from its
  /// owning tag's `__deleted__` state (design doc § Architecture 10). Now
  /// that `deleteTag`/`replaceTag` tombstone rather than delete `tags`,
  /// the `ON DELETE CASCADE` from `tags` into `tag_images` never fires for
  /// a tombstoned tag, so the row physically persists; this JOIN is what
  /// keeps it invisible.
  Future<Map<String, String>> getAllTagImages() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT ti.tagId, ti.imagePath
      FROM tag_images ti
      JOIN tags t ON t.id = ti.tagId
      WHERE t.__deleted__ = 0
    ''');
    return {
      for (final row in rows)
        row['tagId'] as String: row['imagePath'] as String,
    };
  }

  /// Get the image path for a specific tag. Returns null once the owning
  /// tag is tombstoned, even though the `tag_images` row itself still
  /// physically exists — see [getAllTagImages]'s doc comment.
  Future<String?> getTagImage(String tagId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT ti.imagePath
      FROM tag_images ti
      JOIN tags t ON t.id = ti.tagId
      WHERE ti.tagId = ? AND t.__deleted__ = 0
    ''',
      [tagId],
    );
    if (rows.isEmpty) return null;
    return rows.first['imagePath'] as String;
  }

  Future<void> replaceTag(String oldTagName, String newTagName) async {
    final db = await database;

    // Get the old tag ID. M1.3: matched against the LIVE tag only (see
    // findLiveTagByName) — this was previously a bare `WHERE name = ?`,
    // one of the three independently-duplicated unguarded name lookups
    // this milestone's schema change fixes (design doc § Architecture 10,
    // "flagging replaceTag's own two additional unguarded lookups"). A
    // tombstoned tag sharing the old name is no longer "the same tag" to
    // rename from.
    final oldTag = await findLiveTagByName(db, oldTagName);

    if (oldTag == null) return; // Old (live) tag doesn't exist

    final oldTagId = oldTag['id'] as String;

    // Check if a live tag with the new name already exists.
    final newTag = await findLiveTagByName(db, newTagName);

    // M2.4 (design doc § Architecture 11.3's own named follow-up): whether
    // this call is a genuine MERGE into an already-live tag (`newTag !=
    // null` below) or a plain RENAME (`newTag == null`: no live tag
    // currently holds `newTagName`, so a brand-new row is minted for it)
    // determines whether the old tag's eventual tombstone also gets
    // `redirectTarget` populated -- see the write below.
    final isRealMerge = newTag != null;

    String newTagId;
    if (newTag == null) {
      // Create new tag preserving original color when available.
      final newTagModel = Tag(
        id: _uuid.v4(),
        name: newTagName,
        color: oldTag['color'] as String,
        createdAt: DateTime.now(),
      );
      final json = newTagModel.toJson();
      json['createdAt'] = newTagModel.createdAt.millisecondsSinceEpoch;
      json.remove('conversationUsageCount');
      json['__deleted__'] = 0;
      json['redirectTarget'] = null;
      await db.insert('tags', json);
      newTagId = newTagModel.id;
    } else {
      newTagId = newTag['id'] as String;
    }

    // Get all notes that have the old tag
    final noteTagMaps = await db.query(
      'note_tags',
      where: 'tagId = ?',
      whereArgs: [oldTagId],
    );

    // For each note, add the new tag if it doesn't already exist
    // For each note, add the new tag if it doesn't already exist
    for (final noteTagMap in noteTagMaps) {
      final noteId = noteTagMap['noteId'] as String;

      // Verify note exists (and is live -- M1.10: a tombstoned note's row
      // still physically exists, so it must be excluded here too, or a
      // deleted note could get a fresh note_tags row re-attached) to avoid
      // Foreign Key violations (orphaned tags)
      final noteExists = await db.query(
        'notes',
        columns: ['id'],
        where: 'id = ? AND __deleted__ = 0',
        whereArgs: [noteId],
        limit: 1,
      );

      if (noteExists.isEmpty) {
        // Cleanup orphan
        LoggerService.warning(
          'Found orphaned note_tag for noteId: $noteId. Cleaning up.',
        );
        await db.delete('note_tags', where: 'noteId = ?', whereArgs: [noteId]);
        continue;
      }

      // Check if this note already has the new tag
      final existingNewTag = await db.query(
        'note_tags',
        where: 'noteId = ? AND tagId = ?',
        whereArgs: [noteId, newTagId],
      );

      // Only insert if the note doesn't already have the new tag
      if (existingNewTag.isEmpty) {
        await db.insert('note_tags', {
          'noteId': noteId,
          'tagId': newTagId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }

    // Update conversation tag relationships
    final conversationTagMaps = await db.query(
      'conversation_tags',
      where: 'tagId = ?',
      whereArgs: [oldTagId],
    );

    final now = DateTime.now().millisecondsSinceEpoch;

    for (final conversationTagMap in conversationTagMaps) {
      final conversationId = conversationTagMap['conversationId'] as String;

      final existingNewConversationTag = await db.query(
        'conversation_tags',
        where: 'conversationId = ? AND tagId = ?',
        whereArgs: [conversationId, newTagId],
      );

      if (existingNewConversationTag.isEmpty) {
        await db.insert('conversation_tags', {
          'conversationId': conversationId,
          'tagId': newTagId,
        });
      }

      await db.update(
        'conversations',
        {'updatedAt': now},
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    }

    // Delete all old tag relationships. Membership rows in an OR-Set
    // table — real deletion is correct and unaffected by this milestone.
    await db.delete('note_tags', where: 'tagId = ?', whereArgs: [oldTagId]);
    await db.delete(
      'conversation_tags',
      where: 'tagId = ?',
      whereArgs: [oldTagId],
    );

    // M1.9: tombstone the old tag row instead of deleting it — same
    // reasoning as deleteTag above.
    //
    // M2.4 fix (design doc § Architecture 11.3's own named follow-up,
    // confirmed still open as of § Architecture 11.6(e): "replaceTag's own
    // doc comment states outright it does not implement the full
    // tagMerge/redirectTarget CRDT semantics... tags.redirectTarget's
    // column comment confirms it is always NULL until tagMerge is
    // implemented"): when this call is a genuine MERGE into an
    // already-live tag (`isRealMerge`, i.e. `newTagId` identifies a
    // pre-existing row this call did not just create), the losing tag's
    // tombstone now also carries `redirectTarget = newTagId` in the same
    // write, giving `tags.redirectTarget` its first real producer anywhere
    // in this codebase. This is schema-compatible (the column has existed
    // since M1.3) and needs no migration -- just this write. Deliberately
    // scoped to the merge branch only, not the plain-rename branch just
    // above (`newTag == null`): a rename mints a brand-new tag row with its
    // own fresh id rather than continuing `oldTagId`'s identity under a
    // different name, so it is not "the same tag, redirected" in the sense
    // `redirectTarget`/tagMerge's CRDT semantics describe -- matching this
    // milestone's own explicit scope boundary ("just make the EXISTING
    // manual 'merge tags' code path populate the field it was always
    // supposed to populate", not the full auto-merge/collision-detection
    // mechanism, which is M2.7's job per § 11.6(e)). This tombstone+
    // redirect write is an ordinary pair of field-scoped writes from the
    // new M2.4 capture triggers' point of view (`__deleted__`/
    // `redirectTarget` each already have their own `AFTER UPDATE` trigger
    // above) -- no special-case trigger needed for this to become
    // capturable.
    await db.update(
      'tags',
      {'__deleted__': 1, if (isRealMerge) 'redirectTarget': newTagId},
      where: 'id = ?',
      whereArgs: [oldTagId],
    );

    // Every note that carried the old tag now has different indexed tag
    // metadata (meta chunk) — notify the indexer per note.
    final affectedNoteIds = <String>{
      for (final noteTagMap in noteTagMaps) noteTagMap['noteId'] as String,
    };
    for (final noteId in affectedNoteIds) {
      _notifyNoteContentChanged(noteId);
    }
  }

  // Relationships CRUD
  Future<String> insertRelationship(Relationship relationship) async {
    final db = await database;
    final json = relationship.toJson();
    json['createdAt'] = relationship.createdAt.millisecondsSinceEpoch;
    await db.insert('relationships', json);
    return relationship.id;
  }

  Future<List<Relationship>> getRelationships(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: '(fromNoteId = ? OR toNoteId = ?) AND __deleted__ = 0',
      whereArgs: [noteId, noteId],
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      return Relationship(
        id: maps[i]['id'],
        fromNoteId: maps[i]['fromNoteId'],
        toNoteId: maps[i]['toNoteId'],
        type: maps[i]['type'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
      );
    });
  }

  Future<List<Relationship>> getOutgoingRelationships(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'fromNoteId = ? AND __deleted__ = 0',
      whereArgs: [noteId],
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      return Relationship(
        id: maps[i]['id'],
        fromNoteId: maps[i]['fromNoteId'],
        toNoteId: maps[i]['toNoteId'],
        type: maps[i]['type'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
      );
    });
  }

  Future<List<Relationship>> getIncomingRelationships(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'toNoteId = ? AND __deleted__ = 0',
      whereArgs: [noteId],
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      return Relationship(
        id: maps[i]['id'],
        fromNoteId: maps[i]['fromNoteId'],
        toNoteId: maps[i]['toNoteId'],
        type: maps[i]['type'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(maps[i]['createdAt']),
      );
    });
  }

  // M1.8: tombstone write, not a real delete — see the doc comment above
  // _createRelationshipsTable.
  Future<void> deleteRelationship(String relationshipId) async {
    final db = await database;
    await db.update(
      'relationships',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [relationshipId],
    );
  }

  // M1.8: tombstone write, not a real delete — see the doc comment above
  // _createRelationshipsTable. Preserves the pre-existing "removes all
  // types between these two notes, in either direction" semantics
  // unchanged (not filtered by `type`) — that's a separate, out-of-scope
  // question this milestone deliberately does not touch.
  Future<void> deleteRelationshipBetween(
    String fromNoteId,
    String toNoteId,
  ) async {
    final db = await database;
    await db.update(
      'relationships',
      {'__deleted__': 1},
      where:
          '(fromNoteId = ? AND toNoteId = ?) OR (fromNoteId = ? AND toNoteId = ?)',
      whereArgs: [fromNoteId, toNoteId, toNoteId, fromNoteId],
    );
  }

  // M1.8: tombstone write, not a real delete — see the doc comment above
  // _createRelationshipsTable. M1.10: takes an optional [executor] (the
  // established `DatabaseExecutor? executor` idiom used elsewhere in this
  // file, e.g. computeAppRevisionVisibility) so `deleteNote` can call this
  // from inside its own transaction instead of duplicating this where
  // clause.
  Future<void> deleteRelationshipsForNote(
    String noteId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.update(
      'relationships',
      {'__deleted__': 1},
      where: 'fromNoteId = ? OR toNoteId = ?',
      whereArgs: [noteId, noteId],
    );
  }

  Future<bool> relationshipExists(
    String fromNoteId,
    String toNoteId,
    String type,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'relationships',
      where: 'fromNoteId = ? AND toNoteId = ? AND type = ? AND __deleted__ = 0',
      whereArgs: [fromNoteId, toNoteId, type],
    );
    return maps.isNotEmpty;
  }

  // Helper methods
  DateTime _validateTimestamp(
    dynamic timestamp,
    String fieldName,
    String recordId,
  ) {
    if (timestamp is int) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else if (timestamp is String) {
      // This indicates a schema violation - string timestamps should not exist
      LoggerService.error(
        'Database schema violation: $fieldName field contains string timestamp in record $recordId',
        error: 'Expected integer timestamp, got string: $timestamp',
      );
      throw FormatException(
        'Database schema violation: $fieldName field should contain integer timestamp, but contains string: $timestamp',
      );
    } else {
      LoggerService.error(
        'Database schema violation: $fieldName field has invalid type in record $recordId',
        error:
            'Expected integer timestamp, got ${timestamp.runtimeType}: $timestamp',
      );
      throw FormatException(
        'Database schema violation: $fieldName field should contain integer timestamp, but got ${timestamp.runtimeType}: $timestamp',
      );
    }
  }

  Future<Note> _mapToNote(Map<String, dynamic> map) async {
    final subNotes = await getSubNotes(map['id']);
    final tags = await _getNoteTags(map['id']);
    final attachments = await _getNoteAttachments(map['id']);

    String content = map['content'] as String? ?? '';
    if (content.isEmpty && (map['_contentLength'] as int? ?? 0) > 0) {
      // Content was too large and skipped in initial query, fetch it now in chunks
      final db = await database;
      content = await _readLargeString(
        db,
        'notes',
        'content',
        map['id'] as String,
      );
    }

    return Note(
      id: map['id'],
      title: map['title'],
      content: content,
      type: NoteType.values.firstWhere(
        (e) => e.toString().split('.').last == map['type'],
        orElse: () => NoteType.note,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt']),
      subNotes: subNotes,
      tags: tags,
      attachmentPaths: attachments,
      scheduledAt: map['scheduledAt'],
      completeBy: map['completeBy'],
      status: map['status'] != null ? _stringToTaskStatus(map['status']) : null,
      completionPercentage: map['completionPercentage'],
      pinned: (map['pinned'] ?? 0) == 1,
      isArchived: (map['isArchived'] ?? 0) == 1,
      recurrenceRule: map['recurrenceRule'],
    );
  }

  Future<List<String>> _getNoteTags(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT t.name
      FROM tags t
      JOIN note_tags nt ON t.id = nt.tagId
      WHERE nt.noteId = ? AND t.__deleted__ = 0
    ''',
      [noteId],
    );

    return maps.map((map) => map['name'] as String).toList();
  }

  // M1.11: `AND __deleted__ = 0` -- a tombstoned attachment row still
  // physically exists, so without this guard it would remain visible.
  Future<List<String>> _getNoteAttachments(String noteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'noteId = ? AND __deleted__ = 0',
      whereArgs: [noteId],
    );

    final List<String> attachmentPaths = [];
    for (final map in maps) {
      final filePath = map['filePath'] as String;
      final isRelativePath = (map['isRelativePath'] as int) == 1;

      if (isRelativePath) {
        // Convert relative path to full path for backward compatibility
        final fullPath = await FileUtils.getFullFilePath(filePath, true);
        attachmentPaths.add(fullPath);
      } else {
        // Legacy absolute path
        attachmentPaths.add(filePath);
      }
    }

    return attachmentPaths;
  }

  // Verify if an attachment path belongs to any note.
  //
  // M1.11: every branch's `where` clause now also requires
  // `__deleted__ = 0` -- a removed (tombstoned) attachment's path must not
  // be reported as "already in the database" (matches prior behavior,
  // where a removed attachment's row was really gone, not merely
  // tombstoned, so this query would already have found nothing).
  Future<bool> verifyAttachmentPath(String attachmentPath) async {
    final db = await database;

    // Check if the path is absolute (starts with /) or relative
    final isAbsolutePath = attachmentPath.startsWith('/');

    if (isAbsolutePath) {
      // Case 1: Absolute path - try both relative and absolute variants
      // 1a) Try relative path variant (like existing behavior)
      final fileName = attachmentPath.split('/').last;
      final relativePath = 'attachments/$fileName';

      final List<Map<String, dynamic>> rel = await db.query(
        'attachments',
        where: 'filePath = ? AND __deleted__ = 0',
        whereArgs: [relativePath],
      );
      if (rel.isNotEmpty) return true;

      // 1b) Try absolute path as-is with isRelativePath = 0
      final List<Map<String, dynamic>> abs = await db.query(
        'attachments',
        where: 'filePath = ? AND isRelativePath = 0 AND __deleted__ = 0',
        whereArgs: [attachmentPath],
      );
      return abs.isNotEmpty;
    } else {
      // Path is already relative, search directly
      final List<Map<String, dynamic>> maps = await db.query(
        'attachments',
        where: 'filePath = ? AND __deleted__ = 0',
        whereArgs: [attachmentPath],
      );

      return maps.isNotEmpty;
    }
  }

  // Get the note ID for a given attachment path.
  //
  // M1.11: `AND __deleted__ = 0` -- a removed (tombstoned) attachment
  // should not resolve to a note id (matches prior behavior, where the row
  // was really gone).
  Future<String?> getNoteIdForAttachment(String attachmentPath) async {
    final db = await database;

    // Check if the path is absolute (starts with /) or relative
    final isAbsolutePath = attachmentPath.startsWith('/');

    String searchPath;
    if (isAbsolutePath) {
      // Convert absolute path to relative path for database lookup
      final fileName = attachmentPath.split('/').last;
      searchPath = 'attachments/$fileName';
    } else {
      // Path is already relative, use as is
      searchPath = attachmentPath;
    }

    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: 'filePath = ? AND __deleted__ = 0',
      whereArgs: [searchPath],
    );

    return maps.isNotEmpty ? maps.first['noteId'] as String? : null;
  }

  /// Finds the row for a *live* tag by name — live meaning
  /// `__deleted__ = 0 AND redirectTarget IS NULL`, i.e. a tag a user would
  /// currently perceive as "existing" (an ordinary tombstoned tag, or the
  /// losing/redirecting side of a future tagMerge, does not match).
  ///
  /// This is the single shared query every tag-identity-by-name lookup in
  /// the app must go through (M1.3) — matches idx_tags_name_live's own
  /// predicate exactly, so "a live tag with this name exists" and "this
  /// name is available for a new live tag" are always the same question,
  /// asked the same way. Before this method existed, three independent
  /// call sites (`_getOrCreateTagId` here and in NoteModificationService,
  /// plus `replaceTag`'s own two lookups) each ran a bare `WHERE name = ?`
  /// with no liveness filter at all — harmless while `tags.name` carried a
  /// blanket UNIQUE constraint (at most one row could ever match), but
  /// silently wrong once deletion becomes a soft tombstone: an unfiltered
  /// lookup would match and reuse a tombstoned row's id, resurrecting a
  /// dead tag's identity under a new tag's actions (design doc § Architecture
  /// 10, "Round 20 correction").
  ///
  /// Takes a [DatabaseExecutor] (not [Database]) so it works identically
  /// inside a transaction (NoteModificationService's call sites) and
  /// against a plain opened database.
  static Future<Map<String, Object?>?> findLiveTagByName(
    DatabaseExecutor db,
    String tagName,
  ) async {
    final rows = await db.query(
      'tags',
      where: 'name = ? AND __deleted__ = 0 AND redirectTarget IS NULL',
      whereArgs: [tagName],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Returns the id of the live tag named [tagName], creating a fresh
  /// (random-UUID, `__deleted__ = 0`, `redirectTarget = NULL`) row if none
  /// exists yet — the single shared replacement for the two
  /// independently-duplicated `_getOrCreateTagId` copies this file and
  /// NoteModificationService used to each maintain separately. See
  /// [findLiveTagByName] for why the liveness filter matters.
  static Future<String> getOrCreateLiveTagId(
    DatabaseExecutor db,
    String tagName,
  ) async {
    final existing = await findLiveTagByName(db, tagName);
    if (existing != null) {
      return existing['id'] as String;
    }

    final tagId = const Uuid().v4();
    await db.insert('tags', {
      'id': tagId,
      'name': tagName,
      'color': '#2196F3',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'usageCount': 0,
      '__deleted__': 0,
      'redirectTarget': null,
    });
    return tagId;
  }

  /// [executor] lets a caller already inside a transaction (`updateNote`)
  /// run this against that same `txn` instead of a fresh top-level
  /// statement -- the same optional-executor idiom `deleteRelationshipsForNote`/
  /// `deleteNoteConversationMappings` already use (M1.10), not a new one
  /// invented for this milestone. Defaults to `await database` so
  /// `insertNote`'s existing non-transactional call site is unaffected.
  Future<void> _linkNoteToTag(
    String noteId,
    String tagName, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final tagId = await getOrCreateLiveTagId(db, tagName);

    // Link note to tag (only if not already linked)
    final existingLink = await db.query(
      'note_tags',
      where: 'noteId = ? AND tagId = ?',
      whereArgs: [noteId, tagId],
    );

    if (existingLink.isEmpty) {
      await db.insert('note_tags', {
        'noteId': noteId,
        'tagId': tagId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _insertAttachment(
    String noteId,
    String filePath, {
    bool isRelativePath = false,
    bool includeInAIContext = true,
  }) async {
    final db = await database;
    await _insertAttachmentRow(
      db,
      noteId,
      filePath,
      isRelativePath: isRelativePath,
      includeInAIContext: includeInAIContext,
    );
    _notifyNoteContentChanged(noteId);
  }

  /// Executor-based sibling of [_insertAttachment], factored out so
  /// [diffAndPersistAttachments] can insert a genuinely-new attachment row
  /// against a caller-supplied transaction executor without risking the
  /// classic sqflite deadlock (a plain `await database` write from inside
  /// an already-open `db.transaction` callback blocks forever on the same
  /// lock the outer transaction is holding).
  static Future<void> _insertAttachmentRow(
    DatabaseExecutor db,
    String noteId,
    String filePath, {
    bool isRelativePath = false,
    bool includeInAIContext = true,
  }) async {
    final fileName = filePath.split('/').last;
    final fileType = FileTypeUtils.getFileExtension(fileName);
    final uuid = Uuid();

    // Default HTML files to be excluded from AI context to save tokens
    final isHtml =
        fileType.toLowerCase() == 'html' || fileType.toLowerCase() == 'htm';
    final finalIncludeInAIContext = isHtml ? false : includeInAIContext;

    await db.insert('attachments', {
      'id': uuid.v4(),
      'noteId': noteId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
      'isRelativePath': isRelativePath ? 1 : 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': finalIncludeInAIContext ? 1 : 0,
    });
  }

  // Get all attachments from database
  //
  // M1.11: `WHERE __deleted__ = 0` -- callers of this method
  // (`NoteMarkerService`'s marker-cleanup sweeps) should not see tombstoned
  // attachment rows.
  Future<List<Map<String, dynamic>>> getAllAttachments() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'attachments',
      where: '__deleted__ = 0',
    );
    return maps;
  }

  // Get database path
  Future<String> getDatabasePath() async {
    final dbName = _databaseNameOverride ?? 'note_synapse.db';
    return p.join(await getDatabasesPath(), dbName);
  }

  // Force database checkpoint
  Future<void> checkpoint() async {
    final db = await database;
    await db.rawQuery('PRAGMA wal_checkpoint(FULL);');
  }

  // Migrate a backup database to current version
  Future<void> migrateBackupDatabase(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    oldVersion = await _migrationStartingVersion(db, oldVersion);
    LoggerService.info(
      'Migrating backup database from version $oldVersion to $newVersion',
    );

    // Inline migration execution for backup databases (no RecoveryScreen navigation)
    for (int version = oldVersion + 1; version <= newVersion; version++) {
      final migrationStep = _migrationSteps[version];
      if (migrationStep == null) {
        LoggerService.warning('No migration step defined for version $version');
        continue;
      }

      try {
        LoggerService.info(
          'Executing backup migration to version $version: ${migrationStep.description}',
        );
        await migrationStep.execute(db, isBackupMigration: true);
        LoggerService.info('Successfully migrated backup to version $version');
      } catch (e) {
        LoggerService.error(
          'Backup migration to version $version failed: $e',
          error: e,
        );
        rethrow; // Recovery must not merge a partially migrated database.
      }
    }
  }

  // Clear all data.
  //
  // M1.13 design decision: this function is a full local reset/debug wipe
  // (its only current callers are `AppProvider.clearAllData` -- not
  // presently wired to any settings/UI screen -- and a handful of test
  // `setUp`s that use it as belt-and-suspenders cleanup right after
  // `DatabaseService.createNew()`), not an ordinary CRDT-tracked deletion
  // of user content. That distinction matters now that every table it
  // touches (other than the five OR-Set membership tables, where real
  // deletion is always correct) is covered by the M1.5/M1.13 hard-delete
  // guard: a real `db.delete` against a guarded table now aborts unless
  // something first disables the guard for it.
  //
  // Two structural options existed: (a) convert every entity-table line
  // below to a tombstone write, consistent with every other soft-delete
  // conversion in this file; or (b) have this function bypass the guard
  // for its own operation. (a) was rejected: "clear all data" exists to
  // produce a genuinely empty local database (the point of a reset/debug
  // tool), and tombstoning instead would leave every row this function
  // used to remove still physically present forever -- the opposite of
  // what a caller of a function named `clearAllData` would reasonably
  // expect, and a real correctness problem for the `tags.name`/
  // `tag_workflow_bindings.pattern`-style liveness-aware uniqueness this
  // codebase already depends on elsewhere (a "cleared" database would
  // still be carrying every previously-live row as a tombstone, silently
  // inflating storage and query-plan cost with no way back to a truly
  // empty state short of reinstalling the app). This function takes
  // option (b) instead: it temporarily drops the guard triggers for the
  // entity tables it wipes, performs the same real deletes it always has,
  // then unconditionally reinstalls every guard trigger in a `finally` --
  // so no caller can ever observe this function having left any table's
  // guard disabled, including on a partial failure partway through. The
  // five OR-Set membership tables below (`note_tags`,
  // `conversation_message_mapping`, `conversation_note_mapping`,
  // `conversation_tags`, `message_parents`) were never guarded in the
  // first place (real deletion is correct for them by design), so no
  // bypass is needed for those lines.
  Future<void> clearAllData() async {
    final db = await database;

    // Derived search-index rows go FIRST (self-healing order): if the wipe is
    // interrupted here, the cleared global flag makes the next backfill
    // rebuild the index; the reverse order could leave ghost chunks for
    // deleted notes behind a still-set "done" flag. None of these tables is
    // hard-delete-guarded (they hold derived data, never CRDT-tracked user
    // content), so no guard bypass is needed for them.
    if (_chunksFtsAvailable) {
      await db.delete('chunks_fts');
    }
    await db.delete('chunk_embeddings');
    await db.delete('search_chunks');
    // Includes the global ('global','all','chunks') backfill-complete row.
    await db.delete('search_index_state');

    // The entity tables this function wipes that the M1.5/M1.13
    // hard-delete guard protects -- every guarded table this function
    // touches. `tag_workflow_bindings`/`tag_images`/`tag_ai_configs`/the
    // User-App family are deliberately absent: this function has never
    // touched any of them (a pre-existing, unrelated scope choice, not
    // something M1.13 introduced), so there is nothing to bypass for them
    // here.
    const guardedTablesToWipe = [
      'relationships',
      'attachments',
      'subnotes',
      'notes',
      'tags',
      'filters',
      'conversation_messages',
      'conversation_attachments',
      'conversations',
    ];
    for (final table in guardedTablesToWipe) {
      await db.execute('DROP TRIGGER IF EXISTS guard_no_hard_delete_$table');
    }
    try {
      // Delete all data from all tables
      await db.delete('relationships');
      await db.delete('attachments');
      await db.delete('note_tags');
      await db.delete('subnotes');
      await db.delete('notes');
      await db.delete('tags');
      await db.delete('filters');

      await db.delete('conversation_messages');
      await db.delete('conversation_attachments');
      await db.delete('conversation_message_mapping');
      await db.delete('conversation_note_mapping');
      await db.delete('conversation_tags');
      await db.delete('message_parents');
      await db.delete('conversations');

      // M2.4: the five OR-Set membership deletes above now fire this
      // milestone's own new AFTER DELETE capture triggers (they were never
      // guarded, so nothing above needed to bypass anything for them) --
      // meaning this wipe would otherwise leave `sync_touch_log` full of
      // touch rows referencing entities this same call just physically
      // removed. `clearAllData` is documented above as producing a
      // "genuinely empty local database", not an ordinary CRDT-tracked
      // deletion (§ Architecture 11.3's drain/outbox machinery is not
      // meant to see this operation at all) -- so every sync control-plane
      // table that could hold a reference to an entity/subject/operation
      // this call just physically erased is wiped alongside everything
      // else, keeping that promise honest now that a real write path into
      // several of them exists (`OutboxDrainer`,
      // `lib/services/sync/outbox_drainer.dart`).
      //
      // `syncEntityScopedControlPlaneTablesToWipe`'s own doc comment
      // (below `_syncMutationCaptureTriggerStatements`) gives the full
      // per-table reasoning for exactly which of the fifteen M1.1 tables
      // are wiped here vs. deliberately left alone.
      for (final table in syncEntityScopedControlPlaneTablesToWipe) {
        await db.delete(table);
      }
    } finally {
      // Reinstall every guard trigger unconditionally -- including on a
      // failure partway through the deletes above -- so this function can
      // never leave the guard disabled for any table. Reuses the single
      // source of truth (_hardDeleteGuardTriggerStatements), not just the
      // nine dropped above, for the same anti-drift reason `_onCreate`/
      // the migrations do: `CREATE TRIGGER IF NOT EXISTS` makes
      // reinstalling all of them (including the five never dropped here)
      // a safe no-op for the ones that were never removed.
      for (final statement in _hardDeleteGuardTriggerStatements) {
        await db.execute(statement);
      }
    }
  }

  // Utility methods
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
    // TEMP capture objects died with the connection; drop the stale state so
    // the next captured write reinstalls them on the new connection. (An
    // in-flight install for the old connection is left to finish — its
    // result is discarded because it is keyed to the closed Database.)
    _captureState = null;
  }

  // Helper method to convert string to TaskStatus
  TaskStatus _stringToTaskStatus(String statusString) {
    switch (statusString) {
      case 'abandoned':
        return TaskStatus.abandoned;
      case 'complete':
        return TaskStatus.complete;
      case 'in_progress':
        return TaskStatus.inProgress;
      case 'todo':
        return TaskStatus.todo;
      default:
        return TaskStatus.todo;
    }
  }

  // Filters CRUD
  Future<String> insertFilter(Filter filter) async {
    final db = await database;

    // Build the map directly for database insertion
    final json = {
      'id': filter.id,
      'name': filter.name,
      'includeText': filter.includeText,
      'includeTags': filter.includeTags.join(','),
      'excludeTags': filter.excludeTags.join(','),
      'noteTypes': filter.noteTypes
          .map((t) => t.toString().split('.').last)
          .join(','),
      'includeArchived': filter.includeArchived ? 1 : 0,
      'isPinned': filter.isPinned ? 1 : 0,
      'isSpace': filter.isSpace ? 1 : 0,
      'createdAt': filter.createdAt.millisecondsSinceEpoch,
      'updatedAt': filter.updatedAt.millisecondsSinceEpoch,
    };

    await db.insert('filters', json);
    return filter.id;
  }

  Future<List<Filter>> getAllFilters() async {
    final db = await database;
    // M1.7: __deleted__ = 0 filters out tombstoned filters. Filters have no
    // fallback concept, so this raw filter is already the effective one.
    final List<Map<String, dynamic>> maps = await db.query(
      'filters',
      where: '__deleted__ = 0',
      orderBy: 'createdAt DESC',
    );

    return List.generate(maps.length, (i) {
      final includeTagsString = maps[i]['includeTags'] as String? ?? '';
      final includeTags = includeTagsString.isEmpty
          ? <String>[]
          : includeTagsString.split(',');

      final excludeTagsString = maps[i]['excludeTags'] as String? ?? '';
      final excludeTags = excludeTagsString.isEmpty
          ? <String>[]
          : excludeTagsString.split(',');

      final noteTypesString = maps[i]['noteTypes'] as String? ?? '';
      final noteTypes = noteTypesString.isEmpty
          ? NoteType
                .values // Default to all types if empty (backward compatibility)
          : noteTypesString.split(',').map((e) {
              return NoteType.values.firstWhere(
                (type) => type.toString().split('.').last == e,
                orElse: () => NoteType.note,
              );
            }).toList();

      return Filter(
        id: maps[i]['id'],
        name: maps[i]['name'],
        includeText: maps[i]['includeText'],
        includeTags: includeTags,
        excludeTags: excludeTags,
        noteTypes: noteTypes,
        includeArchived: (maps[i]['includeArchived'] ?? 0) == 1,
        isPinned: (maps[i]['isPinned'] ?? 0) == 1,
        isSpace: (maps[i]['isSpace'] ?? 0) == 1,
        createdAt: _validateTimestamp(
          maps[i]['createdAt'],
          'createdAt',
          maps[i]['id'],
        ),
        updatedAt: _validateTimestamp(
          maps[i]['updatedAt'],
          'updatedAt',
          maps[i]['id'],
        ),
      );
    });
  }

  Future<Filter?> getFilter(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'filters',
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;

    final map = maps.first;
    final includeTagsString = map['includeTags'] as String? ?? '';
    final includeTags = includeTagsString.isEmpty
        ? <String>[]
        : includeTagsString.split(',');

    final excludeTagsString = map['excludeTags'] as String? ?? '';
    final excludeTags = excludeTagsString.isEmpty
        ? <String>[]
        : excludeTagsString.split(',');

    final noteTypesString = map['noteTypes'] as String? ?? '';
    final noteTypes = noteTypesString.isEmpty
        ? NoteType
              .values // Default to all types
        : noteTypesString.split(',').map((e) {
            return NoteType.values.firstWhere(
              (type) => type.toString().split('.').last == e,
              orElse: () => NoteType.note,
            );
          }).toList();

    return Filter(
      id: map['id'],
      name: map['name'],
      includeText: map['includeText'],
      includeTags: includeTags,
      excludeTags: excludeTags,
      noteTypes: noteTypes,
      includeArchived: (map['includeArchived'] ?? 0) == 1,
      isPinned: (map['isPinned'] ?? 0) == 1,
      isSpace: (map['isSpace'] ?? 0) == 1,
      createdAt: _validateTimestamp(map['createdAt'], 'createdAt', map['id']),
      updatedAt: _validateTimestamp(map['updatedAt'], 'updatedAt', map['id']),
    );
  }

  Future<void> updateFilter(Filter filter) async {
    final db = await database;

    // Build the map directly for database update
    final json = {
      'id': filter.id,
      'name': filter.name,
      'includeText': filter.includeText,
      'includeTags': filter.includeTags.join(','),
      'excludeTags': filter.excludeTags.join(','),
      'noteTypes': filter.noteTypes
          .map((t) => t.toString().split('.').last)
          .join(','),
      'includeArchived': filter.includeArchived ? 1 : 0,
      'isPinned': filter.isPinned ? 1 : 0,
      'isSpace': filter.isSpace ? 1 : 0,
      'createdAt': filter.createdAt.millisecondsSinceEpoch,
      'updatedAt': filter.updatedAt.millisecondsSinceEpoch,
    };

    await db.update('filters', json, where: 'id = ?', whereArgs: [filter.id]);
  }

  /// M1.7 (design doc § Phased delivery, M1.7): a tombstone write, not a
  /// real SQL DELETE — mirrors deleteUserApp/deleteUserAppLibrary's M1.4
  /// conversion.
  Future<void> deleteFilter(String id) async {
    final db = await database;
    await db.update(
      'filters',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Execute raw SQL query for user apps
  Future<List<Map<String, dynamic>>> executeRawQuery(String sql) async {
    final db = await database;
    try {
      final trimmedSql = sql.trim().toLowerCase();

      // Execute the query
      final result = await db.rawQuery(sql);
      return result;
    } catch (e) {
      throw Exception('SQL query execution failed: $e');
    }
  }

  // ===========================================================================
  // M1.4 — User-App-family derived, effective visibility (design doc §
  // Architecture 10, "User Apps + revision history" + the following "User
  // App visibility, extended to be the fallback's actual liveness root"
  // paragraph). Deletion in this family is *always* a tombstone write from
  // here on — see deleteUserApp/deleteAppRevision/deleteUserAppLibrary/
  // deleteUserAppLibraryDependency below, none of which issue a real SQL
  // DELETE anymore (test/hard_delete_audit_test.dart's checked-in baseline
  // no longer lists any of them as a hard-delete site). Every list/lookup
  // read path in this file for this family filters on the values computed
  // here, not on raw `__deleted__` directly, so a tombstoned revision can
  // still legitimately read as visible while it serves as its app's
  // zero-live-revisions fallback (below).
  //
  // Layering (app -> revision -> library -> dependency), each level
  // composing the one above it — mirrors the real ownership chain, NOT the
  // abstract test/sync_protocol/app_ops.dart simulator's field names
  // one-for-one: `user_app_libraries.revision_id`, despite its name, holds
  // an `app_revisions.revisionNumber` value (an int), never an
  // `app_revisions.id` (a string) — confirmed directly against every real
  // call site (e.g. export_app_screen.dart's
  // `getUserAppLibraries(appUuid, pinnedRevision.revisionNumber)`,
  // user_app_service.dart's `addLibrary(revisionId: revisionNumber, ...)`)
  // — and is NOT itself declared as a foreign key to `app_revisions` at
  // all (only `user_app_libraries.app_uuid -> user_apps.uuid` is a real
  // FK; see test/hard_delete_audit_test.dart's kFkEdgeBaseline, which has
  // no `app_revisions -> user_app_libraries` edge). So resolving "which
  // revision owns this library row" requires a join through
  // `(user_apps.uuid = app_uuid) x (app_revisions.appId = user_apps.id AND
  // app_revisions.revisionNumber = revision_id)`, done explicitly below —
  // CLAUDE.md's own standing note that "`user_app_revision.revision` is the
  // revision number (not `id`)" is exactly this fact, under the real
  // table/column names.
  //
  //   - effectiveAppVisible(app)      = NOT app.__deleted__
  //   - effectiveRevisionVisible(r)   = effectiveAppVisible(r's app) AND
  //                                     (NOT r.__deleted__ OR r is the
  //                                     fallback — see below)
  //   - effectiveLibraryVisible(l)    = NOT l.__deleted__ AND
  //                                     effectiveRevisionVisible(l's revision)
  //   - effectiveDependencyVisible(d) = NOT d.__deleted__ AND
  //                                     effectiveLibraryVisible(d's library)
  //
  // **Fallback-selection rule.** The plan text establishes the fallback
  // CONCEPT — "a revision's effective visibility is `NOT __deleted__` OR
  // `(currently serving as the zero-live-revisions fallback for its app)`"
  // — but never states a concrete tie-break formula (a full-text search of
  // the plan finds no `revisionNumber`-based, `createdAt`-based, or any
  // other concretely stated fallback-selection formula anywhere).
  // test/sync_protocol/app_ops.dart's header comment worked through this
  // exact gap for the abstract CRDT simulator and settled on "whichever
  // revision became non-live MOST RECENTLY", expressed there as the
  // highest `(hlc, authorId, authorSeq)` among the revisions' own
  // `__deleted__` tombstone writes (reusing `hlcTieBreakWins`, the
  // document's sole established precedent for "which of several operations
  // is most recent"), reasoning: (1) the revision most recently made
  // non-live is the one a user most recently still saw as their app's
  // current version — keeping the app usable rather than orphaned is
  // exactly round 8's intent for adding a fallback at all; (2) the plan
  // itself (Codebase grounding, "No `UNIQUE` constraint on `(appId,
  // revisionNumber)`") explicitly distrusts `revisionNumber` as a reliable
  // ordering/identity key elsewhere in this exact document.
  //
  // This implementation adapts the SAME reasoning to real SQL: there is no
  // per-field HLC yet in this pre-sync-engine codebase (that machinery
  // lands with the sync engine itself, M2+), so `app_revisions.deletedAt`
  // — a local wall-clock timestamp written exactly when `__deleted__` is
  // set to 1, and left as-is (not cleared) by this milestone since nothing
  // yet implements revision undelete — stands in for "most recent
  // tombstone write": the revision with the highest `deletedAt` wins. Ties
  // (identical `deletedAt`, possible if two deletes land in the same
  // millisecond, e.g. an automated test) break on `revisionNumber DESC` —
  // deliberately not used as the PRIMARY key, matching the plan's own
  // stated distrust of `revisionNumber` above, but fine as a last-resort,
  // fully deterministic tie-break that never leaves the result dependent on
  // row-scan order.
  //
  // Deliberately note what this milestone does NOT attempt: the
  // `deleteAppRevision` guard below ("Cannot delete the only remaining
  // revision") already prevents any single local delete action from ever
  // driving an app to zero raw-live revisions, so the fallback path is
  // unreachable through today's UI alone — it exists for the CRDT-merge
  // future (M2+) where two devices' individually-safe-looking concurrent
  // deletes can combine into a zero-live state neither device intended.
  // Tests below exercise this by writing `__deleted__`/`deletedAt` directly
  // (bypassing the guarded application function), the same way
  // test/sync_protocol/app_ops.dart's own tests do against the simulator.
  /// Computes [AppRevisionVisibility] for [appId] fresh from the raw
  /// `user_apps`/`app_revisions` rows — see the section doc comment above
  /// for the full rule. Returns `({}, null)` if the app doesn't exist or is
  /// itself tombstoned (apps have no fallback concept of their own: a
  /// deleted app's revisions are never effectively visible, full stop,
  /// regardless of their own raw `__deleted__` state).
  Future<AppRevisionVisibility> computeAppRevisionVisibility(
    String appId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;

    final appRows = await db.rawQuery(
      'SELECT __deleted__ FROM user_apps WHERE id = ?',
      [appId],
    );
    if (appRows.isEmpty || (appRows.first['__deleted__'] as int? ?? 0) != 0) {
      return const AppRevisionVisibility({}, null);
    }

    final rows = await db.rawQuery(
      'SELECT id, __deleted__, deletedAt, revisionNumber FROM app_revisions WHERE appId = ?',
      [appId],
    );
    if (rows.isEmpty) return const AppRevisionVisibility({}, null);

    final liveIds = <String>{
      for (final r in rows)
        if ((r['__deleted__'] as int? ?? 0) == 0) r['id'] as String,
    };
    if (liveIds.isNotEmpty) {
      return AppRevisionVisibility(liveIds, null);
    }

    // Zero raw-live revisions: elect the fallback (see section doc comment
    // for the tie-break rule).
    Map<String, Object?>? best;
    for (final r in rows) {
      if (best == null) {
        best = r;
        continue;
      }
      final rAt = r['deletedAt'] as int? ?? 0;
      final bestAt = best['deletedAt'] as int? ?? 0;
      final rNum = r['revisionNumber'] as int;
      final bestNum = best['revisionNumber'] as int;
      if (rAt > bestAt || (rAt == bestAt && rNum > bestNum)) {
        best = r;
      }
    }
    final fallbackId = best!['id'] as String;
    return AppRevisionVisibility({fallbackId}, fallbackId);
  }

  /// Convenience wrapper over [computeAppRevisionVisibility] for callers
  /// that only need the fallback id (e.g. building a
  /// `(__deleted__ = 0 OR id = ?)` SQL filter — a `null` fallbackId is
  /// harmless there since `id = NULL` never matches in SQLite, so the
  /// clause correctly collapses to plain `__deleted__ = 0` when no fallback
  /// is in effect).
  Future<String?> fallbackRevisionIdForApp(
    String appId, {
    DatabaseExecutor? executor,
  }) async => (await computeAppRevisionVisibility(
    appId,
    executor: executor,
  )).fallbackRevisionId;

  Future<bool> _isUserAppDeleted(
    String appId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final rows = await db.rawQuery(
      'SELECT __deleted__ FROM user_apps WHERE id = ?',
      [appId],
    );
    if (rows.isEmpty) return true; // nonexistent app: never visible
    return (rows.first['__deleted__'] as int? ?? 0) != 0;
  }

  Future<bool> isAppRevisionEffectivelyVisible(
    String revisionId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final rows = await db.rawQuery(
      'SELECT appId FROM app_revisions WHERE id = ?',
      [revisionId],
    );
    if (rows.isEmpty) return false;
    final appId = rows.first['appId'] as String;
    final vis = await computeAppRevisionVisibility(appId, executor: db);
    return vis.visibleRevisionIds.contains(revisionId);
  }

  /// A library is effectively visible iff it is not itself raw-tombstoned
  /// AND its owning revision is effectively visible. Resolves the owning
  /// revision via the `(app_uuid -> user_apps.uuid) x (appId, revisionNumber
  /// = revision_id)` join described in the section doc comment above —
  /// `revision_id` is a revisionNumber, not an `app_revisions.id`.
  Future<bool> isUserAppLibraryEffectivelyVisible(
    int libraryId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final rows = await db.query(
      'user_app_libraries',
      where: 'id = ?',
      whereArgs: [libraryId],
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    if ((row['__deleted__'] as int? ?? 0) != 0) return false;

    final appUuid = row['app_uuid'] as String;
    final revisionNumber = row['revision_id'] as int;

    final appRows = await db.query(
      'user_apps',
      columns: ['id', '__deleted__'],
      where: 'uuid = ?',
      whereArgs: [appUuid],
    );
    if (appRows.isEmpty || (appRows.first['__deleted__'] as int? ?? 0) != 0) {
      return false;
    }
    final appId = appRows.first['id'] as String;

    final revRows = await db.rawQuery(
      'SELECT id FROM app_revisions WHERE appId = ? AND revisionNumber = ?',
      [appId, revisionNumber],
    );
    if (revRows.isEmpty) return false;

    final vis = await computeAppRevisionVisibility(appId, executor: db);
    return vis.visibleRevisionIds.contains(revRows.first['id'] as String);
  }

  /// A dependency is effectively visible iff it is not itself
  /// raw-tombstoned AND its owning library is effectively visible.
  Future<bool> isUserAppLibraryDependencyEffectivelyVisible(
    int dependencyId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final rows = await db.query(
      'user_app_library_dependencies',
      where: 'id = ?',
      whereArgs: [dependencyId],
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    if ((row['__deleted__'] as int? ?? 0) != 0) return false;
    final libraryId = row['library_id'] as int;
    return isUserAppLibraryEffectivelyVisible(libraryId, executor: db);
  }

  // User Apps CRUD
  Future<String> insertUserApp(UserApp app) async {
    final db = await database;
    // Build JSON manually to avoid conflicts with toJson() DateTime serialization
    final json = {
      'id': app.id,
      'uuid': app.uuid,
      'name': app.name,
      'description': app.description,
      'steps': app.steps.join('|'), // Store steps as pipe-separated string
      'htmlContent': app.htmlContent,
      'appState': app.appState != null ? jsonEncode(app.appState) : null,
      'type': app.type.toString().split('.').last, // Store enum as string
      'selectedRevisionId': app.selectedRevisionId,
      'author': app.author,
      'license': app.license,
      'i18n': app.i18n.isEmpty ? null : jsonEncode(userAppI18nToJson(app.i18n)),
      'createdAt': app.createdAt.millisecondsSinceEpoch,
      'updatedAt': app.updatedAt.millisecondsSinceEpoch,
    };

    LoggerService.debug(
      'DatabaseService.insertUserApp: Inserting app ${app.id} - ${app.name}',
    );
    await db.insert('user_apps', json);
    LoggerService.debug(
      'DatabaseService.insertUserApp: Successfully inserted app ${app.id}',
    );
    return app.id;
  }

  Future<List<UserApp>> getAllUserApps() async {
    final db = await database;
    // Exclude appState to avoid CursorWindow issues with large state data.
    // App state should be loaded on-demand via getUserAppState().
    // M1.4: __deleted__ = 0 filters out tombstoned apps. Apps have no
    // fallback concept (see the effective-visibility section doc comment
    // above), so this raw filter is already the effective one.
    final maps = await db.rawQuery('''
      SELECT id, uuid, name, description, steps, htmlContent, type,
             selectedRevisionId, author, license, i18n, createdAt, updatedAt
      FROM user_apps
      WHERE __deleted__ = 0
      ORDER BY createdAt DESC
    ''');
    LoggerService.debug(
      'DatabaseService.getAllUserApps: Found ${maps.length} user apps',
    );
    return maps.map((map) => _userAppFromMap(map)).toList();
  }

  Future<UserApp?> getUserApp(String id) async {
    final db = await database;
    // Explicitly select columns excluding appState to avoid CursorWindow size limits
    final maps = await db.rawQuery(
      '''
      SELECT id, uuid, name, description, steps, htmlContent, type,
             selectedRevisionId, author, license, i18n, createdAt, updatedAt
      FROM user_apps
      WHERE id = ? AND __deleted__ = 0
    ''',
      [id],
    );

    if (maps.isNotEmpty) {
      return _userAppFromMap(maps.first);
    }
    return null;
  }

  Future<UserApp?> getUserAppByUuid(String uuid) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT id, uuid, name, description, steps, htmlContent, type,
             selectedRevisionId, author, license, i18n, createdAt, updatedAt
      FROM user_apps
      WHERE uuid = ? AND __deleted__ = 0
      LIMIT 1
    ''',
      [uuid],
    );
    if (maps.isNotEmpty) {
      return _userAppFromMap(maps.first);
    }
    return null;
  }

  Future<void> updateUserApp(UserApp app) async {
    final db = await database;
    // Build JSON manually to avoid conflicts with toJson() DateTime serialization
    final json = {
      'id': app.id,
      'uuid': app.uuid,
      'name': app.name,
      'description': app.description,
      'steps': app.steps.join('|'), // Store steps as pipe-separated string
      'htmlContent': app.htmlContent,
      'type': app.type.toString().split('.').last, // Store enum as string
      'selectedRevisionId': app.selectedRevisionId,
      'author': app.author,
      'license': app.license,
      'i18n': app.i18n.isEmpty ? null : jsonEncode(userAppI18nToJson(app.i18n)),
      'createdAt': app.createdAt.millisecondsSinceEpoch,
      'updatedAt': app.updatedAt.millisecondsSinceEpoch,
    };

    if (app.appState != null) {
      json['appState'] = jsonEncode(app.appState);
    }

    await db.update('user_apps', json, where: 'id = ?', whereArgs: [app.id]);
  }

  /// M1.4 (design doc § Architecture 10, M1 status section): a single
  /// tombstone write on `user_apps`, nothing else. The previous three
  /// separate hard deletes (`user_app_libraries`, `app_revisions`,
  /// `user_apps`) collapse into this one write per the derived-visibility
  /// model — revisions/libraries/dependencies need no write of their own,
  /// since `computeAppRevisionVisibility` (and the library/dependency
  /// visibility helpers built on it) already treat every descendant of a
  /// deleted app as not effectively visible. This mirrors
  /// `deleteAppRevision`'s own round-14 fix one level up the ownership
  /// chain.
  Future<void> deleteUserApp(String id) async {
    final db = await database;

    final app = await getUserApp(id);
    if (app == null) return;

    await db.update(
      'user_apps',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateUserAppState(String id, Map<String, dynamic> state) async {
    final db = await database;
    await db.update(
      'user_apps',
      {
        'appState': jsonEncode(state),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, dynamic>?> getUserAppState(String id) async {
    final db = await database;

    // Use raw query with chunked TEXT reading to avoid cursor window issues
    final results = await db.rawQuery(
      '''
      SELECT id,
             CASE 
               WHEN length(CAST(appState AS BLOB)) > 0 THEN 'TEXT_DATA'
               ELSE NULL 
             END as has_text
      FROM user_apps 
      WHERE id = ?
    ''',
      [id],
    );

    if (results.isEmpty || results.first['has_text'] == null) {
      return null;
    }

    // Read TEXT data in chunks to avoid cursor window issues
    try {
      final textData = await _readLargeString(db, 'user_apps', 'appState', id);
      if (textData.isEmpty) {
        return null;
      }
      return jsonDecode(textData) as Map<String, dynamic>;
    } catch (e) {
      LoggerService.error('Failed to read appState for app $id: $e', error: e);
      return null;
    }
  }

  UserApp _userAppFromMap(Map<String, dynamic> map) {
    // Handle both int and string timestamps for backward compatibility
    DateTime parseTimestamp(dynamic timestamp) {
      if (timestamp is int) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp);
      } else if (timestamp is String) {
        return DateTime.parse(timestamp);
      } else {
        throw Exception('Invalid timestamp format: $timestamp');
      }
    }

    Map<String, UserAppLocalizedMetadata> parseI18n(dynamic raw) {
      if (raw == null) return const {};
      try {
        final decoded = raw is String ? jsonDecode(raw) : raw;
        return userAppI18nFromJson(decoded);
      } catch (e) {
        LoggerService.warning(
          'Ignoring malformed localized metadata for app ${map['id']}: $e',
        );
        return const {};
      }
    }

    return UserApp(
      id: map['id'] as String,
      uuid:
          map['uuid'] as String? ??
          const Uuid()
              .v4(), // Generate UUID if missing for backward compatibility
      name: map['name'] as String,
      description: map['description'] as String,
      steps: (map['steps'] as String).split('|'), // Parse pipe-separated steps
      htmlContent: map['htmlContent'] as String,
      appState: map['appState'] != null
          ? jsonDecode(map['appState'] as String) as Map<String, dynamic>
          : null,
      type: map['type'] != null
          ? UserAppType.values.firstWhere(
              (e) => e.toString().split('.').last == map['type'],
              orElse: () => UserAppType.normal,
            )
          : UserAppType.normal,
      selectedRevisionId: map['selectedRevisionId'] as String?,
      author: map['author'] as String? ?? '',
      license: map['license'] as String? ?? '',
      i18n: parseI18n(map['i18n']),
      createdAt: parseTimestamp(map['createdAt']),
      updatedAt: parseTimestamp(map['updatedAt']),
    );
  }

  // App Revisions CRUD
  Future<String> insertAppRevision(AppRevision revision) async {
    final db = await database;
    final json = {
      'id': revision.id,
      'appId': revision.appId,
      'revisionNumber': revision.revisionNumber,
      'revisionTimestamp': revision.revisionTimestamp.millisecondsSinceEpoch,
      'userPrompt': revision.userPrompt,
      'aiResponse': revision.aiResponse,
      'appCode': revision.appCode,
      'attachmentPaths': revision.attachmentPaths.join(
        '|',
      ), // Store attachment paths as pipe-separated string
    };

    LoggerService.debug(
      'DatabaseService.insertAppRevision: Inserting revision ${revision.id} for app ${revision.appId}',
    );
    await db.insert('app_revisions', json);
    LoggerService.debug(
      'DatabaseService.insertAppRevision: Successfully inserted revision ${revision.id}',
    );
    return revision.id;
  }

  /// M1.4: filters to effectively-visible revisions only — see
  /// `computeAppRevisionVisibility`'s doc comment. Returns `[]` outright if
  /// the owning app itself doesn't exist or is deleted (rather than relying
  /// on the `(__deleted__ = 0 OR id = ?)` trick below to also cover that
  /// case, since a nonexistent/deleted app never has a meaningful
  /// fallback). The `(__deleted__ = 0 OR id = fallbackRevisionId)` filter
  /// otherwise composes both branches of `computeAppRevisionVisibility` in
  /// one WHERE clause: when the app has a raw-live revision, fallbackId is
  /// null and `id = NULL` never matches in SQLite, so the clause collapses
  /// to plain `__deleted__ = 0`; when the app has zero raw-live revisions,
  /// every row has `__deleted__ = 1`, so only the fallback row's `id = ?`
  /// branch can match.
  Future<List<AppRevision>> getAppRevisions(String appId) async {
    final db = await database;
    if (await _isUserAppDeleted(appId, executor: db)) return [];
    final fallbackId = await fallbackRevisionIdForApp(appId, executor: db);

    final maps = await db.rawQuery(
      '''
      SELECT
        id, appId, revisionNumber, revisionTimestamp, userPrompt, aiResponse, attachmentPaths,
        CASE WHEN length(CAST(appCode AS BLOB)) < 500000 THEN appCode ELSE NULL END as appCode,
        length(CAST(appCode AS BLOB)) as _appCodeLength
      FROM app_revisions
      WHERE appId = ? AND (__deleted__ = 0 OR id = ?)
      ORDER BY revisionNumber ASC
      ''',
      [appId, fallbackId],
    );
    LoggerService.debug(
      'DatabaseService.getAppRevisions: Found ${maps.length} revisions for app $appId',
    );
    if (maps.isNotEmpty) {
      LoggerService.debug('First revision data: ${maps.first}');
    }

    final List<AppRevision> revisions = [];
    for (final map in maps) {
      revisions.add(await _appRevisionFromMap(map));
    }

    if (revisions.isNotEmpty) {
      LoggerService.debug(
        'First revision appCode length: ${revisions.first.appCode.length}',
      );
    }
    return revisions;
  }

  /// M1.4: returns null for a revision that exists but is not effectively
  /// visible (tombstoned and not currently serving as its app's fallback,
  /// or belonging to a deleted app) — see `isAppRevisionEffectivelyVisible`.
  Future<AppRevision?> getAppRevision(String id) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT
        id, appId, revisionNumber, revisionTimestamp, userPrompt, aiResponse, attachmentPaths,
        CASE WHEN length(CAST(appCode AS BLOB)) < 500000 THEN appCode ELSE NULL END as appCode,
        length(CAST(appCode AS BLOB)) as _appCodeLength
      FROM app_revisions
      WHERE id = ?
      ''',
      [id],
    );
    if (maps.isEmpty) return null;
    if (!await isAppRevisionEffectivelyVisible(id, executor: db)) return null;
    return await _appRevisionFromMap(maps.first);
  }

  /// M1.4 (design doc § Architecture 10, round 14 fix): an ordinary
  /// soft-delete — write `__deleted__=1`/`deletedAt=now` on the revision
  /// itself, nothing else. Libraries, dependencies, and revision
  /// attachments need no explicit write of their own: their effective
  /// visibility already derives from this revision's effective visibility
  /// (`isUserAppLibraryEffectivelyVisible`/
  /// `isUserAppLibraryDependencyEffectivelyVisible`), so tombstoning the
  /// revision alone correctly hides all of them, exactly as the design doc
  /// specifies. This also removes the function's only remaining hard
  /// delete: `deleteUserAppLibrariesForRevision`, the actual,
  /// unscoped-by-appId function responsible for the original round-8
  /// cross-app scoping bug, has been deleted from the codebase entirely
  /// (this was its only call site) rather than left as unreferenced dead
  /// code — round 16 named this explicitly.
  ///
  /// The "cannot delete the only remaining revision" guard below now reads
  /// `allRevisions` from the effective-visibility-filtered
  /// `getAppRevisions`, so it actually means "at least one EFFECTIVELY
  /// VISIBLE revision must remain" — a strictly more correct reading of its
  /// own original intent than a raw-row-count check would give under
  /// soft-delete, and the reason this guard makes the zero-live-revisions
  /// fallback scenario unreachable through this function alone: it can only
  /// arise from independently-safe-looking concurrent deletes merging
  /// across devices (M2+ sync), not from a single local delete action.
  Future<void> deleteAppRevision(String id) async {
    final db = await database;

    // Get the revision to find its appId and revision number
    final revision = await getAppRevision(id);
    if (revision == null) return;

    // Get all revisions for this app to check if this is the only one
    final allRevisions = await getAppRevisions(revision.appId);
    if (allRevisions.length <= 1) {
      throw Exception(
        'Cannot delete the only remaining revision. At least one revision must exist.',
      );
    }

    // Get the app to check if this is the pinned revision
    final app = await getUserApp(revision.appId);
    if (app == null) return;

    // If this is the pinned revision, move the pin to the previous "latest" revision
    if (app.selectedRevisionId == id) {
      // Find the latest remaining revision (highest revision number)
      final remainingRevisions = allRevisions.where((r) => r.id != id).toList();
      if (remainingRevisions.isNotEmpty) {
        // Sort by revision number descending to get the latest
        remainingRevisions.sort(
          (a, b) => b.revisionNumber.compareTo(a.revisionNumber),
        );
        final newPinnedRevision = remainingRevisions.first;

        // Update the app's selectedRevisionId
        final updatedApp = app.copyWith(
          selectedRevisionId: newPinnedRevision.id,
        );
        await updateUserApp(updatedApp);
      }
    }

    await db.update(
      'app_revisions',
      {'__deleted__': 1, 'deletedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// NOT converted by M1.4 — unlike `deleteAppRevision` above, this plural
  /// sibling has no call site anywhere in `lib/` (verified: it is dead
  /// code, reachable only from this file's own definition and this
  /// milestone's audit test). It remains a real hard delete and stays in
  /// test/hard_delete_audit_test.dart's checked-in baseline; converting
  /// unused code is out of this milestone's explicit scope (design doc M1
  /// status section names `deleteAppRevision`/`deleteUserAppLibrary`/
  /// `deleteUserAppLibraryDependency`/`deleteUserApp` specifically, not
  /// this function).
  Future<void> deleteAppRevisions(String appId) async {
    final db = await database;
    await db.delete('app_revisions', where: 'appId = ?', whereArgs: [appId]);
  }

  /// Deliberately reads the MAX over ALL rows (tombstoned or not), not just
  /// effectively-visible ones — soft-delete leaves a deleted revision's row
  /// (and its `revisionNumber`) physically in place, and
  /// `user_app_libraries.revision_id` stores that same `revisionNumber`
  /// (not `app_revisions.id` — see the effective-visibility section doc
  /// comment above) to scope a library to its owning revision. Filtering
  /// this MAX to only-visible rows would let a future revision reuse a
  /// tombstoned revision's number, silently re-associating that dead
  /// revision's still-physically-present libraries with the new one.
  Future<int> getNextRevisionNumber(String appId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(revisionNumber) as maxRevision FROM app_revisions WHERE appId = ?',
      [appId],
    );
    final maxRevision = result.first['maxRevision'] as int?;
    return (maxRevision ?? 0) + 1;
  }

  /// M1.4: latest EFFECTIVELY VISIBLE revision — see `getAppRevisions`'s
  /// doc comment for the same `(__deleted__ = 0 OR id = ?)` reasoning.
  Future<AppRevision?> getLatestAppRevision(String appId) async {
    final db = await database;
    if (await _isUserAppDeleted(appId, executor: db)) return null;
    final fallbackId = await fallbackRevisionIdForApp(appId, executor: db);

    final result = await db.rawQuery(
      '''
      SELECT
        id, appId, revisionNumber, revisionTimestamp, userPrompt, aiResponse, attachmentPaths,
        CASE WHEN length(CAST(appCode AS BLOB)) < 500000 THEN appCode ELSE NULL END as appCode,
        length(CAST(appCode AS BLOB)) as _appCodeLength
      FROM app_revisions
      WHERE appId = ? AND (__deleted__ = 0 OR id = ?)
      ORDER BY revisionNumber DESC
      LIMIT 1
      ''',
      [appId, fallbackId],
    );
    if (result.isNotEmpty) {
      return await _appRevisionFromMap(result.first);
    }
    return null;
  }

  Future<AppRevision> _appRevisionFromMap(Map<String, dynamic> map) async {
    String appCode = map['appCode'] as String? ?? '';
    if (appCode.isEmpty && (map['_appCodeLength'] as int? ?? 0) > 0) {
      final db = await database;
      appCode = await _readLargeString(
        db,
        'app_revisions',
        'appCode',
        map['id'] as String,
      );
    }

    final revision = AppRevision(
      id: map['id'] as String,
      appId: map['appId'] as String,
      revisionNumber: map['revisionNumber'] as int,
      revisionTimestamp: DateTime.fromMillisecondsSinceEpoch(
        map['revisionTimestamp'] as int,
      ),
      userPrompt: map['userPrompt'] as String,
      aiResponse: map['aiResponse'] as String,
      appCode: appCode,
      attachmentPaths: map['attachmentPaths'] != null
          ? (map['attachmentPaths'] as String)
                .split('|')
                .where((path) => path.isNotEmpty)
                .toList()
          : [],
    );
    LoggerService.debug(
      '_appRevisionFromMap: Created revision ${revision.id} with appCode length: ${revision.appCode.length}',
    );
    return revision;
  }

  // User App Libraries CRUD
  Future<int> insertUserAppLibrary({
    required String appUuid,
    required int revisionId,
    required String name,
    String? usageInstructions,
  }) async {
    final db = await database;
    final result = await db.insert('user_app_libraries', {
      'app_uuid': appUuid,
      'revision_id': revisionId,
      'name': name,
      'usage_instructions': usageInstructions,
    });
    return result;
  }

  /// M1.4: `revisionId` here is an `app_revisions.revisionNumber`, not an
  /// `app_revisions.id` (see the effective-visibility section doc comment
  /// above) — resolved to the owning revision row via the
  /// `(app_uuid -> user_apps.uuid) x (appId, revisionNumber)` join so its
  /// effective visibility can be checked before returning any libraries at
  /// all. Own-row `__deleted__ = 0` additionally filters out libraries
  /// directly tombstoned via `deleteUserAppLibrary`.
  Future<List<Map<String, dynamic>>> getUserAppLibraries(
    String appUuid,
    int revisionId,
  ) async {
    final db = await database;

    final appRows = await db.query(
      'user_apps',
      columns: ['id', '__deleted__'],
      where: 'uuid = ?',
      whereArgs: [appUuid],
    );
    if (appRows.isEmpty || (appRows.first['__deleted__'] as int? ?? 0) != 0) {
      return [];
    }
    final appId = appRows.first['id'] as String;

    final revRows = await db.rawQuery(
      'SELECT id FROM app_revisions WHERE appId = ? AND revisionNumber = ?',
      [appId, revisionId],
    );
    if (revRows.isEmpty) return [];
    if (!await isAppRevisionEffectivelyVisible(
      revRows.first['id'] as String,
      executor: db,
    )) {
      return [];
    }

    return await db.query(
      'user_app_libraries',
      where: 'app_uuid = ? AND revision_id = ? AND __deleted__ = 0',
      whereArgs: [appUuid, revisionId],
    );
  }

  /// M1.4 (design doc § Architecture 10, round 15 sibling fix): an ordinary
  /// soft-delete written directly against the library, independent of its
  /// owning revision's state — composes with the revision-derived
  /// visibility in `isUserAppLibraryEffectivelyVisible` ("a library is
  /// invisible if EITHER its own raw tombstone is set OR its owning
  /// revision is effectively deleted").
  Future<void> deleteUserAppLibrary(int libraryId) async {
    final db = await database;
    await db.update(
      'user_app_libraries',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [libraryId],
    );
  }

  // User App Library Dependencies CRUD
  Future<int> insertUserAppLibraryDependency({
    String? originalUrl,
    required String localPath,
    required List<int> bytes,
    required int libraryId,
  }) async {
    final db = await database;
    final result = await db.insert('user_app_library_dependencies', {
      'original_url': originalUrl,
      'local_path': localPath,
      'bytes': Uint8List.fromList(bytes),
      'library_id': libraryId,
    });
    return result;
  }

  /// M1.4: returns `[]` outright if the owning library is not effectively
  /// visible (own tombstone, or a non-effectively-visible owning revision —
  /// see `isUserAppLibraryEffectivelyVisible`), plus an own-row
  /// `__deleted__ = 0` filter for dependencies tombstoned directly via
  /// `deleteUserAppLibraryDependency`.
  Future<List<Map<String, dynamic>>> getUserAppLibraryDependencies(
    int libraryId,
  ) async {
    final db = await database;
    if (!await isUserAppLibraryEffectivelyVisible(libraryId, executor: db)) {
      return [];
    }

    // Use raw query with chunked BLOB reading to avoid cursor window issues
    final results = await db.rawQuery(
      '''
      SELECT id, original_url, local_path, library_id,
             CASE
               WHEN length(bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL
             END as has_blob
      FROM user_app_library_dependencies
      WHERE library_id = ? AND __deleted__ = 0
    ''',
      [libraryId],
    );

    final List<Map<String, dynamic>> processedResults = [];
    for (final map in results) {
      final newMap = Map<String, dynamic>.from(map);

      // Read BLOB data in chunks to avoid cursor window issues
      if (map['has_blob'] != null) {
        try {
          final blobData = await _readLargeBlob(
            db,
            'user_app_library_dependencies',
            'bytes',
            map['id'] as int,
          );
          newMap['bytes'] = blobData;
        } catch (e) {
          LoggerService.error(
            'Failed to read BLOB data for dependency ${map['id']}: $e',
            error: e,
          );
          newMap['bytes'] = <int>[];
        }
      } else {
        newMap['bytes'] = <int>[];
      }

      processedResults.add(newMap);
    }

    return processedResults;
  }

  /// Unscoped by app/revision (searches by `local_path` alone) — not called
  /// anywhere in `lib/` today (verified: dead code, kept for API
  /// completeness/tests). Filters only its own raw tombstone; since it has
  /// no app to resolve a fallback against, it cannot compute the full
  /// owning-revision effective-visibility chain the scoped
  /// `getDependencyByAppAndPath` below does. If this is ever revived for
  /// real use, prefer the scoped variant instead.
  Future<Map<String, dynamic>?> getUserAppLibraryDependencyByPath(
    String localPath,
  ) async {
    final db = await database;

    // Use raw query to avoid cursor window issues
    final results = await db.rawQuery(
      '''
      SELECT id, original_url, local_path, library_id,
             CASE
               WHEN length(bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL
             END as has_blob
      FROM user_app_library_dependencies
      WHERE local_path = ? AND __deleted__ = 0
    ''',
      [localPath],
    );

    if (results.isNotEmpty) {
      final result = Map<String, dynamic>.from(results.first);

      // Read BLOB data in chunks to avoid cursor window issues
      if (result['has_blob'] != null) {
        try {
          final blobData = await _readLargeBlob(
            db,
            'user_app_library_dependencies',
            'bytes',
            result['id'] as int,
          );
          result['bytes'] = blobData;
        } catch (e) {
          LoggerService.error(
            'Failed to read BLOB data for dependency ${result['id']}: $e',
            error: e,
          );
          result['bytes'] = <int>[];
        }
      } else {
        result['bytes'] = <int>[];
      }

      return result;
    }
    return null;
  }

  /// M1.4 (design doc § Architecture 10, round 15 sibling fix): an ordinary
  /// soft-delete, independent of its owning library/revision's state —
  /// composes with `isUserAppLibraryDependencyEffectivelyVisible`'s "own
  /// tombstone OR owning library not effectively visible" rule.
  Future<void> deleteUserAppLibraryDependency(int dependencyId) async {
    final db = await database;
    await db.update(
      'user_app_library_dependencies',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [dependencyId],
    );
  }

  // Get dependency by app UUID, revision ID, and local path
  //
  // M1.4: `revisionId` is an `app_revisions.revisionNumber` (see the
  // effective-visibility section doc comment above). Resolves the owning
  // app + revision first and returns null outright if either is not
  // effectively visible, before even running the join query below — same
  // shape as `getUserAppLibraries`.
  Future<Map<String, dynamic>?> getDependencyByAppAndPath(
    String appUuid,
    int revisionId,
    String localPath,
  ) async {
    final db = await database;

    final appRows = await db.query(
      'user_apps',
      columns: ['id', '__deleted__'],
      where: 'uuid = ?',
      whereArgs: [appUuid],
    );
    if (appRows.isEmpty || (appRows.first['__deleted__'] as int? ?? 0) != 0) {
      return null;
    }
    final appId = appRows.first['id'] as String;

    final revRows = await db.rawQuery(
      'SELECT id FROM app_revisions WHERE appId = ? AND revisionNumber = ?',
      [appId, revisionId],
    );
    if (revRows.isEmpty) return null;
    if (!await isAppRevisionEffectivelyVisible(
      revRows.first['id'] as String,
      executor: db,
    )) {
      return null;
    }

    final results = await db.rawQuery(
      '''
      SELECT d.id, d.original_url, d.local_path, d.library_id,
             CASE
               WHEN length(d.bytes) > 0 THEN 'BLOB_DATA'
               ELSE NULL
             END as has_blob
      FROM user_app_library_dependencies d
      JOIN user_app_libraries l ON d.library_id = l.id
      WHERE l.app_uuid = ? AND l.revision_id = ? AND d.local_path = ?
            AND d.__deleted__ = 0 AND l.__deleted__ = 0
    ''',
      [appUuid, revisionId, localPath],
    );

    if (results.isNotEmpty) {
      final result = Map<String, dynamic>.from(results.first);

      // Read BLOB data in chunks to avoid cursor window issues
      if (result['has_blob'] != null) {
        try {
          final blobData = await _readLargeBlob(
            db,
            'user_app_library_dependencies',
            'bytes',
            result['id'] as int,
          );
          result['bytes'] = blobData;
        } catch (e) {
          LoggerService.error(
            'Failed to read BLOB data for dependency ${result['id']}: $e',
            error: e,
          );
          result['bytes'] = <int>[];
        }
      } else {
        result['bytes'] = <int>[];
      }

      return result;
    }
    return null;
  }

  // Helper method to read TEXT data in chunks to avoid cursor window issues
  Future<String> _readLargeString(
    Database db,
    String table,
    String column,
    String id, {
    String idColumn = 'id',
    int chunkSize = syncLargeColumnThreshold,
  }) async {
    // SQLite length(TEXT)/substr(TEXT) stop at embedded NUL and count code
    // points rather than UTF-8 bytes. Reuse the validated byte-slice reader
    // so chunks fit Android's CursorWindow even for multibyte text.
    final sizes = await db.rawQuery(
      'SELECT length(CAST("$column" AS BLOB)) AS text_size '
      'FROM "$table" WHERE "$idColumn" = ?',
      [id],
    );
    if (sizes.isEmpty) {
      throw StateError('Missing row while reading $table.$column ($id)');
    }
    return readLargeTextColumn(
      db,
      table: table,
      column: column,
      idColumn: idColumn,
      entityId: id,
      totalLength: sizes.single['text_size'] as int? ?? 0,
      chunkSize: chunkSize,
    );
  }

  Future<List<int>> _readLargeBlob(
    Database db,
    String table,
    String column,
    int id, {
    String idColumn = 'id',
    int chunkSize = 1024 * 1024, // 1MB
  }) async {
    final List<int> allBytes = [];

    try {
      // Get the total size of the BLOB
      final sizeResult = await db.rawQuery(
        'SELECT length($column) as blob_size FROM $table WHERE $idColumn = ?',
        [id],
      );

      if (sizeResult.isEmpty) {
        return <int>[];
      }

      final int totalSize = sizeResult.first['blob_size'] as int;

      // Read BLOB in chunks
      for (int offset = 0; offset < totalSize; offset += chunkSize) {
        final int currentChunkSize = (offset + chunkSize > totalSize)
            ? totalSize - offset
            : chunkSize;

        final chunkResult = await db.rawQuery(
          'SELECT substr($column, ?, ?) as chunk FROM $table WHERE $idColumn = ?',
          [offset + 1, currentChunkSize, id],
        );

        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as Uint8List;
          allBytes.addAll(chunk);
        }
      }

      return allBytes;
    } catch (e) {
      LoggerService.error(
        'Error reading large blob from $table.$column: $e',
        error: e,
      );
      return <int>[];
    }
  }

  // Conversations CRUD
  Future<String> insertConversation(Conversation conversation) async {
    final db = await database;
    final json = conversation.toJson();
    json['createdAt'] = conversation.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = conversation.updatedAt.millisecondsSinceEpoch;
    json['isArchived'] = conversation.isArchived ? 1 : 0;
    json['noteIds'] = '[]'; // Always empty, managed by mapping table

    await db.insert('conversations', json);
    return conversation.id;
  }

  /// SQL testing whether the conversation in scope (`c`) carries one tag, named
  /// by a `?` placeholder. A correlated EXISTS rather than a join, so ANDing
  /// and ORing several of them cannot multiply rows — which is what lets the
  /// `all-spaces` escape be a plain OR.
  ///
  /// `t.__deleted__ = 0` matches the tag-name join below (M1.9): a tombstoned
  /// tag row must not satisfy a scope.
  static const String _conversationHasTagExists =
      'EXISTS (SELECT 1 FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId '
      'WHERE ct.conversationId = c.id AND t.name = ? AND t.__deleted__ = 0)';

  /// Conversations, newest first.
  ///
  /// [tagNames] are the **caller's own** requirement and are ANDed
  /// unconditionally: a match must carry every one of them, in or out of a
  /// Space.
  ///
  /// [scopeTags] are the active Space's tags. They are ANDed among themselves
  /// in a group of their own, and [includeAllSpacesTag] ORs the reserved
  /// `all-spaces` tag around **that group only**:
  ///
  ///     t1 AND t2 AND ((s1 AND s2) OR all-spaces)
  ///
  /// so a conversation marked as visible everywhere shows up inside a Space
  /// (design §4.12) while the caller's own chips still have to match. This
  /// mirrors [searchNotesFTS] deliberately, and for the same reason: merging
  /// the two lists and ORing around the whole conjunction turns "tag `urgent`
  /// in this Space" into "tag `urgent`, OR anything marked all-spaces", which
  /// returns every cross-Space conversation, none of which has `urgent`. That
  /// is the M5 blocker, and the two-list signature is what stops it recurring.
  ///
  /// The flag does nothing without [scopeTags] — with no Space there is no
  /// scope to escape, so it fails closed. Left unset, the query is exactly
  /// what it has always been.
  ///
  ///
  /// M1.12: `c.__deleted__ = 0` is now unconditional (not gated behind
  /// [includeEmpty]) — a conversation the user explicitly deleted via
  /// `deleteConversation`/`deleteConversationExplicitly` must never
  /// reappear for any caller, unlike the derived-empty/redundant exclusion
  /// below, which some callers (e.g. `getConversationTree`) deliberately
  /// opt out of via `includeEmpty: true`.
  ///
  /// `includeEmpty: false` now excludes BOTH conditions
  /// `_cleanupEmptyConversations` used to physically real-delete on
  /// ("truly empty" — zero live message mappings — AND "redundant" — every
  /// message already owned by an earlier conversation, no notes of its
  /// own) — see `_findEmptyOrRedundantConversationIds`'s and
  /// `_cleanupEmptyConversations`'s own doc comments for the full M1.12
  /// design rationale for why this read-time filter, not a write, is now
  /// what makes both conditions take effect. This is a real, disclosed
  /// behavior change from pre-M1.12: `includeEmpty: false` previously only
  /// ever excluded the "truly empty" condition here (the "redundant" one
  /// was only ever enforced by `_cleanupEmptyConversations` getting around
  /// to a physical delete, a timing-dependent gap this closes) and
  /// `includeEmpty: true` callers previously saw either condition
  /// inconsistently, depending on whether that background cleanup had run
  /// yet — now consistently one way or the other, no more flicker.
  Future<List<Conversation>> getAllConversations({
    Duration? maxAge,
    List<String>? conversationIds,
    List<String>? tagNames,
    List<String>? scopeTags,
    bool includeEmpty = true,
    bool includeAllSpacesTag = false,
  }) async {
    final db = await database;

    final requiredTags = tagNames ?? const <String>[];
    final spaceTags = scopeTags ?? const <String>[];

    final filters = <String>['c.__deleted__ = 0'];
    final filterArgs = <dynamic>[];

    if (maxAge != null) {
      filters.add('c.updatedAt >= ?');
      filterArgs.add(DateTime.now().subtract(maxAge).millisecondsSinceEpoch);
    }

    if (conversationIds != null && conversationIds.isNotEmpty) {
      final idsPlaceholder = List.filled(conversationIds.length, '?').join(',');
      filters.add('c.id IN ($idsPlaceholder)');
      filterArgs.addAll(conversationIds);
    }

    // M1.12: the empty/redundant exclusion is resolved ONCE, into `filters`,
    // so every branch below inherits it. It subsumes the plain "has at least
    // one message mapping" EXISTS this used to carry per-branch: that only
    // covered the "truly empty" condition, while this also drops conversations
    // whose every message is already owned by an earlier one.
    if (!includeEmpty) {
      final hiddenIds = await _findEmptyOrRedundantConversationIds(db);
      if (hiddenIds.isNotEmpty) {
        final hiddenPlaceholder = List.filled(hiddenIds.length, '?').join(',');
        filters.add('c.id NOT IN ($hiddenPlaceholder)');
        filterArgs.addAll(hiddenIds);
      }
    }

    if (spaceTags.isNotEmpty) {
      // Correlated EXISTS instead of the join+HAVING shape below: an OR cannot
      // be expressed as a `COUNT(DISTINCT t.name) = ?` and a join would return
      // one row per matching tag.
      String conjunctionOf(List<String> names) => List.filled(
        names.length,
        _conversationHasTagExists,
      ).join('\n          AND ');

      final tagSegments = <String>[];
      final tagArgs = <dynamic>[];

      // The caller's own tags, outside the OR: they narrow within the Space,
      // they are never escaped by `all-spaces` (A7).
      if (requiredTags.isNotEmpty) {
        tagSegments.add(conjunctionOf(requiredTags));
        tagArgs.addAll(requiredTags);
      }

      if (includeAllSpacesTag) {
        tagSegments.add(
          '((${conjunctionOf(spaceTags)})'
          '\n          OR $_conversationHasTagExists)',
        );
        tagArgs
          ..addAll(spaceTags)
          ..add(_allSpacesTag);
      } else {
        tagSegments.add(conjunctionOf(spaceTags));
        tagArgs.addAll(spaceTags);
      }

      final whereSegments = <String>[...tagSegments, ...filters];

      final maps = await db.rawQuery(
        '''
        SELECT c.*
        FROM conversations c
        WHERE ${whereSegments.join(' AND ')}
        ORDER BY c.updatedAt DESC
      ''',
        <dynamic>[...tagArgs, ...filterArgs],
      );
      return maps.map((map) => _mapToConversation(map)).toList();
    }

    if (tagNames != null && tagNames.isNotEmpty) {
      final tagPlaceholders = List.filled(tagNames.length, '?').join(',');
      // M1.9: `t.__deleted__ = 0` filters out a tombstoned tag row.
      final whereSegments = <String>[
        't.name IN ($tagPlaceholders)',
        't.__deleted__ = 0',
      ];
      whereSegments.addAll(filters);

      final query =
          '''
        SELECT c.*
        FROM conversations c
        JOIN conversation_tags ct ON c.id = ct.conversationId
        JOIN tags t ON t.id = ct.tagId
        WHERE ${whereSegments.join(' AND ')}
        GROUP BY c.id
        HAVING COUNT(DISTINCT t.name) = ?
        ORDER BY c.updatedAt DESC
      ''';

      final queryArgs = <dynamic>[...tagNames, ...filterArgs, tagNames.length];

      final maps = await db.rawQuery(query, queryArgs);
      return maps.map((map) => _mapToConversation(map)).toList();
    }

    // Prepare simple query filters
    final whereClause = filters
        .map((clause) => clause.replaceAll('c.', ''))
        .join(' AND ');

    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      where: whereClause,
      whereArgs: filterArgs.isEmpty ? null : filterArgs,
      orderBy: 'updatedAt DESC',
    );

    return maps.map((map) => _mapToConversation(map)).toList();
  }

  /// Gets the first and last message of a conversation for preview purposes
  /// efficiently using LIMIT 1 queries.
  Future<List<ConversationMessage>> getConversationPreviewMessages(
    String conversationId,
  ) async {
    final db = await database;

    // Get the first message
    final firstMsgMaps = await db.rawQuery(
      '''
      SELECT cm.*
      FROM conversation_messages cm
      JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp ASC
      LIMIT 1
      ''',
      [conversationId],
    );

    if (firstMsgMaps.isEmpty) return [];

    // Get the last message
    final lastMsgMaps = await db.rawQuery(
      '''
      SELECT cm.*
      FROM conversation_messages cm
      JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp DESC
      LIMIT 1
      ''',
      [conversationId],
    );

    final messages = <ConversationMessage>[];
    final firstMap = Map<String, dynamic>.from(firstMsgMaps.first);
    await _populateMessageAttachmentPaths(db, firstMap);
    messages.add(_mapToConversationMessage(firstMap, conversationId));

    // Only add last message if it's different from the first
    if (lastMsgMaps.isNotEmpty) {
      final lastMap = Map<String, dynamic>.from(lastMsgMaps.first);
      if (lastMap['id'] != firstMap['id']) {
        await _populateMessageAttachmentPaths(db, lastMap);
        messages.add(_mapToConversationMessage(lastMap, conversationId));
      }
    }

    return messages;
  }

  Future<Conversation?> getConversation(String id) async {
    final db = await database;
    // M1.12: `__deleted__ = 0` -- a straightforward entity tombstone check,
    // no derived-empty/redundant filtering here (unlike getAllConversations'
    // includeEmpty: false) -- a caller doing a direct by-id lookup (e.g.
    // right after creating a brand-new, still message-less conversation)
    // must still be able to find it.
    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return _mapToConversation(maps.first);
  }

  Future<void> updateConversation(Conversation conversation) async {
    final db = await database;
    final json = conversation.toJson();
    json['createdAt'] = conversation.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = conversation.updatedAt.millisecondsSinceEpoch;
    json['isArchived'] = conversation.isArchived ? 1 : 0;
    json['noteIds'] = '[]'; // Always empty, managed by mapping table

    await db.update(
      'conversations',
      json,
      where: 'id = ?',
      whereArgs: [conversation.id],
    );
  }

  // M1.12: tombstone write, not a real delete — see the doc comment above
  // `_createConversationsTable`. The `conversations -> {
  // conversation_message_mapping, conversation_note_mapping,
  // conversation_tags }` `ON DELETE CASCADE` no longer fires once the
  // final statement below became an `UPDATE`, so all three OR-Set
  // membership tables now need an explicit real-delete replacement — all
  // three are covered by `_purgeMembershipRowsForConversationIds` (new this
  // milestone, shared with `deleteConversationExplicitly`/
  // `_cleanupEmptyConversations`/`deleteEmptyConversations`), which
  // subsumes what the standalone `deleteConversationNoteMappings` used to
  // additionally be called for here — calling both was a genuine, harmless
  // but confusing redundancy (found in review) since
  // `_purgeMembershipRowsForConversationIds` already deletes
  // `conversation_note_mapping` too; only the latter is called now, so
  // `conversation_note_mapping` cleanup happens exactly once. This does NOT
  // touch `conversation_messages` rows themselves — a deleted conversation's
  // messages are deliberately left as-is (same pre-existing behavior as
  // before this milestone), becoming invisible via `getConversationMessages`
  // et al. only if/when they lose every live membership, which is exactly
  // what `computeConversationMessageVisibility`'s derived formula is for.
  Future<void> deleteConversation(String id) async {
    final db = await database;
    await _purgeMembershipRowsForConversationIds(db, {id});
    await db.update(
      'conversations',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // M1.12 (design doc § Phased delivery, M1.12; § Architecture 6, "orphan-
  // message cleanup" / derived effective-deletedness): mirrors
  // `computeAppRevisionVisibility`'s role for the User-App family
  // (M1.4) — a derived, always-recomputed-fresh visibility check consulted
  // by read paths instead of trusting a raw tombstone column alone — but
  // for a genuinely different, harder shape: membership-derived rather
  // than fallback-derived, with no exact precedent elsewhere in this
  // codebase (see the design doc's own M1.12 scoping note).
  //
  // A `conversation_messages` row's EFFECTIVE deletedness is:
  //
  //   effectiveDeleted(m) = m.__deleted__ AND NOT (EXISTS a live
  //                         conversation_message_mapping row referencing m)
  //
  // equivalently, effectiveVisible(m) = NOT m.__deleted__ OR (EXISTS a
  // live conversation_message_mapping row referencing m) — a message with
  // ANY live membership is never effectively deleted, regardless of what
  // its raw `__deleted__` bit says or in what order the tombstone write
  // and the membership add/remove happened. This is round 14's fix for
  // the cross-subject tombstone-vs-concurrent-membership-add race:
  // `conversation_messages.__deleted__` and `conversation_message_mapping`
  // are different CRDT subjects entirely, so the ordinary per-field
  // delete/undelete conflict rule (which only ever compares two operations
  // on the *same* field) has no mechanism to relate them — deriving
  // visibility instead of writing it is what actually closes the race:
  // the moment a live membership becomes known, by whatever path and
  // whenever that happens, the message's effective state is immediately,
  // always correct, with no compensating write needed at all.
  //
  // Deliberately NOT `NOT m.__deleted__ AND EXISTS(...)`: a message that
  // was NEVER explicitly tombstoned (raw `__deleted__ = 0`) but has lost
  // every live membership — e.g. `deleteConversation` real-deleted its
  // only `conversation_message_mapping` row via
  // `_purgeMembershipRowsForConversationIds`, but nothing in this
  // milestone's scope ever writes a tombstone for the now-membership-less
  // message itself — is still classified EFFECTIVELY VISIBLE by this
  // formula. This is intentional, not an oversight: § Architecture 6
  // describes orphan detection as a SEPARATE, future (M2+, no sync engine
  // yet) mechanism whose own job is to WRITE the `__deleted__` tombstone
  // once it independently decides a message is orphaned ("zero live
  // memberships and zero live parent-edges... a different TRIGGER for
  // when the tombstone gets written... instead of a direct user action").
  // This milestone builds only the READ-side half of that design (this
  // derived formula), not the write-side orphan-detection GC pass, which
  // stays out of scope for M1 — same physical-purge/GC deferral every
  // other soft-delete conversion in this effort already makes. In
  // practice, an un-tombstoned, membership-less message is simply never
  // reachable through any conversation-scoped read path anyway (they all
  // join through `conversation_message_mapping`, which by construction
  // has no row for it) — this formula only matters for
  // `getConversationMessage`, the one direct-by-id lookup with no such
  // implicit join guarantee.
  Future<bool> computeConversationMessageVisibility(
    String messageId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final rows = await db.rawQuery(
      'SELECT __deleted__ FROM conversation_messages WHERE id = ?',
      [messageId],
    );
    if (rows.isEmpty) return false; // nonexistent message: never visible
    final rawDeleted = (rows.first['__deleted__'] as int? ?? 0) != 0;
    if (!rawDeleted) return true;

    final liveMembership = await db.rawQuery(
      'SELECT 1 FROM conversation_message_mapping WHERE messageId = ? LIMIT 1',
      [messageId],
    );
    return liveMembership.isNotEmpty;
  }

  // Conversation Messages CRUD
  Future<String> insertConversationMessage(ConversationMessage message) async {
    final db = await database;
    final json = message.toJson();
    json['timestamp'] = message.timestamp.millisecondsSinceEpoch;
    json['metadata'] = message.metadata != null
        ? jsonEncode(message.metadata)
        : null;
    // Remove attachmentPaths and conversationId as they're not in the database schema
    json.remove('attachmentPaths');
    json.remove('conversationId');

    await db.insert('conversation_messages', json);
    return message.id;
  }

  // M1.12: deliberately does NOT add a `cm.__deleted__ = 0` filter — the
  // `INNER JOIN conversation_message_mapping` below already requires a
  // live mapping row to return a message at all, which already IS the
  // "has live membership" condition `computeConversationMessageVisibility`
  // derives effective visibility from. Adding a raw `__deleted__` filter
  // here would be actively WRONG, not merely redundant: it would hide a
  // message that has a live mapping but also carries a stale/racing
  // tombstone bit, exactly the case the derived-visibility design exists
  // to keep visible (see that function's own doc comment). Same reasoning
  // applies to `getConversationPreviewMessages`/`getMessagesForConversations`
  // below/elsewhere in this file — none of them need or should gain this
  // filter.
  Future<List<ConversationMessage>> getConversationMessages(
    String conversationId,
  ) async {
    final db = await database;
    // Join with conversation_message_mapping to get messages for this conversation
    // EXCLUDE metadata from the main query to avoid CursorWindow size limits
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT cm.id, cm.type, cm.content, cm.timestamp, cm.modelUsed
      FROM conversation_messages cm
      INNER JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
      WHERE cmm.conversationId = ?
      ORDER BY cm.timestamp ASC
    ''',
      [conversationId],
    );

    final messages = <ConversationMessage>[];

    for (final map in maps) {
      // Create a mutable copy of the map
      final messageMap = Map<String, dynamic>.from(map);

      // Fetch metadata separately
      try {
        final metadataResult = await db.query(
          'conversation_messages',
          columns: ['metadata'],
          where: 'id = ?',
          whereArgs: [messageMap['id']],
        );

        if (metadataResult.isNotEmpty) {
          messageMap['metadata'] = metadataResult.first['metadata'];
        }
      } catch (e) {
        // Fallback: If fetching full metadata fails (e.g. single row too big),
        // try to read it in chunks using substr.
        // Note: This is a last resort and might be slow.
        LoggerService.error(
          'Error fetching metadata for message ${messageMap['id']}: $e. Attempting chunked read.',
        );
        try {
          messageMap['metadata'] = await _readLargeMetadata(
            db,
            messageMap['id'] as String,
          );
        } catch (e2) {
          LoggerService.error('Failed to read large metadata: $e2');
          // Proceed without metadata rather than crashing the whole view
        }
      }

      await _populateMessageAttachmentPaths(db, messageMap);
      messages.add(_mapToConversationMessage(messageMap, conversationId));
    }

    return messages;
  }

  // Helper to read potentially huge metadata in chunks
  Future<String?> _readLargeMetadata(Database db, String messageId) async {
    final sb = StringBuffer();
    int offset = 1; // SQLite substr is 1-based
    const chunkSize = 1000000; // 1MB chunks

    while (true) {
      final List<Map<String, dynamic>> result = await db.rawQuery(
        'SELECT substr(metadata, ?, ?) as chunk FROM conversation_messages WHERE id = ?',
        [offset, chunkSize, messageId],
      );

      if (result.isEmpty || result.first['chunk'] == null) break;

      final chunk = result.first['chunk'] as String;
      if (chunk.isEmpty) break;

      sb.write(chunk);
      offset += chunkSize;

      // If chunk is smaller than requested, we reached the end
      if (chunk.length < chunkSize) break;
    }

    return sb.isNotEmpty ? sb.toString() : null;
  }

  // M1.12: the one message-content read path with no `JOIN
  // conversation_message_mapping` of its own (a direct by-id lookup), so it
  // must explicitly consult `computeConversationMessageVisibility` — see
  // that function's own doc comment, and `getConversationMessages`' doc
  // comment above for why every OTHER message-content read path does not
  // need (and must not gain) an equivalent check.
  Future<ConversationMessage?> getConversationMessage(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversation_messages',
      columns: [
        'id',
        'type',
        'content',
        'timestamp',
        'modelUsed',
      ], // Exclude metadata
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    if (!await computeConversationMessageVisibility(id, executor: db)) {
      return null;
    }

    // Get the conversationId from the mapping table
    final mappingResult = await db.query(
      'conversation_message_mapping',
      where: 'messageId = ?',
      whereArgs: [id],
      limit: 1,
    );

    final conversationId = mappingResult.isNotEmpty
        ? mappingResult.first['conversationId'] as String
        : '';

    final messageMap = Map<String, dynamic>.from(maps.first);

    // Fetch metadata separately
    try {
      final metadataResult = await db.query(
        'conversation_messages',
        columns: ['metadata'],
        where: 'id = ?',
        whereArgs: [id],
      );

      if (metadataResult.isNotEmpty) {
        messageMap['metadata'] = metadataResult.first['metadata'];
      }
    } catch (e) {
      LoggerService.error(
        'Error fetching metadata for message $id: $e. Attempting chunked read.',
      );
      try {
        messageMap['metadata'] = await _readLargeMetadata(db, id);
      } catch (e2) {
        LoggerService.error('Failed to read large metadata: $e2');
      }
    }

    await _populateMessageAttachmentPaths(db, messageMap);
    return _mapToConversationMessage(messageMap, conversationId);
  }

  Future<void> updateConversationMessage(ConversationMessage message) async {
    final db = await database;
    final json = message.toJson();
    json['timestamp'] = message.timestamp.millisecondsSinceEpoch;
    json['metadata'] = message.metadata != null
        ? jsonEncode(message.metadata)
        : null;
    // Remove attachmentPaths and conversationId as they're not in the database schema
    json.remove('attachmentPaths');
    json.remove('conversationId');

    await db.update(
      'conversation_messages',
      json,
      where: 'id = ?',
      whereArgs: [message.id],
    );
  }

  // M1.12: delegates to `_deleteMessagesBatch` (a single-id batch) instead
  // of issuing its own real delete — this function had no explicit
  // cleanup of `conversation_attachments`/`message_parents`/
  // `conversation_message_mapping` of its own before this milestone,
  // relying entirely on the `conversation_messages -> {...}`
  // `ON DELETE CASCADE` to clean them up; that cascade stops firing the
  // moment `conversation_messages`' own deletion becomes an `UPDATE`
  // (exactly the M1.10-style cascade-dependency risk this milestone's own
  // scope explicitly calls out). Delegating reuses `_deleteMessagesBatch`'s
  // already-correct explicit replacement for all three, rather than
  // duplicating that logic here — this function's own delete scope
  // (this one message id, not its subtree) is unchanged, since
  // `_deleteMessagesBatch` alone (without `_getMessageSubtree` first,
  // which only `deleteMessageWithSubtree` does) never recurses to
  // children either. (Not currently called from anywhere in `lib/` outside
  // this file — verified by grep — but converted correctly regardless,
  // matching this milestone's own scope.)
  Future<void> deleteConversationMessage(String id) async {
    await _deleteMessagesBatch([id]);
  }

  // Comprehensive message deletion with subtree cleanup
  Future<void> deleteMessageWithSubtree(String messageId) async {
    LoggerService.info(
      'Starting deletion of message $messageId and its subtree',
    );

    // 1. Find all messages in the subtree (children recursively)
    final messagesToDelete = await _getMessageSubtree(messageId);
    LoggerService.info(
      'Found ${messagesToDelete.length} messages to delete in subtree',
    );

    // 2. Delete all related data efficiently
    await _deleteMessagesBatch(messagesToDelete);

    // 3. Find conversations that now have no messages and delete them
    await _cleanupEmptyConversations();

    LoggerService.info(
      'Successfully deleted message $messageId and its subtree',
    );
  }

  // Efficiently delete a batch of messages and all their related data
  Future<void> _deleteMessagesBatch(List<String> messageIds) async {
    if (messageIds.isEmpty) return;

    final db = await database;

    // Create placeholders for IN clause
    final placeholders = messageIds.map((_) => '?').join(',');

    // 1. Tombstone attachments for all messages.
    //
    // M1.8 left this as a real delete, deliberately, "deferred to M1.12
    // when conversation_messages itself is converted" (see the doc comment
    // above `_createConversationAttachmentsTable`) — the M1.8-era
    // justification was that `conversation_messages` still got a real hard
    // delete right below, so tombstoning attachments alone would leave
    // stale tombstones for messages that were already permanently gone,
    // with nothing ever cleaning them up. **M1.12**: that premise no
    // longer holds — step 4 below now tombstones `conversation_messages`
    // too, so both rows go through the exact same soft-delete-now,
    // physical-purge-later treatment as every other converted entity in
    // this effort, closing the gap instead of reproducing it under a new
    // milestone number. `conversation_attachments` already has `__deleted__`
    // (M1.8) and every read path already filters on it
    // (getConversationAttachments/_populateMessageAttachmentPaths), so this
    // needed no schema work, only this logic change.
    await db.update(
      'conversation_attachments',
      {'__deleted__': 1},
      where: 'messageId IN ($placeholders)',
      whereArgs: messageIds,
    );

    // 2. Delete message-parent relationships for all messages. OR-Set
    // membership table (§ Architecture, the five-table list) — real
    // deletion stays correct and unaffected by this milestone.
    await db.delete(
      'message_parents',
      where:
          'messageId IN ($placeholders) OR parentMessageId IN ($placeholders)',
      whereArgs: [...messageIds, ...messageIds],
    );

    // 3. Delete conversation-message mappings for all messages. OR-Set
    // membership table — this IS the `set_remove` that makes
    // `computeConversationMessageVisibility`'s derived formula correctly
    // report these messages as having zero live memberships, so it must
    // stay a real delete, not a tombstone, same as message_parents above.
    await db.delete(
      'conversation_message_mapping',
      where: 'messageId IN ($placeholders)',
      whereArgs: messageIds,
    );

    // 4. Tombstone the messages themselves. M1.12: was a real delete;
    // converted alongside step 1 above (see that step's doc comment).
    // Combined with step 3 having just real-deleted every live membership
    // for these exact ids, `computeConversationMessageVisibility` reports
    // every one of these messages as effectively deleted immediately after
    // this call returns, consistent with the derived formula (raw
    // __deleted__=1 AND zero live memberships).
    await db.update(
      'conversation_messages',
      {'__deleted__': 1},
      where: 'id IN ($placeholders)',
      whereArgs: messageIds,
    );
  }

  // Get all messages in the subtree of a given message using proper recursive traversal
  Future<List<String>> _getMessageSubtree(String messageId) async {
    final db = await database;
    final messagesToDelete = <String>{};

    // Recursive function to traverse the tree
    Future<void> traverseSubtree(String currentMessageId) async {
      if (messagesToDelete.contains(currentMessageId)) {
        return; // Already processed
      }

      messagesToDelete.add(currentMessageId);

      // Find all children of current message
      final children = await db.query(
        'message_parents',
        where: 'parentMessageId = ?',
        whereArgs: [currentMessageId],
      );

      // Recursively process each child
      for (final child in children) {
        final childId = child['messageId'] as String;
        await traverseSubtree(childId);
      }
    }

    await traverseSubtree(messageId);
    return messagesToDelete.toList();
  }

  // M1.12: finds the same two candidate sets `_cleanupEmptyConversations`/
  // `deleteEmptyConversations` used to physically `DELETE FROM
  // conversations` on — "truly empty" (zero live message mappings) and,
  // when [includeRedundant], "redundant" (every message already owned by
  // an earlier conversation, and zero notes of its own) — but as a pure
  // SELECT, for a caller to use as a READ-time exclusion filter
  // ([getAllConversations]'s `includeEmpty: false`) or as input to the
  // now-write-nothing-to-`conversations` cleanup functions below. See
  // `_cleanupEmptyConversations`'s own doc comment for why this milestone
  // deliberately stopped writing `conversations.__deleted__` from either
  // condition. [updatedBeforeMillis] restricts the "truly empty" condition
  // to conversations whose `updatedAt` predates it (`deleteEmptyConversations`'s
  // own age gate); it does not apply to the "redundant" condition, matching
  // that condition's pre-M1.12 scope (only `_cleanupEmptyConversations` — not
  // `deleteEmptyConversations` — ever implemented it).
  //
  // **Accepted performance tradeoff, recorded deliberately, not a silent
  // gap (review finding)**: before M1.12, this pair of queries only ran
  // inside `_cleanupEmptyConversations`, an infrequent, write-triggered
  // background pass (once per message-subtree deletion). Since
  // `getAllConversations(includeEmpty: false)` now calls this function on
  // every invocation to compute its read-time exclusion filter, and that
  // path is a real UI hot path (e.g. `linear_history_dialog.dart`'s
  // conversation-history listing), the "redundant" query in particular — a
  // window-function/CTE join over `conversation_message_mapping` and
  // `conversation_note_mapping` — now runs far more often than before, on
  // every list load rather than only after an edit. This is an intentional
  // consequence of the cross-CRDT-subject-race fix (§ Architecture 6,
  // round 14's pattern): making "empty/redundant" a derived, always-fresh
  // read-time property is what closes the race a cached/written value
  // would reopen, and that correctness property is worth the extra query
  // cost at this app's scale (a personal note-taking app, not a multi-
  // tenant service). If this ever becomes a measured bottleneck, the fix is
  // an index-assisted or incrementally-maintained cache of the derived set
  // — NOT reverting to writing `conversations.__deleted__` eagerly, which
  // would reintroduce the race this design exists to avoid.
  Future<Set<String>> _findEmptyOrRedundantConversationIds(
    DatabaseExecutor db, {
    bool includeRedundant = true,
    int? updatedBeforeMillis,
  }) async {
    final ids = <String>{};

    final emptyWhere = StringBuffer('cmm.conversationId IS NULL');
    final emptyArgs = <Object?>[];
    if (updatedBeforeMillis != null) {
      emptyWhere.write(' AND c.updatedAt < ?');
      emptyArgs.add(updatedBeforeMillis);
    }
    final emptyConversations = await db.rawQuery('''
      SELECT c.id
      FROM conversations c
      LEFT JOIN conversation_message_mapping cmm ON c.id = cmm.conversationId
      WHERE $emptyWhere
    ''', emptyArgs);
    ids.addAll(emptyConversations.map((r) => r['id'] as String));

    if (includeRedundant) {
      final redundantConversations = await db.rawQuery('''
        WITH message_mappings AS (
          SELECT
            cmm.conversationId,
            cmm.messageId,
            ROW_NUMBER() OVER (
              PARTITION BY cmm.messageId
              ORDER BY c.createdAt ASC, c.id ASC
            ) AS messageRank
          FROM conversation_message_mapping cmm
          JOIN conversations c ON c.id = cmm.conversationId
        ),
        conversation_note_counts AS (
          SELECT conversationId, COUNT(*) AS noteCount
          FROM conversation_note_mapping
          GROUP BY conversationId
        )
        SELECT mm.conversationId AS id
        FROM message_mappings mm
        LEFT JOIN conversation_note_counts cnc ON mm.conversationId = cnc.conversationId
        GROUP BY mm.conversationId, COALESCE(cnc.noteCount, 0)
        HAVING SUM(CASE WHEN mm.messageRank = 1 THEN 1 ELSE 0 END) = 0
           AND COALESCE(cnc.noteCount, 0) = 0
      ''');
      ids.addAll(redundantConversations.map((r) => r['id'] as String));
    }

    return ids;
  }

  // M1.12: real-deletes the three OR-Set membership rows
  // (`conversation_tags`, `conversation_note_mapping`,
  // `conversation_message_mapping`) for every id in [conversationIds] —
  // safe unconditionally, since these are OR-Set membership tables
  // (§ Architecture, the five-table list) whose real deletion is always
  // the correct local `set_remove` representation, regardless of the
  // parent `conversations` row's own tombstone/visibility state. Used by
  // `deleteConversation`/`deleteConversationExplicitly` (as the explicit
  // cascade replacement for the `ON DELETE CASCADE` that stopped firing
  // once those functions' own `conversations` delete became an `UPDATE`)
  // and by `_cleanupEmptyConversations`/`deleteEmptyConversations` (as
  // garbage collection for a conversation that
  // [_findEmptyOrRedundantConversationIds] found and that
  // [getAllConversations]'s own read-time filter has already made
  // permanently unreachable through the UI — see that function's own doc
  // comment for why this milestone deliberately stopped tombstoning
  // `conversations` itself for this case).
  Future<void> _purgeMembershipRowsForConversationIds(
    DatabaseExecutor db,
    Set<String> conversationIds,
  ) async {
    if (conversationIds.isEmpty) return;
    final placeholders = List.filled(conversationIds.length, '?').join(',');
    final args = conversationIds.toList();
    await db.delete(
      'conversation_tags',
      where: 'conversationId IN ($placeholders)',
      whereArgs: args,
    );
    await db.delete(
      'conversation_note_mapping',
      where: 'conversationId IN ($placeholders)',
      whereArgs: args,
    );
    await db.delete(
      'conversation_message_mapping',
      where: 'conversationId IN ($placeholders)',
      whereArgs: args,
    );
  }

  // M1.12 design decision (flagged by the design doc's own M1.12 scoping
  // note as a genuinely previously-unresolved gap, not a solved problem
  // mechanically implemented here): this function — and
  // `deleteEmptyConversations` below — deliberately do NOT write
  // `conversations.__deleted__` for the "empty"/"redundant" conversations
  // they find, even though every other converted function in this effort
  // writes a tombstone at its equivalent point. A plain "real-delete-to-
  // tombstone swap" here would reintroduce, at the `conversations` level,
  // exactly the cross-subject race round 14 already fixed at the
  // `conversation_messages` level (see `computeConversationMessageVisibility`'s
  // doc comment): if this function eagerly wrote `__deleted__=1` to a
  // conversation it currently (locally) sees as empty, and a CONCURRENT
  // device (once sync lands, M2+) had, at the same time, added a genuine
  // new message to that same conversation (e.g. resuming a template
  // conversation created with no messages yet), the two writes — this
  // device's `conversations.__deleted__` tombstone and the other device's
  // `conversation_message_mapping` `set_add` — are writes to two DIFFERENT
  // CRDT subjects entirely, so the ordinary per-field delete/undelete
  // conflict rule has no mechanism to relate them; the conversation would
  // stay permanently, wrongly tombstoned even after the new message syncs
  // in, with no compensating operation ever firing. **Fix, generalizing
  // the exact same derived-visibility pattern**: "empty"/"redundant" is
  // instead a purely DERIVED, always-recomputed-at-read-time property —
  // see `getAllConversations`'s `includeEmpty: false` branch, which now
  // calls the same `_findEmptyOrRedundantConversationIds` this function
  // does, as a read-time exclusion filter rather than trusting a stored
  // bit. `conversations.__deleted__` remains reserved exclusively for
  // actual, explicit, user-initiated deletion
  // (`deleteConversation`/`deleteConversationExplicitly`); it is never
  // written by either of the two functions below.
  //
  // What these functions still usefully do, given they no longer write
  // `conversations.__deleted__` at all: real-delete the three OR-Set
  // membership rows for each candidate id, via
  // `_purgeMembershipRowsForConversationIds` — safe at any time (an
  // ordinary `set_remove`, not subject to the tombstone-write race above),
  // and prevents those tables from accumulating unbounded stale rows for a
  // conversation the UI will never show again via
  // `getAllConversations(includeEmpty: false)` regardless. The
  // `conversations` row itself is deliberately left physically present
  // (not tombstoned, not deleted) — an accepted, disclosed residual,
  // exactly mirroring how every other soft-delete conversion in this
  // effort defers physical row reclamation to a future GC milestone (no
  // sync engine, no GC pass yet, same M1 scope boundary everywhere else in
  // this file). A row left this way remains visible to any
  // `includeEmpty: true` caller (e.g. `getConversationTree`) — a real,
  // disclosed behavior change from pre-M1.12, where such a conversation
  // was only visible until whichever of these two functions next happened
  // to run and physically remove it (a timing-dependent inconsistency this
  // change replaces with a single, always-consistent rule).
  Future<void> _cleanupEmptyConversations() async {
    final db = await database;
    final ids = await _findEmptyOrRedundantConversationIds(db);
    if (ids.isEmpty) return;

    await _purgeMembershipRowsForConversationIds(db, ids);
    LoggerService.info(
      'Purged membership rows for ${ids.length} derived-empty/redundant '
      'conversations (M1.12: the conversations row itself is intentionally '
      'left untouched — see doc comment)',
    );
  }

  // Delete conversation (only if explicitly requested)
  //
  // M1.12: the final `conversations` statement is now a tombstone write,
  // not a real delete — see the doc comment above `_createConversationsTable`.
  // The message loop below already real-deletes every
  // `conversation_message_mapping` row for this conversationId as a side
  // effect of `deleteMessageWithSubtree` -> `_deleteMessagesBatch` (keyed
  // by messageId, so it covers every mapping this conversationId
  // originally had) — but the explicit
  // `_purgeMembershipRowsForConversationIds` call below is kept
  // unconditional and self-contained anyway, not left to rely on that as
  // an invariant, matching the same "never rely on another function's
  // incidental side effect to satisfy a cascade requirement" discipline
  // M1.10 established for `deleteNote`. It also covers `conversation_tags`
  // and `conversation_note_mapping`, neither of which anything else in this
  // function's body touches — previously covered only by the now-inert
  // `conversations -> {conversation_tags, conversation_note_mapping}`
  // `ON DELETE CASCADE`. This function used to ALSO call the standalone
  // `deleteConversationNoteMappings` for the note-mapping half of that —
  // removed (review finding) since `_purgeMembershipRowsForConversationIds`
  // already deletes `conversation_note_mapping` too; calling both was a
  // harmless but confusing redundant delete of the same rows.
  Future<void> deleteConversationExplicitly(String conversationId) async {
    final db = await database;

    LoggerService.info('Explicitly deleting conversation: $conversationId');

    // Get all messages in this conversation
    final messageMappings = await db.query(
      'conversation_message_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );

    // Delete all messages in this conversation
    for (final mapping in messageMappings) {
      final messageId = mapping['messageId'] as String;
      await deleteMessageWithSubtree(messageId);
    }

    // M1.12 cascade replacement — see doc comment above.
    await _purgeMembershipRowsForConversationIds(db, {conversationId});

    // Tombstone the conversation itself.
    await db.update(
      'conversations',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [conversationId],
    );

    LoggerService.info('Successfully deleted conversation: $conversationId');
  }

  // Delete messages using tree node traversal (for UI efficiency)
  Future<void> deleteMessagesFromTreeNodes(List<String> messageIds) async {
    if (messageIds.isEmpty) return;

    LoggerService.info(
      'Deleting ${messageIds.length} messages from tree nodes',
    );

    // Delete all related data efficiently
    await _deleteMessagesBatch(messageIds);

    // Find conversations that now have no messages and delete them
    await _cleanupEmptyConversations();

    LoggerService.info('Successfully deleted messages from tree nodes');
  }

  // Conversation Attachments CRUD
  Future<String> insertConversationAttachment(
    ConversationAttachment attachment,
  ) async {
    final db = await database;
    final json = attachment.toDatabase();
    await db.insert('conversation_attachments', json);
    return attachment.id;
  }

  Future<List<ConversationAttachment>> getConversationAttachments(
    String messageId,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversation_attachments',
      where: 'messageId = ? AND __deleted__ = 0',
      whereArgs: [messageId],
      orderBy: 'createdAt ASC',
    );

    return maps.map((map) => ConversationAttachment.fromDatabase(map)).toList();
  }

  // M1.8: tombstone write, not a real delete — see the doc comment above
  // _createConversationAttachmentsTable. Unlike _deleteMessagesBatch's own
  // conversation_attachments delete (deferred to M1.12, see that comment),
  // this standalone function is fully converted.
  Future<void> deleteConversationAttachment(String id) async {
    final db = await database;
    await db.update(
      'conversation_attachments',
      {'__deleted__': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Helper methods for mapping database results to models
  Conversation _mapToConversation(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String,
      noteIds: const [], // Always empty, managed by mapping table
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
      isArchived: (map['isArchived'] ?? 0) == 1,
    );
  }

  Future<void> _populateMessageAttachmentPaths(
    Database db,
    Map<String, dynamic> messageMap,
  ) async {
    try {
      final attachmentRecords = await db.query(
        'conversation_attachments',
        columns: ['filePath'],
        where: 'messageId = ? AND __deleted__ = 0',
        whereArgs: [messageMap['id']],
        orderBy: 'createdAt ASC',
      );
      if (attachmentRecords.isNotEmpty) {
        final paths = attachmentRecords
            .map((r) => r['filePath'] as String)
            .toList();
        messageMap['attachmentPaths'] = jsonEncode(paths);
      }
    } catch (e) {
      LoggerService.error(
        'Failed to get attachments for message ${messageMap['id']}: $e',
      );
    }
  }

  ConversationMessage _mapToConversationMessage(
    Map<String, dynamic> map,
    String conversationId,
  ) {
    return ConversationMessage(
      id: map['id'] as String,
      conversationId: conversationId,
      type: MessageType.values.firstWhere(
        (e) => e.toString().split('.').last == map['type'],
        orElse: () => MessageType.user,
      ),
      content: map['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      attachmentPaths: map['attachmentPaths'] != null
          ? List<String>.from(jsonDecode(map['attachmentPaths'] as String))
          : [],
      modelUsed: map['modelUsed'] as String?,
      metadata: map['metadata'] != null
          ? Map<String, dynamic>.from(jsonDecode(map['metadata'] as String))
          : null,
    );
  }

  // New conversation-message mapping methods
  Future<String> insertConversationMessageMapping({
    required String conversationId,
    required String messageId,
  }) async {
    final db = await database;
    final result = await db.insert('conversation_message_mapping', {
      'conversationId': conversationId,
      'messageId': messageId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    return result.toString();
  }

  Future<List<Map<String, dynamic>>> getConversationMessageMappings(
    String conversationId,
  ) async {
    final db = await database;
    return await db.query(
      'conversation_message_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'id ASC', // Use auto-increment ID for canonical ordering
    );
  }

  Future<List<String>> getConversationMessageIds(String conversationId) async {
    final mappings = await getConversationMessageMappings(conversationId);
    return mappings.map((m) => m['messageId'] as String).toList();
  }

  // New message parent methods
  Future<String> insertMessageParent({
    required String messageId,
    required String parentMessageId,
  }) async {
    final db = await database;
    final id = '${messageId}_$parentMessageId';
    await db.insert('message_parents', {
      'id': id,
      'messageId': messageId,
      'parentMessageId': parentMessageId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllMessageParents() async {
    final db = await database;
    return await db.query('message_parents');
  }

  Future<String?> getMessageParent(String messageId) async {
    final db = await database;
    final results = await db.query(
      'message_parents',
      where: 'messageId = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return results.isNotEmpty
        ? results.first['parentMessageId'] as String?
        : null;
  }

  Future<List<String>> getMessageChildren(String parentMessageId) async {
    final db = await database;
    final results = await db.query(
      'message_parents',
      where: 'parentMessageId = ?',
      whereArgs: [parentMessageId],
    );
    return results.map((r) => r['messageId'] as String).toList();
  }

  // M1.12: same design decision as `_cleanupEmptyConversations` (see that
  // function's own doc comment for the full rationale) — no longer writes
  // `conversations.__deleted__` for the age-gated "truly empty" candidates
  // it finds; `getAllConversations(includeEmpty: false)` now derives that
  // exclusion fresh at read time instead. Only real-deletes the candidates'
  // now-unreachable OR-Set membership rows. Unlike
  // `_cleanupEmptyConversations`, this function was never scoped to the
  // "redundant" condition (`includeRedundant: false`), preserving its
  // pre-M1.12 behavior exactly.
  Future<void> deleteEmptyConversations({required Duration olderThan}) async {
    final db = await database;
    final since = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    final ids = await _findEmptyOrRedundantConversationIds(
      db,
      includeRedundant: false,
      updatedBeforeMillis: since,
    );
    if (ids.isEmpty) return;

    await _purgeMembershipRowsForConversationIds(db, ids);
  }

  // Find all conversations that contain a specific message
  Future<List<String>> getConversationsContainingMessage(
    String messageId,
  ) async {
    final db = await database;
    final results = await db.query(
      'conversation_message_mapping',
      where: 'messageId = ?',
      whereArgs: [messageId],
    );
    return results.map((r) => r['conversationId'] as String).toList();
  }

  // Conversation-Note Mapping CRUD methods
  Future<String> insertConversationNoteMapping({
    required String conversationId,
    required String noteId,
  }) async {
    final db = await database;
    final result = await db.insert('conversation_note_mapping', {
      'conversationId': conversationId,
      'noteId': noteId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return result.toString();
  }

  Future<List<String>> getConversationNoteIds(String conversationId) async {
    final db = await database;
    final results = await db.query(
      'conversation_note_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
    );
    return results.map((r) => r['noteId'] as String).toList();
  }

  Future<List<String>> getNoteConversationIds(String noteId) async {
    final db = await database;
    final results = await db.query(
      'conversation_note_mapping',
      where: 'noteId = ?',
      whereArgs: [noteId],
      orderBy: 'createdAt ASC',
    );
    return results.map((r) => r['conversationId'] as String).toList();
  }

  Future<void> deleteConversationNoteMapping({
    required String conversationId,
    required String noteId,
  }) async {
    final db = await database;
    await db.delete(
      'conversation_note_mapping',
      where: 'conversationId = ? AND noteId = ?',
      whereArgs: [conversationId, noteId],
    );
  }

  Future<void> deleteConversationNoteMappings(String conversationId) async {
    final db = await database;
    await db.delete(
      'conversation_note_mapping',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );
  }

  // M1.10: takes an optional [executor] (see deleteRelationshipsForNote's
  // own doc comment) so `deleteNote` can call this from inside its own
  // transaction.
  Future<void> deleteNoteConversationMappings(
    String noteId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    await db.delete(
      'conversation_note_mapping',
      where: 'noteId = ?',
      whereArgs: [noteId],
    );
  }

  Future<bool> conversationNoteMappingExists({
    required String conversationId,
    required String noteId,
  }) async {
    final db = await database;
    final results = await db.query(
      'conversation_note_mapping',
      where: 'conversationId = ? AND noteId = ?',
      whereArgs: [conversationId, noteId],
      limit: 1,
    );
    return results.isNotEmpty;
  }

  Future<int> getNoteConversationCount(String noteId) async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT COUNT(*) as count FROM conversation_note_mapping WHERE noteId = ?',
      [noteId],
    );
    return results.first['count'] as int;
  }

  Future<int> getConversationNoteCount(String conversationId) async {
    final db = await database;
    final results = await db.rawQuery(
      'SELECT COUNT(*) as count FROM conversation_note_mapping WHERE conversationId = ?',
      [conversationId],
    );
    return results.first['count'] as int;
  }

  // Conversation-Tag mapping methods
  Future<void> addTagsToConversation(
    String conversationId,
    List<String> tagNames,
  ) async {
    if (tagNames.isEmpty) return;

    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final tagName in tagNames) {
      final tagId = await getOrCreateLiveTagId(db, tagName);
      await db.insert('conversation_tags', {
        'conversationId': conversationId,
        'tagId': tagId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    await db.update(
      'conversations',
      {'updatedAt': now},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> setConversationTags(
    String conversationId,
    List<String> tagNames,
  ) async {
    final db = await database;
    final currentMappings = await db.query(
      'conversation_tags',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );

    final currentTagIds = currentMappings
        .map((row) => row['tagId'] as String)
        .toSet();
    final desiredTagIds = <String>{};

    for (final tagName in tagNames) {
      final tagId = await getOrCreateLiveTagId(db, tagName);
      desiredTagIds.add(tagId);
    }

    for (final tagId in currentTagIds) {
      if (!desiredTagIds.contains(tagId)) {
        await db.delete(
          'conversation_tags',
          where: 'conversationId = ? AND tagId = ?',
          whereArgs: [conversationId, tagId],
        );
      }
    }

    for (final tagId in desiredTagIds) {
      await db.insert('conversation_tags', {
        'conversationId': conversationId,
        'tagId': tagId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    await db.update(
      'conversations',
      {'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> removeTagFromConversation(
    String conversationId,
    String tagName,
  ) async {
    final db = await database;

    // M1.9: another divergent bare `WHERE name = ?` lookup found while
    // auditing every tags read path — switched to the shared live-tag
    // lookup for the same reason deleteTag's own lookup was (a
    // tombstoned row sharing this name must not shadow the live one now
    // that deleteTag/replaceTag actually leave tombstoned rows behind).
    final tagRecord = await findLiveTagByName(db, tagName);

    if (tagRecord == null) return;

    final tagId = tagRecord['id'] as String;
    await db.delete(
      'conversation_tags',
      where: 'conversationId = ? AND tagId = ?',
      whereArgs: [conversationId, tagId],
    );

    await db.update(
      'conversations',
      {'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<List<Tag>> getConversationTags(String conversationId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT t.id, t.name, t.color, t.createdAt, t.usageCount
      FROM conversation_tags ct
      INNER JOIN tags t ON t.id = ct.tagId
      WHERE ct.conversationId = ? AND t.__deleted__ = 0
      ORDER BY t.name COLLATE NOCASE ASC
    ''',
      [conversationId],
    );

    return maps.map((map) {
      return Tag(
        id: map['id'] as String,
        name: map['name'] as String,
        color: map['color'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
        usageCount: (map['usageCount'] as int?) ?? 0,
        conversationUsageCount: 0,
      );
    }).toList();
  }

  Future<List<String>> getConversationTagNames(String conversationId) async {
    final tags = await getConversationTags(conversationId);
    return tags.map((tag) => tag.name).toList();
  }

  // Multi-function Apps Methods

  Future<void> addAppToMultiFunction(String appId) async {
    final db = await database;
    await db.insert('multi_function_apps', {
      'appId': appId,
      'isDefault': 0,
      'addedAt': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeAppFromMultiFunction(String appId) async {
    final db = await database;
    await db.delete(
      'multi_function_apps',
      where: 'appId = ?',
      whereArgs: [appId],
    );
  }

  Future<void> setMultiFunctionDefaultApp(String appId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Reset all to not default
      await txn.update('multi_function_apps', {'isDefault': 0});
      // Set the specific app to default
      await txn.update(
        'multi_function_apps',
        {'isDefault': 1},
        where: 'appId = ?',
        whereArgs: [appId],
      );
    });
  }

  Future<void> clearMultiFunctionDefaultApp() async {
    final db = await database;
    await db.update('multi_function_apps', {'isDefault': 0});
  }

  Future<List<String>> getMultiFunctionApps() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'multi_function_apps',
      orderBy: 'addedAt DESC',
    );
    return maps.map((map) => map['appId'] as String).toList();
  }

  Future<String?> getMultiFunctionDefaultAppId() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'multi_function_apps',
      where: 'isDefault = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return maps.first['appId'] as String;
    }
    return null;
  }

  static Future<void> _migrateToVersion27(
    Database db, {
    required bool isBackupMigration,
  }) async {
    LoggerService.info(
      'Starting migration to version 27: Adding isPinned column to filters table',
    );

    try {
      // Check if column already exists
      final columns = await db.rawQuery('PRAGMA table_info(filters)');
      final hasIsPinned = columns.any((col) => col['name'] == 'isPinned');

      if (!hasIsPinned) {
        await db.execute(
          'ALTER TABLE filters ADD COLUMN isPinned INTEGER NOT NULL DEFAULT 0',
        );
      }
    } catch (e) {
      LoggerService.error('Error adding isPinned column: $e', error: e);
      rethrow;
    }
  }

  /// Batch fetch messages for multiple conversations efficiently
  Future<List<ConversationMessage>> getMessagesForConversations(
    List<String> conversationIds,
  ) async {
    if (conversationIds.isEmpty) return [];

    final db = await database;
    // SQLite has a limit on variables, so we chunk requests if necessary
    const chunkSize = 500;
    final messages = <ConversationMessage>[];

    for (var i = 0; i < conversationIds.length; i += chunkSize) {
      final end = (i + chunkSize < conversationIds.length)
          ? i + chunkSize
          : conversationIds.length;
      final chunk = conversationIds.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');

      final results = await db.rawQuery('''
        SELECT 
          cm.id, 
          cm.type, 
          cm.content, 
          cm.timestamp, 
          cm.modelUsed, 
          cmm.conversationId
        FROM conversation_messages cm
        JOIN conversation_message_mapping cmm ON cm.id = cmm.messageId
        WHERE cmm.conversationId IN ($placeholders)
        ORDER BY cm.timestamp ASC
        ''', chunk);

      for (final map in results) {
        final messageMap = Map<String, dynamic>.from(map);
        await _populateMessageAttachmentPaths(db, messageMap);
        messages.add(
          _mapToConversationMessage(
            messageMap,
            messageMap['conversationId'] as String,
          ),
        );
      }
    }

    return messages;
  }

  /// Batch fetch conversation IDs for multiple messages
  /// Returns a map of messageId -> List<conversationId>
  Future<Map<String, List<String>>> getConversationIdsForMessages(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return {};

    final db = await database;
    final result = <String, List<String>>{};

    // Chunking to avoid variable limit
    const chunkSize = 500;

    for (var i = 0; i < messageIds.length; i += chunkSize) {
      final end = (i + chunkSize < messageIds.length)
          ? i + chunkSize
          : messageIds.length;
      final chunk = messageIds.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');

      final rows = await db.rawQuery('''
        SELECT messageId, conversationId
        FROM conversation_message_mapping
        WHERE messageId IN ($placeholders)
        ''', chunk);

      for (final row in rows) {
        final messageId = row['messageId'] as String;
        final conversationId = row['conversationId'] as String;

        if (!result.containsKey(messageId)) {
          result[messageId] = [];
        }
        result[messageId]!.add(conversationId);
      }
    }

    return result;
  }
  // --- Agent / AI Features ---

  /// The reserved "visible from every Space" tag, mirroring
  /// `SpaceScopeService.allSpacesTag`. Spelled out rather than imported so the
  /// database layer does not pull `shared_preferences` in for one string (the
  /// same reason [_allSpacesTagV47] is a literal). The scoped-search tests
  /// tag their fixtures with `SpaceScopeService.allSpacesTag` and expect them
  /// found, so the two cannot drift apart silently.
  static const String _allSpacesTag = 'all-spaces';

  /// SQL testing whether the note in scope (`n`) carries one tag, named by a
  /// `?` placeholder. A correlated EXISTS rather than a join, so ANDing
  /// several of them cannot multiply rows.
  ///
  /// `t.__deleted__ = 0` upholds the M1.10 tombstone read-filter contract:
  /// a tombstoned tag row must not satisfy a scope.
  static const String _noteHasTagExists =
      'EXISTS (SELECT 1 FROM note_tags nt JOIN tags t ON t.id = nt.tagId '
      'WHERE nt.noteId = n.id AND t.name = ? AND t.__deleted__ = 0)';

  /// Search notes using Full-Text Search.
  ///
  /// Superseded for in-app search by the chunk-level index
  /// ([searchChunksLexical] + `SearchService`), but kept as the note-level
  /// FTS entry point and as the subject of the M1.10 tombstone read-filter
  /// contract (`__deleted__ = 0` on both the note and the tag join).
  ///
  /// [tags] are the **caller's own** requirement and are ANDed unconditionally:
  /// a match must carry every one of them, in or out of a Space.
  ///
  /// [scopeTags] are the active Space's tags. They are ANDed among themselves
  /// in a group of their own, and [includeAllSpacesTag] ORs the reserved
  /// `all-spaces` tag around **that group only**:
  ///
  ///     t1 AND t2 AND ((s1 AND s2) OR all-spaces)
  ///
  /// so a note marked visible everywhere is found by a Space-scoped search even
  /// though it carries none of the Space's tags — while the caller's own tags
  /// still have to match (A7: explicit tags are ANDed *within* the space
  /// scope). Merging the two lists and ORing around the whole conjunction is
  /// the bug this shape exists to prevent: a search for tag `invoice` inside a
  /// Space would return every `all-spaces` note, none of which has `invoice`,
  /// and migration v48 put `all-spaces` on every `agent-skill` note.
  ///
  /// Appending `all-spaces` as one more AND term would instead require every
  /// match to be an `all-spaces` note. The flag does nothing without
  /// [scopeTags] — with no Space there is no scope to escape. Left false, the
  /// query is exactly what it has always been.
  Future<List<Note>> searchNotesFTS(
    String query, {
    List<String>? tags,
    List<String>? scopeTags,
    bool includeAllSpacesTag = false,
  }) async {
    final db = await database;
    // Wrap the query as a phrase to avoid accidental FTS syntax errors.
    final sanitizedQuery = '"$query"';
    final requiredTags = tags ?? const <String>[];
    final spaceTags = scopeTags ?? const <String>[];

    try {
      String sql = '''
        SELECT n.*
        FROM notes_fts fts
        JOIN notes n ON fts.rowid = n.rowid
        WHERE notes_fts MATCH ? AND n.__deleted__ = 0
      ''';

      List<Object?> args = [sanitizedQuery];

      String conjunctionOf(List<String> names) => List.filled(
        names.length,
        _noteHasTagExists,
      ).join('\n            AND ');

      if (requiredTags.isNotEmpty) {
        sql += '\n            AND ${conjunctionOf(requiredTags)}';
        args.addAll(requiredTags);
      }

      if (spaceTags.isNotEmpty) {
        if (includeAllSpacesTag) {
          sql +=
              '\n            AND ((${conjunctionOf(spaceTags)})'
              '\n            OR $_noteHasTagExists)';
          args
            ..addAll(spaceTags)
            ..add(_allSpacesTag);
        } else {
          sql += '\n            AND ${conjunctionOf(spaceTags)}';
          args.addAll(spaceTags);
        }
      }

      sql += ' LIMIT 50';

      final results = await db.rawQuery(sql, args);
      return await _batchLoadNotes(results);
    } catch (e) {
      LoggerService.error('FTS Search failed: $e');
      return [];
    }
  }

  /// Chunk-level lexical search, step (a) of plan §1.4: returns docid +
  /// matchinfo('pcnalx') blob for every chunks_fts row matching [ftsQuery]
  /// (an expression built by `buildFtsQuery` — never raw user input).
  ///
  /// No ranking or ordering happens here: matchinfo blobs are tiny, so ALL
  /// matches are returned (capped at [limit] rows as a runaway guard — a
  /// plain LIMIT, deliberately unordered) and the caller ranks them in Dart
  /// via `bm25FromMatchinfo`, then fetches full rows for only the top slice
  /// with [getSearchChunksByIds]. This avoids rank truncation: the cap
  /// bounds pathological corpora, not the ranking pool.
  ///
  /// [sourceTypes] / [noteId] narrow the candidate pool IN SQL. That is not an
  /// optimization but a correctness requirement for scoped callers: the LIMIT
  /// is deliberately unordered, so FTS4's doclist scan keeps the LOWEST
  /// docids. Chunk kinds written LAST by the indexer (figures follow the
  /// chunk/pdf_text/ocr stages, so they hold the HIGHEST `search_chunks.id`)
  /// would be cut away wholesale on any corpus where a common term matches
  /// more than [limit] chunks, and a figure-scoped search would report "no
  /// figures" while matching figures exist. Filtering here applies the cap to
  /// in-scope rows instead. Callers still re-apply the same predicates during
  /// accumulation — this narrows, it never replaces the visibility pass.
  ///
  /// Throws if chunks_fts is unavailable ([chunksFtsAvailable] is false) or
  /// the MATCH expression is invalid — callers gate on availability first.
  Future<List<ChunkFtsMatch>> searchChunksLexical(
    String ftsQuery, {
    int limit = 5000,
    Set<String>? sourceTypes,
    String? noteId,
  }) async {
    final db = await database;
    final predicates = <String>[];
    final args = <Object?>[ftsQuery];
    if (sourceTypes != null && sourceTypes.isNotEmpty) {
      final types = sourceTypes.toList();
      final placeholders = List.filled(types.length, '?').join(',');
      predicates.add('c.sourceType IN ($placeholders)');
      args.addAll(types);
    }
    if (noteId != null) {
      predicates.add('c.noteId = ?');
      args.add(noteId);
    }
    args.add(limit);
    // The unscoped form stays a bare FTS scan: joining search_chunks for every
    // match would make ordinary note search pay for a filter it does not use.
    final sql = predicates.isEmpty
        ? "SELECT docid, matchinfo(chunks_fts, 'pcnalx') AS mi "
              'FROM chunks_fts WHERE content MATCH ? LIMIT ?'
        : "SELECT chunks_fts.docid AS docid, matchinfo(chunks_fts, 'pcnalx') "
              'AS mi FROM chunks_fts '
              'JOIN search_chunks c ON c.id = chunks_fts.docid '
              'WHERE chunks_fts.content MATCH ? AND ${predicates.join(' AND ')} '
              'LIMIT ?';
    final rows = await db.rawQuery(sql, args);
    return [
      for (final row in rows)
        ChunkFtsMatch(
          docid: row['docid'] as int,
          matchinfo: row['mi'] as Uint8List,
        ),
    ];
  }

  /// Fetches full search_chunks rows for [chunkIds] (step (b) of plan §1.4),
  /// joined with the owning note's isArchived flag and — for attachment-
  /// derived chunks — the source attachment's includeInAIContext flag, so the
  /// caller can apply visibility/audience filters without extra queries.
  ///
  /// Chunks whose note no longer exists are dropped by the INNER JOIN — and
  /// "no longer exists" means TOMBSTONED too (`notes.__deleted__ = 1`), since
  /// deletion is a soft-delete write everywhere in this file: without that
  /// predicate a deleted note's chunks would keep surfacing in search until
  /// the indexer's next orphan sweep happened to run. Same for the
  /// attachment-derived chunks: the source attachment must still be live
  /// and belong to this note, even for UI searches that ignore AI consent.
  /// Returned in no particular order; callers reorder by their own ranking.
  ///
  /// [sourceTypes] / [noteId] drop out-of-scope rows in SQL. `c.text` can be a
  /// kilobyte or more per row, so a scoped caller (`search_figures`, whose
  /// candidate list is ranked over every chunk kind) would otherwise haul the
  /// full text of hundreds of rows it is about to discard in Dart.
  Future<List<SearchChunkRow>> getSearchChunksByIds(
    List<int> chunkIds, {
    Set<String>? sourceTypes,
    String? noteId,
  }) async {
    if (chunkIds.isEmpty) return [];
    final db = await database;
    const chunkSize = 500; // SQLite variable-limit-safe IN() size.
    final scopeSql = StringBuffer();
    final scopeArgs = <Object?>[];
    if (sourceTypes != null && sourceTypes.isNotEmpty) {
      final types = sourceTypes.toList();
      scopeSql.write(
        ' AND c.sourceType IN (${List.filled(types.length, '?').join(',')})',
      );
      scopeArgs.addAll(types);
    }
    if (noteId != null) {
      scopeSql.write(' AND c.noteId = ?');
      scopeArgs.add(noteId);
    }
    final results = <SearchChunkRow>[];
    for (var i = 0; i < chunkIds.length; i += chunkSize) {
      final slice = chunkIds.sublist(
        i,
        i + chunkSize > chunkIds.length ? chunkIds.length : i + chunkSize,
      );
      final placeholders = List.filled(slice.length, '?').join(',');
      final args = [...slice, ...scopeArgs];
      final rows = await db.rawQuery('''
        SELECT c.id, c.chunkKey, c.noteId, c.sourceType, c.sourceId, c.page,
               c.seq, c.text,
               n.isArchived AS noteIsArchived,
               a.includeInAIContext AS attachmentIncludeInAIContext
        FROM search_chunks c
        JOIN notes n ON n.id = c.noteId AND n.__deleted__ = 0
        LEFT JOIN attachments a ON a.id = c.sourceId
          AND a.noteId = c.noteId AND a.__deleted__ = 0
        WHERE c.id IN ($placeholders)$scopeSql
          AND (c.sourceType NOT IN ('attachment_text', 'attachment_ocr', 'figure')
               OR a.id IS NOT NULL)
      ''', args);
      for (final row in rows) {
        final aiFlag = row['attachmentIncludeInAIContext'] as int?;
        results.add(
          SearchChunkRow(
            id: row['id'] as int,
            chunkKey: row['chunkKey'] as String,
            noteId: row['noteId'] as String,
            sourceType: row['sourceType'] as String,
            sourceId: row['sourceId'] as String?,
            page: row['page'] as int?,
            seq: row['seq'] as int,
            text: row['text'] as String,
            noteIsArchived: (row['noteIsArchived'] as int? ?? 0) != 0,
            attachmentIncludeInAIContext: aiFlag == null ? null : aiFlag != 0,
          ),
        );
      }
    }
    return results;
  }

  /// Executes a raw SQL query. USE WITH CAUTION.
  Future<List<Map<String, dynamic>>> runRawQuery(
    String query, [
    List<Object?>? arguments,
  ]) async {
    final db = await database;
    return await db.rawQuery(query, arguments);
  }

  // ===========================================================================
  // Raw-write change capture
  //
  // TEMP triggers journal which note-domain rows a raw DML statement touched
  // (including rows written indirectly by persistent triggers), so UI caches
  // can be invalidated precisely. TEMP objects are connection-local and never
  // persisted: no schema change, invisible to recovery/backup and to other
  // connections. Design: .claude/plans/user-app-bridge-ui-refresh-fix.md
  // ===========================================================================

  static const String _changeJournal = '_synapse_change_journal';
  static const String _captureActiveFlag = '_synapse_capture_active';

  /// Committed capture-install state, keyed to the connection it was
  /// installed on. TEMP objects die with their connection, so a state whose
  /// [_CaptureState.db] is not the live connection is stale and triggers a
  /// reinstall (after close()/reopen, incl. recovery/import).
  _CaptureState? _captureState;
  Future<_CaptureState>? _captureInstalling;
  Database? _captureInstallingFor;
  bool _captureReverifyRequested = false;

  /// Ask for the capture trigger set to be re-verified before the next
  /// captured write. Call after schema-altering SQL: a dropped table takes
  /// its triggers with it, and `IF NOT EXISTS` makes re-install idempotent
  /// for survivors.
  void markSchemaChangedForCapture() {
    _captureReverifyRequested = true;
  }

  /// The TEMP trigger statements for one monitored table. Kinds: 'notes'
  /// rows carry the affected note id; 'relationships' rows carry an endpoint
  /// note id; 'tags'/'filters' rows are domain markers (note_id NULL) —
  /// except tag UPDATE/DELETE, which additionally journal every note bearing
  /// the tag (cached notes embed tag names, so a rename/delete must refresh
  /// them). BEFORE DELETE on tags so the note_tags join rows still exist
  /// regardless of cascade behavior.
  ///
  /// Every trigger is gated on a row existing in the TEMP active-flag table,
  /// which only [runRawWriteWithChangeCapture] sets inside its transaction.
  /// Ordinary app writes therefore pay one EXISTS check on an empty TEMP
  /// table and journal nothing — without the gate, the journal would grow
  /// unboundedly between captured writes.
  static List<String> _captureTriggerStatements(String table) {
    const journal = _changeJournal;
    String trigger(String name, String timing, String body) =>
        'CREATE TEMP TRIGGER IF NOT EXISTS _syn_cap_$name '
        '$timing ON $table '
        'WHEN EXISTS (SELECT 1 FROM $_captureActiveFlag) '
        'BEGIN $body END';
    String note(String ref) =>
        "INSERT INTO $journal(kind, note_id) VALUES ('notes', $ref);";
    String relationship(String ref) =>
        "INSERT INTO $journal(kind, note_id) VALUES ('relationships', $ref);";
    String domain(String kind) =>
        "INSERT INTO $journal(kind, note_id) VALUES ('$kind', NULL);";
    // Every note currently carrying the tag; used before the association
    // rows are removed.
    String notesWithTag(String tagRef) =>
        "INSERT INTO $journal(kind, note_id) "
        "SELECT 'notes', noteId FROM note_tags WHERE tagId = $tagRef;";
    // Annotations belong to a note directly (note_id) or through an
    // attachment (attachment_id). A NULL note_id journal row is ignored on
    // read, so both inserts are always safe to emit.
    String annotationNote(String noteRef, String attachmentRef) =>
        "INSERT INTO $journal(kind, note_id) VALUES ('notes', $noteRef); "
        "INSERT INTO $journal(kind, note_id) "
        "SELECT 'notes', noteId FROM attachments WHERE id = $attachmentRef;";

    switch (table) {
      case 'notes':
        return [
          trigger('notes_ai', 'AFTER INSERT', note('NEW.id')),
          // Both sides: an UPDATE that rewrites the primary key must remove
          // the old cached entry as well as upsert the new one.
          trigger(
            'notes_au',
            'AFTER UPDATE',
            '${note('OLD.id')} ${note('NEW.id')}',
          ),
          trigger('notes_ad', 'AFTER DELETE', note('OLD.id')),
        ];
      case 'subnotes':
      case 'note_tags':
      case 'attachments':
        // UPDATE records both sides so association moves refresh both notes.
        return [
          trigger('${table}_ai', 'AFTER INSERT', note('NEW.noteId')),
          trigger(
            '${table}_au',
            'AFTER UPDATE',
            '${note('OLD.noteId')} ${note('NEW.noteId')}',
          ),
          trigger('${table}_ad', 'AFTER DELETE', note('OLD.noteId')),
        ];
      case 'relationships':
        return [
          trigger(
            'relationships_ai',
            'AFTER INSERT',
            '${relationship('NEW.fromNoteId')} '
                '${relationship('NEW.toNoteId')}',
          ),
          trigger(
            'relationships_au',
            'AFTER UPDATE',
            '${relationship('OLD.fromNoteId')} '
                '${relationship('OLD.toNoteId')} '
                '${relationship('NEW.fromNoteId')} '
                '${relationship('NEW.toNoteId')}',
          ),
          trigger(
            'relationships_ad',
            'AFTER DELETE',
            '${relationship('OLD.fromNoteId')} '
                '${relationship('OLD.toNoteId')}',
          ),
        ];
      case 'tags':
        return [
          trigger('tags_ai', 'AFTER INSERT', domain('tags')),
          trigger(
            'tags_au',
            'AFTER UPDATE',
            '${domain('tags')} ${notesWithTag('OLD.id')}',
          ),
          trigger(
            'tags_bd',
            'BEFORE DELETE',
            '${domain('tags')} ${notesWithTag('OLD.id')}',
          ),
        ];
      case 'filters':
        return [
          trigger('filters_ai', 'AFTER INSERT', domain('filters')),
          trigger('filters_au', 'AFTER UPDATE', domain('filters')),
          trigger('filters_ad', 'AFTER DELETE', domain('filters')),
        ];
      case 'note_annotations':
        // Annotation text feeds the search index, so raw-SQL annotation
        // writes must reach the indexer via the owning note's id.
        return [
          trigger(
            'note_annotations_ai',
            'AFTER INSERT',
            annotationNote('NEW.note_id', 'NEW.attachment_id'),
          ),
          trigger(
            'note_annotations_au',
            'AFTER UPDATE',
            '${annotationNote('OLD.note_id', 'OLD.attachment_id')} '
                '${annotationNote('NEW.note_id', 'NEW.attachment_id')}',
          ),
          trigger(
            'note_annotations_ad',
            'AFTER DELETE',
            annotationNote('OLD.note_id', 'OLD.attachment_id'),
          ),
        ];
      default:
        // A table listed in _capturedTables without a trigger spec would be
        // silently uncaptured — fail loudly instead.
        throw ArgumentError('No capture trigger spec for table "$table"');
    }
  }

  static const List<String> _capturedTables = [
    'notes',
    'subnotes',
    'note_tags',
    'attachments',
    'relationships',
    'tags',
    'filters',
    'note_annotations',
  ];

  Future<_CaptureState> _installCaptureObjects(Database db) async {
    try {
      await db.execute(
        'CREATE TEMP TABLE IF NOT EXISTS $_changeJournal'
        '(kind TEXT NOT NULL, note_id TEXT)',
      );
      await db.execute(
        'CREATE TEMP TABLE IF NOT EXISTS $_captureActiveFlag(flag INTEGER)',
      );
    } catch (e) {
      // Without the journal nothing can be captured (and the triggers would
      // reference a missing table), so bail out entirely.
      LoggerService.error(
        '[ChangeCapture] Failed to create journal tables: $e',
        error: e,
      );
      return _CaptureState(db, journalReady: false, complete: false);
    }

    var complete = true;
    for (final table in _capturedTables) {
      try {
        for (final statement in _captureTriggerStatements(table)) {
          await db.execute(statement);
        }
      } catch (e) {
        // Per-table isolation: a dropped/renamed core table must not block
        // writes to unrelated tables. Degraded capture is reported to the
        // caller per execution via RawWriteResult.captureComplete.
        complete = false;
        LoggerService.warning(
          '[ChangeCapture] Trigger install failed for "$table" '
          '(capture degraded): $e',
        );
      }
    }
    return _CaptureState(db, journalReady: true, complete: complete);
  }

  /// Ensures TEMP capture objects exist on [db] and returns the resulting
  /// state. The in-flight future is keyed to the connection, so a caller on
  /// a NEW connection never receives an install running against a closed
  /// one; the committed [_captureState] is only published while [db] is
  /// still the live connection, so late continuations cannot re-poison state
  /// after close(). The in-flight slot is always cleared, so a failed
  /// install never blocks retries.
  Future<_CaptureState> _ensureCaptureReady(Database db) {
    final state = _captureState;
    if (state != null &&
        identical(state.db, db) &&
        !_captureReverifyRequested) {
      return Future.value(state);
    }
    if (_captureInstalling != null && identical(_captureInstallingFor, db)) {
      return _captureInstalling!;
    }

    _captureInstallingFor = db;
    final install = () async {
      _captureReverifyRequested = false;
      _CaptureState result;
      try {
        result = await _installCaptureObjects(db);
      } catch (e) {
        LoggerService.error('[ChangeCapture] Install failed: $e', error: e);
        result = _CaptureState(db, journalReady: false, complete: false);
      }
      if (identical(_database, db)) {
        _captureState = result;
      }
      return result;
    }();
    _captureInstalling = install.whenComplete(() {
      if (identical(_captureInstallingFor, db)) {
        _captureInstalling = null;
        _captureInstallingFor = null;
      }
    });
    return _captureInstalling!;
  }

  /// Executes a single raw DML statement, journaling which note-domain rows
  /// it touched (including writes performed by persistent triggers it fires).
  ///
  /// The statement runs through the transaction executor — never the plain
  /// database handle — because re-entering [database] inside a transaction
  /// deadlocks sqflite. Statements that cannot run inside a transaction
  /// (VACUUM, ATTACH, some PRAGMAs) must NOT be routed here; callers are
  /// expected to use [runRawQuery] for those and invalidate broadly.
  Future<RawWriteResult> runRawWriteWithChangeCapture(String sql) async {
    final db = await database;
    final capture = await _ensureCaptureReady(db);

    if (!capture.journalReady) {
      // No journal at all: execute plainly and report degraded capture.
      final rows = await db.rawQuery(sql);
      return RawWriteResult(rows: rows, captureComplete: false);
    }

    final changedNoteIds = <String>{};
    final relationshipNoteIds = <String>{};
    var tagsChanged = false;
    var filtersChanged = false;
    late final List<Map<String, dynamic>> rows;

    await db.transaction((txn) async {
      // Arm the trigger gate for exactly this statement; without a flag row
      // the TEMP triggers are inert, so ordinary app writes never journal.
      // A rollback removes the flag row with everything else.
      await txn.delete(_changeJournal);
      await txn.insert(_captureActiveFlag, {'flag': 1});
      rows = await txn.rawQuery(sql);
      final journal = await txn.query(_changeJournal);
      for (final row in journal) {
        final kind = row['kind'] as String?;
        final noteId = row['note_id'] as String?;
        if (kind == 'notes' && noteId != null) {
          changedNoteIds.add(noteId);
        } else if (kind == 'relationships' && noteId != null) {
          relationshipNoteIds.add(noteId);
        } else if (kind == 'tags') {
          tagsChanged = true;
        } else if (kind == 'filters') {
          filtersChanged = true;
        }
      }
      await txn.delete(_captureActiveFlag);
      await txn.delete(_changeJournal);
    });

    return RawWriteResult(
      rows: rows,
      changedNoteIds: changedNoteIds,
      relationshipNoteIds: relationshipNoteIds,
      tagsChanged: tagsChanged,
      filtersChanged: filtersChanged,
      captureComplete: capture.complete,
    );
  }

  /// Fallback search using LIKE.
  ///
  /// Superseded for in-app search by `SearchService` (the chunk index), but
  /// kept as the substring-search entry point and as the subject of the
  /// M1.10 tombstone read-filter contract (`__deleted__ = 0`).
  Future<List<Note>> searchNotes(String query) async {
    final db = await database;
    final results = await db.query(
      'notes',
      where: '(title LIKE ? OR content LIKE ?) AND __deleted__ = 0',
      whereArgs: ['%$query%', '%$query%'],
      orderBy: 'updatedAt DESC',
      limit: 50,
    );
    return await _batchLoadNotes(results);
  }

  /// Get the AI extraction prompt for a specific tag.
  ///
  /// M1.9: like `tag_images`, `tag_ai_configs` (`tagId` is its actual
  /// primary key) derives visibility from its owning tag's `__deleted__`
  /// state rather than carrying its own tombstone — this JOIN keeps a
  /// tombstoned tag's prompt invisible even though the row still
  /// physically exists once the `ON DELETE CASCADE` from `tags` stops
  /// firing (design doc § Architecture 10).
  Future<String?> getTagExtractionPrompt(String tagId) async {
    final db = await database;
    try {
      final results = await db.rawQuery(
        '''
        SELECT tac.extractionPrompt
        FROM tag_ai_configs tac
        JOIN tags t ON t.id = tac.tagId
        WHERE tac.tagId = ? AND t.__deleted__ = 0
        ''',
        [tagId],
      );

      if (results.isNotEmpty) {
        return results.first['extractionPrompt'] as String?;
      }
    } catch (e) {
      // Table might not exist yet if migration hasn't run or dev mode
      LoggerService.warning('Failed to get tag config: $e');
    }
    return null;
  }

  /// Update or Insert the AI extraction prompt for a tag
  Future<void> updateTagExtractionPrompt(String tagId, String? prompt) async {
    final db = await database;
    if (prompt == null || prompt.isEmpty) {
      await db.delete('tag_ai_configs', where: 'tagId = ?', whereArgs: [tagId]);
    } else {
      await db.insert('tag_ai_configs', {
        'tagId': tagId,
        'extractionPrompt': prompt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<Note?> getNoteById(String id) async {
    final db = await database;
    final results = await db.query(
      'notes',
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [id],
    );
    if (results.isEmpty) return null;
    final notes = await _batchLoadNotes(results);
    return notes.isNotEmpty ? notes.first : null;
  }

  /// Get an exact (non-prefix) workflow binding for a tag name.
  ///
  /// M1.7: `__deleted__ = 0` filters out a tombstoned binding — callers
  /// (chiefly `TagWorkflowService.resolveBindings`) must only ever match a
  /// LIVE binding.
  Future<WorkflowBindingRow?> getExactWorkflowBinding(String tagName) async {
    final db = await database;
    final result = await db.query(
      'tag_workflow_bindings',
      where: 'pattern = ? AND isPrefix = 0 AND __deleted__ = 0',
      whereArgs: [tagName],
    );
    if (result.isEmpty) return null;
    return WorkflowBindingRow.fromRow(result.first);
  }

  /// Get all prefix workflow bindings. M1.7: live only, see
  /// getExactWorkflowBinding's doc comment.
  Future<List<WorkflowBindingRow>> getPrefixWorkflowBindings() async {
    final db = await database;
    final result = await db.query(
      'tag_workflow_bindings',
      where: 'isPrefix = 1 AND __deleted__ = 0',
    );
    return result.map(WorkflowBindingRow.fromRow).toList();
  }

  /// Get a workflow binding by its exact stored pattern. M1.7: live only,
  /// see getExactWorkflowBinding's doc comment.
  Future<WorkflowBindingRow?> getWorkflowBindingByPattern(
    String pattern,
  ) async {
    final db = await database;
    final result = await db.query(
      'tag_workflow_bindings',
      where: 'pattern = ? AND __deleted__ = 0',
      whereArgs: [pattern],
    );
    if (result.isEmpty) return null;
    return WorkflowBindingRow.fromRow(result.first);
  }

  /// Get all workflow bindings, exact and prefix. M1.7: live only, see
  /// getExactWorkflowBinding's doc comment.
  Future<List<WorkflowBindingRow>> getAllWorkflowBindings() async {
    final db = await database;
    final result = await db.query(
      'tag_workflow_bindings',
      where: '__deleted__ = 0',
      orderBy: 'isPrefix DESC, pattern COLLATE NOCASE ASC',
    );
    return result.map(WorkflowBindingRow.fromRow).toList();
  }

  /// Insert or replace a workflow binding. `pattern` is the primary key, so
  /// this always fully overwrites any existing row under the same pattern —
  /// including a previously-tombstoned one, implicitly resetting
  /// `__deleted__` back to 0 since [WorkflowBindingRow.toMap] never mentions
  /// the column (see the M1.7 doc comment on
  /// `_createTagWorkflowBindingsTable`).
  Future<void> insertWorkflowBinding(WorkflowBindingRow binding) async {
    final db = await database;
    await db.insert(
      'tag_workflow_bindings',
      binding.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// M1.7 (design doc § Phased delivery, M1.7): a tombstone write, not a
  /// real SQL DELETE — mirrors deleteUserApp/deleteUserAppLibrary's M1.4
  /// conversion.
  Future<void> deleteWorkflowBinding(String pattern) async {
    final db = await database;
    await db.update(
      'tag_workflow_bindings',
      {'__deleted__': 1},
      where: 'pattern = ?',
      whereArgs: [pattern],
    );
  }

  // --- End Agent / AI Features ---
}

/// One chunks_fts MATCH hit: the search_chunks rowid ([docid]) and its
/// matchinfo('pcnalx') blob, ready for `bm25FromMatchinfo`.
class ChunkFtsMatch {
  const ChunkFtsMatch({required this.docid, required this.matchinfo});

  final int docid;
  final Uint8List matchinfo;
}

/// A search_chunks row with the joined visibility flags SearchService needs
/// (owning note's archived state; source attachment's includeInAIContext).
class SearchChunkRow {
  const SearchChunkRow({
    required this.id,
    required this.chunkKey,
    required this.noteId,
    required this.sourceType,
    required this.sourceId,
    required this.page,
    required this.seq,
    required this.text,
    required this.noteIsArchived,
    required this.attachmentIncludeInAIContext,
  });

  final int id;
  final String chunkKey;
  final String noteId;

  /// meta | note_body | subnote | annotation | attachment_text |
  /// attachment_ocr | figure
  final String sourceType;
  final String? sourceId;

  /// 1-based page for attachment-derived chunks.
  final int? page;
  final int seq;

  /// RAW chunk text (snippet + embedding input).
  final String text;
  final bool noteIsArchived;

  /// includeInAIContext of the attachment joined via sourceId; null when
  /// sourceId is not an existing attachment id (note-body/meta/subnote/
  /// annotation chunks, or a dangling attachment reference).
  final bool? attachmentIncludeInAIContext;
}
