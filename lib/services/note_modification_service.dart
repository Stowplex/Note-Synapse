import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import 'database_service.dart';
import '../utils/file_utils.dart';
import '../utils/synapse_temp_utils.dart';
import 'logger_service.dart';

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

    Note updatedNote = note;

    // 1. Content Modification
    if (modifications.containsKey('content')) {
      final contentMod = modifications['content'] as Map<String, dynamic>;
      final action = contentMod['action'] as String? ?? 'no-op';
      final text = contentMod['text'] as String? ?? '';

      if (action != 'no-op' && text.isNotEmpty) {
        String newContent = updatedNote.content;
        switch (action) {
          case 'append':
            newContent = '$newContent\n$text';
            break;
          case 'prepend':
            newContent = '$text\n$newContent';
            break;
          case 'replace':
            newContent = text;
            break;
          default:
            LoggerService.warning('Unknown content action: $action');
        }
        updatedNote = updatedNote.copyWith(content: newContent);
      }
    }

    // 2. Title Modification
    if (modifications.containsKey('title')) {
      final titleMod = modifications['title'] as Map<String, dynamic>;
      final newTitle = titleMod['new_title'] as String?;
      if (newTitle != null && newTitle.isNotEmpty) {
        updatedNote = updatedNote.copyWith(title: newTitle);
      }
    }

    // 3. Tags Modification
    if (modifications.containsKey('tags')) {
      final tagsMod = modifications['tags'] as Map<String, dynamic>;
      final addedTags = (tagsMod['added'] as List?)?.cast<String>() ?? [];
      final removedTags = (tagsMod['removed'] as List?)?.cast<String>() ?? [];

      final currentTags = Set<String>.from(updatedNote.tags);
      currentTags.addAll(addedTags);
      currentTags.removeAll(removedTags);
      updatedNote = updatedNote.copyWith(tags: currentTags.toList());
    }

    // 4. Attachments Modification
    if (modifications.containsKey('attachments')) {
      final attMod = modifications['attachments'] as Map<String, dynamic>;
      final addedAtts = (attMod['added'] as List?)?.cast<String>() ?? [];
      final removedAtts = (attMod['removed'] as List?)?.cast<String>() ?? [];

      final currentAtts = Set<String>.from(updatedNote.attachmentPaths);
      currentAtts.addAll(addedAtts);
      currentAtts.removeAll(removedAtts);
      updatedNote = updatedNote.copyWith(attachmentPaths: currentAtts.toList());
    }

    // 5. Subnotes Modification
    if (modifications.containsKey('subnote')) {
      final subMod = modifications['subnote'] as Map<String, dynamic>;
      final addedSubnotes = (subMod['added'] as List?) ?? [];
      final removedIds = (subMod['removed'] as List?)?.cast<String>() ?? [];

      final currentSubnotes = List<SubNote>.from(updatedNote.subNotes);

      // Remove
      currentSubnotes.removeWhere((s) => removedIds.contains(s.id));

      // Add
      for (final s in addedSubnotes) {
        if (s is Map<String, dynamic>) {
          final name = s['name'] ?? s['title'] ?? 'Untitled Task';
          final content = s['content'] ?? '';

          currentSubnotes.add(
            SubNote(
              id: _uuid.v4(),
              name: name,
              content: content,
              createdAt: DateTime.now(),
              isCompleted: false,
            ),
          );
        }
      }
      updatedNote = updatedNote.copyWith(subNotes: currentSubnotes);
    }

    // Persist changes to Note table + Tags + Subnotes + Attachments
    updatedNote = updatedNote.copyWith(updatedAt: DateTime.now());
    await _db.updateNote(updatedNote);

    // 6. Links (Relationship) Modification
    if (modifications.containsKey('link')) {
      final linkData = modifications['link'];

      List<dynamic> addedLinks = [];
      List<String> removedTargets = [];

      if (linkData is List) {
        // Old format: treat entire list as additions
        addedLinks = linkData;
      } else if (linkData is Map<String, dynamic>) {
        addedLinks = (linkData['added'] as List?) ?? [];
        removedTargets =
            (linkData['removed'] as List?)?.cast<String>() ?? [];
      }

      for (final link in addedLinks) {
        if (link is Map<String, dynamic>) {
          final relationType = link['relation'] as String? ?? 'related';
          final targetId = link['target'] as String?;

          if (targetId != null) {
            await _db.insertRelationship(
              Relationship(
                id: _uuid.v4(),
                fromNoteId: updatedNote.id,
                toNoteId: targetId,
                type: relationType,
                createdAt: DateTime.now(),
              ),
            );
          }
        }
      }

      for (final targetId in removedTargets) {
        await _db.deleteRelationshipBetween(updatedNote.id, targetId);
      }
    }

    return updatedNote;
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
