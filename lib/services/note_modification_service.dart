import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import 'database_service.dart';
import 'logger_service.dart';

class NoteModificationService {
  final DatabaseService _db = DatabaseService();
  final Uuid _uuid = const Uuid();

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
      final links = (modifications['link'] as List?) ?? [];
      for (final link in links) {
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
    }

    return updatedNote;
  }
}
