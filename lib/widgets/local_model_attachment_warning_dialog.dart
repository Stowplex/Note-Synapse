import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../models/model_config.dart';
import '../services/local_model_attachment_constraint_service.dart';
import '../services/model_storage_service.dart';

sealed class LocalModelAttachmentWarningDialogResult {}

class LocalModelAttachmentWarningStop
    extends LocalModelAttachmentWarningDialogResult {}

class LocalModelAttachmentWarningContinue
    extends LocalModelAttachmentWarningDialogResult {
  LocalModelAttachmentWarningContinue({this.modelOverride});

  final ModelConfig? modelOverride;
}

class LocalModelAttachmentWarningDialog extends StatefulWidget {
  const LocalModelAttachmentWarningDialog({
    super.key,
    required this.currentModel,
    required this.warning,
  });

  final ModelConfig? currentModel;
  final LocalModelAttachmentConstraintWarning warning;

  static Future<LocalModelAttachmentWarningDialogResult?> show(
    BuildContext context, {
    required ModelConfig? currentModel,
    required LocalModelAttachmentConstraintWarning warning,
  }) {
    return showDialog<LocalModelAttachmentWarningDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LocalModelAttachmentWarningDialog(
        currentModel: currentModel,
        warning: warning,
      ),
    );
  }

  @override
  State<LocalModelAttachmentWarningDialog> createState() =>
      _LocalModelAttachmentWarningDialogState();
}

class _LocalModelAttachmentWarningDialogState
    extends State<LocalModelAttachmentWarningDialog> {
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
    if (!mounted) return;

    setState(() {
      _models = models.where((m) => m.id != widget.currentModel?.id).toList();
      _selectedModel = widget.warning.suggestedModel;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSwitch = _selectedModel != null;

    return AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: Colors.amber.shade700,
        size: 32,
      ),
      title: const Text('Local Model Attachment Warning'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'These attachments may not fit well in Gemma 4. Switching to a cloud model is recommended.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            ...widget.warning.messages.map(
              (message) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $message', style: theme.textTheme.bodyMedium),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else if (_models.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: _selectedModel?.id,
                decoration: const InputDecoration(
                  labelText: 'Switch to model',
                  border: OutlineInputBorder(),
                ),
                items: _models
                    .map(
                      (model) => DropdownMenuItem(
                        value: model.id,
                        child: Text(
                          model.displayName ?? model.modelName ?? model.id,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (id) {
                  setState(() {
                    _selectedModel = _models.firstWhere((m) => m.id == id);
                  });
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, LocalModelAttachmentWarningStop()),
          child: const Text('Stop'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, LocalModelAttachmentWarningContinue()),
          child: const Text('Continue Anyway'),
        ),
        FilledButton(
          onPressed: canSwitch
              ? () => Navigator.pop(
                  context,
                  LocalModelAttachmentWarningContinue(
                    modelOverride: _selectedModel,
                  ),
                )
              : null,
          child: const Text('Switch Model'),
        ),
      ],
    );
  }
}
