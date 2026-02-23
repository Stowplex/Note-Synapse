import '../models/attachment.dart';
import '../models/note.dart';
import '../utils/synapse_resource_uri.dart';
import 'database_service.dart';

/// Result of resolving an attachment link, containing both the attachment
/// and its parent note.
class AttachmentLinkResult {
  final Attachment attachment;
  final Note note;

  const AttachmentLinkResult({
    required this.attachment,
    required this.note,
  });
}

/// Service for generating and resolving attachment links in notes.
///
/// Attachment links use the synapseresource://attachment/<id> URI scheme
/// and can be embedded in markdown content as clickable links.
class AttachmentLinkService {
  final DatabaseService _db;

  AttachmentLinkService(this._db);

  /// Resolves an attachment link by looking up the attachment and its parent note.
  ///
  /// Returns null if the attachment or its parent note cannot be found.
  Future<AttachmentLinkResult?> resolveAttachmentLink(
      String attachmentId) async {
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
