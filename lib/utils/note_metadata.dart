import 'dart:convert';

import '../models/note_source.dart';

/// Pure helpers over the `notes.metadata` JSON map.
///
/// The map is shared with other owners (`NoteMarkerService` owns `markers`),
/// so every helper preserves keys it does not understand and never mutates
/// its input. Persistence lives elsewhere: `DatabaseService.updateNoteMetadata`
/// replaces the whole JSON, so a writer must read, merge with [withSources],
/// then write.
class NoteMetadata {
  NoteMetadata._();

  /// Key of the source list inside the metadata map.
  static const String sourcesKey = 'sources';

  /// The identity a source is de-duplicated on: its `url` (which
  /// [NoteSource] stores trimmed). The one rule shared by [readSources],
  /// [withSources] and `NoteSourceService`, so the read side, the write side
  /// and the service's "already recorded" checks always agree.
  static String sourceKey(NoteSource source) => source.url;

  /// Decodes a `notes.metadata` column value. Null for null, blank, invalid
  /// JSON, or JSON whose top level is not an object.
  static Map<String, dynamic>? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Not JSON we can use; treated as no metadata.
    }
    return null;
  }

  /// The `sources` list of [metadata], in stored order. Entries that are not
  /// objects or have no usable `url` are skipped rather than failing the
  /// whole list, and a repeated `url` keeps its first entry only, mirroring
  /// [withSources] so the read and write sides agree (two id-less entries
  /// with the same url would otherwise come back with the same derived id).
  static List<NoteSource> readSources(Map<String, dynamic>? metadata) {
    final raw = metadata?[sourcesKey];
    if (raw is! List) return [];
    final sources = <NoteSource>[];
    final seenUrls = <String>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        final source = NoteSource.fromJson(Map<String, dynamic>.from(entry));
        if (!seenUrls.add(sourceKey(source))) continue;
        sources.add(source);
      } catch (_) {
        // Malformed entry: skip it.
      }
    }
    return sources;
  }

  /// A new map: [metadata] with its `sources` list replaced by [sources],
  /// de-duplicated on `url` (first occurrence wins). A source whose `url`
  /// is blank is dropped, since [readSources] would skip it anyway. Every
  /// other key (`markers`, ...) is carried over untouched and [metadata]
  /// itself is not modified. An empty result removes the key.
  static Map<String, dynamic> withSources(
    Map<String, dynamic>? metadata,
    List<NoteSource> sources,
  ) {
    final result = Map<String, dynamic>.from(metadata ?? const {});
    final seenUrls = <String>{};
    final unique = <Map<String, dynamic>>[];
    for (final source in sources) {
      final key = sourceKey(source);
      if (key.isEmpty) continue;
      if (seenUrls.add(key)) unique.add(source.toJson());
    }
    if (unique.isEmpty) {
      result.remove(sourcesKey);
    } else {
      result[sourcesKey] = unique;
    }
    return result;
  }

  /// JSON string for `Note.metadata` holding [sources] — merged into [into]
  /// when given so other keys survive. Same de-duplication as [withSources].
  static String encodeSources(
    List<NoteSource> sources, {
    Map<String, dynamic>? into,
  }) => jsonEncode(withSources(into, sources));
}
