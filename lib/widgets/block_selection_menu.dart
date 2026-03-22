import 'package:flutter/material.dart';
import 'package:note_synapse/l10n/app_localizations.dart';

class BlockSelectionMenu extends StatelessWidget {
  final VoidCallback? onExpandAbove;
  final VoidCallback? onContractAbove;
  final VoidCallback? onExpandBelow;
  final VoidCallback? onContractBelow;
  final VoidCallback onEdit;
  final VoidCallback onAIEdit;
  final VoidCallback onDelete;
  final VoidCallback onExit;

  final bool canExpandAbove;
  final bool canContractAbove;
  final bool canExpandBelow;
  final bool canContractBelow;

  const BlockSelectionMenu({
    super.key,
    required this.onExpandAbove,
    required this.onContractAbove,
    required this.onExpandBelow,
    required this.onContractBelow,
    required this.onEdit,
    required this.onAIEdit,
    required this.onDelete,
    required this.onExit,
    this.canExpandAbove = true,
    this.canContractAbove = true,
    this.canExpandBelow = true,
    this.canContractBelow = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Expand Above
            IconButton(
              icon: const Icon(Icons.expand_less), // Or keyboard_arrow_up
              tooltip: l10n.expandSelectionAbove,
              onPressed: canExpandAbove ? onExpandAbove : null,
            ),
            // Contract Above (Maybe arrow_downward if above?)
            // Icons for expand/contract relative to selection:
            // Expand Above: Up arrow
            // Contract Above: Down arrow (shrinks top boundary down)
            IconButton(
              icon: const Icon(
                Icons.vertical_align_bottom,
              ), // Or something depicting shrinking top
              tooltip: l10n.contractSelectionAbove,
              onPressed: canContractAbove ? onContractAbove : null,
            ),
            // Divider
            const SizedBox(width: 4, height: 24, child: VerticalDivider()),

            // Contract Below: Up arrow (shrinks bottom boundary up)
            IconButton(
              icon: const Icon(Icons.vertical_align_top),
              tooltip: l10n.contractSelectionBelow,
              onPressed: canContractBelow ? onContractBelow : null,
            ),
            // Expand Below: Down arrow
            IconButton(
              icon: const Icon(Icons.expand_more),
              tooltip: l10n.expandSelectionBelow,
              onPressed: canExpandBelow ? onExpandBelow : null,
            ),

            const SizedBox(width: 4, height: 24, child: VerticalDivider()),

            // Edit
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: l10n.editSelection,
              onPressed: onEdit,
            ),
            // AI Edit
            IconButton(
              icon: const Icon(Icons.auto_awesome),
              tooltip: l10n.aiEdit,
              onPressed: onAIEdit,
            ),
            // Delete
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              tooltip: l10n.deleteSelection,
              onPressed: onDelete,
            ),
            const SizedBox(width: 4, height: 24, child: VerticalDivider()),
            // Exit
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: l10n.close,
              onPressed: onExit,
            ),
          ],
        ),
      ),
    );
  }
}
