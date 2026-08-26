import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import 'data_change_notifier.dart';
import 'database_service.dart';
import '../utils/file_utils.dart';
import '../utils/synapse_temp_utils.dart';
import 'logger_service.dart';
import 'service_locator.dart';
import 'tag_workflow_service.dart';

class NoteModificationService {
  final DatabaseService _db;
  final DataChangeNotifier _changeNotifier;
  final Uuid _uuid = const Uuid();

  /// Creates a NoteModificationService.
  ///
  /// [db] - The database service for persistence operations.
  /// [changeNotifier] - Receives post-commit change events so UI caches can
  /// refresh. Defaults to the process-wide shared notifier.
  NoteModificationService(this._db, {DataChangeNotifier? changeNotifier})
    : _changeNotifier = changeNotifier ?? DataChangeNotifier.shared();

  /// Publishes a post-commit change event. Enqueue-only by contract
  /// ([DataChangeNotifier.publish] never throws), so calling this can never
  /// turn a committed write into an apparent failure.
  void _publishChange({
    Set<String> noteIds = const {},
    bool tagsChanged = false,
    Set<String> relationshipNoteIds = const {},
  }) {
    _changeNotifier.publish(
      DataChangeEvent(
        noteIds: noteIds,
        tagsChanged: tagsChanged,
        relationshipNoteIds: relationshipNoteIds,
      ),
    );
  }

  /// Every note id whose relationships the given `link` payload touches:
  /// the note itself plus all added/removed targets. Computed BEFORE the
  /// modification is applied so removal endpoints are not lost.
  static Set<String> _linkEndpoints(String noteId, dynamic linkData) {
    if (linkData == null) return const {};
    final endpoints = <String>{noteId};
    List<dynamic> added = const [];
    List<dynamic> removed = const [];
    if (linkData is List) {
      added = linkData;
    } else if (linkData is Map<String, dynamic>) {
      added = (linkData['added'] as List?) ?? const [];
      removed = (linkData['removed'] as List?) ?? const [];
    }
    for (final link in added) {
      if (link is Map<String, dynamic> && link['target'] is String) {
        endpoints.add(link['target'] as String);
      }
    }
    for (final target in removed) {
      if (target is String) endpoints.add(target);
    }
    return endpoints.length == 1 ? const {} : endpoints;
  }

  /// Known modification fields that must be JSON objects (not bare strings or
  /// arrays), paired with a hint describing their correct shape. The agent
  /// frequently passes `content` as a raw string or `tags` as a bare array;
  /// without this guard the failure surfaces as an opaque
  /// `type 'String' is not a subtype of type 'Map<String, dynamic>'` cast
  /// error that the model cannot recover from.
  ///
  /// `link` is intentionally excluded: its handler accepts both the
  /// `{added, removed}` object and a bare array of links, so neither shape is
  /// an error.
  static const Map<String, String> _objectFieldHints = {
    'content':
        '{"action": "append|prepend|replace", "text": "...", '
        '"section": "(optional) markdown heading to target", '
        '"insert_position": "(optional) append|prepend within the section"}',
    'title': '{"new_title": "..."}',
    'tags': '{"added": ["tag1"], "removed": ["tag2"]}',
    'attachments': '{"added": ["file.png"], "removed": ["old.png"]}',
    'subnote':
        '{"added": [{"name": "...", "content": "..."}], "removed": ["id"]}',
  };

  /// Validates that each present modification field has the expected object
  /// shape, throwing a self-describing error the model can act on instead of
  /// an opaque type-cast failure.
  static void _validateModificationShape(Map<String, dynamic> modification) {
    _objectFieldHints.forEach((field, hint) {
      if (modification.containsKey(field) && modification[field] is! Map) {
        final actual = modification[field].runtimeType;
        throw Exception(
          'Invalid "$field" in modification: expected an object but got '
          '$actual. The "$field" field must be shaped like: $hint',
        );
      }
    });
  }

  /// Applies modifications defined in the JSON schema to a note.
  /// Returns the updated Note object.
  Future<Note> applyModifications(
    String noteId,
    Map<String, dynamic> modifications,
  ) async {
    LoggerService.debug(
      'Applying modifications to note $noteId: $modifications',
    );

    _validateModificationShape(modifications);

    final note = await _db.getNoteById(noteId);
    if (note == null) {
      throw Exception('Note not found: $noteId');
    }

    await _enforceImmutableBinding(note, modifications);
    final updatedNote = _buildUpdatedNote(note, modifications);
    final linkEndpoints = _linkEndpoints(noteId, modifications['link']);

    // Note persistence and link changes commit atomically so a link failure
    // cannot leave a committed-but-unpublished note update behind.
    final db = await _db.database;
    await db.transaction((txn) async {
      await _persistNote(txn, updatedNote);
      await _applyLinkModifications(
        updatedNote.id,
        modifications['link'],
        txn: txn,
      );
    });

    _publishChange(
      noteIds: {noteId},
      tagsChanged: modifications.containsKey('tags'),
      relationshipNoteIds: linkEndpoints,
    );
    return updatedNote;
  }

  /// Applies multiple note modifications atomically.
  Future<List<Note>> applyBatchModifications(
    List<Map<String, dynamic>> updates,
  ) async {
    if (updates.isEmpty) {
      throw Exception('No note modifications provided.');
    }

    final prepared = <_PreparedNoteUpdate>[];
    for (final update in updates) {
      final noteId = update['note_id'] as String?;
      final modification = update['modification'] as Map<String, dynamic>?;
      if (noteId == null || noteId.isEmpty) {
        throw Exception('Each update must include a non-empty note_id.');
      }
      if (modification == null) {
        throw Exception('Each update must include a modification object.');
      }

      _validateModificationShape(modification);

      final note = await _db.getNoteById(noteId);
      if (note == null) {
        throw Exception('Note not found: $noteId');
      }

      await _enforceImmutableBinding(note, modification);
      prepared.add(
        _PreparedNoteUpdate(
          original: note,
          modification: modification,
          updated: _buildUpdatedNote(note, modification),
        ),
      );
    }

    final db = await _db.database;
    await db.transaction((txn) async {
      for (final update in prepared) {
        await _persistNote(txn, update.updated);
        await _applyLinkModifications(
          update.updated.id,
          update.modification['link'],
          txn: txn,
        );
      }
    });

    _publishChange(
      noteIds: {for (final update in prepared) update.updated.id},
      tagsChanged: prepared.any(
        (update) => update.modification.containsKey('tags'),
      ),
      relationshipNoteIds: {
        for (final update in prepared)
          ..._linkEndpoints(update.updated.id, update.modification['link']),
      },
    );

    return prepared.map((update) => update.updated).toList();
  }

  /// Builds a Note object from data without persisting to database.
  /// Use this when you need to handle insertion separately (e.g., via AppProvider.addNote).
  Future<Note> buildNote(Map<String, dynamic> data) async {
    final title = data['title']?.toString().trim() ?? 'Untitled Note';
    final content = data['content']?.toString().trim() ?? '';
    final typeString = data['type']?.toString() ?? 'note';
    final type = _parseNoteType(typeString);

    final now = DateTime.now();

    // Process subnotes - support both 'subNotes' array and 'subnotes' (case insensitive)
    final subNotes = <SubNote>[];
    final subNotesData = data['subNotes'] ?? data['subnotes'];
    if (subNotesData is List) {
      for (final subNoteData in subNotesData) {
        if (subNoteData is Map<String, dynamic>) {
          subNotes.add(_createSubNote(subNoteData));
        }
      }
    } else if (data['subnote'] is Map<String, dynamic>) {
      // Handle "subnote" property (added list) from schema if provided
      final subMod = data['subnote'] as Map<String, dynamic>;
      final addedSubnotes = (subMod['added'] as List?) ?? [];
      for (final s in addedSubnotes) {
        if (s is Map<String, dynamic>) {
          subNotes.add(_createSubNote(s));
        }
      }
    }

    // Process tags
    final tags =
        (data['tags'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];

    // Process attachments
    final attachmentPaths = <String>[];
    if (data['attachments'] is List) {
      for (final attachment in (data['attachments'] as List)) {
        attachmentPaths.add(await processAttachment(attachment));
      }
    }

    // Task fields
    String? scheduledAt;
    String? completeBy;
    TaskStatus? status;
    double? completionPercentage;

    if (type == NoteType.task) {
      scheduledAt =
          data['scheduledAt']?.toString() ?? data['scheduled_at']?.toString();
      completeBy =
          data['completeBy']?.toString() ?? data['complete_by']?.toString();
      status = data['status'] != null
          ? _parseTaskStatus(data['status'].toString())
          : TaskStatus.todo;
      completionPercentage =
          (data['completionPercentage'] ?? data['completion_percentage']) !=
              null
          ? (data['completionPercentage'] ??
                    data['completion_percentage'] as num)
                .toDouble()
          : 0.0;
    }

    return Note(
      id: _uuid.v4(),
      title: title,
      content: content,
      type: type,
      createdAt: now,
      updatedAt: now,
      subNotes: subNotes,
      tags: tags,
      attachmentPaths: attachmentPaths,
      scheduledAt: scheduledAt,
      completeBy: completeBy,
      status: status,
      completionPercentage: completionPercentage,
      pinned: data['pinned'] == true,
      isArchived: data['isArchived'] == true,
    );
  }

  /// Creates and persists a new note. For UI-aware insertion, use buildNote + AppProvider.addNote.
  Future<Note> createNote(Map<String, dynamic> data) async {
    final note = await buildNote(data);
    await _db.insertNote(note);
    // Publication is guarded rather than transactional here: insertNote owns
    // attachment-path conversion and cannot run against a transaction
    // executor. Reaching the try below means the note insert committed, so
    // the finally publishes it even when a later relationship insert throws
    // — a committed note must not stay invisible to the UI.
    final linkedEndpoints = <String>{};
    try {
      // If there are links (relationships)
      if (data.containsKey('link')) {
        final links = (data['link'] as List?) ?? [];
        for (final link in links) {
          if (link is Map<String, dynamic>) {
            final relationType = link['relation'] as String? ?? 'related';
            final targetId = link['target'] as String?;

            if (targetId != null) {
              await _db.insertRelationship(
                Relationship(
                  id: _uuid.v4(),
                  fromNoteId: note.id,
                  toNoteId: targetId,
                  type: relationType,
                  createdAt: DateTime.now(),
                ),
              );
              linkedEndpoints.add(targetId);
            }
          }
        }
      }

      return note;
    } finally {
      _publishChange(
        noteIds: {note.id},
        tagsChanged: note.tags.isNotEmpty,
        relationshipNoteIds: linkedEndpoints.isEmpty
            ? const {}
            : {note.id, ...linkedEndpoints},
      );
    }
  }

  Future<void> _enforceImmutableBinding(
    Note note,
    Map<String, dynamic> modifications,
  ) async {
    final tagWorkflow = getIt<TagWorkflowService>();
    final hasContentMod =
        modifications.containsKey('content') &&
        (modifications['content'] as Map<String, dynamic>)['action'] != 'no-op';
    final hasTitleMod = modifications.containsKey('title');

    if (!hasContentMod && !hasTitleMod) {
      return;
    }

    if (await tagWorkflow.hasImmutableBinding(note.tags)) {
      throw Exception(
        'Cannot modify content or title: this note has a tag with an immutable '
        'workflow binding. Tags, links, and attachments can still be modified.',
      );
    }
  }

  Note _buildUpdatedNote(Note note, Map<String, dynamic> modifications) {
    Note updatedNote = note;

    if (modifications.containsKey('content')) {
      final contentMod = modifications['content'] as Map<String, dynamic>;
      updatedNote = updatedNote.copyWith(
        content: _applyContentModification(updatedNote.content, contentMod),
      );
    }

    if (modifications.containsKey('title')) {
      final titleMod = modifications['title'] as Map<String, dynamic>;
      final newTitle = titleMod['new_title'] as String?;
      if (newTitle != null && newTitle.isNotEmpty) {
        updatedNote = updatedNote.copyWith(title: newTitle);
      }
    }

    if (modifications.containsKey('tags')) {
      final tagsMod = modifications['tags'] as Map<String, dynamic>;
      final addedTags = (tagsMod['added'] as List?)?.cast<String>() ?? [];
      final removedTags = (tagsMod['removed'] as List?)?.cast<String>() ?? [];
      final currentTags = Set<String>.from(updatedNote.tags);
      currentTags.addAll(addedTags);
      currentTags.removeAll(removedTags);
      updatedNote = updatedNote.copyWith(tags: currentTags.toList());
    }

    if (modifications.containsKey('attachments')) {
      final attMod = modifications['attachments'] as Map<String, dynamic>;
      final addedAtts = (attMod['added'] as List?)?.cast<String>() ?? [];
      final removedAtts = (attMod['removed'] as List?)?.cast<String>() ?? [];
      final currentAtts = Set<String>.from(updatedNote.attachmentPaths);
      currentAtts.addAll(addedAtts);
      currentAtts.removeAll(removedAtts);
      updatedNote = updatedNote.copyWith(attachmentPaths: currentAtts.toList());
    }

    if (modifications.containsKey('subnote')) {
      final subMod = modifications['subnote'] as Map<String, dynamic>;
      final addedSubnotes = (subMod['added'] as List?) ?? [];
      final removedIds = (subMod['removed'] as List?)?.cast<String>() ?? [];
      final currentSubnotes = List<SubNote>.from(updatedNote.subNotes);
      currentSubnotes.removeWhere((s) => removedIds.contains(s.id));

      for (final s in addedSubnotes) {
        if (s is Map<String, dynamic>) {
          currentSubnotes.add(
            SubNote(
              id: _uuid.v4(),
              name: s['name'] ?? s['title'] ?? 'Untitled Task',
              content: s['content'] ?? '',
              createdAt: DateTime.now(),
              isCompleted: false,
            ),
          );
        }
      }

      updatedNote = updatedNote.copyWith(subNotes: currentSubnotes);
    }

    return updatedNote.copyWith(updatedAt: DateTime.now());
  }

  String _applyContentModification(
    String currentContent,
    Map<String, dynamic> contentMod,
  ) {
    final action = contentMod['action'] as String? ?? 'no-op';
    final text = contentMod['text'] as String? ?? '';
    final section = contentMod['section'] as String?;
    final insertPosition = contentMod['insert_position'] as String? ?? action;

    // Empty append/prepend operations are no-ops, but an empty replacement is
    // meaningful: it clears the note. Block-scoped updates already follow this
    // contract, and Note Actions need it when removing the only formula.
    if (action == 'no-op' || (text.isEmpty && action != 'replace')) {
      return currentContent;
    }

    if (section != null && section.isNotEmpty) {
      return _applySectionContentModification(
        currentContent,
        section: section,
        text: text,
        insertPosition: insertPosition,
      );
    }

    return applyWholeContentAction(currentContent, action, text);
  }

  /// Applies an `append` / `prepend` / `replace` content action to a whole
  /// piece of content.
  ///
  /// Shared with [BlockNoteScopeService]-backed writes so that plugin edits to
  /// a transient block note behave exactly like the note-level equivalents.
  /// Section-scoped modifications are handled by the caller, not here.
  static String applyWholeContentAction(
    String currentContent,
    String action,
    String text,
  ) {
    switch (action) {
      case 'append':
        return '$currentContent\n$text';
      case 'prepend':
        return '$text\n$currentContent';
      case 'replace':
        return text;
      default:
        LoggerService.warning('Unknown content action: $action');
        return currentContent;
    }
  }

  String _applySectionContentModification(
    String content, {
    required String section,
    required String text,
    required String insertPosition,
  }) {
    final lines = content.split('\n');
    final headingIndex = lines.indexWhere((line) => line.trim() == section);
    if (headingIndex == -1) {
      throw Exception('Section not found: $section');
    }

    final headingLevel = _headingLevel(section);
    var sectionEnd = lines.length;
    for (var i = headingIndex + 1; i < lines.length; i++) {
      final level = _headingLevel(lines[i].trim());
      if (level != null && headingLevel != null && level <= headingLevel) {
        sectionEnd = i;
        break;
      }
    }

    final sectionBodyStart = headingIndex + 1;
    final before = lines.sublist(0, sectionBodyStart);
    final body = lines.sublist(sectionBodyStart, sectionEnd);
    final after = lines.sublist(sectionEnd);
    final textLines = text.split('\n');

    late final List<String> newBody;
    switch (insertPosition) {
      case 'append':
        newBody = [...body];
        if (newBody.isNotEmpty && newBody.last.isNotEmpty) {
          newBody.add('');
        }
        newBody.addAll(textLines);
        break;
      case 'prepend':
        newBody = [...textLines];
        if (body.isNotEmpty && newBody.isNotEmpty && newBody.last.isNotEmpty) {
          newBody.add('');
        }
        newBody.addAll(body);
        break;
      default:
        throw Exception(
          'Unsupported insert_position for section update: $insertPosition',
        );
    }

    return [...before, ...newBody, ...after].join('\n');
  }

  int? _headingLevel(String line) {
    final match = RegExp(r'^(#+)\s+').firstMatch(line);
    return match?.group(1)?.length;
  }

  // M1.11: subnote/attachment diffing now delegates to
  // `DatabaseService.diffAndPersistSubNotes`/`diffAndPersistAttachments` --
  // the single shared implementation `updateNote`
  // (database_service.dart) also calls, instead of this class maintaining
  // its own independently-duplicated copy of the diff logic (which is what
  // made `updateNote`/`_persistNote` a drift risk in the first place; see
  // both functions' own doc comments in database_service.dart for the full
  // id-/filePath-diff design).
  Future<void> _persistNote(DatabaseExecutor db, Note note) async {
    final json = note.toJson();
    json['createdAt'] = note.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = note.updatedAt.millisecondsSinceEpoch;
    json['pinned'] = note.pinned ? 1 : 0;
    json['isArchived'] = note.isArchived ? 1 : 0;
    json.remove('subNotes');
    json.remove('tags');
    json.remove('attachmentPaths');
    // Note objects loaded from the database never carry metadata (markers
    // etc. are written only via updateNoteMetadata), so writing toJson()'s
    // null here would wipe the column on every modification.
    json.remove('metadata');

    // M1.10: `AND __deleted__ = 0` -- a tombstoned note's row still
    // physically exists, so without this guard `updatedRows` would be 1
    // even though the note is meant to be gone, and the subnote/tag/
    // attachment writes below would incorrectly revive child rows for a
    // deleted note.
    final updatedRows = await db.update(
      'notes',
      json,
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [note.id],
    );
    if (updatedRows == 0) {
      // Note deleted (or tombstoned) between the read and this write;
      // creating child rows for a nonexistent/deleted note would orphan
      // them.
      throw Exception('Note no longer exists: ${note.id}');
    }

    // **M1.10-disclosed race with `deleteNote`, re-assessed by M1.11 --
    // likely already closed, not newly fixed here.** M1.10 recorded a race
    // between this liveness check and the child-row writes below,
    // reasoning conservatively that even though `_persistNote` always runs
    // inside a caller-supplied transaction (`applyModifications`/
    // `applyBatchModifications`'s `db.transaction`), that only protected
    // against a partial write of *this* call, not interleaving with a
    // concurrent `deleteNote`. Investigating this for M1.11 (see
    // `updateNote`'s own doc comment in database_service.dart, which cites
    // the actual sqflite source): `sqflite_common`'s
    // `DatabaseMixin.transaction()` acquires the single per-connection
    // write lock (`_rawLock`) for its *entire* callback duration, and every
    // statement run via the `txn`/`db` executor it hands out reuses that
    // same held lock rather than re-acquiring it -- so two `db.transaction`
    // calls against the same open `Database` (which `deleteNote` and
    // `applyModifications`/`applyBatchModifications` both are, via the
    // shared `DatabaseService` singleton) cannot actually interleave at
    // the statement level; one fully commits or rolls back before the
    // other's callback can start. Under that reading, the race M1.10
    // disclosed for `_persistNote` specifically was likely never
    // reachable in practice, even before this milestone -- unlike
    // `updateNote`, which issued each statement as its own separate,
    // un-transactioned call and so genuinely could interleave with a
    // concurrent `deleteNote` (see that function's doc comment for why,
    // and how M1.11 closes it there). This function's own atomicity
    // envelope is unchanged by M1.11: it still simply runs inside whatever
    // transaction its caller already opened. Recorded here, not silently
    // upgraded to "fixed", since this reasoning has not been independently
    // stress-tested against real concurrent callers the way `updateNote`'s
    // closure was reasoned through structurally -- if sqflite's locking
    // behavior above is ever wrong or changes, this residual reopens.
    await DatabaseService.diffAndPersistSubNotes(db, note.id, note.subNotes);

    await db.delete('note_tags', where: 'noteId = ?', whereArgs: [note.id]);
    for (final tagName in note.tags) {
      await _linkNoteToTag(db, note.id, tagName);
    }

    await DatabaseService.diffAndPersistAttachments(
      db,
      note.id,
      note.attachmentPaths,
    );
  }

  /// Test-only hook onto the private [_persistNote] above -- both callers
  /// in this file (`applyModifications`/`applyBatchModifications`) always
  /// reach it via a `db.transaction` callback after their own
  /// `getNoteById`/`_buildUpdatedNote` machinery, none of which M1.11's
  /// parity requirement (`updateNote` and `_persistNote` must behave
  /// identically for the same subnote/attachment diff) actually needs
  /// exercised. Lets tests drive `_persistNote` directly against a plain
  /// executor, exactly the same way `applyLinkModificationsForTest` (M1.8)
  /// already does for `_applyLinkModifications`.
  @visibleForTesting
  Future<void> persistNoteForTest(DatabaseExecutor db, Note note) =>
      _persistNote(db, note);

  /// Test-only hook onto the private [_applyLinkModifications] below --
  /// both callers in this file (`applyModifications`/
  /// `applyBatchModifications`) always pass a non-null `txn`, so the
  /// `txn == null` branch is otherwise unreachable from outside this class.
  /// Exists so M1.8's soft-delete conversion of both the `txn`- and
  /// non-`txn`-based relationship-removal paths can be exercised and
  /// verified directly (see
  /// test/relationships_conversation_attachments_soft_delete_test.dart),
  /// per the scoping pass flagging this pair as the most likely place for
  /// the two paths to drift.
  @visibleForTesting
  Future<void> applyLinkModificationsForTest(
    String noteId,
    dynamic linkData, {
    DatabaseExecutor? txn,
  }) => _applyLinkModifications(noteId, linkData, txn: txn);

  Future<void> _applyLinkModifications(
    String noteId,
    dynamic linkData, {
    DatabaseExecutor? txn,
  }) async {
    if (linkData == null) return;

    List<dynamic> addedLinks = [];
    List<String> removedTargets = [];

    if (linkData is List) {
      addedLinks = linkData;
    } else if (linkData is Map<String, dynamic>) {
      addedLinks = (linkData['added'] as List?) ?? [];
      removedTargets = (linkData['removed'] as List?)?.cast<String>() ?? [];
    }

    for (final link in addedLinks) {
      if (link is Map<String, dynamic>) {
        final relationType = link['relation'] as String? ?? 'related';
        final targetId = link['target'] as String?;
        if (targetId != null) {
          final relationship = Relationship(
            id: _uuid.v4(),
            fromNoteId: noteId,
            toNoteId: targetId,
            type: relationType,
            createdAt: DateTime.now(),
          );
          if (txn != null) {
            final json = relationship.toJson();
            json['createdAt'] = relationship.createdAt.millisecondsSinceEpoch;
            await txn.insert('relationships', json);
          } else {
            await _db.insertRelationship(relationship);
          }
        }
      }
    }

    for (final targetId in removedTargets) {
      if (txn != null) {
        // M1.8: tombstone write, not a real delete -- mirrors
        // DatabaseService.deleteRelationshipBetween's own conversion
        // exactly (same where clause, same "removes all types between
        // these two notes, in either direction" semantics), since this is
        // the txn-based sibling of that call used when a transaction was
        // already passed in.
        await txn.update(
          'relationships',
          {'__deleted__': 1},
          where:
              '(fromNoteId = ? AND toNoteId = ?) OR (fromNoteId = ? AND toNoteId = ?)',
          whereArgs: [noteId, targetId, targetId, noteId],
        );
      } else {
        await _db.deleteRelationshipBetween(noteId, targetId);
      }
    }
  }

  Future<void> _linkNoteToTag(
    DatabaseExecutor db,
    String noteId,
    String tagName,
  ) async {
    // M1.3: delegates to DatabaseService.getOrCreateLiveTagId — the single
    // shared, liveness-aware replacement for this method's own previously
    // independently-duplicated `_getOrCreateTagId` (this class held its own
    // copy of the exact same unguarded-lookup bug database_service.dart's
    // version had; see DatabaseService.findLiveTagByName's doc comment).
    final tagId = await DatabaseService.getOrCreateLiveTagId(db, tagName);
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

  /// Processes an attachment, promoting temporary files or handling base64.
  Future<String> processAttachment(dynamic attachment) async {
    if (attachment is String) {
      if (SynapseTempUtils.isSynapseTempUri(attachment)) {
        return await _promoteSynapseTempAttachment(attachment);
      }

      final isValid = await _db.verifyAttachmentPath(attachment);
      if (isValid) {
        return attachment;
      }

      // If it's just a filename that exists in the database already (as a relative path)
      // This is helpful for tools that might only pass the name.
      if (!attachment.contains('/')) {
        // Could search or just assume it's valid if it meets some criteria
        // But usually we prefer full relative paths or synapsetemp
      }

      throw Exception(
        'Invalid attachment path: $attachment - file not found in database',
      );
    } else if (attachment is Map<String, dynamic>) {
      if (attachment['type'] == 'base64' &&
          attachment['data'] != null &&
          attachment['fileName'] != null) {
        return await FileUtils.saveFileToPrivateStorage(
          _decodeBase64(attachment['data']),
          attachment['fileName'],
        );
      }
    }

    throw Exception('Invalid attachment format: $attachment');
  }

  List<int> _decodeBase64(String data) {
    var base64String = data;
    if (base64String.contains(',')) {
      base64String = base64String.split(',').last;
    }
    return base64Decode(base64String);
  }

  Future<String> _promoteSynapseTempAttachment(String uri) async {
    try {
      final tempFile = await SynapseTempUtils.loadFile(uri);
      final relativePath = await FileUtils.saveFileToPrivateStorage(
        tempFile.bytes,
        tempFile.fileName,
      );
      LoggerService.debug(
        '[NoteModificationService] Promoted temporary attachment ${tempFile.fileName} to $relativePath',
      );
      return relativePath;
    } catch (e) {
      LoggerService.error(
        '[NoteModificationService] Error promoting temporary attachment from $uri: $e',
        error: e,
      );
      throw Exception('Failed to promote temporary attachment: $e');
    }
  }

  SubNote _createSubNote(Map<String, dynamic> data) {
    final name =
        (data['name'] ?? data['title'])?.toString().trim() ?? 'Untitled Task';
    return SubNote(
      id: _uuid.v4(),
      name: name,
      content: data['content']?.toString().trim() ?? '',
      createdAt: DateTime.now(),
      isCompleted: data['isCompleted'] == true || data['is_completed'] == true,
    );
  }

  NoteType _parseNoteType(String typeString) {
    switch (typeString.toLowerCase()) {
      case 'note':
        return NoteType.note;
      case 'task':
        return NoteType.task;
      default:
        return NoteType.note;
    }
  }

  TaskStatus _parseTaskStatus(String statusString) {
    switch (statusString.toLowerCase()) {
      case 'todo':
        return TaskStatus.todo;
      case 'in_progress':
        return TaskStatus.inProgress;
      case 'complete':
        return TaskStatus.complete;
      case 'abandoned':
        return TaskStatus.abandoned;
      default:
        return TaskStatus.todo;
    }
  }
}

class _PreparedNoteUpdate {
  const _PreparedNoteUpdate({
    required this.original,
    required this.modification,
    required this.updated,
  });

  final Note original;
  final Map<String, dynamic> modification;
  final Note updated;
}
