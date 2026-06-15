import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Accept / reject / reorder corrected pages, then choose the output format.
class ClipReviewScreen extends StatelessWidget {
  final List<Uint8List> pages;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index) onRemove;
  final VoidCallback onCompilePdf;
  final VoidCallback onCompileImages;

  /// Optional per-page correction entry. When null, no edit affordance shows.
  final void Function(int index)? onEdit;

  const ClipReviewScreen({
    super.key,
    required this.pages,
    required this.onReorder,
    required this.onRemove,
    required this.onCompilePdf,
    required this.onCompileImages,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            itemCount: pages.length,
            onReorder: onReorder,
            itemBuilder: (context, i) => ListTile(
              key: ValueKey('wc-page-$i'),
              leading: SizedBox(width: 56, child: Image.memory(pages[i])),
              title: Text('${i + 1}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onEdit != null)
                    IconButton(
                      icon: const Icon(Icons.crop),
                      onPressed: () => onEdit!(i),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onRemove(i),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            key: const ValueKey('wc-compile'),
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: onCompileImages,
                    child: Text(l10n.worldClipOutputImages)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                    onPressed: onCompilePdf,
                    child: Text(l10n.worldClipOutputPdf)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
