import 'package:flutter/material.dart';
import 'package:note_synapse/l10n/app_localizations.dart';

enum BlockSelectionPopupMode {
  expandAbove,
  contractAbove,
  expandBelow,
  contractBelow,
}

class BlockSelectionCountPopup extends StatefulWidget {
  final BlockSelectionPopupMode mode;
  final void Function(int count) onApplyCount;
  final VoidCallback onApplyDirectional;
  final int initialCount;
  final int minCount;

  const BlockSelectionCountPopup({
    super.key,
    required this.mode,
    required this.onApplyCount,
    required this.onApplyDirectional,
    this.initialCount = 2,
    this.minCount = 1,
  });

  @override
  State<BlockSelectionCountPopup> createState() =>
      _BlockSelectionCountPopupState();
}

class _BlockSelectionCountPopupState extends State<BlockSelectionCountPopup> {
  late int _count = widget.initialCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final directionalLabel = switch (widget.mode) {
      BlockSelectionPopupMode.expandAbove => l10n.expandToTop,
      BlockSelectionPopupMode.expandBelow => l10n.expandToBottom,
      BlockSelectionPopupMode.contractAbove ||
      BlockSelectionPopupMode.contractBelow => l10n.contractToStart,
    };

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.remove, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: _count > widget.minCount
                  ? () => setState(() => _count--)
                  : null,
            ),
            SizedBox(
              width: 28,
              child: Text(
                '$_count',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => setState(() => _count++),
            ),
            IconButton(
              icon: const Icon(Icons.check),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => widget.onApplyCount(_count),
            ),
            const SizedBox(width: 4, height: 24, child: VerticalDivider()),
            TextButton(
              onPressed: widget.onApplyDirectional,
              child: Text(directionalLabel),
            ),
          ],
        ),
      ),
    );
  }
}
