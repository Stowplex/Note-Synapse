import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/screens/local_model_settings_screen.dart';
import '../l10n/app_localizations.dart';

class LocalModelPickerScreen extends StatefulWidget {
  final bool closeOnConfigured;

  const LocalModelPickerScreen({super.key, this.closeOnConfigured = false});

  @override
  State<LocalModelPickerScreen> createState() => _LocalModelPickerScreenState();
}

class _LocalModelPickerScreenState extends State<LocalModelPickerScreen> {
  final _service = GetIt.instance<LocalModelService>();
  List<LocalModelStatus> _models = [];
  final Map<String, LocalModelDownloadProgress?> _downloadProgress = {};
  final Map<String, String> _downloadErrors = {};

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    final models = await _service.getAvailableModels();
    if (mounted) setState(() => _models = models);
  }

  void _startDownload(LocalModelPreset preset) {
    setState(() {
      _downloadProgress[preset.id] = null;
      _downloadErrors.remove(preset.id);
    });

    _service
        .downloadModel(
          preset,
          onComplete: (configPath) {
            if (mounted) {
              setState(() => _downloadProgress.remove(preset.id));
              _loadModels();
            }
          },
          onError: (error) {
            if (mounted) {
              setState(() {
                _downloadProgress.remove(preset.id);
                _downloadErrors[preset.id] = error;
              });
            }
          },
        )
        .listen((progress) {
          if (mounted) {
            setState(() => _downloadProgress[preset.id] = progress);
          }
        });
  }

  Future<void> _openModelSettings(
    LocalModelPreset preset,
    String configPath,
  ) async {
    final configured = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            LocalModelSettingsScreen(preset: preset, configPath: configPath),
      ),
    );

    await _loadModels();

    if (configured == true && mounted && widget.closeOnConfigured) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _deleteModel(LocalModelStatus status) async {
    final preset = status.preset;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.localModelDelete),
        content: Text('Delete ${preset.displayName} and free up disk space?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.localModelDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _service.removeModel(preset.id);
    // Drop the configured model entry so it no longer appears as set up.
    await GetIt.instance<ModelStorageService>().deleteModel(
      'local_${preset.id}',
    );

    if (!mounted) return;
    await _loadModels();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${preset.displayName} deleted')));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.localModelSettings)),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _models.length,
        itemBuilder: (context, index) => _buildModelCard(_models[index]),
      ),
    );
  }

  Widget _buildModelCard(LocalModelStatus status) {
    final preset = status.preset;
    final isDownloading = _downloadProgress.containsKey(preset.id);
    final error = _downloadErrors[preset.id];
    final l10n = AppLocalizations.of(context)!;
    final progress = _downloadProgress[preset.id];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preset.displayName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preset.supportsVision ? 'Vision + Text' : 'Text only',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (status.isDownloaded && !isDownloading)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        onPressed: () =>
                            _openModelSettings(preset, status.modelPath!),
                        child: Text(l10n.localModelReady),
                      ),
                      IconButton(
                        tooltip: l10n.localModelDelete,
                        icon: Icon(
                          Icons.delete_outline,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: () => _deleteModel(status),
                      ),
                    ],
                  )
                else if (isDownloading)
                  const SizedBox.shrink()
                else if (error != null)
                  const SizedBox.shrink()
                else
                  OutlinedButton(
                    onPressed: () => _startDownload(preset),
                    child: Text(l10n.localModelDownload),
                  ),
              ],
            ),
            if (isDownloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress == null
                    ? null
                    : progress.progressPercent / 100.0,
              ),
              const SizedBox(height: 4),
              Text(
                progress == null
                    ? l10n.localModelDownloading
                    : '${l10n.localModelDownloading} ${progress.progressPercent}%',
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                l10n.localModelDownloadFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      MaterialLocalizations.of(context).backButtonTooltip,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _startDownload(preset),
                    child: Text(l10n.localModelRetry),
                  ),
                ],
              ),
            ],
            if (status.isDownloaded && !isDownloading)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.localModelReady,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (!status.isDownloaded && !isDownloading && error == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.localModelNotDownloaded,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

}
