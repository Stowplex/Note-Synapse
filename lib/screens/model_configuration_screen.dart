import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yaml/yaml.dart';
import '../models/model_type.dart';
import '../models/model_config.dart';
import '../models/model_capabilities.dart';
import '../services/model_storage_service.dart';
import '../services/model_selector.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';

class ModelConfigurationScreen extends StatefulWidget {
  final ModelType modelType;

  const ModelConfigurationScreen({super.key, required this.modelType});

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

  bool _supportsImages = false;
  bool _supportsDocuments = false;
  bool _supportsAudio = false;
  bool _supportsVideo = false;

  List<ModelConfig> _presets = [];
  ModelConfig? _selectedPreset;
  Map<String, bool> _premiumWarnings = {};
  Map<String, String> _presetApiKeyUrls = {};
  String? _apiKeyUrl;
  List<String>? _existingModelFeatures;

  @override
  void initState() {
    super.initState();
    _loadExistingConfiguration();
    _loadPresets();

    // Set default API key URL based on model type
    _setDefaultApiKeyUrl();
  }

  void _setDefaultApiKeyUrl() {
    switch (widget.modelType) {
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
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);

      final presetFiles = manifestMap.keys
          .where((String key) => key.startsWith('assets/model_presets/'))
          .toList();

      List<ModelConfig> presets = [];
      Map<String, bool> premiumWarnings = {};
      Map<String, String> presetApiKeyUrls = {};
      for (final file in presetFiles) {
        final yamlString = await rootBundle.loadString(file);
        final doc = loadYaml(yamlString);

        final modelTypeString = doc['model_type'] as String?;
        if (modelTypeString != null && modelTypeString == widget.modelType.id) {
          final displayName = doc['model_display_name'] as String?;
          if (displayName != null) {
            premiumWarnings[displayName] =
                doc['warn_premium'] as bool? ?? false;

            // Store API key URL for this preset
            final apiKeyUrl = doc['api_key_url'] as String?;
            if (apiKeyUrl != null) {
              presetApiKeyUrls[displayName] = apiKeyUrl;
            }
          }

          final capabilities = ModelCapabilities(
            maxInputTokens: doc['max_input_token'] ?? 100000,
            maxOutputTokens: doc['max_output_token'] ?? 4000,
            supportsImages:
                doc['model_capabilities']?.contains('support_image') ?? false,
            supportsDocuments:
                doc['model_capabilities']?.contains(
                  'support_document_understanding',
                ) ??
                false,
            supportsAudio:
                doc['model_capabilities']?.contains('support_audio') ?? false,
            supportsVideo:
                doc['model_capabilities']?.contains('support_video') ?? false,
          );

          final supportedAttachmentMimeTypes =
              (doc['supported_attachment_mime_types'] as YamlList?)
                  ?.cast<dynamic>()
                  .whereType<String>()
                  .map((value) => value.trim())
                  .toList();

          final modelFeatures = (doc['model_features'] as YamlList?)
              ?.cast<dynamic>()
              .whereType<String>()
              .map((value) => value.trim())
              .toList();

          final preset = ModelConfig(
            type: ModelType.fromId(modelTypeString) ?? widget.modelType,
            endpoint: doc['model_endpoint'],
            modelName: doc['model_name'],
            displayName: displayName,
            maxInputTokens: doc['max_input_token'],
            maxOutputTokens: doc['max_output_token'],
            customCapabilitiesObject: capabilities,
            supportedAttachmentMimeTypes: supportedAttachmentMimeTypes,
            modelFeatures: modelFeatures,
          );
          presets.add(preset);
        }
      }

      if (widget.modelType == ModelType.gemini) {
        presets.add(
          ModelConfig(
            type: ModelType.gemini,
            displayName: 'Custom',
            endpoint: 'https://generativelanguage.googleapis.com/v1beta',
          ),
        );
      }

      if (widget.modelType == ModelType.openaiCompatible) {
        presets.add(
          ModelConfig(type: ModelType.openaiCompatible, displayName: 'Custom'),
        );
      }

      setState(() {
        _presets = presets;
        _premiumWarnings = premiumWarnings;
        _presetApiKeyUrls = presetApiKeyUrls;
      });
    } catch (e) {
      // Handle error loading presets
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
      _supportedAttachmentMimeTypesController.text =
          preset.supportedAttachmentMimeTypes?.join(', ') ?? '';

      // Set API key URL from preset
      _apiKeyUrl = preset.displayName != null
          ? _presetApiKeyUrls[preset.displayName]
          : null;
    });
  }

  Future<void> _loadExistingConfiguration() async {
    try {
      final config = await ModelStorageService.getModelConfig(widget.modelType);
      final apiKey = await ModelStorageService.getModelApiKey(widget.modelType);

      if (mounted) {
        setState(() {
          _apiKeyController.text = apiKey ?? '';
          if (config != null) {
            _endpointController.text = config.endpoint ?? '';
            _modelNameController.text = config.modelName ?? '';
            _displayNameController.text = config.displayName ?? '';
            _maxInputTokensController.text =
                config.maxInputTokens?.toString() ?? '100000';
            _maxOutputTokensController.text =
                config.maxOutputTokens?.toString() ?? '4000';
            _supportsImages =
                config.customCapabilitiesObject?.supportsImages ?? false;
            _supportsDocuments =
                config.customCapabilitiesObject?.supportsDocuments ?? false;
            _supportsAudio =
                config.customCapabilitiesObject?.supportsAudio ?? false;
            _supportsVideo =
                config.customCapabilitiesObject?.supportsVideo ?? false;
            _supportedAttachmentMimeTypesController.text =
                config.supportedAttachmentMimeTypes?.join(', ') ?? '';
            _existingModelFeatures = config.modelFeatures;
          }
        });
      }
    } catch (e) {
      // Ignore errors when loading existing configuration
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
      );

      final config = ModelConfig(
        type: widget.modelType,
        apiKey: apiKey.isNotEmpty ? apiKey : null,
        endpoint: endpoint.isNotEmpty ? endpoint : null,
        modelName: modelName.isNotEmpty ? modelName : null,
        displayName: displayName.isNotEmpty ? displayName : null,
        maxInputTokens: maxInputTokens,
        maxOutputTokens: maxOutputTokens,
        customCapabilitiesObject: capabilities,
        supportedAttachmentMimeTypes: supportedAttachmentMimeTypes,
        modelFeatures: _selectedPreset?.modelFeatures ?? _existingModelFeatures,
        isConfigured: true,
      );

      await ModelStorageService.saveModelConfig(config);

      final appProvider = Provider.of<AppProvider>(context, listen: false);
      appProvider.updateModelConfig(config);

      // Always reload the model when configuration is saved to ensure
      // the model uses the updated configuration, even if it's the same model type
      await ModelSelector.instance.switchToModel(
        widget.modelType,
        config: config,
      );

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
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.configureModelTitle(widget.modelType.displayName)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildModelInfoCard(),
              const SizedBox(height: 24),
              _buildPresetSelector(),
              const SizedBox(height: 24),
              _buildApiKeySection(),
              const SizedBox(height: 24),
              if (widget.modelType == ModelType.openaiCompatible ||
                  widget.modelType == ModelType.gemini) ...[
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
              ],
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
              initialValue: _selectedPreset,
              items: _presets.map((preset) {
                return DropdownMenuItem<ModelConfig>(
                  value: preset,
                  child: Text(
                    preset.displayName ??
                        preset.modelName ??
                        l10n.unknownPreset,
                  ),
                );
              }).toList(),
              onChanged: (preset) => _applyPreset(preset),
              decoration: InputDecoration(
                labelText: l10n.selectPreset,
                border: const OutlineInputBorder(),
              ),
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
                  widget.modelType.displayName,
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
              _getApiKeyDescription(l10n),
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
    final l10n = AppLocalizations.of(context)!;

    return SizedBox(
      height: 50,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _configureModel,
        child: _isLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(l10n.continueButton),
      ),
    );
  }

  IconData _getModelIcon() {
    switch (widget.modelType) {
      case ModelType.gemini:
        return Icons.psychology;
      case ModelType.openaiCompatible:
        return Icons.api;
    }
  }

  String _getModelDescription(AppLocalizations l10n) {
    switch (widget.modelType) {
      case ModelType.gemini:
        return l10n.geminiModelDescriptionDetailed;
      case ModelType.openaiCompatible:
        return l10n.openaiCompatibleModelDescriptionDetailed;
    }
  }

  String _getApiKeyDescription(AppLocalizations l10n) {
    switch (widget.modelType) {
      case ModelType.gemini:
        return l10n.geminiApiKeyDescription;
      case ModelType.openaiCompatible:
        return l10n.openaiCompatibleApiKeyDescription;
    }
  }
}
