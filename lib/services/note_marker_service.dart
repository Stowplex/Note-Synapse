import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/logger_service.dart';

// data-change-exempt: this service only writes notes.metadata /
// attachments.metadata (markers), and metadata is never loaded into cached
// Note objects (_mapToNote skips it), so a DataChangeNotifier publish would
// trigger a full note refetch with zero cache benefit.
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

  // ── Marker-by-id operations (parent-agnostic) ───────────────────────────

  /// Updates the `lastViewedConversationId` field on the marker with
  /// [markerId], wherever it lives. Pass [newConvId] = `null` to clear
  /// the field (e.g. when the previously-viewed branch was deleted and we
  /// want to fall back to the original conversation on next open).
  ///
  /// Implementation note: walks all notes and all attachments looking
  /// for the marker by ID. This is O(notes + attachments) per call.
  /// At v1 scale (typical users have well under 100 markers across all
  /// notes) this is fine; revisit if marker counts grow significantly.
  /// Chosen over widening the public API to take a parent ID because
  /// callers (the marker preview re-entry flow) don't always know which
  /// note/attachment the marker came from.
  Future<void> updateMarkerLastViewed(
    String markerId,
    String? newConvId,
  ) async {
    try {
      // Try notes first.
      final notes = await _db.getAllNotes();
      for (final note in notes) {
        final metadata = await _db.getNoteMetadata(note.id);
        final markers = _parseMarkers(metadata?['markers']);
        final idx = markers.indexWhere(
          (m) => (m as Map<String, dynamic>)['id'] == markerId,
        );
        if (idx >= 0) {
          final updated = Map<String, dynamic>.from(
            markers[idx] as Map<String, dynamic>,
          );
          if (newConvId == null) {
            updated.remove('lastViewedConversationId');
          } else {
            updated['lastViewedConversationId'] = newConvId;
          }
          markers[idx] = updated;
          final newMeta = Map<String, dynamic>.from(metadata ?? {});
          newMeta['markers'] = markers;
          await _db.updateNoteMetadata(note.id, newMeta);
          return;
        }
      }
      // Fall through to attachments.
      final attachmentMaps = await _db.getAllAttachments();
      for (final raw in attachmentMaps) {
        final attachment = Attachment.fromDatabase(raw);
        final metadata = attachment.metadata;
        final markers = _parseMarkers(metadata?['markers']);
        final idx = markers.indexWhere(
          (m) => (m as Map<String, dynamic>)['id'] == markerId,
        );
        if (idx >= 0) {
          final updated = Map<String, dynamic>.from(
            markers[idx] as Map<String, dynamic>,
          );
          if (newConvId == null) {
            updated.remove('lastViewedConversationId');
          } else {
            updated['lastViewedConversationId'] = newConvId;
          }
          markers[idx] = updated;
          final newMeta = Map<String, dynamic>.from(metadata ?? {});
          newMeta['markers'] = markers;
          await _db.updateAttachmentMetadata(attachment.id, newMeta);
          return;
        }
      }
      LoggerService.warning(
        'updateMarkerLastViewed: marker $markerId not found',
      );
    } catch (e) {
      LoggerService.warning('Failed to update marker lastViewed: $e');
    }
  }

  /// Removes the marker with [markerId] from wherever it lives (note or
  /// attachment). Same scan-all approach as [updateMarkerLastViewed]; see
  /// the rationale there.
  Future<void> deleteMarker(String markerId) async {
    try {
      final notes = await _db.getAllNotes();
      for (final note in notes) {
        final metadata = await _db.getNoteMetadata(note.id);
        final markers = _parseMarkers(metadata?['markers']);
        if (markers.any(
          (m) => (m as Map<String, dynamic>)['id'] == markerId,
        )) {
          await deleteMarkerForNote(note.id, markerId);
          return;
        }
      }
      final attachmentMaps = await _db.getAllAttachments();
      for (final raw in attachmentMaps) {
        final attachment = Attachment.fromDatabase(raw);
        final markers = _parseMarkers(attachment.metadata?['markers']);
        if (markers.any(
          (m) => (m as Map<String, dynamic>)['id'] == markerId,
        )) {
          await deleteMarkerForAttachment(attachment.id, markerId);
          return;
        }
      }
      LoggerService.warning('deleteMarker: marker $markerId not found');
    } catch (e) {
      LoggerService.warning('Failed to delete marker: $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  List<dynamic> _parseMarkers(dynamic raw) {
    if (raw is List) return List<dynamic>.from(raw);
    return [];
  }
}
