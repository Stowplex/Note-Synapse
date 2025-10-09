import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.palette),
              title: const Text('Appearance'),
              subtitle: const Text('Theme and display settings'),
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
              leading: const Icon(Icons.psychology),
              title: const Text('AI API'),
              subtitle: const Text('Configure your AI API key'),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appearance'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Consumer<AppProvider>(
              builder: (context, appProvider, child) {
                return SwitchListTile(
                  title: const Text('Dark Mode'),
                  subtitle: const Text('Toggle between light and dark theme'),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI API'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.key),
              title: const Text('API Key'),
              subtitle: FutureBuilder<String?>(
                future: SecureStorageService.getApiKey(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Text('Loading...');
                  }
                  
                  final apiKey = snapshot.data;
                  if (apiKey == null || apiKey.isEmpty) {
                    return const Text('No API key configured');
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
              title: const Text('Update API Key'),
              subtitle: const Text('Enter a new API key'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _isLoading ? null : _showUpdateApiKeyDialog,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_forever),
              title: const Text('Reset API Key'),
              subtitle: const Text('Clear current API key and return to setup'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showResetApiKeyDialog,
            ),
          ),
        ],
      ),
    );
  }

  void _showApiKeyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Current API Key'),
        content: FutureBuilder<String?>(
          future: SecureStorageService.getApiKey(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const CircularProgressIndicator();
            }
            
            final apiKey = snapshot.data;
            if (apiKey == null || apiKey.isEmpty) {
              return const Text('No API key configured');
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
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showUpdateApiKeyDialog() {
    final TextEditingController controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter your new Gemini API key:'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'Enter your API key here',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context);
                await _updateApiKey(controller.text.trim());
              }
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  void _showResetApiKeyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset API Key'),
        content: const Text(
          'This will clear your current API key and return you to the setup screen. Are you sure?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _resetApiKey();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateApiKey(String newApiKey) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await SecureStorageService.saveApiKey(newApiKey);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('API key updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {}); // Refresh the UI
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating API key: $e'),
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
            content: Text('Error resetting API key: $e'),
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

