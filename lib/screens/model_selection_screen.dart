import 'package:flutter/material.dart';
import '../models/model_type.dart';
import '../models/model_capabilities.dart';
import '../services/model_storage_service.dart';
import 'model_configuration_screen.dart';

class ModelSelectionScreen extends StatefulWidget {
  const ModelSelectionScreen({super.key});

  @override
  State<ModelSelectionScreen> createState() => _ModelSelectionScreenState();
}

class _ModelSelectionScreenState extends State<ModelSelectionScreen> {
  ModelType? _selectedModel;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSelectedModel();
  }

  Future<void> _loadSelectedModel() async {
    try {
      final selectedModel = await ModelStorageService.getSelectedModel();
      setState(() {
        _selectedModel = selectedModel;
      });
    } catch (e) {
      // Use default if loading fails
      setState(() {
        _selectedModel = ModelType.gemini25Flash;
      });
    }
  }

  Future<void> _proceedToConfiguration() async {
    if (_selectedModel == null) {
      setState(() {
        _error = 'Please select a model';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Check if model is already configured
      final isConfigured = await ModelStorageService.isModelConfigured(_selectedModel!);
      
      if (isConfigured) {
        // Model is already configured, proceed to main app
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/main');
        }
      } else {
        // Navigate to configuration screen
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ModelConfigurationScreen(modelType: _selectedModel!),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Error checking model configuration: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              Icon(
                Icons.psychology,
                size: 80,
                color: Theme.of(context).primaryColor,
              ),
              const SizedBox(height: 24),
              Text(
                'Choose Your AI Model',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Select the AI model that best fits your needs',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Expanded(
                child: ListView(
                  children: ModelType.all.map((modelType) {
                    return _buildModelCard(modelType);
                  }).toList(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
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
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _proceedToConfiguration,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelCard(ModelType modelType) {
    final isSelected = _selectedModel == modelType;
    final capabilities = _getModelCapabilities(modelType);
    
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedModel = modelType;
            _error = null;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? Theme.of(context).primaryColor : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _getModelIcon(modelType),
                    color: isSelected ? Theme.of(context).primaryColor : Colors.grey[600],
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      modelType.displayName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected ? Theme.of(context).primaryColor : null,
                      ),
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).primaryColor,
                      size: 24,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _getModelDescription(modelType),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 12),
              _buildCapabilitiesChips(capabilities),
              if (modelType == ModelType.gemini25Flash) ...[
                const SizedBox(height: 12),
                _buildGeminiInfo(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCapabilitiesChips(ModelCapabilities capabilities) {
    final chips = <Widget>[];
    
    if (capabilities.supportsImages) {
      chips.add(_buildCapabilityChip('Images', Icons.image));
    }
    if (capabilities.supportsDocuments) {
      chips.add(_buildCapabilityChip('Documents', Icons.description));
    }
    if (capabilities.supportsAudio) {
      chips.add(_buildCapabilityChip('Audio', Icons.audiotrack));
    }
    if (capabilities.supportsVideo) {
      chips.add(_buildCapabilityChip('Video', Icons.videocam));
    }
    
    if (chips.isEmpty) {
      chips.add(_buildCapabilityChip('Text Only', Icons.text_fields));
    }
    
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: chips,
    );
  }

  Widget _buildCapabilityChip(String label, IconData icon) {
    return Chip(
      label: Text(label),
      avatar: Icon(icon, size: 16),
      backgroundColor: Colors.blue[50],
      labelStyle: const TextStyle(fontSize: 12),
    );
  }

  Widget _buildGeminiInfo() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue[200]!),
      ),
      child: Row(
        children: [
          Icon(Icons.info, color: Colors.blue[600], size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Supports all capabilities including document understanding',
              style: TextStyle(
                color: Colors.blue[700],
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getModelIcon(ModelType modelType) {
    switch (modelType) {
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

  String _getModelDescription(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini25Flash:
        return 'Google\'s most advanced model with full multimodal capabilities';
      case ModelType.gemma3n:
        return 'Google\'s efficient model with most capabilities except document understanding';
      case ModelType.qwen25:
        return 'High-performance text-only model for fast text generation';
      case ModelType.openaiCompatible:
        return 'Compatible with OpenAI API endpoints with configurable capabilities';
    }
  }

  ModelCapabilities _getModelCapabilities(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini25Flash:
        return const ModelCapabilities(
          maxInputTokens: 1000000,
          maxOutputTokens: 60000,
          supportsImages: true,
          supportsDocuments: true,
          supportsAudio: true,
          supportsVideo: true,
        );
      case ModelType.gemma3n:
        return const ModelCapabilities(
          maxInputTokens: 1000000,
          maxOutputTokens: 60000,
          supportsImages: true,
          supportsDocuments: false,
          supportsAudio: true,
          supportsVideo: true,
        );
      case ModelType.qwen25:
        return const ModelCapabilities(
          maxInputTokens: 1000000,
          maxOutputTokens: 60000,
          supportsImages: false,
          supportsDocuments: false,
          supportsAudio: false,
          supportsVideo: false,
        );
      case ModelType.openaiCompatible:
        return const ModelCapabilities(
          maxInputTokens: 100000,
          maxOutputTokens: 4000,
          supportsImages: false,
          supportsDocuments: false,
          supportsAudio: false,
          supportsVideo: false,
        );
    }
  }
}
