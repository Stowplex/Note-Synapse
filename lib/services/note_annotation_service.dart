import '../models/note_annotation.dart';
import 'database_service.dart';
import 'logger_service.dart';

class NoteAnnotationService {
  final DatabaseService _db;
  NoteAnnotationService(this._db);

  Future<void> saveAnnotation(NoteAnnotation annotation) async {
    try {
      await _db.saveNoteAnnotation(annotation);
    } catch (e) {
      LoggerService.warning('Failed to save annotation: $e');
    }
  }

  Future<NoteAnnotation?> getAnnotation(String id) async {
    try {
      return await _db.getNoteAnnotation(id);
    } catch (e) {
      LoggerService.warning('Failed to get annotation: $e');
      return null;
    }
  }

  Future<List<NoteAnnotation>> getAnnotationsForNote(String noteId) async {
    try {
      return await _db.getNoteAnnotationsForNote(noteId);
    } catch (e) {
      LoggerService.warning('Failed to get note annotations: $e');
      return [];
    }
  }

  Future<List<NoteAnnotation>> getAnnotationsForAttachment(
    String attachmentId,
  ) async {
    try {
      return await _db.getNoteAnnotationsForAttachment(attachmentId);
    } catch (e) {
      LoggerService.warning('Failed to get attachment annotations: $e');
      return [];
    }
  }

  Future<void> deleteAnnotation(String id) async {
    try {
      await _db.deleteNoteAnnotation(id);
    } catch (e) {
      LoggerService.warning('Failed to delete annotation: $e');
    }
  }
}
