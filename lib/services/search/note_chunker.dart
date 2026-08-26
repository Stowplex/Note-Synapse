// Markdown-aware note chunking for the search index (plan §1.2).
//
// A note is split into ChunkDrafts:
// - one `meta` chunk (title + tag names) restoring tag matching,
// - `note_body` chunks split at headings then paragraphs (~1200 char target,
//   small trailing chunks merged), each prefixed with its heading breadcrumb,
// - `subnote` chunks (one stream per subnote, sourceId = subnote id),
// - `annotation` chunks (one stream per annotation, sourceId = annotation id).
//
// chunkPdfPage() produces `attachment_text` chunks for phase 3.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/note.dart';
import '../../models/note_annotation.dart';

/// Target chunk size in characters.
const int kChunkTargetChars = 1200;

/// Chunks smaller than this are merged into their neighbor.
const int kChunkMinChars = 200;

/// A chunk of note-derived text ready to be written to `search_chunks`.
class ChunkDraft {
  /// Logical identity: "{noteId}:{sourceType}:{sourceId|-}:{seq}".
  final String chunkKey;
  final String noteId;

  /// meta | note_body | subnote | annotation | attachment_text | ...
  final String sourceType;
  final String? sourceId;

  /// 1-based page number for attachment-derived chunks.
  final int? page;
  final int seq;

  /// Raw (un-normalized) text — used for snippets and embedding input.
  final String text;

  /// Optional JSON payload stored in `search_chunks.meta` (attachment_ocr
  /// chunks: {blockBounds, renderScale}; figure chunks in phase 4).
  final String? meta;

  /// sha256 hex of [text] (plus [meta] when present, NUL-separated so the
  /// hash of meta-less chunks is unchanged); drives chunk-diff on reindex.
  final String contentHash;

  ChunkDraft({
    required this.noteId,
    required this.sourceType,
    this.sourceId,
    this.page,
    required this.seq,
    required this.text,
    this.meta,
  }) : chunkKey = '$noteId:$sourceType:${sourceId ?? '-'}:$seq',
       contentHash = sha256
           .convert(utf8.encode(meta == null ? text : '$text\u0000$meta'))
           .toString();

  @override
  String toString() => 'ChunkDraft($chunkKey, ${text.length} chars)';
}

/// Chunks a note (body, meta, subnotes, annotations) into [ChunkDraft]s.
///
/// [annotations] are the note's `note_annotations` rows; pass what applies.
List<ChunkDraft> chunkNote(
  Note note, {
  List<NoteAnnotation> annotations = const [],
}) {
  final drafts = <ChunkDraft>[];

  // Meta chunk: title + tag names (Note.tags holds tag names).
  final metaText = [
    note.title.trim(),
    ...note.tags.map((t) => t.trim()),
  ].where((s) => s.isNotEmpty).join('\n');
  if (metaText.isNotEmpty) {
    drafts.add(
      ChunkDraft(noteId: note.id, sourceType: 'meta', seq: 0, text: metaText),
    );
  }

  // Body chunks.
  var seq = 0;
  for (final text in chunkMarkdown(note.content)) {
    drafts.add(
      ChunkDraft(
        noteId: note.id,
        sourceType: 'note_body',
        seq: seq++,
        text: text,
      ),
    );
  }

  // Subnote chunks: name acts as the root breadcrumb of its content.
  for (final subNote in note.subNotes) {
    var subSeq = 0;
    for (final text in chunkMarkdown(
      subNote.content,
      rootBreadcrumb: subNote.name.trim(),
    )) {
      drafts.add(
        ChunkDraft(
          noteId: note.id,
          sourceType: 'subnote',
          sourceId: subNote.id,
          seq: subSeq++,
          text: text,
        ),
      );
    }
  }

  // Annotation chunks.
  for (final annotation in annotations) {
    var annSeq = 0;
    for (final text in chunkMarkdown(annotation.content)) {
      drafts.add(
        ChunkDraft(
          noteId: note.id,
          sourceType: 'annotation',
          sourceId: annotation.id,
          seq: annSeq++,
          text: text,
        ),
      );
    }
  }

  return drafts;
}

/// Chunks one page of extracted PDF text into `attachment_text` drafts.
///
/// [page] is 1-based (repo-wide URI convention). Because `chunkKey` encodes
/// only (noteId, sourceType, sourceId, seq), per-page chunk indexes are
/// spread onto a page-scoped seq band (`(page-1) * 1000 + i`) so keys stay
/// unique and stable across the whole attachment; a single page can never
/// reach 1000 chunks at the ~1200-char target.
List<ChunkDraft> chunkPdfPage(
  String noteId,
  String attachmentId,
  int page,
  String pageText,
) {
  assert(page >= 1, 'page is 1-based');
  final drafts = <ChunkDraft>[];
  var i = 0;
  for (final text in chunkPlainText(pageText)) {
    assert(
      i < 1000,
      'page $page produced $i+ chunks, overflowing its 1000-wide seq band',
    );
    drafts.add(
      ChunkDraft(
        noteId: noteId,
        sourceType: 'attachment_text',
        sourceId: attachmentId,
        page: page,
        seq: (page - 1) * 1000 + i++,
        text: text,
      ),
    );
  }
  return drafts;
}

// ---------------------------------------------------------------------------
// Markdown-aware chunking
// ---------------------------------------------------------------------------

class _Section {
  final List<String> breadcrumb;
  final List<String> paragraphs = [];
  _Section(this.breadcrumb);
}

final _headingRe = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _fenceRe = RegExp(r'^(```|~~~)');

/// Splits markdown into chunks: sections at headings, then paragraphs,
/// packed to ~[kChunkTargetChars] with a small (<[kChunkMinChars]) trailing
/// chunk merged backward within its section. Each chunk is prefixed with
/// its heading breadcrumb ("H1 > H2") so section context survives chunking.
List<String> chunkMarkdown(String markdown, {String rootBreadcrumb = ''}) {
  final sections = _splitSections(markdown, rootBreadcrumb);
  final chunks = <String>[];

  for (var i = 0; i < sections.length; i++) {
    final section = sections[i];
    final breadcrumb = section.breadcrumb.join(' > ');
    final packed = _packParagraphs(section.paragraphs);
    for (final body in packed) {
      chunks.add(breadcrumb.isEmpty ? body : '$breadcrumb\n$body');
    }
    // A body-less heading still carries searchable words — but skip it when
    // the next section's breadcrumb already contains it (a parent heading is
    // repeated in every descendant chunk anyway).
    if (packed.isEmpty && breadcrumb.isNotEmpty) {
      final coveredByNext =
          i + 1 < sections.length &&
          _isBreadcrumbPrefix(section.breadcrumb, sections[i + 1].breadcrumb);
      if (!coveredByNext) chunks.add(breadcrumb);
    }
  }

  return chunks;
}

/// Whether [prefix] is an element-wise prefix of (or equal to) [full].
/// Compared per heading, not on the joined string, so a sibling `# AB`
/// does not count as covering `# A`.
bool _isBreadcrumbPrefix(List<String> prefix, List<String> full) {
  if (prefix.length > full.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (prefix[i] != full[i]) return false;
  }
  return true;
}

/// Packs paragraphs of plain (non-markdown) text, e.g. extracted PDF text.
List<String> chunkPlainText(String text) {
  final paragraphs = _splitParagraphs(text);
  return _packParagraphs(paragraphs);
}

List<_Section> _splitSections(String markdown, String rootBreadcrumb) {
  final root = rootBreadcrumb.isEmpty ? <String>[] : <String>[rootBreadcrumb];
  final sections = <_Section>[_Section(List.of(root))];
  // headingStack[i] = heading text at markdown level i+1 (null if absent).
  final headingStack = List<String?>.filled(6, null);
  final paragraph = StringBuffer();
  // The opening marker ('```' or '~~~') while inside a fence, else null.
  // Only the matching marker closes a fence: a ~~~ line inside a ``` block
  // is fence content, not a closer (and vice versa).
  String? fenceMarker;

  void flushParagraph() {
    final text = paragraph.toString().trim();
    paragraph.clear();
    if (text.isNotEmpty) sections.last.paragraphs.add(text);
  }

  for (final line in markdown.split('\n')) {
    final fence = _fenceRe.firstMatch(line.trimLeft());
    if (fenceMarker != null) {
      if (fence != null && fence.group(1) == fenceMarker) fenceMarker = null;
      paragraph.writeln(line);
      continue;
    }
    if (fence != null) {
      fenceMarker = fence.group(1);
      paragraph.writeln(line);
      continue;
    }
    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      flushParagraph();
      final level = heading.group(1)!.length;
      headingStack[level - 1] = heading.group(2)!;
      for (var i = level; i < 6; i++) {
        headingStack[i] = null;
      }
      final breadcrumb = [...root, ...headingStack.whereType<String>()];
      sections.add(_Section(breadcrumb));
      continue;
    }
    if (line.trim().isEmpty) {
      flushParagraph();
    } else {
      paragraph.writeln(line);
    }
  }
  flushParagraph();
  return sections;
}

List<String> _splitParagraphs(String text) {
  return text
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
}

/// Packs paragraphs into chunks of ~[kChunkTargetChars]; a paragraph longer
/// than the target is hard-split at whitespace near the target boundary.
List<String> _packParagraphs(List<String> paragraphs) {
  final pieces = <String>[];
  for (final paragraph in paragraphs) {
    if (paragraph.length <= kChunkTargetChars) {
      pieces.add(paragraph);
    } else {
      pieces.addAll(_hardSplit(paragraph));
    }
  }

  final chunks = <String>[];
  final current = StringBuffer();
  for (final piece in pieces) {
    if (current.isNotEmpty &&
        current.length + 2 + piece.length > kChunkTargetChars &&
        current.length >= kChunkMinChars) {
      chunks.add(current.toString());
      current.clear();
    }
    if (current.isNotEmpty) current.write('\n\n');
    current.write(piece);
  }
  if (current.isNotEmpty) chunks.add(current.toString());

  // Merge a small trailing chunk into the previous one (within the same
  // section, so every chunk keeps a single accurate breadcrumb).
  if (chunks.length >= 2 && chunks.last.length < kChunkMinChars) {
    final tail = chunks.removeLast();
    chunks[chunks.length - 1] = '${chunks.last}\n\n$tail';
  }
  return chunks;
}

List<String> _hardSplit(String paragraph) {
  final parts = <String>[];
  var start = 0;
  while (paragraph.length - start > kChunkTargetChars) {
    var cut = start + kChunkTargetChars;
    // Prefer breaking at whitespace within the trailing 200 chars.
    final window = paragraph.substring(start, cut);
    final lastSpace = window.lastIndexOf(RegExp(r'\s'));
    if (lastSpace > kChunkTargetChars - 200) {
      cut = start + lastSpace;
    }
    // Never cut between the halves of a surrogate pair: astral chars (e.g.
    // CJK extension B) are two UTF-16 code units. If the cut lands on a low
    // surrogate, back off one so the pair stays together.
    if (_isLowSurrogate(paragraph.codeUnitAt(cut))) cut--;
    parts.add(paragraph.substring(start, cut).trim());
    start = cut;
  }
  final tail = paragraph.substring(start).trim();
  if (tail.isNotEmpty) parts.add(tail);
  return parts;
}

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
