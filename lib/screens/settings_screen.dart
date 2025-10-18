import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../services/secure_storage_service.dart';
import '../services/logger_service.dart';
import '../services/model_storage_service.dart';
import '../services/model_selector.dart';
import '../models/model_type.dart';
import 'setup_screen.dart';
import 'model_selection_screen.dart';
import 'model_configuration_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.palette),
              title: Text(l10n.appearance),
              subtitle: Text(l10n.appearanceSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AppearanceSettingsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.language),
              title: Text(l10n.language),
              subtitle: Text(l10n.languageSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LanguageSettingsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.psychology),
              title: Text(l10n.aiApi),
              subtitle: Text(l10n.aiApiSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AIModelSettingsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.bug_report),
              title: Text(l10n.aiDebugOverlay),
              subtitle: Text(l10n.aiDebugOverlaySubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AIDebugOverlayScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appearance),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Consumer<AppProvider>(
              builder: (context, appProvider, child) {
                return SwitchListTile(
                  title: Text(l10n.darkMode),
                  subtitle: Text(l10n.darkModeSubtitle),
                  value: appProvider.isDarkMode,
                  onChanged: (value) {
                    appProvider.toggleTheme();
                  },
                  secondary: const Icon(Icons.dark_mode),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class LanguageSettingsScreen extends StatelessWidget {
  const LanguageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.language),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Consumer<AppProvider>(
              builder: (context, appProvider, child) {
                return Column(
                  children: [
                    RadioListTile<Locale>(
                      title: Text(l10n.english),
                      value: const Locale('en', ''),
                      groupValue: appProvider.locale,
                      onChanged: (Locale? value) {
                        if (value != null) {
                          appProvider.changeLanguage(value);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.languageChanged),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      },
                    ),
                    RadioListTile<Locale>(
                      title: Text(l10n.chineseSimplified),
                      value: const Locale('zh', ''),
                      groupValue: appProvider.locale,
                      onChanged: (Locale? value) {
                        if (value != null) {
                          appProvider.changeLanguage(value);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.languageChanged),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class AIModelSettingsScreen extends StatefulWidget {
  const AIModelSettingsScreen({super.key});

  @override
  State<AIModelSettingsScreen> createState() => _AIModelSettingsScreenState();
}

class _AIModelSettingsScreenState extends State<AIModelSettingsScreen> {
  ModelType? _currentModel;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentModel();
  }

  Future<void> _loadCurrentModel() async {
    try {
      final currentModel = await ModelStorageService.getSelectedModel();
      setState(() {
        _currentModel = currentModel;
      });
    } catch (e) {
      LoggerService.error('Error loading current model: $e');
    }
  }

  Future<void> _switchModel(ModelType modelType) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await ModelSelector.instance.switchToModel(modelType);
      setState(() {
        _currentModel = modelType;
        _isLoading = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Switched to ${modelType.displayName}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error switching model: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _configureModel(ModelType modelType) async {
    final isConfigured = await ModelStorageService.isModelConfigured(modelType);
    
    if (isConfigured) {
      // Model is configured, just switch to it
      await _switchModel(modelType);
    } else {
      // Model needs configuration
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ModelConfigurationScreen(modelType: modelType),
          ),
        ).then((result) {
          // Refresh the current model after configuration
          _loadCurrentModel();
          if (result == true) {
            // Show success message if configuration was successful
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${modelType.displayName} configuration updated successfully'),
                backgroundColor: Colors.green,
              ),
            );
          }
        });
      }
    }
  }

  Future<void> _handleModelAction(String action, ModelType modelType) async {
    switch (action) {
      case 'use':
        await _switchModel(modelType);
        break;
      case 'configure':
        await _openModelConfiguration(modelType);
        break;
      case 'reset':
        await _resetModelConfiguration(modelType);
        break;
    }
  }

  Future<void> _openModelConfiguration(ModelType modelType) async {
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ModelConfigurationScreen(modelType: modelType),
        ),
      ).then((result) {
        // Refresh the current model after configuration
        _loadCurrentModel();
        if (result == true) {
          // Show success message if configuration was successful
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${modelType.displayName} configuration updated successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      });
    }
  }

  Future<void> _resetModelConfiguration(ModelType modelType) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reset ${modelType.displayName} Configuration'),
        content: Text('Are you sure you want to reset the configuration for ${modelType.displayName}? This will clear all settings and allow you to reconfigure the model.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _isLoading = true;
      });

      try {
        await ModelStorageService.resetModelConfiguration(modelType);
        
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${modelType.displayName} configuration reset successfully'),
              backgroundColor: Colors.green,
            ),
          );
          // Refresh the current model
          _loadCurrentModel();
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error resetting configuration: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Model Settings'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Current Model',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_currentModel != null) ...[
                          Row(
                            children: [
                              Icon(_getModelIcon(_currentModel!), color: Theme.of(context).primaryColor),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _currentModel!.displayName,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _getModelDescription(_currentModel!),
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
                          ),
                        ] else ...[
                          const Text('No model selected'),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Available Models',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...ModelType.all.map((modelType) {
                  final isCurrentModel = _currentModel == modelType;
                  return FutureBuilder<bool>(
                    future: ModelStorageService.isModelConfigured(modelType),
                    builder: (context, snapshot) {
                      final isConfigured = snapshot.data ?? false;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(_getModelIcon(modelType)),
                          title: Text(modelType.displayName),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_getModelDescription(modelType)),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    isConfigured ? Icons.check_circle : Icons.error_outline,
                                    size: 16,
                                    color: isConfigured ? Colors.green : Colors.orange,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isConfigured ? 'Configured' : 'Not Configured',
                                    style: TextStyle(
                                      color: isConfigured ? Colors.green : Colors.orange,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (isCurrentModel) ...[
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.check_circle,
                                      size: 16,
                                      color: Theme.of(context).primaryColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Current',
                                      style: TextStyle(
                                        color: Theme.of(context).primaryColor,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) => _handleModelAction(value, modelType),
                            itemBuilder: (BuildContext context) => [
                              if (!isCurrentModel)
                                const PopupMenuItem<String>(
                                  value: 'use',
                                  child: Row(
                                    children: [
                                      Icon(Icons.check_circle_outline),
                                      SizedBox(width: 8),
                                      Text('Use model'),
                                    ],
                                  ),
                                ),
                              const PopupMenuItem<String>(
                                value: 'configure',
                                child: Row(
                                  children: [
                                    Icon(Icons.settings),
                                    SizedBox(width: 8),
                                    Text('Configure model'),
                                  ],
                                ),
                              ),
                              const PopupMenuItem<String>(
                                value: 'reset',
                                child: Row(
                                  children: [
                                    Icon(Icons.refresh),
                                    SizedBox(width: 8),
                                    Text('Reset model'),
                                  ],
                                ),
                              ),
                            ],
                            icon: const Icon(Icons.more_vert),
                          ),
                        ),
                      );
                    },
                  );
                }).toList(),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const ModelSelectionScreen(),
                        ),
                      ).then((_) {
                        _loadCurrentModel();
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add New Model'),
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
      case ModelType.openaiCompatible:
        return Icons.api;
    }
  }

  String _getModelDescription(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini25Flash:
        return 'Google\'s most advanced model with full multimodal capabilities';
      case ModelType.openaiCompatible:
        return 'Compatible with OpenAI API endpoints with configurable capabilities';
    }
  }
}

class AIApiSettingsScreen extends StatefulWidget {
  const AIApiSettingsScreen({super.key});

  @override
  State<AIApiSettingsScreen> createState() => _AIApiSettingsScreenState();
}

class _AIApiSettingsScreenState extends State<AIApiSettingsScreen> {
  bool _isLoading = false;
  bool _obscureApiKey = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiApi),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.key),
              title: Text(l10n.apiKey),
              subtitle: FutureBuilder<String?>(
                future: SecureStorageService.getApiKey(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Text(l10n.loading);
                  }
                  
                  final apiKey = snapshot.data;
                  if (apiKey == null || apiKey.isEmpty) {
                    return Text(l10n.noApiKeyConfigured);
                  }
                  
                  return Text(
                    _obscureApiKey 
                        ? '•' * 20 
                        : apiKey.length > 20 
                            ? '${apiKey.substring(0, 20)}...' 
                            : apiKey,
                    style: const TextStyle(fontFamily: 'monospace'),
                  );
                },
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off),
                    onPressed: () {
                      setState(() {
                        _obscureApiKey = !_obscureApiKey;
                      });
                    },
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              onTap: _showApiKeyDialog,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: _isLoading 
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
              title: Text(l10n.updateApiKey),
              subtitle: Text(l10n.updateApiKeySubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: _isLoading ? null : _showUpdateApiKeyDialog,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_forever),
              title: Text(l10n.resetApiKey),
              subtitle: Text(l10n.resetApiKeySubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showResetApiKeyDialog,
            ),
          ),
        ],
      ),
    );
  }

  void _showApiKeyDialog() {
    final l10n = AppLocalizations.of(context)!;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.currentApiKey),
        content: FutureBuilder<String?>(
          future: SecureStorageService.getApiKey(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const CircularProgressIndicator();
            }
            
            final apiKey = snapshot.data;
            if (apiKey == null || apiKey.isEmpty) {
              return Text(l10n.noApiKeyConfigured);
            }
            
            return SelectableText(
              apiKey,
              style: const TextStyle(fontFamily: 'monospace'),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  void _showUpdateApiKeyDialog() {
    final l10n = AppLocalizations.of(context)!;
    final TextEditingController controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.updateApiKey),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.enterNewApiKey),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: l10n.apiKeyLabel,
                hintText: l10n.apiKeyHint,
                border: const OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context);
                await _updateApiKey(controller.text.trim());
              }
            },
            child: Text(l10n.update),
          ),
        ],
      ),
    );
  }

  void _showResetApiKeyDialog() {
    final l10n = AppLocalizations.of(context)!;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.resetApiKey),
        content: Text(l10n.resetApiKeyConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _resetApiKey();
            },
            child: Text(l10n.reset),
          ),
        ],
      ),
    );
  }

  Future<void> _updateApiKey(String newApiKey) async {
    final l10n = AppLocalizations.of(context)!;
    
    setState(() {
      _isLoading = true;
    });

    try {
      await SecureStorageService.saveApiKey(newApiKey);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.apiKeyUpdatedSuccessfully),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {}); // Refresh the UI
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorUpdatingApiKey(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _resetApiKey() async {
    final l10n = AppLocalizations.of(context)!;
    
    setState(() {
      _isLoading = true;
    });

    try {
      await SecureStorageService.deleteApiKey();
      
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const SetupScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorResettingApiKey(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}

class AIDebugOverlayScreen extends StatefulWidget {
  const AIDebugOverlayScreen({super.key});

  @override
  State<AIDebugOverlayScreen> createState() => _AIDebugOverlayScreenState();
}

class _AIDebugOverlayScreenState extends State<AIDebugOverlayScreen> {
  @override
  Widget build(BuildContext context) {
    final logs = LoggerService.aiLogBucket;
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiDebugOverlayTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {});
            },
            tooltip: l10n.refreshLogs,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              setState(() {
                LoggerService.clearAiLogBucket();
              });
            },
            tooltip: l10n.clearLogs,
          ),
        ],
      ),
      body: logs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bug_report, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    l10n.noAiLogsAvailable,
                    style: const TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.aiLogsDescription,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final log = logs[logs.length - 1 - index]; // Show newest first
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ExpansionTile(
                    leading: Icon(
                      log.type == 'request' 
                          ? Icons.arrow_upward 
                          : log.type == 'response' 
                              ? Icons.arrow_downward 
                              : Icons.error,
                      color: log.type == 'request' 
                          ? Colors.blue 
                          : log.type == 'response' 
                              ? Colors.green 
                              : Colors.red,
                    ),
                    title: Text(
                      '${log.type.toUpperCase()} - ${log.endpoint.isNotEmpty ? log.endpoint : 'Unknown Endpoint'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'ID: ${log.id} • ${log.timestamp.toString().substring(11, 19)}',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (log.data.containsKey('headers'))
                              _buildDataSection(l10n.headers, log.data['headers']),
                            if (log.data.containsKey('body'))
                              _buildDataSection(l10n.body, log.data['body']),
                            if (log.data.containsKey('statusCode'))
                              _buildDataSection(l10n.statusCode, log.data['statusCode']),
                            if (log.data.containsKey('error'))
                              _buildDataSection(l10n.error, log.data['error']),
                            if (log.data.containsKey('duration'))
                              _buildDataSection(l10n.duration, '${log.data['duration']}ms'),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildDataSection(String title, dynamic data) {
    final theme = Theme.of(context);
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: theme.textTheme.titleMedium?.color,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.dividerColor,
                width: 1,
              ),
            ),
            child: SelectableText(
              data is Map || data is List
                  ? const JsonEncoder.withIndent('  ').convert(data)
                  : data.toString(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: theme.textTheme.bodyMedium?.color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

