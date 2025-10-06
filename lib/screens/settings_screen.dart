import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/secure_storage_service.dart';
import '../models/ai_interaction.dart';
import 'setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionHeader('AI Configuration'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.psychology),
              title: const Text('Gemini API Key'),
              subtitle: const Text('Configure your AI API key'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showApiKeyDialog,
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionHeader('Data Management'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.storage),
              title: const Text('Database Info'),
              subtitle: Consumer<AppProvider>(
                builder: (context, appProvider, child) {
                  return Text('${appProvider.notes.length} notes, ${appProvider.tags.length} tags');
                },
              ),
              trailing: const Icon(Icons.info),
            ),
          ),
          Card(
            child: ListTile(
              leading: _isLoading 
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_forever),
              title: const Text('Clear All Data'),
              subtitle: const Text('Delete all notes and data'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _isLoading ? null : _showClearDataDialog,
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionHeader('AI Interactions'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('AI History'),
              subtitle: Consumer<AppProvider>(
                builder: (context, appProvider, child) {
                  return Text('${appProvider.aiInteractions.length} interactions');
                },
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showAIHistory,
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionHeader('About'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info),
              title: const Text('Version'),
              subtitle: const Text('1.0.0'),
              trailing: const Icon(Icons.info),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 16),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).primaryColor,
        ),
      ),
    );
  }

  void _showApiKeyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('API Key Configuration'),
        content: const Text(
          'Your current API key is stored securely. To change it, you can reset the app and enter a new key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _resetApiKey();
            },
            child: const Text('Reset Key'),
          ),
        ],
      ),
    );
  }

  void _resetApiKey() {
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
              await SecureStorageService.deleteApiKey();
              if (mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (context) => const SetupScreen()),
                );
              }
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  void _showClearDataDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Data'),
        content: const Text(
          'This will permanently delete all your notes, tasks, and AI interactions. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _clearAllData();
            },
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _clearAllData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Clear all data from the app provider
      await context.read<AppProvider>().clearAllData();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All data has been cleared successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error clearing data: $e'),
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

  void _showAIHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const AIHistoryScreen(),
      ),
    );
  }
}

class AIHistoryScreen extends StatelessWidget {
  const AIHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI History'),
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          if (appProvider.aiInteractions.isEmpty) {
            return const Center(
              child: Text('No AI interactions yet'),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: appProvider.aiInteractions.length,
            itemBuilder: (context, index) {
              final interaction = appProvider.aiInteractions[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(_getInteractionIcon(interaction.type)),
                  title: Text(_getInteractionTitle(interaction.type)),
                  subtitle: Text(
                    interaction.prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    _formatDate(interaction.createdAt),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () => _showInteractionDetails(context, interaction),
                ),
              );
            },
          );
        },
      ),
    );
  }

  IconData _getInteractionIcon(AIInteractionType type) {
    switch (type) {
      case AIInteractionType.multiNoteQa:
        return Icons.quiz;
      case AIInteractionType.noteTransformation:
        return Icons.transform;
      case AIInteractionType.newNoteCreation:
        return Icons.add_circle;
    }
  }

  String _getInteractionTitle(AIInteractionType type) {
    switch (type) {
      case AIInteractionType.multiNoteQa:
        return 'Multi-Note Q&A';
      case AIInteractionType.noteTransformation:
        return 'Note Transformation';
      case AIInteractionType.newNoteCreation:
        return 'New Note Creation';
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  void _showInteractionDetails(BuildContext context, interaction) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_getInteractionTitle(interaction.type)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Prompt:',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(interaction.prompt),
              const SizedBox(height: 16),
              Text(
                'Response:',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(interaction.response),
            ],
          ),
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
}
