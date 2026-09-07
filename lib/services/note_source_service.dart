import 'dart:convert';

import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/logger_service.dart';
import 'package:note_synapse/utils/note_metadata.dart';

// data-change-exempt: this service only writes notes.metadata (sources), and
// metadata is never loaded into cached Note objects (_mapToNote skips it), so
// a DataChangeNotifier publish would trigger a full note refetch with zero
// cache benefit.

/// Persists where a note's content was clipped from: the `sources` list in
/// `notes.metadata` (see [NoteMetadata] for the map rules).
///
/// `DatabaseService.updateNoteMetadata` replaces the whole JSON and the map
/// is shared with `NoteMarkerService` (`markers`), so every write here is
/// read-merge-write through [NoteMetadata.withSources], which carries every
/// other key over untouched. A write that would leave the source list as it
/// is gets skipped. Like `NoteMarkerService`, nothing here throws: failures
/// are logged, and reads degrade to an empty list.
class NoteSourceService {
  final DatabaseService _db;
  NoteSourceService(this._db);

  /// The sources of [noteId] in stored order; empty when the note has none,
  /// does not exist, or its metadata cannot be read. Entries that are not
  /// usable (see [NoteMetadata.readSources]) are skipped.
  Future<List<NoteSource>> getSources(String noteId) async {
    try {
      return NoteMetadata.readSources(await _readMetadata(noteId));
    } catch (e) {
      LoggerService.warning('Failed to get note sources', error: e);
      return [];
    }
  }

  /// Appends [sources] to [noteId]'s list. A source whose `url` is already
  /// recorded is ignored so that the existing entry — its id, title and clip
  /// time — survives; duplicates within [sources] collapse to the first, and
  /// a blank `url` is dropped. Nothing is written when there is nothing new
  /// to add.
  Future<void> addSources(String noteId, List<NoteSource> sources) async {
    if (sources.isEmpty) return;
    try {
      final metadata = await _readMetadata(noteId);
      final existing = NoteMetadata.readSources(metadata);
      final known = existing.map(NoteMetadata.sourceKey).toSet();
      final hasNew = sources.any((s) {
        final key = NoteMetadata.sourceKey(s);
        return key.isNotEmpty && !known.contains(key);
      });
      if (!hasNew) return;
      await _db.updateNoteMetadata(
        noteId,
        NoteMetadata.withSources(metadata, [...existing, ...sources]),
      );
    } catch (e) {
      LoggerService.warning('Failed to add note sources', error: e);
    }
  }

  /// Replaces the entry whose `id` matches [source], keeping its position.
  /// Any other entry with the same `url` is then dropped, so the first-wins
  /// de-duplication of [NoteMetadata.withSources] never discards the entry
  /// that was just edited. When no entry has that id, [source] is appended
  /// — unless its `url` is already recorded, in which case the existing
  /// entry wins, as in [addSources]. A blank `url` is never written, in
  /// either branch (it would otherwise turn an edit into a removal), and
  /// nothing is written when the stored entry already equals [source].
  Future<void> updateSource(String noteId, NoteSource source) async {
    try {
      final metadata = await _readMetadata(noteId);
      final existing = NoteMetadata.readSources(metadata);
      final index = existing.indexWhere((s) => s.id == source.id);
      final key = NoteMetadata.sourceKey(source);
      if (key.isEmpty) return;
      final List<NoteSource> updated;
      if (index >= 0) {
        if (_sameEntry(existing[index], source)) return;
        updated = List.of(existing)..[index] = source;
        updated.removeWhere(
          (s) => s.id != source.id && NoteMetadata.sourceKey(s) == key,
        );
      } else {
        final known = existing.any((s) => NoteMetadata.sourceKey(s) == key);
        if (known) return;
        updated = [...existing, source];
      }
      await _db.updateNoteMetadata(
        noteId,
        NoteMetadata.withSources(metadata, updated),
      );
    } catch (e) {
      LoggerService.warning('Failed to update note source', error: e);
    }
  }

  /// Removes the entry with [sourceId]; every other entry and every other
  /// metadata key stays. Nothing is written when no entry has that id.
  Future<void> removeSource(String noteId, String sourceId) async {
    try {
      final metadata = await _readMetadata(noteId);
      final existing = NoteMetadata.readSources(metadata);
      final remaining = existing.where((s) => s.id != sourceId).toList();
      if (remaining.length == existing.length) return;
      await _db.updateNoteMetadata(
        noteId,
        NoteMetadata.withSources(metadata, remaining),
      );
    } catch (e) {
      LoggerService.warning('Failed to remove note source', error: e);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// [DatabaseService.getNoteMetadata], with a column that holds JSON this
  /// app cannot use (not valid JSON, or a top level that is not an object)
  /// logged and treated as empty: no reader can use it either, so the next
  /// write may replace it. Database errors propagate, so a write never runs
  /// against a guessed-empty map that would wipe `markers`.
  Future<Map<String, dynamic>?> _readMetadata(String noteId) async {
    try {
      return await _db.getNoteMetadata(noteId);
    } catch (e) {
      if (e is! FormatException && e is! TypeError) rethrow;
      LoggerService.warning(
        'Note $noteId has malformed metadata; treating it as empty',
        error: e,
      );
      return null;
    }
  }

  /// Whether [a] and [b] would be stored as the same JSON entry.
  static bool _sameEntry(NoteSource a, NoteSource b) =>
      jsonEncode(a.toJson()) == jsonEncode(b.toJson());
}
