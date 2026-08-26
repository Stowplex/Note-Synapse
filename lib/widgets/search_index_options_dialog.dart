// Step 21 — per-attachment search-index toggles (plan §1.3).
//
// One dialog, reached from the attachment context menu and from the PDF
// viewer's overflow menu, writing `attachment.metadata.searchIndex`
// ([AttachmentSearchIndexConfig]). Pure props + an [onSave] callback: the two
// host screens construct `DatabaseService()` directly as a field, so the
// persistence they do cannot be intercepted in a test — keeping the dialog
// free of services is what makes the policy UI testable at all. The pieces
// the hosts share and MUST get right (the metadata read-modify-write, the
// exclusion confirmation) live here for the same reason.
//
// Only the stages that APPLY to the file are offered. A switch that silently
// does nothing is worse than its absence, so the file type decides
// ([searchIndexFileKindFor]) and the inapplicable cases get a sentence
// explaining what the indexer does with them instead.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/attachment.dart';
import '../services/search/attachment_ocr_extractor.dart';

/// Which indexing stages an attachment's file type can feed.
///
/// Mirrors the pipeline's own eligibility predicates
/// (`AttachmentTextExtractor.isPdfAttachment`,
/// [AttachmentOcrExtractor.isRasterImageAttachment],
/// `NoteIndexService.isSvgAttachment`) so the dialog can never offer a toggle
/// no stage reads.
enum SearchIndexFileKind {
  /// Text layer, on-device derivation (OCR + figure crops) and embedding all
  /// apply; the page cap can bind.
  pdf,

  /// png/jpg/jpeg/webp: no text layer to extract; OCR/figure and embedding
  /// apply.
  rasterImage,

  /// Nothing is extracted from the file itself — but the `figure` chunk built
  /// from its NAME and the note's alt text is still sent to the embedding
  /// provider, so embedding (and only embedding) applies.
  svg,

  /// Not content-indexed — only reachable through the note it is attached to.
  other,
}

/// The [SearchIndexFileKind] of [fileName] (extension only, case-insensitive).
SearchIndexFileKind searchIndexFileKindFor(String fileName) {
  final name = fileName.toLowerCase();
  if (name.endsWith('.pdf')) return SearchIndexFileKind.pdf;
  // kRasterImageExtensions is THE list the whole pipeline agrees on; reusing
  // it keeps the dialog from offering an OCR toggle for a file the ocr stage
  // would refuse (or hiding one it would honor).
  if (AttachmentOcrExtractor.isRasterImageFileName(name)) {
    return SearchIndexFileKind.rasterImage;
  }
  if (name.endsWith('.svg')) return SearchIndexFileKind.svg;
  return SearchIndexFileKind.other;
}

/// Whether [config] differs from the defaults in a way THIS file type can
/// show — what the menus paint as "customized".
///
/// Deliberately kind-aware: a flag no stage reads for this kind (a `.txt`
/// carrying any config at all, a raster carrying `text:'on'` because it was
/// renamed away from `.pdf`) is not something the user can inspect or revert
/// here, so labelling the entry "customized" would point at a dialog that
/// shows nothing of the sort.
bool searchIndexConfigIsCustomized(
  String fileName,
  AttachmentSearchIndexConfig config,
) {
  switch (searchIndexFileKindFor(fileName)) {
    case SearchIndexFileKind.pdf:
      return config.text != 'auto' || !config.ocr || !config.embed;
    case SearchIndexFileKind.rasterImage:
      return !config.ocr || !config.embed;
    case SearchIndexFileKind.svg:
      return !config.embed;
    case SearchIndexFileKind.other:
      return false;
  }
}

/// The metadata map to persist for [config]: a read-modify-write of the
/// `searchIndex` key over the attachment's STORED metadata, re-read through
/// [reload] (`DatabaseService.getAttachmentById`) instead of merged onto the
/// caller's cached [attachment].
///
/// The screens' caches go stale while a pushed route is on top of them — the
/// immersive viewer writes `bookmarks`, NoteMarkerService writes `markers`,
/// the AI-context dialog writes `aiContextConfig` — and merging onto a
/// snapshot taken before any of that silently DELETES those keys on save.
/// [attachment] is the fallback for a row that has since disappeared.
Future<Map<String, dynamic>> buildSearchIndexMetadata({
  required Attachment attachment,
  required AttachmentSearchIndexConfig config,
  required Future<Attachment?> Function(String attachmentId) reload,
}) async {
  final stored = await reload(attachment.id) ?? attachment;
  final metadata = Map<String, dynamic>.from(stored.metadata ?? {});
  metadata['searchIndex'] = config.toJson();
  return metadata;
}

/// Confirmation for `notes.metadata.searchIndex.exclude` (plan §1.3).
///
/// Excluding is destructive — it purges the note's chunks and everything
/// derived from its attachments — so it is gated on an explicit yes: anything
/// else (Cancel, a tap outside, a back gesture) returns false.
Future<bool> showSearchExcludeNoteConfirmation(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.searchExcludeNoteConfirmTitle),
      content: Text(l10n.searchExcludeNoteConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.searchExcludeNoteConfirm),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Per-attachment search indexing policy editor.
class SearchIndexOptionsDialog extends StatefulWidget {
  const SearchIndexOptionsDialog({
    super.key,
    required this.fileName,
    required this.config,
    required this.onSave,
    this.pageCount,
    this.pageCap,
  });

  /// File name of the attachment — decides which toggles apply, and is shown
  /// in the dialog (the PDF viewer's menu has no other affordance naming the
  /// file the entry acts on).
  final String fileName;

  /// Policy as stored today.
  final AttachmentSearchIndexConfig config;

  /// Called with the new policy when Save is pressed. Never called on Cancel.
  ///
  /// AWAITED before the dialog closes: the hosts re-read the attachment after
  /// the save to relabel their menu entry, and a fire-and-forget callback
  /// lets that read queue on sqflite ahead of the UPDATE it is meant to
  /// observe (`updateAttachmentMetadata` does a SELECT first), leaving the
  /// entry showing stale policy after a save that in fact succeeded.
  final Future<void> Function(AttachmentSearchIndexConfig) onSave;

  /// Page count of the PDF, when the caller knows it.
  final int? pageCount;

  /// Current `searchIndexPdfPageCap`, when the caller knows it.
  final int? pageCap;

  @override
  State<SearchIndexOptionsDialog> createState() =>
      _SearchIndexOptionsDialogState();
}

class _SearchIndexOptionsDialogState extends State<SearchIndexOptionsDialog> {
  /// 'auto' | 'on' | 'off' — see [AttachmentSearchIndexConfig.text].
  late String _text;

  /// Which enabled value the text switch returns to when it is switched back
  /// on. Seeded from the stored value so an explicit `'on'` survives an
  /// off/on round trip inside the dialog instead of silently decaying to
  /// 'auto' (which would re-impose the page cap the user opted out of).
  late String _lastEnabledText;

  /// Whether the policy arrived as an explicit `'on'`. Never cleared, because
  /// it answers "was the cap row ever relevant to this file", which a later
  /// toggle cannot change — see [_showPageCapRow].
  late bool _hadExplicitOn;

  late bool _ocr;
  late bool _embed;

  /// A save is in flight (the callback is awaited before the pop): the
  /// buttons go inert so a second tap cannot fire a second write.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _text = widget.config.text;
    _lastEnabledText = _text == 'off' ? 'auto' : _text;
    _hadExplicitOn = _text == 'on';
    _ocr = widget.config.ocr;
    _embed = widget.config.embed;
  }

  SearchIndexFileKind get _kind => searchIndexFileKindFor(widget.fileName);

  /// PDF longer than the current cap: without an explicit opt-in the text and
  /// ocr stages skip it, so the dialog has to say so rather than leave the
  /// text switch looking effective.
  bool get _exceedsPageCap {
    final pages = widget.pageCount;
    final cap = widget.pageCap;
    return pages != null && cap != null && pages > cap;
  }

  /// The cap is known but the page count is not (opening the document
  /// failed). The cap cannot be ruled OUT, so the opt-in has to stay
  /// reachable — otherwise a genuinely over-cap PDF whose count could not be
  /// read can never be opted past it from here.
  bool get _pageCountUnknown =>
      widget.pageCount == null && widget.pageCap != null;

  /// The cap row is shown when the cap BINDS (or might), and also whenever the
  /// policy is — or arrived as — an explicit `'on'`: an existing opt-in must
  /// be visible and reversible even if the file has since shrunk or the cap
  /// was raised, and the row must not disappear mid-session just because the
  /// opt-in was toggled off.
  bool get _showPageCapRow =>
      _kind == SearchIndexFileKind.pdf &&
      (_exceedsPageCap || _pageCountUnknown || _text == 'on' || _hadExplicitOn);

  /// Whether this file type has anything to save (everything but [other]).
  bool get _hasToggles => _kind != SearchIndexFileKind.other;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.searchIndexOptions, style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(
                l10n.searchIndexOptionsSubtitle(widget.fileName),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildBody(l10n, theme),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: Text(_hasToggles ? l10n.cancel : l10n.close),
                  ),
                  if (_hasToggles)
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(l10n.save),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(
        AttachmentSearchIndexConfig(text: _text, ocr: _ocr, embed: _embed),
      );
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  List<Widget> _buildBody(AppLocalizations l10n, ThemeData theme) {
    switch (_kind) {
      case SearchIndexFileKind.other:
        return [_explanation(theme, l10n.searchIndexNotIndexable)];
      case SearchIndexFileKind.svg:
        // No text layer and nothing derived on this device — but the chunk
        // built from the file name and the note's alt text IS embedded (as
        // text: SVG has no image input), and this switch is the only
        // per-attachment control over that upload.
        return [
          _explanation(theme, l10n.searchIndexSvgOnly),
          _embedToggle(l10n),
          _warning(theme, l10n.searchIndexEmbedPurgeWarning),
        ];
      case SearchIndexFileKind.pdf:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.searchIndexExtractText),
            subtitle: Text(l10n.searchIndexExtractTextSubtitle),
            value: _text != 'off',
            onChanged: (value) => setState(() {
              _text = value ? _lastEnabledText : 'off';
            }),
          ),
          if (_showPageCapRow)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(l10n.searchIndexAnywayOverCap),
                subtitle: Text(_pageCapSubtitle(l10n)),
                value: _text == 'on',
                // Meaningless while extraction is off entirely — shown, so
                // the reason the PDF is skipped stays visible, but inert.
                onChanged: _text == 'off'
                    ? null
                    : (value) => setState(() {
                        _text = value ? 'on' : 'auto';
                        _lastEnabledText = _text;
                      }),
              ),
            ),
          ..._derivationToggles(l10n),
          _warning(theme, l10n.searchIndexPurgeWarning),
        ];
      case SearchIndexFileKind.rasterImage:
        return [
          ..._derivationToggles(l10n),
          _warning(theme, l10n.searchIndexPurgeWarning),
        ];
    }
  }

  /// The two stages every file with extractable content shares: on-device
  /// derivation and embedding.
  List<Widget> _derivationToggles(AppLocalizations l10n) {
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        // Deliberately NOT labelled "OCR": metadata.searchIndex.ocr is this
        // file's on-device-derivation consent — it gates the figures stage
        // (and its rendered crops) as well as text recognition, so an
        // OCR-only label would make the crop purge read as a bug.
        title: Text(l10n.searchIndexDeriveOnDevice),
        subtitle: Text(l10n.searchIndexDeriveOnDeviceSubtitle),
        value: _ocr,
        onChanged: (value) => setState(() => _ocr = value),
      ),
      _embedToggle(l10n),
    ];
  }

  Widget _embedToggle(AppLocalizations l10n) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.searchIndexEmbed),
      // The subtitle names IMAGES as well as text on purpose: an
      // image-capable provider receives a figure chunk as a picture — the
      // crops rendered from a PDF, or a raster attachment's own file — and
      // this row sits directly under one that ends "Nothing is uploaded."
      subtitle: Text(l10n.searchIndexEmbedSubtitle),
      value: _embed,
      onChanged: (value) => setState(() => _embed = value),
    );
  }

  String _pageCapSubtitle(AppLocalizations l10n) {
    final pages = widget.pageCount;
    final cap = widget.pageCap;
    if (pages != null && cap != null) {
      return l10n.searchIndexOverCapSubtitle(pages, cap);
    }
    return l10n.searchIndexAnywaySubtitle;
  }

  Widget _explanation(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Purge-on-toggle is what the indexer actually does — turning a stage off
  /// deletes what it produced: the chunks, the rendered crops, and (since the
  /// embed stage purges policy violations at the head of every pass) the
  /// stored vectors.
  Widget _warning(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
