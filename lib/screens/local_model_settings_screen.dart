import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/models/model_capabilities.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import '../l10n/app_localizations.dart';

class LocalModelSettingsScreen extends StatefulWidget {
  final LocalModelPreset preset;
  final String configPath;
  final ModelConfig? existingConfig;
  final bool returnToPreviousScreenOnSave;

  const LocalModelSettingsScreen({
    super.key,
    required this.preset,
    required this.configPath,
    this.existingConfig,
    this.returnToPreviousScreenOnSave = true,
  });

  @override
  State<LocalModelSettingsScreen> createState() =>
      _LocalModelSettingsScreenState();
}

class _LocalModelSettingsScreenState extends State<LocalModelSettingsScreen> {
  late String _backendType;
  bool _enableThinking = false;
  int _tokenWindow = 16384;

  List<String> get _availableBackends {
    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
        ? 'ios'
        : 'desktop';
    return widget.preset.supportedBackends[platform] ?? ['cpu'];
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.existingConfig;
    if (existing != null) {
      _backendType =
          existing.backendType ??
          widget.preset.defaultBackend[_platformKey] ??
          'gpu';
      _enableThinking =
          widget.preset.supportsThinking && (existing.enableThinking ?? false);
      _tokenWindow = (existing.tokenWindow ?? widget.preset.defaultTokenWindow)
          .clamp(widget.preset.minTokenWindow, widget.preset.maxTokenWindow);
    } else {
      _backendType = widget.preset.defaultBackend[_platformKey] ?? 'gpu';
      _tokenWindow = widget.preset.defaultTokenWindow;
    }
  }

  String get _platformKey => Platform.isAndroid ? 'android' : 'ios';

  Future<void> _saveAndActivate() async {
    final configId = 'local_${widget.preset.id}';
    final config = ModelConfig(
      id: configId,
      type: ModelType.localMnn,
      modelName: widget.preset.id,
      displayName: widget.preset.displayName,
      endpoint: widget.configPath,
      tokenWindow: _tokenWindow,
      enableThinking: widget.preset.supportsThinking ? _enableThinking : false,
      backendType: _backendType,
      isConfigured: true,
      customCapabilitiesObject: ModelCapabilities(
        maxInputTokens: _tokenWindow,
        maxOutputTokens: 8192,
        supportsImages: widget.preset.supportsVision,
        supportsDocuments: false,
        supportsAudio: false,
        supportsVideo: false,
        supportsToolOrchestration: widget.preset.supportsToolOrchestration,
        supportedImageFormats: const ['png', 'jpg', 'jpeg'],
        supportedDocumentFormats: const [],
      ),
    );

    final storage = GetIt.instance<ModelStorageService>();
    // Use update if this model already exists, otherwise add
    final existing = await storage.getConfiguredModels();
    if (existing.any((m) => m.id == configId)) {
      await storage.updateModel(config);
    } else {
      await storage.addModel(config);
    }
    await GetIt.instance<ModelSelector>().switchToModel(config);

    if (!mounted) return;
    if (widget.returnToPreviousScreenOnSave) {
      Navigator.pop(context, true);
      return;
    }
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.localModelDelete),
        content: Text('Delete ${widget.preset.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await GetIt.instance<LocalModelService>().removeModel(widget.preset.id);
      final storage = GetIt.instance<ModelStorageService>();
      final configId = 'local_${widget.preset.id}';
      await storage.deleteModel(configId);
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
          Text(
            l10n.localModelBackend,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _backendType,
            items: _availableBackends
                .map(
                  (b) =>
                      DropdownMenuItem(value: b, child: Text(_backendLabel(b))),
                )
                .toList(),
            onChanged: (v) => setState(() => _backendType = v!),
          ),
          const SizedBox(height: 24),
          if (widget.preset.supportsThinking) ...[
            SwitchListTile(
              title: Text(l10n.localModelEnableThinking),
              subtitle: const Text('Extended reasoning (uses more tokens)'),
              value: _enableThinking,
              onChanged: (v) => setState(() => _enableThinking = v),
            ),
            const SizedBox(height: 24),
          ],
          Text(
            l10n.localModelTokenWindow,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(widget.preset.minTokenWindow.toString()),
              Expanded(
                child: Slider(
                  value: _tokenWindow.toDouble(),
                  min: widget.preset.minTokenWindow.toDouble(),
                  max: widget.preset.maxTokenWindow.toDouble(),
                  divisions:
                      ((widget.preset.maxTokenWindow -
                                  widget.preset.minTokenWindow) /
                              2048)
                          .round(),
                  label: _tokenWindow.toString(),
                  onChanged: (v) => setState(() => _tokenWindow = v.round()),
                ),
              ),
              Text(widget.preset.maxTokenWindow.toString()),
            ],
          ),
          Center(
            child: Text(
              '$_tokenWindow',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
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
      case 'opencl':
        return 'OpenCL (GPU)';
      case 'metal':
        return 'Metal (GPU)';
      case 'gpu':
        return 'GPU';
      case 'cpu':
        return 'CPU';
      default:
        return backend;
    }
  }
}
