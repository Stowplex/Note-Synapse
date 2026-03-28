import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../l10n/app_localizations.dart';
import '../models/model_config.dart';
import '../services/model_storage_service.dart';

/// Result returned by [ToolOrchestrationWarningDialog].
sealed class ToolOrchestrationDialogResult {}

/// User chose to stop — do not send.
class ToolOrchestrationStop extends ToolOrchestrationDialogResult {}

/// User chose to continue, optionally with a model override.
///
/// [modelOverride] is null when the user clicked "Continue Anyway" without
/// switching models. When non-null, the caller should apply the override before
/// sending.
class ToolOrchestrationContinue extends ToolOrchestrationDialogResult {
  final ModelConfig? modelOverride;
  ToolOrchestrationContinue({this.modelOverride});
}

/// Compact warning row shown inside tool panels when orchestration is unsupported.
Widget buildToolOrchestrationWarningRow(BuildContext context) {
  final theme = Theme.of(context);
  return Row(
    children: [
      Icon(Icons.warning_amber_rounded, size: 12, color: Colors.amber.shade700),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          AppLocalizations.of(context)!.toolOrchestrationWarningTitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.amber.shade700,
          ),
        ),
      ),
    ],
  );
}

/// Dialog shown when the user is about to send a message with tools selected
/// but the active model does not have [ModelCapabilities.supportsToolOrchestration].
///
/// Allows the user to:
/// - Continue anyway with the current model
/// - Switch to a model that supports tool orchestration and continue
/// - Stop and cancel the send
class ToolOrchestrationWarningDialog extends StatefulWidget {
  const ToolOrchestrationWarningDialog({
    super.key,
    required this.currentModel,
  });

  final ModelConfig? currentModel;

  /// Show the dialog and return the user's decision.
  static Future<ToolOrchestrationDialogResult?> show(
    BuildContext context,
    ModelConfig? currentModel,
  ) {
    return showDialog<ToolOrchestrationDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ToolOrchestrationWarningDialog(currentModel: currentModel),
    );
  }

  @override
  State<ToolOrchestrationWarningDialog> createState() =>
      _ToolOrchestrationWarningDialogState();
}

class _ToolOrchestrationWarningDialogState
    extends State<ToolOrchestrationWarningDialog> {
  List<ModelConfig> _models = [];
  ModelConfig? _selectedModel;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    final storage = GetIt.instance<ModelStorageService>();
    final models = await storage.getConfiguredModels();
    if (mounted) {
      setState(() {
        _models = models;
        // Pre-select the current model in the dropdown
        _selectedModel = models
            .where((m) => m.id == widget.currentModel?.id)
            .firstOrNull;
        _loading = false;
      });
    }
  }

  bool get _selectedSupportsOrchestration =>
      _selectedModel?.customCapabilitiesObject?.supportsToolOrchestration ??
      true;

  String get _selectedModelName =>
      _selectedModel?.displayName ??
      _selectedModel?.modelName ??
      widget.currentModel?.displayName ??
      widget.currentModel?.modelName ??
      'Unknown model';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final supported = _selectedSupportsOrchestration;

    return AlertDialog(
      icon: Icon(
        supported ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
        color: supported ? colorScheme.primary : Colors.amber.shade700,
        size: 32,
      ),
      title: Text(
        supported
            ? 'Tool Orchestration Supported'
            : l10n.toolOrchestrationWarningTitle,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              supported
                  ? l10n.toolOrchestrationSupportedBody(_selectedModelName)
                  : l10n.toolOrchestrationWarningBody(_selectedModelName),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.toolOrchestrationSwitchModel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _loading
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _buildModelDropdown(colorScheme),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, ToolOrchestrationStop()),
          child: Text(l10n.toolOrchestrationStop),
        ),
        FilledButton(
          onPressed: () {
            final override =
                _selectedModel?.id != widget.currentModel?.id
                    ? _selectedModel
                    : null;
            Navigator.pop(
              context,
              ToolOrchestrationContinue(modelOverride: override),
            );
          },
          style: supported
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: Colors.amber.shade700,
                  foregroundColor: Colors.white,
                ),
          child: Text(
            supported
                ? l10n.toolOrchestrationContinue
                : l10n.toolOrchestrationContinueAnyway,
          ),
        ),
      ],
    );
  }

  Widget _buildModelDropdown(ColorScheme colorScheme) {
    if (_models.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.maxFinite,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<String>(
        value: _selectedModel?.id,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        onChanged: (id) {
          setState(() {
            _selectedModel = _models.firstWhere((m) => m.id == id);
          });
        },
        items: _models.map((model) {
          final orchestration =
              model.customCapabilitiesObject?.supportsToolOrchestration ?? true;
          final name =
              model.displayName ?? model.modelName ?? model.id;
          return DropdownMenuItem<String>(
            value: model.id,
            child: Row(
              children: [
                Icon(
                  orchestration
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: 16,
                  color: orchestration
                      ? Colors.green.shade600
                      : colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
