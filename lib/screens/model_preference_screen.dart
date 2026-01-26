import 'package:flutter/material.dart';
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
            content: Text('Error loading model preferences: $e'),
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
            content: Text('Error saving preferences: $e'),
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
    // Determine available models not yet in the list
    final availableModels = _allModels
        .where((m) => !_preferenceListIds.contains(m.id))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Model Preferences'),
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
            tooltip: 'View Feature Matrix',
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
                    'Drag and drop to reorder models. The first model that matches the required capabilities will be used. If the list is empty or no match is found, the system default model is used.',
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
                  'Priority List',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Expanded(
                child: activeListIds.isEmpty
                    ? Center(
                        child: Text(
                          'No preferences set.\nSystem default model will be used.',
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
                                  'Unknown Model',
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(model.type.displayName),
                                const SizedBox(height: 4),
                                _buildCapabilityIcons(model),
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
                  'Available Models',
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
                        model.displayName ?? model.modelName ?? 'Unknown Model',
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(model.type.displayName),
                          const SizedBox(height: 4),
                          _buildCapabilityIcons(model),
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

  Widget _buildCapabilityIcons(ModelConfig model) {
    final caps = model.customCapabilitiesObject;
    if (caps == null) return const SizedBox.shrink();

    final icons = <Widget>[];

    if (caps.supportsImages) {
      icons.add(_buildIcon(Icons.image, 'Image Input', Colors.blue));
    }
    if (caps.supportsVideo) {
      icons.add(_buildIcon(Icons.videocam, 'Video Input', Colors.purple));
    }
    if (caps.supportsAudio) {
      icons.add(_buildIcon(Icons.mic, 'Audio Input', Colors.orange));
    }
    if (caps.supportsDocuments) {
      icons.add(_buildIcon(Icons.description, 'Docs', Colors.brown));
    }
    if (caps.supportsImageGeneration) {
      icons.add(_buildIcon(Icons.brush, 'Image Gen', Colors.pink));
    }
    if (caps.supportsCodeGeneration) {
      icons.add(_buildIcon(Icons.code, 'Code Gen', Colors.teal));
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
                'Model Feature Matrix',
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
                  columns: const [
                    DataColumn(label: Text('Model Name')),
                    DataColumn(label: Text('Image In')),
                    DataColumn(label: Text('Video In')),
                    DataColumn(label: Text('Audio')),
                    DataColumn(label: Text('Img Gen')),
                    DataColumn(label: Text('Code Gen')),
                    DataColumn(label: Text('Docs')),
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
                                    'Unknown',
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
