import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/note_source.dart';
import '../utils/date_utils.dart';

/// The "clipped from" block between a note's title and its body.
///
/// The source is side information, so the card is collapsed by default
/// within a hard three-line budget: the first source's title, its site and
/// clip time, and `+N more` when there are other sources (about 56 logical
/// pixels for one source, under 90 for several). Expanding — the chevron or
/// `+N more` — lists every source with its [NoteSource.compactUrl] on one
/// ellipsized line. A URL never wraps and the collapsed state shows none at
/// all; [onOpen] and [onCopy] receive the source so they can use its full
/// [NoteSource.url].
///
/// Gestures: tap the title or meta line to open; long-press a row for the
/// copy / edit / remove menu (also while collapsed); chevron or `+N more` to
/// expand and `Show less` to collapse. Expansion is widget state only, so
/// every visit starts collapsed.
class NoteSourceCard extends StatefulWidget {
  const NoteSourceCard({
    super.key,
    required this.sources,
    required this.onOpen,
    required this.onCopy,
    this.onEdit,
    this.onRemove,
    this.compact = false,
  });

  final List<NoteSource> sources;

  /// Tap on a row's title or meta line.
  final void Function(NoteSource source) onOpen;

  /// The menu's copy entry, always present.
  final void Function(NoteSource source) onCopy;

  /// The menu's edit / remove entries, shown only when given.
  final void Function(NoteSource source)? onEdit;
  final void Function(NoteSource source)? onRemove;

  /// Open / copy only: expanded rows get no trailing `⋯` button. The editing
  /// view uses this; the long-press menu still offers whichever callbacks
  /// are given.
  final bool compact;

  @override
  State<NoteSourceCard> createState() => _NoteSourceCardState();
}

enum _SourceAction { copy, edit, remove }

class _NoteSourceCardState extends State<NoteSourceCard> {
  static const double _edgeInset = 12;
  static const double _iconSize = 18;
  static const double _iconGap = 8;

  /// Left inset of the text column, so the link strips align with the titles.
  static const double _textInset = _edgeInset + _iconSize + _iconGap;

  /// Minimum size of every tap target, so the three gestures do not fight
  /// on a phone.
  static const double _tapTarget = 40;

  bool _expanded = false;

  /// Global position of the last pointer-down on a row, so a long-press
  /// menu opens under the finger. Cleared once used.
  Offset? _pointerDown;

  bool get _multiple => widget.sources.length > 1;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  void didUpdateWidget(NoteSourceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A single source has no expand control, so a list that shrank to one
    // entry forgets its expansion: a second source added later must not
    // bring the card back expanded.
    if (widget.sources.length <= 1) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sources.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    // A single source has no expand control, so it is always collapsed (and
    // a list that shrank to one entry while expanded collapses with it).
    final expanded = _expanded && _multiple;
    return SelectionContainer.disabled(
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: expanded ? _buildExpanded(l10n) : _buildCollapsed(l10n),
        ),
      ),
    );
  }

  // ── Layouts ──────────────────────────────────────────────────────────────

  /// Line 1: first title. Line 2: site · clip time. Line 3, only with more
  /// than one source: `+N more`, which is also the expand control.
  Widget _buildCollapsed(AppLocalizations l10n) {
    final first = widget.sources.first;
    final others = widget.sources.length - 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _row(
                first,
                l10n,
                // The bottom edge belongs to the `+N more` strip when shown.
                padding: EdgeInsets.fromLTRB(
                  _edgeInset,
                  8,
                  8,
                  others > 0 ? 0 : 8,
                ),
                titleLines: 1,
                showUrl: false,
              ),
            ),
            if (others > 0) ...[
              _iconButton(Icons.expand_more, l10n.expand, _toggle),
              const SizedBox(width: 4),
            ],
          ],
        ),
        if (others > 0)
          _linkStrip(
            l10n.moreSources(others),
            _toggle,
            const EdgeInsets.fromLTRB(_textInset, 6, _edgeInset, 8),
          ),
      ],
    );
  }

  /// Every source: title on up to two lines, meta line, compact URL line and
  /// (unless [NoteSourceCard.compact]) a trailing `⋯`; `Show less` last.
  Widget _buildExpanded(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final menuTooltip = MaterialLocalizations.of(context).showMenuTooltip;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, source) in widget.sources.indexed) ...[
          if (index > 0)
            Divider(
              height: 1,
              indent: _textInset,
              color: theme.colorScheme.outlineVariant,
            ),
          Row(
            children: [
              Expanded(
                child: _row(
                  source,
                  l10n,
                  padding: const EdgeInsets.fromLTRB(_edgeInset, 8, 8, 8),
                  titleLines: 2,
                  showUrl: true,
                ),
              ),
              if (!widget.compact) ...[
                Builder(
                  builder: (buttonContext) => _iconButton(
                    Icons.more_horiz,
                    menuTooltip,
                    () => _showActions(buttonContext, source),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
        ],
        _linkStrip(
          l10n.showLess,
          _toggle,
          const EdgeInsets.fromLTRB(_textInset, 6, _edgeInset, 8),
        ),
      ],
    );
  }

  // ── Pieces ───────────────────────────────────────────────────────────────

  /// One source's tap area: leading icon, title, meta line and, when
  /// [showUrl], the compact URL. Tap opens, long-press shows the menu.
  Widget _row(
    NoteSource source,
    AppLocalizations l10n, {
    required EdgeInsets padding,
    required int titleLines,
    required bool showUrl,
  }) {
    final theme = Theme.of(context);
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final meta = _metaLine(source, l10n);
    return Builder(
      builder: (rowContext) => Semantics(
        button: true,
        label: _semanticsLabel(source, l10n),
        hint: l10n.openOriginal,
        excludeSemantics: true,
        onTap: () => widget.onOpen(source),
        onLongPress: () => _showActions(rowContext, source),
        child: InkWell(
          onTap: () => widget.onOpen(source),
          onTapDown: (details) => _pointerDown = details.globalPosition,
          onLongPress: () {
            final at = _pointerDown;
            _pointerDown = null;
            _showActions(rowContext, source, at: at);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _tapTarget),
            child: Padding(
              padding: padding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      source.kind == NoteSourceKind.file
                          ? Icons.insert_drive_file
                          : Icons.public,
                      size: _iconSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: _iconGap),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          source.displayTitle,
                          maxLines: titleLines,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: metaStyle,
                          ),
                        ],
                        if (showUrl) ...[
                          const SizedBox(height: 2),
                          // Last resort after compactUrl: one line, never
                          // wrapped, ellipsized.
                          Text(
                            source.compactUrl,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: metaStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A 40 px square icon button for the chevron and the `⋯`.
  Widget _iconButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      icon: Icon(icon),
      iconSize: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(_tapTarget, _tapTarget),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// Full-width `+N more` / `Show less` control, at least [_tapTarget] tall
  /// with the text vertically centred.
  Widget _linkStrip(String text, VoidCallback onTap, EdgeInsets padding) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _tapTarget),
        child: Padding(
          padding: padding,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              text,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuEntry(IconData icon, String label, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        // The menu caps its content width, so a long label or a large text
        // scale ellipsizes instead of overflowing.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: color == null ? null : TextStyle(color: color),
          ),
        ),
      ],
    );
  }

  // ── Text ─────────────────────────────────────────────────────────────────

  /// `siteName ?? host`, then the clip time when known, joined by ` · `.
  /// The site is left out when it would only repeat the title line (a
  /// source without a title shows its host as the title).
  static String _metaLine(NoteSource source, AppLocalizations l10n) {
    final site = source.siteName ?? source.host;
    final clippedAt = source.clippedAt;
    return [
      if (site.isNotEmpty && site != source.displayTitle) site,
      if (clippedAt != null) _clipTime(clippedAt, l10n),
    ].join(' · ');
  }

  static String _clipTime(DateTime clippedAt, AppLocalizations l10n) {
    final when = AppDateUtils.formatRelative(clippedAt, l10n);
    // `justNow` is a standalone label ("Just now"); inside "clipped {when}"
    // it reads as a phrase. A no-op for the other relative forms and for zh.
    return l10n.clippedRelative(
      when == l10n.justNow ? when.toLowerCase() : when,
    );
  }

  /// Full title and host (plus site name and clip time when known) for
  /// screen readers; the visible lines are excluded from semantics.
  static String _semanticsLabel(NoteSource source, AppLocalizations l10n) {
    final title = source.displayTitle;
    final host = source.host;
    final siteName = source.siteName;
    final clippedAt = source.clippedAt;
    return [
      l10n.clippedFrom,
      title,
      if (host.isNotEmpty && host != title) host,
      if (siteName != null && siteName != host && siteName != title) siteName,
      if (clippedAt != null) _clipTime(clippedAt, l10n),
    ].join(', ');
  }

  // ── Menu ─────────────────────────────────────────────────────────────────

  /// Copy / Edit / Remove, under the finger when [at] (a global position) is
  /// known, otherwise over [anchorContext]'s box (the `⋯` button, or the
  /// row for a semantics long-press).
  Future<void> _showActions(
    BuildContext anchorContext,
    NoteSource source, {
    Offset? at,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = anchorContext.findRenderObject() as RenderBox?;
    if (overlay == null || box == null || !box.hasSize) return;
    final Rect anchor;
    if (at != null) {
      anchor = Rect.fromCenter(
        center: overlay.globalToLocal(at),
        width: 1,
        height: 1,
      );
    } else {
      anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    }
    final action = await showMenu<_SourceAction>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      items: [
        PopupMenuItem(
          value: _SourceAction.copy,
          child: _menuEntry(Icons.link, l10n.copyLink),
        ),
        if (widget.onEdit != null)
          PopupMenuItem(
            value: _SourceAction.edit,
            child: _menuEntry(Icons.edit_outlined, l10n.editSource),
          ),
        if (widget.onRemove != null)
          PopupMenuItem(
            value: _SourceAction.remove,
            child: _menuEntry(
              Icons.delete_outline,
              l10n.removeSource,
              color: theme.colorScheme.error,
            ),
          ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SourceAction.copy:
        widget.onCopy(source);
      case _SourceAction.edit:
        widget.onEdit?.call(source);
      case _SourceAction.remove:
        widget.onRemove?.call(source);
    }
  }
}
