import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/screens/local_model_settings_screen.dart';
import '../l10n/app_localizations.dart';

class LocalModelPickerScreen extends StatefulWidget {
  const LocalModelPickerScreen({super.key});

  @override
  State<LocalModelPickerScreen> createState() => _LocalModelPickerScreenState();
}

class _LocalModelPickerScreenState extends State<LocalModelPickerScreen> {
  final _service = GetIt.instance<LocalModelService>();
  List<LocalModelStatus> _models = [];
  final Map<String, double> _downloadProgress = {};
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
      _downloadProgress[preset.id] = 0.0;
      _downloadErrors.remove(preset.id);
    });

    _service.downloadModel(
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
    ).listen((progress) {
      if (mounted) {
        setState(() => _downloadProgress[preset.id] = progress);
      }
    });
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
                      Text(preset.displayName,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        preset.supportsVision ? 'Vision + Text' : 'Text only',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (status.isDownloaded && !isDownloading)
                  FilledButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LocalModelSettingsScreen(
                          preset: preset,
                          configPath: status.modelPath!,
                        ),
                      ),
                    ),
                    child: Text(l10n.localModelReady),
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
              LinearProgressIndicator(value: _downloadProgress[preset.id]),
              const SizedBox(height: 4),
              Text('${l10n.localModelDownloading} '
                  '${(_downloadProgress[preset.id]! * 100).toStringAsFixed(0)}%'),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(l10n.localModelDownloadFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(MaterialLocalizations.of(context).backButtonTooltip),
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
                child: Text(l10n.localModelReady,
                    style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              ),
            if (!status.isDownloaded && !isDownloading && error == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l10n.localModelNotDownloaded,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
