import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_json_view/flutter_json_view.dart';
import 'package:file_saver/file_saver.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../services/secure_storage_service.dart';
import '../services/logger_service.dart';
import '../services/model_storage_service.dart';
import '../services/service_locator.dart';
import '../services/model_selector.dart';
import '../models/model_type.dart';
import 'setup_screen.dart';
import 'model_configuration_screen.dart';
import 'recovery_screen.dart';
import 'mcp_settings_screen.dart';
import 'prompt_settings_screen.dart';
import 'agentic_settings_screen.dart';
import 'getting_started_screen.dart';
import 'model_preference_screen.dart';
import '../services/conversation_settings_service.dart';
import '../models/model_config.dart';
import 'settings/user_app_settings_screen.dart';
import '../services/wake_lock_service.dart' as wake_lock;
import '../services/models/local_model_presets.dart';
import 'local_model_settings_screen.dart';
import '../services/network_settings_service.dart';
import '../services/network_provider.dart';
import 'settings/about_screen.dart';
import 'package:flutter/foundation.dart';
import '../services/sync/google_drive_auth_service.dart';
import 'settings/cloud_sync_screen.dart';
import 'settings/debug_menu_screen.dart';
import 'settings/web_logins_screen.dart';
import 'search_settings_screen.dart';
import 'world_clip/world_clip_projects_screen.dart';

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
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.lightbulb_outline),
              title: Text(l10n.gettingStarted),
              subtitle: Text(l10n.gettingStartedSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const GettingStartedScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.movie_creation_outlined),
              title: Text(l10n.worldClipProjects),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const WorldClipProjectsScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Live subtitle: "Lexical only" / "<Provider> · indexing NN%" /
          // "<Provider> · N errors" / "Switching to B — NN% re-indexed".
          const SearchSettingsTile(),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.psychology),
              title: Text(l10n.aiApi),
              subtitle: Text(l10n.aiApiSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const AIModelSettingsScreen(),
                ),
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
                MaterialPageRoute(
                  builder: (context) => const AIDebugOverlayScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.apps),
              title: Text(l10n.userAppSettingsTitle),
              subtitle: Text(l10n.userAppSettingsSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const UserAppSettingsScreen(),
                ),
              ),
            ),
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.cookie_outlined),
                title: Text(l10n.webLogins),
                subtitle: Text(l10n.webLoginsSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const WebLoginsScreen(),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.settings_applications),
              title: Text(l10n.system),
              subtitle: Text(l10n.systemSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SystemSettingsScreen(),
                ),
              ),
            ),
          ),
          // Android/iOS only, not merely non-web: the OAuth redirect is a
          // private-use URL scheme that only those two platforms register
          // (Android intent-filter / iOS CFBundleURLSchemes). On desktop the
          // consent flow would open a browser and then wait five minutes for
          // a callback that can never arrive. `GoogleDriveAuthService.connect`
          // also fails fast for the same reason; this just keeps the entry
          // point from being offered at all.
          if (GoogleDriveAuthService.isSupportedPlatform) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_sync),
                title: Text(l10n.cloudSync),
                subtitle: Text(l10n.cloudSyncSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CloudSyncScreen(),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.backup),
              title: Text(l10n.recovery),
              subtitle: Text(l10n.recoverySubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const RecoveryScreen()),
              ),
            ),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.bug_report),
                title: Text(l10n.debugMenu),
                subtitle: Text(l10n.debugMenuSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const DebugMenuScreen(),
                  ),
                ),
              ),
            ),
          ],
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
      appBar: AppBar(title: Text(l10n.appearance)),
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
      appBar: AppBar(title: Text(l10n.language)),
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
                      value: const Locale('en', 'US'),
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
                      value: const Locale('zh', 'CN'),
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
  List<ModelConfig> _configuredModels = [];
  ModelConfig? _activeModel;
  bool _isLoading = false;

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
      final activeModel = await getIt<ModelStorageService>().getActiveModel();

      if (mounted) {
        setState(() {
          _configuredModels = models;
          _activeModel = activeModel;
          _isLoading = false;
        });
      }
    } catch (e) {
      LoggerService.error('Error loading model settings: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _switchModel(ModelConfig config) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await getIt<ModelSelector>().switchToModel(config);

      if (mounted) {
        // Force refresh of model config in provider to update UI
        Provider.of<AppProvider>(
          context,
          listen: false,
        ).updateModelConfig(config);

        setState(() {
          _activeModel = config;
          _isLoading = false;
        });

        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.switchedToModel(
                config.displayName ?? config.modelName ?? 'Model',
              ),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });

      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorSwitchingModel(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteModel(ModelConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${config.displayName}?'),
        content: const Text(
          'Are you sure you want to delete this model configuration? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await getIt<ModelStorageService>().deleteModel(config.id);
        await _loadData();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Model deleted successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting model: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _openModelConfiguration({ModelConfig? config}) async {
    if (!mounted) return;

    // For local MNN models, route to the local model settings screen
    if (config != null && config.type == ModelType.localMnn) {
      final preset = LocalModelPresets.findById(config.modelName ?? '');
      if (preset != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LocalModelSettingsScreen(
              preset: preset,
              configPath: config.endpoint ?? '',
              existingConfig: config,
            ),
          ),
        );
        _loadData();
        return;
      }
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ModelConfigurationScreen(config: config),
      ),
    );
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiModelSettings)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // MCP Settings Card
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_sync),
                    title: Text(l10n.mcpSettings),
                    subtitle: Text(l10n.mcpSettingsSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const McpSettingsScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.repeat),
                    title: Text(l10n.aiConversationSettings),
                    subtitle: Text(l10n.aiConversationSettingsSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            const AiConversationSettingsScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_tree_rounded),
                    title: Text(l10n.agenticSettings),
                    subtitle: Text(l10n.agenticSettingsSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AgenticSettingsScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.sort_rounded),
                    title: Text(l10n.modelPreferences),
                    subtitle: Text(l10n.modelPreferencesSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ModelPreferenceScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Configured Models',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () => _openModelConfiguration(),
                      tooltip: 'Add Model',
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                if (_configuredModels.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        children: [
                          const Icon(
                            Icons.model_training,
                            size: 48,
                            color: Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No models configured',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Add a model to get started with AI features.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () => _openModelConfiguration(),
                            icon: const Icon(Icons.add),
                            label: const Text('Add Model'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._configuredModels.map((model) {
                    final isActive = _activeModel?.id == model.id;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: isActive ? 4 : 1,
                      shape: isActive
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: Theme.of(context).primaryColor,
                                width: 2,
                              ),
                            )
                          : null,
                      child: ListTile(
                        leading: Icon(_getModelIcon(model.type)),
                        title: Text(
                          model.displayName ??
                              model.modelName ??
                              'Unknown Model',
                          style: TextStyle(
                            fontWeight: isActive
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(model.type.displayName),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isActive)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'Active',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                switch (value) {
                                  case 'use':
                                    _switchModel(model);
                                    break;
                                  case 'edit':
                                    _openModelConfiguration(config: model);
                                    break;
                                  case 'delete':
                                    _deleteModel(model);
                                    break;
                                }
                              },
                              itemBuilder: (BuildContext context) => [
                                if (!isActive)
                                  PopupMenuItem<String>(
                                    value: 'use',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.check_circle_outline),
                                        const SizedBox(width: 8),
                                        Text(l10n.useModel),
                                      ],
                                    ),
                                  ),
                                PopupMenuItem<String>(
                                  value: 'edit',
                                  child: Row(
                                    children: [
                                      const Icon(Icons.edit),
                                      const SizedBox(width: 8),
                                      const Text('Edit'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.delete,
                                        color: Colors.red,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        l10n.delete,
                                        style: const TextStyle(
                                          color: Colors.red,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () => _openModelConfiguration(config: model),
                      ),
                    );
                  }),
              ],
            ),
    );
  }

  IconData _getModelIcon(ModelType modelType) {
    switch (modelType) {
      case ModelType.gemini:
        return Icons.auto_awesome;
      case ModelType.openaiCompatible:
        return Icons.smart_toy;
      case ModelType.localMnn:
        return Icons.computer;
    }
  }
}

class AiConversationSettingsScreen extends StatefulWidget {
  const AiConversationSettingsScreen({super.key});

  @override
  State<AiConversationSettingsScreen> createState() =>
      _AiConversationSettingsScreenState();
}

class _AiConversationSettingsScreenState
    extends State<AiConversationSettingsScreen> {
  int _maxIterations = ConversationSettingsService.defaultMaxToolIterations;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadPreference();
  }

  Future<void> _loadPreference() async {
    final value = await ConversationSettingsService.getMaxToolIterations();
    if (!mounted) return;
    setState(() {
      _maxIterations = value;
      _isLoading = false;
    });
  }

  Future<void> _updatePreference(int newValue) async {
    setState(() {
      _isSaving = true;
    });
    try {
      await ConversationSettingsService.setMaxToolIterations(newValue);
      if (!mounted) return;
      setState(() {
        _maxIterations = newValue;
      });
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.iterationLimitUpdated(newValue))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiConversationSettings)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.tune),
                    title: Text(l10n.aiPrompts),
                    subtitle: Text(l10n.aiPromptsSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const PromptSettingsScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.iterationLimitLabel,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.aiConversationSettingsDescription,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              l10n.iterationLimitValueLabel,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Text(
                              l10n.iterationLimitValue(_maxIterations),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Slider(
                          value: _maxIterations.toDouble(),
                          min: ConversationSettingsService.minToolIterations
                              .toDouble(),
                          max: ConversationSettingsService.maxToolIterationsCap
                              .toDouble(),
                          divisions:
                              ConversationSettingsService.maxToolIterationsCap -
                              ConversationSettingsService.minToolIterations,
                          label: '$_maxIterations',
                          onChanged: (value) {
                            setState(() {
                              _maxIterations = value.round();
                            });
                          },
                          onChangeEnd: (value) =>
                              _updatePreference(value.round()),
                        ),
                        Text(
                          l10n.iterationLimitHelper(
                            ConversationSettingsService.minToolIterations,
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.7),
                              ),
                        ),
                        if (_isSaving) ...[
                          const SizedBox(height: 12),
                          const LinearProgressIndicator(minHeight: 2),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
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
      appBar: AppBar(title: Text(l10n.aiApi)),
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
                    icon: Icon(
                      _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                    ),
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
  Future<void> _exportLogs() async {
    try {
      final logs = LoggerService.aiLogBucket;
      final jsonStr = jsonEncode(logs.map((e) => e.toJson()).toList());
      final date = DateTime.now().toIso8601String().substring(0, 10);
      await FileSaver.instance.saveAs(
        name: 'ai_debug_logs_$date',
        bytes: Uint8List.fromList(utf8.encode(jsonStr)),
        fileExtension: 'json',
        mimeType: MimeType.text,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

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
            icon: const Icon(Icons.download),
            onPressed: _exportLogs,
            tooltip: l10n.exportLogs,
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
                          : log.type == 'console'
                          ? Icons.terminal
                          : Icons.error,
                      color: log.type == 'request'
                          ? Colors.blue
                          : log.type == 'response'
                          ? Colors.green
                          : log.type == 'console'
                          ? Colors.orange
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
                              _buildDataSection(
                                l10n.headers,
                                log.data['headers'],
                              ),
                            if (log.data.containsKey('body'))
                              _buildDataSection(l10n.body, log.data['body']),
                            if (log.data.containsKey('statusCode'))
                              _buildDataSection(
                                l10n.statusCode,
                                log.data['statusCode'],
                              ),
                            if (log.data.containsKey('error'))
                              _buildDataSection(l10n.error, log.data['error']),
                            if (log.data.containsKey('consoleOutput'))
                              _buildDataSection(
                                l10n.consoleOutput,
                                log.data['consoleOutput'],
                              ),
                            if (log.data.containsKey('duration'))
                              _buildDataSection(
                                l10n.duration,
                                '${log.data['duration']}ms',
                              ),
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

    final jsonViewTheme = JsonViewTheme(
      backgroundColor: Colors.transparent,
      keyStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.primary,
      ),
      stringStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: theme.textTheme.bodyMedium?.color,
      ),
      intStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: theme.colorScheme.secondary,
      ),
      doubleStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: theme.colorScheme.secondary,
      ),
      boolStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: theme.colorScheme.tertiary,
      ),
      openIcon: Icon(
        Icons.arrow_drop_down,
        size: 20,
        color: theme.iconTheme.color,
      ),
      closeIcon: Icon(
        Icons.arrow_right,
        size: 20,
        color: theme.iconTheme.color,
      ),
      initiallyExpanded: false,
      largeStringThreshold: 500,
    );

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
              border: Border.all(color: theme.dividerColor, width: 1),
            ),
            child: data is Map
                ? JsonView.map(
                    Map<String, dynamic>.from(data),
                    theme: jsonViewTheme,
                  )
                : data is List
                ? JsonView.map({'items': data}, theme: jsonViewTheme)
                : SelectableText(
                    data.toString(),
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

class SystemSettingsScreen extends StatefulWidget {
  const SystemSettingsScreen({super.key});

  @override
  State<SystemSettingsScreen> createState() => _SystemSettingsScreenState();
}

class _SystemSettingsScreenState extends State<SystemSettingsScreen> {
  bool _keepScreenOn = false;
  int _maxLogEntries = LoggerService.defaultMaxLogEntries;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPreference();
  }

  Future<void> _loadPreference() async {
    final enabled = await wake_lock.isWakeLockEnabled();
    final maxLogEntries = await LoggerService.getMaxLogEntries();
    if (mounted) {
      setState(() {
        _keepScreenOn = enabled;
        _maxLogEntries = maxLogEntries;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleKeepScreenOn(bool value) async {
    setState(() {
      _keepScreenOn = value;
    });
    await wake_lock.setWakeLock(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.system)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Dark Mode
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
                const SizedBox(height: 8),
                // Keep Screen On
                Card(
                  child: SwitchListTile(
                    title: Text(l10n.keepScreenOn),
                    subtitle: Text(l10n.keepScreenOnSubtitle),
                    value: _keepScreenOn,
                    onChanged: _toggleKeepScreenOn,
                    secondary: const Icon(Icons.brightness_7),
                  ),
                ),
                const SizedBox(height: 16),
                // Network
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.wifi),
                    title: Text(l10n.network),
                    subtitle: Text(l10n.networkSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const NetworkSettingsScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Language
                Card(
                  child: Consumer<AppProvider>(
                    builder: (context, appProvider, child) {
                      return ListTile(
                        leading: const Icon(Icons.language),
                        title: Text(l10n.language),
                        subtitle: Text(
                          _getLanguageLabel(appProvider.locale, l10n),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () =>
                            _showLanguageDialog(context, appProvider, l10n),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                // AI Log Entries Limit
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.article_outlined),
                    title: Text(l10n.aiLogEntriesLimit),
                    subtitle: Text(l10n.aiLogEntriesLimitDescription),
                    trailing: DropdownButton<int>(
                      value: _maxLogEntries,
                      underline: const SizedBox(),
                      onChanged: (value) async {
                        if (value != null) {
                          setState(() => _maxLogEntries = value);
                          await LoggerService.setMaxLogEntries(value);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(l10n.settingsSaved)),
                            );
                          }
                        }
                      },
                      items: [
                        DropdownMenuItem(
                          value: 0,
                          child: Text(l10n.aiLogEntriesDisabled),
                        ),
                        const DropdownMenuItem(value: 100, child: Text('100')),
                        const DropdownMenuItem(value: 300, child: Text('300')),
                        const DropdownMenuItem(value: 500, child: Text('500')),
                        DropdownMenuItem(
                          value: -1,
                          child: Text(l10n.aiLogEntriesUnlimited),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // About
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(l10n.about),
                    subtitle: Text(l10n.aboutSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AboutScreen(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  String _getLanguageLabel(Locale? locale, AppLocalizations l10n) {
    if (locale == null) return l10n.english;
    if (locale.languageCode == 'zh') return l10n.chineseSimplified;
    return l10n.english;
  }

  void _showLanguageDialog(
    BuildContext context,
    AppProvider appProvider,
    AppLocalizations l10n,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.language),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<Locale>(
              title: Text(l10n.english),
              value: const Locale('en', 'US'),
              groupValue: appProvider.locale,
              onChanged: (Locale? value) {
                if (value != null) {
                  appProvider.changeLanguage(value);
                  Navigator.of(context).pop();
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
              value: const Locale('zh', 'CN'),
              groupValue: appProvider.locale,
              onChanged: (Locale? value) {
                if (value != null) {
                  appProvider.changeLanguage(value);
                  Navigator.of(context).pop();
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
        ),
      ),
    );
  }
}

class NetworkSettingsScreen extends StatefulWidget {
  const NetworkSettingsScreen({super.key});

  @override
  State<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends State<NetworkSettingsScreen> {
  NetworkProtocolPreference _protocolPreference =
      NetworkSettingsService.defaultProtocolPreference;
  int _retryCount = NetworkSettingsService.defaultRetryCount;
  int _backoffBase = NetworkSettingsService.defaultBackoffBase;
  int _timeout = NetworkSettingsService.defaultTimeout;
  int _connectTimeout = NetworkSettingsService.defaultConnectTimeout;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final protocol = await NetworkSettingsService.getProtocolPreference();
    final retryCount = await NetworkSettingsService.getRetryCount();
    final backoffBase = await NetworkSettingsService.getBackoffBase();
    final timeout = await NetworkSettingsService.getTimeout();
    final connectTimeout = await NetworkSettingsService.getConnectTimeout();
    if (mounted) {
      setState(() {
        _protocolPreference = protocol;
        _retryCount = retryCount;
        _backoffBase = backoffBase;
        _timeout = timeout;
        _connectTimeout = connectTimeout;
        _isLoading = false;
      });
    }
  }

  Future<void> _updateProtocolPreference(
    NetworkProtocolPreference preference,
  ) async {
    setState(() {
      _protocolPreference = preference;
    });
    await NetworkSettingsService.setProtocolPreference(preference);
    await NetworkProvider.instance.reloadSettings();
  }

  Future<void> _updateRetryCount(int count) async {
    setState(() {
      _retryCount = count;
    });
    await NetworkSettingsService.setRetryCount(count);
    await NetworkProvider.instance.reloadSettings();
  }

  Future<void> _updateBackoffBase(int seconds) async {
    setState(() {
      _backoffBase = seconds;
    });
    await NetworkSettingsService.setBackoffBase(seconds);
    await NetworkProvider.instance.reloadSettings();
  }

  Future<void> _updateTimeout(int seconds) async {
    setState(() {
      _timeout = seconds;
    });
    await NetworkSettingsService.setTimeout(seconds);
    await NetworkProvider.instance.reloadSettings();
  }

  Future<void> _updateConnectTimeout(int seconds) async {
    setState(() {
      _connectTimeout = seconds;
    });
    await NetworkSettingsService.setConnectTimeout(seconds);
    await NetworkProvider.instance.reloadSettings();
  }

  String _getProtocolLabel(NetworkProtocolPreference preference) {
    final l10n = AppLocalizations.of(context)!;
    switch (preference) {
      case NetworkProtocolPreference.auto:
        return l10n.protocolAuto;
      case NetworkProtocolPreference.http3Only:
        return l10n.protocolHttp3Only;
      case NetworkProtocolPreference.http11Only:
        return l10n.protocolHttp11Only;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.network)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Protocol Preference
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.speed),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.protocolPreference,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.protocolPreferenceSubtitle,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<NetworkProtocolPreference>(
                          value: _protocolPreference,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          items: NetworkProtocolPreference.values
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(_getProtocolLabel(p)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              _updateProtocolPreference(value);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Retry Count
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.repeat),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.retryCount,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.retryCountSubtitle,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '$_retryCount',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Slider(
                          value: _retryCount.toDouble(),
                          min: NetworkSettingsService.minRetryCount.toDouble(),
                          max: NetworkSettingsService.maxRetryCount.toDouble(),
                          divisions:
                              NetworkSettingsService.maxRetryCount -
                              NetworkSettingsService.minRetryCount,
                          label: '$_retryCount',
                          onChanged: (value) {
                            setState(() {
                              _retryCount = value.round();
                            });
                          },
                          onChangeEnd: (value) =>
                              _updateRetryCount(value.round()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Backoff Base
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.timer),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.backoffBase,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n.backoffBaseSubtitle,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${_backoffBase}s',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Slider(
                          value: _backoffBase.toDouble(),
                          min: NetworkSettingsService.minBackoffBase.toDouble(),
                          max: NetworkSettingsService.maxBackoffBase.toDouble(),
                          divisions:
                              NetworkSettingsService.maxBackoffBase -
                              NetworkSettingsService.minBackoffBase,
                          label: '${_backoffBase}s',
                          onChanged: (value) {
                            setState(() {
                              _backoffBase = value.round();
                            });
                          },
                          onChangeEnd: (value) =>
                              _updateBackoffBase(value.round()),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.retryPattern(
                            _backoffBase.toString(),
                            (_backoffBase * 2).toString(),
                            (_backoffBase * 4).toString(),
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.7),
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Request Timeout
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.timer),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Request Timeout',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Maximum duration for network requests',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${_timeout}s',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Slider(
                          value: _timeout.toDouble(),
                          min: NetworkSettingsService.minTimeout.toDouble(),
                          max: NetworkSettingsService.maxTimeout.toDouble(),
                          divisions:
                              (NetworkSettingsService.maxTimeout -
                                  NetworkSettingsService.minTimeout) ~/
                              30,
                          label: '${_timeout}s',
                          onChanged: (value) {
                            setState(() {
                              _timeout = value.round();
                            });
                          },
                          onChangeEnd: (value) => _updateTimeout(value.round()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Connect Timeout
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.timer_outlined),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Connect Timeout',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Maximum duration for establishing connection',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${_connectTimeout}s',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Slider(
                          value: _connectTimeout.toDouble(),
                          min: NetworkSettingsService.minConnectTimeout
                              .toDouble(),
                          max: NetworkSettingsService.maxConnectTimeout
                              .toDouble(),
                          divisions:
                              (NetworkSettingsService.maxConnectTimeout -
                                  NetworkSettingsService.minConnectTimeout) ~/
                              5,
                          label: '${_connectTimeout}s',
                          onChanged: (value) {
                            setState(() {
                              _connectTimeout = value.round();
                            });
                          },
                          onChangeEnd: (value) =>
                              _updateConnectTimeout(value.round()),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
