import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/model_type.dart';
import '../models/model_config.dart';
import '../models/model_capabilities.dart';
import '../services/model_storage_service.dart';
import '../services/service_locator.dart';
import '../services/model_selector.dart';
import '../services/model_preset_service.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';

class ModelConfigurationScreen extends StatefulWidget {
  final ModelConfig? config; // If provided, we are editing
  final ModelType? initialType; // If adding, start with this type
  final bool isOnboarding;

  const ModelConfigurationScreen({
    super.key,
    this.config,
    this.initialType,
    this.isOnboarding = false,
  });

  @override
  State<ModelConfigurationScreen> createState() =>
      _ModelConfigurationScreenState();
}

class _ModelConfigurationScreenState extends State<ModelConfigurationScreen> {
  final _apiKeyController = TextEditingController();
  final _endpointController = TextEditingController();
  final _modelNameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _maxInputTokensController = TextEditingController();
  final _maxOutputTokensController = TextEditingController();
  final _supportedAttachmentMimeTypesController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  String? _error;

  late ModelType _selectedType;
  bool _isEditing = false;

  bool _supportsImages = false;
  bool _supportsDocuments = false;
  bool _supportsAudio = false;
  bool _supportsVideo = false;
  bool _supportsImageGeneration = false;
  bool _supportsCodeGeneration = false;

  List<ModelConfig> _presets = [];
  ModelConfig? _selectedPreset;
  Map<String, bool> _premiumWarnings = {};
  Map<String, String> _presetApiKeyUrls = {};
  String? _apiKeyUrl;
  List<String>? _existingModelFeatures;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.config != null;
    _selectedType =
        widget.config?.type ?? widget.initialType ?? ModelType.gemini;

    if (_isEditing) {
      _loadExistingConfiguration();
    } else {
      _loadPresets();
      _setDefaultApiKeyUrl();
    }
  }

  void _setDefaultApiKeyUrl() {
    switch (_selectedType) {
      case ModelType.gemini:
        _apiKeyUrl = 'https://aistudio.google.com/app/apikey';
        break;
      case ModelType.openaiCompatible:
        _apiKeyUrl = 'https://platform.openai.com/api-keys';
        break;
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _endpointController.dispose();
    _modelNameController.dispose();
    _displayNameController.dispose();
    _maxInputTokensController.dispose();
    _maxOutputTokensController.dispose();
    _supportedAttachmentMimeTypesController.dispose();
    super.dispose();
  }

  Future<void> _loadPresets() async {
    try {
      final presets = await ModelPresetService.instance.loadPresets();

      // Filter presets for current model type
      final modelPresets = presets
          .where((p) => p.type == _selectedType)
          .toList();

      // Add "Custom" preset option
      if (_selectedType == ModelType.gemini) {
        modelPresets.add(
          ModelConfig(
            type: ModelType.gemini,
            displayName: 'Custom',
            endpoint: 'https://generativelanguage.googleapis.com/v1beta',
          ),
        );
      } else if (_selectedType == ModelType.openaiCompatible) {
        modelPresets.add(
          ModelConfig(type: ModelType.openaiCompatible, displayName: 'Custom'),
        );
      }

      if (mounted) {
        setState(() {
          _presets = modelPresets;

          // Update auxiliary maps from service
          for (final preset in modelPresets) {
            if (preset.displayName != null) {
              final displayName = preset.displayName!;
              if (ModelPresetService.instance.hasPremiumWarning(displayName)) {
                _premiumWarnings[displayName] = true;
              }

              final apiKeyUrl = ModelPresetService.instance.getApiKeyUrl(
                displayName,
              );
              if (apiKeyUrl != null) {
                _presetApiKeyUrls[displayName] = apiKeyUrl;
              }
            }
          }
        });
      }
    } catch (e) {
      // Handle error loading presets
      debugPrint('Error loading presets: $e');
    }
  }

  void _applyPreset(ModelConfig? preset) {
    if (preset == null) return;

    if (_premiumWarnings[preset.displayName] == true) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Premium Model'),
          content: const Text(
            'This model may incur costs. Please ensure you have set up billing with the provider.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }

    setState(() {
      _selectedPreset = preset;
      _endpointController.text = preset.endpoint ?? '';
      _modelNameController.text = preset.modelName ?? '';
      // Don't overwrite display name if user has already typed something, unless it was empty
      _displayNameController.text = preset.displayName ?? '';
      _maxInputTokensController.text = preset.maxInputTokens?.toString() ?? '';
      _maxOutputTokensController.text =
          preset.maxOutputTokens?.toString() ?? '';
      _supportsImages =
          preset.customCapabilitiesObject?.supportsImages ?? false;
      _supportsDocuments =
          preset.customCapabilitiesObject?.supportsDocuments ?? false;
      _supportsAudio = preset.customCapabilitiesObject?.supportsAudio ?? false;
      _supportsVideo = preset.customCapabilitiesObject?.supportsVideo ?? false;
      _supportsImageGeneration =
          preset.customCapabilitiesObject?.supportsImageGeneration ?? false;
      _supportsCodeGeneration =
          preset.customCapabilitiesObject?.supportsCodeGeneration ?? false;
      _supportedAttachmentMimeTypesController.text =
          preset.supportedAttachmentMimeTypes?.join(', ') ?? '';

      // Set API key URL from preset
      _apiKeyUrl = preset.displayName != null
          ? _presetApiKeyUrls[preset.displayName]
          : null;

      // If no specific URL, fallback to default
      if (_apiKeyUrl == null) {
        _setDefaultApiKeyUrl();
      }
    });
  }

  Future<void> _loadExistingConfiguration() async {
    try {
      final config = widget.config!;
      // Load API key using ID
      final apiKey = await getIt<ModelStorageService>().getModelApiKey(
        config.id,
      );

      if (mounted) {
        setState(() {
          _apiKeyController.text = apiKey ?? '';
          _endpointController.text = config.endpoint ?? '';
          _modelNameController.text = config.modelName ?? '';
          _displayNameController.text = config.displayName ?? '';
          _maxInputTokensController.text =
              config.maxInputTokens?.toString() ?? '';
          _maxOutputTokensController.text =
              config.maxOutputTokens?.toString() ?? '';
          _supportsImages =
              config.customCapabilitiesObject?.supportsImages ?? false;
          _supportsDocuments =
              config.customCapabilitiesObject?.supportsDocuments ?? false;
          _supportsAudio =
              config.customCapabilitiesObject?.supportsAudio ?? false;
          _supportsVideo =
              config.customCapabilitiesObject?.supportsVideo ?? false;
          _supportsImageGeneration =
              config.customCapabilitiesObject?.supportsImageGeneration ?? false;
          _supportsCodeGeneration =
              config.customCapabilitiesObject?.supportsCodeGeneration ?? false;
          _supportedAttachmentMimeTypesController.text =
              config.supportedAttachmentMimeTypes?.join(', ') ?? '';
          _existingModelFeatures = config.modelFeatures;

          // Also load presets to allow switching preset even when editing
          _loadPresets();
        });
      }
    } catch (e) {
      // Ignore errors when loading existing configuration
      debugPrint('Error loading existing config: $e');
    }
  }

  Future<void> _configureModel() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final apiKey = _apiKeyController.text.trim();
      final endpoint = _endpointController.text.trim();
      final modelName = _modelNameController.text.trim();
      final displayName = _displayNameController.text.trim();
      final maxInputTokens = int.tryParse(
        _maxInputTokensController.text.trim(),
      );
      final maxOutputTokens = int.tryParse(
        _maxOutputTokensController.text.trim(),
      );
      final supportedAttachmentMimeTypes = _parseSupportedMimeTypes(
        _supportedAttachmentMimeTypesController.text,
      );

      final capabilities = ModelCapabilities(
        maxInputTokens: maxInputTokens ?? 100000,
        maxOutputTokens: maxOutputTokens ?? 4000,
        supportsImages: _supportsImages,
        supportsDocuments: _supportsDocuments,
        supportsAudio: _supportsAudio,
        supportsVideo: _supportsVideo,
        supportsImageGeneration: _supportsImageGeneration,
        supportsCodeGeneration: _supportsCodeGeneration,
      );

      // If editing, use existing ID. If adding, ModelConfig constructor generates new ID.
      final config = _isEditing
          ? widget.config!.copyWith(
              apiKey: apiKey.isNotEmpty ? apiKey : null,
              endpoint: endpoint.isNotEmpty ? endpoint : null,
              modelName: modelName.isNotEmpty ? modelName : null,
              displayName: displayName.isNotEmpty ? displayName : null,
              maxInputTokens: maxInputTokens,
              maxOutputTokens: maxOutputTokens,
              customCapabilitiesObject: capabilities,
              supportedAttachmentMimeTypes: supportedAttachmentMimeTypes,
              modelFeatures:
                  _selectedPreset?.modelFeatures ?? _existingModelFeatures,
              isConfigured: true,
            )
          : ModelConfig(
              type: _selectedType,
              apiKey: apiKey.isNotEmpty ? apiKey : null,
              endpoint: endpoint.isNotEmpty ? endpoint : null,
              modelName: modelName.isNotEmpty ? modelName : null,
              displayName: displayName.isNotEmpty ? displayName : null,
              maxInputTokens: maxInputTokens,
              maxOutputTokens: maxOutputTokens,
              customCapabilitiesObject: capabilities,
              supportedAttachmentMimeTypes: supportedAttachmentMimeTypes,
              modelFeatures:
                  _selectedPreset?.modelFeatures ?? _existingModelFeatures,
              isConfigured: true,
            );

      // Save configuration
      if (_isEditing) {
        await getIt<ModelStorageService>().updateModel(config);
      } else {
        await getIt<ModelStorageService>().addModel(config);
      }

      // Save API Key securely
      if (apiKey.isNotEmpty) {
        await getIt<ModelStorageService>().saveModelApiKey(config.id, apiKey);
      }

      // If this is the first model or user wants to use it, we could activate it.
      // For now, let's just save it. The user can activate it from the list.
      // But if we are editing the active model, we should probably reload it.
      final activeModel = await getIt<ModelStorageService>().getActiveModel();
      if (activeModel?.id == config.id) {
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        appProvider.updateModelConfig(config);
        await getIt<ModelSelector>().switchToModel(config);
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _error = l10n.errorConfiguringModel(e.toString());
        _isLoading = false;
      });
    }
  }

  Future<void> _openApiKeyUrl() async {
    if (_apiKeyUrl == null) return;

    if (await canLaunchUrl(Uri.parse(_apiKeyUrl!))) {
      await launchUrl(Uri.parse(_apiKeyUrl!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isEditing
        ? 'Edit ${widget.config?.displayName ?? "Model"}'
        : 'Add New Model';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_isEditing) ...[
                _buildModelTypeSelector(),
                const SizedBox(height: 24),
              ],
              _buildModelInfoCard(),
              const SizedBox(height: 24),
              _buildPresetSelector(),
              const SizedBox(height: 24),
              _buildApiKeySection(),
              const SizedBox(height: 24),
              // Show these sections for all types now, as they are configurable
              _buildEndpointSection(),
              const SizedBox(height: 24),
              _buildModelNameSection(),
              const SizedBox(height: 24),
              _buildDisplayNameSection(),
              const SizedBox(height: 24),
              _buildTokenLimitsSection(),
              const SizedBox(height: 24),
              _buildSupportedMimeSection(),
              const SizedBox(height: 24),
              _buildCapabilitiesSection(),
              const SizedBox(height: 24),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _buildErrorCard(),
              ],
              const SizedBox(height: 24),
              _buildActionButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelTypeSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Model Type',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<ModelType>(
              value: _selectedType,
              items: ModelType.values.map((type) {
                return DropdownMenuItem<ModelType>(
                  value: type,
                  child: Row(
                    children: [
                      Icon(_getModelIconForType(type), size: 20),
                      const SizedBox(width: 8),
                      Text(type.displayName),
                    ],
                  ),
                );
              }).toList(),
              onChanged: (type) {
                if (type != null) {
                  setState(() {
                    _selectedType = type;
                    _presets = []; // Clear presets to reload for new type
                    _selectedPreset = null;
                    _setDefaultApiKeyUrl();
                    _loadPresets();
                  });
                }
              },
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetSelector() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.loadPreset,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<ModelConfig>(
              value: _selectedPreset,
              items: _presets.map((preset) {
                return DropdownMenuItem<ModelConfig>(
                  value: preset,
                  child: Text(
                    preset.displayName ??
                        preset.modelName ??
                        l10n.unknownPreset,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (preset) => _applyPreset(preset),
              decoration: InputDecoration(
                labelText: l10n.selectPreset,
                border: const OutlineInputBorder(),
              ),
              isExpanded: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelInfoCard() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_getModelIcon(), color: Theme.of(context).primaryColor),
                const SizedBox(width: 12),
                Text(
                  _selectedType.displayName,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_getModelDescription(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _buildApiKeySection() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.apiKey,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _getApiKeyDescription(_selectedType, l10n),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiKeyController,
              decoration: InputDecoration(
                labelText: l10n.apiKey,
                hintText: l10n.apiKeyHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: _apiKeyUrl != null
                    ? IconButton(
                        icon: const Icon(Icons.open_in_new),
                        onPressed: _openApiKeyUrl,
                        tooltip: l10n.getApiKey,
                      )
                    : null,
              ),
              obscureText: true,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.pleaseEnterApiKey;
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEndpointSection() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.apiEndpoint,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.apiEndpointDescription,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _endpointController,
              decoration: InputDecoration(
                labelText: l10n.endpointUrl,
                hintText: l10n.endpointUrlHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.link),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.pleaseEnterEndpointUrl;
                }
                final uri = Uri.tryParse(value);
                if (uri == null || !uri.hasAbsolutePath) {
                  return l10n.pleaseEnterValidUrl;
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelNameSection() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.modelName,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.modelNameDescription,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _modelNameController,
              decoration: InputDecoration(
                labelText: l10n.modelName,
                hintText: l10n.modelNameHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.smart_toy),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.pleaseEnterModelName;
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisplayNameSection() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.displayName,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.displayNameDescription,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _displayNameController,
              decoration: InputDecoration(
                labelText: l10n.displayName,
                hintText: l10n.displayNameHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.badge),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTokenLimitsSection() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.tokenLimits,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.tokenLimitsDescription,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _maxInputTokensController,
                    decoration: InputDecoration(
                      labelText: l10n.maxInputTokens,
                      hintText: l10n.maxInputTokensHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.input),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return l10n.required;
                      }
                      final tokens = int.tryParse(value.trim());
                      if (tokens == null || tokens <= 0) {
                        return l10n.mustBePositiveNumber;
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _maxOutputTokensController,
                    decoration: InputDecoration(
                      labelText: l10n.maxOutputTokens,
                      hintText: l10n.maxOutputTokensHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.output),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return l10n.required;
                      }
                      final tokens = int.tryParse(value.trim());
                      if (tokens == null || tokens <= 0) {
                        return l10n.mustBePositiveNumber;
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapabilitiesSection() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.modelCapabilities,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.modelCapabilitiesDescription,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              title: Text(l10n.imageProcessing),
              subtitle: Text(l10n.imageProcessingDescription),
              value: _supportsImages,
              onChanged: (value) {
                setState(() {
                  _supportsImages = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: Text(l10n.documentUnderstanding),
              subtitle: Text(l10n.documentUnderstandingDescription),
              value: _supportsDocuments,
              onChanged: (value) {
                setState(() {
                  _supportsDocuments = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: Text(l10n.audioProcessing),
              subtitle: Text(l10n.audioProcessingDescription),
              value: _supportsAudio,
              onChanged: (value) {
                setState(() {
                  _supportsAudio = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: Text(l10n.videoProcessing),
              subtitle: Text(l10n.videoProcessingDescription),
              value: _supportsVideo,
              onChanged: (value) {
                setState(() {
                  _supportsVideo = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: const Text('Generate Image'),
              subtitle: const Text(
                'Model can generate images from text prompts',
              ),
              value: _supportsImageGeneration,
              onChanged: (value) {
                setState(() {
                  _supportsImageGeneration = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: const Text('Code Generation'),
              subtitle: const Text(
                'Model is optimized for writing and debugging code',
              ),
              value: _supportsCodeGeneration,
              onChanged: (value) {
                setState(() {
                  _supportsCodeGeneration = value ?? false;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupportedMimeSection() {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.supportedAttachmentMimeTypesLabel,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.supportedAttachmentMimeTypesHelper,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _supportedAttachmentMimeTypesController,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l10n.supportedAttachmentMimeTypesLabel,
                hintText: l10n.supportedAttachmentMimeTypesHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String>? _parseSupportedMimeTypes(String raw) {
    final entries = raw
        .split(RegExp(r'[,\n]'))
        .map((entry) => entry.trim().toLowerCase())
        .where((entry) => entry.isNotEmpty)
        .toList();
    return entries.isEmpty ? null : entries;
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Row(
        children: [
          Icon(Icons.error, color: Colors.red[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_error!, style: TextStyle(color: Colors.red[600])),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    return SizedBox(
      height: 50,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _configureModel,
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).primaryColor,
          foregroundColor: Colors.white,
        ),
        child: _isLoading
            ? const CircularProgressIndicator(color: Colors.white)
            : Text('Save Configuration'),
      ),
    );
  }

  IconData _getModelIcon() {
    return _getModelIconForType(_selectedType);
  }

  IconData _getModelIconForType(ModelType type) {
    switch (type) {
      case ModelType.gemini:
        return Icons.auto_awesome;
      case ModelType.openaiCompatible:
        return Icons.smart_toy;
    }
  }

  String _getModelDescription(AppLocalizations l10n) {
    switch (_selectedType) {
      case ModelType.gemini:
        return 'Google\'s most advanced model with full multimodal capabilities';
      case ModelType.openaiCompatible:
        return 'Compatible with OpenAI API endpoints with configurable capabilities';
    }
  }

  String _getApiKeyDescription(ModelType type, AppLocalizations l10n) {
    switch (type) {
      case ModelType.gemini:
        return l10n.geminiApiKey;
      case ModelType.openaiCompatible:
        return 'API Key for OpenAI compatible provider';
    }
  }
}
