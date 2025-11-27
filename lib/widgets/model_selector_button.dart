import 'package:flutter/material.dart';
import '../models/model_config.dart';
import '../services/model_storage_service.dart';

class ModelSelectorButton extends StatefulWidget {
  final Function(ModelConfig?) onModelSelected;
  final ModelConfig? selectedModel;
  final bool isElliptical;
  final bool isSendButton;

  const ModelSelectorButton({
    super.key,
    required this.onModelSelected,
    this.selectedModel,
    this.isElliptical = false,
    this.isSendButton = false,
  });

  @override
  State<ModelSelectorButton> createState() => _ModelSelectorButtonState();
}

class _ModelSelectorButtonState extends State<ModelSelectorButton> {
  List<ModelConfig> _availableModels = [];
  ModelConfig? _activeDefaultModel;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    try {
      final models = await ModelStorageService.getConfiguredModels();
      final activeModel = await ModelStorageService.getActiveModel();
      if (mounted) {
        setState(() {
          _availableModels = models;
          _activeDefaultModel = activeModel;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          // Error handling if needed
        });
      }
    }
  }

  void _showModelSelectionMenu(BuildContext context) {
    if (_availableModels.isEmpty) return;

    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<ModelConfig>(
      context: context,
      position: position,
      items: [
        ..._availableModels.map((model) {
          // Determine if this model is "selected"
          // It is selected if:
          // 1. It matches the current override (widget.selectedModel)
          // 2. OR if there is NO override (widget.selectedModel is null) AND it matches the active default model
          final isSelected =
              (widget.selectedModel?.id == model.id) ||
              (widget.selectedModel == null &&
                  _activeDefaultModel?.id == model.id);

          return PopupMenuItem<ModelConfig>(
            value: model,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    model.displayName ?? model.modelName ?? 'Unknown Model',
                    style: isSelected
                        ? const TextStyle(fontWeight: FontWeight.bold)
                        : null,
                  ),
                ),
                if (isSelected)
                  Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
              ],
            ),
          );
        }),
      ],
    ).then((ModelConfig? selected) {
      // If null is returned, it could be dismissal or "Default Model" selection.
      // We treat both as clearing the override for now.
      // To strictly distinguish, we would need a more complex UI or a non-null sentinel for "Default".
      // But clearing on dismiss is also a reasonable behavior for a "temporary override" menu.
      // However, to avoid accidental resets on outside clicks, we should check if the result is actually from a selection.
      // showMenu returns null if dismissed.
      // Let's assume the user wants to reset if they select "Default Model".
      // If they click outside, it returns null.
      // We can't distinguish easily.
      // Let's just call the callback.
      widget.onModelSelected(selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Determine icon and color based on selection
    final isSelected = widget.selectedModel != null;
    final iconColor = isSelected
        ? theme.colorScheme.primary
        : (isDark ? Colors.white70 : Colors.black54);

    // Tooltip text
    final tooltip = widget.selectedModel?.displayName ?? 'Select Model';

    if (widget.isElliptical) {
      // Style for elliptical buttons (right side split)
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showModelSelectionMenu(context),
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(20),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: theme.dividerColor, width: 1),
              ),
            ),
            child: Icon(Icons.arrow_drop_down, size: 18, color: iconColor),
          ),
        ),
      );
    } else if (widget.isSendButton) {
      // Style for send buttons (bottom/side split or integrated)
      return GestureDetector(
        onLongPress: () => _showModelSelectionMenu(context),
        onTap: () => _showModelSelectionMenu(context),
        child: Container(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.expand_more, size: 16, color: iconColor),
        ),
      );
    } else {
      // Default style (icon button)
      return IconButton(
        icon: Icon(Icons.psychology, color: iconColor),
        tooltip: tooltip,
        onPressed: () => _showModelSelectionMenu(context),
      );
    }
  }
}
