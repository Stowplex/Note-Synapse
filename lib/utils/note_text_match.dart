// Reusable substring predicate for note filtering (plan §1.5/§1.6).
//
// This is the extracted form of the case-insensitive contains predicate that
// notes_screen.dart / note_selection_service.dart / saved filters implement
// inline today (Step 5 rewires those call sites onto this function). Unlike
// the inline copies it folds through NFKC (via [foldForMatch]) so full-width
// and compatibility characters compare equal, matching what the search index
// normalization does.
//
// NFKC costs several times what the plain `toLowerCase` it replaced did, and
// saved-filter matching runs over every note's FULL content on the widget
// build path (notes_screen._filterNotes -> AppProvider.getFilteredNotes), so
// the folded text is memoized per note in the bounded cache below.

import 'package:flutter/foundation.dart';

import '../models/note.dart';
import '../services/search/search_text_normalizer.dart';

/// Whether [note]'s title, content, or any tag contains [query] as a
/// case-insensitive (NFKC-folded) substring. An empty (or whitespace-folded
/// empty) query matches every note, mirroring the existing screen semantics
/// where an empty search box shows all notes.
///
/// [includeTags] exists for the one legacy call site (note_detail_screen's
/// link-note picker) whose inline predicate matched title/content only —
/// pass false there to preserve its behavior.
bool matchesSubstringQuery(
  Note note,
  String query, {
  bool includeTags = true,
}) => matchesFoldedQuery(note, foldForMatch(query), includeTags: includeTags);

/// [matchesSubstringQuery] for a query the caller already folded with
/// [foldForMatch]. Callers that test MANY notes against ONE query (saved
/// filters, list screens) should fold once and use this so the query is not
/// re-folded per note.
bool matchesFoldedQuery(
  Note note,
  String foldedQuery, {
  bool includeTags = true,
}) {
  if (foldedQuery.isEmpty) return true;
  final folded = _foldedNote(note);
  return folded.title.contains(foldedQuery) ||
      folded.content.contains(foldedQuery) ||
      (includeTags && folded.tags.any((tag) => tag.contains(foldedQuery)));
}

// ---------------------------------------------------------------------------
// Folded-text memoization
// ---------------------------------------------------------------------------

/// Cache bounds. An entry holds a folded COPY of the note's text, so the
/// cache is capped by BOTH an entry count and a total character budget — a
/// handful of very large notes must not pin megabytes. Eviction is LRU; once
/// a corpus no longer fits, matching simply degrades to the uncached cost.
const int _maxCachedNotes = 512;

/// UTF-16 code units (~4 MB at 2 bytes each).
const int _maxCachedChars = 2 * 1024 * 1024;

/// Insertion-ordered (LinkedHashMap): the first key is the least recently
/// used, and a hit is re-inserted to move it to the most-recent end.
final Map<String, _FoldedNote> _foldCache = <String, _FoldedNote>{};
int _foldCacheChars = 0;
int _foldCount = 0;

_FoldedNote _foldedNote(Note note) {
  final cached = _foldCache.remove(note.id);
  if (cached != null) {
    if (cached.isCurrentFor(note)) {
      _foldCache[note.id] = cached; // move to MRU
      return cached;
    }
    _foldCacheChars -= cached.chars; // stale (edited): drop and re-fold
  }

  _foldCount++;
  final folded = _FoldedNote.of(note);
  // A note that alone exceeds the budget is never cached (caching it would
  // evict everything else and still leave the cache over budget).
  if (folded.chars > _maxCachedChars) return folded;

  _foldCache[note.id] = folded;
  _foldCacheChars += folded.chars;
  while (_foldCache.length > _maxCachedNotes ||
      _foldCacheChars > _maxCachedChars) {
    final evicted = _foldCache.remove(_foldCache.keys.first)!;
    _foldCacheChars -= evicted.chars;
  }
  return folded;
}

/// A note's text folded once with [foldForMatch], plus the cheap fingerprint
/// used to decide whether the fold is still current. [Note.updatedAt] is the
/// primary guard; the lengths catch in-place edits that reuse a timestamp.
class _FoldedNote {
  _FoldedNote._({
    required this.title,
    required this.content,
    required this.tags,
    required this.chars,
    required this.updatedAtMicros,
    required this.titleLength,
    required this.contentLength,
    required this.tagCount,
  });

  factory _FoldedNote.of(Note note) {
    final title = foldForMatch(note.title);
    final content = foldForMatch(note.content);
    final tags = note.tags.map(foldForMatch).toList(growable: false);
    var chars = title.length + content.length;
    for (final tag in tags) {
      chars += tag.length;
    }
    return _FoldedNote._(
      title: title,
      content: content,
      tags: tags,
      chars: chars,
      updatedAtMicros: note.updatedAt.microsecondsSinceEpoch,
      titleLength: note.title.length,
      contentLength: note.content.length,
      tagCount: note.tags.length,
    );
  }

  final String title;
  final String content;
  final List<String> tags;

  /// Folded UTF-16 code units held by this entry (the cache's size unit).
  final int chars;

  final int updatedAtMicros;
  final int titleLength;
  final int contentLength;
  final int tagCount;

  bool isCurrentFor(Note note) =>
      updatedAtMicros == note.updatedAt.microsecondsSinceEpoch &&
      titleLength == note.title.length &&
      contentLength == note.content.length &&
      tagCount == note.tags.length;
}

/// Test hook: how many times a note's text has actually been folded (i.e.
/// cache misses). Stays flat while repeated builds re-match unchanged notes.
@visibleForTesting
int get noteFoldCount => _foldCount;

/// Test hook: entries currently memoized.
@visibleForTesting
int get noteFoldCacheSize => _foldCache.length;

/// Test hook: drops all memoized folds so tests start from a known state.
@visibleForTesting
void resetNoteFoldCache() {
  _foldCache.clear();
  _foldCacheChars = 0;
  _foldCount = 0;
}
