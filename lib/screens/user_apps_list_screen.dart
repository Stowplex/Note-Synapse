import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../services/logger_service.dart';
import '../services/user_app_service.dart';
import '../services/service_locator.dart';
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
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _editingFocusNode.addListener(_onFocusChange);
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _editingController.dispose();
    _editingFocusNode.removeListener(_onFocusChange);
    _editingFocusNode.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
    });
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
            content: Text(
              AppLocalizations.of(context)!.errorUpdatingAppName(e.toString()),
            ),
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
    final l10n = AppLocalizations.of(context)!;

    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        // Check if WebView is supported
        if (!appProvider.isWebViewSupported()) {
          return _buildWebViewNotSupportedScreen(context);
        }

        final filteredApps = _getFilteredApps(appProvider.userApps);

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.myApps),
            actions: [
              SizedBox(
                width: 200,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 8.0,
                  ),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: l10n.searchApps,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surface.withOpacity(0.7),
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ],
          ),
          body: filteredApps.isEmpty
              ? _buildEmptyState(
                  context,
                  appProvider.userApps.isEmpty,
                  _searchQuery.isNotEmpty,
                )
              : _buildAppsList(context, appProvider, filteredApps),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _showAddAppMenu(context),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  Widget _buildWebViewNotSupportedScreen(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.myApps)),
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

  Widget _buildEmptyState(
    BuildContext context,
    bool isNoApps,
    bool isSearchResult,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSearchResult ? Icons.search_off : Icons.apps,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              isSearchResult ? l10n.noAppsFound : l10n.noUserApps,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              isSearchResult
                  ? l10n.tryAdjustingSearchTerms
                  : l10n.createFirstApp,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (!isSearchResult) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => _showAddAppMenu(context),
                icon: const Icon(Icons.add),
                label: Text(l10n.createNewApp),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<UserApp> _getFilteredApps(List<UserApp> apps) {
    if (_searchQuery.isEmpty) {
      return apps;
    }
    return apps.where((app) {
      final nameMatch = app.name.toLowerCase().contains(_searchQuery);
      final descriptionMatch = app.description.toLowerCase().contains(
        _searchQuery,
      );
      return nameMatch || descriptionMatch;
    }).toList();
  }

  Widget _buildAppsList(
    BuildContext context,
    AppProvider appProvider,
    List<UserApp> apps,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: apps.length,
      itemBuilder: (context, index) {
        final app = apps[index];
        return _buildAppCard(context, app, appProvider);
      },
    );
  }

  Widget _buildAppCard(
    BuildContext context,
    UserApp app,
    AppProvider appProvider,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = _editingAppId == app.id;

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Icon(
            _getAppIcon(app.type),
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
              _getAppTypeLabel(l10n, app.type),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
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
                onSelected: (value) =>
                    _handleMenuAction(context, value, app, appProvider),
                itemBuilder: (context) {
                  final isMultiFunction = appProvider.multiFunctionApps
                      .contains(app.id);
                  return [
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
                    if (app.type == UserAppType.normal)
                      PopupMenuItem<String>(
                        value: 'toggleMultiFunction',
                        child: Row(
                          children: [
                            Icon(
                              isMultiFunction
                                  ? Icons.remove_circle_outline
                                  : Icons.add_circle_outline,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              isMultiFunction
                                  ? l10n.removeFromMultiFunction
                                  : l10n.addToMultiFunction,
                            ),
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
                      value: 'manageState',
                      child: Row(
                        children: [
                          const Icon(Icons.storage),
                          const SizedBox(width: 8),
                          Text(l10n.manageAppState),
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
                  ];
                },
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
                _importApp();
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
      MaterialPageRoute(builder: (context) => const UserAppCreationScreen()),
    );
  }

  // Uses the State's own context: the bottom-sheet context that invokes this
  // is popped before the picker completes.
  Future<void> _importApp() async {
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
          LoggerService.debug(
            'Selected file: ${file.name}, path: ${file.path}',
          );

          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ImportAppScreen(yamlFilePath: file.path!),
            ),
          );
        } else {
          LoggerService.debug('File path is null');
          _showImportError('File path is null');
        }
      } else {
        LoggerService.debug('No file selected or result is null');
        _showImportError('No file selected or result is null');
      }
    } catch (e) {
      LoggerService.error('Error in file picker: $e');
      _showImportError('Error selecting file: $e');
    }
  }

  void _showImportError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.orange),
    );
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
          builder: (context) =>
              UserAppViewScreen(app: app, selectedNotes: null),
        ),
      );
    }
  }

  void _navigateToEditApp(BuildContext context, UserApp app) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => UserAppEditScreen(app: app)),
    );
  }

  void _navigateToExportApp(BuildContext context, UserApp app) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExportAppScreen(app: app)),
    );
  }

  Future<void> _cloneApp(
    BuildContext context,
    UserApp app,
    AppProvider appProvider,
  ) async {
    final l10n = AppLocalizations.of(context)!;

    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      // Clone the app
      await getIt<UserAppService>().cloneUserApp(app);

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

  void _handleMenuAction(
    BuildContext context,
    String action,
    UserApp app,
    AppProvider appProvider,
  ) {
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
      case 'manageState':
        _showAppStateDialog(context, app, appProvider);
        break;
      case 'delete':
        _showDeleteDialog(context, app, appProvider);
        break;
      case 'toggleMultiFunction':
        _toggleMultiFunction(context, app, appProvider);
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
              builder: (context) =>
                  UserAppViewScreen(app: app, selectedNotes: selectedNotes),
            ),
          );
        },
      ),
    );
  }

  void _showAppStateDialog(
    BuildContext context,
    UserApp app,
    AppProvider appProvider,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) =>
          _AppStateDialog(app: app, appProvider: appProvider),
    );
  }

  void _showDeleteDialog(
    BuildContext context,
    UserApp app,
    AppProvider appProvider,
  ) {
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

  Future<void> _toggleMultiFunction(
    BuildContext context,
    UserApp app,
    AppProvider appProvider,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final isMultiFunction = appProvider.multiFunctionApps.contains(app.id);

    try {
      if (isMultiFunction) {
        await appProvider.removeAppFromMultiFunction(app.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.appRemovedFromMultiFunction)),
          );
        }
      } else {
        await appProvider.addAppToMultiFunction(app.id);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.appAddedToMultiFunction)));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating multi-function status: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  IconData _getAppIcon(UserAppType type) {
    switch (type) {
      case UserAppType.noteAction:
        return Icons.apps;
      case UserAppType.aiTool:
        return Icons.smart_toy;
      case UserAppType.normal:
        return Icons.web;
    }
  }

  String _getAppTypeLabel(AppLocalizations l10n, UserAppType type) {
    switch (type) {
      case UserAppType.noteAction:
        return l10n.appTypeNoteAction;
      case UserAppType.aiTool:
        return l10n.appTypeAiTool;
      case UserAppType.normal:
        return l10n.appTypeNormal;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _AppStateDialog extends StatefulWidget {
  final UserApp app;
  final AppProvider appProvider;

  const _AppStateDialog({required this.app, required this.appProvider});

  @override
  State<_AppStateDialog> createState() => _AppStateDialogState();
}

class _AppStateDialogState extends State<_AppStateDialog> {
  late TextEditingController _stateController;
  bool _isLoading = true;
  bool _hasState = false;

  @override
  void initState() {
    super.initState();
    _stateController = TextEditingController();
    _loadState();
  }

  @override
  void dispose() {
    _stateController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    try {
      final state = await widget.appProvider.getAppState(widget.app.id);
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (state != null && state.isNotEmpty) {
            _hasState = true;
            // Format JSON with indentation for readability
            const encoder = JsonEncoder.withIndent('  ');
            _stateController.text = encoder.convert(state);
          } else {
            _hasState = false;
            _stateController.text = '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasState = false;
          _stateController.text = '';
        });
      }
      LoggerService.error('Error loading app state: $e', error: e);
    }
  }

  Future<void> _saveState() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final stateText = _stateController.text.trim();
      Map<String, dynamic> state;

      if (stateText.isEmpty) {
        state = <String, dynamic>{};
      } else {
        // Try to parse JSON
        state = jsonDecode(stateText) as Map<String, dynamic>;
      }

      await widget.appProvider.saveAppState(widget.app.id, state);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.stateSaved),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid JSON: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
      LoggerService.error('Error saving app state: $e', error: e);
    }
  }

  Future<void> _clearState() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await widget.appProvider.saveAppState(widget.app.id, <String, dynamic>{});
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.stateCleared),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorSavingState(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
      LoggerService.error('Error clearing app state: $e', error: e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.manageAppState),
      content: SizedBox(
        width: double.maxFinite,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_hasState)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        l10n.noState,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ),
                  TextField(
                    controller: _stateController,
                    maxLines: 15,
                    decoration: InputDecoration(
                      hintText: _hasState ? '' : '{}',
                      border: const OutlineInputBorder(),
                      labelText: l10n.appState,
                    ),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        if (_hasState)
          TextButton(onPressed: _clearState, child: Text(l10n.clearState)),
        TextButton(onPressed: _saveState, child: Text(l10n.save)),
      ],
    );
  }
}
