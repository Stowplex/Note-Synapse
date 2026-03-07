import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/logger_service.dart';

class NoteMarkerService {
  final DatabaseService _db;
  NoteMarkerService(this._db);

  // ── Attachment markers (PDF / image) ────────────────────────────────────

  Future<void> saveMarkerForAttachment(
    String attachmentId,
    InNoteMarker marker,
  ) async {
    try {
      final attachment = await _db.getAttachmentById(attachmentId);
      if (attachment == null) return;
      final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
      final markers = _parseMarkers(metadata['markers']);
      markers.add(marker.toJson());
      metadata['markers'] = markers;
      await _db.updateAttachmentMetadata(attachmentId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to save attachment marker: $e');
    }
  }

  Future<List<InNoteMarker>> getMarkersForAttachment(
    String attachmentId,
  ) async {
    try {
      final attachment = await _db.getAttachmentById(attachmentId);
      if (attachment == null) return [];
      return _parseMarkers(attachment.metadata?['markers'])
          .map((e) => InNoteMarker.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      LoggerService.warning('Failed to get attachment markers: $e');
      return [];
    }
  }

  Future<void> deleteMarkerForAttachment(
    String attachmentId,
    String markerId,
  ) async {
    try {
      final attachment = await _db.getAttachmentById(attachmentId);
      if (attachment == null) return;
      final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
      final markers = _parseMarkers(metadata['markers'])
        ..removeWhere((m) => (m as Map<String, dynamic>)['id'] == markerId);
      metadata['markers'] = markers;
      await _db.updateAttachmentMetadata(attachmentId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to delete attachment marker: $e');
    }
  }

  // ── Note markers (text notes) ────────────────────────────────────────────

  Future<void> saveMarkerForNote(String noteId, InNoteMarker marker) async {
    try {
      final metadata = Map<String, dynamic>.from(
        await _db.getNoteMetadata(noteId) ?? {},
      );
      final markers = _parseMarkers(metadata['markers']);
      markers.add(marker.toJson());
      metadata['markers'] = markers;
      await _db.updateNoteMetadata(noteId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to save note marker: $e');
    }
  }

  Future<List<InNoteMarker>> getMarkersForNote(String noteId) async {
    try {
      final metadata = await _db.getNoteMetadata(noteId);
      return _parseMarkers(metadata?['markers'])
          .map((e) => InNoteMarker.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      LoggerService.warning('Failed to get note markers: $e');
      return [];
    }
  }

  Future<void> deleteMarkerForNote(String noteId, String markerId) async {
    try {
      final metadata = Map<String, dynamic>.from(
        await _db.getNoteMetadata(noteId) ?? {},
      );
      final markers = _parseMarkers(metadata['markers'])
        ..removeWhere((m) => (m as Map<String, dynamic>)['id'] == markerId);
      metadata['markers'] = markers;
      await _db.updateNoteMetadata(noteId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to delete note marker: $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  List<dynamic> _parseMarkers(dynamic raw) {
    if (raw is List) return List<dynamic>.from(raw);
    return [];
  }
}
