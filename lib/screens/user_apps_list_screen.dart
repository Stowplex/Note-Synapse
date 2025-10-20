import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../services/logger_service.dart';
import '../services/user_app_service.dart';
import 'user_app_creation_screen.dart';
import 'user_app_view_screen.dart';
import 'user_app_edit_screen.dart';
import 'import_app_screen.dart';
import 'export_app_screen.dart';
import 'note_selection_dialog.dart';

class UserAppsListScreen extends StatefulWidget {
  const UserAppsListScreen({super.key});

  @override
  State<UserAppsListScreen> createState() => _UserAppsListScreenState();
}

class _UserAppsListScreenState extends State<UserAppsListScreen> {
  String? _editingAppId;
  final TextEditingController _editingController = TextEditingController();
  final FocusNode _editingFocusNode = FocusNode();
  String? _selectedYamlFile;
  String? _errorMessage;

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
            onPressed: () => _showAddAppMenu(context),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Show error message if there's one
    if (_errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_errorMessage!),
              backgroundColor: Colors.orange,
            ),
          );
          setState(() {
            _errorMessage = null; // Clear the error
          });
        }
      });
    }
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
              onPressed: () => _showAddAppMenu(context),
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
            app.type == UserAppType.noteAction ? Icons.apps : Icons.web,
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
        trailing: isEditing
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                ],
              )
            : PopupMenuButton<String>(
                onSelected: (value) => _handleMenuAction(context, value, app, appProvider),
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(Icons.edit),
                        const SizedBox(width: 8),
                        Text(l10n.editApp),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'clone',
                    child: Row(
                      children: [
                        const Icon(Icons.copy),
                        const SizedBox(width: 8),
                        Text(l10n.cloneApp),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'export',
                    child: Row(
                      children: [
                        const Icon(Icons.file_download),
                        const SizedBox(width: 8),
                        Text(l10n.exportApp),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(Icons.delete),
                        const SizedBox(width: 8),
                        Text(l10n.deleteApp),
                      ],
                    ),
                  ),
                ],
                icon: const Icon(Icons.more_vert),
              ),
        onTap: isEditing ? null : () => _navigateToViewApp(context, app),
      ),
    );
  }

  void _showAddAppMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(AppLocalizations.of(context)!.createNewApp),
              onTap: () {
                Navigator.pop(context);
                _navigateToCreateApp(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_upload),
              title: Text(AppLocalizations.of(context)!.importApp),
              onTap: () {
                Navigator.pop(context);
                _importApp(context);
              },
            ),
          ],
        ),
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

  Future<void> _importApp(BuildContext context) async {
    try {
      LoggerService.debug('Starting file picker...');
      
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      LoggerService.debug('File picker result: $result');
      
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        
        if (file.path != null) {
          LoggerService.debug('Selected file: ${file.name}, path: ${file.path}');
          
          // Store the file path and trigger navigation in the next frame
          _selectedYamlFile = file.path!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _navigateToImportScreen();
            }
          });
        } else {
          LoggerService.debug('File path is null');
          setState(() {
            _errorMessage = 'File path is null';
          });
        }
      } else {
        LoggerService.debug('No file selected or result is null');
        setState(() {
          _errorMessage = 'No file selected or result is null';
        });
      }
    } catch (e) {
      LoggerService.error('Error in file picker: $e');
      setState(() {
        _errorMessage = 'Error selecting file: $e';
      });
    }
  }

  void _navigateToImportScreen() {
    if (_selectedYamlFile != null) {
      LoggerService.debug('Navigating to ImportAppScreen with file: $_selectedYamlFile');
      final filePath = _selectedYamlFile!; // Store the path before clearing
      _selectedYamlFile = null; // Clear before navigation
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ImportAppScreen(
            yamlFilePath: filePath,
          ),
        ),
      );
    }
  }

  void _navigateToViewApp(BuildContext context, UserApp app) {
    if (app.type == UserAppType.noteAction) {
      // For NoteActionApp, show note selection dialog first
      _showNoteSelectionDialog(context, app);
    } else {
      // For normal apps, navigate directly
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => UserAppViewScreen(app: app, selectedNotes: null),
        ),
      );
    }
  }

  void _navigateToEditApp(BuildContext context, UserApp app) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserAppEditScreen(app: app),
      ),
    );
  }

  void _navigateToExportApp(BuildContext context, UserApp app) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExportAppScreen(app: app),
      ),
    );
  }

  Future<void> _cloneApp(BuildContext context, UserApp app, AppProvider appProvider) async {
    final l10n = AppLocalizations.of(context)!;
    
    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );
      
      // Clone the app
      await UserAppService.cloneUserApp(app);
      
      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
      }
      
      // Refresh the app list
      await appProvider.refreshUserApps();
      
      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.appClonedSuccessfully),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      // Close loading dialog if still open
      if (mounted) {
        Navigator.of(context).pop();
      }
      
      // Show error message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorCloningApp(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
      
      LoggerService.error('Error cloning app: $e', error: e);
    }
  }

  void _handleMenuAction(BuildContext context, String action, UserApp app, AppProvider appProvider) {
    switch (action) {
      case 'edit':
        _navigateToEditApp(context, app);
        break;
      case 'clone':
        _cloneApp(context, app, appProvider);
        break;
      case 'export':
        _navigateToExportApp(context, app);
        break;
      case 'delete':
        _showDeleteDialog(context, app, appProvider);
        break;
    }
  }

  void _showNoteSelectionDialog(BuildContext context, UserApp app) {
    showDialog(
      context: context,
      builder: (context) => NoteSelectionDialog(
        onNotesSelected: (selectedNotes) {
          Navigator.of(context).pop(); // Close dialog
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => UserAppViewScreen(
                app: app, 
                selectedNotes: selectedNotes,
              ),
            ),
          );
        },
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
