// Pure presentation logic for search results and the first-run index banner
// (plan §1.6). Extracted from notes_screen.dart so it is unit-testable:
// badge derivation maps chunk provenance (sourceType / 1-based page) to a
// user-facing badge KIND — the screen turns the kind into l10n'd text — and
// the banner helpers decide visibility/percent from [IndexProgress].

import '../services/search/note_index_service.dart' show IndexProgress;

/// User-facing source-provenance badge kinds (plan §1.6: "PDF · p.4",
/// "Image", "Sub-note", "Tag" — provenance, not retrieval-layer jargon).
enum SearchBadgeKind {
  /// No badge: the match came from the note body itself.
  none,

  /// Attachment-derived match with a known page ("PDF · p.N").
  pdfPage,

  /// Attachment text without a page (non-paged attachment formats).
  attachment,

  /// Raster image content (OCR of an image attachment, or a figure chunk).
  image,

  /// Sub-note content.
  subnote,

  /// The note's meta chunk (title + tags). Plan §1.6 labels this "Tag":
  /// the chunk exists to restore tag matching, and a plain title match is
  /// indistinguishable from it at this level.
  tag,

  /// Annotation content.
  annotation,
}

/// A derived badge: [kind] plus the 1-based [page] when [kind] is
/// [SearchBadgeKind.pdfPage].
class SearchSourceBadge {
  const SearchSourceBadge(this.kind, {this.page});

  final SearchBadgeKind kind;
  final int? page;

  @override
  bool operator ==(Object other) =>
      other is SearchSourceBadge && other.kind == kind && other.page == page;

  @override
  int get hashCode => Object.hash(kind, page);

  @override
  String toString() => 'SearchSourceBadge($kind, page: $page)';
}

/// Maps a best-chunk's provenance to its badge. [sourceType] is one of the
/// search_chunks sourceType values (meta | note_body | subnote | annotation |
/// attachment_text | attachment_ocr | figure); [page] is 1-based.
///
/// Unknown sourceTypes (future stages) degrade to no badge rather than
/// mislabeling.
SearchSourceBadge deriveSearchBadge({required String sourceType, int? page}) {
  switch (sourceType) {
    case 'meta':
      return const SearchSourceBadge(SearchBadgeKind.tag);
    case 'subnote':
      return const SearchSourceBadge(SearchBadgeKind.subnote);
    case 'annotation':
      return const SearchSourceBadge(SearchBadgeKind.annotation);
    case 'attachment_text':
      return page != null
          ? SearchSourceBadge(SearchBadgeKind.pdfPage, page: page)
          : const SearchSourceBadge(SearchBadgeKind.attachment);
    case 'attachment_ocr':
      // Paged OCR text comes from PDF pages; page-less OCR text comes from
      // raster image attachments.
      return page != null
          ? SearchSourceBadge(SearchBadgeKind.pdfPage, page: page)
          : const SearchSourceBadge(SearchBadgeKind.image);
    case 'figure':
      return const SearchSourceBadge(SearchBadgeKind.image);
    case 'note_body':
    default:
      return const SearchSourceBadge(SearchBadgeKind.none);
  }
}

/// First-run banner visibility (plan §1.6): visible only while a backfill is
/// actually running AND the user has not dismissed it. Auto-hides at
/// completion because the indexer flips [IndexProgress.running] off.
///
/// [dismissed] is tri-state: null means the persisted dismissal flag has not
/// been read back yet (the SharedPreferences read is async), and the banner
/// stays hidden until it resolves so an already-dismissed banner cannot flash
/// on the first frame(s) after mount.
bool shouldShowIndexBanner({
  required IndexProgress progress,
  required bool? dismissed,
}) => dismissed == false && progress.running;

/// Whole-number percent for "Building search index… N%". 0 while the total
/// is unknown; clamped to 0–100.
int indexProgressPercent(IndexProgress progress) {
  if (progress.total <= 0) return 0;
  return (progress.done * 100 ~/ progress.total).clamp(0, 100);
}
