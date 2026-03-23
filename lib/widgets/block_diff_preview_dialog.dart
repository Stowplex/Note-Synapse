import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../utils/line_diff.dart';

/// Dialog showing an inline diff of original vs transformed block content.
/// Returns `true` if user accepts, `false` if rejected.
class BlockDiffPreviewDialog extends StatelessWidget {
  final String original;
  final String transformed;

  const BlockDiffPreviewDialog({
    super.key,
    required this.original,
    required this.transformed,
  });

  /// Shows the diff preview dialog.
  static Future<bool> show(
    BuildContext context, {
    required String original,
    required String transformed,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BlockDiffPreviewDialog(
        original: original,
        transformed: transformed,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final diffLines = computeLineDiff(original, transformed);
    final size = MediaQuery.of(context).size;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: size.width * 0.8,
        height: size.height * 0.6,
        constraints: const BoxConstraints(
          maxWidth: 800,
          maxHeight: 600,
          minWidth: 300,
          minHeight: 200,
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(28),
                  topRight: Radius.circular(28),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.difference,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.aiEditDiffTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            // Diff content (scrollable)
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: diffLines.length,
                itemBuilder: (context, index) {
                  final line = diffLines[index];
                  return _buildDiffLine(context, line);
                },
              ),
            ),

            // Actions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l10n.aiEditReject),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(l10n.aiEditAccept),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiffLine(BuildContext context, DiffLine line) {
    final Color? bgColor;
    final TextStyle? textStyle;
    final String prefix;

    switch (line.type) {
      case DiffLineType.added:
        bgColor = Colors.green.withOpacity(0.15);
        textStyle = const TextStyle(fontFamily: 'monospace');
        prefix = '+ ';
      case DiffLineType.removed:
        bgColor = Colors.red.withOpacity(0.15);
        textStyle = const TextStyle(
          fontFamily: 'monospace',
          decoration: TextDecoration.lineThrough,
        );
        prefix = '- ';
      case DiffLineType.unchanged:
        bgColor = null;
        textStyle = const TextStyle(fontFamily: 'monospace');
        prefix = '  ';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      color: bgColor,
      child: Text(
        '$prefix${line.text}',
        style: textStyle,
      ),
    );
  }
}
