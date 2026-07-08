import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Accept / reject / reorder corrected pages, batch-clone edits across a
/// multi-selection, then choose the output format.
class ClipReviewScreen extends StatefulWidget {
  final List<Uint8List> pages;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index) onRemove;
  final VoidCallback onCompilePdf;
  final VoidCallback onCompileImages;

  /// Optional per-page correction entry. When null, no edit affordance shows.
  final void Function(int index)? onEdit;

  /// Optional batch clone: copy [sourceIndex]'s corrections (rotation + crop /
  /// keystone) onto every page in [targetIndices].
  final void Function(int sourceIndex, Set<int> targetIndices)? onCloneEdits;

  /// Optional batch clone of the edit *actions*: copy [sourceIndex]'s
  /// rotation/color settings but re-run document auto-detection on each
  /// target's own frame (pages framed differently each get a fitted quad,
  /// instead of pasting the source's literal crop).
  final void Function(int sourceIndex, Set<int> targetIndices)?
      onCloneEditActions;

  const ClipReviewScreen({
    super.key,
    required this.pages,
    required this.onReorder,
    required this.onRemove,
    required this.onCompilePdf,
    required this.onCompileImages,
    this.onEdit,
    this.onCloneEdits,
    this.onCloneEditActions,
  });

  @override
  State<ClipReviewScreen> createState() => _ClipReviewScreenState();
}

class _ClipReviewScreenState extends State<ClipReviewScreen> {
  bool _multiSelect = false;
  final Set<int> _selected = {};

  @override
  void didUpdateWidget(ClipReviewScreen old) {
    super.didUpdateWidget(old);
    // Page count changed (a page was removed) → indices shifted; drop the now
    // ambiguous selection rather than act on stale indices.
    if (old.pages.length != widget.pages.length) {
      _selected.removeWhere((i) => i >= widget.pages.length);
    }
  }

  void _toggleMultiSelect() => setState(() {
        _multiSelect = !_multiSelect;
        if (!_multiSelect) _selected.clear();
      });

  void _toggle(int i) => setState(() {
        _selected.contains(i) ? _selected.remove(i) : _selected.add(i);
      });

  void _selectAll() => setState(() {
        _selected
          ..clear()
          ..addAll(List.generate(widget.pages.length, (i) => i));
      });

  void _clear() => setState(() => _selected.clear());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        if (widget.onCloneEdits != null) _selectionBar(),
        Expanded(
          child: _multiSelect
              ? ListView.builder(
                  itemCount: widget.pages.length,
                  itemBuilder: (context, i) => _tile(context, i),
                )
              : ReorderableListView.builder(
                  itemCount: widget.pages.length,
                  onReorder: widget.onReorder,
                  itemBuilder: (context, i) => _tile(context, i),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            key: const ValueKey('wc-compile'),
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: widget.onCompileImages,
                    child: Text(l10n.worldClipOutputImages)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                    onPressed: widget.onCompilePdf,
                    child: Text(l10n.worldClipOutputPdf)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _selectionBar() {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('wc-multiselect-toggle'),
              tooltip: _multiSelect ? 'Done selecting' : 'Select multiple',
              icon: Icon(_multiSelect ? Icons.close : Icons.checklist),
              onPressed: _toggleMultiSelect,
            ),
            if (_multiSelect) ...[
              Expanded(child: Text('${_selected.length} selected')),
              TextButton(onPressed: _selectAll, child: const Text('Select all')),
              TextButton(onPressed: _clear, child: const Text('Deselect all')),
            ] else
              const Expanded(child: Text('Review clips')),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, int i) {
    final selected = _selected.contains(i);
    return ListTile(
      key: ValueKey('wc-page-$i'),
      selected: _multiSelect && selected,
      onTap: _multiSelect ? () => _toggle(i) : null,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_multiSelect)
            Checkbox(value: selected, onChanged: (_) => _toggle(i)),
          SizedBox(width: 56, child: Image.memory(widget.pages[i])),
        ],
      ),
      title: Text('${i + 1}'),
      trailing: PopupMenuButton<String>(
        key: ValueKey('wc-menu-$i'),
        icon: const Icon(Icons.more_vert),
        onSelected: (value) {
          switch (value) {
            case 'edit':
              widget.onEdit?.call(i);
              break;
            case 'clone':
              widget.onCloneEdits?.call(i, Set<int>.of(_selected));
              break;
            case 'cloneActions':
              widget.onCloneEditActions?.call(i, Set<int>.of(_selected));
              break;
            case 'delete':
              widget.onRemove(i);
              break;
          }
        },
        itemBuilder: (context) => [
          if (widget.onEdit != null)
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(
                  leading: Icon(Icons.crop), title: Text('Edit')),
            ),
          if (widget.onCloneEdits != null)
            PopupMenuItem(
              value: 'clone',
              enabled: _multiSelect && _selected.isNotEmpty,
              child: ListTile(
                leading: const Icon(Icons.content_copy),
                title: const Text('Clone edits'),
                subtitle: Text(_multiSelect && _selected.isNotEmpty
                    ? 'to ${_selected.length} selected'
                    : 'select pages first'),
              ),
            ),
          if (widget.onCloneEditActions != null)
            PopupMenuItem(
              value: 'cloneActions',
              enabled: _multiSelect && _selected.isNotEmpty,
              child: ListTile(
                leading: const Icon(Icons.auto_fix_high),
                title: Text(AppLocalizations.of(context)!
                    .worldClipCloneEditActions),
                subtitle: Text(_multiSelect && _selected.isNotEmpty
                    ? 'to ${_selected.length} selected'
                    : 'select pages first'),
              ),
            ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
                leading: Icon(Icons.delete_outline), title: Text('Delete')),
          ),
        ],
      ),
    );
  }
}
