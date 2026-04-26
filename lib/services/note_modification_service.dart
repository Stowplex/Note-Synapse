import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import 'database_service.dart';
import '../utils/file_utils.dart';
import '../utils/file_type_utils.dart';
import '../utils/synapse_temp_utils.dart';
import 'logger_service.dart';
import 'service_locator.dart';
import 'tag_workflow_service.dart';

class NoteModificationService {
  final DatabaseService _db;
  final Uuid _uuid = const Uuid();

  /// Creates a NoteModificationService.
  ///
  /// [db] - The database service for persistence operations.
  NoteModificationService(this._db);

  /// Applies modifications defined in the JSON schema to a note.
  /// Returns the updated Note object.
  Future<Note> applyModifications(
    String noteId,
    Map<String, dynamic> modifications,
  ) async {
    LoggerService.debug(
      'Applying modifications to note $noteId: $modifications',
    );

    final note = await _db.getNoteById(noteId);
    if (note == null) {
      throw Exception('Note not found: $noteId');
    }

    await _enforceImmutableBinding(note, modifications);
    final updatedNote = _buildUpdatedNote(note, modifications);
    await _db.updateNote(updatedNote);
    await _applyLinkModifications(updatedNote.id, modifications['link']);
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
          }
        }
      }
    }

    return note;
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

    if (action == 'no-op' || text.isEmpty) {
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

  Future<void> _persistNote(DatabaseExecutor db, Note note) async {
    final json = note.toJson();
    json['createdAt'] = note.createdAt.millisecondsSinceEpoch;
    json['updatedAt'] = note.updatedAt.millisecondsSinceEpoch;
    json['pinned'] = note.pinned ? 1 : 0;
    json['isArchived'] = note.isArchived ? 1 : 0;
    json.remove('subNotes');
    json.remove('tags');
    json.remove('attachmentPaths');

    await db.update('notes', json, where: 'id = ?', whereArgs: [note.id]);

    await db.delete('subnotes', where: 'noteId = ?', whereArgs: [note.id]);
    for (final subNote in note.subNotes) {
      await db.insert('subnotes', {
        'id': subNote.id,
        'noteId': note.id,
        'name': subNote.name,
        'content': subNote.content,
        'createdAt': subNote.createdAt.millisecondsSinceEpoch,
        'isCompleted': subNote.isCompleted ? 1 : 0,
      });
    }

    await db.delete('note_tags', where: 'noteId = ?', whereArgs: [note.id]);
    for (final tagName in note.tags) {
      await _linkNoteToTag(db, note.id, tagName);
    }

    final existingAttachmentsRows = await db.query(
      'attachments',
      columns: ['filePath', 'includeInAIContext'],
      where: 'noteId = ?',
      whereArgs: [note.id],
    );
    final existingPaths = <String>{};
    final existingContextMap = <String, bool>{};
    for (final row in existingAttachmentsRows) {
      final path = row['filePath'] as String;
      existingPaths.add(path);
      existingContextMap[path] = (row['includeInAIContext'] as int?) != 0;
    }

    final pathsToKeep = <String>{};
    for (final attachmentPath in note.attachmentPaths) {
      var isRelativePath = attachmentPath.startsWith('attachments/');
      var finalPath = attachmentPath;
      if (!isRelativePath) {
        final relativePath = await FileUtils.getRelativePath(attachmentPath);
        if (relativePath != null) {
          finalPath = relativePath;
          isRelativePath = true;
        }
      }

      if (existingPaths.contains(finalPath)) {
        pathsToKeep.add(finalPath);
      } else {
        final includeInAIContext =
            existingContextMap[finalPath] ??
            existingContextMap[attachmentPath] ??
            true;
        await _insertAttachment(
          db,
          note.id,
          finalPath,
          isRelativePath: isRelativePath,
          includeInAIContext: includeInAIContext,
        );
      }
    }

    for (final existingPath in existingPaths) {
      if (!pathsToKeep.contains(existingPath)) {
        await db.delete(
          'attachments',
          where: 'noteId = ? AND filePath = ?',
          whereArgs: [note.id, existingPath],
        );
      }
    }
  }

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
        await txn.delete(
          'relationships',
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
    final tagId = await _getOrCreateTagId(db, tagName);
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

  Future<String> _getOrCreateTagId(DatabaseExecutor db, String tagName) async {
    final existing = await db.query(
      'tags',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: [tagName],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return existing.first['id'] as String;
    }

    final tagId = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('tags', {
      'id': tagId,
      'name': tagName,
      'color': '#2196F3',
      'createdAt': now,
      'usageCount': 0,
    });
    return tagId;
  }

  Future<void> _insertAttachment(
    DatabaseExecutor db,
    String noteId,
    String filePath, {
    bool isRelativePath = false,
    bool includeInAIContext = true,
  }) async {
    final fileName = filePath.split('/').last;
    final fileType = FileTypeUtils.getFileExtension(fileName);
    final isHtml =
        fileType.toLowerCase() == 'html' || fileType.toLowerCase() == 'htm';
    final finalIncludeInAIContext = isHtml ? false : includeInAIContext;

    await db.insert('attachments', {
      'id': _uuid.v4(),
      'noteId': noteId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
      'isRelativePath': isRelativePath ? 1 : 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': finalIncludeInAIContext ? 1 : 0,
    });
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
