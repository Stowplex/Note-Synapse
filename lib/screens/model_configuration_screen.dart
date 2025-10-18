import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/model_type.dart';
import '../models/model_config.dart';
import '../services/model_storage_service.dart';
import '../services/model_selector.dart';

class ModelConfigurationScreen extends StatefulWidget {
  final ModelType modelType;

  const ModelConfigurationScreen({
    super.key,
    required this.modelType,
  });

  @override
  State<ModelConfigurationScreen> createState() => _ModelConfigurationScreenState();
}

class _ModelConfigurationScreenState extends State<ModelConfigurationScreen> {
  final _apiKeyController = TextEditingController();
  final _endpointController = TextEditingController();
  final _modelNameController = TextEditingController();
  final _maxInputTokensController = TextEditingController();
  final _maxOutputTokensController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  
  bool _isLoading = false;
  String? _error;
  
  // Capability checkboxes for OpenAI
  bool _supportsImages = false;
  bool _supportsDocuments = false;
  bool _supportsAudio = false;
  bool _supportsVideo = false;

  @override
  void initState() {
    super.initState();
    _loadExistingConfiguration();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _endpointController.dispose();
    _modelNameController.dispose();
    _maxInputTokensController.dispose();
    _maxOutputTokensController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingConfiguration() async {
    try {
      final config = await ModelStorageService.getModelConfig(widget.modelType);
      final apiKey = await ModelStorageService.getModelApiKey(widget.modelType);
      
      if (mounted) {
        setState(() {
          _apiKeyController.text = apiKey ?? '';
          _endpointController.text = config.endpoint ?? '';
          _modelNameController.text = config.modelName ?? '';
          _maxInputTokensController.text = config.customCapabilities['maxInputTokens']?.toString() ?? '100000';
          _maxOutputTokensController.text = config.customCapabilities['maxOutputTokens']?.toString() ?? '4000';
          _supportsImages = config.customCapabilities['supportsImages'] ?? false;
          _supportsDocuments = config.customCapabilities['supportsDocuments'] ?? false;
          _supportsAudio = config.customCapabilities['supportsAudio'] ?? false;
          _supportsVideo = config.customCapabilities['supportsVideo'] ?? false;
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
      final maxInputTokens = int.tryParse(_maxInputTokensController.text.trim()) ?? 100000;
      final maxOutputTokens = int.tryParse(_maxOutputTokensController.text.trim()) ?? 4000;
      
      Map<String, dynamic> customCapabilities = {};
      if (widget.modelType == ModelType.openaiCompatible) {
        customCapabilities = {
          'maxInputTokens': maxInputTokens,
          'maxOutputTokens': maxOutputTokens,
          'supportsImages': _supportsImages,
          'supportsDocuments': _supportsDocuments,
          'supportsAudio': _supportsAudio,
          'supportsVideo': _supportsVideo,
        };
      }

      final config = ModelConfig(
        type: widget.modelType,
        apiKey: apiKey.isNotEmpty ? apiKey : null,
        endpoint: endpoint.isNotEmpty ? endpoint : null,
        modelName: modelName.isNotEmpty ? modelName : null,
        customCapabilities: customCapabilities,
      );
      
      await ModelStorageService.saveModelConfig(config);

      // Only switch to the model if it's not already the current one
      final currentModel = await ModelStorageService.getSelectedModel();
      if (currentModel != widget.modelType) {
        await ModelSelector.instance.switchToModel(widget.modelType);
      }

      if (mounted) {
        Navigator.of(context).pop(true); // Return true to indicate successful configuration
      }
    } catch (e) {
      setState(() {
        _error = 'Error configuring model: $e';
        _isLoading = false;
      });
    }
  }



  Future<void> _openApiKeyUrl() async {
    String url;
    switch (widget.modelType) {
      case ModelType.gemini25Flash:
        url = 'https://aistudio.google.com/app/apikey';
        break;
      case ModelType.openaiCompatible:
        url = 'https://platform.openai.com/api-keys';
        break;
    }
    
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Configure ${widget.modelType.displayName}'),
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
              
              _buildApiKeySection(),
              if (widget.modelType == ModelType.openaiCompatible) ...[
                const SizedBox(height: 24),
                _buildEndpointSection(),
                const SizedBox(height: 24),
                _buildModelNameSection(),
                const SizedBox(height: 24),
                _buildTokenLimitsSection(),
                const SizedBox(height: 24),
                _buildCapabilitiesSection(),
              ],
              
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

  Widget _buildModelInfoCard() {
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
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_getModelDescription()),
          ],
        ),
      ),
    );
  }

  Widget _buildApiKeySection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'API Key',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _getApiKeyDescription(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiKeyController,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: 'Enter your API key',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: _openApiKeyUrl,
                  tooltip: 'Get API Key',
                ),
              ),
              obscureText: true,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter an API key';
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'API Endpoint',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the OpenAI-compatible API endpoint URL',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _endpointController,
              decoration: const InputDecoration(
                labelText: 'Endpoint URL',
                hintText: 'https://api.openai.com/v1/chat/completions',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter an endpoint URL';
                }
                final uri = Uri.tryParse(value);
                if (uri == null || !uri.hasAbsolutePath) {
                  return 'Please enter a valid URL';
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Model Name',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the model name to use (e.g., gpt-4, gpt-3.5-turbo, claude-3-sonnet)',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _modelNameController,
              decoration: const InputDecoration(
                labelText: 'Model Name',
                hintText: 'gpt-4',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.smart_toy),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter a model name';
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTokenLimitsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Token Limits',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Configure the maximum input and output tokens for this model',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _maxInputTokensController,
                    decoration: const InputDecoration(
                      labelText: 'Max Input Tokens',
                      hintText: '100000',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.input),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Required';
                      }
                      final tokens = int.tryParse(value.trim());
                      if (tokens == null || tokens <= 0) {
                        return 'Must be a positive number';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _maxOutputTokensController,
                    decoration: const InputDecoration(
                      labelText: 'Max Output Tokens',
                      hintText: '4000',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.output),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Required';
                      }
                      final tokens = int.tryParse(value.trim());
                      if (tokens == null || tokens <= 0) {
                        return 'Must be a positive number';
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Model Capabilities',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Select which capabilities this model supports',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              title: const Text('Image Processing'),
              subtitle: const Text('Can analyze and understand images'),
              value: _supportsImages,
              onChanged: (value) {
                setState(() {
                  _supportsImages = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: const Text('Document Understanding'),
              subtitle: const Text('Can process PDFs and documents'),
              value: _supportsDocuments,
              onChanged: (value) {
                setState(() {
                  _supportsDocuments = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: const Text('Audio Processing'),
              subtitle: const Text('Can transcribe and analyze audio'),
              value: _supportsAudio,
              onChanged: (value) {
                setState(() {
                  _supportsAudio = value ?? false;
                });
              },
            ),
            CheckboxListTile(
              title: const Text('Video Processing'),
              subtitle: const Text('Can analyze video content'),
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
            child: Text(
              _error!,
              style: TextStyle(color: Colors.red[600]),
            ),
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
        child: _isLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Continue'),
      ),
    );
  }

  IconData _getModelIcon() {
    switch (widget.modelType) {
      case ModelType.gemini25Flash:
        return Icons.psychology;
      case ModelType.openaiCompatible:
        return Icons.api;
    }
  }

  String _getModelDescription() {
    switch (widget.modelType) {
      case ModelType.gemini25Flash:
        return 'Google\'s most advanced model with full multimodal capabilities including document understanding.';
      case ModelType.openaiCompatible:
        return 'Compatible with OpenAI API endpoints. Configure the endpoint URL and select supported capabilities.';
    }
  }

  String _getApiKeyDescription() {
    switch (widget.modelType) {
      case ModelType.gemini25Flash:
        return 'Get your API key from Google AI Studio';
      case ModelType.openaiCompatible:
        return 'Get your API key from your OpenAI-compatible service provider';
    }
  }

}
