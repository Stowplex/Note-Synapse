import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/prompts/prompt_configuration_registry.dart';
import '../services/prompts/prompt_configuration_service.dart';

class PromptSettingsScreen extends StatefulWidget {
  const PromptSettingsScreen({super.key});

  @override
  State<PromptSettingsScreen> createState() => _PromptSettingsScreenState();
}

class _PromptSettingsScreenState extends State<PromptSettingsScreen> {
  late final PromptConfigurationService _service;
  late final List<PromptConfigSection> _sections;
  final Map<String, TextEditingController> _controllers = {};
  VoidCallback? _serviceListener;

  @override
  void initState() {
    super.initState();
    _service = PromptConfigurationService.instance;
    _sections = PromptConfigurationRegistry.instance.listSections();
    for (final section in _sections) {
      for (final entry in section.entries) {
        _ensureController(entry.id, _service.getValue(entry.id) ?? '');
      }
    }
    _serviceListener = () {
      if (!mounted) return;
      for (final section in _sections) {
        for (final entry in section.entries) {
          final latest = _service.getValue(entry.id) ?? '';
          final controller = _controllers[entry.id];
          if (controller != null && controller.text != latest) {
            controller.text = latest;
          }
        }
      }
    };
    _service.addListener(_serviceListener!);
  }

  @override
  void dispose() {
    if (_serviceListener != null) {
      _service.removeListener(_serviceListener!);
    }
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _ensureController(String entryId, String value) {
    if (_controllers.containsKey(entryId)) return;
    final controller = TextEditingController(text: value);
    controller.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
    _controllers[entryId] = controller;
  }

  TextEditingController _controllerFor(String entryId) {
    final controller = _controllers[entryId];
    if (controller == null) {
      throw StateError('Controller not initialized for $entryId');
    }
    return controller;
  }

  Future<void> _handleSave(PromptConfigEntry entry) async {
    final controller = _controllerFor(entry.id);
    await _service.setValue(entry.id, controller.text);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.promptSettingsSaved(entry.title))),
    );
  }

  Future<void> _handleReset(PromptConfigEntry entry) async {
    await _service.clearValue(entry.id);
    if (!mounted) return;
    final controller = _controllerFor(entry.id);
    if (controller.text.isNotEmpty) {
      controller.clear();
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.promptSettingsCleared(entry.title))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.promptSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.promptSettingsDescription,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 16),
          for (final section in _sections) ...[
            _PromptConfigSectionWidget(
              section: section,
              controllers: _controllers,
              service: _service,
              onSave: _handleSave,
              onReset: _handleReset,
            ),
            const SizedBox(height: 16),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _PromptConfigSectionWidget extends StatelessWidget {
  const _PromptConfigSectionWidget({
    required this.section,
    required this.controllers,
    required this.service,
    required this.onSave,
    required this.onReset,
  });

  final PromptConfigSection section;
  final Map<String, TextEditingController> controllers;
  final PromptConfigurationService service;
  final Future<void> Function(PromptConfigEntry) onSave;
  final Future<void> Function(PromptConfigEntry) onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(section.title, style: theme.textTheme.titleMedium),
            if ((section.description ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(section.description!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 12),
            for (final entry in section.entries) ...[
              _PromptConfigEntryWidget(
                entry: entry,
                controller: controllers[entry.id]!,
                service: service,
                onSave: onSave,
                onReset: onReset,
              ),
              if (entry != section.entries.last) const Divider(height: 32),
            ],
          ],
        ),
      ),
    );
  }
}

class _PromptConfigEntryWidget extends StatelessWidget {
  const _PromptConfigEntryWidget({
    required this.entry,
    required this.controller,
    required this.service,
    required this.onSave,
    required this.onReset,
  });

  final PromptConfigEntry entry;
  final TextEditingController controller;
  final PromptConfigurationService service;
  final Future<void> Function(PromptConfigEntry) onSave;
  final Future<void> Function(PromptConfigEntry) onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final storedValue = service.getValue(entry.id) ?? '';
    final hasChanges = controller.text != storedValue;
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(entry.title, style: theme.textTheme.titleSmall),
        if ((entry.description ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(entry.description!, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: entry.multiline ? null : 1,
          minLines: entry.multiline ? 3 : 1,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: entry.placeholder,
            helperText: entry.helperText,
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton(
              onPressed: controller.text.isEmpty && storedValue.isEmpty
                  ? null
                  : () => onReset(entry),
              child: Text(l10n.promptSettingsReset),
            ),
            const Spacer(),
            FilledButton(
              onPressed: hasChanges ? () => onSave(entry) : null,
              child: Text(l10n.promptSettingsSave),
            ),
          ],
        ),
      ],
    );
  }
}
