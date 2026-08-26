import '../models/attachment.dart';
import '../models/note.dart';
import '../utils/synapse_resource_uri.dart';
import 'database_service.dart';

/// Result of resolving an attachment link, containing both the attachment
/// and its parent note.
class AttachmentLinkResult {
  final Attachment attachment;
  final Note note;

  const AttachmentLinkResult({required this.attachment, required this.note});
}

/// Service for generating and resolving attachment links in notes.
///
/// Attachment links use the `synapseresource://attachment/<id>` URI scheme
/// and can be embedded in markdown content as clickable links.
class AttachmentLinkService {
  final DatabaseService _db;

  AttachmentLinkService(this._db);

  /// Resolves an attachment link by looking up the attachment and its parent note.
  ///
  /// Returns null if the attachment or its parent note cannot be found.
  Future<AttachmentLinkResult?> resolveAttachmentLink(
    String attachmentId,
  ) async {
    final attachment = await _db.getAttachmentById(attachmentId);
    if (attachment == null) return null;

    final note = await _db.getNote(attachment.noteId);
    if (note == null) return null;

    return AttachmentLinkResult(attachment: attachment, note: note);
  }

  /// Generates a markdown link string for an attachment.
  ///
  /// Example output: `[report.pdf](synapseresource://attachment/att-1?page=5)`
  String generateMarkdownLink({
    required String attachmentId,
    required String linkText,
    int? page,
  }) {
    final uri = SynapseResourceUri.attachmentUri(attachmentId, page: page);
    return '[$linkText]($uri)';
  }

  /// Generates a markdown IMAGE embed for an extracted figure region.
  ///
  /// Example output: `![Figure 3: pipeline](synapseresource://figure/<id>)`.
  /// [figureId] is the content-addressed `<chunkKey>~<contentHash prefix>`
  /// built by `FigureResolver.buildFigureId` — the renderer verifies the hash
  /// before displaying anything, so a stale id degrades to the dangling
  /// placeholder instead of a wrong figure.
  ///
  /// Whole PDF pages are NEVER embedded as images; use
  /// [generateMarkdownLink] with a `page` for those.
  String generateFigureMarkdownImage({
    required String figureId,
    required String caption,
  }) => _markdownImage(SynapseResourceUri.figureUri(figureId), caption);

  /// Generates a markdown IMAGE embed for an attachment that IS the image —
  /// a raster image file, which has no derived crop of its own.
  ///
  /// Example output: `![whiteboard](synapseresource://attachment/att-1)`.
  /// Vector images (SVG) cannot be rendered inline; link to those with
  /// [generateMarkdownLink] instead.
  String generateAttachmentMarkdownImage({
    required String attachmentId,
    required String caption,
  }) => _markdownImage(SynapseResourceUri.attachmentUri(attachmentId), caption);

  /// `![alt](uri)` with [caption] made safe as alt text: newlines and
  /// brackets would break out of the syntax.
  String _markdownImage(String uri, String caption) {
    final altText = caption.replaceAll(RegExp(r'[\r\n\[\]]'), ' ').trim();
    return '![$altText]($uri)';
  }

  /// Returns a smart default link text for an attachment.
  ///
  /// Priority: bookmarkTitle > chapterTitle > fileName (with optional page suffix).
  String defaultLinkText({
    required String fileName,
    int? page,
    String? bookmarkTitle,
    String? chapterTitle,
  }) {
    if (bookmarkTitle != null) return bookmarkTitle;
    if (chapterTitle != null) return chapterTitle;
    if (page != null) return '$fileName - Page $page';
    return fileName;
  }
}
