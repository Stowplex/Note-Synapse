// Figure/table region extraction for the search index (plan §4.1, Step 13).
//
// Turns a PDF attachment into [FigureRegion]s (precise figure/table rects in
// PDF page coordinates, NOT page thumbnails) and renders each region as a
// high-res derived PNG under `attachments/derived/`. It is EXTRACTOR ONLY:
// Step 14 wires it into NoteIndexService's figure stage (which owns policy
// gates, chunk creation, and persistence); Step 16 calls [renderRegion] to
// regenerate a missing derived asset on demand. It never touches the
// database.
//
// Pipeline per page:
//   1. Caption anchors — text items whose first line matches
//      [captionAnchorPattern] (`Figure 1`, `Fig. 12`, `Table 2`, `图1`,
//      `表 2`, `圖3`; line-start anchored so "The figure 3 shows" in running
//      text never matches). Anchors come from BOTH text sources: text-layer
//      fragments (via the [PdfFigureSource] seam) and OCR block bounds from
//      Step 12's stored chunk meta ([ocrItemsFromChunkMeta]) — OCR is a
//      first-class signal, so scanned pages get captions too.
//   2. Region inference ([inferFigureRegions]) — the band adjacent to each
//      caption (above for figures; above OR below for tables, preferring the
//      side that actually holds the table), computed over the UNION of
//      text-layer items and OCR blocks. What bounds the band is BODY-LIKE
//      text ([classifyPageLines]): a line that belongs to a paragraph-shaped
//      RUN of similarly-margined, regularly-spaced lines, or another
//      caption. Width alone is explicitly NOT the test — a chart title or an
//      axis label is wide and is figure content, a page of verse is narrow
//      and is body text. Table rows and lone labels are absorbed INTO the
//      region; wrapped caption lines are folded into the caption itself,
//      which is what makes multi-line table captions work at all.
//
//      Four things decide "body-like", and each exists because its absence
//      produced a measured failure on REAL page geometry (pdfrx emits one
//      fragment per WORD, so every one of these is invisible to fixtures
//      built from whole-line rects):
//        * a table row's cells are derived PER ITEM, never pooled across the
//          items of a visual row, and a gap becomes a cell gutter only when
//          both flanking cells qualify. Pooled word fragments made "every
//          cell is narrow" trivially true, so the gap between two page
//          COLUMNS read as a table gutter on every body row of a two-column
//          paper — 104 of 105 lines "tabular", nothing blocking, and a
//          caption claiming its whole column at 0.9 confidence;
//        * a page COLUMN is told from a table by its corridor
//          ([detectLayoutCorridors]) and by the page-height extent of its
//          gutter — both computed ONCE per page into [_PageColumns], which
//          EVERY consumer applies (round 4: the table-block detector applied
//          neither, so it re-derived a page's corridor as a table gutter and
//          claimed 65 lines of Chinese prose the classifier had already
//          called body text) — and, because both of those need ~60% of page
//          height and a BOUNDED block of two-column prose reaches neither,
//          by what its cells HOLD. What a cell holds is read from its TEXT
//          ([_isCellSizedText]): words for scripts that separate them,
//          characters for the ones that do not. Guessing it from geometry
//          was two holes at once — a Chinese line is one "word", and a
//          three-column layout's 130pt columns are "narrow";
//        * a run BLOCKS only when it fills the strip it shares with the
//          caption. A paragraph fills ~90% of it; a two-line in-figure
//          legend ~30% and a stack of ten tick labels ~4%, and blocking on
//          those cut 146pt and 168pt of plot area off their figures;
//        * "vertically adjacent" is measured against the PAGE'S OWN leading
//          ([_pageLinePitch]), not a fixed fraction of the glyph box. A
//          double-spaced page has paragraphs too — assuming otherwise cost
//          every figure in a thesis or a court filing its region, and let
//          four lines of double-spaced prose render as a page-sized figure.
//
//      A TABLE caption additionally looks for the block it claims
//      ([_TableBlock]): the rows against its edge that keep a regular pitch
//      (or an exact multiple of it, so a blank separator row does not end the
//      table), line their columns up on either edge or their centres, and
//      carry gutters that survive the page-column defences. That block is
//      POSITIVE evidence, measured locally, and it is what a table caption
//      may act on — its rows stop bounding the band however the page
//      classifier read them, and the band is TRIMMED to them. With no block,
//      a table caption needs real content in the band, and the band is
//      trimmed to that content: a table IS text, so a table region never
//      extends past the text it holds.
//
//      The region then expands horizontally to the column margins (the
//      bounding body lines above/below share the caption's column) or, for a
//      table, to its block; a side of the band with no text beside it at all
//      claims the text-free extent instead, because a figure is by
//      definition where text ISN'T and a caption's own width is not the
//      figure's. Nothing claimed may cross a detected corridor. A vertical
//      re-check + fallback keeps a full-width reference from dragging a
//      two-column figure across the other column. Bands are then rejected
//      when they are entirely text-free and smaller than a plate (an empty
//      band is evidence of whitespace, not of a figure), when their own TEXT
//      DENSITY is body-like rather than figure-like ([kMaxBandTextDensity]),
//      or when they cover most of the page while holding many width-weighted
//      text lines.
//
//      Those last two are the BACKSTOPS, and they are not exemptible. A
//      table's own rows are excluded from them — a table is dense text by
//      definition — but the exemption is RE-DERIVED at the emit gate from
//      each item's own visual row (a gutter, flanked by something that holds
//      what a table cell holds, surviving the page-column defences). Round 3
//      took the block detector's word for it, which meant one bug in that
//      detector could emit a whole page of prose at 0.9 confidence past two
//      guards designed to be the last line of defence. Pages with a large
//      text-free band
//      (> [kWhitespaceMinAreaFrac] of page area) but no caption become
//      low-confidence caption-less candidates, kept behind
//      [FigureRegionExtractor.minConfidence] (default admits captioned
//      regions only).
//   3. High-res crop render — `PdfPage.render(x, y, width, height,
//      fullWidth, fullHeight)` at [FigureRegionExtractor.kFigureRenderScale]
//      (3×, degraded per region by
//      [FigureRegionExtractor.effectiveRenderScale] so no crop can exceed
//      the raster budget — pdfium allocates the whole RGBA bitmap up front
//      and an A0 page at 3× is a 289 MB OOM kill, not an exception), using
//      the same §4.1 coordinate transform as the OCR stage
//      (pdfRectToRasterRect: PDF y-up points → raster y-down pixels), saved
//      as `attachments/derived/<attachmentId>_p<N>_f<i>.png`. Derived assets
//      are regenerable (excluded from export/backup) — [renderRegion]
//      rebuilds one from its stored [FigureRegion] JSON.
//
// COORDINATE FRAME: every rect here — text items, region rects, the stored
// chunk meta — is in the page's DISPLAY space (y-up points, rotation
// applied), the same frame `page.width`/`page.height`, `page.render()` and
// Step 12's `space:'pdf'` OCR bounds use. pdfium's character boxes are NOT
// in that frame on `/Rotate 90|270` pages, so the pdfrx seam normalizes them
// on the way in ([rotateRectToDisplaySpace]).
//
// pdfrx is seamed behind [PdfFigureSource] (mirroring PdfTextSource /
// PdfOcrRenderSource): pdfium cannot initialize headless under
// `flutter test`, so unit tests + the Step-13 spike validate the inference
// math through fakes built from known ground-truth geometry; a
// skipped-by-default integration test exercises the real opener.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart' hide PdfRect;

import '../../models/attachment.dart';
import '../../utils/file_utils.dart';
import '../logger_service.dart';
import 'attachment_ocr_extractor.dart' show PdfRect, pdfRectToRasterRect;
import 'attachment_text_extractor.dart' show AttachmentTextExtractor;

// ─── Text items (the union input of region inference) ───────────────────────

/// One piece of page text with its bounds in PDF PAGE coordinates (y-up,
/// origin bottom-left, points, ROTATION-ADJUSTED — see
/// [rotateRectToDisplaySpace]). Built from a text-layer fragment/line or an
/// OCR block — region inference does not care which.
class PageTextItem {
  const PageTextItem({
    required this.text,
    required this.rect,
    this.fragmentRects = const [],
  });

  final String text;
  final PdfRect rect;

  /// Bounds of the pre-merge fragments this line was assembled from
  /// ([mergeFragmentsIntoLines]), left-to-right. Empty for items that never
  /// went through the merge (OCR blocks, hand-built items) — consumers then
  /// treat the whole [rect] as the single fragment.
  ///
  /// This is what keeps TABLE structure alive: a table row whose per-cell
  /// fragments merge into one wide line is indistinguishable from a body
  /// line by its outer rect alone, but its internal cell gutters give it
  /// away ([classifyPageLines]).
  final List<PdfRect> fragmentRects;

  @override
  String toString() =>
      'PageTextItem("${text.length > 24 ? '${text.substring(0, 24)}…' : text}"'
      ', l=${rect.left} b=${rect.bottom} r=${rect.right} t=${rect.top})';
}

/// Parses one `attachment_ocr` chunk's meta JSON (Step 12's
/// `{blockBounds: [{rect: {l,t,r,b}, text}], space, ...}`) into
/// [PageTextItem]s for the region-inference union.
///
/// Only `space == 'pdf'` bounds apply (they are already mapped to PDF page
/// coordinates); raster-image bounds (`space == 'image'`) have no PDF page
/// and yield `[]`, as does malformed meta.
List<PageTextItem> ocrItemsFromChunkMeta(String metaJson) {
  try {
    final decoded = jsonDecode(metaJson);
    if (decoded is! Map<String, dynamic>) return const [];
    if (decoded['space'] != 'pdf') return const [];
    final blocks = decoded['blockBounds'];
    if (blocks is! List) return const [];
    final items = <PageTextItem>[];
    for (final block in blocks) {
      if (block is! Map) continue;
      final rect = block['rect'];
      final text = block['text'];
      if (rect is! Map || text is! String) continue;
      final l = (rect['l'] as num?)?.toDouble();
      final t = (rect['t'] as num?)?.toDouble();
      final r = (rect['r'] as num?)?.toDouble();
      final b = (rect['b'] as num?)?.toDouble();
      if (l == null || t == null || r == null || b == null) continue;
      items.add(
        PageTextItem(text: text, rect: (left: l, top: t, right: r, bottom: b)),
      );
    }
    return items;
  } catch (_) {
    return const [];
  }
}

// ─── Caption anchors ─────────────────────────────────────────────────────────

/// What a caption announces.
enum CaptionKind { figure, table }

/// Every space-like character a caption may be indented with or separated
/// by: plain space/tab plus the Unicode spaces real typesetting emits — NBSP
/// (U+00A0), the en/em/thin/hair quad family (U+2000–U+200A), narrow NBSP
/// (U+202F), medium mathematical space (U+205F) and the ideographic space
/// (U+3000, `图　1`). Typesetters pick these precisely to keep "Figure" and
/// its number on one line, so rejecting them silently drops exactly the
/// captions that were typeset most carefully.
const String _kCaptionSpaceChars = ' \\t\u00a0\u2000-\u200a\u202f\u205f\u3000';

/// Separator between the keyword and the number: any caption space, plus the
/// ASCII/fullwidth dot and colon.
const String _kCaptionSeparatorChars = '$_kCaptionSpaceChars.．:：';

/// Punctuation that ENDS a caption number: the caption/title separator a
/// typesetter puts between "Table IV" and its title, plus the closing paren
/// of "Figure 1)" and the CJK equivalents.
const String _kCaptionNumberEnders = r':：.．。、\-–—)）';

/// Caption pattern (plan §4.1, tuned during the Step-13 spike; hardened in
/// round 2 against Roman-numeral collisions): a figure/table keyword at LINE
/// START, then an optional separator run, then a number — ASCII, fullwidth,
/// Chinese numerals, or an UPPERCASE-style Roman numeral (`TABLE I`,
/// `TABLE III: Ablation`; IEEE mandates Roman table numbering and two-column
/// IEEE papers are the archetypal input). Line-start anchoring is the
/// mid-sentence rejector ("The figure 3 shows…" never matches); the keyword
/// must be immediately followed by separator/number, so "Configure",
/// "figures", "表面", "图书馆" never match either.
///
/// Three number branches, deliberately unequal:
///
///  * DIGITS — no tail requirement at all, so sub-figure labels ("Figure 1a")
///    still match. A digit after the keyword is unambiguous.
///  * CJK NUMERALS — must be followed by a caption separator, whitespace or
///    end of line. Without that, `表十分感谢…` ("十" = ten) and `图一致性协议`
///    ("一" = one) are captions.
///  * ROMAN — must be a CANONICAL numeral (so `DVD`, `ID`, `MIX` cannot be
///    parsed as one) AND be followed by a separator, TWO spaces (the IEEE
///    "TABLE I␣␣COMPARISON OF SCHEDULERS" form) or end of line. The pattern
///    is case-insensitive, so every one of I/V/X/L/C/D/M heads common
///    English words; a single space is not enough evidence (`Figure CLI
///    output`, `Table L2 cache`, `Fig. M1 board` all used to match).
///    Trade-off: `Table IV Results` and `Fig. IX shows…` — a Roman numeral
///    followed by ONE space — are no longer captions.
final RegExp captionAnchorPattern = RegExp(
  '^[$_kCaptionSpaceChars]*'
  r'(figure|fig\.?|table|图|表|圖)'
  '[$_kCaptionSeparatorChars]*'
  '(?:'
  r'[0-9０-９]+'
  '|[一二三四五六七八九十百]+(?=[$_kCaptionNumberEnders$_kCaptionSpaceChars]|\$)'
  '|(?=[IVXLCDM])M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})'
  '(?=[$_kCaptionNumberEnders]|[$_kCaptionSpaceChars]{2}|\$)'
  ')',
  caseSensitive: false,
);

/// Leading orphan a merged line may carry BEFORE its caption keyword: a
/// footnote/superscript mark that pdfrx emits as its own tiny fragment and
/// [mergeFragmentsIntoLines] sorts ahead of the caption ("ᵃ Figure 3: …" →
/// `a Figure 3: …`). One or two characters only, and only when the line's
/// first fragment really is tiny ([_kCaptionOrphanMaxWidthFactor]), so
/// "The figure 3 shows…" and the Chinese "如图1所示" can never sneak in
/// through it.
final RegExp _captionOrphanPrefixPattern = RegExp(
  r'^[a-z0-9*†‡§¶#]{1,2}[ \t ]+',
  caseSensitive: false,
);

/// Two-letter words that DO start English sentences about figures ("In
/// figure 3 we…", "As table II shows…"): never treated as orphan marks.
///
/// The single-letter English words ("A figure 3 in the appendix shows…",
/// "I figure 3 is enough") are NOT listed here, because a superscript
/// footnote mark is very often exactly "a" — blocklisting the letter would
/// disable the mechanism for the case it exists for. They are rejected by
/// [_captionOrphanStrictTailPattern] instead, which is a property of what
/// FOLLOWS the number rather than a list of words.
const Set<String> _kCaptionOrphanBlocklist = {
  'in',
  'on',
  'at',
  'of',
  'to',
  'by',
  'as',
  'is',
  'it',
  'we',
  'or',
  'so',
  'if',
  'no',
  'my',
  'do',
  'up',
  'us',
  'an',
  'be',
  'he',
  'me',
};

/// A tiny first fragment is at most this multiple of the line's height wide —
/// a superscript letter or a footnote dagger, never a word.
const double _kCaptionOrphanMaxWidthFactor = 0.6;

/// What must follow the number when the keyword was only reached by stripping
/// an ORPHAN prefix: the caption/title separator ("ᵃ Figure 3: …"), possibly
/// after a sub-figure letter. The orphan retry is the one path into caption
/// detection that is not anchored at the start of the line, so it demands the
/// strict caption form — otherwise a sentence whose first word happens to be
/// one narrow character ("A figure 3 in the appendix shows…") is a caption.
final RegExp _captionOrphanStrictTailPattern = RegExp(
  '^[a-z]?[$_kCaptionNumberEnders]',
  caseSensitive: false,
);

/// Trailing letter of a SUB-figure number ("Figure 2a" under "Figure 2"),
/// applied to the text immediately after the matched number.
final RegExp _captionSubLetterPattern = RegExp(
  r'^([a-z])(?![a-z])',
  caseSensitive: false,
);

/// A detected caption line and where it sits on the page.
class CaptionAnchor {
  const CaptionAnchor({
    required this.text,
    required this.rect,
    required this.kind,
    required this.itemIndex,
    this.number = '',
    this.subLetter,
  });

  /// Trimmed caption text (the whole item's text — captions are usually a
  /// single line/block).
  final String text;

  /// The caption item's bounds (PDF page coordinates).
  final PdfRect rect;

  final CaptionKind kind;

  /// Index into the items list the anchor was detected in (so inference can
  /// exclude the anchor from its own obstacle set).
  final int itemIndex;

  /// The caption's number as matched ("2", "IV", "一"), lower-cased.
  final String number;

  /// The sub-figure letter directly after the number ("a" of "Figure 2a"),
  /// or null. A caption WITH one, under a caption with the same [number] and
  /// none, is a sub-caption: it labels part of its parent's figure, so it
  /// neither claims a region of its own nor bounds its parent's.
  final String? subLetter;
}

/// Detects caption anchors among [items]: an item is a caption when its
/// FIRST non-empty line matches [captionAnchorPattern]. Only the first line
/// is checked — captions are standalone lines/blocks; a body paragraph that
/// merely contains "Figure 3" on a later line is not a caption.
List<CaptionAnchor> detectCaptionAnchors(List<PageTextItem> items) {
  final anchors = <CaptionAnchor>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final firstLine = item.text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) continue;
    var candidate = firstLine;
    var match = captionAnchorPattern.firstMatch(candidate);
    if (match == null && _hasTinyLeadingFragment(item)) {
      // A superscript/footnote mark merged AHEAD of the caption: pdfrx emits
      // it as its own fragment and mergeFragmentsIntoLines sorts by
      // top-desc/left-asc, so the caption text arrives as "a Figure 3: …"
      // and the ^-anchored pattern misses its own caption. Only a 1–2
      // character orphan, only when the first fragment is physically tiny,
      // and never a word that starts a sentence about a figure.
      final orphan = _captionOrphanPrefixPattern.firstMatch(candidate);
      if (orphan != null &&
          !_kCaptionOrphanBlocklist.contains(
            orphan.group(0)!.trim().toLowerCase(),
          )) {
        final stripped = candidate.substring(orphan.end);
        final retry = captionAnchorPattern.firstMatch(stripped);
        if (retry != null &&
            _captionOrphanStrictTailPattern.hasMatch(
              stripped.substring(retry.end),
            )) {
          candidate = stripped;
          match = retry;
        }
      }
    }
    if (match == null) continue;
    final keyword = match.group(1)!.toLowerCase();
    final numberStart = match.start + match.group(1)!.length;
    final tail = candidate.substring(match.end);
    anchors.add(
      CaptionAnchor(
        text: item.text.trim(),
        rect: item.rect,
        kind: keyword == 'table' || keyword == '表'
            ? CaptionKind.table
            : CaptionKind.figure,
        itemIndex: i,
        number: candidate
            .substring(numberStart, match.end)
            .replaceAll(RegExp('[$_kCaptionSeparatorChars]'), '')
            .toLowerCase(),
        subLetter: _captionSubLetterPattern
            .firstMatch(tail)
            ?.group(1)
            ?.toLowerCase(),
      ),
    );
  }
  return anchors;
}

/// Whether [item]'s leftmost fragment is too small to be a word — the
/// evidence that its first token is a superscript mark rather than text.
/// Items with no fragment breakdown (OCR blocks) never qualify.
bool _hasTinyLeadingFragment(PageTextItem item) {
  if (item.fragmentRects.length < 2) return false;
  final first = item.fragmentRects.reduce((a, b) => a.left <= b.left ? a : b);
  final lineHeight = item.rect.top - item.rect.bottom;
  if (lineHeight <= 0) return false;
  return (first.right - first.left) <=
      _kCaptionOrphanMaxWidthFactor * lineHeight;
}

// ─── Region inference ────────────────────────────────────────────────────────

/// How a region was found.
enum FigureRegionSource { captioned, whitespace }

/// Gap between a caption edge and the region it anchors, and between the
/// region and the body line bounding it.
const double kCaptionRegionPaddingPts = 4.0;

/// Regions shorter/narrower than this are degenerate (e.g. a caption-shaped
/// line inside running text) and dropped.
const double kMinRegionHeightPts = 40.0;
const double kMinRegionWidthPts = 40.0;

/// "Wide" for the purposes of the run/tabular heuristics below. NOT a
/// blocker test on its own — width alone conflates "wide" with "body text",
/// which used to truncate any figure containing a chart title or an axis
/// label wider than a fifth of the page (see [classifyPageLines]).
const double kBodyLineMinWidthFrac = 0.20;

/// Horizontal gap that reads as a table CELL GUTTER rather than a word
/// space: at least this many points AND at least this multiple of the line
/// height. Justified prose stretches its word spaces — measured on random
/// 9-word lines, a 6pt floor alone turned 24 of 26 justified lines into
/// "table rows"; 0.75×line-height puts the floor above anything a justified
/// line produces at normal measures.
const double kCellGutterMinPts = 6.0;
const double kCellGutterMinHeightFactor = 0.75;

/// A "cell" wider than this fraction of the page is a column of body text,
/// not a table cell. Applied to the two cells FLANKING a candidate gutter
/// (not to every cell in the row): a table row may legitimately mix a wide
/// description cell with narrow numeric ones. Round 3 raised it from 0.45,
/// because the width cap is no longer the thing standing between "two page
/// columns" and "a table" — [kTableCellMaxWords]/[kNarrowCellWidthFrac] is
/// (a 50%-wide DESCRIPTION cell beside a 23% numeric one used to fail here).
const double kMaxCellWidthFrac = 0.60;

/// POSITIVE evidence that a gap is a table gutter rather than the space
/// between two columns of PROSE: at least one of the two cells flanking it
/// must hold what a table cell holds.
///
/// This is the answer to the worst false positive found in round 3: rows of
/// two-column prose under a table caption are geometrically IDENTICAL to a
/// two-column table (same cell widths, same pitch, same alignment), and every
/// page-level defence (corridor, gutter extent) needs ~60% of page height to
/// fire, which a bounded prose block never reaches. What actually differs is
/// what is INSIDE the cells: a table cell holds a label or a number ("12.4",
/// "earliest deadline first"), a prose column holds a full line of running
/// text.
///
/// Round 4 measures that from the cell's TEXT ([_isCellSizedText]) rather
/// than from its geometry, because both geometric proxies were holes:
///
///  * counting merged FRAGMENTS is meaningless for scripts that do not
///    separate words. pdfrx splits fragments on whitespace only
///    (`pdfrx_engine/lib/src/pdf_text_formatter.dart`), so a Chinese or
///    Japanese line is ONE fragment ⇒ "one word" ⇒ "table cell", and a
///    standard two-column Chinese page read as a 64-row table;
///  * a "narrow box" is only narrow relative to a chosen column count: a
///    three-column layout has 130pt columns, well inside a 22%-of-page cap,
///    so any 3–4 column page was a table. That cap is now the LAST-RESORT
///    fallback for cells whose text cannot be attributed (see
///    [_isTableCell]), never the primary test.
///
/// Deliberately a RECALL trade: a table whose cells all hold five or more
/// words (a requirements matrix) is not recognised as tabular. Its rows then
/// BLOCK (the safe direction) and the table is missed; a missed table is a
/// page link, a wrong one is a screenshot of prose captioned "Table 2".
const int kTableCellMaxWords = 4;

/// …and its equivalent for Han/Kana/Hangul, which write a phrase in a
/// fraction of the characters and no spaces at all. A cell label
/// (`平均准确率`, `精度`) is a handful of ideographs; a line of running text
/// is twenty. Set from measured typesetting, not from the Latin bound: four
/// "words" of Chinese would reject ordinary header cells.
const int kTableCellMaxCjkChars = 8;

/// Last-resort width cap for a cell whose CONTENT cannot be read at all
/// (fragment/token counts that do not correspond, so no text can be
/// attributed to the cell). Never reached on the OCR path — an OCR block
/// carries its own text.
const double kNarrowCellWidthFrac = 0.22;

/// Two rows belong to the same table when a gutter x of one falls within
/// this many points of a gutter of the other…
const double kGutterAlignTolerancePts = 10.0;

/// …and their centers sit within this multiple of the taller row's height.
const double kTableRowMaxPitchFactor = 6.0;

/// PAGE COLUMN LAYOUT vs table, rule 1 (the corridor rule). A vertical
/// text-free corridor at least this wide, with a FULL-HEIGHT text column on
/// at least one side (this many lines spanning this much of the page), is a
/// page column separator. The gap between two page columns is not a table
/// gutter, however neatly it repeats down the page — that mistake turned
/// every body row of a two-column paper into a "table row" (which never
/// blocks), and a caption then swallowed its whole column.
const double kLayoutCorridorMinWidthPts = 10.0;
const int kLayoutColumnMinLines = 12;
const double kLayoutColumnMinHeightFrac = 0.6;

/// PAGE COLUMN LAYOUT vs table, rule 2 (the extent rule), for pages whose
/// column corridor is broken by a full-width line (a title, a footnote, a
/// spanning figure). One gutter x shared by this many rows across this much
/// of the PAGE HEIGHT is a column layout: a real table is a BOUNDED band.
const int kLayoutGutterMinRows = 12;
const double kLayoutGutterMinHeightFrac = 0.6;

/// Vertical gap, as a fraction of line height, up to which two lines read as
/// consecutive lines of one paragraph (leading is a small fraction of the
/// line height; table row pitch is a multiple of it).
///
/// This is the SINGLE-SPACED floor. It is not the whole rule: a fixed
/// fraction of the glyph box says a double-spaced page has no paragraphs at
/// all, which is how a thesis, a court filing or a line-numbered pleading
/// lost every figure it had (nothing blocked, so every band overgrew into a
/// rejection) and how four lines of double-spaced prose rendered as a
/// page-sized "figure". Leading is a property of the PAGE, so the page's own
/// leading is measured ([_pageLinePitch]) and used alongside this floor.
const double kBodyRunMaxGapFactor = 0.9;

/// Two lines are consecutive lines of a paragraph when their baselines sit
/// within this multiple of the PAGE'S OWN measured line pitch…
const double kRunPitchTolerance = 1.35;

/// …and never further apart than this multiple of the line height, whatever
/// the page pitch measured. A page of six diagram labels 90pt apart measures
/// a 90pt "pitch"; that is the figure's layout, not a paragraph's leading,
/// and this cap is what keeps such labels lone lines.
const double kRunMaxPitchFactor = 4.0;

/// Fewest samples before the measured page pitch is trusted at all. Two, so
/// that a nearly blank page — three double-spaced lines and a caption at the
/// foot — still measures its own leading; the [kRunMaxPitchFactor] cap is
/// what keeps a pitch measured from too few samples from doing damage, and
/// the run-fill density test is what keeps a sparse "run" from blocking.
const int kPagePitchMinSamples = 2;

/// Left/right edges this close (points) count as "the same margin".
const double kRunMarginTolerancePts = 6.0;

/// Looser margin tolerance for two stacked WIDE lines, so a first-line
/// indent (~1–2 em) still reads as one paragraph.
const double kWideRunMarginTolerancePts = 24.0;

/// At most this many wrapped continuation lines are folded into one caption
/// (so captions of up to three lines survive). A paragraph is longer than
/// its caption looks: folding four lines let an ordinary paragraph under a
/// full-measure caption become "caption text" — and folded lines stop
/// blocking and stop counting, so the figure above grew over them.
const int kMaxCaptionContinuationLines = 2;

/// A LIST OF FIGURES / LIST OF TABLES page: this many captions stacked at
/// one margin with less than [kMinRegionHeightPts] of clear space between
/// consecutive entries. No figure fits between them, so they are index
/// entries pointing at figures on other pages, not captions of anything
/// here. Every thesis has such a page, and its first entry used to claim the
/// band above it — the heading — as a 0.9-confidence "figure".
const int kCaptionListMinEntries = 3;

/// A run of text FILLS the strip it sits in when at least this much of that
/// strip's area is ink — the test that separates a paragraph (≈0.9) from an
/// in-figure legend (≈0.3) or a stack of tick labels (≈0.04) without
/// resorting to width alone. A PAIR of lines is the weakest possible
/// evidence of a paragraph and gets the stricter threshold.
const double kBlockingRunMinDensity = 0.35;
const double kBlockingRunPairMinDensity = 0.5;

/// A captioned band whose own text covers more than this fraction of it is
/// body text, not a figure: an in-figure legend is ~2–3% of the band, a
/// column of prose is 80%+.
///
/// Round 3 made this backstop CLASSIFICATION-INDEPENDENT. It used to exempt
/// every line the classifier had called `isTabular` whenever the caption said
/// "Table", which meant one classification mistake was enough to emit a band
/// of 43.8% prose ink at 0.9 confidence. The only exemption left is the
/// caption's OWN table block ([_TableBlock]) — rows positively identified as
/// the aligned, caption-adjacent, table-shaped structure this caption claims.
/// Anything else in the band counts, whatever it was classified as.
const double kMaxBandTextDensity = 0.12;

/// A captioned band that contains NO text at all must be at least this tall
/// AND clear [kMinContentFreeRegionHeightFrac] of the page. An empty band is
/// not evidence of a figure — it is evidence of whitespace, and every page
/// has whitespace: between two paragraphs, above a caption at the foot of a
/// verse page, between a text block and the paper's edge. Only its SIZE
/// relative to the page distinguishes a plate from ordinary leading, so the
/// page-relative floor (round 2's rule for bands running to the page edge)
/// now applies to every empty band. A 66pt gap between a poem and its
/// caption used to clear the flat 60pt floor and render as a blank PNG.
///
/// RECALL TRADE: a small text-free figure (under ~119pt on US Letter) with a
/// caption is no longer emitted. It degrades to a page link.
const double kMinContentFreeRegionHeightPts = 60.0;
const double kMinContentFreeRegionHeightFrac = 0.15;

/// A table caption whose band holds no [_TableBlock] needs at least this many
/// text items in the band to be claiming a table at all: one stray item (a
/// page number under a caption at the page foot) is not a table.
const int kMinBlocklessTableBandItems = 2;

/// A band taller than this fraction of the page that still contains
/// [kWholePageMaxTextLines] or more WEIGHTED text lines is the whole page,
/// not a figure (verse, TOC, narrow CJK columns, sparse slides). Real
/// full-page figures contain few or no text LINES — scattered tick labels
/// below [kCountedTextLineMinWidthFrac] and outside any run do not count.
///
/// Lines are WEIGHTED by width rather than counted flat (round 3): a line at
/// or above [kWideTextLineWidthFrac] of the page counts double. That second
/// signal is what let the flat cap rise from 6 to 9 without giving back the
/// round-2 regression it was tuned for — a page of seven 49%-wide lone lines
/// still scores 14, while six 26%-wide diagram labels (an architecture figure
/// with six labelled boxes, previously lost at a hard 6-label cliff) score 6.
const double kWholePageBandHeightFrac = 0.6;
const int kWholePageMaxTextLines = 9;
const double kCountedTextLineMinWidthFrac = 0.12;
const double kWideTextLineWidthFrac = 0.4;

/// A caption-less text-free band must exceed this fraction of the page area
/// to become a whitespace candidate.
const double kWhitespaceMinAreaFrac = 0.15;

// ─── The TABLE BLOCK: positive evidence, measured next to the caption ───────

/// A table caption's block starts at the first row within this multiple of
/// that row's height (or [kTableBlockMinFirstGapPts], whichever is larger) of
/// the caption edge. A table touches its caption; a table two paragraphs away
/// is not this caption's table.
const double kTableBlockMaxFirstGapFactor = 2.5;
const double kTableBlockMinFirstGapPts = 24.0;

/// …and continues while the row pitch stays within this factor of the pitch
/// the block started with, or of an exact MULTIPLE of it: a table's rows sit
/// on a lattice, and a blank separator row inside one table is a missing
/// lattice point (2× the pitch), not the end of the table. A paragraph after
/// the table does not continue the rhythm either way.
const double kTableBlockPitchTolerance = 1.6;
const int kTableBlockMaxPitchMultiple = 2;

/// Two rows belong to the same table block when this many of their column
/// starts (cell/fragment left edges) line up within
/// [kTableBlockColumnAlignTolerancePts]. Column alignment is what identifies
/// a table independently of gap SIZE, which is why a dense numeric table
/// whose 4pt column gaps sit under the word-space floor can still be claimed
/// here (it never becomes `isTabular` page-wide — that would make every
/// justified line of prose a table row).
const int kTableBlockMinAlignedColumns = 2;
const double kTableBlockColumnAlignTolerancePts = 3.0;

/// Fewest rows that can constitute a table block. One row of gutter-separated
/// cells is a wide-spaced heading; two aligned rows are a table.
const int kTableBlockMinRows = 2;

/// How far past its current edge a region reaches to absorb an adjacent
/// label or table cell, as a fraction of page width (~18pt on US Letter).
/// Round 3 replaced a fixed 8pt with this; it stays well under the narrowest
/// inter-column gap a two-column layout uses, so a region still cannot reach
/// across a page column.
const double kAbsorbReachFrac = 0.03;

/// A band with NO text in it at all cannot take its horizontal extent from
/// neighbouring text — there is none; a figure is by definition where text
/// ISN'T. Such a band claims the text-free extent instead: out to the page's
/// text margins, and when even those are narrower than this fraction of the
/// page (a lone caption under a full-page plate), out to the caption's own
/// margin MIRRORED on the other side.
///
/// Mirroring is a guess at the page's margin box, not evidence, so round 4
/// restricted it to bands that hold NO text at all — which, after the
/// content-free height rule above, means bands the size of a plate. A band
/// with content takes its extent from that content. The 66pt strip between a
/// poem and its caption used to take a 432pt width from this rule and render
/// as a blank PNG.
const double kEmptyBandNarrowExtentFrac = 0.5;

/// Two emitted regions this close on every edge are the same region (a
/// sub-figure caption re-deriving its parent's band).
const double kDuplicateRegionTolerancePts = 2.0;

/// Confidences per source; the default threshold admits captioned only.
const double kCaptionedConfidence = 0.9;
const double kWhitespaceConfidence = 0.4;
const double kDefaultMinConfidence = 0.5;

/// One inferred figure/table region on a page.
class FigureRegion {
  const FigureRegion({
    required this.page,
    required this.rectPdf,
    this.caption,
    required this.confidence,
    required this.source,
  });

  /// 1-based page number (repo-wide URI convention).
  final int page;

  /// Region bounds in PDF page coordinates (y-up, points).
  final PdfRect rectPdf;

  /// Caption text (null for whitespace candidates).
  final String? caption;

  final double confidence;
  final FigureRegionSource source;

  /// JSON for the figure chunk's meta (Step 14) and for regenerating the
  /// derived asset from stored state (Step 16 → [renderRegion]).
  Map<String, dynamic> toJson() => {
    'page': page,
    'rect': {
      'l': rectPdf.left,
      't': rectPdf.top,
      'r': rectPdf.right,
      'b': rectPdf.bottom,
    },
    if (caption != null) 'caption': caption,
    'confidence': confidence,
    'source': source.name,
  };

  factory FigureRegion.fromJson(Map<String, dynamic> json) {
    final rect = json['rect'] as Map<String, dynamic>;
    return FigureRegion(
      page: json['page'] as int,
      rectPdf: (
        left: (rect['l'] as num).toDouble(),
        top: (rect['t'] as num).toDouble(),
        right: (rect['r'] as num).toDouble(),
        bottom: (rect['b'] as num).toDouble(),
      ),
      caption: json['caption'] as String?,
      confidence: (json['confidence'] as num).toDouble(),
      source: FigureRegionSource.values.byName(json['source'] as String),
    );
  }

  @override
  String toString() =>
      'FigureRegion(p$page ${source.name} conf=$confidence '
      'l=${rectPdf.left} b=${rectPdf.bottom} r=${rectPdf.right} '
      't=${rectPdf.top}${caption == null ? '' : ' "$caption"'})';
}

double _xOverlap(PdfRect a, PdfRect b) =>
    math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left));

double _width(PdfRect r) => r.right - r.left;
double _height(PdfRect r) => r.top - r.bottom;
double _centerY(PdfRect r) => (r.top + r.bottom) / 2;

// ─── Line classification: what actually BLOCKS region growth ────────────────

/// What one page line is, for the purposes of region growth.
///
/// The old model was "wide ⇒ body text ⇒ blocker", which is wrong in both
/// directions: a chart title or an axis label inside a figure is wide but is
/// figure content, while a page of verse/TOC/narrow-column text is all
/// narrow but is all body text. The model is now "BODY-LIKE ⇒ blocker":
///
///  * [isCaption] — any caption blocks (a neighbouring figure's caption is a
///    hard edge for this one).
///  * [inBodyRun] — the line has a vertically adjacent, similarly-margined
///    neighbour in the same column, i.e. it is one line of a PARAGRAPH. A
///    LONE line surrounded by vertical whitespace is figure content and is
///    absorbed no matter how wide it is.
///  * [isTabular] — the line is a table row (cells separated by gutters that
///    line up with another row's). Table rows are TEXT INSIDE THE REGION, so
///    they never block, however wide they are.
class PageLineClass {
  const PageLineClass({
    required this.isCaption,
    required this.isTabular,
    required this.inBodyRun,
    this.runGroup = -1,
  });

  final bool isCaption;
  final bool isTabular;
  final bool inBodyRun;

  /// Index of the paragraph (connected component of run partners) this line
  /// belongs to, or -1. Region growth measures how densely a whole paragraph
  /// fills the strip it would block, so it has to know which lines are the
  /// same paragraph — see `_runFillsSpan` in [inferFigureRegions].
  final int runGroup;

  /// Whether growth of a neighbouring region CAN stop at this line. Whether
  /// it actually does is decided per region: a run only blocks when it fills
  /// the strip it sits in (an in-figure legend does not).
  bool get blocksGrowth => isCaption || (inBodyRun && !isTabular);

  @override
  String toString() =>
      'PageLineClass(caption=$isCaption tabular=$isTabular run=$inBodyRun '
      'group=$runGroup blocks=$blocksGrowth)';
}

/// A vertical text-free corridor that separates two PAGE COLUMNS (as opposed
/// to two table cells): at least [kLayoutCorridorMinWidthPts] wide, with a
/// full-height text column ([kLayoutColumnMinLines] lines spanning
/// [kLayoutColumnMinHeightFrac] of the page) on at least one side and at
/// least two lines on the other.
///
/// This is the difference between a two-column paper and a two-column table.
/// A table's gutter exists only over the table's own rows; a page column's
/// corridor runs the height of the page, and the body lines on either side
/// of it are body lines — they must keep blocking region growth, not become
/// "table rows" that get absorbed.
List<({double left, double right})> detectLayoutCorridors(
  List<PageTextItem> items, {
  required double pageHeightPts,
  bool proseColumnsOnly = false,
}) {
  if (items.length < kLayoutColumnMinLines + 2) return const [];
  final spans = [
    for (final item in items) (left: item.rect.left, right: item.rect.right),
  ]..sort((a, b) => a.left.compareTo(b.left));
  final covered = <({double left, double right})>[];
  for (final span in spans) {
    if (covered.isNotEmpty && span.left <= covered.last.right) {
      final last = covered.removeLast();
      covered.add((left: last.left, right: math.max(last.right, span.right)));
    } else {
      covered.add(span);
    }
  }

  final corridors = <({double left, double right})>[];
  for (var k = 0; k + 1 < covered.length; k++) {
    final left = covered[k].right;
    final right = covered[k + 1].left;
    if (right - left < kLayoutCorridorMinWidthPts) continue;
    var leftLines = 0;
    var rightLines = 0;
    var leftTop = double.negativeInfinity;
    var leftBottom = double.infinity;
    var rightTop = double.negativeInfinity;
    var rightBottom = double.infinity;
    for (final item in items) {
      // A page COLUMN is made of running text. When the caller asks for
      // prose columns (the page-level call; the merge-time call sees single
      // WORD fragments and cannot), a side whose every line holds what a
      // table cell holds is a table COLUMN, however tall it is — that is a
      // standalone appendix table page, whose 40pt inter-cell gap would
      // otherwise be "the page's column corridor" and suppress its own
      // table's gutters.
      final prose = !proseColumnsOnly || !_isCellSizedText(item.text);
      if (item.rect.right <= left) {
        if (prose) leftLines++;
        leftTop = math.max(leftTop, item.rect.top);
        leftBottom = math.min(leftBottom, item.rect.bottom);
      } else if (item.rect.left >= right) {
        if (prose) rightLines++;
        rightTop = math.max(rightTop, item.rect.top);
        rightBottom = math.min(rightBottom, item.rect.bottom);
      }
    }
    final minHeight = kLayoutColumnMinHeightFrac * pageHeightPts;
    final leftIsColumn =
        leftLines >= kLayoutColumnMinLines && leftTop - leftBottom >= minHeight;
    final rightIsColumn =
        rightLines >= kLayoutColumnMinLines &&
        rightTop - rightBottom >= minHeight;
    if ((leftIsColumn && rightLines >= 2) ||
        (rightIsColumn && leftLines >= 2)) {
      corridors.add((left: left, right: right));
    }
  }
  return corridors;
}

/// The page's items grouped into VISUAL ROWS (a table row's cells, or the
/// two body lines a two-column page puts on one baseline).
class _PageRows {
  const _PageRows(this.rows, this.rowRects, this.byTop);

  /// Item indexes per row, rows ordered top-down.
  final List<List<int>> rows;

  /// Bounding rect of each row.
  final List<PdfRect> rowRects;

  /// All item indexes sorted by descending top (the scan order both the row
  /// grouping and the run pairing rely on).
  final List<int> byTop;
}

_PageRows _visualRows(List<PageTextItem> items) {
  final n = items.length;
  final rows = <List<int>>[];
  final rowRects = <PdfRect>[];
  final byTop = [for (var i = 0; i < n; i++) i]
    ..sort((a, b) => items[b].rect.top.compareTo(items[a].rect.top));
  for (final i in byTop) {
    final r = items[i].rect;
    var placed = false;
    for (var ri = rows.length - 1; ri >= 0; ri--) {
      final rr = rowRects[ri];
      if (rr.bottom > r.top) break; // Rows above r; earlier rows are higher.
      final overlap = math.min(rr.top, r.top) - math.max(rr.bottom, r.bottom);
      final minH = math.min(_height(rr), _height(r));
      if (minH > 0 && overlap >= 0.5 * minH) {
        rows[ri].add(i);
        rowRects[ri] = _union(rr, r);
        placed = true;
        break;
      }
    }
    if (!placed) {
      rows.add([i]);
      rowRects.add(r);
    }
  }
  return _PageRows(rows, rowRects, byTop);
}

/// One cell of a visual row, with what it holds.
class _RowCell {
  const _RowCell(this.rect, this.words, this.text);

  final PdfRect rect;

  /// Fragments (≈ words) merged into this cell, or null when the source item
  /// carried no fragment breakdown — an OCR block is one opaque box, and
  /// "unknown" must not be read as "one word".
  final int? words;

  /// The cell's own TEXT when it could be attributed (the whole item's text
  /// for a single-fragment item or an OCR block; the fragment's share of the
  /// line otherwise — see [_rowCells]), else null. This is the primary
  /// evidence for [_isTableCell]: geometry cannot tell a Chinese line from a
  /// Chinese cell, and character counts can.
  final String? text;
}

/// Characters of scripts that do not put spaces between words. Word counting
/// is blind to these (the whole line arrives as one fragment), so they are
/// counted individually instead.
bool _isWordlessScript(int rune) =>
    (rune >= 0x3040 && rune <= 0x30ff) || // Hiragana + Katakana
    (rune >= 0x3400 && rune <= 0x4dbf) || // CJK ext. A
    (rune >= 0x4e00 && rune <= 0x9fff) || // CJK unified
    (rune >= 0xf900 && rune <= 0xfaff) || // CJK compatibility
    (rune >= 0xac00 && rune <= 0xd7af) || // Hangul syllables
    (rune >= 0x20000 && rune <= 0x2ffff); // CJK ext. B+

/// Whether [text] is what a TABLE CELL holds — a label, a number, a short
/// phrase — as opposed to a line of running text. Latin-style text is
/// measured in whitespace-separated tokens ([kTableCellMaxWords]), CJK in
/// characters ([kTableCellMaxCjkChars]); mixed text must satisfy both.
bool _isCellSizedText(String text) {
  var tokens = 0;
  var cjkChars = 0;
  for (final token in text.trim().split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    var cjk = 0;
    for (final rune in token.runes) {
      if (_isWordlessScript(rune)) cjk++;
    }
    cjkChars += cjk;
    if (cjk < token.runes.length) tokens++;
  }
  return tokens <= kTableCellMaxWords && cjkChars <= kTableCellMaxCjkChars;
}

/// The gap at which a row's fragments stop being one cell: a word space
/// stretched by justification, never a column gutter (see
/// [kCellGutterMinPts]).
double _rowGutterMinPts(PdfRect rowRect) =>
    math.max(kCellGutterMinPts, kCellGutterMinHeightFactor * _height(rowRect));

/// Cells of one visual row. Derived PER ITEM — an item's cells are the groups
/// its own pre-merge fragments fall into (a row whose cells merged into one
/// wide line still exposes them), or the item itself when it has none — then
/// merged into one left-to-right list (items in a row are disjoint runs of
/// text, so sorting is enough).
List<_RowCell> _rowCells(
  List<PageTextItem> items,
  List<int> row,
  double gutterMin,
) {
  final cells = <_RowCell>[];
  for (final i in row) {
    final fragments = items[i].fragmentRects;
    if (fragments.length < 2) {
      cells.add(
        _RowCell(items[i].rect, fragments.isEmpty ? null : 1, items[i].text),
      );
      continue;
    }
    final sorted = [...fragments]..sort((a, b) => a.left.compareTo(b.left));
    // Attribute the line's TEXT to its fragments. mergeFragmentsIntoLines
    // writes text in scan order (top-descending, then left-ascending) and
    // pdfrx emits one fragment per whitespace-separated token, so on a single
    // baseline the k-th token belongs to the k-th fragment from the left.
    // Only when the counts correspond — otherwise the cells carry no text and
    // fall back to counting fragments.
    final tokens = items[i].text.trim().split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    final attributable = tokens.length == sorted.length;
    var cell = sorted.first;
    var words = 1;
    var text = attributable ? StringBuffer(tokens.first) : null;
    for (var k = 1; k < sorted.length; k++) {
      if (sorted[k].left - cell.right >= gutterMin) {
        cells.add(_RowCell(cell, words, text?.toString()));
        cell = sorted[k];
        words = 1;
        text = attributable ? StringBuffer(tokens[k]) : null;
      } else {
        cell = _union(cell, sorted[k]);
        words++;
        if (attributable) text!.write(' ${tokens[k]}');
      }
    }
    cells.add(_RowCell(cell, words, text?.toString()));
  }
  cells.sort((a, b) => a.rect.left.compareTo(b.rect.left));
  return cells;
}

/// Whether [cell] holds what a TABLE cell holds — a label, a number, a short
/// phrase — as opposed to a line of running text.
///
/// The cell's TEXT decides whenever it could be attributed, which is every
/// production path: a text-layer line whose per-word fragments correspond to
/// its tokens, a single-fragment line (the whole CJK-line case), and an OCR
/// block (one box, its own text). Only text that cannot be attributed at all
/// falls back to geometry, and that fallback demands BOTH a short fragment
/// run and a narrow box — the two round-3 proxies, now required together
/// because each alone was a hole (see [kTableCellMaxWords]).
bool _isTableCell(_RowCell cell, double pageWidthPts) {
  final text = cell.text;
  if (text != null && text.trim().isNotEmpty) return _isCellSizedText(text);
  final narrow = _width(cell.rect) <= kNarrowCellWidthFrac * pageWidthPts;
  final words = cell.words;
  return narrow && (words == null || words <= kTableCellMaxWords);
}

/// Gutters of one row: gaps at least [gutterMin] wide whose two flanking
/// cells are both under [kMaxCellWidthFrac] AND at least one of which looks
/// like a table cell. The flanking cells come back with the position,
/// because "which items are table cells" is decided per CELL: a visual row
/// on a two-column page holds the other column's body line too, and that
/// line is not a table row for sitting next to one.
List<({double x, _RowCell leftCell, _RowCell rightCell})> _rowGutters(
  List<_RowCell> cells, {
  required double pageWidthPts,
  required double gutterMin,
  bool Function(double x)? rejectX,
}) {
  final gutters = <({double x, _RowCell leftCell, _RowCell rightCell})>[];
  final maxCellWidth = kMaxCellWidthFrac * pageWidthPts;
  for (var k = 0; k + 1 < cells.length; k++) {
    final a = cells[k];
    final b = cells[k + 1];
    if (b.rect.left - a.rect.right < gutterMin) continue;
    if (_width(a.rect) > maxCellWidth || _width(b.rect) > maxCellWidth) {
      continue;
    }
    if (!_isTableCell(a, pageWidthPts) && !_isTableCell(b, pageWidthPts)) {
      continue;
    }
    final x = (a.rect.right + b.rect.left) / 2;
    if (rejectX != null && rejectX(x)) continue;
    gutters.add((x: x, leftCell: a, rightCell: b));
  }
  return gutters;
}

/// The PAGE-COLUMN defences, computed ONCE per page and applied by EVERY
/// consumer of gutters.
///
/// This is the round-4 structural fix. The two defences that tell a page
/// COLUMN from a table column — the text-free corridor
/// ([detectLayoutCorridors]) and the page-height extent of a repeated gutter
/// ([kLayoutGutterMinRows]/[kLayoutGutterMinHeightFrac]) — used to live
/// INSIDE [classifyPageLines], where only the classifier could see them.
/// [_detectTableBlock], the one path that can exempt items from the
/// backstops, applied neither: on a two-column Chinese page the classifier
/// returned "not tabular, blocks growth" for all 65 lines, correctly, and the
/// extractor emitted the whole page anyway because the block detector had
/// re-derived the corridor as a table gutter. A defence only one consumer
/// applies is not a defence.
class _PageColumns {
  const _PageColumns(this.corridors, this.gutterBands);

  /// Text-free corridors separating page columns.
  final List<({double left, double right})> corridors;

  /// x-intervals of gutter clusters carried by many rows across most of the
  /// page height: a column layout whose corridor is broken by a full-width
  /// line (a title, a footnote, a spanning figure).
  final List<({double left, double right})> gutterBands;

  /// Whether a gap at [x] is page-column structure rather than a table
  /// gutter. Used by the classifier AND by table-block detection.
  bool rejects(double x) {
    for (final c in corridors) {
      if (x > c.left && x < c.right) return true;
    }
    for (final g in gutterBands) {
      if (x >= g.left && x <= g.right) return true;
    }
    return false;
  }

  /// How far a region overlapping [span] may reach horizontally without
  /// crossing into another page column. A figure in the left column of a
  /// two-column page is bounded by the corridor even when the other column
  /// happens to be blank beside it.
  ({double left, double right}) boundsFor(PdfRect span, double pageWidthPts) {
    var left = 0.0;
    var right = pageWidthPts;
    for (final c in corridors) {
      final mid = (c.left + c.right) / 2;
      if (span.right <= mid) {
        right = math.min(right, c.right);
      } else if (span.left >= mid) {
        left = math.max(left, c.left);
      }
    }
    return (left: left, right: right);
  }
}

/// Everything one page's geometry says, derived once: visual rows, the
/// page-column defences, the surviving gutters, the page's own line pitch and
/// the per-item classification.
class _PageAnalysis {
  const _PageAnalysis({
    required this.visual,
    required this.columns,
    required this.rowGutters,
    required this.classes,
    required this.linePitch,
  });

  final _PageRows visual;
  final _PageColumns columns;

  /// Gutters per visual row that SURVIVED the page-column defences.
  final List<List<({double x, _RowCell leftCell, _RowCell rightCell})>>
  rowGutters;

  final List<PageLineClass> classes;

  /// The page's measured body leading (centre-to-centre), or null when the
  /// page has too few adjacent line pairs to measure one.
  final double? linePitch;

  /// Whether the visual row [ri] shows table evidence of its own: a gutter
  /// that survived the page-column defences. Re-derived at the emit gate, so
  /// no bug in block detection can hand a paragraph an exemption.
  bool rowHasTableEvidence(int ri) => rowGutters[ri].isNotEmpty;
}

/// The page's own body leading: the median centre-to-centre distance between
/// vertically adjacent, column-sharing lines.
///
/// A fixed fraction of the glyph box cannot express "the next line of this
/// paragraph" on a page that is not single-spaced, and double spacing is not
/// exotic — theses, court filings, review drafts and line-numbered pleadings
/// all use it. Measuring the page instead of assuming its leading is what
/// makes those pages behave like any other (and what stops four lines of
/// double-spaced prose from rendering as a page-sized "figure").
double? _pageLinePitch(List<PageTextItem> items) {
  final byTop = [for (var i = 0; i < items.length; i++) i]
    ..sort((a, b) => items[b].rect.top.compareTo(items[a].rect.top));
  final samples = <double>[];
  for (var ii = 0; ii < byTop.length; ii++) {
    final a = items[byTop[ii]].rect;
    for (var jj = ii + 1; jj < byTop.length; jj++) {
      final b = items[byTop[jj]].rect;
      // Same visual row (the two columns of one baseline) — not a pitch.
      // Measured by overlap, not by "b starts below a's box": tight leading
      // makes consecutive lines touch, and skipping those pairs biased the
      // median towards the gaps BETWEEN blocks.
      final overlap = math.min(a.top, b.top) - math.max(a.bottom, b.bottom);
      final minHeight = math.min(_height(a), _height(b));
      if (minHeight > 0 && overlap >= 0.5 * minHeight) continue;
      final minWidth = math.min(_width(a), _width(b));
      if (minWidth <= 0 || _xOverlap(a, b) < 0.5 * minWidth) continue;
      final pitch = _centerY(a) - _centerY(b);
      if (pitch > 0) samples.add(pitch);
      break; // Nearest line below only.
    }
  }
  if (samples.length < kPagePitchMinSamples) return null;
  samples.sort();
  return samples[samples.length ~/ 2];
}

/// Classifies every item on a page (pure geometry; exported so the spike and
/// unit tests can assert the classification directly).
///
/// [captionIndexes] are the indexes [detectCaptionAnchors] matched.
/// [pageHeightPts] is needed by both column-layout rules — a page column is
/// distinguished from a table column by how much of the PAGE its corridor
/// and its gutter span, which is the only signal that survives when the
/// cells on either side are the same shape either way.
List<PageLineClass> classifyPageLines(
  List<PageTextItem> items, {
  required double pageWidthPts,
  required double pageHeightPts,
  Set<int> captionIndexes = const <int>{},
}) => _analysePage(
  items,
  pageWidthPts: pageWidthPts,
  pageHeightPts: pageHeightPts,
  captionIndexes: captionIndexes,
).classes;

_PageAnalysis _analysePage(
  List<PageTextItem> items, {
  required double pageWidthPts,
  required double pageHeightPts,
  Set<int> captionIndexes = const <int>{},
}) {
  final n = items.length;
  final tabular = List<bool>.filled(n, false);
  final inRun = List<bool>.filled(n, false);
  final visual = _visualRows(items);
  if (n == 0) {
    return _PageAnalysis(
      visual: visual,
      columns: const _PageColumns([], []),
      rowGutters: const [],
      classes: const [],
      linePitch: null,
    );
  }

  // 1. Visual rows: items that overlap vertically by at least half the
  //    shorter one's height sit on the same row (a table row's cells, or a
  //    two-column page's two body lines).
  final rows = visual.rows;
  final rowRects = visual.rowRects;
  final byTop = visual.byTop;

  // 2. Per-row cell gutters. Cells are derived PER ITEM — an item's cells
  //    are the groups its own pre-merge fragments fall into (a row whose
  //    cells merged into one wide line still exposes its gutters here), or
  //    the item itself when it has no fragments (OCR blocks). Pooling every
  //    item's fragments into one list, as round 1 did, made the test
  //    trivially true on real input: pdfrx emits ONE FRAGMENT PER WORD, so
  //    "every cell is narrow" is a statement about words, and the gap
  //    between two page columns then read as a table gutter on every single
  //    body row of a two-column paper.
  //
  //    A gap becomes a gutter only when both flanking cells are under the
  //    width cap and at least one HOLDS what a table cell holds
  //    ([_isTableCell]).
  final rawGutters =
      <List<({double x, _RowCell leftCell, _RowCell rightCell})>>[];
  for (var ri = 0; ri < rows.length; ri++) {
    final gutterMin = _rowGutterMinPts(rowRects[ri]);
    rawGutters.add(
      _rowGutters(
        _rowCells(items, rows[ri], gutterMin),
        pageWidthPts: pageWidthPts,
        gutterMin: gutterMin,
      ),
    );
  }

  // Rows and items are both in descending-top order, so the pair loops below
  // can stop scanning once they are further apart than any pair could be
  // (bounded by the page's tallest line) instead of running n² on a page of
  // thousands of tiny cells.
  var maxLineHeight = 0.0;
  for (var i = 0; i < n; i++) {
    maxLineHeight = math.max(maxLineHeight, _height(items[i].rect));
  }

  // 3. The PAGE-COLUMN defences, over the raw gutters: the text-free
  //    corridors, plus gutter CLUSTERS carried by many rows across most of
  //    the page height (a column layout whose corridor is broken by a
  //    full-width line). Both are recorded in [_PageColumns] so that every
  //    later consumer — the classifier below, table-block detection, region
  //    extent — applies the same defence.
  final gutterEntries =
      <({double x, int row, _RowCell leftCell, _RowCell rightCell})>[
        for (var ri = 0; ri < rows.length; ri++)
          for (final g in rawGutters[ri])
            (x: g.x, row: ri, leftCell: g.leftCell, rightCell: g.rightCell),
      ]..sort((a, b) => a.x.compareTo(b.x));
  final gutterBands = <({double left, double right})>[];
  var start = 0;
  while (start < gutterEntries.length) {
    var end = start + 1;
    while (end < gutterEntries.length &&
        gutterEntries[end].x - gutterEntries[end - 1].x <=
            kGutterAlignTolerancePts &&
        gutterEntries[end].x - gutterEntries[start].x <=
            2 * kGutterAlignTolerancePts) {
      end++;
    }
    final clusterRows = {
      for (var k = start; k < end; k++) gutterEntries[k].row,
    };
    var top = double.negativeInfinity;
    var bottom = double.infinity;
    for (final ri in clusterRows) {
      top = math.max(top, rowRects[ri].top);
      bottom = math.min(bottom, rowRects[ri].bottom);
    }
    if (clusterRows.length >= kLayoutGutterMinRows &&
        top - bottom >= kLayoutGutterMinHeightFrac * pageHeightPts) {
      gutterBands.add((
        left: gutterEntries[start].x - kGutterAlignTolerancePts,
        right: gutterEntries[end - 1].x + kGutterAlignTolerancePts,
      ));
    }
    start = end;
  }
  final columns = _PageColumns(
    detectLayoutCorridors(
      items,
      pageHeightPts: pageHeightPts,
      proseColumnsOnly: true,
    ),
    gutterBands,
  );

  final liveGutters = List.generate(
    rows.length,
    (_) => <({double x, _RowCell leftCell, _RowCell rightCell})>[],
    growable: false,
  );
  for (final entry in gutterEntries) {
    if (columns.rejects(entry.x)) continue;
    liveGutters[entry.row].add((
      x: entry.x,
      leftCell: entry.leftCell,
      rightCell: entry.rightCell,
    ));
  }

  // 4. A row is a TABLE row when a vertically nearby row repeats one of its
  //    (surviving) gutters: one row of gutter-separated cells is ambiguous
  //    (it could be a wide-spaced heading), two aligned rows are a table.
  //
  //    Only items flanking the aligned gutter that are THEMSELVES shaped
  //    like table cells become table cells. A visual row spans the page, so
  //    it also holds whatever else sits on that baseline: the other column's
  //    body line, a margin gloss, an equation number, a verse number. Round
  //    3 marked both flanks, so any short item beside a body line turned
  //    that body line into a "table row" — which stops blocking, and the
  //    figure below then grew straight over the paragraph.
  void markFlanking(
    int row,
    ({double x, _RowCell leftCell, _RowCell rightCell}) gutter,
  ) {
    for (final flank in [gutter.leftCell, gutter.rightCell]) {
      if (!_isTableCell(flank, pageWidthPts)) continue;
      for (final i in rows[row]) {
        if (_xOverlap(items[i].rect, flank.rect) > 0.5) tabular[i] = true;
      }
    }
  }

  final maxRowPitch = kTableRowMaxPitchFactor * maxLineHeight;
  for (var a = 0; a < rows.length; a++) {
    if (liveGutters[a].isEmpty) continue;
    for (var b = a + 1; b < rows.length; b++) {
      if (_centerY(rowRects[a]) - _centerY(rowRects[b]) > maxRowPitch) break;
      if (liveGutters[b].isEmpty) continue;
      final pitch = (_centerY(rowRects[a]) - _centerY(rowRects[b])).abs();
      final maxH = math.max(_height(rowRects[a]), _height(rowRects[b]));
      if (pitch > kTableRowMaxPitchFactor * maxH) continue;
      for (final ga in liveGutters[a]) {
        for (final gb in liveGutters[b]) {
          if ((ga.x - gb.x).abs() > kGutterAlignTolerancePts) continue;
          markFlanking(a, ga);
          markFlanking(b, gb);
        }
      }
    }
  }

  // 5. Body runs: paragraphs. Two lines are run partners when they are
  //    vertically adjacent at LEADING distance — the page's own measured
  //    leading, not a fixed fraction of the glyph box — share a column, and
  //    share a margin. Table rows are excluded (a tight table is not a
  //    paragraph). Partners are unioned into paragraph GROUPS, because
  //    whether a paragraph blocks is a property of the whole paragraph, not
  //    of one line (a two-line legend inside a plot is a "run" by geometry
  //    alone).
  final pitch = _pageLinePitch(items);
  final group = List<int>.filled(n, -1);
  int find(int i) {
    var root = i;
    while (group[root] >= 0) {
      root = group[root];
    }
    var walk = i;
    while (group[walk] >= 0) {
      final next = group[walk];
      group[walk] = root;
      walk = next;
    }
    return root;
  }

  final maxRunGap = kRunMaxPitchFactor * maxLineHeight;
  for (var ii = 0; ii < n; ii++) {
    final i = byTop[ii];
    if (tabular[i]) continue;
    for (var jj = ii + 1; jj < n; jj++) {
      final j = byTop[jj];
      // byTop is descending, so items[i] is the upper of the pair; once the
      // lower one's top has fallen below the widest possible leading, no
      // later item can reach back up either.
      if (items[j].rect.top < items[i].rect.bottom - maxRunGap) break;
      if (tabular[j]) continue;
      if (!_isRunPartner(items[i].rect, items[j].rect, pageWidthPts, pitch)) {
        continue;
      }
      inRun[i] = true;
      inRun[j] = true;
      final rootI = find(i);
      final rootJ = find(j);
      if (rootI != rootJ) group[rootJ] = rootI;
    }
  }

  return _PageAnalysis(
    visual: visual,
    columns: columns,
    rowGutters: liveGutters,
    linePitch: pitch,
    classes: [
      for (var i = 0; i < n; i++)
        PageLineClass(
          isCaption: captionIndexes.contains(i),
          isTabular: tabular[i],
          inBodyRun: inRun[i],
          runGroup: inRun[i] ? find(i) : -1,
        ),
    ],
  );
}

/// Whether [a] and [b] are consecutive lines of one paragraph.
///
/// [pagePitch] is the page's measured leading ([_pageLinePitch]); when it is
/// available, two lines one pitch apart are consecutive lines whatever the
/// ratio to their glyph boxes — never further than [kRunMaxPitchFactor] line
/// heights, so a page whose only "pitch" is the spacing of six diagram
/// labels cannot turn those labels into a paragraph.
bool _isRunPartner(
  PdfRect a,
  PdfRect b,
  double pageWidthPts,
  double? pagePitch,
) {
  final h = math.max(_height(a), _height(b));
  if (h <= 0) return false;
  // (Records are value types — pick both ends from one comparison rather
  // than asking `identical` which of them the winner was.)
  final aIsUpper = a.top >= b.top;
  final upper = aIsUpper ? a : b;
  final lower = aIsUpper ? b : a;
  final gap = upper.bottom - lower.top;
  // Slight overlap is fine (glyph boxes of tight leading).
  if (gap < -0.5 * h) return false;
  var maxGap = kBodyRunMaxGapFactor * h;
  if (pagePitch != null) {
    maxGap = math.max(maxGap, kRunPitchTolerance * pagePitch - h);
  }
  if (gap > math.min(maxGap, kRunMaxPitchFactor * h)) return false;
  final minWidth = math.min(_width(a), _width(b));
  if (minWidth <= 0 || _xOverlap(a, b) < 0.5 * minWidth) return false;
  final dLeft = (a.left - b.left).abs();
  final dRight = (a.right - b.right).abs();
  if (dLeft <= kRunMarginTolerancePts || dRight <= kRunMarginTolerancePts) {
    return true;
  }
  // Both wide and both margins nearly aligned: an indented first line.
  final wide = kBodyLineMinWidthFrac * pageWidthPts;
  return _width(a) >= wide &&
      _width(b) >= wide &&
      dLeft <= kWideRunMarginTolerancePts &&
      dRight <= kWideRunMarginTolerancePts;
}

/// A caption anchor after its wrapped continuation lines have been folded in.
class _MergedAnchor {
  _MergedAnchor(this.anchor, this.rect, this.text, this.indexes);

  final CaptionAnchor anchor;

  /// Caption bounds INCLUDING continuation lines.
  final PdfRect rect;

  /// Caption text including continuation lines.
  final String text;

  /// Item indexes that make up the caption (anchor + continuations); these
  /// are excluded when bounding this anchor's own band.
  final Set<int> indexes;

  CaptionKind get kind => anchor.kind;
}

/// Folds a caption's wrapped continuation lines into the anchor.
///
/// Multi-line captions are the NORM for tables ("Table 2: Results summary
/// for every model and / dataset, averaged over five seeds"), and the wrap
/// line sits exactly between the caption and the table. Treating it as a
/// body line put a blocker there and killed the region; treating it as part
/// of the caption is both true and what makes the table reachable.
///
/// A continuation is the next line BELOW the caption (reading order) that
///  * sits at leading distance and overlaps the caption's column,
///  * is not itself a caption and not a table row,
///  * is aligned with the caption — same LEFT margin, or the same CENTRE for
///    a centred caption. An INDENTED line starts a new paragraph; round 1
///    only rejected lines starting further LEFT than the caption, so an
///    indented short line folded in,
///  * does not extend materially past the caption's right edge (what keeps a
///    table's first row, reliably wider than its caption, out of the
///    caption).
///
/// Two rules then decide whether the collected chain is a wrapped caption or
/// the paragraph that happens to follow it (round 1 had neither, so a
/// full-measure caption followed by an ordinary paragraph swallowed four
/// body lines — which also stopped them blocking and counting):
///  * it must END: a caption wrap runs out, a paragraph does not, so a chain
///    that still has a candidate line after [kMaxCaptionContinuationLines]
///    is a paragraph and nothing is folded;
///  * its LAST line must be short of the caption's measure, because that is
///    what "the text ran out" looks like. Trailing lines that are as wide as
///    the caption are dropped from the chain.
_MergedAnchor _mergeCaptionContinuations(
  CaptionAnchor anchor,
  List<PageTextItem> items,
  List<PageLineClass> classes,
  double? pagePitch,
) {
  final lineHeight = _height(anchor.rect);
  final indexes = <int>{anchor.itemIndex};
  if (lineHeight <= 0) {
    return _MergedAnchor(anchor, anchor.rect, anchor.text, indexes);
  }
  final firstWidth = _width(anchor.rect);
  // The wrap of a caption sits one LINE below it — one line of THIS page's
  // leading, which on a double-spaced page is nothing like 0.9 glyph boxes.
  final maxWrapGap = math.max(
    kBodyRunMaxGapFactor * lineHeight,
    pagePitch == null
        ? 0.0
        : math.min(
            kRunPitchTolerance * pagePitch - lineHeight,
            kRunMaxPitchFactor * lineHeight,
          ),
  );

  /// Next line below [rect] that could be a wrap of this caption.
  int nextContinuation(PdfRect rect, Set<int> taken) {
    var bestIndex = -1;
    var bestTop = double.negativeInfinity;
    for (var i = 0; i < items.length; i++) {
      if (taken.contains(i)) continue;
      if (classes[i].isCaption || classes[i].isTabular) continue;
      final c = items[i].rect;
      final gap = rect.bottom - c.top;
      if (gap < -0.2 * lineHeight || gap > maxWrapGap) continue;
      final sameLeft =
          (c.left - anchor.rect.left).abs() <= kRunMarginTolerancePts;
      final sameCentre =
          ((c.left + c.right) / 2 - (anchor.rect.left + anchor.rect.right) / 2)
                  .abs() <=
              2 * kRunMarginTolerancePts &&
          c.left >= anchor.rect.left - kRunMarginTolerancePts;
      if (!sameLeft && !sameCentre) continue;
      final rightAllowance = math.max(
        kRunMarginTolerancePts,
        0.15 * _width(rect),
      );
      if (c.right > rect.right + rightAllowance) continue;
      final minWidth = math.min(_width(c), _width(rect));
      if (minWidth <= 0 || _xOverlap(c, rect) < 0.5 * minWidth) continue;
      if (c.top > bestTop) {
        bestTop = c.top;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  var rect = anchor.rect;
  final chain = <int>[];
  for (var step = 0; step < kMaxCaptionContinuationLines; step++) {
    final next = nextContinuation(rect, {...indexes, ...chain});
    if (next < 0) break;
    chain.add(next);
    rect = _union(rect, items[next].rect);
  }
  // A paragraph keeps going where a caption wrap stops.
  if (chain.length == kMaxCaptionContinuationLines &&
      nextContinuation(rect, {...indexes, ...chain}) >= 0) {
    chain.clear();
  }
  // …and its last line is short of the measure.
  while (chain.isNotEmpty &&
      _width(items[chain.last].rect) > firstWidth - kRunMarginTolerancePts) {
    chain.removeLast();
  }

  rect = anchor.rect;
  final text = StringBuffer(anchor.text);
  for (final i in chain) {
    rect = _union(rect, items[i].rect);
    text.write(' ${items[i].text.trim()}');
    indexes.add(i);
  }
  return _MergedAnchor(anchor, rect, text.toString(), indexes);
}

PdfRect _union(PdfRect a, PdfRect b) => (
  left: math.min(a.left, b.left),
  top: math.max(a.top, b.top),
  right: math.max(a.right, b.right),
  bottom: math.min(a.bottom, b.bottom),
);

/// The rows a table caption actually claims: the aligned, regularly-pitched,
/// cell-bearing block that starts against the caption edge.
class _TableBlock {
  const _TableBlock(this.itemIndexes, this.rect);

  /// Items making up the block — candidates for exemption from this
  /// caption's ink/line backstops, and the extent the band is trimmed to.
  /// The exemption is RE-DERIVED at the emit gate from each item's own
  /// visual row ([_PageAnalysis.rowHasTableEvidence]), so a block that
  /// claimed a paragraph cannot exempt it.
  final Set<int> itemIndexes;

  /// Union of the block's rows — what the band is trimmed to, and the
  /// horizontal extent the region adopts.
  final PdfRect rect;
}

/// One row's column signature: every cell's left, right and centre.
class _ColumnSignature {
  const _ColumnSignature(this.left, this.right, this.centre);

  factory _ColumnSignature.of(List<_RowCell> cells) => _ColumnSignature(
    [for (final c in cells) c.rect.left],
    [for (final c in cells) c.rect.right],
    [for (final c in cells) (c.rect.left + c.rect.right) / 2],
  );

  final List<double> left;
  final List<double> right;
  final List<double> centre;
}

/// How many of two rows' columns line up — on their LEFT edges, their RIGHT
/// edges or their CENTRES.
///
/// Left edges alone is the shape of a text column, not of a table: money
/// columns are right-aligned and headers are centred, so "1,234" over
/// "123,456" broke alignment at row 2 and an income statement was never a
/// block at all (its region then ran from the caption to the page edge and
/// left the third money column outside the crop).
int _alignedColumnCount(_ColumnSignature a, _ColumnSignature b) {
  bool near(double x, List<double> ys) =>
      ys.any((y) => (x - y).abs() <= kTableBlockColumnAlignTolerancePts);
  var count = 0;
  for (var k = 0; k < a.left.length; k++) {
    if (near(a.left[k], b.left) ||
        near(a.right[k], b.right) ||
        near(a.centre[k], b.centre)) {
      count++;
    }
  }
  return count;
}

/// Finds the table block on one side of a table caption, or null when there
/// is no positive evidence of one.
///
/// This is the replacement for "not obviously a page column, so it must be a
/// table". Nothing here is inferred from what the page-wide classifier
/// decided: the block must SHOW that it is a table, next to the caption that
/// claims it —
///
///  * it starts against the caption ([kTableBlockMaxFirstGapFactor]) and
///    shares its horizontal span, so the paragraph two inches below a
///    caption is never "the table";
///  * every row carries at least one real cell gutter — a gap wide enough to
///    not be a word space, flanked by something that HOLDS what a table cell
///    holds ([_isTableCell]) — and that gutter must survive the page-column
///    defences ([_PageColumns.rejects]). Round 3 passed no such filter here,
///    so the block detector re-derived a page's column corridor as a table
///    gutter that the classifier had already rejected, and claimed the whole
///    page of prose the classifier had already called body text;
///  * consecutive rows keep the pitch the block started with — or an exact
///    multiple of it, so one blank separator row does not end the table
///    ([kTableBlockPitchTolerance], [kTableBlockMaxPitchMultiple]) — and line
///    their columns up on either edge or their centres
///    ([kTableBlockMinAlignedColumns]);
///  * a leading row with no gutter at all may be a MERGED HEADER (a spanning
///    title cell over the columns). Exactly one is allowed, and only when the
///    block behind it stands on its own evidence;
///  * another caption ends it.
///
/// The block is what makes a table REACHABLE (its rows no longer bound the
/// band, however the page classifier read them) and what the band is TRIMMED
/// to. It is not a licence: the exemption from the ink backstop is re-derived
/// per row at the emit gate.
_TableBlock? _detectTableBlock({
  required List<PageTextItem> items,
  required _PageAnalysis page,
  required PdfRect captionRect,
  required Set<int> exclude,
  required Set<int> captionIndexes,
  required bool below,
  required double pageWidthPts,
}) {
  final visual = page.visual;
  final candidates = <int>[];
  for (var ri = 0; ri < visual.rows.length; ri++) {
    if (visual.rows[ri].any(exclude.contains)) continue;
    final rr = visual.rowRects[ri];
    if (below ? rr.top > captionRect.bottom : rr.bottom < captionRect.top) {
      continue;
    }
    candidates.add(ri);
  }
  candidates.sort(
    (a, b) => below
        ? visual.rowRects[b].top.compareTo(visual.rowRects[a].top)
        : visual.rowRects[a].bottom.compareTo(visual.rowRects[b].bottom),
  );

  final chosen = <int>[];
  final blockItems = <int>{};
  PdfRect? blockRect;
  PdfRect? prevRect;
  _ColumnSignature? prevColumns;
  double? basePitch;
  // A spanning header row (no gutters of its own) held back until the rows
  // behind it prove there is a table.
  int? pendingHeader;
  PdfRect? pendingHeaderRect;
  for (final ri in candidates) {
    if (visual.rows[ri].any(captionIndexes.contains)) break;
    final gutterMin = _rowGutterMinPts(visual.rowRects[ri]);
    // Only the cells that belong to THIS caption's table: cells shaped like
    // table cells, plus whatever sits in the caption's own column. A visual
    // row spans the whole page, so on a two-column page it also holds the
    // OTHER column's body line — which must neither widen the region nor
    // earn an exemption from the density backstop by association.
    final cells = [
      for (final c in _rowCells(items, visual.rows[ri], gutterMin))
        if (_isTableCell(c, pageWidthPts) ||
            _xOverlap(c.rect, captionRect) > 0.5)
          c,
    ];
    // A row with nothing of ours in it at all sits in another column
    // entirely (the body text beside a column-width table) — skip it. A row
    // that DOES reach into this column but is not a row of cells is the
    // paragraph the table ends at, and stops the block.
    if (cells.isEmpty) continue;
    final gutters = _rowGutters(
      cells,
      pageWidthPts: pageWidthPts,
      gutterMin: gutterMin,
      rejectX: page.columns.rejects,
    );
    final rr = cells.map((c) => c.rect).reduce(_union);
    if (gutters.isEmpty) {
      // A merged header spans its columns, so it has no gutter. Hold the
      // FIRST such row (and only the first) and let the rows behind it
      // decide; anything else ends the block.
      if (prevRect == null && pendingHeader == null) {
        final gap = below
            ? captionRect.bottom - rr.top
            : rr.bottom - captionRect.top;
        final maxGap = math.max(
          kTableBlockMinFirstGapPts,
          kTableBlockMaxFirstGapFactor * _height(rr),
        );
        if (gap < -0.5 * _height(rr) ||
            gap > maxGap ||
            _xOverlap(rr, captionRect) <= 0.5) {
          return null;
        }
        pendingHeader = ri;
        pendingHeaderRect = rr;
        continue;
      }
      break;
    }
    final columns = _ColumnSignature.of(cells);
    if (prevRect == null) {
      final anchorRect = pendingHeaderRect ?? rr;
      final gap = below
          ? captionRect.bottom - anchorRect.top
          : anchorRect.bottom - captionRect.top;
      final maxGap = math.max(
        kTableBlockMinFirstGapPts,
        kTableBlockMaxFirstGapFactor * _height(anchorRect),
      );
      if (gap < -0.5 * _height(anchorRect) || gap > maxGap) return null;
      if (_xOverlap(anchorRect, captionRect) <= 0.5) return null;
      if (pendingHeaderRect != null) {
        // The held header only counts when it sits at table pitch above the
        // first real row and shares its columns' span.
        final headerPitch = (_centerY(pendingHeaderRect) - _centerY(rr)).abs();
        final maxH = math.max(_height(pendingHeaderRect), _height(rr));
        if (headerPitch > kTableRowMaxPitchFactor * maxH ||
            _xOverlap(pendingHeaderRect, rr) <= 0.5) {
          // Not this table's header after all — so the caption's gap was
          // measured against the wrong row. The rows themselves must then
          // start against the caption, or there is no block here.
          final ownGap = below
              ? captionRect.bottom - rr.top
              : rr.bottom - captionRect.top;
          if (ownGap >
              math.max(
                kTableBlockMinFirstGapPts,
                kTableBlockMaxFirstGapFactor * _height(rr),
              )) {
            return null;
          }
        } else {
          chosen.add(pendingHeader!);
          blockRect = pendingHeaderRect;
          for (final i in visual.rows[pendingHeader]) {
            final r = items[i].rect;
            final centre = (r.left + r.right) / 2;
            if (centre > pendingHeaderRect.left - 0.5 &&
                centre < pendingHeaderRect.right + 0.5) {
              blockItems.add(i);
            }
          }
        }
      }
    } else {
      final pitch = (_centerY(prevRect) - _centerY(rr)).abs();
      final maxH = math.max(_height(prevRect), _height(rr));
      if (basePitch == null) {
        if (pitch > kTableRowMaxPitchFactor * maxH) break;
        basePitch = pitch;
      } else {
        // A table's rows sit on a LATTICE. A skipped row (a blank separator
        // between sections of the same table) is a missing lattice point at
        // exactly 2× the pitch, not a new rhythm — round 3's flat tolerance
        // of 1.6× could not span one, so the table was silently truncated to
        // the rows above the separator and the crop LOOKED complete.
        final steps = basePitch > 0 ? (pitch / basePitch).round() : 0;
        if (steps < 1 ||
            steps > kTableBlockMaxPitchMultiple ||
            pitch > kTableBlockPitchTolerance * steps * basePitch) {
          break;
        }
      }
      if (_alignedColumnCount(prevColumns!, columns) <
          kTableBlockMinAlignedColumns) {
        break;
      }
    }
    chosen.add(ri);
    for (final i in visual.rows[ri]) {
      final r = items[i].rect;
      if ((r.left + r.right) / 2 > rr.left - 0.5 &&
          (r.left + r.right) / 2 < rr.right + 0.5) {
        blockItems.add(i);
      }
    }
    blockRect = blockRect == null ? rr : _union(blockRect, rr);
    prevRect = rr;
    prevColumns = columns;
  }
  if (blockRect == null || chosen.length < kTableBlockMinRows) return null;
  return _TableBlock(blockItems, blockRect);
}

/// Anchor indexes that are entries of a LIST OF FIGURES / LIST OF TABLES
/// rather than captions of anything on this page.
///
/// The evidence is that they are stacked at one margin with less than
/// [kMinRegionHeightPts] of clear space between consecutive entries: whatever
/// they announce, it is not between them, because nothing fits between them.
/// Three such entries in a row is a list — every thesis has that page, and
/// its first entry used to claim the heading above it at 0.9 confidence.
Set<int> _captionListEntries(List<CaptionAnchor> anchors) {
  if (anchors.length < kCaptionListMinEntries) return const {};
  final order = [for (var i = 0; i < anchors.length; i++) i]
    ..sort((a, b) => anchors[b].rect.top.compareTo(anchors[a].rect.top));
  final listed = <int>{};
  var chain = <int>[order.first];
  for (var k = 1; k < order.length; k++) {
    final upper = anchors[chain.last].rect;
    final lower = anchors[order[k]].rect;
    final clear = upper.bottom - lower.top;
    final sameMargin =
        (upper.left - lower.left).abs() <= kRunMarginTolerancePts;
    if (sameMargin && clear >= 0 && clear < kMinRegionHeightPts) {
      chain.add(order[k]);
      continue;
    }
    if (chain.length >= kCaptionListMinEntries) listed.addAll(chain);
    chain = [order[k]];
  }
  if (chain.length >= kCaptionListMinEntries) listed.addAll(chain);
  return listed;
}

/// Infers figure/table regions for one page over the UNION of text-layer and
/// OCR items (pure geometry — this is what the spike validates against
/// ground-truth fixtures).
///
/// Captioned regions: grow the band away from the caption (up for figures;
/// for tables the side that actually holds the table), stopping at the
/// nearest BODY-LIKE line that horizontally overlaps the caption's span —
/// see [classifyPageLines] for what "body-like" means and why width alone is
/// not it. Blocking is decided PER REGION, not once per page: a line only
/// stops growth when the paragraph it belongs to fills the strip it shares
/// with this caption (`runFillsSpan` below), which is what separates a
/// column of prose from an in-figure legend or a stack of tick labels that
/// happen to sit at leading distance from each other. Wrapped caption lines
/// are folded into the anchor first ([_mergeCaptionContinuations]);
/// in-figure labels and table rows are absorbed into the region instead of
/// bounding it. The region then adopts the column margins of the bounding
/// body lines and absorbs in-band items transitively, with a vertical
/// re-check + fallback so a full-width reference can never drag a two-column
/// figure across the other column. Bands are rejected when they are entirely
/// text-free and short, when their own text density is body-like
/// ([kMaxBandTextDensity]), or when they cover most of the page while
/// containing many text lines.
///
/// Whitespace candidates: maximal horizontal bands free of ALL text, larger
/// than [kWhitespaceMinAreaFrac] of the page, not already claimed by a
/// captioned region — emitted at [kWhitespaceConfidence] and filtered by
/// [minConfidence] (default admits captioned only).
List<FigureRegion> inferFigureRegions({
  required int page,
  required double pageWidthPts,
  required double pageHeightPts,
  required List<PageTextItem> items,
  double minConfidence = kDefaultMinConfidence,
}) {
  final anchors = detectCaptionAnchors(items);
  final anchorIndexes = {for (final a in anchors) a.itemIndex};
  final analysis = _analysePage(
    items,
    pageWidthPts: pageWidthPts,
    pageHeightPts: pageHeightPts,
    captionIndexes: anchorIndexes,
  );
  final classes = analysis.classes;
  final merged = [
    for (final anchor in anchors)
      _mergeCaptionContinuations(anchor, items, classes, analysis.linePitch),
  ];
  final visual = analysis.visual;

  // The visual row each item sits in, so the emit gate can re-derive an
  // item's exemption from the row's OWN table evidence.
  final rowOfItem = List<int>.filled(items.length, -1);
  for (var ri = 0; ri < visual.rows.length; ri++) {
    for (final i in visual.rows[ri]) {
      rowOfItem[i] = ri;
    }
  }

  // A LIST OF FIGURES / LIST OF TABLES page: three or more captions stacked
  // at one margin with no room for a figure between them. They are index
  // entries, not captions of anything on this page — and the first of them
  // used to claim the band above it (the page's heading) as a figure.
  final listed = _captionListEntries(anchors);

  // SUB-CAPTIONS ("Fig. 2a baseline" / "Fig. 2b proposed" under "Figure 2:"):
  // each labels a PART of its parent's figure. Left alone, each re-derived
  // the parent's exact band (two byte-identical regions) and, being captions,
  // bounded the parent's own growth into an 8pt sliver that was then dropped
  // — the parent figure lost to its own sub-labels. A sub-caption therefore
  // claims no region and is treated as content of its parent's band.
  final subordinate = List<bool>.filled(anchors.length, false);
  final subItemsOf = List.generate(anchors.length, (_) => <int>{});
  for (var p = 0; p < anchors.length; p++) {
    final parent = anchors[p];
    if (parent.subLetter != null || parent.number.isEmpty) continue;
    for (var c = 0; c < anchors.length; c++) {
      if (c == p) continue;
      final child = anchors[c];
      if (child.subLetter == null ||
          child.kind != parent.kind ||
          child.number != parent.number) {
        continue;
      }
      if ((_centerY(child.rect) - _centerY(parent.rect)).abs() >
          0.5 * pageHeightPts) {
        continue;
      }
      subordinate[c] = true;
      subItemsOf[p].add(child.itemIndex);
    }
  }

  final runMembers = <int, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    if (classes[i].runGroup >= 0) {
      runMembers.putIfAbsent(classes[i].runGroup, () => []).add(i);
    }
  }

  /// Whether the paragraph [group] FILLS the strip it shares with [span] —
  /// the test that decides whether a run of text actually bounds a region.
  ///
  /// A paragraph covers most of the strip's area: its lines run the width of
  /// the column and its leading is a fraction of its line height. The two
  /// things that used to truncate figures do not: a two-line in-figure
  /// legend covers ~30% of the strip and a stack of ten y-axis tick labels
  /// ~4%, because they are narrow — while a page of narrow VERSE still
  /// covers ~42%, because the strip it shares with its own caption is narrow
  /// too. Width alone cannot tell those apart; this ratio can.
  final fillCache = <String, bool>{};
  bool runFillsSpan(int group, PdfRect span) {
    final key = '$group:${span.left}:${span.right}';
    final cached = fillCache[key];
    if (cached != null) return cached;
    var top = double.negativeInfinity;
    var bottom = double.infinity;
    var left = span.left;
    var right = span.right;
    var ink = 0.0;
    var lines = 0;
    for (final i in runMembers[group] ?? const <int>[]) {
      final r = items[i].rect;
      if (_xOverlap(r, span) <= 0.5) continue;
      lines++;
      top = math.max(top, r.top);
      bottom = math.min(bottom, r.bottom);
      left = math.min(left, r.left);
      right = math.max(right, r.right);
      ink += _width(r) * _height(r);
    }
    final strip = (top - bottom) * (right - left);
    final density = strip > 0 ? ink / strip : 0.0;
    final fills =
        lines >= 2 &&
        density >=
            (lines >= 3 ? kBlockingRunMinDensity : kBlockingRunPairMinDensity);
    fillCache[key] = fills;
    return fills;
  }

  bool blocks(int i, PdfRect span) {
    if (classes[i].isCaption) return true;
    if (classes[i].isTabular || !classes[i].inBodyRun) return false;
    return runFillsSpan(classes[i].runGroup, span);
  }

  /// Nearest blocker edge above [fromY] over the horizontal [span]
  /// (excluding the caption's own lines): the bottom of the lowest blocker
  /// whose bottom is at/above [fromY]. The page top when nothing is above.
  ({double edge, PdfRect? rect}) boundAbove(
    PdfRect span,
    double fromY,
    Set<int> exclude,
  ) {
    double? edge;
    PdfRect? rect;
    for (var i = 0; i < items.length; i++) {
      if (exclude.contains(i) || !classes[i].blocksGrowth) continue;
      final b = items[i].rect;
      if (_xOverlap(b, span) <= 0.5) continue;
      if (b.bottom < fromY) continue;
      if (edge != null && b.bottom >= edge) continue;
      if (!blocks(i, span)) continue;
      edge = b.bottom;
      rect = b;
    }
    return (edge: edge ?? pageHeightPts, rect: rect);
  }

  /// Mirror of [boundAbove] going down: the top of the highest blocker whose
  /// top is at/below [fromY].
  ({double edge, PdfRect? rect}) boundBelow(
    PdfRect span,
    double fromY,
    Set<int> exclude,
  ) {
    double? edge;
    PdfRect? rect;
    for (var i = 0; i < items.length; i++) {
      if (exclude.contains(i) || !classes[i].blocksGrowth) continue;
      final b = items[i].rect;
      if (_xOverlap(b, span) <= 0.5) continue;
      if (b.top > fromY) continue;
      if (edge != null && b.top <= edge) continue;
      if (!blocks(i, span)) continue;
      edge = b.top;
      rect = b;
    }
    return (edge: edge ?? 0, rect: rect);
  }

  /// Text items sitting inside a band over [span] — how a table announces
  /// which side of its caption it is on, and the "is this band anything but
  /// whitespace?" signal.
  int contentIn(double bottom, double top, PdfRect span, Set<int> exclude) {
    var count = 0;
    for (var i = 0; i < items.length; i++) {
      if (exclude.contains(i)) continue;
      final r = items[i].rect;
      final centerY = _centerY(r);
      if (centerY <= bottom || centerY >= top) continue;
      if (_xOverlap(r, span) <= 0.5) continue;
      count++;
    }
    return count;
  }

  final regions = <FigureRegion>[];

  for (var ai = 0; ai < merged.length; ai++) {
    if (subordinate[ai] || listed.contains(ai)) continue;
    final anchor = merged[ai];
    final span = anchor.rect;
    final exclude = {...anchor.indexes, ...subItemsOf[ai]};

    // POSITIVE table evidence, per side. A table block overrides the band's
    // bounds entirely: its rows are the content the caption claims, so they
    // neither bound the band nor count against it, and the band is TRIMMED
    // to them (a table caption with nothing below it used to hand back the
    // 692pt strip from the caption to the page edge for a 126pt table).
    _TableBlock? block;
    var blockBelow = false;
    if (anchor.kind == CaptionKind.table) {
      _TableBlock? sideBlock(bool below) => _detectTableBlock(
        items: items,
        page: analysis,
        captionRect: span,
        exclude: exclude,
        captionIndexes: anchorIndexes,
        below: below,
        pageWidthPts: pageWidthPts,
      );
      // Below first: "Table N" captions sit above their table by convention,
      // and when both sides look like tables that convention is the only
      // evidence there is.
      block = sideBlock(true);
      blockBelow = block != null;
      block ??= sideBlock(false);
    }

    // Vertical band on the chosen side of the caption.
    final above = boundAbove(span, span.top, exclude);
    final aboveBottom = span.top + kCaptionRegionPaddingPts;
    final aboveTop = above.edge - kCaptionRegionPaddingPts;
    final aboveHeight = aboveTop - aboveBottom;

    var useAbove = true;
    var bandBottom = aboveBottom;
    var bandTop = aboveTop;
    PdfRect? boundingBlocker = above.rect;
    if (block != null) {
      useAbove = !blockBelow;
      if (blockBelow) {
        bandTop = math.min(
          span.bottom - kCaptionRegionPaddingPts,
          block.rect.top + kCaptionRegionPaddingPts,
        );
        bandBottom = block.rect.bottom - kCaptionRegionPaddingPts;
      } else {
        bandBottom = math.max(
          span.top + kCaptionRegionPaddingPts,
          block.rect.bottom - kCaptionRegionPaddingPts,
        );
        bandTop = block.rect.top + kCaptionRegionPaddingPts;
      }
      boundingBlocker = null;
    } else if (anchor.kind == CaptionKind.table) {
      final below = boundBelow(span, span.bottom, exclude);
      final belowTop = span.bottom - kCaptionRegionPaddingPts;
      final belowBottom = below.edge + kCaptionRegionPaddingPts;
      final belowHeight = belowTop - belowBottom;
      // A table caption sits above OR below its table. Pick the side that
      // HAS the table: the one holding more text (table rows are text, and
      // this is what stops a 42pt strip of inter-paragraph whitespace above
      // the caption from beating the real table below it), then the taller.
      final aboveOk = aboveHeight >= kMinRegionHeightPts;
      final belowOk = belowHeight >= kMinRegionHeightPts;
      final aboveContent = aboveOk
          ? contentIn(aboveBottom, aboveTop, span, exclude)
          : -1;
      final belowContent = belowOk
          ? contentIn(belowBottom, belowTop, span, exclude)
          : -1;
      if (belowOk &&
          (!aboveOk ||
              belowContent > aboveContent ||
              (belowContent == aboveContent && belowHeight > aboveHeight))) {
        useAbove = false;
        bandBottom = belowBottom;
        bandTop = belowTop;
        boundingBlocker = below.rect;
      }
    }
    if (bandTop - bandBottom < kMinRegionHeightPts) continue;

    // Horizontal extent: caption span → column margins of the bounding body
    // lines (the blocker that bounded the band, plus the nearest body line
    // on the caption's other side — both share the caption's column) → then
    // absorb narrow in-band items (in-figure labels, table cells) that
    // overlap the growing interval, transitively.
    var left = span.left;
    var right = span.right;
    if (block != null) {
      // The claimed rows ARE the horizontal extent — including columns too
      // far from the caption for any reach to find (a third money column
      // 100pt out used to be left outside the crop).
      left = block.rect.left;
      right = block.rect.right;
    } else {
      if (boundingBlocker != null) {
        left = math.min(left, boundingBlocker.left);
        right = math.max(right, boundingBlocker.right);
      }
      final opposite = useAbove
          ? boundBelow(span, span.bottom, exclude).rect
          : boundAbove(span, span.top, exclude).rect;
      if (opposite != null) {
        left = math.min(left, opposite.left);
        right = math.max(right, opposite.right);
      }
    }
    // The caption's own page column. NOTHING this region claims may cross a
    // detected corridor: not an absorbed label, not the text margin a clear
    // side reaches for. A figure in the left column of a two-column page
    // whose right column happens to be blank beside it used to take its
    // extent from the far column's margin and crop both columns.
    final columnBounds = analysis.columns.boundsFor(span, pageWidthPts);
    final absorbReach = kAbsorbReachFrac * pageWidthPts;
    ({double left, double right}) absorbInBand(double l, double r) {
      var changed = true;
      var guard = 0;
      while (changed && guard++ < 64) {
        changed = false;
        for (final item in items) {
          final rect = item.rect;
          final centerY = (rect.top + rect.bottom) / 2;
          if (centerY <= bandBottom || centerY >= bandTop) continue;
          if (rect.right <= columnBounds.left ||
              rect.left >= columnBounds.right) {
            continue; // Another page column entirely.
          }
          if (math.min(r, rect.right) - math.max(l, rect.left) < -absorbReach) {
            continue; // Reach for adjacent labels/cells, never a page column.
          }
          final newLeft = math.max(rect.left, columnBounds.left);
          final newRight = math.min(rect.right, columnBounds.right);
          if (newLeft < l) {
            l = newLeft;
            changed = true;
          }
          if (newRight > r) {
            r = newRight;
            changed = true;
          }
        }
      }
      return (left: l, right: r);
    }

    final widened = absorbInBand(left, right);
    left = widened.left;
    right = widened.right;

    // Vertical re-check against the widened span: in a two-column layout a
    // full-width reference could have widened the span into the other
    // column's text — if the re-check collapses the band, fall back to the
    // caption-only span (plus in-band absorption) and keep the original
    // band…
    final wideSpan = (
      left: left,
      top: bandTop,
      right: right,
      bottom: bandBottom,
    );
    var revertedWidth = false;
    if (block != null) {
      // The band is the claimed block: there is nothing to re-check, and a
      // blocker beyond the block is simply outside the region.
    } else if (useAbove) {
      final recheck = boundAbove(wideSpan, bandBottom, exclude);
      final newTop = recheck.edge - kCaptionRegionPaddingPts;
      if (newTop - bandBottom < kMinRegionHeightPts) {
        final narrow = absorbInBand(span.left, span.right);
        left = narrow.left;
        right = narrow.right;
        revertedWidth = true;
      } else if (newTop < bandTop) {
        bandTop = newTop;
      }
    } else {
      final recheck = boundBelow(wideSpan, bandTop, exclude);
      final newBottom = recheck.edge + kCaptionRegionPaddingPts;
      if (bandTop - newBottom < kMinRegionHeightPts) {
        final narrow = absorbInBand(span.left, span.right);
        left = narrow.left;
        right = narrow.right;
        revertedWidth = true;
      } else if (newBottom > bandBottom) {
        bandBottom = newBottom;
      }
    }

    // …but the REVERTED width still has to survive its own bound check. It
    // is the reverted-width path that used to hand back a whole-page "figure"
    // on pages of narrow lines: the widened span collapsed, the width fell
    // back, and the full-height band was kept unexamined. If the region's
    // FINAL horizontal extent runs straight into body text, there is no
    // region here.
    if (revertedWidth) {
      final finalSpan = (
        left: left,
        top: bandTop,
        right: right,
        bottom: bandBottom,
      );
      if (useAbove) {
        final edge =
            boundAbove(finalSpan, bandBottom, exclude).edge -
            kCaptionRegionPaddingPts;
        if (edge - bandBottom < kMinRegionHeightPts) continue;
        if (edge < bandTop) bandTop = edge;
      } else {
        final edge =
            boundBelow(finalSpan, bandTop, exclude).edge +
            kCaptionRegionPaddingPts;
        if (bandTop - edge < kMinRegionHeightPts) continue;
        if (edge > bandBottom) bandBottom = edge;
      }
    }

    // THE PAGE EDGE BOUNDS NOTHING. When growth ran off the page without
    // meeting a blocker, the band's far edge is not evidence — and any
    // PARAGRAPH inside such a band bounds it, whether or not that paragraph
    // was dense enough to block growth on its own. The fill test exists to
    // protect in-figure text (a two-line legend, a stack of tick labels),
    // and in-figure text never sits alone in a band that runs off the page:
    // it sits between a caption and the body text above it. Two lines of
    // double-spaced prose at the top of an otherwise blank page did, and
    // came back inside a page-sized "figure".
    if (block == null) {
      final reachedPageEdge = useAbove
          ? bandTop >= pageHeightPts - kCaptionRegionPaddingPts
          : bandBottom <= kCaptionRegionPaddingPts;
      if (reachedPageEdge) {
        final bandSpan = (
          left: left,
          top: bandTop,
          right: right,
          bottom: bandBottom,
        );
        for (var i = 0; i < items.length; i++) {
          if (exclude.contains(i)) continue;
          if (!classes[i].inBodyRun || classes[i].isTabular) continue;
          final r = items[i].rect;
          if (_xOverlap(r, bandSpan) <= 0.5) continue;
          if (useAbove) {
            if (r.bottom < bandTop && r.bottom >= bandBottom) {
              bandTop = r.bottom - kCaptionRegionPaddingPts;
            }
          } else if (r.top > bandBottom && r.top <= bandTop) {
            bandBottom = r.top + kCaptionRegionPaddingPts;
          }
        }
      }
    }

    // WHITESPACE EXTENT. A figure is where text ISN'T, so a side of the band
    // with no text beside it carries no width evidence at all — and deriving
    // the extent only from adjacent text collapsed a full-page plate to the
    // width of the words under it (a 258pt caption for a 468pt figure). A
    // side that is CLEAR over the band's whole height may therefore claim
    // out to the page's text margin — clamped to the caption's own page
    // COLUMN, because a blank right column is not evidence that this figure
    // is two columns wide.
    //
    // A side that is NOT clear claims nothing: that is what keeps a
    // two-column figure out of the other column.
    var bandIsEmpty = false;
    if (block == null) {
      var leftClear = true;
      var rightClear = true;
      var textLeft = span.left;
      var textRight = span.right;
      var inBand = 0;
      for (var i = 0; i < items.length; i++) {
        if (exclude.contains(i)) continue;
        final r = items[i].rect;
        if (r.right > columnBounds.left && r.left < columnBounds.right) {
          textLeft = math.min(textLeft, r.left);
          textRight = math.max(textRight, r.right);
        }
        if (math.min(r.top, bandTop) - math.max(r.bottom, bandBottom) <= 0) {
          continue;
        }
        if (r.right > columnBounds.left && r.left < columnBounds.right) {
          inBand++;
        }
        if (r.left < left - 0.5) leftClear = false;
        if (r.right > right + 0.5) rightClear = false;
      }
      bandIsEmpty = inBand == 0;
      if (leftClear) {
        left = math.max(math.min(left, textLeft), columnBounds.left);
      }
      if (rightClear) {
        right = math.min(math.max(right, textRight), columnBounds.right);
      }
      // Last resort, and ONLY for a band with no text in it at all: a plate
      // with nothing but its caption under it leaves no text to measure, so
      // the caption's own margin is mirrored on the far side. Mirroring is
      // not evidence — it is a guess at the page's margin box — so a band
      // that HAS content must take its extent from that content instead. A
      // 66pt strip of whitespace beside a poem used to take a 432pt width
      // from this rule and render as a blank PNG captioned "Figure 9".
      if (bandIsEmpty &&
          right - left < kEmptyBandNarrowExtentFrac * pageWidthPts) {
        if (rightClear) {
          right = math.min(
            math.max(right, pageWidthPts - left),
            columnBounds.right,
          );
        } else if (leftClear) {
          left = math.max(
            math.min(left, pageWidthPts - right),
            columnBounds.left,
          );
        }
      }
    }

    // A TABLE IS TEXT, so a table region is TRIMMED to the text it holds —
    // with a block, to the block; without one, to whatever the band actually
    // contains in this column. The blockless path had no trimming at all: any
    // shape that defeated block detection (a merged header row, a
    // right-aligned money column) reverted to a band running from the caption
    // to the PAGE EDGE, which is how a 122pt table came back as a 692pt crop.
    if (anchor.kind == CaptionKind.table && block == null) {
      final bandSpan = (
        left: left,
        top: bandTop,
        right: right,
        bottom: bandBottom,
      );
      PdfRect? content;
      for (var i = 0; i < items.length; i++) {
        if (exclude.contains(i)) continue;
        final r = items[i].rect;
        final centerY = _centerY(r);
        if (centerY <= bandBottom || centerY >= bandTop) continue;
        if (r.right <= columnBounds.left || r.left >= columnBounds.right) {
          continue;
        }
        if (_xOverlap(r, bandSpan) <= 0.5) continue;
        content = content == null ? r : _union(content, r);
      }
      if (content == null) continue; // Nothing to crop: not a table.
      bandTop = math.min(bandTop, content.top + kCaptionRegionPaddingPts);
      bandBottom = math.max(
        bandBottom,
        content.bottom - kCaptionRegionPaddingPts,
      );
      left = math.max(left, content.left - kCaptionRegionPaddingPts);
      right = math.min(right, content.right + kCaptionRegionPaddingPts);
    }

    // Clamp to the page and to the caption's page column.
    left = left.clamp(columnBounds.left, columnBounds.right);
    right = right.clamp(columnBounds.left, columnBounds.right);
    left = left.clamp(0.0, pageWidthPts);
    right = right.clamp(0.0, pageWidthPts);
    bandBottom = bandBottom.clamp(0.0, pageHeightPts);
    bandTop = bandTop.clamp(0.0, pageHeightPts);
    if (bandTop - bandBottom < kMinRegionHeightPts ||
        right - left < kMinRegionWidthPts) {
      continue;
    }

    final finalSpan = (
      left: left,
      top: bandTop,
      right: right,
      bottom: bandBottom,
    );

    // A band with NO text in it at all is not evidence of a figure — it is
    // evidence of whitespace, and every page has whitespace. Only its SIZE
    // relative to the page tells a plate from the leading between two
    // paragraphs, the gap above a caption at the foot of a poem, or the
    // page's own bottom margin. Round 3 applied the page-relative floor only
    // to bands running to the page edge; a 66pt strip between a poem and its
    // caption cleared the flat 60pt floor everywhere else and rendered as a
    // blank 432×66 PNG captioned "Figure 9: Sonnet layout" — 0 items, 0% ink.
    final bandContent = contentIn(bandBottom, bandTop, finalSpan, exclude);
    if (bandContent == 0 &&
        bandTop - bandBottom <
            math.max(
              kMinContentFreeRegionHeightPts,
              kMinContentFreeRegionHeightFrac * pageHeightPts,
            )) {
      continue;
    }

    // A TABLE is text. An empty rect beside a table caption is the strip of
    // page whitespace next to it, never the table — the blank-PNG-labelled-
    // "Table 2" failure in its general form (round 2 fixed the case where a
    // better-populated side existed; a table caption at the top or foot of a
    // page has no such competition). Without a block to vouch for it, one
    // stray item in the band is no better evidence than none.
    if (anchor.kind == CaptionKind.table &&
        block == null &&
        bandContent < kMinBlocklessTableBandItems) {
      continue;
    }

    // THE EXEMPTION, RE-DERIVED. The backstops below ignore the rows a table
    // caption positively claims — otherwise no table could ever pass a
    // density test, a table being dense text by definition. Round 3 took that
    // claim on the block detector's word, which made the backstops
    // exemptible: one bug in block detection (it applied none of the
    // page-column defences) was enough to emit a whole page of prose at 0.9
    // confidence, with 69% prose ink, past two guards that had been designed
    // to be the last line of defence.
    //
    // So the exemption is re-derived HERE, per item, from the item's own
    // visual row: a row is exempt only if it carries table evidence of its
    // own — a gutter, flanked by something that holds what a table cell
    // holds, surviving the page-column defences ([_PageColumns]). Nothing a
    // block asserts can exempt a paragraph.
    final claimed = <int>{};
    if (block != null) {
      for (final i in block.itemIndexes) {
        final ri = rowOfItem[i];
        if (ri >= 0 && analysis.rowHasTableEvidence(ri)) claimed.add(i);
      }
    }

    // TEXT-DENSITY guard: whatever the line-by-line classification decided,
    // a band whose own area is largely ink is body text. A figure is sparse
    // — a plot with an in-figure legend is 2–3% ink, a chart with a title
    // and axis labels 5–6% — while a column of prose is 80%+ and a page of
    // one-line paragraphs (a slide, a chat log) is still well over the
    // threshold. This is the backstop for every way the classifier can be
    // fooled: misread column gutters, in-figure text that looks like a
    // paragraph, lone lines that form no run at all.
    final bandArea = (bandTop - bandBottom) * (right - left);
    if (bandArea > 0) {
      var ink = 0.0;
      for (var i = 0; i < items.length; i++) {
        if (exclude.contains(i) || claimed.contains(i)) continue;
        final r = items[i].rect;
        final w = _xOverlap(r, finalSpan);
        final h = math.min(r.top, bandTop) - math.max(r.bottom, bandBottom);
        if (w <= 0 || h <= 0) continue;
        ink += w * h;
      }
      if (ink / bandArea > kMaxBandTextDensity) continue;
    }

    // Whole-page guard: a band covering most of the page that still holds
    // many text LINES is the page itself (verse, TOC, narrow CJK columns,
    // sparse slides), not a figure. Scattered narrow labels do not count —
    // a genuine full-page figure keeps passing.
    if (bandTop - bandBottom > kWholePageBandHeightFrac * pageHeightPts) {
      var textLines = 0;
      for (var i = 0; i < items.length; i++) {
        if (exclude.contains(i) || claimed.contains(i)) continue;
        final r = items[i].rect;
        final centerY = _centerY(r);
        if (centerY <= bandBottom || centerY >= bandTop) continue;
        if (_xOverlap(r, finalSpan) <= 0.5) continue;
        final wide = _width(r) >= kWideTextLineWidthFrac * pageWidthPts;
        if (classes[i].isCaption ||
            classes[i].inBodyRun ||
            _width(r) >= kCountedTextLineMinWidthFrac * pageWidthPts) {
          // Width-weighted: a page-measure line is evidence of a page of
          // text, a diagram label is not (see [kWholePageMaxTextLines]).
          textLines += wide ? 2 : 1;
        }
      }
      if (textLines >= kWholePageMaxTextLines) continue;
    }

    final rect = (left: left, top: bandTop, right: right, bottom: bandBottom);
    // Two captions that derived the same band describe one region; emitting
    // it twice renders the same crop twice and offers the reader a choice
    // between identical images.
    final duplicate = regions.any(
      (r) =>
          (r.rectPdf.left - rect.left).abs() <= kDuplicateRegionTolerancePts &&
          (r.rectPdf.right - rect.right).abs() <=
              kDuplicateRegionTolerancePts &&
          (r.rectPdf.top - rect.top).abs() <= kDuplicateRegionTolerancePts &&
          (r.rectPdf.bottom - rect.bottom).abs() <=
              kDuplicateRegionTolerancePts,
    );
    if (duplicate) continue;

    regions.add(
      FigureRegion(
        page: page,
        rectPdf: rect,
        caption: anchor.text,
        confidence: kCaptionedConfidence,
        source: FigureRegionSource.captioned,
      ),
    );
  }

  // Caption-less candidates: horizontal bands free of ALL text items whose
  // area exceeds the threshold and which are not already claimed by a
  // captioned region. Behind the confidence threshold (default: excluded).
  if (minConfidence <= kWhitespaceConfidence) {
    final pageArea = pageWidthPts * pageHeightPts;
    // Merge item y-intervals into covered bands.
    final intervals =
        items.map((i) => (bottom: i.rect.bottom, top: i.rect.top)).toList()
          ..sort((a, b) => a.bottom.compareTo(b.bottom));
    final covered = <({double bottom, double top})>[];
    for (final iv in intervals) {
      if (covered.isNotEmpty && iv.bottom <= covered.last.top) {
        final last = covered.removeLast();
        covered.add((bottom: last.bottom, top: math.max(last.top, iv.top)));
      } else {
        covered.add(iv);
      }
    }
    final gaps = <({double bottom, double top})>[];
    var cursor = 0.0;
    for (final band in covered) {
      if (band.bottom > cursor) gaps.add((bottom: cursor, top: band.bottom));
      cursor = math.max(cursor, band.top);
    }
    if (cursor < pageHeightPts) gaps.add((bottom: cursor, top: pageHeightPts));

    // Horizontal extent: the page's text margins when known, else full page.
    var left = 0.0;
    var right = pageWidthPts;
    if (items.isNotEmpty) {
      left = items.map((i) => i.rect.left).reduce(math.min);
      right = items.map((i) => i.rect.right).reduce(math.max);
    }

    for (final gap in gaps) {
      final height = gap.top - gap.bottom;
      if (height * pageWidthPts <= kWhitespaceMinAreaFrac * pageArea) continue;
      final bandArea = height * (right - left);
      if (bandArea <= 0) continue;
      // Skip bands mostly claimed by a captioned region.
      var claimed = false;
      for (final region in regions) {
        final r = region.rectPdf;
        final ix = math.min(r.right, right) - math.max(r.left, left);
        final iy = math.min(r.top, gap.top) - math.max(r.bottom, gap.bottom);
        if (ix > 0 && iy > 0 && ix * iy > 0.5 * bandArea) {
          claimed = true;
          break;
        }
      }
      if (claimed) continue;
      regions.add(
        FigureRegion(
          page: page,
          rectPdf: (left: left, top: gap.top, right: right, bottom: gap.bottom),
          confidence: kWhitespaceConfidence,
          source: FigureRegionSource.whitespace,
        ),
      );
    }
  }

  return [
    for (final r in regions)
      if (r.confidence >= minConfidence) r,
  ];
}

// ─── pdfrx seam ──────────────────────────────────────────────────────────────

/// One page's text items + geometry, as loaded through the seam.
class PdfFigurePage {
  const PdfFigurePage({
    required this.pageWidthPts,
    required this.pageHeightPts,
    required this.items,
  });

  /// Page size in PDF points (y-up coordinate space).
  final double pageWidthPts;
  final double pageHeightPts;

  /// Text-layer items (fragment lines with bounds, PDF page coordinates).
  final List<PageTextItem> items;
}

/// Minimal figure-extraction view of an open PDF document: structured-text
/// fragments AND sub-region rendering (the pdfrx seam for the figure stage,
/// mirroring PdfTextSource / PdfOcrRenderSource).
abstract class PdfFigureSource {
  int get pageCount;

  /// Text items + page size of page [pageIndex] (0-based; [FigureRegion.page]
  /// is 1-based — the conversion happens in [FigureRegionExtractor]).
  Future<PdfFigurePage> loadPage(int pageIndex);

  /// Renders the sub-region [x, y, width, height] (raster pixels, y-down,
  /// within a virtual full page of [fullWidth]×[fullHeight] pixels) of page
  /// [pageIndex] as PNG bytes. Null when rendering fails.
  Future<Uint8List?> renderRegionPng(
    int pageIndex, {
    required int x,
    required int y,
    required int width,
    required int height,
    required double fullWidth,
    required double fullHeight,
  });

  Future<void> dispose();
}

/// Opens the PDF at an absolute [path] for figure extraction.
typedef PdfFigureSourceOpener = Future<PdfFigureSource> Function(String path);

/// Merges text fragments into line items: pdfrx's fragment granularity is
/// not guaranteed to be full lines, and caption matching needs whole lines
/// ("Figure" + "1:" as separate word fragments would never match).
/// Fragments join when they overlap vertically by at least half the smaller
/// height AND sit within 1.5×line-height horizontally — the gap cap keeps
/// two-column lines at the same y from merging into a page-wide item (which
/// would become a column-crossing blocker).
///
/// Each merged line KEEPS its source fragment rects in
/// [PageTextItem.fragmentRects]. A table row's per-cell fragments merge at
/// this granularity (a 10pt gutter is well under 1.5 line-heights), so
/// without them a table row is indistinguishable from a body line and the
/// whole table reads as a wall of body text.
List<PageTextItem> mergeFragmentsIntoLines(
  List<PageTextItem> fragments, {
  double? pageHeightPts,
}) {
  // A page COLUMN corridor is never crossed by a line. The 1.5×line-height
  // gap cap alone lets a 12pt gutter join a right-column caption to the body
  // text beside it — and a caption merged into a body line stops being a
  // caption at all (its keyword is no longer at line start, and its rect now
  // spans both columns).
  final corridors = pageHeightPts == null
      ? const <({double left, double right})>[]
      : detectLayoutCorridors(fragments, pageHeightPts: pageHeightPts);
  bool crossesCorridor(double from, double to) {
    if (from > to) {
      final swap = from;
      from = to;
      to = swap;
    }
    for (final corridor in corridors) {
      if (from <= corridor.left && to >= corridor.right) return true;
    }
    return false;
  }

  final sorted = [...fragments]
    ..sort((a, b) {
      final byTop = b.rect.top.compareTo(a.rect.top); // Top of page first.
      return byTop != 0 ? byTop : a.rect.left.compareTo(b.rect.left);
    });
  final lines = <({StringBuffer text, PdfRect rect, List<PdfRect> parts})>[];
  for (final fragment in sorted) {
    final r = fragment.rect;
    ({StringBuffer text, PdfRect rect, List<PdfRect> parts})? target;
    var targetIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      final lr = lines[i].rect;
      final vOverlap = math.min(lr.top, r.top) - math.max(lr.bottom, r.bottom);
      final minHeight = math.min(lr.top - lr.bottom, r.top - r.bottom);
      if (minHeight <= 0 || vOverlap < 0.5 * minHeight) continue;
      final gap = math.max(lr.left, r.left) - math.min(lr.right, r.right);
      final lineHeight = math.max(lr.top - lr.bottom, r.top - r.bottom);
      if (gap > 1.5 * lineHeight) continue;
      if (crossesCorridor(
        math.min(lr.right, r.right),
        math.max(lr.left, r.left),
      )) {
        continue;
      }
      target = lines[i];
      targetIndex = i;
      break;
    }
    if (target == null) {
      lines.add((
        text: StringBuffer(fragment.text.trim()),
        rect: r,
        parts: [
          if (fragment.fragmentRects.isEmpty) r else ...fragment.fragmentRects,
        ],
      ));
    } else {
      target.text.write(' ${fragment.text.trim()}');
      if (fragment.fragmentRects.isEmpty) {
        target.parts.add(r);
      } else {
        target.parts.addAll(fragment.fragmentRects);
      }
      lines[targetIndex] = (
        text: target.text,
        parts: target.parts,
        rect: (
          left: math.min(target.rect.left, r.left),
          top: math.max(target.rect.top, r.top),
          right: math.max(target.rect.right, r.right),
          bottom: math.min(target.rect.bottom, r.bottom),
        ),
      );
    }
  }
  return [
    for (final line in lines)
      if (line.text.toString().trim().isNotEmpty)
        PageTextItem(
          text: line.text.toString().trim(),
          rect: line.rect,
          fragmentRects: line.parts..sort((a, b) => a.left.compareTo(b.left)),
        ),
  ];
}

/// Maps a rect from the UNROTATED PDF user space (where pdfium's
/// `FPDFText_GetCharBox` — and therefore pdfrx's `fragment.bounds` /
/// `charRects` — lives) into the page's DISPLAY space (where `page.width` /
/// `page.height` and every raster `page.render` produces live).
///
/// The two frames differ exactly when the page carries `/Rotate 90|180|270`:
/// `FPDF_GetPageWidthF/HeightF` are rotation-adjusted (a `/Rotate 90` A4
/// page reports 842×595), while character boxes are not. Pairing them would
/// measure line widths along the wrong axis AND crop a differently-rotated
/// area of the raster — a silently wrong figure on every rotated scan.
///
/// [displayWidthPts]/[displayHeightPts] are `page.width`/`page.height`. This
/// is the same transform as pdfrx's own `PdfRect.rotate(rotation, page)`
/// (pdfrx_engine `lib/src/pdf_rect.dart`), reimplemented here so it is a
/// pure function the unit tests can pin without a live pdfium.
PdfRect rotateRectToDisplaySpace(
  PdfRect rect, {
  required int rotation,
  required double displayWidthPts,
  required double displayHeightPts,
}) {
  final quarter = rotation & 3;
  if (quarter == 0) return rect;
  // Unrotated page size: the display size with the axes swapped for 90/270.
  final swap = quarter.isOdd;
  final w = swap ? displayHeightPts : displayWidthPts;
  final h = swap ? displayWidthPts : displayHeightPts;
  switch (quarter) {
    case 1: // clockwise 90: (x, y) → (y, w − x)
      return (
        left: rect.bottom,
        top: w - rect.left,
        right: rect.top,
        bottom: w - rect.right,
      );
    case 2: // 180: (x, y) → (w − x, h − y)
      return (
        left: w - rect.right,
        top: h - rect.bottom,
        right: w - rect.left,
        bottom: h - rect.top,
      );
    default: // 3, clockwise 270: (x, y) → (h − y, x)
      return (
        left: h - rect.top,
        top: rect.right,
        right: h - rect.bottom,
        bottom: rect.left,
      );
  }
}

class _PdfrxFigureSource implements PdfFigureSource {
  _PdfrxFigureSource(this._document);

  final PdfDocument _document;

  @override
  int get pageCount => _document.pages.length;

  @override
  Future<PdfFigurePage> loadPage(int pageIndex) async {
    final page = _document.pages[pageIndex];
    final text = await page.loadStructuredText();
    // page.width/height and page.render() are in DISPLAY space; text bounds
    // are not (see [rotateRectToDisplaySpace]). Normalize on the way in so
    // every consumer downstream — width heuristics, the region rect, the
    // crop transform, the stored chunk meta — shares one frame, the same one
    // Step 12's OCR bounds already use.
    final rotation = page.rotation.index;
    final fragments = <PageTextItem>[
      for (final fragment in text.fragments)
        if (fragment.text.trim().isNotEmpty && fragment.bounds.isNotEmpty)
          PageTextItem(
            text: fragment.text,
            rect: rotateRectToDisplaySpace(
              (
                left: fragment.bounds.left,
                top: fragment.bounds.top,
                right: fragment.bounds.right,
                bottom: fragment.bounds.bottom,
              ),
              rotation: rotation,
              displayWidthPts: page.width,
              displayHeightPts: page.height,
            ),
          ),
    ];
    return PdfFigurePage(
      pageWidthPts: page.width,
      pageHeightPts: page.height,
      items: mergeFragmentsIntoLines(fragments, pageHeightPts: page.height),
    );
  }

  @override
  Future<Uint8List?> renderRegionPng(
    int pageIndex, {
    required int x,
    required int y,
    required int width,
    required int height,
    required double fullWidth,
    required double fullHeight,
  }) async {
    final page = _document.pages[pageIndex];
    final pdfImage = await page.render(
      x: x,
      y: y,
      width: width,
      height: height,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
    );
    if (pdfImage == null) return null;
    try {
      final uiImage = await pdfImage.createImage();
      try {
        final byteData = await uiImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (byteData == null) return null;
        // Copy: the ui.Image's backing buffer is disposed below.
        return Uint8List.fromList(byteData.buffer.asUint8List());
      } finally {
        uiImage.dispose();
      }
    } finally {
      pdfImage.dispose();
    }
  }

  @override
  Future<void> dispose() => _document.dispose();
}

/// Default opener: pdfrx `PdfDocument.openFile` (same open/dispose + cache
/// guard pattern as the pdf_text and ocr openers).
Future<PdfFigureSource> openPdfrxFigureSource(String path) async {
  Pdfrx.getCacheDirectory ??= () async {
    final tempDir = await getTemporaryDirectory();
    return tempDir.path;
  };
  final document = await PdfDocument.openFile(path);
  return _PdfrxFigureSource(document);
}

// ─── Derived assets ──────────────────────────────────────────────────────────

/// A rendered + saved figure crop.
class DerivedFigure {
  const DerivedFigure({
    required this.region,
    required this.fileName,
    required this.assetRelativePath,
    required this.contentHash,
  });

  final FigureRegion region;

  /// `<attachmentId>_p<N>_f<i>.png`.
  final String fileName;

  /// Path relative to the app documents dir (`attachments/derived/<file>`),
  /// resolvable via `FileUtils.getFullFilePath(path, true)`.
  final String assetRelativePath;

  /// sha256 hex of the PNG bytes — the content-addressed half of §4.2's
  /// figureId, so a stale URI can never silently resolve to a different
  /// region after re-extraction.
  ///
  /// Determinism caveat: re-rendering the same region from the same PDF
  /// reproduces this hash only WITHIN one pdfrx/pdfium version. A renderer
  /// upgrade can re-encode identical-looking pixels into different PNG
  /// bytes, so after a dependency bump a freshly regenerated asset may not
  /// match the stored figureId. Treat a mismatch as "asset regenerated" and
  /// re-key it; it is a cache/identity token, not a cross-version proof
  /// that the crop is the right one.
  final String contentHash;
}

/// Default location of derived figure assets: `attachments/derived/` inside
/// the app documents dir (created on demand). Derived assets are regenerable
/// and must be excluded from export/backup (plan §4.1 — the exclusion lands
/// with the indexer wiring).
Future<Directory> defaultDerivedFigureDirectory() async {
  final attachments = await FileUtils.getPrivateStorageDirectory();
  final derived = Directory('${attachments.path}/derived');
  if (!await derived.exists()) {
    await derived.create(recursive: true);
  }
  return derived;
}

// ─── Extractor ───────────────────────────────────────────────────────────────

/// Outcome of one figure-extraction attempt (mirrors ExtractionStatus).
enum FigureExtractionStatus {
  /// Extraction ran; [FigureExtractionResult.figures] holds the rendered
  /// regions (possibly empty when no region cleared the threshold).
  extracted,

  /// Attachment is not a PDF — the figure stage's PDF path does not apply
  /// (raster image attachments become figure chunks directly in Step 14,
  /// with no region extraction).
  skippedNotPdf,

  /// The pause/cancel callback fired between pages; partial output is
  /// discarded (already-written PNG files are regenerable and simply get
  /// overwritten on the re-run).
  aborted,

  /// The file is missing or unreadable.
  failed,
}

class FigureExtractionResult {
  const FigureExtractionResult._(
    this.status, {
    this.figures = const [],
    this.pageCount,
    this.errorMessage,
    this.failedPages = 0,
    this.attemptedRenders = 0,
    this.failedRenders = 0,
  });

  final FigureExtractionStatus status;

  /// Rendered + saved figures (only for [FigureExtractionStatus.extracted]).
  final List<DerivedFigure> figures;

  /// Page count of the document, when it was opened.
  final int? pageCount;

  final String? errorMessage;

  /// Pages whose text/geometry could not be loaded at all. A run where every
  /// page failed reports [FigureExtractionStatus.failed], not an empty
  /// `extracted` — otherwise Step 14 records "done" for a document it never
  /// managed to read and never retries it.
  final int failedPages;

  /// Regions that reached the renderer, and how many of those failed to
  /// render or save (a full or unwritable disk fails EVERY one of them).
  final int attemptedRenders;
  final int failedRenders;
}

/// Extracts figure/table regions from PDF attachments and renders them as
/// high-res derived PNGs.
///
/// Deliberately database-free: policy gates (per-attachment config, note
/// exclusion, page cap) and chunk persistence belong to the indexer stage
/// (Step 14), which also supplies the stored OCR bounds via
/// [ocrItemsFromChunkMeta]. This class owns geometry, rendering, and derived
/// files only.
class FigureRegionExtractor {
  FigureRegionExtractor({
    PdfFigureSourceOpener? opener,
    Future<Directory> Function()? derivedDirLoader,
    this.minConfidence = kDefaultMinConfidence,
  }) : _opener = opener ?? openPdfrxFigureSource,
       _derivedDirLoader = derivedDirLoader ?? defaultDerivedFigureDirectory;

  /// Render scale for figure crops: 3× the page's PDF point size (plan §4.1
  /// "2–3×"; a column-wide figure on US Letter becomes ~1400 px wide —
  /// high-res enough for inline chat display and multimodal embedding).
  /// Degraded per region by [effectiveRenderScale] when 3× would blow the
  /// raster budget.
  static const double kFigureRenderScale = 3.0;

  /// Raster budget for ONE region crop. pdfium allocates
  /// `width × height × 4` bytes of RGBA up front inside the render worker,
  /// so an unbounded scale is an OOM kill, not a catchable exception: a
  /// full-page region on an A0 engineering drawing (2384×3370 pt) at 3×
  /// would ask for 7152×10110 px ≈ 289 MB. 8 MP caps that allocation at
  /// ~32 MB while leaving a full US-Letter page at the nominal 3×
  /// (1836×2376 = 4.4 MP); the per-side cap keeps extreme aspect ratios
  /// (a full-width banner strip) from producing a single enormous axis.
  static const int kMaxRenderSidePx = 4000;
  static const int kMaxRenderPixels = 8000000;

  /// Largest scale at/below [kFigureRenderScale] whose raster for [rect]
  /// fits the budget above. Degrades resolution rather than failing — a
  /// downscaled figure is still a figure.
  static double effectiveRenderScale(PdfRect rect) {
    final w = rect.right - rect.left;
    final h = rect.top - rect.bottom;
    if (w <= 0 || h <= 0) return kFigureRenderScale;
    var scale = kFigureRenderScale;
    scale = math.min(scale, kMaxRenderSidePx / math.max(w, h));
    scale = math.min(scale, math.sqrt(kMaxRenderPixels / (w * h)));
    return scale > 0 ? scale : kFigureRenderScale;
  }

  final PdfFigureSourceOpener _opener;
  final Future<Directory> Function() _derivedDirLoader;

  /// Regions below this confidence are dropped. The default
  /// ([kDefaultMinConfidence]) admits captioned regions only; lowering it to
  /// [kWhitespaceConfidence] or less also admits caption-less whitespace
  /// candidates.
  final double minConfidence;

  /// Derived asset naming: `<attachmentId>_p<page>_f<index>.png` with
  /// [figureIndex] the 0-based index of the region on its page — stable
  /// under re-extraction as long as the page's regions are unchanged (and
  /// content-addressed via [DerivedFigure.contentHash] when they are not).
  static String derivedFigureFileName(
    String attachmentId,
    int page,
    int figureIndex,
  ) => '${attachmentId}_p${page}_f$figureIndex.png';

  /// Detects figure/table regions in the PDF at [pdfPath] WITHOUT rendering
  /// (geometry only — used by tests/spike and by callers that only need
  /// candidate rects). [ocrItemsByPage] carries Step 12's stored OCR block
  /// bounds, keyed by 1-based page.
  ///
  /// A page that fails to load is skipped (one broken page must not lose the
  /// document); a document that fails to OPEN throws, since this method has
  /// no error channel — callers that need one use [extractFigures].
  Future<List<FigureRegion>> detectRegions(
    String pdfPath, {
    Map<int, List<PageTextItem>> ocrItemsByPage = const {},
  }) async {
    final source = await _opener(pdfPath);
    try {
      final regions = <FigureRegion>[];
      for (var i = 0; i < source.pageCount; i++) {
        final PdfFigurePage page;
        try {
          page = await source.loadPage(i);
        } catch (e) {
          LoggerService.warning(
            '[FigureRegionExtractor] detectRegions: page ${i + 1} of '
            '$pdfPath failed to load: $e',
          );
          continue;
        }
        regions.addAll(
          inferFigureRegions(
            page: i + 1,
            pageWidthPts: page.pageWidthPts,
            pageHeightPts: page.pageHeightPts,
            items: [...page.items, ...?ocrItemsByPage[i + 1]],
            minConfidence: minConfidence,
          ),
        );
      }
      return regions;
    } finally {
      await source.dispose();
    }
  }

  /// Full pipeline for one PDF attachment: detect regions on every page,
  /// render each at [kFigureRenderScale], save under `attachments/derived/`.
  ///
  /// [ocrItemsByPage]: Step 12's stored OCR block bounds by 1-based page
  /// (from the attachment's `attachment_ocr` chunk meta via
  /// [ocrItemsFromChunkMeta]) — the caller (Step 14) supplies them so
  /// scanned pages contribute caption anchors and text obstacles.
  ///
  /// [shouldAbort] is consulted before each page (indexer pause semantics);
  /// an aborted run discards its partial result list (any PNGs already
  /// written are regenerable and are overwritten by the re-run).
  ///
  /// Status is [FigureExtractionStatus.failed] — not an empty `extracted` —
  /// when EVERY page failed to load or EVERY region failed to render/save,
  /// so a document pdfium cannot read and a full/read-only disk both stay
  /// retryable instead of being frozen as "done, no figures".
  Future<FigureExtractionResult> extractFigures(
    Attachment attachment, {
    Map<int, List<PageTextItem>> ocrItemsByPage = const {},
    bool Function()? shouldAbort,
  }) async {
    if (!AttachmentTextExtractor.isPdfAttachment(attachment)) {
      return const FigureExtractionResult._(
        FigureExtractionStatus.skippedNotPdf,
      );
    }
    final path = await attachment.getAbsolutePath();
    if (!await File(path).exists()) {
      return FigureExtractionResult._(
        FigureExtractionStatus.failed,
        errorMessage: 'File not found: ${attachment.filePath}',
      );
    }

    final PdfFigureSource source;
    try {
      source = await _opener(path);
    } catch (e) {
      return FigureExtractionResult._(
        FigureExtractionStatus.failed,
        errorMessage: 'Failed to open PDF: $e',
      );
    }
    try {
      final pageCount = source.pageCount;
      final figures = <DerivedFigure>[];
      var failedPages = 0;
      var attemptedRenders = 0;
      var failedRenders = 0;
      String? firstError;
      for (var i = 0; i < pageCount; i++) {
        if (shouldAbort?.call() ?? false) {
          return FigureExtractionResult._(
            FigureExtractionStatus.aborted,
            pageCount: pageCount,
          );
        }
        final PdfFigurePage page;
        try {
          page = await source.loadPage(i);
        } catch (e) {
          // One broken page must not lose the rest of the document — but it
          // IS counted, so an entirely unreadable document does not pass as
          // "no figures here".
          failedPages++;
          firstError ??= '$e';
          LoggerService.warning(
            '[FigureRegionExtractor] Page ${i + 1} of '
            '${attachment.fileName} failed to load: $e',
          );
          continue;
        }
        final regions = inferFigureRegions(
          page: i + 1,
          pageWidthPts: page.pageWidthPts,
          pageHeightPts: page.pageHeightPts,
          items: [...page.items, ...?ocrItemsByPage[i + 1]],
          minConfidence: minConfidence,
        );
        for (var f = 0; f < regions.length; f++) {
          try {
            final rendered = await _renderAndSave(
              source,
              attachment.id,
              regions[f],
              figureIndex: f,
              pageWidthPts: page.pageWidthPts,
              pageHeightPts: page.pageHeightPts,
            );
            if (rendered.figure != null) {
              figures.add(rendered.figure!);
            }
            if (rendered.attempted) attemptedRenders++;
            if (rendered.failed) failedRenders++;
          } catch (e) {
            attemptedRenders++;
            failedRenders++;
            firstError ??= '$e';
            LoggerService.warning(
              '[FigureRegionExtractor] Region $f on page ${i + 1} of '
              '${attachment.fileName} failed to render: $e',
            );
          }
        }
        // Reap derived assets of regions this page no longer has: a page
        // that used to yield 3 figures and now yields 1 would otherwise
        // leave _p<N>_f1/_f2.png on disk forever.
        await _reapStaleDerived(attachment.id, i + 1, regions.length);
      }
      if (pageCount > 0 && failedPages == pageCount) {
        return FigureExtractionResult._(
          FigureExtractionStatus.failed,
          pageCount: pageCount,
          failedPages: failedPages,
          errorMessage:
              'All $pageCount pages failed to load; first: $firstError',
        );
      }
      if (attemptedRenders > 0 && failedRenders == attemptedRenders) {
        return FigureExtractionResult._(
          FigureExtractionStatus.failed,
          pageCount: pageCount,
          failedPages: failedPages,
          attemptedRenders: attemptedRenders,
          failedRenders: failedRenders,
          errorMessage:
              'All $attemptedRenders figure renders failed'
              '${firstError == null ? '' : '; first: $firstError'}',
        );
      }
      return FigureExtractionResult._(
        FigureExtractionStatus.extracted,
        figures: figures,
        pageCount: pageCount,
        failedPages: failedPages,
        attemptedRenders: attemptedRenders,
        failedRenders: failedRenders,
      );
    } catch (e) {
      return FigureExtractionResult._(
        FigureExtractionStatus.failed,
        errorMessage: 'Figure extraction failed: $e',
      );
    } finally {
      await source.dispose();
    }
  }

  /// Deletes `<attachmentId>_p<page>_f<k>.png` for every k at/above
  /// [keptCount] until a gap — the page's region count only ever shrinks by
  /// dropping trailing indexes, so the first missing index ends the run.
  Future<void> _reapStaleDerived(
    String attachmentId,
    int page,
    int keptCount,
  ) async {
    try {
      final dir = await _derivedDirLoader();
      for (var k = keptCount; k < keptCount + 64; k++) {
        final file = File(
          '${dir.path}/${derivedFigureFileName(attachmentId, page, k)}',
        );
        if (!await file.exists()) break;
        await file.delete();
      }
    } catch (e) {
      // Reaping is housekeeping: never fail an extraction over it.
      LoggerService.info(
        '[FigureRegionExtractor] Could not reap stale derived assets for '
        '$attachmentId p$page: $e',
      );
    }
  }

  /// Re-renders ONE region on demand (Step 16's missing-asset path: the
  /// region comes from the figure chunk's stored meta via
  /// [FigureRegion.fromJson]). Returns null — never throws — when the PDF
  /// cannot be opened, the page is gone, the stored rect no longer fits the
  /// page, or rendering fails; on success the derived PNG is (re)written.
  ///
  /// The stored rect IS re-validated against the freshly loaded page size:
  /// if the file at [pdfPath] was replaced with a differently-sized
  /// document, the old rect would still crop "successfully" and hand the
  /// user a plausible-looking crop of the wrong area.
  ///
  /// Note on [DerivedFigure.contentHash]: regenerating the same region from
  /// the same PDF reproduces the same hash only WITHIN one pdfrx/pdfium
  /// version — a renderer upgrade can re-encode identical pixels into
  /// different PNG bytes. Callers must therefore treat a hash mismatch after
  /// a dependency bump as "asset regenerated", not "wrong region"; the hash
  /// is a cache/identity key, not a correctness proof across versions.
  Future<DerivedFigure?> renderRegion(
    String pdfPath, {
    required String attachmentId,
    required FigureRegion region,
    required int figureIndex,
  }) async {
    PdfFigureSource? source;
    try {
      source = await _opener(pdfPath);
      if (region.page < 1 || region.page > source.pageCount) return null;
      final page = await source.loadPage(region.page - 1);
      const tolerance = 1.0;
      final r = region.rectPdf;
      if (r.left < -tolerance ||
          r.bottom < -tolerance ||
          r.right > page.pageWidthPts + tolerance ||
          r.top > page.pageHeightPts + tolerance) {
        LoggerService.warning(
          '[FigureRegionExtractor] Stored rect $r does not fit page '
          '${region.page} of $pdfPath '
          '(${page.pageWidthPts}x${page.pageHeightPts}) — the file was '
          'likely replaced; refusing to render a shifted crop',
        );
        return null;
      }
      final clamped = FigureRegion(
        page: region.page,
        rectPdf: (
          left: r.left.clamp(0.0, page.pageWidthPts),
          top: r.top.clamp(0.0, page.pageHeightPts),
          right: r.right.clamp(0.0, page.pageWidthPts),
          bottom: r.bottom.clamp(0.0, page.pageHeightPts),
        ),
        caption: region.caption,
        confidence: region.confidence,
        source: region.source,
      );
      final rendered = await _renderAndSave(
        source,
        attachmentId,
        clamped,
        figureIndex: figureIndex,
        pageWidthPts: page.pageWidthPts,
        pageHeightPts: page.pageHeightPts,
      );
      return rendered.figure;
    } catch (e) {
      LoggerService.warning(
        '[FigureRegionExtractor] renderRegion failed for $pdfPath '
        'p${region.page} f$figureIndex: $e',
      );
      return null;
    } finally {
      await source?.dispose();
    }
  }

  /// Renders one region at [effectiveRenderScale] and writes the derived PNG.
  ///
  /// Coordinate transform: the shared §4.1 forward transform
  /// ([pdfRectToRasterRect] — PDF y-up points → raster y-down pixels within
  /// the virtual `fullWidth × fullHeight` page), then rounded to whole
  /// pixels and clamped inside the page raster.
  ///
  /// [_RenderOutcome.attempted] distinguishes "this rect was degenerate, no
  /// render was ever asked for" from "the renderer/disk said no", which is
  /// what lets [extractFigures] tell an empty document from a broken one.
  Future<_RenderOutcome> _renderAndSave(
    PdfFigureSource source,
    String attachmentId,
    FigureRegion region, {
    required int figureIndex,
    required double pageWidthPts,
    required double pageHeightPts,
  }) async {
    final scale = effectiveRenderScale(region.rectPdf);
    final fullWidth = pageWidthPts * scale;
    final fullHeight = pageHeightPts * scale;
    final raster = pdfRectToRasterRect(
      region.rectPdf,
      renderScale: scale,
      pageHeightPts: pageHeightPts,
    );
    final x = raster.left
        .floor()
        .clamp(0, math.max(0, fullWidth.floor()))
        .toInt();
    final y = raster.top
        .floor()
        .clamp(0, math.max(0, fullHeight.floor()))
        .toInt();
    final width = math.min(raster.width.round(), fullWidth.round() - x);
    final height = math.min(raster.height.round(), fullHeight.round() - y);
    if (width <= 0 || height <= 0) {
      return const _RenderOutcome(attempted: false, failed: false);
    }

    final pngBytes = await source.renderRegionPng(
      region.page - 1,
      x: x,
      y: y,
      width: width,
      height: height,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
    );
    if (pngBytes == null || pngBytes.isEmpty) {
      return const _RenderOutcome(attempted: true, failed: true);
    }

    final fileName = derivedFigureFileName(
      attachmentId,
      region.page,
      figureIndex,
    );
    final dir = await _derivedDirLoader();
    await File('${dir.path}/$fileName').writeAsBytes(pngBytes);
    return _RenderOutcome(
      attempted: true,
      failed: false,
      figure: DerivedFigure(
        region: region,
        fileName: fileName,
        assetRelativePath: 'attachments/derived/$fileName',
        contentHash: sha256.convert(pngBytes).toString(),
      ),
    );
  }
}

/// Result of one [FigureRegionExtractor._renderAndSave] call.
class _RenderOutcome {
  const _RenderOutcome({
    required this.attempted,
    required this.failed,
    this.figure,
  });

  /// Whether the renderer was actually invoked (false for degenerate rects).
  final bool attempted;

  /// Whether the render or the write failed.
  final bool failed;

  final DerivedFigure? figure;
}
