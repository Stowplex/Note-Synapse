import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/model_type.dart';
import '../services/model_storage_service.dart';
import '../services/model_service.dart';
import '../services/logger_service.dart';

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
  final _formKey = GlobalKey<FormState>();
  
  bool _isLoading = false;
  bool _isDownloading = false;
  String? _error;
  double _downloadProgress = 0.0;
  
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
      
      Map<String, dynamic> customCapabilities = {};
      if (widget.modelType == ModelType.openaiCompatible) {
        customCapabilities = {
          'supportsImages': _supportsImages,
          'supportsDocuments': _supportsDocuments,
          'supportsAudio': _supportsAudio,
          'supportsVideo': _supportsVideo,
        };
      }

      await ModelService.instance.configureModel(
        widget.modelType,
        apiKey: apiKey.isNotEmpty ? apiKey : null,
        endpoint: endpoint.isNotEmpty ? endpoint : null,
        modelName: modelName.isNotEmpty ? modelName : null,
        customCapabilities: customCapabilities,
      );

      // Switch to the newly configured model
      await ModelService.instance.switchToModel(widget.modelType);

      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/main');
      }
    } catch (e) {
      setState(() {
        _error = 'Error configuring model: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _downloadModel() async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _error = null;
    });

    try {
      // Save API key temporarily for download (for models that require it)
      if (widget.modelType == ModelType.gemma3n && _apiKeyController.text.trim().isNotEmpty) {
        final apiKey = _apiKeyController.text.trim();
        LoggerService.debug('ModelConfigurationScreen: Saving API key for download, length: ${apiKey.length}');
        await ModelStorageService.saveModelApiKey(widget.modelType, apiKey);
        LoggerService.debug('ModelConfigurationScreen: API key saved successfully');
      } else if (widget.modelType == ModelType.gemma3n) {
        LoggerService.warning('ModelConfigurationScreen: No API key provided for Gemma model');
      }
      
      // Use real download progress
      await ModelService.instance.downloadModel(
        widget.modelType,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _downloadProgress = progress;
            });
          }
        },
      );
      
      // Switch to the newly downloaded model
      await ModelService.instance.switchToModel(widget.modelType);
      
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Model downloaded and activated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = 'Error downloading model: $e';
        _isDownloading = false;
      });
      
      // Reset configuration state so user can try again
      try {
        await ModelService.instance.resetModelConfiguration(widget.modelType);
      } catch (resetError) {
        LoggerService.error('Error resetting model configuration: $resetError');
      }
    }
  }

  Future<void> _resetConfiguration() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await ModelService.instance.resetModelConfiguration(widget.modelType);
      
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Configuration reset successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = 'Error resetting configuration: $e';
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
      case ModelType.gemma3n:
        url = 'https://huggingface.co/settings/tokens';
        break;
      case ModelType.openaiCompatible:
        url = 'https://platform.openai.com/api-keys';
        break;
      case ModelType.qwen25:
        // No API key needed for Qwen
        return;
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
              
              if (widget.modelType == ModelType.qwen25) ...[
                _buildDownloadSection(),
              ] else ...[
                _buildApiKeySection(),
                if (widget.modelType == ModelType.openaiCompatible) ...[
                  const SizedBox(height: 24),
                  _buildEndpointSection(),
                  const SizedBox(height: 24),
                  _buildModelNameSection(),
                  const SizedBox(height: 24),
                  _buildCapabilitiesSection(),
                ],
                if (widget.modelType == ModelType.gemma3n) ...[
                  const SizedBox(height: 24),
                  _buildDownloadSection(),
                ],
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

  Widget _buildDownloadSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Download Model',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _getDownloadDescription(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            if (_isDownloading) ...[
              Column(
                children: [
                  LinearProgressIndicator(value: _downloadProgress),
                  const SizedBox(height: 8),
                  Text('Downloading... ${(_downloadProgress * 100).toInt()}%'),
                ],
              ),
            ] else ...[
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _downloadModel,
                      icon: const Icon(Icons.download),
                      label: const Text('Download Model'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _resetConfiguration,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset Configuration'),
                    ),
                  ),
                ],
              ),
            ],
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
      case ModelType.gemma3n:
        return Icons.smart_toy;
      case ModelType.qwen25:
        return Icons.chat;
      case ModelType.openaiCompatible:
        return Icons.api;
    }
  }

  String _getModelDescription() {
    switch (widget.modelType) {
      case ModelType.gemini25Flash:
        return 'Google\'s most advanced model with full multimodal capabilities including document understanding.';
      case ModelType.gemma3n:
        return 'Google\'s efficient model with most capabilities except document understanding. Requires Hugging Face token and model download.';
      case ModelType.qwen25:
        return 'High-performance text-only model for fast text generation. Requires model download.';
      case ModelType.openaiCompatible:
        return 'Compatible with OpenAI API endpoints. Configure the endpoint URL and select supported capabilities.';
    }
  }

  String _getApiKeyDescription() {
    switch (widget.modelType) {
      case ModelType.gemini25Flash:
        return 'Get your API key from Google AI Studio';
      case ModelType.gemma3n:
        return 'Get your Hugging Face token from your account settings';
      case ModelType.openaiCompatible:
        return 'Get your API key from your OpenAI-compatible service provider';
      case ModelType.qwen25:
        return 'No API key required for local models';
    }
  }

  String _getDownloadDescription() {
    switch (widget.modelType) {
      case ModelType.gemma3n:
        return 'Download the Gemma 3n model from Hugging Face. This may take several minutes depending on your internet connection.';
      case ModelType.qwen25:
        return 'Download the Qwen 2.5 model from Hugging Face. This may take several minutes depending on your internet connection.';
      default:
        return 'This model does not require download.';
    }
  }
}
