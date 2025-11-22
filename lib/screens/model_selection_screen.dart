import 'package:flutter/material.dart';
import '../models/model_type.dart';
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
      final activeModel = await ModelStorageService.getActiveModel();
      setState(() {
        _selectedModel = activeModel?.type ?? ModelType.gemini;
      });
    } catch (e) {
      // Use default if loading fails
      setState(() {
        _selectedModel = ModelType.gemini;
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
      // Check if any model of this type is already configured
      final models = await ModelStorageService.getConfiguredModels();
      final isConfigured = models.any((m) => m.type == _selectedModel);

      if (isConfigured) {
        // Model is already configured, proceed to main app
        // We might want to ensure it's active if it's not
        final activeModel = await ModelStorageService.getActiveModel();
        if (activeModel?.type != _selectedModel) {
          final modelToActivate = models.firstWhere(
            (m) => m.type == _selectedModel,
          );
          await ModelStorageService.activateModel(modelToActivate.id);
        }

        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/main');
        }
      } else {
        // Navigate to configuration screen
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) =>
                  ModelConfigurationScreen(initialType: _selectedModel),
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
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: Colors.grey[600]),
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
              color: isSelected
                  ? Theme.of(context).primaryColor
                  : Colors.transparent,
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
                    color: isSelected
                        ? Theme.of(context).primaryColor
                        : Colors.grey[600],
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      modelType.displayName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected
                            ? Theme.of(context).primaryColor
                            : null,
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
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getModelIcon(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini:
        return Icons.psychology;
      case ModelType.openaiCompatible:
        return Icons.api;
    }
  }

  String _getModelDescription(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini:
        return 'Google\'s most advanced model with full multimodal capabilities';
      case ModelType.openaiCompatible:
        return 'Compatible with OpenAI API endpoints with configurable capabilities';
    }
  }
}
