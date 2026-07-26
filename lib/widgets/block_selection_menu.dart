import 'package:flutter/material.dart';
import 'package:note_synapse/l10n/app_localizations.dart';

class BlockSelectionMenu extends StatelessWidget {
  /// Width each button occupies. Kept tight so all nine buttons fit inside a
  /// 360dp-wide phone without overflowing the card.
  static const double buttonExtent = 36.0;

  static const double _iconSize = 20.0;

  /// Rendered width of the menu, used by callers to keep the floating card on
  /// screen: nine buttons, three dividers, the card's inner padding and the
  /// Card's own default 4dp margin on each side.
  ///
  /// Must never under-report the real width, or the caller's position clamp
  /// lets the card run off screen. Asserted in block_selection_menu_test.dart.
  static const double estimatedWidth =
      9 * buttonExtent + 3 * _dividerWidth + 2 * _cardPadding + 2 * _cardMargin;

  static const double _dividerWidth = 4.0;
  static const double _cardPadding = 4.0;
  static const double _cardMargin = 4.0;

  /// Material 3 IconButtons default to a 48dp tap target, which makes nine of
  /// them overflow a narrow phone. Shrink-wrapping the tap target is what
  /// actually lets [buttonExtent] take effect.
  static ButtonStyle get _denseButtonStyle => IconButton.styleFrom(
    minimumSize: const Size(buttonExtent, buttonExtent),
    maximumSize: const Size(buttonExtent, buttonExtent),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  final VoidCallback? onExpandAbove;
  final VoidCallback? onContractAbove;
  final VoidCallback? onExpandBelow;
  final VoidCallback? onContractBelow;
  final VoidCallback onEdit;
  final VoidCallback onAIEdit;
  final VoidCallback onNoteActionApp;
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
    required this.onNoteActionApp,
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
            _buildActionButton(
              icon: Icons.edit,
              tooltip: l10n.editSelection,
              onPressed: onEdit,
            ),
            // AI Edit
            _buildActionButton(
              icon: Icons.auto_awesome,
              tooltip: l10n.aiEdit,
              onPressed: onAIEdit,
            ),
            // Run a Note Action App on the selection
            _buildActionButton(
              icon: Icons.apps,
              tooltip: l10n.runNoteActionAppOnSelection,
              onPressed: onNoteActionApp,
            ),
            // Delete
            _buildActionButton(
              icon: Icons.delete,
              color: Colors.red,
              tooltip: l10n.deleteSelection,
              onPressed: onDelete,
            ),
            const SizedBox(width: 4, height: 24, child: VerticalDivider()),
            // Exit
            _buildActionButton(
              icon: Icons.close,
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
        icon: Icon(icon, size: _iconSize),
        style: _denseButtonStyle,
        onPressed: canUse ? onPressed : null,
        onLongPress: canUse ? onLongPress : null,
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, color: color, size: _iconSize),
      tooltip: tooltip,
      style: _denseButtonStyle,
      onPressed: onPressed,
    );
  }
}
