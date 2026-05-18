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

  final GlobalKey? expandAboveKey;
  final GlobalKey? contractAboveKey;
  final GlobalKey? contractBelowKey;
  final GlobalKey? expandBelowKey;
  final VoidCallback? onLongPressExpandAbove;
  final VoidCallback? onLongPressContractAbove;
  final VoidCallback? onLongPressContractBelow;
  final VoidCallback? onLongPressExpandBelow;

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
    this.expandAboveKey,
    this.contractAboveKey,
    this.contractBelowKey,
    this.expandBelowKey,
    this.onLongPressExpandAbove,
    this.onLongPressContractAbove,
    this.onLongPressContractBelow,
    this.onLongPressExpandBelow,
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
            _buildBoundaryButton(
              key: expandAboveKey,
              icon: Icons.expand_less,
              tooltip: l10n.expandSelectionAbove,
              canUse: canExpandAbove,
              onPressed: onExpandAbove,
              onLongPress: onLongPressExpandAbove,
            ),
            // Contract Above (Maybe arrow_downward if above?)
            // Icons for expand/contract relative to selection:
            // Expand Above: Up arrow
            // Contract Above: Down arrow (shrinks top boundary down)
            _buildBoundaryButton(
              key: contractAboveKey,
              icon: Icons.vertical_align_bottom,
              tooltip: l10n.contractSelectionAbove,
              canUse: canContractAbove,
              onPressed: onContractAbove,
              onLongPress: onLongPressContractAbove,
            ),
            // Divider
            const SizedBox(width: 4, height: 24, child: VerticalDivider()),

            // Contract Below: Up arrow (shrinks bottom boundary up)
            _buildBoundaryButton(
              key: contractBelowKey,
              icon: Icons.vertical_align_top,
              tooltip: l10n.contractSelectionBelow,
              canUse: canContractBelow,
              onPressed: onContractBelow,
              onLongPress: onLongPressContractBelow,
            ),
            // Expand Below: Down arrow
            _buildBoundaryButton(
              key: expandBelowKey,
              icon: Icons.expand_more,
              tooltip: l10n.expandSelectionBelow,
              canUse: canExpandBelow,
              onPressed: onExpandBelow,
              onLongPress: onLongPressExpandBelow,
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

  Widget _buildBoundaryButton({
    required GlobalKey? key,
    required IconData icon,
    required String tooltip,
    required bool canUse,
    required VoidCallback? onPressed,
    required VoidCallback? onLongPress,
  }) {
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.manual,
      child: IconButton(
        key: key,
        icon: Icon(icon),
        onPressed: canUse ? onPressed : null,
        onLongPress: canUse ? onLongPress : null,
      ),
    );
  }
}
