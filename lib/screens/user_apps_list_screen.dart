import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import 'user_app_creation_screen.dart';
import 'user_app_view_screen.dart';

class UserAppsListScreen extends StatefulWidget {
  const UserAppsListScreen({super.key});

  @override
  State<UserAppsListScreen> createState() => _UserAppsListScreenState();
}

class _UserAppsListScreenState extends State<UserAppsListScreen> {
  String? _editingAppId;
  final TextEditingController _editingController = TextEditingController();
  final FocusNode _editingFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _editingFocusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _editingController.dispose();
    _editingFocusNode.removeListener(_onFocusChange);
    _editingFocusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_editingFocusNode.hasFocus && _editingAppId != null) {
      _saveAppName();
    }
  }

  void _startEditingAppName(UserApp app) {
    setState(() {
      _editingAppId = app.id;
      _editingController.text = app.name;
    });
    _editingFocusNode.requestFocus();
  }

  Future<void> _saveAppName() async {
    if (_editingAppId == null) return;

    final newName = _editingController.text.trim();
    if (newName.isEmpty) {
      _cancelEditing();
      return;
    }

    try {
      final appProvider = context.read<AppProvider>();
      final app = appProvider.userApps.firstWhere((a) => a.id == _editingAppId);
      
      if (app.name != newName) {
        final updatedApp = app.copyWith(
          name: newName,
          updatedAt: DateTime.now(),
        );
        
        await appProvider.updateUserApp(updatedApp);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.appNameUpdated),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.errorUpdatingAppName(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      _cancelEditing();
    }
  }

  void _cancelEditing() {
    setState(() {
      _editingAppId = null;
      _editingController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        // Check if WebView is supported
        if (!appProvider.isWebViewSupported()) {
          return _buildWebViewNotSupportedScreen(context);
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(AppLocalizations.of(context)!.myApps),
          ),
          body: appProvider.userApps.isEmpty
              ? _buildEmptyState(context)
              : _buildAppsList(context, appProvider),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _navigateToCreateApp(context),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  Widget _buildWebViewNotSupportedScreen(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
        appBar: AppBar(
          title: Text(l10n.myApps),
        ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.web_asset_off,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.webViewNotSupported,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.webViewNotSupportedDescription,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.apps,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.noUserApps,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.createFirstApp,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _navigateToCreateApp(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.createNewApp),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppsList(BuildContext context, AppProvider appProvider) {
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: appProvider.userApps.length,
      itemBuilder: (context, index) {
        final app = appProvider.userApps[index];
        return _buildAppCard(context, app, appProvider);
      },
    );
  }

  Widget _buildAppCard(BuildContext context, UserApp app, AppProvider appProvider) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = _editingAppId == app.id;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Icon(
            Icons.apps,
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
        title: isEditing
            ? TextField(
                controller: _editingController,
                focusNode: _editingFocusNode,
                style: const TextStyle(fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Enter app name...',
                ),
                onSubmitted: (_) => _saveAppName(),
                onTapOutside: (_) => _saveAppName(),
              )
            : GestureDetector(
                onTap: () => _startEditingAppName(app),
                child: Text(
                  app.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(app.description),
            const SizedBox(height: 4),
            Text(
              '${l10n.created}: ${_formatDate(app.createdAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isEditing) ...[
              IconButton(
                icon: const Icon(Icons.check),
                onPressed: _saveAppName,
                tooltip: 'Save',
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: _cancelEditing,
                tooltip: 'Cancel',
              ),
            ] else ...[
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => _startEditingAppName(app),
                tooltip: l10n.editAppName,
              ),
              IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _navigateToViewApp(context, app),
                tooltip: l10n.toApp,
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => _showDeleteDialog(context, app, appProvider),
                tooltip: l10n.delete,
              ),
            ],
          ],
        ),
        onTap: isEditing ? null : () => _navigateToViewApp(context, app),
      ),
    );
  }

  void _navigateToCreateApp(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const UserAppCreationScreen(),
      ),
    );
  }

  void _navigateToViewApp(BuildContext context, UserApp app) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserAppViewScreen(app: app, selectedNotes: null),
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, UserApp app, AppProvider appProvider) {
    final l10n = AppLocalizations.of(context)!;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.delete),
        content: Text(l10n.confirmDeleteApp),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await appProvider.deleteUserApp(app.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.appDeletedSuccessfully),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.errorDeletingApp(e.toString())),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
