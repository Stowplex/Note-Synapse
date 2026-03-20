import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import '../l10n/app_localizations.dart';

class LocalModelSettingsScreen extends StatefulWidget {
  final LocalModelPreset preset;
  final String configPath;

  const LocalModelSettingsScreen({
    super.key,
    required this.preset,
    required this.configPath,
  });

  @override
  State<LocalModelSettingsScreen> createState() => _LocalModelSettingsScreenState();
}

class _LocalModelSettingsScreenState extends State<LocalModelSettingsScreen> {
  late String _backendType;
  bool _enableThinking = false;
  int _tokenWindow = 16384;

  List<String> get _availableBackends {
    if (Platform.isAndroid) {
      return ['cpu', 'opencl'];
    } else if (Platform.isIOS) {
      final defaultBackend = widget.preset.defaultBackend['ios'] ?? 'cpu';
      if (defaultBackend == 'metal') return ['metal', 'cpu'];
      return ['cpu'];
    }
    return ['cpu'];
  }

  @override
  void initState() {
    super.initState();
    final platform = Platform.isAndroid ? 'android' : 'ios';
    _backendType = widget.preset.defaultBackend[platform] ?? 'cpu';
    _tokenWindow = widget.preset.defaultTokenWindow;
  }

  Future<void> _saveAndActivate() async {
    final config = ModelConfig(
      id: 'local_${widget.preset.id}',
      type: ModelType.localMnn,
      modelName: widget.preset.id,
      displayName: widget.preset.displayName,
      endpoint: widget.configPath,
      tokenWindow: _tokenWindow,
      enableThinking: _enableThinking,
      backendType: _backendType,
      isConfigured: true,
    );

    final storage = GetIt.instance<ModelStorageService>();
    await storage.addModel(config);
    await GetIt.instance<ModelSelector>().switchToModel(config);

    if (mounted) {
      Navigator.popUntil(context, (route) => route.isFirst);
    }
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.localModelDelete),
        content: Text('Delete ${widget.preset.displayName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed == true) {
      await GetIt.instance<LocalModelService>().removeModel(widget.preset.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(widget.preset.displayName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.localModelBackend, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _backendType,
            items: _availableBackends
                .map((b) => DropdownMenuItem(value: b, child: Text(_backendLabel(b))))
                .toList(),
            onChanged: (v) => setState(() => _backendType = v!),
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            title: Text(l10n.localModelEnableThinking),
            subtitle: const Text('Extended reasoning (uses more tokens)'),
            value: _enableThinking,
            onChanged: (v) => setState(() => _enableThinking = v),
          ),
          const SizedBox(height: 24),
          Text(l10n.localModelTokenWindow, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('4096'),
              Expanded(
                child: Slider(
                  value: _tokenWindow.toDouble(),
                  min: 4096,
                  max: 32768,
                  divisions: 7,
                  label: _tokenWindow.toString(),
                  onChanged: (v) => setState(() => _tokenWindow = v.round()),
                ),
              ),
              const Text('32768'),
            ],
          ),
          Center(child: Text('$_tokenWindow', style: Theme.of(context).textTheme.titleMedium)),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _saveAndActivate,
            child: const Text('Save & Activate'),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _deleteModel,
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.localModelDelete),
          ),
        ],
      ),
    );
  }

  String _backendLabel(String backend) {
    switch (backend) {
      case 'opencl': return 'OpenCL (GPU)';
      case 'metal': return 'Metal (GPU)';
      case 'cpu': return 'CPU';
      default: return backend;
    }
  }
}
