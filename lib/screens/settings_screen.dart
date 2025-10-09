import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../services/secure_storage_service.dart';
import 'setup_screen.dart';

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
                MaterialPageRoute(builder: (context) => const AIApiSettingsScreen()),
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

