import 'package:flutter/material.dart';
import '../models/model_type.dart';
import '../services/model_storage_service.dart';
import '../services/service_locator.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import 'model_configuration_screen.dart';
import 'local_model_picker_screen.dart';

class ModelSelectionScreen extends StatefulWidget {
  final bool isOnboarding;

  const ModelSelectionScreen({super.key, this.isOnboarding = false});

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
      final activeModel = await getIt<ModelStorageService>().getActiveModel();
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
      final models = await getIt<ModelStorageService>().getConfiguredModels();
      final isConfigured = models.any((m) => m.type == _selectedModel);

      if (isConfigured) {
        // Model is already configured, proceed to main app
        if (widget.isOnboarding) {
          if (mounted) {
            await context.read<AppProvider>().setOnboardingCompleted(true);
          }
        }

        // We might want to ensure it's active if it's not
        final activeModel = await getIt<ModelStorageService>().getActiveModel();
        if (activeModel?.type != _selectedModel) {
          final modelToActivate = models.firstWhere(
            (m) => m.type == _selectedModel,
          );
          await getIt<ModelStorageService>().activateModel(modelToActivate.id);
        }

        if (mounted) {
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil('/main', (route) => false);
        }
      } else {
        // Navigate to configuration screen
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ModelConfigurationScreen(
                initialType: _selectedModel,
                isOnboarding: widget.isOnboarding,
              ),
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
                AppLocalizations.of(context)!.onboardingChooseModelTitle,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context)!.onboardingChooseModelSubtitle,
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
              if (widget.isOnboarding) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: 50,
                  child: TextButton(
                    onPressed: () async {
                      if (context.mounted) {
                        await context
                            .read<AppProvider>()
                            .setOnboardingCompleted(true);
                      }
                      if (context.mounted) {
                        Navigator.of(
                          context,
                        ).pushNamedAndRemoveUntil('/main', (route) => false);
                      }
                    },
                    child: Text(
                      AppLocalizations.of(context)!.onboardingConfigLater,
                    ),
                  ),
                ),
              ],
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
          if (modelType == ModelType.localMnn) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LocalModelPickerScreen(),
              ),
            );
            return;
          }
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
      case ModelType.localMnn:
        return Icons.phone_android;
    }
  }

  String _getModelDescription(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini:
        return AppLocalizations.of(context)!.geminiModelDescription;
      case ModelType.openaiCompatible:
        return AppLocalizations.of(context)!.openaiCompatibleModelDescription;
      case ModelType.localMnn:
        return AppLocalizations.of(context)!.localModelDescription;
    }
  }
}
