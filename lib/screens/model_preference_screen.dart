import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/model_config.dart';
import '../services/model_preference_service.dart';
import '../services/model_storage_service.dart';
import '../services/service_locator.dart';

class ModelPreferenceScreen extends StatefulWidget {
  const ModelPreferenceScreen({super.key});

  @override
  State<ModelPreferenceScreen> createState() => _ModelPreferenceScreenState();
}

class _ModelPreferenceScreenState extends State<ModelPreferenceScreen> {
  List<ModelConfig> _allModels = [];
  List<String> _preferenceListIds = [];
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final models = await getIt<ModelStorageService>().getConfiguredModels();
      final prefs = await getIt<ModelPreferenceService>().getPreferenceList();

      setState(() {
        _allModels = models;
        _preferenceListIds = List.from(prefs);
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              )!.errorLoadingModelPreferences(e.toString()),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _savePreferences() async {
    setState(() {
      _isSaving = true;
    });

    try {
      await getIt<ModelPreferenceService>().setPreferenceList(
        _preferenceListIds,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              )!.errorSavingModelPreferences(e.toString()),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _addModelToPreference(ModelConfig model) {
    if (!_preferenceListIds.contains(model.id)) {
      setState(() {
        _preferenceListIds.add(model.id);
      });
      _savePreferences();
    }
  }

  void _removeModelFromPreference(int index) {
    setState(() {
      _preferenceListIds.removeAt(index);
    });
    _savePreferences();
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (oldIndex < newIndex) {
        newIndex -= 1;
      }
      final item = _preferenceListIds.removeAt(oldIndex);
      _preferenceListIds.insert(newIndex, item);
    });
    _savePreferences();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Determine available models not yet in the list
    final availableModels = _allModels
        .where((m) => !_preferenceListIds.contains(m.id))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.modelPreferences),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.only(right: 16.0),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) => _FeatureMatrixSheet(models: _allModels),
              );
            },
            tooltip: l10n.viewFeatureMatrix,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    l10n.modelPreferenceDragDropHint,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                  ),
                ),
                Expanded(
                  child: SplitView(
                    activeListIds: _preferenceListIds,
                    allModels: _allModels,
                    availableModels: availableModels,
                    onReorder: _onReorder,
                    onRemove: _removeModelFromPreference,
                    onAdd: _addModelToPreference,
                  ),
                ),
              ],
            ),
    );
  }
}

class SplitView extends StatelessWidget {
  final List<String> activeListIds;
  final List<ModelConfig> allModels;
  final List<ModelConfig> availableModels;
  final Function(int, int) onReorder;
  final Function(int) onRemove;
  final Function(ModelConfig) onAdd;

  const SplitView({
    super.key,
    required this.activeListIds,
    required this.allModels,
    required this.availableModels,
    required this.onReorder,
    required this.onRemove,
    required this.onAdd,
  });

  ModelConfig? _getModel(String id) {
    try {
      return allModels.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        // Active Preference List
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Text(
                  l10n.priorityList,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Expanded(
                child: activeListIds.isEmpty
                    ? Center(
                        child: Text(
                          l10n.noPreferencesSetMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                      )
                    : ReorderableListView.builder(
                        itemCount: activeListIds.length,
                        onReorder: onReorder,
                        itemBuilder: (context, index) {
                          final model = _getModel(activeListIds[index]);
                          if (model == null)
                            return SizedBox(key: ValueKey('null_$index'));

                          return ListTile(
                            key: ValueKey(model.id),
                            leading: const Icon(Icons.drag_handle),
                            title: Text(
                              model.displayName ??
                                  model.modelName ??
                                  l10n.unknownModel,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(model.type.displayName),
                                const SizedBox(height: 4),
                                _buildCapabilityIcons(context, model),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () => onRemove(index),
                              color: Colors.red,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 1),
        // Available Models List
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Text(
                  l10n.availableModels,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: availableModels.length,
                  itemBuilder: (context, index) {
                    final model = availableModels[index];
                    return ListTile(
                      title: Text(
                        model.displayName ??
                            model.modelName ??
                            l10n.unknownModel,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(model.type.displayName),
                          const SizedBox(height: 4),
                          _buildCapabilityIcons(context, model),
                        ],
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => onAdd(model),
                        color: Colors.green,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCapabilityIcons(BuildContext context, ModelConfig model) {
    final caps = model.customCapabilitiesObject;
    if (caps == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final icons = <Widget>[];

    if (caps.supportsImages) {
      icons.add(_buildIcon(Icons.image, l10n.imageInputCapability, Colors.blue));
    }
    if (caps.supportsVideo) {
      icons.add(
        _buildIcon(Icons.videocam, l10n.videoInputCapability, Colors.purple),
      );
    }
    if (caps.supportsAudio) {
      icons.add(_buildIcon(Icons.mic, l10n.audioInputCapability, Colors.orange));
    }
    if (caps.supportsDocuments) {
      icons.add(
        _buildIcon(Icons.description, l10n.docsCapability, Colors.brown),
      );
    }
    if (caps.supportsImageGeneration) {
      icons.add(_buildIcon(Icons.brush, l10n.imageGenCapability, Colors.pink));
    }
    if (caps.supportsSpeechGeneration) {
      icons.add(
        _buildIcon(
          Icons.record_voice_over,
          l10n.speechGenCapability,
          Colors.indigo,
        ),
      );
    }
    if (caps.supportsCodeGeneration) {
      icons.add(_buildIcon(Icons.code, l10n.codeGenCapability, Colors.teal));
    }

    if (icons.isEmpty) return const SizedBox.shrink();

    return Wrap(spacing: 8, children: icons);
  }

  Widget _buildIcon(IconData icon, String tooltip, Color color) {
    return Tooltip(
      message: tooltip,
      child: Icon(icon, size: 16, color: color),
    );
  }
}

class _FeatureMatrixSheet extends StatelessWidget {
  final List<ModelConfig> models;

  const _FeatureMatrixSheet({required this.models});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.modelFeatureMatrix,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: DataTable(
                  columnSpacing: 20,
                  columns: [
                    DataColumn(label: Text(l10n.modelNameColumn)),
                    DataColumn(label: Text(l10n.imageInColumn)),
                    DataColumn(label: Text(l10n.videoInColumn)),
                    DataColumn(label: Text(l10n.audioColumn)),
                    DataColumn(label: Text(l10n.imgGenColumn)),
                    DataColumn(label: Text(l10n.ttsGenColumn)),
                    DataColumn(label: Text(l10n.codeGenColumn)),
                    DataColumn(label: Text(l10n.docsColumn)),
                  ],
                  rows: models.map((model) {
                    final caps = model.customCapabilitiesObject;
                    return DataRow(
                      cells: [
                        DataCell(
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                model.displayName ??
                                    model.modelName ??
                                    l10n.unknown,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                model.type.displayName,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildBoolCell(caps?.supportsImages ?? false),
                        _buildBoolCell(caps?.supportsVideo ?? false),
                        _buildBoolCell(caps?.supportsAudio ?? false),
                        _buildBoolCell(caps?.supportsImageGeneration ?? false),
                        _buildBoolCell(caps?.supportsSpeechGeneration ?? false),
                        _buildBoolCell(caps?.supportsCodeGeneration ?? false),
                        _buildBoolCell(caps?.supportsDocuments ?? false),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  DataCell _buildBoolCell(bool value) {
    return DataCell(
      Icon(
        value ? Icons.check_circle : Icons.cancel,
        color: value ? Colors.green : Colors.grey[300],
        size: 20,
      ),
    );
  }
}
