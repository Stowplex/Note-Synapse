import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/merge_document.dart';
import 'interactive_checkbox_markdown.dart';

/// The merged note as a reorderable list of blocks: drag to reorder, swipe to
/// remove, tap a gap to choose where the next ticked block lands.
class MergeArrangeList extends StatelessWidget {
  const MergeArrangeList({
    super.key,
    required this.document,
    required this.colorOf,
    required this.fallbackNoteId,
    required this.onChanged,
  });

  final MergeDocument document;
  final Color Function(MergeSource source) colorOf;

  /// Note id used to resolve images in segments that have no source.
  final String fallbackNoteId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    if (document.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l10n.mergeEmptyHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final segments = document.segments;
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 32),
      buildDefaultDragHandles: false,
      itemCount: segments.length,
      onReorderItem: (from, to) {
        document.move(from, to);
        onChanged();
      },
      itemBuilder: (context, index) {
        final segment = segments[index];
        return Column(
          key: ObjectKey(segment),
          mainAxisSize: MainAxisSize.min,
          children: [
            _Gap(
              index: index,
              document: document,
              onChanged: onChanged,
            ),
            _SegmentCard(
              index: index,
              segment: segment,
              color: segment.source == null ? null : colorOf(segment.source!),
              fallbackNoteId: fallbackNoteId,
              onRemove: () {
                document.removeAt(index);
                onChanged();
              },
            ),
            if (index == segments.length - 1)
              _Gap(
                index: segments.length,
                document: document,
                onChanged: onChanged,
              ),
          ],
        );
      },
    );
  }
}

/// The tappable space between two blocks. Shows the insertion marker when
/// [document.insertionIndex] points here.
class _Gap extends StatelessWidget {
  const _Gap({
    required this.index,
    required this.document,
    required this.onChanged,
  });

  final int index;
  final MergeDocument document;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final active = document.insertionIndex == index;

    if (active) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Divider(color: theme.colorScheme.primary, thickness: 2),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.mergeInsertHere,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(Icons.close),
              onPressed: () {
                document.insertionIndex = null;
                onChanged();
              },
            ),
            Expanded(
              child: Divider(color: theme.colorScheme.primary, thickness: 2),
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: () {
        document.insertionIndex = index;
        onChanged();
      },
      child: SizedBox(
        height: 14,
        child: Center(
          child: Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  const _SegmentCard({
    required this.index,
    required this.segment,
    required this.color,
    required this.fallbackNoteId,
    required this.onRemove,
  });

  final int index;
  final MergeSegment segment;
  final Color? color;
  final String fallbackNoteId;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final noteId = segment.source?.note.id ?? fallbackNoteId;
    final sourceTitle = segment.source?.note.title;

    return Dismissible(
      key: ValueKey('dismiss-${identityHashCode(segment)}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: theme.colorScheme.errorContainer,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Text(
              l10n.mergeRemoveBlock,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ],
        ),
      ),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              constraints: const BoxConstraints(minHeight: 44),
              color: color ?? Colors.transparent,
            ),
            const SizedBox(width: 8),
            if (sourceTitle != null)
              Tooltip(
                message: l10n.mergeBlockFromNote(sourceTitle),
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Icon(Icons.circle, size: 10, color: color),
                ),
              )
            else
              const SizedBox(width: 10),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: InteractiveCheckboxMarkdown(
                  key: ValueKey('${identityHashCode(segment)}-${segment.text.hashCode}'),
                  noteId: noteId,
                  originalContent: segment.text,
                  maxLines: null,
                  overflow: null,
                ),
              ),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_handle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
